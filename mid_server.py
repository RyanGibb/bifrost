import argparse
import asyncio
import json
import base64
import re
import os
import sys
from pathlib import Path

import capnp
import redis.asyncio as redis

# ----- local libs -----
sys.path.append(str(Path(__file__).parent / "lib"))
from utils import cp_prop_value
from prompt import get_prompt

# ----- logging -----
import logging
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] MID  %(levelname)-8s %(message)s", datefmt="%H:%M:%S")
logger = logging.getLogger("mid")

# ----- capnp schema -----
capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(Path(__file__).parent / "lib" / "bigraph_rpc.capnp"))

# ----- LLM / tools -----
from fastmcp import Client

LOCAL_TOOL_WHITELIST = {
    "load_bigraph_from_file_glob",
    "query_state",
    "publish_rule_to_redis",
    "publish_rules_batch",
    "save_graph_to_file"}
OLLAMA_MODEL = "gemma3:270m"
OLLAMA_TIMEOUT_SEC = float(os.environ.get("OLLAMA_TIMEOUT_SEC", "60"))
MAX_STEPS = int(os.environ.get("MID_MAX_STEPS", "10"))

# ---------- helpers ----------

def _get_prop(node, key):
    for p in node.properties:
        if p.key == key:
            v = p.value
            return getattr(v, v.which())
    return None

def _node_name_like(n):
    try:
        return _get_prop(n, "name") or getattr(n, "name", "")
    except Exception:
        return ""

# TODO move 2 utils
def _mint_uid(prefix: str = "n") -> str:
    import uuid, time
    # ULID would be nicer; keep it stdlib: time-ordered-ish prefix + short uuid
    return f"{prefix}_{int(time.time()*1000)}_{uuid.uuid4().hex[:8]}"

# TODO move 2 utils
def _ensure_reactum_uids(rule_or_rules):
    def ensure_on_rule(r: dict):
        for nd in r.get("reactum", []) or []:
            props = nd.setdefault("properties", {})
            if not props.get("uid"):
                props["uid"] = _mint_uid()
    if isinstance(rule_or_rules, dict):
        ensure_on_rule(rule_or_rules)
    else:
        for r in (rule_or_rules or []):
            if isinstance(r, dict): ensure_on_rule(r)
    return rule_or_rules

def _resolve_selector_to_id(msg, selector: str | int):
    for n in msg.nodes:
        if _get_prop(n, "uid") == selector:
            return n.id
    for n in msg.nodes:
        if _node_name_like(n) == selector:
            return n.id
    try:
        sel_id = int(selector)
        for n in msg.nodes:
            if n.id == sel_id:
                return n.id
    except Exception:
        pass
    return None

def _collect_subtree_ids(msg, root_id: int) -> set[int]:
    keep = {root_id}
    added = True
    while added:
        added = False
        for n in msg.nodes:
            if n.parent in keep and n.id not in keep:
                keep.add(n.id); added = True
    return keep

def _find_hub_root_id(region_msg, hub_id: str) -> int | None:
    for n in region_msg.nodes:
        if n.control == "Hub":
            hid = _get_prop(n, "hub_id") or _node_name_like(n) or str(n.id)
            if hid == hub_id:
                return n.parent if n.parent != -1 else n.id
    for n in region_msg.nodes:
        if _get_prop(n, "hub_id") == hub_id:
            return n.id
    return None


def _flatten_nodes_of_slice(msg, root_id: int) -> list[dict]:
    ids = _collect_subtree_ids(msg, root_id)
    sub = _build_graph_from_nodes(msg, ids)
    return _nodes_from_bigraph_msg(sub)

def _build_graph_from_nodes(src_msg, node_ids):
    idset = set(node_ids)
    nodes = [n for n in src_msg.nodes if n.id in idset]
    out = bigraph_capnp.Bigraph.new_message()
    out.siteCount = getattr(src_msg, "siteCount", 0)
    out.names = list(getattr(src_msg, "names", []))
    cap_nodes = out.init("nodes", len(nodes))
    for i, n in enumerate(nodes):
        cap_nodes[i].id = n.id
        cap_nodes[i].control = n.control
        cap_nodes[i].arity = n.arity
        cap_nodes[i].parent = n.parent if n.parent in idset else -1
        try: cap_nodes[i].name = getattr(n, "name", f"node_{n.id}")
        except Exception: pass
        try: cap_nodes[i].type = getattr(n, "type", n.control)
        except Exception: pass
        if len(n.ports):
            ports = cap_nodes[i].init("ports", len(n.ports))
            for j, p in enumerate(n.ports): ports[j] = p
        if len(n.properties):
            props = cap_nodes[i].init("properties", len(n.properties))
            for j, p in enumerate(n.properties):
                props[j].key = p.key
                cp_prop_value(props[j].value, p.value)
    return out

def _is_noop_rule(rule: dict) -> bool:
    try:
        return json.dumps(rule.get("redex") or [], sort_keys=True) == json.dumps(rule.get("reactum") or [], sort_keys=True)
    except Exception:
        return False

def _validate_escalate_rules(rules: list[dict]) -> tuple[bool, str]:
    for r in rules:
        name = (r.get("name") or "")
        if isinstance(name, str) and name.startswith("ESCALATE__") and not _is_noop_rule(r):
            return False, f"rule '{name}' must be a no-op (reactum == redex)."
    return True, ""

def _merge_local_into_region(local_msg, region_msg):
    """merge a hub's subgraph into region keyed by (hub_id/name, control)."""
    def key_of(node):
        return (_get_prop(n, "uid") or _get_prop(node, "hub_id") or _get_prop(node, "name") or getattr(node, "name", ""), node.control)

    idset = {n.id for n in local_msg.nodes}
    roots = [n for n in local_msg.nodes if n.parent not in idset or n.parent == -1]
    if not roots:
        return region_msg
    src_root = roots[0]
    src_key = key_of(src_root)

    region_nodes = list(region_msg.nodes)
    idx = next((i for i, n in enumerate(region_nodes) if key_of(n) == src_key), None)

    local_ids = _collect_subtree_ids(local_msg, src_root.id)
    local_nodes = [n for n in local_msg.nodes if n.id in local_ids]

    if idx is None:
        existing = {n.id for n in region_nodes}
        region_nodes.extend(n for n in local_nodes if n.id not in existing)
    else:
        region_nodes[idx] = src_root
        existing = {n.id for n in region_nodes}
        region_nodes.extend(n for n in local_nodes if n.id not in existing)

    out = bigraph_capnp.Bigraph.new_message()
    out.siteCount = region_msg.siteCount
    out.names = list(region_msg.names)
    cap_nodes = out.init("nodes", len(region_nodes))
    for i, n in enumerate(region_nodes):
        cap_nodes[i] = n
    return out

# TODO more 2 utils
def _add_or_update_string_prop_on_node(msg, node_id: int, key: str, value: str):
    out = bigraph_capnp.Bigraph.new_message()
    out.siteCount = getattr(msg, "siteCount", 0)
    out.names = list(getattr(msg, "names", []))

    prop_lens, need_add = [], []
    for n in msg.nodes:
        found = any(p.key == key for p in n.properties)
        prop_lens.append(len(n.properties) + (1 if (n.id == node_id and not found) else 0))
        need_add.append(n.id == node_id and not found)

    cap_nodes = out.init("nodes", len(msg.nodes))
    for i, n in enumerate(msg.nodes):
        cap_nodes[i].id = n.id
        cap_nodes[i].control = n.control
        cap_nodes[i].arity = n.arity
        cap_nodes[i].parent = n.parent
        try: cap_nodes[i].name = getattr(n, "name", f"node_{n.id}")
        except Exception: pass
        try: cap_nodes[i].type = getattr(n, "type", n.control)
        except Exception: pass

        if len(n.ports):
            ports = cap_nodes[i].init("ports", len(n.ports))
            for j, p in enumerate(n.ports): ports[j] = p

        plen = prop_lens[i]
        if plen:
            props = cap_nodes[i].init("properties", plen)
            for j, p in enumerate(n.properties):
                props[j].key = p.key
                cp_prop_value(props[j].value, p.value)
            if n.id == node_id:
                for j in range(len(n.properties)):
                    if props[j].key == key:
                        props[j].value.stringVal = str(value)
                        break
                else:
                    props[len(n.properties)].key = key
                    props[len(n.properties)].value.stringVal = str(value)
    return out

def _nodes_from_bigraph_msg(msg):
    nodes = []
    for n in msg.nodes:
        props = {}
        for p in n.properties:
            w = p.value.which()
            props[p.key] = getattr(p.value, w)
        nodes.append({
            "id": int(n.id),
            "control": str(n.control),
            "name": getattr(n, "name", f"node_{n.id}"),
            "parent": int(getattr(n, "parent", -1)),
            "properties": props,
        })
    return nodes

def _read_nodes_from_capnp_file(path: Path) -> list[dict]:
    with path.open("rb") as f:
        msg = bigraph_capnp.Bigraph.read(f)
    return _nodes_from_bigraph_msg(msg)

# ---------- helpers: LLM / tools ----------

async def run_ollama(prompt: str) -> str:
    # logger.info(prompt)
    async def _inner():
        proc = await asyncio.create_subprocess_exec(
            "ollama", "run", OLLAMA_MODEL,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE)
        out_b, err_b = await proc.communicate(prompt.encode("utf-8"))
        if err_b:
            try: err = err_b.decode("utf-8", errors="replace").strip()
            except Exception: err = str(err_b)
            if err: logger.warning("Ollama stderr: %s", err)
        try: return out_b.decode("utf-8", errors="replace").strip()
        except Exception: return ""
    try:
        return await asyncio.wait_for(_inner(), timeout=OLLAMA_TIMEOUT_SEC)
    except asyncio.TimeoutError:
        logger.warning("Ollama timed out after %.1fs at mid", OLLAMA_TIMEOUT_SEC)
        return ""

async def _call_tool_safe(client: Client, name: str, params: dict | None = None):
    params = params or {}
    try:
        return await client.call_tool(name, params)
    except Exception as e:
        if "args" in str(e):
            return await client.call_tool(name, {"args": params})
        raise

def _extract_last_json_object(s: str) -> str | None:
    # scan backwards for a balanced {...} - bit crude
    stack = 0
    end = None
    for i, ch in enumerate(s):
        if ch == '{':
            stack += 1
        elif ch == '}':
            stack -= 1
            if stack == 0:
                end = i
    if end is None:
        return None
    # find the first '{' that leads to this balanced end
    start = s.find('{')
    if start == -1 or start > end:
        return None
    blob = s[start:end+1]
    return blob

async def mid_step(prompt: str) -> tuple[str | None, dict]:
    """
    parse LLM's JSON: returns (verb, args) where verb ∈ allowed set, else ('escalate', {}).
    """
    s = (await run_ollama(prompt)).strip()
    if not s:
        return "escalate", {}
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\n?", "", s)
        s = re.sub(r"\n?```$", "", s)
    try:
        data = json.loads(s)
    except json.JSONDecodeError:
        blob = _extract_last_json_object(s)
        if not blob:
            return "escalate", {}
        try:
            data = json.loads(blob)
        except Exception:
            return "escalate", {}

    verb = data.get("tool") or data.get("decision")
    args = data.get("args") if isinstance(data.get("args"), dict) else {}
    if "rules" in data and "rules" not in args and isinstance(data["rules"], list):
        args["rules"] = data["rules"]
    if "rule" in data and "rule" not in args and isinstance(data["rule"], dict):
        args["rule"] = data["rule"]

    allowed = {"noop", "escalate"} | LOCAL_TOOL_WHITELIST | {"publish_rule_to_redis", "publish_rules_batch"}
    if verb not in allowed:
        return "escalate", {}
    return verb, args

# ---------- Mid server ----------

class MidServer:
    def __init__(self, mid_id: str):
        self.mid_id = mid_id
        self.redis = redis.Redis()
        self.state_file = (Path(__file__).parent / f"mid_{self.mid_id}_state.capnp").resolve()
        self.mcp_script = str((Path(__file__).parent / "mcp_funcs.py").resolve())

    # ---- graph fetch / fan-out ----
    async def request_graph(self, reason: str = "startup"):
        payload = {"type": "GRAPH_REQUEST", "mid_id": self.mid_id, "reason": reason}
        await self.redis.publish("building:requests", json.dumps(payload))
        logger.info("requested slice for mid:%s (%s)", self.mid_id, reason)

    def _discover_hubs(self, region_msg):
        hubs = []
        for n in region_msg.nodes:
            if n.control == "Hub":
                hub_id = _get_prop(n, "hub_id") or _node_name_like(n) or str(n.id)
                sel = _get_prop(n, "manages_selector")
                rid = _resolve_selector_to_id(region_msg, sel) if sel else n.parent
                rid = n.id if rid is None else rid
                hubs.append((hub_id, rid))
        for n in region_msg.nodes:
            hid = _get_prop(n, "hub_id")
            if hid:
                hubs.append((hid, n.id))
        seen, out = set(), []
        for h in hubs:
            if h[0] not in seen:
                out.append(h); seen.add(h[0])
        return out

    async def _fan_out_hubs(self, region_msg):
        for hub_id, root_id in self._discover_hubs(region_msg):
            slice_ids = _collect_subtree_ids(region_msg, root_id)
            now_ms = str(int(asyncio.get_running_loop().time() * 1000))
            hub_slice = _add_or_update_string_prop_on_node(
                _build_graph_from_nodes(region_msg, slice_ids),
                root_id, "rev_ts", now_ms
            )
            await self.redis.publish(f"hub:{hub_id}:graph", hub_slice.to_bytes())
            logger.info("mid:%s pushed hub slice to hub:%s:graph (root=%s)", self.mid_id, hub_id, root_id)

    # ---- LLM path ----
    async def process(self, hub_id: str, event: dict) -> bool:
        """
        bounded controller loop.
        terminal: publish_rule_to_redis | publish_rules_batch | noop | escalate(False)
        """
        if not self.state_file.exists():
            logger.info("No stored graph")
            return False

        try:
            with self.state_file.open("rb") as f:
                region_msg = bigraph_capnp.Bigraph.read(f)
            hub_root = _find_hub_root_id(region_msg, hub_id)
            if hub_root is None:
                logger.warning("No hub root found for hub_id=%s in region; using whole region as fallback", hub_id)
                hub_nodes = _nodes_from_bigraph_msg(region_msg)
                allowed_ids = {n["id"] for n in hub_nodes}
            else:
                hub_nodes = _flatten_nodes_of_slice(region_msg, hub_root)
                allowed_ids = {n["id"] for n in hub_nodes}
        except Exception as e:
            logger.warning("Failed to read/slice region graph: %s", e)
            hub_nodes, allowed_ids = [], set()

        subgraph_state = json.dumps({"nodes": hub_nodes}, indent=2)

        client = Client(self.mcp_script)
        logger.info("spawning MCP: %s ", self.mcp_script)

        async with client:
            await _call_tool_safe(client, "load_bigraph_from_file_glob", {"path": str(self.state_file)})

            try:
                tools = await client.list_tools()
                tool_list = "\n".join(
                    f"- {t.name}: {t.description}"
                    for t in tools if t.name in LOCAL_TOOL_WHITELIST
                )
            except Exception:
                tool_list = "\n".join(f"- {n}" for n in sorted(LOCAL_TOOL_WHITELIST))

            conversation_history, step = [], 0

            def enforce_scope(rule_or_rules) -> tuple[bool, str]:
                def collect_ids(r):
                    ids = []
                    for side in ("redex", "reactum"):
                        for nd in (r.get(side) or []):
                            nid = nd.get("id")
                            if nid is not None:
                                try: ids.append(int(nid))
                                except Exception: pass
                    return ids
                if isinstance(rule_or_rules, dict):
                    bad = [i for i in collect_ids(rule_or_rules) if i not in allowed_ids]
                    return (not bad, f"Node IDs out of region scope: {bad}" if bad else "")
                all_ids = []
                for r in (rule_or_rules or []):
                    all_ids.extend(collect_ids(r))
                bad = [i for i in all_ids if i not in allowed_ids]
                return (not bad, f"Batch out of region scope: {bad}" if bad else "")
            
            while step < MAX_STEPS:
                # refresh the merged region into MCP before each step so query_state is current
                await _call_tool_safe(client, "load_bigraph_from_file_glob", {"path": str(self.state_file)})

                controller_prompt = (
                    get_prompt(subgraph_state, tool_list, event,
                            conversation_history=conversation_history,
                            rule_published=False) + """
    FURTHER CONSTRAINTS (MID):
    - Return ONLY a single JSON object. No prose, no markdown, no comments.
    - Allowed tools: load_bigraph_from_file_glob, query_state, publish_rule_to_redis, publish_rules_batch, save_graph_to_file, noop, escalate.
    - Use LOCAL operational rules by default (names without 'ESCALATE__').
    - Use 'ESCALATE__' prefix **only** for escalate-on-match rules at the hub (reactum MUST equal redex).
    - Never reference node IDs outside the provided subgraph.
    - If a durable policy isn't needed, choose {"tool":"noop"}.
    - If you cannot safely act within these constraints, choose {"tool":"escalate"}.
    """.strip()
                )

                verb, args = await mid_step(controller_prompt)
                logger.debug("mid LLM step -> verb=%r args_keys=%s",
                             verb, list(args.keys()) if isinstance(args, dict) else type(args))

                if not verb:
                    conversation_history.append({"tool": "invalid_or_parse_error"}); step += 1; continue

                if verb == "noop":
                    conversation_history.append({"tool": "noop"}); return True

                if verb == "escalate":
                    conversation_history.append({"tool": "escalate"}); return False

                if verb == "publish_rule_to_redis":
                    rule = args.get("rule") if isinstance(args, dict) else None
                    rule = _ensure_reactum_uids(rule)
                    if not isinstance(rule, dict):
                        conversation_history.append({"tool": verb, "error": "missing or invalid rule"}); step += 1; continue
                    ok, msg = enforce_scope(rule)
                    if not ok:
                        conversation_history.append({"tool": verb, "args": {"rule": rule}, "error": msg}); step += 1; continue
                    ok, msg = _validate_escalate_rules([rule])
                    if not ok:
                        conversation_history.append({"tool": verb, "args": {"rule": rule}, "error": msg}); step += 1; continue
                    rule.setdefault("hub_id", hub_id)
                    try:
                        await client.call_tool("publish_rule_to_redis", {"rule": rule})
                        logger.info("Published single rule"); return True
                    except Exception as e:
                        conversation_history.append({"tool": verb, "error": str(e)}); step += 1; continue

                if verb == "publish_rules_batch":
                    rules = args.get("rules") if isinstance(args, dict) else None
                    rules = _ensure_reactum_uids(rules)
                    if not isinstance(rules, list) or not rules:
                        conversation_history.append({"tool": verb, "error": "missing or empty rules"}); step += 1; continue
                    ok, msg = enforce_scope(rules)
                    if not ok:
                        conversation_history.append({"tool": verb, "args": {"rules": rules}, "error": msg}); step += 1; continue
                    ok, msg = _validate_escalate_rules(rules)
                    if not ok:
                        conversation_history.append({"tool": verb, "args": {"rules": rules}, "error": msg}); step += 1; continue
                    for r in rules:
                        if isinstance(r, dict):
                            r.setdefault("hub_id", hub_id)
                    try:
                        await client.call_tool("publish_rules_batch", {"hub_id": hub_id, "rules": rules})
                        logger.info("Published %d rules", len(rules)); return True
                    except Exception as e:
                        conversation_history.append({"tool": verb, "error": str(e)}); step += 1; continue

                # other whitelisted tools (load/query/save)
                try:
                    await _call_tool_safe(client, verb, args if isinstance(args, dict) else {})
                    conversation_history.append({"tool": verb, "result": "ok"})
                except Exception as e:
                    conversation_history.append({"tool": verb, "error": str(e)})

                step += 1
            return False  # budget exhausted -> escalate upstream

    async def escalate_to_cloud(self, hub_id: str, event: dict, reason: str = "unknown"):
        escalation = {
            "type": "ESCALATION_REQUEST",
            "mid_id": self.mid_id,
            "hub_id": hub_id,
            "event": event,
            "timestamp": asyncio.get_running_loop().time(),
            "reason": reason,
            "region_graph_file": str(self.state_file) if self.state_file.exists() else None,
        }
        await self.redis.publish("building:requests", json.dumps(escalation))
        logger.info("Escalated to cloud from mid:%s (hub %s): %s", self.mid_id, hub_id, reason)

    async def _serve_hub_graph_request(self, data: dict):
        hub_id = data.get("hub_id")
        if not hub_id:
            return
        if self.state_file.exists():
            with self.state_file.open("rb") as f:
                region = bigraph_capnp.Bigraph.read(f)
            hubs = self._discover_hubs(region)
            tgt = next((h for h in hubs if h[0] == hub_id), None)
            if tgt:
                _, root_id = tgt
                slice_ids = _collect_subtree_ids(region, root_id)
                hub_slice = _build_graph_from_nodes(region, slice_ids)
                await self.redis.publish(f"hub:{hub_id}:graph", hub_slice.to_bytes())
                logger.info("returned hub graph to hub:%s:graph on request", hub_id)
            else:
                logger.warning("No managed root found for hub_id=%s", hub_id)
        else:
            await self.request_graph("hub_request_no_region")

    async def handle_mid_escalation(self, data: dict):
        try:
            hub_id = data.get("hub_id")
            event = data.get("event", {})
            reason = data.get("reason")
            logger.info("mid %s handling escalation from hub %s (%s)", self.mid_id, hub_id, reason)

            if not self.state_file.exists():
                logger.info("No stored graph; requesting and pausing...")
                await self.request_graph("escalation_no_region")
                await asyncio.sleep(1)

            # Merge hub's local graph into region BEFORE processing
            room_graph_file = data.get("graph_file")
            if room_graph_file and Path(room_graph_file).exists() and self.state_file.exists():
                with self.state_file.open("rb") as f:
                    region_msg = bigraph_capnp.Bigraph.read(f)
                with open(room_graph_file, "rb") as f:
                    local_msg = bigraph_capnp.Bigraph.read(f)
                merged = _merge_local_into_region(local_msg, region_msg)
                with self.state_file.open("wb") as f:
                    merged.write(f)
                logger.info("Merged hub local graph (%s) into region graph", room_graph_file)

            success = await self.process(hub_id, event)
            if not success:
                await self.escalate_to_cloud(hub_id, event, reason="mid_timeout_or_uncertain")
        except Exception as e:
            logger.error("mid escalation error: %s", e)
            try:
                hub_id = data.get("hub_id")
                event = data.get("event", {})
                await self.escalate_to_cloud(hub_id or "unknown", event, reason=f"mid_exception:{e}")
            except Exception as e2:
                logger.error("mid secondary escalation failed: %s", e2)

    # ---- message loop ----
    async def _on_direct_message(self, ch: str, data: bytes):
        if ch == f"mid:{self.mid_id}:graph":
            self.state_file.write_bytes(data)
            with self.state_file.open("rb") as f:
                region = bigraph_capnp.Bigraph.read(f)
            logger.info("mid:%s received region graph (%d nodes)", self.mid_id, len(region.nodes))
            await self._fan_out_hubs(region)
            return

        if ch == f"mid:{self.mid_id}:requests":
            payload = json.loads(data)
            msg_type = payload.get("type")
            if msg_type == "GRAPH_REQUEST":
                await self._serve_hub_graph_request(payload)
            elif msg_type == "ESCALATION_REQUEST":
                await self.handle_mid_escalation(payload)
            return

    async def _on_pattern_message(self, payload: dict):
        msg_type = payload.get("type")
        if msg_type == "GRAPH_REQUEST":
            await self._serve_hub_graph_request(payload)
        elif msg_type == "ESCALATION_REQUEST":
            await self.handle_mid_escalation(payload)

    async def start(self):
        await self.request_graph("init")

        ps = self.redis.pubsub()
        region_graph_ch = f"mid:{self.mid_id}:graph"
        mid_requests_ch = f"mid:{self.mid_id}:requests"
        mid_rules_out_ch = f"mid:{self.mid_id}:rules_out"  

        await ps.subscribe(region_graph_ch, mid_requests_ch, mid_rules_out_ch)
        await ps.psubscribe("hub:*:requests", "region:*:requests", "floor:*:requests")

        logger.info("mid %s listening on %s, %s, %s and patterns hub:*:requests, region:*:requests, floor:*:requests", self.mid_id, region_graph_ch, mid_requests_ch, mid_rules_out_ch,)

        async for message in ps.listen():
            t = message.get("type")
            if t not in ("message", "pmessage"):
                continue
            try:
                if t == "message":
                    ch = message["channel"].decode()

                    if ch == mid_rules_out_ch:
                        try:
                            payload = json.loads(message["data"])
                            envs = payload.get("batch") if isinstance(payload, dict) and "batch" in payload else [payload]
                            for env in envs:
                                hub = env["hub_id"]
                                raw = base64.b64decode(env["capnp_rule_b64"])
                                await self.redis.publish(f"hub:{hub}:rules", raw)
                                logger.info("Forwarded cloud rule to hub:%s:rules", hub)
                        except Exception as e:
                            logger.error("Failed to forward rules_out payload: %s", e)
                        continue

                    await self._on_direct_message(ch, message["data"])
                else:
                    await self._on_pattern_message(json.loads(message["data"]))
            except Exception as e:
                logger.error("mid:%s error processing graph or request: %s", self.mid_id, e)

# ---------- main ----------

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mid-id", required=True, help="this server's id")
    args = parser.parse_args()

    mid = MidServer(args.mid_id)
    await mid.start()

if __name__ == "__main__":
    asyncio.run(main())
