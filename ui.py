# --- ui.py (state handling without query_state) ---

import argparse
import asyncio
import json
import sys
import re
import time
from typing import Any, Dict, List, Optional, Set, Tuple

import redis
from fastmcp import Client  # used only to publish rules (no query_state)

import logging
logging.basicConfig(level=logging.INFO, format="[%(asctime)s] UI %(levelname)s: %(message)s", datefmt="%H:%M:%S")
logger = logging.getLogger("UI")

# ---- Cap'n Proto loading ----
import capnp
capnp.remove_import_hook()
from pathlib import Path
bigraph_capnp = capnp.load(str(Path(__file__).parent / "lib" / "bigraph_rpc.capnp"))

# ---------- local graph helpers (NO MCP) ----------

def _prop_to_py(val) -> Any:
    w = val.which()
    if w == "boolVal": return bool(val.boolVal)
    if w == "intVal": return int(val.intVal)
    if w == "floatVal": return float(val.floatVal)
    if w == "stringVal": return str(val.stringVal)
    if w == "colorVal":
        c = val.colorVal
        return {"r": int(c.r), "g": int(c.g), "b": int(c.b)}
    return None

def _node_to_dict(n) -> Dict[str, Any]:
    props = {}
    for p in n.properties:
        try:
            props[p.key] = _prop_to_py(p.value)
        except Exception:
            pass
    out = {
        "id": int(n.id),
        "control": str(n.control),
        "parent": int(getattr(n, "parent", -1)),
        "properties": props,
    }
    try: out["name"] = getattr(n, "name")
    except Exception: pass
    try: out["type"] = getattr(n, "type")
    except Exception: pass
    return out

def load_bigraph(path: str):
    with open(path, "rb") as f:
        return bigraph_capnp.Bigraph.read(f)

def bigraph_to_nodes_list(msg) -> List[Dict[str, Any]]:
    return [_node_to_dict(n) for n in msg.nodes]

def _get_prop(node, key):
    for p in node.properties:
        if p.key == key:
            v = p.value
            w = v.which()
            return getattr(v, w)
    return None

def _node_name_like(n):
    try:
        return _get_prop(n, "name") or getattr(n, "name", "")
    except Exception:
        return ""

def _collect_subtree_ids(msg, root_id: int) -> set[int]:
    keep = {root_id}
    added = True
    while added:
        added = False
        for n in msg.nodes:
            if n.parent in keep and n.id not in keep:
                keep.add(n.id)
                added = True
    return keep

def _subgraph_roots(msg):
    idset = {n.id for n in msg.nodes}
    return [n for n in msg.nodes if n.parent not in idset or n.parent == -1]

def merge_subgraph_into_master(sub_msg, master_msg):
    """Replace matching subtrees in master with sub_msg roots/subtrees, else append."""
    roots = _subgraph_roots(sub_msg)
    if not roots:
        return master_msg

    def key_tuple(n):
        return (_get_prop(n, "uid"), _node_name_like(n), n.id)

    master_nodes = list(master_msg.nodes)

    for r in roots:
        uid, nm, rid = key_tuple(r)
        # find target root
        target_id = None
        for mn in master_nodes:
            if (_get_prop(mn, "uid") and _get_prop(mn, "uid") == uid) or \
               (_node_name_like(mn) and _node_name_like(mn) == nm) or \
               (mn.id == rid):
                target_id = mn.id
                break

        if target_id is None:
            existing = {n.id for n in master_nodes}
            for n in sub_msg.nodes:
                if n.id not in existing:
                    master_nodes.append(n)
            continue

        # remove that subtree
        to_remove = {target_id}
        changed = True
        while changed:
            changed = False
            for n in list(master_nodes):
                if n.parent in to_remove and n.id not in to_remove:
                    to_remove.add(n.id)
                    changed = True
        master_nodes = [n for n in master_nodes if n.id not in to_remove]

        # append all sub nodes (de-dupe by id)
        existing = {n.id for n in master_nodes}
        for n in sub_msg.nodes:
            if n.id not in existing:
                master_nodes.append(n)

    out = bigraph_capnp.Bigraph.new_message()
    out.siteCount = getattr(master_msg, "siteCount", 0)
    out.names = list(getattr(master_msg, "names", []))
    cap_nodes = out.init("nodes", len(master_nodes))
    for i, n in enumerate(master_nodes):
        cap_nodes[i] = n
    return out

def request_and_merge_latest(master_path: str,
                             redis_host: str = "localhost",
                             listen_sec: float = 1.0) -> str:
    """
    Synchronously:
      * loads master,
      * asks cloud to re-push mids (and mids to hub) via building:requests,
      * listens briefly for mid:*:graph and hub:*:graph,
      * merges any received graphs into master,
      * writes merged file (ui_master_merged.capnp),
      * returns merged path.
    """
    master = load_bigraph(master_path)

    r = redis.Redis(redis_host)
    ps = r.pubsub()
    ps.psubscribe("mid:*:graph", "hub:*:graph")

    # Kick the network to (re)push regions from cloud to mids (mids will fan-out to hubs)
    r.publish("building:requests", json.dumps({"type": "GRAPH_REQUEST", "reason": "ui_refresh"}))

    deadline = time.monotonic() + listen_sec
    merged = master

    while time.monotonic() < deadline:
        msg = ps.get_message(ignore_subscribe_messages=True, timeout=0.05)
        if not msg:
            continue
        if msg["type"] != "pmessage":
            continue
        try:
            payload = msg["data"]
            if isinstance(payload, (bytes, bytearray)):
                # graph bytes
                bio = payload  # already bytes
                sub = bigraph_capnp.Bigraph.read_bytes(bio)
                merged = merge_subgraph_into_master(sub, merged)
                logger.info("Merged a %s subgraph (%d nodes)", msg["channel"].decode(), len(sub.nodes))
        except Exception as e:
            logger.warning("Skipping malformed graph on %s: %s", msg.get("channel"), e)

    try:
        ps.close()
    except Exception:
        pass

    out_path = str(Path(master_path).with_name("ui_master_merged.capnp"))
    try:
        if hasattr(merged, "write"):
            # merged is a Builder → safe to write directly
            with open(out_path, "wb") as f:
                merged.write(f)
        else:
            # merged is a Reader (no updates received in time) → copy original bytes
            Path(out_path).write_bytes(Path(master_path).read_bytes())
    except Exception:
        # last resort: copy original
        Path(out_path).write_bytes(Path(master_path).read_bytes())

    logger.info("Wrote merged master to %s", out_path)
    return out_path

def load_nodes_from_capnp(path: str) -> List[Dict[str, Any]]:
    msg = load_bigraph(path)
    return bigraph_to_nodes_list(msg)

# ---------- LLM backends (unchanged) ----------

try:
    from openai import AsyncOpenAI
    OPENAI_AVAILABLE = True
    openai_client = AsyncOpenAI()
except Exception:
    OPENAI_AVAILABLE = False
    openai_client = None

async def run_llm(prompt: str, backend: str) -> str:
    if backend.startswith("ollama/"):
        model = backend.split("/", 1)[1]
        proc = await asyncio.create_subprocess_exec(
            "ollama", "run", model,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE)
        out_b, err_b = await proc.communicate(prompt.encode("utf-8"))
        return out_b.decode("utf-8", errors="replace").strip()

    if backend.startswith("openai/"):
        if not OPENAI_AVAILABLE:
            raise RuntimeError("openai backend requested but package not available")
        model = backend.split("/", 1)[1]
        resp = await openai_client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            temperature=0,
        )
        return resp.choices[0].message.content

    raise ValueError(f"Unsupported backend: {backend}")

# ---------- UI class (uses local state only) ----------

class RuleGeneratorUI:
    def __init__(self, master_path: str, model_backend: str, redis_host: str = "localhost"):
        self.master_path = master_path
        self.model_backend = model_backend
        self.redis_client = redis.Redis(redis_host)
        # MCP client used ONLY to publish rules (no query_state)
        self.mcp_client = Client("mcp_funcs.py")

    async def refresh_master_and_load_nodes(self, burst_sec: float = 1.0) -> Tuple[str, List[Dict[str, Any]]]:
        merged_path = request_and_merge_latest(self.master_path, listen_sec=burst_sec)
        nodes = load_nodes_from_capnp(merged_path)
        return merged_path, nodes

    async def create_rule_from_text(self, free_text: str) -> Dict[str, Any]:
        # 1) locally refresh + load nodes
        merged_path, nodes = await self.refresh_master_and_load_nodes(burst_sec=1.0)

        logger.info("nodes")
        logger.info(nodes)

        node_map = {int(n["id"]): n for n in nodes if "id" in n}
        allowed_ids: Set[int] = set(node_map.keys())
        hub_index = self._build_hub_index(node_map)

        logger.info("hub index")
        logger.info(hub_index)

        # 2) build prompt and call LLM
        prompt = self._build_prompt(free_text, nodes)
        logger.info("prompt")
        logger.info(prompt)

        raw = await run_llm(prompt, self.model_backend)
        decision, args = self._parse_llm_output(raw)

        if decision == "noop" or (decision is None and not args):
            return {"status": "noop", "detail": "LLM returned noop", "raw": raw}

        rules: List[dict] = []
        if decision == "publish_rule_to_redis" and isinstance(args, dict) and "rule" in args:
            rules = [args["rule"]]
        elif decision == "publish_rules_batch" and isinstance(args, dict):
            rules = list(args.get("rules", []))
        else:
            if isinstance(args, dict) and "rules" in args and isinstance(args["rules"], list):
                rules = args["rules"]

        if not rules:
            return {"status": "error", "detail": "LLM did not return any rules.", "raw": raw}

        invalid_ids = self._validate_rule_ids(rules, allowed_ids)
        if invalid_ids:
            return {
                "status": "error",
                "detail": f"Rule references unknown node IDs: {sorted(invalid_ids)}",
                "raw": raw}

        for r in rules:
            if "hub_id" not in r or not r["hub_id"]:
                inferred = self._infer_hub_for_rule(r, node_map, hub_index)
                if not inferred:
                    return {"status": "error", "detail": "Could not infer hub_id for a rule.", "rule": r}
                r["hub_id"] = inferred

        # 3) publish via MCP tool (encoding + redis publish)
        #    (No query_state/load here—tool should not require it)
        results = {}
        async with self.mcp_client:
            by_hub: Dict[str, List[dict]] = {}
            for r in rules:
                by_hub.setdefault(r["hub_id"], []).append(r)
            for hub_id, rules_for_hub in by_hub.items():
                try:
                    resp = await self.mcp_client.call_tool("publish_rules_batch", {"hub_id": hub_id, "rules": rules_for_hub})
                    results[hub_id] = {"ok": True, "count": len(rules_for_hub), "result": resp.data}
                except Exception as e:
                    results[hub_id] = {"ok": False, "count": len(rules_for_hub), "error": str(e)}

        return {"status": "published", "by_hub": results, "raw": raw}

    # ----------- helpers (unchanged) -----------

    def _build_prompt(self, free_text: str, nodes: List[dict]) -> str:
        compact_nodes = [{
                "id": int(n.get("id")),
                "control": n.get("control"),
                "name": n.get("name", None),
                "parent": n.get("parent", -1),
                "properties": n.get("properties", {}),
            }
            for n in nodes if "id" in n
        ]

        schema_block = """
Return ONLY strict JSON, one of:

1) Single rule:
{
  "decision": "publish_rule_to_redis",
  "args": {
    "rule": {
      "name": "SOME_NAME",
      "hub_id": "<optional - leave blank to infer>",
      "redex": [ { "id": <int>, "control": "<Control>", "properties": { ... } }, ... ],
      "reactum": [ { "id": <int>, "control": "<Control>", "properties": { ... } }, ... ]
    }
  }
}

2) Multiple rules:
{
  "decision": "publish_rules_batch",
  "args": { "rules": [
     { "name": "...", "hub_id": "<optional>", "redex": [...], "reactum": [...] },
     ...
  ]}
}

3) No rule needed:
{ "decision": "noop", "args": {} }

Rules:
- Use ONLY node IDs that appear in the provided 'nodes' list.
- Prefer a single concise rule unless multiple are clearly required.
- Do NOT invent properties not present on those node types.
- If the request cannot be safely implemented as a rule, return "noop".
"""
        prompt = f"""
You are a building automation rule writer. The current building graph (subset) is:

nodes = {json.dumps(compact_nodes, indent=2)}

User request:
{free_text.strip()}

{schema_block}
""".strip()
        return prompt

    def _parse_llm_output(self, out: str) -> Tuple[Optional[str], dict]:
        text = out.strip()
        if text.startswith("```"):
            text = re.sub(r"^```(?:json)?\n?", "", text)
            text = re.sub(r"\n?```$", "", text)
        try:
            obj = json.loads(text)
        except Exception:
            return None, {}
        return obj.get("decision"), obj.get("args", {})

    def _build_hub_index(self, node_map: Dict[int, dict]) -> Dict[int, str]:
        parent = {nid: nd.get("parent", -1) for nid, nd in node_map.items()}
        cache: Dict[int, Optional[str]] = {}

        def name_like(nd: dict) -> str:
            props = nd.get("properties", {}) or {}
            return props.get("name") or nd.get("name") or ""

        def resolve(nid: int) -> Optional[str]:
            if nid in cache:
                return cache[nid]
            cur = nid
            visited = set()
            while cur != -1 and cur in node_map and cur not in visited:
                visited.add(cur)
                nd = node_map[cur]
                props = nd.get("properties", {}) or {}
                if nd.get("control") == "Hub":
                    hub = props.get("hub_id") or name_like(nd) or str(nd.get("id"))
                    cache[nid] = hub
                    return hub
                if nd.get("control") == "Room" and "hub_id" in props:
                    cache[nid] = props["hub_id"]
                    return props["hub_id"]
                cur = parent.get(cur, -1)
            cache[nid] = None
            return None

        for nid in node_map.keys():
            resolve(nid)
        return {k: v for k, v in cache.items() if v}

    def _validate_rule_ids(self, rules: List[dict], allowed: Set[int]) -> Set[int]:
        bad: Set[int] = set()
        def pull(rule: dict):
            for side in ("redex", "reactum"):
                for nd in rule.get(side, []) or []:
                    nid = nd.get("id")
                    if nid is not None:
                        try:
                            nid_i = int(nid)
                            if nid_i not in allowed:
                                bad.add(nid_i)
                        except Exception:
                            bad.add(nid)
        for r in rules:
            pull(r)
        return bad

    def _infer_hub_for_rule(self, rule: dict, node_map: Dict[int, dict], hub_index: Dict[int, str]) -> Optional[str]:
        ids: Set[int] = set()
        for side in ("redex", "reactum"):
            for nd in rule.get(side, []) or []:
                nid = nd.get("id")
                try:
                    ids.add(int(nid))
                except Exception:
                    pass
        hubs = [hub_index.get(nid) for nid in ids if hub_index.get(nid)]
        if not hubs:
            return None
        return max(set(hubs), key=hubs.count)

# -------------- CLI runner (unchanged) --------------

def read_free_text(prompt="Enter your rule request (free text). Finish with Ctrl-D (Unix) / Ctrl-Z then Enter (Windows):"):
    if not sys.stdin.isatty():
        return sys.stdin.read().strip()
    print(prompt)
    lines = []
    while True:
        try:
            line = input()
        except EOFError:
            break
        lines.append(line)
    return "\n".join(lines).strip()

async def main():
    parser = argparse.ArgumentParser(description="Free-text rule generator (local state)")
    parser.add_argument("--model_backend", default="openai/gpt-4o-mini", help="ollama/<model> or openai/<model>")
    parser.add_argument("--master", default="graph.capnp", help="Path to master graph capnp file")
    parser.add_argument("--request", help="Natural-language rule request. If omitted, read interactively.")
    args = parser.parse_args()

    if args.request:
        free_text = args.request.strip()
    else:
        free_text = read_free_text()
        if not free_text:
            free_text = input("Request (single line): ").strip()

    ui = RuleGeneratorUI(master_path=args.master, model_backend=args.model_backend)
    result = await ui.create_rule_from_text(free_text)
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    asyncio.run(main())
