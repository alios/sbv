----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Compilers.C
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Compilation of symbolic programs to C
-----------------------------------------------------------------------------

{-# LANGUAGE PatternGuards #-}

module Data.SBV.Compilers.C(compileToC, compileToC') where

import Data.Maybe(isJust)
import qualified Data.Foldable as F (toList)
import Text.PrettyPrint.HughesPJ
import System.Random

import Data.SBV.BitVectors.Data
import Data.SBV.BitVectors.PrettyNum(shex)
import Data.SBV.Compilers.CodeGen

-- token for the target language
data SBVToC = SBVToC

instance SBVTarget SBVToC where
  targetName _ = "C"
  translate _  = cgen

-- Unsupported features, or features TBD go thorough here..
tbd :: String -> a
tbd msg = error $ "SBV->C: Not yet supported: " ++ msg

-- | Given a symbolic computation, render it as an equivalent C program.
--
--    * First argument: States whether run-time-checks should be inserted for index-out-of-bounds or shifting-by-large values etc.
--      If `False`, such checks are ignored, gaining efficiency, at the cost of potential undefined behavior.
--
--    * Second argument is an optional directory name under which the files will be saved. If `Nothing`, the result
--      will be written to stdout. Use @`Just` \".\"@ for creating files in the current directory.
--
--    * The third argument is name of the function, which also forms the names of the C and header files.
--
--    * The fourth argument are the names of the arguments to be used and the names of the outputs, if any.
--       Provide as many arguments as you like, SBV will make up ones if you don't pass enough.
--
--    * The fifth and the final argument is the computation to be compiled.
--
-- Compilation will also generate a @Makefile@ and a sample driver program, which executes the program over random
-- input values.
compileToC :: SymExecutable f => Bool -> Maybe FilePath -> String -> [String] -> f -> IO ()
compileToC rtc mbDir fn extraNames f = do rands <- newStdGen >>= return . randoms
                                          codeGen SBVToC rands rtc mbDir fn extraNames f

-- | Same as 'compileToC', except use the specified values (first argument) instead of random values
-- when generating the driver program. This version is useful mainly for generating repeatable test values.
compileToC' :: SymExecutable f => [Integer] -> Bool -> Maybe FilePath -> String -> [String] -> f -> IO ()
compileToC' dvals = codeGen SBVToC (dvals ++ repeat 0)

cgen :: [Integer] -> Bool -> String -> [String] -> Result -> [(FilePath, Doc)]
cgen randVals rtc nm extraNames sbvProg@(Result ins _ _ _ _ _ _ outs) =
        [ ("Makefile",  genMake   nm nmd)
        , (nm  ++ ".h", genHeader nm sig)
        , (nmd ++ ".c", genDriver randVals nm typ)
        , (nm  ++ ".c", genCProg  rtc nm sig sbvProg (map fst outputVars))
        ]
  where nmd = nm ++ "_driver"
        typ@(CType (_, outputVars)) = mkCType extraNames ins outs
        sig = pprCFunHeader nm typ

-- | A simple representation of C types for functions
-- sufficient enough to represent SBV generated functions
newtype CType = CType ([(String, (Bool, Int))], [(String, (Bool, Int))])

mkCType :: [String] -> [NamedSymVar] -> [SW] -> CType
mkCType extraNames ins outs = CType (map mkVar ins, map mkVar (zip outs outNames))
  where outNames = extraNames ++ ["out" ++ show i | i <- [length extraNames ..]]
        mkVar (sw, n) = (n, (hasSign sw, sizeOf sw))

-- | Pretty print a functions type. If there is only one output, we compile it
-- as a function that returns that value. Otherwise, we compile it as a void function
-- that takes return values as pointers to be updated.
pprCFunHeader :: String -> CType -> Doc
pprCFunHeader fn (CType (ins, outs)) = retType <+> text fn <> parens (fsep (punctuate comma (map mkParam ins ++ os)))
  where (retType, os) = case outs of
                          [(_, bs)] -> (pprCWord False bs, [])
                          _         -> (text "void", map mkPParam outs)

mkParam, mkPParam :: (String, (Bool, Int)) -> Doc
mkParam  (n, bs) = pprCWord True  bs <+> text n
mkPParam (n, bs) = pprCWord False bs <+> text "*" <> text n

-- | Renders as "const SWord8 s0", etc. the first parameter is the width of the typefield
declSW :: Int -> SW -> Doc
declSW w sw@(SW sgsz _) = text "const" <+> pad (showCType sgsz) <+> text (show sw)
  where pad s = text $ s ++ take (w - length s) (repeat ' ')

-- | Renders as "s0", etc, or the corresponding constant
showSW :: [(SW, CW)] -> SW -> Doc
showSW consts sw
  | sw == falseSW                 = text "0"
  | sw == trueSW                  = text "1"
  | Just cw <- sw `lookup` consts = showConst cw
  | True                          = text $ show sw

-- | Words as it would be defined in the standard header stdint.h
pprCWord :: Bool -> (Bool, Int) -> Doc
pprCWord cnst sgsz = (if cnst then text "const" else empty) <+> text (showCType sgsz)

showCType :: (Bool, Int) -> String
showCType (False, 1) = "SBool"
showCType (s, sz)
  | sz `elem` [8, 16, 32, 64] = t
  | True                      = tbd $ "Non-regular bitvector type: " ++ t
 where t = (if s then "SInt" else "SWord") ++ show sz

-- | The printf specifier for the type
specifier :: (Bool, Int) -> Doc
specifier (False,  1) = text "%d"
specifier (False,  8) = text "%\"PRIu8\""
specifier (True,   8) = text "%\"PRId8\""
specifier (False, 16) = text "%\"PRIu16\""
specifier (True,  16) = text "%\"PRId16\""
specifier (False, 32) = text "%\"PRIu32\""
specifier (True,  32) = text "%\"PRId32\""
specifier (False, 64) = text "%\"PRIu64\""
specifier (True,  64) = text "%\"PRId64\""
specifier (s, sz)     = tbd $ "Format specifier at type " ++ (if s then "SInt" else "SWord") ++ show sz

-- | Make a constant value of the given type. We don't check for out of bounds here, as it should not be needed.
--   There are many options here, using binary, decimal, etc. We simply
--   8-bit or less constants using decimal; otherwise we use hex.
--   Note that this automatically takes care of the boolean (1-bit) value problem, since it
--   shows the result as an integer, which is OK as far as C is concerned.
mkConst :: Integer -> (Bool, Int) -> Doc
mkConst i   (False,  1) = integer i
mkConst i   (False,  8) = integer i
mkConst i   (True,   8) = integer i
mkConst i t@(False, 16) = text (shex False t i) <> text "U"
mkConst i t@(True,  16) = text (shex False t i)
mkConst i t@(False, 32) = text (shex False t i) <> text "UL"
mkConst i t@(True,  32) = text (shex False t i) <> text "L"
mkConst i t@(False, 64) = text (shex False t i) <> text "ULL"
mkConst i t@(True,  64) = text (shex False t i) <> text "LL"
mkConst i   (True,  1)  = tbd $ "Signed 1-bit value " ++ show i
mkConst i   (s, sz)     = tbd $ "Constant " ++ show i ++ " at type " ++ (if s then "SInt" else "SWord") ++ show sz

-- | Show a constant
showConst :: CW -> Doc
showConst cw = mkConst (cwVal cw) (hasSign cw, sizeOf cw)

-- | Generate a makefile for ease of experimentation..
genMake :: String -> String -> Doc
genMake fn dn =
     text "# Makefile for" <+> nm <> text ". Automatically generated by SBV. Do not edit!"
  $$ text ""
  $$ text "CC=gcc"
  $$ text "CCFLAGS=-Wall -O3 -DNDEBUG -fomit-frame-pointer"
  $$ text ""
  $$ text "all:" <+> nmd
  $$ text ""
  $$ nmo <> text ":" <+> fsep [nmc, nmh]
  $$ text "\t${CC} ${CCFLAGS}" <+> text "-c" <+> nmc <+> text "-o" <+> nmo
  $$ text ""
  $$ nmdo <> text ":" <+> nmdc
  $$ text "\t${CC} ${CCFLAGS}" <+> text "-c" <+> nmdc <+> text "-o" <+> nmdo
  $$ text ""
  $$ nmd <> text ":" <+> fsep [nmo, nmdo]
  $$ text "\t${CC} ${CCFLAGS}" <+> nmo <+> nmdo <+> text "-o" <+> nmd
  $$ text ""
  $$ text "clean:"
  $$ text "\trm -f" <+> nmdo <+> nmo
  $$ text ""
  $$ text "veryclean: clean"
  $$ text "\trm -f" <+> nmd
  $$ text ""
 where nm   = text fn
       nmd  = text dn
       nmh  = nm <> text ".h"
       nmc  = nm <> text ".c"
       nmo  = nm <> text ".o"
       nmdc = nmd <> text ".c"
       nmdo = nmd <> text ".o"

-- | Generate the header
genHeader :: String -> Doc -> Doc
genHeader fn signature =
     text "/* Header file for" <+> nm <> text ". Automatically generated by SBV. Do not edit! */"
  $$ text ""
  $$ text "#ifndef" <+> tag
  $$ text "#define" <+> tag
  $$ text ""
  $$ text "#include <inttypes.h>"
  $$ text "#include <stdint.h>"
  $$ text ""
  $$ text "/* Unsigned bit-vectors */"
  $$ text "typedef uint8_t  SBool  ;"
  $$ text "typedef uint8_t  SWord8 ;"
  $$ text "typedef uint16_t SWord16;"
  $$ text "typedef uint32_t SWord32;"
  $$ text "typedef uint64_t SWord64;"
  $$ text ""
  $$ text "/* Signed bit-vectors */"
  $$ text "typedef int8_t  SInt8 ;"
  $$ text "typedef int16_t SInt16;"
  $$ text "typedef int32_t SInt32;"
  $$ text "typedef int64_t SInt64;"
  $$ text ""
  $$ text "/* Entry point prototype: */"
  $$ signature <> semi
  $$ text ""
  $$ text "#endif /*" <+> tag <+> text "*/"
  $$ text ""
 where nm  = text fn
       tag = text "__" <> nm <> text "__HEADER_INCLUDED__"

sepIf :: Bool -> Doc
sepIf b = if b then text "" else empty

-- | Generate an example driver program
genDriver :: [Integer] -> String -> CType -> Doc
genDriver randVals fn (CType (inps, outs)) =
     text "/* Example driver program for" <+> nm <> text ". */"
  $$ text "/* Automatically generated by SBV. Edit as you see fit! */"
  $$ text ""
  $$ text "#include <inttypes.h>"
  $$ text "#include <stdint.h>"
  $$ text "#include <stdio.h>"
  $$ text "#include" <+> doubleQuotes (nm <> text ".h")
  $$ text ""
  $$ text "int main(void)"
  $$ text "{"
  $$ text ""
  $$ nest 2 (   vcat (map (\ (n, bs) -> pprCWord False bs <+> text n <> semi) (if singleOut then [] else outs))
             $$ sepIf (not singleOut)
             $$ call
             $$ text ""
             $$ (case outs of
                   [(n, bsz)] ->   text "printf" <> parens (doubleQuotes (fcall <+> text "=" <+> specifier bsz <> text "\\n") <> comma <+> text n) <> semi
                   _          ->   text "printf" <> parens (doubleQuotes (fcall <+> text "->\\n")) <> semi
                                 $$ vcat (map display outs))
             $$ text ""
             $$ text "return 0" <> semi)
  $$ text "}"
  $$ text ""
 where nm = text fn
       singleOut = case outs of
                    [_] -> True
                    _   -> False
       call = case outs of
                [(n, bs)] -> pprCWord True bs <+> text n <+> text "=" <+> fcall <> semi
                _         -> fcall <> semi
       mkCVal (_, bsz@(b, sz)) r
         | not b = mkConst (abs r `mod` (2^sz))                bsz
         | True  = mkConst ((abs r `mod` (2^sz)) - (2^(sz-1))) bsz
       fcall = case outs of
                [_] -> nm <> parens (fsep (punctuate comma (zipWith mkCVal inps randVals)))
                _   -> nm <> parens (fsep (punctuate comma (zipWith mkCVal inps randVals ++ map (\ (n, _) -> text "&" <> text n) outs)))
       display (s, bsz) = text "printf" <> parens (doubleQuotes (text " " <+> text s <+> text "=" <+> specifier bsz <> text "\\n") <> comma <+> text s) <> semi

-- | Generate the C program
genCProg :: Bool -> String -> Doc -> Result -> [String] -> Doc
genCProg rtc fn proto (Result inps preConsts tbls arrs uints axms asgns outs) outputVars
  | not (null arrs)  = tbd "User specified arrays"
  | not (null uints) = tbd "Uninterpreted constants"
  | not (null axms)  = tbd "User given axioms"
  | True
  =  text "/* File:" <+> doubleQuotes (nm <> text ".c") <> text ". Automatically generated by SBV. Do not edit! */"
  $$ text ""
  $$ text "#include <inttypes.h>"
  $$ text "#include <stdint.h>"
  $$ text "#include" <+> doubleQuotes (nm <> text ".h")
  $$ text ""
  $$ proto
  $$ text "{"
  $+$ nest 2 (   vcat mappedInputs
              $$ layout (or anyOuts) (merge (map genTbl tbls) (map genAsgn assignments))
              $$ sepIf (not (null assignments) || not (null tbls))
              $$ genOuts outs)
  $$ text "}"
  $$ text ""
 where nm = text fn
       assignments = F.toList asgns
       (anyOuts, mappedInputs) = unzip $ map genInp inps
       typeWidth = getMax 0 [len (hasSign s, sizeOf s) | (s, _) <- assignments]
                where len (False, 1) = 5 -- SBool
                      len (False, n) = 5 + length (show n) -- SWordN
                      len (True,  n) = 4 + length (show n) -- SIntN
                      getMax 7 _      = 7  -- 7 is the max we can get with SWord64, so don't bother looking any further
                      getMax m []     = m
                      getMax m (x:xs) = getMax (m `max` x) xs
       consts = (falseSW, falseCW) : (trueSW, trueCW) : preConsts
       isConst s = isJust (lookup s consts)
       genInp :: NamedSymVar -> (Bool, Doc)
       genInp (sw@(SW bs _), n)
         | s == n = (False, empty)  -- no aliasing, so no need to assign
         | True   = (True, mkParam (s, bs) <+> text "=" <+> text n <> semi)
         where s = show sw
       genTbl :: ((Int, (Bool, Int), (Bool, Int)), [SW]) -> (Int, Doc)
       genTbl ((i, _, (sg, sz)), elts) =  (location, static <+> mkParam ("table" ++ show i, (sg, sz)) <> text "[] = {"
                                                     $$ nest 4 (fsep (punctuate comma (map (showSW consts) elts)))
                                                     $$ text "};")
         where static   = if location == -1 then text "static" else empty
               location = maximum (-1 : map getNodeId elts)
       getNodeId s@(SW _ (NodeId n)) | isConst s = -1
                                     | True      = n
       genAsgn :: (SW, SBVExpr) -> (Int, Doc)
       genAsgn (sw, n) = (getNodeId sw, declSW typeWidth sw <+> text "=" <+> ppExpr rtc consts n <> semi)
       genOuts :: [SW] -> Doc
       genOuts [sw] = text "return" <+> showSW consts sw <> semi
       genOuts os
         | length os /= length outputVars = error $ "SBV->C: Impossible happened, mismatch outputs: " ++ show (os, outputVars)
         | True                           = vcat (zipWith assignOut outputVars os)
         where assignOut v sw = text "*" <> text v <+> text "=" <+> showSW consts sw <> semi
       -- merge tables intermixed with assignments, paying attention to putting tables as
       -- early as possible.. Note that the assignment list (second argument) is sorted on its order
       merge :: [(Int, Doc)] -> [(Int, Doc)] -> [(Bool, Doc)]
       merge []               as                  = map (\(_, a) -> (True,  a)) as
       merge ts               []                  = map (\(_, t) -> (False, t)) ts
       merge ts@((i, t):trest) as@((i', a):arest)
         | i < i'                                 = (False, t) : merge trest as
         | True                                   = (True,  a) : merge ts arest
       -- layout makes sure tables and assignments are clearly separated
       layout :: Bool -> [(Bool, Doc)] -> Doc
       layout _  []          = empty
       layout pa ((a, d):rs)
         | a     && pa       =            d $$ layout True  rs
         | a     && not pa   = text "" $$ d $$ layout True  rs
         | True              = text "" $$ d $$ layout False rs

ppExpr :: Bool -> [(SW, CW)] -> SBVExpr -> Doc
ppExpr rtc consts (SBVApp op opArgs) = p op (map (showSW consts) opArgs)
  where cBinOps = [ (Plus, "+"), (Times, "*"), (Minus, "-"), (Quot, "/"), (Rem, "%")
                  , (Equal, "=="), (NotEqual, "!=")
                  , (LessThan, "<"), (GreaterThan, ">"), (LessEq, "<="), (GreaterEq, ">=")
                  , (And, "&"), (Or, "|"), (XOr, "^")
                  ]
        p (ArrRead _)       _ = tbd $ "User specified arrays (ArrRead)"
        p (ArrEq _ _)       _ = tbd $ "User specified arrays (ArrEq)"
        p (Uninterpreted s) _ = tbd $ "Uninterpreted constants (" ++ show s ++ ")"
        p (Rol i) _           = tbd $ "Rotate-left operator (" ++ show i ++")"
        p (Ror i) _           = tbd $ "Rotate-right operator (" ++ show i ++")"
        p (Extract i j) _     = tbd $ "Segment-extraction operator (" ++ show i ++ "-" ++ show  j ++")"
        p Join _              = tbd $ "Word concatenation operator"
        p (Shl i) [a]         = shift "<<" i a (let s = head opArgs in (hasSign s, sizeOf s))
        p (Shr i) [a]         = shift ">>" i a (let s = head opArgs in (hasSign s, sizeOf s))
        p Not [a] = text "~" <> a
        p Ite [a, b, c] = a <+> text "?" <+> b <+> text ":" <+> c
        p (LkUp (t, (as, at), _, len) ind def) []
          | not rtc     -- ignore run-time-checks per user request
          = lkUp
          | needsCheckL && needsCheckR
          = checkBoth  <+> text "?" <+> lkUp <+> text ":" <+> showSW consts def
          | needsCheckL
          = checkLeft  <+> text "?" <+> lkUp <+> text ":" <+> showSW consts def
          | needsCheckR
          = checkRight <+> text "?" <+> lkUp <+> text ":" <+> showSW consts def
          | True
          = lkUp
          where index = showSW consts ind
                lkUp = text "table" <> int t <> brackets (showSW consts ind)
                checkLeft  = index <+> text "< 0"
                checkRight = index <+> text ">=" <+> int len
                checkBoth  = parens (checkLeft <+> text "||" <+> checkRight)
                (needsCheckL, needsCheckR) | as   = (True,  (2::Integer)^(at-1)-1  >= (fromIntegral len))
                                           | True = (False, (2::Integer)^(at)  -1  >= (fromIntegral len))
        p o [a, b]
          | Just co <- lookup o cBinOps
          = a <+> text co <+> b
        p o args = error $ "SBV->C: Impossible happened. Received operator " ++ show o ++ " applied to " ++ show args
        shift o i a (sg, sz)
          | not rtc = if i == 0 then a else a <+> text o <+> int i
          | sg      = tbd $ "Operator " ++ o ++ " applied to a signed argument"
          | i < 0   = tbd $ "Operator " ++ o ++ " with a negative shift amount (" ++ show i ++ ")"
          | i >= sz = tbd $ "Operator " ++ o ++ " shifting with a larger-than-bit-size argument (" ++ show i ++"), applied to a " ++ show sz ++ "-bit argument"
          | i == 0  = a
          | True    = a <+> text o <+> int i
