import 'observation.dart';

/// Deterministic success condition emitted by the model alongside `done`.
///
/// Everything here is checkable against the accessibility tree without
/// another inference, so "the task is finished" is proven by the device state
/// instead of by the model's claim.
class VerifyCriteria {
  const VerifyCriteria({
    this.package,
    this.allText = const [],
    this.anyText = const [],
    this.states = const [],
  });

  /// Foreground package that must be visible, e.g. `com.android.settings`.
  final String? package;

  /// Labels that must all appear somewhere on screen.
  final List<String> allText;

  /// Of these labels at least one must appear on screen (empty = no check).
  final List<String> anyText;

  /// Toggle states that must hold on a named control.
  final List<VerifyState> states;

  bool get isEmpty =>
      package == null && allText.isEmpty && anyText.isEmpty && states.isEmpty;

  /// Parse the optional `verify` object from a model response.
  /// Throws [FormatException] on a malformed payload so the whole response is
  /// rejected before any action runs.
  static VerifyCriteria? parse(Object? value) {
    if (value == null) return null;
    if (value is! Map) {
      throw const FormatException('verify must be an object');
    }
    final json = Map<String, dynamic>.from(value);
    const allowed = {'package', 'all', 'any', 'state'};
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('verify has unexpected fields');
    }

    String? package;
    final packageValue = json['package'];
    if (packageValue != null) {
      if (packageValue is! String ||
          !RegExp(
            r'^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$',
          ).hasMatch(packageValue)) {
        throw const FormatException('verify.package is not a package name');
      }
      package = packageValue;
    }

    List<String> readLabelList(Object? raw, String field) {
      if (raw == null) return const [];
      if (raw is! List || raw.length > 8) {
        throw FormatException('verify.$field must be a short list');
      }
      return raw
          .map((item) {
            if (item is! String || item.trim().isEmpty || item.length > 80) {
              throw FormatException('verify.$field contains an invalid label');
            }
            return item.trim();
          })
          .toList(growable: false);
    }

    final states = <VerifyState>[];
    final rawStates = json['state'];
    if (rawStates != null) {
      if (rawStates is! List || rawStates.length > 4) {
        throw const FormatException('verify.state must be a short list');
      }
      for (final raw in rawStates) {
        if (raw is! Map) {
          throw const FormatException('verify.state entries must be objects');
        }
        final entry = Map<String, dynamic>.from(raw);
        if (entry.keys.any((key) => key != 'label' && key != 'checked')) {
          throw const FormatException('verify.state has unexpected fields');
        }
        final label = entry['label'];
        final checked = entry['checked'];
        if (label is! String ||
            label.trim().isEmpty ||
            label.length > 80 ||
            checked is! bool) {
          throw const FormatException('verify.state entry is invalid');
        }
        states.add(VerifyState(label: label.trim(), checked: checked));
      }
    }

    return VerifyCriteria(
      package: package,
      allText: readLabelList(json['all'], 'all'),
      anyText: readLabelList(json['any'], 'any'),
      states: states,
    );
  }

  /// Evaluate against a fresh observation.
  /// Returns `null` when every condition holds, otherwise the first
  /// human-readable reason the evidence does not support success.
  String? failureReason(UiSnapshot? snapshot) {
    if (snapshot == null) {
      return 'no screen observation was available to check';
    }
    if (package != null && snapshot.packageName != package) {
      return 'the foreground app is "${snapshot.packageName ?? 'unknown'}", '
          'expected "$package"';
    }
    final visible = snapshot.visibleLabels;
    final haystack = visible.join('\n').toLowerCase();
    for (final label in allText) {
      if (!haystack.contains(label.toLowerCase())) {
        return 'the screen does not show "$label"';
      }
    }
    if (anyText.isNotEmpty &&
        !anyText.any((label) => haystack.contains(label.toLowerCase()))) {
      return 'the screen shows none of: ${anyText.map((l) => '"$l"').join(', ')}';
    }
    for (final state in states) {
      final element = _findElement(snapshot, state.label);
      if (element == null) {
        return 'no control labeled "${state.label}" is visible';
      }
      final checked = element['checked'] == true;
      if (checked != state.checked) {
        return '"${state.label}" is ${checked ? 'on' : 'off'}, '
            'expected ${state.checked ? 'on' : 'off'}';
      }
    }
    return null;
  }

  Map<String, dynamic>? _findElement(UiSnapshot snapshot, String label) {
    final needle = label.toLowerCase();
    for (final element in snapshot.elements) {
      final text = element['text']?.toString().toLowerCase() ?? '';
      final desc = element['desc']?.toString().toLowerCase() ?? '';
      if (text.contains(needle) || desc.contains(needle)) return element;
    }
    return null;
  }

  String describe() {
    final parts = <String>[];
    if (package != null) parts.add('app=$package');
    if (allText.isNotEmpty) parts.add('text=$allText');
    if (anyText.isNotEmpty) parts.add('any=$anyText');
    for (final state in states) {
      parts.add('${state.label}=${state.checked ? 'on' : 'off'}');
    }
    return parts.isEmpty ? 'no criteria' : parts.join(', ');
  }
}

class VerifyState {
  const VerifyState({required this.label, required this.checked});

  final String label;
  final bool checked;
}

enum VerificationStatus {
  /// The device state proves the goal.
  verified,

  /// No explicit criteria, but the screen demonstrably changed as a result
  /// of executed actions. Evidence, but weaker than a matched criterion.
  weaklyVerified,

  /// The evidence contradicts the claim or does not exist.
  failed,
}

class VerificationResult {
  const VerificationResult(this.status, this.evidence);

  final VerificationStatus status;
  final String evidence;

  bool get isSuccess =>
      status == VerificationStatus.verified ||
      status == VerificationStatus.weaklyVerified;

  @override
  String toString() => 'VerificationResult(${status.name}: $evidence)';
}

/// Deterministic verification of a claimed task result.
///
/// Order of evidence, cheapest first:
/// 1. explicit criteria matched against the accessibility tree,
/// 2. previous-vs-current screen comparison when no criteria exist,
/// 3. failure when neither supports the claim (never a blind success).
class TaskVerifier {
  const TaskVerifier._();

  static VerificationResult verify({
    VerifyCriteria? criteria,
    UiSnapshot? snapshot,
    UiSnapshot? previousSnapshot,
    bool performedAction = false,
    bool modelClaimedDone = true,
  }) {
    if (criteria != null && !criteria.isEmpty) {
      final failure = criteria.failureReason(snapshot);
      if (failure == null) {
        return VerificationResult(
          VerificationStatus.verified,
          'matched ${criteria.describe()}',
        );
      }
      return VerificationResult(VerificationStatus.failed, failure);
    }

    if (!performedAction) {
      // No device effect was requested or produced, so there is nothing on
      // the device to disprove the answer.
      return const VerificationResult(
        VerificationStatus.verified,
        'no device action was required for this answer',
      );
    }

    if (snapshot == null) {
      return const VerificationResult(
        VerificationStatus.failed,
        'the screen could not be observed after the actions',
      );
    }

    final changed =
        previousSnapshot != null &&
        previousSnapshot.signature != snapshot.signature;
    if (!changed) {
      return VerificationResult(
        VerificationStatus.failed,
        modelClaimedDone
            ? 'the screen is unchanged after the executed actions'
            : 'the screen did not change',
      );
    }

    final where = snapshot.packageName ?? 'the current app';
    return VerificationResult(
      VerificationStatus.weaklyVerified,
      'screen changed (now showing $where, '
      '${snapshot.elements.length} elements) but no explicit criteria were given',
    );
  }
}
