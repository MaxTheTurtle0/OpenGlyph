# Measure OpenGlyph on a Mac

The read-only monitor samples the installed app without changing it, importing files, or preventing sleep. It writes process and system statistics, never captured text or images.

Build with the installed Xcode command line tools:

```sh
swiftc -O tools/MonitorProcess.swift -o /tmp/MonitorProcess
/tmp/MonitorProcess "$HOME/Applications/OpenGlyph.app/Contents/MacOS/OpenGlyph" \
  "$HOME/Library/Logs/OpenGlyph/performance-$(date +%Y%m%d-%H%M%S)" 3600 1
```

The final two arguments are duration and sample interval in seconds. The output directory must be new. Use `nohup` and redirect output if collecting over SSH. The monitor stops after the requested duration; sleep can delay completion and create gaps.

The output contains `metadata.json`, one sample per line in `samples.jsonl`, and `completion.json`. Check completion, missing samples, query errors, gaps, and process identities before drawing conclusions. Cached process identities are validated every sample; full discovery runs periodically, so brief additional instances may be missed.

After collection, summarize the directory:

```sh
python3 tools/SummarizeProcess.py /absolute/output/directory
```

This writes `summary.json` and `series.csv`. The summary uses the process identity with the most successful observations and excludes marked gaps from average CPU usage. Check the identity counts when the app restarted or another instance ran. First and last five-minute memory medians help compare the start and end of a full run; short probes have overlapping windows.

## Reading the measurements

- Physical footprint is the primary app-memory measurement. Resident memory is separate and includes a different set of pages. Divide bytes by 1,048,576 for MiB.
- CPU is measured from differences in kernel counters between samples. The monitor converts Mach ticks with the machine's timebase before calculating CPU time. One logical core at full use is 100%; a multi-threaded process can exceed 100%.
- Observed session peaks come from the samples. Lifetime peaks include activity before this run and must not be presented as hourly growth.
- Neural memory is recorded separately when the kernel supports it. Process CPU counters do not include all Apple helper-service, GPU, or Neural Engine work.
- Disk, page-in, and wakeup counters are cumulative. Use interval differences or subtract values from the same process identity to measure activity during the run.
- Whole-machine CPU, compression, swap, memory pressure, and thermal state provide context. They cannot be attributed entirely to OpenGlyph.
- The sampler records its own CPU and memory use so collection overhead is visible.

One hour of normal use can show observed memory growth and CPU activity. It does not establish maximum recognition cost or prove that every workload is free of leaks. Compare similar workloads, distinguish model initialization from steady use, and disclose sleep or sampling gaps.

## Compare recognition changes

The developer benchmark generates twelve dense text images, six 1080p and six 4K, followed by eight small-text, language, and QR fixtures. Generation runs separately from recognition. It never reads the screen, updates history, or touches the clipboard.

```sh
BENCHMARK_BINARY=/tmp/ocr-baseline CORE_SOURCE_DIR=/absolute/baseline/OpenGlyphCore \
  scripts/benchmark-ocr.sh --build-only
/tmp/ocr-baseline generate --fixtures-dir /tmp/ocr-fixtures
/tmp/ocr-baseline run --fixtures-dir /tmp/ocr-fixtures --label baseline \
  --idle-seconds 30 --output /tmp/ocr-baseline.json

BENCHMARK_BINARY=/tmp/ocr-candidate scripts/benchmark-ocr.sh --build-only
/tmp/ocr-candidate run --fixtures-dir /tmp/ocr-fixtures --label candidate \
  --idle-seconds 30 --output /tmp/ocr-candidate.json
```

Use the same generated fixture directory for both builds. The tool checks its manifest and image SHA-256 values before recognition. Compile both with the same SDK; the script sets the app's macOS 14 deployment target. The default execution context runs serial `Task.detached` jobs like the app, and records whether each recognition actually ran on the main thread. `--execution-context main` is available for a separate comparison. `--start-delay-seconds 20` leaves time for attaching a profiler.

Latency covers the file-recognition pipeline and worker dispatch/resumption, excluding fixture generation, validation, quality scoring, and idle sampling. CPU counters immediately bracket recognition. Process CPU excludes helper services, GPU, and Neural Engine execution. Compare the first call separately from steady calls because Vision can initialize a model for tens of seconds.

The JSON contains footprint, RSS, allocator in-use/reserved bytes, native CPU, thermal state, and memory-pressure observations. Allocator statistics are separate from physical footprint. Kernel lifetime peaks belong to the entire fresh benchmark process, including tool overhead and all twenty fixtures; use the twelfth case's after-sample to isolate the dense-grid stage. These are observations of a short synthetic workload, not a substitute for profiling the installed GUI over time. Reject runs affected by sleep or suspend, and repeat comparisons if model initialization or system pressure makes them uncertain.

Text correctness is recorded as counts, error rates, and normalized output hashes; recognized text is not serialized. Dense-grid token precision/recall/F1 retains duplicate counts but ignores reading order. The smaller fixtures also report normalized exact matches and character error rates. Compare both completion and correctness; an import can complete with transcription mistakes. Check backup flags before comparing Accurate and Fast measurements.
