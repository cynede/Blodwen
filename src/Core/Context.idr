module Core.Context

import Core.CaseTree
import public Core.Core
import Core.TT
import Core.TTC
import Core.Options

import Utils.Binary

import public Control.Catchable

import Data.CMap
import Data.StringMap
import Data.CSet
import Data.List
import Data.Vect

%default total

public export
record Context a where
     constructor MkContext 
     -- for looking up by exact (completely qualified) names
     exactNames : SortedMap a 
     -- for looking up by name root or partially qualified (so possibly
     -- ambiguous) names. This doesn't store machine generated names.
     hierarchy : StringMap (List (Name, a))
     -- Namespaces which are visible (i.e. have been imported)
     -- This only matters during evaluation and type checking, to control
     -- access in a program - in all other cases, we'll assume everything is
     -- visible
     visibleNS : List (List String)

export
empty : Context a
empty = MkContext empty empty []

export
lookupCtxtExact : Name -> Context a -> Maybe a
lookupCtxtExact n dict = lookup n (exactNames dict)

export
lookupCtxtName : Name -> Context a -> List (Name, a)
lookupCtxtName n dict
    = case userNameRoot n of
           Nothing => case lookupCtxtExact n dict of
                           Nothing => []
                           Just res => [(n, res)]
           Just r => case lookup r (hierarchy dict) of
                          Nothing => []
                          Just ns => filter (matches n) ns
	where
		-- Name matches if a prefix of the namespace matches a prefix of the 
    -- namespace in the context
    matches : Name -> (Name, a) -> Bool
    matches (NS ns _) (NS cns _, _) = ns `isPrefixOf` cns
    matches (NS _ _) _ = True -- no in library name, so root doesn't match
    matches _ _ = True -- no prefix, so root must match, so good

export
lookupCtxt : Name -> Context a -> List a
lookupCtxt n dict = map snd (lookupCtxtName n dict)

addToHier : Name -> a -> 
						StringMap (List (Name, a)) -> StringMap (List (Name, a))
addToHier n val hier
     -- Only add user defined names. Machine generated names can only be
		 -- found with the exactNames
     = case userNameRoot n of
            Nothing => hier
            Just root =>
                 case lookup root hier of
                      Nothing => insert root [(n, val)] hier
                      Just ns => insert root (update val ns) hier
  where
    update : a -> List (Name, a) -> List (Name, a)
    update val [] = [(n, val)]
    update val (old :: xs) 
		    = if n == fst old 
					   then (n, val) :: xs
						 else old :: update val xs

export
addCtxt : Name -> a -> Context a -> Context a
addCtxt n val (MkContext dict hier vis) 
     = let dict' = insert n val dict
           hier' = addToHier n val hier in
           MkContext dict' hier' vis

-- Merge two contexts, with entries in the second overriding entries in
-- the first
mergeContext : Context a -> Context a -> Context a
mergeContext ctxt (MkContext exact hier vis)
    = record { visibleNS $= (vis ++) } (insertFrom (toList exact) ctxt)
  where
    insertFrom : List (Name, a) -> Context a -> Context a
    insertFrom [] ctxt = ctxt
    insertFrom ((n, val) :: cs) ctxt
        = insertFrom cs (addCtxt n val ctxt)

mergeContextAs : List String -> List String ->
                 Context a -> Context a -> Context a
mergeContextAs oldns newns ctxt (MkContext exact hier vis)
    = record { visibleNS $= (vis ++) } (insertFrom (toList exact) ctxt)
  where
    insertFrom : List (Name, a) -> Context a -> Context a
    insertFrom [] ctxt = ctxt
    insertFrom ((n, val) :: cs) ctxt
        = insertFrom cs (addCtxt n val ctxt)

export
fromList : List (Name, a) -> Context a
fromList [] = empty
fromList ((n, val) :: rest) = addCtxt n val (fromList rest)

export
toList : Context a -> List (Name, a)
toList = toList . exactNames

export
TTC annot a => TTC annot (Context a) where
  toBuf b ctxt = toBuf b (toList (exactNames ctxt))
  fromBuf s b
      = do xs <- fromBuf s b
           pure (fromList xs)

public export
data Def : Type where
     None  : Def -- Not yet defined
     PMDef : (ishole : Bool) -> (args : List Name) -> CaseTree args -> Def
     Builtin : PrimFn arity -> Def
     DCon  : (tag : Int) -> (arity : Nat) -> 
						 (forcedpos : List Nat) -> -- argument positions whose value is
			                         -- forced by the constructors type
			       Def
     TCon  : (tag : Int) -> (arity : Nat) -> 
						 (parampos : List Nat) -> -- argument positions which are parametric
						 (datacons : List Name) -> 
			       Def
     Hole : (numlocs : Nat) -> (pvar : Bool) -> Def 
		           -- Unsolved hole, under 'numlocs' locals, and whether it
						   -- is standing for a pattern variable (and therefore mustn't
							 -- be solved)
     BySearch : Nat -> Def -- Undefined name, to be defined by proof search
                    -- e.g. auto implicit or interface implementation
     ImpBind : Def -- Hole turned into an implicitly bound variable
                   -- (which will be deleted after elaboration)
     -- The constraint names refer into a context of constraints,
     -- defined in Core.UnifyState
     Guess : (guess : ClosedTerm) -> (constraints : List Name) -> Def
     -- A delayed elaboration. Name refers into a context of delayed
     -- elaborators in Core.UnifyState
     Delayed : Name -> Def

export
Show Def where
  show None = "No definition"
  show (PMDef hole args tree) 
      = showHole hole ++"; " ++ show args ++ ";" ++ show tree
    where
      showHole : Bool -> String
      showHole h = if h then "Solved hole" else "Def"
  show (Builtin {arity} f)
      = "<<builtin with " ++ show arity ++ " arguments>>"
  show (TCon tag arity params cons)
	    = "TyCon " ++ show tag ++ "; arity " ++ show arity ++ "; params " ++
        show params ++ "; constructors " ++ show cons
  show (DCon tag arity forced)
      = "DataCon " ++ show tag ++ "; arity " ++ show arity ++ 
        "; forced positions " ++ show forced
  show (Hole locs False)
      = "Hole with " ++ show locs ++ " locals"
  show (Hole locs True)
      = "Pattern variable with " ++ show locs ++ " locals"
  show (BySearch n)
      = "Search with depth " ++ show n
  show ImpBind = "Implicitly bound name"
  show (Guess g cons) = "Guess " ++ show g ++ " with constraints " ++ show cons
  show (Delayed n) = "Delayed " ++ show n

TTC annot Def where
  toBuf b None = tag 0
  toBuf b (PMDef ishole args sc) 
      = do tag 1; toBuf b ishole; toBuf b args; toBuf b sc
  toBuf b (Builtin _)
      = throw (InternalError "Trying to serialise a Builtin")
  toBuf b (DCon t arity forcedpos) 
      = do tag 2; toBuf b t; toBuf b arity; toBuf b forcedpos
  toBuf b (TCon t arity parampos datacons) 
      = do tag 3; toBuf b t; toBuf b arity; toBuf b parampos; toBuf b datacons
  toBuf b (Hole numlocs pvar) 
      = do tag 4; toBuf b numlocs; toBuf b pvar
  toBuf b (BySearch k) 
      = do tag 5; toBuf b k
  toBuf b ImpBind = tag 6
  toBuf b (Guess guess constraints) 
      = do tag 7; toBuf b guess; toBuf b constraints
  toBuf b (Delayed n)
      = throw (InternalError "Trying to serialise a Delayed elaborator")

  fromBuf s b 
      = case !getTag of
             0 => pure None
             1 => do x <- fromBuf s b; y <- fromBuf s b; z <- fromBuf s b
                     pure (PMDef x y z)
             2 => do x <- fromBuf s b; y <- fromBuf s b; z <- fromBuf s b
                     pure (DCon x y z)
             3 => do w <- fromBuf s b; x <- fromBuf s b; y <- fromBuf s b; z <- fromBuf s b
                     pure (TCon w x y z)
             4 => do x <- fromBuf s b; y <- fromBuf s b
                     pure (Hole x y)
             5 => do x <- fromBuf s b
                     pure (BySearch x)
             6 => pure ImpBind
             7 => do x <- fromBuf s b; y <- fromBuf s b
                     pure (Guess x y)
             _ => corrupt "Def"

public export
data DefFlag = TypeHint Name | GlobalHint | Inline

export
Eq DefFlag where
    (==) (TypeHint ty) (TypeHint ty') = ty == ty'
    (==) GlobalHint GlobalHint = True
    (==) Inline Inline = True
    (==) _ _ = False

TTC annot DefFlag where
  toBuf b (TypeHint x) = do tag 0; toBuf b x
  toBuf b GlobalHint = tag 1
  toBuf b Inline = tag 2

  fromBuf s b 
      = case !getTag of
             0 => do x <- fromBuf s b; pure (TypeHint x)
             1 => pure GlobalHint
             2 => pure Inline
             _ => corrupt "DefFlag"

-- *everything* about a definition goes here, so that we can save out the
-- type checked code "simply" by writing out a list of GlobalDefs
public export
record GlobalDef where
     constructor MkGlobalDef
     type : ClosedTerm
     visibility : Visibility
     totality : Totality
     flags : List DefFlag
     definition : Def
     refersTo : List Name

TTC annot GlobalDef where
  toBuf b def
      = do toBuf b (type def)
           toBuf b (visibility def)
           toBuf b (totality def)
           toBuf b (flags def)
           toBuf b (definition def)
           toBuf b (refersTo def)

  fromBuf s b
      = do ty <- fromBuf s b
           vis <- fromBuf s b
           tot <- fromBuf s b
           flgs <- fromBuf s b
           def <- fromBuf s b
           ref <- fromBuf s b
           pure (MkGlobalDef ty vis tot flgs def ref)

getRefs : Def -> List Name
getRefs None = []
getRefs (PMDef ishole args sc) = getRefs sc
getRefs (Builtin _) = []
getRefs (DCon tag arity forced) = []
getRefs (TCon tag arity params datacons) = []
getRefs (Hole numlocs _) = []
getRefs (BySearch _) = []
getRefs ImpBind = []
getRefs (Guess guess constraints) = CSet.toList (getRefs guess)
getRefs (Delayed n) = []

export
newDef : (ty : ClosedTerm) -> (vis : Visibility) -> Def -> GlobalDef
newDef ty vis def = MkGlobalDef ty vis Unchecked [] def (getRefs def)

-- A context of global definitions
public export
Gamma : Type
Gamma = Context GlobalDef

-- Everything needed to typecheck data types/functions
public export
record Defs where
      constructor MkAllDefs
      gamma : Gamma -- All the definitions
      moduleNS : List String -- namespace for the current input file
      currentNS : List String -- namespace for current definitions
      options : Options
      toSave : SortedSet -- Definitions to write out as .tti
      imported : List (List String, Bool, List String) 
          -- imported modules, to rexport, as namespace
      allImported : List (String, List String)
          -- all imported filenames/namespaces, just to avoid loading something
          -- twice unnecessarily (this is a record of all the things we've
          -- called 'readFromTTC' with, in practice)
      autoHints : List Name -- global auto hints
      typeHints : Context (List Name) -- type name hints
      nextTag : Int -- next tag for type constructors
      nextHole : Int -- next hole/constraint id
      nextVar	: Int

export
noGam : Defs -> Defs
noGam = record { gamma = empty }

-- Just write out what's in "gamma", the relevant options, and the imported
-- modules
-- Everything else is either reconstructed from that, or not used when reading
-- from a file
export
TTC annot Defs where
  toBuf b val 
      = do toBuf b (CMap.toList (exactNames (gamma val)))
           toBuf b (imported val)
           toBuf b (laziness (options val))
  fromBuf s b 
      = do ns <- fromBuf s b {a = List (Name, GlobalDef)}
           imported <- fromBuf s b
           lazy <- fromBuf s b
           pure (MkAllDefs (insertFrom ns empty) [] [] 
                            (record { laziness = lazy } defaults)
                            empty imported [] [] empty 100 0 0)
    where
      insertFrom : List (Name, GlobalDef) -> Gamma -> Gamma
      insertFrom [] ctxt = ctxt
      insertFrom ((n, val) :: cs) ctxt
          = insertFrom cs (addCtxt n val ctxt)

export
initCtxt : Defs
initCtxt = MkAllDefs empty ["Main"] ["Main"] defaults empty [] [] [] empty 100 0 0

export
getSave : Defs -> List Name
getSave = toList . toSave

export
lookupGlobalExact : Name -> Gamma -> Maybe GlobalDef
lookupGlobalExact n gam = lookupCtxtExact n gam

export
lookupGlobalName : Name -> Gamma -> List (Name, GlobalDef)
lookupGlobalName n gam = lookupCtxtName n gam
    
-- private names are only visible in this namespace if their namespace
-- is the current namespace (or an outer one)
-- that is: given that most recent namespace is first in the list,
-- the namespace of 'n' is a suffix of nspace
export
visibleIn : (nspace : List String) -> Name -> Visibility -> Bool
visibleIn nspace (NS ns n) Private = isSuffixOf ns nspace
-- Public and Export names are always visible
visibleIn nspace n _ = True

-- TODO: This also needs to take into account totality, later
export
reducibleIn : (nspace : List String) -> Name -> Visibility -> Bool
reducibleIn nspace (NS ns n) Export = isSuffixOf ns nspace
reducibleIn nspace (NS ns n) Private = isSuffixOf ns nspace
reducibleIn nspace n _ = True

export
lookupDefExact : Name -> Gamma -> Maybe Def
lookupDefExact n gam
    = do def <- lookupGlobalExact n gam
         pure (definition def)

export
lookupDefName : Name -> Gamma -> List (Name, Def)
lookupDefName n gam
    = map (\(x, g) => (x, definition g)) (lookupGlobalName n gam)

export
lookupTyExact : Name -> Gamma -> Maybe ClosedTerm
lookupTyExact n gam 
    = do def <- lookupGlobalExact n gam
         pure (type def)

export
lookupTyName : Name -> Gamma -> List (Name, ClosedTerm)
lookupTyName n gam
    = map (\(x, g) => (x, type g)) (lookupGlobalName n gam)

export
lookupDefTyExact : Name -> Gamma -> Maybe (Def, ClosedTerm)
lookupDefTyExact n gam 
    = do def <- lookupGlobalExact n gam
         pure (definition def, type def)

export
lookupDefTyVisExact : Name -> Gamma -> Maybe (Def, ClosedTerm, Visibility)
lookupDefTyVisExact n gam 
    = do def <- lookupGlobalExact n gam
         pure (definition def, type def, visibility def)

export
lookupDefTyName : Name -> Gamma -> List (Name, Def, ClosedTerm)
lookupDefTyName n gam
    = map (\(x, g) => (x, definition g, type g)) (lookupGlobalName n gam)

export
lookupDefTyNameIn : (nspace : List String) ->
                    Name -> Gamma -> List (Name, Def, ClosedTerm)
lookupDefTyNameIn nspace n gam
    = map (\ (x, d, t, v) => (x, d, t)) $
        filter isVisible $
          map (\ (x, g) => (x, definition g, type g, visibility g)) 
            (lookupGlobalName n gam)
  where
    isVisible : (Name, Def, ClosedTerm, Visibility) -> Bool
    isVisible (n, d, t, v) = visibleIn nspace n v


public export
record Constructor where
  constructor MkCon
  name : Name
  arity : Nat
  type : ClosedTerm

public export
data DataDef : Type where
     MkData : (tycon : Constructor) -> (datacons : List Constructor) ->
              DataDef

public export
data Clause : Type where
     MkClause : (env : Env Term vars) ->
                (lhs : Term vars) -> (rhs : Term vars) -> Clause

public export
data FnDef : Type where
     MkFn : (n : Name) -> (ty : ClosedTerm) -> (clauses : List Clause) ->
            FnDef

-- A label for the context in the global state
export
data Ctxt : Type where

export
getCtxt : {auto c : Ref Ctxt Defs} ->
					Core annot Gamma
getCtxt = pure (gamma !(get Ctxt))

export
isDelayType : Name -> Defs -> Bool
isDelayType n defs
    = case laziness (options defs) of
           Nothing => False
           Just l => n == delayType l

export
isDelay : Name -> Defs -> Bool
isDelay n defs
    = case laziness (options defs) of
           Nothing => False
           Just l => n == delay l

export
isForce : Name -> Defs -> Bool
isForce n defs
    = case laziness (options defs) of
           Nothing => False
           Just l => n == force l

export
delayName : Defs -> Maybe Name
delayName defs
    = do l <- laziness (options defs)
         pure (delay l)

export
forceName : Defs -> Maybe Name
forceName defs
    = do l <- laziness (options defs)
         pure (force l)

export
setVisible : {auto c : Ref Ctxt Defs} -> 
             (nspace : List String) -> Core annot ()
setVisible nspace
    = do defs <- get Ctxt
         put Ctxt (record { gamma->visibleNS $= (nspace ::) } defs)

-- Return True if the given namespace is visible in the context (meaning
-- the namespace itself, and any namespace it's nested inside)
export
isVisible : {auto c : Ref Ctxt Defs} -> 
            (nspace : List String) -> Core annot Bool
isVisible nspace
    = do defs <- get Ctxt
         pure (any visible (allParents (currentNS defs) ++ visibleNS (gamma defs)))
  where
    allParents : List String -> List (List String)
    allParents [] = []
    allParents (n :: ns) = (n :: ns) :: allParents ns

    -- Visible if any visible namespace is a suffix of the namespace we're
    -- asking about
    visible : List String -> Bool
    visible visns = isSuffixOf visns nspace

export
checkUnambig : {auto c : Ref Ctxt Defs} ->
               annot -> Name -> Core annot Name
checkUnambig loc n
    = do defs <- get Ctxt
         case lookupDefName n (gamma defs) of
              [] => throw (UndefinedName loc n)
              [(fulln, _)] => pure fulln
              ns => throw (AmbiguousName loc (map fst ns))

export
setLazy : {auto c : Ref Ctxt Defs} ->
          annot -> (delayType : Name) -> (delay : Name) -> (force : Name) ->
          Core annot ()
setLazy loc ty d f
    = do defs <- get Ctxt
         ty' <- checkUnambig loc ty
         d' <- checkUnambig loc d
         f' <- checkUnambig loc f
         put Ctxt (record { options $= setLazy ty' d' f' } defs)

export
getDirs : {auto c : Ref Ctxt Defs} -> Core annot Dirs
getDirs
    = do defs <- get Ctxt
         pure (dirs (options defs))

-- Extend the context with the definitions/options given in the second
-- New options override current ones
export
extend : {auto c : Ref Ctxt Defs} ->
         Defs -> Core annot ()
extend new
    = do ctxt <- get Ctxt
         put Ctxt (record { gamma $= mergeContext (gamma new),
                            options $= mergeOptions (options new) } ctxt)

export
extendAs : {auto c : Ref Ctxt Defs} ->
           List String -> List String -> 
           Defs -> Core annot ()
extendAs modNS importAs new
    = if modNS == importAs 
         then extend new
         else do ctxt <- get Ctxt
                 put Ctxt (record { gamma $= mergeContextAs modNS importAs (gamma new),
                                    options $= mergeOptions (options new) } ctxt)

-- Set the default namespace for new definitions
export
setNS : {auto c : Ref Ctxt Defs} ->
        List String -> Core annot ()
setNS ns
    = do defs <- get Ctxt
         put Ctxt (record { currentNS = ns } defs)

-- Get the default namespace for new definitions
export
getNS : {auto c : Ref Ctxt Defs} ->
        Core annot (List String)
getNS 
    = do defs <- get Ctxt
         pure (currentNS defs)

-- Add the module name, and namespace, of an imported module
-- (i.e. for "import X as Y", it's (X, Y)
-- "import public X" is, when rexported, the same as 
-- "import X as [current namespace]")
export
addImported : {auto c : Ref Ctxt Defs} ->
              (List String, Bool, List String) -> Core annot ()
addImported mod
    = do defs <- get Ctxt
         put Ctxt (record { imported $= (mod ::) } defs)

export
getImported : {auto c : Ref Ctxt Defs} -> 
              Core annot (List (List String, Bool, List String))
getImported
    = do defs <- get Ctxt
         pure (imported defs)

-- Add a new nested namespace to the current namespace for new definitions
-- e.g. extendNS ["Data"] when namespace is "Prelude.List" leads to
-- current namespace of "Prelude.List.Data"
-- Inner namespaces go first, for ease of name lookup
export
extendNS : {auto c : Ref Ctxt Defs} ->
           List String -> Core annot ()
extendNS ns
    = do defs <- get Ctxt
         put Ctxt (record { currentNS $= ((reverse ns) ++) } defs)

-- Get the name as it would be defined in the current namespace
-- i.e. if it doesn't have an explicit namespace already, add it,
-- otherwise leave it alone
export
inCurrentNS : {auto c : Ref Ctxt Defs} ->
              Name -> Core annot Name
inCurrentNS (UN n)
    = do defs <- get Ctxt
         pure (NS (currentNS defs) (UN n))
inCurrentNS n@(MN _ _)
    = do defs <- get Ctxt
         pure (NS (currentNS defs) n)
inCurrentNS n = pure n

-- Note that the name should be saved when writing out a .ttc
export
addToSave : {auto c : Ref Ctxt Defs} ->
            Name -> Core annot ()
addToSave n
    = do defs <- get Ctxt
         put Ctxt (record { toSave $= insert n } defs)

-- Clear the names to save when writing out a .tti
export
clearToSave : {auto c : Ref Ctxt Defs} ->
              Core annot ()
clearToSave
    = do defs <- get Ctxt
         put Ctxt (record { toSave = empty } defs)

export
getNextTypeTag : {auto x : Ref Ctxt Defs} ->
								 Core annot Int
getNextTypeTag
    = do defs <- get Ctxt
         let t = nextTag defs
         put Ctxt (record { nextTag = t + 1 } defs)
         pure t

export
getNextHole : {auto x : Ref Ctxt Defs} -> Core annot Int
getNextHole
    = do defs <- get Ctxt
         let t = nextHole defs
         put Ctxt (record { nextHole = t + 1 } defs)
         pure t

export
genName : {auto x : Ref Ctxt Defs} ->
					String -> Core annot Name
genName root
    = do ust <- get Ctxt
         put Ctxt (record { nextVar $= (+1) } ust)
         inCurrentNS (MN root (nextVar ust))

export
genCaseName : {auto x : Ref Ctxt Defs} ->
			     		Name -> Core annot Name
genCaseName root
    = do ust <- get Ctxt
         put Ctxt (record { nextVar $= (+1) } ust)
         pure (GN (CaseBlock root (nextVar ust)))

export
genWithName : {auto x : Ref Ctxt Defs} ->
			     		Name -> Core annot Name
genWithName root
    = do ust <- get Ctxt
         put Ctxt (record { nextVar $= (+1) } ust)
         pure (GN (WithBlock root (nextVar ust)))

export
setCtxt : {auto x : Ref Ctxt Defs} -> Gamma -> Core annot ()
setCtxt gam
    = do st <- get Ctxt
         put Ctxt (record { gamma = gam } st)

export
getDescendents : Name -> Gamma -> List Name
getDescendents n g
    = CSet.toList $ getAllDesc [n] empty g
  where
    getAllDesc : List Name -> SortedSet -> Gamma -> SortedSet
    getAllDesc [] ns g = ns
    getAllDesc (n :: rest) ns g
      = if contains n ns
           then getAllDesc rest ns g
           else case lookupGlobalExact n g of
                     Nothing => ns
                     Just def => assert_total $
											 let refs = refersTo def in
												 getAllDesc (rest ++ refs)
						                        (union ns (fromList refs)) g

export
addDef : {auto x : Ref Ctxt Defs} -> Name -> GlobalDef -> Core annot ()
addDef n def
    = do g <- getCtxt 
         setCtxt (addCtxt n def g)

export
addBuiltin : {auto x : Ref Ctxt Defs} -> 
             Name -> ClosedTerm -> Totality ->
             PrimFn arity -> Core annot ()
addBuiltin n ty tot op 
    = addDef n (MkGlobalDef ty Public tot [] (Builtin op) [])

export
updateDef : {auto x : Ref Ctxt Defs} ->
						Name -> Def -> Core annot ()
updateDef n def 
    = do g <- getCtxt
         case lookupCtxtExact n g of
              Nothing => throw (InternalError ("No such name to update " ++ show n))
              Just odef => 
                   let gdef = record { definition = def,
																		   refersTo = getRefs def } odef in
                       setCtxt (addCtxt n gdef g)
 
export
updateTy : {auto x : Ref Ctxt Defs} ->
						Name -> ClosedTerm -> Core annot ()
updateTy n ty
    = do g <- getCtxt
         case lookupCtxtExact n g of
              Nothing => throw (InternalError ("No such name to update " ++ show n))
              Just odef => 
                   let gdef = record { type = ty } odef in
                       setCtxt (addCtxt n gdef g)
 
export
setFlag : {auto x : Ref Ctxt Defs} ->
					annot -> Name -> DefFlag -> Core annot ()
setFlag loc n fl
    = do ctxt <- getCtxt
         case lookupGlobalExact n ctxt of
              Nothing => throw (UndefinedName loc n)
              Just def =>
                   do let flags' = fl :: filter (/= fl) (flags def)
                      addDef n (record { flags = flags' } def)

export
unsetFlag : {auto x : Ref Ctxt Defs} ->
            annot -> Name -> DefFlag -> Core annot ()
unsetFlag loc n fl
    = do ctxt <- getCtxt
         case lookupGlobalExact n ctxt of
              Nothing => throw (UndefinedName loc n)
              Just def =>
                   do let flags' = filter (/= fl) (flags def)
                      addDef n (record { flags = flags' } def)

export
hasFlag : {auto x : Ref Ctxt Defs} ->
          annot -> Name -> DefFlag -> Core annot Bool
hasFlag loc n fl
    = do ctxt <- getCtxt
         case lookupGlobalExact n ctxt of
              Nothing => throw (UndefinedName loc n)
              Just def => pure (fl `elem` flags def)

export
setTotality : {auto x : Ref Ctxt Defs} ->
              annot -> Name -> Totality -> Core annot ()
setTotality loc n tot
    = do ctxt <- getCtxt
         case lookupGlobalExact n ctxt of
              Nothing => throw (UndefinedName loc n)
              Just def => 
                   addDef n (record { totality = tot } def)

export
getTotality : {auto x : Ref Ctxt Defs} ->
              annot -> Name -> Core annot Totality
getTotality loc n
    = do ctxt <- getCtxt
         case lookupGlobalExact n ctxt of
              Nothing => throw (UndefinedName loc n)
              Just def => pure $ totality def

export
setVisibility : {auto x : Ref Ctxt Defs} ->
                annot -> Name -> Visibility -> Core annot ()
setVisibility loc n vis
    = do ctxt <- getCtxt
         case lookupGlobalExact n ctxt of
              Nothing => throw (UndefinedName loc n)
              Just def => 
                   addDef n (record { visibility = vis } def)

export
getVisibility : {auto x : Ref Ctxt Defs} ->
                annot -> Name -> Core annot Visibility
getVisibility loc n
    = do ctxt <- getCtxt
         case lookupGlobalExact n ctxt of
              Nothing => throw (UndefinedName loc n)
              Just def => pure $ visibility def

export
isTotal : {auto x : Ref Ctxt Defs} ->
          annot -> Name -> Core annot Bool
isTotal loc n
    = do t <- getTotality loc n
         case t of
              Total => pure True
              _ => pure False

-- Check that the names used in the term don't conflict with the visibility
-- of the name. No name in the term, defined in the same namespace,
-- can have lower visibility than the given name and visibility.
export
checkNameVisibility : {auto x : Ref Ctxt Defs} ->
                      annot -> 
                      Name -> Visibility -> Term vars -> Core annot ()
checkNameVisibility loc n vis tm
    = do traverse visible (toList (getRefs tm))
         pure ()
  where
    eqNS : Name -> Name -> Bool
    eqNS (NS xs _) (NS ys _) = xs == ys
    eqNS _ _ = False

    visible : Name -> Core annot ()
    visible ref
        = do defs <- get Ctxt
             case lookupGlobalExact ref (gamma defs) of
                  Just def =>
                       if visibility def < vis && eqNS n ref
                          then throw (VisibilityError loc vis n 
                                            (visibility def) ref)
                          else pure ()
                  Nothing => pure ()

argToPat : ClosedTerm -> Pat
argToPat tm with (unapply tm)
  argToPat (apply (Ref (DataCon tag _) cn) args) | ArgsList 
         = PCon cn tag (assert_total (map argToPat args))
  argToPat (apply (Ref _ var) []) | ArgsList = PVar var
  argToPat (apply (PrimVal c) []) | ArgsList = PConst c
  argToPat (apply f args) | ArgsList = PAny

toPatClause : {auto x : Ref Ctxt Defs} ->
							annot -> Name -> (ClosedTerm, ClosedTerm) ->
              Core annot (List Pat, ClosedTerm)
toPatClause loc n (lhs, rhs) with (unapply lhs)
  toPatClause loc n (apply (Ref Func fn) args, rhs) | ArgsList 
      = case nameEq n fn of
             Nothing => throw (GenericMsg loc ("Wrong function name in pattern LHS " ++ show (n, fn)))
             Just Refl => do -- putStrLn $ "Clause: " ++ show (apply (Ref Func fn) args) ++ " = " ++ show rhs
                             pure (map argToPat args, rhs)
  toPatClause loc n (apply f args, rhs) | ArgsList 
      = throw (GenericMsg loc "Not a function name in pattern LHS")

-- Assumption (given 'ClosedTerm') is that the pattern variables are
-- explicitly named. We'll assign de Bruijn indices when we're done, and
-- the names of the top level variables we created are returned in 'args'
export
simpleCase : {auto x : Ref Ctxt Defs} ->
						 annot -> Name -> (def : CaseTree []) ->
             (clauses : List (ClosedTerm, ClosedTerm)) ->
             Core annot (args ** CaseTree args)
simpleCase loc fn def clauses 
    = do ps <- traverse (toPatClause loc fn) clauses
         case patCompile ps def of
              Left err => throw (CaseCompile loc fn err)
              Right ok => pure ok

export
addFnDef : {auto x : Ref Ctxt Defs} ->
					 annot -> Visibility ->
           FnDef -> Core annot ()
addFnDef loc vis (MkFn n ty clauses) 
    = do let cs = map toClosed clauses
         (args ** tree) <- simpleCase loc n (Unmatched "Unmatched case") cs
--          coreLift $ putStrLn $ "Case tree for " ++ show n ++ ": " 
-- 				             ++ show args ++ "\n" ++ show cs ++ "\n" ++ show tree
         let def = newDef ty vis (PMDef False args tree)
         addDef n def
  where
    close : Int -> (plets : Bool) -> Env Term vars -> Term vars -> ClosedTerm
    close i plets [] tm = tm
    close i True (PLet c val ty :: bs) tm 
		    = close (i + 1) True bs (Bind (MN "pat" i) (Let c val ty) (renameTop _ tm))
    close i plets (b :: bs) tm 
        = close (i + 1) plets bs (subst (Ref Bound (MN "pat" i)) tm)

    toClosed : Clause -> (ClosedTerm, ClosedTerm)
    toClosed (MkClause env lhs rhs) 
          = (close 0 False env lhs, close 0 True env rhs)

updateParams : Maybe (List (Maybe (Term vars))) -> 
                  -- arguments to the type constructor which could be
                  -- parameters
                  -- Nothing, as an argument, means this argument can't
                  -- be a parameter position
               List (Term vars) ->
                  -- arguments to an application 
               List (Maybe (Term vars))
updateParams Nothing args = map couldBeParam args
  where
    couldBeParam : Term vars -> Maybe (Term vars)
    couldBeParam (Local v) = Just (Local v)
    couldBeParam _ = Nothing
updateParams (Just args) args' = zipWith mergeArg args args'
  where
    mergeArg : Maybe (Term vars) -> Term vars -> Maybe (Term vars)
    mergeArg (Just (Local x)) (Local y)
        = if sameVar x y then Just (Local x) else Nothing
    mergeArg _ _ = Nothing

getPs : Maybe (List (Maybe (Term vars))) -> Name -> Term vars ->
           Maybe (List (Maybe (Term vars)))
getPs acc tyn (Bind x (Pi _ _ ty) sc)
      = let scPs = getPs (map (map (map weaken)) acc) tyn sc in
            map (map shrink) scPs
  where
    shrink : Maybe (Term (x :: vars)) -> Maybe (Term vars)
    shrink Nothing = Nothing
    shrink (Just tm) = shrinkTerm tm (DropCons SubRefl)
getPs acc tyn tm with (unapply tm)
  getPs acc tyn (apply (Ref _ n) args) | ArgsList 
      = if n == tyn 
           then Just (updateParams acc args)
           else acc
  getPs acc tyn (apply f args) | ArgsList = acc

toPos : Maybe (List (Maybe a)) -> List Nat
toPos Nothing = []
toPos (Just ns) = justPos 0 ns
  where
    justPos : Nat -> List (Maybe a) -> List Nat
    justPos i [] = []
    justPos i (Just x :: xs) = i :: justPos (1 + i) xs
    justPos i (Nothing :: xs) = justPos (1 + i) xs

getConPs : Maybe (List (Maybe (Term vars))) -> Name -> Term vars -> List Nat
getConPs acc tyn (Bind x (Pi _ _ ty) sc) 
    = let bacc = getPs acc tyn ty in
          getConPs (map (map (map weaken)) bacc) tyn sc
getConPs acc tyn tm = toPos (getPs acc tyn tm)
    
combinePos : Eq a => List (List a) -> List a
combinePos [] = []
combinePos (xs :: xss) = filter (\x => all (elem x) xss) xs

paramPos : Name -> (dcons : List ClosedTerm) ->
           List Nat
paramPos tyn dcons = combinePos (map (getConPs Nothing tyn) dcons)

export
addData : {auto x : Ref Ctxt Defs} ->
					Visibility -> DataDef -> Core annot ()
addData vis (MkData (MkCon tyn arity tycon) datacons)
    = do gam <- getCtxt 
         tag <- getNextTypeTag 
         let tydef = newDef tycon vis (TCon tag arity 
                                            (paramPos tyn (map type datacons))
                                            (map name datacons))
         let gam' = addCtxt tyn tydef gam
         setCtxt (addDataConstructors 0 datacons gam')
  where
    conVisibility : Visibility -> Visibility
    conVisibility Export = Private
    conVisibility x = x
    
    findGuarded : AList Nat vars -> Term vars -> List Nat
    findGuarded as tm with (unapply tm)
      findGuarded as (apply (Ref (DataCon _ _) _) args) | ArgsList 
			     = nub $ assert_total (concatMap (findGuarded as) args)
      findGuarded as (apply (Ref (TyCon _ _) _) args) | ArgsList 
			     = nub $ assert_total (concatMap (findGuarded as) args)
      findGuarded as (apply (Local {x} var) []) | ArgsList
	         = [getCorresponding as var]
      findGuarded as (apply f args) | ArgsList 
			     = []

		-- Calculate which argument positions in the type are 'forced'.
		-- An argument is forced if it appears guarded by constructors in one
		-- of the parameters or indices of the constructor's return type
    forcedPos : (pos : Nat) -> AList Nat vars -> Term vars -> List Nat
    forcedPos p as (Bind x (Pi _ _ ty) sc)
        = forcedPos (p + 1) (p :: as) sc
    forcedPos p as tm = findGuarded as tm

    addDataConstructors : (tag : Int) -> 
                          List Constructor -> Gamma -> Gamma
    addDataConstructors tag [] gam = gam
    addDataConstructors tag (MkCon n a ty :: cs) gam
        = do let condef = newDef ty (conVisibility vis) 
						                     (DCon tag a (forcedPos 0 [] ty))
             let gam' = addCtxt n condef gam
             addDataConstructors (tag + 1) cs gam'

export
addToTypeHints : Name -> Name -> Defs -> Defs
addToTypeHints ty hint defs
    = let hs : List Name
             = case lookupCtxtExact ty (typeHints defs) of
                    Nothing => []
                    Just ns => ns in
          record { typeHints $= addCtxt ty (hint :: hs) } defs

export
addHintFor : {auto x : Ref Ctxt Defs} ->
					   annot -> Name -> Name -> Core annot ()
addHintFor loc ty hint
    = do defs <- get Ctxt
         let hs : List Name
                = case lookupCtxtExact ty (typeHints defs) of
                       Nothing => []
                       Just ns => ns
         put Ctxt (addToTypeHints ty hint defs)
         setFlag loc hint (TypeHint ty)

export
addGlobalHint : {auto x : Ref Ctxt Defs} ->
					      annot -> Name -> Core annot ()
addGlobalHint loc hint
    = do d <- get Ctxt
         put Ctxt (record { autoHints $= (hint ::) } d)
         setFlag loc hint GlobalHint

-- Get all the names that might solve a goal of the given type
-- (constructors, local hints, global hints, in that order)
export
getHintsFor : {auto x : Ref Ctxt Defs} ->
							annot -> Name -> Core annot (List Name)
getHintsFor loc target
    = do defs <- get Ctxt
         case lookupDefExact target (gamma defs) of
              Just (TCon _ _ _ cons) => 
                   do let hs = case lookupCtxtExact target (typeHints defs) of
                                    Nothing => []
                                    Just ns => ns
                      pure (hs ++ cons ++ autoHints defs)
              _ => throw (UndefinedName loc target)

export
runWithCtxt : Show annot => Core annot () -> IO ()
runWithCtxt prog = coreRun prog 
                           (\err => printLn err)
                           (\ok => pure ())

-- Return whether an argument to the given term would be a forced argument
export
isForcedArg : Gamma -> Term vars -> Bool
isForcedArg gam tm with (unapply tm)
  isForcedArg gam (apply (Ref (DataCon _ _) n) args) | ArgsList 
      = case lookupDefExact n gam of
             Just (DCon _ _ forcedpos)
						    -- if the number of args so far is in forcedpos, then
								-- the next argument position is indeed forced
                   => length args `elem` forcedpos
             _ => False
  isForcedArg gam (apply f args) | ArgsList = False
