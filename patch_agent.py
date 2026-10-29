from pathlib import Path

p = Path("lib/services/ai_service.dart")
s = p.read_text()

start = "  Future<AgentResponse> agentChat("
end = "  void cancelLocalGeneration()"

if s.count(start) != 1 or s.count(end) != 1:
    raise SystemExit("STOP: Could not identify agentChat boundaries safely.")

a = s.index(start)
b = s.index(end, a)

replacement = r'''  Future<AgentResponse> agentChat(
    String message, {
    Uint8List? imageBytes,
    Map<String, int>? screenSize,
    String? uiTree,
    void Function(String token)? onToken,
  }) async {
    if (!localModel.isReady) {
      _lastProvider = localModel.hasSelectedModel ? 'ERROR' : 'NO MODEL';
      return AgentResponse.fallback(
        localModel.hasSelectedModel
            ? 'The local model is selected but not loaded. Load it in Settings.'
            : 'No local GGUF model is loaded. Select and load your Qwen model in Settings.',
      );
    }

    _lastProvider = 'LOCAL';

    try {
      final boundedTree = uiTree == null
          ? null
          : (uiTree.length <= 16000 ? uiTree : uiTree.substring(0, 16000));

      final prompt = StringBuffer()
        ..writeln('USER_REQUEST:')
        ..writeln(message)
        ..writeln();

      if (screenSize != null) {
        prompt.writeln(
          'SCREEN_SIZE: ${screenSize['width']}x${screenSize['height']} pixels',
        );
      }

      if (boundedTree != null) {
        prompt
          ..writeln('UNTRUSTED_ACCESSIBILITY_TREE:')
          ..writeln(boundedTree)
          ..writeln('END_UNTRUSTED_ACCESSIBILITY_TREE');
      }

      // Qwen is text-only; never transmit image bytes to a cloud service.
      final text = await localModel.generateAgentResponse(
        _localSystemPrompt,
        prompt.toString(),
        onToken: onToken,
      );

      return parseAgentResponse(text, screenSize: screenSize);
    } catch (error) {
      if (error is LocalGenerationCancelledException) {
        return AgentResponse.fallback('Local generation cancelled.');
      }

      return AgentResponse.fallback(
        'Local inference failed. ${localModel.lastError ?? 'Check that the model is loaded, then retry.'}',
      );
    }
  }

'''

s = s[:a] + replacement + s[b:]
p.write_text(s)
print("SUCCESS: agentChat now uses local inference only.")
