import 'dart:async';
import 'package:flutter/foundation.dart';

/// Structured result returned from every tool execution.
class ToolResult {
  const ToolResult({
    required this.success,
    required this.action,
    required this.verified,
    required this.message,
    this.data = const {},
  });

  final bool success;
  final String action;
  final bool verified;
  final String message;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
    'success': success,
    'action': action,
    'verified': verified,
    'message': message,
    'data': data,
  };

  @override
  String toString() =>
      'ToolResult(action: $action, success: $success, verified: $verified, message: "$message")';
}

/// Definition of a tool in the controlled tool registry.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parametersSchema,
    required this.requiredParameters,
    this.requiresPermission = false,
    this.timeout = const Duration(seconds: 5),
  });

  final String name;
  final String description;
  final Map<String, String> parametersSchema;
  final List<String> requiredParameters;
  final bool requiresPermission;
  final Duration timeout;

  bool validateParameters(
    Map<String, dynamic> params,
    StringBuffer errorReason,
  ) {
    for (final req in requiredParameters) {
      if (!params.containsKey(req) || params[req] == null) {
        errorReason.write('Missing required parameter: "$req". ');
        return false;
      }
    }
    return true;
  }
}

/// Central controlled tool registry for safe assistant execution.
class ToolRegistry {
  static const Map<String, ToolDefinition> tools = {
    'open_app': ToolDefinition(
      name: 'open_app',
      description: 'Launch an installed application by package name',
      parametersSchema: {
        'package': 'Android package name, e.g. com.google.android.youtube',
      },
      requiredParameters: ['package'],
    ),
    'tap': ToolDefinition(
      name: 'tap',
      description:
          'Perform a single tap gesture at normalized or pixel screen coordinates',
      parametersSchema: {
        'x': 'X coordinate (pixel or 0.0-1.0)',
        'y': 'Y coordinate (pixel or 0.0-1.0)',
      },
      requiredParameters: ['x', 'y'],
      requiresPermission: true,
      timeout: Duration(seconds: 4),
    ),
    'long_press': ToolDefinition(
      name: 'long_press',
      description: 'Perform a long press gesture at coordinates',
      parametersSchema: {'x': 'X coordinate', 'y': 'Y coordinate'},
      requiredParameters: ['x', 'y'],
      requiresPermission: true,
      timeout: Duration(seconds: 4),
    ),
    'double_tap': ToolDefinition(
      name: 'double_tap',
      description: 'Perform a double tap gesture at coordinates',
      parametersSchema: {'x': 'X coordinate', 'y': 'Y coordinate'},
      requiredParameters: ['x', 'y'],
      requiresPermission: true,
      timeout: Duration(seconds: 5),
    ),
    'type': ToolDefinition(
      name: 'type',
      description: 'Type text into the currently focused editable input field',
      parametersSchema: {'text': 'String to type'},
      requiredParameters: ['text'],
      requiresPermission: true,
    ),
    'clear': ToolDefinition(
      name: 'clear',
      description: 'Clear text from the currently focused editable input field',
      parametersSchema: {},
      requiredParameters: [],
      requiresPermission: true,
    ),
    'swipe': ToolDefinition(
      name: 'swipe',
      description:
          'Perform a swipe gesture from start coordinates to end coordinates',
      parametersSchema: {
        'startX': 'Start X coordinate',
        'startY': 'Start Y coordinate',
        'endX': 'End X coordinate',
        'endY': 'End Y coordinate',
      },
      requiredParameters: ['startX', 'startY', 'endX', 'endY'],
      requiresPermission: true,
      timeout: Duration(seconds: 4),
    ),
    'back': ToolDefinition(
      name: 'back',
      description:
          'Navigate back to the previous screen using Android global Back',
      parametersSchema: {},
      requiredParameters: [],
      requiresPermission: true,
    ),
    'home': ToolDefinition(
      name: 'home',
      description: 'Return to the Android home screen',
      parametersSchema: {},
      requiredParameters: [],
      requiresPermission: true,
    ),
    'wait': ToolDefinition(
      name: 'wait',
      description:
          'Wait for UI transitions or animations to settle (in milliseconds)',
      parametersSchema: {'ms': 'Milliseconds to pause (maximum 5000)'},
      requiredParameters: ['ms'],
      timeout: Duration(seconds: 6),
    ),
    'create_reminder': ToolDefinition(
      name: 'create_reminder',
      description: 'Create and persist a scheduled reminder or task locally',
      parametersSchema: {
        'title': 'Task or reminder title',
        'scheduledTime': 'ISO 8601 formatted datetime string',
        'recurrence': 'none, daily, weekly, or weekdays',
      },
      requiredParameters: ['title', 'scheduledTime'],
    ),
    'list_reminders': ToolDefinition(
      name: 'list_reminders',
      description:
          'Retrieve pending or completed scheduled reminders and tasks',
      parametersSchema: {
        'completed': 'Boolean (true for completed, false for pending)',
      },
      requiredParameters: [],
    ),
    'complete_reminder': ToolDefinition(
      name: 'complete_reminder',
      description: 'Mark a scheduled reminder as completed',
      parametersSchema: {'id': 'Unique reminder ID'},
      requiredParameters: ['id'],
    ),
    'add_memory': ToolDefinition(
      name: 'add_memory',
      description:
          'Store a personal fact or preference in long-term local memory',
      parametersSchema: {
        'content': 'Information to remember',
        'category': 'personal, preference, work, fact',
      },
      requiredParameters: ['content'],
    ),
    'search_memory': ToolDefinition(
      name: 'search_memory',
      description:
          'Search user long-term local memory for facts or preferences',
      parametersSchema: {'query': 'Search query string'},
      requiredParameters: ['query'],
    ),
    'get_time': ToolDefinition(
      name: 'get_time',
      description: 'Get current local date and time',
      parametersSchema: {},
      requiredParameters: [],
    ),
  };

  /// Returns system prompt documentation of all allowed tools for the local LLM.
  static String getPromptToolDocumentation() {
    final buffer = StringBuffer();
    buffer.writeln(
      'SUPPORTED TOOLS (Format exactly as {"type": "tool_name", ...params}):',
    );
    for (final entry in tools.entries) {
      final t = entry.value;
      buffer.write('- ${t.name}: ${t.description}. Params: ');
      if (t.parametersSchema.isEmpty) {
        buffer.writeln('none');
      } else {
        buffer.writeln(t.parametersSchema.keys.join(', '));
      }
    }
    return buffer.toString();
  }
}
