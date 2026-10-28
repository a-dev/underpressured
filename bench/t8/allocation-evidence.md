# Allocation profile evidence

Both release profiles processed one 1,000-item batch with the same no-op `.alreadyOptimized` pipeline and drained events through `.idle`. They used `MallocStackLoggingNoCompact=1` and `malloc_history -allEvents -fullStacks`; profiler timings are excluded from the wall-time results.

- Baseline `1987bd6`: Queue.setState allocated 1,000 Swift array-copy buffers totaling 104,032,000 bytes.
- Current: Queue.setState allocated 0 Swift array-copy buffers totaling 0 bytes.

- The baseline's sampled queue-state array-copy buffer was 104,032 bytes.
- No matching current Queue.setState array-copy allocation appeared in this profile.
- The current Queue.setState sample below is an AsyncStream deque allocation, not an array copy.


## 1987bd6 stack sample

```text
ALLOC 0x7a33448000-0x7a3346165f [size=104032]:
4   QueueBaseline                         0x102e4ec78 specialized _ArrayBuffer._consumeAndCreateNew(bufferIsUnique:minimumCapacity:growForAppend:) + 164
5   QueueBaseline                         0x102e4e66c Queue.setState(_:batch:item:) + 1140  Queue.swift:248
6   QueueBaseline                         0x102e4c41c Queue.startAvailable() + 2136  Queue.swift:154
7   QueueBaseline                         0x102e4b194 Queue.enqueue(_:) + 1400  Queue.swift:114
```

## current stack sample

```text
ALLOC 0x10565d770-0x10565d887 [size=280]:
14  libswift_Concurrency.dylib            0x2b3786974 _Deque.append(_:) + 148
15  libswift_Concurrency.dylib            0x2b378413c AsyncStream._Storage.yield(_:) + 1256
16  libswift_Concurrency.dylib            0x2b37833ac AsyncStream.Continuation.yield(_:) + 24
17  QueueBenchmark                        0x104e97c04 Queue.setState(_:itemID:) + 1000  /<compiler-generated>:0
18  QueueBenchmark                        0x104e95488 Queue.startAvailable() + 2364  Queue.swift:216
19  QueueBenchmark                        0x104e92ea0 Queue.enqueue(_:) + 3060  Queue.swift:162
```
