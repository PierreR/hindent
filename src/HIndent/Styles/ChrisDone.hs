{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Chris Done's style.
--
-- Documented here: <https://github.com/chrisdone/haskell-style-guide>

module HIndent.Styles.ChrisDone
  (chrisDone)
  where

import HIndent.Pretty
import HIndent.Types

import Control.Monad
import Control.Monad.Loops
import Control.Monad.State.Class
import Data.Int
import Language.Haskell.Exts.Annotated.Syntax
import Prelude hiding (exp)

--------------------------------------------------------------------------------
-- Style configuration

-- | A short function name.
shortName :: Int64
shortName = 10

-- | Column limit: 50
smallColumnLimit :: Int64
smallColumnLimit = 50

-- | Empty state.
data State = State

-- | The printer style.
chrisDone :: Style
chrisDone =
  Style {styleName = "chris-done"
        ,styleAuthor = "Chris Done"
        ,styleDescription = "Chris Done's personal style. Documented here: <https://github.com/chrisdone/haskell-style-guide>"
        ,styleInitialState = State
        ,styleExtenders =
           [Extender exp
           ,Extender fieldupdate
           ,Extender rhs
           ,Extender guardedrhs
           ,Extender guardedalt
           ,Extender unguardedalt
           ,Extender stmt
           ,Extender decl]
        ,styleDefConfig =
           Config {configMaxColumns = 80
                  ,configIndentSpaces = 2}}

--------------------------------------------------------------------------------
-- Extenders

-- | Pretty print type signatures like
--
-- foo :: (Show x,Read x)
--     => (Foo -> Bar)
--     -> Maybe Int
--     -> (Char -> X -> Y)
--     -> IO ()
--
decl :: t -> Decl NodeInfo -> Printer ()
decl _ (TypeSig _ names ty') =
  depend (do inter (write ", ")
                   (map pretty names)
             write " :: ")
         (declTy ty')
  where declTy dty =
          case dty of
            TyForall _ mbinds mctx ty ->
              do case mbinds of
                   Nothing -> return ()
                   Just ts ->
                     do write "forall "
                        spaced (map pretty ts)
                        write ". "
                        newline
                 case mctx of
                   Nothing -> prettyTy ty
                   Just ctx ->
                     do pretty ctx
                        newline
                        indented (-3)
                                 (depend (write "=> ")
                                         (prettyTy ty))
            _ -> prettyTy dty
        collapseFaps (TyFun _ arg result) = arg : collapseFaps result
        collapseFaps e = [e]
        prettyTy ty =
          do small <- isSmall' ty
             if small
                then pretty ty
                else case collapseFaps ty of
                       [] -> pretty ty
                       tys ->
                         prefixedLined "-> "
                                       (map pretty tys)
        isSmall' p =
          do overflows <- isOverflow (pretty p)
             oneLine <- isSingleLiner (pretty p)
             return (not overflows && oneLine)
decl _ e = prettyNoExt e

-- | I want field updates to be dependent or newline.
fieldupdate :: t -> FieldUpdate NodeInfo -> Printer ()
fieldupdate _ e =
  case e of
    FieldUpdate _ n e' ->
      dependOrNewline
        (do pretty n
            write " = ")
        e'
        pretty
    _ -> prettyNoExt e

-- | Right-hand sides are dependent.
rhs :: State -> Rhs NodeInfo -> Printer ()
rhs _ (UnGuardedRhs _ e) =
  do indentSpaces <- getIndentSpaces
     indented indentSpaces
              (dependOrNewline (write " = ")
                               e
                               pretty)
rhs _ e = prettyNoExt e

-- | I want guarded RHS be dependent or newline.
guardedrhs :: State -> GuardedRhs NodeInfo -> Printer ()
guardedrhs _ (GuardedRhs _ stmts e) =
  indented 1
           (do prefixedLined
                 ","
                 (map (\p ->
                         do space
                            pretty p)
                      stmts)
               dependOrNewline
                 (write " = ")
                 e
                 (indented 1 .
                  pretty))

-- | I want guarded alts be dependent or newline.
guardedalt :: State -> GuardedAlt NodeInfo -> Printer ()
guardedalt _ (GuardedAlt _ stmts e) =
  indented 1
           (do (prefixedLined
                  ","
                  (map (\p ->
                          do space
                             pretty p)
                       stmts))
               dependOrNewline
                 (write " -> ")
                 e
                 (indented 1 .
                  pretty))

-- | I want unguarded alts be dependent or newline.
unguardedalt :: State -> GuardedAlts NodeInfo -> Printer ()
unguardedalt _ (UnGuardedAlt _ e) =
  dependOrNewline
    (write " -> ")
    e
    (indented 2 .
     pretty)
unguardedalt _ e = prettyNoExt e

-- Do statements need to handle infix expression indentation specially because
-- do x *
--    y
-- is two invalid statements, not one valid infix op.
stmt :: State -> Stmt NodeInfo -> Printer ()
stmt _ (Qualifier _ e@(InfixApp _ a op b)) =
  do col <- fmap (psColumn . snd) (sandbox (write ""))
     infixApp e a op b (Just col)
stmt _ e = prettyNoExt e

-- | Expressions
exp :: State -> Exp NodeInfo -> Printer ()
-- Infix applications will render on one line if possible, otherwise
-- if any of the arguments are not "flat" then that expression is
-- line-separated.
exp _ e@(InfixApp _ a op b) =
  infixApp e a op b Nothing
-- | We try to render everything on a flat line. More than one of the
-- arguments are not flat and it wouldn't be a single liner.
-- If the head is short we depend, otherwise we swing.
exp _ (App _ op a) =
  do orig <- gets psIndentLevel
     dependBind
       (do (short,st) <- isShort f
           put st
           space
           return short)
       (\headIsShort ->
          do let flats = map isFlat args
                 flatish =
                   length (filter not flats) <
                   2
             if (headIsShort && flatish) ||
                all id flats
                then do ((singleLiner,overflow),st) <- sandboxNonOverflowing args
                        if singleLiner && not overflow
                           then put st
                           else multi orig args headIsShort
                else multi orig args headIsShort)
  where (f,args) = flatten op [a]
        flatten :: Exp NodeInfo
                -> [Exp NodeInfo]
                -> (Exp NodeInfo,[Exp NodeInfo])
        flatten (App _ f' a') b =
          flatten f' (a' : b)
        flatten f' as = (f',as)
-- | Lambdas are dependent if they can be.
exp _ (Lambda _ ps b) =
  depend (write "\\")
         (do spaced (map pretty ps)
             dependOrNewline
               (write " -> ")
               b
               (indented 1 .
                pretty))
exp _ (Tuple _ boxed exps) =
  depend (write (case boxed of
                   Unboxed -> "(#"
                   Boxed -> "("))
         (do single <- isSingleLiner p
             underflow <- fmap not (isOverflow p)
             if single && underflow
                then p
                else prefixedLined ","
                                   (map pretty exps)
             write (case boxed of
                      Unboxed -> "#)"
                      Boxed -> ")"))
  where p = commas (map pretty exps)
exp _ (List _ es) =
  do (ok,st) <- sandbox renderFlat
     if ok
        then put st
        else brackets (prefixedLined ","
                                     (map pretty es))
  where renderFlat =
          do line <- gets psLine
             brackets (commas (map pretty es))
             st <- get
             columnLimit <- getColumnLimit
             let overflow = psColumn st > columnLimit
                 single = psLine st == line
             return (not overflow && single)
exp _ e = prettyNoExt e

--------------------------------------------------------------------------------
-- Indentation helpers

-- | Sandbox and render the nodes on multiple lines, returning whether
-- each is a single line.
sandboxSingles :: Pretty ast
               => [ast NodeInfo] -> Printer (Bool,PrintState)
sandboxSingles args =
  sandbox (allM (\(i,arg) ->
                   do when (i /= (0::Int)) newline
                      line <- gets psLine
                      pretty arg
                      st <- get
                      return (psLine st == line))
                (zip [0 ..] args))

-- | Render multi-line nodes.
multi :: Pretty ast
      => Int64 -> [ast NodeInfo] -> Bool -> Printer ()
multi orig args headIsShort =
  if headIsShort
     then lined (map pretty args)
     else do (allAreSingle,st) <- sandboxSingles args
             if allAreSingle
                then put st
                else do newline
                        indentSpaces <- getIndentSpaces
                        column (orig + indentSpaces)
                               (lined (map pretty args))

-- | Sandbox and render the node on a single line, return whether it's
-- on a single line and whether it's overflowing.
sandboxNonOverflowing :: Pretty ast
                      => [ast NodeInfo] -> Printer ((Bool,Bool),PrintState)
sandboxNonOverflowing args =
  sandbox (do line <- gets psLine
              columnLimit <- getColumnLimit
              singleLineRender
              st <- get
              return (psLine st == line,psColumn st > columnLimit + 20))
  where singleLineRender =
          spaced (map pretty args)

--------------------------------------------------------------------------------
-- Predicates

-- | Is the expression "short"? Used for app heads.
isShort :: (Pretty ast)
        => ast NodeInfo -> Printer (Bool,PrintState)
isShort p =
  do line <- gets psLine
     orig <- fmap (psColumn . snd) (sandbox (write ""))
     (_,st) <- sandbox (pretty p)
     return (psLine st == line &&
             (psColumn st < orig + shortName),st)

-- | Is the given expression "small"? I.e. does it fit on one line and
-- under 'smallColumnLimit' columns.
isSmall :: MonadState PrintState m
        => m a -> m (Bool,PrintState)
isSmall p =
  do line <- gets psLine
     (_,st) <- sandbox p
     return (psLine st == line && psColumn st < smallColumnLimit,st)

-- | Is an expression flat?
isFlat :: Exp NodeInfo -> Bool
isFlat (Lambda _ _ e) = isFlat e
isFlat (App _ a b) =
  isName a && isName b
  where isName (Var{}) = True
        isName _ = False
isFlat (InfixApp _ a _ b) =
  isFlat a && isFlat b
isFlat (NegApp _ a) = isFlat a
isFlat VarQuote{} = True
isFlat TypQuote{} = True
isFlat (List _ []) = True
isFlat Var{} = True
isFlat Lit{} = True
isFlat Con{} = True
isFlat (LeftSection _ e _) = isFlat e
isFlat (RightSection _ _ e) = isFlat e
isFlat _ = False

-- | Does printing the given thing overflow column limit? (e.g. 80)
isOverflow :: Printer a -> Printer Bool
isOverflow p =
  do (_,st) <- sandbox p
     columnLimit <- getColumnLimit
     return (psColumn st > columnLimit)

-- | Does printing the given thing overflow column limit? (e.g. 80)
isOverflowMax :: Printer a -> Printer Bool
isOverflowMax p =
  do (_,st) <- sandbox p
     columnLimit <- getColumnLimit
     return (psColumn st > columnLimit + 20)

-- | Is the given expression a single-liner when printed?
isSingleLiner :: MonadState PrintState m
              => m a -> m Bool
isSingleLiner p =
  do line <- gets psLine
     (_,st) <- sandbox p
     return (psLine st == line)

--------------------------------------------------------------------------------
-- Helpers

infixApp :: (Pretty ast,Pretty ast1,Pretty ast2)
         => Exp NodeInfo
         -> ast NodeInfo
         -> ast1 NodeInfo
         -> ast2 NodeInfo
         -> Maybe Int64
         -> Printer ()
infixApp e a op b indent =
  do let is = isFlat e
     overflow <- isOverflow
                   (depend (do pretty a
                               space
                               pretty op
                               space)
                           (do pretty b))
     if is && not overflow
        then do depend (do pretty a
                           space
                           pretty op
                           space)
                       (do pretty b)
        else do pretty a
                space
                pretty op
                newline
                case indent of
                  Nothing -> pretty b
                  Just col ->
                    do indentSpaces <- getIndentSpaces
                       column (col + indentSpaces)
                              (pretty b)

-- | Make the right hand side dependent if it's flat, otherwise
-- newline it.
dependOrNewline :: Printer ()
                -> Exp NodeInfo
                -> (Exp NodeInfo -> Printer ())
                -> Printer ()
dependOrNewline left right f =
  do if isFlat right
        then renderDependent
        else do (small,st) <- isSmall renderDependent
                if small
                   then put st
                   else do left
                           newline
                           (f right)
  where renderDependent = depend left (f right)
