import argparse
from pathlib import Path
import warnings
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

plt.rcParams.update({
    "figure.dpi": 140,
    "savefig.dpi": 300,
    "font.size": 11,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "legend.frameon": False,
})

# ---------------- utilities ----------------

def to_num(df, cols):
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

def ci95(a: np.ndarray):
    a = a[~np.isnan(a)]
    if a.size == 0:
        return (np.nan, np.nan, np.nan)
    m = float(np.mean(a))
    s = float(np.std(a, ddof=1)) if a.size > 1 else 0.0
    ci = 1.96 * s / (np.sqrt(a.size) if a.size > 0 else 1.0)
    return (m, m - ci, m + ci)

def agg_ci(df, xcol, ycol):
    g = df.groupby(xcol, dropna=True)[ycol].apply(
        lambda s: pd.Series(ci95(s.to_numpy()), index=["mean","lo","hi"])
    )
    out = g.unstack().reset_index()
    return out.sort_values(by=xcol).reset_index(drop=True)

def linear_fit(x, y):
    x = np.asarray(x, dtype=float)
    y = np.asarray(y, dtype=float)
    m = np.isfinite(x) & np.isfinite(y)
    x, y = x[m], y[m]
    if x.size < 2:
        return np.nan, np.nan, np.nan
    slope, intercept = np.polyfit(x, y, 1)
    yhat = slope * x + intercept
    ss_res = float(np.sum((y - yhat) ** 2))
    ss_tot = float(np.sum((y - np.mean(y)) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else np.nan
    return slope, intercept, r2

def require(df, cols):
    missing = [c for c in cols if c not in df.columns]
    if missing:
        raise SystemExit(f"missing required columns: {missing}")

# ---------------- plots ----------------

def plot_rule_latency(df, outpdf):
    require(df, ["graph_size","rule","latency_us"])
    fig, ax = plt.subplots(figsize=(6.4, 4.2))

    rules = sorted([r for r in df["rule"].dropna().unique().tolist() if r])
    for rule in rules:
        sub = df[df["rule"] == rule]
        if sub.empty: 
            continue
        agg = agg_ci(sub, "graph_size", "latency_us")
        if agg.empty:
            continue
        ax.plot(agg["graph_size"], agg["mean"], marker="o", linewidth=1.4, label=rule)
        ax.fill_between(agg["graph_size"], agg["lo"], agg["hi"], alpha=0.20)

    ax.set_title("Rule App. Latency vs Graph Size")
    ax.set_xlabel("Graph Size (nodes)")
    ax.set_ylabel("Latency (µs)")
    if rules:
        ax.legend(ncol=1)
    fig.tight_layout()
    fig.savefig(outpdf, bbox_inches="tight")
    plt.close(fig)

def plot_serdes_vs_nodes(df, outpdf):
    require(df, ["graph_size","read_bg_us","decode_bg_us","load_bg_us"])
    fig, ax = plt.subplots(figsize=(6.4, 4.2))
    series = [
        ("decode_bg_us", "decode only"),
        ("read_bg_us",   "read (I/O) only"),
        ("load_bg_us",   "deserialize (read+decode)"),
    ]

    serialize_cols = [c for c in ["save_bg_us","bg_save_us","serialize_bg_us","encode_bg_us"] if c in df.columns]
    if serialize_cols:
        ser_col = serialize_cols[0]
        df["_serdes_e2e_us"] = df[ser_col].astype(float) + df["load_bg_us"].astype(float)
        series.append(("_serdes_e2e_us", "serialize+deserialize (end-to-end)"))
    else:
        warnings.warn("No serialize time column found in results_general.csv; plotting deserialize only.")

    for col, label in series:
        if col not in df.columns:
            continue
        agg = agg_ci(df, "graph_size", col)
        if agg.empty:
            continue
        ax.plot(agg["graph_size"], agg["mean"], marker="o", linewidth=1.4, label=label)
        ax.fill_between(agg["graph_size"], agg["lo"], agg["hi"], alpha=0.20)

    ax.set_title("(De)serialization vs graph size")
    ax.set_xlabel("Graph size (nodes)")
    ax.set_ylabel("Latency (µs)")
    ax.legend()
    fig.tight_layout()
    fig.savefig(outpdf, bbox_inches="tight")
    plt.close(fig)

# ---------------- main ----------------

def main():
    ap = argparse.ArgumentParser("Plot benchmark suite from results_general.csv")
    ap.add_argument("--csv", required=True, help="Path to results_general.csv (bench_apply output)")
    ap.add_argument("--outdir", default="figs", help="Directory to write PDFs")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(args.csv)

    num_cols = [
        "graph_size","trial","latency_us","matched",
        "search_us","apply_us",
        "load_bg_us","load_redex_us","load_react_us","load_meta_us","create_rule_us",
        "bg_bytes","redex_bytes","react_bytes","meta_bytes",
        "read_bg_us","decode_bg_us","read_redex_us","decode_redex_us","read_react_us","decode_react_us",
        "save_bg_us","bg_save_us","serialize_bg_us","encode_bg_us",
    ]
    to_num(df, num_cols)

    plot_rule_latency(df, outdir / "fig_rule_latency_vs_graph_size.pdf")

    plot_serdes_vs_nodes(df, outdir / "fig_serdes_vs_graph_size.pdf")

    print(f"[ok] wrote PDFs → {outdir.resolve()}")

if __name__ == "__main__":
    main()
