from pathlib import Path

p = Path("lib/services/ai_service.dart")
s = p.read_text()

old = """  bool mayUseGemini({bool localUnavailableOrFailed = false}) {
    if (!isConfigured || !_allowGeminiData) return false;
    return switch (_providerMode) {
      AiProviderMode.localOnly => false,
      AiProviderMode.localFirst =>
        _cloudFallbackEnabled && localUnavailableOrFailed,
      AiProviderMode.cloudPreferred => true,
    };
  }"""

new = """  bool mayUseGemini({bool localUnavailableOrFailed = false}) => false;"""

if s.count(old) != 1:
    raise SystemExit("STOP: Gemini policy method did not match exactly.")

s = s.replace(old, new, 1)

# Make the local model the only reported request capability.
old2 = """  bool get canInterpretRequests =>
      localModel.isReady ||
      mayUseGemini(localUnavailableOrFailed: !localModel.isReady);"""

new2 = """  bool get canInterpretRequests => localModel.isReady;"""

if s.count(old2) != 1:
    raise SystemExit("STOP: capability getter did not match exactly.")

s = s.replace(old2, new2, 1)

p.write_text(s)
print("SUCCESS: Gemini policy disabled; request capability is local-only.")
