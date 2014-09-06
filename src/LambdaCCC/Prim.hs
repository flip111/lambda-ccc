{-# LANGUAGE TypeOperators, TypeFamilies, GADTs, KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses, ViewPatterns, PatternGuards, CPP #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleInstances, FlexibleContexts #-}
{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE UndecidableInstances #-} -- see below

{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fcontext-stack=35 #-}  -- for N32

-- {-# OPTIONS_GHC -fno-warn-unused-imports #-} -- TEMP
-- {-# OPTIONS_GHC -fno-warn-unused-binds   #-} -- TEMP

----------------------------------------------------------------------
-- |
-- Module      :  LambdaCCC.Prim
-- Copyright   :  (c) 2013 Tabula, Inc.
-- License     :  BSD3
-- 
-- Maintainer  :  conal@tabula.com
-- Stability   :  experimental
-- 
-- Primitives
----------------------------------------------------------------------

module LambdaCCC.Prim
  ( Lit(..), HasLit(..), litSS
  , Prim(..),litP,xor -- ,cond -- ,ifThenElse
  , primArrow
  ) where

-- #define LitSources

import Prelude hiding (id,(.),not,and,or,curry,uncurry)

-- import Control.Arrow ((&&&))
import Data.Constraint (Dict(..))
import Data.Typeable (Typeable)

import Circat.Category
import Circat.Classes (BoolCat(not,and,or),MuxCat(..),NumCat(..))
import qualified Circat.Classes as C

-- :( . TODO: Disentangle!
-- HasUnitArrow links the category and primitive type
import Circat.Circuit (GenBuses,(:>)
#ifdef LitSources
                      , litUnit,litBool,litInt
#else
                      , constC
#endif
                      )

-- import TypeEncode.Encode (EncodeCat(..))

-- TODO: sort out the two uses of xor and simplify the Circat.Classes imports
-- and uses.

import LambdaCCC.Misc
import LambdaCCC.ShowUtils (Show'(..))

{--------------------------------------------------------------------
    Literals
--------------------------------------------------------------------}

-- | Literals
data Lit :: * -> * where
  UnitL  :: Unit -> Lit Unit
  BoolL  :: Bool -> Lit Bool
  IntL   :: Int  -> Lit Int

-- The Unit argument is just for uniformity

instance Eq' (Lit a) (Lit b) where
  UnitL x === UnitL y = x == y
  BoolL x === BoolL y = x == y
  IntL  x === IntL  y = x == y
  _       === _       = False

instance Eq (Lit a) where (==) = (===)

-- | Convenient 'Lit' construction
class HasLit a where toLit :: a -> Lit a

instance HasLit Unit where toLit = UnitL
instance HasLit Bool where toLit = BoolL
instance HasLit Int  where toLit = IntL

-- TODO: Do I still need this stuff?

-- Proofs

litTypeable :: Lit a -> Dict (Typeable a)
litTypeable (UnitL _) = Dict
litTypeable (BoolL _) = Dict
litTypeable (IntL  _) = Dict

litHasShow :: Lit a -> Dict (Show a)
litHasShow (UnitL _) = Dict
litHasShow (BoolL _) = Dict
litHasShow (IntL  _) = Dict

#define LSh (litHasShow -> Dict)

-- instance Show (Lit a) where
--   showsPrec p UnitL     = showsPrec p ()
--   showsPrec p (BoolL b) = showsPrec p b
--   showsPrec p (IntL  b) = showsPrec p b

instance Show (Lit a) where
  showsPrec p l@LSh = showsPrec p (eval l)

litGenBuses :: Lit a -> Dict (GenBuses a)
litGenBuses (UnitL _) = Dict
litGenBuses (BoolL _) = Dict
litGenBuses (IntL  _) = Dict

#define LSo (litGenBuses -> Dict)

litSS :: Lit a -> (Dict (Typeable a, Show a, GenBuses a))
litSS l | (Dict,Dict,Dict) <- (litTypeable l, litHasShow l,litGenBuses l) = Dict

#define LS (litSS -> Dict)

instance Evalable (Lit a) where
  type ValT (Lit a) = a
  eval (UnitL x) = x
  eval (BoolL x) = x
  eval (IntL  x) = x

instance HasUnitArrow (->) Lit where
  unitArrow x = const (eval x)

instance HasUnitArrow (:>) Lit where
#ifdef LitSources
  unitArrow (UnitL x) = litUnit x
  unitArrow (BoolL x) = litBool x
  unitArrow (IntL  x) = litInt  x
#else
  unitArrow l@LS = constC (eval l)
#endif

{--------------------------------------------------------------------
    Primitives
--------------------------------------------------------------------}

-- | Primitives
data Prim :: * -> * where
  LitP          :: Lit a -> Prim a
  NotP          :: Prim (Bool -> Bool)
  AndP,OrP,XorP :: Prim (Bool -> Bool -> Bool)
  AddP,MulP     :: Prim (Int -> Int -> Int)
  ExlP          :: Prim (a :* b -> a)
  ExrP          :: Prim (a :* b -> b)
  InlP          :: Prim (a -> a :+ b)
  InrP          :: Prim (b -> a :+ b)
  PairP         :: Prim (a -> b -> a :* b)
  CondBP        :: Prim (Bool :* (Bool :* Bool) -> Bool)  -- mux on Bool
  CondIP        :: Prim (Bool :* (Int  :* Int ) -> Int )  -- mux on Int
  AbstP         :: (HasRep a, Rep a ~ a') => Prim (a' -> a)
  ReprP         :: (HasRep a, Rep a ~ a') => Prim (a -> a')
  OopsP         :: Prim a

instance Eq' (Prim a) (Prim b) where
  LitP a    === LitP b    = a === b
  NotP      === NotP      = True
  AndP      === AndP      = True
  OrP       === OrP       = True
  XorP      === XorP      = True
  AddP      === AddP      = True
  MulP      === MulP      = True
  ExlP      === ExlP      = True
  ExrP      === ExrP      = True
  InlP      === InlP      = True
  InrP      === InrP      = True
  PairP     === PairP     = True
  CondBP    === CondBP    = True
  CondIP    === CondIP    = True
  AbstP     === AbstP     = True
  ReprP     === ReprP     = True
  OopsP     === OopsP     = True
  _         === _         = False

instance Eq (Prim a) where (==) = (===)

instance Show (Prim a) where
  showsPrec p (LitP a)   = showsPrec p a
  showsPrec _ NotP       = showString "not"
  showsPrec _ AndP       = showString "(&&)"
  showsPrec _ OrP        = showString "(||)"
  showsPrec _ XorP       = showString "xor"
  showsPrec _ AddP       = showString "add"
  showsPrec _ MulP       = showString "mul"
  showsPrec _ ExlP       = showString "exl"
  showsPrec _ InlP       = showString "Left"
  showsPrec _ InrP       = showString "Right"
  showsPrec _ ExrP       = showString "exr"
  showsPrec _ PairP      = showString "(,)"
  showsPrec _ CondBP     = showString "muxB"
  showsPrec _ CondIP     = showString "muxI"
  showsPrec _ AbstP      = showString "abst"
  showsPrec _ ReprP      = showString "repr"
  showsPrec _ OopsP      = showString "<oops>"

instance Show' Prim where showsPrec' = showsPrec

primArrow :: ( BiCCCC k Lit
             , BoolCat k, MuxCat k, NumCat k Int, RepCat k
             ) =>
             Prim (a :=> b) -> (a `k` b)
primArrow NotP      = not
primArrow AndP      = curry and
primArrow OrP       = curry or
primArrow XorP      = curry C.xor
primArrow AddP      = curry add
primArrow MulP      = curry mul
primArrow ExlP      = exl
primArrow ExrP      = exr
primArrow InlP      = inl
primArrow InrP      = inr
primArrow PairP     = curry id
primArrow CondBP    = muxB
primArrow CondIP    = muxI
primArrow AbstP     = abstC
primArrow ReprP     = reprC
primArrow OopsP     = error "primArrow: Oops"
primArrow (LitP _)  = error ("primArrow: LitP with function type?!")

instance ( BiCCCC k Lit
         , BoolCat k, MuxCat k, NumCat k Int
         ) =>
         HasUnitArrow k Prim where
  unitArrow NotP      = unitFun not
  unitArrow AndP      = unitFun (curry and)
  unitArrow OrP       = unitFun (curry or)
  unitArrow XorP      = unitFun (curry C.xor)
  unitArrow AddP      = unitFun (curry add)
  unitArrow MulP      = unitFun (curry mul)
  unitArrow ExlP      = unitFun exl
  unitArrow ExrP      = unitFun exr
  unitArrow InlP      = unitFun inl
  unitArrow InrP      = unitFun inr
  unitArrow PairP     = unitFun (curry id)
  unitArrow CondBP    = unitFun muxB
  unitArrow CondIP    = unitFun muxI
  unitArrow AbstP     = unitFun abstC
  unitArrow ReprP     = unitFun reprC
  unitArrow OopsP     = error "unitArrow on Prim: OopsP"
  unitArrow (LitP l)  = unitArrow l

--     Variable `k' occurs more often than in the instance head
--       in the constraint: BiCCC k
--     (Use -XUndecidableInstances to permit this)

instance Evalable (Prim a) where
  type ValT (Prim a) = a
  eval (LitP l)      = eval l
  eval NotP          = not
  eval AndP          = (&&)
  eval OrP           = (||)
  eval XorP          = xor
  eval AddP          = (+)
  eval MulP          = (*)
  eval ExlP          = fst
  eval ExrP          = snd
  eval InlP          = Left
  eval InrP          = Right
  eval PairP         = (,)
  eval CondBP        = muxB
  eval CondIP        = muxI
  eval AbstP         = abstC
  eval ReprP         = reprC
  eval OopsP         = error "eval on Prim: Oops!"

-- TODO: replace fst with exl, etc.

-- TODO: Split LitP out of Prim, and make Prim have domain and range. Then
-- revisit 'HasConstArrow', and implement Evalable (Prim a b) homomorphically.
-- See convertP in LambdaCCC.CCC.

infixr 3 `xor`

xor :: Binop Bool
xor = (/=)
{-# NOINLINE xor #-}

litP :: HasLit a => a -> Prim a
litP = LitP . toLit
