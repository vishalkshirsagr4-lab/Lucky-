import 'package:flutter_test/flutter_test.dart';
import 'package:screen_aware_ai/services/command_router.dart';

void main() {
  const router = LocalCommandRouter();

  group('CommandRouter extended multilingual and tool routing tests', () {
    test('routes time query', () {
      final match = router.route('what time is it');
      expect(match, isNotNull);
      expect(match!.type, equals(LocalCommandType.time));

      final match2 = router.route('current time');
      expect(match2, isNotNull);
      expect(match2!.type, equals(LocalCommandType.time));
    });

    test('routes reminder command', () {
      final match = router.route('remind me to call Mom at 5 PM');
      expect(match, isNotNull);
      expect(match!.type, equals(LocalCommandType.reminder));
      expect(match.params!['title'].toString().toLowerCase(), contains('call mom'));

      final match2 = router.route('remind me in 15 minutes to turn off stove');
      expect(match2, isNotNull);
      expect(match2!.type, equals(LocalCommandType.reminder));
    });

    test('routes memory store and query commands', () {
      final matchStore = router.route('remember that my favorite color is navy');
      expect(matchStore, isNotNull);
      expect(matchStore!.type, equals(LocalCommandType.memory));
      expect(matchStore.params!['content'], equals('my favorite color is navy'));

      final matchQuery = router.route('what do you remember about color');
      expect(matchQuery, isNotNull);
      expect(matchQuery!.type, equals(LocalCommandType.searchMemory));
      expect(matchQuery.params!['query'], equals('color'));
    });

    test('routes Hindi command aliases', () {
      // YouTube open
      final match1 = router.route('यूट्यूब खोलो');
      expect(match1, isNotNull);
      expect(match1!.type, equals(LocalCommandType.action));
      expect(match1.action?.params['package'], equals('com.google.android.youtube'));

      // Go home
      final match2 = router.route('होम पर जाओ');
      expect(match2, isNotNull);
      expect(match2!.type, equals(LocalCommandType.action));
      expect(match2.action?.type, equals('home'));

      // Go back
      final match3 = router.route('पीछे जाओ');
      expect(match3, isNotNull);
      expect(match3!.type, equals(LocalCommandType.action));
      expect(match3.action?.type, equals('back'));

      // Stop
      final match4 = router.route('रुको');
      expect(match4, isNotNull);
      expect(match4!.type, equals(LocalCommandType.stop));
    });

    test('routes Kannada command aliases', () {
      // YouTube open
      final match1 = router.route('ಯೂಟ್ಯೂಬ್ ತೆರೆಯಿರಿ');
      expect(match1, isNotNull);
      expect(match1!.type, equals(LocalCommandType.action));
      expect(match1.action?.params['package'], equals('com.google.android.youtube'));

      // Go home
      final match2 = router.route('ಮುಖಪುಟಕ್ಕೆ ಹೋಗಿ');
      expect(match2, isNotNull);
      expect(match2!.type, equals(LocalCommandType.action));
      expect(match2.action?.type, equals('home'));

      // Go back
      final match3 = router.route('ಹಿಂದೆ ಹೋಗಿ');
      expect(match3, isNotNull);
      expect(match3!.type, equals(LocalCommandType.action));
      expect(match3.action?.type, equals('back'));

      // Stop
      final match4 = router.route('ನಿಲ್ಲಿಸಿ');
      expect(match4, isNotNull);
      expect(match4!.type, equals(LocalCommandType.stop));
    });
  });
}
