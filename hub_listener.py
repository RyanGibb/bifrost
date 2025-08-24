import re
import sys
import json
import time
import redis
import logging
import pathlib
import argparse
import subprocess
from typing import Dict, Any, Optional, Tuple, List

# --- setup / capnp -----------------------------------------------------------
sys.path.append(str(pathlib.Path(__file__).parent / "lib"))
from utils import load_state_dict_from_capnp  # noqa: E402

import capnp  # noqa: E402
capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(pathlib.Path(__file__).parent / "lib" / "bigraph_rpc.capnp"))

# --- logging -----------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] HUB %(levelname)s: %(message)s", datefmt="%H:%M:%S")
logger = logging.getLogger("hub")

class LocalHub:
    # ---------- init / bootstrap ----------
    def __init__(self, hub_id: str):
        logger.info("launching hub %s", hub_id)
        self.hub_id = hub_id
        self.redis_client = redis.Redis()
        self.state_file = pathlib.Path(f"{hub_id}_state.capnp")
        self.rules_dir = pathlib.Path(f"rules_store/{hub_id}/")
        self.rules_dir.mkdir(parents=True, exist_ok=True)

        self.state: Dict[str, Any] = {"nodes": {}}
        self.pending_events: List[dict] = []
        self.mid_id: Optional[str] = None

        self._load_or_request_state()
        self._get_mid_from_state()

    def _load_or_request_state(self):
        if self.state_file.exists():
            try:
                current = load_state_dict_from_capnp(self.state_file)
                if not current.get("nodes"):
                    self.request_graph("empty_graph")
            except Exception:
                self.request_graph("invalid_graph")
            logger.info("Using graph: %s", self.state_file)
            self.state = load_state_dict_from_capnp(self.state_file)
        else:
            logger.warning("No graph yet; requesting from above")
            self.request_graph("no_graph")

    # ---------- messaging ----------
    def _publish(self, channel: str, payload: Dict[str, Any]):
        self.redis_client.publish(channel, json.dumps(payload))

    def request_graph(self, reason: str = "startup"):
        payload = {"type": "GRAPH_REQUEST", "hub_id": self.hub_id, "reason": reason}
        channel = f"mid:{self.mid_id}:requests" if getattr(self, "mid_id", None) else f"hub:{self.hub_id}:requests"
        self._publish(channel, payload)
        logger.info("requested graph via %s (%s)", channel, reason)

    def escalate(self, event: Dict[str, Any], reason: str = "no_matching_rules", matched_rule: str | None = None):
        payload = {
            "type": "ESCALATION_REQUEST",
            "hub_id": self.hub_id,
            "event": event,
            "timestamp": time.time(),
            "reason": reason,
            "graph_file": str(self.state_file),
            "matched_rule": matched_rule}
        channel = f"mid:{self.mid_id}:requests" if getattr(self, "mid_id", None) else f"hub:{self.hub_id}:requests"
        self.redis_client.publish(channel, json.dumps(payload))
        logger.info("Escalated to %s (%s) rule=%s", channel, reason, matched_rule)

    # ---------- graph ----------
    def _resolve_selector_to_id(self, selector: str | int) -> Optional[int]:
        # uid property
        for nd in self.state["nodes"].values():
            if nd.get("properties", {}).get("uid") == selector:
                return nd["id"]
        # name property or node name
        for nd in self.state["nodes"].values():
            nm = nd.get("properties", {}).get("name") or nd.get("name")
            if nm == selector:
                return nd["id"]
        return None

    def _is_descendant(self, child_id: int, ancestor_id: int) -> bool:
        nodes = self.state["nodes"]
        parent = nodes.get(child_id, {}).get("parent", -1)
        while parent != -1 and parent in nodes:
            if parent == ancestor_id:
                return True
            parent = nodes[parent].get("parent", -1)
        return False

    def _hub_root_id(self) -> Optional[int]:
        nodes = self.state["nodes"]
        # find hub node matching this hub_id
        for nid, nd in nodes.items():
            if nd.get("control") == "Hub":
                props = nd.get("properties", {})
                if props.get("hub_id") == self.hub_id or nd.get("name") == self.hub_id:
                    return nd.get("parent") if nd.get("parent", -1) != -1 else nid
        # else: any node with hub_id
        for nid, nd in nodes.items():
            if nd.get("properties", {}).get("hub_id") == self.hub_id:
                return nid
        if nodes:
            all_ids = set(nodes.keys())
            non_roots = {nd.get("parent") for nd in nodes.values() if nd.get("parent", -1) != -1}
            roots = [i for i in all_ids if i not in non_roots]
            return roots[0] if roots else None
        return None

    def _derive_mid_id_from_state(self) -> Optional[str]:
        # find hub node with this hub_id and a mid_id
        for nd in self.state["nodes"].values():
            if nd.get("control") == "Hub":
                props = nd.get("properties", {})
                if props.get("hub_id") == self.hub_id and "mid_id" in props:
                    return props["mid_id"]
        # else: any node with mid_id
        for nd in self.state["nodes"].values():
            mid = nd.get("properties", {}).get("mid_id")
            if isinstance(mid, str) and mid:
                return mid
        return None

    def _get_mid_from_state(self):
        self.mid_id = self._derive_mid_id_from_state()
        if self.mid_id:
            logger.info("Hub %s learned mid_id=%s", self.hub_id, self.mid_id)

    def save_state_dict_to_capnp(self):
        msg = bigraph_capnp.Bigraph.new_message()
        msg.siteCount = 0
        msg.names = []
        nodes = list(self.state["nodes"].values())
        cap_nodes = msg.init("nodes", len(nodes))
        for i, nd in enumerate(nodes):
            cap_nodes[i].id = nd["id"]
            cap_nodes[i].control = nd["control"]
            cap_nodes[i].arity = len(nd.get("ports", []))
            cap_nodes[i].parent = nd.get("parent", -1) if nd.get("parent") is not None else -1
            cap_nodes[i].name = nd.get("name", f"node_{nd['id']}")
            cap_nodes[i].type = nd.get("type", nd["control"])
            if nd.get("ports"):
                ports = cap_nodes[i].init("ports", len(nd["ports"]))
                for j, p in enumerate(nd["ports"]):
                    ports[j] = p
            if nd.get("properties"):
                props = cap_nodes[i].init("properties", len(nd["properties"]))
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

    def update_node_property(self, node_id: int, key: str, value: Any):
        node = self.state["nodes"].get(node_id)
        if not node:
            return
        node.setdefault("properties", {})[key] = value
        self.save_state_dict_to_capnp()

    # ---------- occupancy ----------
    # TODO sort out later

    def _resolve_space_id(self, selector: str | int) -> Optional[int]:
        return self._resolve_selector_to_id(selector)

    def _set_occupancy(self, space_id: int, value: int):
        node = self.state["nodes"].get(space_id)
        if not node:
            return
        node.setdefault("properties", {})["occupancy"] = max(0, value)
        self.save_state_dict_to_capnp()

    def _get_occupancy(self, space_id: int) -> int:
        try:
            return int(self.state["nodes"].get(space_id, {}).get("properties", {}).get("occupancy", 0))
        except Exception:
            return 0

    def _find_user_node(self, user: str) -> Tuple[Optional[int], Optional[int]]:
        for nid, node in self.state["nodes"].items():
            if node.get("control") != "User":
                continue
            props = node.get("properties", {})
            if props.get("uid") == user or props.get("email") == user:
                return nid, node.get("parent")
        return None, None

    def _adjust_space_occupancy(self, space_id: Optional[int], delta: int):
        if space_id is None or space_id not in self.state["nodes"]:
            return
        self._set_occupancy(space_id, max(0, self._get_occupancy(space_id) + delta))

    def add_user(self, user: str, space_id: int):
        if space_id not in self.state["nodes"]:
            logger.warning("Space %s not found", space_id)
            return

        parent_node = self.state["nodes"][space_id]
        space_name = parent_node.get("properties", {}).get("name", f"space_{space_id}")
        hub_id = parent_node.get("properties", {}).get("hub_id", self.hub_id)

        existing_id = None
        for nid, node in self.state["nodes"].items():
            if node.get("control") == "User":
                props = node.get("properties", {})
                if props.get("uid") == user or props.get("email") == user:
                    existing_id = nid
                    break

        if existing_id is not None:
            self.state["nodes"][existing_id]["parent"] = space_id
            self.state["nodes"][existing_id].setdefault("properties", {}).update(
                {"space": space_name, "hub_id": hub_id})
            logger.info("Moved user %s (id=%d) to space %s", user, existing_id, space_name)
        else:
            new_id = max(self.state["nodes"].keys(), default=0) + 1
            self.state["nodes"][new_id] = {
                "id": new_id,
                "control": "User",
                "parent": space_id,
                "properties": {"uid": user, "email": user, "space": space_name, "hub_id": hub_id}}
            logger.info("Added user %s (id=%d) to space %s", user, new_id, space_name)

        self.save_state_dict_to_capnp()

    def rm_user(self, user: str):
        for nid, node in list(self.state["nodes"].items()):
            if node.get("control") == "User":
                props = node.get("properties", {})
                if props.get("uid") == user or props.get("email") == user:
                    del self.state["nodes"][nid]
                    logger.info("Removed user %s (node id=%d)", user, nid)
                    self.save_state_dict_to_capnp()
                    return
        logger.warning("No user %s found", user)

    def update_occupancy(self, space_selector: str | int | None, entered: Optional[List[str]] = None, left: Optional[List[str]] = None,):
        entered = entered or []
        left = left or []

        sid = None
        if entered:
            sid = self._resolve_space_id(space_selector) if space_selector is not None else None
            if sid is None:
                logger.warning("Space '%s' not found", space_selector)
                entered = []

        for u in entered:
            _, prev_space = self._find_user_node(u)
            self.add_user(u, sid)
            if prev_space is not None and prev_space != sid:
                self._adjust_space_occupancy(prev_space, -1)
            self._adjust_space_occupancy(sid, +1)

        for u in left:
            user_node_id, prev_space = self._find_user_node(u)
            exit_sid = self._resolve_space_id(space_selector) if space_selector is not None else prev_space
            if prev_space is not None and exit_sid == prev_space:
                self.rm_user(u)
                self._adjust_space_occupancy(prev_space, -1)
            else:
                if user_node_id is None:
                    logger.info("Left: user %s not found; no-op", u)
                else:
                    logger.info(
                        "Left: user %s current space=%s does not match provided space=%s; no-op",
                        u,
                        prev_space,
                        exit_sid,
                    )

    # ---------- rules ----------
    def get_rules(self) -> List[pathlib.Path]:
        return sorted(self.rules_dir.glob("*.capnp"))

    def _is_escalate(self, rule_name: str) -> bool:
        return rule_name.startswith("ESCALATE__")

    def _get_rule_name(self, rule_file: pathlib.Path) -> str:
        try:
            with rule_file.open("rb") as f:
                rule = bigraph_capnp.Rule.read(f)
            return rule.name
        except Exception:
            return rule_file.name

    def _current_rev_ts(self) -> int:
        rid = self._hub_root_id()
        if rid is None: return 0
        try:
            return int(self.state["nodes"][rid].get("properties", {}).get("rev_ts", 0))
        except Exception:
            return 0

    def _bump_rev(self, who: str = "hub"):
        rid = self._hub_root_id()
        if rid is None:
            return
        now = int(time.time() * 1000)
        self.update_node_property(rid, "rev_ts", now)
        self.update_node_property(rid, "rev_by", who)

    def _atomic_replace_state_bytes(self, raw: bytes):
        tmp = self.state_file.with_suffix(".capnp.tmp")
        tmp.write_bytes(raw)
        tmp.replace(self.state_file)

    def _is_incoming_graph_stale(self, incoming_path: pathlib.Path) -> bool:
        try:
            incoming = load_state_dict_from_capnp(incoming_path)
            rid = self._hub_root_id()
            if rid is None:
                return False
            cur = self._current_rev_ts()
            inc = int(incoming["nodes"][rid].get("properties", {}).get("rev_ts", 0))
            return inc <= cur
        except Exception:
            return False
        
    def apply_rule(self, rule_file: pathlib.Path) -> Tuple[bool, bool, str]:
        """
        returns: (matched, is_escalate, rule_name)

        behavior:
        - bridge.exe both checks and, when matched, writes the new state to self.state_file.
        - we treat 'rule applied successfully!' as the write signal (needs upated to something more explicit later)
        """
        rule_name = self._get_rule_name(rule_file)
        is_escal = self._is_escalate(rule_name)

        try:
            res = subprocess.run(
                ["_build/default/bin/bridge.exe", str(rule_file), str(self.state_file)],
                text=True,
                capture_output=True,
                timeout=15.0,                     # NEW: timeout
                check=False
            )
        except subprocess.TimeoutExpired:
            logger.warning("bridge.exe timed out applying %s", rule_name)
            return False, is_escal, rule_name

        out = (res.stdout or "") + ("\n" + res.stderr if res.stderr else "")

        can_apply = False
        applied = False
        m = re.search(r"Can apply rule:\s*(true|false)", out, flags=re.IGNORECASE)
        if m:
            can_apply = (m.group(1).lower() == "true")
        if re.search(r"Rule applied successfully!", out, flags=re.IGNORECASE):
            applied = True

        matched = bool(can_apply or applied)

        logger.info("Rule check: %s (matched=%s, escal=%s, applied=%s, rc=%s)",
                    rule_name, matched, is_escal, applied, res.returncode)

        # If applied, reload and bump rev timestamp (for CAS)
        if applied:
            try:
                self.state = load_state_dict_from_capnp(self.state_file)
                self._bump_rev("hub")            # NEW: mark fresh local write
            except Exception as e:
                logger.warning("Applied rule but failed to reload state: %s", e)

        return matched, is_escal, rule_name

    # ---------- events ----------
    def _handle_event_payload(self, ch: str, raw: bytes):
        if ch.endswith(":rules"):
            rule_path = self.rules_dir / f"rule_{int(time.time())}.capnp"
            rule_path.write_bytes(raw)
            logger.info("received new rule: %s", rule_path.name)
            return

        if ch.endswith(":graph"):
            # CAS-lite: ignore stale region slices
            tmp_in = self.state_file.with_suffix(".incoming.capnp")
            tmp_in.write_bytes(raw)
            if self._is_incoming_graph_stale(tmp_in):
                logger.info("Ignored stale incoming graph (rev_ts<=current)")
                try: tmp_in.unlink()
                except Exception: pass
                return

            self._atomic_replace_state_bytes(raw)
            self.state = load_state_dict_from_capnp(self.state_file)
            self._get_mid_from_state()
            logger.info("Saved graph to %s (mid_id=%s)", self.state_file, getattr(self, "mid_id", None))

            if self.pending_events:
                backlog = self.pending_events[:]
                self.pending_events.clear()
                for ev in backlog:
                    self.handle_event(ev)
            return

        event = json.loads(raw)
        self.handle_event(event)

    def handle_event(self, event: dict):
        et = event.get("type")
        ed = event.get("data", {})

        if not self.state["nodes"]:
            self.request_graph("no_graph_yet")
            self.pending_events.append(event)
            return

        ########################################################################
        # TODO sort out
        if et == "USER_ENTERED_ROOM":
            space, user = ed.get("space"), ed.get("user")
            if space and user:
                self.update_occupancy(space, entered=[user])

        elif et == "MULTIPLE_USERS_ENTERED":
            space, users = ed.get("space"), ed.get("users", [])
            if space and users:
                self.update_occupancy(space, entered=users)

        elif et == "USER_LEFT_ROOM":
            space, user = ed.get("space"), ed.get("user")
            if space and user:
                self.update_occupancy(space, left=[user])

        elif et == "MULTIPLE_USERS_LEFT":
            space, users = ed.get("space"), ed.get("users", [])
            if space and users:
                self.update_occupancy(space, left=users)

        elif et == "SCHEDULED_MEETING_STARTED":
            meeting_id = ed.get("meeting_id", "")
            for node in self.state["nodes"].values():
                if node.get("control") == "TranscriptionUnit":
                    self.update_node_property(node["id"], "meeting_id", meeting_id)
        ########################################################################

        # ---- rules & escalation ----
        rules = self.get_rules()
        if not rules:
            self.escalate(event, reason="no_stored_rules")
            return

        any_matched = False
        first_escalate_rule = None

        for rf in rules:
            matched, is_esc, rname = self.apply_rule(rf)
            if matched:
                any_matched = True
                try:
                    self.state = load_state_dict_from_capnp(self.state_file)
                except Exception as e:
                    logger.warning("Applied rule but failed to reload state: %s", e)
                if is_esc and first_escalate_rule is None:
                    first_escalate_rule = rname

        if not any_matched:
            self.escalate(event, reason="no_matched_rules")
            return

        if first_escalate_rule:
            self.escalate(event, reason="rule_requested_escalation", matched_rule=first_escalate_rule)
            return

    def listen(self):
        event_chl = f"iot:events:{self.hub_id}"
        rule_chl = f"hub:{self.hub_id}:rules"
        graph_chl = f"hub:{self.hub_id}:graph"

        ps = self.redis_client.pubsub()
        ps.subscribe([event_chl, rule_chl, graph_chl])
        logger.info("Listening on %s (events), %s (rules), %s (graph)", event_chl, rule_chl, graph_chl)

        for msg in ps.listen():
            if msg.get("type") != "message":
                continue
            ch = msg["channel"].decode()
            try:
                self._handle_event_payload(ch, msg["data"])
            except Exception as e:
                logger.error("Error processing msg: %s", e)


# ============================================================================
# main
# ============================================================================
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("hub_id", help="hub ID (e.g., exec, alpha, beta, open)")
    args = parser.parse_args()
    LocalHub(args.hub_id).listen()


if __name__ == "__main__":
    main()
