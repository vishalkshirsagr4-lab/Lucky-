import 'ai_service.dart';
import 'observation.dart';
import 'task_verifier.dart';

/// A validated plan produced by one inference and reused across actions.
///
/// The plan is the unit of work the loop executes without asking the model
/// anything again: only when it is exhausted (or contradicted by new screen
/// evidence) does the pipeline plan anew.
class AgentPlan {
  AgentPlan({
    required this.actions,
    required this.speak,
    required this.done,
    required this.verify,
    required this.isValidated,
  });

  factory AgentPlan.fromResponse(AgentResponse response) => AgentPlan(
    actions: List<AgentAction>.unmodifiable(response.actions),
    speak: response.speak,
    done: response.done,
    verify: response.verify,
    isValidated: response.isValidated,
  );

  final List<AgentAction> actions;
  final String speak;
  final bool done;
  final VerifyCriteria? verify;
  final bool isValidated;

  int _cursor = 0;

  bool get exhausted => _cursor >= actions.length;
  int get remaining => actions.length - _cursor;
  int get total => actions.length;

  /// Next unexecuted action, advancing the cursor.
  AgentAction? takeNext() => exhausted ? null : actions[_cursor++];

  /// Put the last taken action back so exactly one safe retry can run.
  /// No-op when nothing has been taken yet.
  void retryLast() {
    if (_cursor > 0) _cursor--;
  }
}

/// Stable identity of an action for repeat/failure detection.
///
/// Two `tap`s of the same element collapse to the same signature, so the
/// budget can stop a loop that keeps performing the same no-effect action.
String actionSignature(AgentAction action) {
  if (action.params.isEmpty) return action.type;
  final keys = action.params.keys.toList()..sort();
  final parts = keys.map((key) => '$key=${action.params[key]}');
  return '${action.type}(${parts.join(',')})';
}

/// Configurable limits and loop-prevention rules for one task run.
///
/// Every stop reason is explicit so the controller can tell the user exactly
/// which budget was exhausted instead of silently ending the loop.
class AgentBudget {
  AgentBudget({
    required this.maxActions,
    required this.maxInferences,
    required this.deadline,
    this.maxConsecutiveNoEffect = 3,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxActions;
  final int maxInferences;
  final Duration deadline;
  final int maxConsecutiveNoEffect;
  final DateTime Function() _clock;

  DateTime? _startedAt;
  int actionsExecuted = 0;
  int inferences = 0;
  int _consecutiveNoEffect = 0;
  String? _lastActionSignature;
  final Map<String, int> _failures = <String, int>{};
  String? _stopReason;

  String? get stopReason => _stopReason;
  bool get stopped => _stopReason != null;

  bool _withinDeadline() {
    final started = _startedAt;
    if (started == null) return true;
    return _clock().difference(started) < deadline;
  }

  /// True until a limit, deadline, or loop-prevention rule trips.
  bool get canContinue {
    if (_stopReason != null) return false;
    if (!_withinDeadline()) {
      stop('task_deadline');
      return false;
    }
    return true;
  }

  /// Gate for one model inference.
  bool get canPlan {
    if (!canContinue) return false;
    if (inferences >= maxInferences) {
      stop('inference_limit');
      return false;
    }
    return true;
  }

  /// Gate for one device action.
  bool get canExecuteAction {
    if (!canContinue) return false;
    if (actionsExecuted >= maxActions) {
      stop('action_limit');
      return false;
    }
    return true;
  }

  /// Record that an inference was performed.
  void recordPlan() {
    _startedAt ??= _clock();
    inferences++;
  }

  /// Record a device action and apply the repeat/stagnation rules.
  ///
  /// [screenChanged] is the observed effect: false means the accessibility
  /// tree was identical before and after the action.
  /// [affectsScreen] is false for actions with no expected UI change (`wait`).
  void recordAction({
    required String signature,
    required bool screenChanged,
    bool affectsScreen = true,
    bool failed = false,
  }) {
    _startedAt ??= _clock();
    actionsExecuted++;
    if (failed) {
      _failures[signature] = (_failures[signature] ?? 0) + 1;
    }
    if (!affectsScreen) return;

    if (screenChanged) {
      _consecutiveNoEffect = 0;
      _lastActionSignature = signature;
      return;
    }

    _consecutiveNoEffect++;
    if (signature == _lastActionSignature) {
      // Identical action repeated with no observable effect: classic loop.
      stop('repeated_action_no_effect');
    } else if (_consecutiveNoEffect >= maxConsecutiveNoEffect) {
      stop('screen_unchanged');
    }
    _lastActionSignature = signature;
  }

  int failuresFor(String signature) => _failures[signature] ?? 0;

  /// A failed action may be retried at most once, and never when it already
  /// produced an irreversible effect (checked by the caller).
  bool canRetry(String signature) => failuresFor(signature) < 1;

  void stop(String reason) {
    _stopReason ??= reason;
  }

  /// User-facing explanation of why the loop ended.
  String describeStop() => switch (_stopReason) {
    null => '',
    'task_deadline' =>
      'Stopped: the task exceeded the ${deadline.inSeconds} second time limit.',
    'inference_limit' =>
      'Stopped: reached the limit of $maxInferences reasoning steps for this task.',
    'action_limit' =>
      'Stopped: reached the limit of $maxActions device actions for this task.',
    'repeated_action_no_effect' =>
      'Stopped: the same action repeated without changing the screen.',
    'screen_unchanged' =>
      'Stopped: the screen did not change after several actions.',
    _ => 'Stopped: $_stopReason.',
  };
}

class ActionValidation {
  const ActionValidation.accept() : ok = true, reason = null;
  const ActionValidation.reject(String this.reason) : ok = false;

  final bool ok;
  final String? reason;

  @override
  String toString() => ok ? 'accepted' : 'rejected: $reason';
}

/// Deterministic pre-execution validation.
///
/// Nothing runs unless it is a supported action whose target is proven to
/// exist in the current observation: element ids must resolve, coordinates
/// must be on-screen, and `type` needs a focused editable field.
class ActionValidator {
  const ActionValidator._();

  static const Set<String> screenActions = {
    'tap',
    'long_press',
    'double_tap',
    'type',
    'clear',
    'swipe',
    'back',
    'home',
    'open_app',
    'wait',
  };

  /// Actions that can never be blindly repeated after a failure because they
  /// may submit a form, duplicate input, or otherwise change data.
  static const Set<String> neverRetry = {'type', 'clear'};

  static const Set<String> gestureTypes = {'tap', 'long_press', 'double_tap'};

  static ActionValidation validate(
    AgentAction action, {
    UiSnapshot? snapshot,
    Map<String, int>? screenSize,
  }) {
    switch (action.type) {
      case 'open_app':
        final package = action.params['package'];
        if (package is! String ||
            !RegExp(r'^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$').hasMatch(package)) {
          return const ActionValidation.reject(
            'open_app needs a valid package',
          );
        }
        return const ActionValidation.accept();

      case 'back':
      case 'home':
      case 'wait':
      case 'clear':
      case 'create_reminder':
      case 'add_memory':
        return const ActionValidation.accept();

      case 'type':
        final text = action.params['text'];
        if (text is! String || text.isEmpty) {
          return const ActionValidation.reject('type needs non-empty text');
        }
        if (snapshot == null) {
          return const ActionValidation.reject(
            'no screen observation to confirm a focused input field',
          );
        }
        if (!snapshot.hasFocusedEditable) {
          return const ActionValidation.reject(
            'no focused input field is visible, so typing would be lost',
          );
        }
        return const ActionValidation.accept();

      case 'swipe':
        final coords = [
          action.params['startX'],
          action.params['startY'],
          action.params['endX'],
          action.params['endY'],
        ];
        if (coords.any((value) => value is! num)) {
          return const ActionValidation.reject(
            'swipe needs numeric coordinates',
          );
        }
        final width = screenSize?['width'];
        final height = screenSize?['height'];
        if (width != null && height != null) {
          final startX = (coords[0] as num).toDouble();
          final endX = (coords[2] as num).toDouble();
          final startY = (coords[1] as num).toDouble();
          final endY = (coords[3] as num).toDouble();
          if (startX >= width ||
              endX >= width ||
              startY >= height ||
              endY >= height) {
            return const ActionValidation.reject(
              'swipe coordinates fall outside the screen',
            );
          }
          if ((startX - endX).abs() < 8 && (startY - endY).abs() < 8) {
            return const ActionValidation.reject(
              'swipe distance is too small to scroll',
            );
          }
        }
        return const ActionValidation.accept();

      case 'tap':
      case 'long_press':
      case 'double_tap':
        final elementId = action.params['element'];
        if (elementId is! int || elementId < 0) {
          return ActionValidation.reject(
            '${action.type} needs an element id from the latest observation',
          );
        }
        if (snapshot == null) {
          return ActionValidation.reject(
            'no screen observation to resolve element $elementId',
          );
        }
        final element = snapshot.elementById(elementId);
        if (element == null) {
          return ActionValidation.reject(
            'element $elementId is not on the observed screen',
          );
        }
        if (element['enabled'] == false) {
          return ActionValidation.reject('element $elementId is disabled');
        }
        final interactive =
            element['clickable'] == true ||
            element['editable'] == true ||
            element['checkable'] == true ||
            element['scrollable'] == true ||
            element['focusable'] == true ||
            element['longClickable'] == true;
        if (!interactive) {
          return ActionValidation.reject(
            'element $elementId is not interactive',
          );
        }
        final bounds = element['bounds'];
        if (bounds is! Map) {
          return ActionValidation.reject('element $elementId has no bounds');
        }
        final width = screenSize?['width'];
        final height = screenSize?['height'];
        if (width != null && height != null) {
          final cx = bounds['cx'];
          final cy = bounds['cy'];
          if (cx is num && cy is num) {
            if (cx < 0 || cx >= width || cy < 0 || cy >= height) {
              return ActionValidation.reject(
                'element $elementId lies outside the screen',
              );
            }
          }
        }
        return const ActionValidation.accept();

      default:
        return ActionValidation.reject('unsupported action "${action.type}"');
    }
  }
}
