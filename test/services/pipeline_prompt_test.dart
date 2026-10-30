import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/ai_service.dart';
import 'package:screen_aware_ai/services/observation.dart';

/// Builds a Settings-like accessibility payload at the native element cap
/// (200 nodes), which is what the old implementation forwarded verbatim.
String bigTree({int count = 200}) {
  final elements = <Map<String, dynamic>>[
    for (var i = 0; i < count; i++)
      {
        'id': i,
        'type': i % 4 == 0 ? 'Switch' : 'TextView',
        if (i % 2 == 0)
          'text': 'Some settings row label number $i on the screen',
        if (i % 3 == 0) 'clickable': true,
        if (i % 5 == 0) 'checkable': true,
        if (i % 7 == 0) 'checked': true,
        'bounds': {'cx': 540, 'cy': 120 + i * 11, 'w': 1080, 'h': 96},
      },
  ];
  return jsonEncode({'package': 'com.android.settings', 'elements': elements});
}

void main() {
  group('verify criteria in the model schema', () {
    Map<String, dynamic> response(Map<String, dynamic> extra) => {
      'actions': [
        {'type': 'tap', 'element': 4},
      ],
      'speak': 'Display is open.',
      'done': true,
      'lang': 'en',
      ...extra,
    };

    test('parses a valid verify object', () {
      final parsed = AiService.parseAgentResponse(
        jsonEncode(
          response({
            'verify': {
              'package': 'com.android.settings',
              'all': ['Display'],
              'state': [
                {'label': 'Dark theme', 'checked': true},
              ],
            },
          }),
        ),
      );

      expect(parsed.isValidated, isTrue);
      expect(parsed.verify?.package, 'com.android.settings');
      expect(parsed.verify?.allText, ['Display']);
      expect(parsed.verify?.states.single.checked, isTrue);
      expect(parsed.actions.single.type, 'tap');
    });

    test('rejects the whole response when verify is malformed', () {
      for (final verify in [
        'not an object',
        {'unknown_key': 1},
        {'package': 'bad package'},
        {'all': 42},
      ]) {
        final parsed = AiService.parseAgentResponse(
          jsonEncode(response({'verify': verify})),
        );
        expect(
          parsed.isValidated,
          isFalse,
          reason: 'malformed verify must invalidate the response: $verify',
        );
        expect(parsed.actions, isEmpty, reason: 'nothing may execute');
      }
    });

    test('responses without verify still parse', () {
      final parsed = AiService.parseAgentResponse(jsonEncode(response({})));
      expect(parsed.isValidated, isTrue);
      expect(parsed.verify, isNull);
    });
  });

  group('prompt size (measured before/after)', () {
    const request =
        'Open Android Settings, navigate to Display, and tell me when the '
        'Display page is open.';
    const screen = {'width': 1080, 'height': 2400};

    test('compact observation is smaller than the raw tree it replaces', () {
      final raw = bigTree();
      final snapshot = UiSnapshot.parse(raw)!;
      final compact = snapshot.renderForModel();

      // Old path: the raw accessibility JSON was forwarded to the model.
      final before = AiService.promptLength(
        request,
        screenSize: screen,
        uiTree: raw.length <= 16000 ? raw : raw.substring(0, 16000),
      );
      // New path: the compact line rendering.
      final after = AiService.promptLength(
        request,
        screenSize: screen,
        uiTree: compact,
      );

      debugPrint(
        'PROMPT_SIZE before_chars=$before after_chars=$after '
        'saved=${before - after} '
        'raw_tree=${raw.length} compact_tree=${compact.length}',
      );

      expect(after, lessThan(before));
      expect(compact.length, lessThanOrEqualTo(6000));
      // Element ids survive compaction so tap(element) stays valid, and the
      // element cap keeps huge trees bounded.
      expect(compact, contains('[117]'), reason: 'interactive ids are kept');
      expect(compact, isNot(contains('[120]')), reason: 'element cap applies');
    });
  });
}
