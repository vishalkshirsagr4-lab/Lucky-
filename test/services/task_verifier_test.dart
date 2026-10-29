import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/observation.dart';
import 'package:screen_aware_ai/services/task_verifier.dart';

UiSnapshot settingsDisplay() => UiSnapshot.parse('''
{"package":"com.android.settings","elements":[
 {"id":3,"type":"TextView","text":"Display","clickable":true,"bounds":{"cx":540,"cy":300,"w":1080,"h":96}},
 {"id":8,"type":"Switch","text":"Dark theme","checkable":true,"checked":true,"clickable":true,"bounds":{"cx":980,"cy":420,"w":96,"h":52}},
 {"id":9,"type":"TextView","text":"Brightness level","bounds":{"cx":540,"cy":150,"w":1080,"h":60}}
]}
''')!;

UiSnapshot homeScreen() => UiSnapshot.parse(
  '{"package":"com.android.launcher","elements":[{"id":0,"type":"TextView",'
  '"text":"Home","bounds":{"cx":540,"cy":100,"w":200,"h":60}}]}',
)!;

void main() {
  group('VerifyCriteria.parse', () {
    test('parses package, labels, and control states', () {
      final criteria = VerifyCriteria.parse({
        'package': 'com.android.settings',
        'all': ['Display'],
        'any': ['Brightness', 'Night Light'],
        'state': [
          {'label': 'Dark theme', 'checked': true},
        ],
      })!;

      expect(criteria.package, 'com.android.settings');
      expect(criteria.allText, ['Display']);
      expect(criteria.anyText, ['Brightness', 'Night Light']);
      expect(criteria.states.single.checked, isTrue);
      expect(criteria.isEmpty, isFalse);
    });

    test('rejects malformed criteria instead of trusting them', () {
      expect(() => VerifyCriteria.parse('nope'), throwsFormatException);
      expect(() => VerifyCriteria.parse({'unknown': 1}), throwsFormatException);
      expect(
        () => VerifyCriteria.parse({'package': 'not a package'}),
        throwsFormatException,
      );
      expect(
        () => VerifyCriteria.parse({
          'state': [
            {'label': 'Dark theme'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => VerifyCriteria.parse({'all': List.filled(9, 'x')}),
        throwsFormatException,
      );
      expect(VerifyCriteria.parse(null), isNull);
    });
  });

  group('TaskVerifier with explicit criteria', () {
    test('verifies when package and labels match the live screen', () {
      final result = TaskVerifier.verify(
        criteria: const VerifyCriteria(
          package: 'com.android.settings',
          allText: ['Display', 'Brightness'],
        ),
        snapshot: settingsDisplay(),
        performedAction: true,
      );

      expect(result.status, VerificationStatus.verified);
      expect(result.isSuccess, isTrue);
      expect(result.evidence, contains('com.android.settings'));
    });

    test('fails when the foreground app is not the expected one', () {
      final result = TaskVerifier.verify(
        criteria: const VerifyCriteria(package: 'com.android.settings'),
        snapshot: homeScreen(),
        performedAction: true,
      );

      expect(result.status, VerificationStatus.failed);
      expect(result.isSuccess, isFalse);
      expect(result.evidence, contains('com.android.launcher'));
    });

    test('fails when the expected label is missing', () {
      final result = TaskVerifier.verify(
        criteria: const VerifyCriteria(allText: ['Display', 'Night Light']),
        snapshot: settingsDisplay(),
        performedAction: true,
      );

      expect(result.status, VerificationStatus.failed);
      expect(result.evidence, contains('Night Light'));
    });

    test('fails when none of the alternative labels are visible', () {
      final result = TaskVerifier.verify(
        criteria: const VerifyCriteria(anyText: ['Nonsense A', 'Nonsense B']),
        snapshot: settingsDisplay(),
        performedAction: true,
      );
      expect(result.status, VerificationStatus.failed);
    });

    test('checks a toggle against its actual reported state', () {
      final on = TaskVerifier.verify(
        criteria: const VerifyCriteria(
          states: [VerifyState(label: 'Dark theme', checked: true)],
        ),
        snapshot: settingsDisplay(),
        performedAction: true,
      );
      expect(on.status, VerificationStatus.verified);

      final off = TaskVerifier.verify(
        criteria: const VerifyCriteria(
          states: [VerifyState(label: 'Dark theme', checked: false)],
        ),
        snapshot: settingsDisplay(),
        performedAction: true,
      );
      expect(off.status, VerificationStatus.failed);
      expect(off.evidence, contains('is on'));
    });

    test('fails when there is no observation at all', () {
      final result = TaskVerifier.verify(
        criteria: const VerifyCriteria(package: 'com.android.settings'),
        snapshot: null,
        performedAction: true,
      );
      expect(result.status, VerificationStatus.failed);
      expect(result.evidence, contains('no screen observation'));
    });
  });

  group('TaskVerifier without criteria', () {
    test('accepts answers that required no device action', () {
      final result = TaskVerifier.verify(
        snapshot: homeScreen(),
        performedAction: false,
      );
      expect(result.status, VerificationStatus.verified);
    });

    test('treats a changed screen as weak but acceptable evidence', () {
      final result = TaskVerifier.verify(
        snapshot: settingsDisplay(),
        previousSnapshot: homeScreen(),
        performedAction: true,
      );
      expect(result.status, VerificationStatus.weaklyVerified);
      expect(result.isSuccess, isTrue);
      expect(result.evidence, contains('no explicit criteria'));
    });

    test('never accepts a claim when the screen did not change', () {
      final result = TaskVerifier.verify(
        snapshot: settingsDisplay(),
        previousSnapshot: settingsDisplay(),
        performedAction: true,
      );
      expect(result.status, VerificationStatus.failed);
      expect(result.isSuccess, isFalse);
      expect(result.evidence, contains('unchanged'));
    });

    test('fails when no observation exists after actions', () {
      final result = TaskVerifier.verify(
        snapshot: null,
        previousSnapshot: settingsDisplay(),
        performedAction: true,
      );
      expect(result.status, VerificationStatus.failed);
    });
  });
}
