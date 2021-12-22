import Lean

open Lean Meta System Std

initialize kArrayCompileAttr : TagAttribute ←
  registerTagAttribute `kcompile "tag to request KArray compile"

structure CompilationUnit where
  filePath   : FilePath
  env        : Environment
  declName   : Name
  targetName : String

class Reflected (a : α)

instance : Reflected (λ x => Float.sqrt x) := ⟨⟩

def typeTranslationList : List (String × String) := [
  ("Float", "double")
]

def functionTranslationList : List (String × String) := [
  ("Float.sqrt", "sqrt")
]

-- is this function being called multiple times???
def hashMapFromList (l : List (String × String)) : HashMap String String := Id.run do
  let mut m : HashMap String String ← HashMap.empty
  for (a, b) in l do
    m ← m.insert a b
  m

constant typeTranslationHashMap : HashMap String String :=
  hashMapFromList typeTranslationList

constant functionTranslationHashMap : HashMap String String :=
  hashMapFromList functionTranslationList

def formattedName (e : Expr) : String :=
  toString e |>.replace "." "_"

def eName (e : Expr) : String :=
  match e.getAppFn.constName? with
  | some n => functionTranslationHashMap.find! n.toString
  | none => formattedName e

/-
# TODO: make sure compiled functions only depend on either:
* functions supported out-of-the-box like add, mul, sqrt, cos etc or
* other compiled functions
-/
partial def toCCode (compilationUnits : List CompilationUnit)
(e : Expr) : MetaM String :=
  match e with
  | Expr.fvar _ _=> eName e
  | Expr.app f x _ => do
    -- Is `f` reflected?
    let s ← synthInstance? (← mkAppM `Reflected #[f])
    match s with
    | some _ => eName f ++ "(" ++ (← toCCode compilationUnits x) ++ ")"
    | none => (← toCCode compilationUnits f) ++
      "(" ++ (← toCCode compilationUnits x) ++ ")"
  | _ =>
    -- TODO: if `f` is not reflected, check if it's a marked declaration. otherwise:
    throwError "Invalid Expression"

def getTypes (e : Expr) (acc : List String := []) : MetaM (List String) :=
  match e with
  | Expr.lam _ t e' _ => getTypes e' (acc.concat $ toString t)
  | Expr.app t _ _ => do
    match t with
    | Expr.const c _ _ => do
      Meta.forallTelescope (← getConstInfo c).type fun _ type => 
        acc.concat $ toString type
    | _ => throwError "Invalid marked declaration"
  | _ => throwError "Invalid Expression"

partial def metaCompile (compilationUnits : List CompilationUnit) (declName : Name) :
MetaM (String × String × String) := do
  let metaExpr ← whnf $ mkConst declName
  let types ← getTypes metaExpr
  let argNamesAndBody : (List String) × String ←
    match metaExpr with
    | Expr.lam .. => lambdaTelescope metaExpr fun args body =>
      (args.data.map formattedName, toCCode compilationUnits body)
    | _ => throwError "Function expected!"
  (typeTranslationHashMap.find! types.getLast!,
    ",".intercalate $ (types.zip argNamesAndBody.1).map λ (type, name) =>
      s!"{typeTranslationHashMap.find! type} {name}",
    ← argNamesAndBody.2)

def collectCompilationUnits (filePath : FilePath) : IO (List CompilationUnit) := do
  let input ← IO.FS.readFile filePath
  let (env, ok) ← Lean.Elab.runFrontend input Options.empty filePath.toString `main
  if ok then
    let mut res : List CompilationUnit ← []
    let externMap ← externAttr.ext.getState env
    for declName in kArrayCompileAttr.ext.getState env do
      match externMap.find? declName with
      | none =>
        IO.println $ s!"Warning ({filePath}):\n\t`{declName}` isn't marked with " ++
          "`extern`. Skipping KArray compilation."
      | some data =>
        let mut hasProperStandardEntry ← false
        for entry in data.entries do
          match entry with
          | ExternEntry.standard name targetName =>
            let nameString ← name.toString
            if nameString = "all" ∨ nameString = "cpp" then -- this condition suffices
              res ← res.concat ⟨filePath, env, declName, targetName⟩
              hasProperStandardEntry ← true
              break
          | _ => continue -- non-standard entries are ignored
        if ¬hasProperStandardEntry then
          panic! s!"\nError ({filePath}):\n\t`kcompile` tag requires `{declName}` to " ++
            "be marked with `extern <targetName>`."
    res
  else
    panic! s!"\nLean's Frontend failed to run `{filePath}`."

-- TODO: check if `targetName` is a valid function name for C code
def isValidCFunctionName (targetName : String) : Bool := true

def validateCompilationUnits (compilationUnits : List CompilationUnit) : IO PUnit := do
  let mut targetNamesSet : HashSet String ← HashSet.empty
  for compilationUnit in compilationUnits do
    if ¬(isValidCFunctionName compilationUnit.targetName) then
      panic! s!"\nError ({compilationUnit.filePath}):\n\tInvalid target name " ++
        s!"'{compilationUnit.targetName}' on declaration `{compilationUnit.declName}`."
    if targetNamesSet.contains compilationUnit.targetName then
      panic! s!"\nError ({compilationUnit.filePath}):\n\tDuplicated occurrence of " ++
        s!"target name '{compilationUnit.targetName}' on declaration `{compilationUnit.declName}`."
    targetNamesSet ← targetNamesSet.insert compilationUnit.targetName

/-
The header is a string like:
  "external double add(double x, double y)"

Notice that "x" and "y" could be hidden in a header, but it's better to explicit them
so we can reuse the header when defining the function itself.

The body is a string like:
  "{return x + y;}"
-/
def processCompilationUnit (compilationUnits : List CompilationUnit)
(compilationUnit : CompilationUnit) : IO (String × String) := do
  let env ← compilationUnit.env
  let (returnType, args, body) ← Prod.fst <$>
    (metaCompile compilationUnits compilationUnit.declName).run'.toIO {} {env}
  let header ← s!"external {returnType} {compilationUnit.targetName}({args})"
  (header, s!"\{return {body};}")

def cIncludes : String :=
  "#include <lean/lean.h>\n" ++
  "#include <math.h>"

def cDefines : String :=
  "#define external extern \"C\" LEAN_EXPORT"

def semicolon : String := ";"

def newLine : String := "\n"

def semicolonNewLine : String := semicolon ++ newLine

def buildFinalCCode (cHeadersAndBodies : List (String × String)) : String :=
  let cHeaders := cHeadersAndBodies.map λ (h, _) => h
  cIncludes ++ newLine ++ cDefines ++ newLine ++ -- includes and defines
    (semicolonNewLine.intercalate cHeaders ++ semicolonNewLine) ++ --headers
    (newLine.intercalate $ cHeadersAndBodies.map λ (a, b) => a ++ b) -- declarations
