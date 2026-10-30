# Streaming Markdown profile benchmark

This benchmark measures the cost of parsing and laying out updates to a growing Markdown response. It uses `GptMarkdown` directly, with realistic headings, links, lists, inline code, and fenced code blocks.

It does not run app bootstrap, pairing, networking, storage, or the app theme. This keeps the measurement focused on Markdown rendering.

## Run on Windows

From `app/`, generate a local runner if one is not present:

```powershell
flutter create --platforms=windows --org ch.pungitore .
flutter build windows --profile -t benchmark/streaming_markdown_profile.dart
```

Run the baseline at 200,000 initial characters:

```powershell
$env:BENCH_CHARS = "200000"
.\build\windows\x64\runner\Profile\app.exe
```

Enable the production adaptive policy in the same binary:

```powershell
$env:BENCH_ADAPTIVE = "true"
.\build\windows\x64\runner\Profile\app.exe
```

The process prints one `streaming_markdown_profile` JSON line and exits. Use a profile build on physical hardware: widget tests do not provide comparable frame timings.

## Controls

- **`BENCH_CHARS`**: Initial document length. Default: `50000`.
- **`BENCH_INTERVAL_MS`**: Baseline update interval. Default: `16`.
- **`BENCH_ADAPTIVE`**: Set to `true` to use `streamingFlushIntervalMs` from production.
- **`BENCH_WARMUP_MS`**: Warm-up excluded from metrics. Default: `1500`.
- **`BENCH_DURATION_MS`**: Measured duration. Default: `8000`.
- **`BENCH_RESULT_FILE`**: Optional path for the JSON result.

Use the same device, window size, Flutter version, and workload for A/B comparisons.

## Adaptive policy

- **Below 50,000 characters**: Flush every 16 ms.
- **50,000–99,999 characters**: Flush every 50 ms.
- **100,000 characters and above**: Flush every 100 ms.
- **Response completion**: Always flush immediately.

This preserves live Markdown while reducing tail parses and string-copy churn. It does not eliminate expensive individual frames for very long documents.

## Measured result

Flutter 3.44.6, `gpt_markdown` 1.4.0, Windows profile build, 200,000 initial characters, 8-second measured window. Values are medians from three alternating baseline/adaptive runs in the same binary. Network input is simulated separately from UI flushes to match the production pipeline.

| Metric | 16 ms baseline | Adaptive | Change |
| --- | ---: | ---: | ---: |
| Streaming updates | 172 | 72 | 58% fewer |
| Total build time | 6.25 s | 4.48 s | 28% less |
| Builds over 16.67 ms | 172 | 72 | 58% fewer |
| Frame p95 | 58.5 ms | 97.4 ms | 66% longer |

The previous 1.1.7 renderer took roughly 0.5–0.6 seconds per build at the same document length. The upgrade provides the largest improvement; adaptive cadence reduces total work further.

Adaptive batches contain more new text, so individual stalls become longer even though fewer stalls occur. This is the trade-off: less total CPU work in exchange for less fluid updates on very long responses.

These are desktop comparative results, not physical-phone battery measurements. The time-window workload also applies different backpressure to each variant, so it is not an identical-total-characters benchmark.
