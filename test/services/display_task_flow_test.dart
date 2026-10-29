import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/agent_plan.dart';
import 'package:screen_aware_ai/services/ai_service.dart';
import 'package:screen_aware_ai/services/observation.dart';
import 'package:screen_aware_ai/services/task_verifier.dart';

/// A scripted run of the acceptance task
/// "Open Android Settings, navigate to Display, and tell me when the Display
/// page is open." against the same decision objects the agent loop uses.
///
/// This exercises planning, action validation, verification, and loop limits
/// deterministically; the on-device run itself still needs a phone.
void main() {
  UiSnapshot screen(String package, List<Map<String, dynamic>> elements) =>
      UiSnapshot.parse(
        '{"package":"$package","elements":${elements.map(_encode).toList()}}',
      )!;

  final home = screen('com.android.launcher', [
    {
      'id': 0,
      'type': 'TextView',
      'text': 'Home',
      'bounds': {'cx': 540, 'cy': 100, 'w': 200, 'h': 60},
    },
  ]);

  final settingsList = screen('com.android.settings', [
    {
      'id': 12,
      'type': 'TextView',
      'text': 'Display',
      'clickable': true,
      'bounds': {'cx': 540, 'cy': 300, 'w': 1080, 'h': 96},
    },
    {
      'id': 13,
      'type': 'TextView',
      'text': 'Battery',
      'clickable': true,
      'bounds': {'cx': 540, 'cy': 420, 'w': 1080, 'h': 96},
    },
  ]);

  final displayPage = screen('com.android.settings', [
    {
      'id': 5,
      'type': 'TextView',
      'text': 'Display',
      'bounds': {'cx': 300, 'cy': 80, 'w': 500, 'h': 80},
    },
    {
      'id': 6,
      'type': 'Switch',
      'text': 'Dark theme',
      'checkable': true,
      'checked': false,
      'clickable': true,
      'bounds': {'cx': 980, 'cy': 400, 'w': 96, 'h': 52},
    },
  ]);

  AgentResponse response({
    required List<AgentAction> actions,
    required bool done,
    String speak = '',
    VerifyCriteria? verify,
  }) => AgentResponse(
    actions: actions,
    speak: speak,
    done: done,
    lang: 'en',
    rawResponse: '{}',
    verify: verify,
  );

  group('acceptance task: Settings → Display', () {
    test('plans, executes, and stops on verified success', () {
      const screen = {'width': 1080, 'height': 2400};
      var inferences = 0;
      var actionsExecuted = 0;

      var baseline = home;
      var latest = home;
      AgentPlan? plan;

      // ── Plan 1: launch Settings ────────────────────────────────────
      inferences++;
      plan = AgentPlan.fromResponse(
        response(
          actions: [
            AgentAction(
              type: 'open_app',
              params: {'package': 'com.android.settings'},
            ),
          ],
          speak: 'Opening Settings.',
          done: false,
        ),
      );
      expect(plan.speak, 'Opening Settings.');

      while (!plan.exhausted) {
        final action = plan.takeNext()!;
        final validation = ActionValidator.validate(
          action,
          snapshot: latest,
          screenSize: screen,
        );
        expect(validation.ok, isTrue, reason: validation.reason);
        baseline = latest;
        actionsExecuted++;
        // Deterministic device effect of open_app:
        latest = settingsList;
        final changed = baseline.signature != latest.signature;
        final budget = AgentBudget(
          maxActions: 12,
          maxInferences: 8,
          deadline: const Duration(minutes: 2),
        );
        budget.recordPlan();
        budget.recordAction(
          signature: actionSignature(action),
          screenChanged: changed,
        );
        expect(budget.stopped, isFalse);
      }

      // Plan 1 is not done, so exactly one more inference is needed.
      expect(inferences, 1);
      expect(actionsExecuted, 1);
      expect(plan.done, isFalse);

      // ── Plan 2: tap Display, claim completion with criteria ────────
      inferences++;
      final displayElement = latest.visibleLabels.indexWhere(
        (label) => label == 'Display',
      );
      expect(displayElement, isNot(-1), reason: 'Display label is visible');

      plan = AgentPlan.fromResponse(
        response(
          actions: [
            AgentAction(type: 'tap', params: {'element': 12}),
          ],
          speak: 'The Display page is open.',
          done: true,
          verify: const VerifyCriteria(
            package: 'com.android.settings',
            allText: ['Display', 'Dark theme'],
          ),
        ),
      );

      final action = plan.takeNext()!;
      final validation = ActionValidator.validate(
        action,
        snapshot: latest,
        screenSize: screen,
      );
      expect(validation.ok, isTrue, reason: validation.reason);

      actionsExecuted++;
      baseline = latest;
      latest = displayPage; // device effect of tapping "Display"
      expect(baseline.signature, isNot(latest.signature));

      // ── Verify ─────────────────────────────────────────────────────
      final verdict = TaskVerifier.verify(
        criteria: plan.verify,
        snapshot: latest,
        previousSnapshot: baseline,
        performedAction: true,
      );
      expect(verdict.status, VerificationStatus.verified);
      expect(verdict.isSuccess, isTrue);

      // Verified success ends the task: no further inference, no further
      // action, and a short confirmation is available to speak.
      expect(inferences, 2);
      expect(actionsExecuted, 2);
      expect(plan.speak, 'The Display page is open.');
      expect(plan.exhausted, isTrue);
    });

    test('does not accept the claim when the Display page never opened', () {
      final plan = AgentPlan.fromResponse(
        response(
          actions: [
            AgentAction(type: 'tap', params: {'element': 12}),
          ],
          speak: 'The Display page is open.',
          done: true,
          verify: const VerifyCriteria(
            package: 'com.android.settings',
            allText: ['Dark theme'],
          ),
        ),
      );
      plan.takeNext();

      // The tap produced no transition: still on the Settings list.
      final verdict = TaskVerifier.verify(
        criteria: plan.verify,
        snapshot: settingsList,
        previousSnapshot: settingsList,
        performedAction: true,
      );
      expect(verdict.status, VerificationStatus.failed);
      expect(verdict.isSuccess, isFalse);
      expect(verdict.evidence, contains('Dark theme'));
    });

    test('an invalid target stops the task instead of tapping blindly', () {
      final plan = AgentPlan.fromResponse(
        response(
          actions: [
            AgentAction(type: 'tap', params: {'element': 4242}),
          ],
          speak: 'Tapping Display.',
          done: false,
        ),
      );
      final action = plan.takeNext()!;
      final validation = ActionValidator.validate(
        action,
        snapshot: settingsList,
        screenSize: {'width': 1080, 'height': 2400},
      );
      expect(validation.ok, isFalse);
      expect(validation.reason, contains('not on the observed screen'));
    });

    test('a screen that never changes ends the run at the loop limit', () {
      final budget = AgentBudget(
        maxActions: 6,
        maxInferences: 3,
        deadline: const Duration(minutes: 2),
      );
      var stopped = false;
      for (var i = 0; i < 6 && !stopped; i++) {
        if (!budget.canExecuteAction || !budget.canPlan) {
          stopped = true;
          break;
        }
        budget.recordPlan();
        budget.recordAction(
          signature: 'tap(element=${10 + i})',
          screenChanged: false,
        );
        stopped = budget.stopped;
      }

      expect(stopped, isTrue);
      expect(budget.stopReason, anyOf('screen_unchanged', 'action_limit'));
      expect(budget.describeStop(), isNotEmpty);
    });
  });
}

String _encode(Map<String, dynamic> element) {
  final buffer = StringBuffer('{');
  var first = true;
  element.forEach((key, value) {
    if (!first) buffer.write(',');
    first = false;
    buffer.write('"$key":');
    if (value is String) {
      buffer.write('"$value"');
    } else if (value is Map) {
      buffer.write(
        '{${value.entries.map((e) => '"${e.key}":${e.value}').join(',')}}',
      );
    } else {
      buffer.write(value);
    }
  });
  buffer.write('}');
  return buffer.toString();
}
