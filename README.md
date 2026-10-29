# 🔮 Lucy - Screen-Aware AI Assistant

Lucy is a screen-aware AI companion powered by Google Gemini and local action intelligence. Lucy understands what's on screen and interprets commands via voice or text input, planning actions, navigating apps, and interacting with you in English, Japanese, or Arabic.

---

## 🌟 Key Features

- **Screen-Aware Reasoning**: Analyzes screenshots and accessibility trees to understand active apps and UI components.
- **Voice & Text Interaction**: Supports natural speech recognition, text-to-speech feedback, and direct keyboard command input.
- **Gemini Multimodal Intelligence**: Powered by `gemini-2.5-flash` with structured JSON action output (`tap`, `open_app`, `type`, `swipe`, `back`, `home`, `wait`).
- **Deterministic Local Commands**: Offline commands like *"open youtube"*, *"open settings"*, *"go back"*, *"go home"*, *"repeat that"*, and *"stop listening"*.
- **Multi-Language Support**: Seamlessly communicates in English, Japanese (日本語), and Arabic (العربية) with automatic locale switching.
- **Privacy & Policy Controls**: Granular settings for AI provider mode (`Cloud Preferred`, `Local First`, `Local Only`), Gemini cloud data consent, speech rate, and session timeouts.

---

## 🏗️ Architecture

```
User Command (Voice / Text)
        │
        ▼
   AgentController
        │
        ├──▶ LocalCommandRouter (Deterministic offline routes: open_app, back, home, etc.)
        │
        └──▶ AiService (Gemini 2.5 Flash + Vision & Accessibility Tree)
                 │
                 ├──▶ UI Tree & Dimensions Resolution
                 ├──▶ Tap-by-Element Bounds Translation
                 └──▶ VoiceService (TTS response + status updates)
```

---

## ⚙️ Configuration & Secrets

- **Gemini API Key**: Automatically detected from the environment or entered securely via the in-app Gemini Key Dialog / Settings panel.
- **Provider Modes**:
  - `Cloud Preferred`: Leverages Gemini multimodal capabilities with fast response times.
  - `Local First`: Tries offline deterministic models first, with optional Gemini cloud fallback.
  - `Local Only`: Restricts all execution to device-only commands.
