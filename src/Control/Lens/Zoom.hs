{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
#ifdef TRUSTWORTHY
{-# LANGUAGE Trustworthy #-}
#endif

-------------------------------------------------------------------------------
-- |
-- Module      :  Control.Lens.Zoom
-- Copyright   :  (C) 2012-13 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  Rank2Types
--
-------------------------------------------------------------------------------
module Control.Lens.Zoom
  ( Magnify(..)
  , Zoom(..)
  ) where

import Control.Lens.Getter
import Control.Lens.Internal.Action
import Control.Lens.Internal.Zoom
import Control.Lens.Type
import Control.Monad
import Control.Monad.Reader as Reader
import Control.Monad.State as State
import Control.Monad.Trans.State.Lazy as Lazy
import Control.Monad.Trans.State.Strict as Strict
import Control.Monad.Trans.Writer.Lazy as Lazy
import Control.Monad.Trans.Writer.Strict as Strict
import Control.Monad.Trans.RWS.Lazy as Lazy
import Control.Monad.Trans.RWS.Strict as Strict
import Control.Monad.Trans.Error
import Control.Monad.Trans.List
import Control.Monad.Trans.Identity
import Control.Monad.Trans.Maybe
import Data.Monoid
import Data.Profunctor.Unsafe

-- $setup
-- >>> import Control.Lens
-- >>> import Control.Monad.State
-- >>> import Data.Map as Map
-- >>> import Debug.SimpleReflect.Expr as Expr
-- >>> import Debug.SimpleReflect.Vars as Vars
-- >>> let f :: Expr -> Expr; f = Vars.f
-- >>> let g :: Expr -> Expr; g = Vars.g
-- >>> let h :: Expr -> Expr -> Expr; h = Vars.h

-- Chosen so that they have lower fixity than ('%='), and to match ('<~').
infixr 2 `zoom`, `magnify`

-- | This class allows us to use 'zoom' in, changing the 'State' supplied by
-- many different 'Control.Monad.Monad' transformers, potentially quite
-- deep in a 'Monad' transformer stack.
class (Zoomed m ~ Zoomed n, MonadState s m, MonadState t n) => Zoom m n s t | m -> s, n -> t, m t -> n, n s -> m where
  -- | Run a monadic action in a larger 'State' than it was defined in,
  -- using a 'Lens'' or 'Control.Lens.Traversal.Traversal''.
  --
  -- This is commonly used to lift actions in a simpler 'State'
  -- 'Monad' into a 'State' 'Monad' with a larger 'State' type.
  --
  -- When applied to a 'Simple' 'Control.Lens.Traversal.Traversal' over
  -- multiple values, the actions for each target are executed sequentially
  -- and the results are aggregated.
  --
  -- This can be used to edit pretty much any 'Monad' transformer stack with a 'State' in it!
  --
  -- >>> flip State.evalState (a,b) $ zoom _1 $ use id
  -- a
  --
  -- >>> flip State.execState (a,b) $ zoom _1 $ id .= c
  -- (c,b)
  --
  -- >>> flip State.execState [(a,b),(c,d)] $ zoom traverse $ _2 %= f
  -- [(a,f b),(c,f d)]
  --
  -- >>> flip State.runState [(a,b),(c,d)] $ zoom traverse $ _2 <%= f
  -- (f b <> f d <> mempty,[(a,f b),(c,f d)])
  --
  -- >>> flip State.evalState (a,b) $ zoom both (use id)
  -- a <> b
  --
  -- @
  -- 'zoom' :: 'Monad' m             => 'Lens'' s t      -> 'StateT' t m a -> 'StateT' s m a
  -- 'zoom' :: ('Monad' m, 'Monoid' c) => 'Control.Lens.Traversal.Traversal'' s t -> 'StateT' t m c -> 'StateT' s m c
  -- 'zoom' :: 'Monad' m             => 'Lens'' s t      -> 'RWST' r w t m c -> 'RWST' r w s m c
  -- 'zoom' :: ('Monad' m, 'Monoid' c) => 'Control.Lens.Traversal.Traversal'' s t -> 'RWST' r w t m c -> 'RWST' r w s m c
  -- 'zoom' :: 'Monad' m             => 'Lens'' s t      -> 'ErrorT' e ('RWST' r w t m c) -> 'ErrorT' e ('RWST' r w s m c)
  -- 'zoom' :: ('Monad' m, 'Monoid' c) => 'Control.Lens.Traversal.Traversal'' s t -> 'ErrorT' e ('RWST' r w t m c) -> 'ErrorT' e ('RWST' r w s m c)
  -- ...
  -- @
  zoom :: LensLike' (Zoomed m c) t s -> m c -> n c

instance Monad z => Zoom (Strict.StateT s z) (Strict.StateT t z) s t where
  zoom l (Strict.StateT m) = Strict.StateT $ unfocusing #. l (Focusing #. m)
  {-# INLINE zoom #-}

instance Monad z => Zoom (Lazy.StateT s z) (Lazy.StateT t z) s t where
  zoom l (Lazy.StateT m) = Lazy.StateT $ unfocusing #. l (Focusing #. m)
  {-# INLINE zoom #-}

instance Zoom m n s t => Zoom (ReaderT e m) (ReaderT e n) s t where
  zoom l (ReaderT m) = ReaderT (zoom l . m)
  {-# INLINE zoom #-}

instance Zoom m n s t => Zoom (IdentityT m) (IdentityT n) s t where
  zoom l (IdentityT m) = IdentityT (zoom l m)
  {-# INLINE zoom #-}

instance (Monoid w, Monad z) => Zoom (Strict.RWST r w s z) (Strict.RWST r w t z) s t where
  zoom l (Strict.RWST m) = Strict.RWST $ \r -> unfocusingWith #. l (FocusingWith #. m r)
  {-# INLINE zoom #-}

instance (Monoid w, Monad z) => Zoom (Lazy.RWST r w s z) (Lazy.RWST r w t z) s t where
  zoom l (Lazy.RWST m) = Lazy.RWST $ \r -> unfocusingWith #. l (FocusingWith #. m r)
  {-# INLINE zoom #-}

instance (Monoid w, Zoom m n s t) => Zoom (Strict.WriterT w m) (Strict.WriterT w n) s t where
  zoom l = Strict.WriterT . zoom (\afb -> unfocusingPlus #. l (FocusingPlus #. afb)) . Strict.runWriterT
  {-# INLINE zoom #-}

instance (Monoid w, Zoom m n s t) => Zoom (Lazy.WriterT w m) (Lazy.WriterT w n) s t where
  zoom l = Lazy.WriterT . zoom (\afb -> unfocusingPlus #. l (FocusingPlus #. afb)) . Lazy.runWriterT
  {-# INLINE zoom #-}

instance Zoom m n s t => Zoom (ListT m) (ListT n) s t where
  zoom l = ListT . zoom (\afb -> unfocusingOn . l (FocusingOn . afb)) . runListT
  {-# INLINE zoom #-}

instance Zoom m n s t => Zoom (MaybeT m) (MaybeT n) s t where
  zoom l = MaybeT . liftM getMay . zoom (\afb -> unfocusingMay #. l (FocusingMay #. afb)) . liftM May . runMaybeT
  {-# INLINE zoom #-}

instance (Error e, Zoom m n s t) => Zoom (ErrorT e m) (ErrorT e n) s t where
  zoom l = ErrorT . liftM getErr . zoom (\afb -> unfocusingErr #. l (FocusingErr #. afb)) . liftM Err . runErrorT
  {-# INLINE zoom #-}

-- TODO: instance Zoom m m a a => Zoom (ContT r m) (ContT r m) a a where

-- | This class allows us to use 'magnify' part of the environment, changing the environment supplied by
-- many different 'Monad' transformers. Unlike 'zoom' this can change the environment of a deeply nested 'Monad' transformer.
--
-- Also, unlike 'zoom', this can be used with any valid 'Getter', but cannot be used with a 'Traversal' or 'Fold'.
class (Magnified m ~ Magnified n, MonadReader b m, MonadReader a n) => Magnify m n b a | m -> b, n -> a, m a -> n, n b -> m where
  -- | Run a monadic action in a larger environment than it was defined in, using a 'Getter'.
  --
  -- This acts like 'Control.Monad.Reader.Class.local', but can in many cases change the type of the environment as well.
  --
  -- This is commonly used to lift actions in a simpler 'Reader' 'Monad' into a 'Monad' with a larger environment type.
  --
  -- This can be used to edit pretty much any 'Monad' transformer stack with an environment in it:
  --
  -- >>> (1,2) & magnify _2 (+1)
  -- 3
  --
  -- >>> flip Reader.runReader (1,2) $ magnify _1 Reader.ask
  -- 1
  --
  -- >>> flip Reader.runReader (1,2,[10..20]) $ magnify (_3._tail) Reader.ask
  -- [11,12,13,14,15,16,17,18,19,20]
  --
  -- @
  -- 'magnify' ::             'Getter' s a -> (a -> r) -> s -> r
  -- 'magnify' :: 'Monoid' c => 'Fold' s a   -> (a -> r) -> s -> r
  -- @
  --
  -- @
  -- 'magnify' :: 'Monoid' w                'Getter' s t -> 'RWST' s w st c -> 'RWST' t w st c
  -- 'magnify' :: ('Monoid' w, 'Monoid' c) => 'Fold' s t   -> 'RWST' s w st c -> 'RWST' t w st c
  -- ...
  -- @
  magnify :: LensLike' (Magnified m c) a b -> m c -> n c

instance Monad m => Magnify (ReaderT b m) (ReaderT a m) b a where
  magnify l (ReaderT m) = ReaderT $ getEffect #. l (Effect #. m)
  {-# INLINE magnify #-}

-- | @
-- 'magnify' = 'views'
-- @
instance Magnify ((->) b) ((->) a) b a where
  magnify = views
  {-# INLINE magnify #-}

instance (Monad m, Monoid w) => Magnify (Strict.RWST b w s m) (Strict.RWST a w s m) b a where
  magnify l (Strict.RWST m) = Strict.RWST $ getEffectRWS #. l (EffectRWS #. m)
  {-# INLINE magnify #-}

instance (Monad m, Monoid w) => Magnify (Lazy.RWST b w s m) (Lazy.RWST a w s m) b a where
  magnify l (Lazy.RWST m) = Lazy.RWST $ getEffectRWS #. l (EffectRWS #. m)
  {-# INLINE magnify #-}

instance Magnify m n b a => Magnify (IdentityT m) (IdentityT n) b a where
  magnify l (IdentityT m) = IdentityT (magnify l m)
  {-# INLINE magnify #-}
