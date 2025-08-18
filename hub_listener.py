#!/usr/bin/env python3
import json
import pathlib
import logging
import redis
import subprocess
import time
import capnp
import os
from typing import Dict, Any, Optional

# ==== Logging ====
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] HUB %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("hub")

# ==== Cap’n Proto schema ====
capnp.remove_import_hook()
bigraph_capnp = capnp.load(
    str(pathlib.Path(__file__).parent / "lib" / "bigraph_rpc.capnp")
)

class LocalHub:
    def __init__(self, hub_id: str, parent_channel: str = "building:requests"):
        self.hub_id = hub_id
        self.parent_channel = parent_channel
        self.redis_client = redis.Redis()

        self.state_file = pathlib.Path(f"{hub_id}_state.capnp")
        self.rules_dir = pathlib.Path(f"rules_store/{hub_id}/")
        self.rules_dir.mkdir(exist_ok=True)

        self.init_room_state()

    def save_state(self):
        """Write internal state dict to Cap’n Proto file"""
        msg = bigraph_capnp.Bigraph.new_message()
        msg.siteCount = 0
        msg.names = []

        nodes = list(self.state["nodes"].values())
        capnp_nodes = msg.init("nodes", len(nodes))
        for i, nd in enumerate(nodes):
            capnp_nodes[i].id = nd["id"]
            capnp_nodes[i].control = nd["control"]
            capnp_nodes[i].arity = len(nd["ports"])
            capnp_nodes[i].parent = nd["parent"] if nd["parent"] is not None else -1
            if nd["ports"]:
                ports = capnp_nodes[i].init("ports", len(nd["ports"]))
                for j, port in enumerate(nd["ports"]):
                    ports[j] = port
            if nd["properties"]:
                props = capnp_nodes[i].init("properties", len(nd["properties"]))
                for j, (k, v) in enumerate(nd["properties"].items()):
                    props[j].key = k
                    if isinstance(v, bool):
                        props[j].value.boolVal = v
                    elif isinstance(v, int):
                        props[j].value.intVal = v
                    elif isinstance(v, float):
                        props[j].value.floatVal = v
                    elif isinstance(v, str):
                        props[j].value.stringVal = v

        with self.state_file.open("wb") as f:
            msg.write(f)
        logger.info("Saved state to %s", self.state_file)

    def update_node_property(self, node_id: int, key: str, value: Any):
        if node_id in self.state["nodes"]:
            self.state["nodes"][node_id]["properties"][key] = value
            self.save_state()
            
    def init_room_state(self):
        """Initialize state based on hub_id - map hub to room"""
        # Map hub IDs to room configurations
        room_configs = {
            "room42": {
                "room_id": 1,
                "room_name": "MeetingRoom42",
                "light_id": 2,
                "display_id": 3,
                "pir_id": 4
            },
            "office1": {
                "room_id": 10,
                "room_name": "Office1", 
                "light_id": 11,
                "pir_id": 12
            },
            "conference": {
                "room_id": 20,
                "room_name": "ConferenceA",
                "light_id": 21,
                "pir_id": 22
            }
        }
        
        config = room_configs.get(self.hub_id)
        if not config:
            logger.error(f"Unknown hub_id: {self.hub_id}")
            return
            
        # Build initial state
        room_node = {
            "id": config["room_id"],
            "control": "Room",
            "parent": None,
            "ports": [],
            "properties": {"name": config["room_name"]},
            "name": config["room_name"],
            "type": "Room"
        }
        
        light_node = {
            "id": config["light_id"],
            "control": "Light",
            "parent": config["room_id"],
            "ports": [],
            "properties": {"brightness": 0},  # Start with lights off
            "name": f"light_{self.hub_id}",
            "type": "Light"
        }
        
        pir_node = {
            "id": config["pir_id"],
            "control": "PIR",
            "parent": config["room_id"],
            "ports": [],
            "properties": {"motion_detected": False},
            "name": f"pir_{self.hub_id}",
            "type": "PIR"
        }
        
        self.state = {
            "nodes": {
                config["room_id"]: room_node,
                config["light_id"]: light_node,
                config["pir_id"]: pir_node
            }
        }
        
        if "display_id" in config:
            display_node = {
                "id": config["display_id"],
                "control": "Display",
                "parent": config["room_id"],
                "ports": [],
                "properties": {"on": False},
                "name": f"display_{self.hub_id}",
                "type": "Display"
            }
            self.state["nodes"][config["display_id"]] = display_node
        
        self.save_state()

    def update_node_property(self, node_id: int, key: str, value: Any):
        if node_id in self.state["nodes"]:
            self.state["nodes"][node_id]["properties"][key] = value
            self.save_state()

    # === Rules ===
    def local_rules(self):
        return list(self.rules_dir.glob("*.capnp"))

    def apply_rule(self, rule_file: pathlib.Path) -> bool:
        """Apply an OCaml rule via bridge.exe"""
        cmd = [
            "_build/default/bin/bridge.exe",
            str(rule_file),
            str(self.state_file),
        ]
        res = subprocess.run(cmd, text=True, capture_output=True)
        if res.returncode == 0:
            logger.info("Applied rule: %s", rule_file.name)
            return True
        else:
            logger.warning("Rule failed: %s (%s)", rule_file.name, res.stderr.strip())
            return False

    # === Escalation to parent ===
    def escalate(self, event: Dict[str, Any]):
        payload = {
            "type": "ESCALATION_REQUEST",
            "hub_id": self.hub_id,
            "timestamp": time.time(),
            "event": event,
            "graph_file": str(self.state_file),
        }
        self.redis_client.publish(self.parent_channel, json.dumps(payload))
        logger.info("Escalated event to parent channel '%s'", self.parent_channel)

    # === Event handling ===
    # TODO hardcoded for now
    def handle_event(self, event: Dict[str, Any]):
        if event.get("type") == "USER_ENTERED_ROOM":
            logger.info("Event: USER_ENTERED_ROOM")
            
            # Find PIR sensor in this room
            pir_node = None
            for node in self.state["nodes"].values():
                if node["control"] == "PIR":
                    pir_node = node
                    break
                    
            if pir_node:
                self.update_node_property(pir_node["id"], "motion_detected", True)

            rules = self.local_rules()
            if not rules:
                logger.info("No local rules — escalating to parent")
                self.escalate(event)
                return

            applied = False
            for rf in rules:
                if self.apply_rule(rf):
                    logger.info("Success")
                    applied = True

            if not applied:
                logger.info("No rules matched — escalating to parent")
                self.escalate(event)

    # === Hub runtime ===
    def listen(self):
        event_channel = f"iot:events:{self.hub_id}"
        rule_channel = f"hub:{self.hub_id}:rules"
        ps = self.redis_client.pubsub()
        ps.subscribe([event_channel, rule_channel])

        logger.info("Listening on %s (events) and %s (rules)", event_channel, rule_channel)
        for msg in ps.listen():
            if msg["type"] != "message":
                continue
            try:
                data = msg["data"]
                # Rule channel — binary capnp
                if msg["channel"].decode() == rule_channel:
                    rule_path = self.rules_dir / f"rule_{int(time.time())}.capnp"
                    with rule_path.open("wb") as f:
                        f.write(data)
                    logger.info("Received new rule from parent: %s", rule_path.name)
                else:
                    event = json.loads(data)
                    self.handle_event(event)
            except Exception as e:
                logger.error("Error processing message: %s", e)


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} HUB_ID")
        sys.exit(1)

    hub_id = sys.argv[1]
    hub = LocalHub(hub_id)
    hub.listen()