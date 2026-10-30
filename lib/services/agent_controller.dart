import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'command_router.dart';
import 'local_model_service.dart';
import 'memory_service.dart';
import 'reminder_service.dart';
import 'safety_confirmation_service.dart';
import 'voice_service.dart';
import 'screen_capture_service.dart';
import 'agent_plan.dart';
import 'observation.dart';
import 'pipeline_profiler.dart';
import 'task_verifier.dart';

enum AgentState {
  idle,
  listening,
  capturing,
  analyzing,
  speaking,
  waitingConfirmation,
  executingAction,
}

class ConversationEntry {
  final String text;
  final bool isUser;
  final Uint8List? screenshotBytes;
  final DateTime timestamp;

  ConversationEntry({
    required this.text,
    required this.isUser,
    this.screenshotBytes,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class _ActionExecutionResult {
  const _ActionExecutionResult(
    this.snapshot,
    this.succeeded, {
    this.dispatchMs = 0,
    this.waitMs = 0,
  });

  final UiSnapshot? snapshot;
  final bool succeeded;

  /// Time spent dispatching the gesture/node action itself.
  final int dispatchMs;

  /// Time spent polling the accessibility tree for the resulting change.
  final int waitMs;
}

class AgentController extends ChangeNotifier with WidgetsBindingObserver {
  AgentController() {
    WidgetsBinding.instance.addObserver(this);
    _localModel.addListener(_onLocalModelChanged);
  }

  final VoiceService _voiceService = VoiceService();
  final ScreenCaptureManager _screenCapture = ScreenCaptureManager();
  final LocalCommandRouter _commandRouter = LocalCommandRouter();
  final MemoryService _memoryService = MemoryService();
  final ReminderService _reminderService = ReminderService();
  final SafetyConfirmationService _safetyConfirmation =
      SafetyConfirmationService();
  late final LocalModelService _localModel = LocalModelService(_screenCapture);
  late final AiService _aiService = AiService(_localModel);

  MemoryService get memoryService => _memoryService;
  ReminderService get reminderService => _reminderService;
  SafetyConfirmationService get safetyConfirmation => _safetyConfirmation;

  AgentState _state = AgentState.idle;
  AgentState get state => _state;

  final List<ConversationEntry> _conversation = [];
  List<ConversationEntry> get conversation => List.unmodifiable(_conversation);

  String _statusMessage =
      'Use a text command or start manual foreground listening.';
  String get statusMessage => _statusMessage;

  Uint8List? _lastScreenshotBytes;
  Uint8List? get lastScreenshotBytes => _lastScreenshotBytes;

  String? _currentTranscript = '';
  String? get currentTranscript => _currentTranscript;

  /// When the current recognizer session started, for speech-stage timing.
  DateTime? _listenStartedAt;

  bool _isActive = false;
  bool get isActive => _isActive;

  int _listenRetryCount = 0;
  static const int _maxListenRetries = 3;

  /// Tunable from the Settings screen, persisted to SharedPreferences.
  Future<void> setMaxActionsPerTask(int actions) async {
    if (actions < 1 || actions > 40) {
      throw ArgumentError.value(actions, 'actions', 'Use 1 to 40.');
    }
    _maxActions = actions;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_maxActionsKey, actions);
    notifyListeners();
  }

  Future<void> setMaxInferencesPerTask(int steps) async {
    if (steps < 1 || steps > 20) {
      throw ArgumentError.value(steps, 'steps', 'Use 1 to 20.');
    }
    _maxInferences = steps;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_maxInferencesKey, steps);
    notifyListeners();
  }

  Future<void> setTaskDeadline(Duration deadline) async {
    final seconds = deadline.inSeconds;
    if (seconds < 15 || seconds > 600) {
      throw ArgumentError.value(deadline, 'deadline', '15 to 600 seconds.');
    }
    _taskDeadline = deadline;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_taskDeadlineKey, seconds);
    notifyListeners();
  }

  Future<void> setInferenceTimeout(Duration timeout) async {
    final seconds = timeout.inSeconds;
    if (seconds < 10 || seconds > 180) {
      throw ArgumentError.value(timeout, 'timeout', '10 to 180 seconds.');
    }
    _inferenceTimeout = timeout;
    _aiService.inferenceTimeout = _inferenceTimeout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_inferenceTimeoutKey, seconds);
    notifyListeners();
  }

  /// Configurable task limits (seconds/actions/steps), read from preferences
  /// in [initialize] so they can be tuned without a code change.
  static const String _maxActionsKey = 'lucy_max_actions';
  static const String _maxInferencesKey = 'lucy_max_inferences';
  static const String _taskDeadlineKey = 'lucy_task_deadline_seconds';
  static const String _inferenceTimeoutKey = 'lucy_inference_timeout_seconds';

  static const int _defaultMaxActions = 12;
  static const int _defaultMaxInferences = 8;
  static const Duration _defaultTaskDeadline = Duration(minutes: 2);
  static const Duration _defaultInferenceTimeout = Duration(seconds: 60);

  int _maxActions = _defaultMaxActions;
  int _maxInferences = _defaultMaxInferences;
  Duration _taskDeadline = _defaultTaskDeadline;
  Duration _inferenceTimeout = _defaultInferenceTimeout;

  int get maxActionsPerTask => _maxActions;
  int get maxInferencesPerTask => _maxInferences;
  Duration get taskDeadline => _taskDeadline;
  Duration get inferenceTimeout => _inferenceTimeout;

  /// Tunable from the Settings screen, persisted to SharedPreferences.
    final seconds = timeout.inSeconds;
    if (seconds < 10 || seconds > 180) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Must be between 10 and 180 seconds.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_inferenceTimeoutKey, seconds);
    _inferenceTimeout = Duration(seconds: seconds);
    _aiService.inferenceTimeout = _inferenceTimeout;
    notifyListeners();
  }

  static const Duration _uiPollInterval = Duration(milliseconds: 120);
  static const Duration _tapReadyTimeout = Duration(milliseconds: 900);
  static const Duration _typeReadyTimeout = Duration(milliseconds: 900);
  static const Duration _navigationReadyTimeout = Duration(milliseconds: 1200);
  static const Duration _openAppReadyTimeout = Duration(milliseconds: 2500);
  static const int _maxVerificationRecoveries = 2;

  /// Screen observations are cached so one action cycle reads the tree once.
  late final ScreenObserver _observer = ScreenObserver(
    fetchTree: _screenCapture.getUITree,
  );

  /// Hard guard: only one observe → plan → execute → verify loop may run.
  bool _loopRunning = false;
  bool get isLoopRunning => _loopRunning;

  bool _cancelRequested = false;

  bool _isAskingForFurtherHelp = false;
  String? _lastAssistantResponse;
  String _streamingStatus = '';
  int _requestSequence = 0;
  bool _isVoiceReady = false;
  Timer? _followupTimeoutTimer;
  Duration _followupTimeout = const Duration(minutes: 2);
  static const String _historyPrefKey = 'lucy_conversation_history';
  static const int _maxHistoryEntries = 100;
  Future<void> _historyWrite = Future<void>.value();

  /// Language code of the most recent agent reply ("en" or "ja").
  /// Used to localize hardcoded follow-ups, cancel-word detection, TTS, and STT locale.
  String _currentLang = 'en';
  String get currentLang => _currentLang;

  static const String _langPrefKey = 'lucy_lang';
  static const Set<String> _supportedLangs = {'en', 'ja', 'ar'};

  /// Set the UI/voice language. Persists across restarts. Restarts the
  /// listener if currently active so STT picks up the new locale.
  Future<void> setLanguage(String lang) async {
    final normalized = lang.toLowerCase();
    if (!_supportedLangs.contains(normalized)) return;
    if (_currentLang == normalized) return;
    _currentLang = normalized;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_langPrefKey, normalized);
    if (_isActive && _state == AgentState.listening) {
      await _voiceService.stopListening();
      _startListening();
    }
  }

  Future<void> setSpeechRate(double rate) async {
    await _voiceService.setSpeechRate(rate);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lucy_speech_rate', rate);
    notifyListeners();
  }

  Future<void> setFollowupTimeout(Duration timeout) async {
    if (timeout < const Duration(seconds: 15) ||
        timeout > const Duration(minutes: 10)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'Must be between 15 seconds and 10 minutes',
      );
    }
    _followupTimeout = timeout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('lucy_followup_timeout_seconds', timeout.inSeconds);
    _followupTimeoutTimer?.cancel();
    _followupTimeoutTimer = null;
    if (_isActive && _isAskingForFurtherHelp) {
      _scheduleFollowupTimeout();
    }
    notifyListeners();
  }

  /// Estimated agent loop budget seen on the Settings screen for the current
  /// run: action limit, inference budget, task time limit, and generation
  /// timeout. These mirror the SharedPreferences keys so a planned run can
  /// be described in advance.
  String get loopLimitsSummary =>
      '${_maxActionsPerTask}/${_maxInferencesPerTask} actions·steps '
      'in ${_taskDeadline.inSeconds}s, gen ${_inferenceTimeout.inSeconds}s';

  static const Map<String, String> _followUps = {
    'en': 'Do you need any further help?',
    'ja': '他に何かお手伝いできることはありますか？',
    'ar': 'هل تحتاج إلى أي مساعدة أخرى؟',
  };
  static const Map<String, String> _stoppingMessages = {
    'en': 'Alright, stopping the agent.',
    'ja': 'わかりました。エージェントを停止します。',
    'ar': 'حسنًا، سأوقف المساعد الآن.',
  };

  // Patterns that mean "no, I'm done" when replying to the follow-up prompt.
  static final RegExp _negativeEn = RegExp(
    r'^(no|nope|nah|stop|exit|nothing|not\b.*)$',
  );
  // Hiragana/katakana/kanji forms of "no", "stop", "that's enough", "done".
  static final RegExp _negativeJa = RegExp(
    r'(いいえ|いえ|けっこう|結構|もういい|もう大丈夫|大丈夫|終了|終わり|やめて|止めて|停止|いらない|不要|ない)',
  );
  // Arabic forms: "no", "stop", "enough", "done", "nothing".
  static final RegExp _negativeAr = RegExp(
    r'(لا|كلا|توقف|قف|اوقف|أوقف|اكتفي|يكفي|كفى|انتهى|انتهيت|خلاص|لا شيء|لا شكرا|لا شكرًا)',
  );

  AiService get aiService => _aiService;
  LocalModelService get localModel => _localModel;
  ScreenCaptureManager get screenCapture => _screenCapture;
  bool get speechRecognitionReady => _isVoiceReady;
  String get microphoneStatus => _voiceService.isListening
      ? 'Active in the current app session'
      : 'Not active; Android permission is requested when voice starts';
  double get speechRate => _voiceService.speechRate;
  Duration get followupTimeout => _followupTimeout;
  String get wakeWordStatus =>
      'Unavailable: no offline wake-word engine installed';
  String get backgroundListeningStatus =>
      'Unavailable: voice input is manual and stops outside the active app session';

  /// Whether a cancel has been requested by the user.
  bool get cancelRequested => _cancelRequested;

  /// Force-stop the current agent loop immediately.
  void requestCancel() {
    _cancelRequested = true;
    _aiService.cancelLocalGeneration();
    _voiceService.stopSpeaking();
    notifyListeners();
  }

  Future<bool> selectLocalModel() async => _localModel.selectModel();
  Future<void> loadLocalModel() => _localModel.loadModel();
  Future<void> unloadLocalModel() => _localModel.unloadModel();
  Future<void> setProviderMode(AiProviderMode mode) =>
      _aiService.setProviderMode(mode);
  Future<void> setCloudFallbackEnabled(bool enabled) =>
      _aiService.setCloudFallbackEnabled(enabled);
  Future<void> setAllowGeminiData(bool enabled) =>
      _aiService.setAllowGeminiData(enabled);

  void _onLocalModelChanged() => notifyListeners();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _cancelForBackground();
    }
  }

  @override
  void didHaveMemoryPressure() => _cancelForBackground();

  void _cancelForBackground() {
    if (_isActive) requestCancel();
    unawaited(_voiceService.stopListening());
    if (_localModel.state == LocalModelState.ready ||
        _localModel.state == LocalModelState.generating ||
        _localModel.state == LocalModelState.inferenceFailed) {
      unawaited(_localModel.unloadModel().catchError((_) {}));
    }
  }

  Future<void> initialize() async {
    await _aiService.initialize();
    await _memoryService.initialize();
    await _reminderService.initialize();
    final prefs = await SharedPreferences.getInstance();
    final savedLang = prefs.getString(_langPrefKey);
    if (savedLang != null && _supportedLangs.contains(savedLang)) {
      _currentLang = savedLang;
    }

    // Configurable loop limits with safe bounds; invalid values fall back to
    // the defaults instead of disabling the agent.
    _maxActions = _clampInt(
      prefs.getInt(_maxActionsKey) ?? _defaultMaxActions,
      1,
      40,
    );
    _maxInferences = _clampInt(
      prefs.getInt(_maxInferencesKey) ?? _defaultMaxInferences,
      1,
      20,
    );
    _taskDeadline = Duration(
      seconds: _clampInt(
        prefs.getInt(_taskDeadlineKey) ?? _defaultTaskDeadline.inSeconds,
        15,
        600,
      ),
    );
    _inferenceTimeout = Duration(
      seconds: _clampInt(
        prefs.getInt(_inferenceTimeoutKey) ??
            _defaultInferenceTimeout.inSeconds,
        10,
        180,
      ),
    );
    _aiService.inferenceTimeout = _inferenceTimeout;

    final savedSpeechRate = prefs.getDouble('lucy_speech_rate');
    if (savedSpeechRate != null &&
        savedSpeechRate >= 0.1 &&
        savedSpeechRate <= 1.0) {
      await _voiceService.setSpeechRate(savedSpeechRate);
    }
    final savedTimeoutSeconds = prefs.getInt('lucy_followup_timeout_seconds');
    if (savedTimeoutSeconds != null &&
        savedTimeoutSeconds >= 15 &&
        savedTimeoutSeconds <= 600) {
      _followupTimeout = Duration(seconds: savedTimeoutSeconds);
    }
    final savedHistory = prefs.getStringList(_historyPrefKey) ?? const [];
    for (final item in savedHistory.take(_maxHistoryEntries)) {
      try {
        final entry = jsonDecode(item) as Map<String, dynamic>;
        final text = entry['text'];
        final isUser = entry['isUser'];
        final timestamp = entry['timestamp'];
        if (text is String && isUser is bool && timestamp is String) {
          _conversation.add(
            ConversationEntry(
              text: text,
              isUser: isUser,
              timestamp: DateTime.tryParse(timestamp),
            ),
          );
        }
      } on FormatException catch (error) {
        debugPrint('Ignoring malformed saved conversation entry: $error');
      } catch (error) {
        debugPrint('Could not restore a saved conversation entry: $error');
      }
    }
    notifyListeners();

    // Wire native stop notification action → requestCancel
    _screenCapture.onForceStop = () {
      if (_isActive) {
        requestCancel();
      }
    };

    _voiceService.onResult = (text, isFinal) {
      _currentTranscript = text;
      if (isFinal && text.isNotEmpty) {
        _handleUserInput(text);
      }
      notifyListeners();
    };

    _voiceService.onListeningDone = () {
      if (_state == AgentState.listening &&
          _currentTranscript?.isEmpty == true) {
        if (_isActive) {
          _listenRetryCount++;
          if (_listenRetryCount > _maxListenRetries) {
            print(
              'Listening retry limit reached ($_maxListenRetries). Stopping.',
            );
            _listenRetryCount = 0;
            _statusMessage = 'Listening timed out. Tap to restart.';
            _setState(AgentState.idle);
            _isActive = false;
            notifyListeners();
            return;
          }
          Future.delayed(const Duration(seconds: 2), () {
            if (_isActive && _state == AgentState.listening) {
              _startListening();
            }
          });
        }
      } else {
        _listenRetryCount = 0;
      }
    };

    _voiceService.onError = (error) {
      debugPrint('Voice error: $error');
      if (_isActive && _state == AgentState.listening) {
        if (error == 'error_busy' || error == 'error_client') {
          _statusMessage =
              'Speech recognition is busy or unavailable. Tap the microphone to retry.';
          _isActive = false;
          _setState(AgentState.idle);
          notifyListeners();
          return;
        }
        _listenRetryCount++;
        if (_listenRetryCount > _maxListenRetries) {
          _isActive = false;
          _statusMessage = 'Speech recognition failed: $error';
          _setState(AgentState.idle);
          notifyListeners();
          return;
        }
        Future.delayed(Duration(seconds: _listenRetryCount), () {
          if (_isActive && _state == AgentState.listening) _startListening();
        });
      }
    };
  }

  static int _clampInt(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

  void configureAi(String apiKey) {
    _aiService.configure(apiKey);
    notifyListeners();
  }

  void confirmPendingAction(bool approved) {
    _safetyConfirmation.resolveConfirmation(approved);
    if (!approved) {
      _cancelRequested = true;
    }
    notifyListeners();
  }

  Future<void> toggleAgent() async {
    if (_isActive) {
      await stopAgent();
    } else {
      await startAgent();
    }
  }

  Future<void> startAgent() async {
    if (_isActive) return;
    _isActive = true;
    _addConversation(
      'Manual voice listening started. Lucy does not listen for a wake phrase in the background.',
      false,
    );
    _statusMessage =
        'Manual listening is active in Lucy. Tap the button to stop.';
    _isAskingForFurtherHelp = false;
    notifyListeners();

    _isVoiceReady = await _voiceService.initialize();
    final prefs = await SharedPreferences.getInstance();
    final savedSpeechRate = prefs.getDouble('lucy_speech_rate');
    if (savedSpeechRate != null &&
        savedSpeechRate >= 0.1 &&
        savedSpeechRate <= 1.0) {
      await _voiceService.setSpeechRate(savedSpeechRate);
    }
    if (!_isVoiceReady) {
      _isActive = false;
      _statusMessage =
          'Speech recognition is unavailable. Check Android microphone permission and speech services.';
      _setState(AgentState.idle);
      return;
    }

    // Check if accessibility service is enabled
    final hasAccessibility = await _screenCapture.isAccessibilityEnabled();
    if (!hasAccessibility) {
      _addConversation(
        '⚠️ Accessibility service is not enabled. UI actions (tap, type, swipe) are unavailable. '
        'Enable Lucy in Android Settings → Accessibility.',
        false,
      );
    }

    _listenRetryCount = 0;
    _startListening();
  }

  Future<void> stopAgent({String? statusMessage}) async {
    _isActive = false;
    // Keep cancellation set until the in-flight loop observes it. Clearing it
    // here could let a pending model response execute one more action.
    _cancelRequested = true;
    _followupTimeoutTimer?.cancel();
    _followupTimeoutTimer = null;
    await _voiceService.stopListening();
    await _voiceService.stopSpeaking();
    _setState(AgentState.idle);
    _statusMessage =
        statusMessage ??
        'Lucy is stopped. Use text commands or start manual listening.';
    _addConversation('Agent stopped.', false);
    notifyListeners();
  }

  Future<void> _startListening() async {
    if (!_isActive) return;
    if (_isAskingForFurtherHelp) {
      _scheduleFollowupTimeout();
    }
    _setState(AgentState.listening);
    _statusMessage =
        "🎤 I'm listening in the foreground. Wake-word detection is unavailable.";
    _currentTranscript = '';
    _listenStartedAt = DateTime.now();
    notifyListeners();

    await _voiceService.startListening(
      localeId: VoiceService.sttLocaleFor(_currentLang),
    );
  }

  /// Main handler: user says something → agent loop begins.
  Future<void> _handleUserInput(String text, {bool voiceInput = true}) async {
    if (!_isActive ||
        (voiceInput && _state != AgentState.listening) ||
        (!voiceInput &&
            _state != AgentState.idle &&
            _state != AgentState.listening)) {
      return;
    }

    _followupTimeoutTimer?.cancel();
    _followupTimeoutTimer = null;
    _setState(AgentState.analyzing);
    if (voiceInput) {
      await _voiceService.stopListening();
    }
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
    final requestTimer = Stopwatch()..start();
    debugPrint('Lucy[$requestId] stage=command_received');
    final listenStartedAt = _listenStartedAt;
    if (listenStartedAt != null) {
      // Time from starting the recognizer to the final transcript. This
      // includes the time the user spent speaking, so it measures capture
      // latency rather than model latency.
      debugPrint(
        'Lucy[$requestId] stage=speech_recognition '
        'elapsed_ms=${DateTime.now().difference(listenStartedAt).inMilliseconds}',
      );
    }

    _addConversation(text, true);
    _currentTranscript = '';

    final routedCommand = _commandRouter.route(text);
    if (routedCommand != null) {
      await _handleLocalCommand(routedCommand, requestId);
      debugPrint(
        'Lucy[$requestId] stage=total elapsed_ms=${requestTimer.elapsedMilliseconds}',
      );
      if (voiceInput && _isActive) _startListening();
      return;
    }

    if (!_aiService.canInterpretRequests) {
      final message =
          'No selected AI provider can handle this request. Supported exact local commands still work. '
          'Load a GGUF model for offline interpretation, or enable Gemini and cloud data consent in Settings.';
      _addConversation(message, false);
      _isAskingForFurtherHelp = true;
      _statusMessage = _aiService.localModelStatus;
      await _speakAndWait(message);
      debugPrint(
        'Lucy[$requestId] stage=total elapsed_ms=${requestTimer.elapsedMilliseconds}',
      );
      if (voiceInput && _isActive) _startListening();
      return;
    }

    if (_isAskingForFurtherHelp) {
      _isAskingForFurtherHelp = false;
      final trimmed = text.trim();
      final textLowerAscii = trimmed.toLowerCase().replaceAll(
        RegExp(r'[^\w\s]'),
        '',
      );
      final isNegative =
          _negativeEn.hasMatch(textLowerAscii) ||
          _negativeJa.hasMatch(trimmed) ||
          _negativeAr.hasMatch(trimmed);
      if (isNegative) {
        _setState(AgentState.speaking);
        final stopMsg =
            _stoppingMessages[_currentLang] ?? _stoppingMessages['en']!;
        _addConversation(stopMsg, false);
        await _voiceService.speak(stopMsg, lang: _currentLang);

        await Future.delayed(const Duration(milliseconds: 500));
        while (_voiceService.isSpeaking) {
          await Future.delayed(const Duration(milliseconds: 200));
        }

        await stopAgent();
        return;
      }
    }

    await _runAgentLoop(text, requestId: requestId);
    debugPrint(
      'Lucy[$requestId] stage=total elapsed_ms=${requestTimer.elapsedMilliseconds}',
    );

    // Resume listening after the loop completes
    if (voiceInput && _isActive) {
      _startListening();
    }
  }

  Future<void> submitTextCommand(String text) async {
    final command = text.trim();
    if (command.isEmpty ||
        (_state != AgentState.idle && _state != AgentState.listening)) {
      return;
    }
    final resumeVoice = _isActive && _state == AgentState.listening;
    if (resumeVoice) {
      await _voiceService.stopListening();
    } else {
      _isActive = true;
    }
    await _handleUserInput(command, voiceInput: false);
    if (_isActive && resumeVoice) {
      _startListening();
    } else if (_isActive) {
      _isActive = false;
      _setState(AgentState.idle);
      _statusMessage = 'Manual command complete. Voice activation is off.';
      notifyListeners();
    }
  }

  void _scheduleFollowupTimeout() {
    if (_followupTimeoutTimer != null) return;
    _followupTimeoutTimer = Timer(_followupTimeout, () {
      _followupTimeoutTimer = null;
      if (_isActive && _isAskingForFurtherHelp) {
        unawaited(
          stopAgent(
            statusMessage: 'Conversation timed out; microphone stopped.',
          ),
        );
      }
    });
  }

  /// The core agent loop: OBSERVE → PLAN → EXECUTE → VERIFY → CONTINUE/STOP.
  ///
  /// One inference produces a plan of up to five validated actions. The plan
  /// is then executed action by action, reusing the observations already taken
  /// for readiness checks, so a new inference only happens when the plan is
  /// spent or contradicted by the screen. Success is accepted only after
  /// deterministic verification against the accessibility tree.
  Future<void> _runAgentLoop(String userMessage, {String? requestId}) async {
    if (_loopRunning) {
      debugPrint('Lucy[$requestId] rejected: an agent loop is already running');
      _addConversation('I am still working on the previous request.', false);
      return;
    }
    _loopRunning = true;
    try {
      await _runTask(userMessage, requestId: requestId ?? 'task');
    } catch (error, stackTrace) {
      // Never swallow a failure: report it and keep the loop stopped.
      debugPrint('Lucy[$requestId] stage=fatal error=$error\n$stackTrace');
      _addConversation(
        'Something failed while running this task: $error',
        false,
      );
    } finally {
      _loopRunning = false;
    }
  }

  Future<void> _runTask(String userMessage, {required String requestId}) async {
    final profiler = PipelineProfiler(requestId);
    _cancelRequested = false;
    _observer.invalidate();

    await _screenCapture.showStopOverlay();
    final canObserveUi = await _screenCapture.isAccessibilityEnabled();
    final screenSize = await profiler.time(
      'screen_size',
      _screenCapture.getScreenSize,
    );

    final budget = AgentBudget(
      maxActions: _maxActions,
      maxInferences: _maxInferences,
      deadline: _taskDeadline,
    );

    final memoryContext = _memoryService.getContextSummaryForPrompt();
    final baseMessage = memoryContext.isNotEmpty
        ? '$memoryContext\n$userMessage'
        : userMessage;

    UiSnapshot? baseline; // screen observed before the first device action
    UiSnapshot? latest; // most recent observation
    AgentPlan? plan;
    var performedAction = false;
    var recoveries = 0;
    var emptyPlanRetries = 0;
    var taskCompleted = false;
    var needsFreshObservation = false;
    String? evidenceNote;
    String? finalMessage;

    while (_isActive && !_cancelRequested) {
      if (!budget.canContinue) {
        finalMessage = budget.describeStop();
        break;
      }

      if (plan != null && !plan.exhausted) {
        // ── EXECUTE ────────────────────────────────────────────────────
        final action = plan.takeNext()!;
        if (!budget.canExecuteAction) {
          finalMessage = budget.describeStop();
          break;
        }

        _setState(AgentState.executingAction);
        _statusMessage =
            '⚡ Executing ${action.type} '
            '(${plan.total - plan.remaining}/${plan.total})…';
        notifyListeners();

        var validation = ActionValidator.validate(
          action,
          snapshot: latest,
          screenSize: screenSize,
        );
        if (!validation.ok && latest == null && canObserveUi) {
          // Nothing observed yet: one cheap read may resolve the target
          // without spending an inference.
          final refreshed = await profiler.time('observe', _observer.refresh);
          if (refreshed != null) {
            latest = refreshed;
            validation = ActionValidator.validate(
              action,
              snapshot: latest,
              screenSize: screenSize,
            );
          }
        }

        if (!validation.ok) {
          // Stop the sequence: the target is not proven to exist.
          final fresh = await profiler.time('observe', _observer.refresh);
          latest = fresh ?? latest;
          final detail = validation.reason ?? 'the action is not valid';
          if (recoveries < _maxVerificationRecoveries && budget.canPlan) {
            recoveries++;
            evidenceNote = 'Step refused: $detail.';
            plan = null;
            needsFreshObservation = false;
            continue;
          }
          finalMessage = 'I stopped before running ${action.type}: $detail.';
          break;
        }

        baseline ??= latest;
        // The screen is about to change: invalidate the cached observation
        // before dispatching so the readiness poll reads real state.
        _observer.markActionExecuted();

        final result = await _executeAction(
          action,
          latest,
          canObserveUi: canObserveUi,
        );
        profiler.record(
          'action_${action.type}',
          result.dispatchMs,
          detail: 'succeeded=${result.succeeded}',
        );
        profiler.record('wait_ready', result.waitMs);

        final signature = actionSignature(action);

        if (!result.succeeded) {
          // Stop the action sequence immediately, observe the new state, and
          // decide whether one safe retry is justified.
          final afterFailure = await profiler.time(
            'observe',
            _observer.refresh,
          );
          final stateAfter = afterFailure ?? result.snapshot ?? latest;
          final changed =
              latest != null &&
              stateAfter != null &&
              latest.signature != stateAfter.signature;
          budget.recordAction(
            signature: signature,
            screenChanged: changed,
            failed: true,
          );

          if (changed && !ActionValidator.neverRetry.contains(action.type)) {
            // The device changed despite the reported failure: the effect
            // happened, so continue instead of repeating it.
            performedAction = true;
            latest = stateAfter;
            continue;
          }

          final irreversible = ActionValidator.neverRetry.contains(action.type);
          if (irreversible || !budget.canRetry(signature)) {
            finalMessage =
                'I could not complete ${action.type} after a failed attempt, '
                'so I stopped rather than repeat it.';
            break;
          }
          evidenceNote =
              '${action.type} failed once; retrying once from a fresh observation.';
          plan.retryLast();
          needsFreshObservation = true;
          continue;
        }
        final screenAffecting = _affectsScreen(action.type);
        if (screenAffecting) performedAction = true;
        final stateAfter = result.snapshot;
        final changed =
            latest != null &&
            stateAfter != null &&
            latest.signature != stateAfter.signature;
        latest = stateAfter ?? latest;
        budget.recordAction(
          signature: signature,
          screenChanged: changed,
          affectsScreen: screenAffecting,
        );
        if (budget.stopped) {
          finalMessage = budget.describeStop();
          break;
        }
        if (!changed) needsFreshObservation = true;
        continue;
      }

      if (plan != null && plan.done) {
        // ── VERIFY ─────────────────────────────────────────────────────
        _setState(AgentState.analyzing);
        _statusMessage = '🔎 Verifying the result…';
        notifyListeners();

        final verifyTimer = Stopwatch()..start();
        // The readiness snapshot may predate a transition: read fresh
        // evidence and give loading screens a bounded chance to settle.
        final fresh = await _refreshForVerification();
        latest = fresh ?? latest;

        final verdict = TaskVerifier.verify(
          criteria: plan.verify,
          snapshot: latest,
          previousSnapshot: baseline,
          performedAction: performedAction,
        );
        profiler.record(
          'verify',
          verifyTimer.elapsedMilliseconds,
          detail: 'status=${verdict.status.name}',
        );

        if (verdict.isSuccess) {
          taskCompleted = true;
          final answer = plan.speak.trim();
          final confirmation = answer.isEmpty
              ? 'Done. ${verdict.evidence}.'
              : answer;
          finalMessage =
              '$confirmation ${_followUps[_currentLang] ?? _followUps['en']}';
          break;
        }

        if (recoveries < _maxVerificationRecoveries && budget.canPlan) {
          recoveries++;
          evidenceNote =
              'Verification failed: ${verdict.evidence}. The observation '
              'below is the screen right now.';
          plan = null;
          continue;
        }

        finalMessage =
            'I could not confirm that this task succeeded: ${verdict.evidence}.';
        break;
      }

      // ── PLAN ─────────────────────────────────────────────────────────
      if (!budget.canPlan) {
        finalMessage = budget.describeStop();
        break;
      }

      if (latest == null || needsFreshObservation) {
        _setState(AgentState.capturing);
        _statusMessage = '📸 Observing screen…';
        notifyListeners();
        needsFreshObservation = false;
        latest = await profiler.time('observe', _observer.refresh);
      }

      _setState(AgentState.analyzing);
      _statusMessage = '🤖 Planning… (step ${budget.inferences + 1})';
      notifyListeners();

      final promptBuilder = StringBuffer()..writeln(baseMessage);
      if (evidenceNote != null) {
        promptBuilder
          ..writeln()
          ..writeln('SCREEN_EVIDENCE: $evidenceNote');
      }
      if (performedAction) {
        promptBuilder
          ..writeln()
          ..writeln(
            'PREVIOUS_STEP: ${budget.actionsExecuted} action(s) executed; the '
            'observation below is the screen right now. Continue the task, or '
            'finish with done=true and a verify object.',
          );
      }
      final preparedMessage = promptBuilder.toString();
      final observationText = latest?.renderForModel();

      final promptTimer = Stopwatch()..start();
      final promptChars = AiService.promptLength(
        preparedMessage,
        screenSize: screenSize,
        uiTree: observationText,
      );
      profiler.record(
        'prompt_prepare',
        promptTimer.elapsedMilliseconds,
        detail: 'prompt_chars=$promptChars',
      );

      final response = await profiler.time('ai_inference', () {
        return _aiService.agentChat(
          preparedMessage,
          screenSize: screenSize,
          uiTree: observationText,
          timeout: _inferenceTimeout,
          onToken: (_) {
            // Surface the first token so a long local generation is visible.
            if (_streamingStatus.isEmpty) {
              _streamingStatus = 'local';
              _statusMessage = '🎙 Local model is responding…';
              notifyListeners();
            }
          },
        );
      });
      _streamingStatus = '';
      budget.recordPlan();

      if (!response.isValidated) {
        // Never execute an unvalidated response and never claim success.
        finalMessage = response.speak;
        break;
      }

      plan = AgentPlan.fromResponse(response);
      evidenceNote = null;
      _syncLanguage(response.lang);

      if (plan.actions.isEmpty && !plan.done) {
        emptyPlanRetries++;
        if (emptyPlanRetries > 1) {
          finalMessage =
              'The model returned no action for this step, so I stopped.';
          break;
        }
        evidenceNote =
            'Your previous response contained no actions and done=false. '
            'Return actions, or set done=true with a verify object.';
        plan = null;
        continue;
      }
      emptyPlanRetries = 0;

      if (plan.speak.isNotEmpty &&
          (_conversation.isEmpty || _conversation.last.text != plan.speak)) {
        _addConversation(plan.speak, false);
      }
      // Brief acknowledgment: start it now, never block execution on it.
      if (!plan.done && plan.speak.isNotEmpty && plan.actions.isNotEmpty) {
        unawaited(
          _voiceService
              .speak(_trimForTts(plan.speak), lang: _currentLang)
              .catchError((Object error) {
                debugPrint('Acknowledgment speech failed: $error');
              }),
        );
      }
    }

    await _screenCapture.hideStopOverlay();

    if (_cancelRequested) {
      _cancelRequested = false;
      _addConversation('🛑 Stopped by user.', false);
      profiler.logSummary();
      return;
    }

    if (finalMessage != null && finalMessage.trim().isNotEmpty) {
      final text = finalMessage.trim();
      _isAskingForFurtherHelp = true;
      if (_conversation.isEmpty || _conversation.last.text != text) {
        _addConversation(text, false);
      }
      await _speakFinal(text, profiler);
    }

    if (taskCompleted) {
      _statusMessage = '✅ Task verified. Ask me for anything else.';
      notifyListeners();
    }

    profiler.logSummary();
  }

  /// Whether an action type is expected to change the observable screen.
  /// Local side effects (memory, reminders) and pure waits must not be
  /// "verified" against a screen that was never supposed to change.
  static bool _affectsScreen(String type) =>
      type != 'wait' && type != 'add_memory' && type != 'create_reminder';

  /// Poll the accessibility tree until [matches] reports success or the
  /// timeout elapses. Returns the matching snapshot, or null when the screen
  /// never showed the expected state.
  Future<UiSnapshot?> _awaitScreen(
    bool Function(UiSnapshot snapshot) matches, {
    Duration timeout = const Duration(milliseconds: 2000),
  }) => _observer.awaitUntil(
    matches,
    timeout: timeout,
    interval: _uiPollInterval,
    isCancelled: () => _cancelRequested,
  );

  /// Fresh evidence for verification: re-read the tree and give loading
  /// screens and blank windows a bounded chance to settle first.
  Future<UiSnapshot?> _refreshForVerification() async {
    var snapshot = await _observer.refresh();
    var attempts = 0;
    while (!_cancelRequested &&
        attempts < 2 &&
        snapshot != null &&
        (snapshot.isLoading || snapshot.isBlank)) {
      await Future.delayed(const Duration(milliseconds: 300));
      snapshot = await _observer.refresh();
      attempts++;
    }
    return snapshot;
  }

  /// Speak the final result as soon as it is appropriate, without claiming
  /// success before verification produced this message.
  Future<void> _speakFinal(String text, PipelineProfiler profiler) async {
    _lastAssistantResponse = text;
    _setState(AgentState.speaking);
    _statusMessage = '🔊 Speaking…';
    notifyListeners();

    // Let a still-playing acknowledgment finish briefly, then speak.
    final guard = Stopwatch()..start();
    while (_voiceService.isSpeaking &&
        guard.elapsed < const Duration(seconds: 4)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    final startTimer = Stopwatch()..start();
    await _voiceService.speak(_trimForTts(text), lang: _currentLang);
    profiler.record('tts_start', startTimer.elapsedMilliseconds);

    final doneTimer = Stopwatch()..start();
    while (_voiceService.isSpeaking &&
        !_cancelRequested &&
        doneTimer.elapsed < const Duration(seconds: 30)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    profiler.record('tts_end', doneTimer.elapsedMilliseconds);
  }

  /// Keep STT/TTS language in sync with the model's language tag.
  void _syncLanguage(String lang) {
    if (!_supportedLangs.contains(lang) || lang == _currentLang) return;
    _currentLang = lang;
    unawaited(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(_langPrefKey, _currentLang),
      ),
    );
  }

  Future<void> _handleLocalCommand(
    LocalCommand command,
    String requestId,
  ) async {
    switch (command.type) {
      case LocalCommandType.stop:
      case LocalCommandType.sleep:
        final response = command.type == LocalCommandType.sleep
            ? 'Okay, going to sleep.'
            : 'Okay, stopping voice listening.';
        _addConversation(response, false);
        await _speakAndWait(response);
        await stopAgent();
        return;
      case LocalCommandType.cancel:
        _cancelRequested = true;
        const response = 'Cancelled.';
        _addConversation(response, false);
        await _speakAndWait(response);
        return;
      case LocalCommandType.repeat:
        final previous = _lastAssistantResponse;
        if (previous == null) {
          const response = 'There is nothing to repeat yet.';
          _addConversation(response, false);
          await _speakAndWait(response);
          return;
        }
        await _speakAndWait(previous);
        return;
      case LocalCommandType.action:
        final action = command.action!;
        _setState(AgentState.executingAction);
        _statusMessage = 'Executing local command...';
        notifyListeners();
        final timer = Stopwatch()..start();
        bool success;
        var evidence = '';
        switch (action.type) {
          case 'open_app':
            final package = action.params['package'] as String;
            success = await _screenCapture.openApp(package);
            // The launch call returning true is not evidence: confirm the
            // app is actually in front before claiming it opened.
            if (success) {
              final canVerify = await _screenCapture.isAccessibilityEnabled();
              if (!canVerify) {
                evidence =
                    ' I cannot verify the screen without the accessibility service.';
              } else {
                final matched = await _awaitScreen(
                  (snapshot) => snapshot.packageName == package,
                );
                if (matched == null) {
                  success = false;
                  evidence =
                      ' the foreground app is '
                      '${_observer.last?.packageName ?? 'unchanged'}.';
                }
              }
            }
            break;
          case 'back':
            success = await _screenCapture.pressBack();
            break;
          case 'home':
            success = await _screenCapture.pressHome();
            break;
          default:
            success = false;
            break;
        }
        debugPrint(
          'Lucy[$requestId] stage=fast_action_${action.type} '
          'elapsed_ms=${timer.elapsedMilliseconds} success=$success',
        );
        final response = success
            ? switch (action.type) {
                'open_app' => 'Opened ${command.label ?? 'the app'}.$evidence',
                'back' => 'Went back.',
                'home' => 'Went to the home screen.',
                _ => 'Command completed.',
              }
            : evidence.isNotEmpty
            ? 'I could not confirm that command:$evidence'
            : 'I could not complete that command. Check that the required Android permissions are enabled.';
        _addConversation(response, false);
        _isAskingForFurtherHelp = true;
        await _speakAndWait(response);
        return;

      case LocalCommandType.time:
        final now = DateTime.now();
        final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
        final amPm = now.hour >= 12 ? 'PM' : 'AM';
        final minute = now.minute.toString().padLeft(2, '0');
        const weekdays = [
          'Monday',
          'Tuesday',
          'Wednesday',
          'Thursday',
          'Friday',
          'Saturday',
          'Sunday',
        ];
        const months = [
          'January',
          'February',
          'March',
          'April',
          'May',
          'June',
          'July',
          'August',
          'September',
          'October',
          'November',
          'December',
        ];
        final dayName = weekdays[now.weekday - 1];
        final monthName = months[now.month - 1];
        final timeResponse =
            'It is $hour:$minute $amPm on $dayName, $monthName ${now.day}.';
        _addConversation(timeResponse, false);
        await _speakAndWait(timeResponse);
        return;

      case LocalCommandType.reminder:
        final title = command.params!['title'] as String;
        final scheduled = command.params!['scheduledTime'] as DateTime;
        final recurrence = command.params!['recurrence'] as ReminderRecurrence;
        await _reminderService.addReminder(
          title: title,
          scheduledTime: scheduled,
          recurrence: recurrence,
        );
        final hour = scheduled.hour % 12 == 0 ? 12 : scheduled.hour % 12;
        final amPm = scheduled.hour >= 12 ? 'PM' : 'AM';
        final minute = scheduled.minute.toString().padLeft(2, '0');
        final recurText = recurrence == ReminderRecurrence.none
            ? ''
            : ' (${recurrence.name})';
        final remResponse =
            'Reminder set for "$title" at $hour:$minute $amPm$recurText.';
        _addConversation(remResponse, false);
        await _speakAndWait(remResponse);
        return;

      case LocalCommandType.listReminders:
        final pending = _reminderService.pendingReminders;
        String listResponse;
        if (pending.isEmpty) {
          listResponse = 'You have no pending tasks or reminders.';
        } else {
          final count = pending.length;
          final items = pending.take(3).map((r) => r.title).join(', ');
          listResponse =
              'You have $count pending ${count == 1 ? 'task' : 'tasks'}: $items.';
        }
        _addConversation(listResponse, false);
        await _speakAndWait(listResponse);
        return;

      case LocalCommandType.memory:
        final content = command.params!['content'] as String;
        await _memoryService.addMemory(content);
        final memResponse = 'I remembered that: "$content".';
        _addConversation(memResponse, false);
        await _speakAndWait(memResponse);
        return;

      case LocalCommandType.searchMemory:
        final query = command.params!['query'] as String;
        final matches = _memoryService.search(query);
        String searchResponse;
        if (matches.isEmpty) {
          searchResponse = 'I do not have any saved memories about "$query".';
        } else {
          final top = matches.first.content;
          searchResponse = 'I remember: "$top".';
        }
        _addConversation(searchResponse, false);
        await _speakAndWait(searchResponse);
        return;
    }
  }

  Future<void> _speakAndWait(String text) async {
    _lastAssistantResponse = text;
    _setState(AgentState.speaking);
    await _voiceService.speak(text, lang: _currentLang);
    while (_voiceService.isSpeaking && _isActive) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Capture the screen with retry logic.
  /// After navigating to another app, the first capture attempt may return null
  /// because the VirtualDisplay hasn't rendered a fresh frame yet. Retrying
  /// with increasing delays ensures we eventually get a valid screenshot.
  Future<Uint8List?> _captureScreenWithRetry({int maxRetries = 3}) async {
    for (int i = 0; i < maxRetries; i++) {
      try {
        final bytes = await _screenCapture.captureScreen();
        if (bytes != null) return bytes;
      } catch (e) {
        print('Screenshot capture attempt ${i + 1} failed: $e');
      }
      if (i < maxRetries - 1) {
        // Increasing delay between retries: 200ms, 400ms
        await Future.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }
    print('All $maxRetries screenshot capture attempts failed');
    return null;
  }

  /// Resolve element ID from the UI tree to (cx, cy) coordinates.
  /// Returns null if the element is not found.
  Map<String, double>? _resolveElementCoordinates(
    int elementId,
    List<Map<String, dynamic>> uiElements,
  ) {
    final element = _findElementById(elementId, uiElements);
    if (element != null) {
      final bounds = element['bounds'] as Map<String, dynamic>?;
      if (bounds != null) {
        return {
          'x': (bounds['cx'] as num).toDouble(),
          'y': (bounds['cy'] as num).toDouble(),
        };
      }
    }
    return null;
  }

  Map<String, dynamic>? _findElementById(
    int elementId,
    List<Map<String, dynamic>> uiElements,
  ) {
    for (final element in uiElements) {
      if (element['id'] == elementId) {
        return element;
      }
    }
    return null;
  }

  bool _didPackageChange(UiSnapshot? before, UiSnapshot? after) {
    if (before?.packageName == null || after?.packageName == null) {
      return false;
    }
    return before!.packageName != after!.packageName;
  }

  bool _didTreeSignatureChange(UiSnapshot? before, UiSnapshot? after) {
    final beforeSignature = before?.signature;
    final afterSignature = after?.signature;
    if (beforeSignature == null || afterSignature == null) {
      return false;
    }
    return beforeSignature != afterSignature;
  }

  bool _tapTargetsEditableField(
    AgentAction action,
    UiSnapshot? beforeSnapshot,
  ) {
    final elementId = action.params['element'] as num?;
    if (elementId == null || beforeSnapshot == null) {
      return false;
    }

    final element = _findElementById(
      elementId.toInt(),
      beforeSnapshot.elements,
    );
    if (element == null) {
      return false;
    }

    return element['editable'] == true ||
        element['focusable'] == true ||
        (element['type']?.toString().contains('EditText') ?? false);
  }

  bool _isConsequentialControl(Map<String, dynamic>? element) {
    if (element == null) return false;
    final label = '${element['text'] ?? ''} ${element['desc'] ?? ''}'
        .toLowerCase()
        .trim();
    if (label.isEmpty) return false;
    return RegExp(
      r'\b(send|post|publish|buy|purchase|pay|transfer|delete|remove|submit|place order)\b',
    ).hasMatch(label);
  }

  Duration _readinessTimeoutForAction(AgentAction action) {
    switch (action.type) {
      case 'open_app':
        return _openAppReadyTimeout;
      case 'tap':
      case 'long_press':
      case 'double_tap':
        return _tapReadyTimeout;
      case 'type':
        return _typeReadyTimeout;
      case 'swipe':
      case 'back':
      case 'home':
        return _navigationReadyTimeout;
      case 'wait':
        // The wait action performs its delay inside _executeAction.
        // Do not wait again for a UI change afterward.
        return Duration.zero;
      default:
        return Duration.zero;
    }
  }

  bool _isActionReady(
    AgentAction action,
    UiSnapshot? beforeSnapshot,
    UiSnapshot? currentSnapshot,
  ) {
    if (currentSnapshot == null) {
      return false;
    }

    if (beforeSnapshot == null) {
      return true;
    }

    final packageChanged = _didPackageChange(beforeSnapshot, currentSnapshot);
    final treeChanged = _didTreeSignatureChange(
      beforeSnapshot,
      currentSnapshot,
    );

    switch (action.type) {
      case 'open_app':
        final targetPackage = action.params['package'] as String?;
        if (targetPackage != null &&
            targetPackage.isNotEmpty &&
            currentSnapshot.packageName == targetPackage) {
          return true;
        }
        return packageChanged || treeChanged;
      case 'tap':
      case 'long_press':
      case 'double_tap':
        final expectsFocusedInput = _tapTargetsEditableField(
          action,
          beforeSnapshot,
        );
        if (expectsFocusedInput && currentSnapshot.hasFocusedEditable) {
          return true;
        }
        return packageChanged || treeChanged;
      case 'type':
      case 'swipe':
      case 'back':
      case 'home':
      case 'wait':
        return packageChanged || treeChanged;
      default:
        return true;
    }
  }

  Future<UiSnapshot?> _waitForActionReadiness(
    AgentAction action,
    UiSnapshot? beforeSnapshot, {
    required bool canObserveUi,
  }) async {
    final timeout = _readinessTimeoutForAction(action);
    if (timeout == Duration.zero) {
      return beforeSnapshot;
    }

    if (!canObserveUi) {
      return beforeSnapshot;
    }

    // A tap can return long before the new window renders: wait for the
    // tree to actually change instead of sleeping a fixed amount.
    final matched = await _observer.awaitUntil(
      (snapshot) => _isActionReady(action, beforeSnapshot, snapshot),
      timeout: timeout,
      interval: _uiPollInterval,
      isCancelled: () => _cancelRequested,
    );
    return matched ?? beforeSnapshot;
  }

  /// Execute a single agent action.
  ///
  /// [canObserveUi] is read once per task instead of per action so one round
  /// trip through the platform channel is not spent on every step.
  Future<_ActionExecutionResult> _executeAction(
    AgentAction action,
    UiSnapshot? beforeSnapshot, {
    required bool canObserveUi,
  }) async {
    // Actions that require the accessibility service
    const accessibilityActions = {
      'tap',
      'long_press',
      'double_tap',
      'type',
      'clear',
      'swipe',
      'back',
      'home',
    };

    if (accessibilityActions.contains(action.type)) {
      if (!canObserveUi) {
        _addConversation(
          '⚠️ Cannot execute "${action.type}" — accessibility service not enabled. '
          'Please enable it in Settings → Accessibility → Lucy.',
          false,
        );
        return _ActionExecutionResult(beforeSnapshot, false);
      }
    }

    if (_safetyConfirmation.requiresConfirmation(action)) {
      _setState(AgentState.waitingConfirmation);
      final conf = _safetyConfirmation.createConfirmation(action);
      _addConversation(
        '⚠️ Confirmation Required: ${conf.title} — ${conf.description}',
        false,
      );
      notifyListeners();
      final approved = await _safetyConfirmation.requestConfirmation(conf);
      if (!approved) {
        _addConversation('Action was cancelled by user.', false);
        return _ActionExecutionResult(beforeSnapshot, false);
      }
      _setState(AgentState.executingAction);
      notifyListeners();
    }

    var succeeded = false;
    final dispatchTimer = Stopwatch()..start();
    try {
      switch (action.type) {
        case 'create_reminder':
          final title = action.params['title'] as String? ?? 'Reminder';
          final timeStr = action.params['scheduledTime'] as String?;
          final scheduled = timeStr != null
              ? (DateTime.tryParse(timeStr) ??
                    DateTime.now().add(const Duration(hours: 1)))
              : DateTime.now().add(const Duration(hours: 1));
          await _reminderService.addReminder(
            title: title,
            scheduledTime: scheduled,
          );
          succeeded = true;
          break;

        case 'add_memory':
          final content = action.params['content'] as String? ?? '';
          if (content.isNotEmpty) {
            await _memoryService.addMemory(content);
            succeeded = true;
          }
          break;
        case 'open_app':
          final package = action.params['package'] as String? ?? '';
          if (package.isNotEmpty) {
            succeeded = await _screenCapture.openApp(package);
          }
          break;

        case 'tap':
        case 'long_press':
        case 'double_tap':
          final elementId = action.params['element'] as num?;
          final target = elementId == null || beforeSnapshot == null
              ? null
              : _findElementById(elementId.toInt(), beforeSnapshot.elements);
          if (_isConsequentialControl(target)) {
            _addConversation(
              'Stopped before activating "${target?['text'] ?? target?['desc']}". Confirm and complete this consequential action yourself, then tell Lucy to continue.',
              false,
            );
            return _ActionExecutionResult(beforeSnapshot, false);
          }
          final coords = elementId == null
              ? null
              : _resolveElementCoordinates(
                  elementId.toInt(),
                  beforeSnapshot?.elements ?? const [],
                );
          if (coords != null) {
            final x = coords['x']!;
            final y = coords['y']!;
            succeeded = switch (action.type) {
              'long_press' => await _screenCapture.performLongPress(x, y),
              'double_tap' => await _screenCapture.performDoubleTap(x, y),
              _ => await _screenCapture.performTap(x, y),
            };
          }
          break;

        case 'type':
          final text = action.params['text'] as String? ?? '';
          if (text.isNotEmpty) {
            succeeded = await _screenCapture.performType(text);
          }
          break;

        case 'clear':
          succeeded = await _screenCapture.performType('');
          break;

        case 'swipe':
          final startX = (action.params['startX'] as num?)?.toDouble() ?? 0;
          final startY = (action.params['startY'] as num?)?.toDouble() ?? 0;
          final endX = (action.params['endX'] as num?)?.toDouble() ?? 0;
          final endY = (action.params['endY'] as num?)?.toDouble() ?? 0;
          succeeded = await _screenCapture.performSwipe(
            startX,
            startY,
            endX,
            endY,
          );
          break;

        case 'back':
          succeeded = await _screenCapture.pressBack();
          break;

        case 'home':
          succeeded = await _screenCapture.pressHome();
          break;

        case 'wait':
          final ms = (action.params['ms'] as num?)?.toInt() ?? 1000;
          final boundedMs = ms.clamp(0, 10000).toInt();
          if (!_cancelRequested) {
            final deadline = DateTime.now().add(
              Duration(milliseconds: boundedMs),
            );
            while (!_cancelRequested) {
              final remaining = deadline.difference(DateTime.now());
              if (remaining <= Duration.zero) {
                succeeded = true;
                break;
              }
              await Future.delayed(
                remaining < _uiPollInterval ? remaining : _uiPollInterval,
              );
            }
          }
          break;

        default:
          print('Unknown action type: ${action.type}');
      }
    } catch (e) {
      print('Error executing action ${action.type}: $e');
    }
    final dispatchMs = dispatchTimer.elapsedMilliseconds;

    if (!succeeded) {
      return _ActionExecutionResult(
        beforeSnapshot,
        false,
        dispatchMs: dispatchMs,
      );
    }

    final waitTimer = Stopwatch()..start();
    final snapshot = await _waitForActionReadiness(
      action,
      beforeSnapshot,
      canObserveUi: canObserveUi,
    );
    return _ActionExecutionResult(
      snapshot,
      true,
      dispatchMs: dispatchMs,
      waitMs: waitTimer.elapsedMilliseconds,
    );
  }

  String _trimForTts(String text) {
    // Remove action/emoji markers for cleaner TTS
    String cleaned = text;
    cleaned = cleaned.replaceAll(RegExp(r'⚡.*?\n'), '');
    cleaned = cleaned.trim();
    if (cleaned.length > 300) {
      return '${cleaned.substring(0, 297)}...';
    }
    return cleaned;
  }

  void _setState(AgentState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<bool> capturePreview() async {
    final screenshotBytes = await _captureScreenWithRetry();
    if (screenshotBytes == null) {
      return false;
    }

    _lastScreenshotBytes = screenshotBytes;
    notifyListeners();
    return true;
  }

  void _addConversation(
    String text,
    bool isUser, {
    Uint8List? screenshotBytes,
  }) {
    _conversation.add(
      ConversationEntry(
        text: text,
        isUser: isUser,
        screenshotBytes: screenshotBytes,
      ),
    );
    if (_conversation.length > _maxHistoryEntries) {
      _conversation.removeRange(0, _conversation.length - _maxHistoryEntries);
    }
    _historyWrite = _historyWrite.then((_) => _persistConversation());
    unawaited(_historyWrite);
    notifyListeners();
  }

  Future<void> _persistConversation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = _conversation
          .map(
            (entry) => jsonEncode({
              'text': entry.text,
              'isUser': entry.isUser,
              'timestamp': entry.timestamp.toIso8601String(),
            }),
          )
          .toList(growable: false);
      await prefs.setStringList(_historyPrefKey, entries);
    } catch (error) {
      debugPrint('Could not save conversation history: $error');
    }
  }

  void clearConversation() {
    _conversation.clear();
    _lastScreenshotBytes = null;
    _isAskingForFurtherHelp = false;
    _aiService.resetChat();
    _historyWrite = _historyWrite.then((_) => _persistConversation());
    unawaited(_historyWrite);
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _followupTimeoutTimer?.cancel();
    _voiceService.dispose();
    _localModel.removeListener(_onLocalModelChanged);
    unawaited(_localModel.disposeEngine());
    super.dispose();
  }
}

