import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_aware_ai/services/memory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryService memoryService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    memoryService = MemoryService();
    await memoryService.initialize();
  });

  group('MemoryService tests', () {
    test('starts with empty memories', () {
      expect(memoryService.memories, isEmpty);
      expect(memoryService.getPromptContextSummary(), isEmpty);
    });

    test('can save a memory and persist it', () async {
      final entry = await memoryService.saveMemory(
        'User prefers dark mode and coffee in the morning',
        category: 'User Preferences',
      );

      expect(entry.id, isNotEmpty);
      expect(entry.content, contains('dark mode'));
      expect(entry.category, equals('User Preferences'));
      expect(memoryService.memories.length, equals(1));

      // Test prompt context summary
      final summary = memoryService.getPromptContextSummary();
      expect(summary, contains('(User Preferences)'));
      expect(summary, contains('dark mode'));
    });

    test('search finds matching memories by keyword and category', () async {
      await memoryService.saveMemory('Favorite music app is Spotify', category: 'App Facts');
      await memoryService.saveMemory('Mom birthday is on July 14', category: 'Personal');
      await memoryService.saveMemory('Work laptop password hint is blue sky', category: 'Other');

      final musicResults = memoryService.searchMemories('spotify');
      expect(musicResults.length, equals(1));
      expect(musicResults.first.category, equals('App Facts'));

      final categoryResults = memoryService.getMemoriesByCategory('Personal');
      expect(categoryResults.length, equals(1));
      expect(categoryResults.first.content, contains('Mom birthday'));
    });

    test('can update an existing memory', () async {
      final saved = await memoryService.saveMemory('I like tea', category: 'User Preferences');
      await memoryService.updateMemory(saved.id, 'I prefer green tea over black tea');

      expect(memoryService.memories.first.content, equals('I prefer green tea over black tea'));
      expect(memoryService.memories.first.id, equals(saved.id));
    });

    test('can delete memory and clear all', () async {
      final m1 = await memoryService.saveMemory('Memory one');
      final m2 = await memoryService.saveMemory('Memory two');
      expect(memoryService.memories.length, equals(2));

      await memoryService.deleteMemory(m1.id);
      expect(memoryService.memories.length, equals(1));
      expect(memoryService.memories.first.id, equals(m2.id));

      await memoryService.clearAllMemories();
      expect(memoryService.memories, isEmpty);
    });

    test('exports memories as valid JSON', () async {
      await memoryService.saveMemory('Test memory content', category: 'Personal');
      final jsonStr = memoryService.exportToJson();
      final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list = decoded['memories'] as List;

      expect(list.length, equals(1));
      expect(list.first['content'], equals('Test memory content'));
      expect(list.first['category'], equals('Personal'));
    });

    test('toggle auto extract setting persists', () async {
      expect(memoryService.autoExtractEnabled, isTrue);
      await memoryService.setAutoExtract(false);
      expect(memoryService.autoExtractEnabled, isFalse);

      // Verify persistence by re-initializing new service instance with same mock storage
      final newService = MemoryService();
      await newService.initialize();
      expect(newService.autoExtractEnabled, isFalse);
    });
  });
}
