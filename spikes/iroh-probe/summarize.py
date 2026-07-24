#!/usr/bin/env python3
"""S-02: Network matrix summarizer — read iroh-probe JSONL results → Markdown table.

Usage:
    python3 summarize.py results/                    # scan directory for *.jsonl
    python3 summarize.py wifi.jsonl 4g.jsonl         # explicit files
    python3 summarize.py wifi.jsonl 4g.jsonl --names "同WiFi" "家宽↔4G"

Output: Markdown table (stdout).
Columns: 场景 | 直连率 | P50 连接ms | P50 吞吐 Mbps | N
"""
import json
import os
import sys
import argparse
from pathlib import Path
from statistics import median
from collections import defaultdict
from typing import List, Dict, Optional


def load_file(path: str) -> List[dict]:
    results = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                results.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return results


def is_direct(r: dict) -> bool:
    """True if the connection was direct (lan or direct), not relay or error."""
    return r.get("path") in ("lan", "direct") and r.get("error") is None


def compute_stats(results: List[dict]) -> dict:
    """Compute aggregate stats from a list of probe results."""
    if not results:
        return {"直连率": "N/A", "P50连接ms": "N/A", "P50吞吐Mbps": "N/A", "N": 0}

    n = len(results)
    direct_count = sum(1 for r in results if is_direct(r))
    direct_rate = f"{100 * direct_count / n:.0f}%"

    connect_times = [r["connect_ms"] for r in results if r.get("connect_ms") is not None]
    throughputs = [
        r["throughput_mbps"] for r in results if r.get("throughput_mbps", 0) > 0 and r.get("error") is None
    ]

    return {
        "直连率": direct_rate,
        "P50连接ms": f"{median(connect_times):.0f}" if connect_times else "N/A",
        "P50吞吐Mbps": f"{median(throughputs):.0f}" if throughputs else "N/A",
        "N": n,
    }


def format_table(scenarios: Dict[str, List[dict]]) -> str:
    """Format a Markdown table from scenario → results mapping."""
    if not scenarios:
        return "_(no data)_"

    # Sort scenarios for stable output
    names = sorted(scenarios.keys())

    headers = ["场景", "直连率", "P50 连接 (ms)", "P50 吞吐 (Mbps)", "N"]
    col_widths = [max(len(h), 20) for h in headers]

    # Compute stats
    rows = []
    for name in names:
        s = compute_stats(scenarios[name])
        rows.append([name, s["直连率"], s["P50连接ms"], s["P50吞吐Mbps"], str(s["N"])])
        col_widths[0] = max(col_widths[0], len(name))

    lines = []
    # Header
    lines.append("| " + " | ".join(h.ljust(w) for h, w in zip(headers, col_widths)) + " |")
    lines.append("| " + " | ".join("-" * w for w in col_widths) + " |")
    # Rows
    for row in rows:
        lines.append("| " + " | ".join(v.ljust(w) for v, w in zip(row, col_widths)) + " |")

    # Summary footer
    total = sum(len(results) for results in scenarios.values())
    lines.append(f"\n_共计 {len(scenarios)} 个场景，{total} 次测试_")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Summarize iroh-probe JSONL results")
    parser.add_argument(
        "sources", nargs="*",
        help="JSONL files or one directory containing *.jsonl"
    )
    parser.add_argument(
        "--names", nargs="*",
        help="Scenario names for explicit files (same order)"
    )
    parser.add_argument(
        "--out", "-o",
        help="Write to file instead of stdout"
    )
    args = parser.parse_args()

    if not args.sources:
        print("Usage: summarize.py <files-or-dir> [--names ...]", file=sys.stderr)
        sys.exit(1)

    # Determine input: directory scan or explicit files
    files = []
    if len(args.sources) == 1 and os.path.isdir(args.sources[0]):
        dir_path = Path(args.sources[0])
        files = sorted(dir_path.glob("*.jsonl"))
    else:
        for s in args.sources:
            p = Path(s)
            if p.is_file():
                files.append(p)
            else:
                print(f"Warning: {s} not found, skipping", file=sys.stderr)

    if not files:
        print("No JSONL files found.", file=sys.stderr)
        sys.exit(1)

    # Map files to scenario names
    names = args.names or []
    scenarios: Dict[str, List[dict]] = defaultdict(list)
    for i, fp in enumerate(files):
        name = names[i] if i < len(names) else fp.stem
        try:
            results = load_file(str(fp))
            scenarios[name] = results
        except Exception as e:
            print(f"Error reading {fp}: {e}", file=sys.stderr)

    output = format_table(scenarios)

    if args.out:
        with open(args.out, "w") as f:
            f.write(output + "\n")
        print(f"Written to {args.out}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
