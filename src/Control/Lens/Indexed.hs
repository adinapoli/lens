{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
#ifdef DEFAULT_SIGNATURES
{-# LANGUAGE DefaultSignatures #-}
#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ >= 706
#define MPTC_DEFAULTS
#endif
#endif
#ifdef TRUSTWORTHY
{-# LANGUAGE Trustworthy #-} -- vector, hashable
#endif

#ifndef MIN_VERSION_containers
#define MIN_VERSION_containers(x,y,z) 1
#endif
-------------------------------------------------------------------------------
-- |
-- Module      :  Control.Lens.Indexed
-- Copyright   :  (C) 2012-13 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  Rank2Types
--
-- (The classes in here need to be defined together for @DefaultSignatures@ to work.)
-------------------------------------------------------------------------------
module Control.Lens.Indexed
  (
  -- * Indexing
    Indexable(..)
  , Conjoined(..)
  , Indexed(..)
  , (<.), (<.>), (.>)
  , reindexed
  , icompose
  , indexing
  , indexing64
  -- * Indexed Functors
  , FunctorWithIndex(..)
  -- * Indexed Foldables
  , FoldableWithIndex(..)
  , ifolding
  -- ** Indexed Foldable Combinators
  , iany
  , iall
  , itraverse_
  , ifor_
  , imapM_
  , iforM_
  , iconcatMap
  , ifind
  , ifoldrM
  , ifoldlM
  , itoList
  -- * Converting to Folds
  , withIndex
  , asIndex
  -- * Restricting by Index
  , indices
  , index
  -- * Indexed Traversables
  , TraversableWithIndex(..)
  -- * Indexed Traversable Combinators
  , ifor
  , imapM
  , iforM
  , imapAccumR
  , imapAccumL
  ) where

import Control.Applicative
import Control.Applicative.Backwards
import Control.Monad (void, liftM)
import Control.Monad.Trans.State.Lazy as Lazy
import Control.Lens.Fold
import Control.Lens.Internal.Fold
import Control.Lens.Internal.Getter
import Control.Lens.Internal.Indexed
import Control.Lens.Internal.Level
import Control.Lens.Internal.Magma
import Control.Lens.Setter
import Control.Lens.Traversal
import Control.Lens.Type
import Data.Foldable
import Data.Functor.Contravariant
import Data.Functor.Identity
import Data.Functor.Reverse
import Data.Hashable
import Data.HashMap.Lazy as HashMap
import Data.IntMap as IntMap
import Data.Map as Map
import Data.Monoid
import Data.Profunctor.Unsafe
import Data.Sequence hiding (index)
import Data.Traversable
import Data.Tuple (swap)
import Data.Vector (Vector)
import qualified Data.Vector as V

infixr 9 <.>, <., .>

-- $setup
-- >>> :set -XNoOverloadedStrings
-- >>> import Control.Lens

-- | Compose an 'Indexed' function with a non-indexed function.
--
-- Mnemonically, the @<@ points to the indexing we want to preserve.
(<.) :: Indexable i p => (Indexed i s t -> r) -> ((a -> b) -> s -> t) -> p a b -> r
(<.) f g h = f . Indexed $ g . indexed h
{-# INLINE (<.) #-}

-- | Compose a non-indexed function with an 'Indexed' function.
--
-- Mnemonically, the @>@ points to the indexing we want to preserve.
--
-- This is the same as @('.')@. 
--
-- @f '.' g@ (and @f '.>' g@) gives you the index of @g@ unless @g@ is index-preserving, like a
-- 'Prism', 'Iso' or 'Equality', in which case it'll pass through the index of @f@.
(.>) :: (st -> r) -> (kab -> st) -> kab -> r
(.>) = (.)
{-# INLINE (.>) #-}

-- | Remap the index.
reindexed :: Indexable j p => (i -> j) -> (Indexed i a b -> r) -> p a b -> r
reindexed ij f g = f . Indexed $ indexed g . ij
{-# INLINE reindexed #-}

-- | Composition of 'Indexed' functions.
--
-- Mnemonically, the @\<@ and @\>@ points to the fact that we want to preserve the indices.
(<.>) :: Indexable (i, j) p => (Indexed i s t -> r) -> (Indexed j a b -> s -> t) -> p a b -> r
f <.> g = icompose (,) f g
{-# INLINE (<.>) #-}

-- | Composition of 'Indexed' functions with a user supplied function for combining indices.
icompose :: Indexable p c => (i -> j -> p) -> (Indexed i s t -> r) -> (Indexed j a b -> s -> t) -> c a b -> r
icompose ijk istr jabst cab = istr . Indexed $ \i -> jabst . Indexed $ \j -> indexed cab $ ijk i j
{-# INLINE icompose #-}

-------------------------------------------------------------------------------
-- Converting to Folds
-------------------------------------------------------------------------------

-- | Fold a container with indices returning both the indices and the values.
--
-- The result is only valid to compose in a 'Traversal', if you don't edit the
-- index as edits to the index have no effect.
withIndex :: (Indexable i p, Functor f) => Overloading p (Indexed i) f s t (i, s) (j, t)
withIndex f = Indexed $ \i a -> snd <$> indexed f i (i, a)
{-# INLINE withIndex #-}

-- | When composed with an 'IndexedFold' or 'IndexedTraversal' this yields an
-- ('Indexed') 'Fold' of the indices.
asIndex :: (Indexable i p, Contravariant f, Functor f) => Overloading' p (Indexed i) f s i
asIndex f = Indexed $ \i _ -> coerce (indexed f i i)
{-# INLINE asIndex #-}

-------------------------------------------------------------------------------
-- Restricting by index
-------------------------------------------------------------------------------

-- | This allows you to filter an 'IndexedFold', 'IndexedGetter', 'IndexedTraversal' or 'IndexedLens' based on a predicate
-- on the indices.
--
-- >>> ["hello","the","world","!!!"]^..traversed.indices even
-- ["hello","world"]
--
-- >>> over (traversed.indices (>0)) Prelude.reverse $ ["He","was","stressed","o_O"]
-- ["He","saw","desserts","O_o"]
indices :: (Indexable i p, Applicative f) => (i -> Bool) -> Overloading' p (Indexed i) f a a
indices p f = Indexed $ \i a -> if p i then indexed f i a else pure a
{-# INLINE indices #-}

-- | This allows you to filter an 'IndexedFold', 'IndexedGetter', 'IndexedTraversal' or 'IndexedLens' based on an index.
--
-- >>> ["hello","the","world","!!!"]^?traversed.index 2
-- Just "world"
index :: (Indexable i p, Eq i, Applicative f) => i -> Overloading' p (Indexed i) f a a
index j f = Indexed $ \i a -> if j == i then indexed f i a else pure a
{-# INLINE index #-}


-------------------------------------------------------------------------------
-- FunctorWithIndex
-------------------------------------------------------------------------------

-- | A 'Functor' with an additional index.
--
-- Instances must satisfy a modified form of the 'Functor' laws:
--
-- @
-- 'imap' f '.' 'imap' g ≡ 'imap' (\\i -> f i '.' g i)
-- 'imap' (\\_ a -> a) ≡ 'id'
-- @
class Functor f => FunctorWithIndex i f | f -> i where
  -- | Map with access to the index.
  imap :: (i -> a -> b) -> f a -> f b
#ifdef MPTC_DEFAULTS
  default imap :: TraversableWithIndex i f => (i -> a -> b) -> f a -> f b
  imap = iover itraversed
  {-# INLINE imap #-}
#endif

  -- | The 'IndexedSetter' for a 'FunctorWithIndex'.
  --
  -- If you don't need access to the index, then 'mapped' is more flexible in what it accepts.
  imapped :: FunctorWithIndex i f => IndexedSetter i (f a) (f b) a b
  imapped = conjoined mapped (isets imap)
  {-# INLINE [0] imapped #-}

#ifdef USE_RULES
{-# RULES "imapped/mapped" imapped = mapped :: Functor f => Setter (f a) (f b) a b #-}
#endif

-------------------------------------------------------------------------------
-- FoldableWithIndex
-------------------------------------------------------------------------------

-- | A container that supports folding with an additional index.
class Foldable f => FoldableWithIndex i f | f -> i where
  --
  -- | Fold a container by mapping value to an arbitrary 'Monoid' with access to the index @i@.
  --
  -- When you don't need access to the index then 'foldMap' is more flexible in what it accepts.
  --
  -- @
  -- 'foldMap' ≡ 'ifoldMap' '.' 'const'
  -- @
  ifoldMap :: Monoid m => (i -> a -> m) -> f a -> m
#ifdef MPTC_DEFAULTS
  default ifoldMap :: (TraversableWithIndex i f, Monoid m) => (i -> a -> m) -> f a -> m
  ifoldMap = ifoldMapOf itraversed
  {-# INLINE ifoldMap #-}
#endif

  -- | The 'IndexedFold' of a 'FoldableWithIndex' container.
  ifolded :: IndexedFold i (f a) a
  ifolded = conjoined folded $ \f -> coerce . getFolding . ifoldMap (\i -> Folding #. indexed f i)
  {-# INLINE[0] ifolded #-} -- see RULES below

  -- | Right-associative fold of an indexed container with access to the index @i@.
  --
  -- When you don't need access to the index then 'Data.Foldable.foldr' is more flexible in what it accepts.
  --
  -- @
  -- 'Data.Foldable.foldr' ≡ 'ifoldr' '.' 'const'
  -- @
  ifoldr   :: (i -> a -> b -> b) -> b -> f a -> b
  ifoldr f z t = appEndo (ifoldMap (\i -> Endo #. f i) t) z
  {-# INLINE ifoldr #-}

  -- | Left-associative fold of an indexed container with access to the index @i@.
  --
  -- When you don't need access to the index then 'Data.Foldable.foldl' is more flexible in what it accepts.
  --
  -- @
  -- 'Data.Foldable.foldl' ≡ 'ifoldl' '.' 'const'
  -- @
  ifoldl :: (i -> b -> a -> b) -> b -> f a -> b
  ifoldl f z t = appEndo (getDual (ifoldMap (\i -> Dual #. Endo #. flip (f i)) t)) z
  {-# INLINE ifoldl #-}

  -- | /Strictly/ fold right over the elements of a structure with access to the index @i@.
  --
  -- When you don't need access to the index then 'foldr'' is more flexible in what it accepts.
  --
  -- @
  -- 'foldr'' ≡ 'ifoldr'' '.' 'const'
  -- @
  ifoldr' :: (i -> a -> b -> b) -> b -> f a -> b
  ifoldr' f z0 xs = ifoldl f' id xs z0
    where f' i k x z = k $! f i x z
  {-# INLINE ifoldr' #-}

  -- | Fold over the elements of a structure with an index, associating to the left, but /strictly/.
  --
  -- When you don't need access to the index then 'Control.Lens.Fold.foldlOf'' is more flexible in what it accepts.
  --
  -- @
  -- 'Control.Lens.Fold.foldlOf'' l ≡ 'ifoldlOf'' l '.' 'const'
  -- @
  ifoldl' :: (i -> b -> a -> b) -> b -> f a -> b
  ifoldl' f z0 xs = ifoldr f' id xs z0
    where f' i x k z = k $! f i z x
  {-# INLINE ifoldl' #-}

#ifdef USE_RULES
{-# RULES "ifolded/folded" ifolded = folded :: Foldable f => Fold (f a) a #-}
#endif

-- | Obtain a 'Fold' by lifting an operation that returns a 'Foldable' result.
--
-- This can be useful to lift operations from @'Data.List'@ and elsewhere into a 'Fold'.
ifolding :: FoldableWithIndex i f => (s -> f a) -> IndexedFold i s a
ifolding sfa iagb = coerce . itraverse_ (indexed iagb) . sfa
{-# INLINE ifolding #-}

-- | Return whether or not any element in a container satisfies a predicate, with access to the index @i@.
--
-- When you don't need access to the index then 'any' is more flexible in what it accepts.
--
-- @
-- 'any' ≡ 'iany' '.' 'const'
-- @
iany :: FoldableWithIndex i f => (i -> a -> Bool) -> f a -> Bool
iany f = getAny #. ifoldMap (\i -> Any #. f i)
{-# INLINE iany #-}

-- | Return whether or not all elements in a container satisfy a predicate, with access to the index @i@.
--
-- When you don't need access to the index then 'all' is more flexible in what it accepts.
--
-- @
-- 'all' ≡ 'iall' '.' 'const'
-- @
iall :: FoldableWithIndex i f => (i -> a -> Bool) -> f a -> Bool
iall f = getAll #. ifoldMap (\i -> All #. f i)
{-# INLINE iall #-}

-- | Traverse elements with access to the index @i@, discarding the results.
--
-- When you don't need access to the index then 'traverse_' is more flexible in what it accepts.
--
-- @
-- 'traverse_' l = 'itraverse' '.' 'const'
-- @
itraverse_ :: (FoldableWithIndex i t, Applicative f) => (i -> a -> f b) -> t a -> f ()
itraverse_ f = getTraversed #. ifoldMap (\i -> Traversed #. void . f i)
{-# INLINE itraverse_ #-}

-- | Traverse elements with access to the index @i@, discarding the results (with the arguments flipped).
--
-- @
-- 'ifor_' ≡ 'flip' 'itraverse_'
-- @
--
-- When you don't need access to the index then 'for_' is more flexible in what it accepts.
--
-- @
-- 'for_' a ≡ 'ifor_' a '.' 'const'
-- @
ifor_ :: (FoldableWithIndex i t, Applicative f) => t a -> (i -> a -> f b) -> f ()
ifor_ = flip itraverse_
{-# INLINE ifor_ #-}

-- | Run monadic actions for each target of an 'IndexedFold' or 'Control.Lens.IndexedTraversal.IndexedTraversal' with access to the index,
-- discarding the results.
--
-- When you don't need access to the index then 'Control.Lens.Fold.mapMOf_' is more flexible in what it accepts.
--
-- @
-- 'mapM_' ≡ 'imapM' '.' 'const'
-- @
imapM_ :: (FoldableWithIndex i t, Monad m) => (i -> a -> m b) -> t a -> m ()
imapM_ f = getSequenced #. ifoldMap (\i -> Sequenced #. liftM skip . f i)
{-# INLINE imapM_ #-}

-- | Run monadic actions for each target of an 'IndexedFold' or 'Control.Lens.IndexedTraversal.IndexedTraversal' with access to the index,
-- discarding the results (with the arguments flipped).
--
-- @
-- 'iforM_' ≡ 'flip' 'imapM_'
-- @
--
-- When you don't need access to the index then 'Control.Lens.Fold.forMOf_' is more flexible in what it accepts.
--
-- @
-- 'Control.Lens.Fold.forMOf_' l a ≡ 'iforMOf' l a '.' 'const'
-- @
iforM_ :: (FoldableWithIndex i t, Monad m) => t a -> (i -> a -> m b) -> m ()
iforM_ = flip imapM_
{-# INLINE iforM_ #-}

-- | Concatenate the results of a function of the elements of an indexed container with access to the index.
--
-- When you don't need access to the index then 'concatMap' is more flexible in what it accepts.
--
-- @
-- 'concatMap' ≡ 'iconcatMap' '.' 'const'
-- 'iconcatMap' ≡ 'ifoldMap'
-- @
iconcatMap :: FoldableWithIndex i f => (i -> a -> [b]) -> f a -> [b]
iconcatMap = ifoldMap
{-# INLINE iconcatMap #-}

-- | Searches a container with a predicate that is also supplied the index, returning the left-most element of the structure
-- matching the predicate, or 'Nothing' if there is no such element.
--
-- When you don't need access to the index then 'find' is more flexible in what it accepts.
--
-- @
-- 'find' ≡ 'ifind' '.' 'const'
-- @
ifind :: FoldableWithIndex i f => (i -> a -> Bool) -> f a -> Maybe (i, a)
ifind p = ifoldr (\i a y -> if p i a then Just (i, a) else y) Nothing
{-# INLINE ifind #-}

-- | Monadic fold right over the elements of a structure with an index.
--
-- When you don't need access to the index then 'foldrM' is more flexible in what it accepts.
--
-- @
-- 'foldrM' ≡ 'ifoldrM' '.' 'const'
-- @
ifoldrM :: (FoldableWithIndex i f, Monad m) => (i -> a -> b -> m b) -> b -> f a -> m b
ifoldrM f z0 xs = ifoldl f' return xs z0
  where f' i k x z = f i x z >>= k
{-# INLINE ifoldrM #-}

-- | Monadic fold over the elements of a structure with an index, associating to the left.
--
-- When you don't need access to the index then 'foldlM' is more flexible in what it accepts.
--
-- @
-- 'foldlM' ≡ 'ifoldlM' '.' 'const'
-- @
ifoldlM :: (FoldableWithIndex i f, Monad m) => (i -> b -> a -> m b) -> b -> f a -> m b
ifoldlM f z0 xs = ifoldr f' return xs z0
  where f' i x k z = f i z x >>= k
{-# INLINE ifoldlM #-}

-- | Extract the key-value pairs from a structure.
--
-- When you don't need access to the indices in the result, then 'Data.Foldable.toList' is more flexible in what it accepts.
--
-- @
-- 'Data.Foldable.toList' ≡ 'Data.List.map' 'fst' '.' 'itoList'
-- @
itoList :: FoldableWithIndex i f => f a -> [(i,a)]
itoList = ifoldr (\i c -> ((i,c):)) []
{-# INLINE itoList #-}

-------------------------------------------------------------------------------
-- TraversableWithIndex
-------------------------------------------------------------------------------

-- | A 'Traversable' with an additional index.
--
-- An instance must satisfy a (modified) form of the 'Traversable' laws:
--
-- @
-- 'itraverse' ('const' 'Identity') ≡ 'Identity'
-- 'fmap' ('itraverse' f) '.' 'itraverse' g ≡ 'Data.Functor.Compose.getCompose' '.' 'itraverse' (\\i -> 'Data.Functor.Compose.Compose' '.' 'fmap' (f i) '.' g i)
-- @
class (FunctorWithIndex i t, FoldableWithIndex i t, Traversable t) => TraversableWithIndex i t | t -> i where
  -- | Traverse an indexed container.
  itraverse :: Applicative f => (i -> a -> f b) -> t a -> f (t b)
#ifdef MPTC_DEFAULTS
  default itraverse :: Applicative f => (Int -> a -> f b) -> t a -> f (t b)
  itraverse = traversed .# Indexed
  {-# INLINE itraverse #-}
#endif

  -- | The 'IndexedTraversal' of a 'TraversableWithIndex' container.
  itraversed :: IndexedTraversal i (t a) (t b) a b
  itraversed = conjoined traverse (itraverse . indexed)
  {-# INLINE[0] itraversed #-}

#ifdef USE_RULES
{-# RULES
"itraversed/imapped"  itraversed = imapped :: FunctorWithIndex i f => IndexedLensLike i Mutator (f a) (f b) a b
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor Any) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor All) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor [r]) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Endo r)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Dual (Endo r))) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Last r)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (First r)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Sum Int)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Sum Integer)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Sum Double)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Sum Float)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Product Int)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Product Integer)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Product Double)) (f a) a
"itraversed/ifolded"  itraversed = ifolded :: FoldableWithIndex i f => IndexedLensLike' i (Accessor (Product Float)) (f a) a
"itraversed/traverse" itraversed = traverse #-}
#endif

-- | Traverse with an index (and the arguments flipped).
--
-- @
-- 'for' a ≡ 'ifor' a '.' 'const'
-- 'ifor' ≡ 'flip' 'itraverse'
-- @
ifor :: (TraversableWithIndex i t, Applicative f) => t a -> (i -> a -> f b) -> f (t b)
ifor = flip itraverse
{-# INLINE ifor #-}

-- | Map each element of a structure to a monadic action,
-- evaluate these actions from left to right, and collect the results, with access
-- the index.
--
-- When you don't need access to the index 'mapM' is more liberal in what it can accept.
--
-- @
-- 'mapM' ≡ 'imapM' '.' 'const'
-- @
imapM :: (TraversableWithIndex i t, Monad m) => (i -> a -> m b) -> t a -> m (t b)
imapM f = unwrapMonad #. itraverse (\i -> WrapMonad #. f i)
{-# INLINE imapM #-}

-- | Map each element of a structure to a monadic action,
-- evaluate these actions from left to right, and collect the results, with access
-- its position (and the arguments flipped).
--
-- @
-- 'forM' a ≡ 'iforM' a '.' 'const'
-- 'iforM' ≡ 'flip' 'imapM'
-- @
iforM :: (TraversableWithIndex i t, Monad m) => t a -> (i -> a -> m b) -> m (t b)
iforM = flip imapM
{-# INLINE iforM #-}

-- | Generalizes 'Data.Traversable.mapAccumR' to add access to the index.
--
-- 'imapAccumROf' accumulates state from right to left.
--
-- @
-- 'Control.Lens.Traversal.mapAccumR' ≡ 'imapAccumR' '.' 'const'
-- @
imapAccumR :: TraversableWithIndex i t => (i -> s -> a -> (s, b)) -> s -> t a -> (s, t b)
imapAccumR f s0 a = swap (Lazy.runState (forwards (itraverse (\i c -> Backwards (Lazy.state (\s -> swap (f i s c)))) a)) s0)
{-# INLINE imapAccumR #-}

-- | Generalizes 'Data.Traversable.mapAccumL' to add access to the index.
--
-- 'imapAccumLOf' accumulates state from left to right.
--
-- @
-- 'Control.Lens.Traversal.mapAccumLOf' ≡ 'imapAccumL' '.' 'const'
-- @
imapAccumL :: TraversableWithIndex i t => (i -> s -> a -> (s, b)) -> s -> t a -> (s, t b)
imapAccumL f s0 a = swap (Lazy.runState (itraverse (\i c -> Lazy.state (\s -> swap (f i s c))) a) s0)
{-# INLINE imapAccumL #-}

-------------------------------------------------------------------------------
-- Instances
-------------------------------------------------------------------------------

instance FunctorWithIndex i f => FunctorWithIndex i (Backwards f) where
  imap f  = Backwards . imap f . forwards
  {-# INLINE imap #-}

instance FoldableWithIndex i f => FoldableWithIndex i (Backwards f) where
  ifoldMap f = ifoldMap f . forwards
  {-# INLINE ifoldMap #-}

instance TraversableWithIndex i f => TraversableWithIndex i (Backwards f) where
  itraverse f = fmap Backwards . itraverse f . forwards
  {-# INLINE itraverse #-}

instance FunctorWithIndex i f => FunctorWithIndex i (Reverse f) where
  imap f = Reverse . imap f . getReverse
  {-# INLINE imap #-}

instance FoldableWithIndex i f => FoldableWithIndex i (Reverse f) where
  ifoldMap f = getDual . ifoldMap (\i -> Dual #. f i) . getReverse
  {-# INLINE ifoldMap #-}

instance TraversableWithIndex i f => TraversableWithIndex i (Reverse f) where
  itraverse f = fmap Reverse . forwards . itraverse (\i -> Backwards . f i) . getReverse
  {-# INLINE itraverse #-}

instance FunctorWithIndex () Identity where
  imap f (Identity a) = Identity (f () a)
  {-# INLINE imap #-}

instance FoldableWithIndex () Identity where
  ifoldMap f (Identity a) = f () a
  {-# INLINE ifoldMap #-}

instance TraversableWithIndex () Identity where
  itraverse f (Identity a) = Identity <$> f () a
  {-# INLINE itraverse #-}

instance FunctorWithIndex k ((,) k) where
  imap f (k,a) = (k, f k a)
  {-# INLINE imap #-}

instance FoldableWithIndex k ((,) k) where
  ifoldMap = uncurry
  {-# INLINE ifoldMap #-}

instance TraversableWithIndex k ((,) k) where
  itraverse f (k, a) = (,) k <$> f k a
  {-# INLINE itraverse #-}

-- | The position in the list is available as the index.
instance FunctorWithIndex Int [] where
  imap = iover itraversed
  {-# INLINE imap #-}
instance FoldableWithIndex Int [] where
  ifoldMap = ifoldMapOf itraversed
  {-# INLINE ifoldMap #-}
instance TraversableWithIndex Int [] where
  itraverse = itraverseOf traversed
  {-# INLINE itraverse #-}

-- | The position in the 'Seq' is available as the index.
instance FunctorWithIndex Int Seq where
  imap = iover itraversed
  {-# INLINE imap #-}
instance FoldableWithIndex Int Seq where
  ifoldMap = ifoldMapOf itraversed
  {-# INLINE ifoldMap #-}
instance TraversableWithIndex Int Seq where
  itraverse = itraverseOf traversed
  {-# INLINE itraverse #-}

instance FunctorWithIndex Int Vector where
  imap = V.imap
  {-# INLINE imap #-}
instance FoldableWithIndex Int Vector where
  ifoldMap = ifoldMapOf itraversed
  {-# INLINE ifoldMap #-}
  ifoldr = V.ifoldr
  {-# INLINE ifoldr #-}
  ifoldl = V.ifoldl . flip
  {-# INLINE ifoldl #-}
  ifoldr' = V.ifoldr'
  {-# INLINE ifoldr' #-}
  ifoldl' = V.ifoldl' . flip
  {-# INLINE ifoldl' #-}
instance TraversableWithIndex Int Vector where
  itraverse f = sequenceA . V.imap f
  {-# INLINE itraverse #-}

instance FunctorWithIndex Int IntMap where
  imap = iover itraversed
  {-# INLINE imap #-}
instance FoldableWithIndex Int IntMap where
  ifoldMap = ifoldMapOf itraversed
  {-# INLINE ifoldMap #-}
instance TraversableWithIndex Int IntMap where
#if MIN_VERSION_containers(0,5,0)
  itraverse = IntMap.traverseWithKey
#else
  itraverse f = sequenceA . IntMap.mapWithKey f
#endif
  {-# INLINE itraverse #-}

instance FunctorWithIndex k (Map k) where
  imap = iover itraversed
  {-# INLINE imap #-}
instance FoldableWithIndex k (Map k) where
  ifoldMap = ifoldMapOf itraversed
  {-# INLINE ifoldMap #-}
instance TraversableWithIndex k (Map k) where
#if MIN_VERSION_containers(0,5,0)
  itraverse = Map.traverseWithKey
#else
  itraverse f = sequenceA . Map.mapWithKey f
#endif
  {-# INLINE itraverse #-}

instance (Eq k, Hashable k) => FunctorWithIndex k (HashMap k) where
  imap = iover itraversed
  {-# INLINE imap #-}
instance (Eq k, Hashable k) => FoldableWithIndex k (HashMap k) where
  ifoldMap = ifoldMapOf itraversed
  {-# INLINE ifoldMap #-}
instance (Eq k, Hashable k) => TraversableWithIndex k (HashMap k) where
  itraverse = HashMap.traverseWithKey
  {-# INLINE itraverse #-}

instance FunctorWithIndex r ((->) r) where
  imap f g x = f x (g x)
  {-# INLINE imap #-}

instance FunctorWithIndex i (Level i) where
  imap f = go where
    go (Two n l r) = Two n (go l) (go r)
    go (One i a)   = One i (f i a)
    go Zero        = Zero
  {-# INLINE imap #-}

instance FoldableWithIndex i (Level i) where
  ifoldMap f = go where
    go (Two _ l r) = go l `mappend` go r
    go (One i a)   = f i a
    go Zero        = mempty
  {-# INLINE ifoldMap #-}

instance TraversableWithIndex i (Level i) where
  itraverse f = go where
    go (Two n l r) = Two n <$> go l <*> go r
    go (One i a)   = One i <$> f i a
    go Zero        = pure Zero
  {-# INLINE itraverse #-}

instance FunctorWithIndex i (Magma i t b) where
  imap f (MagmaAp x y)    = MagmaAp (imap f x) (imap f y)
  imap _ (MagmaPure x)    = MagmaPure x
  imap f (MagmaFmap xy x) = MagmaFmap xy (imap f x)
  imap f (Magma i a)      = Magma i (f i a)
  {-# INLINE imap #-}

instance FoldableWithIndex i (Magma i t b) where
  ifoldMap f (MagmaAp x y)   = ifoldMap f x `mappend` ifoldMap f y
  ifoldMap _ MagmaPure{}     = mempty
  ifoldMap f (MagmaFmap _ x) = ifoldMap f x
  ifoldMap f (Magma i a)     = f i a
  {-# INLINE ifoldMap #-}

instance TraversableWithIndex i (Magma i t b) where
  itraverse f (MagmaAp x y)    = MagmaAp <$> itraverse f x <*> itraverse f y
  itraverse _ (MagmaPure x)    = pure (MagmaPure x)
  itraverse f (MagmaFmap xy x) = MagmaFmap xy <$> itraverse f x
  itraverse f (Magma i a)      = Magma i <$> f i a
  {-# INLINE itraverse #-}

-------------------------------------------------------------------------------
-- Misc.
-------------------------------------------------------------------------------

skip :: a -> ()
skip _ = ()
{-# INLINE skip #-}

