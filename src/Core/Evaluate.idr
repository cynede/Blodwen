module Core.Evaluate

import Core.TT
import Core.Context
import Core.CaseTree

import Control.Monad.State
import Data.List

%default covering -- total is hard here, because the things we're evaluating
                  -- might not themselves terminate, but covering is important.
-- TODO/Question: Use a partiality monad instead, or can we capture the
-- partiality with ST?

mutual
  public export
  data LocalEnv : List Name -> List Name -> Type where
       Nil  : LocalEnv outer []
       (::) : Closure outer -> LocalEnv outer vars -> LocalEnv outer (x :: vars)

  public export
  data Closure : List Name -> Type where
       MkClosure : LocalEnv outer vars -> 
                   Env Term outer ->
                   Term (vars ++ outer) -> Closure outer

export
toClosure : Env Term outer -> Term outer -> Closure outer
toClosure env tm = MkClosure [] env tm

%name LocalEnv loc, loc1
%name Closure thunk, thunk1

-- Things you can apply arguments to
public export
data VHead : List Name -> Type where
     VLocal   : Elem x vars -> VHead vars
     VRef     : NameType -> Name -> VHead vars

-- Weak head normal forms
public export
data Value : List Name -> Type where
     VBind    : (x : Name) -> Binder (Closure vars) -> 
                (Closure vars -> Closure vars) -> Value vars
     VApp     : VHead vars -> List (Closure vars) -> Value vars
     VDCon    : Name -> (tag : Int) -> (arity : Nat) -> 
                List (Closure vars) -> Value vars
     VTCon    : Name -> (tag : Int) -> (arity : Nat) -> 
                List (Closure vars) -> Value vars
     VPrimVal : Constant -> Value vars
     VErased  : Value vars
     VType    : Value vars

%name Evaluate.Value val, val1

Stack : List Name -> Type
Stack outer = List (Closure outer)

parameters (gam : Gamma)
  mutual
    evalLocal : Env Term outer ->
                LocalEnv outer vars -> Stack outer -> 
                Elem x (vars ++ outer) -> 
                Value outer
    evalLocal {vars = []} env loc stk p 
          = case getBinder p env of
                 Let val ty => eval env [] stk val
                 b => VApp (VLocal p) []
    evalLocal {vars = (x :: xs)} 
              env ((MkClosure loc' env' tm') :: locs) stk Here 
                   = eval env' loc' stk tm'
    evalLocal {vars = (x :: xs)} env (_ :: loc) stk (There later) 
                   = evalLocal env loc stk later

    -- Take arguments from the stack, as long as there's enough.
    -- Returns the arguments, and the rest of the stack
    takeFromStack : (arity : Nat) -> Stack outer ->
                    Maybe (List (Closure outer), Stack outer)
    takeFromStack arity stk = takeStk arity stk []
      where
        takeStk : (remain : Nat) -> Stack outer -> 
                  List (Closure outer) -> 
                  Maybe (List (Closure outer), Stack outer)
        takeStk Z stk acc = Just (reverse acc, stk)
        takeStk (S k) [] acc = Nothing
        takeStk (S k) (arg :: stk) acc = takeStk k stk (arg :: acc)

    extendFromStack : (args : List Name) -> 
                      LocalEnv outer vars -> Stack outer ->
                      Maybe (LocalEnv outer (args ++ vars), Stack outer)
    extendFromStack [] loc stk = Just (loc, stk)
    extendFromStack (n :: ns) loc [] = Nothing
    extendFromStack (n :: ns) loc (arg :: args) 
         = do (loc', stk') <- extendFromStack ns loc args
              pure (arg :: loc', stk')

    getCaseBound : List (Closure outer) ->
                   (args : List Name) ->
                   LocalEnv outer vars ->
                   Maybe (LocalEnv outer (args ++ vars))
    getCaseBound [] [] loc = Just loc
    getCaseBound [] (x :: xs) loc = Nothing -- mismatched arg length
    getCaseBound (arg :: args) [] loc = Nothing -- mismatched arg length
    getCaseBound (arg :: args) (n :: ns) loc 
         = do loc' <- getCaseBound args ns loc
              pure (arg :: loc')

    tryAlt : Env Term outer ->
             LocalEnv outer (more ++ vars) ->
             Stack outer -> Value outer -> CaseAlt more ->
             Maybe (Value outer)
    tryAlt {more} {vars} env loc stk (VDCon nm tag' arity args') (ConCase x tag args sc) 
         = if tag == tag'
              then do bound <- getCaseBound args' args loc
                      let loc' : LocalEnv _ ((args ++ more) ++ vars) 
                          = rewrite sym (appendAssociative args more vars) in
                                    bound
                      evalTree env loc' stk sc
              else Nothing
    tryAlt env loc stk (VPrimVal c') (ConstCase c sc) 
         = if c == c' then evalTree env loc stk sc
                      else Nothing
    tryAlt env loc stk val (DefaultCase sc) = evalTree env loc stk sc
    tryAlt _ _ _ _ _ = Nothing

    findAlt : Env Term outer ->
              LocalEnv outer (args ++ vars) ->
              Stack outer -> Value outer -> List (CaseAlt args) ->
              Maybe (Value outer)
    findAlt env loc stk val [] = Nothing
    findAlt env loc stk val (x :: xs) 
         = case tryAlt env loc stk val x of
                Nothing => findAlt env loc stk val xs
                res => res

    evalTree : Env Term outer ->
               LocalEnv outer (args ++ vars) -> Stack outer -> 
               CaseTree args ->
               Maybe (Value outer)
    evalTree {args} {vars} {outer} env loc stk (Case x alts) 
      = let x' : List.Elem _ ((args ++ vars) ++ outer) 
               = rewrite sym (appendAssociative args vars outer) in
                         elemExtend x
            xval = evalLocal env loc stk x' in
                   findAlt env loc stk xval alts
    evalTree {args} {vars} {outer} env loc stk (STerm tm) 
          = let tm' : Term ((args ++ vars) ++ outer) 
                    = rewrite sym (appendAssociative args vars outer) in
                              embed tm in
            Just (eval env loc stk tm')
    evalTree env loc stk (Unmatched msg) = Nothing
    evalTree env loc stk Impossible = Nothing

    eval : Env Term outer -> LocalEnv outer vars -> Stack outer -> 
           Term (vars ++ outer) -> Value outer
    eval env loc stk (Local p) = evalLocal env loc stk p
    eval env loc stk (Ref nt fn) 
         = case lookupDef fn gam of
                Just (PMDef args tree) => 
                    case extendFromStack args loc stk of
                         Nothing => VApp (VRef nt fn) stk
                         Just (loc', stk') => 
                              case evalTree env loc' stk' tree of
                                   Nothing => VApp (VRef nt fn) stk
                                   Just val => val
                Just (DCon tag arity) => 
                    case takeFromStack arity stk of
                         Nothing => VApp (VRef nt fn) stk
                         Just (args, stk') => VDCon fn tag arity (args ++ stk')
                Just (TCon tag arity _) =>
                    case takeFromStack arity stk of
                         Nothing => VApp (VRef nt fn) stk
                         Just (args, stk') => VTCon fn tag arity (args ++ stk')
                _ => VApp (VRef nt fn) stk
    eval env loc (closure :: stk) (Bind x (Lam ty) tm) 
         = eval env (closure :: loc) stk tm
    eval env loc stk (Bind x (Let val ty) tm)
         = eval env (MkClosure loc env val :: loc) stk tm

    -- If stk is not empty, this won't have been well typed, since we can't
    -- apply binders to arguments when those binders are values
    eval {outer} {vars} env loc stk (Bind x b tm) 
         = VBind x (map (MkClosure loc env) b)
                   (\arg => MkClosure (arg :: loc) env tm)

    eval env loc stk (App fn arg) 
         = eval env loc (MkClosure loc env arg :: stk) fn
    -- If stk is not empty, this won't have been well typed, since we can't
    -- apply primitives to arguments
    eval env loc stk (PrimVal x) = VPrimVal x
    eval env loc stk Erased = VErased
    eval env loc stk TType = VType

export
whnf : Gamma -> Env Term outer -> Term outer -> Value outer
whnf gam env tm = eval gam env [] [] tm

export
evalClosure : Gamma -> Closure vars -> Value vars
evalClosure gam (MkClosure loc env tm) = eval gam env loc [] tm

export
getValArity : Gamma -> Env Term vars -> Value vars -> Nat
getValArity gam env (VBind x (Pi _ _) sc) 
    = S (getValArity gam env (evalClosure gam (sc (MkClosure [] env Erased))))
getValArity gam env val = 0

export
getArity : Gamma -> Env Term vars -> Term vars -> Nat
getArity gam env tm = getValArity gam env (whnf gam env tm)

public export
interface Convert (tm : List Name -> Type) where
  convert : Gamma -> Env Term vars -> tm vars -> tm vars -> Bool
  convGen : Gamma -> Env Term vars -> tm vars -> tm vars -> State Int Bool

  convert gam env tm tm' = evalState (convGen gam env tm tm') 0
  
genName : String -> State Int Name
genName root 
    = do n <- get
         put (n + 1)
         pure (MN root n)

public export
interface Quote (tm : List Name -> Type) where
  quote : Env Term vars -> tm vars -> Term vars
  quoteGen : Env Term vars -> tm vars -> State Int (Term vars)

  quote env tm = evalState (quoteGen env tm) 0

mutual
  quoteBinder : Env Term vars -> Binder (Closure vars) -> 
                State Int (Binder (Term vars))
  quoteBinder env (Lam ty) 
      = do ty' <- quoteGen env ty
           pure (Lam ty')
  quoteBinder env (Let val ty) 
      = do val' <- quoteGen env val
           ty' <- quoteGen env ty
           pure (Let val' ty')
  quoteBinder env (Pi x ty) 
      = do ty' <- quoteGen env ty
           pure (Pi x ty')
  quoteBinder env (PVar ty) 
      = do ty' <- quoteGen env ty
           pure (PVar ty')
  quoteBinder env (PVTy ty) 
      = do ty' <- quoteGen env ty
           pure (PVTy ty')

  Quote VHead where
    quoteGen env (VLocal prf) = pure $ Local prf
    quoteGen env (VRef t fn) = pure $ Ref t fn

  Quote Value where
    quoteGen env (VBind x b sc) 
          = do var <- genName "quoteVar"
               sc' <- quoteGen env (sc (toClosure env (Ref Bound var)))
               b' <- quoteBinder env b
               pure (Bind x b' (refToLocal var x sc'))
    quoteGen env (VApp val thunks) 
        = do val' <- quoteGen env val
             thunks' <- traverse (quoteGen env) thunks
             pure (apply val' thunks')
    quoteGen env (VPrimVal x) = pure $ PrimVal x
    quoteGen env (VDCon x tag arity xs) 
        = do xs' <- traverse (quoteGen env) xs
             pure (apply (Ref (DataCon tag arity) x) xs')
    quoteGen env (VTCon x tag arity xs) 
        = do xs' <- traverse (quoteGen env) xs
             pure (apply (Ref (TyCon tag arity) x) xs')
    quoteGen env VErased = pure Erased
    quoteGen env VType = pure TType

  export 
  Quote Closure where
    quoteGen env (MkClosure [] x tm) = pure tm
    quoteGen env thunk = quoteGen env (evalClosure empty thunk)

  export
  Quote Term where
    quoteGen env tm = pure tm

mutual
  allConv : Gamma -> Env Term vars ->
            List (Closure vars) -> List (Closure vars) -> State Int Bool
  allConv gam env [] [] = pure True
  allConv gam env (x :: xs) (y :: ys) 
      = pure $ !(convGen gam env x y) && !(allConv gam env xs ys)
  allConv gam env _ _ = pure False

  chkConvHead : Gamma -> Env Term vars ->
                VHead vars -> VHead vars -> State Int Bool 
  chkConvHead gam env (VLocal x) (VLocal y) = pure $ sameVar x y
  chkConvHead gam env (VRef x y) (VRef x' y') = pure $ y == y'
  chkConvHead gam env x y = pure False

  chkConv : Gamma -> Env Term vars -> 
            Value vars -> Value vars -> State Int Bool 
  chkConv gam env (VBind x b scope) (VBind x' b' scope') 
      = do var <- genName "convVar"
           let c = MkClosure [] env (Ref Bound var)
           convGen gam env (scope c) (scope' c)
  chkConv gam env (VApp val args) (VApp val' args')
      = pure $ !(chkConvHead gam env val val') 
                 && !(allConv gam env args args')
  chkConv gam env (VPrimVal x) (VPrimVal y) = pure $ x == y
  chkConv gam env (VDCon _ tag _ xs) (VDCon _ tag' _ xs') 
      = pure $ (tag == tag' && !(allConv gam env xs xs'))
  chkConv gam env (VTCon _ tag _ xs) (VTCon _ tag' _ xs')
      = pure $ (tag == tag' && !(allConv gam env xs xs'))
  chkConv gam env VErased _ = pure True
  chkConv gam env _ VErased = pure True
  chkConv gam env VType VType = pure True
  chkConv gam env x y = pure False

  export
  Convert Value where
    convGen = chkConv

  export
  Convert Term where
    convGen gam env x y = convGen gam env (whnf gam env x) (whnf gam env y)

  export
  Convert Closure where
    convGen gam env thunk thunk'
        = convGen gam env (evalClosure gam thunk)
                          (evalClosure gam thunk')

