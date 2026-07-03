# Cleanup

Highlight text anywhere → hotkey → an LLM rewrites it. Pick from 1–5 variants, tune with follow-up instructions, replace the original in place.

Two native apps sharing the same design (Mono theme, follows system dark/light):

- **mac/** — Swift menubar app (macOS)
- **windows/** — C#/WPF tray app (Windows 10/11)

## Backends

| Backend | Setup |
|---|---|
| Ollama (local) | Install [Ollama](https://ollama.com), pull a model (`ollama pull llama3.2:3b`). Free, private. |
| ChatGPT subscription | Uses your Codex CLI login — see below. Model: `gpt-5.5` (only model OpenAI allows on this path). |
| OpenAI-compatible API | Any base URL + API key (OpenAI, OpenRouter, etc). |

### ChatGPT subscription setup (both platforms)

1. `npm install -g @openai/codex`
2. `codex login` → browser opens, sign in with your ChatGPT account
3. That's it — Cleanup reads `~/.codex/auth.json` and calls the same backend Codex uses.

If it stops working (token lasts ~10 days), run `codex` once in a terminal to refresh. The Settings window shows live login status.

## macOS

```bash
cd mac
bash build.sh install   # builds + installs to /Applications + registers the right-click Service
```

- **Trigger 1:** select text, hit **⌃⌘E** (works in every app, incl. Chrome/Electron)
- **Trigger 2:** right-click selected text → **Services → Clean Up Message** (native apps only — Chrome/Electron draw their own menus and never show Services)
- First run: grant the Accessibility prompt (needed for selection capture + Replace paste)
- Only the /Applications copy may be registered — `build.sh install` unregisters the build copy; two registered bundles fight over the service port

## Windows

**Easiest:** grab `CleanupSetup.exe` from [Releases](https://github.com/AbhiPoluri/cleanup-app/releases) — self-contained (no .NET needed), per-user install (no admin), with checkboxes for Start Menu shortcut, desktop shortcut, and run-at-signin. Built by CI from `installer/cleanup.iss`; cut a new one by pushing a `v*` tag.

**From source:** needs the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd windows
dotnet run
```

- Tray icon ✦ appears; select text in any app, hit **Ctrl+Shift+E**
- Tray menu → Test Popup opens the popup with sample text (no selection needed)
- Settings live at `%APPDATA%\Cleanup\settings.json`
- To make a standalone exe: `dotnet publish -c Release -r win-x64 --self-contained`

## Popup keys

| Key | Action |
|---|---|
| ⌘1–5 / Ctrl+1–5 | select a variant card |
| ⌘R / Ctrl+R | regenerate all |
| ⌘↩ / Ctrl+Enter | replace the original selection |
| Esc | cancel |

Type in the "tune it…" bar to refine the selected card ("shorter", "less formal", "keep the joke").

## Notes

- The variant slider (1–5) controls how many rewrites you get per shot; each follows a distinct brief (balanced / polished / compressed / fuller / minimal edit) so they're actually different.
- API keys are stored in plain text (UserDefaults / settings.json). Fine for personal use; don't put shared-machine secrets in there.
- Windows has a second trigger: select text with the mouse and a small ✦ button fades in near the selection — click it to open the popup. Toggle it off in Settings if it annoys you.
