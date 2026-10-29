import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/reminder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ReminderService reminderService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    reminderService = ReminderService();
    await reminderService.initialize();
  });

  group('ReminderParser natural language tests', () {
    test('parses "in 15 minutes"', () {
      final now = DateTime(2026, 1, 1, 12, 0);
      final parsed = ReminderParser.parseNaturalLanguage('remind me in 15 minutes to turn off stove', referenceTime: now);

      expect(parsed, isNotNull);
      expect(parsed!.title.toLowerCase(), contains('turn off stove'));
      expect(parsed.targetTime.difference(now).inMinutes, equals(15));
    });

    test('parses "in 2 hours"', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      final parsed = ReminderParser.parseNaturalLanguage('remind me in 2 hours to call dentist', referenceTime: now);

      expect(parsed, isNotNull);
      expect(parsed!.title.toLowerCase(), contains('call dentist'));
      expect(parsed.targetTime.difference(now).inHours, equals(2));
    });

    test('parses "at 5 PM"', () {
      final now = DateTime(2026, 1, 1, 10, 0);
      final parsed = ReminderParser.parseNaturalLanguage('remind me to water plants at 5 PM', referenceTime: now);

      expect(parsed, isNotNull);
      expect(parsed!.title.toLowerCase(), contains('water plants'));
      expect(parsed.targetTime.hour, equals(17));
      expect(parsed.targetTime.minute, equals(0));
    });

    test('parses "at 9:30 AM"', () {
      final now = DateTime(2026, 1, 1, 8, 0);
      final parsed = ReminderParser.parseNaturalLanguage('remind me to join standup meeting at 9:30 AM', referenceTime: now);

      expect(parsed, isNotNull);
      expect(parsed!.title.toLowerCase(), contains('join standup meeting'));
      expect(parsed.targetTime.hour, equals(9));
      expect(parsed.targetTime.minute, equals(30));
    });

    test('parses "tomorrow morning"', () {
      final now = DateTime(2026, 1, 1, 15, 0);
      final parsed = ReminderParser.parseNaturalLanguage('remind me to buy milk tomorrow morning', referenceTime: now);

      expect(parsed, isNotNull);
      expect(parsed!.title.toLowerCase(), contains('buy milk'));
      expect(parsed.targetTime.day, equals(2));
      expect(parsed.targetTime.hour, equals(9));
    });

    test('parses "tonight"', () {
      final now = DateTime(2026, 1, 1, 12, 0);
      final parsed = ReminderParser.parseNaturalLanguage('remind me to watch movie today night', referenceTime: now);

      expect(parsed, isNotNull);
      expect(parsed!.title.toLowerCase(), contains('watch movie'));
      expect(parsed.targetTime.hour, equals(20));
    });
  });

  group('ReminderService operational tests', () {
    test('addReminder adds to pending list', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final item = await reminderService.addReminder(
        title: 'Take vitamins',
        scheduledTime: scheduled,
      );

      expect(item.id, isNotEmpty);
      expect(item.title, equals('Take vitamins'));
      expect(item.isCompleted, isFalse);
      expect(reminderService.pendingReminders.length, equals(1));
      expect(reminderService.completedReminders, isEmpty);
    });

    test('toggleCompletion moves reminder between pending and completed', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final item = await reminderService.addReminder(
        title: 'Call Mom',
        scheduledTime: scheduled,
      );

      await reminderService.toggleCompletion(item.id);
      expect(reminderService.pendingReminders, isEmpty);
      expect(reminderService.completedReminders.length, equals(1));

      // Toggle back
      await reminderService.toggleCompletion(item.id);
      expect(reminderService.pendingReminders.length, equals(1));
      expect(reminderService.completedReminders, isEmpty);
    });

    test('deleteReminder removes item', () async {
      final scheduled = DateTime.now().add(const Duration(hours: 1));
      final item = await reminderService.addReminder(
        title: 'Meeting',
        scheduledTime: scheduled,
      );
      expect(reminderService.reminders.length, equals(1));

      await reminderService.deleteReminder(item.id);
      expect(reminderService.reminders, isEmpty);
    });

    test('clearCompletedReminders removes only completed', () async {
      final now = DateTime.now();
      final item1 = await reminderService.addReminder(
        title: 'Item 1',
        scheduledTime: now.add(const Duration(hours: 1)),
      );
      await reminderService.addReminder(
        title: 'Item 2',
        scheduledTime: now.add(const Duration(hours: 2)),
      );

      await reminderService.toggleCompletion(item1.id);
      expect(reminderService.completedReminders.length, equals(1));
      expect(reminderService.pendingReminders.length, equals(1));

      await reminderService.clearCompletedReminders();
      expect(reminderService.completedReminders, isEmpty);
      expect(reminderService.pendingReminders.length, equals(1));
      expect(reminderService.pendingReminders.first.title, equals('Item 2'));
    });
  });
}
