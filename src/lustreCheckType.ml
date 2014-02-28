(* This file is part of the Kind 2 model checker.

   Copyright (c) 2014 by the Board of Trustees of the University of Iowa

   Licensed under the Apache License, Version 2.0 (the "License"); you
   may not use this file except in compliance with the License.  You
   may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0 

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied. See the License for the specific language governing
   permissions and limitations under the License. 

*)

open Lib

(* Abbreviations *)
module A = LustreAst
module I = LustreIdent
module T = LustreType
module E = LustreExpr
module N = LustreNode

module ISet = I.LustreIdentSet

(* Call to a node that is only defined later

   This is just failing at the moment, we'd need some dependency
   analysis to recognize cycles to fully support forward
   referencing. *)
exception Forward_reference of I.t * A.position


(* Identifier for new variables from abstrations *)
let new_var_ident = I.mk_string_ident "__abs" 

(* Identifier for new variables from node calls *)
let new_call_ident = I.mk_string_ident "__returns" 


(* Sort a list of indexed expressions *)
let sort_indexed_pairs list =
  List.sort (fun (i1, _) (i2, _) -> I.compare_index i1 i2) list


(* ******************************************************************** *)
(* Data structures                                                      *)
(* ******************************************************************** *)

(* Context for typing *)
type lustre_context = 

    { 

      (* Type identifiers and their types *)
      basic_types : (LustreIdent.t * LustreType.t) list; 

      (* Map of prefix of a type identifiers to its suffixes and their
         types *)
      indexed_types : 
        (LustreIdent.t * 
           (LustreIdent.index * LustreType.t) list) list; 

      (* Type identifiers for free types *)
      free_types : LustreIdent.t list; 

      (* Types of identifiers *)
      type_ctx : (LustreIdent.t * LustreType.t) list; 

      (* Map of prefix of an identifier to its suffixes

         Pair the suffix with a unit value to reuse function for
         [indexed_types]. *)
      index_ctx : 
        (LustreIdent.t * 
           (LustreIdent.index * unit) list) list; 

      (* Values of constants *)
      consts : (LustreIdent.t * LustreExpr.t) list; 

      (* Nodes *)
      nodes : (LustreIdent.t * LustreNode.t) list;

    }


(* Initial context *)
let init_lustre_context = 
  { basic_types = [];
    indexed_types = [];
    free_types = [];
    type_ctx = [];
    index_ctx = [];
    consts = [];
    nodes = [] }


(* Pretty-print a type identifier *)
let pp_print_basic_type safe ppf (i, t) = 
  Format.fprintf ppf 
    "%a: %a" 
    (I.pp_print_ident safe) i 
    (T.pp_print_lustre_type safe) t


(* Pretty-print an identifier suffix and its type *)
let pp_print_index_type safe ppf (i, t) = 
  Format.fprintf ppf 
    "%a: %a" 
    (I.pp_print_index safe) i 
    (T.pp_print_lustre_type safe) t


(* Pretty-print a prefix and its suffixes with their types *)
let pp_print_indexed_type safe ppf (i, t) = 

  Format.fprintf ppf 
    "%a: @[<hv 1>[%a]@]" 
    (I.pp_print_ident safe) i 
    (pp_print_list (pp_print_index_type safe) ";@ ") t


(* Pretty-print types of identifiers *)
let pp_print_type_ctx safe ppf (i, t) = 
  Format.fprintf ppf "%a: %a" 
    (I.pp_print_ident safe) i 
    (T.pp_print_lustre_type safe) t


(* Pretty-print suffixes of identifiers *)
let pp_print_index_ctx safe ppf (i, j) = 

  Format.fprintf ppf 
    "%a: @[<hv 1>[%a]@]" 
    (I.pp_print_ident safe) i 
    (pp_print_list 
       (fun ppf (i, _) -> I.pp_print_index safe ppf i)
       ";@ ") 
    j


(* Pretty-print values of constants *)
let pp_print_consts safe ppf (i, e) = 
  Format.fprintf ppf 
    "%a: %a" 
    (I.pp_print_ident safe) i 
    (E.pp_print_lustre_expr safe) e

  

(* Pretty-print a context for type checking *)
let pp_print_lustre_context 
    safe
    ppf 
    { basic_types;
      indexed_types; 
      free_types; 
      type_ctx; 
      index_ctx; 
      consts } =
  
  Format.fprintf ppf
    "@[<v>@[<v>*** basic_types:@,%a@]@,\
          @[<v>*** indexed_types:@,%a@]@,\
          @[<v>*** free_types:@,@[<hv>%a@]@,@]\
          @[<v>*** type_ctx:@,%a@]@,\
          @[<v>*** index_ctx:@,%a@]@,\
          @[<v>*** consts:@,%a@]@,\
     @]" 
    (pp_print_list (pp_print_basic_type safe) "@,") basic_types
    (pp_print_list (pp_print_indexed_type safe) "@,") indexed_types
    (pp_print_list (I.pp_print_ident safe) ",@ ") free_types
    (pp_print_list (pp_print_type_ctx safe) "@,") type_ctx
    (pp_print_list (pp_print_index_ctx safe) "@,") index_ctx
    (pp_print_list (pp_print_consts safe) "@,") consts



(* ******************************************************************** *)
(* Evaluation of expressions                                            *)
(* ******************************************************************** *)

(* Given an expression parsed into the AST, evaluate to a list of
   LustreExpr.t paired with an index. Unfold and abstract from the
   context, also return a list of created variables and node calls.  

   The functions [mk_new_var_ident] and [mk_new_call_ident] return a
   fresh identifier for a variable and for a variable capturing the
   output of a node call, respectively. The former is called with a
   unit argument and returns an identifier __abs[n], the latter is is
   given the name of the node as an argument and returns an identifier
   __call.X[n] where X is the node name.

   A typing context is given to type check expressions, it is not
   modified.

   There are several mutually recursive functions, [eval_ast_expr] is
   the main entry point.

*)
let rec eval_ast_expr'     
    mk_new_var_ident 
    mk_new_call_ident
    ({ basic_types; 
       indexed_types; 
       free_types; 
       type_ctx; 
       index_ctx; 
       consts;
       nodes } as context)
    result
    ((new_vars, new_calls) as new_defs) = 


  (* Evaluate the argument of a unary expression and construct a unary
     expression of the result with the given constructor *)
  let eval_unary_ast_expr mk expr pos tl = 

    let expr', new_defs' = 
      unary_apply_to 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        new_defs 
        mk
        expr 
        pos
        result 
    in  

    eval_ast_expr' 
      mk_new_var_ident 
      mk_new_call_ident 
      context 
      expr'
      new_defs'
      tl

  in


  (* Evaluate the arguments of a binary expression and construct a
     binary expression of the result with the given constructor *)
  let eval_binary_ast_expr mk expr1 expr2 pos tl = 

    let expr', new_defs' = 
      binary_apply_to 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        new_defs 
        mk
        expr1 
        expr2 
        pos
        result 
    in  

    eval_ast_expr' 
      mk_new_var_ident 
      mk_new_call_ident 
      context 
      expr'
      new_defs'
      tl

  in

  function

    (* All expressions evaluated, return result *)
    | [] -> (result, new_defs)


    (* An identifier without suffixes: a constant or a variable *)
    | (index, A.Ident (_, ident)) :: tl when 
        List.mem_assoc (I.push_index index ident) type_ctx -> 

      (* Add index to identifier *)
      let ident' = I.push_index index ident in

      (* Construct expression *)
      let expr = 

        (* Return value of constant *)
        try List.assoc ident' consts with 

          (* Identifier is not constant *)
          | Not_found -> 

            (* Return variable on the base clock *)
            E.mk_var 
              ident' 
              (List.assoc ident' type_ctx) 
              E.base_clock

      in

      (* Add expression to result *)
      eval_ast_expr' 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        ((index, expr) :: result) 
        new_defs 
        tl


    (* A nested identifier with suffixes *)
    | (index, (A.Ident (_, ident) as e)) :: tl when 
        List.mem_assoc ident index_ctx -> 

      (* Expand indexed identifier *)
      let tl' = 
        List.fold_left 
          (fun a (j, _) -> (I.push_index_to_index j index, e) :: a)
          tl
          (List.assoc ident index_ctx)
      in

      (* Continue with unfolded indexes *)
      eval_ast_expr' 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        result 
        new_defs 
        tl'


    (* Identifier must have a type or indexes *)
    | (_, A.Ident (pos, ident)) :: _ -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Identifier %a not declared in %a" 
              (I.pp_print_ident false) ident
              A.pp_print_position pos))


    (* Projection to a record field *)
    | (index, A.RecordProject (pos, ident, field)) :: tl -> 

      (try

         (* Check if identifier has index *)
         if List.mem_assoc field (List.assoc ident index_ctx) then

           (* Append index to identifier *)
           let expr' = 
             A.Ident (pos, I.push_index field ident) 
           in

           (* Continue with record field *)
           eval_ast_expr' 
             mk_new_var_ident 
             mk_new_call_ident 
             context 
             result 
             new_defs 
             ((index, expr') :: tl)

         else

           raise Not_found

       with Not_found ->

         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "Identifier %a does not have field %a in %a" 
                 (I.pp_print_ident false) ident
                 A.pp_print_position pos
                 (I.pp_print_index false) field)))


    (* Projection to a tuple or array field *)
    | (index, A.TupleProject (pos, ident, field_expr)) :: tl -> 

      (try

         (* Evaluate expression to an integer constant *)
         let field_index = 
           I.mk_int_index (int_const_of_ast_expr context field_expr) 
         in

         (* Check if identifier has index *)
         if List.mem_assoc field_index (List.assoc ident index_ctx) then

           (* Append index to identifier *)
           let expr' = 
             A.Ident (pos, I.push_index field_index ident) 
           in

           (* Continue with array or tuple field *)
           eval_ast_expr' 
             mk_new_var_ident 
             mk_new_call_ident 
             context 
             result 
             new_defs 
             ((index, expr') :: tl)

         else

           raise Not_found 

       with Not_found -> 

         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "Identifier %a does not have field %a in %a" 
                 (I.pp_print_ident false) ident
                 A.pp_print_expr field_expr
                 A.pp_print_position pos)))


    (* Boolean constant true *)
    | (index, A.True pos) :: tl -> 

      (* Add expression to result *)
      eval_ast_expr' 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        ((index, E.t_true) :: result) 
        new_defs 
        tl


    (* Boolean constant false *)
    | (index, A.False pos) :: tl -> 

      (* Add expression to result *)
      eval_ast_expr'
        mk_new_var_ident 
        mk_new_call_ident 
        context
        ((index, E.t_false) :: result) 
        new_defs 
        tl


    (* Integer constant *)
    | (index, A.Num (pos, d)) :: tl -> 

      (* Add expression to result *)
      eval_ast_expr' 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        ((index, E.mk_int (Numeral.of_string d)) :: result) 
        new_defs 
        tl


    (* Real constant *)
    | (index, A.Dec (pos, f)) :: tl -> 

      (* Add expression to result *)
      eval_ast_expr' 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        ((index, E.mk_real (Decimal.of_string f)) :: result) 
        new_defs 
        tl


    (* Conversion to an integer number *)
    | (index, A.ToInt (pos, expr)) :: tl -> 

      eval_unary_ast_expr E.mk_to_int expr pos tl


    (* Conversion to a real number *)
    | (index, A.ToReal (pos, expr)) :: tl -> 

      eval_unary_ast_expr E.mk_to_real expr pos tl


    (* An expression list, flatten nested lists and add an index to
       each elements *)
    | (index, A.ExprList (pos, expr_list)) :: tl -> 

      (* Flatten nested lists *)
      let rec flatten_expr_list accum = function 

        | [] -> List.rev accum

        | A.ExprList (pos, expr_list) :: tl -> 
          flatten_expr_list accum (expr_list @ tl)

        | expr :: tl -> flatten_expr_list (expr :: accum) tl

      in

      (* Turn ((a,b),c) into (a,b,c) *)
      let expr_list' = flatten_expr_list [] expr_list in

      (* Treat as tuple *)
      eval_ast_expr' 
        mk_new_var_ident
        mk_new_call_ident 
        context 
        result
        new_defs 
        ((index, A.TupleExpr (pos, expr_list')) :: tl)


    (* Tuple constructor *)
    | (index, A.TupleExpr (pos, expr_list)) :: tl -> 

      let _, new_defs', result' = 

        (* Iterate over list of expressions *)
        List.fold_left
          (fun (i, new_defs, accum) expr -> 

             (* Evaluate one expression *)
             let expr', new_defs' = 
               eval_ast_expr 
                 mk_new_var_ident
                 mk_new_call_ident 
                 context 
                 new_defs 
                 expr
             in

             (* Increment counter *)
             (Numeral.(succ i),

              (* Continue with added definitions *)
              new_defs',

              (* Append current index to each index of evaluated
                 expression *)
              List.fold_left 
                (fun a (j, e) -> (I.push_int_index_to_index i j, e) :: a)
                accum
                expr'))

          (Numeral.zero, new_defs, result)
          expr_list
      in

      (* Continue with result added *)
      eval_ast_expr' 
        mk_new_var_ident
        mk_new_call_ident 
        context 
        result' 
        new_defs' 
        tl


    (* Array constructor *)
    | (index, A.ArrayConstr (pos, expr, size_expr)) :: tl -> 

      (* Evaluate expression to an integer constant *)
      let array_size = int_const_of_ast_expr context size_expr in

      (* Size of array must be non-zero and positive *)
      if Numeral.(array_size <= zero) then 

        (* Fail *)
        raise 
          (Failure 
             (Format.asprintf 
                "Expression %a cannot be used to \
                 construct an array in %a " 
                A.pp_print_expr size_expr
                A.pp_print_position pos));

      (* Evaluate expression for array elements *)
      let expr_val, new_defs' = 
        eval_ast_expr 
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          new_defs 
          expr 
      in 

      (* Add expression paired with each index to the result *)
      let result' = 

        let rec aux accum = function 

          (* All elements of array enuerated

             Started with size of array, lowest index is zero *)
          | i when Numeral.(i = zero) -> accum

          (* Array element *)
          | i -> 


            (* Append current index to each index of evaluated
               expression and recurse to next lower array element *)
            aux 
              (List.fold_left
                 (fun a (j, e) -> 
                    (I.push_int_index_to_index Numeral.(pred i) j, e) :: a)
                 accum
                 expr_val)
              (Numeral.(pred i))

        in

        (* Add all array elements *)
        aux result array_size

      in

      (* Continue with result added *)
      eval_ast_expr' 
        mk_new_var_ident
        mk_new_call_ident 
        context
        result' 
        new_defs' 
        tl

    (* Array slice *)
    | (index, A.ArraySlice (pos, _, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Array slices not implemented in %a" 
              A.pp_print_position A.dummy_pos))


    (*
      | (index, A.ArraySlice (p, ident, slices)) :: tl ->  

    (* Maintain a list of pairs of indexes: an index in the array
      that is sliced and the corresponding index in the new array.

      [aux m a l u i] appends to each index pair in [m] all
      integers from [i] to [u] to the first index, the difference
      between [i] and [l] to the second index in the pair and add
      the resulting pair to [a] *)
      let rec aux indexes lbound ubound accum = 

      function 

    (* Reached maximum, return result *)
      | i when i > ubound -> accum

    (* Need to add integer i as index *)
      | i -> 

    (* Add to all elements in accum and recurse for next *)
      aux 
      indexes
      lbound 
      ubound
      (List.fold_left
      (fun a (j, j') -> 

      (I.add_int_to_index j i, 
      I.add_int_to_index j' (i - lbound)) :: a)
      accum
      indexes)
      (succ i)

      in

    (* Indexes to slice from array *)
      let index_map = 

      List.fold_left
      (fun a (el, eu) -> 

    (* Evaluate expression for lower bound to an integer *)
      let il = int_const_of_ast_expr context el in

      if il < 0 then 

    (* Fail *)
      raise 
      (Failure 
      (Format.asprintf 
      "Expression %a in %a cannot be used as \
      the lower bound of an array slice" 
      A.pp_print_expr el
      A.pp_print_position p));

    (* Evaluate expression for lower bound to an integer *)
      let iu = int_const_of_ast_expr context eu in

      if iu < il then

    (* Fail *)
      raise 
      (Failure 
      (Format.asprintf 
      "Expression %a in %a cannot be used as \
      the upper bound of an array slice" 
      A.pp_print_expr eu
      A.pp_print_position p));

    (* Append all indexes between il und iu to indexes in
      accumulator *)
      aux a il iu [] il)
      [([],[])]
      l

      in

      IndexedExpr 
      (List.fold_left 
      (fun a (i, i') -> 

      (match expr_find_index i [] expr_list with 

    (* Index not found *)
      | [] -> 

    (* Fail *)
      raise 
      (Failure 
      (Format.asprintf 
      "Array %a in %a does not have index %a" 
      I.pp_print_ident id
      A.pp_print_position p
      I.pp_print_index i))

      | l -> 

      List.fold_left
      (fun a (j, e) -> (i' @ j, e) :: a)
      a
      l))

      []
      index_map)

    *)


    (* Concatenation of arrays *)
    | (index, A.ArrayConcat (pos, _, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Array concatenation not implemented in %a" 
              A.pp_print_position A.dummy_pos))


    (* Record constructor *)
    | (index, A.RecordConstruct (pos, record_type, expr_list)) :: tl -> 

      (* Get fields of record and their types *)
      let indexes = 

        try 

          List.map 
            (function (index, _) -> 
              (index, 

               (* Add field name to identifier and get type *)
               List.assoc (I.push_index index record_type) basic_types))

            (* Indexes of record type *)
            (List.assoc record_type indexed_types)

        with Not_found -> 

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Record type %a in %a is not defined" 
                  (I.pp_print_ident false) record_type
                  A.pp_print_position pos))

      in

      (* Convert identifiers to indexes for expressions in constructor *)
      let expr_list', new_defs' = 
        List.fold_left 
          (fun (accum, new_defs) (ident, ast_expr) -> 

             (* Evaluate one expression *)
             let expr', new_defs' = 
               eval_ast_expr 
                 mk_new_var_ident
                 mk_new_call_ident 
                 context 
                 new_defs 
                 ast_expr
             in

             (List.fold_left 
                (fun accum (index', expr') ->
                   (I.push_ident_index_to_index 
                      ident 
                      index', 
                    expr') :: accum)
                accum
                expr',
              new_defs')) 
          ([], new_defs)
          expr_list 
      in

      (* Add indexed expressions and new definitions to result *)
      let result' = 

        try 

          List.fold_left2 
            (fun 
              accum
              (record_index, record_type) 
              ((expr_index, { E.expr_type }) as expr) -> 

              if 

                (* Indexes must match *)
                record_index = expr_index &&

                (* Element type must be a subtype of field type *)
                T.check_type expr_type record_type 

              then


                (* Continue with added definitions *)
                (expr :: accum)

              else 

                raise E.Type_mismatch)
            result
            (sort_indexed_pairs indexes)
            (sort_indexed_pairs expr_list')


        (* Type checking error or one expression has more indexes *)
        with Invalid_argument "List.fold_left2" | E.Type_mismatch -> 

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Type mismatch in record of type %a in %a" 
                  (I.pp_print_ident false) record_type
                  A.pp_print_position pos))

      in

      (* Continue with result added *)
      eval_ast_expr' 
        mk_new_var_ident
        mk_new_call_ident 
        context
        result' 
        new_defs' 
        tl


    (* Boolean negation *)
    | (index, A.Not (pos, expr)) :: tl ->

      eval_unary_ast_expr E.mk_not expr pos tl


    (* Boolean conjunction *)
    | (index, A.And (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_and expr1 expr2 pos tl


    (* Boolean disjunction *)
    | (index, A.Or (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_or expr1 expr2 pos tl


    (* Boolean exclusive disjunction *)
    | (index, A.Xor (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_xor expr1 expr2 pos tl


    (* Boolean implication *)
    | (index, A.Impl (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_impl expr1 expr2 pos tl


    (* Boolean at-most-one constaint  *)
    | (index, A.OneHot (pos, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "One-hot expression not supported in %a" 
              A.pp_print_position A.dummy_pos))


    (* Unary minus *)
    | (index, A.Uminus (pos, expr)) :: tl -> 

      eval_unary_ast_expr E.mk_uminus expr pos tl


    (* Integer modulus *)
    | (index, A.Mod (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_mod expr1 expr2 pos tl


    (* Subtraction *)
    | (index, A.Minus (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_minus expr1 expr2 pos tl


    (* Addition *)
    | (index, A.Plus (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_plus expr1 expr2 pos tl


    (* Real division *)
    | (index, A.Div (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_div expr1 expr2 pos tl


    (* Multiplication *)
    | (index, A.Times (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_times expr1 expr2 pos tl


    (* Integer division *)
    | (index, A.IntDiv (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_intdiv expr1 expr2 pos tl


    (* If-then-else *)
    | (index, A.Ite (pos, expr1, expr2, expr3)) :: tl -> 

      let expr1', new_defs' = 
        eval_ast_expr 
          mk_new_var_ident 
          mk_new_call_ident 
          context
          new_defs 
          expr1 
      in

      (* Check evaluated expression *)
      (match expr1' with 

        (* Boolean expression without indexes *)
        | [ index, ({ E.expr_type = T.Bool } as expr1) ] when 
            index = I.empty_index -> 

          let expr', new_defs' = 
            binary_apply_to 
              mk_new_var_ident 
              mk_new_call_ident 
              context 
              new_defs' 
              (E.mk_ite expr1) 
              expr2 
              expr3 
              pos
              result
          in

          (* Add expression to result *)
          eval_ast_expr' 
            mk_new_var_ident 
            mk_new_call_ident 
            context 
            expr'
            new_defs' 
            tl


        (* Expression is not Boolean or is indexed *)
        | _ -> 

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Condition is not of Boolean type in %a" 
                  A.pp_print_position pos)))


    (* With operator for recursive node calls *)
    | (index, A.With (pos, _, _, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Recursive nodes not supported in %a" 
              A.pp_print_position pos))


    (* Equality *)
    | (index, A.Eq (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_eq expr1 expr2 pos tl


    (* Disequality *)
    | (index, A.Neq (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_neq expr1 expr2 pos tl


    (* Less than or equal *)
    | (index, A.Lte (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_lte expr1 expr2 pos tl


    (* Less than *)
    | (index, A.Lt (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_lt expr1 expr2 pos tl


    (* Greater than or equal *)
    | (index, A.Gte (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_gte expr1 expr2 pos tl


    (* Greater than *)
    | (index, A.Gt (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_gt expr1 expr2 pos tl


    (* Projection on clock *)
    | (index, A.When (pos, _, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "When expression not supported in %a" 
              A.pp_print_position pos))


    (* Interpolation to base clock *)
    | (index, A.Current (pos, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Current expression not supported in %a" 
              A.pp_print_position pos))


    (* Condact, a node with an activation condition *)
    | (index, A.Condact (pos, cond, ident, args, init)) :: tl -> 

      (* Inputs and outputs of called node *)
      let { N.inputs = node_inputs; N.outputs = node_outputs } = 

        try 

          (* Get node context by identifier *)
          List.assoc ident nodes 

        with Not_found -> 

          (* Forward referenced node *)
          raise (Forward_reference (ident, pos))

      in

      (* Evaluate inputs as list of expressions *)
      let args', ((vars', calls') as new_defs') = 
        eval_ast_expr
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          new_defs 
          (A.ExprList (A.dummy_pos, args))
      in

      (* Evaluate initial values as list of expressions *)
      let init', ((vars', calls') as new_defs') = 
        eval_ast_expr
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          new_defs' 
          (A.ExprList (A.dummy_pos, init))
      in

      (* Evaluate initial values as list of expressions *)
      let cond', ((vars', calls') as new_defs') = 

        match 
          eval_ast_expr
            mk_new_var_ident 
            mk_new_call_ident 
            context 
            new_defs' 
            cond
        with 

          (* Expression without indexes *)
          | ([ index, ({ E.expr_type = T.Bool } as expr) ], new_defs) 
            when index = I.empty_index -> 

            expr, new_defs

          (* Expression is not Boolean or is indexed *)
          | _ -> 

            (* Fail *)
            raise 
              (Failure 
                 (Format.asprintf 
                    "Condition is not of Boolean type in %a" 
                    A.pp_print_position pos))

      in

      (* Fresh identifier for node call *)
      let call_ident = mk_new_call_ident ident in

      (* Type check and flatten indexed expressions for input into
         list without indexes *)
      let node_input_exprs =
        node_inputs_of_exprs node_inputs args'
      in

      (* Type check and flatten indexed expressions for input into
         list without indexes *)
      let node_init_exprs =
        node_init_of_exprs node_outputs init'
      in

      (* Flatten indexed types of node outputs to a list of
         identifiers and their types *)
      let node_output_idents = 
        output_idents_of_node ident pos call_ident node_outputs
      in

      (* Node call evaluates to variables capturing the output of the
         node with indexes by their position *)
      let result' = 
        add_node_output_to_result index result node_output_idents
      in

      (* Add expression to result *)
      eval_ast_expr' 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        result' 
        (vars', 
         (node_output_idents, 
          cond', 
          ident, 
          node_input_exprs, 
          node_init_exprs) :: calls') 
        tl



(*


      (try 

         let { node_inputs; node_outputs } = List.assoc ident nodes in

         let cond', new_defs' = 
           eval_ast_expr
             mk_new_var_ident 
             mk_new_call_ident 
             context 
             new_defs 
             cond
         in

         let args', new_defs'' = 
           eval_ast_expr_list
             mk_new_var_ident 
             mk_new_call_ident 
             context 
             new_defs' 
             args
         in

         let init', (vars', calls') =
           eval_ast_expr_list
             mk_new_var_ident 
             mk_new_call_ident 
             context 
             new_defs'' 
             init
         in

         let call_ident = mk_new_call_ident ident in

         let node_input_exprs =
           node_inputs_of_exprs node_inputs args'
         in

         let node_output_idents = 
           output_idents_of_node ident pos call_ident node_outputs
         in

         (* TODO: fold_right2 on node_outputs and init', sort both by
            index, type check and add to a list *)




         let result' = 
           add_node_output_to_result index result node_output_idents
         in

         (* Add expression to result *)
         eval_ast_expr' 
           mk_new_var_ident 
           mk_new_call_ident 
           context 
           result' 
           (vars', 
            (node_output_idents, 
             E.t_true, 
             ident, 
             node_input_exprs, 
             init_exprs) :: calls') 
           tl

       with Not_found -> 

         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "Node %a not defined or forward-referenced in %a" 
                 (I.pp_print_ident false) ident
                 A.pp_print_position A.dummy_pos)))

*)

    (* Temporal operator pre *)
    | (index, A.Pre (pos, expr)) :: tl -> 

      (try 

         (* Evaluate expression *)
         let expr', new_defs' = 
           eval_ast_expr 
             mk_new_var_ident 
             mk_new_call_ident 
             context 
             new_defs 
             expr 
         in

         (* Abstract expression under pre to a fresh variable *)
         let expr'', new_defs'' = 

           (* Not necessary to keep order of indexes here *)
           List.fold_left
             (fun (accum, new_defs) (index, expr) -> 
                let expr', new_defs' = 
                  E.mk_pre mk_new_var_ident new_defs expr 
                in
                (((index, expr') :: accum), new_defs'))
             (result, new_defs')
             expr'

         in

         (* Add expression to result *)
         eval_ast_expr' 
           mk_new_var_ident 
           mk_new_call_ident 
           context 
           expr'' 
           new_defs'' 
           tl

       with E.Type_mismatch ->

         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "Type mismatch for expressions at %a"
                 A.pp_print_position pos)))


    (* Followed by operator *)
    | (index, A.Fby (pos, _, _, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Fby operator not implemented in %a" 
              A.pp_print_position pos))


    (* Arrow temporal operator *)
    | (index, A.Arrow (pos, expr1, expr2)) :: tl -> 

      eval_binary_ast_expr E.mk_arrow expr1 expr2 pos tl


    (* Node call *)
    | (index, A.Call (pos, ident, expr_list)) :: tl -> 

      (* Inputs and outputs of called node *)
      let { N.inputs = node_inputs; N.outputs = node_outputs } = 

        try 

          (* Get node context by identifier *)
          List.assoc ident nodes 

        with Not_found -> 

          (* Forward referenced node *)
          raise (Forward_reference (ident, pos))

      in

      (* Evaluate inputs as list of expressions *)
      let expr_list', ((vars', calls') as new_defs') = 
        eval_ast_expr
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          new_defs 
          (A.ExprList (A.dummy_pos, expr_list))
      in

      (* Fresh identifier for node call *)
      let call_ident = mk_new_call_ident ident in

      (* Type check and flatten indexed expressions for input into
         list without indexes *)
      let node_input_exprs =
        node_inputs_of_exprs node_inputs expr_list'
      in

      (* Flatten indexed types of node outputs to a list of
         identifiers and their types *)
      let node_output_idents = 
        output_idents_of_node ident pos call_ident node_outputs
      in

      (* Node call evaluates to variables capturing the output of the
         node with indexes by their position *)
      let result' = 
        add_node_output_to_result index result node_output_idents
      in

      (* Add expression to result *)
      eval_ast_expr' 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        result' 
        (vars', 
         (node_output_idents, 
          E.t_true, 
          ident, 
          node_input_exprs, []) :: calls') 
        tl


    (* Node call to a parametric node *)
    | (index, A.CallParam (pos, _, _, _)) :: tl -> 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Parametric nodes not supported in %a" 
              A.pp_print_position pos))



(* Apply operation to expression component-wise *)
and unary_apply_to 
    mk_new_var_ident
    mk_new_call_ident 
    context 
    new_defs 
    mk 
    expr 
    pos
    accum = 

  try 

    (* Evaluate expression *)
    let expr', new_defs' = 
      eval_ast_expr 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        new_defs 
        expr 
    in

    (List.fold_left
       (fun a (j, e) -> (j, mk e) :: a)
       accum
       expr',
     new_defs')

  with E.Type_mismatch ->

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Type mismatch for expressions at %a"
            A.pp_print_position pos))


(* Apply operation to expressions component-wise *)
and binary_apply_to 
    mk_new_var_ident
    mk_new_call_ident 
    context 
    new_defs 
    mk 
    expr1 
    expr2 
    pos
    accum = 

  (* Evaluate first expression *)
  let expr1', new_defs' = 
    eval_ast_expr 
      mk_new_var_ident 
      mk_new_call_ident 
      context 
      new_defs 
      expr1 
  in

  (* Evaluate second expression *)
  let expr2', new_defs' = 
    eval_ast_expr 
      mk_new_var_ident 
      mk_new_call_ident 
      context 
      new_defs' 
      expr2 
  in

  try 

    (* Check type of corresponding expressions *)
    (List.fold_left2
       (fun accum (index1, expr1) (index2, expr2) -> 

          (* Indexes must match *)
          if index1 = index2 then 

            (index1, mk expr1 expr2) :: accum

          else          

            raise E.Type_mismatch)

       accum
       (sort_indexed_pairs expr1')
       (sort_indexed_pairs expr2'),
     new_defs')

  (* Type checking error or one expression has more indexes *)
  with Invalid_argument "List.fold_left2" | E.Type_mismatch -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "@[<v>Type mismatch for expressions@ %a and@ %a@ at %a@]"
            A.pp_print_expr expr1
            A.pp_print_expr expr2
            A.pp_print_position pos))


(* Evaluate expression *)
and eval_ast_expr 
    mk_new_var_ident 
    mk_new_call_ident 
    context 
    new_defs 
    expr = 

  let expr', new_defs' = 
    eval_ast_expr' 
      mk_new_var_ident
      mk_new_call_ident 
      context
      [] 
      new_defs 
      [(I.empty_index, expr)]
  in

  (* Sort expressions by their indexes *)
  (sort_indexed_pairs expr', new_defs')


(* Evaluate expression to an integer constant *)
and int_const_of_ast_expr context expr = 

  (* Evaluate expression *)
  match 

    eval_ast_expr 

      (* Immediately fail when abstraction expressions to a
         definition *)
      (fun _ ->       
         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "Expression %a in %a must be a constant integer" 
                 A.pp_print_expr expr
                 A.pp_print_position A.dummy_pos))) 

      (* Immediately fail when abstraction expressions to a
         node call *)
      (fun _ ->       
         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "Expression %a in %a must be a constant integer" 
                 A.pp_print_expr expr
                 A.pp_print_position A.dummy_pos))) 

      context
      ([], [])
      expr 

  with

    (* Expression must evaluate to a singleton list of an integer
       expression without index and without new definitions *)
    | ([ index, { E.expr_pre_vars; 
                  E.expr_init = E.Int di; 
                  E.expr_step = E.Int ds } ],
       ([], [])) when 
        index = I.empty_index && 
        ISet.is_empty expr_pre_vars && 
        Numeral.(di = ds) -> di

    (* Expression is not a constant integer *)
    | _ ->       

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Expression %a in %a must be a constant integer" 
              A.pp_print_expr expr
              A.pp_print_position A.dummy_pos))


(* Type check expressions for node inputs and return sorted list of
   expressions for node inputs *)
and node_inputs_of_exprs node_inputs expr_list =

  let node_inputs' = 

    (* Add an index to each inputs and sort *)
    sort_indexed_pairs 
      (snd
         (List.fold_left
            (fun (j, accum) (_, (indexes, is_const)) -> 
               (Numeral.(succ j),
                (List.fold_right
                   (fun (index, expr_type) accum -> 
                      (I.push_int_index_to_index j index, 
                       (expr_type, is_const)) :: accum)
                   indexes
                   accum)))
            (Numeral.zero, [])
            node_inputs))
  in

  try

    (* Check types and index, keep lists sorted *)
    List.fold_right2
      (fun 
        (in_index, (in_type, is_const)) 
        (expr_index, ({ E.expr_type } as expr)) 
        accum ->

        (* TODO: check if expression is actually constant. How
           to optimize in that case? *)

        (* Indexes must match *)
        if (* in_index = expr_index *) true then 

          (* Expression must be of a subtype of input type *)
          if T.check_type expr_type in_type then 

            expr :: accum

          else

            raise E.Type_mismatch

        else

          raise E.Type_mismatch)
      (sort_indexed_pairs node_inputs')
      expr_list
      []

  (* Type checking error or one expression has more indexes *)
  with Invalid_argument "List.fold_right2" | E.Type_mismatch -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Type mismatch for expressions at %a"
            A.pp_print_position A.dummy_pos))



(* Type check expressions for node inputs and return sorted list of
   expressions for node inputs *)
and node_init_of_exprs node_outputs expr_list =

  let node_outputs' = 

    (* Add an index to each output and sort *)
    (sort_indexed_pairs 
       (snd
          (List.fold_left
             (fun  (j, accum) (_, indexes) -> 
                (Numeral.(succ j),
                 (List.fold_right
                    (fun (index, expr_type) accum -> 
                       (I.push_int_index_to_index j index, 
                        expr_type) :: accum)
                    indexes
                    accum)))
             (Numeral.zero, [])
             node_outputs)))
  in

  try

    (* Check types and index, keep lists sorted *)
    List.fold_right2
      (fun 
        (in_index, in_type) 
        (expr_index, ({ E.expr_type } as expr)) 
        accum ->

        (* Indexes must match *)
        if in_index = expr_index then 

          (* Expression must be of a subtype of input type *)
          if T.check_type expr_type in_type then 

            expr :: accum

          else

            raise E.Type_mismatch

        else

          raise E.Type_mismatch)
      (sort_indexed_pairs node_outputs')
      expr_list
      []

  (* Type checking error or one expression has more indexes *)
  with Invalid_argument "List.fold_right2" | E.Type_mismatch -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Type mismatch for expressions at %a"
            A.pp_print_position A.dummy_pos))



(* Return list of identifier and types to capture node outputs *)
and output_idents_of_node ident pos call_ident = function 

  (* Node must have outputs *)
  | [] ->  

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Node %a cannot be called, it does not have \
             outputs in %a" 
            (I.pp_print_ident false) ident
            A.pp_print_position pos))

  | node_outputs -> 

    (* Keep order of parameters *)
    List.fold_right
      (fun (out_ident, out_type) accum -> 

         (* Add identifier of output to identifier for node call *)
         let out_ident = 
           I.push_back_ident_index out_ident call_ident 
         in

         (* Add each suffix of indexed type and type of index *)
         List.fold_right 
           (fun (index, out_type) accum ->
              (I.push_back_index index out_ident, out_type) :: accum)
           (sort_indexed_pairs out_type)
           accum)
      node_outputs
      []


(* Add list of variables capturing the output with indexes to the result *)
and add_node_output_to_result index result = function

  (* Node must have outputs, this has been checked before *)
  | [] -> assert false

  (* Don't add index if node has a single output *)
  | [(var_ident, var_type)] -> 

    (index, E.mk_var var_ident var_type E.base_clock) :: result

  (* Add indexes to be able to sort if node has more than one output *)
  | node_output_idents -> 

    snd
      (* Add indexes to variables capturing node outputs

         Must add indexes in order *)
      (List.fold_left
         (fun (i, accum) (var_ident, var_type) -> 
            (Numeral.(succ i),
             (I.push_int_index_to_index i index, 
              E.mk_var var_ident var_type E.base_clock) :: accum))
         (Numeral.zero, result)
         node_output_idents)
      
      
      
(* ******************************************************************** *)
(* Type declarations                                                    *)
(* ******************************************************************** *)


(* Return true if type [t] has been declared in the context *)
let type_in_context { basic_types; indexed_types; free_types } t = 

  (* Check if [t] is a basic types *)
  (List.mem_assoc t basic_types) ||

  (* Check is [t] is an indexed type *)
  (List.mem_assoc t indexed_types) || 

  (* Check if [t] is a free type *)
  (List.mem t free_types) 


(* Return true if identifier [i] has been declared, raise an
   exceptions if the identifier is reserved. *)
let ident_in_context { type_ctx; index_ctx } i = 

  if 

    (* Identifier must not be reserved *)
    i = new_var_ident || i = new_call_ident 

  then
    
    raise 
      (Invalid_argument 
         (Format.asprintf 
            "Identifier %a is reserved internal use" 
            (I.pp_print_ident false) new_var_ident))

  else

    (* In type context or a nested identifier *)
    (List.mem_assoc i type_ctx) || (List.mem_assoc i index_ctx)



(* Add enum constants to context if type is an enumeration *)
let add_enum_to_context type_ctx = function

  (* Type is an enumeration *)
  | T.Enum l as basic_type -> 
    
    List.fold_left
      (fun type_ctx enum_element -> 
         
         try 
           
             (* Get type of constant *)
             let enum_element_type = List.assoc enum_element type_ctx in 

             (* Skip if constant declared with the same (enum) type *)
             if basic_type = enum_element_type then type_ctx else

               (* Fail *)
               raise 
                 (Failure 
                    (Format.asprintf 
                       "Enum constant %a declared with \
                        different type in %a" 
                       (I.pp_print_ident false) enum_element
                       A.pp_print_position A.dummy_pos));
             
           (* Constant not declared *)
           with Not_found -> 

             (* Push constant to typing context *)
             (enum_element, basic_type) :: type_ctx)
        type_ctx
        l

  (* Other basic types do not change typing context *)
  | _ -> type_ctx



(* For an identifier t = t.i1...in associate each proper prefix with
   suffix and the given value v: add (t, (i1...in, v)), ...,
   (t.i1..in-1, (in, v)) to the map. Do not add the empty suffix, that
   is, (t.i1..in-1, ([], v)).

*)
let add_to_prefix_map map ident value =

  let rec aux prefix map = function 

    (* Do not add full index to list *)
    | [] -> map

    (* [index] is second to last or earlier *)
    | index :: tl as suffix -> 

      (* Add association of suffix and type to prefix *)
      let rec aux2 accum = function

        (* Prefix of identifier not found *)
        | [] -> 

          (* Add association of prefix with suffix and value *)
          (prefix, [(I.index_of_one_index_list suffix, value)]) :: accum

        (* Prefix of identifier found *)
        | (p, l) :: tl when p = prefix -> 

          (* Add association of prefix with suffix and type, and
             finish *)
          List.rev_append
            ((p, (I.index_of_one_index_list suffix, value) :: l) :: tl) 
            accum

        (* Recurse to keep searching for prefix of identifier *)
        | h :: tl -> aux2 (h :: accum) tl

      in

      (* Add index to prefix *)
      let prefix' = I.push_one_index index prefix in

      (* Recurse for remaining suffix *)
      aux prefix' (aux2 [] map) tl

  in

  (* Get indexes of identifier of type *)
  let (ident_base, suffix) = I.split_ident ident in

  (* Add types of all suffixes *)
  aux ident_base map suffix



(* Add type declaration for an alias type to a context

   Associate possibly indexed identifier with its Lustre type;
   associate all prefixes of an indexed identifier with its suffixes
   and their basic types; and for enum type associate the enum type to
   each constant.
*)
let add_alias_type_decl 
    ident
    ({ basic_types; indexed_types; type_ctx } as context) 
    index 
    basic_type =

  (* Add index to identifier *)
  let indexed_ident = I.push_index index ident in

  (* Add alias for basic type *)
  let basic_types' = (indexed_ident, basic_type) :: basic_types in

  (* Add types of all suffixes *)
  let indexed_types' = 
    add_to_prefix_map indexed_types indexed_ident basic_type
  in

  (* Add enum constants to type context if type is an enumeration *)
  let type_ctx' = add_enum_to_context type_ctx basic_type in

  (* Changes to context *)
  { context with 
      basic_types = basic_types'; 
      indexed_types = indexed_types';
      type_ctx = type_ctx' }
  


(* Expand a possibly nested type expression to indexed basic types and
   apply [f] to each
   
   The context of the unfolding cannot be modified by f, this is a
   good thing and disallows defining types recursively. *)
let rec fold_ast_type' 
    ({ basic_types; 
       indexed_types; 
       free_types; 
       type_ctx; 
       index_ctx; 
       consts } as context)
    f 
    accum = function 

  (* All types seen *)
  | [] -> accum 

  (* Basic type Boolean *)
  | (index, A.Bool) :: tl -> 

    fold_ast_type' context f (f accum index T.t_bool) tl

  (* Basic type i *)
  | (index, A.Int) :: tl -> 

    fold_ast_type' context f (f accum index T.t_int) tl

  (* Basic type real *)
  | (index, A.Real) :: tl -> 

    fold_ast_type' context f (f accum index T.t_real) tl

  (* Integer range type needs to be constructed from evaluated
     expressions for bounds *)
  | (index, A.IntRange (lbound, ubound)) :: tl -> 

    (* Evaluate expressions for bounds to constants *)
    let const_lbound, const_ubound = 
      (int_const_of_ast_expr context lbound, 
       int_const_of_ast_expr context ubound) 
    in

    (* Construct an integer range type *)
    fold_ast_type' 
      context 
      f 
      (f accum index (T.mk_int_range const_lbound const_ubound)) 
      tl

  (* Enum type needs to be constructed *)
  | (index, A.EnumType enum_elements) :: tl -> 

    (* Construct an enum type *)
    fold_ast_type' context f (f accum index (T.mk_enum enum_elements)) tl


  (* User type that is an alias *)
  | (index, A.UserType ident) :: tl when 
      List.mem_assoc ident basic_types -> 

    (* Substitute basic type *)
    fold_ast_type' 
      context 
      f 
      (f accum index (List.assoc ident basic_types)) 
      tl


  (* User type that is an alias for an indexed type *)
  | (index, A.UserType ident) :: tl when 
      List.mem_assoc ident indexed_types -> 

    (* Apply f to basic types with index *)
    let accum' = 
      List.fold_left
        (fun a (j, s) -> f a (I.push_index_to_index index j) s)
        accum
        (List.assoc ident indexed_types)
    in

    (* Recurse for tail of list *)
    fold_ast_type' context f accum' tl


  (* User type that is a free type *)
  | (index, A.UserType ident) :: tl when 
      List.mem ident free_types -> 

    (* Substitute free type *)
    fold_ast_type' 
      context 
      f 
      (f accum index (T.mk_free_type ident)) 
      tl


  (* User type that is neither an alias nor free *)
  | (index, A.UserType ident) :: _ -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Type %a in %a is not declared" 
            (I.pp_print_ident false) ident
            A.pp_print_position A.dummy_pos))


  (* Record type *)
  | (index, A.RecordType record_fields) :: tl -> 

    (* Substitute with indexed types of fields *)
    fold_ast_type' 
      context 
      f 
      accum 
      (List.fold_left
         (fun a (j, s) -> 
            (I.push_index_to_index index (I.index_of_ident j), s) :: a)
         tl
         record_fields)


  (* Tuple type *)
  | (index, A.TupleType tuple_fields) :: tl -> 

    (* Substitute with indexed types of elements *)
    fold_ast_type' 
      context 
      f 
      accum 
      (fst
         (List.fold_left
            (fun (a, j) s -> 
               (I.push_index_to_index index (I.mk_int_index j), s) :: a, 
               Numeral.(succ j))
            (tl, Numeral.zero)
            tuple_fields))


  (* Array type *)
  | (index, A.ArrayType (type_expr, size_expr)) :: tl -> 

    (* Evaluate size of array to a constant integer *)
    let array_size = int_const_of_ast_expr context size_expr in

    (* Array size must must be at least one *)
    if Numeral.(array_size <= zero) then 

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Expression %a must be positive as array size in %a" 
              A.pp_print_expr size_expr
              A.pp_print_position A.dummy_pos));

    (* Append indexed types *)
    let rec aux accum = function
      | j when Numeral.(j = zero) -> accum
      | j -> 

        aux 
          ((I.push_index_to_index index (I.mk_int_index Numeral.(pred j)), 
            type_expr) :: 
             accum)
          Numeral.(pred j)

    in

    (* Substitute with indexed types of elements *)
    fold_ast_type' 
      context 
      f 
      accum 
      (aux tl array_size)


(* Wrapper for folding function over type expression  *)
let fold_ast_type context f accum t = 
  fold_ast_type' context f accum [(I.empty_index, t)] 


(* ******************************************************************** *)
(* Constant declarations                                                *)
(* ******************************************************************** *)


(* Add a typed or untyped constant declaration to the context *)
let add_typed_decl
    ident 
    ({ basic_types; 
       indexed_types; 
       free_types; 
       type_ctx; 
       index_ctx; 
       consts } as context) 
    expr 
    type_expr =

  try 

    (* Evaluate expression *)
    let expr_val, new_defs = 
      eval_ast_expr 

        (* Immediately fail when abstraction expressions to a
            definition *)
        (fun _ ->       
           (* Fail *)
           raise 
             (Failure 
                (Format.asprintf 
                   "Expression %a in %a must be a constant" 
                   A.pp_print_expr expr
                   A.pp_print_position A.dummy_pos))) 

        (* Immediately fail when abstraction expressions to a node
           call *)
        (fun _ ->       
           (* Fail *)
           raise 
             (Failure 
                (Format.asprintf 
                   "Expression %a in %a must be a constant" 
                   A.pp_print_expr expr
                   A.pp_print_position A.dummy_pos))) 

        context 
        ([], [])
        expr 
    in

    (match type_expr with 

      (* No type given *)
      | None -> ()

      (* Check if type of expression matches given type *)
      | Some t -> 

        fold_ast_type 
          context
          (fun () type_index def_type ->
             let { E.expr_type } = 
               try 
                 List.assoc type_index expr_val 
               with Not_found -> 
                 raise E.Type_mismatch 
             in
             if 
               T.check_type def_type expr_type 
             then
               () 
             else 
               raise E.Type_mismatch)
          ()
          t

    );

    (* Add association of identifiers to values *)
    let consts' = 
      List.fold_left
        (fun a (j, e) -> (I.push_index j ident, e) :: a)
        consts
        expr_val
    in

    (* Add association of identifiers to types *)
    let type_ctx' = 
      List.fold_left
        (fun a (j, { E.expr_type = t }) ->
           (I.push_index j ident, t) :: a)
        type_ctx
        expr_val
    in

    (* Add associations of identifiers to indexes *)
    let index_ctx' = 
      List.fold_left
        (fun a (j, _) -> 
           add_to_prefix_map a (I.push_index j ident) ())
        index_ctx
        expr_val
    in

    { context with 
        consts = consts';
        type_ctx = type_ctx';
        index_ctx = index_ctx' }

  with E.Type_mismatch -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Type mismatch for expressions at %a" 
            A.pp_print_position A.dummy_pos))

let add_const_decl context = function 

  (* Free constant *)
  | A.FreeConst (ident, _) -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Free constant not supported in %a" 
            A.pp_print_position A.dummy_pos))

  (* Constant without type *)
  | A.UntypedConst (ident, expr) -> 
    add_typed_decl ident context expr None

  (* Constant with given type *)
  | A.TypedConst (ident, expr, type_expr) -> 
    add_typed_decl ident context expr (Some type_expr)
  

(* ******************************************************************** *)
(* Node declarations                                                    *)
(* ******************************************************************** *)


(* Add declaration of a node input to contexts *)
let add_node_input_decl
    ident
    is_const
    (({ type_ctx; index_ctx } as context), 
     ({ N.inputs = node_inputs } as node))
    index 
    basic_type =
  
  (* Add index to identifier *)
  let ident' = I.push_index index ident in

  (* Add to typing context *)
  let type_ctx' = 
    (ident', basic_type) :: 
      (add_enum_to_context type_ctx basic_type) 
  in

  (* Add indexed identifier to context *)
  let index_ctx' = add_to_prefix_map index_ctx ident' () in

  (* Add to constant node inputs *)
  let node_inputs' = match node_inputs with 

    | (i, (l, c)) :: tl when i = ident -> 
      
      (ident, ((index, basic_type) :: l, c)) :: tl 
        
    | _ -> (ident, ([(index, basic_type)], is_const)) :: node_inputs 

  in

  ({ context with type_ctx = type_ctx'; index_ctx = index_ctx' }, 
   { node with N.inputs = node_inputs' })


(* Add declaration of a node output to contexts *)
let add_node_output_decl
    ident
    (({ type_ctx; index_ctx } as context), 
     ({ N.outputs = node_outputs } as node))
    index 
    basic_type =
  
  (* Add index to identifier *)
  let ident' = I.push_index index ident in

  (* Add to typing context *)
  let type_ctx' = 
    (ident', basic_type) :: 
      (add_enum_to_context type_ctx basic_type) 
  in
  
  (* Add indexed identifier to context *)
  let index_ctx' = add_to_prefix_map index_ctx ident' () in

  (* Add to constant node inputs *)
  let node_outputs' = match node_outputs with 

    | (i, l) :: tl when i = ident -> 
      
      (ident, (index, basic_type) :: l) :: tl 
        
    | _ -> (ident, [(index, basic_type)]) :: node_outputs 

  in

  ({ context with type_ctx = type_ctx'; index_ctx = index_ctx' }, 
   { node with N.outputs = node_outputs' })


(* Add declaration of a node local variable or constant to contexts *)
let add_node_var_decl
    ident
    (({ type_ctx; index_ctx } as context), 
     ({ N.locals = node_vars } as node))
    index 
    basic_type =
  
  (* Add index to identifier *)
  let ident' = I.push_index index ident in

  (* Add to typing context *)
  let type_ctx' = 
    (ident', basic_type) :: 
      (add_enum_to_context type_ctx basic_type) 
  in

  (* Add indexed identifier to context *)
  let index_ctx' = add_to_prefix_map index_ctx ident' () in

  (* Add to constant node inputs *)
  let node_vars' = match node_vars with 

    | (i, l) :: tl when i = ident -> 
      
      (ident, (index, basic_type) :: l) :: tl 
        
    | _ -> (ident, [(index, basic_type)]) :: node_vars 

  in

  ({ context with type_ctx = type_ctx'; index_ctx = index_ctx' }, 
   { node with N.locals = node_vars' })


(* Add all node inputs to contexts *)
let rec parse_node_inputs context node = function

  (* All inputs parsed, return in original order *)
  | [] -> (context, { node with N.inputs = List.rev node.N.inputs })


  (* Identifier must not be declared *)
  | (ident, _, _, _) :: _ when 

      (try 
         ident_in_context context ident 
       with Invalid_argument e -> 

         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "%s in %a" 
                 e
                 A.pp_print_position A.dummy_pos))) -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Node input %a already declared in %a" 
            (I.pp_print_ident false) ident
            A.pp_print_position A.dummy_pos))


  (* Input on the base clock *)
  | (ident, var_type, A.ClockTrue, is_const) :: tl -> 

    (* Add declaration of possibly indexed type to contexts *)
    let context', node' = 
      fold_ast_type 
        context
        (add_node_input_decl ident is_const)
        (context, node)
        var_type
    in

    (* Continue with following inputs *)
    parse_node_inputs context' node' tl

  | _ -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Clocked node inputs not supported in %a" 
            A.pp_print_position A.dummy_pos))


(* Add all node outputs to contexts *)
let rec parse_node_outputs context node = function

  (* All outputs parsed, return in original order *)
  | [] -> (context, { node with N.outputs = List.rev node.N.outputs })


  (* Identifier must not be declared *)
  | (ident, _, _) :: _ when       
      
      (try 
         ident_in_context context ident 
       with Invalid_argument e -> 
         
         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "%s in %a" 
                 e
                 A.pp_print_position A.dummy_pos))) -> 
    
    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Node output %a already declared in %a" 
            (I.pp_print_ident false) ident
            A.pp_print_position A.dummy_pos))


  (* Output on the base clock *)
  | (ident, var_type, A.ClockTrue) :: tl -> 

    (* Add declaration of possibly indexed type to contexts *)
    let context', node' = 
      fold_ast_type 
        context
        (add_node_output_decl ident)
        (context, node)
        var_type
    in

    (* Continue with following outputs *)
    parse_node_outputs context' node' tl

  | _ -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Clocked node outputs not supported in %a" 
            A.pp_print_position A.dummy_pos))



(* Add all node local declarations to contexts *)
let rec parse_node_locals context node = function

  (* All local declarations parsed, order does not matter *)
  | [] -> (context, node)


  (* Identifier must not be declared *)
  | A.NodeVarDecl (ident, _, _) :: _ 
  | A.NodeConstDecl (A.FreeConst (ident, _)) :: _
  | A.NodeConstDecl (A.UntypedConst (ident, _)) :: _
  | A.NodeConstDecl (A.TypedConst (ident, _, _)) :: _ when 

      (try 
         ident_in_context context ident 
       with Invalid_argument e -> 

         (* Fail *)
         raise 
           (Failure 
              (Format.asprintf 
                 "%s in %a" 
                 e
                 A.pp_print_position A.dummy_pos))) -> 


    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Node local variable or constant %a already declared in %a" 
            (I.pp_print_ident false) ident
            A.pp_print_position A.dummy_pos))


  (* Output on the base clock *)
  | A.NodeVarDecl (ident, var_type, A.ClockTrue) :: tl -> 

    (* Add declaration of possibly indexed type to contexts *)
    let context', node' = 
      fold_ast_type 
        context
        (add_node_var_decl ident)
        (context, node)
        var_type
    in

    (* Continue with following outputs *)
    parse_node_locals context' node' tl

  |  A.NodeVarDecl (ident, _, _) :: _ -> 

    (* Fail *)
    raise 
      (Failure 
         (Format.asprintf 
            "Clocked node local variables not supported for %a in %a" 
            (I.pp_print_ident false) ident
            A.pp_print_position A.dummy_pos))


  | A.NodeConstDecl const_decl :: tl -> 

    let context' = add_const_decl context const_decl in

    (* Continue with following outputs *)
    parse_node_locals context' node tl


(* Add abstracted variables and node calls to context *)
let new_defs_to_context context node (vars, calls) =

  let context', node' = 

    List.fold_left 
      (fun (context, node) (ident, { E.expr_type }) -> 
         let (base_ident, index) = I.split_ident ident in
         add_node_var_decl 
           base_ident
           (context, node)
           (I.index_of_one_index_list index)
           expr_type)
      (context, node)
      vars

  in

  List.fold_left
    (fun accum (outputs, _, _, _, _) ->
       List.fold_left 
         (fun (context, node) (ident, expr_type) -> 
            let (base_ident, index) = I.split_ident ident in
            add_node_var_decl 
              base_ident
              (context, node)
              (I.index_of_one_index_list index)
              expr_type)
         accum
         outputs)
    (context', node')
    calls


(* Parse a statement (equation, assert or annotation) in a node *)
let rec parse_node_equations 
    mk_new_var_ident
    mk_new_call_ident 
    context 
    node = 

  function

    | [] -> node 

    (* Assertion *)
    | A.Assert ast_expr :: tl -> 

      (* Evaluate expression *)
      let expr', ((new_vars, new_calls) as new_defs) = 
        eval_ast_expr 
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          ([], []) 
          ast_expr 
      in

      (* Add new definitions to context *)
      let context', node' = new_defs_to_context context node new_defs in

      (* Check evaluated expression *)
      (match expr' with 

        (* Boolean expression without indexes *)
        | [ index, 
            ({ E.expr_init; 
               E.expr_step; 
               E.expr_type = T.Bool } as expr) ] when 
            index = I.empty_index -> 


          if E.pre_is_unguarded expr then 

            Format.printf 
              "@[<h>Warning: unguarded pre in %a in %a@]@." 
              A.pp_print_expr ast_expr
              A.pp_print_position A.dummy_pos;

          parse_node_equations 
            mk_new_var_ident 
            mk_new_call_ident 
            context'
            { node' with 
                N.asserts = (expr :: node.N.asserts); 
                N.equations = new_vars @ node.N.equations; 
                N.calls = new_calls @ node.N.calls }
            tl

        (* Expression is not Boolean or is indexed *)
        | _ -> 

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Assertion is not of Boolean type in %a" 
                  A.pp_print_position A.dummy_pos)))


    (* Property annotation *)
    | A.AnnotProperty ast_expr :: tl -> 

      (* Evaluate expression *)
      let expr', ((new_vars, new_calls) as new_defs) = 
        eval_ast_expr 
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          ([], []) 
          ast_expr 
      in

      (* Add new definitions to context *)
      let context', node' = new_defs_to_context context node new_defs in

      (* Check evaluated expression *)
      (match expr' with 

        (* Boolean expression without indexes *)
        | [ index, 
            ({ E.expr_init; 
               E.expr_step; 
               E.expr_type = T.Bool } as expr) ] when 
            index = I.empty_index -> 

          if E.pre_is_unguarded expr then 

            Format.printf 
              "@[<h>Warning: unguarded pre in %a in %a@]@." 
              A.pp_print_expr ast_expr
              A.pp_print_position A.dummy_pos;

          parse_node_equations 
            mk_new_var_ident 
            mk_new_call_ident 
            context' 
            { node' with 
                N.props = (expr :: node.N.props); 
                N.equations = new_vars @ node.N.equations; 
                N.calls = new_calls @ node.N.calls }
            tl

        (* Expression is not Boolean or is indexed *)
        | _ -> 

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Property is not of Boolean type in %a" 
                  A.pp_print_position A.dummy_pos)))


    (* Equations with more than one variable on the left-hand side *)
    | A.Equation (struct_items, ast_expr) :: tl -> 

      (* Evaluate expression *)
      let expr', ((new_vars, new_calls) as new_defs) = 
        eval_ast_expr 
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          ([], []) 

          (* Wrap right-hand side in a singleton list, nested lists
             are flattened, s.t. ((a,b)) become (a,b) *)
          (A.ExprList (A.dummy_pos, [ast_expr]))
      in

      if 

        List.exists 
          (function (_, e) -> E.pre_is_unguarded e) 
          expr' 

      then 

        Format.printf 
          "@[<h>-- Warning: unguarded pre in %a in %a@]@." 
          A.pp_print_expr ast_expr
          A.pp_print_position A.dummy_pos;

      let eq_types = 
        List.rev
          (snd
             (List.fold_left 
                (fun (i, accum) -> function

                   | A.SingleIdent ident -> 

                     let ident_types =

                       sort_indexed_pairs

                         (try 

                            (* Return type if assigning to an output *)
                            List.assoc ident node.N.outputs 

                          with Not_found -> 

                            (* Return type if assigning to a local variable *)
                            try List.assoc ident node.N.locals

                            with Not_found -> 

                              (* Fail *)
                              raise 
                                (Failure 
                                   (Format.asprintf 
                                      "Equation does not assign to output \
                                       or local variable in %a" 
                                      A.pp_print_position A.dummy_pos)))

                     in

                     (succ i,
                      List.fold_left 
                        (fun accum (index, ident_type) -> 
                           (I.push_index index ident, ident_type) :: accum)
                        accum
                        ident_types)

                   | _ -> 

                     (* Fail *)
                     raise 
                       (Failure 
                          (Format.asprintf 
                             "Assignments not supported in %a" 
                             A.pp_print_position A.dummy_pos)))
                (0, [])
                struct_items))
      in

      let node' = 

        List.fold_right2

          (fun 
            (ident, ident_type) 
            (_, ({ E.expr_type } as expr)) 
            node -> 

            (* Do not check for matching indexes here, the best thing
               possible is to compare suffixes, but it is not obvious, where
               to start suffix at *)
            let eq = (ident, expr) in

            (* Type must be a subtype of declared type *)
            if T.check_type expr_type ident_type then

              (* Add equation *)
              { node with N.equations = eq :: node.N.equations }

            else

              (* Type of expression may not be subtype of
                 declared type *)
              (match ident_type, expr_type with 

                (* Declared type is integer range,
                   expression is of type integer *)
                | T.IntRange (lbound, ubound), T.Int -> 

                  (* Value of expression is in range of
                     declared type: lbound <= expr and
                     expr <= ubound *)
                  let range_expr = 
                    (E.mk_and 
                       (E.mk_lte (E.mk_int lbound) expr) 
                       (E.mk_lte expr (E.mk_int ubound)))
                  in

                  
                  let aux = 
                    fun (i, l) -> 
                      (i, 
                       List.map
                         (fun (j, t) -> 
                            if I.push_index j i = ident then
                              (j, T.t_int)
                            else
                              (j, t))
                         l)
                  in

                  let node_outputs' = List.map aux node.N.outputs in
                  
                  let node_vars' = List.map aux node.N.locals in

(*
              Format.printf 
                "@[<v>Expression may not be in \
                 subrange of variable. \
                 Need to add property@;%a@]@."
                E.pp_print_lustre_expr range_expr;
*)
                  { node with 
                      N.outputs = node_outputs';
                      N.locals = node_vars';
                      N.equations = eq :: node.N.equations;
                      N.props = range_expr :: node.N.props } 

                | _ -> 

                  (* Fail *)
                  raise 
                    (Failure 
                       (Format.asprintf 
                          "Type mismatch for expressions at %a" 
                          A.pp_print_position A.dummy_pos))))

          eq_types
          expr'
          node

      in

      (* Add new definitions to context *)
      let context'', node'' = new_defs_to_context context node' new_defs in

      parse_node_equations 
        mk_new_var_ident 
        mk_new_call_ident 
        context''
        { node'' with
            N.equations = new_vars @ node''.N.equations; 
            N.props = node''.N.props; 
            N.calls = new_calls @ node''.N.calls }
        tl


    (* Annotation for main node *)
    | A.AnnotMain :: tl -> 

      parse_node_equations 
        mk_new_var_ident 
        mk_new_call_ident 
        context 
        { node with N.is_main = true }
        tl


(* Parse a contract annotation of a node *)
let rec parse_node_contract 
    mk_new_var_ident 
    mk_new_call_ident
    context 
    node = 

  function

    | [] -> node 

    (* Assumption *)
    | A.Requires expr :: tl -> 

      (* Evaluate expression *)
      let expr', ((new_vars, new_calls) as new_defs) = 
        eval_ast_expr 
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          ([], []) 
          expr 
      in

      (* Add new definitions to context *)
      let context', node' = new_defs_to_context context node new_defs in

      (* Check evaluated expression *)
      (match expr' with 

        (* Boolean expression without indexes *)
        | [ index, 
            ({ E.expr_init; 
               E.expr_step; 
               E.expr_type = T.Bool } as expr) ] when 
            index = I.empty_index -> 

          parse_node_contract 
            mk_new_var_ident 
            mk_new_call_ident 
            context' 
            { node' with 
                N.requires = (expr :: node.N.requires); 
                N.equations = new_vars @ node.N.equations; 
                N.calls = new_calls @ node.N.calls }
            tl

        (* Expression is not Boolean or is indexed *)
        | _ -> 

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Requires clause is not of Boolean type in %a" 
                  A.pp_print_position A.dummy_pos)))

    (* Guarantee *)
    | A.Ensures expr :: tl -> 

      (* Evaluate expression *)
      let expr', ((new_vars, new_calls) as new_defs) = 
        eval_ast_expr 
          mk_new_var_ident 
          mk_new_call_ident 
          context 
          ([], []) 
          expr 
      in

      (* Add new definitions to context *)
      let context', node' = new_defs_to_context context node new_defs in

      (* Check evaluated expression *)
      (match expr' with 

        (* Boolean expression without indexes *)
        | [ index, 
            ({ E.expr_init; 
               E.expr_step; 
               E.expr_type = T.Bool } as expr) ] when 
            index = I.empty_index -> 

          parse_node_contract 
            mk_new_var_ident 
            mk_new_call_ident 
            context' 
            { node' with 
                N.ensures = (expr :: node.N.ensures); 
                N.equations = new_vars @ node.N.equations;
                N.calls = new_calls @ node.N.calls }
            tl

        (* Expression is not Boolean or is indexed *)
        | _ -> 

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Ensures clause is not of Boolean type in %a" 
                  A.pp_print_position A.dummy_pos)))


let parse_node_signature  
    node_ident
    global_context
    inputs 
    outputs 
    locals 
    equations 
    contract =

  let mk_new_var_ident = 
    let r = ref Numeral.(- one) in
    fun () -> Numeral.incr r; I.push_int_index !r new_var_ident
  in

  let rec mk_new_call_ident =
    let l = ref [] in
    fun ident -> 
      try 
        let r = List.assoc ident !l in
        Numeral.(incr r);
        I.push_back_int_index !r (I.push_back_ident_index ident new_call_ident) 
      with Not_found -> 
        l := (ident, ref Numeral.(- one)) :: !l;
        mk_new_call_ident ident
  in

  (* Parse inputs, add to global context and node context *)
  let local_context_inputs, node_context_inputs = 
    parse_node_inputs global_context N.empty_node inputs
  in

  (* Parse outputs, add to local context and node context *)
  let local_context_outputs, node_context_outputs = 
    parse_node_outputs local_context_inputs node_context_inputs outputs
  in

  (* Parse contract

     Must check here, may not use local variables *)
  let node_context_contract = 
    parse_node_contract 
      mk_new_var_ident 
      mk_new_call_ident 
      local_context_outputs 
      node_context_outputs 
      contract
  in

  (* Parse local declarations, add to local context and node context *)
  let local_context_locals, node_context_locals = 
    parse_node_locals local_context_outputs node_context_contract locals
  in

  (* Parse equations and assertions, add to node context, local
     context is not modified *)
  let node_context_equations = 
    parse_node_equations 
      mk_new_var_ident 
      mk_new_call_ident 
      local_context_locals 
      node_context_locals 
      equations
  in

  (*
  Format.printf "%a@." pp_print_lustre_context local_context_locals;
*)

  let node_context_equations = N.solve_eqs_node_calls node_context_equations in

  let var_dep = 
    N.node_var_dependencies 
      false 
      global_context.nodes
      node_context_equations
      []
      ((List.map (fun (v, _) -> (v, [])) node_context_equations.N.equations) @
       (List.map (fun (v, _) -> (v, [])) node_context_equations.N.outputs))
  in

  Format.printf "@[<v>%a@]@."
    (pp_print_list 
      (fun ppf (v, d) ->
        Format.fprintf ppf 
          "@[<h>%a:@ %a@]"
          (I.pp_print_ident false) v 
          (pp_print_list 
             (I.pp_print_ident false)
             " ")
          (ISet.elements d))
      "@,")
    var_dep;

  let node_context_deps = 
    { node_context_equations with 
        N.output_input_dep = 
          N.output_input_dep_of_var_dep 
            node_context_equations 
            var_dep } 
  in

  let equations_sorted =
    List.sort
      (fun (v1, _) (v2, _) -> 
         if ISet.mem v1 (List.assoc v2 var_dep) then (- 1) 
         else if ISet.mem v2 (List.assoc v1 var_dep) then 1 
         else I.compare v1 v2)
      node_context_deps.N.equations
  in

  let node_context_dep_order =
    { node_context_deps with N.equations = equations_sorted }
  in

  Format.printf "%a@." (N.pp_print_node true node_ident) node_context_dep_order;

  node_context_dep_order

(* ******************************************************************** *)
(* Main                                                                 *)
(* ******************************************************************** *)

let rec check_declarations
    ({ basic_types; 
       indexed_types; 
       free_types; 
       type_ctx; 
       index_ctx; 
       consts; 
       nodes } as global_context) = 

  function

    (* All declarations processed, return result *)
    | [] -> global_context


    (* Declaration of a type as alias or free *)
    | (A.TypeDecl (A.AliasType (ident, _) as type_decl)) :: decls
    | (A.TypeDecl (A.FreeType ident as type_decl)) :: decls -> 

      if       

        (* Type t must not be declared *)
        type_in_context global_context ident

      then

        (* Fail *)
        raise 
          (Failure 
             (Format.asprintf 
                "Type %a is redeclared in %a" 
                (I.pp_print_ident false) ident
                A.pp_print_position A.dummy_pos));

      (* Change context with alias type declaration *)
      let global_context' = match type_decl with 

        (* Identifier is an alias for a type *)
        | A.AliasType (ident, type_expr) -> 

          (* Add alias type declarations for the possibly indexed
             type expression *)
          let global_context' = 
            fold_ast_type 
              global_context
              (add_alias_type_decl ident) 
              global_context 
              type_expr
          in

          (* Return changed context and unchanged declarations *)
          global_context'

        (* Identifier is a free type *)
        | A.FreeType ident -> 

          (* Add type identifier to free types *)
          let free_types' = ident :: free_types in

          (* Changes to global context *)
          { global_context with free_types = free_types' }

      in

      (* Recurse for next declarations *)
      check_declarations global_context' decls


    (* Declaration of a typed, untyped or free constant *)
    | (A.ConstDecl (A.FreeConst (ident, _) as const_decl)) :: decls 
    | (A.ConstDecl (A.UntypedConst (ident, _) as const_decl)) :: decls 
    | (A.ConstDecl (A.TypedConst (ident, _, _) as const_decl)) :: decls ->

      if


        (try 

           (* Identifier must not be declared *)
           ident_in_context global_context ident 

         with Invalid_argument e -> 

           (* Fail *)
           raise 
             (Failure 
                (Format.asprintf 
                   "%s in %a" 
                   e
                   A.pp_print_position A.dummy_pos)))

      then

        (* Fail *)
        raise 
          (Failure 
             (Format.asprintf 
                "Identifier %a is redeclared as constant in %a" 
                (I.pp_print_ident false) ident
                A.pp_print_position A.dummy_pos));

      (* Change context with constant declaration *)
      let global_context' = 
        add_const_decl global_context const_decl 
      in

      (* Recurse for next declarations *)
      check_declarations global_context' decls


    (* Node declaration without parameters *)
    | (A.NodeDecl 
         (node_ident, 
          [], 
          inputs, 
          outputs, 
          locals, 
          equations, 
          contract)) :: decls ->

      (try 

        (* Add declarations to global context *)
        let node_context = 
          parse_node_signature
            node_ident
            global_context 
            inputs 
            outputs
            locals
            equations 
            contract
        in
        
        (* Recurse for next declarations *)
        check_declarations 
          { global_context with 
              nodes = (node_ident, node_context) :: nodes }
          decls

       (* Forward reference in node *)
       with Forward_reference (ident, pos) -> 

        if 

          (* Is the referenced node declared later? *)
          List.exists 
            (function 
              | A.NodeDecl (i, _, _, _, _, _, _) when i = ident -> true 
              | _ -> false)
            decls

        then

          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Node %a is forward referenced in %a" 
                  (I.pp_print_ident false) ident
                  A.pp_print_position pos))
      
        else
          
          (* Fail *)
          raise 
            (Failure 
               (Format.asprintf 
                  "Node %a is not defined in %a" 
                  (I.pp_print_ident false) ident
                  A.pp_print_position pos)))



    (* Node declaration without parameters *)
    | (A.FuncDecl _) :: _ ->

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Functions not supported in %a" 
              A.pp_print_position A.dummy_pos))


    (* Node declaration without parameters *)
    | (A.NodeParamInst _) :: _
    | (A.NodeDecl _) :: _ ->

      (* Fail *)
      raise 
        (Failure 
           (Format.asprintf 
              "Parametric nodes not supported in %a" 
              A.pp_print_position A.dummy_pos))


let check_program p = 

  let global_context = check_declarations init_lustre_context p in

  ()

  (* Format.printf "%a@." pp_print_lustre_context global_context
  *)


(* 
   Local Variables:
   compile-command: "make -C .. lustre-checker"
   indent-tabs-mode: nil
   End: 
*)
  
