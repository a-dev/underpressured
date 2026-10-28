#!/usr/bin/env python3
"""Summarize Queue-owned Swift array-copy events from malloc_history reports."""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

ARRAY_COPY_FRAMES = (
    "_ArrayBuffer._consumeAndCreateNew",
    "_ContiguousArrayBuffer._consumeAndCreateNew",
    "ContiguousArray._createNewBuffer",
    "_copyCollectionToContiguousArray",
)
QUEUE_METHOD = re.compile(r"\bQueue\.([A-Za-z_]\w*)\(")


def summarize(path: Path) -> tuple[dict[str, tuple[int, int]], list[str] | None, list[str] | None]:
    totals: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    state_copy_sample: list[str] | None = None
    state_event_sample: list[str] | None = None
    event: list[str] = []

    def flush() -> None:
        nonlocal state_copy_sample, state_event_sample
        if not event or not event[0].startswith("ALLOC "):
            return
        stack = "\n".join(event)
        method_match = QUEUE_METHOD.search(stack)
        if method_match is None:
            return
        method = f"Queue.{method_match.group(1)}"
        copies_array = any(frame in stack for frame in ARRAY_COPY_FRAMES)
        size_match = re.search(r"\[size=(\d+)\]", event[0])
        size = int(size_match.group(1)) if size_match else 0
        if copies_array:
            totals[method][0] += 1
            totals[method][1] += size
            if method == "Queue.setState" and state_copy_sample is None:
                state_copy_sample = excerpt(event)
        elif method == "Queue.setState" and state_event_sample is None and "AsyncStream" in stack:
            state_event_sample = excerpt(event)

    def excerpt(rows: list[str]) -> list[str]:
        selected = [rows[0]]
        for row in rows[1:]:
            if QUEUE_METHOD.search(row) or any(name in row for name in ARRAY_COPY_FRAMES) or "AsyncStream" in row or "_Deque.append" in row:
                selected.append(row)
            if len(selected) >= 8:
                break
        return selected

    with path.open(errors="replace") as source:
        for line in source:
            if re.match(r"^(?:ALLOC|FREE\s|VM_ALLOC|VM_DEALLOC)", line):
                flush()
                event[:] = [line.rstrip()]
            elif event:
                event.append(line.rstrip())
    flush()
    return ({key: (value[0], value[1]) for key, value in totals.items()}, state_copy_sample, state_event_sample)


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit("usage: summarize-allocations.py BASELINE.txt CURRENT.txt OUTPUT.tsv OUTPUT.md")
    baseline, current, tsv_path, markdown_path = map(Path, sys.argv[1:])
    results = [
        ("1987bd6", summarize(baseline)),
        ("current", summarize(current)),
    ]
    with tsv_path.open("w") as destination:
        destination.write("revision\tprofile\tqueue_method\tarray_copy_allocations\tallocated_bytes\n")
        for revision, (totals, _, _) in results:
            for method in sorted(totals):
                count, size = totals[method]
                destination.write(f"{revision}\t1,000 items; one profile run\t{method}\t{count}\t{size}\n")
            if "Queue.setState" not in totals:
                destination.write(f"{revision}\t1,000 items; one profile run\tQueue.setState\t0\t0\n")

    old_total = results[0][1][0].get("Queue.setState", (0, 0))
    new_total = results[1][1][0].get("Queue.setState", (0, 0))
    old_copy_size = None
    if results[0][1][1]:
        match = re.search(r"\[size=(\d+)\]", results[0][1][1][0])
        old_copy_size = int(match.group(1)) if match else None
    lines = [
        "# Allocation profile evidence",
        "",
        "Both release profiles processed one 1,000-item batch with the same no-op `.alreadyOptimized` pipeline and drained events through `.idle`. They used `MallocStackLoggingNoCompact=1` and `malloc_history -allEvents -fullStacks`; profiler timings are excluded from the wall-time results.",
        "",
        f"- Baseline `1987bd6`: Queue.setState allocated {old_total[0]:,} Swift array-copy buffers totaling {old_total[1]:,} bytes.",
        f"- Current: Queue.setState allocated {new_total[0]:,} Swift array-copy buffers totaling {new_total[1]:,} bytes.",
        "",
    ]
    if old_copy_size is not None:
        lines.append(f"- The baseline's sampled queue-state array-copy buffer was {old_copy_size:,} bytes.")
    if new_total[0] == 0:
        lines.append("- No matching current Queue.setState array-copy allocation appeared in this profile.")
    else:
        lines.append("- The current profile includes Queue.setState array-copy allocations; see the current stack sample below.")
    if new_total[0] == 0 and results[1][1][2]:
        lines.append("- The current Queue.setState sample below is an AsyncStream deque allocation, not an array copy.")
    lines.append("")
    for revision, (_, copy_sample, event_sample) in results:
        lines.extend(["", f"## {revision} stack sample", "", "```text"])
        sample = copy_sample if copy_sample else event_sample
        lines.extend(sample or ["No Queue.setState allocation sample was retained."])
        lines.append("```")
    markdown_path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
