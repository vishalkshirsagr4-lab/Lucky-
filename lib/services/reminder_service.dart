import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReminderRecurrence { none, daily, weekly, weekdays }

class ReminderItem {
  ReminderItem({
    required this.id,
    required this.title,
    this.description,
    required this.scheduledTime,
    this.recurrence = ReminderRecurrence.none,
    this.isCompleted = false,
    DateTime? createdAt,
    this.category = 'general',
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String title;
  final String? description;
  final DateTime scheduledTime;
  final ReminderRecurrence recurrence;
  final bool isCompleted;
  final DateTime createdAt;
  final String category;

  ReminderItem copyWith({
    String? title,
    String? description,
    DateTime? scheduledTime,
    ReminderRecurrence? recurrence,
    bool? isCompleted,
    String? category,
  }) {
    return ReminderItem(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      recurrence: recurrence ?? this.recurrence,
      isCompleted: isCompleted ?? this.isCompleted,
      createdAt: createdAt,
      category: category ?? this.category,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'scheduledTime': scheduledTime.toIso8601String(),
    'recurrence': recurrence.name,
    'isCompleted': isCompleted,
    'createdAt': createdAt.toIso8601String(),
    'category': category,
  };

  factory ReminderItem.fromJson(Map<String, dynamic> json) {
    return ReminderItem(
      id: json['id'] as String,
      title: json['title'] as String,
      description: json['description'] as String?,
      scheduledTime: DateTime.parse(json['scheduledTime'] as String),
      recurrence: ReminderRecurrence.values.firstWhere(
        (r) => r.name == json['recurrence'],
        orElse: () => ReminderRecurrence.none,
      ),
      isCompleted: json['isCompleted'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      category: json['category'] as String? ?? 'general',
    );
  }
}

class ReminderService extends ChangeNotifier {
  static const _remindersPrefKey = 'lucy_reminders';
  final List<ReminderItem> _reminders = [];

  List<ReminderItem> get reminders => List.unmodifiable(_reminders);
  List<ReminderItem> get pendingReminders =>
      _reminders.where((r) => !r.isCompleted).toList(growable: false);
  List<ReminderItem> get completedReminders =>
      _reminders.where((r) => r.isCompleted).toList(growable: false);

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = prefs.getString(_remindersPrefKey);
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawJson) as List<dynamic>;
        _reminders.clear();
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            _reminders.add(ReminderItem.fromJson(item));
          }
        }
        _reminders.sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));
      } catch (e) {
        debugPrint('Failed to load reminders: $e');
      }
    }
    notifyListeners();
  }

  Future<ReminderItem> addReminder({
    required String title,
    required DateTime scheduledTime,
    String? description,
    ReminderRecurrence recurrence = ReminderRecurrence.none,
    String category = 'general',
  }) async {
    final item = ReminderItem(
      id: 'rem_${DateTime.now().millisecondsSinceEpoch}',
      title: title.trim(),
      description: description?.trim(),
      scheduledTime: scheduledTime,
      recurrence: recurrence,
      category: category.trim(),
    );
    _reminders.add(item);
    _reminders.sort((a, b) => a.scheduledTime.compareTo(b.scheduledTime));
    await _persist();
    notifyListeners();
    return item;
  }

  Future<bool> toggleCompletion(String id) async {
    final index = _reminders.indexWhere((r) => r.id == id);
    if (index == -1) return false;
    return markCompleted(id, !_reminders[index].isCompleted);
  }

  Future<void> clearCompletedReminders() async {
    _reminders.removeWhere((r) => r.isCompleted);
    await _persist();
    notifyListeners();
  }

  Future<bool> markCompleted(String id, bool completed) async {
    final index = _reminders.indexWhere((r) => r.id == id);
    if (index == -1) return false;

    _reminders[index] = _reminders[index].copyWith(isCompleted: completed);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<bool> deleteReminder(String id) async {
    final index = _reminders.indexWhere((r) => r.id == id);
    if (index == -1) return false;

    _reminders.removeAt(index);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<ReminderItem?> cancelByTitle(String titleQuery) async {
    final q = titleQuery.toLowerCase().trim();
    final index = _reminders.indexWhere(
      (r) => !r.isCompleted && r.title.toLowerCase().contains(q),
    );
    if (index == -1) return null;
    final removed = _reminders.removeAt(index);
    await _persist();
    notifyListeners();
    return removed;
  }

  Future<void> clearAll() async {
    _reminders.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_remindersPrefKey);
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_reminders.map((r) => r.toJson()).toList());
    await prefs.setString(_remindersPrefKey, encoded);
  }
}

class ParsedReminderResult {
  const ParsedReminderResult({
    required this.title,
    required this.scheduledTime,
    this.recurrence = ReminderRecurrence.none,
  });

  final String title;
  final DateTime scheduledTime;
  final ReminderRecurrence recurrence;

  DateTime get targetTime => scheduledTime;
}

class ReminderParser {
  static ParsedReminderResult? parseNaturalLanguage(
    String text, {
    DateTime? referenceTime,
  }) => parse(text, now: referenceTime);

  /// Parse natural language commands into a [ParsedReminderResult].
  /// Examples:
  /// - "remind me to study at 7 PM"
  /// - "remind me to call John tomorrow morning"
  /// - "create a daily reminder to revise DBMS at 9 AM"
  /// - "remind me in 30 minutes to drink water"
  static ParsedReminderResult? parse(String text, {DateTime? now}) {
    final baseNow = now ?? DateTime.now();
    final raw = text.trim().toLowerCase();

    var recurrence = ReminderRecurrence.none;
    if (raw.contains('daily') || raw.contains('every day')) {
      recurrence = ReminderRecurrence.daily;
    } else if (raw.contains('weekly') || raw.contains('every week')) {
      recurrence = ReminderRecurrence.weekly;
    } else if (raw.contains('weekdays') || raw.contains('every weekday')) {
      recurrence = ReminderRecurrence.weekdays;
    }

    // Pattern 1: "in X minutes/hours to [task]"
    final inTimeReg = RegExp(
      r'remind me in\s+(\d+)\s*(minute|min|hour|hr)s?\s*(?:to\s+)?(.*)',
    );
    final inMatch = inTimeReg.firstMatch(raw);
    if (inMatch != null) {
      final amount = int.tryParse(inMatch.group(1) ?? '0') ?? 0;
      final unit = inMatch.group(2) ?? 'min';
      final title = inMatch.group(3)?.trim() ?? 'Reminder';
      final scheduled = unit.startsWith('h')
          ? baseNow.add(Duration(hours: amount))
          : baseNow.add(Duration(minutes: amount));
      return ParsedReminderResult(
        title: _cleanTitle(title),
        scheduledTime: scheduled,
        recurrence: recurrence,
      );
    }

    // Pattern 2: "remind me [tomorrow / today] [morning/afternoon/evening/night] to [task]"
    final relativePeriodReg = RegExp(
      r'remind me (?:to\s+)?(.*?)\s+(tomorrow|today)\s*(morning|afternoon|evening|night)?',
    );
    final periodMatch = relativePeriodReg.firstMatch(raw);
    if (periodMatch != null && periodMatch.group(1)!.isNotEmpty) {
      final title = periodMatch.group(1)!;
      final dayStr = periodMatch.group(2)!;
      final periodStr = periodMatch.group(3);

      var scheduled = dayStr == 'tomorrow'
          ? baseNow.add(const Duration(days: 1))
          : baseNow;

      final hour = switch (periodStr) {
        'morning' => 9,
        'afternoon' => 14,
        'evening' => 18,
        'night' => 20,
        _ => 9,
      };

      scheduled = DateTime(
        scheduled.year,
        scheduled.month,
        scheduled.day,
        hour,
        0,
      );
      return ParsedReminderResult(
        title: _cleanTitle(title),
        scheduledTime: scheduled,
        recurrence: recurrence,
      );
    }

    // Pattern 3: "remind me to [task] at [time: 7 PM, 7:30 pm, 19:00]"
    final atTimeReg = RegExp(
      r'remind me (?:to\s+)?(.*?)\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?',
    );
    final atMatch = atTimeReg.firstMatch(raw);
    if (atMatch != null) {
      final title = atMatch.group(1)!;
      var hour = int.parse(atMatch.group(2)!);
      final minute = int.tryParse(atMatch.group(3) ?? '0') ?? 0;
      final amPm = atMatch.group(4);

      if (amPm == 'pm' && hour < 12) hour += 12;
      if (amPm == 'am' && hour == 12) hour = 0;

      var scheduled = DateTime(
        baseNow.year,
        baseNow.month,
        baseNow.day,
        hour,
        minute,
      );
      if (scheduled.isBefore(baseNow)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }

      return ParsedReminderResult(
        title: _cleanTitle(title),
        scheduledTime: scheduled,
        recurrence: recurrence,
      );
    }

    return null;
  }

  static String _cleanTitle(String raw) {
    var t = raw.trim();
    t = t.replaceAll(RegExp(r'^(to|that)\s+'), '');
    t = t.replaceAll(RegExp(r'[.!?]+$'), '');
    if (t.isEmpty) return 'Reminder';
    return t[0].toUpperCase() + t.substring(1);
  }
}
