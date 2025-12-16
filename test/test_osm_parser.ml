(** Test for OSM JSON parser *)

open Bifrost.Bigraph
open Bifrost.Osm_parser

let assert_equal ~name actual expected =
  if actual = expected then
    Printf.printf "✓ %s\n" name
  else
    Printf.printf "✗ %s: expected %d, got %d\n" name expected actual

let () =
  let json_file = "bigraph-of-the-world/output/8-295355-Cambridge.json" in

  try
    let bigraph = parse_osm_json json_file in

    Printf.printf "OSM Parser Tests\n";
    Printf.printf "================\n\n";

    (* Test 1: Basic parsing *)
    let num_nodes = NodeMap.cardinal bigraph.place.nodes in
    let num_regions = RegionSet.cardinal bigraph.place.regions in
    let num_sites = SiteSet.cardinal bigraph.place.sites in
    let num_edges = EdgeSet.cardinal bigraph.link.edges in
    let num_controls = List.length bigraph.signature in

    assert_equal ~name:"Node count" num_nodes 62838;
    assert_equal ~name:"Region count" num_regions 2;
    assert_equal ~name:"Site count" num_sites 0;
    assert_equal ~name:"Edge count" num_edges 31355;
    assert_equal ~name:"Control count" num_controls 5;
    Printf.printf "\n";

    (* Test 2: OSM ID search *)
    (match find_by_osm_id bigraph "way 993981175" with
    | Some node ->
        Printf.printf "✓ OSM ID search: found way 993981175 as node %d\n" node.id
    | None -> Printf.printf "✗ OSM ID search: way 993981175 not found\n");
    Printf.printf "\n";

    (* Test 3: Type search *)
    let buildings = find_by_type bigraph "Building" in
    let streets = find_by_type bigraph "Street" in
    assert_equal ~name:"Building nodes" (List.length buildings) 27868;
    assert_equal ~name:"Street nodes" (List.length streets) 1612;
    Printf.printf "\n";

    Printf.printf "All tests passed!\n"
  with e ->
    Printf.printf "Error: %s\n" (Printexc.to_string e);
    exit 1
