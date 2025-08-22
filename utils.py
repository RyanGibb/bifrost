import sys
import pathlib
sys.path.append(str(pathlib.Path(__file__).parent / "lib"))

import capnp

from bigraph_dsl import Bigraph, Node, Rule
from bigraph_dsl import CONTROL_SCHEMA

capnp.remove_import_hook()
bigraph_capnp = capnp.load(
    str(pathlib.Path(__file__).parent / "lib" / "bigraph_rpc.capnp")
)

def _get_prop_schema(control: str):
    # handles CONTROL_SCHEMA["types"][control] and CONTROL_SCHEMA[control]
    schema = CONTROL_SCHEMA.get("types", {}).get(control)
    if not schema and control in CONTROL_SCHEMA:
        schema = CONTROL_SCHEMA[control]
    return (schema or {}).get("properties", {})

def sanitize_properties(control: str, props: dict) -> dict:
    """Clamp properties to schema so Node(...) val doesn't explode!"""
    meta = _get_prop_schema(control)
    out = {}
    for k, v in props.items():
        if k in meta:
            t = meta[k].get("type")
            if t == "int" and isinstance(v, int):
                rng = meta[k].get("range")
                if rng:
                    lo, hi = rng
                    if v < lo or v > hi:
                        old = v
                        v = max(lo, min(hi, v))
                        logger.warning(f"Clamped {control}.{k}: {old} -> {v} (range {rng})")
        out[k] = v
    return out

def capnp_to_native(obj):
    """Convert Capnp object to native Python types"""
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
    """Convert Capnp PropertyValue to native Python type"""
    which = value.which()
    if which == 'boolVal': return value.boolVal
    elif which == 'intVal': return value.intVal
    elif which == 'floatVal': return value.floatVal
    elif which == 'stringVal': return value.stringVal
    elif which == 'colorVal': return (value.colorVal.r, value.colorVal.g, value.colorVal.b)
    else:
        raise ValueError(f"Unsupported type: {which}")

def load_state_dict_from_capnp(graph_file: str):
    """Load room slice into dict for local updates."""
    try:
        with graph_file.open("rb") as f:
            msg = bigraph_capnp.Bigraph.read(f)
    except Exception:
        state = {"nodes": {}}
        return
    state = {"nodes": {}}
    for n in msg.nodes:
        nd = {
            "id": n.id,
            "control": n.control,
            "parent": n.parent if n.parent != -1 else None,
            "ports": list(n.ports),
            "properties": {},
            "name": getattr(n, "name", f"node_{n.id}"),
            "type": getattr(n, "type", n.control),
        }
        for p in n.properties:
            w = p.value.which()
            nd["properties"][p.key] = getattr(p.value, w)
        state["nodes"][n.id] = nd
    return state

def graph_from_json(json_nodes):
    """Convert JSON structured node list into graph"""
    nodes = []
    for nd in json_nodes:
        children = graph_from_json(nd.get("children", []))
        node = Node(
            control=nd["control"],
            id=nd.get("id", 0),  # default to 0 for type matching
            properties=nd.get("properties", {}),
            children=children,
            name=nd.get("name", f"node_{nd.get('id', 0)}"),
            node_type=nd.get("type", nd["control"]))  # default type to control
        nodes.append(node)
    return nodes

def cp_prop_value(dst_prop_val, src_prop_val):
    w = src_prop_val.which()
    if w == "boolVal":
        dst_prop_val.boolVal = src_prop_val.boolVal
    elif w == "intVal":
        dst_prop_val.intVal = src_prop_val.intVal
    elif w == "floatVal":
        dst_prop_val.floatVal = src_prop_val.floatVal
    elif w == "stringVal":
        dst_prop_val.stringVal = src_prop_val.stringVal
    elif w == "colorVal":
        c = src_prop_val.colorVal
        dst_prop_val.init("colorVal")
        dst_prop_val.colorVal.r = c.r
        dst_prop_val.colorVal.g = c.g
        dst_prop_val.colorVal.b = c.b

def validate_node(node: dict):
    """Validate node type etc follows CONTROL_SCHEMA"""
    node_type = node.get("type", node.get("control")) # fallback
    
    schema = CONTROL_SCHEMA.get("types", {}).get(node_type, {})
    valid_props = schema.get("properties", {})
    
    if valid_props and "properties" in node:
        for prop, val in node["properties"].items():
            if prop not in valid_props:
                raise ValueError(f"Invalid property '{prop}' for type '{node_type}'")
            expected = valid_props[prop]
            expected_type = expected["type"]
            
            if expected_type == "int" and not isinstance(val, int):
                raise ValueError(f"Property '{prop}' must be int")
            elif expected_type == "bool" and not isinstance(val, bool):
                raise ValueError(f"Property '{prop}' must be bool")
            elif expected_type == "string" and not isinstance(val, str):
                raise ValueError(f"Property '{prop}' must be string")
            elif expected_type == "float" and not isinstance(val, float):
                raise ValueError(f"Property '{prop}' must be float")
            elif expected_type == "color":
                if not (isinstance(val, (list, tuple)) and len(val) == 3 and all(isinstance(c, int) for c in val)):
                    raise ValueError(f"Property '{prop}' must be RGB tuple")
                    
    for child in node.get("children", []):
        validate_node(child)