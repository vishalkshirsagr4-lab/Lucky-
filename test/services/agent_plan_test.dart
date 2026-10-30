import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/agent_plan.dart';
import 'package:screen_aware_ai/services/ai_service.dart';
import 'package:screen_aware_ai/services/observation.dart';
import 'package:screen_aware_ai/services/task_verifier.dart';

AgentAction action(String type, [Map<String, dynamic> params = const {}]) =>
    AgentAction(type: type, params: params);

UiSnapshot settingsSnapshot() => UiSnapshot.parse('''
{"package":"com.android.settings","elements":[
 {"id":0,"type":"TextView","text":"Display","clickable":true,"enabled":false,"bounds":{"cx":540,"cy":300,"w":1080,"h":96}},
 {"id":4,"type":"TextView","text":"Display","clickable":true,"bounds":{"cx":540,"cy":300,"w":1080,"h":96}},
 {"id":7,"type":"LinearLayout","text":"Header only","bounds":{"cx":540,"cy":80,"w":1080,"h":60}},
 {"id":9,"type":"EditText","text":"Search settings","editable":true,"focused":true,"focusable":true,"bounds":{"cx":540,"cy":60,"w":1000,"h":90}},
 {"id":11,"type":"Switch","text":"Dark theme","checkable":true,"checked":false,"clickable":true,"bounds":{"cx":980,"cy":420,"w":96,"h":52}}
]}
''')!;

void main() {
  group('AgentPlan', () {
    test('walks actions in order and reports exhaustion', () {
      final plan = AgentPlan.fromResponse(
        AgentResponse(
          actions: [action('back'), action('home')],
          speak: 'Working.',
          done: false,
          lang: 'en',
          rawResponse: '{}',
        ),
      );

      expect(plan.total, 2);
      expect(plan.exhausted, isFalse);
      expect(plan.takeNext()!.type, 'back');
      expect(plan.remaining, 1);
      expect(plan.takeNext()!.type, 'home');
      expect(plan.exhausted, isTrue);
      expect(plan.takeNext(), isNull);
    });

    test('retryLast re-queues exactly one action for a safe retry', () {
      final plan = AgentPlan.fromResponse(
        AgentResponse(
          actions: [
            action('tap', {'element': 4}),
            action('back'),
          ],
          speak: '',
          done: true,
          lang: 'en',
          rawResponse: '{}',
        ),
      );

      plan.takeNext();
      plan.retryLast();
      expect(plan.remaining, 2);
      expect(plan.takeNext()!.type, 'tap');
      // retryLast is a no-op before anything was taken.
      final fresh = AgentPlan.fromResponse(
        AgentResponse(
          actions: [action('home')],
          speak: '',
          done: true,
          lang: 'en',
          rawResponse: '{}',
        ),
      );
      fresh.retryLast();
      expect(fresh.remaining, 1);
    });

    test('carries the verify criteria from the response', () {
      final plan = AgentPlan.fromResponse(
        AgentResponse(
          actions: [
            action('tap', {'element': 4}),
          ],
          speak: 'Opening Display.',
          done: true,
          lang: 'en',
          rawResponse: '{}',
          verify: const VerifyCriteria(package: 'com.android.settings'),
        ),
      );
      expect(plan.verify?.package, 'com.android.settings');
      expect(plan.done, isTrue);
    });
  });

  group('actionSignature', () {
    test('is stable across parameter ordering', () {
      final a = action('tap', {'element': 4});
      final b = action('tap', {'element': 4});
      final c = action('tap', {'element': 5});
      expect(actionSignature(a), actionSignature(b));
      expect(actionSignature(a), isNot(actionSignature(c)));
      expect(actionSignature(action('back')), 'back');
    });
  });

  group('ActionValidator', () {
    final screen = {'width': 1080, 'height': 2400};

    test('accepts an element that exists, is enabled and interactive', () {
      final result = ActionValidator.validate(
        action('tap', {'element': 4}),
        snapshot: settingsSnapshot(),
        screenSize: screen,
      );
      expect(result.ok, isTrue, reason: result.reason);
    });

    test('rejects taps on elements missing from the observation', () {
      final result = ActionValidator.validate(
        action('tap', {'element': 4242}),
        snapshot: settingsSnapshot(),
        screenSize: screen,
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('not on the observed screen'));
    });

    test('rejects taps without any observation to check against', () {
      final result = ActionValidator.validate(
        action('tap', {'element': 4}),
        screenSize: screen,
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('no screen observation'));
    });

    test('rejects disabled and non-interactive elements', () {
      final disabled = ActionValidator.validate(
        action('tap', {'element': 0}),
        snapshot: settingsSnapshot(),
        screenSize: screen,
      );
      expect(disabled.ok, isFalse);
      expect(disabled.reason, contains('disabled'));

      final passive = ActionValidator.validate(
        action('tap', {'element': 7}),
        snapshot: settingsSnapshot(),
        screenSize: screen,
      );
      expect(passive.ok, isFalse);
      expect(passive.reason, contains('not interactive'));
    });

    test('rejects typing when no editable field is focused', () {
      final focused = ActionValidator.validate(
        action('type', {'text': 'hello'}),
        snapshot: settingsSnapshot(),
        screenSize: screen,
      );
      expect(focused.ok, isTrue, reason: focused.reason);

      final unfocused = ActionValidator.validate(
        action('type', {'text': 'hello'}),
        snapshot: UiSnapshot.parse(
          '{"package":"a.b","elements":[{"id":0,"type":"TextView",'
          '"text":"x","bounds":{"cx":1,"cy":1,"w":1,"h":1}}]}',
        ),
        screenSize: screen,
      );
      expect(unfocused.ok, isFalse);
      expect(unfocused.reason, contains('focused input field'));
    });

    test('rejects swipes and taps that fall off the screen', () {
      final swipe = ActionValidator.validate(
        action('swipe', {
          'startX': 100,
          'startY': 100,
          'endX': 5000,
          'endY': 100,
        }),
        snapshot: settingsSnapshot(),
        screenSize: screen,
      );
      expect(swipe.ok, isFalse);

      final degenerate = ActionValidator.validate(
        action('swipe', {
          'startX': 100,
          'startY': 100,
          'endX': 101,
          'endY': 101,
        }),
        snapshot: settingsSnapshot(),
        screenSize: screen,
      );
      expect(degenerate.ok, isFalse);
    });

    test('accepts navigation and rejects unsupported action types', () {
      expect(
        ActionValidator.validate(action('back'), screenSize: screen).ok,
        isTrue,
      );
      expect(
        ActionValidator.validate(action('home'), screenSize: screen).ok,
        isTrue,
      );
      expect(
        ActionValidator.validate(
          action('open_app', {'package': 'com.android.settings'}),
          screenSize: screen,
        ).ok,
        isTrue,
      );
      expect(
        ActionValidator.validate(
          action('open_app', {'package': 'not a package'}),
        ).ok,
        isFalse,
      );
      expect(
        ActionValidator.validate(action('shell', {'command': 'rm -rf'})).ok,
        isFalse,
      );
    });
  });

  group('AgentBudget loop limits', () {
    late DateTime now;

    AgentBudget build({
      int actions = 3,
      int inferences = 2,
      int seconds = 60,
    }) => AgentBudget(
      maxActions: actions,
      maxInferences: inferences,
      deadline: Duration(seconds: seconds),
      clock: () => now,
    );

    setUp(() => now = DateTime(2026, 1, 1, 10));

    test('stops at the action limit with an explicit reason', () {
      final budget = build(actions: 2);
      budget.recordAction(signature: 'a', screenChanged: true);
      budget.recordAction(signature: 'b', screenChanged: true);
      expect(budget.canExecuteAction, isFalse);
      expect(budget.stopReason, 'action_limit');
      expect(budget.describeStop(), contains('2 device actions'));
      expect(budget.canContinue, isFalse);
    });

    test('stops at the inference limit', () {
      final budget = build(inferences: 2);
      expect(budget.canPlan, isTrue);
      budget.recordPlan();
      expect(budget.canPlan, isTrue);
      budget.recordPlan();
      expect(budget.canPlan, isFalse);
      expect(budget.stopReason, 'inference_limit');
    });

    test('stops when the overall task deadline passes', () {
      final budget = build(seconds: 30);
      budget.recordPlan();
      now = now.add(const Duration(seconds: 31));
      expect(budget.canContinue, isFalse);
      expect(budget.stopReason, 'task_deadline');
    });

    test('stops when the identical action repeats with no screen change', () {
      final budget = build();
      final signature = 'tap(element=4)';
      budget.recordAction(signature: signature, screenChanged: false);
      expect(
        budget.stopReason,
        isNull,
        reason: 'the first no-effect action is allowed',
      );
      budget.recordAction(signature: signature, screenChanged: false);
      expect(budget.stopReason, 'repeated_action_no_effect');
      expect(budget.describeStop(), contains('same action repeated'));
    });

    test('stops after several different actions that change nothing', () {
      final budget = build();
      budget.recordAction(signature: 'a', screenChanged: false);
      budget.recordAction(signature: 'b', screenChanged: false);
      expect(budget.stopReason, isNull);
      budget.recordAction(signature: 'c', screenChanged: false);
      expect(budget.stopReason, 'screen_unchanged');
    });

    test('a successful action resets the no-effect counter', () {
      final budget = build();
      budget.recordAction(signature: 'a', screenChanged: false);
      budget.recordAction(signature: 'b', screenChanged: false);
      budget.recordAction(signature: 'c', screenChanged: true);
      budget.recordAction(signature: 'd', screenChanged: false);
      expect(budget.stopReason, isNull);
    });

    test('actions without an expected screen effect never trip stagnation', () {
      final budget = build();
      for (var i = 0; i < 5; i++) {
        budget.recordAction(
          signature: 'wait',
          screenChanged: false,
          affectsScreen: false,
        );
      }
      expect(budget.stopReason, isNull);
      expect(budget.actionsExecuted, 5);
    });

    test('allows exactly one retry of a failed action', () {
      final budget = build();
      final signature = 'tap(element=4)';
      expect(budget.canRetry(signature), isTrue);
      budget.recordAction(
        signature: signature,
        screenChanged: false,
        failed: true,
      );
      expect(budget.canRetry(signature), isFalse);
      budget.recordAction(signature: 'other', screenChanged: true);
      expect(budget.canRetry('other'), isTrue);
    });

    test('failed actions still count toward the action limit', () {
      final budget = build(actions: 2);
      budget.recordAction(signature: 'a', screenChanged: false, failed: true);
      budget.recordAction(signature: 'b', screenChanged: false, failed: true);
      expect(budget.canExecuteAction, isFalse);
      expect(budget.stopReason, 'action_limit');
    });
  });
}
