# T8 queue benchmark

`run.sh` builds the `QueueBenchmark` executable in release mode and writes its CSV measurements to stdout. Build output goes to stderr, so the result can be saved directly:

```sh
./bench/t8/run.sh > /tmp/t8-results.csv
```

The timed region starts at admission and ends after the idle event is consumed. It includes queue transitions and event delivery, but excludes item and batch construction. Parallelism is 8; the no-op pipeline never reserves pixels.

The executable runs no-op batches of 1,000, 5,000, and 10,000 items five times each. A single event consumer drains each run through `.idle`; it counts terminal item events and checks `Queue.diagnostics` after completion. The final check runs 100 independent 100-item batches on one queue and verifies retained execution records and slots are zero after every idle.

`profile-baseline.sh` and `profile-allocations.sh` capture the same 1,000-item, one-repeat profile using macOS `MallocStackLoggingNoCompact` and `malloc_history`. The baseline script extracts only `UnderpressuredCore` from commit `1987bd6`; the current script uses the workspace package. Both wait for a workload-ready marker before collecting the full allocation/free event history. Their raw histories are written under `/tmp` by default. They do not save profiler output in the repository.

Capture both histories with these commands. If an output already exists, choose a new path.

```sh
./bench/t8/profile-baseline.sh
./bench/t8/profile-allocations.sh
```

Summarize the captured histories and save the compact evidence files with:

```sh
./bench/t8/summarize-allocations.py \
  /tmp/underpressured-t8-baseline-allocation-history.txt \
  /tmp/underpressured-t8-allocation-history.txt \
  bench/t8/allocation-evidence.tsv \
  bench/t8/allocation-evidence.md
```

The profiling runtime is intentionally excluded from the timing results. The no-op pipeline measures scheduler and event-stream behavior; it does not measure image processing, filesystem throughput, or application end-to-end performance.

Recorded measurements and limits are in [RESULTS.md](RESULTS.md).
