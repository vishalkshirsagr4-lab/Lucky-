import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/observation.dart';

/// A Settings-like tree with [count] elements, half of them interactive.
String buildTree({
  int count = 60,
  String package = 'com.android.settings',
  List<Map<String, dynamic>>? extra,
}) {
  final elements = <Map<String, dynamic>>[
    for (var i = 0; i < count; i++)
      {
        'id': i,
        'type': i.isEven ? 'TextView' : 'LinearLayout',
        if (i % 3 == 0)
          'text': 'Setting item $i with a reasonably long label text',
        if (i % 3 == 0) 'clickable': true,
        if (i % 5 == 0) 'checkable': true,
        if (i % 7 == 0) 'checked': true,
        'bounds': {'cx': 540, 'cy': 100 + i * 12, 'w': 1080, 'h': 96},
      },
    ...?extra,
  ];
  return jsonEncode({'package': package, 'elements': elements});
}

void main() {
  group('UiSnapshot.parse', () {
    test('parses package, elements, and focused editable state', () {
      final snapshot = UiSnapshot.parse(
        buildTree(
          extra: [
            {
              'id': 999,
              'type': 'EditText',
              'text': 'Search',
              'editable': true,
              'focused': true,
              'bounds': {'cx': 500, 'cy': 60, 'w': 900, 'h': 80},
            },
          ],
        ),
      );

      expect(snapshot, isNotNull);
      expect(snapshot!.packageName, 'com.android.settings');
      expect(snapshot.elements, hasLength(61));
      expect(snapshot.hasFocusedEditable, isTrue);
      expect(snapshot.isBlank, isFalse);
    });

    test('returns null for empty and malformed input instead of throwing', () {
      expect(UiSnapshot.parse(null), isNull);
      expect(UiSnapshot.parse(''), isNull);
      expect(UiSnapshot.parse('not json'), isNull);
      expect(UiSnapshot.parse('[1,2,3]'), isNull);
    });

    test('detects loading screens, blank screens, and permission dialogs', () {
      final loading = UiSnapshot.parse(
        buildTree(
          extra: [
            {
              'id': 500,
              'type': 'ProgressBar',
              'bounds': {'cx': 10, 'cy': 10, 'w': 5, 'h': 5},
            },
          ],
        ),
      );
      expect(loading!.isLoading, isTrue);

      final blank = UiSnapshot.parse('{"package":"x","elements":[]}');
      expect(blank!.isBlank, isTrue);

      final permission = UiSnapshot.parse(
        buildTree(package: 'com.android.permissioncontroller', count: 3),
      );
      expect(permission!.isPermissionDialog, isTrue);
    });

    test('reports staleness against a maximum age', () {
      final snapshot = UiSnapshot.parse(
        buildTree(),
        now: DateTime(2026, 1, 1, 10),
      );
      expect(
        snapshot!.isStale(
          DateTime(2026, 1, 1, 10, 0, 0, 300),
          maxAge: const Duration(milliseconds: 400),
        ),
        isFalse,
      );
      expect(
        snapshot.isStale(
          DateTime(2026, 1, 1, 10, 0, 1),
          maxAge: const Duration(milliseconds: 400),
        ),
        isTrue,
      );
    });
  });

  group('UiSnapshot.renderForModel', () {
    test('renders ids, labels, centers, sizes, and flags on one line each', () {
      final snapshot = UiSnapshot.parse(
        buildTree(
          count: 0,
          extra: [
            {
              'id': 12,
              'type': 'Switch',
              'text': 'Dark theme',
              'checkable': true,
              'checked': true,
              'clickable': true,
              'bounds': {'cx': 980, 'cy': 420, 'w': 96, 'h': 52},
            },
            {
              'id': 13,
              'type': 'TextView',
              'text': 'Disabled row',
              'clickable': true,
              'enabled': false,
              'bounds': {'cx': 540, 'cy': 500, 'w': 1080, 'h': 96},
            },
          ],
        ),
      )!;

      final rendered = snapshot.renderForModel();
      expect(rendered, startsWith('package=com.android.settings elements=2'));
      expect(
        rendered,
        contains('[12] Switch "Dark theme" @980,420 96x52 click check=on'),
      );
      expect(rendered, contains('[13] TextView "Disabled row" @540,500'));
      expect(rendered, contains('disabled'));
      // Short lines: far cheaper to prefill than the raw JSON tree.
      expect(rendered.length, lessThan(snapshot.rawTree.length));
    });

    test('keeps every interactive element while trimming passive text', () {
      final interactive = <Map<String, dynamic>>[
        for (var i = 0; i < 6; i++)
          {
            'id': 100 + i,
            'type': 'Button',
            'text': 'Action button number $i that is fairly long text',
            'clickable': true,
            'bounds': {'cx': 540, 'cy': 200 + i * 100, 'w': 900, 'h': 80},
          },
      ];
      final passive = <Map<String, dynamic>>[
        for (var i = 0; i < 40; i++)
          {
            'id': 200 + i,
            'type': 'TextView',
            'text': 'Passive descriptive text block number $i on this screen',
            'bounds': {'cx': 540, 'cy': 900 + i * 20, 'w': 900, 'h': 40},
          },
      ];
      final snapshot = UiSnapshot.parse(
        buildTree(count: 0, extra: [...interactive, ...passive]),
      )!;

      // Budget that comfortably fits the interactive rows but not all text.
      final rendered = snapshot.renderForModel(maxChars: 900);
      for (var i = 0; i < 6; i++) {
        expect(rendered, contains('[${100 + i}]'), reason: 'interactive $i');
      }
      expect(rendered.length, lessThanOrEqualTo(900));
      expect(rendered, isNot(contains('[239]')));
    });

    test('caps element count for very large trees', () {
      final snapshot = UiSnapshot.parse(buildTree(count: 200))!;
      final rendered = snapshot.renderForModel(maxElements: 50, maxChars: 8000);
      expect('['.allMatches(rendered).length, lessThanOrEqualTo(50));
    });
  });

  group('ScreenObserver caching', () {
    late DateTime now;
    late int fetches;
    late String tree;

    setUp(() {
      now = DateTime(2026, 1, 1, 10);
      fetches = 0;
      tree = buildTree(count: 3);
    });

    ScreenObserver build({Duration ttl = const Duration(milliseconds: 400)}) {
      return ScreenObserver(
        fetchTree: () async {
          fetches++;
          return tree;
        },
        cacheTtl: ttl,
        clock: () => now,
      );
    }

    test(
      'reuses one observation until an action or the TTL invalidates it',
      () async {
        final observer = build();

        expect(await observer.observe(), isNotNull);
        expect(fetches, 1);

        // Same screen, no action: served from cache.
        now = now.add(const Duration(milliseconds: 100));
        await observer.observe();
        await observer.observe();
        expect(fetches, 1, reason: 'one action cycle must read the tree once');

        // An action was executed: the cached screen is no longer evidence.
        observer.markActionExecuted();
        now = now.add(const Duration(milliseconds: 10));
        await observer.observe();
        expect(fetches, 2);

        // Without an action, aging past the TTL also forces a re-read.
        now = now.add(const Duration(milliseconds: 1000));
        await observer.observe();
        expect(fetches, 3);
      },
    );

    test('refresh always reads and invalidate drops the cache', () async {
      final observer = build();
      await observer.observe();
      await observer.refresh();
      expect(fetches, 2);

      observer.invalidate();
      expect(observer.last, isNull);
      await observer.observe();
      expect(fetches, 3);
    });

    test(
      'waits through a slow screen transition instead of sleeping',
      () async {
        var reads = 0;
        final observer = ScreenObserver(
          fetchTree: () async {
            reads++;
            // The first reads still show the old window; only the third
            // reflects the transition.
            return reads < 3 ? buildTree(count: 3) : buildTree(count: 5);
          },
          clock: () => now,
        );

        final changed = await observer.awaitUntil(
          (snapshot) => snapshot.elements.length == 5,
          timeout: const Duration(seconds: 2),
          interval: const Duration(milliseconds: 1),
        );

        expect(changed, isNotNull);
        expect(changed!.elements, hasLength(5));
        expect(reads, 3, reason: 'poll until the expected state appears');
      },
    );

    test('gives up after the timeout when the screen never changes', () async {
      var reads = 0;
      final observer = ScreenObserver(
        fetchTree: () async {
          reads++;
          return buildTree(count: 3);
        },
        clock: () => now,
      );

      final timer = Stopwatch()..start();
      final result = await observer.awaitUntil(
        (_) => false,
        timeout: const Duration(milliseconds: 60),
        interval: const Duration(milliseconds: 10),
      );

      expect(result, isNull, reason: 'no evidence, no success');
      expect(timer.elapsedMilliseconds, greaterThanOrEqualTo(50));
      expect(
        reads,
        greaterThan(1),
        reason: 'it kept polling until the deadline',
      );
    });

    test('stops polling when the task is cancelled', () async {
      var reads = 0;
      var cancelled = false;
      final observer = ScreenObserver(
        fetchTree: () async {
          reads++;
          cancelled = true;
          return buildTree(count: 3);
        },
        clock: () => now,
      );

      final result = await observer.awaitUntil(
        (_) => false,
        timeout: const Duration(seconds: 5),
        interval: const Duration(milliseconds: 10),
        isCancelled: () => cancelled,
      );

      expect(result, isNull);
      expect(reads, 1, reason: 'cancellation must stop the poll loop');
    });

    test('a failing platform read yields null instead of throwing', () async {
      final observer = ScreenObserver(
        fetchTree: () async => throw StateError('accessibility off'),
        clock: () => now,
      );
      expect(await observer.refresh(), isNull);
      expect(await observer.observe(), isNull);
    });
  });
}
