from fastmcp import FastMCP
from bigraph_dsl import Bigraph, Node, Rule
import json
import redis
import logging
import capnp, pathlib

capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(pathlib.Path(__file__).with_name("bigraph_rpc.capnp")))

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)-8s %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger(__name__)

mcp = FastMCP("")
loaded_graph: Bigraph | None = None

from bigraph_dsl import CONTROL_SCHEMA


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


def convert_capnp_property(value):
    """Convert capnp PropertyValue to Python native type"""
    which = value.which()
    if which == 'boolVal':
        return value.boolVal
    elif which == 'intVal':
        return value.intVal
    elif which == 'floatVal':
        return value.floatVal
    elif which == 'stringVal':
        return value.stringVal
    elif which == 'colorVal':
        return (value.colorVal.r, value.colorVal.g, value.colorVal.b)
    else:
        raise ValueError(f"Unsupported property type: {which}")


@mcp.tool
def load_bigraph_from_file(path: str):
    global loaded_graph
    with open(path, "rb") as f:
        msg = bigraph_capnp.Bigraph.read(f)
    nodes_raw = msg.nodes
    id_to_node = {}
    children_map = {}
    for n in nodes_raw:
        properties = {p.key: convert_capnp_property(p.value) for p in n.properties}
        node = Node(
            control=n.control,
            id=n.id,
            arity=n.arity,
            ports=[p for p in n.ports],
            properties=properties)
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


def validate_node(node: dict):
    """Validate that node control and properties follow CONTROL_SCHEMA"""
    control = node.get("control")
    if control not in CONTROL_SCHEMA:
        raise ValueError(f"Invalid control: {control}")

    valid_props = CONTROL_SCHEMA[control].get("properties")
    if valid_props and "properties" in node:
        for prop, val in node["properties"].items():
            if prop not in valid_props:
                raise ValueError(f"Invalid property '{prop}' for control '{control}'")

            expected_type = valid_props[prop]["type"]
            if expected_type == "int" and not isinstance(val, int):
                raise ValueError(f"Property '{prop}' must be int")
            if expected_type == "bool" and not isinstance(val, bool):
                raise ValueError(f"Property '{prop}' must be bool")
            if expected_type == "str" and not isinstance(val, str):
                raise ValueError(f"Property '{prop}' must be str")
            if expected_type == "float" and not isinstance(val, float):
                raise ValueError(f"Property '{prop}' must be float")
            if expected_type == "color":
                if not (isinstance(val, (list, tuple)) and len(val) == 3 and all(isinstance(c, int) for c in val)):
                    raise ValueError(f"Property '{prop}' must be RGB tuple of 3 ints")

    for child in node.get("children", []):
        validate_node(child)

def bigraph_from_json(json_nodes):
    """Convert JSON structured node list into Bigraph"""
    nodes = []
    for nd in json_nodes:
        children = bigraph_from_json(nd.get("children", []))
        node = Node(
            control=nd["control"],
            id=nd.get("id"),
            properties=nd.get("properties", {}),
            children=children)
        nodes.append(node)
    return nodes


@mcp.tool
def publish_rule_to_redis(rule: dict, redis_host="localhost", channel="rules"):
    """Publish a validated rule to Redis."""
    logger.info(f"Publishing rule {rule.get('name')}")

    for node in rule.get("redex", []):
        validate_node(node)
    for node in rule.get("reactum", []):
        validate_node(node)

    redex_bigraph = Bigraph(bigraph_from_json(rule["redex"]))
    reactum_bigraph = Bigraph(bigraph_from_json(rule["reactum"]))
    generated_rule = Rule(rule["name"], redex_bigraph, reactum_bigraph)

    r = redis.Redis(redis_host)
    capnp_data = generated_rule.to_capnp().to_bytes()
    r.publish(channel, capnp_data)
    r.set(f"rule:{generated_rule.name}", capnp_data)

    return {"status": "ok", "name": rule["name"]}

# def apply_rule(rule: Rule, target_path="target.capnp") -> str:
#     """Apply Bigraph rule."""
#     rule.save("rule.capnp")
#     result = subprocess.run(
#         ["../_build/default/dsl/bridge.exe", "rule.capnp", target_path],
#         capture_output=True,
#         text=True)
#     logger.info(result.stdout)

# @mcp.tool
# def save_and_apply_rule(code: str):
#     """
#     Takes Python DSL code that defines a Rule, executes it,
#     saves it, and applies it to the target Bigraph.
#     """
#     local_vars = {
#         "Bigraph": Bigraph,
#         "Node": Node,
#         "Rule": Rule}

#     exec(code, globals(), local_vars)
#     with open("rule.py", "w") as file:
#         file.write(code)
#     generated_rule = None
#     for v in local_vars.values():
#         if isinstance(v, Rule):
#             generated_rule = v
#             logger.info(f"Generated rule = {generated_rule}")
#             break
#     if not generated_rule:
#         raise ValueError("No Rule object found in provided code.")
#     return apply_rule(generated_rule)

if __name__ == "__main__":
    mcp.run()

