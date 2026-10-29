from pathlib import Path

p = Path("lib/services/ai_service.dart")
s = p.read_text()

def replace_once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"STOP: Expected one match for {label}, found {count}")
    s = s.replace(old, new, 1)

replace_once(
'''  bool get requiresScreenshot =>
      _providerMode != AiProviderMode.localOnly &&
      (_providerMode == AiProviderMode.cloudPreferred
          ? mayUseGemini()
          : !localModel.isReady &&
                mayUseGemini(localUnavailableOrFailed: true));''',
'''  bool get requiresScreenshot => false;''',
"requiresScreenshot",
)

start = s.index("  Future<void> initialize() async {")
end = s.index("  String get activeProviderStatus {", start)

s = s[:start] + '''  Future<void> initialize() async {
    await localModel.initialize();
    final prefs = await SharedPreferences.getInstance();

    // Lucy is local-only: ignore and clear legacy cloud preferences.
    _apiKey = null;
    _providerMode = AiProviderMode.localOnly;
    _cloudFallbackEnabled = false;
    _allowGeminiData = false;

    await prefs.setString(_providerModeKey, AiProviderMode.localOnly.name);
    await prefs.setBool(_cloudFallbackKey, false);
    await prefs.setBool(_allowGeminiDataKey, false);
    await prefs.remove(_apiKeyPrefKey);
  }

  Future<void> setProviderMode(AiProviderMode mode) async {
    _providerMode = AiProviderMode.localOnly;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerModeKey, AiProviderMode.localOnly.name);
  }

  Future<void> setCloudFallbackEnabled(bool enabled) async {
    _cloudFallbackEnabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cloudFallbackKey, false);
  }

  Future<void> setAllowGeminiData(bool enabled) async {
    _allowGeminiData = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowGeminiDataKey, false);
  }

''' + s[end:]

p.write_text(s)
print("SUCCESS: local-only settings enforced.")
