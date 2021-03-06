--------------------------------------------------------------------------------
-- | This module mostly meant for internal usage, and might change between minor
-- releases.
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE Rank2Types                #-}
module Text.Digestive.Form.Internal
    ( Form
    , FormTree (..)
    , SomeForm (..)
    , Ref
    , transform
    , monadic
    , toFormTree
    , children
    , (.:)
    , getRef
    , lookupForm
    , toField
    , queryField
    , eval
    , formMapView

      -- * Debugging
    , debugFormPaths
    ) where


--------------------------------------------------------------------------------
import           Control.Applicative    (Applicative (..))
import           Control.Monad          (liftM, liftM2, (>=>))
import           Control.Monad.Identity (Identity (..))
import           Data.Monoid            (Monoid)


--------------------------------------------------------------------------------
import           Data.Text              (Text)
import qualified Data.Text              as T


--------------------------------------------------------------------------------
import           Text.Digestive.Field
import           Text.Digestive.Types


--------------------------------------------------------------------------------
-- | Base type for a form.
--
-- The three type parameters are:
--
-- * @v@: the type for textual information, displayed to the user. For example,
--   error messages are of this type. @v@ stands for "view".
--
-- * @m@: the monad in which validators operate. The classical example is when
--   validating input requires access to a database, in which case this @m@
--   should be an instance of @MonadIO@.
--
-- * @a@: the type of the value returned by the form, used for its Applicative
--   instance.
--
type Form v m a = FormTree m v m a


--------------------------------------------------------------------------------
data FormTree t v m a where
    -- Applicative interface
    Pure    :: Field v a -> FormTree t v m a
    App     :: FormTree t v m (b -> a)
            -> FormTree t v m b
            -> FormTree t v m a

    -- Modifications
    Map     :: (b -> m (Result v a)) -> FormTree t v m b -> FormTree t v m a
    Monadic :: t (FormTree t v m a) -> FormTree t v m a

    -- Setting refs
    Ref     :: Ref -> FormTree t v m a -> FormTree t v m a


--------------------------------------------------------------------------------
instance Monad m => Functor (FormTree t v m) where
    fmap = transform . (return .) . (return .)


--------------------------------------------------------------------------------
instance (Monad m, Monoid v) => Applicative (FormTree t v m) where
    pure x  = Pure (Singleton x)
    x <*> y = App x y


--------------------------------------------------------------------------------
instance Show (FormTree Identity v m a) where
    show = unlines . showForm


--------------------------------------------------------------------------------
data SomeForm v m = forall a. SomeForm (FormTree Identity v m a)


--------------------------------------------------------------------------------
instance Show (SomeForm v m) where
    show (SomeForm f) = show f


--------------------------------------------------------------------------------
type Ref = Text


--------------------------------------------------------------------------------
showForm :: FormTree Identity v m a -> [String]
showForm form = case form of
    (Pure x)  -> ["Pure (" ++ show x ++ ")"]
    (App x y) -> concat
        [ ["App"]
        , map indent (showForm x)
        , map indent (showForm y)
        ]
    (Map _ x)   -> "Map _" : map indent (showForm x)
    (Monadic x) -> "Monadic" : map indent (showForm $ runIdentity x)
    (Ref r x)   -> ("Ref " ++ show r) : map indent (showForm x)
  where
    indent = ("  " ++)


--------------------------------------------------------------------------------
transform :: Monad m
          => (a -> m (Result v b)) -> FormTree t v m a -> FormTree t v m b
transform f (Map g x) = flip Map x $ \y -> bindResult (g y) f
transform f x         = Map f x


--------------------------------------------------------------------------------
monadic :: m (Form v m a) -> Form v m a
monadic = Monadic


--------------------------------------------------------------------------------
toFormTree :: Monad m => Form v m a -> m (FormTree Identity v m a)
toFormTree (Pure x)    = return $ Pure x
toFormTree (App x y)   = liftM2 App (toFormTree x) (toFormTree y)
toFormTree (Map f x)   = liftM (Map f) (toFormTree x)
toFormTree (Monadic x) = x >>= toFormTree >>= return . Monadic . Identity
toFormTree (Ref r x)   = liftM (Ref r) (toFormTree x)


--------------------------------------------------------------------------------
children :: FormTree Identity v m a -> [SomeForm v m]
children (Pure _)    = []
children (App x y)   = [SomeForm x, SomeForm y]
children (Map _ x)   = children x
children (Monadic x) = children $ runIdentity x
children (Ref _ x)   = children x


--------------------------------------------------------------------------------
pushRef :: Monad t => Ref -> FormTree t v m a -> FormTree t v m a
pushRef = Ref


--------------------------------------------------------------------------------
-- | Operator to set a name for a subform.
(.:) :: Monad m => Text -> Form v m a -> Form v m a
(.:) = pushRef
infixr 5 .:


--------------------------------------------------------------------------------
popRef :: FormTree Identity v m a -> (Maybe Ref, FormTree Identity v m a)
popRef form = case form of
    (Pure _)    -> (Nothing, form)
    (App _ _)   -> (Nothing, form)
    (Map f x)   -> let (r, form') = popRef x in (r, Map f form')
    (Monadic x) -> popRef $ runIdentity x
    (Ref r x)   -> (Just r, x)


--------------------------------------------------------------------------------
getRef :: FormTree Identity v m a -> Maybe Ref
getRef = fst . popRef


--------------------------------------------------------------------------------
lookupForm :: Path -> FormTree Identity v m a -> [SomeForm v m]
lookupForm path = go path . SomeForm
  where
    -- Note how we use `popRef` to strip the ref away. This is really important.
    go []       form            = [form]
    go (r : rs) (SomeForm form) = case popRef form of
        (Just r', stripped)
            | r == r' && null rs -> [SomeForm stripped]
            | r == r'            -> children form >>= go rs
            | otherwise          -> []
        (Nothing, _)             -> children form >>= go (r : rs)


--------------------------------------------------------------------------------
toField :: FormTree Identity v m a -> Maybe (SomeField v)
toField (Pure x)    = Just (SomeField x)
toField (App _ _)   = Nothing
toField (Map _ x)   = toField x
toField (Monadic x) = toField (runIdentity x)
toField (Ref _ x)   = toField x


--------------------------------------------------------------------------------
queryField :: Path
           -> FormTree Identity v m a
           -> (forall b. Field v b -> c)
           -> c
queryField path form f = case lookupForm path form of
    []                   -> error $ ref ++ " does not exist"
    (SomeForm form' : _) -> case toField form' of
        Just (SomeField field) -> f field
        _                      -> error $ ref ++ " is not a field"
  where
    ref = T.unpack $ fromPath path


--------------------------------------------------------------------------------
ann :: Path -> Result v a -> Result [(Path, v)] a
ann _    (Success x) = Success x
ann path (Error x)   = Error [(path, x)]


--------------------------------------------------------------------------------
eval :: Monad m => Method -> Env m -> FormTree Identity v m a
     -> m (Result [(Path, v)] a, [(Path, FormInput)])
eval = eval' []

eval' :: Monad m => Path -> Method -> Env m -> FormTree Identity v m a
      -> m (Result [(Path, v)] a, [(Path, FormInput)])

eval' path method env form = case form of

    Pure field -> do
        val <- env path
        let x = evalField method val field
        return $ (pure x, [(path, v) | v <- val])

    App x y -> do
        (x', inp1) <- eval' path method env x
        (y', inp2) <- eval' path method env y
        return (x' <*> y', inp1 ++ inp2)

    Map f x -> do
        (x', inp) <- eval' path method env x
        x''       <- bindResult (return x') (f >=> return . ann path)
        return (x'', inp)

    Monadic x -> eval' path method env $ runIdentity x

    Ref r x -> eval' (path ++ [r]) method env x


--------------------------------------------------------------------------------
formMapView :: Monad m
            => (v -> w) -> FormTree Identity v m a -> FormTree Identity w m a
formMapView f (Pure x)    = Pure $ fieldMapView f x
formMapView f (App x y)   = App (formMapView f x) (formMapView f y)
formMapView f (Map g x)   = Map (g >=> return . resultMapError f) (formMapView f x)
formMapView f (Monadic x) = formMapView f $ runIdentity x
formMapView f (Ref r x)   = Ref r $ formMapView f x


--------------------------------------------------------------------------------
-- | Utility: bind for 'Result' inside another monad
bindResult :: Monad m
           => m (Result v a) -> (a -> m (Result v b)) -> m (Result v b)
bindResult mx f = do
    x <- mx
    case x of
        Error errs  -> return $ Error errs
        Success x'  -> f x'


--------------------------------------------------------------------------------
-- | Debugging purposes
debugFormPaths :: Monad m => FormTree Identity v m a -> [Path]
debugFormPaths (Pure _)    = [[]]
debugFormPaths (App x y)   = debugFormPaths x ++ debugFormPaths y
debugFormPaths (Map _ x)   = debugFormPaths x
debugFormPaths (Monadic x) = debugFormPaths $ runIdentity x
debugFormPaths (Ref r x)   = map (r :) $ debugFormPaths x
