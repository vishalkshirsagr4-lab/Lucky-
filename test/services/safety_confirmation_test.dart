import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/ai_service.dart';
import 'package:screen_aware_ai/services/safety_confirmation_service.dart';

void main() {
  late SafetyConfirmationService safetyService;

  setUp(() {
    safetyService = SafetyConfirmationService();
  });

  group('SafetyConfirmationService high-impact detection', () {
    test('detects send_message / SMS / email as high impact', () {
      final action = AgentAction(
        type: 'send_message',
        params: {'recipient': 'John', 'text': 'Hello'},
      );
      expect(safetyService.requiresConfirmation(action), isTrue);

      final confirmation = safetyService.createConfirmation(action);
      expect(confirmation.category, equals(HighImpactCategory.sendMessage));
      expect(confirmation.details['Recipient'], equals('John'));
      expect(confirmation.details['Message'], equals('Hello'));
    });

    test('detects delete_data as high impact', () {
      final action = AgentAction(
        type: 'delete_data',
        params: {'target': '/storage/data.txt'},
      );
      expect(safetyService.requiresConfirmation(action), isTrue);

      final confirmation = safetyService.createConfirmation(action);
      expect(confirmation.category, equals(HighImpactCategory.deleteData));
    });

    test('detects typing sensitive data into password fields', () {
      final action = AgentAction(type: 'type', params: {'text': 'secret123'});
      expect(
        safetyService.requiresConfirmation(
          action,
          focusedFieldHint: 'Enter your password',
        ),
        isTrue,
      );
    });

    test('regular click or read actions are not high impact', () {
      final action = AgentAction(type: 'click', params: {'x': 100, 'y': 200});
      expect(safetyService.requiresConfirmation(action), isFalse);
    });

    test('open regular app is not high impact', () {
      final action = AgentAction(
        type: 'open_app',
        params: {'package': 'com.android.calculator'},
      );
      expect(safetyService.requiresConfirmation(action), isFalse);
    });
  });

  group('SafetyConfirmationService confirmation lifecycle', () {
    test('requestConfirmation returns true when approved', () async {
      final action = AgentAction(
        type: 'send_message',
        params: {'recipient': 'Alice', 'text': 'On my way'},
      );
      final confirmation = safetyService.createConfirmation(action);
      final future = safetyService.requestConfirmation(confirmation);

      expect(safetyService.hasPendingConfirmation, isTrue);
      expect(
        safetyService.pendingConfirmation?.category,
        equals(HighImpactCategory.sendMessage),
      );

      // User approves
      safetyService.resolveConfirmation(true);

      final result = await future;
      expect(result, isTrue);
      expect(safetyService.hasPendingConfirmation, isFalse);
    });

    test('requestConfirmation returns false when rejected', () async {
      final action = AgentAction(
        type: 'delete_data',
        params: {'target': '/downloads'},
      );
      final confirmation = safetyService.createConfirmation(action);
      final future = safetyService.requestConfirmation(confirmation);

      expect(safetyService.hasPendingConfirmation, isTrue);

      // User rejects
      safetyService.resolveConfirmation(false);

      final result = await future;
      expect(result, isFalse);
      expect(safetyService.hasPendingConfirmation, isFalse);
    });

    test('cancelPending cancels with false', () async {
      final action = AgentAction(
        type: 'delete_data',
        params: {'target': 'all'},
      );
      final confirmation = safetyService.createConfirmation(action);
      final future = safetyService.requestConfirmation(confirmation);

      safetyService.cancelPending();

      final result = await future;
      expect(result, isFalse);
      expect(safetyService.hasPendingConfirmation, isFalse);
    });
  });
}
