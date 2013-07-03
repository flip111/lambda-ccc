{-# LANGUAGE TypeOperators, TypeFamilies, GADTs, KindSignatures #-}
{-# LANGUAGE ExistentialQuantification, ScopedTypeVariables, PatternGuards #-}
{-# LANGUAGE MagicHash, ConstraintKinds #-}
{-# LANGUAGE CPP #-}

{-# OPTIONS_GHC -Wall #-}

-- {-# OPTIONS_GHC -fno-warn-unused-imports #-} -- TEMP
{-# OPTIONS_GHC -fno-warn-unused-binds   #-} -- TEMP

----------------------------------------------------------------------
-- |
-- Module      :  LambdaCCC.Lambda
-- Copyright   :  (c) 2013 Tabula, Inc.
-- License     :  BSD3
-- 
-- Maintainer  :  conal@tabula.com
-- Stability   :  experimental
-- 
-- Lambda expressions -- statically typed
----------------------------------------------------------------------

module LambdaCCC.Lambda
  ( Name
  , V, Pat(..), E(..)
  , varTy, patTy, expTy
  , var#, varPat#, app, lamv, lamv#, lett
  , varT, constT
  , reifyE, reifyE', evalE
  , vars, vars2
  ) where

import Control.Arrow ((&&&))
import Data.Maybe (isJust,fromMaybe,catMaybes,listToMaybe)
import Text.Printf (printf)
import Debug.Trace (trace)

import GHC.Pack (unpackCString#)
import GHC.Prim (Addr#)

import Data.IsTy
import Data.Proof.EQ

import LambdaCCC.Misc
import LambdaCCC.ShowUtils
import LambdaCCC.Prim
import LambdaCCC.Ty

-- Whether to fold simple definitions during show
#define ShowFolded

-- Whether to simplify during construction
#define Simplify

-- | Variable names
type Name = String

-- | Typed variable
data V a = V Name (Ty a)

instance Show (V a) where
  -- showsPrec p (V n ty) = showString n . showString " :: " . showsPrec p ty
  showsPrec _ (V n _) = showString n

instance IsTy V where
  V na tya `tyEq` V nb tyb | nb == na  = tya `tyEq` tyb
                           | otherwise = Nothing

instance Eq (V a) where
  V na _ == V nb _ = nb == na

varTy :: V a -> Ty a
varTy (V _ ty) = ty

-- | Lambda patterns
data Pat :: * -> * where
  UnitPat :: Pat Unit
  VarPat  :: V a -> Pat a
  PairPat :: Pat a -> Pat b -> Pat (a :* b)

instance Eq (Pat a) where
  UnitPat == UnitPat = True
  VarPat v == VarPat v' = v == v'
  PairPat a b == PairPat a' b' = a == a' && b == b'
  _ == _ = False

instance Show (Pat a) where
  showsPrec _ UnitPat       = showString "()"
  showsPrec p (VarPat v)    = showsPrec p v
  showsPrec p (PairPat a b) = showsPair p a b

patTy :: Pat a -> Ty a
patTy UnitPat       = UnitT
patTy (VarPat v)    = varTy v
patTy (PairPat a b) = patTy a :* patTy b

-- | Does a variable occur in a pattern?
occursP :: V a -> Pat b -> Bool
occursP _ UnitPat       = False
occursP v (VarPat v')   = isJust (v `tyEq` v')
occursP v (PairPat a b) = occursP v a || occursP v b

infixl 9 :^

-- infix 1 :#

-- | Lambda expressions
data E :: * -> * where
  Var   :: forall a   . V a -> E a
  Const :: forall a   . Prim a -> Ty a -> E a
  (:^)  :: forall b a . HasTy a => E (a :=> b) -> E a -> E b
  Lam   :: forall a b . Pat a -> E b -> E (a :=> b)

-- | The type of an expression
expTy :: E a -> Ty a
expTy (Var v)      = varTy v
expTy (Const _ ty) = ty
expTy (f :^ _)     = case expTy f of _ :=> b -> b
expTy (Lam p e)    = patTy p :=> expTy e

-- | A variable occurs freely in an expression
occursE :: V a -> E b -> Bool
occursE v (Var v')  = isJust (v `tyEq` v')
occursE v (f :^ e)  = occursE v f || occursE v e
occursE v (Lam p e) = not (occursP v p) && occursE v e
occursE _ _         = False

-- I've placed the quantifiers explicitly to reflect what I learned from GHCi
-- (In GHCi, use ":set -fprint-explicit-foralls" and ":ty (:^)".)
-- When I said "forall a b" in (:^), GHC swapped them back. Oh well.

instance IsTy E where
  type IsTyConstraint E z = HasTy z
  tyEq = tyEq'

instance Eq (E a) where
  Var v     == Var v'                                = v == v'
  Const x _ == Const x' _                            = x == x'
  (f :^ a)  == (f' :^ a') | Just Refl <- a `tyEq` a' = f == f'
  Lam p e   == Lam p' e'                             = p == p' && e == e'
  _         == _                                     = False

-- TODO: Replace the Const Ty argument with a HasTy constraint for ease of use.
-- I'm waiting until I know how to construct the required dictionaries in Core.
-- 
-- Meanwhile,

varT :: HasTy a => Name -> E a
varT nm = Var (V nm typ)

constT :: HasTy a => Prim a -> E a
constT p = Const p typ

var# :: forall a. Addr# -> Ty a -> E a
var# addr ty = Var (V (unpackCString# addr) ty)

varPat# :: forall a. Addr# -> Ty a -> Pat a
varPat# addr ty = VarPat (V (unpackCString# addr) ty)

app :: forall b a . E (a :=> b) -> Ty a -> E a -> E b
app f tya a | HasTy <- tyHasTy tya = f :^ a

-- varVarPat :: forall a b. Name -> Name -> Ty a -> Ty b -> Pat (a :* b)
-- varVarPat na nb tya tyb = PairPat (varPat na tya) (varPat nb tyb)

lamv :: forall a b. V a -> E b -> E (a -> b)
#ifdef Simplify
-- Eta-reduce
lamv v (f :^ Var v') | Just Refl <- v `tyEq` v', not (v `occursE` f) = f
#endif
lamv v body = Lam (VarPat v) body

-- TODO: Generalize eta-reduction to pattern lambdas.

lamv# :: forall a b. Addr# -> Ty a -> E b -> E (a -> b)
lamv# addr ty body = lamv (V (unpackCString# addr) ty) body

-- | Let expression (beta redex)
lett :: forall a b. Pat a -> E a -> E b -> E b
lett pat e body | HasTy <- tyHasTy (patTy pat) = Lam pat body :^ e

instance Show (E a) where
#ifdef ShowFolded
--   showsPrec p (Const prim :^ (u :# v)) | Just (OpInfo op fixity) <- opInfo prim =
--     showsOp2' op fixity p u v
  showsPrec p (Const PairP _ :^ u :^ v) = showsPair p u v
  showsPrec p (Const prim _ :^ u :^ v) | Just (OpInfo op fixity) <- opInfo prim =
    showsOp2' op fixity p u v
  showsPrec p (Lam q body :^ rhs) =  -- beta redex as "let"
    showParen (p > 0) $
    showString "let " . showsPrec 0 q . showString " = " . showsPrec 0 rhs
    . showString " in " . showsPrec 0 body
#endif
  showsPrec _ (Var (V n _))  = showString n
  showsPrec p (Const c _) = showsPrec p c
--  showsPrec p (u :# v)  = showsPair p u v
  showsPrec p (u :^ v)  = showsApp p u v
  showsPrec p (Lam q e) = showParen (p > 0) $
                          showString "\\ " . showsPrec 0 q . showString " -> " . showsPrec 0 e

data OpInfo = OpInfo String Fixity

opInfo :: Prim a -> Maybe OpInfo
opInfo AddP = Just $ OpInfo "+"     (6,AssocLeft )
opInfo AndP = Just $ OpInfo "&&&"   (3,AssocRight)
opInfo OrP  = Just $ OpInfo "|||"   (2,AssocRight)
opInfo XorP = Just $ OpInfo "`xor`" (2,AssocRight)
opInfo _   = Nothing

-- | Single variable binding
data Bind = forall a. Bind (V a) a
-- | Variable environment
type Env = [Bind]

reifyE :: HasTy a => String -> a -> E a
reifyE msg a = reifyE' msg a typ

reifyE' :: String -> a -> Ty a -> E a
reifyE' msg _ _ = error (printf "Oops -- reifyE' %s was not eliminated" msg)
{-# NOINLINE reifyE' #-}

-- The artificially strange definition of reifyE' prevents it from getting
-- inlined and so allows the reify'/eval rule to fire. The NOINLINE pragma is
-- somehow insufficient, and the reify/eval rule won't fire. I don't know how to
-- get rules with dictionaries to work.

{-# RULES

"reify'/eval" forall e msg t. reifyE' (evalE e) msg t = e
"eval/reify'" forall x msg t. evalE (reifyE' x msg t) = x

-- "reify/eval"  forall   msg e. reifyE (evalE e) msg = e

  #-}

-- We evaluate *closed* expressions (no free variables)
instance Evalable (E a) where
  type ValT (E a) = a
  eval = evalE

evalE :: E a -> a
evalE e = trace ("evalE: " ++ show e) $
          eval' e []  -- provide empty environment

-- TODO: Rework so that eval' can work independently of env. Will save repeated
-- evals.

-- Expression evaluation requires a binding environment. In other words,
-- expressions evaluate to a function from environments.

eval' :: E a -> Env -> a
eval' (Var v)   env = fromMaybe (error $ "eval': unbound variable: " ++ show v) $
                      lookupVar v env
eval' (Const p _) _   = eval p
-- eval' (u :# v)  env = (eval' u env, eval' v env)
eval' (u :^ v)  env = (eval' u env) (eval' v env)
eval' (Lam p e) env = \ x -> eval' e (extendEnv p x env)

extendEnv :: Pat b -> b -> Env -> Env
extendEnv UnitPat       ()    = id
extendEnv (VarPat vb)   b     = (Bind vb b :)
extendEnv (PairPat p q) (a,b) = extendEnv q b . extendEnv p a

lookupVar :: forall a. V a -> Env -> Maybe a
lookupVar va = listToMaybe . catMaybes . map check
 where
   check :: Bind -> Maybe a
   check (Bind vb b) | Just Refl <- va `tyEq` vb = Just b
                     | otherwise                 = Nothing

-- Oh, hm. I'm using a difference (Hughes) list representation. extendEnv maps
-- UnitPat, VarPat, and PairPat to mempty, singleton, and mappend, respectively.
-- 
-- TODO: adopt another representation, such as Seq. Replace the explicit
-- recursion in lookupVar with a fold or something. It's almost a mconcat.

vars :: HasTy a => Name -> (Pat a, E a)
vars = (VarPat &&& Var) . flip V typ

-- vars n = (VarPat v, Var v) where v = V n typ

vars2 :: HasTy2 a b =>
         (Name,Name) -> (Pat (a,b), (E a,E b))
vars2 (na,nb) = (PairPat ap bp, (ae,be))
 where
   (ap,ae) = vars na
   (bp,be) = vars nb

{--------------------------------------------------------------------
    Rules
--------------------------------------------------------------------}

{-# RULES
 
"reify/not"   forall s. reifyE' s not   = Const NotP
"reify/(&&)"  forall s. reifyE' s (&&)  = Const AndP
"reify/(||)"  forall s. reifyE' s (||)  = Const OrP
"reify/xor"   forall s. reifyE' s xor   = Const XorP
"reify/(+)"   forall s. reifyE' s (+)   = Const AddP
"reify/fst"   forall s. reifyE' s fst   = Const FstP
"reify/snd"   forall s. reifyE' s snd   = Const SndP
"reify/pair"  forall s. reifyE' s (,)   = Const PairP
 
"reify/false" forall s. reifyE' s False = Const (LitP False)
"reify/true"  forall s. reifyE' s True  = Const (LitP True)
 
  #-}

-- TODO: Generalize the false & true rules. I think I'll need to do via an
-- explicit Core transformation. I'll have to be able to find out whether the
-- type is Showable. I suppose I could handle a few known type constructors.
