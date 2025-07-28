open Bifrost.Bigraph
open Bifrost.Utils
open Bifrost.Matching

let test_property_update () =
  let ctl_light = create_control "Light" 0 in

  (* redex *)
  let redex_bg = empty_bigraph [ctl_light] in
  let redex_light, redex_bg = create_node_with_uid ~props:["power", Bool true] "light1" 20 ctl_light redex_bg in
  let redex_place = {
    redex_bg.place with
    nodes = NodeMap.singleton redex_light.id redex_light;
    region_nodes = RegionMap.singleton 0 (NodeSet.singleton redex_light.id);
  } in
  let redex = { redex_bg with place = redex_place } in

  (* reactum *)
  let reactum_bg = empty_bigraph [ctl_light] in
  let react_light, reactum_bg = create_node_with_uid ~props:["power", Bool false] "light1" 30 ctl_light reactum_bg in
  let reactum_place = {
    reactum_bg.place with
    nodes = NodeMap.singleton react_light.id react_light;
    region_nodes = RegionMap.singleton 0 (NodeSet.singleton react_light.id);
  } in
  let reactum = { reactum_bg with place = reactum_place } in

  let redex_with_iface = {
    bigraph = redex;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in

  let reactum_with_iface = {
    bigraph = reactum;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in

  let rule = create_rule "turn_light_off" redex_with_iface reactum_with_iface in

  (* target *)
  let target_bg = empty_bigraph [ctl_light] in
  let target_light, target_bg = create_node_with_uid ~props:["power", Bool true] "light1" 2 ctl_light target_bg in
  let target_place = {
    target_bg.place with
    nodes = NodeMap.singleton target_light.id target_light;
    region_nodes = RegionMap.singleton 0 (NodeSet.singleton target_light.id);
  } in
  let target = { target_bg with place = target_place } in

  let target_with_iface = {
    bigraph = target;
    inner = { sites = 0; names = [] };
    outer = { sites = 0; names = [] };
  } in

  (match apply_rule rule target_with_iface with
  | Some result_state ->
      Printf.printf "Result state:\n";
      print_bigraph result_state.bigraph;
      Printf.printf "Node count: before=%d, after=%d\n"
        (get_node_count target_with_iface.bigraph)
        (get_node_count result_state.bigraph)
  | None -> Printf.printf "Failed\n");;

  
let run () =
  test_property_update ()

let () = run ()