#!/usr/bin/env python3
import sys
import re
import json
import asyncio
import argparse
import logging
import pathlib

import capnp
import fastmcp
import redis.asyncio as redis

sys.path.append(str(pathlib.Path(__file__).parent / "lib"))
from prompt import get_prompt
from utils import cp_prop_value

capnp.remove_import_hook()
bigraph_capnp = capnp.load(str(pathlib.Path(__file__).parent / "lib" / "bigraph_rpc.capnp"))

from openai import AsyncOpenAI
openai_client = AsyncOpenAI()

logging.basicConfig(level=logging.INFO, format="[%(asctime)s] CLOUD %(levelname)-8s %(message)s", datefmt="%H:%M:%S")
logger = logging.getLogger("cloud")

MASTER_FILE = pathlib.Path("graph.capnp")

# ---------- helpers ----------
def _get_prop(node, key):
    for p in node.properties:
        if p.key == key:
            v = p.value
            return getattr(v, v.which())
    return None

def _node_name_like(n):
    return _get_prop(n, "name") or getattr(n, "name", "")

def _ids_from_msg(msg) -> set[int]:
    return {n.id for n in msg.nodes}

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
        cap_nodes[i].name = getattr(n, "name", f"node_{n.id}") 
        cap_nodes[i].type = getattr(n, "type", n.control) 
        if len(n.ports): 
            ports = cap_nodes[i].init("ports", len(n.ports)) 
            for j, p in enumerate(n.ports): 
                ports[j] = p 
        if len(n.properties): 
            props = cap_nodes[i].init("properties", len(n.properties)) 
            for j, p in enumerate(n.properties): 
                props[j].key = p.key 
                cp_prop_value(props[j].value, p.value) 
    return out

def _capnp_to_flat_nodes(msg):
    out = []
    for n in msg.nodes:
        props = {}
        for p in n.properties:
            w = p.value.which()
            try:
                if w == "stringVal":
                    props[p.key] = p.value.stringVal
                elif w == "boolVal":
                    props[p.key] = bool(p.value.boolVal)
                elif w in ("intVal", "i64Val", "i32Val", "u64Val", "u32Val"):
                    props[p.key] = int(getattr(p.value, w))
                elif w in ("floatVal", "doubleVal"):
                    props[p.key] = float(getattr(p.value, w))
                else:
                    props[p.key] = getattr(p.value, w)
            except Exception:
                props[p.key] = None
        out.append({
            "id": int(n.id),
            "control": n.control,
            "name": getattr(n, "name", None) or props.get("name"),
            "parent": int(getattr(n, "parent", -1)),
            "properties": props,
        })
    return out

# ---------- subgraph ----------
def _resolve_selector_to_id(msg, selector: str | int) -> int | None:
    for n in msg.nodes:
        if _get_prop(n, "uid") == selector:
            return n.id
    for n in msg.nodes:
        if _get_prop(n, "name") == selector or getattr(n, "name", "") == selector:
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

def _subgraph_roots(msg):
    idset = {n.id for n in msg.nodes}
    return [n for n in msg.nodes if n.parent not in idset or n.parent == -1]

def _merge_subgraph_into_master(sub_msg, master_msg):
    roots = _subgraph_roots(sub_msg)
    if not roots:
        return master_msg

    def key_tuple(n):
        return (_get_prop(n, "uid"), _node_name_like(n), n.id)

    master_nodes = list(master_msg.nodes)

    for r in roots:
        uid, nm, rid = key_tuple(r)
        target_id = None
        for mn in master_nodes:
            if (_get_prop(mn, "uid") and _get_prop(mn, "uid") == uid) or \
               (_node_name_like(mn) and _node_name_like(mn) == nm) or \
               (mn.id == rid):
                target_id = mn.id
                break

        if target_id is None:
            existing_ids = {n.id for n in master_nodes}
            master_nodes.extend(n for n in sub_msg.nodes if n.id not in existing_ids)
            continue

        to_remove = {target_id}
        changed = True
        while changed:
            changed = False
            for n in list(master_nodes):
                if n.parent in to_remove and n.id not in to_remove:
                    to_remove.add(n.id); changed = True
        master_nodes = [n for n in master_nodes if n.id not in to_remove]

        existing_ids = {n.id for n in master_nodes}
        master_nodes.extend(n for n in sub_msg.nodes if n.id not in existing_ids)

    out = bigraph_capnp.Bigraph.new_message()
    out.siteCount = master_msg.siteCount
    out.names = list(master_msg.names)
    cap_nodes = out.init("nodes", len(master_nodes))
    for i, n in enumerate(master_nodes):
        cap_nodes[i] = n
    return out

# ---------- discovery ----------
def _parent_map(msg):
    return {n.id: n.parent for n in msg.nodes}

def _mids_by_region(master_msg):
    out = []
    for n in master_msg.nodes:
        if n.control == "MidServer":
            mid_id = _get_prop(n, "mid_id") or _get_prop(n, "name") or getattr(n, "name", "") or str(n.id)
            sel = _get_prop(n, "region_selector")
            rrid = _resolve_selector_to_id(master_msg, sel) if sel else (n.parent if n.parent != -1 else n.id)
            rrid = n.id if rrid is None else rrid
            out.append((mid_id, rrid))
    return out

def _find_mid_covering_node(master_msg, node_id: int) -> tuple[str | None, int | None]:
    for mid_id, root_id in _mids_by_region(master_msg):
        if node_id in _collect_subtree_ids(master_msg, root_id):
            return mid_id, root_id
    return None, None

def _find_midservers(master_msg): 
    """return list of dicts: {mid_id, region_root_id}""" 
    mids = [] 
    pmap = _parent_map(master_msg) 
    for n in master_msg.nodes: 
        if n.control == "MidServer": 
            mid_id = _get_prop(n, "mid_id") or _node_name_like(n) or str(n.id) 
            # region root: property 'region_selector' -> id, else parent 
            sel = _get_prop(n, "region_selector") 
            rrid = _resolve_selector_to_id(master_msg, sel) if sel else pmap.get(n.id, None) 
            if rrid is None: # fallback to the mid node itself 
                rrid = n.id 
            mids.append({"mid_id": mid_id, "region_root_id": rrid}) 
    return mids

def _find_hub_node(master_msg, hub_id: str):
    hub_node = next((n for n in master_msg.nodes
                     if n.control == "Hub" and ((_get_prop(n, "hub_id") or _get_prop(n, "name") or getattr(n, "name", "")) == hub_id)), None)
    if not hub_node:
        hub_node = next((n for n in master_msg.nodes if n.control == "Room" and _get_prop(n, "hub_id") == hub_id), None)
    return hub_node

# ---------- LLM wrappers ----------
async def run_llm(prompt: str, backend: str) -> str:
    """
    backend:
      - 'ollama/<model>'
      - 'openai/<model>'
    """
    # logger.info(prompt)

    if backend.startswith("ollama/"):
        model = backend.split("/", 1)[1]
        proc = await asyncio.create_subprocess_exec(
            "ollama", "run", model,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE)
        out_b, _ = await proc.communicate(prompt.encode("utf-8"))
        return out_b.decode("utf-8", errors="replace").strip()

    if backend.startswith("openai/"):
        model = backend.split("/", 1)[1]
        resp = await openai_client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            temperature=0)
        return (resp.choices[0].message.content or "").strip()

    raise ValueError(f"Unsupported backend {backend}")

async def llm_decide(prompt: str, tools, backend: str):
    out = await run_llm(prompt, backend)
    logger.info("model output\n%s", out)
    if out.strip().startswith("```"):
        out = re.sub(r"^```(?:json)?\n?", "", out)
        out = re.sub(r"\n?```$", "", out)
    try:
        data = json.loads(out)
        return data.get("tool"), data.get("args", {})
    except json.JSONDecodeError:
        logger.warning("Cloud LLM returned non-JSON")
        return None, {}

# ---------- push regions to mids ----------
async def push_regions_to_mids(r: redis.Redis):
    if not MASTER_FILE.exists():
        logger.warning("No MASTER_FILE to push")
        return
    with MASTER_FILE.open("rb") as f:
        master = bigraph_capnp.Bigraph.read(f)
    mids = _find_midservers(master)
    logger.info("Discovered %d mid servers", len(mids))
    for m in mids:
        region_slice = _build_graph_from_nodes(master, _collect_subtree_ids(master, m["region_root_id"]))
        await r.publish(f"mid:{m['mid_id']}:graph", region_slice.to_bytes())
        logger.info("Pushed region slice to mid:%s:graph", m["mid_id"])

# ---------- escalate ----------
def _is_noop_rule(rule: dict) -> bool:
    try:
        return json.dumps(rule.get("redex") or [], sort_keys=True) == json.dumps(rule.get("reactum") or [], sort_keys=True)
    except Exception:
        return False

def _validate_escalate_rules(rules: list[dict]) -> tuple[bool, str]:
    for r in rules:
        nm = (r.get("name") or "")
        if isinstance(nm, str) and nm.startswith("ESCALATE__") and not _is_noop_rule(r):
            return False, f"Rule '{nm}' must be a strict no-op (reactum == redex)."
    return True, ""

async def handle_escalation(payload: dict, backend: str):
    """
    handler for mid -> cloud escalation
    """
    mid_id = payload.get("mid_id")
    hub_id = payload.get("hub_id")
    region_graph_file = payload.get("region_graph_file") or payload.get("floor_graph_file")
    event_data = payload.get("event", {})

    logger.info("Cloud handling escalation (mid=%s hub=%s)", mid_id, hub_id)

    allowed_ids: set[int] = set()
    region_msg = None
    if region_graph_file and pathlib.Path(region_graph_file).exists():
        with open(region_graph_file, "rb") as f:
            region_msg = bigraph_capnp.Bigraph.read(f)

        if MASTER_FILE.exists():
            with MASTER_FILE.open("rb") as f:
                master_msg = bigraph_capnp.Bigraph.read(f)
            merged = _merge_subgraph_into_master(region_msg, master_msg)
            with MASTER_FILE.open("wb") as f:
                merged.write(f)
            logger.info("Merged region graph (%s) into master", region_graph_file)
        else:
            with MASTER_FILE.open("wb") as f:
                region_msg.write(f)
            logger.info("Initialized master with first region slice: %s", region_graph_file)
    else:
        logger.warning("No region_graph_file provided; proceeding without scope IDs.")

    # --- helper: find the hub root inside a region slice ---
    def _find_hub_root_in_region(msg, _hub_id: str) -> int | None:
        for n in msg.nodes:
            if n.control == "Hub":
                hid = _get_prop(n, "hub_id") or _get_prop(n, "name") or getattr(n, "name", "") or str(n.id)
                if hid == _hub_id:
                    return n.parent if n.parent != -1 else n.id
        for n in msg.nodes:
            if _get_prop(n, "hub_id") == _hub_id:
                return n.id
        return None

    if region_msg is not None and hub_id:
        hub_root = _find_hub_root_in_region(region_msg, hub_id)
        if hub_root is None:
            hub_nodes = _capnp_to_flat_nodes(region_msg)
            allowed_ids = _ids_from_msg(region_msg)
            logger.warning("Hub root not found for hub_id=%s; using entire region slice for prompt", hub_id)
        else:
            ids = _collect_subtree_ids(region_msg, hub_root)
            hub_slice = _build_graph_from_nodes(region_msg, ids)
            hub_nodes = _capnp_to_flat_nodes(hub_slice)
            allowed_ids = set(ids)

        subgraph_state_dict = {
            "nodes": hub_nodes,
            "meta": {"subset": True, "count": len(hub_nodes), "source": "cloud:hub_snapshot"},
        }
    else:
        subgraph_state_dict = {"nodes": [], "meta": {"subset": True, "count": 0, "source": "cloud:region_missing"}}

    mcp_script = str((pathlib.Path(__file__).parent / "mcp_funcs.py").resolve())
    client = fastmcp.Client(mcp_script)

    try:
        async with client:
            if MASTER_FILE.exists():
                await client.call_tool("load_bigraph_from_file_glob", {"path": str(MASTER_FILE.resolve())})

            tools = await client.list_tools()
            tool_list_str = "\n".join(f"- {t.name}: {t.description}" for t in tools)

            rule_published = False
            conversation_history = []

            def _enforce_scope(rule_or_rules):
                def collect_ids(r):
                    ids = []
                    for side in ("redex", "reactum"):
                        for nd in (r.get(side) or []):
                            nid = nd.get("id")
                            if nid is not None:
                                try:
                                    ids.append(int(nid))
                                except Exception:
                                    pass
                    return ids

                if isinstance(rule_or_rules, dict):
                    ids = collect_ids(rule_or_rules)
                    if allowed_ids and any(nid not in allowed_ids for nid in ids):
                        extra = [nid for nid in ids if nid not in allowed_ids]
                        return False, f"Rule touches node IDs outside hub scope: {extra}"
                    return True, ""

                all_ids = []
                for r in (rule_or_rules or []):
                    all_ids.extend(collect_ids(r))
                if allowed_ids and any(nid not in allowed_ids for nid in all_ids):
                    extra = [nid for nid in all_ids if nid not in allowed_ids]
                    return False, f"Batch touches node IDs outside hub scope: {extra}"
                return True, ""

            # bounded decision loop; cloud may use query_state, or publish via mid
            for _ in range(10):
                if MASTER_FILE.exists():
                    await client.call_tool("load_bigraph_from_file_glob", {"path": str(MASTER_FILE.resolve())})
                prompt = (
                    get_prompt(json.dumps(subgraph_state_dict, indent=2), tool_list_str, event_data,
                               conversation_history=conversation_history, rule_published=rule_published)
                    + f"""
HARD CONSTRAINTS (CLOUD):
- Return ONLY a single JSON object. No prose, no markdown, no comments.
- Allowed tools: query_state, publish_rule_to_redis, publish_rules_batch, noop.
- Prefer LOCAL operational rules for the hub; only use 'ESCALATE__' names for escalate-on-match (must be NO-OP).
- Only reference node IDs from this escalated hub subgraph.
- Do NOT invent properties outside the schema.
- If unsure, return {{\"tool\":\"noop\",\"args\":{{}}}}.
- When publishing, include "via_mid_id":"{mid_id}" in args so the mid can forward to the hub.
""".strip()
                )

                tool, args = await llm_decide(prompt, tools, backend)
                if not tool:
                    break

                if not isinstance(args, dict):
                    args = {}
                if tool in ("publish_rule_to_redis", "publish_rules_batch"):
                    args.setdefault("via_mid_id", mid_id)

                if tool == "noop":
                    conversation_history.append({"tool": "noop"})
                    break

                if tool == "publish_rule_to_redis":
                    rule = args.get("rule", {})
                    ok, err = _enforce_scope(rule)
                    if not ok:
                        conversation_history.append({"tool": tool, "args": args, "error": err})
                        continue
                    ok2, err2 = _validate_escalate_rules([rule])
                    if not ok2:
                        conversation_history.append({"tool": tool, "args": args, "error": err2})
                        continue
                    rule.setdefault("hub_id", hub_id)
                    try:
                        # publish via mid -> forwarded to hub by mid_server
                        await client.call_tool("publish_rule_to_redis", {"rule": rule, "via_mid_id": args.get("via_mid_id")})
                        logger.info("Rule published via mid:%s", args.get("via_mid_id"))
                        rule_published = True
                        break
                    except Exception as e:
                        conversation_history.append({"tool": tool, "args": args, "error": str(e)})
                        continue

                if tool == "publish_rules_batch":
                    rules = args.get("rules", [])
                    ok, err = _enforce_scope(rules)
                    if not ok:
                        conversation_history.append({"tool": tool, "args": args, "error": err})
                        continue
                    ok2, err2 = _validate_escalate_rules(rules)
                    if not ok2:
                        conversation_history.append({"tool": tool, "args": args, "error": err2})
                        continue
                    for rdef in rules:
                        if isinstance(rdef, dict):
                            rdef.setdefault("hub_id", hub_id)
                    try:
                        await client.call_tool("publish_rules_batch", {
                            "hub_id": hub_id,
                            "rules": rules,
                            "via_mid_id": args.get("via_mid_id")})
                        logger.info("Batch published via mid:%s", args.get("via_mid_id"))
                        rule_published = True
                        break
                    except Exception as e:
                        conversation_history.append({"tool": tool, "args": args, "error": str(e)})
                        continue

                try:
                    resp = await client.call_tool(tool, args or {})
                    conversation_history.append({"tool": tool, "args": args, "result": getattr(resp, "data", "ok")})
                except Exception as e:
                    conversation_history.append({"tool": tool, "args": args, "error": str(e)})

    except Exception as e:
        logger.error("Cloud escalation error: %s", e)


# ---------- listen ----------
async def _handle_graph_request(r: redis.Redis, data: dict):
    mid_id = data.get("mid_id")
    hub_id = data.get("hub_id")

    if not MASTER_FILE.exists():
        return

    with MASTER_FILE.open("rb") as f:
        master = bigraph_capnp.Bigraph.read(f)

    if mid_id:
        mids = _find_midservers(master)
        tgt = next((m for m in mids if m["mid_id"] == mid_id), None)
        if tgt:
            region_slice = _build_graph_from_nodes(master, _collect_subtree_ids(master, tgt["region_root_id"]))
            await r.publish(f"mid:{mid_id}:graph", region_slice.to_bytes())
            logger.info("Re-pushed region slice to mid:%s:graph (on request)", mid_id)
        return

    if hub_id:
        hub_node = _find_hub_node(master, hub_id)
        if not hub_node:
            logger.warning("GRAPH_REQUEST: hub '%s' not found in master", hub_id)
            return
        mid_for_hub, region_root = _find_mid_covering_node(master, hub_node.id)
        if not mid_for_hub:
            logger.warning("GRAPH_REQUEST: no mid covers hub '%s' (node %s)", hub_id, hub_node.id)
            return
        region_slice = _build_graph_from_nodes(master, _collect_subtree_ids(master, region_root))
        await r.publish(f"mid:{mid_for_hub}:graph", region_slice.to_bytes())
        logger.info("Pushed region slice to mid:%s:graph (hub %s requested)", mid_for_hub, hub_id)

async def listen_for_requests(backend: str):
    r = redis.Redis()
    ps = r.pubsub()
    await ps.subscribe("building:requests")
    logger.info("Cloud listening on 'building:requests'")

    await push_regions_to_mids(r)

    async for msg in ps.listen():
        if msg.get("type") != "message":
            continue
        try:
            raw = msg["data"]
            data = json.loads(raw.decode("utf-8")) if isinstance(raw, (bytes, bytearray)) else json.loads(raw)

            msg_type = data.get("type")
            if msg_type == "ESCALATION_REQUEST":
                await handle_escalation(data, backend)
            elif msg_type == "GRAPH_REQUEST":
                await _handle_graph_request(r, data)

        except Exception as e:
            logger.error("Cloud listener error: %s", e)

# ---------- main ----------
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model_backend", default="openai/gpt-4o-mini",
                        help="Backend: ollama/<model> or openai/<model>")
    args = parser.parse_args()
    asyncio.run(listen_for_requests(args.model_backend))

if __name__ == "__main__":
    main()
