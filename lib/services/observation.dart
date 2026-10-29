import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A single observation of the foreground screen taken through the
/// Android accessibility tree.
///
/// The raw JSON string coming from [ScreenCaptureManager.getUITree] is kept
/// verbatim so callers can compare two observations for change detection,
/// while the parsed [elements] list supports deterministic checks without
/// re-parsing the tree.
class UiSnapshot {
  UiSnapshot({
    required this.rawTree,
    required this.packageName,
    required this.elements,
    required this.hasFocusedEditable,
    required this.capturedAt,
  });

  /// Full JSON returned by the accessibility service (`package` + `elements`).
  final String rawTree;

  /// Foreground package name, or `null` when the service could not report it.
  final String? packageName;

  /// Parsed element list in tree order. Each entry keeps the original `id`
  /// used by `tap(element)` so ids stay valid across compaction.
  final List<Map<String, dynamic>> elements;

  /// Whether an editable node currently reports focus (needed by `type`).
  final bool hasFocusedEditable;

  /// When this observation was taken; used to reject stale evidence.
  final DateTime capturedAt;

  /// Stable change-detection key. Two observations with the same signature
  /// describe the same visible screen state.
  String get signature => rawTree;

  /// Parse the accessibility service payload. Returns `null` for empty or
  /// malformed input instead of throwing, so a bad read never crashes a task.
  static UiSnapshot? parse(String? raw, {DateTime? now}) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final elementsJson = decoded['elements'];
      final elements = <Map<String, dynamic>>[];
      if (elementsJson is List) {
        for (final element in elementsJson) {
          if (element is Map) {
            elements.add(Map<String, dynamic>.from(element));
          }
        }
      }
      final hasFocusedEditable = elements.any(
        (element) => element['editable'] == true && element['focused'] == true,
      );
      return UiSnapshot(
        rawTree: raw,
        packageName: decoded['package'] as String?,
        elements: elements,
        hasFocusedEditable: hasFocusedEditable,
        capturedAt: now ?? DateTime.now(),
      );
    } catch (error) {
      debugPrint('Ignoring malformed accessibility tree: $error');
      return null;
    }
  }

  bool isStale(DateTime now, {required Duration maxAge}) =>
      now.difference(capturedAt) > maxAge;

  /// No usable nodes: the window is inaccessible or not rendered yet.
  bool get isBlank => elements.isEmpty;

  /// Content that is still loading (progress indicators or "loading" copy).
  bool get isLoading {
    for (final element in elements) {
      final type = element['type']?.toString() ?? '';
      if (type.contains('Progress')) return true;
      if (_labelOf(element) != null &&
          RegExp(
            r'\b(loading|please wait|fetching|updating)\b',
            caseSensitive: false,
          ).hasMatch(_labelOf(element)!)) {
        return true;
      }
    }
    return false;
  }

  /// A runtime permission prompt owns the screen instead of the app.
  bool get isPermissionDialog {
    final package = packageName ?? '';
    final isPermissionPackage = package.contains('permissioncontroller');
    final labels = visibleLabels;
    final asksPermission =
        labels.any(
          RegExp(r'\b(allow|deny|permission)\b', caseSensitive: false).hasMatch,
        ) &&
        labels.length <= 8;
    return isPermissionPackage || asksPermission;
  }

  /// Every visible text/description label, used for deterministic checks.
  List<String> get visibleLabels {
    final labels = <String>[];
    for (final element in elements) {
      final label = _labelOf(element);
      if (label != null && label.isNotEmpty) labels.add(label);
    }
    return labels;
  }

  /// All visible text joined, lower-cased matching happens in the verifier.
  String get visibleText => visibleLabels.join('\n');

  static String? _labelOf(Map<String, dynamic> element) {
    final text = element['text']?.toString().trim();
    if (text != null && text.isNotEmpty) return text;
    final desc = element['desc']?.toString().trim();
    if (desc != null && desc.isNotEmpty) return desc;
    return null;
  }

  /// Element lookup by the id the model references in `tap(element)`.
  Map<String, dynamic>? elementById(int id) {
    for (final element in elements) {
      if (element['id'] == id) return element;
    }
    return null;
  }

  bool elementHasLabel(int id, RegExp pattern) {
    final element = elementById(id);
    if (element == null) return false;
    final label = _labelOf(element);
    return label != null && pattern.hasMatch(label);
  }

  /// Compact, deterministic rendering of this screen for the local model.
  ///
  /// One line per element keeps prompt prefill far cheaper than shipping the
  /// full JSON tree while preserving the fields the agent needs: the id used
  /// by `tap`, the label, the center point used by gestures, the size, and
  /// the interaction flags.
  ///
  /// Format:
  /// ```text
  /// package=com.android.settings elements=2
  /// [3] TextView "Display" @540,300 1080x96 click
  /// [9] Switch "Dark theme" @980,420 96x52 check=on disabled
  /// ```
  String renderForModel({
    int maxElements = 120,
    int maxChars = 6000,
    int maxLabelChars = 60,
  }) {
    final header =
        'package=${packageName ?? 'unknown'} '
        'elements=${elements.length}';

    if (elements.isEmpty) return '$header\n(no visible elements)';

    String render(Map<String, dynamic> element) {
      final id = element['id'];
      final type = element['type'] ?? 'View';
      final label = _labelOf(element);
      final bounds = element['bounds'];
      var line = '[$id] $type';
      if (label != null && label.isNotEmpty) {
        final clipped = label.length > maxLabelChars
            ? '${label.substring(0, maxLabelChars - 1)}…'
            : label;
        line += ' "${clipped.replaceAll('"', "'")}"';
      }
      if (bounds is Map) {
        final cx = bounds['cx'];
        final cy = bounds['cy'];
        final w = bounds['w'];
        final h = bounds['h'];
        if (cx != null && cy != null && w != null && h != null) {
          line += ' @$cx,$cy ${w}x$h';
        }
      }
      final flags = <String>[];
      if (element['clickable'] == true) flags.add('click');
      if (element['editable'] == true) flags.add('edit');
      if (element['focused'] == true) flags.add('focus');
      if (element['focusable'] == true) flags.add('focusable');
      if (element['scrollable'] == true) flags.add('scroll');
      if (element['longClickable'] == true) flags.add('longclick');
      if (element['checkable'] == true) {
        flags.add(element['checked'] == true ? 'check=on' : 'check=off');
      }
      if (element['enabled'] == false) flags.add('disabled');
      return flags.isEmpty ? line : '$line ${flags.join(' ')}';
    }

    final entries = <_RenderedElement>[];
    for (final element in elements.take(maxElements)) {
      final isInteractive =
          element['clickable'] == true ||
          element['editable'] == true ||
          element['checkable'] == true ||
          element['scrollable'] == true ||
          element['focusable'] == true;
      entries.add(
        _RenderedElement(line: render(element), isInteractive: isInteractive),
      );
    }

    // Interactive nodes are what the agent acts on, so they are never dropped
    // for budget reasons. Passive text fills whatever room is left, and the
    // kept lines stay in original tree order so reading order survives.
    final budget = maxChars - header.length - 1;
    var used = entries
        .where((entry) => entry.isInteractive)
        .fold<int>(0, (sum, entry) => sum + entry.line.length + 1);
    final keep = List<bool>.filled(entries.length, false);
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].isInteractive) {
        keep[i] = true;
        continue;
      }
      if (used + entries[i].line.length + 1 <= budget) {
        keep[i] = true;
        used += entries[i].line.length + 1;
      }
    }

    final ordered = <String>[];
    for (var i = 0; i < entries.length; i++) {
      if (keep[i]) ordered.add(entries[i].line);
    }

    final body = ordered.join('\n');
    final output = '$header\n$body';
    if (output.length <= maxChars) return output;
    return '${output.substring(0, maxChars)}…';
  }
}

class _RenderedElement {
  const _RenderedElement({required this.line, required this.isInteractive});

  final String line;
  final bool isInteractive;
}

/// Observes the foreground screen through the accessibility tree and caches
/// the result so one action cycle never fetches the same screen twice.
///
/// A cached observation is only served while no device action has been
/// executed since it was taken and it is younger than [cacheTtl]; the screen
/// can change on its own (animations, app transitions), so age matters too.
class ScreenObserver {
  ScreenObserver({
    required Future<String?> Function() fetchTree,
    this.cacheTtl = const Duration(milliseconds: 400),
    DateTime Function()? clock,
  }) : _fetchTree = fetchTree,
       _clock = clock ?? DateTime.now;

  final Future<String?> Function() _fetchTree;
  final Duration cacheTtl;
  final DateTime Function() _clock;

  UiSnapshot? _last;
  DateTime? _lastActionAt;
  int _fetchCount = 0;

  /// Number of real accessibility reads performed; asserted in tests to prove
  /// observations are reused inside one action cycle.
  int get fetchCount => _fetchCount;

  UiSnapshot? get last => _last;

  /// Latest observation, re-read only when [force] is set or the cached one
  /// is no longer trustworthy (an action ran, or it aged out).
  Future<UiSnapshot?> observe({bool force = false}) async {
    final now = _clock();
    if (!force && _last != null) {
      final modifiedSinceRead =
          _lastActionAt != null && !_lastActionAt!.isBefore(_last!.capturedAt);
      final tooOld = now.difference(_last!.capturedAt) > cacheTtl;
      if (!modifiedSinceRead && !tooOld) return _last;
    }
    return refresh();
  }

  /// Always read the tree again.
  Future<UiSnapshot?> refresh() async {
    final now = _clock();
    String? raw;
    try {
      _fetchCount++;
      raw = await _fetchTree();
    } catch (error) {
      debugPrint('Screen observation failed: $error');
      return null;
    }
    final parsed = UiSnapshot.parse(raw, now: now);
    if (parsed == null) return null;
    _last = parsed;
    return parsed;
  }

  /// Poll fresh observations until [matches] succeeds or [timeout] elapses.
  ///
  /// This is how the pipeline copes with slow screen transitions: a tap can
  /// return long before the new window renders, so readiness is decided by
  /// re-reading the tree, not by sleeping. Returns the matching snapshot, or
  /// null when the screen never showed the expected state.
  Future<UiSnapshot?> awaitUntil(
    bool Function(UiSnapshot snapshot) matches, {
    Duration timeout = const Duration(milliseconds: 2000),
    Duration interval = const Duration(milliseconds: 120),
    bool Function()? isCancelled,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (isCancelled?.call() != true) {
      final snapshot = await refresh();
      if (snapshot != null && matches(snapshot)) return snapshot;
      if (!DateTime.now().isBefore(deadline)) break;
      final remaining = deadline.difference(DateTime.now());
      await Future.delayed(remaining < interval ? remaining : interval);
    }
    return null;
  }

  /// Call right after a device action so the next observation is fresh.
  void markActionExecuted() {
    _lastActionAt = _clock();
  }

  /// Drop cached evidence (app switch, task start).
  void invalidate() {
    _last = null;
    _lastActionAt = null;
  }
}
