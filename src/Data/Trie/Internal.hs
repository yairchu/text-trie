{-# OPTIONS_GHC -Wall -fwarn-tabs #-}

-- For list fusion on toListBy, and for applicative hiding
{-# LANGUAGE CPP #-}

----------------------------------------------------------------
--                                                  ~ 2009.01.20
-- |
-- Module      :  Data.Trie.Internal
-- Copyright   :  Copyright (c) 2008--2009 wren ng thornton
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Internal definition of the 'Trie' data type and generic functions
-- for manipulating them. Almost everything here is re-exported
-- from "Data.Trie", which is the preferred API for users. This
-- module is for developers who need deeper (and potentially fragile)
-- access to the abstract type.
----------------------------------------------------------------

module Data.Trie.Internal
    (
    -- * Data types
      Trie(), showTrie
    
    -- * Functions for 'ByteString's
    , breakMaximalPrefix
    
    -- * Basic functions
    , empty, null, singleton, size
    
    -- * Conversion and folding functions
    , foldrWithKey, toListBy
    
    -- * Query functions
    , lookupBy_, submap
    
    -- * Single-value modification
    , alterBy
    
    -- * Combining tries
    , mergeBy
    
    -- * Mapping functions
    , mapBy, filterMap
    ) where

import Prelude hiding (null, lookup)
import qualified Prelude

import qualified Data.ByteString as S
import Data.Trie.ByteStringInternal
import Data.Trie.BitTwiddle

import Data.Binary

import Data.Monoid         (Monoid(..))
import Control.Monad       (liftM3, liftM4)
#ifdef APPLICATIVE_IN_BASE
import Control.Monad       (ap)
import Control.Applicative (Applicative(..), (<$>))
import Data.Foldable       (Foldable(..))
import Data.Traversable    (Traversable(traverse))
#endif

#ifdef __GLASGOW_HASKELL__
import GHC.Exts (build)
#endif
----------------------------------------------------------------
----------------------------------------------------------------


{---------------------------------------------------------------
-- ByteString Big-endian Patricia Trie datatype
---------------------------------------------------------------}
{-
In our idealized representation, we use a (directed) discrete graph
to represent our finite state machine. To organize the set of
outgoing arcs from a given Node we have ArcSet be a big-endian
patricia tree like Data.IntMap. In order to simplify things we then
go through a series of derivations.

data Node a   = Accept a (ArcSet a)
              | Reject   (Branch a)          -- Invariant: Must be Branch
data Arc a    = Arc    ByteString (Node a)   -- Invariant: never empty string
data ArcSet a = None
              | One    {KeyElem} (Arc a)
              | Branch {Prefix} {Mask} (ArcSet a) (ArcSet a)
data Trie a   = Empty
              | Start  ByteString (Node a)   -- Maybe empty string [1]

[1] If we maintain the invariants on how Nodes recurse, then we
can't simply have Start(Node a) because we may have a shared prefix
where the prefix itself is not Accept'ed.


-- Squash Arc into One:
-- (pure good)
data Node a   = Accept a (ArcSet a)
              | Reject   (Branch a)
data ArcSet a = None
              | Arc    ByteString (Node a)
              | Branch {Prefix} {Mask} (ArcSet a) (ArcSet a)
data Trie a   = Empty
              | Start  ByteString (Node a)


-- Squash Node together:
-- (most likely good)
data Node a   = Node (Maybe a) (ArcSet a)
data ArcSet a = None
              | Arc    ByteString (Node a)
              | Branch {Prefix} {Mask} (ArcSet a) (ArcSet a)
data Trie a   = Empty
              | Start  ByteString (Node a)


-- Squash Empty/None and Arc/Start together:
-- (This complicates invariants about non-empty strings and Node's
-- recursion, but those can be circumvented by using smart
-- constructors.)
data Node a = Node (Maybe a) (ArcSet a)
data Trie a = Empty
            | Arc    ByteString (Node a)
            | Branch {Prefix} {Mask} (Trie a) (Trie a)


-- Squash Node into Arc:
-- (By this point, pure good)
-- Unseen invariants:
-- * ByteString non-empty, unless Arc is absolute root of tree
-- * If (Maybe a) is Nothing, then (Trie a) is Branch
--   * With views, we could re-expand Arc into accepting and
--     nonaccepting variants
--
-- [2] Maybe we shouldn't unpack the ByteString. We could specialize
-- or inline the breakMaximalPrefix function to prevent constructing
-- a new ByteString from the parts...
-}
-- | A map from 'ByteString's to @a@. For all the generic functions,
-- note that tries are strict in the @Maybe@ but not in @a@.
--
-- The 'Monad' instance is strange. If a key @k1@ is a prefix of
-- other keys, then results from binding the value at @k1@ will
-- override values from longer keys when they collide. If this is
-- useful for anything, or if there's a more sensible instance, I'd
-- be curious to know.

data Trie a = Empty
            | Arc    {-# UNPACK #-} !ByteString
                                    !(Maybe a)
                                    !(Trie a)
            | Branch {-# UNPACK #-} !Prefix
                     {-# UNPACK #-} !Mask
                                    !(Trie a)
                                    !(Trie a)
    deriving Eq
    -- Prefix/Mask should be deterministic regardless of insertion order
    -- TODO: prove this is so.


-- TODO? add Ord instance like Data.Map?

{---------------------------------------------------------------
-- Trie instances: serialization et cetera
---------------------------------------------------------------}

-- This instance does not unveil the innards of our abstract type.
-- It doesn't emit truly proper Haskell code though, since ByteStrings
-- are printed as (ASCII) Strings, but that's not our fault. (Also
-- 'fromList' is in "Data.Trie" instead of here.)
instance (Show a) => Show (Trie a) where
    showsPrec p t = showParen (p > 10)
                  $ ("Data.Trie.fromList "++) . shows (toListBy (,) t)


-- | Visualization fuction for debugging.
showTrie :: (Show a) => Trie a -> String
showTrie t = shows' id t ""
    where
    spaces f = map (const ' ') (f "")
    
    shows' _  Empty            = (".\n"++)
    shows' ss (Branch p m l r) =
        let s'  = ("--"++) . shows p . (","++) . shows m . ("-+"++)
            ss' = ss . (tail (spaces s') ++)
        in s'              . shows' (ss' . ("|"++)) l
           . ss' . ("|\n"++)
           . ss' . ("`"++) . shows' (ss' . (" "++)) r
    shows' ss (Arc k mv t') =
        let s' = ("--"++) . shows k
                 . maybe id (\v -> ("-("++) . shows v . (")"++)) mv
                 . ("--"++)
        in  s' . shows' (ss . (spaces s' ++)) t'


-- TODO?? a Read instance? hrm... should I?

instance (Binary a) => Binary (Trie a) where
    put Empty            = put (0 :: Word8)
    put (Arc k m t)      = do put (1 :: Word8)
                              put k
                              put m
                              put t
    put (Branch p m l r) = do put (2 :: Word8)
                              put p
                              put m
                              put l
                              put r
    
    get = do tag <- get :: Get Word8
             case tag of
                 0 -> return Empty
                 1 -> liftM3 Arc get get get
                 _ -> liftM4 Branch get get get get


{---------------------------------------------------------------
-- Trie instances: Abstract Nonsense
---------------------------------------------------------------}

instance Functor Trie where
    fmap _ Empty              = Empty
    fmap f (Arc k Nothing  t) = Arc k Nothing      (fmap f t)
    fmap f (Arc k (Just v) t) = Arc k (Just (f v)) (fmap f t)
    fmap f (Branch p m l r)   = Branch p m (fmap f l) (fmap f r)


#ifdef APPLICATIVE_IN_BASE
instance Foldable Trie where
    foldMap _ Empty              = mempty
    foldMap f (Arc _ Nothing  t) = foldMap f t
    foldMap f (Arc _ (Just v) t) = f v `mappend` foldMap f t
    foldMap f (Branch _ _ l r)   = foldMap f l `mappend` foldMap f r
    
    -- BUG: are these right, or reversed? (Are we traversing
    -- rightward, or associating to the right?) These're the same
    -- as the default implementation from 'foldMap', so if they're
    -- wrong, so is foldMap.
    
    foldr f = \z t -> go t id z
        where
        go Empty              k x = k x
        go (Branch _ _ l r)   k x = go r (go l k) x
        go (Arc _ Nothing t)  k x = go t k x
        go (Arc _ (Just v) t) k x = go t k (f v x)
    
    foldl f = \z t -> go t id z
        where
        go Empty              k x = k x
        go (Branch _ _ l r)   k x = go l (go r k) x
        go (Arc _ Nothing t)  k x = go t k x
        go (Arc _ (Just v) t) k x = go t k (f x v)

-- TODO: newtype Keys = K Trie ; instance Foldable Keys

instance Traversable Trie where
    traverse _ Empty              = pure Empty
    traverse f (Arc k Nothing  t) = Arc k Nothing        <$> traverse f t
    traverse f (Arc k (Just v) t) = Arc k . Just <$> f v <*> traverse f t
    traverse f (Branch p m l r)   = Branch p m <$> traverse f l <*> traverse f r

instance Applicative Trie where
    pure  = return
    (<*>) = ap
#endif

-- Does this even make sense? It's not nondeterminism like lists
-- and sets. If no keys were prefixes of other keys it'd make sense
-- as a decision-tree; but since keys /can/ prefix, tries formed
-- from shorter keys can shadow the results from longer keys due
-- to the 'unionL'. It does seem to follow the laws though... What
-- computation could this possibly represent?
--
--  1. return x >>= f  == f x
--  2. m >>= return    == m
--  3. (m >>= f) >>= g == m >>= (\x -> f x >>= g)
instance Monad Trie where
    return x = singleton S.empty x
    
    (>>=) Empty              _ = empty
    (>>=) (Branch p m l r)   f = branch p m (l >>= f) (r >>= f)
    (>>=) (Arc k Nothing  t) f = arc k Nothing (t >>= f)
    (>>=) (Arc k (Just v) t) f = arc k Nothing (f v `unionL` (t >>= f))
                               where
                               unionL = mergeBy (\x _ -> Just x)


-- This instance is more sensible than Data.IntMap and Data.Map's
instance (Monoid a) => Monoid (Trie a) where
    mempty  = empty
    mappend = mergeBy $ \x y -> Just (x `mappend` y)


-- Since the Monoid instance isn't natural in @a@, I can't think
-- of any other sensible instance for MonadPlus. It's as specious
-- as Maybe, IO, and STM's instances though.
--
-- MonadPlus laws: <http://www.haskell.org/haskellwiki/MonadPlus>
--  1. <Trie a, mzero, mplus> forms a monoid
--  2. mzero >>= f        === mzero
--  3. m >> mzero         === mzero
--  4. mplus m n >>= k    === mplus (m >>= k) (n >>= k)
--  4' mplus (return a) n === return a
{-
-- Follows #1, #1, and #3. But it does something like 4' instead
-- of actually doing #4 (since we'd merge the trees generated by
-- @k@ for conflicting values)
--
-- TODO: cf Control.Applicative.Alternative (base-4, but not Hugs).
-- But (<*>) gets odd when the function is not 'pure'... maybe
-- helpful though.
instance MonadPlus Trie where
    mzero = empty
    mplus = unionL where unionL = mergeBy (\x _ -> Just x)
-}


{---------------------------------------------------------------
-- Extra mapping functions
---------------------------------------------------------------}

-- | Apply a function to all values, potentially removing them.
filterMap :: (a -> Maybe b) -> Trie a -> Trie b
filterMap _ Empty              = empty
filterMap f (Arc k Nothing  t) = arc k Nothing (filterMap f t)
filterMap f (Arc k (Just v) t) = arc k (f v)   (filterMap f t)
filterMap f (Branch p m l r)   = branch p m (filterMap f l) (filterMap f r)

-- | Generic version of 'fmap'. This function is notably more
-- expensive than 'fmap' or 'filterMap' because we have to reconstruct
-- the keys.
mapBy :: (ByteString -> a -> Maybe b) -> Trie a -> Trie b
mapBy f = go S.empty
    where
    go _ Empty              = empty
    go q (Arc k Nothing  t) = arc k Nothing  (go q' t) where q' = S.append q k
    go q (Arc k (Just v) t) = arc k (f q' v) (go q' t) where q' = S.append q k
    go q (Branch p m l r)   = branch p m (go q l) (go q r)


{---------------------------------------------------------------
-- Smart constructors and helper functions for building tries
---------------------------------------------------------------}

-- | Smart constructor to prune @Empty@ from @Branch@es.
branch :: Prefix -> Mask -> Trie a -> Trie a -> Trie a
branch _ _ Empty r     = r
branch _ _ l     Empty = l
branch p m l     r     = Branch p m l r


-- | Smart constructor to prune @Arc@s that lead nowhere.
-- N.B if mv=Just then doesn't check whether t=epsilon. It's up to callers to ensure that invariant isn't broken.
arc :: ByteString -> Maybe a -> Trie a -> Trie a
arc k mv@(Just _)   t                            = Arc k mv t
arc _    Nothing    Empty                        = Empty
arc k    Nothing  t@(Branch _ _ _ _) | S.null k  = t
                                     | otherwise = Arc k Nothing t
arc k    Nothing    (Arc k' mv' t')              = Arc (S.append k k') mv' t'


-- | Smart constructor to join two tries into a @Branch@ with maximal
-- prefix sharing. Requires knowing the prefixes, but can combine
-- either @Branch@es or @Arc@s.
--
-- N.B. /do not/ use if prefixes could match entirely!
branchMerge :: Prefix -> Trie a -> Prefix -> Trie a -> Trie a
branchMerge _ Empty _ t2    = t2
branchMerge _  t1   _ Empty = t1
branchMerge p1 t1  p2 t2
    | zero p1 m             = Branch p m t1 t2
    | otherwise             = Branch p m t2 t1
    where
    m = branchMask p1 p2
    p = mask p1 m


-- It would be better if Arc used
-- Data.ByteString.TrieInternal.wordHead somehow, that way
-- we can see 4/8/?*Word8 at a time instead of just one.
-- But that makes maintaining invariants ...difficult :(
getPrefix :: Trie a -> Prefix
getPrefix (Branch p _ _ _)        = p
getPrefix (Arc k _ _) | S.null k  = 0 -- for lack of a better value
                      | otherwise = S.head k
getPrefix Empty                   = error "getPrefix: no Prefix of Empty"


{---------------------------------------------------------------
-- Error messages
---------------------------------------------------------------}

errorLogHead :: String -> ByteString -> ByteStringElem
{-# NOINLINE errorLogHead #-}
errorLogHead s q | S.null q  = error (s ++": found null subquery")
                 | otherwise = S.head q


----------------------------------------------------------------
----------------------------------------------------------------

{---------------------------------------------------------------
-- Basic functions
---------------------------------------------------------------}

-- | /O(1)/, Construct the empty trie.
empty :: Trie a
{-# INLINE empty #-}
empty = Empty

-- | /O(1)/, Is the trie empty?
null :: Trie a -> Bool
{-# INLINE null #-}
null Empty = True
null _     = False

-- | /O(1)/, Construct a singleton trie.
singleton :: ByteString -> a -> Trie a
{-# INLINE singleton #-}
singleton k v = Arc k (Just v) Empty
-- For singletons, don't need to verify invariant on arc length >0

-- | /O(n)/, Get count of elements in trie.
size  :: Trie a -> Int
{-# INLINE size #-}
size t = size' t id 0

-- | /O(n)/, Internal CPS accumulator function for calculating
-- 'size'.
size' :: Trie a -> (Int -> Int) -> Int -> Int
size' Empty              f n = f n
size' (Branch _ _ l r)   f n = size' l (size' r f) n
size' (Arc _ Nothing t)  f n = size' t f n
size' (Arc _ (Just _) t) f n = size' t f $! n + 1


{---------------------------------------------------------------
-- Conversion functions 
---------------------------------------------------------------}

-- Still rather inefficient
-- 
-- TODO: rewrite list-catenation to be lazier (real CPS instead of
-- function building? is the function building really better than
-- (++) anyways?)
--
-- TODO: the @q@ accumulator should be lazy ByteString and only
-- forced by @fcons@. It's already non-strict, but we should ensure
-- O(n) not O(n^2) when it's forced.
--
-- BUG: not safe for deep strict @fcons@, only for WHNF-strict like (:)
-- Where to put the strictness to amortize it?
--
-- | Convert a trie into a list (in key-sorted order) using a
-- function, folding the list as we go.
foldrWithKey :: (ByteString -> a -> b -> b) -> b -> Trie a -> b
foldrWithKey fcons nil = \t -> go S.empty t nil
    where
    go _ Empty            = id
    go q (Branch _ _ l r) = go q l . go q r
    go q (Arc k mv t)     = case mv of
                            Nothing -> rest
                            Just v  -> (fcons k' v) . rest
                          where
                          rest = go k' t
                          k'   = S.append q k

-- cf Data.ByteString.unpack
-- <http://hackage.haskell.org/packages/archive/bytestring/0.9.1.4/doc/html/src/Data-ByteString.html>
--
-- | Convert a trie into a list using a function. Resulting values
-- are in key-sorted order.
toListBy :: (ByteString -> a -> b) -> Trie a -> [b]

#if !defined(__GLASGOW_HASKELL__)
-- TODO: should probably inline foldrWithKey
-- TODO: compare performance of that vs both this and the GHC version
{-# INLINE toListBy #-}
toListBy f t = foldrWithKey (((:) .) . f) [] t

#else

{-# INLINE toListBy #-}
-- Written with 'build' to enable the build\/foldr fusion rules.
toListBy f t = build (toListByFB f t)

-- TODO: should probably have a specialized version for strictness,
-- and a rule to rewrite generic lazy version into it. As per
-- Data.ByteString.unpack and the comments there about strictness
-- and fusion.
toListByFB :: (ByteString -> a -> b) -> Trie a -> (b -> c -> c) -> c -> c
{-# INLINE [0] toListByFB #-}
toListByFB f t cons nil = foldrWithKey ((cons .) . f) nil t

#endif


{---------------------------------------------------------------
-- Query functions (just recurse)
---------------------------------------------------------------}

-- | Generic function to find a value (if it exists) and the subtrie
-- rooted at the prefix. The first function argument is called if and
-- only if a node is exactly reachable by the query; if no node is
-- exactly reachable the default value is used; if the middle of
-- an arc is reached, the second function argument is used.
--
-- This function is intended for internal use. For the public-facing
-- version, see @lookupBy@ in "Data.Trie".
lookupBy_ :: (Maybe a -> Trie a -> b) -> b -> (Trie a -> b)
          -> ByteString -> Trie a -> b
lookupBy_ f z a = lookupBy_'
    where
    -- | Deal with epsilon query (when there is no epsilon value)
    lookupBy_' q t@(Branch _ _ _ _) | S.null q = f Nothing t
    lookupBy_' q t                             = go q t
    
    -- | The main recursion
    go _    Empty       = z
    
    go q   (Arc k mv t) =
        let (_,k',q')   = breakMaximalPrefix k q
        in case (not $ S.null k', S.null q') of
                (True,  True)  -> a (Arc k' mv t)
                (True,  False) -> z
                (False, True)  -> f mv t
                (False, False) -> go q' t
        
    go q t_@(Branch _ _ _ _) = findArc t_
        where
        qh = errorLogHead "lookupBy_" q
        
        -- | /O(min(m,W))/, where /m/ is number of @Arc@s in this
        -- branching, and /W/ is the word size of the Prefix,Mask type.
        findArc (Branch p m l r)
            | nomatch qh p m  = z
            | zero qh m       = findArc l
            | otherwise       = findArc r
        findArc t@(Arc _ _ _) = go q t
        findArc Empty         = z


-- This function needs to be here, not in "Data.Trie", because of
-- 'arc' which isn't exported. We could use the monad instance
-- instead, though it'd be far more circuitous.
--     arc k Nothing  t === singleton k () >> t
--     arc k (Just v) t === singleton k v  >>= unionR t . singleton S.empty
--         (...except 'arc' doesn't do the invariant correction
--           of (>>=) for epsilon`elem`t)
--
-- | Return the subtrie containing all keys beginning with a prefix.
submap :: ByteString -> Trie a -> Trie a
{-# INLINE submap #-}
submap q = lookupBy_ (arc q) empty (arc q Nothing) q
{-  -- Disable superfluous error checking.
    -- @submap'@ would replace the first argument to @lookupBy_@
    where
    submap' Nothing Empty       = errorEmptyAfterNothing "submap"
    submap' Nothing (Arc _ _ _) = errorArcAfterNothing   "submap"
    submap' mx      t           = Arc q mx t
    
errorInvariantBroken :: String -> String -> a
{-# NOINLINE errorInvariantBroken #-}
errorInvariantBroken s e =  error (s ++ ": Invariant was broken" ++ e')
    where
    e' = if Prelude.null e then e else ", found: " ++ e

errorArcAfterNothing    :: String -> a
{-# NOINLINE errorArcAfterNothing #-}
errorArcAfterNothing   s = errorInvariantBroken s "Arc after Nothing"

errorEmptyAfterNothing  :: String -> a
{-# NOINLINE errorEmptyAfterNothing #-}
errorEmptyAfterNothing s = errorInvariantBroken s "Empty after Nothing"
-- -}


{---------------------------------------------------------------
-- Single-value modification functions (recurse and clone spine)
---------------------------------------------------------------}

-- TODO: We should CPS on Empty to avoid cloning spine if no change.
-- Difficulties arise with the calls to 'branch' and 'arc'. Will
-- have to create a continuation chain, so no savings on memory
-- allocation; but would have savings on held memory, if they're
-- still holding the old one...
--
-- | Generic function to alter a trie by one element with a function
-- to resolve conflicts (or non-conflicts).
alterBy :: (ByteString -> a -> Maybe a -> Maybe a)
         -> ByteString -> a -> Trie a -> Trie a
alterBy f_ q_ x_
    | S.null q_ = alterEpsilon
    | otherwise = go q_
    where
    f         = f_ q_ x_
    nothing q = arc q (f Nothing) Empty
    
    alterEpsilon t_@Empty                    = arc q_ (f Nothing) t_
    alterEpsilon t_@(Branch _ _ _ _)         = arc q_ (f Nothing) t_
    alterEpsilon t_@(Arc k mv t) | S.null k  = arc q_ (f mv)      t
                                 | otherwise = arc q_ (f Nothing) t_
    
    
    go q Empty            = nothing q
    
    go q t@(Branch p m l r)
        | nomatch qh p m  = branchMerge p t  qh (nothing q)
        | zero qh m       = branch p m (go q l) r
        | otherwise       = branch p m l (go q r)
        where
        qh = errorLogHead "alterBy" q
    
    go q t_@(Arc k mv t) =
        let (p,k',q') = breakMaximalPrefix k q
        in case (not $ S.null k', S.null q') of
                (True,  True)  -> -- add node to middle of arc
                                  arc p (f Nothing) (Arc k' mv t)
                (True,  False) ->
                           case nothing q' of
                           Empty -> t_ -- Nothing to add, reuse old arc
                           l     -> arc' (branchMerge (getPrefix l) l
                                                      (getPrefix r) r)
                                    where
                                    r = Arc k' mv t
                                    
                                    -- inlined version of 'arc'
                                    arc' | S.null p  = id
                                         | otherwise = Arc p Nothing
                                    
                (False, True)  -> arc k (f mv) t
                (False, False) -> arc k mv (go q' t)


{---------------------------------------------------------------
-- Trie-combining functions
---------------------------------------------------------------}

-- TEST CASES: foldr (unionL . uncurry singleton) empty t
--             foldr (uncurry insert) empty t
--    where t = map (\s -> (pk s, 0))
--                  ["heat","hello","hoi","apple","appa","hell","appb","appc"]
--
-- | Combine two tries, using a function to resolve collisions.
-- This can only define the space of functions between union and
-- symmetric difference but, with those two, all set operations can
-- be defined (albeit inefficiently).
mergeBy :: (a -> a -> Maybe a) -> Trie a -> Trie a -> Trie a
mergeBy f = mergeBy'
    where
    -- | Deals with epsilon entries, before recursing into @go@
    mergeBy'
        t0_@(Arc k0 mv0 t0)
        t1_@(Arc k1 mv1 t1)
        | S.null k0 && S.null k1 = arc k0 (mergeMaybe f mv0 mv1) (go t0 t1)
        | S.null k0              = arc k0 mv0 (go t0 t1_)
        |              S.null k1 = arc k1 mv1 (go t1 t0_)
    mergeBy'
        (Arc k0 mv0@(Just _) t0)
        t1_@(Branch _ _ _ _)
        | S.null k0              = arc k0 mv0 (go t0 t1_)
    mergeBy'
        t0_@(Branch _ _ _ _)
        (Arc k1 mv1@(Just _) t1)
        | S.null k1              = arc k1 mv1 (go t1 t0_)
    mergeBy' t0_ t1_             = go t0_ t1_
    
    
    -- | The main recursion
    go Empty t1    = t1
    go t0    Empty = t0
    
    -- /O(n+m)/ for this part where /n/ and /m/ are sizes of the branchings
    go  t0@(Branch p0 m0 l0 r0)
        t1@(Branch p1 m1 l1 r1)
        | shorter m0 m1  = union0
        | shorter m1 m0  = union1
        | p0 == p1       = branch p0 m0 (go l0 l1) (go r0 r1)
        | otherwise      = branchMerge p0 t0 p1 t1
        where
        union0  | nomatch p1 p0 m0  = branchMerge p0 t0 p1 t1
                | zero p1 m0        = branch p0 m0 (go l0 t1) r0
                | otherwise         = branch p0 m0 l0 (go r0 t1)
        
        union1  | nomatch p0 p1 m1  = branchMerge p0 t0 p1 t1
                | zero p0 m1        = branch p1 m1 (go t0 l1) r1
                | otherwise         = branch p1 m1 l1 (go t0 r1)
    
    go t0_ t1_ = go' t0_ t1_
        where
        p0 = getPrefix t0_
        p1 = getPrefix t1_
        m' = branchMask p0 p1
        p' = mask p0 m'
        
        go' (Arc k0 mv0 t0)
            (Arc k1 mv1 t1)
            | m' == 0 =
                let (pre,k0',k1') = breakMaximalPrefix k0 k1
                in if S.null pre
                then error "mergeBy: no mask, but no prefix string"
                else let {-# INLINE arcMerge #-}
                         arcMerge mv' t1' t2' = arc pre mv' (go t1' t2')
                     in case (S.null k0', S.null k1') of
                         (True, True)  -> arcMerge (mergeMaybe f mv0 mv1) t0 t1
                         (True, False) -> arcMerge mv0 t0 (Arc k1' mv1 t1)
                         (False,True)  -> arcMerge mv1 t1 (Arc k0' mv0 t0)
                         (False,False) -> arcMerge Nothing (Arc k0' mv0 t0)
                                                           (Arc k1' mv1 t1)
        go' (Arc _ _ _)
            (Branch _p1 m1 l r)
            | nomatch p0 p1 m1 = branchMerge p1 t1_  p0 t0_
            | zero p0 m1       = branch p1 m1 (go t0_ l) r
            | otherwise        = branch p1 m1 l (go t0_ r)
        go' (Branch _p0 m0 l r)
            (Arc _ _ _)
            | nomatch p1 p0 m0 = branchMerge p0 t0_  p1 t1_
            | zero p1 m0       = branch p0 m0 (go t1_ l) r
            | otherwise        = branch p0 m0 l (go t1_ r)
        
        -- Inlined branchMerge. Both tries are disjoint @Arc@s now.
        go' _ _ | zero p0 m'   = Branch p' m' t0_ t1_
        go' _ _                = Branch p' m' t1_ t0_

mergeMaybe :: (a -> a -> Maybe a) -> Maybe a -> Maybe a -> Maybe a
{-# INLINE mergeMaybe #-}
mergeMaybe _ Nothing      Nothing  = Nothing
mergeMaybe _ Nothing mv1@(Just _)  = mv1
mergeMaybe _ mv0@(Just _) Nothing  = mv0
mergeMaybe f (Just v0)   (Just v1) = f v0 v1

----------------------------------------------------------------
----------------------------------------------------------- fin.
