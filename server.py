from fastmcp import Client
from pathlib import Path
import json
import redis
import logging
import capnp, pathlib
import threading
import subprocess
import re
import sys
import asyncio

sys.path.append(str(Path(__file__).parent / "lib"))

from bigraph_dsl import Bigraph, Node, Rule, CONTROL_SCHEMA
from prompt import get_prompt

OLLAMA_MODEL = "qwen2.5-coder:3b"

# ==== Capnp schema ====
capnp.remove_import_hook() 
bigraph_capnp = capnp.load(
    str(pathlib.Path(__file__).parent / "lib" / "bigraph_rpc.capnp")
)

# ==== Logging ====
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] SERVER %(levelname)-8s %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("server")

MASTER_FILE = Path("master_building_graph.capnp")
RULES_ROOT = Path("rules_store")
RULES_ROOT.mkdir(exist_ok=True)

room_id = 0

# TODO move 2 utils
def convert_capnp_property(value):
    """Convert capnp PropertyValue to Python native type"""
    which = value.which()
    if which == 'boolVal': return value.boolVal
    elif which == 'intVal': return value.intVal
    elif which == 'floatVal': return value.floatVal
    elif which == 'stringVal': return value.stringVal
    elif which == 'colorVal': return (value.colorVal.r, value.colorVal.g, value.colorVal.b)
    else:
        raise ValueError(f"Unsupported property type: {which}")
    
def load_bigraph_from_file(path: str):
    """Load a Cap'n Proto bigraph"""
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
    logger.info(f"Loaded graph from {path}")
    return loaded_graph

# ---------------------------------------------------------
# Escalation Handling
# ---------------------------------------------------------
def merge_into_master(room_id: str, subgraph_path: Path):
    """Replace a subgraph in the master bigraph with new state from a hub."""
    global loaded_graph

    if not MASTER_FILE.exists():
        logger.error("Master graph not found. Cannot merge.")
        return

    master = load_bigraph_from_file(MASTER_FILE)

    update = load_bigraph_from_file(subgraph_path)

    updated_node = None
    for node in update.nodes:
        if node.control == "Room":
            updated_node = node
            break

    if not updated_node:
        logger.error("No Room node found in update")
        return

    target_node = None
    target_index = None
    for i, node in enumerate(master.nodes):
        if node.control == "Room" and node.properties.get("name") == updated_node.properties.get("name"):
            target_node = node
            target_index = i
            break

    if not target_node:
        logger.warning(f"Room {updated_node.properties.get('name')} not found in master, adding it")
        master.nodes.append(updated_node)
    else:
        master.nodes[target_index] = updated_node
        logger.info(f"Replaced room {updated_node.properties.get('name')} in master")

    master.save(MASTER_FILE)
    loaded_graph = master
    logger.info(f"Merged update for room {updated_node.properties.get('name')} into master bigraph")

# TODO move 2 utils
def validate_node(node: dict):
    """Validate that node control and properties follow CONTROL_SCHEMA"""
    control = node.get("control")
    if control not in CONTROL_SCHEMA:
        raise ValueError(f"Invalid control: {control}")

    valid_props = CONTROL_SCHEMA[control].get("properties")
    if valid_props and "properties" in node:
        for prop, val in node["properties"].items():
            if prop not in valid_props:
                raise ValueError(f"Invalid property '{prop}' for '{control}'")
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

# TODO move 2 utils
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
    # r.publish(channel, capnp_data)
    r.publish(f"hub:{room_id}:rules", capnp_data)
    r.set(f"rule:{generated_rule.name}", capnp_data)
    logger.info(f"Published new rule '{rule.name}' to hub:{room_id}:rules")

    return {"status": "ok", "name": rule["name"]}

async def handle_escalation(room_id: str, subgraph_file: str):
    """Handles a single escalation request by generating and publishing a rule via LLM."""
    logger.info("Handling escalation")
    merge_into_master(room_id, Path(subgraph_file))
    
    escalation_client = Client("mcp_funcs.py")
    
    try:
        async with escalation_client:
            resp = await escalation_client.call_tool("load_bigraph_from_file_glob", {"path": "master_building_graph.capnp"})
            
            state_resp = await escalation_client.call_tool("query_state", {})
            subgraph_state_dict = state_resp.data
            
            tools = await escalation_client.list_tools()
            tool_list_str = "\n".join(f"- {t.name}: {t.description}" for t in tools)
            
            tool, args = await llm(
                get_prompt(json.dumps(subgraph_state_dict, indent=2), tool_list_str),
                tools
            )

            if not tool:
                logger.warning("LLM did not select a tool.")
                return

            if "graph_json" in args:
                args["graph_json"] = subgraph_state_dict

            if tool == "publish_rule_to_redis" and "rule" in args:
                args["rule"]["room_id"] = room_id

            resp = await escalation_client.call_tool(tool, args)
            result = resp.data

            logger.info(f"Tool '{tool}' executed with result: {result}")

            if tool == "publish_rule_to_redis" and result.get("status") == "ok":
                logger.info(f"Rule '{result.get('name')}' successfully published for room {room_id}")
            elif tool != "publish_rule_to_redis":
                logger.info(f"Tool '{tool}' completed successfully")
            else:
                logger.warning("Tool execution did not complete successfully.")
                
    except Exception as e:
        logger.error(f"Error in escalation handler: {e}")
        raise

def run_escalation_listener():
    """Wrapper to run the async escalation listener in its own event loop"""
    asyncio.run(listen_for_escalations())

async def listen_for_escalations():
    """Async Redis listener — runs escalation handling to completion."""
    r = redis.Redis()
    ps = r.pubsub()
    ps.subscribe("building:requests")
    logger.info("Listening for escalations on 'building:requests'")
    
    # Use async Redis if available, or handle sync in executor
    loop = asyncio.get_event_loop()
    
    try:
        for msg in ps.listen():
            if msg["type"] != "message":
                continue
            try:
                data = json.loads(msg["data"])
                if data.get("type") == "ESCALATION_REQUEST":
                    # Handle escalation asynchronously
                    await handle_escalation(data["hub_id"], data["graph_file"])
            except Exception as e:
                logger.error(f"Error handling escalation: {e}")
    except Exception as e:
        logger.error(f"Redis listener error: {e}")
        raise


async def run_ollama(prompt: str) -> str:
    proc = subprocess.Popen(
        ["ollama", "run", OLLAMA_MODEL],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True)
    out, err = proc.communicate(prompt)
    if err:
        print("Ollama error:", err)
    return out.strip()

async def llm(user_prompt: str, tools):
    tool_list = "\n".join(f"- {t.name}: {t.description}" for t in tools)
    output = await run_ollama(get_prompt(user_prompt, tool_list))

    if output.strip().startswith("```"):
        output = re.sub(r"^```(?:json)?\n?", "", output)
        output = re.sub(r"\n?```$", "", output)

    try:
        parsed = json.loads(output)
        tool = parsed.get("tool")
        args = parsed.get("args", {})
        return tool, args

    except json.JSONDecodeError as e:
        print("Error: invalid JSON", output)
        print(f"Details: {e}")
        return None, {}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------
if __name__ == "__main__":
    try:
        listener_thread = threading.Thread(target=run_escalation_listener, daemon=True)
        listener_thread.start()
        
        logger.info("Server started. Press Ctrl+C to exit.")
        
        # Keep the main thread alive
        while True:
            listener_thread.join(timeout=1.0)  # Check every second
            if not listener_thread.is_alive():
                logger.error("Listener thread died, restarting...")
                listener_thread = threading.Thread(target=run_escalation_listener, daemon=True)
                listener_thread.start()
                
    except KeyboardInterrupt:
        logger.info("Shutting down server...")
    except Exception as e:
        logger.error(f"Server error: {e}")
        raise

