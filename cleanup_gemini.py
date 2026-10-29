from pathlib import Path
import re
import shutil

p = Path("lib/services/ai_service.dart")
s = p.read_text()

backup = p.with_suffix(".dart.pre_gemini_cleanup")
shutil.copy2(p, backup)

def replace_once(pattern, replacement, label):
    global s
    s2, count = re.subn(pattern, replacement, s, count=1, flags=re.S)
    if count != 1:
        shutil.copy2(backup, p)
        raise SystemExit(f"STOP: expected one match for {label}; restored backup.")
    s = s2

# Remove Gemini configuration fields.
replace_once(
    r"  GenerativeModel\? _model;\s*\n"
    r"  ChatSession\? _chat;\s*\n"
    r"  String\? _apiKey;\s*\n",
    "",
    "Gemini fields",
)

# Remove the Gemini API-key preference constant and related getters.
replace_once(
    r"  static const _apiKeyPrefKey = 'lucy_gemini_api_key';\s*\n"
    r"  String\? get apiKey => _apiKey;\s*\n"
    r"  bool get isConfigured => _apiKey != null && _apiKey!\.isNotEmpty;\s*\n",
    "",
    "Gemini preference/getters",
)

# Remove the legacy Gemini system prompt.
replace_once(
    r"  static const _systemPrompt = '''.*?''';\s*\n",
    "",
    "Gemini system prompt",
)

# Remove configure() and the obsolete Gemini chat method.
replace_once(
    r"  void configure\(String apiKey\) \{.*?\n  \}\s*\n",
    "",
    "configure method",
)

replace_once(
    r"  Future<AgentResponse> _geminiChat\(.*?\n  \}\s*\n",
    "",
    "_geminiChat method",
)

# Remove resetChat(), which only resets Gemini chat history.
replace_once(
    r"  /// Reset chat history for a fresh conversation\.\s*\n"
    r"  void resetChat\(\) \{.*?\n  \}\s*\n",
    "",
    "resetChat method",
)

# Save only after all expected sections were removed.
p.write_text(s)
print(f"Cleaned Gemini-only code. Backup: {backup}")
