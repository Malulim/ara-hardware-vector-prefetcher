#!/usr/bin/env python3
"""Sweep pf_system_tb over vector length, memory latency and instruction gap,
in three modes, and write one CSV row per run plus a markdown summary.

  bypass : prefetch_buffer routed around entirely (baseline Ara path)
  off    : prefetch_buffer in the path, +pf_disable (ROB only)
  on     : prefetching enabled

Usage (from hardware/, after `make verilate_unit veril_unit_top=pf_system_tb
veril_unit_library=build/verilator-pfsys`):

  python3 tb/unit/pf_sweep.py <out.csv> <out.md> [label]
"""
import csv, itertools, re, subprocess, sys

BIN = "build/verilator-pfsys/Vpf_system_tb"
VLS, LATS, GAPS = [1, 2, 4, 8, 16, 32, 64], [2, 4, 7, 12], [0, 8, 40]
MODES = {"bypass": ["+BYPASS"], "off": ["+pf_disable"], "on": []}
NINSN = 64


def run(vl, lat, gap, mode):
    out = subprocess.run(
        [BIN, f"+VL={vl}", f"+LAT={lat}", f"+GAP={gap}", f"+NINSN={NINSN}", "+pf_stats"] + MODES[mode],
        capture_output=True, text=True).stdout
    row = {"vl": vl, "lat": lat, "gap": gap, "mode": mode}
    for tag in ("PF_RESULT", "PF_STATS"):
        m = re.search(tag + r" (.*)", out)
        if not m:
            sys.exit(f"no {tag} for {row}:\n{out}")
        row.update((k, int(v)) for k, v in (kv.split("=") for kv in m.group(1).split()) if k not in row)
    return row


def main():
    csv_path, md_path = sys.argv[1], sys.argv[2]
    label = sys.argv[3] if len(sys.argv) > 3 else ""
    rows = [run(*c) for c in itertools.product(VLS, LATS, GAPS, MODES)]
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    by = {(r["vl"], r["lat"], r["gap"], r["mode"]): r for r in rows}
    md = [f"# Prefetcher sweep: {label}", "",
          f"`pf_system_tb`, {NINSN} strided loads per run. Cycles are per instruction,",
          "averaged over the second half of the run. Speedup is off / on.", ""]
    for gap in GAPS:
        md += [f"## gap = {gap} cycles between instructions", "",
               "| vl | L | bypass | off | on | speedup | hits / elements | prefetches sent | duplicates |",
               "|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for vl, lat in itertools.product(VLS, LATS):
            b, off, on = (by[(vl, lat, gap, m)] for m in MODES)
            md.append("| {} | {} | {:.1f} | {:.1f} | {:.1f} | {:.2f}x | {} / {} ({:.0f}%) | {} | {} |".format(
                vl, lat, b["steady_x100"] / 100, off["steady_x100"] / 100, on["steady_x100"] / 100,
                off["steady_x100"] / on["steady_x100"], on["hit"], on["real_ar"],
                100 * on["hit"] / on["real_ar"], on["pred_ar"], on["dup"]))
        md.append("")
    on = [r for r in rows if r["mode"] == "on"]
    blind = [r for r in on if r["new_insn"] < NINSN]
    md += ["## New instructions the predictor noticed", "",
           f"It should notice all {NINSN} in every run. It noticed fewer in {len(blind)} of {len(on)} runs"
           + (f" (as few as {min(r['new_insn'] for r in blind)})." if blind else "."), "",
           "| gap | runs where it missed instructions |", "|---:|---:|"]
    md += [f"| {g} | {sum(r['gap'] == g for r in blind)} of {sum(r['gap'] == g for r in on)} |" for g in GAPS]
    md.append("")
    worst = max(abs(by[(v, l, g, "off")]["steady_x100"] - by[(v, l, g, "bypass")]["steady_x100"])
                for v, l, g in itertools.product(VLS, LATS, GAPS))
    md += ["## Cost of the ROB alone", "",
           f"Largest |off - bypass| over all runs: {worst / 100:.2f} cycles per instruction.", ""]
    open(md_path, "w").write("\n".join(md))
    print(f"{len(rows)} runs -> {csv_path}, {md_path}")


if __name__ == "__main__":
    main()
