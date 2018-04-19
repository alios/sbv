{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.RegExp
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- A collection of regular-expression related utilities.
-----------------------------------------------------------------------------

module Data.SBV.RegExp (
        -- * Matching
        match
        -- * Literals
        , literal
        -- * White space
        , newline, whiteSpace, whiteSpaceNoNewLine
        -- * Separators
        , tab, punctuation
        -- * Digits
        , digit, octDigit, hexDigit
        -- * Numbers
        , decimal, octal, hexadecimal
        -- * Identifiers
        , identifier
        ) where

import Data.SBV.Core.Data hiding (literal)
import qualified Data.SBV.Core.Data as SBV (literal)

import Data.SBV.Core.Model () -- instances only

-- Only for testing
import Prelude hiding (length)
import Data.SBV.String (length)

-- For doctest use only
--
-- $setup
-- >>> import Data.SBV.Provers.Prover (prove, sat)
-- >>> import Data.SBV.Utils.Boolean  ((<=>), (==>))
-- >>> import Data.SBV.Core.Model

-- | @`match` s r@ checks whether @s@ is in the language generated by @r@.
-- TODO: Currently SBV does *not* optimize this call if @s@ is concrete, but
-- rather directly defers down to the solver. We might want to perform the
-- operation on the Haskell side for performance reasons, should this become
-- important.
--
-- For instance, you can generate valid-looking phone numbers like this:
--
-- > let dig09 = RE_Range '0' '9'
-- > let dig19 = RE_Range '1' '9'
-- > let pre   = dig19 `RE_Conc` RE_Loop 2 2 dig09
-- > let post  = dig19 `RE_Conc` RE_Loop 3 3 dig09
-- > let phone = pre `RE_Conc` RE_Literal "-" `RE_Conc` post
-- > sat (`match` phone)
-- > Satisfiable. Model:
-- >   s0 = "222-2248" :: String
--
-- >>> :set -XOverloadedStrings
-- >>> prove $ \s -> match s (RE_Literal "hello") <=> s .== "hello"
-- Q.E.D.
-- >>> prove $ \s -> match s (RE_Loop 2 5 (RE_Literal "xyz")) ==> length s .>= 6
-- Q.E.D.
-- >>> prove $ \s -> match s (RE_Loop 2 5 (RE_Literal "xyz")) ==> length s .<= 15
-- Q.E.D.
-- >>> prove $ \s -> match s (RE_Loop 2 5 (RE_Literal "xyz")) ==> length s .>= 7
-- Falsifiable. Counter-example:
--   s0 = "xyzxyz" :: String
match :: SString -> SRegExp -> SBool
match s r = lift1 (StrInRe r) opt s
  where -- TODO: Replace this with a function that concretely evaluates the string against the
        -- reg-exp, possible future work. But probably there isn't enough ROI.
        opt :: Maybe (String -> Bool)
        opt = Nothing

literal             :: a
literal             = error "literal"

newline             :: a
newline             = error "newline"

whiteSpace          :: a
whiteSpace          = error "whiteSpace"

whiteSpaceNoNewLine :: a
whiteSpaceNoNewLine = error "whiteSpaceNoNewLine"

tab                 :: a
tab                 = error "tab"

punctuation         :: a
punctuation         = error "punctuation"

digit               :: a
digit               = error "digit"

octDigit            :: a
octDigit            = error "octDigit"

hexDigit            :: a
hexDigit            = error "hexDigit"

decimal             :: a
decimal             = error "decimal"

octal               :: a
octal               = error "octal"

hexadecimal         :: a
hexadecimal         = error "hexadecimal"

identifier          :: a
identifier          = error "identifier"

-- | Lift a unary operator over strings.
lift1 :: forall a b. (SymWord a, SymWord b) => StrOp -> Maybe (a -> b) -> SBV a -> SBV b
lift1 w mbOp a
  | Just cv <- concEval1 mbOp a
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k = kindOf (undefined :: b)
        r st = do swa <- sbvToSW st a
                  newExpr st k (SBVApp (StrOp w) [swa])

-- | Concrete evaluation for unary ops
concEval1 :: (SymWord a, SymWord b) => Maybe (a -> b) -> SBV a -> Maybe (SBV b)
concEval1 mbOp a = SBV.literal <$> (mbOp <*> unliteral a)

-- | Quiet GHC about testing only functions
__unused :: a
__unused = undefined length
