(* Various operations on types that only arise during typechecking. *)
open Common
open Common_types
open Common.Source_code


(* Tries to ensure that a type is treated as unrestricted. All base types are
   unrestricted. Output mailbox types cannot be made unrestricted. Input mailbox
   types are unrestricted if they are equivalent to 1.
 *)
let make_unrestricted t pos =
    let open Type in
    match t with
        (* Trivially unrestricted *)
        | Base _
        | Tuple []
        | TVar _
        | Fun { linear = false; _ } -> Constraint_set.empty
        (* Cannot be unrestricted *)
        | Fun { linear = true; _ }
        | Mailbox { capability = Capability.In; _ } ->
            Gripers.cannot_make_unrestricted t [pos]
        (* Generate a pattern constraint in order to ensure linearity *)
        | Mailbox { capability = Capability.Out; pattern = Some pat; _ } ->
                Constraint_set.of_list
                    [Constraint.make (Pattern.One) pat]
        | _ -> assert false

(* Auxiliary definitions*)
let substitute_types xs ys =
  let rec subst_aux varmap t =
    match t with
    | Type.TVar _ ->
      begin match List.assoc_opt t varmap with
        | None -> t
        | Some t' -> t'
      end
    | Base _ -> t
    | Fun { linear; typarams; args; result } ->
      Fun { linear;
            typarams;
            args=(List.map (subst_aux varmap) args);
            result=(subst_aux varmap result)
          }
    | Tuple ts -> Tuple (List.map (subst_aux varmap) ts)
    | Sum (t1, t2) ->
        Sum (subst_aux varmap t1, subst_aux varmap t2)
    | Mailbox { capability; interface=(iname, tyargs); pattern; quasilinearity } ->
      let tyargs' = List.map (subst_aux varmap) tyargs in
      Mailbox { capability; interface=(iname, tyargs'); pattern; quasilinearity }

  in subst_aux (List.combine xs ys)

(* Checks whether t1 is a subtype of t2, and produces the necessary constraints.
   We need to take a coinductive view of subtyping to avoid infinite loops, so
   we track the visited interface names.
 *)
let rec subtype_type :
    (interface_name * interface_name) list ->
        Interface_env.t -> Type.t -> Type.t -> Position.t -> Constraint_set.t =
    fun visited ienv t1 t2 pos ->
        match t1, t2 with
            | Base b1, Base b2 when b1 = b2 ->
              Constraint_set.empty
            | TVar s1, TVar s2 when s1 = s2 ->
              Constraint_set.empty
            (* Subtyping covariant for tuples and sums *)
            | Tuple tyas, Tuple tybs ->
                Constraint_set.union_many
                    (List.map (fun (tya, tyb) -> subtype_type visited ienv tya tyb pos) 
                        (List.combine tyas tybs))
            | Sum (tya1, tya2), Sum (tyb1, tyb2) ->
                Constraint_set.union
                    (subtype_type visited ienv tya1 tyb1 pos)
                    (subtype_type visited ienv tya2 tyb2 pos)
            | Mailbox { pattern = None; _ }, _
            | _, Mailbox { pattern = None; _ } ->
                    (* Should have been sorted by annotation pass *)
                    assert false
            | Fun { linear = lin1; args = args1;
                    result = body1; _ },
              Fun { linear = lin2; args = args2;
                    result = body2; _ } ->
                    let () =
                        if lin1 <> lin2 then
                            Gripers.subtype_linearity_mismatch t1 t2 [pos]
                    in
                    (* Args contravariant; body covariant *)
                    let args_constrs =
                        List.map2 (fun a2 a1 -> subtype_type visited ienv a2 a1 pos) args2 args1
                        |> Constraint_set.union_many in
                    let body_constrs = subtype_type visited ienv body1 body2 pos in
                    Constraint_set.union args_constrs body_constrs
            | Mailbox {
                capability = capability1;
                interface = (iname1, _);
                pattern = Some pat1;
                quasilinearity = ql1
              },
              Mailbox {
                capability = capability2;
                interface = (iname2, _);
                pattern = Some pat2;
                quasilinearity = ql2
              } ->
                  (* First, ensure interface subtyping *)
                  let interface1 = WithPos.node (Interface_env.lookup iname1 ienv []) in
                  let interface2 =  WithPos.node (Interface_env.lookup iname2 ienv []) in
                  let () =
                      if not (Type.Quasilinearity.is_sub ql1 ql2) then
                          Gripers.quasilinearity_mismatch t1 t2 [pos]
                  in
                  let iface_constraints =
                      subtype_interface visited ienv interface1 interface2 pos in
                  let pat_constraints =
                      if capability1 = capability2 then
                          match capability1 with
                            | In ->
                                (* Input types are covariant *)
                                Constraint_set.single_constraint pat1 pat2
                            | Out ->
                                (* Output types are contravariant *)
                                Constraint_set.single_constraint pat2 pat1
                      else
                          Gripers.subtype_cap_mismatch t1 t2 [pos]
                  in
                  Constraint_set.union iface_constraints pat_constraints
            | _, _ ->
                Gripers.subtype_mismatch t1 t2 [pos]

and subtype_interface :
    (interface_name * interface_name) list ->
        Interface_env.t -> Interface.t -> Interface.t -> Position.t -> Constraint_set.t =
        fun visited ienv i1 i2 pos ->
            if List.mem (Interface.name i1, Interface.name i2) visited then
                Constraint_set.empty
            else
                (* Interface i1 is a subtype of interface i2 if i2 supports all
                 messages that i1 supports, and the payloads of i1's messages
                 are subtypes of those of i2. *)
                let visited = (Interface.name i1, Interface.name i2) :: visited in
                List.fold_left (fun acc (tag, payloads1) ->
                    let payloads2 = Interface.lookup tag i2 in
                    List.combine payloads1 payloads2
                    |> List.map (fun (p1, p2) -> subtype_type visited ienv p1 p2 pos)
                    |> Constraint_set.union_many
                    |> Constraint_set.union acc
                ) Constraint_set.empty (Interface.bindings i1)

(** subtype ienv t1 t2 checks whether t1 is a subtype of t2, and generates the
    relevant set of constraints. Wraps around subtype_type. *)
let subtype = subtype_type []
