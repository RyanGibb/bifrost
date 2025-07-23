open Bifrost.Bigraph
open Bifrost.Utils
open Bifrost.Matching

(* Test helper functions *)
let _create_simple_bigraph signature nodes parent_relations =
  let bigraph = empty_bigraph signature in
  (* Add all nodes first *)
  let bigraph = List.fold_left add_node_to_root bigraph nodes in
  (* Then establish parent relationships *)
  List.fold_left (fun bg (child_id, parent_id) ->
    move_node bg child_id parent_id
  ) bigraph parent_relations

let assert_equal_int expected actual msg =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %d, got %d" msg expected actual)

let assert_equal_bool expected actual msg =
  if expected <> actual then
    failwith (Printf.sprintf "%s: expected %b, got %b" msg expected actual)

let assert_some opt msg =
  match opt with
  | Some x -> x
  | None -> failwith (Printf.sprintf "%s: expected Some, got None" msg)

let _assert_none opt msg =
  match opt with
  | None -> ()
  | Some _ -> failwith (Printf.sprintf "%s: expected None, got Some" msg)

(* Test 1: Basic structural matching *)
let test_basic_structural_matching () =
  Printf.printf "Testing basic structural matching...\n";
  
  let signature = [create_control "A" 0; create_control "B" 0] in
  
  (* Pattern: just node A *)
  let pattern_node = create_node 100 (create_control "A" 0) in
  let pattern_bg = add_node_to_root (empty_bigraph signature) pattern_node in
  let pattern = {
    bigraph = pattern_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Target: nodes A and B *)
  let target_a = create_node 1 (create_control "A" 0) in
  let target_b = create_node 2 (create_control "B" 0) in
  let target_bg = add_node_to_root (add_node_to_root (empty_bigraph signature) target_a) target_b in
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Should match A in target *)
  let match_result = match_pattern pattern target in
  assert_equal_int 1 (List.length match_result.node_mapping) "Should have one mapping";
  let (pattern_id, target_id) = List.hd match_result.node_mapping in
  assert_equal_int 100 pattern_id "Pattern node ID should be 100";
  assert_equal_int 1 target_id "Target node ID should be 1";
  
  Printf.printf "Basic structural matching passed!\n\n"

(* Test 2: Spatial relationship matching *)
let test_spatial_relationship_matching () =
  Printf.printf "Testing spatial relationship matching...\n";
  
  let signature = [create_control "Container" 0; create_control "Item" 0] in
  
  (* Pattern: Container[Item] *)
  let pattern_container = create_node 100 (create_control "Container" 0) in
  let pattern_item = create_node 101 (create_control "Item" 0) in
  let pattern_bg = empty_bigraph signature in
  let pattern_bg = add_node_to_root pattern_bg pattern_container in
  let pattern_bg = add_node_as_child pattern_bg 100 pattern_item in
  let pattern = {
    bigraph = pattern_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Target: Container1[Item1], Container2 *)
  let target_container1 = create_node 1 (create_control "Container" 0) in
  let target_container2 = create_node 2 (create_control "Container" 0) in
  let target_item1 = create_node 3 (create_control "Item" 0) in
  let target_bg = empty_bigraph signature in
  let target_bg = add_node_to_root target_bg target_container1 in
  let target_bg = add_node_to_root target_bg target_container2 in
  let target_bg = add_node_as_child target_bg 1 target_item1 in
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Should match Container1[Item1] *)
  let match_result = match_pattern pattern target in
  assert_equal_int 2 (List.length match_result.node_mapping) "Should have two mappings";
  
  (* Check that spatial relationships are preserved *)
  let find_mapping pattern_id = 
    List.find (fun (p_id, _) -> p_id = pattern_id) match_result.node_mapping |> snd in
  let container_target_id = find_mapping 100 in
  let item_target_id = find_mapping 101 in
  
  (* Verify parent-child relationship is preserved *)
  let item_parent = get_parent target.bigraph item_target_id in
  assert_equal_int container_target_id (assert_some item_parent "Item should have parent") 
    "Item's parent should be the matched container";
  
  Printf.printf "Spatial relationship matching passed!\n\n"

(* Test 3: Context extraction *)
let test_context_extraction () =
  Printf.printf "Testing context extraction...\n";
  
  let signature = [create_control "Room" 0; create_control "Person" 1] in
  
  (* Pattern: Room[Person] - to match the spatial structure in target *)
  let pattern_room = create_node 100 (create_control "Room" 0) in
  let pattern_person = create_node 101 (create_control "Person" 1) in
  let pattern_bg = empty_bigraph signature in
  let pattern_bg = add_node_to_root pattern_bg pattern_room in
  let pattern_bg = add_node_as_child pattern_bg 100 pattern_person in
  let pattern = {
    bigraph = pattern_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Target: Room1[Person], Room2 *)
  let target_room1 = create_node 1 (create_control "Room" 0) in
  let target_room2 = create_node 2 (create_control "Room" 0) in
  let target_person = create_node 3 (create_control "Person" 1) in
  let target_bg = empty_bigraph signature in
  let target_bg = add_node_to_root target_bg target_room1 in
  let target_bg = add_node_to_root target_bg target_room2 in
  let target_bg = add_node_as_child target_bg 1 target_person in
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  let match_result = match_pattern pattern target in
  
  (* Context should contain only Room2 (Room1 and Person were matched) *)
  assert_equal_int 1 (get_node_count match_result.context.bigraph) "Context should have 1 node";
  
  (* Verify only Room2 is in context *)
  let context_has_room1 = NodeMap.mem 1 match_result.context.bigraph.place.nodes in
  let context_has_room2 = NodeMap.mem 2 match_result.context.bigraph.place.nodes in
  let context_has_person = NodeMap.mem 3 match_result.context.bigraph.place.nodes in
  
  assert_equal_bool false context_has_room1 "Context should not contain Room1 (was matched)";
  assert_equal_bool true context_has_room2 "Context should contain Room2";
  assert_equal_bool false context_has_person "Context should not contain Person (was matched)";
  
  Printf.printf "Context extraction passed!\n\n"

(* Test 4: ID preservation in rule application *)
let test_id_preservation () =
  Printf.printf "Testing ID preservation in rule application...\n";
  
  let signature = [create_control "A" 0] in
  
  (* Target: A *)
  let target_node = create_node 42 (create_control "A" 0) in
  let target_bg = add_node_to_root (empty_bigraph signature) target_node in
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Rule: A -> A (identity, but should preserve ID) *)
  let redex_node = create_node 100 (create_control "A" 0) in
  let redex_bg = add_node_to_root (empty_bigraph signature) redex_node in
  let redex = {
    bigraph = redex_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  let reactum_node = create_node 200 (create_control "A" 0) in
  let reactum_bg = add_node_to_root (empty_bigraph signature) reactum_node in
  let reactum = {
    bigraph = reactum_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  let rule = create_rule "identity" redex reactum in
  let result = assert_some (apply_rule rule target) "Rule should apply" in
  
  (* Result should still have node with ID 42 *)
  let has_original_id = NodeMap.mem 42 result.bigraph.place.nodes in
  assert_equal_bool true has_original_id "Original ID should be preserved";
  
  Printf.printf "ID preservation passed!\n\n"

(* Test 5: Parent map preservation in rule application *)
let test_parent_map_preservation () =
  Printf.printf "Testing parent map preservation in rule application...\n";
  
  let signature = [create_control "Container" 0; create_control "Item" 0] in
  
  (* Target: Container[Item] *)
  let target_container = create_node 1 (create_control "Container" 0) in
  let target_item = create_node 2 (create_control "Item" 0) in
  let target_bg = empty_bigraph signature in
  let target_bg = add_node_to_root target_bg target_container in
  let target_bg = add_node_as_child target_bg 1 target_item in
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Rule: Container[Item] -> Container[Item] (should preserve parent relationship) *)
  let redex_container = create_node 100 (create_control "Container" 0) in
  let redex_item = create_node 101 (create_control "Item" 0) in
  let redex_bg = empty_bigraph signature in
  let redex_bg = add_node_to_root redex_bg redex_container in
  let redex_bg = add_node_as_child redex_bg 100 redex_item in
  let redex = {
    bigraph = redex_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  let reactum_container = create_node 200 (create_control "Container" 0) in
  let reactum_item = create_node 201 (create_control "Item" 0) in
  let reactum_bg = empty_bigraph signature in
  let reactum_bg = add_node_to_root reactum_bg reactum_container in
  let reactum_bg = add_node_as_child reactum_bg 200 reactum_item in
  let reactum = {
    bigraph = reactum_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  let rule = create_rule "preserve_containment" redex reactum in
  let result = assert_some (apply_rule rule target) "Rule should apply" in
  
  (* Check that parent relationship is preserved *)
  let item_parent = get_parent result.bigraph 2 in
  assert_equal_int 1 (assert_some item_parent "Item should have parent") 
    "Item should still be contained in Container";
  
  Printf.printf "Parent map preservation passed!\n\n"

(* Test 6: No match scenarios *)
let test_no_match_scenarios () =
  Printf.printf "Testing no match scenarios...\n";
  
  let signature = [create_control "A" 0; create_control "B" 0] in
  
  (* Pattern: A *)
  let pattern_node = create_node 100 (create_control "A" 0) in
  let pattern_bg = add_node_to_root (empty_bigraph signature) pattern_node in
  let pattern = {
    bigraph = pattern_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Target: only B (no A) *)
  let target_node = create_node 1 (create_control "B" 0) in
  let target_bg = add_node_to_root (empty_bigraph signature) target_node in
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };  
  } in
  
  (* Should not match *)
  (try
    let _ = match_pattern pattern target in
    failwith "Should have raised NoMatch exception"
  with
  | NoMatch _ -> Printf.printf "Correctly detected no match\n"
  | e -> failwith ("Unexpected exception: " ^ Printexc.to_string e));
  
  Printf.printf "No match scenarios passed!\n\n"

(* Test 7: Multiple possible matches *)
let test_multiple_matches () =
  Printf.printf "Testing multiple possible matches...\n";
  
  let signature = [create_control "A" 0] in
  
  (* Pattern: A *)
  let pattern_node = create_node 100 (create_control "A" 0) in
  let pattern_bg = add_node_to_root (empty_bigraph signature) pattern_node in
  let pattern = {
    bigraph = pattern_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Target: A, A (two A nodes) *)
  let target_a1 = create_node 1 (create_control "A" 0) in
  let target_a2 = create_node 2 (create_control "A" 0) in
  let target_bg = add_node_to_root (add_node_to_root (empty_bigraph signature) target_a1) target_a2 in
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Should match one of them (deterministic based on our implementation) *)
  let match_result = match_pattern pattern target in
  assert_equal_int 1 (List.length match_result.node_mapping) "Should match exactly one node";
  
  let (_, matched_target_id) = List.hd match_result.node_mapping in
  let is_valid_match = matched_target_id = 1 || matched_target_id = 2 in
  assert_equal_bool true is_valid_match "Should match one of the two A nodes";
  
  Printf.printf "Multiple matches handled correctly!\n\n"

(* Test 8: Complex spatial hierarchy *)
let test_complex_spatial_hierarchy () =
  Printf.printf "Testing complex spatial hierarchy matching...\n";
  
  let signature = [
    create_control "Building" 0;
    create_control "Floor" 0; 
    create_control "Room" 0;
    create_control "Person" 1
  ] in
  
  (* Pattern: Building[Floor[Room[Person]]] *)
  let pattern_building = create_node 100 (create_control "Building" 0) in
  let pattern_floor = create_node 101 (create_control "Floor" 0) in
  let pattern_room = create_node 102 (create_control "Room" 0) in
  let pattern_person = create_node 103 (create_control "Person" 1) in
  
  let pattern_bg = empty_bigraph signature in
  let pattern_bg = add_node_to_root pattern_bg pattern_building in
  let pattern_bg = add_node_as_child pattern_bg 100 pattern_floor in
  let pattern_bg = add_node_as_child pattern_bg 101 pattern_room in
  let pattern_bg = add_node_as_child pattern_bg 102 pattern_person in
  
  let pattern = {
    bigraph = pattern_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Target: Building1[Floor1[Room1[Person1]], Floor2] *)
  let target_building = create_node 1 (create_control "Building" 0) in
  let target_floor1 = create_node 2 (create_control "Floor" 0) in
  let target_floor2 = create_node 3 (create_control "Floor" 0) in
  let target_room = create_node 4 (create_control "Room" 0) in
  let target_person = create_node 5 (create_control "Person" 1) in
  
  let target_bg = empty_bigraph signature in
  let target_bg = add_node_to_root target_bg target_building in
  let target_bg = add_node_as_child target_bg 1 target_floor1 in
  let target_bg = add_node_as_child target_bg 1 target_floor2 in
  let target_bg = add_node_as_child target_bg 2 target_room in
  let target_bg = add_node_as_child target_bg 4 target_person in
  
  let target = {
    bigraph = target_bg;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in
  
  (* Should match the Building[Floor1[Room[Person]]] substructure *)
  let match_result = match_pattern pattern target in
  assert_equal_int 4 (List.length match_result.node_mapping) "Should match all 4 nodes in hierarchy";
  
  (* Context should contain Floor2 *)
  assert_equal_int 1 (get_node_count match_result.context.bigraph) "Context should have Floor2";
  let context_has_floor2 = NodeMap.mem 3 match_result.context.bigraph.place.nodes in
  assert_equal_bool true context_has_floor2 "Context should contain Floor2";
  
  Printf.printf "Complex spatial hierarchy matching passed!\n\n"

let run_matching_tests () =
  Printf.printf "Running Comprehensive Matching Module Tests\n";
  Printf.printf "==========================================\n\n";
  
  test_basic_structural_matching ();
  test_spatial_relationship_matching ();
  test_context_extraction ();
  test_id_preservation ();
  test_parent_map_preservation ();
  test_no_match_scenarios ();
  test_multiple_matches ();
  test_complex_spatial_hierarchy ();
  
  Printf.printf "All matching tests passed successfully!\n"

let () = run_matching_tests ()