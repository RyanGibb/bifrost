open Bifrost.Bigraph
open Bifrost.Utils
open Bifrost.Matching

let test_property_update () =
  let ctl_light = create_control "Light" 0 in

  (* redex *)
  let redex_bg = empty_bigraph [ ctl_light ] in
  let redex_light =
    create_node
      ~props:[ ("power", Bool true) ]
      ~name:"light1" ~node_type:"Light" 20 ctl_light
  in
  let redex_bg = add_node_to_root redex_bg redex_light in
  let redex_place =
    {
      redex_bg.place with
      region_nodes = RegionMap.singleton 0 (NodeSet.singleton redex_light.id);
    }
  in
  let redex = { redex_bg with place = redex_place } in

  (* reactum *)
  let reactum_bg = empty_bigraph [ ctl_light ] in
  let react_light =
    create_node
      ~props:[ ("power", Bool false) ]
      ~name:"light1" ~node_type:"Light" 30 ctl_light
  in
  let reactum_bg = add_node_to_root reactum_bg react_light in
  let reactum_place =
    {
      reactum_bg.place with
      region_nodes = RegionMap.singleton 0 (NodeSet.singleton react_light.id);
    }
  in
  let reactum = { reactum_bg with place = reactum_place } in

  let redex_with_iface =
    {
      bigraph = redex;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  let reactum_with_iface =
    {
      bigraph = reactum;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  let rule = create_rule "turn_light_off" redex_with_iface reactum_with_iface in

  (* target *)
  let target_bg = empty_bigraph [ ctl_light ] in
  let target_light =
    create_node
      ~props:[ ("power", Bool true) ]
      ~name:"light1" ~node_type:"Light" 2 ctl_light
  in
  let target_bg = add_node_to_root target_bg target_light in
  let target_place =
    {
      target_bg.place with
      region_nodes = RegionMap.singleton 0 (NodeSet.singleton target_light.id);
    }
  in
  let target = { target_bg with place = target_place } in

  let target_with_iface =
    {
      bigraph = target;
      inner = { sites = 0; names = [] };
      outer = { sites = 0; names = [] };
    }
  in

  match apply_rule rule target_with_iface with
  | Some result_state ->
      Printf.printf "Result state:\n";
      print_bigraph result_state.bigraph;
      Printf.printf "Node count: before=%d, after=%d\n"
        (get_node_count target_with_iface.bigraph)
        (get_node_count result_state.bigraph)
  | None -> Printf.printf "Failed\n"

let run () = test_property_update ()
let () = run ()
