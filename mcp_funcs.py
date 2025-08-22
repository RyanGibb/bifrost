import sys
import json
import base64
import logging
import pathlib
from typing import List, Dict, Any

import redis
import capnp

capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(pathlib.Path(__file__).parent / "lib" / "bigraph_rpc.capnp"))

sys.path.append(str(pathlib.Path(__file__).parent / "lib"))
from bigraph_dsl import Bigraph, Node, Rule
from utils import convert_capnp_property, sanitize_properties, graph_from_json, validate_node

from fastmcp import FastMCP

mcp = FastMCP("")
loaded_graph: Bigraph | None = None

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(levelname)-8s %(message)s", datefmt="%H:%M:%S")
logger = logging.getLogger(__name__)


# ---------- helpers ----------
def _pv_to_py(pv) -> Any:
    """Capnp union -> native python."""
    w = pv.which()
    if   w == "boolVal":   return bool(pv.boolVal)
    elif w == "intVal":    return int(pv.intVal)
    elif w == "floatVal":  return float(pv.floatVal)
    elif w == "stringVal": return str(pv.stringVal)
    elif w == "colorVal":  return {"r": pv.colorVal.r, "g": pv.colorVal.g, "b": pv.colorVal.b}
    # best effort fallback
    return getattr(pv, w, None)

def _prop_dict(n) -> Dict[str, Any]:
    return {p.key: _pv_to_py(p.value) for p in getattr(n, "properties", [])}

def _name_like(n) -> str:
    for p in getattr(n, "properties", []):
        if p.key == "name":
            v = _pv_to_py(p.value)
            if v:
                return str(v)
    return getattr(n, "name", f"node_{getattr(n, 'id', 'unknown')}")

def _flat_nodes_from_bigraph_msg_like(msg) -> List[Dict[str, Any]]:
    """
    build a flat list from any object exposing a .nodes iterable of capnp-like nodes
    works for both actual capnp messages and DSL wrappers
    """
    idset = {int(n.id) for n in msg.nodes}
    out: List[Dict[str, Any]] = []
    for n in msg.nodes:
        pid = int(getattr(n, "parent", -1))
        out.append({
            "id": int(n.id),
            "control": str(n.control),
            "name": getattr(n, "name", _name_like(n)),
            "parent": pid if pid in idset and pid != -1 else -1,
            "properties": _prop_dict(n)})
    return out

def _tree_from_bigraph_msg_like(msg) -> List[Dict[str, Any]]:
    """
    build a tree shape from any object exposing a .nodes iterable of capnp-like nodes
    """
    id2node = {int(n.id): n for n in msg.nodes}
    idset = set(id2node.keys())
    children: Dict[int, List[int]] = {i: [] for i in idset}
    roots: List[int] = []
    for n in msg.nodes:
        pid = int(getattr(n, "parent", -1))
        if pid in idset and pid != -1:
            children[pid].append(int(n.id))
        else:
            roots.append(int(n.id))

    def build(nid: int) -> Dict[str, Any]:
        n = id2node[nid]
        return {
            "id": int(n.id),
            "control": str(n.control),
            "name": getattr(n, "name", _name_like(n)),
            "properties": _prop_dict(n),
            "children": [build(c) for c in children[nid]]}

    return [build(r) for r in roots]

# ---------- tools ----------
@mcp.tool
def load_bigraph_from_file_glob(path: str):
    """Load a bigraph from a Cap'N'Proto serialization."""
    global loaded_graph
    with open(path, "rb") as f:
        msg = bigraph_capnp.Bigraph.read(f)

    id_to_node: Dict[int, Node] = {}
    children_map: Dict[int, List[int]] = {}
    for n in msg.nodes:
        props = {p.key: convert_capnp_property(p.value) for p in n.properties}
        props = sanitize_properties(n.control, props)
        node = Node(
            control=n.control,
            id=n.id,
            arity=n.arity,
            ports=[p for p in n.ports],
            properties=props,
        )
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
    logger.info(f"Loaded graph from {path}")

@mcp.tool
async def query_state(shape: str = "flat") -> Dict[str, Any]:
    """Query the currently loaded graph (DSL Bigraph)."""
    if loaded_graph is None:
        return {"nodes": [], "meta": {"loaded": False, "error": "no graph loaded"}}

    def _flatten_dsl_graph(bg: Bigraph) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        def walk(node, parent_id: int):
            out.append({
                "id": int(node.id),
                "control": str(node.control),
                "name": getattr(node, "name", None) or node.properties.get("name"),
                "parent": int(parent_id),
                "properties": dict(node.properties),
            })
            for c in getattr(node, "children", []):
                walk(c, node.id)
        for root in getattr(bg, "nodes", []):
            walk(root, -1)
        return out

    def _tree_dsl_graph(bg: Bigraph) -> List[Dict[str, Any]]:
        def build(node) -> Dict[str, Any]:
            return {
                "id": int(node.id),
                "control": str(node.control),
                "name": getattr(node, "name", None) or node.properties.get("name"),
                "properties": dict(node.properties),
                "children": [build(c) for c in getattr(node, "children", [])],
            }
        return [build(r) for r in getattr(bg, "nodes", [])]

    try:
        if shape == "tree":
            return {"tree": _tree_dsl_graph(loaded_graph), "meta": {"loaded": True}}
        if shape == "both":
            return {
                "nodes": _flatten_dsl_graph(loaded_graph),
                "tree": _tree_dsl_graph(loaded_graph),
                "meta": {"loaded": True},
            }
        # default flat
        return {"nodes": _flatten_dsl_graph(loaded_graph), "meta": {"loaded": True}}
    except Exception as e:
        return {"nodes": [], "meta": {"loaded": True, "error": str(e)}}


@mcp.tool
def publish_rule_to_redis(rule: dict, via_mid_id: str | None = None) -> dict:
    """Publish a validated rule to Redis, direct or via mid"""
    logger.info(f"Publishing rule {rule.get('name')}")

    if not all(k in rule for k in ("name", "redex", "reactum")):
        raise ValueError("Rule must have 'name', 'redex', and 'reactum' fields")

    # Validate nodes
    for nd in rule.get("redex", []):   validate_node(nd)
    for nd in rule.get("reactum", []): validate_node(nd)

    redex_bg   = Bigraph(graph_from_json(rule["redex"]))
    reactum_bg = Bigraph(graph_from_json(rule["reactum"]))
    generated  = Rule(rule["name"], redex_bg, reactum_bg)

    r = redis.Redis("localhost")
    capnp_data = generated.to_capnp().to_bytes()

    hub_id = rule.get("hub_id", "default")

    if via_mid_id:
        # envelope for mid forwarding
        envelope = {
            "hub_id": hub_id,
            "capnp_rule_b64": base64.b64encode(capnp_data).decode("ascii"),
        }
        r.publish(f"mid:{via_mid_id}:rules_out", json.dumps(envelope))
        logger.info(f"Published rule '{rule['name']}' via mid:{via_mid_id}")
        return {"status": "ok", "name": rule["name"], "via_mid_id": via_mid_id, "hub_id": hub_id}

    # direct-to-hub (mid path)
    r.publish(f"hub:{hub_id}:rules", capnp_data)
    r.set(f"rule:{generated.name}", capnp_data)
    logger.info(f"Published new rule '{rule['name']}' to hub:{hub_id}:rules")
    return {"status": "ok", "name": rule["name"], "hub_id": hub_id}

@mcp.tool
def publish_rules_batch(rules: List[Dict[str, Any]], hub_id: str = None, via_mid_id: str | None = None) -> Dict[str, Any]:
    """
    Publish multiple rules at once.

    If via_mid_id is provided, this function does NOT publish directly to the hub
    Instead it wraps each rule's capnp bytes in a JSON envelope and publishes a batch to:
        mid:{via_mid_id}:rules_out
    The mid_server listens on that channel and forwards to hub:{hub_id}:rules.

    Args:
        rules: List[dict] with 'name', 'redex', 'reactum' (and optional 'hub_id')
        hub_id: Default hub to target (overridden by rule['hub_id'] if present)
        via_mid_id: If set, publish via the mid (forwarding path)
    """
    import json, base64  # local to keep function self-contained

    logger.info(f"Publishing batch of {len(rules)} rules (via_mid_id={via_mid_id})")

    r = redis.Redis("localhost")
    published_rules: List[Dict[str, Any]] = []
    errors: List[str] = []

    # ---- via-mid path: envelope & single publish to mid:{mid}:rules_out ----
    if via_mid_id:
        batch_env = []
        for i, rule in enumerate(rules):
            try:
                if not all(k in rule for k in ("name", "redex", "reactum")):
                    errors.append(f"rule {i}: missing required fields")
                    continue

                for nd in rule.get("redex", []):
                    validate_node(nd)
                for nd in rule.get("reactum", []):
                    validate_node(nd)

                redex_bg = Bigraph(graph_from_json(rule["redex"]))
                reactum_bg = Bigraph(graph_from_json(rule["reactum"]))
                generated = Rule(rule["name"], redex_bg, reactum_bg)
                cap = generated.to_capnp().to_bytes()

                tgt_hub = hub_id or rule.get("hub_id", "default")
                batch_env.append({
                    "hub_id": tgt_hub,
                    "capnp_rule_b64": base64.b64encode(cap).decode("ascii"),
                    "name": rule["name"]})

                published_rules.append({"name": rule["name"], "hub_id": tgt_hub, "via_mid_id": via_mid_id})
            except Exception as e:
                msg = f"Rule {i} ({rule.get('name', 'unnamed')}): {str(e)}"
                errors.append(msg)

        if batch_env:
            channel = f"mid:{via_mid_id}:rules_out"
            r.publish(channel, json.dumps({"batch": batch_env}))
            logger.info(f"Published batch via {channel} (n={len(batch_env)})")

        return {
            "status": "completed",
            "published": published_rules,
            "errors": errors,
            "total": len(rules),
            "successful": len(published_rules)}

    for i, rule in enumerate(rules):
        try:
            if not all(k in rule for k in ("name", "redex", "reactum")):
                errors.append(f"rule {i}: missing required fields")
                continue

            for nd in rule.get("redex", []):
                validate_node(nd)
            for nd in rule.get("reactum", []):
                validate_node(nd)

            redex_bg = Bigraph(graph_from_json(rule["redex"]))
            reactum_bg = Bigraph(graph_from_json(rule["reactum"]))
            generated = Rule(rule["name"], redex_bg, reactum_bg)

            cap = generated.to_capnp().to_bytes()
            tgt_hub = hub_id or rule.get("hub_id", "default")
            channel = f"hub:{tgt_hub}:rules"

            r.publish(channel, cap)
            r.set(f"rule:{generated.name}", cap)

            published_rules.append({"name": rule["name"], "hub_id": tgt_hub, "channel": channel})
            logger.info(f"Published rule '{rule['name']}' to {channel}\nRule:\n {rule}")
        except Exception as e:
            msg = f"Rule {i} ({rule.get('name', 'unnamed')}): {str(e)}"
            errors.append(msg)
            logger.error(f"Failed to publish rule {i}: {e}")

    return {
        "status": "completed",
        "published": published_rules,
        "errors": errors,
        "total": len(rules),
        "successful": len(published_rules)}


@mcp.tool
def save_graph_to_file(file_path: str) -> str:
    """Saves the current loaded graph to a file."""
    if loaded_graph is None:
        raise ValueError("No graph loaded")
    loaded_graph.save(file_path)
    return f"Graph saved to {file_path}"

###########################################################################################
# TODO sort out

@mcp.tool
def get_calendar_events(user_id: str, hours_ahead: int = 5) -> dict:
    """Get calendar events for a user within the next N hours."""
    calendar_db = {
        "john.smith@company.com": [
            {
                "id": "proj_alpha_review",
                "title": "project alpha review",
                "start_time": "14:00",
                "duration_minutes": 60,
                "location": "ExecutiveConference",
                "participants": ["john.smith@company.com", "jane.doe@company.com", "bob.wilson@company.com"],
                "description": "Quarterly review of project alpha progress",
            }
        ],
        "jane.doe@company.com": [
            {
                "id": "proj_alpha_review",
                "title": "project alpha_review",
                "start_time": "14:00",
                "duration_minutes": 60,
                "location": "ExecutiveConference",
                "participants": ["john.smith@company.com", "jane.doe@company.com", "bob.wilson@company.com"],
            },
            {
                "id": "team_standup",
                "title": "daily standup",
                "start_time": "09:00",
                "duration_minutes": 15,
                "location": "TeamRoom_A",
                "participants": ["jane.doe@company.com", "bob.wilson@company.com"],
            },
        ],
    }
    return {"user_id": user_id, "events": calendar_db.get(user_id, [])}

@mcp.tool
def get_meeting_files(meeting_id: str) -> dict:
    """Get files/presentations associated with a meeting."""
    meeting_files = {
        "proj_alpha_review": {
            "presentations": [
                {
                    "filename": "alpha_q4_review.pptx",
                    "url": "https://files.company.com/meetings/alpha_q4_review.pptx",
                    "presenter": "john.smith@company.com",
                }
            ],
            "documents": [
                {
                    "filename": "alpha_metrics.pdf",
                    "url": "https://files.company.com/meetings/alpha_metrics.pdf",
                }
            ],
            "shared_notes": "https://notes.company.com/alpha_review_2024",
        }
    }
    return meeting_files.get(meeting_id, {"presentations": [], "documents": []})

@mcp.tool
def get_user_info(user_id: str) -> dict:
    """Get user information by ID (email)."""
    user_db = {
        "john.smith@company.com": {
            "name": "John Smith",
            "title": "Engineering Manager",
            "department": "Engineering",
            "phone": "+1-555-0100",
        },
        "jane.doe@company.com": {
            "name": "Jane Doe",
            "title": "Senior Engineer",
            "department": "Engineering",
            "phone": "+1-555-0101",
        },
        "bob.wilson@company.com": {
            "name": "Bob Wilson",
            "title": "Junior Engineer",
            "department": "Engineering",
            "phone": "+1-555-0102",
        },
    }
    return user_db.get(user_id, {"error": "User not found"})

@mcp.tool
def share_transcription(meeting_id: str, participant_emails: list) -> dict:
    """Share meeting transcription with participants."""
    logger.info(f"Sharing transcription for meeting {meeting_id} to {participant_emails}")
    return {"status": "shared", "meeting_id": meeting_id, "participants_notified": participant_emails}

###########################################################################################

if __name__ == "__main__":
    mcp.run()
