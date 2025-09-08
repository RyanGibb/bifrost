import argparse, random, os, json, csv, pathlib, sys, time
from typing import List, Optional
from pathlib import Path

sys.path.append(str(pathlib.Path(__file__).parent.parent / "lib"))
from bigraph_dsl import Bigraph, Node  

# ---------- args ----------

def parse_args():
    ap = argparse.ArgumentParser("Export bigraph + rules (CapNP) for OCaml timing (with IO metrics)")
    ap.add_argument("--max-nodes", type=int, default=10000)
    ap.add_argument("--step",      type=int, default=500)
    ap.add_argument("--trials",    type=int, default=30)
    ap.add_argument("--seed",      type=int, default=None)
    ap.add_argument("--outdir",    type=str, default="artifacts")
    ap.add_argument("--manifest",  type=str, default="artifacts/manifest.csv")
    ap.add_argument("--verbose",   action="store_true")
    return ap.parse_args()

# ---------- timers / IO ----------

def _us(ns: int) -> float: return ns / 1_000.0

def timed_save_bigraph(path: str, bg: Bigraph) -> tuple[float, int]:
    t0 = time.perf_counter_ns()
    bg.save(path)
    t1 = time.perf_counter_ns()
    sz = Path(path).stat().st_size
    return _us(t1 - t0), sz

def timed_write_json(path: str, obj: dict) -> tuple[float, int]:
    t0 = time.perf_counter_ns()
    with open(path, "w") as f:
        json.dump(obj, f)
    t1 = time.perf_counter_ns()
    sz = Path(path).stat().st_size
    return _us(t1 - t0), sz

# ---------- constructors ----------

_gid = 10_000_000
def next_id():
    global _gid
    _gid += 1
    return _gid

def skeleton(n: Node) -> Node:
    return Node(n.control, id=n.id, name=n.name,
                node_type=n.node_type,
                properties=dict(n.properties or {}),
                children=[])

def clone_focus_with_props(focus: Node, **overrides) -> Node:
    props = dict(focus.properties or {}); props.update(overrides)
    return Node(focus.control, id=focus.id, name=focus.name,
                node_type=focus.node_type, properties=props, children=[])

def mk_region(rid: int) -> Node:
    return Node("Region", id=next_id(), name=f"Region_{rid}", node_type="Region",
                properties={"rid": rid}, children=[])

def mk_device(name: str, power: bool) -> Node:
    return Node("Device", id=next_id(), name=name, node_type="Device",
                properties={"name": name, "power": power}, children=[])

def mk_container(ix: int) -> Node:
    return Node("Container", id=next_id(), name=f"grp_{ix}", node_type="Container",
                properties={"idx": ix}, children=[])

# ---------- traversal / shaping ----------

def deep_clone_node(n: Node) -> Node:
    m = Node(n.control, id=n.id, name=n.name, node_type=n.node_type,
             properties=dict(n.properties or {}), children=[])
    for c in (n.children or []):
        m.children.append(deep_clone_node(c))
    return m

def clone_bigraph(bg: Bigraph) -> Bigraph:
    roots = getattr(bg, "roots", None) or getattr(bg, "nodes", None) or []
    return Bigraph([deep_clone_node(r) for r in roots])

def count_subtree(n: Node) -> int:
    return 1 + sum(count_subtree(c) for c in (n.children or []))

def iter_nodes(n: Node):
    yield n
    for c in (n.children or []):
        yield from iter_nodes(c)

def device_children(parent: Node) -> List[Node]:
    return [c for c in (parent.children or []) if c.control == "Device"]

def ensure_device_children(parent: Node, k: int, rng: random.Random):
    cur = device_children(parent)
    need = max(0, k - len(cur))
    for _ in range(need):
        d = Node("Device", id=next_id(), name=f"dev_extra_{parent.id}_{len(parent.children)}",
                 node_type="Device", properties={"power": bool(rng.getrandbits(1))}, children=[])
        parent.children.append(d)

def choose_container(root: Node, rng: random.Random) -> Optional[Node]:
    cands = [n for n in iter_nodes(root) if n.control == "Container"]
    return rng.choice(cands) if cands else None

def is_in_subtree(root: Node, target: Node) -> bool:
    for n in iter_nodes(root):
        if n.id == target.id:
            return True
    return False

# ---------- random gen ----------

def gen_random_hierarchy(target_nodes: int, inject_focus_name: str, rng: random.Random):
    root = Node("Root", id=next_id(), name="root", node_type="Root", properties={}, children=[])
    r0, r1 = mk_region(0), mk_region(1)
    root.children.extend([r0, r1])

    parents: List[Node] = [r0, r1]
    total_nodes = 3

    focus_power = bool(rng.getrandbits(1))
    focus_region = r0 if rng.random() < 0.5 else r1
    focus = mk_device(inject_focus_name, focus_power)
    focus_region.children.append(focus)
    total_nodes += 1

    grp_ix = 0
    while total_nodes < target_nodes:
        parent = rng.choice(parents)
        if rng.random() < 0.35:
            c = mk_container(grp_ix); grp_ix += 1
            parent.children.append(c)
            parents.append(c)
            total_nodes += 1
        else:
            d = Node("Device", id=next_id(), name=f"dev_{total_nodes}", node_type="Device",
                     properties={"name": f"dev_{total_nodes}", "power": bool(rng.getrandbits(1))},
                     children=[])
            parent.children.append(d)
            total_nodes += 1

        if rng.random() < 0.05:
            parents.append(r0 if rng.random() < 0.5 else r1)

    bg = Bigraph([root])
    return bg, focus.id, (0 if focus_region is r0 else 1), focus_power

# ---------- rule builders (baseline) ----------

def with_iface(meta: dict, inner=1, outer=1) -> dict:
    m = dict(meta); m.setdefault("inner_sites", inner); m.setdefault("outer_sites", outer); return m

def build_prop_toggle_rule(root_node: Node, region_node: Node, focus_node: Node, focus_power_now: bool):
    redex_focus = clone_focus_with_props(focus_node, power=focus_power_now)
    react_focus = clone_focus_with_props(focus_node, power=(not focus_power_now))
    r_rx = skeleton(region_node); r_rx.children = [redex_focus]
    r_tx = skeleton(region_node); r_tx.children = [react_focus]
    root_rx = skeleton(root_node); root_rx.children = [r_rx]
    root_tx = skeleton(root_node); root_tx.children = [r_tx]
    return with_iface({"name":"prop_update_toggle"}), Bigraph([root_rx]), Bigraph([root_tx])

def build_remove_rule(root_node: Node, region_node: Node, focus_node: Node):
    redex_focus = clone_focus_with_props(focus_node)
    r_rx = skeleton(region_node); r_rx.children = [redex_focus]
    r_tx = skeleton(region_node)
    root_rx = skeleton(root_node); root_rx.children = [r_rx]
    root_tx = skeleton(root_node); root_tx.children = [r_tx]
    return with_iface({"name":"remove_device"}), Bigraph([root_rx]), Bigraph([root_tx])

def build_reparent_rule(root_node: Node, region0: Node, region1: Node, focus_node: Node, current_region: int):
    other = 1 - current_region
    r0_rx, r1_rx = skeleton(region0), skeleton(region1)
    r0_tx, r1_tx = skeleton(region0), skeleton(region1)
    redex_focus = clone_focus_with_props(focus_node)
    react_focus = clone_focus_with_props(focus_node)
    (r0_rx if current_region==0 else r1_rx).children = [redex_focus]
    (r0_tx if other==0 else r1_tx).children = [react_focus]
    root_rx = skeleton(root_node); root_rx.children = [r0_rx, r1_rx]
    root_tx = skeleton(root_node); root_tx.children = [r0_tx, r1_tx]
    return with_iface({"name":"reparent_region"}), Bigraph([root_rx]), Bigraph([root_tx])

# ---------- pretty print ----------

def pp_node(n: Node, indent=""):
    show = ("name","power","rid","idx","code","alarm")
    props = n.properties or {}
    meta = []
    if getattr(n, "name", None): meta.append(f'name="{n.name}"')
    for k in show:
        if k in props: meta.append(f"{k}={props[k]}")
    lab = "" if not meta else " [" + "; ".join(map(str, meta)) + "]"
    print(f"{indent}- {n.control}#{n.id}{lab}")
    for c in (n.children or []): pp_node(c, indent+"  ")

def pp_bigraph(bg: Bigraph, title: Optional[str] = None):
    if title: print(f"\n=== {title} ===")
    roots = getattr(bg, "roots", None) or getattr(bg, "nodes", None) or []
    for r in roots: pp_node(r)

def pp_rule(meta: dict, redex: Bigraph, react: Bigraph, n: int, t: int, prefix: str = ""):
    title = f"{prefix}Rule: {meta.get('name','(unnamed)')} (n={n}, t={t})"
    print(f"\n--- {title} ---")
    print("meta:", json.dumps(meta, sort_keys=True))
    pp_bigraph(redex, "Redex")
    pp_bigraph(react, "Reactum")

# ---------- serialization ----------

def save_rule_bundle_timed(outdir: str, n: int, t: int, meta: dict, redex: Bigraph, react: Bigraph, verbose=False):
    rule = meta["name"]
    redex_path = os.path.join(outdir, f"rule_{rule}_n{n}_t{t}_redex.capnp")
    react_path = os.path.join(outdir, f"rule_{rule}_n{n}_t{t}_react.capnp")
    meta_path  = os.path.join(outdir, f"rule_{rule}_n{n}_t{t}.json")

    redex_us, redex_bytes = timed_save_bigraph(redex_path, redex)
    react_us, react_bytes = timed_save_bigraph(react_path, react)
    meta_us,  meta_bytes  = timed_write_json(meta_path, meta)

    if verbose:
        print(f"Saved rule redex → {redex_path} ({redex_bytes} B in {redex_us:.1f} µs)")
        print(f"Saved rule react → {react_path} ({react_bytes} B in {react_us:.1f} µs)")
        print(f"Saved rule meta  → {meta_path}  ({meta_bytes} B in {meta_us:.1f} µs)")

    return (redex_path, react_path, meta_path,
            redex_us, react_us, meta_us, redex_bytes, react_bytes, meta_bytes)

# ---------- main ----------

def main():
    args = parse_args()
    os.makedirs(args.outdir, exist_ok=True)
    rng = random.Random(args.seed)

    manifest_path = Path(args.manifest)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)

    io_metrics_path = Path(args.outdir) / "io_metrics.csv"
    new_io = not io_metrics_path.exists()
    iof = open(io_metrics_path, "a", newline="")
    io_wr = csv.writer(iof)
    if new_io:
        io_wr.writerow([
            "graph_size","rule","trial",
            "gen_us","build_rule_us",
            "bg_bytes","bg_save_us",
            "redex_bytes","redex_save_us",
            "react_bytes","react_save_us",
            "meta_bytes","meta_save_us",
            "bg_path","rule_redex_path","rule_react_path","rule_meta_path"
        ])

    with open(manifest_path, "w", newline="") as mf:
        wr = csv.writer(mf)
        wr.writerow(["graph_size","rule","trial","bg_path","rule_redex_path","rule_react_path","rule_meta_path"])

        sizes = list(range(args.step, args.max_nodes + 1, args.step))
        for n in sizes:
            for t in range(1, args.trials + 1):
                focus_name = "bench_focus"

                gen_t0 = time.perf_counter_ns()
                bg, focus_id, cur_region, focus_power = gen_random_hierarchy(n, focus_name, rng)
                gen_us = _us(time.perf_counter_ns() - gen_t0)

                roots = getattr(bg, "roots", None) or getattr(bg, "nodes", None) or []
                root = roots[0]
                regions = { (c.properties or {}).get("rid"): c for c in (root.children or []) if c.control == "Region" }
                r0, r1 = regions[0], regions[1]

                def find_focus(node: Node):
                    if node.id == focus_id: return node
                    for c in (node.children or []):
                        r = find_focus(c)
                        if r: return r
                    return None

                focus_node = find_focus(root)
                assert focus_node is not None, "focus not found"

                bg_path = os.path.join(args.outdir, f"bg_n{n}_t{t}.capnp")
                bg_save_us, bg_bytes = timed_save_bigraph(bg_path, bg)
                if args.verbose:
                    print(f"Saved bigraph → {bg_path} ({bg_bytes} B in {bg_save_us:.1f} µs)")

                for build in (
                    lambda: build_prop_toggle_rule(root, (r0 if cur_region == 0 else r1), focus_node, focus_power),
                    lambda: build_remove_rule(root, (r0 if cur_region == 0 else r1), focus_node),
                    lambda: build_reparent_rule(root, r0, r1, focus_node, cur_region),
                ):
                    b0 = time.perf_counter_ns()
                    meta, redex, react = build()
                    build_rule_us = _us(time.perf_counter_ns() - b0)
                    if args.verbose: pp_rule(meta, redex, react, n, t, prefix="Baseline ")

                    (rdx, rct, mta,
                     rdx_us, rct_us, mta_us,
                     rdx_b,  rct_b,  mta_b) = save_rule_bundle_timed(args.outdir, n, t, meta, redex, react, args.verbose)

                    wr.writerow([n, meta["name"], t, bg_path, rdx, rct, mta])
                    io_wr.writerow([n, meta["name"], t,
                                    f"{gen_us:.1f}", f"{build_rule_us:.1f}",
                                    bg_bytes, f"{bg_save_us:.1f}",
                                    rdx_b, f"{rdx_us:.1f}",
                                    rct_b, f"{rct_us:.1f}",
                                    mta_b, f"{mta_us:.1f}",
                                    bg_path, rdx, rct, mta])

    iof.close()
    print(f"Wrote manifest: {manifest_path}")
    print(f"Wrote IO metrics: {io_metrics_path}")

if __name__ == "__main__":
    main()
