
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveDataTypeable #-}

-- | This program compares two Infernal covariance models with each other.
-- Based on the Infernal CM scoring mechanism, a Link sequence and Link score
-- are calculated. The Link sequence is defined as the sequence scoring highest
-- in both models simultanuously.
--
-- The complete algorithm is described in:
--
-- "Christian Höner zu Siederdissen, and Ivo L. Hofacker. 2010. Discriminatory
-- power of RNA family models. Bioinformatics 26, no. 18: 453–59."
--
-- <http://bioinformatics.oxfordjournals.org/content/26/18/i453.long>
--
--
--
-- NOTE always use coverage analysis to find out, if we really used all code
-- paths (in long models, if a path is not taken, there is a bug)

-- NOTE when comparing hits with cmsearch, use the following commandline:
--
-- cmsearch --no-null3 --cyk --fil-no-hmm --fil-no-qdb
--
-- --no-null3 : important, the test sequence is so short that null3 can easily
-- generate scores that are way off! remember, we are interested in a sequence
-- that is typically embedded in something large
--
-- --fil-no-hmm, --fil-no-qdb: do not use heuristics for speedup, they
-- sometimes hide results (in at least one case)
--
-- (--toponly): if the comparison was done onesided
--
-- (-g): if you want to compare globally

module BioInf.CMCompare where

import Control.Arrow (first,second,(***))
import Control.Lens
import Control.Monad
import Data.Array.IArray
import Data.List (maximumBy,nub,sort)
import qualified Data.Map as M
import System.Console.CmdArgs
import System.Environment (getArgs)
import Text.Printf

import Biobase.Primary
import Biobase.SElab.CM
import Biobase.SElab.CM.Import
import Biobase.SElab.Types



-- * optimization functions

-- | Type of the optimization functions.

type Opt a =
  ( CM -> StateID -> a  -- E
  , CM -> StateID -> BitScore -> a -> a -- lbegin
  , CM -> StateID -> BitScore -> a -> a -- S
  , CM -> StateID -> BitScore -> a -> a -- D
  , CM -> StateID -> BitScore -> (Char,Char,BitScore) -> a -> a -- MP
  , CM -> StateID -> BitScore -> (Char,BitScore) -> a -> a -- ML
  , CM -> StateID -> BitScore -> (Char,BitScore) -> a -> a -- IL
  , CM -> StateID -> BitScore -> (Char,BitScore) -> a -> a -- MR
  , CM -> StateID -> BitScore -> (Char,BitScore) -> a -> a -- IR
  , CM -> StateID -> a -> a -> a  -- B
  , [(a,a)] -> [(a,a)]  -- optimization
  , a -> String -- finalize, make pretty for output
  )

-- | Calculates the cyk optimal score over both models.

cykMaxiMin :: Opt BitScore
cykMaxiMin = (end,lbegin,start,delete,matchP,matchL,insertL,matchR,insertR,branch,opt,finalize) where
  end     _ _     = 0
  lbegin  _ _ t s = t + s
  start   _ _ t s = t + s
  delete  _ _ t s = t + s
  matchP  _ _ t (_,_,e) s = t + e + s
  matchL  _ _ t (_,e)   s = t + e + s
  insertL _ _ t (_,e)   s = t + e + s
  matchR  _ _ t (_,e)   s = t + e + s
  insertR _ _ t (_,e)   s = t + e + s
  branch  _ _ s t = s + t
  opt [] = []
  opt xs = [maximumBy (\(a,b) (c,d) -> (min a b) `compare` (min c d)) xs] -- (xs `using` parList rdeepseq)]
  finalize s = show s

-- | Return the nucleotide sequence leading to the score. uses an optional
-- endmarker to denote end states. the string is the same for both models. this
-- is the only Opt function, currently, for which this is true.

rnaString :: Bool -> Opt [Char]
rnaString endmarker = (end,lbegin,start,delete,matchP,matchL,insertL,matchR,insertR,branch,opt,finalize) where
  end     _ _     = ['N' | endmarker]
  lbegin  _ _ _ s = s
  start   _ _ _ s = s
  delete  _ _ _ s = s
  matchP  _ _ _ (k1,k2,_) s = [k1] ++ s ++ [k2]
  matchL  _ _ _ (k,_)   s = k : s
  insertL _ _ _ (k,_)   s = k : s
  matchR  _ _ _ (k,_)   s = s ++ [k]
  insertR _ _ _ (k,_)   s = s ++ [k]
  branch  _ _ s t = s ++ t
  opt = id
  finalize s = if endmarker
                 then concatMap f s
                 else concatMap show s
  f x
    | x=='N' = "_"
    | otherwise   = show x

-- | Dotbracket notation, again with an endmarker, to see the secondary
-- structure corresponding to the rnastring.

dotBracket :: Bool -> Opt String
dotBracket endmarker = (end,lbegin,start,delete,matchP,matchL,insertL,matchR,insertR,branch,opt,finalize) where
  end     _ _     = ['_' | endmarker]
  lbegin  _ _ _ s = s
  start   _ _ _ s = s
  delete  _ _ _ s = s
  matchP  _ _ _ _ s = "(" ++ s ++ ")"
  matchL  _ _ _ _ s = '.' : s
  insertL _ _ _ _ s = ',' : s
  matchR  _ _ _ _ s = s ++ "."
  insertR _ _ _ _ s = s ++ ","
  branch  _ _ s t = s ++ t
  opt = id
  finalize s = s

-- | Show the nodes which were visited to get the score. the last node can
-- occur multiple times. if it does, local end transitions were used.

visitedNodes :: Opt [NodeID]
visitedNodes = (end,lbegin,start,delete,matchP,matchL,insertL,matchR,insertR,branch,opt,finalize) where
  end     cm k       = [((cm^.states) M.! k) ^. nodeID]
  lbegin  cm k _   s = s
  start   cm k _   s = ((cm^.states) M.! k) ^. nodeID : s
  delete  cm k _   s = ((cm^.states) M.! k) ^. nodeID : s
  matchP  cm k _ _ s = ((cm^.states) M.! k) ^. nodeID : s
  matchL  cm k _ _ s = ((cm^.states) M.! k) ^. nodeID : s
  insertL cm k _ _ s = ((cm^.states) M.! k) ^. nodeID : s
  matchR  cm k _ _ s = ((cm^.states) M.! k) ^. nodeID : s
  insertR cm k _ _ s = ((cm^.states) M.! k) ^. nodeID : s
  branch  cm k   s t = ((cm^.states) M.! k) ^. nodeID : (s ++ t)
  opt = id -- NOTE do not sort, do not nub !
  finalize xs = (show $ map unNodeID xs) -- NOTE do not sort, do not nub !

-- | Detailed output of the different states, that were visited.

extendedOutput :: Opt String
extendedOutput = (end,lbegin,start,delete,matchP,matchL,insertL,matchR,insertR,branch,opt,finalize) where
  end      cm sid               = printf "E      %5d %5d"                             (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) 
  lbegin   cm sid t           s = printf "lbegin %5d %5d   %7.3f \n%s"                (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t)                       s
  start    cm sid t           s = printf "S      %5d %5d   %7.3f \n%s"                (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t)                       s
  delete   cm sid t           s = printf "D      %5d %5d   %7.3f \n%s"                (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t)                       s
  matchP   cm sid t (k1,k2,e) s = printf "MP     %5d %5d   %7.3f   %7.3f %1s %1s\n%s" (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t) (unBitScore e) (show k1) (show k2) s
  matchL   cm sid t (k,e)     s = printf "ML     %5d %5d   %7.3f   %7.3f %1s\n%s"     (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t) (unBitScore e) (show k)            s
  insertL  cm sid t (k,e)     s = printf "IL     %5d %5d   %7.3f   %7.3f %1s\n%s"     (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t) (unBitScore e) (show k)            s
  matchR   cm sid t (k,e)     s = printf "MR     %5d %5d   %7.3f   %7.3f   %1s\n%s"   (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t) (unBitScore e) (show k)            s
  insertR  cm sid t (k,e)     s = printf "IR     %5d %5d   %7.3f   %7.3f   %1s\n%s"   (unStateID sid) (unNodeID $ ((cm^.states) M.! sid)^.nodeID) (unBitScore t) (unBitScore e) (show k)            s
  branch   cm sid   s t = printf "B      %5d %5d\n%s\n%s" (unStateID sid) (unNodeID $ ((cm^.states) M.! sid) ^. nodeID) s t
  opt                   = id
  finalize            s = "\nLabel State  Node     Trans     Emis\n\n" ++ s

-- | Algebra product operation.

(<*>) :: Eq a => Opt a -> Opt b -> Opt (a,b)
algA <*> algB = (end,lbegin,start,delete,matchP,matchL,insertL,matchR,insertR,branch,opt,finalize) where
  (endA,lbeginA,startA,deleteA,matchPA,matchLA,insertLA,matchRA,insertRA,branchA,optA,finalizeA) = algA
  (endB,lbeginB,startB,deleteB,matchPB,matchLB,insertLB,matchRB,insertRB,branchB,optB,finalizeB) = algB
  end     cm k             = (endA cm k, endB cm k)
  lbegin  cm k t   (sA,sB) = (lbeginA cm k t sA, lbeginB cm k t sB)
  start   cm k t   (sA,sB) = (startA cm k t sA, startB cm k t sB)
  delete  cm k t   (sA,sB) = (deleteA cm k t sA, deleteB cm k t sB)
  matchP  cm k t e (sA,sB) = (matchPA cm k t e sA, matchPB cm k t e sB)
  matchL  cm k t e (sA,sB) = (matchLA cm k t e sA, matchLB cm k t e sB)
  insertL cm k t e (sA,sB) = (insertLA cm k t e sA, insertLB cm k t e sB)
  matchR  cm k t e (sA,sB) = (matchRA cm k t e sA, matchRB cm k t e sB)
  insertR cm k t e (sA,sB) = (insertRA cm k t e sA, insertRB cm k t e sB)
  branch  cm k (sA,sB) (tA,tB) = (branchA cm k sA tA, branchB cm k sB tB)
  opt xs = [((xl1,xl2),(xr1,xr2)) | (xl1,xr1) <- nub $ optA [(yl1,yr1) | ((yl1,yl2),(yr1,yr2)) <- xs]
                                  , (xl2,xr2) <-       optB [(yl2,yr2) | ((yl1,yl2),(yr1,yr2)) <- xs, (yl1,yr1) == (xl1,xr1)]
           ]
  finalize (sA,sB) = finalizeA sA ++ "\n" ++ finalizeB sB



-- * The grammar for CM comparison.

-- | Recursion in two CMs simultanously.

recurse :: Bool -> Opt a -> CM -> CM -> Array (StateID,StateID) [(a,a)]
recurse fastIns (end,lbegin,start,delete,matchP,matchL,insertL,matchR,insertR,branch,opt,finalize) m1 m2 = locarr where

  loc k1 k2
    | otherwise = opt $ do
        r <- arr ! (k1, k2)
        return $ (lbegin m1 k1 lb1 *** lbegin m2 k2 lb2) r
    where
      lb1 = M.findWithDefault (BitScore (-10000)) k1 (m1^.localBegin)
      lb2 = M.findWithDefault (BitScore (-10000)) k2 (m2^.localBegin)

  rec k1 k2 = let xyz = rec' k1 k2
              in  xyz -- traceShow ("rec",k1,((m1^.states) M.! k1) ^. stateType,k2,((m2^.states) M.! k2) ^. stateType) xyz
  rec' k1 k2
    --
    | t1 == E && t2 == E = [(end m1 k1, end m2 k2)]
    --
    | t1 == S && t2 == S = opt $ do
        (c1,tr1) <- s1 ^. transitions ++ [(ls1,le1)]
        (c2,tr2) <- s2 ^. transitions ++ [(ls2,le2)]
        r <- arr ! (c1, c2)
        return $ (start m1 k1 tr1 *** start m2 k2 tr2) r
    | t1 == D && t2 == D = opt $ do
        (c1,tr1) <- s1 ^. transitions ++ [(ls1,le1)]
        (c2,tr2) <- s2 ^. transitions ++ [(ls2,le2)]
        r <- arr ! (c1, c2)
        return $ (delete m1 k1 tr1 *** delete m2 k2 tr2) r
    -- match pair emitting states
    | t1 == MP && t2 == MP
    =   opt $ do
        (c1,tr1) <- s1 ^. transitions ++ [(ls1,le1)]
        (c2,tr2) <- s2 ^. transitions ++ [(ls2,le2)]
        (e1,e2) <- zip (s1 ^. emits ^. pair) (s2 ^. emits ^. pair)
        r <- arr ! (c1, c2)
        return $ (matchP m1 k1 tr1 e1 *** matchP m2 k2 tr2 e2) r
    -- match left emitting states
    | t1 `elem` lstates && t2 `elem` lstates
    =   opt $ do
        (c1,tr1) <- s1 ^. transitions ++ [(ls1,le1)]
        (c2,tr2) <- s2 ^. transitions ++ [(ls2,le2)]
        guard $ (not fastIns && (c1 /= k1 || c2 /= k2)) || (fastIns && c1/=k1 && c2/=k2)
        (e1,e2) <- zip (s1 ^. emits ^. single) (s2 ^. emits ^. single)
        r <- arr ! (c1, c2)
        let f = if t1 == ML then matchL else insertL
        let g = if t2 == ML then matchL else insertL
        return $ (f m1 k1 tr1 e1 *** g m2 k2 tr2 e2) r
    -- match right emitting states
    | t1 `elem` rstates && t2 `elem` rstates
    =   opt $ do
        (c1,tr1) <- s1 ^. transitions ++ [(ls1,le1)]
        (c2,tr2) <- s2 ^. transitions ++ [(ls2,le2)]
        guard $ (not fastIns && (c1 /= k1 || c2 /= k2)) || (fastIns && c1/=k1 && c2/=k2)
        (e1,e2) <- zip (s1 ^. emits ^. single) (s2 ^. emits ^. single)
        r <- arr ! (c1, c2)
        let f = if t1 == MR then matchR else insertR
        let g = if t2 == MR then matchR else insertR
        return $ (f m1 k1 tr1 e1 *** g m2 k2 tr2 e2) r
    -- if one state is E, we can only delete states, except for another S state, which will go into local end
    -- it is not possible to use an emitting state on the right as those would require emitting on the left, too!
    | t1 == E && t2 `elem` [D,S] = opt $ do
      (c2,tr2) <- s2 ^. transitions ++ [(ls2,le2)]
      r <- arr ! (k1,c2)
      return $ if t2 == D then second (delete m2 k2 tr2) r else second (start m2 k2 tr2) r
    -- the other way around with D,E
    | t1 `elem` [D,S] && t2 == E = opt $ do
      (c1,tr1) <- s1 ^. transitions ++ [(ls1,le2)]
      r <- arr ! (c1,k2)
      return $ if t1 == D then first (delete m1 k1 tr1) r else first (start m1 k1 tr1) r
    -- two branching states
    | t1 == B && t2 == B = opt $
      let 
        [(l1,_),(r1,_)] = s1 ^. transitions
        [(l2,_),(r2,_)] = s2 ^. transitions
      in
        -- both branches are matched
        do
          (s1,s2) <- arr ! (l1,l2) -- left branch (m1,m2)
          (t1,t2) <- arr ! (r1,r2) -- right branch (m1,m2)
          return (branch m1 k1 s1 t1, branch m2 k2 s2 t2) -- (m1,m2)
        ++
        do
          (t1,s2) <- arr ! (r1,l2) -- match right branch of m1 with left branch of m2
          -- local ends for other branches
          x <- arr ! (ls1,ls2)
          let (s1,t2) = (delete m1 l1 le1 *** delete m2 l2 le2) x
          return (branch m1 k1 s1 t1, branch m2 k2 s2 t2)
        ++
        do
          (s1,t2) <- arr ! (l1,r2)
          x <- arr ! (ls1,ls2)
          let (t1,s2) = (delete m1 l1 le1 *** delete m2 l2 le2) x
          return (branch m1 k1 s1 t1, branch m2 k2 s2 t2)
    -- branch - non-branch
    | t1 == B && t2 /= B = opt $
      let
        [(l,_), (r,_)] = s1 ^. transitions
      in
        do
          (s1,s2) <- arr ! (l,k2) -- left branch and m2
          x <- arr ! (ls1,ls2)
          -- dont do anything for ls2, since we do not have to
          -- delete a branch in model 2.
          let (t1,t2) = first (delete m1 r le1) x
          return (branch m1 k1 s1 t1, branch m2 k2 s2 t2)
        ++
        do
          (t1,t2) <- arr ! (r,k2) -- right branch and m2
          x <- arr ! (ls1,ls2)
          let (s1,s2) = first (delete m1 l le1) x -- delete left branch in m1
          return (branch m1 k1 s1 t1, branch m2 k2 s2 t2)
    -- branch - non-branch
    | t1 /= B && t2 == B = opt $
      let
        [(l,_), (r,_)] = s2 ^. transitions
      in
        do
          (s1,s2) <- arr ! (k1,l)
          x <- arr ! (ls1,ls2)
          let (t1,t2) = second (delete m2 r le2) x
          return (branch m1 k1 s1 t1, branch m2 k2 s2 t2)
        ++
        do
          (t1,t2) <- arr ! (k1,r)
          x <- arr ! (ls1,ls2)
          let (s1,s2) = second (delete m2 l le2) x
          return (branch m1 k1 s1 t1, branch m2 k2 s2 t2)
    -- S state versus any
    | t1 == S = opt $ do
        (c1,tr1) <- s1 ^. transitions ++ [(ls1,le1)]
        r <- arr ! (c1, k2)
        return $ first (start m1 k1 tr1) r
    -- S state versus any
    | t2 == S = opt $ do
        (c2,tr2) <- s2 ^. transitions ++ [(ls2,le2)]
        r <- arr ! (k1, c2)
        return $ second (start m2 k2 tr2) r
    --
    | otherwise = []
    where
      s1  = (m1 ^. states) M.! k1
      s2  = (m2 ^. states) M.! k2
      t1  = s1 ^. stateType
      t2  = s2 ^. stateType
      le1 = M.findWithDefault (BitScore (-10000)) k1 (m1^.localEnd)
      le2 = M.findWithDefault (BitScore (-10000)) k2 (m2^.localEnd)
      ls1 = sn1
      ls2 = sn2
      lstates = [ML,IL]
      rstates = [MR,IR]

  locarr  = (array ((0,0),(sn1,sn2)) [((k1,k2),loc k1 k2) | k1 <- [0 .. sn1], k2 <- [0 .. sn2]])
  arr     = (array ((0,0),(sn1,sn2)) [((k1,k2),rec k1 k2) | k1 <- [0 .. sn1], k2 <- [0 .. sn2]]) `asTypeOf` locarr
  sn1 = fst . M.findMax $ m1 ^. states
  sn2 = fst . M.findMax $ m2 ^. states

