open Bigraph

exception IncompatibleInterfaces of string
exception InvalidComposition of string

let validate_composition b1 b2 =
  let outer_b1 = match b1 with { outer; _ } -> outer in
  let inner_b2 = match b2 with { inner; _ } -> inner in
  if outer_b1.sites <> inner_b2.sites then
    raise (IncompatibleInterfaces "Site count mismatch")
  else if List.length outer_b1.names <> List.length inner_b2.names then
    raise (IncompatibleInterfaces "Name count mismatch")

let compose b1 b2 =
  validate_composition b1 b2;

  let new_nodes =
    NodeMap.fold
      (fun k v acc -> NodeMap.add k v acc)
      b1.bigraph.place.nodes b2.bigraph.place.nodes
  in

  let new_parent_map =
    NodeMap.fold NodeMap.add b1.bigraph.place.parent_map
      b2.bigraph.place.parent_map
  in

  let new_edges = EdgeSet.union b1.bigraph.link.edges b2.bigraph.link.edges in

  let new_place =
    {
      nodes = new_nodes;
      parent_map = new_parent_map;
      sites = SiteSet.union b1.bigraph.place.sites b2.bigraph.place.sites;
      regions =
        RegionSet.union b1.bigraph.place.regions b2.bigraph.place.regions;
      site_parent_map =
        SiteMap.fold SiteMap.add b1.bigraph.place.site_parent_map
          b2.bigraph.place.site_parent_map;
      region_nodes =
        RegionMap.fold RegionMap.add b1.bigraph.place.region_nodes
          b2.bigraph.place.region_nodes;
    }
  in

  let new_link =
    {
      edges = new_edges;
      outer_names = b2.bigraph.link.outer_names;
      inner_names = b1.bigraph.link.inner_names;
      linking =
        (fun port ->
          match b1.bigraph.link.linking port with
          | Some link -> Some link
          | None -> b2.bigraph.link.linking port);
    }
  in

  (* Remove the id_graph merging code *)
  let composed_bigraph =
    {
      place = new_place;
      link = new_link;
      signature = b1.bigraph.signature @ b2.bigraph.signature;
    }
  in

  { bigraph = composed_bigraph; inner = b1.inner; outer = b2.outer }

(* Update tensor_product function similarly *)
let tensor_product b1 b2 =
  let offset = 10000 in

  let shift_node_ids nodes =
    NodeMap.fold
      (fun id node acc ->
        let new_id = id + offset in
        let new_node =
          {
            node with
            id = new_id;
            ports = List.map (fun p -> p + offset) node.ports;
          }
        in
        NodeMap.add new_id new_node acc)
      nodes NodeMap.empty
  in

  let shift_parent_map parent_map =
    NodeMap.fold
      (fun child_id parent_id acc ->
        NodeMap.add (child_id + offset) (parent_id + offset) acc)
      parent_map NodeMap.empty
  in

  let shifted_b2_nodes = shift_node_ids b2.bigraph.place.nodes in
  let combined_nodes =
    NodeMap.fold NodeMap.add b1.bigraph.place.nodes shifted_b2_nodes
  in

  let shifted_b2_parent_map = shift_parent_map b2.bigraph.place.parent_map in
  let combined_parent_map =
    NodeMap.fold NodeMap.add b1.bigraph.place.parent_map shifted_b2_parent_map
  in

  let shifted_b2_edges =
    EdgeSet.fold
      (fun e acc -> EdgeSet.add (e + offset) acc)
      b2.bigraph.link.edges EdgeSet.empty
  in
  let combined_edges = EdgeSet.union b1.bigraph.link.edges shifted_b2_edges in

  let shift_site_parent_map site_parent_map =
    SiteMap.fold
      (fun site_id parent_id acc ->
        SiteMap.add (site_id + offset) (parent_id + offset) acc)
      site_parent_map SiteMap.empty
  in

  let shift_region_nodes region_nodes =
    RegionMap.fold
      (fun region_id nodes acc ->
        let shifted_nodes = NodeSet.map (fun x -> x + offset) nodes in
        RegionMap.add (region_id + offset) shifted_nodes acc)
      region_nodes RegionMap.empty
  in

  let new_place =
    {
      nodes = combined_nodes;
      parent_map = combined_parent_map;
      sites =
        SiteSet.union b1.bigraph.place.sites
          (SiteSet.map (fun x -> x + offset) b2.bigraph.place.sites);
      regions =
        RegionSet.union b1.bigraph.place.regions
          (RegionSet.map (fun x -> x + offset) b2.bigraph.place.regions);
      site_parent_map =
        SiteMap.fold SiteMap.add b1.bigraph.place.site_parent_map
          (shift_site_parent_map b2.bigraph.place.site_parent_map);
      region_nodes =
        RegionMap.fold RegionMap.add b1.bigraph.place.region_nodes
          (shift_region_nodes b2.bigraph.place.region_nodes);
    }
  in

  let new_link =
    {
      edges = combined_edges;
      outer_names = b1.bigraph.link.outer_names @ b2.bigraph.link.outer_names;
      inner_names = b1.bigraph.link.inner_names @ b2.bigraph.link.inner_names;
      linking =
        (fun port ->
          if port < offset then b1.bigraph.link.linking port
          else
            match b2.bigraph.link.linking (port - offset) with
            | Some (Closed e) -> Some (Closed (e + offset))
            | Some (Name n) -> Some (Name n)
            | None -> None);
    }
  in

  (* Remove id_graph code *)
  let tensor_bigraph =
    {
      place = new_place;
      link = new_link;
      signature = b1.bigraph.signature @ b2.bigraph.signature;
    }
  in

  {
    bigraph = tensor_bigraph;
    inner =
      {
        sites = b1.inner.sites + b2.inner.sites;
        names = b1.inner.names @ b2.inner.names;
      };
    outer =
      {
        sites = b1.outer.sites + b2.outer.sites;
        names = b1.outer.names @ b2.outer.names;
      };
  }
