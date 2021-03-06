(*
 * Copyright (C) 2009-2015 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Sexplib.Std
open Lvm_internal
open Absty
open Expect
open Result

module Status = struct
  type t = 
    | Read
    | Write
    | Visible
  with sexp
	
  let to_string = function
    | Read -> "READ"
    | Write -> "WRITE"
    | Visible -> "VISIBLE"

  let of_string = function
    | "READ" -> return Read
    | "WRITE" -> return Write
    | "VISIBLE" -> return Visible
    | x -> fail (Printf.sprintf "Bad LV status string: %s" x)
end

module Linear = struct
  type t = {
    name : Pv.Name.t;
    start_extent : int64;
  } with sexp
end

module Segment = struct
  type cls = 
  | Linear of Linear.t 

  and t = {
    start_extent : int64; 
    extent_count : int64;
    cls : cls;
  }
  with sexp

  type ts = t list with sexp_of

  let sort s =
    List.sort (fun s1 s2 -> compare s1.start_extent s2.start_extent) s

  let of_metadata name config =
    expect_mapped_int "start_extent" config >>= fun start_extent ->
    expect_mapped_int "extent_count" config >>= fun extent_count ->
    expect_mapped_string "type" config >>= fun ty ->
    ( if ty = "striped" then return ty
      else fail (Printf.sprintf "Cannot handle LV segment type '%s'" ty) ) >>= fun ty ->
    expect_mapped_array "stripes" config >>= fun stripes ->
    ( match stripes with
      | [ name; offset ] ->
        expect_string "name" name >>= fun name ->
        expect_int "offset" offset >>= fun start_extent ->
        Pv.Name.of_string name >>= fun name ->
        return (Linear { Linear.name; start_extent })
      | _ ->
        fail "Striping not supported" ) >>= fun cls ->
    return { start_extent; extent_count; cls }

  let to_allocation s = match s.cls with
    | Linear l ->
	[(l.Linear.name, (l.Linear.start_extent, s.extent_count))]

  let linear s_start_extent ss =
    let rec loop acc ss s_start_extent = match ss with
    | a::ss ->
      let start_extent = Pv.Allocator.get_start a in
      let extent_count = Pv.Allocator.get_size a in
      let name = Pv.Allocator.get_name a in
      let cls = Linear { Linear.name; start_extent; } in
      loop ({ start_extent = s_start_extent; cls; extent_count } :: acc) ss  (Int64.add s_start_extent extent_count)
    | [] -> List.rev acc in
    loop [] ss s_start_extent

end

type t = {
  name : string;
  id : Uuid.t;
  tags : Name.Tag.t list;
  status : Status.t list;
  creation_host: string;
  creation_time: int64;
  segments : Segment.t list;
} with sexp

open Result

let iteri f list = ignore (List.fold_left (fun i x -> f i x; i+1) 0 list)

let comp f g x = f (g x)
let (++) f g x = comp f g x

let marshal lv b =
  let ofs = ref 0 in
  let bprintf fmt = Printf.kprintf (fun s ->
    let len = String.length s in
    Cstruct.blit_from_string s 0 b !ofs len;
    ofs := !ofs + len
  ) fmt in
  bprintf "\n%s {\nid = \"%s\"\nstatus = [%s]\n" lv.name (Uuid.to_string lv.id)
    (String.concat ", " (List.map (o quote Status.to_string) lv.status));
  if List.length lv.tags > 0 then 
    bprintf "tags = [%s]\n" (String.concat ", " (List.map (quote ++ Name.Tag.to_string) lv.tags));
  bprintf "creation_host = \"%s\"\n" lv.creation_host;
  bprintf "creation_time = %Ld\n" lv.creation_time;
  bprintf "segment_count = %d\n\n" (List.length lv.segments);
  let open Segment in
  iteri
    (fun i s -> 
      bprintf "segment%d {\nstart_extent = %Ld\nextent_count = %Ld\n\n"
	(i+1) s.start_extent s.extent_count;
       match s.cls with
	 | Linear l ->
	     bprintf "type = \"striped\"\nstripe_count = 1\t#linear\n\n";
	     bprintf "stripes = [\n\"%s\", %Ld\n]\n}\n" (Pv.Name.to_string l.Linear.name) l.Linear.start_extent;
     ) lv.segments;
  bprintf "}\n";
  Cstruct.shift b !ofs

(** Builds a logical_volume structure out of a name and metadata. *)
let of_metadata name config =
  expect_mapped_string "id" config >>= fun id ->
  Uuid.of_string id >>= fun id ->
  map_expected_mapped_array "status"
    (fun a ->
      expect_string "status" a >>= fun x ->
      Status.of_string x
    ) config >>= fun status ->
  (if List.mem_assoc "tags" config
   then map_expected_mapped_array "tags" (expect_string "tags") config
   else return []) >>= fun tags ->
  all @@ List.map Name.Tag.of_string tags >>= fun tags ->
  expect_mapped_string "creation_host" config >>= fun creation_host ->
  expect_mapped_int "creation_time" config >>= fun creation_time ->
  let segments = filter_structs config in
  Result.all (List.map (fun (a, _) ->
    expect_mapped_struct a segments >>= fun x ->
    Segment.of_metadata a x) segments) >>= fun segments ->
  let segments = Segment.sort segments in
  return { name; id; status; tags; creation_host; creation_time; segments }

let to_allocation lv =
  List.flatten 
    (List.map Segment.to_allocation lv.segments)

let size_in_extents lv =
  List.fold_left (Int64.add) 0L
    (List.map (fun seg -> seg.Segment.extent_count) lv.segments)

let find_extent lv e =
  (* XXX: we need a more efficient structure than a list *)
  List.fold_left (fun acc x -> match acc, x with
    | Some x, _ -> Some x
    | None, { Segment.start_extent = s; extent_count = l } ->
      if s <= e && e <= (Int64.add s l)
      then Some x
      else None
    ) None lv.segments
 
let reduce_size_to lv new_seg_count =
  let rec doit segs left acc =
    match segs with 
      | s::ss ->
	  if left > s.Segment.extent_count then
	    doit ss (Int64.sub left s.Segment.extent_count) (s::acc)
	  else
	    {s with Segment.extent_count = left}::acc
      | _ -> acc
  in
  return {lv with segments = Segment.sort (doit lv.segments new_seg_count [])}
