# T8 queue benchmark results

The release queue benchmark recorded five runs at each size on a Mac14,2 (8 cores, arm64, macOS 27.0.1). Around the run, system load averages were 3.85, 4.09, and 5.02. Treat wall times as descriptive scheduler-only measurements; the five sequential runs are not separate cold-start measurements.

| Items | Median elapsed | Range | Admissions | Waiting visits | State lookups | Finishes | Pixel waiter visits |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 8.479 ms | 7.541–9.228 ms | 1,000 | 1,000 | 2,000 | 1,000 | 0 |
| 5,000 | 43.628 ms | 42.794–44.558 ms | 5,000 | 5,000 | 10,000 | 5,000 | 0 |
| 10,000 | 89.423 ms | 87.940–103.894 ms | 10,000 | 10,000 | 20,000 | 10,000 | 0 |

The recorded scheduler counters are linear in item count: one admission, one waiting visit, two state lookups, and one finish per item. These counters count logical transitions, not every hash-table operation or FIFO compaction move. The FIFO compacts only after consuming about half its slots, so its total movement is amortized linear. Every run drained exactly one terminal event per item and ended with zero active items, batches, waiting slots, pixel-waiter slots, active sources, and no active run. `timings.tsv` contains all 15 observations and counters.

The repeated-cycle check completed 100 independent 100-item runs on one queue. After every `.idle`, active item and batch records, both waiting-slot counts, active-source membership, and the run context were all cleared. The emitted final diagnostics are saved in `retention.tsv`.

## Allocation evidence

Matched release profiles processed one 1,000-item batch and drained events through `.idle`. The old queue at `1987bd6` recorded 1,000 `_ArrayBuffer._consumeAndCreateNew` allocations from `Queue.setState`, each 104,032 bytes, for 104,032,000 bytes of batch-array copies. The current queue recorded zero such allocations from `Queue.setState`. Both profiles also record other queue-related allocations; this result isolates the repeated per-state copies. The method-level counts and compact stack excerpts are in [allocation-evidence.md](allocation-evidence.md) and [allocation-evidence.tsv](allocation-evidence.tsv).

The allocation profile confirms that the repeated batch-array copy site disappeared in the no-op workload. It does not characterize allocations from real image pipelines or UI history.

Instruments could not attach to the launched benchmark on this host. Allocation evidence therefore uses full malloc event histories, including freed allocations. Compact logging and live-allocation snapshots are insufficient for these short-lived copies. The scripts unset `MallocStackLogging`, which would otherwise override `MallocStackLoggingNoCompact`.

No CPU bottleneck, image-throughput improvement, or base-M1 result is claimed by these no-op measurements.
