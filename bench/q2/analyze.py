"""Q2 (task 0.8) analysis. Run with: python3 -I bench/q2/analyze.py

Reads bench/out/q2/sweep.csv and, for each SSIMULACRA2 target, picks per file and per
quantizer the smallest output that reaches the target. Prints the matched table, the
median byte difference against the ADR 0002 10% rule, and writes the side-by-side
review page bench/out/q2/crops/index.html for task 0.9.
"""
import csv
import html
import os
import statistics
import subprocess
import sys

BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(BENCH, "out", "q2")
WORK = os.path.join(OUT, "work")
TARGETS = (80, 85, 90)
CROP = 384


def load():
    with open(os.path.join(OUT, "sweep.csv")) as f:
        return list(csv.DictReader(f))


def best(rows, target):
    """{(file, quantizer): row} with the fewest bytes at SSIMULACRA2 >= target."""
    picks = {}
    for r in rows:
        if float(r["ssimulacra2"]) < target:
            continue
        key = (r["file"], r["quantizer"])
        if key not in picks or int(r["bytes"]) < int(picks[key]["bytes"]):
            picks[key] = r
    return picks


def table(rows):
    files = sorted({(r["file"], r["category"]) for r in rows})
    print("| Target | Category | Files matched by both | Median quantizr/pngquant bytes | Unmatched (quantizr / pngquant) |")
    print("|---|---|---|---|---|")
    results = {}
    for target in TARGETS:
        picks = best(rows, target)
        for category in ("screenshot", "alpha", "all"):
            ratios, miss_q, miss_p = [], 0, 0
            for name, cat in files:
                if category != "all" and cat != category:
                    continue
                q, p = picks.get((name, "quantizr")), picks.get((name, "pngquant"))
                miss_q += q is None
                miss_p += p is None
                if q and p:
                    ratios.append(int(q["bytes"]) / int(p["bytes"]))
            median = statistics.median(ratios) if ratios else float("nan")
            results[(target, category)] = (median, ratios)
            print(f"| {target} | {category} | {len(ratios)} | {median:.3f} ({(median - 1) * 100:+.1f}%) | {miss_q} / {miss_p} |")
    return results


def crop(path, dest, offset):
    subprocess.run(["sips", "-c", str(CROP), str(CROP), "--cropOffset", str(offset[1]), str(offset[0]),
                    path, "--out", dest], check=True, capture_output=True)


def size(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                         check=True, capture_output=True, text=True).stdout.split()
    return int(out[out.index("pixelWidth:") + 1]), int(out[out.index("pixelHeight:") + 1])


def crops(rows, target=85):
    """Side-by-side crops at the matched setting for every file, for the human review."""
    picks = best(rows, target)
    dest_dir = os.path.join(OUT, "crops")
    os.makedirs(dest_dir, exist_ok=True)
    parts = [f"<!doctype html><meta charset=utf-8><title>Q2 crops</title>"
             f"<style>body{{font:14px system-ui;background:#888}}img{{image-rendering:pixelated;width:{CROP * 2}px}}"
             f"td{{vertical-align:top;padding:4px}}</style>"
             f"<h1>Q2: quantizr vs. pngquant at SSIMULACRA2 ≥ {target}</h1>"
             "<p>Each row: source, quantizr, pngquant, shown at 2×. Look for banding, noisy dithering, "
             "wrong colors. Background is grey so alpha edges show.</p><table>"]
    for name in sorted({r["file"] for r in rows}):
        q, p = picks.get((name, "quantizr")), picks.get((name, "pngquant"))
        if not (q and p):
            continue
        ref = os.path.join(WORK, f"{name}.ref.png")
        w, h = size(ref)
        for label, offset in (("center", ((w - CROP) // 2, (h - CROP) // 2)), ("top-left", (0, 0))):
            offset = (max(0, offset[0]), max(0, offset[1]))
            cells = []
            for kind, r in (("source", None), ("quantizr", q), ("pngquant", p)):
                srcpath = ref if r is None else os.path.join(
                    WORK, f"{name}.{r['quantizer']}.{r['colors']}.{r['dither']}.png")
                out = os.path.join(dest_dir, f"{name}.{label}.{kind}.png")
                crop(srcpath, out, offset)
                note = "" if r is None else f" {r['colors']} colors, dither {r['dither']}, {int(r['bytes']):,} B"
                cells.append(f"<td>{kind}{html.escape(note)}<br><img src='{os.path.basename(out)}'></td>")
            parts.append(f"<tr><td colspan=3><b>{name}</b> ({label})</td></tr><tr>{''.join(cells)}</tr>")
    parts.append("</table>")
    with open(os.path.join(dest_dir, "index.html"), "w") as f:
        f.write("\n".join(parts))
    return os.path.join(dest_dir, "index.html")


if __name__ == "__main__":
    rows = load()
    table(rows)
    if "--no-crops" not in sys.argv:
        print("crops:", crops(rows))
