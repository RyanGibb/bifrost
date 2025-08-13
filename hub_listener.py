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

        self.state_file = pathlib.Path(f"{hub_id}_state.capnp") # TODO - won't work irl, fix
        self.rules_dir = pathlib.Path(f"{hub_id}_rules") # TODO - won't work irl, fix
        self.rules_dir.mkdir(exist_ok=True)

        self.state: Dict[str, Any] = {"nodes": {}}

    # === State Management ===
    def initialize_default_room(self):
        """If no state file, create default meeting room graph"""
        self.state["nodes"] = {
            1: {"id": 1, "control": "Room", "properties": {"name": "MeetingRoom"}, "ports": [], "parent": None},
            2: {"id": 2, "control": "Light", "properties": {"brightness": False}, "ports": [], "parent": 1},
            3: {"id": 3, "control": "Display", "properties": {"on": False}, "ports": [], "parent": 1},
            5: {"id": 5, "control": "PIR", "properties": {"motion_detected": False}, "ports": [], "parent": 1},
        }
        self.save_state()

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
    def handle_event(self, event: Dict[str, Any]):
        if event.get("type") == "USER_ENTERED_ROOM":
            logger.info("Event: USER_ENTERED_ROOM")
            self.update_node_property(5, "motion_detected", True)

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
    if not hub.state_file.exists():
        hub.initialize_default_room()
    hub.listen()
