# Bifrost - OCaml Bigraph Implementation

## Project Overview

Bifrost is a comprehensive OCaml implementation of Robin Milner's bigraph theory.
Bigraphs are a mathematical formalism for modeling concurrent systems, spatial structures, and reactive systems.

**Status: FULLY FUNCTIONAL** - Movement rules, spatial hierarchy, and pattern matching all work correctly!

## Architecture

### Core Modules

- **lib/bigraph.ml**: Core data structures and types
  - Node, edge, port, site, and region identifiers
  - Place graphs with `parent_map` for clean parent-child relationships
  - Bigraph composition with proper interfaces
- **lib/operations.ml**: Composition and tensor product operations
- **lib/matching.ml**: Structural pattern matching that works with spatial relationships
- **lib/utils.ml**: Comprehensive spatial hierarchy functions and movement operations

### Key Data Structures

```ocaml
type place_graph = {
  nodes: node NodeMap.t;                    (* All nodes in the bigraph *)
  parent_map: node_id NodeMap.t;           (* child_id -> parent_id mapping *)
  sites: SiteSet.t;                        (* Holes in the structure *)
  regions: RegionSet.t;                    (* Top-level regions *)
  site_parent_map: node_id SiteMap.t;      (* site -> parent mapping *)
  region_nodes: NodeSet.t RegionMap.t;     (* region -> nodes mapping *)
}

type bigraph = {
  place: place_graph;        (* Spatial hierarchy *)
  link: link_graph;          (* Connectivity structure *)
  signature: control list;   (* Available node types *)
}

type bigraph_with_interface = {
  bigraph: bigraph;
  inner: interface;          (* Input interface *)
  outer: interface;          (* Output interface *)
}
```

## Major Improvements Applied

### Problems in Original Implementation
1. **Premature Optimization**: Dual parent/children functions caused complexity without benefit
2. **Broken Pattern Matching**: Exact node ID matching instead of structural matching
3. **Non-functional Movement Rules**: No spatial hierarchy support
4. **Inconsistent Data Structures**: Functions instead of data for parent-child relationships

### Solutions Implemented
1. **Clean Data Structure**: Single `parent_map` with computed helper functions
2. **Structural Pattern Matching**: Matches by control types and spatial relationships
3. **Working Movement Rules**: Proper spatial hierarchy and transformations
4. **Clean Separation**: Data structures for state, functions for operations

## Building and Testing

### Build Commands

```bash
dune build                 # Build the library
dune exec test/test_bifrost.exe  # Run comprehensive tests
dune exec examples/simple_example.exe  # Run examples
```

### Test Results
All tests pass, including:
- Spatial hierarchy creation and querying
- Working movement rules (person between rooms)
- Structural pattern matching
- Bigraph composition and tensor products

### Code Style Notes

- Unused variables prefixed with underscore (e.g., `_node`, `_bigraph`)
- Type annotations used for record field inference
- "Make it work first" principle - premature optimization avoided

## Usage Examples

### Spatial Hierarchy Creation

```ocaml
let bigraph = empty_bigraph signature in
let building = create_node 1 (create_control "Building" 0) in
let room = create_node 2 (create_control "Room" 0) in
let person = create_node 3 (create_control "Person" 1) in

(* Build hierarchy: Person inside Room inside Building *)
let bigraph = add_node_to_root bigraph building in
let bigraph = add_node_as_child bigraph 1 room in      (* Room in Building *)
let bigraph = add_node_as_child bigraph 2 person in    (* Person in Room *)
```

### Working Movement Rules

```ocaml
(* Rule: Person inside any Room -> Person at root level *)
let redex = (* Person inside Room pattern *) in
let reactum = (* Person at root pattern *) in
let move_rule = create_rule "move_out" redex reactum in

(* Apply rule to transform bigraph *)
match apply_rule move_rule target with
| Some result -> (* Person successfully moved out *)
| None -> (* Rule not applicable *)
```

### Direct Movement Operations

```ocaml
(* Move person from room 1 to room 2 *)
let moved_bigraph = move_node bigraph person_id room2_id in

(* Query spatial relationships *)
let parent = get_parent bigraph node_id in
let children = get_children bigraph node_id in
```

## File Structure

```
bifrost/
├── lib/
│   ├── bigraph.ml/mli     # Core types and structures
│   ├── operations.ml      # Composition and tensor operations
│   ├── matching.ml        # Pattern matching and rules
│   ├── utils.ml           # Utility functions
│   └── dune              # Library build configuration
├── test/
│   ├── test_bifrost.ml   # Test cases
│   └── dune              # Test build configuration (depends on bifrost)
├── examples/
│   └── simple_example.ml # Usage examples
├── dune-project          # Project configuration
├── bifrost.opam         # Package metadata
└── CLAUDE.md            # This documentation
```

## What Was Fixed

### The "Premature Optimization" Problem
The original implementation suffered from a classic case of premature optimization. Instead of focusing on getting basic functionality working, it tried to optimize for O(1) parent-child lookups by storing both `parent` and `children` functions. This created:

- **Complexity**: Maintaining consistency between redundant data
- **Bugs**: The optimization prevented basic spatial hierarchy from working
- **Technical Debt**: Made simple operations complicated

### The Solution: "Make It Work First"
Following Donald Knuth's principle that "premature optimization is the root of all evil," we:

1. **Single source of truth**: Just `parent_map: node_id NodeMap.t`
2. **Made it work**: Got spatial hierarchy and movement rules functioning
3. **Kept it simple**: Helper functions compute children on-demand

Result: The bigraph implementation now actually works as intended, with clean, maintainable code that correctly implements bigraph theory.

## Development Notes

- All core bigraph operations work correctly
- Movement rules actually move things between spatial containers
- Pattern matching works on structure, not just exact node IDs
- Spatial hierarchy properly maintained and queryable
- Clean, simple codebase following "make it work first" principle
- Ready for extension with additional bigraph operations
