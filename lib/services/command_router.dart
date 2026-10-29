import 'ai_service.dart';
import 'reminder_service.dart';

enum LocalCommandType {
  action,
  stop,
  cancel,
  repeat,
  sleep,
  time,
  reminder,
  listReminders,
  memory,
  searchMemory,
}

class LocalCommand {
  const LocalCommand(this.type, {this.action, this.label, this.params});

  final LocalCommandType type;
  final AgentAction? action;
  final String? label;
  final Map<String, dynamic>? params;
}

class LocalCommandRouter {
  const LocalCommandRouter();

  static const Map<String, String> _apps = {
    // English
    'youtube': 'com.google.android.youtube',
    'settings': 'com.android.settings',
    'chrome': 'com.android.chrome',
    'gmail': 'com.google.android.gm',
    'maps': 'com.google.android.apps.maps',
    'google maps': 'com.google.android.apps.maps',
    'camera': 'com.android.camera2',
    'calendar': 'com.google.android.calendar',
    'clock': 'com.google.android.deskclock',
    'calculator': 'com.google.android.calculator',
    'play store': 'com.android.vending',
    'photos': 'com.google.android.apps.photos',
    'whatsapp': 'com.whatsapp',
    'messages': 'com.google.android.apps.messaging',
    'phone': 'com.google.android.dialer',
    'files': 'com.google.android.apps.nbu.files',
    'contacts': 'com.google.android.contacts',
    'spotify': 'com.spotify.music',
    'instagram': 'com.instagram.android',
    'telegram': 'org.telegram.messenger',

    // Hindi app aliases
    'यूट्यूब': 'com.google.android.youtube',
    'सेटिंग्स': 'com.android.settings',
    'कैमरा': 'com.android.camera2',
    'व्हाट्सएप': 'com.whatsapp',
    'नक्शा': 'com.google.android.apps.maps',

    // Kannada app aliases
    'ಯೂಟ್ಯೂಬ್': 'com.google.android.youtube',
    'ಸೆಟ್ಟಿಂಗ್ಸ್': 'com.android.settings',
    'ಕ್ಯಾಮೆರಾ': 'com.android.camera2',
    'ವಾಟ್ಸಾಪ್': 'com.whatsapp',
  };

  LocalCommand? route(String command) {
    final raw = command.trim();
    if (raw.isEmpty) return null;

    final normalized = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ');

    // 1. Exact Navigation and UI actions (English, Hindi, Kannada)
    switch (normalized) {
      // Back
      case 'go back':
      case 'back':
      case 'navigate back':
      case 'पीछे जाओ':
      case 'वापस जाओ':
      case 'ಹಿಂದೆ ಹೋಗಿ':
      case 'ಹಿಂದೆ':
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(type: 'back'),
        );

      // Home
      case 'go home':
      case 'home':
      case 'home screen':
      case 'होम पर जाओ':
      case 'होम स्क्रीन':
      case 'ಮುಖಪುಟಕ್ಕೆ ಹೋಗಿ':
      case 'ಹೋಮ್':
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(type: 'home'),
        );

      // Stop listening
      case 'stop listening':
      case 'stop':
      case 'रुको':
      case 'सुनना बंद करो':
      case 'ಕೇಳುವುದನ್ನು ನಿಲ್ಲಿಸಿ':
      case 'ನಿಲ್ಲಿಸಿ':
      case 'ನಿಲ್ಲಿಸು':
        return const LocalCommand(LocalCommandType.stop);

      // Sleep
      case 'go to sleep':
      case 'sleep':
      case 'सो जाओ':
      case 'ನಿದ್ರಿಸಿ':
        return const LocalCommand(LocalCommandType.sleep);

      // Cancel
      case 'cancel':
      case 'cancel that':
      case 'रद्द करो':
      case 'ರದ್ದುಮಾಡಿ':
        return const LocalCommand(LocalCommandType.cancel);

      // Repeat
      case 'repeat that':
      case 'repeat':
      case 'फिर से बोलो':
      case 'ಮತ್ತೊಮ್ಮೆ ಹೇಳಿ':
        return const LocalCommand(LocalCommandType.repeat);

      // Time & Date
      case 'what time is it':
      case 'current time':
      case 'what is the time':
      case 'time':
      case 'date':
      case 'what day is it':
      case 'समय क्या हुआ है':
      case 'कितने बजे हैं':
      case 'ಸಮಯ ಎಷ್ಟು':
        return const LocalCommand(LocalCommandType.time);

      // List Reminders / Tasks
      case 'show my pending tasks':
      case 'show my tasks':
      case 'show tasks':
      case 'show my reminders':
      case 'my reminders':
      case 'my tasks':
      case 'मेरे काम दिखाओ':
      case 'टास्क दिखाओ':
      case 'ನನ್ನ ಕೆಲಸಗಳನ್ನು ತೋರಿಸಿ':
        return const LocalCommand(LocalCommandType.listReminders);
    }

    // 2. Reminder parsing (e.g. "remind me to...", "daily reminder to...")
    if (normalized.startsWith('remind me ') ||
        normalized.startsWith('create a reminder ') ||
        normalized.startsWith('daily reminder ')) {
      final parsed = ReminderParser.parse(normalized);
      if (parsed != null) {
        return LocalCommand(
          LocalCommandType.reminder,
          params: {
            'title': parsed.title,
            'scheduledTime': parsed.scheduledTime,
            'recurrence': parsed.recurrence,
          },
        );
      }
    }

    // 3. Memory storage (e.g. "remember that my coffee preference is latte", "याद रखो...", "ನೆನಪಿಡಿ...")
    const memoryPrefixes = [
      'remember that ',
      'remember ',
      'save to memory ',
      'याद रखो ',
      'ನೆನಪಿಡಿ ',
    ];
    for (final prefix in memoryPrefixes) {
      if (normalized.startsWith(prefix)) {
        final content = normalized.substring(prefix.length).trim();
        if (content.isNotEmpty) {
          return LocalCommand(
            LocalCommandType.memory,
            params: {'content': content},
          );
        }
      }
    }

    // Memory query (e.g. "what do you remember about coffee", "search memory for...")
    const memorySearchPrefixes = [
      'what do you remember about ',
      'what did i say about ',
      'search memory for ',
      'search memory ',
    ];
    for (final prefix in memorySearchPrefixes) {
      if (normalized.startsWith(prefix)) {
        final query = normalized.substring(prefix.length).trim();
        if (query.isNotEmpty) {
          return LocalCommand(
            LocalCommandType.searchMemory,
            params: {'query': query},
          );
        }
      }
    }

    // 4. App Launch (English prefix "open ", "launch "; Hindi suffix " खोलो"; Kannada suffix " ತೆರೆಯಿರಿ")
    const openPrefixes = ['open ', 'launch '];
    for (final prefix in openPrefixes) {
      if (normalized.startsWith(prefix)) {
        final app = normalized.substring(prefix.length).trim();
        final package = _apps[app];
        if (package != null) {
          return LocalCommand(
            LocalCommandType.action,
            action: AgentAction(type: 'open_app', params: {'package': package}),
            label: app,
          );
        }
      }
    }

    // Hindi app open ("यूट्यूब खोलो")
    if (normalized.endsWith(' खोलो') || normalized.endsWith(' खोलें')) {
      final app = normalized.replaceAll(RegExp(r'\s+(खोलो|खोलें)$'), '').trim();
      final package = _apps[app];
      if (package != null) {
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(type: 'open_app', params: {'package': package}),
          label: app,
        );
      }
    }

    // Kannada app open ("ಯೂಟ್ಯೂಬ್ ತೆರೆಯಿರಿ")
    if (normalized.endsWith(' ತೆರೆಯಿರಿ')) {
      final app = normalized.replaceAll(RegExp(r'\s+ತೆರೆಯಿರಿ$'), '').trim();
      final package = _apps[app];
      if (package != null) {
        return LocalCommand(
          LocalCommandType.action,
          action: AgentAction(type: 'open_app', params: {'package': package}),
          label: app,
        );
      }
    }

    return null;
  }
}
