from fastmcp import FastMCP
from bigraph_dsl import Bigraph, Node, Rule

import json
import logging
import subprocess

import capnp, pathlib
capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(pathlib.Path(__file__).with_name("bigraph.capnp")))

logging.basicConfig(
    level=logging.INFO,  # DEBUG shows everything; INFO for less verbosity
    format="[%(asctime)s] %(levelname)-8s %(message)s",
    datefmt="%H:%M:%S")
logger = logging.getLogger(__name__)

mcp = FastMCP("")

loaded_graph: Bigraph | None = None

def capnp_to_native(obj):
    """Recursively convert capnp objects to native Python types"""
    if hasattr(obj, "to_dict"): 
        return capnp_to_native(obj.to_dict())
    elif isinstance(obj, (list, capnp.lib.capnp._DynamicListReader)):
        return [capnp_to_native(i) for i in obj]
    elif isinstance(obj, (dict, capnp.lib.capnp._DynamicStructReader)):
        return {k: capnp_to_native(v) for k, v in dict(obj).items()}
    elif hasattr(obj, "_as_dict"): 
        return capnp_to_native(obj._as_dict())
    else:
        return obj 
    
@mcp.tool
def load_bigraph_from_file(path: str):
    global loaded_graph
    with open(path, "rb") as f:
        msg = bigraph_capnp.Bigraph.read(f)
    nodes_raw = msg.nodes
    id_to_node = {}
    children_map = {}
    for n in nodes_raw:
        node = Node(
            control=n.control,
            id=n.id,
            arity=n.arity,
            ports=[p for p in n.ports],
            properties={p.key: p.value for p in n.properties})
        id_to_node[n.id] = node
        parent = n.parent
        children_map.setdefault(parent, []).append(n.id)
    for parent_id, child_ids in children_map.items():
        if parent_id != -1:
            parent = id_to_node[parent_id]
            for cid in child_ids:
                parent.children.append(id_to_node[cid])
    root_nodes = [id_to_node[nid] for nid in children_map.get(-1, [])]
    loaded_graph = Bigraph(nodes=root_nodes, sites=msg.siteCount, names=list(msg.names))
    # return capnp_to_native(loaded_graph.to_dict())

@mcp.tool
def query_state() -> dict:
    """Return the current Bigraph state as JSON"""
    if loaded_graph is None:
        raise ValueError("No graph loaded")
    return capnp_to_native(loaded_graph.to_dict())

@mcp.tool
def save_bigraph_to_file(file_path: str) -> str:
    """Save the current Bigraph to a capnp file."""
    if loaded_graph is None:
        raise ValueError("No graph loaded")
    loaded_graph.save(file_path)
    return f"Graph saved to {file_path}"

@mcp.tool
def add_node(parent_id: str, control: str, label: str = "", properties: dict = None) -> dict:
    """
    Add node to the Bigraph.
    """
    node = Node(control=control, label=label, properties=properties or {})
    loaded_graph.add_node(node, parent_id=parent_id)


def apply_rule(rule: Rule, target_path="target.capnp") -> str:
    """Apply Bigraph rule."""
    rule.save("rule.capnp")
    result = subprocess.run(
        ["../_build/default/dsl/bridge.exe", "rule.capnp", target_path],
        capture_output=True,
        text=True)
    logger.info(result.stdout)

@mcp.tool
def save_and_apply_rule(code: str):
    """
    Takes Python DSL code that defines a Rule, executes it,
    saves it, and applies it to the target Bigraph.
    """
    local_vars = {
        "Bigraph": Bigraph,
        "Node": Node,
        "Rule": Rule}

    exec(code, globals(), local_vars)
    with open("rule.py", "w") as file:
        file.write(code)
    generated_rule = None
    for v in local_vars.values():
        if isinstance(v, Rule):
            generated_rule = v
            logger.info(f"Generated rule = {generated_rule}")
            break
    if not generated_rule:
        raise ValueError("No Rule object found in provided code.")
    return apply_rule(generated_rule)

if __name__ == "__main__":
    mcp.run()

