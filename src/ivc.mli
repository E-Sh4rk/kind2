module ScMap = Scope.Map

type term_cat = NodeCall of Symbol.t * StateVar.t list
| ContractItem of StateVar.t
| Equation of StateVar.t
| Assertion
| Unknown

type equation = {
    opened: Term.t ;
    closed: Term.t ;
  }

type loc = {
  pos: Lib.position ;
  index: LustreIndex.index ;
}

type ivc = (equation * (loc list) * term_cat) list ScMap.t

type ivc_result = {
  success: bool;
  init: ivc;
  trans: ivc;
}

val error_result : ivc_result

val all_eqs : 'a InputSystem.t -> TransSys.t -> ivc_result

val minimize_lustre_ast : ?valid_lustre:bool -> ivc_result -> ivc_result -> LustreAst.t -> LustreAst.t

val ivc_uc :
  'a InputSystem.t ->
  ?minimize_init:bool ->
  ?approximate:bool ->
  TransSys.t ->
  ivc_result

val ivc_bf :
  'a InputSystem.t ->
  Analysis.param ->
  (
    bool ->
    Lib.kind_module list -> 'a InputSystem.t -> Analysis.param -> TransSys.t
    -> unit
   ) ->
  TransSys.t ->
  ivc_result

val ivc_ucbf :
  'a InputSystem.t ->
  Analysis.param ->
  (
    bool ->
    Lib.kind_module list -> 'a InputSystem.t -> Analysis.param -> TransSys.t
    -> unit
   ) ->
  TransSys.t ->
  ivc_result