import 'package:flutter/foundation.dart';

/// Stage-by-stage timing for one request through the pipeline.
///
/// Every record logs immediately (`stage=... elapsed_ms=... total_ms=...`)
/// and is aggregated so the end-of-task summary shows where the time actually
/// went: speech capture, observation, prompt preparation, inference, action
/// execution, verification, and speech synthesis are all measured separately.
class PipelineProfiler {
  PipelineProfiler(this.requestId, {Stopwatch? stopwatch})
    : _stopwatch = stopwatch ?? (Stopwatch()..start());

  final String requestId;
  final Stopwatch _stopwatch;
  final Map<String, List<int>> _samples = <String, List<int>>{};

  int get totalMs => _stopwatch.elapsedMilliseconds;

  /// Record a completed stage.
  void record(String stage, int elapsedMs, {String? detail}) {
    (_samples[stage] ??= <int>[]).add(elapsedMs);
    final suffix = detail == null ? '' : ' $detail';
    debugPrint(
      'Lucy[$requestId] stage=$stage elapsed_ms=$elapsedMs '
      'total_ms=$totalMs$suffix',
    );
  }

  /// Time an async stage and record its duration.
  Future<T> time<T>(String stage, Future<T> Function() body) async {
    final timer = Stopwatch()..start();
    try {
      return await body();
    } finally {
      record(stage, timer.elapsedMilliseconds);
    }
  }

  /// Number of times a stage ran in this request.
  int countOf(String stage) => _samples[stage]?.length ?? 0;

  int totalOf(String stage) =>
      (_samples[stage] ?? const <int>[]).fold<int>(0, (sum, ms) => sum + ms);

  int maxOf(String stage) => (_samples[stage] ?? const <int>[]).fold<int>(
    0,
    (ms, max) => ms > max ? ms : max,
  );

  /// Stage that consumed the most wall-clock time overall.
  String? get slowestStage {
    String? slowest;
    var worst = -1;
    for (final entry in _samples.entries) {
      final total = entry.value.fold<int>(0, (sum, ms) => sum + ms);
      if (total > worst) {
        worst = total;
        slowest = entry.key;
      }
    }
    return slowest;
  }

  /// One line per stage plus a total, logged when the task ends.
  void logSummary() {
    final stages = _samples.keys.toList()..sort();
    for (final stage in stages) {
      final samples = _samples[stage]!;
      final total = samples.fold<int>(0, (sum, ms) => sum + ms);
      final avg = total ~/ samples.length;
      final max = samples.fold<int>(0, (ms, m) => ms > m ? ms : m);
      debugPrint(
        'Lucy[$requestId] summary stage=$stage count=${samples.length} '
        'total_ms=$total avg_ms=$avg max_ms=$max',
      );
    }
    debugPrint(
      'Lucy[$requestId] summary stage=total elapsed_ms=$totalMs '
      'bottleneck=${slowestStage ?? 'none'}',
    );
  }

  /// Compact machine-readable totals, e.g. for the status screen or a test.
  Map<String, int> get totals => {
    for (final entry in _samples.entries)
      entry.key: entry.value.fold<int>(0, (sum, ms) => sum + ms),
  };
}
