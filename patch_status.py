from pathlib import Path

p = Path("lib/services/ai_service.dart")
s = p.read_text()

start = "  String get activeProviderStatus {"
end = "  static const _systemPrompt = '''"

if s.count(start) != 1 or s.count(end) != 1:
    raise SystemExit("STOP: Could not safely locate provider status block.")

a = s.index(start)
b = s.index(end, a)

replacement = """  String get activeProviderStatus {
    if (localModel.state == LocalModelState.loading) return 'LOADING';

    if (localModel.state == LocalModelState.inferenceFailed ||
        localModel.state == LocalModelState.runtimeInitializationFailed ||
        localModel.state == LocalModelState.unsupportedModel ||
        localModel.state == LocalModelState.invalidModel ||
        localModel.state == LocalModelState.insufficientMemory) {
      return 'ERROR';
    }

    if (localModel.isReady) return 'LOCAL';
    return 'NO MODEL';
  }

"""

s = s[:a] + replacement + s[b:]
p.write_text(s)
print("SUCCESS: Provider status now reports local inference only.")
