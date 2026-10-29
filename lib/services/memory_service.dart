import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryEntry {
  MemoryEntry({
    required this.id,
    required this.content,
    this.category = 'general',
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String content;
  final String category;
  final DateTime createdAt;
  final DateTime updatedAt;

  DateTime get timestamp => createdAt;

  MemoryEntry copyWith({
    String? content,
    String? category,
    DateTime? updatedAt,
  }) {
    return MemoryEntry(
      id: id,
      content: content ?? this.content,
      category: category ?? this.category,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'category': category,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory MemoryEntry.fromJson(Map<String, dynamic> json) {
    return MemoryEntry(
      id: json['id'] as String,
      content: json['content'] as String,
      category: json['category'] as String? ?? 'general',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }
}

class MemoryService extends ChangeNotifier {
  static const _memoriesPrefKey = 'lucy_long_term_memories';
  static const _autoMemoryPrefKey = 'lucy_auto_memory_enabled';

  final List<MemoryEntry> _memories = [];
  bool _autoMemoryEnabled = true;

  List<MemoryEntry> get memories => List.unmodifiable(_memories);
  bool get autoMemoryEnabled => _autoMemoryEnabled;
  int get memoryCount => _memories.length;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _autoMemoryEnabled = prefs.getBool(_autoMemoryPrefKey) ?? true;

    final rawJson = prefs.getString(_memoriesPrefKey);
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawJson) as List<dynamic>;
        _memories.clear();
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            _memories.add(MemoryEntry.fromJson(item));
          }
        }
      } catch (e) {
        debugPrint('Failed to load memories: $e');
      }
    }
    notifyListeners();
  }

  Future<MemoryEntry> addMemory(
    String content, {
    String category = 'general',
  }) async {
    final entry = MemoryEntry(
      id: 'mem_${DateTime.now().millisecondsSinceEpoch}_${_memories.length}',
      content: content.trim(),
      category: category.trim(),
      createdAt: DateTime.now(),
    );
    _memories.insert(0, entry);
    await _persist();
    notifyListeners();
    return entry;
  }

  Future<bool> updateMemory(
    String id,
    String newContent, {
    String? category,
  }) async {
    final index = _memories.indexWhere((m) => m.id == id);
    if (index == -1) return false;

    _memories[index] = _memories[index].copyWith(
      content: newContent.trim(),
      category: category?.trim(),
      updatedAt: DateTime.now(),
    );
    await _persist();
    notifyListeners();
    return true;
  }

  Future<bool> deleteMemory(String id) async {
    final index = _memories.indexWhere((m) => m.id == id);
    if (index == -1) return false;

    _memories.removeAt(index);
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> clearAllMemories() async {
    _memories.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_memoriesPrefKey);
    notifyListeners();
  }

  Future<void> setAutoMemoryEnabled(bool enabled) async {
    _autoMemoryEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoMemoryPrefKey, enabled);
    notifyListeners();
  }

  List<MemoryEntry> search(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return List.unmodifiable(_memories);
    return _memories.where((m) {
      return m.content.toLowerCase().contains(q) ||
          m.category.toLowerCase().contains(q);
    }).toList(growable: false);
  }

  /// Compact summary for injection into the local LLM system prompt
  String getContextSummaryForPrompt({int limit = 5}) {
    if (_memories.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln('[User Saved Memories]');
    final subset = _memories.take(limit);
    for (final m in subset) {
      buffer.writeln('- (${m.category}) ${m.content}');
    }
    buffer.writeln('[/User Saved Memories]');
    return buffer.toString();
  }

  String exportDataAsJson() {
    final export = {
      'exportedAt': DateTime.now().toIso8601String(),
      'autoMemoryEnabled': _autoMemoryEnabled,
      'memories': _memories.map((m) => m.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(export);
  }

  Future<MemoryEntry> saveMemory(
    String content, {
    String category = 'general',
  }) =>
      addMemory(content, category: category);

  bool get autoExtractEnabled => _autoMemoryEnabled;

  Future<void> setAutoExtract(bool enabled) => setAutoMemoryEnabled(enabled);

  List<MemoryEntry> searchMemories(String query) => search(query);

  List<MemoryEntry> getMemoriesByCategory(String cat) {
    final c = cat.toLowerCase().trim();
    return _memories.where((m) => m.category.toLowerCase() == c).toList(growable: false);
  }

  String getPromptContextSummary({int limit = 5}) =>
      getContextSummaryForPrompt(limit: limit);

  String exportToJson() => exportDataAsJson();

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_memories.map((m) => m.toJson()).toList());
    await prefs.setString(_memoriesPrefKey, encoded);
  }
}
