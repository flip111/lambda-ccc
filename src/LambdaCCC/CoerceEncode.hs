{-# LANGUAGE ViewPatterns, PatternGuards #-}
{-# LANGUAGE FlexibleContexts, ConstraintKinds #-}
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
{-# OPTIONS_GHC -Wall #-}

-- {-# OPTIONS_GHC -fno-warn-unused-imports #-} -- TEMP
-- {-# OPTIONS_GHC -fno-warn-unused-binds   #-} -- TEMP

----------------------------------------------------------------------
-- |
-- Module      :  LambdaCCC.CoerceEncode
-- Copyright   :  (c) 2014 Tabula, Inc.
-- 
-- Maintainer  :  conal@tabula.com
-- Stability   :  experimental
-- 
-- Transform away all non-standard types
----------------------------------------------------------------------

module LambdaCCC.CoerceEncode where

-- TODO: Explicit exports

-- import Prelude hiding (id,(.))

import Data.Functor ((<$>))
import Control.Applicative (liftA2)
import Control.Arrow (second)
-- import Data.List (partition)

import CoreArity (etaExpand)

import HERMIT.GHC
import HERMIT.Kure
import HERMIT.Core (CoreProg(..))

import HERMIT.Extras hiding (findTyConT, labeled)

import qualified Type

class Standardizable a where standardize :: Unop a

isStandardType :: Type -> Bool
isStandardType t = any ($ t) [isUnitTy,isBoolTy,isIntTy]

tracing :: Bool
tracing = True

ttrace :: String -> a -> a
ttrace | tracing   = trace
       | otherwise = flip const

instance Standardizable CoreExpr where
  standardize x | ttrace ("standardize expr\n" ++ unsafeShowPpr x) False = undefined
  standardize e@(Type {})     = e
  standardize e@(Coercion {}) = e
  standardize e@(Lit _)       = e
  standardize e@(collectArgs -> ( Var (isDataConWorkId_maybe -> Just con)
                                , filter (not.isTyCoArg) -> valArgs ))
    | isStandardType (exprType e) = ttrace "standard expression type" $
                                    e
    | let argsNeeded = dataConSourceArity con - length valArgs, argsNeeded > 0 =
        ttrace "eta-expand unsaturated constructor application"
        standardize (etaExpand argsNeeded e)
    | otherwise =
        ttrace ("standardize constructor application") $
        castTo (exprType e)
          (foldT (mkCoreTup []) (\ u v  -> mkCoreTup [u,v])
                 (toTree (map standardize valArgs)))
  standardize e@(Var {})     = e
  standardize (App u v)      = App (standardize u) (standardize v)
  standardize (Lam x e)      = Lam x (standardize e)
  standardize (Let b e)      = Let (standardize b) (standardize e)
  standardize (Case e w ty alts) =
    case' (standardize e)
          w'
          ty
          (map (standardizeAlt w' (tyConAppArgs (exprType e))) alts)
   where
     -- We may rewrite an alt to use wild, so update its OccInfo to unknown.
     -- TODO: Only update if used.
     w' = setIdOccInfo w NoOccInfo
  standardize e@(Cast e' _)  = castTo (exprType e) (standardize e')
  standardize (Tick t e)     = Tick t (standardize e)

castTo :: Type -> CoreExpr -> CoreExpr
castTo ty (Cast e _) = castTo ty e
castTo ty e = mkCast e (mkUnivCo Representational (exprType e) ty)

-- TODO: Look into constructing axioms instead of using mkUnivCo

case' :: CoreExpr -> Var -> Type -> [CoreAlt] -> CoreExpr
case' scrut wild _bodyTy [(DEFAULT,[],body)] =
  Let (NonRec wild scrut) body
case' scrut wild bodyTy alts = Case scrut wild bodyTy alts

instance Standardizable CoreBind where
  -- standardize x | ttrace ("standardize bind " ++ unsafeShowPpr' x) False = undefined
  standardize (NonRec x e) = NonRec x (standardize e)
  standardize (Rec ves)    = Rec (map (second standardize) ves)

standardizeAlt :: Var -> [Type] -> Unop CoreAlt
standardizeAlt wild tcTys (DataAlt dc,vs,e) =
  ttrace ("standardizeAlt:\n" ++
          unsafeShowPpr ((dc,vs,e),(valVars0,valVars)
                       , alt' )) $
  alt'
 where
   alt' | [x] <- valVars =
           (DEFAULT, [], standardize (subst [(x,castTo (varType x) (Var wild))] e))
        | otherwise      =
            (tupCon (length valVars), valVars, standardize e)
   valVars0 = filter (not . liftA2 (||) isTypeVar isCoVar) vs
   valVars  = onVarType sub <$> valVars0  -- needed?
   sub      = Type.substTy (Type.zipOpenTvSubst tvs tcTys)
   tvs      = fst (splitForAllTys (dataConRepType dc))
standardizeAlt _ _ _ = error "standardizeAlt: non-DataAlt"

onVarType :: Unop Type -> Unop Var
onVarType f v = setVarType v (f (varType v))

-- TODO: Handle length valVars > 2 correctly. I think I'll have to generate new
-- wildcard variables for the new 'case' expressions. Learn standard GHC
-- techniques, which I think involve checking for free and bound variables.

-- TODO: is the isCoVar test redundant, i.e., are coercion variables also type
-- variables?

tupCon :: Int -> AltCon
tupCon 1 = DEFAULT
tupCon n = DataAlt (tupleCon BoxedTuple n)

instance Standardizable CoreProg where
  standardize ProgNil = ProgNil
  standardize (ProgCons bind prog) = ProgCons (standardize bind) (standardize prog)

-- TODO: Parametrize by bndr

standardizeR :: (MonadCatch m, Standardizable a, SyntaxEq a) =>
                Rewrite c m a
standardizeR = changedArrR standardize

unsafeShowPpr' :: Outputable a => a -> String
unsafeShowPpr' = replace '\n' ' ' . dropMultiSpace . unsafeShowPpr
 where
   dropMultiSpace (' ':s@(' ':_)) = dropMultiSpace s
   dropMultiSpace (c:s)           = c : dropMultiSpace s
   dropMultiSpace []              = []
   replace a b = map (\ x -> if x == a then b else x)