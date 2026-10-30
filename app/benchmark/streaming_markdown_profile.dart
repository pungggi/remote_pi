// ignore_for_file: avoid_print

// Run from app/ after generating a local Windows runner:
//   flutter run --profile -d windows -t benchmark/streaming_markdown_profile.dart
//
// Uses the production Markdown package and equivalent block components. No
// app bootstrap, theme, pairing, network, or saved user data is accessed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/domain/session_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

final bool _adaptive = Platform.environment['BENCH_ADAPTIVE'] == 'true';
final int _initialChars = _positiveInt('BENCH_CHARS', 50000);
final int _intervalMs = _positiveInt('BENCH_INTERVAL_MS', 16);
final int _durationMs = _positiveInt('BENCH_DURATION_MS', 8000);
final int _warmupMs = _positiveInt('BENCH_WARMUP_MS', 1500);

int _positiveInt(String key, int fallback) {
  final value = int.tryParse(Platform.environment[key] ?? '');
  return value != null && value > 0 ? value : fallback;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Benchmark());
}

class _Benchmark extends StatefulWidget {
  const _Benchmark();

  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final frames = <int>[];
  final builds = <int>[];
  final rasters = <int>[];
  final clock = Stopwatch()..start();

  Timer? warmupTimer;
  Timer? inputTimer;
  Timer? flushTimer;
  Timer? finishTimer;
  String streaming = _markdownPrefix(_initialChars);
  String pending = '';
  int updates = 0;
  int sequence = 0;
  bool finished = false;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(recordFrames);
    // Network input is independent from rendering. Like SyncService, an
    // incoming chunk arms one coalescing flush timer; the UI build can then
    // take longer than the interval without creating recursive builds.
    inputTimer = Timer.periodic(const Duration(milliseconds: 4), (_) {
      pending += ' Streaming update ${sequence++} with **bold** text.';
      final interval = _adaptive
          ? streamingFlushIntervalMs(streaming.length + pending.length)
          : _intervalMs;
      flushTimer ??= Timer(Duration(milliseconds: interval), flushPending);
    });
    warmupTimer = Timer(Duration(milliseconds: _warmupMs), () {
      frames.clear();
      builds.clear();
      rasters.clear();
      updates = 0;
      clock.reset();
    });
    finishTimer = Timer(
      Duration(milliseconds: _warmupMs + _durationMs),
      () => unawaited(finish()),
    );
  }

  void flushPending() {
    flushTimer = null;
    if (finished || pending.isEmpty) return;
    final addition = pending;
    pending = '';
    setState(() {
      streaming += addition;
      updates++;
    });
  }

  void recordFrames(List<FrameTiming> timings) {
    for (final timing in timings) {
      frames.add(timing.totalSpan.inMicroseconds);
      builds.add(timing.buildDuration.inMicroseconds);
      rasters.add(timing.rasterDuration.inMicroseconds);
    }
  }

  Future<void> finish() async {
    if (finished) return;
    finished = true;
    inputTimer?.cancel();
    flushTimer?.cancel();
    await SchedulerBinding.instance.endOfFrame;
    frames.sort();
    builds.sort();
    rasters.sort();
    final result = jsonEncode({
      'benchmark': 'streaming_markdown_profile',
      'initialChars': _initialChars,
      'finalChars': streaming.length,
      'adaptive': _adaptive,
      'intervalMs': _intervalMs,
      'warmupMs': _warmupMs,
      'durationMs': clock.elapsedMilliseconds,
      'updates': updates,
      'frameCount': frames.length,
      'frameTotalUs': frames.fold<int>(0, (sum, us) => sum + us),
      'jankFrames': frames.where((us) => us > 16667).length,
      'frameP95Us': percentile(frames),
      'frameMaxUs': frames.isEmpty ? null : frames.last,
      'buildP95Us': percentile(builds),
      'buildTotalUs': builds.fold<int>(0, (sum, us) => sum + us),
      'buildMaxUs': builds.isEmpty ? null : builds.last,
      'buildOverBudget': builds.where((us) => us > 16667).length,
      'rasterTotalUs': rasters.fold<int>(0, (sum, us) => sum + us),
      'rasterP95Us': percentile(rasters),
      'rasterOverBudget': rasters.where((us) => us > 16667).length,
      'rssBytes': ProcessInfo.currentRss,
    });
    stdout.writeln('streaming_markdown_profile $result');
    final resultFile = Platform.environment['BENCH_RESULT_FILE'];
    if (resultFile != null && resultFile.isNotEmpty) {
      await File(resultFile).writeAsString(result);
    } else {
      await stdout.flush();
    }
    exit(0);
  }

  int? percentile(List<int> sorted) =>
      sorted.isEmpty ? null : sorted[((sorted.length - 1) * 0.95).round()];

  @override
  void dispose() {
    warmupTimer?.cancel();
    inputTimer?.cancel();
    flushTimer?.cancel();
    finishTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(recordFrames);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              GptMarkdown(
                streaming,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                codeBuilder: (context, name, code, closed) => Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xff18181b),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      code,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _markdownPrefix(int target) {
  const block = '''
## Implementation plan

The streaming renderer must preserve **Markdown formatting**, links such as
[the project](https://example.com/project), and readable code blocks while the
response grows. This paragraph represents realistic agent output rather than a
short synthetic string.

- Keep the visible transcript responsive.
- Avoid rebuilding content that did not change.
- Preserve `inline_code` and https://example.com/direct-links.

```dart
void main() {
  final values = <int>[1, 2, 3, 4];
  for (final value in values) {
    print('value: ' + value.toString());
  }
}
```

1. Measure a long response.
2. Compare the same workload after each change.
3. Check frame build time and memory use.

''';
  if (target <= 0) return '';
  final buffer = StringBuffer();
  while (buffer.length < target) {
    buffer.write(block);
  }
  final value = buffer.toString();
  return value.length == target ? value : value.substring(0, target);
}
