import Cocoa
import SwiftUI
import Combine
import CoreGraphics
import Network
import Security
import Speech
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import UniformTypeIdentifiers

// MARK: - Settings keys

enum Keys {
    static let backend = "backend"                // "ollama" | "openai" | "chatgpt" | "claude"
    static let chatgptModel = "chatgptModel"
    static let chatgptEffort = "chatgptEffort"    // "low" | "medium" | "high"
    static let claudeModel = "claudeModel"        // Claude Code CLI alias: "haiku" | "sonnet" | "opus"
    static let ollamaURL = "ollamaURL"
    static let ollamaModel = "ollamaModel"
    static let apiBase = "apiBase"
    static let apiKey = "apiKey"
    static let apiModel = "apiModel"
    static let defaultTone = "defaultTone"
    static let defaultCount = "defaultCount"
    static let autoClose = "autoClose"            // close popup on click-away (default false)
    static let diffView = "diffView"              // inline diff panel toggled (default false)
    static let fontSize = "fontSize"              // popup content text size (11–18, default 13)
    static let popupWidth = "popupWidth"          // last popup size, restored next open
    static let popupHeight = "popupHeight"
    static let floatingButton = "floatingButton"  // master: show chips on selection (default true)
    static let chipStar = "chipStar"              // ✦ open-popup chip enabled (default true)
    static let chipBolt = "chipBolt"              // ⚡ instant-rewrite chip enabled (default true)
    static let chipAgent = "chipAgent"            // 🤖 agent chip enabled (default true; also needs CLI)
    static let chipSnip = "chipSnip"              // ✂ snip→agent chip enabled (default true)
    static let buttonSize = "buttonSize"          // floating chip size (22–48, default 30)
    // Agent mode — independent of the rewrite backend above.
    static let agentEngine = "agentEngine"        // "claude" | "codex"
    static let agentModel = "agentModel"          // engine-specific alias (custom allowed)
    static let agentPermission = "agentPermission"// "safe" | "standard" | "full"
    static let agentContext = "agentContext"      // GLOBAL personal context → every project's CLAUDE.md/AGENTS.md
    static let currentProject = "currentProject"  // slug of the project agent/whiteboard use as cwd (default "default")
    static let agentWidth = "agentWidth"          // last agent-window size, restored next open
    static let agentHeight = "agentHeight"
    // Whiteboard mode — a persistent selected-agent session watching a physical board.
    static let whiteboardWidth = "whiteboardWidth"    // last whiteboard-window size
    static let whiteboardHeight = "whiteboardHeight"
    static let whiteboardCorners = "whiteboardCorners"// [Double] normalized quad (TL,TR,BR,BL as x,y pairs)
    static let whiteboardAutoLook = "whiteboardAutoLook"  // ambient auto-snapshot on stable+changed (default OFF; look-on-request is primary)
    static let whiteboardMuted = "whiteboardMuted"    // mute the spoken responses (default false)
    static let whiteboardMic = "whiteboardMic"        // open-mic voice input (default true)
    static let whiteboardWakePhrase = "whiteboardWakePhrase"  // spoken wake phrase gating mic sends (default "hey board"; empty = all through)
    static let whiteboardPreviewMode = "whiteboardPreviewMode"  // "raw" (camera + pin overlay) | "board" (live dewarped crop)
    static let whiteboardPreviewUserSet = "whiteboardPreviewUserSet" // true once the user has flipped the preview toggle (suppresses auto-suggest)
    static let whiteboardPinnedOnce = "whiteboardPinnedOnce"    // true once corners have been committed at least once (drives board-default auto-suggest)
    static let whiteboardCamera = "whiteboardCamera"            // AVCaptureDevice.uniqueID of the chosen camera ("" = system default)
    static let whiteboardSounds = "whiteboardSounds"            // across-the-room audio cues (default true)
    static let didOnboard = "didOnboard"              // first-run welcome shown + dismissed (default false)
    static let settingsWidth = "settingsWidth"        // last Settings window size (content DIPs), restored next open
    static let settingsHeight = "settingsHeight"
    // Local voice engines (Parakeet ASR + Kokoro TTS via the managed venv helper).
    static let voiceASR = "voiceASR"                  // "system" (Apple SFSpeech) | "parakeet" (local)
    static let voiceTTS = "voiceTTS"                  // "system" (AVSpeech) | "kokoro" (local)
    static let kokoroVoice = "kokoroVoice"            // Kokoro voice name (default "af_heart")
}

func defaults() -> UserDefaults { UserDefaults.standard }

func logLine(_ msg: String) { NSLog("[Cleanup] %@", msg) }

func registerDefaults() {
    defaults().register(defaults: [
        Keys.backend: "ollama",
        Keys.ollamaURL: "http://localhost:11434",
        Keys.ollamaModel: "llama3.2:3b",
        Keys.apiBase: "https://api.openai.com",
        Keys.apiModel: "gpt-4o-mini",
        Keys.chatgptModel: "gpt-5.5",
        Keys.chatgptEffort: "low",
        Keys.claudeModel: "haiku",
        Keys.defaultTone: "Clean",
        Keys.defaultCount: 3,
        Keys.autoClose: false,
        Keys.diffView: false,
        Keys.fontSize: 13.0,
        Keys.popupWidth: 620.0,
        Keys.popupHeight: 500.0,
        Keys.floatingButton: true,
        Keys.chipStar: true,
        Keys.chipBolt: true,
        Keys.chipAgent: true,
        Keys.chipSnip: true,
        Keys.buttonSize: 30.0,
        // Agent work deserves a stronger default than the rewrite backend's haiku.
        Keys.agentEngine: "claude",
        Keys.agentModel: "sonnet",
        Keys.agentPermission: "safe",
        Keys.agentContext: "",
        Keys.currentProject: "default",
        Keys.agentWidth: 560.0,
        Keys.agentHeight: 640.0,
        Keys.whiteboardWidth: 900.0,
        Keys.whiteboardHeight: 620.0,
        // default quad = 10% inset rectangle, normalized (TL, TR, BR, BL) top-left origin.
        Keys.whiteboardCorners: [0.1, 0.1, 0.9, 0.1, 0.9, 0.9, 0.1, 0.9],
        // Ambient auto-look is now OFF by default — the primary look triggers are the
        // "Look now" button and spoken/typed look requests. Kept as an opt-in for ambient fans.
        Keys.whiteboardAutoLook: false,
        Keys.whiteboardMuted: false,
        Keys.whiteboardMic: true,
        Keys.whiteboardWakePhrase: "hey board",
        // Preview starts on the raw camera (so pinning is the first thing you do); once corners
        // have been pinned once, the engine defaults future opens to the dewarped "board" view.
        Keys.whiteboardPreviewMode: "raw",
        Keys.whiteboardSounds: true,
        Keys.didOnboard: false,
        Keys.settingsWidth: 760.0,
        Keys.settingsHeight: 560.0,
        Keys.voiceASR: "system",
        Keys.voiceTTS: "system",
        Keys.kokoroVoice: "af_heart",
    ])
}

// popup content text size, clamped to the supported 11–18 range.
func contentFontSize() -> CGFloat {
    let v = defaults().double(forKey: Keys.fontSize)
    return CGFloat(min(18, max(11, v == 0 ? 13 : v)))
}

// floating chip size, clamped to the supported 22–48 range.
func floatingButtonSize() -> CGFloat {
    let v = defaults().double(forKey: Keys.buttonSize)
    return CGFloat(min(48, max(22, v == 0 ? 30 : v)))
}

// MARK: - Mono palette (locked visual spec: zero hue, dark/light pair)

struct Pal {
    let surface: Color, surface2: Color, surface3: Color
    let line: Color, lineStrong: Color
    let text: Color, muted: Color, faint: Color
    let accent: Color, onAccent: Color
    // Diff-only colours — the single sanctioned exception to the zero-hue rule.
    // GitHub-style muted red/green, used exclusively inside the diff viewer
    // (inline panel + pop-out). Everything else in the app stays mono.
    let diffAddText: Color, diffAddBg: Color, diffDelText: Color, diffDelBg: Color

    static let dark = Pal(
        surface: Color(hex: 0x1C1C1C), surface2: Color(hex: 0x262626), surface3: Color(hex: 0x303030),
        line: Color.white.opacity(0.10), lineStrong: Color.white.opacity(0.20),
        text: Color(hex: 0xF2F2F2), muted: Color(hex: 0x9E9E9E), faint: Color(hex: 0x6E6E6E),
        accent: Color(hex: 0xF2F2F2), onAccent: Color(hex: 0x111111),
        // GitHub-dark diff palette: soft red/green text on ~25% tinted fills.
        diffAddText: Color(hex: 0x85E89D), diffAddBg: Color(hex: 0x1F6F3A).opacity(0.25),
        diffDelText: Color(hex: 0xF97583), diffDelBg: Color(hex: 0x8B1E2B).opacity(0.25))

    static let light = Pal(
        surface: Color(hex: 0xFCFCFB), surface2: Color(hex: 0xF1F1EF), surface3: Color(hex: 0xE4E4E1),
        line: Color.black.opacity(0.09), lineStrong: Color.black.opacity(0.18),
        text: Color(hex: 0x1A1A18), muted: Color(hex: 0x5F5F5C), faint: Color(hex: 0x93938F),
        accent: Color(hex: 0x1A1A18), onAccent: Color(hex: 0xFCFCFB),
        // GitHub-light diff palette: deep red/green text on pale tinted fills.
        diffAddText: Color(hex: 0x22863A), diffAddBg: Color(hex: 0xE6FFED),
        diffDelText: Color(hex: 0xCB2431), diffDelBg: Color(hex: 0xFFEEF0))

    static func of(dark isDark: Bool) -> Pal { isDark ? .dark : .light }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - LLM backends

enum LLMError: LocalizedError {
    case badResponse(String)
    var errorDescription: String? {
        if case .badResponse(let s) = self { return s }
        return "LLM error"
    }
}

// Rate-limits the display-only partial callback so token-per-event traffic can't
// jank the UI. First partial fires immediately (words on screen ~1s in); later
// ones at most every 80ms. Materialises the accumulated string only when it
// actually emits. The FINAL text always comes from the backend's return value —
// this path is purely for perceived speed. Lives on the single streaming task,
// so its mutable state needs no locking. (Mirrors Windows Llm.PartialThrottle.)
final class PartialThrottle {
    private let minInterval: TimeInterval = 0.08
    private let cb: (@Sendable (String) -> Void)?
    private let start = Date()
    private var lastEmit: TimeInterval = -1
    init(_ cb: (@Sendable (String) -> Void)?) { self.cb = cb }
    func offer(_ acc: String) {
        guard let cb else { return }
        let now = Date().timeIntervalSince(start)
        if lastEmit >= 0, now - lastEmit < minInterval { return }
        lastEmit = now
        cb(acc)
    }
}

enum LLM {
    static func complete(system: String, user: String,
                         onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let d = defaults()
        let backend = d.string(forKey: Keys.backend) ?? "ollama"
        let raw: String
        switch backend {
        case "openai": raw = try await openAI(system: system, user: user, onPartial: onPartial)
        case "chatgpt": raw = try await chatGPT(system: system, user: user, onPartial: onPartial)
        case "claude": raw = try await claude(system: system, user: user, onPartial: onPartial)
        default: raw = try await ollama(system: system, user: user, onPartial: onPartial)
        }
        return clean(raw)
    }

    // Ollama with stream:true → newline-delimited JSON. Each line carries a
    // message.content fragment; the final one has done:true. Same accumulated-
    // callback contract as the remote backends.
    private static func ollama(system: String, user: String,
                               onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        let d = defaults()
        let base = d.string(forKey: Keys.ollamaURL) ?? "http://localhost:11434"
        guard let url = URL(string: base + "/api/chat") else { throw LLMError.badResponse("Bad Ollama URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": d.string(forKey: Keys.ollamaModel) ?? "llama3.2:3b",
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.badResponse("Ollama HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let throttle = PartialThrottle(onPartial)
        var out = ""
        for try await line in bytes.lines {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let msg = obj["message"] as? [String: Any],
               let frag = msg["content"] as? String, !frag.isEmpty {
                out += frag
                throttle.offer(out)
            }
            if let done = obj["done"] as? Bool, done { break }
        }
        guard !out.isEmpty else { throw LLMError.badResponse("Ollama: empty response") }
        return out
    }

    private static func validEffort(_ e: String?) -> String {
        switch e { case "low", "medium", "high": return e! default: return "low" }
    }

    // OpenAI-compatible with stream:true → SSE. Each "data: {…}" line carries
    // choices[0].delta.content; "data: [DONE]" terminates. Keep-alive comment
    // lines (": …") don't start with "data: " so they're skipped.
    private static func openAI(system: String, user: String,
                               onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        let d = defaults()
        var base = (d.string(forKey: Keys.apiBase) ?? "https://api.openai.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // accept bases with or without a trailing /v1 (OpenRouter documents
        // https://openrouter.ai/api/v1, OpenAI documents https://api.openai.com)
        if !base.lowercased().hasSuffix("/v1") { base += "/v1" }
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badResponse("Bad API base URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(d.string(forKey: Keys.apiKey) ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": d.string(forKey: Keys.apiModel) ?? "gpt-4o-mini",
            "stream": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.badResponse("API: no response") }
        guard http.statusCode == 200 else {
            // drain the stream so we can surface the server's error message
            var raw = ""
            for try await line in bytes.lines { raw += line + "\n" }
            var detail = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                detail = msg
            }
            if detail.count > 200 { detail = String(detail.prefix(200)) + "…" }
            throw LLMError.badResponse("API HTTP \(http.statusCode): \(detail.isEmpty ? "no response body" : detail)")
        }
        let throttle = PartialThrottle(onPartial)
        var out = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = ev["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let frag = delta["content"] as? String, !frag.isEmpty else { continue }
            out += frag
            throttle.offer(out)
        }
        guard !out.isEmpty else { throw LLMError.badResponse("API: empty response") }
        return out
    }

    // ChatGPT subscription via Codex CLI login (~/.codex/auth.json).
    // The codex backend only serves models it allows for ChatGPT accounts (gpt-5.5 as of 2026-07)
    // and only speaks SSE, so stream:true is mandatory.
    private static func chatGPT(system: String, user: String,
                                onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        let authPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let authData = try? Data(contentsOf: authPath),
              let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let accountId = tokens["account_id"] as? String else {
            throw LLMError.badResponse("No Codex login — run `codex login` in Terminal")
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": defaults().string(forKey: Keys.chatgptModel) ?? "gpt-5.5",
            "instructions": system,
            "input": [[
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": user]],
            ]],
            "stream": true,
            "store": false,
            // low effort ≈3x faster for short rewrites; also required for
            // gpt-5.4-mini, which stalls at its default effort (probed 2026-07-09)
            "reasoning": ["effort": validEffort(defaults().string(forKey: Keys.chatgptEffort))],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.badResponse("ChatGPT: no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LLMError.badResponse("ChatGPT token expired — run `codex` once to refresh")
        }
        guard http.statusCode == 200 else {
            throw LLMError.badResponse("ChatGPT HTTP \(http.statusCode)")
        }

        let throttle = PartialThrottle(onPartial)
        var out = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let data = line.dropFirst(6).data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                out += (ev["delta"] as? String) ?? ""
                throttle.offer(out)   // live tokens into the card (throttled)
            case "response.completed":
                return out
            case "response.failed", "error":
                throw LLMError.badResponse("ChatGPT: generation failed")
            default:
                break
            }
        }
        guard !out.isEmpty else { throw LLMError.badResponse("ChatGPT: empty response") }
        return out
    }

    // Claude Code subscription via the `claude` CLI in headless print mode. Reuses
    // the user's Claude Code login — no API key. Streams stream-json JSONL from the
    // child's stdout: `stream_event` lines wrap Anthropic SSE (content_block_delta →
    // text_delta) for the live partial; the final `result` line carries the
    // authoritative full text (is_error → throw with the stderr tail). Slow option
    // (~8-10s: CLI boot + session setup + API) — streaming softens the wait.
    private static func claude(system: String, user: String,
                               onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        guard let cli = ClaudeCLI.resolve() else {
            throw LLMError.badResponse("Claude Code CLI not found — install it and run `claude` once to log in")
        }
        let model = defaults().string(forKey: Keys.claudeModel) ?? "haiku"
        let start = Date()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        // --append-system-prompt injects Prompts.system; --strict-mcp-config + empty
        // --mcp-config and disableAllHooks stop the user's MCP servers / hooks from
        // loading (safety + boot time).
        proc.arguments = [
            "-p", user,
            "--model", model,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--append-system-prompt", system,
            "--strict-mcp-config",
            "--mcp-config", "{\"mcpServers\":{}}",
            "--settings", "{\"disableAllHooks\":true}",
        ]
        // Finder-launched apps don't inherit a login-shell PATH; give the CLI (and any
        // node it shells out to) the usual install dirs so it can find its runtime.
        proc.environment = ClaudeCLI.env()
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() }
        catch { throw LLMError.badResponse("Claude CLI failed to start — \(error.localizedDescription)") }

        // drain stderr concurrently so a full pipe can't deadlock the stdout read
        let stderrTask = Task<String, Never>.detached {
            let d = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(data: d, encoding: .utf8) ?? ""
        }

        return try await withTaskCancellationHandler {
            // hard 120s ceiling — terminate the child if the CLI wedges
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                if proc.isRunning { proc.terminate() }
            }
            defer { timeout.cancel() }

            let throttle = PartialThrottle(onPartial)
            var acc = ""
            var finalText: String? = nil
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                if line.isEmpty { continue }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = obj["type"] as? String else { continue }
                switch type {
                case "stream_event":
                    // wraps an Anthropic SSE event: content_block_delta → text_delta.text
                    if let evt = obj["event"] as? [String: Any],
                       evt["type"] as? String == "content_block_delta",
                       let delta = evt["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta",
                       let txt = delta["text"] as? String, !txt.isEmpty {
                        acc += txt
                        throttle.offer(acc)
                    }
                case "result":
                    // final line — authoritative full text unless flagged as an error
                    if let r = obj["result"] as? String { finalText = r }
                    if let isErr = obj["is_error"] as? Bool, isErr { finalText = nil }
                default:
                    break
                }
            }

            proc.waitUntilExit()
            let result = (finalText?.isEmpty == false) ? finalText! : acc
            if proc.terminationStatus != 0 || result.isEmpty {
                var tail = (await stderrTask.value).trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.count > 300 { tail = "…" + String(tail.suffix(300)) }
                let reason = !tail.isEmpty ? tail
                    : (proc.terminationStatus != 0 ? "exit \(proc.terminationStatus)" : "empty response")
                throw LLMError.badResponse("Claude CLI: \(reason)")
            }
            logLine("llm ok backend=claude model=\(model) total=\(Int(Date().timeIntervalSince(start) * 1000))ms")
            return result
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // models sometimes wrap the rewrite in quotes
        if t.count > 1, (t.first == "\"" && t.last == "\"") || (t.first == "“" && t.last == "”") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}

// MARK: - Claude Code CLI resolution

// Locates the `claude` CLI for the headless backend + Settings status box. Finder-
// launched apps don't inherit a login-shell PATH, so we probe the known install
// dirs first, then fall back to a login shell's `command -v`. Successful lookups
// are cached; a not-found stays uncached so installing mid-session re-probes.
enum ClaudeCLI {
    nonisolated(unsafe) private static var cached: String?

    private static var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func resolve() -> String? {
        if let c = cached, FileManager.default.isExecutableFile(atPath: c) { return c }
        let home = homePath
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            cached = p; return p
        }
        // login-shell fallback: picks up nvm / custom PATH installs
        if let p = loginShellWhich(), FileManager.default.isExecutableFile(atPath: p) {
            cached = p; return p
        }
        return nil
    }

    // Prepend the common install dirs to PATH so the CLI (and any node it needs) is
    // findable regardless of how the app was launched.
    static func env() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = homePath
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
        env["PATH"] = (extra + [LoginShell.path]).joined(separator: ":")
        return env
    }

    private static func loginShellWhich() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard let d = try? pipe.fileHandleForReading.readToEnd(),
              let s = String(data: d, encoding: .utf8) else { return nil }
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // `claude --version` for the Settings status box. Returns (message, healthy).
    static func status() async -> (String, Bool) {
        guard let cli = resolve() else {
            return ("Claude Code CLI not found — install it and run `claude` once to log in", false)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["--version"]
        proc.environment = env()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return ("Found at \(cli) — couldn't run it", false) }
        proc.waitUntilExit()
        let out = ((try? pipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return ("Found (\(out)) — using your Claude Code login, no API key", true) }
        return ("Found at \(cli) — using your Claude Code login, no API key", true)
    }
}

// MARK: - Login-shell PATH

// Finder-launched apps inherit a bare PATH (/usr/bin:/bin) — node installed via nvm,
// homebrew tools, etc. are invisible, so node-shebang CLIs (codex) die with
// "env: node: No such file or directory". The user's login shell knows the real PATH;
// resolve it once and cache it (falls back to the process PATH on any failure).
enum LoginShell {
    nonisolated(unsafe) private static var cached: String?

    static var path: String {
        if let c = cached { return c }
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { cached = fallback; return fallback }
        proc.waitUntilExit()
        let out = ((try? pipe.fileHandleForReading.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = out.isEmpty ? fallback : out
        cached = result
        return result
    }

    // `command -v <cmd>` through a login shell (real PATH). Used by the Health
    // panel to verify node is reachable for the Codex CLI. Not cached — a
    // mid-session install should show up on the next refresh.
    static func which(_ cmd: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v \(cmd)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard let d = try? pipe.fileHandleForReading.readToEnd(),
              let s = String(data: d, encoding: .utf8) else { return nil }
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

// MARK: - Codex CLI resolution

// Locates the `codex` CLI for Agent mode + the Agent-settings status box. Mirrors
// ClaudeCLI exactly (probe known install dirs, login-shell fallback, cache hits).
enum CodexCLI {
    nonisolated(unsafe) private static var cached: String?

    private static var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func resolve() -> String? {
        if let c = cached, FileManager.default.isExecutableFile(atPath: c) { return c }
        let home = homePath
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            cached = p; return p
        }
        if let p = loginShellWhich(), FileManager.default.isExecutableFile(atPath: p) {
            cached = p; return p
        }
        return nil
    }

    static func env() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = homePath
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [LoginShell.path]).joined(separator: ":")
        return env
    }

    private static func loginShellWhich() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard let d = try? pipe.fileHandleForReading.readToEnd(),
              let s = String(data: d, encoding: .utf8) else { return nil }
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // `codex --version` for the Agent-settings status box. Returns (message, healthy).
    static func status() async -> (String, Bool) {
        guard let cli = resolve() else {
            return ("Codex CLI not found — npm i -g @openai/codex, then run `codex login`", false)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cli)
        proc.arguments = ["--version"]
        proc.environment = env()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return ("Found at \(cli) — couldn't run it", false) }
        proc.waitUntilExit()
        let out = ((try? pipe.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return ("Found (\(out)) — using your ChatGPT login, no API key", true) }
        return ("Found at \(cli) — using your ChatGPT login, no API key", true)
    }
}

// MARK: - Agent engine selection

// Thin accessor over the Agent-mode defaults (engine / model / permission). These
// are wholly independent of the rewrite Backend — Agent mode has its own settings.
enum AgentCLI {
    static var engine: String { defaults().string(forKey: Keys.agentEngine) ?? "claude" }

    static var model: String {
        let m = (defaults().string(forKey: Keys.agentModel) ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? AgentModels.defaultModel(engine) : m
    }

    static var permission: String { defaults().string(forKey: Keys.agentPermission) ?? "safe" }

    // Resolve the selected engine's CLI (full probe, cached in the CLI enums).
    static func resolve() -> String? {
        engine == "codex" ? CodexCLI.resolve() : ClaudeCLI.resolve()
    }

    // Whether the selected engine's CLI is present — gates the 🤖 chip and the
    // tray "Agent task…" item.
    static var available: Bool { resolve() != nil }
}

// Model aliases offered per agent engine (custom values still allowed via the picker).
enum AgentModels {
    static let claude = ["sonnet", "opus", "haiku"]
    static let codex = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
    static func list(_ engine: String) -> [String] { engine == "codex" ? codex : claude }
    static func defaultModel(_ engine: String) -> String { engine == "codex" ? "gpt-5.5" : "sonnet" }
}

// Which flavour of screen capture the ✂ chip / menu asked for.
enum SnipMode { case area, window, full }

// MARK: - Local voice engines (Parakeet ASR + Kokoro TTS via a managed venv helper)
//
// A single persistent Python helper (bear-cam pattern: JSON lines over stdin/stdout, models
// lazy-load on first use) does both ASR (onnx-asr Parakeet TDT 0.6B v3) and TTS (kokoro-onnx).
// The Swift side owns spawn/kill + request/response correlation (single in-flight, serialized
// on `io`). Availability = venv present + ping ok. Everything degrades transparently to the
// Apple/system path when unavailable, so this is purely additive.

// Where the managed venv + helper live. Mirrors the Windows agent's layout so the helper
// contract is identical cross-platform.
enum VoicePaths {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Cleanup/voice", isDirectory: true)
    }
    static var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    static var python: URL { venv.appendingPathComponent("bin/python") }
    static var helper: URL { root.appendingPathComponent("helper.py") }
    static var installLog: URL { root.appendingPathComponent("install.log") }
}

// Install phase surfaced in the Settings "Voice" row.
enum VoiceInstallPhase: Equatable {
    case idle
    case installing(String)   // human-readable step
    case installed(String)    // short version line
    case failed(String)       // reason + log pointer
}

// MainActor-observable snapshot of local-voice state for Settings + Health. VoiceEngine (which
// runs its process I/O off-main) pushes updates here.
@MainActor
final class VoiceStatus: ObservableObject {
    static let shared = VoiceStatus()
    @Published var venvPresent = FileManager.default.isExecutableFile(atPath: VoicePaths.python.path)
    @Published var asrReady = false      // helper ping: onnx_asr importable
    @Published var ttsReady = false      // helper ping: kokoro_onnx importable
    @Published var pinged = false        // a ping has resolved at least once
    @Published var install: VoiceInstallPhase = .idle

    func refreshVenv() { venvPresent = FileManager.default.isExecutableFile(atPath: VoicePaths.python.path) }
}

final class VoiceEngine {
    static let shared = VoiceEngine()

    private let io = DispatchQueue(label: "com.abhiram.cleanup.voice.io")       // serializes helper requests
    private let watchdogQ = DispatchQueue(label: "com.abhiram.cleanup.voice.wd")
    private var proc: Process?
    private var stdinH: FileHandle?
    private var stdoutH: FileHandle?
    private var readBuf = Data()
    private var idleKill: DispatchWorkItem?

    // ---- availability (cheap, cached) ----
    var venvPresent: Bool { FileManager.default.isExecutableFile(atPath: VoicePaths.python.path) }

    // A ping refresh; updates VoiceStatus on main. Safe to call opportunistically (window opens,
    // settings shown). No-op cost if the helper is already warm.
    func refreshAvailability() {
        guard venvPresent else {
            Task { @MainActor in VoiceStatus.shared.refreshVenv(); VoiceStatus.shared.asrReady = false; VoiceStatus.shared.ttsReady = false }
            return
        }
        ping { asr, tts in
            Task { @MainActor in
                VoiceStatus.shared.refreshVenv()
                VoiceStatus.shared.asrReady = asr
                VoiceStatus.shared.ttsReady = tts
                VoiceStatus.shared.pinged = true
            }
        }
    }

    // ---- helper source (written to disk verbatim; identical contract to the Windows agent) ----
    static let helperSource = #"""
#!/usr/bin/env python3
"""Cleanup local voice helper — Parakeet (ASR) + Kokoro (TTS).

Runs as a PERSISTENT process. Reads one JSON object per line on stdin, writes
one JSON object per line on stdout. Models lazy-load on first use of each op so
startup + ping are instant; load times are logged to stderr.

Protocol (identical on macOS + Windows):
  {"op":"ping"}                                  -> {"ok":true,"asr":bool,"tts":bool}
  {"op":"asr","path":"<wav>"}                    -> {"ok":true,"text":"..."}
  {"op":"tts","text":"...","voice":"af_heart",
   "out":"<wav>"}                                -> {"ok":true,"path":"<wav>"}
Any failure returns {"ok":false,"error":"..."} — the process never crashes on a
bad request. stdout carries ONLY protocol JSON; all diagnostics go to stderr.
"""
import sys
import json
import time
import os
import wave
import struct
import urllib.request

# Force CPU execution: the CoreML provider chokes on Parakeet's external-data ONNX
# ("model_path must not be empty"), and CPU is plenty fast for short utterances. This also
# steers kokoro-onnx (which reads ONNX_PROVIDER) onto CPU.
os.environ.setdefault("ONNX_PROVIDER", "CPUExecutionProvider")

# Lazily-populated singletons.
_asr = None
_tts = None

# Kokoro model files live next to this script (downloaded once on first TTS use).
_HERE = os.path.dirname(os.path.abspath(__file__))
_KOKORO_MODEL = os.path.join(_HERE, "kokoro-v1.0.onnx")
_KOKORO_VOICES = os.path.join(_HERE, "voices-v1.0.bin")
_KOKORO_MODEL_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
_KOKORO_VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"

# ASR model candidates, in preference order (v3 first). onnx-asr resolves these
# names to the matching Hugging Face ONNX repo and caches the download.
_ASR_MODELS = ["nemo-parakeet-tdt-0.6b-v3", "nemo-parakeet-tdt-0.6b-v2"]


def log(msg):
    sys.stderr.write("[voice-helper] " + msg + "\n")
    sys.stderr.flush()


def _read_wav_16k_mono(path):
    """Read a WAV into a float32 numpy array, mono, resampled to 16 kHz."""
    import numpy as np
    with wave.open(path, "rb") as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        sr = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
    if sw == 2:
        data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sw == 4:
        data = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    elif sw == 1:
        data = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        raise ValueError("unsupported sample width %d" % sw)
    if nch > 1:
        data = data.reshape(-1, nch).mean(axis=1)
    if sr != 16000 and len(data) > 0:
        # simple linear resample to 16 kHz
        tgt = int(round(len(data) * 16000.0 / sr))
        if tgt > 0:
            x = np.linspace(0.0, 1.0, num=len(data), endpoint=False)
            xt = np.linspace(0.0, 1.0, num=tgt, endpoint=False)
            data = np.interp(xt, x, data).astype(np.float32)
    return np.ascontiguousarray(data, dtype=np.float32)


def _load_asr():
    global _asr
    if _asr is not None:
        return _asr
    import onnx_asr
    last = None
    for name in _ASR_MODELS:
        try:
            t0 = time.time()
            _asr = onnx_asr.load_model(name, providers=["CPUExecutionProvider"])
            log("asr loaded %s in %.1fs" % (name, time.time() - t0))
            return _asr
        except Exception as e:  # try the next candidate
            last = e
            log("asr load failed for %s: %s" % (name, e))
    raise RuntimeError("could not load any Parakeet model: %s" % last)


def _ssl_context():
    # python.org framework builds ship no system CA trust; use certifi's bundle so the
    # Kokoro model download (plain urllib over https) verifies instead of failing.
    import ssl
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def _download(url, dest):
    tmp = dest + ".part"
    log("downloading %s" % os.path.basename(dest))
    t0 = time.time()
    with urllib.request.urlopen(url, timeout=120, context=_ssl_context()) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp, dest)
    log("downloaded %s (%d bytes, %.1fs)" % (os.path.basename(dest), os.path.getsize(dest), time.time() - t0))


def _load_tts():
    global _tts
    if _tts is not None:
        return _tts
    from kokoro_onnx import Kokoro
    if not os.path.exists(_KOKORO_MODEL):
        _download(_KOKORO_MODEL_URL, _KOKORO_MODEL)
    if not os.path.exists(_KOKORO_VOICES):
        _download(_KOKORO_VOICES_URL, _KOKORO_VOICES)
    t0 = time.time()
    _tts = Kokoro(_KOKORO_MODEL, _KOKORO_VOICES)
    log("tts loaded in %.1fs" % (time.time() - t0))
    return _tts


def _write_wav(path, samples, sample_rate):
    """Write a float32 numpy array to a 16-bit PCM mono WAV."""
    import numpy as np
    s = np.asarray(samples, dtype=np.float32)
    s = np.clip(s, -1.0, 1.0)
    pcm = (s * 32767.0).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sample_rate))
        w.writeframes(pcm.tobytes())


def op_ping(_req):
    # Report which engines have their PACKAGES importable (not whether models are
    # already resident) so the app can show availability before first use.
    asr_ok = False
    tts_ok = False
    try:
        import onnx_asr  # noqa: F401
        asr_ok = True
    except Exception as e:
        log("ping: onnx_asr missing: %s" % e)
    try:
        import kokoro_onnx  # noqa: F401
        tts_ok = True
    except Exception as e:
        log("ping: kokoro_onnx missing: %s" % e)
    return {"ok": True, "asr": asr_ok, "tts": tts_ok}


def op_asr(req):
    path = req.get("path", "")
    if not path or not os.path.exists(path):
        return {"ok": False, "error": "wav not found: %s" % path}
    model = _load_asr()
    wave_arr = _read_wav_16k_mono(path)
    if len(wave_arr) == 0:
        return {"ok": True, "text": ""}
    t0 = time.time()
    text = model.recognize(wave_arr, sample_rate=16000)
    if isinstance(text, (list, tuple)):
        text = text[0] if text else ""
    log("asr %.2fs -> %r" % (time.time() - t0, (text or "")[:60]))
    return {"ok": True, "text": (text or "").strip()}


def op_tts(req):
    text = (req.get("text") or "").strip()
    out = req.get("out") or ""
    voice = (req.get("voice") or "af_heart").strip() or "af_heart"
    if not text:
        return {"ok": False, "error": "empty text"}
    if not out:
        return {"ok": False, "error": "no output path"}
    kokoro = _load_tts()
    t0 = time.time()
    samples, sr = kokoro.create(text, voice=voice, speed=1.0, lang="en-us")
    _write_wav(out, samples, sr)
    log("tts %.2fs -> %s (%d bytes)" % (time.time() - t0, os.path.basename(out), os.path.getsize(out)))
    return {"ok": True, "path": out}


_OPS = {"ping": op_ping, "asr": op_asr, "tts": op_tts}


def main():
    log("ready (pid %d)" % os.getpid())
    print(json.dumps({"ok": True, "ready": True}), flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as e:
            print(json.dumps({"ok": False, "error": "bad json: %s" % e}), flush=True)
            continue
        op = req.get("op", "")
        fn = _OPS.get(op)
        if fn is None:
            print(json.dumps({"ok": False, "error": "unknown op: %s" % op}), flush=True)
            continue
        try:
            resp = fn(req)
        except Exception as e:
            resp = {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}
            log("op %s failed: %s" % (op, e))
        print(json.dumps(resp), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
"""#

    // Write helper.py to disk (idempotent — always rewrites so an app update ships a fresh helper).
    @discardableResult
    func writeHelper() -> Bool {
        do {
            try FileManager.default.createDirectory(at: VoicePaths.root, withIntermediateDirectories: true)
            try Self.helperSource.write(to: VoicePaths.helper, atomically: true, encoding: .utf8)
            return true
        } catch {
            logLine("voice: helper write failed — \(error.localizedDescription)")
            return false
        }
    }

    // ---- process lifecycle ----
    private func ensureRunning() -> Bool {   // called on `io`
        if let p = proc, p.isRunning { return true }
        proc = nil; stdinH = nil; stdoutH = nil; readBuf = Data()
        guard venvPresent else { return false }
        writeHelper()
        let p = Process()
        p.executableURL = VoicePaths.python
        p.arguments = [VoicePaths.helper.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { logLine("voice: helper spawn failed — \(error.localizedDescription)"); return false }
        // Drain stderr continuously so the pipe never blocks (download progress logs live here).
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            for line in s.split(separator: "\n") where !line.isEmpty { logLine("voice-helper: \(line)") }
        }
        proc = p
        stdinH = inPipe.fileHandleForWriting
        stdoutH = outPipe.fileHandleForReading
        // Consume the ready handshake line.
        guard let ready = readLine(), let obj = try? JSONSerialization.jsonObject(with: ready) as? [String: Any],
              (obj["ready"] as? Bool) == true else {
            logLine("voice: helper did not report ready"); terminate(); return false
        }
        logLine("voice: helper started pid=\(p.processIdentifier)")
        return true
    }

    // Blocking read of one newline-terminated line from stdout (nil on EOF). Runs on `io`.
    private func readLine() -> Data? {
        guard let h = stdoutH else { return nil }
        while true {
            if let nl = readBuf.firstIndex(of: 0x0a) {
                let line = readBuf.subdata(in: readBuf.startIndex..<nl)
                readBuf.removeSubrange(readBuf.startIndex...nl)
                return line
            }
            let chunk = h.availableData
            if chunk.isEmpty { return nil }   // EOF (process died / was terminated)
            readBuf.append(chunk)
        }
    }

    func terminate() {
        io.async { [weak self] in self?._terminate() }
    }
    private func _terminate() {
        idleKill?.cancel(); idleKill = nil
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil; stdinH = nil; stdoutH = nil; readBuf = Data()
    }

    // Core request/response. Single in-flight (serialized on `io`); a watchdog kills a hung helper
    // (which surfaces as an EOF → nil here). completion is invoked on `io`.
    private func request(_ obj: [String: Any], timeout: TimeInterval, completion: @escaping ([String: Any]?) -> Void) {
        io.async { [weak self] in
            guard let self else { completion(nil); return }
            guard self.ensureRunning(), let stdin = self.stdinH else { completion(nil); return }
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { completion(nil); return }
            var line = data; line.append(0x0a)
            do { try stdin.write(contentsOf: line) } catch { self._terminate(); completion(nil); return }
            let wd = DispatchWorkItem { [weak self] in self?._terminate() }
            self.watchdogQ.asyncAfter(deadline: .now() + timeout, execute: wd)
            let resp = self.readLine()
            wd.cancel()
            self.scheduleIdleKill()
            guard let resp, let parsed = try? JSONSerialization.jsonObject(with: resp) as? [String: Any] else {
                completion(nil); return
            }
            completion(parsed)
        }
    }

    // Idle-timeout: reclaim the (few-hundred-MB resident) helper after 5 min of no requests.
    private func scheduleIdleKill() {
        idleKill?.cancel()
        let wd = DispatchWorkItem { [weak self] in self?._terminate(); logLine("voice: helper idle-killed") }
        idleKill = wd
        watchdogQ.asyncAfter(deadline: .now() + 300, execute: wd)
    }

    // ---- public ops (completions hop to main for callers) ----
    func ping(completion: @escaping (Bool, Bool) -> Void) {
        request(["op": "ping"], timeout: 20) { resp in
            let asr = (resp?["asr"] as? Bool) ?? false
            let tts = (resp?["tts"] as? Bool) ?? false
            DispatchQueue.main.async { completion(asr, tts) }
        }
    }

    // Transcribe a 16 kHz mono WAV. nil = failed (caller falls back to the system path).
    func asr(wav: String, completion: @escaping (String?) -> Void) {
        request(["op": "asr", "path": wav], timeout: 90) { resp in
            let ok = (resp?["ok"] as? Bool) ?? false
            let text = resp?["text"] as? String
            DispatchQueue.main.async { completion(ok ? text : nil) }
        }
    }

    // Synthesize `text` to a WAV at `out`. false = failed (caller falls back to system TTS).
    // Timeout is generous to cover the one-time model download on first use.
    func tts(text: String, voice: String, out: String, completion: @escaping (Bool) -> Void) {
        request(["op": "tts", "text": text, "voice": voice, "out": out], timeout: 300) { resp in
            let ok = (resp?["ok"] as? Bool) ?? false
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // ---- install flow (creates the venv, pip-installs both packages, writes helper, pings) ----
    // Progress is published to VoiceStatus.shared.install for the Settings row. Runs entirely off
    // the main thread; the venv doubles as the user's real install.
    func install() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func phase(_ p: VoiceInstallPhase) { Task { @MainActor in VoiceStatus.shared.install = p } }
            phase(.installing("finding Python…"))
            guard let py = Self.resolvePython() else {
                phase(.failed("Python 3.10+ not found on PATH. Install Python, then retry.")); return
            }
            do { try FileManager.default.createDirectory(at: VoicePaths.root, withIntermediateDirectories: true) } catch {}
            let logURL = VoicePaths.installLog
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try? FileHandle(forWritingTo: logURL)
            func appendLog(_ s: String) { logHandle?.write(Data(s.utf8)) }

            // 1) venv
            phase(.installing("creating virtual environment…"))
            appendLog("=== creating venv with \(py) ===\n")
            if !Self.runTool(py.path, ["-m", "venv", VoicePaths.venv.path], log: appendLog) {
                phase(.failed("venv creation failed — see \(logURL.path)")); return
            }
            let venvPy = VoicePaths.python.path
            // 2) pip install (upgrade pip first, then the two packages)
            phase(.installing("installing packages (this can take a few minutes)…"))
            appendLog("=== pip install ===\n")
            _ = Self.runTool(venvPy, ["-m", "pip", "install", "--upgrade", "pip"], log: appendLog)
            let ok = Self.runTool(venvPy, ["-m", "pip", "install", "onnx-asr[cpu,hub]", "kokoro-onnx"], log: appendLog)
            if !ok {
                phase(.failed("pip install failed — see \(logURL.path)")); return
            }
            // 3) helper + verify
            self.writeHelper()
            Task { @MainActor in VoiceStatus.shared.refreshVenv() }
            phase(.installing("verifying…"))
            self.ping { asr, tts in
                Task { @MainActor in
                    VoiceStatus.shared.asrReady = asr; VoiceStatus.shared.ttsReady = tts; VoiceStatus.shared.pinged = true
                    let ver = Self.installedVersions()
                    VoiceStatus.shared.install = (asr && tts)
                        ? .installed(ver)
                        : .failed("packages installed but the helper didn't verify — see \(logURL.path)")
                }
            }
            appendLog("=== done ===\n")
        }
    }

    // Resolve a python3 (>=3.10) through the login shell PATH.
    static func resolvePython() -> URL? {
        for cmd in ["python3.12", "python3.11", "python3.10", "python3"] {
            if let p = LoginShell.which(cmd), FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }

    // Read pip's version line for both packages (best-effort, for the "installed vX" row).
    static func installedVersions() -> String {
        let p = Process()
        p.executableURL = VoicePaths.python
        p.arguments = ["-m", "pip", "show", "onnx-asr", "kokoro-onnx"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "installed" }
        p.waitUntilExit()
        let text = (try? out.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var onnx = "", kok = ""
        for block in text.components(separatedBy: "---") {
            let name = block.range(of: "onnx-asr") != nil ? "onnx" : (block.range(of: "kokoro-onnx") != nil ? "kok" : "")
            if let r = block.range(of: "Version: ") {
                let v = block[r.upperBound...].prefix { $0 != "\n" }
                if name == "onnx" { onnx = String(v) } else if name == "kok" { kok = String(v) }
            }
        }
        if onnx.isEmpty && kok.isEmpty { return "installed" }
        return "onnx-asr \(onnx), kokoro-onnx \(kok)"
    }

    // Run a subprocess to completion, streaming combined output into the install log. Returns
    // true iff exit status 0.
    private static func runTool(_ exe: String, _ args: [String], log: (String) -> Void) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShell.path
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        log("$ \(exe) \(args.joined(separator: " "))\n")
        do { try p.run() } catch { log("spawn failed: \(error.localizedDescription)\n"); return false }
        // Drain as it runs so a big pip install can't fill the pipe buffer.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        if let s = String(data: data, encoding: .utf8) { log(s) }
        p.waitUntilExit()
        log("\n[exit \(p.terminationStatus)]\n")
        return p.terminationStatus == 0
    }
}

// MARK: - Self-signed TLS identity for the phone remote
//
// getUserMedia (hold-to-talk mic capture on a real phone) requires a SECURE context, so the LAN
// remote must be served over https. We mint a self-signed identity once and reuse it. On first
// visit the phone shows a certificate warning the user accepts (noted in the page copy). If any
// step fails, BoardRemote falls back to plain http and logs a warning.
enum RemoteTLS {
    static let passphrase = "cleanup-remote"   // fixed; the p12 never leaves this machine
    static var p12Path: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Cleanup/remote-tls.p12")
    }
    private static var hostPath: URL { p12Path.deletingPathExtension().appendingPathExtension("host") }

    // Load (generating once if needed) the identity as a Network-framework sec_identity_t.
    static func identity(for host: String) -> sec_identity_t? {
        guard let secIdentity = loadOrCreateSecIdentity(for: host) else { return nil }
        return sec_identity_create(secIdentity)
    }

    private static func loadOrCreateSecIdentity(for host: String) -> SecIdentity? {
        let savedHost = (try? String(contentsOf: hostPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The certificate's SAN must match the LAN IP in the QR URL. Regenerate after a DHCP
        // address change, and replace older certificates that predate the host marker.
        if !FileManager.default.fileExists(atPath: p12Path.path) || savedHost != host {
            try? FileManager.default.removeItem(at: p12Path)
            try? FileManager.default.removeItem(at: hostPath)
            guard generateP12(for: host) else { return nil }
        }
        guard let data = try? Data(contentsOf: p12Path) else { return nil }
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess, let arr = items as? [[String: Any]],
              let first = arr.first,
              let idAny = first[kSecImportItemIdentity as String] else {
            logLine("wb: TLS p12 import failed (status \(status))")
            return nil
        }
        return (idAny as! SecIdentity)
    }

    // openssl (via Process) → self-signed cert + key → PKCS#12. Homebrew OpenSSL 3 needs `-legacy`
    // so SecPKCS12Import can read it; LibreSSL (/usr/bin/openssl) rejects `-legacy` but already
    // writes a Sec-readable p12, so we retry without it.
    private static func generateP12(for host: String) -> Bool {
        guard let openssl = resolveOpenSSL() else { logLine("wb: openssl not found for TLS"); return false }
        let dir = p12Path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = dir.appendingPathComponent("remote-tls.key").path
        let cert = dir.appendingPathComponent("remote-tls.crt").path
        defer { try? FileManager.default.removeItem(atPath: key); try? FileManager.default.removeItem(atPath: cert) }

        guard run(openssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", key, "-out", cert, "-days", "3650",
                            "-subj", "/CN=\(host)",
                            "-addext", "subjectAltName=IP:\(host)",
                            "-addext", "extendedKeyUsage=serverAuth"]) else {
            logLine("wb: TLS cert generation failed"); return false
        }
        let base = ["pkcs12", "-export", "-inkey", key, "-in", cert,
                    "-out", p12Path.path, "-passout", "pass:\(passphrase)", "-name", "Cleanup Remote"]
        if run(openssl, ["pkcs12", "-legacy", "-export", "-inkey", key, "-in", cert,
                         "-out", p12Path.path, "-passout", "pass:\(passphrase)", "-name", "Cleanup Remote"]) {
            try? host.write(to: hostPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12Path.path)
            logLine("wb: TLS identity generated at \(p12Path.path)")
            return true
        }
        // retry without -legacy (LibreSSL)
        if run(openssl, base) {
            try? host.write(to: hostPath, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12Path.path)
            logLine("wb: TLS identity generated (no -legacy) at \(p12Path.path)")
            return true
        }
        logLine("wb: TLS p12 export failed")
        return false
    }

    private static func resolveOpenSSL() -> String? {
        for p in ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl", "/usr/bin/openssl"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return LoginShell.which("openssl")
    }

    private static func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - Local mic capture (Parakeet path: raw PCM → silence-segmented WAVs → helper ASR)
//
// The system voice path uses SFSpeechRecognizer live. When Parakeet is selected, we instead
// capture raw audio via AVAudioEngine, convert to 16 kHz mono, segment on silence (RMS), write
// each utterance to a temp WAV, and hand it to the helper. No live partials (acceptable — the
// picker caption says so). Two modes:
//   • continuous = true  (whiteboard / open-mic): emit one utterance per silence-bounded segment.
//   • continuous = false (agent push-to-talk): accumulate until stop(), emit once.
final class LocalSpeechCapture {
    var onUtterance: ((String) -> Void)?   // final transcribed text (main thread)
    var onActive: ((Bool) -> Void)?        // capture running (main thread)

    private let continuous: Bool
    private let audio = AVAudioEngine()
    private let q = DispatchQueue(label: "com.abhiram.cleanup.localmic")
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var buffer: [Float] = []
    private var hadSpeech = false
    private var silentSamples = 0
    private var running = false

    // silence tuning (16 kHz frames)
    private let rmsThreshold: Float = 0.012
    private let silenceHangSamples = 16000 * 7 / 10   // ~0.7s of silence closes a segment
    private let minUtteranceSamples = 16000 * 3 / 10  // drop < ~0.3s (noise)
    private let maxUtteranceSamples = 16000 * 20      // force-commit at ~20s

    init(continuous: Bool) { self.continuous = continuous }

    func start() {
        guard !running else { return }
        let input = audio.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { return }
        converter = AVAudioConverter(from: inFmt, to: target)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buf, _ in
            self?.handle(buf)
        }
        audio.prepare()
        do { try audio.start() } catch { logLine("localmic: engine start failed — \(error.localizedDescription)"); return }
        running = true
        buffer.removeAll(); hadSpeech = false; silentSamples = 0
        onActive?(true)
        logLine("localmic: capture started (continuous=\(continuous))")
    }

    func stop() {
        guard running else { return }
        running = false
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        onActive?(false)
        // Push-to-talk: flush whatever was accumulated as the single utterance. Strong self so
        // the instance survives the flush even if the owner drops its reference on stop().
        if !continuous { q.async { self.flush(force: true) } }
        logLine("localmic: capture stopped")
    }

    private func handle(_ inBuf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / inBuf.format.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var err: NSError?
        var supplied = false
        converter.convert(to: outBuf, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return inBuf
        }
        if err != nil { return }
        let n = Int(outBuf.frameLength)
        guard n > 0, let ch = outBuf.floatChannelData?[0] else { return }
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = ch[i] }
        q.async { [weak self] in self?.ingest(frame) }
    }

    // Runs on `q`. Segment logic + WAV write + helper ASR.
    private func ingest(_ frame: [Float]) {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (frame.isEmpty ? 0 : (sum / Float(frame.count)).squareRoot())
        let voiced = rms > rmsThreshold

        if continuous {
            if voiced {
                hadSpeech = true; silentSamples = 0
                buffer.append(contentsOf: frame)
            } else if hadSpeech {
                buffer.append(contentsOf: frame)   // keep trailing silence for a natural cutoff
                silentSamples += frame.count
                if silentSamples >= silenceHangSamples { flush(force: false) }
            }
            if buffer.count >= maxUtteranceSamples { flush(force: false) }
        } else {
            // push-to-talk: accumulate everything while held
            if voiced { hadSpeech = true }
            buffer.append(contentsOf: frame)
        }
    }

    private func flush(force: Bool) {
        let samples = buffer
        buffer.removeAll(); let hs = hadSpeech; hadSpeech = false; silentSamples = 0
        guard hs || force, samples.count >= (force ? 1600 : minUtteranceSamples) else { return }
        guard let path = Self.writeWav(samples) else { return }
        // Strong self: keep this capture alive until the (possibly slow, first-run) ASR resolves,
        // even if the owner already dropped its reference.
        VoiceEngine.shared.asr(wav: path) { text in
            try? FileManager.default.removeItem(atPath: path)
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.onUtterance?(text)
        }
    }

    // 16 kHz mono PCM16 WAV to a temp file.
    static func writeWav(_ samples: [Float]) -> String? {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("mic-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
        return writeWav(samples, to: path) ? path : nil
    }

    // Standalone WAV writer (also used to convert the whiteboard segment stream).
    @discardableResult
    static func writeWav(_ samples: [Float], to path: String, sampleRate: Int = 16000) -> Bool {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = max(-1, min(1, samples[i]))
            pcm[i] = Int16(v * 32767)
        }
        var data = Data()
        let dataBytes = pcm.count * 2
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: le32(UInt32(36 + dataBytes)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: le32(16))
        data.append(contentsOf: le16(1))                       // PCM
        data.append(contentsOf: le16(1))                       // mono
        data.append(contentsOf: le32(UInt32(sampleRate)))
        data.append(contentsOf: le32(UInt32(sampleRate * 2)))  // byte rate
        data.append(contentsOf: le16(2))                       // block align
        data.append(contentsOf: le16(16))                      // bits
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: le32(UInt32(dataBytes)))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        do { try data.write(to: URL(fileURLWithPath: path)); return true }
        catch { logLine("localmic: wav write failed — \(error.localizedDescription)"); return false }
    }
}

// MARK: - Projects (isolated per-project workspaces)

// One isolated project workspace: ~/Documents/Cleanup/projects/<slug>/
//
// Each project owns its OWN working directory, so the agent's cwd = the project dir. That
// single fact buys per-project isolation for free: Claude Code keys its own auto-memory +
// conversation history to the cwd path, so every project gets a private long-term memory and
// a private resumable conversation, and nothing from one project's dir leaks into another's.
//
// On disk: generated CLAUDE.md + AGENTS.md, a reserved sessions/ dir, and project.json below.
struct Project: Codable, Identifiable, Equatable {
    var slug: String = "default"   // NOT persisted (it IS the dir name); set from the folder on load
    var name: String = "Default"
    var brief: String = ""
    // Codex session/thread id captured from `codex exec --json` on the first turn, so follow-ups
    // (incl. across app restarts) can `codex exec resume <id>` this project's own conversation.
    var codexSessionId: String? = nil
    // True once the project has had a CLI turn. Drives per-project resume (claude --continue /
    // codex resume passed only when set). Cleared by "⊕ new session" to start fresh.
    var hasSession: Bool = false

    var id: String { slug }
    enum CodingKeys: String, CodingKey { case name, brief, codexSessionId, hasSession }

    var dir: URL { ProjectStore.projectsRoot.appendingPathComponent(slug, isDirectory: true) }
    var sessionsDir: URL { dir.appendingPathComponent("sessions", isDirectory: true) }
    var jsonURL: URL { dir.appendingPathComponent("project.json") }
}

// Registry + lifecycle for project workspaces. Enumerates projects/, tracks the current one
// (Keys.currentProject), migrates the legacy single agent/ dir into projects/default on first
// run, and (re)generates each project's CLAUDE.md / AGENTS.md.
enum ProjectStore {
    static var projectsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Cleanup/projects", isDirectory: true)
    }
    // Pre-projects single workdir; its role is migrated into projects/default on first run.
    private static var legacyAgentDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return docs.appendingPathComponent("Cleanup/agent", isDirectory: true)
    }

    // lowercase-kebab: alnum runs kept, everything else collapses to a single '-'.
    static func slugify(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash && !out.isEmpty { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "project" : out
    }

    // ---- bootstrap / migration ----

    // App start: migrate legacy agent/ → projects/default (if needed), guarantee Default exists,
    // then regenerate every project's instruction files from the (possibly changed) personal context.
    static func bootstrap() { ensureDefault(); regenerateAll() }

    // Guarantee projects/default exists. First run migrates the legacy agent/ dir's role (its
    // files + Claude's per-cwd memory) into it; the old dir is left in place, unused.
    @discardableResult
    static func ensureDefault() -> Project {
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let defDir = projectsRoot.appendingPathComponent("default", isDirectory: true)
        var p = Project(slug: "default", name: "Default")
        if !FileManager.default.fileExists(atPath: defDir.path) {
            try? FileManager.default.createDirectory(at: defDir.appendingPathComponent("sessions"),
                                                     withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: legacyAgentDir.path) {
                copyDirInto(legacyAgentDir, defDir)
                logLine("projects: migrated legacy agent → projects/default")
            }
            save(p)
        } else {
            p = load("default") ?? p
        }
        return p
    }

    private static func copyDirInto(_ src: URL, _ dst: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) { continue }
            try? fm.copyItem(at: item, to: target)
        }
    }

    // ---- enumeration / lookup ----

    static func list() -> [Project] {
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        var result: [Project] = []
        if let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for dir in dirs {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
                else { continue }
                let slug = dir.lastPathComponent
                result.append(load(slug) ?? Project(slug: slug, name: slug))
            }
        }
        if result.isEmpty { result.append(ensureDefault()) }
        // Default first, then the rest alphabetically by slug.
        let def = result.filter { $0.slug == "default" }
        let rest = result.filter { $0.slug != "default" }.sorted { $0.slug < $1.slug }
        return def + rest
    }

    static func find(_ slug: String) -> Project? { load(slug) }

    private static func load(_ slug: String) -> Project? {
        let url = projectsRoot.appendingPathComponent(slug).appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url),
              var p = try? JSONDecoder().decode(Project.self, from: data) else { return nil }
        p.slug = slug   // authoritative — the folder name IS the slug
        return p
    }

    static func current() -> Project {
        find(defaults().string(forKey: Keys.currentProject) ?? "default") ?? ensureDefault()
    }
    static func setCurrent(_ slug: String) { defaults().set(slug, forKey: Keys.currentProject) }

    // ---- create / persist ----

    static func create(name: String, brief: String) -> Project {
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Untitled" : trimmed
        let base = slugify(display)
        var slug = base
        var n = 2
        while FileManager.default.fileExists(atPath: projectsRoot.appendingPathComponent(slug).path) {
            slug = "\(base)-\(n)"; n += 1
        }
        var p = Project(slug: slug, name: display)
        p.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(at: p.sessionsDir, withIntermediateDirectories: true)
        save(p)
        writeInstructionFiles(p)
        logLine("projects: created \(slug) (\(display))")
        return p
    }

    static func save(_ p: Project) {
        ensureDir(p)
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        guard let data = try? enc.encode(p) else { return }
        try? data.write(to: p.jsonURL, options: .atomic)
    }

    // Create the project dir (+ sessions/) on demand; used as the CLI cwd. Falls back to the
    // user home so an agent run never dies over a missing dir.
    @discardableResult
    static func ensureDir(_ p: Project) -> URL {
        do {
            try FileManager.default.createDirectory(at: p.sessionsDir, withIntermediateDirectories: true)
            return p.dir
        } catch {
            logLine("projects: ensure dir failed — \(error.localizedDescription)")
            return FileManager.default.homeDirectoryForCurrentUser
        }
    }

    // ---- instruction files ----

    private static func buildInstructions(_ p: Project) -> String {
        var s = "# Cleanup Agent — \(p.name)\n"
        s += "You are the agent inside the Cleanup app, working in the project \"\(p.name)\". Session summaries may live in ./sessions/."
        let brief = p.brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty { s += "\n\n## Project\n" + brief }
        // Personal context is GLOBAL — every project gets it.
        let ctx = (defaults().string(forKey: Keys.agentContext) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty { s += "\n\n## About the user\n" + ctx }
        s += "\n"
        return s
    }

    // Write CLAUDE.md + AGENTS.md (identical) into the project — both Claude Code and Codex
    // auto-load these. Atomic (temp + rename) and only when the content actually changed.
    static func writeInstructionFiles(_ p: Project) {
        ensureDir(p)
        let body = buildInstructions(p)
        writeIfChanged(p.dir.appendingPathComponent("CLAUDE.md"), body)
        writeIfChanged(p.dir.appendingPathComponent("AGENTS.md"), body)
    }

    // Regenerate every project's instruction files (on personal-context save + app start).
    static func regenerateAll() { for p in list() { writeInstructionFiles(p) } }

    private static func writeIfChanged(_ url: URL, _ content: String) {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)   // atomically → temp + rename
    }
}

// Compatibility shim — the single shared workdir was replaced by per-project workspaces above.
enum AgentWorkspace {
    static func writeInstructionFiles() { ProjectStore.bootstrap() }
    @discardableResult static func ensure() -> URL { ProjectStore.ensureDir(ProjectStore.current()) }
}

// MARK: - Model catalog

enum ModelCatalog {
    // probed 2026-07-09: allowed for ChatGPT-sub accounts; gpt-5.5-mini and the
    // -codex-mini variants are rejected with 400
    static let chatgpt = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
    // Claude Code CLI model aliases (resolve to the current Haiku/Sonnet/Opus).
    static let claude = ["haiku", "sonnet", "opus"]

    static func ollama() async -> [String] {
        let base = defaults().string(forKey: Keys.ollamaURL) ?? "http://localhost:11434"
        guard let url = URL(string: base + "/api/tags"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.filter { !$0.contains("embed") }.sorted()
    }

    static func forCurrentBackend() async -> [String] {
        switch defaults().string(forKey: Keys.backend) ?? "ollama" {
        case "chatgpt": return chatgpt
        case "claude": return claude
        case "openai": return []
        default: return await ollama()
        }
    }

    static var currentModelKey: String {
        switch defaults().string(forKey: Keys.backend) ?? "ollama" {
        case "chatgpt": return Keys.chatgptModel
        case "claude": return Keys.claudeModel
        case "openai": return Keys.apiModel
        default: return Keys.ollamaModel
        }
    }
}

// MARK: - Prompts

enum Prompts {
    static let system = "You are a text rewriting engine. Output exactly one rewritten message and nothing else — no quotes around it, no preamble, no labels, no bullet points, no multiple options, no explanations."

    static func toneInstruction(_ tone: String) -> String {
        switch tone {
        case "Clean": return "neutral — just fix grammar, spelling, punctuation, and clarity; keep the writer's voice"
        case "Professional": return "professional and polished, suitable for work or academic contexts"
        case "Casual": return "relaxed and friendly, like texting a friend, but still clean and readable"
        case "Blunt": return "direct and concise; cut hedging and filler"
        default: return tone
        }
    }

    // Each style is a hard, mutually exclusive brief — soft hints like "warmer"
    // converge to near-identical output on short messages.
    static let styles: [(label: String, brief: String)] = [
        ("balanced", "Keep the length and structure natural — a clean, faithful version of the original."),
        ("polished", "Compose it properly: complete sentences, courteous phrasing, no slang or filler words at all."),
        ("compressed", "Cut it down hard: at most half the original length. Drop greetings, pleasantries, and filler — keep only the substance."),
        ("fuller", "Expand it a little: open with a natural greeting and add a touch more courtesy or context. Aim for roughly 1.5x the original length."),
        ("minimal edit", "Change as little as possible: fix only spelling, grammar, and punctuation. Keep the original wording, casual bits, and phrasing wherever they work."),
    ]

    static func variant(text: String, tone: String, index: Int) -> String {
        """
        Rewrite the message below so it is clean, grammatical, and well-punctuated while keeping its meaning. \
        Tone: \(toneInstruction(tone)).
        This version's brief, which overrides everything except meaning: \(styles[index % styles.count].brief) \
        Reply with the rewritten message only.

        Message:
        \(text)
        """
    }

    static func refine(current: String, instruction: String) -> String {
        """
        Here is a message:
        \(current)

        Revise it according to this instruction: \(instruction)
        Return only the revised message.
        """
    }
}

// MARK: - Word-level diff (port of windows/Diff.cs)

enum DiffKind { case same, removed, added }

// One contiguous run of the merged diff. Text keeps its original whitespace so
// the rendered flow reproduces spacing exactly.
struct DiffSegment { let kind: DiffKind; let text: String }

// Word-level LCS diff. Texts are short chat-sized messages, so the classic
// O(n·m) dynamic-programming table is comfortably fast and exact.
enum DiffEngine {
    // Split into tokens where each token is a maximal run of non-whitespace OR a
    // maximal run of whitespace — lets the diff align on word boundaries while
    // rebuilding exact original spacing when rendered.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let start = i
            let ws = chars[i].isWhitespace
            while i < chars.count && chars[i].isWhitespace == ws { i += 1 }
            tokens.append(String(chars[start..<i]))
        }
        return tokens
    }

    // Diff `original` against `variant`: ordered, merged segments. In any replaced
    // region all removed text is emitted before the added text, and adjacent
    // same-kind runs are merged.
    static func compute(_ original: String, _ variant: String) -> [DiffSegment] {
        let a = tokenize(original), b = tokenize(variant)
        let n = a.count, m = b.count

        // dp[i][j] = length of the LCS of a[i..] and b[j..]
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j]
                        ? dp[i + 1][j + 1] + 1
                        : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        // Forward walk of the DP table → raw per-token segments.
        var raw: [DiffSegment] = []
        var x = 0, y = 0
        while x < n && y < m {
            if a[x] == b[y] { raw.append(DiffSegment(kind: .same, text: a[x])); x += 1; y += 1 }
            else if dp[x + 1][y] >= dp[x][y + 1] { raw.append(DiffSegment(kind: .removed, text: a[x])); x += 1 }
            else { raw.append(DiffSegment(kind: .added, text: b[y])); y += 1 }
        }
        while x < n { raw.append(DiffSegment(kind: .removed, text: a[x])); x += 1 }
        while y < m { raw.append(DiffSegment(kind: .added, text: b[y])); y += 1 }

        return merge(raw)
    }

    // Collapse the raw token stream: merge consecutive Same runs, and gather each
    // changed region into at most one Removed + one Added segment.
    private static func merge(_ raw: [DiffSegment]) -> [DiffSegment] {
        var result: [DiffSegment] = []
        var i = 0
        while i < raw.count {
            if raw[i].kind == .same {
                var same = ""
                while i < raw.count && raw[i].kind == .same { same += raw[i].text; i += 1 }
                result.append(DiffSegment(kind: .same, text: same))
            } else {
                var removed = "", added = ""
                while i < raw.count && raw[i].kind != .same {
                    if raw[i].kind == .removed { removed += raw[i].text } else { added += raw[i].text }
                    i += 1
                }
                if !removed.isEmpty { result.append(DiffSegment(kind: .removed, text: removed)) }
                if !added.isEmpty { result.append(DiffSegment(kind: .added, text: added)) }
            }
        }
        return result
    }
}

// Which face of the diff to render: the inline panel shows every segment; a
// pop-out pane shows only its own side (left = original+deletions, right =
// variant+insertions).
enum DiffSide { case inlineAll, left, right }

// Build a coloured AttributedString for the given segments and side. Same red/
// green semantics as windows/Theme + DiffWindow: deletions struck + red-tinted,
// insertions semibold + green-tinted, unchanged plain.
func diffAttributed(_ segs: [DiffSegment], pal: Pal, fontSize: CGFloat, side: DiffSide) -> AttributedString {
    func run(_ s: String, _ fg: Color, weight: Font.Weight = .regular) -> AttributedString {
        var a = AttributedString(s)
        a.font = .system(size: fontSize, weight: weight)
        a.foregroundColor = fg
        return a
    }
    var result = AttributedString()
    for seg in segs {
        switch (seg.kind, side) {
        case (.same, _):
            result += run(seg.text, pal.text)
        case (.removed, .inlineAll), (.removed, .left):
            var r = run(seg.text, pal.diffDelText)
            r.backgroundColor = pal.diffDelBg
            r.strikethroughStyle = Text.LineStyle.single
            result += r
        case (.added, .inlineAll), (.added, .right):
            var r = run(seg.text, pal.diffAddText, weight: .semibold)
            r.backgroundColor = pal.diffAddBg
            result += r
        default:
            break   // removed-on-right / added-on-left: not part of that pane
        }
    }
    return result
}

// MARK: - Session model

enum VariantState {
    case loading
    case refineLoading(String)   // old text held (dimmed) while a refine is in flight
    case streaming(String)       // live partial tokens; final text still comes from the return value
    case done(String)
    case failed(String)
}

@MainActor
final class Session: ObservableObject {
    // mutable so auto mode can retarget it to a freshly-caught selection
    @Published private(set) var original: String
    @Published var tone: String
    @Published var count: Int
    @Published var variants: [VariantState] = []
    // Per-card version history: histories[i][0] = the initially generated text;
    // every completed refine appends a new version. histIndex[i] = which version is
    // DISPLAYED (and what Copy/Replace/diff/further-refines use). Stepping only moves
    // histIndex; a refine always appends the newest version (no branching).
    @Published var histories: [[String]] = []
    @Published var histIndex: [Int] = []
    @Published var selected: Int = 0
    @Published var refining: Bool = false
    // auto mode = recapture selections made anywhere and feed them in without
    // stealing focus. Never persisted — always starts off (new Session each open).
    @Published var autoMode: Bool = false

    private var tasks: [Task<Void, Never>] = []
    // bumped on every regenerate (tone / count change / ⌘R / new selection); a
    // superseded generation's streamed partials and final writes are rejected so
    // they can never land in the fresh batch's cards.
    private var genToken: Int = 0

    init(original: String) {
        self.original = original
        self.tone = defaults().string(forKey: Keys.defaultTone) ?? "Clean"
        self.count = max(1, min(5, defaults().integer(forKey: Keys.defaultCount)))
        generateAll()
    }

    func setTone(_ t: String) {
        guard t != tone else { return }
        tone = t
        generateAll()
    }

    func setCount(_ n: Int) {
        let n = max(1, min(5, n))
        guard n != count else { return }
        count = n
        defaults().set(n, forKey: Keys.defaultCount)
        generateAll()
    }

    func select(_ i: Int) {
        if i >= 0 && i < variants.count { selected = i }
    }

    // Auto mode caught a fresh selection: replace the original and regenerate. The
    // caller has already retargeted the paste-back app to the now-frontmost app.
    // No-op on an empty or unchanged selection.
    func updateSource(_ newText: String) {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != original.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        original = newText
        logLine("auto: new selection (\(t.count) chars) — regenerating")
        generateAll()
    }

    var selectedText: String? {
        guard selected < variants.count, case .done = variants[selected] else { return nil }
        return shown(selected)
    }

    // Text of the version currently DISPLAYED for card i (nil before any lands).
    func shown(_ i: Int) -> String? {
        guard i < histories.count, !histories[i].isEmpty, histIndex[i] < histories[i].count else { return nil }
        return histories[i][histIndex[i]]
    }

    // Move card i's displayed version by delta (clamped). Only histIndex changes —
    // the diff / Copy / Replace all read `shown`, so they follow automatically.
    func stepVersion(_ i: Int, _ delta: Int) {
        guard i < histories.count else { return }
        let n = histories[i].count
        guard n > 1 else { return }
        let ni = max(0, min(n - 1, histIndex[i] + delta))
        guard ni != histIndex[i] else { return }
        histIndex[i] = ni
    }

    func generateAll() {
        cancelTasks()
        genToken &+= 1
        let token = genToken
        variants = Array(repeating: .loading, count: count)
        histories = Array(repeating: [], count: count)
        histIndex = Array(repeating: 0, count: count)
        selected = 0
        for i in 0..<count {
            let prompt = Prompts.variant(text: original, tone: tone, index: i)
            tasks.append(Task { [weak self] in
                let onPartial: @Sendable (String) -> Void = { acc in
                    Task { @MainActor in self?.setPartial(i, acc, token: token) }
                }
                do {
                    let out = try await LLM.complete(system: Prompts.system, user: prompt, onPartial: onPartial)
                    guard !Task.isCancelled else { return }
                    self?.setVariant(i, .done(out), token: token)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.setVariant(i, .failed(error.localizedDescription), token: token)
                }
            })
        }
    }

    func refineSelected(_ instruction: String) {
        let inst = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inst.isEmpty, let current = selectedText, !refining else { return }
        refining = true
        let i = selected
        let token = genToken
        // hold the current text (dimmed) until the first refined partial arrives
        variants[i] = .refineLoading(current)
        tasks.append(Task { [weak self] in
            let onPartial: @Sendable (String) -> Void = { acc in
                Task { @MainActor in self?.setPartial(i, acc, token: token) }
            }
            do {
                let out = try await LLM.complete(system: Prompts.system,
                                                 user: Prompts.refine(current: current, instruction: inst),
                                                 onPartial: onPartial)
                guard !Task.isCancelled else { return }
                self?.setVariant(i, .done(out), token: token)
            } catch {
                guard !Task.isCancelled else { return }
                self?.setVariant(i, .failed(error.localizedDescription), token: token)
            }
            self?.refining = false
        })
    }

    // Live partial: replace loading/refine-loading/streaming state with the newest
    // accumulated text. Ignored once the card has finalized (done/failed) or if the
    // batch has been superseded — a stale straggler must never overwrite a card.
    private func setPartial(_ i: Int, _ text: String, token: Int) {
        guard token == genToken, i < variants.count else { return }
        switch variants[i] {
        case .done, .failed: return
        default: variants[i] = .streaming(text)
        }
    }

    private func setVariant(_ i: Int, _ state: VariantState, token: Int) {
        guard token == genToken, i < variants.count else { return }
        // A completed generation OR refine records a new version and displays it.
        // (Streaming partials go through setPartial; failures land as .failed — so
        // neither adds a version.)
        if case .done(let s) = state, i < histories.count {
            histories[i].append(s)
            histIndex[i] = histories[i].count - 1
        }
        variants[i] = state
    }

    func cancelTasks() {
        tasks.forEach { $0.cancel() }
        tasks = []
        refining = false
    }
}

// MARK: - Popup view

struct PopupView: View {
    @ObservedObject var session: Session
    @Environment(\.colorScheme) private var scheme
    @State private var customTone: String = ""
    @State private var refineText: String = ""
    @State private var sliderVal: Double = 3
    @State private var diffOn: Bool = defaults().bool(forKey: Keys.diffView)
    @State private var showHelp = false

    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    private var fontSize: CGFloat { contentFontSize() }
    private let tones = ["Clean", "Professional", "Casual", "Blunt"]

    private let helpLines: [(String, String)] = [
        ("tone", "Clean · Professional · Casual · Blunt, or type a custom tone"),
        ("VARIANTS", "1–5 rewrites; 1 = single, more = pick a card"),
        ("⌘1–5", "select a card"),
        ("⌘R", "regenerate all variants"),
        ("⌘D / ◫", "toggle the inline red/green diff"),
        ("⧉", "pop the diff out into its own window"),
        ("tune it…", "type an instruction to refine the selected card"),
        ("‹ ›", "step through refine versions on a card"),
        ("⟳ auto", "catch new selections anywhere and rewrite live"),
        ("⌘↩ / esc", "Replace in place / cancel"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(pal.line)
            VStack(alignment: .leading, spacing: 12) {
                chipsRow
                sliderRow
                cards
                if diffOn { diffPanel }
                refineBar
            }
            .padding(14)
            Divider().overlay(pal.line)
            footer
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(pal.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.lineStrong, lineWidth: 1))
        .foregroundColor(pal.text)
        .background(hiddenShortcuts)
        .overlay {
            if showHelp {
                HelpOverlay(title: "Cleanup — shortcuts", lines: helpLines, pal: pal) { showHelp = false }
                    .background(escDismiss)
            }
        }
        .onAppear { sliderVal = Double(session.count) }
    }

    // While help is up, a hidden Esc button intercepts cancel so Esc closes the
    // overlay first instead of the whole popup.
    private var escDismiss: some View {
        Button("") { showHelp = false }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0).frame(width: 0, height: 0)
    }

    @State private var availableModels: [String] = []

    private var titleBar: some View {
        HStack {
            Text("Cleanup").font(.system(size: 12, weight: .semibold)).foregroundColor(pal.muted)
            Spacer()
            // Auto mode: recapture new selections and rewrite them live, without
            // stealing focus. Never persisted — starts off every open.
            toggleButton(session.autoMode ? "⟳ auto ●" : "⟳ auto", on: session.autoMode) {
                session.autoMode.toggle()
            }
            .help("Auto — catch new selections anywhere and rewrite them live (Esc turns it off)")
            HelpChip(pal: pal, on: $showHelp)
            Menu {
                ForEach(availableModels, id: \.self) { m in
                    Button(action: { switchModel(to: m) }) {
                        if m == defaults().string(forKey: ModelCatalog.currentModelKey) {
                            Text("\(m)  ✓")
                        } else {
                            Text(m)
                        }
                    }
                }
                if !availableModels.isEmpty { Divider() }
                Button("Settings…") { AppDelegate.shared.openSettings() }
            } label: {
                MenuChipLabel(pal: pal, radius: 5, vPad: 3) {
                    Text(backendLabel).font(.system(size: 11)).foregroundColor(pal.faint)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .task { availableModels = await ModelCatalog.forCurrentBackend() }
            // quiet outline close button (mirrors Windows CloseBtn; Esc also closes)
            Button(action: { AppDelegate.shared.closePopup() }) {
                Text("✕")
                    .font(.system(size: 11))
                    .foregroundColor(pal.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(pal.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(pal.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func switchModel(to model: String) {
        defaults().set(model, forKey: ModelCatalog.currentModelKey)
        session.generateAll()
    }

    private var backendLabel: String {
        let d = defaults()
        switch d.string(forKey: Keys.backend) ?? "ollama" {
        case "openai": return "\(d.string(forKey: Keys.apiModel) ?? "api")"
        case "chatgpt": return "\(d.string(forKey: Keys.chatgptModel) ?? "gpt-5.5") · ChatGPT"
        case "claude": return "\(d.string(forKey: Keys.claudeModel) ?? "haiku") · Claude"
        default: return "\(d.string(forKey: Keys.ollamaModel) ?? "ollama") · Ollama"
        }
    }

    private var chipsRow: some View {
        HStack(spacing: 6) {
            ForEach(tones, id: \.self) { t in
                chip(t, on: session.tone == t) { session.setTone(t); customTone = "" }
            }
            HStack(spacing: 4) {
                Text("✎").font(.system(size: 11)).foregroundColor(pal.faint)
                TextField("", text: $customTone,
                          prompt: Text("custom tone…").foregroundColor(pal.faint.opacity(0.7)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 100)
                    .onSubmit {
                        let t = customTone.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { session.setTone(t) }
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(Capsule().stroke(pal.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            Spacer()
        }
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundColor(on ? pal.text : pal.muted)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Capsule().fill(on ? pal.surface3 : pal.surface2))
                .overlay(Capsule().stroke(on ? pal.lineStrong : pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var sliderRow: some View {
        HStack(spacing: 12) {
            Text("VARIANTS")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(pal.faint)
            Slider(value: $sliderVal, in: 1...5, step: 1) { editing in
                if !editing { session.setCount(Int(sliderVal)) }
            }
            .frame(width: 160)
            Text("\(Int(sliderVal))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(pal.text)
            Text(Int(sliderVal) == 1 ? "single rewrite" : "pick a card")
                .font(.system(size: 11)).foregroundColor(pal.faint)
            Spacer()
            toggleButton("◫ diff", on: diffOn) { setDiff(!diffOn) }
                .help("Diff — show what the selected variant changes (⌘D)")
            toggleButton("⧉ pop out", on: false) { AppDelegate.shared.togglePopOut() }
                .help("Pop out — open the red/green diff in a separate window")
        }
    }

    // Quiet-outline pill; when `on`, fills/bolds like the tone chips do.
    private func toggleButton(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundColor(on ? pal.text : pal.muted)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? pal.surface3 : pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? pal.lineStrong : pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func setDiff(_ on: Bool) {
        diffOn = on
        defaults().set(on, forKey: Keys.diffView)
    }

    // Selected variant's finished text, or nil while it's still loading/streaming.
    private var selectedDoneText: String? {
        guard session.selected < session.variants.count,
              case .done = session.variants[session.selected] else { return nil }
        return session.shown(session.selected)
    }

    private var diffPanel: some View {
        DiffInlineView(original: session.original, variant: selectedDoneText,
                       pal: pal, fontSize: fontSize)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(pal.line, lineWidth: 1))
    }

    private var cards: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<session.variants.count, id: \.self) { i in
                    card(i)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func card(_ i: Int) -> some View {
        let sel = session.selected == i
        return Button(action: { session.select(i) }) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(i + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(sel ? pal.text : pal.faint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(sel ? pal.lineStrong : pal.line, lineWidth: 1))
                cardBody(i)
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(sel ? pal.surface3 : pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(sel ? pal.accent.opacity(0.55) : pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardBody(_ i: Int) -> some View {
        switch session.variants[i] {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("writing…").font(.system(size: 12)).foregroundColor(pal.faint)
            }
        case .refineLoading(let old):
            // hold the current text (dimmed) with a pulse while the tune runs
            VStack(alignment: .leading, spacing: 6) {
                Text(old).font(.system(size: fontSize)).foregroundColor(pal.text)
                    .opacity(0.35)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("tuning…").font(.system(size: 12)).foregroundColor(pal.faint)
                }
            }
        case .streaming(let s):
            // live partial tokens — no style label until the final text lands
            Text(s).font(.system(size: fontSize)).foregroundColor(pal.text)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        case .done(let s):
            // Show the DISPLAYED version (may be an older one after stepping back),
            // falling back to the completion payload before histories is populated.
            let shown = session.shown(i) ?? s
            let vi = session.histIndex.indices.contains(i) ? session.histIndex[i] : 0
            VStack(alignment: .leading, spacing: 4) {
                Text(shown).font(.system(size: fontSize)).foregroundColor(pal.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .id(vi)                    // identity change per version →
                    .transition(.opacity)      // quick crossfade on step
                HStack(spacing: 6) {
                    if session.variants.count > 1 {
                        Text(Prompts.styles[i % Prompts.styles.count].label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(pal.faint)
                    }
                    Spacer(minLength: 0)
                    versionStepper(i)
                }
            }
        case .failed(let e):
            Text("⚠︎ \(e) — check Settings")
                .font(.system(size: 12)).foregroundColor(pal.muted)
        }
    }

    // Compact per-card "‹ 2/3 ›" stepper — only once a card has more than one
    // version. Chevrons dim to 0.3 at the ends; being Buttons, taps never fall
    // through to the card's selection action.
    @ViewBuilder
    private func versionStepper(_ i: Int) -> some View {
        if session.histories.indices.contains(i), session.histories[i].count > 1 {
            let idx = session.histIndex[i]
            let n = session.histories[i].count
            HStack(spacing: 4) {
                stepChevron("‹", enabled: idx > 0) {
                    withAnimation(.easeInOut(duration: 0.12)) { session.stepVersion(i, -1) }
                }
                Text("\(idx + 1)/\(n)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(pal.faint)
                stepChevron("›", enabled: idx < n - 1) {
                    withAnimation(.easeInOut(duration: 0.12)) { session.stepVersion(i, 1) }
                }
            }
        }
    }

    private func stepChevron(_ glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(pal.muted)
                .opacity(enabled ? 1 : 0.3)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var refineBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $refineText,
                      prompt: Text("tune it…").foregroundColor(pal.faint.opacity(0.7)))
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .disabled(session.refining)
                .onSubmit { submitRefine() }
            if session.refining {
                ProgressView().controlSize(.small)
            } else {
                Button(action: { submitRefine() }) {
                    Text("↵").font(.system(size: 12, weight: .semibold)).foregroundColor(pal.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(pal.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(pal.lineStrong, lineWidth: 1))
        // input dims while a tune is in flight; restores on arrival/supersede
        .opacity(session.refining ? 0.55 : 1)
        .animation(.easeOut(duration: 0.14), value: session.refining)
    }

    private func submitRefine() {
        session.refineSelected(refineText)
        refineText = ""
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("⌘1–5 select · ⌘R regenerate · ⌘D diff · esc cancel")
                .font(.system(size: 11)).foregroundColor(pal.faint)
            Spacer()
            Button("Copy") { AppDelegate.shared.copyResult() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(pal.muted)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(pal.lineStrong, lineWidth: 1))
            Button(action: { AppDelegate.shared.replaceResult() }) {
                Text("Replace ⌘↩")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(pal.onAccent)
                    .padding(.horizontal, 13).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(pal.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var hiddenShortcuts: some View {
        Group {
            ForEach(1...5, id: \.self) { n in
                Button("") { session.select(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("") { session.generateAll() }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { setDiff(!diffOn) }
                .keyboardShortcut("d", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

// MARK: - Inline diff panel

// Shows the original with the selected variant's changes inline (unified). RED/
// GREEN semantics match windows/Theme; selectable, scrolls internally, capped
// ~140pt tall. States: "waiting for variant…" while loading, "no changes" when
// the variant is identical to the original.
struct DiffInlineView: View {
    let original: String
    let variant: String?
    let pal: Pal
    let fontSize: CGFloat

    var body: some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
    }

    @ViewBuilder private var content: some View {
        if let variant {
            let segs = DiffEngine.compute(original, variant)
            if segs.allSatisfy({ $0.kind == .same }) {
                Text("no changes").font(.system(size: fontSize)).foregroundColor(pal.faint)
            } else {
                Text(diffAttributed(segs, pal: pal, fontSize: fontSize, side: .inlineAll))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        } else {
            Text("waiting for variant…").font(.system(size: fontSize)).foregroundColor(pal.faint)
        }
    }
}

// MARK: - Pop-out diff window

// Side-by-side: original (deletions) left, variant (insertions) right. Observes
// the same Session, so it live-syncs on every selection / refine / regenerate.
// Owned by AppDelegate — one instance, re-click focuses, closes with the popup.
struct DiffPopOutView: View {
    @ObservedObject var session: Session
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var scheme
    private var pal: Pal { Pal.of(dark: scheme == .dark) }

    private var variant: String? {
        guard session.selected < session.variants.count,
              case .done = session.variants[session.selected] else { return nil }
        return session.shown(session.selected)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diff").font(.system(size: 12, weight: .semibold)).foregroundColor(pal.muted)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(pal.line)
            HStack(spacing: 0) {
                pane("ORIGINAL", side: .left)
                Divider().overlay(pal.line)
                pane("REWRITE", side: .right)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.surface)
        .foregroundColor(pal.text)
    }

    private func pane(_ header: String, side: DiffSide) -> some View {
        let segs = variant.map { DiffEngine.compute(session.original, $0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text(header).font(.system(size: 10, design: .monospaced)).foregroundColor(pal.faint)
            ScrollView {
                Group {
                    if let segs {
                        Text(diffAttributed(segs, pal: pal, fontSize: fontSize, side: side))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text("waiting for variant…").font(.system(size: fontSize)).foregroundColor(pal.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}

// MARK: - Popup panel

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        AppDelegate.shared.closePopup()
    }
}

// Hosting view that accepts the *first* mouse click even when its window is not
// key. The floating chip panel is nonactivating and never made key (so it can't
// steal the source app's selection), which means the first click on a chip is a
// "first mouse" event. A plain NSHostingView rejects it, so the click is swallowed
// as a focus attempt and the chip's tap gesture never fires. Returning true here
// lets that first click flow straight through to SwiftUI's gesture recognizers.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Hands-free progress chip

// Small pulsing ✦ shown near the cursor while an auto-replace generation runs.
// Lives in a borderless, non-activating floating panel so it never steals focus
// (which would drop the source app's selection). Pulses opacity only (Mono-legal).
struct ProgressChip: View {
    @Environment(\.colorScheme) private var scheme
    @State private var pulse = false
    private var pal: Pal { Pal.of(dark: scheme == .dark) }

    var body: some View {
        ZStack {
            Circle().fill(pal.surface)
            Circle().stroke(pal.lineStrong, lineWidth: 1)
            Text("✦")
                .font(.system(size: 13))
                .foregroundColor(pal.accent)
                .opacity(pulse ? 1.0 : 0.35)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
        }
        .frame(width: 30, height: 30)
        .onAppear { pulse = true }
    }
}

// MARK: - Floating selection chips (✦ open popup · ⚡ instant rewrite)

// PopClip-style bar shown near a fresh selection. Two circular mono chips in a
// borderless nonactivating panel (see AppDelegate.showChips) — never steals focus,
// so the source app keeps its selection. Fades + scales in on appear; hover raises
// opacity, click dips the scale (opacity/scale only → Mono-legal).
struct FloatingChips: View {
    let size: CGFloat
    // Per-chip enable flags (from Settings). 🤖 additionally requires its CLI, which
    // the caller has already folded into showAgent. Only enabled chips render, so the
    // bar width generalises to any 1–3 count.
    let showStar: Bool
    let showBolt: Bool
    let showAgent: Bool
    let showSnip: Bool
    let onStar: () -> Void
    let onBolt: () -> Void
    let onAgent: () -> Void
    let onSnip: (SnipMode) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var shown = false
    private var pal: Pal { Pal.of(dark: scheme == .dark) }

    var body: some View {
        HStack(spacing: max(4, size * 0.2)) {
            if showStar {
                FloatingChip(glyph: "✦", size: size, pal: pal, help: "Clean up — open the popup", action: onStar)
            }
            if showBolt {
                FloatingChip(systemName: "bolt.fill", size: size, pal: pal, help: "Instant rewrite in place", action: onBolt)
            }
            // Agent chip spins up an agent on the selection — only when its toggle is on AND
            // the selected agent engine's CLI is present. "cpu" reads as an agent/compute glyph
            // at chip size and stays distinct from the adjacent ✦ star.
            if showAgent {
                FloatingChip(systemName: "cpu", size: size, pal: pal, help: "Agent mode — spin up an agent", action: onAgent)
            }
            // Snip: screenshot a region → agent. Left-click = area capture (screencapture -i;
            // press Space during it to switch to window mode). Right-click / control-click /
            // long-press = the options menu below (the cleanly-implementable Mac affordance).
            if showSnip {
                FloatingChip(systemName: "scissors", size: size, pal: pal,
                             help: "Snip a region → agent (right-click for options)",
                             action: { onSnip(.area) })
                    .contextMenu {
                        Button("Capture area") { onSnip(.area) }
                        Button("Capture window") { onSnip(.window) }
                        Button("Full screen") { onSnip(.full) }
                    }
            }
        }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.8)
        .onAppear { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
    }
}

struct FloatingChip: View {
    // A chip renders EITHER an SF Symbol (systemName) or a text glyph (✦ stays text).
    // systemName wins when set; otherwise the text glyph is drawn. Both tint to accent,
    // so the bar stays strictly Mono (no color-emoji glyphs).
    var glyph: String = ""
    var systemName: String? = nil
    let size: CGFloat
    let pal: Pal
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle().fill(pal.surface)
            Circle().stroke(pal.lineStrong, lineWidth: 1)
            Group {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: size * 0.42, weight: .medium))
                } else {
                    Text(glyph).font(.system(size: size * 0.43))
                }
            }
            .foregroundColor(pal.accent)
        }
        .frame(width: size, height: size)
        .opacity(hovering ? 1 : 0.9)
        .scaleEffect(pressed ? 0.9 : 1)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .onTapGesture {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                pressed = false
                action()
            }
        }
        .help(help)
    }
}

// MARK: - Voice dictation (SFSpeechRecognizer + AVAudioEngine)

// Push-to-toggle microphone dictation for the agent input. Live partials surface as
// a dim line (onPartial); the finalised phrase is committed to the real input text
// (onFinal). Authorises Speech + microphone on first use; if either is denied or the
// recognizer is unavailable, `disabled` flips true and the mic button greys out.
@MainActor
final class SpeechDictation: ObservableObject {
    @Published var listening = false
    @Published var partial = ""
    @Published var statusHelp = "Voice input"

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var local: LocalSpeechCapture?   // Parakeet path (push-to-talk: accumulate → one utterance)
    private var useLocal = false

    // Disabled when unsupported, or when the user has previously denied Speech access.
    var disabled: Bool {
        guard recognizer != nil else { return true }
        let s = SFSpeechRecognizer.authorizationStatus()
        return s == .denied || s == .restricted
    }

    func toggle() { listening ? commit() : start() }

    private func start() {
        if VoiceModes.parakeetASR { startLocal(); return }
        guard recognizer?.isAvailable == true else { fail("Voice input unavailable — no recognizer"); return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: ensureMic()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    if status == .authorized { self.ensureMic() }
                    else { self.fail("Speech access denied — enable it in System Settings › Privacy") }
                }
            }
        default: fail("Speech access denied — enable it in System Settings › Privacy")
        }
    }

    private func ensureMic() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in ok ? self.begin() : self.fail("Microphone access denied") }
            }
        default: fail("Microphone access denied — enable it in System Settings › Privacy")
        }
    }

    private func begin() {
        stopEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        let input = audio.inputNode
        let fmt = input.outputFormat(forBus: 0)
        // capture `req` (not self) in the audio-thread tap → no actor hop, no data race
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        audio.prepare()
        do { try audio.start() } catch { fail("Microphone unavailable"); return }
        listening = true
        partial = ""
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.listening else { return }
                if let text { self.partial = text; self.onPartial?(text) }
                if final || failed { self.commit() }
            }
        }
    }

    // Parakeet push-to-talk: capture everything while held; on commit, stop → helper ASR → onFinal.
    // No live partials (the hypotheses UI shows "listening…" instead).
    private func startLocal() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginLocal()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in ok ? self.beginLocal() : self.fail("Microphone access denied") }
            }
        default: fail("Microphone access denied — enable it in System Settings › Privacy")
        }
    }

    private func beginLocal() {
        let cap = LocalSpeechCapture(continuous: false)
        cap.onUtterance = { [weak self] text in
            guard let self else { return }
            self.partial = ""
            self.onFinal?(text)
            self.local = nil
        }
        local = cap
        useLocal = true
        listening = true
        partial = ""
        cap.start()
    }

    // Toggle off / send / final: stop capture and hand the finalised text over.
    func commit() {
        guard listening else { return }
        if useLocal {
            useLocal = false
            listening = false
            partial = ""
            local?.stop()   // flushes → helper ASR → onFinal (local nils itself in onUtterance)
            return
        }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        stopEngine()
        listening = false
        partial = ""
        if !text.isEmpty { onFinal?(text) }
    }

    func cancel() {
        if useLocal { useLocal = false; local?.onUtterance = nil; local?.stop(); local = nil }
        stopEngine()
        listening = false
        partial = ""
    }

    private func stopEngine() {
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func fail(_ msg: String) {
        listening = false
        partial = ""
        statusHelp = msg
        logLine("agent voice: \(msg)")
        NSSound.beep()
    }
}

// MARK: - Agent transcript model

enum AgentRole { case user, assistant, tool, error, note, context }

struct AgentMsg: Identifiable {
    let id = UUID()
    let role: AgentRole
    var text: String
    var stopped = false
    var attachments: [String] = []   // filenames sent with a user turn (transcript hint)
    var attachmentPaths: [String] = []  // full paths of image attachments → inline thumbnail + open-on-click (whiteboard looks)
}

// A pending attachment in the tray (per-message; cleared on send).
struct AgentAttachment: Identifiable, Equatable {
    let id = UUID()
    let path: String
    var name: String {
        let n = (path as NSString).lastPathComponent
        return n.isEmpty ? path : n
    }
    var isImage: Bool { AgentAttachment.isImagePath(path) }

    static func isImagePath(_ p: String) -> Bool {
        let ext = (p as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif"].contains(ext)
    }
}

// MARK: - Streaming transcript base (shared by Agent mode + Whiteboard mode)

// Owns the transcript array and the throttled, segment-aware streaming machinery plus
// the Claude stream-json parser. Agent and Whiteboard mode both build on this.
// All members are @MainActor; subclasses drive them from their own run loops.
@MainActor
class StreamingSession: ObservableObject {
    @Published var messages: [AgentMsg] = []

    // live assistant segment (mirrors windows/AgentEngine's seg/segStreamed/throttle)
    var curAssistant: Int?
    private var seg = ""
    private var segStreamed = false
    private var lastEmit: TimeInterval = -1
    private var dirty = false

    // ---- streaming text segment (throttled ~80ms, segment-aware) ----

    func resetSeg() { seg = ""; segStreamed = false; lastEmit = -1; dirty = false }

    func appendDelta(_ d: String) {
        guard !d.isEmpty else { return }
        seg += d; segStreamed = true; dirty = true
        offer()
    }

    // A full (non-delta) message: authoritative only if nothing streamed this segment.
    func setFull(_ full: String) {
        guard !full.isEmpty, !segStreamed else { return }
        seg = full; dirty = false; lastEmit = Date().timeIntervalSinceReferenceDate
        updateBubble(seg)
    }

    private func offer() {
        let now = Date().timeIntervalSinceReferenceDate
        if lastEmit >= 0, now - lastEmit < 0.08 { return }
        lastEmit = now
        if dirty { dirty = false; updateBubble(seg) }
    }

    func flushText() {
        if dirty, !seg.isEmpty { dirty = false; lastEmit = Date().timeIntervalSinceReferenceDate; updateBubble(seg) }
    }

    private func updateBubble(_ s: String) {
        if let i = curAssistant, i < messages.count, messages[i].role == .assistant {
            messages[i].text = s
        } else {
            messages.append(AgentMsg(role: .assistant, text: s))
            curAssistant = messages.count - 1
        }
    }

    // Dim one-liner (tool use / raw output / stopped) — also closes the current segment.
    func event(_ line: String) {
        flushText()
        resetSeg()
        curAssistant = nil
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { messages.append(AgentMsg(role: .tool, text: t)) }
    }

    // The finalised text of the current assistant segment (for TTS / completion hooks).
    var currentAssistantText: String? {
        guard let i = curAssistant, i < messages.count, messages[i].role == .assistant else { return nil }
        let t = messages[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // ---- Claude stream-json parsing ----

    func handleClaude(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "stream_event":
            // wraps an Anthropic SSE event; content_block_delta → text_delta = live tokens
            if let evt = obj["event"] as? [String: Any],
               evt["type"] as? String == "content_block_delta",
               let dl = evt["delta"] as? [String: Any],
               dl["type"] as? String == "text_delta",
               let txt = dl["text"] as? String {
                appendDelta(txt)
            }
        case "assistant":
            // full assistant message: text (fallback if nothing streamed) + tool_use lines
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "text": setFull(block["text"] as? String ?? "")
                    case "tool_use": event("▸ " + claudeVerb(block["name"] as? String ?? "tool", block))
                    default: break
                    }
                }
            }
        case "result":
            break   // authoritative end — text already streamed
        default:
            break
        }
    }

    func claudeVerb(_ name: String, _ block: [String: Any]) -> String {
        let input = block["input"] as? [String: Any]
        func file() -> String? {
            guard let f = input?["file_path"] as? String, !f.isEmpty else { return nil }
            return (f as NSString).lastPathComponent
        }
        func cmd() -> String? {
            guard let c = input?["command"] as? String, !c.isEmpty else { return nil }
            return short(c)
        }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "editing " + (file() ?? "a file")
        case "Read": return "reading " + (file() ?? "a file")
        case "Bash": return "running " + (cmd() ?? "a command")
        case "Grep", "Glob": return "searching"
        case "WebFetch", "WebSearch": return "browsing the web"
        case "Task": return "delegating a subtask"
        case "TodoWrite": return "updating the plan"
        default: return "using " + name
        }
    }

    func short(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(60)) + "…" : t
    }
}

// MARK: - Agent session (runs a Codex / Claude CLI turn, streams JSONL in)

// Owns one agentic CLI session for the life of an Agent window. The first turn starts
// a fresh session; follow-ups resume it (claude -p --continue / codex exec resume
// --last), so context persists. Engine / model / permission come from Agent settings
// (captured at init — independent of the rewrite Backend). Parsing is defensive: a
// single malformed line can never crash a run, and non-JSON output is never lost.
@MainActor
final class AgentSession: StreamingSession {
    @Published var running = false
    @Published var input = ""
    @Published var attachments: [AgentAttachment] = []   // pending, cleared on send

    let engine: String       // "claude" | "codex"
    let model: String
    let permission: String   // "safe" | "standard" | "full"
    let cliMissing: Bool

    // The project supplying cwd + per-project resume state. @Published so the title-bar chip
    // reflects switches. May change mid-window via switchProject.
    @Published var project: Project

    private let seededContext: String?
    private var contextSeeded = false    // seededContext is injected into the FIRST turn only
    private var proc: Process?
    private var runTask: Task<Void, Never>?

    var projectList: [Project] { ProjectStore.list() }

    init(engine: String, model: String, permission: String, seededContext: String?, project: Project) {
        self.engine = engine
        self.model = model
        self.permission = permission
        self.project = project
        let ctx = seededContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.seededContext = (ctx?.isEmpty == false) ? ctx : nil
        self.cliMissing = (AgentCLI.resolve() == nil)
        super.init()

        if let ctx = self.seededContext {
            let head = ctx.replacingOccurrences(of: "\n", with: " ")
            let snippet = head.count > 80 ? String(head.prefix(80)) + "…" : head
            messages.append(AgentMsg(role: .context, text: "context: \(snippet)"))
        }
        if cliMissing {
            messages.append(AgentMsg(role: .note, text: engine == "codex"
                ? "Codex CLI not found. Install it (npm i -g @openai/codex) and run `codex login`, then reopen. — see Health in Settings"
                : "Claude Code CLI not found. Install it and run `claude` once to log in, then reopen. — see Health in Settings"))
        } else if project.hasSession {
            messages.append(AgentMsg(role: .note, text: "resuming \(project.name) — ⊕ for a fresh session"))
        } else {
            messages.append(AgentMsg(role: .note, text: "Ready — ask the agent to do anything. Follow-ups keep the same session."))
        }
    }

    // ---- project switching (chip menu) ----

    func switchProject(_ p: Project) {
        guard p.slug != project.slug else { return }
        project = p
        ProjectStore.setCurrent(p.slug)
        messages.append(AgentMsg(role: .note, text: "— switched to \(p.name) —"))
        logLine("agent: switch project=\(p.slug) resume=\(p.hasSession ? "continue" : "fresh")")
    }

    // ⊕ — clear resume state so the next turn omits --continue / resume. Claude's own per-cwd
    // auto-memory for the project is untouched.
    func startFreshSession() {
        project.hasSession = false
        project.codexSessionId = nil
        ProjectStore.save(project)
        messages.append(AgentMsg(role: .note, text: "started a fresh session in \(project.name)"))
        logLine("agent: new session project=\(project.slug)")
    }

    func editBrief(_ brief: String) {
        project.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        ProjectStore.save(project)
        ProjectStore.writeInstructionFiles(project)   // brief change → regenerate CLAUDE.md / AGENTS.md
        messages.append(AgentMsg(role: .note, text: "updated \(project.name)'s brief"))
    }

    // Add / remove / clear pending attachments (deduped by standardized path).
    func addAttachment(_ path: String) {
        guard !path.isEmpty else { return }
        let std = (path as NSString).standardizingPath
        guard !attachments.contains(where: { $0.path == std }) else { return }
        attachments.append(AgentAttachment(path: std))
    }
    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    // Paste-from-clipboard: if a bitmap is on the pasteboard (and no plain text), save
    // it to a temp PNG and attach it — the screenshot → ⌘V flow. Returns true if it
    // handled the paste (so the text view skips its default paste).
    func pasteImageFromClipboard() -> Bool {
        let pb = NSPasteboard.general
        guard pb.string(forType: .string) == nil else { return false }   // don't intercept text paste
        guard let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let file = (dir as NSString).appendingPathComponent("attach-\(fmt.string(from: Date())).png")
        guard (try? png.write(to: URL(fileURLWithPath: file))) != nil else { return false }
        addAttachment(file)
        return true
    }

    // Enter / send: append the user bubble, seed context into the FIRST task, append the
    // attachments block after it, run. Sending attachments with no text is valid.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        guard (!text.isEmpty || !atts.isEmpty), !running, !cliMissing else {
            if text.isEmpty && atts.isEmpty { NSSound.beep() }
            return
        }
        input = ""
        let display = text.isEmpty ? "Look at the attached file(s)." : text
        // Image attachments carry their paths into the bubble so AgentRow can show real
        // thumbnails (same machinery the whiteboard uses for looks); names cover non-images.
        let imgPaths = atts.filter { $0.isImage }.map { $0.path }
        messages.append(AgentMsg(role: .user, text: display,
                                 attachments: atts.map { $0.name },
                                 attachmentPaths: imgPaths))
        attachments = []

        var task = display
        if !contextSeeded, let ctx = seededContext {
            task += "\n\nContext — the user had this text selected:\n" + ctx
        }
        contextSeeded = true
        // validate at send time — nonexistent paths are skipped with a dim note
        var valid: [String] = []
        for a in atts {
            if FileManager.default.fileExists(atPath: a.path) { valid.append(a.path) }
            else { messages.append(AgentMsg(role: .tool, text: "▸ skipped missing file: \(a.name)")) }
        }
        if !valid.isEmpty {
            task += "\n\nAttached files (read them before answering):\n"
                + valid.map { "- \($0)" }.joined(separator: "\n")
        }
        let images = valid.filter { AgentAttachment.isImagePath($0) }
        // parent dirs of every attachment → --add-dir (Claude's directory boundary
        // denies reads outside cwd/added dirs regardless of --allowedTools)
        let attachDirs = Array(Set(valid.map { ($0 as NSString).deletingLastPathComponent }))

        // Resume is PER PROJECT: continue this project's own conversation once it has had a turn.
        let turnProject = project
        // Codex resume is global rather than cwd-scoped, so only resume when this project has
        // an actual captured thread id. A prior Claude turn may have set hasSession=true.
        let followup = engine == "codex"
            ? !(turnProject.codexSessionId ?? "").isEmpty
            : turnProject.hasSession
        if !project.hasSession { project.hasSession = true; ProjectStore.save(project) }
        running = true
        curAssistant = nil
        resetSeg()
        runTask = Task { [weak self] in
            await self?.launch(task: task, images: images, attachDirs: attachDirs,
                               followup: followup, turnProject: turnProject)
        }
    }

    // Stop: kill the child (terminate, then SIGKILL after a grace) and mark the bubble.
    func stop() {
        runTask?.cancel()
        runTask = nil
        if let p = proc, p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
        proc = nil
        flushText()
        if let i = curAssistant, i < messages.count { messages[i].stopped = true }
        else { messages.append(AgentMsg(role: .tool, text: "▸ stopped")) }
        curAssistant = nil
        running = false
    }

    private func launch(task: String, images: [String], attachDirs: [String] = [], followup: Bool, turnProject: Project) async {
        guard let cli = AgentCLI.resolve() else {
            messages.append(AgentMsg(role: .error, text: (engine == "codex"
                ? "Codex CLI not found" : "Claude Code CLI not found") + " — see Health in Settings"))
            running = false
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = buildArgs(task: task, images: images, attachDirs: attachDirs,
                                followup: followup, turnProject: turnProject)
        p.environment = (engine == "codex" ? CodexCLI.env() : ClaudeCLI.env())
        // Per-project app-owned workdir (~/Documents/Cleanup/projects/<slug>), NOT $HOME: home
        // made Claude auto-load the user's personal ~/CLAUDE.md + global memory into every run.
        // This dir carries the project's own CLAUDE.md / AGENTS.md and its own per-cwd auto-memory.
        p.currentDirectoryURL = ProjectStore.ensureDir(turnProject)
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do { try p.run() }
        catch {
            messages.append(AgentMsg(role: .error, text: "\(engine == "codex" ? "Codex" : "Claude") CLI failed to start — \(error.localizedDescription)"))
            running = false
            return
        }
        proc = p
        let resumeDesc = followup ? (engine == "codex"
            ? (turnProject.codexSessionId?.isEmpty == false ? "resume-id" : "resume-last") : "continue") : "fresh"
        logLine("agent: project=\(turnProject.slug) resume=\(resumeDesc) engine=\(engine) perm=\(permission) tasklen=\(task.count)")

        let stderrTask = Task<String, Never>.detached {
            let d = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(data: d, encoding: .utf8) ?? ""
        }

        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                if line.isEmpty { continue }
                if engine == "codex" { handleCodex(line) } else { handleClaude(line) }
            }
        } catch { /* stream ended / cancelled */ }

        flushText()
        curAssistant = nil
        p.waitUntilExit()
        if !Task.isCancelled && p.terminationStatus != 0 {
            var tail = (await stderrTask.value).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.count > 300 { tail = "…" + String(tail.suffix(300)) }
            messages.append(AgentMsg(role: .error, text: tail.isEmpty ? "exit \(p.terminationStatus)" : tail))
        }
        proc = nil
        running = false
    }

    // ---- argument construction (per engine, per permission tier) ----

    private func buildArgs(task: String, images: [String], attachDirs: [String], followup: Bool, turnProject: Project) -> [String] {
        if engine == "codex" {
            // codex exec [resume <id>] --json -s <sandbox> [-m model] [-i img]… "<task>"
            // Codex resume is NOT cwd-scoped, so resume this project's own thread by the session id
            // captured on its first turn. Without a project-owned id, start fresh rather than
            // risking `--last`, which could resume another provider/project's conversation.
            var a = ["exec"]
            if followup {
                a.append("resume")
                a.append(turnProject.codexSessionId!)
            }
            a.append("--json")
            // `codex exec resume` REJECTS -s (its options differ from plain exec) — the
            // sandbox must go through the config override there. Plain exec keeps -s.
            if followup { a += ["-c", "sandbox_mode=\"\(codexSandbox())\""] }
            else { a += ["-s", codexSandbox()] }
            // The project workdirs aren't git repos, and codex refuses to run outside a
            // trusted repo without this flag.
            a.append("--skip-git-repo-check")
            if !model.isEmpty { a += ["-m", model] }
            // Codex reads images natively via --image; they're also in the task block so
            // it can Read any non-image attachments itself.
            for img in images { a += ["-i", img] }
            a.append(task)
            return a
        } else {
            // claude -p [--continue] "<task>" --model m --output-format stream-json …
            var a = ["-p"]
            if followup { a.append("--continue") }
            a.append(task)
            if !model.isEmpty { a += ["--model", model] }
            a += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            a += claudePermissionFlags()
            for d in attachDirs { a += ["--add-dir", d] }
            a += ["--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                  "--settings", "{\"disableAllHooks\":true}"]
            return a
        }
    }

    private func codexSandbox() -> String {
        switch permission {
        case "full": return "danger-full-access"
        case "standard": return "workspace-write"
        default: return "read-only"
        }
    }

    private func claudePermissionFlags() -> [String] {
        // --allowedTools Read matters: snapshots/attachments live OUTSIDE the home cwd
        // (temp dir, Downloads, …) and reads outside the working directory would
        // otherwise prompt — which dontAsk/headless auto-DENIES ("no access to Read").
        switch permission {
        case "standard": return ["--permission-mode", "acceptEdits", "--allowedTools", "Read"]
        case "full": return ["--dangerously-skip-permissions"]
        default: return ["--permission-mode", "dontAsk",
                         "--disallowedTools", "Bash Edit Write NotebookEdit",
                         "--allowedTools", "Read"]
        }
    }

    // ---- Codex --json parsing (defensive; shapes vary across versions) ----

    private func handleCodex(_ line: String) {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            event(line)   // not JSON → raw dim line (never lose output)
            return
        }
        // event payload may be at root, under "msg", or under "item"
        var ev = root
        if let m = root["msg"] as? [String: Any] { ev = m }
        else if let it = root["item"] as? [String: Any] { ev = it }

        captureCodexSession(root, ev)

        let type = ((ev["type"] as? String) ?? (root["type"] as? String) ?? "").lowercased()
        if type.isEmpty { return }
        if type.contains("reasoning") { return }
        if type.contains("delta") { appendDelta((ev["delta"] as? String) ?? (ev["text"] as? String) ?? ""); return }
        if type.contains("agent_message") || type == "assistant" || type == "message" ||
            (type.contains("message") && !type.contains("user") && !type.contains("system")) {
            if let txt = codexText(ev) { setFull(txt) }
            return
        }
        if type.contains("exec") || type.contains("command") || type.contains("shell") {
            if !type.contains("end") && !type.contains("output") && !type.contains("delta") {
                let cmd = codexCommand(ev)
                event(cmd != nil ? "▸ running: " + cmd! : "▸ running a command")
            }
            return
        }
        if type.contains("patch") || type.contains("apply") ||
            (type.contains("edit") && !type.contains("end")) || (type.contains("write") && !type.contains("end")) {
            if !type.contains("end") { event("▸ editing files") }
            return
        }
        // task_started / task_complete / token_count / thread.* / turn.* → ignored
    }

    // Capture the codex session/thread id from the --json stream (emitted near the start of a
    // fresh run, e.g. thread.started / session.created) and store it on the project so the NEXT
    // turn can `codex exec resume <id>`. Shapes vary across versions — probe defensively.
    private func captureCodexSession(_ root: [String: Any], _ ev: [String: Any]) {
        guard (project.codexSessionId ?? "").isEmpty else { return }
        let id = sessionId(ev) ?? sessionId(root) ?? nestedSessionId(ev) ?? nestedSessionId(root)
        guard let id, !id.isEmpty else { return }
        project.codexSessionId = id
        ProjectStore.save(project)
        logLine("codex resume id=\(id)")
    }

    private func sessionId(_ e: [String: Any]) -> String? {
        for k in ["session_id", "thread_id", "sessionId", "threadId"] {
            if let s = e[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private func nestedSessionId(_ e: [String: Any]) -> String? {
        for k in ["thread", "session"] {
            if let o = e[k] as? [String: Any] {
                for kk in ["id", "thread_id", "session_id"] {
                    if let s = o[kk] as? String, !s.isEmpty { return s }
                }
            }
        }
        return nil
    }

    private func codexText(_ ev: [String: Any]) -> String? {
        if let s = ev["message"] as? String { return s }
        if let s = ev["text"] as? String { return s }
        if let s = ev["content"] as? String { return s }
        if let arr = ev["content"] as? [Any] {
            var sb = ""
            for b in arr {
                if let s = b as? String { sb += s }
                else if let d = b as? [String: Any], let t = d["text"] as? String { sb += t }
            }
            if !sb.isEmpty { return sb }
        }
        return nil
    }

    private func codexCommand(_ ev: [String: Any]) -> String? {
        if let s = ev["command"] as? String { return short(s) }
        if let arr = ev["command"] as? [Any] {
            let parts = arr.compactMap { $0 as? String }
            if !parts.isEmpty { return short(parts.joined(separator: " ")) }
        }
        return nil
    }
}

// MARK: - Agent window chrome

// Borderless rounded workspace window (activating/key so typing works). Esc closes;
// closing kills any live run. Owned by AppDelegate as a single instance.
final class AgentWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { AppDelegate.shared.closeAgent() }
}

// MARK: - Agent multi-line input (Enter sends · Shift+Enter newline · Esc closes)

// NSTextView that lets an image paste (⌘V of a screenshot) be intercepted; a normal
// text paste falls through to the default behaviour.
final class PasteTextView: NSTextView {
    var onPasteImage: (() -> Bool)?
    override func paste(_ sender: Any?) {
        if onPasteImage?() == true { return }
        super.paste(sender)
    }
}

struct AgentInput: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let onSend: () -> Void
    let onEscape: () -> Void
    let onPasteImage: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = PasteTextView()
        tv.onPasteImage = onPasteImage
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.drawsBackground = false
        tv.textColor = .labelColor
        tv.insertionPointColor = .labelColor
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        context.coordinator.textView = tv

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .labelColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: AgentInput
        weak var textView: NSTextView?
        init(_ parent: AgentInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSend()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}

// MARK: - Agent view

private struct AgentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct AgentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Project chip + new/edit sheet (shared by Agent + Whiteboard title bars)

// Wrapping grid of tappable image thumbnails for a sent user bubble (opens full-size on click).
// Mirrors the whiteboard look styling: 120×90, rounded, 1px mono border. Two per row so a
// mixed batch of screenshots stays inside the bubble width.
struct BubbleThumbs: View {
    let paths: [String]
    let pal: Pal
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(stride(from: 0, to: paths.count, by: 2)), id: \.self) { start in
                HStack(spacing: 4) {
                    ForEach(paths[start..<min(start + 2, paths.count)], id: \.self) { p in
                        thumb(p)
                    }
                }
            }
        }
    }
    @ViewBuilder private func thumb(_ p: String) -> some View {
        if let img = NSImage(contentsOfFile: p) {
            Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 90).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(pal.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Open the full-size image")
        }
    }
}

// Unified affordance for the custom mono dropdown chips (project, popup model/backend, camera):
// Surface2-raised body, 1px Line border (→ LineStrong on hover), and a trailing chevron.down so
// "bordered chip + chevron = opens a menu" reads consistently. Implemented as a plain Button that
// pops an NSMenu — SwiftUI `Menu` labels get flattened to bare title text by AppKit (background,
// overlay, and inline images are all dropped), while Button labels render verbatim.
final class MenuActionBox {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()
    @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? MenuActionBox)?.run() }
}
// Convenience: an NSMenuItem driven by a Swift closure (✓ via state).
func chipMenuItem(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
    let it = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    it.target = MenuActionTarget.shared
    it.representedObject = MenuActionBox(run)
    if checked { it.state = .on }
    return it
}

struct MenuChipButton<Content: View>: View {
    let pal: Pal
    var radius: CGFloat = 6
    var hPad: CGFloat = 8
    var vPad: CGFloat = 2
    let makeMenu: () -> NSMenu
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: present) {
            HStack(spacing: 4) {
                content
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(pal.faint)
            }
            .padding(.horizontal, hPad).padding(.vertical, vPad)
            .background(RoundedRectangle(cornerRadius: radius).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(hovering ? pal.lineStrong : pal.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }

    private func present() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: view)
    }
}

// The mono project chip: current project + chevron, opening a menu of projects (✓ current),
// New project…, and Edit project brief…. Kept engine-agnostic via callbacks.
struct ProjectChipMenu: View {
    let current: Project
    let projects: [Project]
    let pal: Pal
    let onSwitch: (Project) -> Void
    let onNew: () -> Void
    let onEditBrief: () -> Void

    var body: some View {
        Menu {
            ForEach(projects) { p in
                Button(action: { onSwitch(p) }) {
                    if p.slug == current.slug { Label(p.name, systemImage: "checkmark") }
                    else { Text(p.name) }
                }
            }
            Divider()
            Button("New project…", action: onNew)
            Divider()
            Button("Edit project brief…", action: onEditBrief)
        } label: {
            MenuChipLabel(pal: pal, radius: 6) {
                Text(current.name).font(.system(size: 11.5, design: .monospaced)).foregroundColor(pal.text)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch project")
    }
}

// Small mono prompt for creating / editing a project (name + optional brief). In edit mode
// the name is read-only (renaming would re-slug the dir).
struct ProjectSheet: View {
    enum Mode { case create, edit }
    let mode: Mode
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var name: String
    @State private var brief: String
    private var pal: Pal { Pal.of(dark: scheme == .dark) }

    init(mode: Mode, name: String = "", brief: String = "", onSave: @escaping (String, String) -> Void) {
        self.mode = mode
        self.onSave = onSave
        _name = State(initialValue: name)
        _brief = State(initialValue: brief)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .create ? "New project" : "Edit project brief")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(pal.text)
            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.system(size: 11)).foregroundColor(pal.faint)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(mode == .edit)
                    .opacity(mode == .edit ? 0.6 : 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Brief (optional)").font(.system(size: 11)).foregroundColor(pal.faint)
                TextEditor(text: $brief)
                    .font(.system(size: 12))
                    .frame(height: 68)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(pal.line, lineWidth: 1))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(mode == .create ? "Create" : "Save") {
                    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if mode == .create && n.isEmpty { NSSound.beep(); return }
                    onSave(n, brief)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(pal.surface)
    }
}

struct AgentView: View {
    @ObservedObject var session: AgentSession
    @StateObject private var voice = SpeechDictation()
    @Environment(\.colorScheme) private var scheme
    @State private var appeared = false
    @State private var atBottom = true
    @State private var scrollHeight: CGFloat = 0
    @State private var dragOver = false
    @State private var showNewProject = false
    @State private var showEditBrief = false
    @State private var showHelp = false

    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    private var fontSize: CGFloat { contentFontSize() }

    private let helpLines: [(String, String)] = [
        ("attach / drag", "attach files; drag them onto the window too"),
        ("paste", "⌘V an image from the clipboard straight into the chat"),
        ("voice", "hold-to-talk voice input (needs mic + speech access)"),
        ("projects", "the chip by the title switches project / cwd; ⊕ starts a fresh session"),
        ("⊕", "new session in this project (clears the running conversation)"),
        ("permission", "Safe = read only · Standard = can edit files · Full = no sandbox"),
        ("↩ / esc", "send / close"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(pal.line)
            transcript
            Divider().overlay(pal.line)
            inputBar
        }
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(pal.surface))
        .overlay {
            if showHelp {
                HelpOverlay(title: "Agent — tips", lines: helpLines, pal: pal) { showHelp = false }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(dragOver ? pal.accent : pal.lineStrong, lineWidth: dragOver ? 1.5 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dragOver.animation(.easeInOut(duration: 0.15))) { providers in
            handleDrop(providers)
        }
        .foregroundColor(pal.text)
        .scaleEffect(appeared ? 1 : 0.97)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            voice.onFinal = { [weak session] t in
                guard let session else { return }
                session.input += (session.input.isEmpty || session.input.hasSuffix(" ") ? "" : " ") + t
            }
            withAnimation(.easeOut(duration: 0.16)) { appeared = true }
        }
        .sheet(isPresented: $showNewProject) {
            ProjectSheet(mode: .create) { name, brief in
                session.switchProject(ProjectStore.create(name: name, brief: brief))
            }
        }
        .sheet(isPresented: $showEditBrief) {
            ProjectSheet(mode: .edit, name: session.project.name, brief: session.project.brief) { _, brief in
                session.editBrief(brief)
            }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("Agent").font(.system(size: 12, weight: .semibold)).foregroundColor(pal.text)
            ProjectChipMenu(current: session.project, projects: session.projectList, pal: pal,
                            onSwitch: { session.switchProject($0) },
                            onNew: { showNewProject = true },
                            onEditBrief: { showEditBrief = true })
            if session.running { BreathingDot(pal: pal) }
            Spacer()
            HelpChip(pal: pal, on: $showHelp)
            Button(action: { session.startFreshSession() }) {
                Text("⊕").font(.system(size: 12)).foregroundColor(pal.muted)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(pal.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(pal.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Start a fresh conversation in this project")
            Text("\(session.engine) · \(session.model) · \(session.permission)")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(pal.faint)
            Button(action: { AppDelegate.shared.closeAgent() }) {
                Text("✕")
                    .font(.system(size: 11)).foregroundColor(pal.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(pal.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(pal.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.messages) { m in
                        AgentRow(msg: m, pal: pal, fontSize: fontSize)
                    }
                    // Visible "thinking" bubble whenever the agent is working but has
                    // nothing on screen yet (first token on big models can take 10s+ —
                    // without this the window reads as dead and users assume it broke).
                    if session.running && session.messages.last?.role != .assistant {
                        ThinkingRow(pal: pal)
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: AgentBottomKey.self,
                                                   value: g.frame(in: .named("agentScroll")).maxY)
                        })
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .coordinateSpace(name: "agentScroll")
            .background(GeometryReader { g in
                Color.clear.preference(key: AgentHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(AgentHeightKey.self) { scrollHeight = $0 }
            .onPreferenceChange(AgentBottomKey.self) { atBottom = $0 <= scrollHeight + 40 }
            .onReceive(session.$messages) { _ in
                guard atBottom else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if !session.attachments.isEmpty { attachTray }
            if voice.listening {
                HStack(spacing: 6) {
                    Text("● listening").font(.system(size: 10, design: .monospaced)).foregroundColor(pal.faint)
                    Text(voice.partial.isEmpty ? "…" : voice.partial)
                        .font(.system(size: fontSize - 1)).italic().foregroundColor(pal.faint)
                        .lineLimit(2)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if session.input.isEmpty {
                        Text("ask the agent to do something…")
                            .font(.system(size: fontSize)).foregroundColor(pal.faint.opacity(0.7))
                            .padding(.leading, 4).padding(.top, 4)
                    }
                    AgentInput(text: $session.input, fontSize: fontSize,
                               onSend: submit, onEscape: { AppDelegate.shared.closeAgent() },
                               onPasteImage: { session.pasteImageFromClipboard() })
                        .frame(minHeight: 22, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(session.cliMissing)
                }
                attachButton
                micButton
                sendStopButton
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.lineStrong, lineWidth: 1))
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
        .animation(.easeOut(duration: 0.15), value: session.attachments.count)
    }

    // Horizontal-scrolling row of pending attachments. Images render as a real thumbnail card
    // (tap to open); other files keep the icon+name pill. Both carry a ✕ remove badge, so a
    // pasted screenshot or snip is instantly recognizable as itself before it's sent.
    private var attachTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 6) {
                ForEach(session.attachments) { att in
                    attachChip(att)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        .frame(maxHeight: 62)
    }

    @ViewBuilder private func attachChip(_ att: AgentAttachment) -> some View {
        if att.isImage, let img = NSImage(contentsOfFile: att.path) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 74, height: 56).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(pal.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) { removeBadge(att) }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: att.path)) }
                .help(att.path)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "doc").font(.system(size: 11)).foregroundColor(pal.muted)
                Text(att.name.count > 24 ? String(att.name.prefix(22)) + "…" : att.name)
                    .font(.system(size: 11)).foregroundColor(pal.muted).lineLimit(1)
                Button(action: { withAnimation(.easeOut(duration: 0.12)) { session.removeAttachment(att.id) } }) {
                    Text("✕").font(.system(size: 10)).foregroundColor(pal.faint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(pal.surface2))
            .overlay(Capsule().stroke(pal.line, lineWidth: 1))
            .help(att.path)
        }
    }

    // ✕ remove badge overlaid on a thumbnail's top-right corner.
    private func removeBadge(_ att: AgentAttachment) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.12)) { session.removeAttachment(att.id) } }) {
            Text("✕").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(2)
        .help("Remove")
    }

    private var attachButton: some View {
        Button(action: pickFiles) {
            Image(systemName: "paperclip").font(.system(size: 14))
                .foregroundColor(pal.muted)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(session.running || session.cliMissing)
        .help("Attach files")
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = "Attach files"
        if panel.runModal() == .OK {
            for url in panel.urls { session.addAttachment(url.path) }
        }
    }

    // Files dropped onto the window are attached; folders attach as-is.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var path: String?
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { path = url.path }
                else if let url = item as? URL { path = url.path }
                if let path { DispatchQueue.main.async { session.addAttachment(path) } }
            }
        }
        return handled
    }

    @State private var micPulse = false
    private var micButton: some View {
        Button(action: { voice.toggle() }) {
            Image(systemName: voice.listening ? "mic.fill" : "mic")
                .font(.system(size: 13))
                .foregroundColor(voice.disabled ? pal.faint : (voice.listening ? pal.text : pal.muted))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(voice.listening ? pal.surface3 : pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(voice.listening ? pal.lineStrong : pal.line, lineWidth: 1))
                .opacity(voice.listening ? (micPulse ? 0.45 : 1) : 1)
        }
        .buttonStyle(.plain)
        .disabled(voice.disabled || session.running)
        .help(voice.disabled ? voice.statusHelp : "Voice input")
        .onChange(of: voice.listening) { _, now in
            if now {
                micPulse = false
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { micPulse = true }
            } else {
                withAnimation(.default) { micPulse = false }
            }
        }
    }

    private var sendStopButton: some View {
        Button(action: submitOrStop) {
            ZStack {
                Circle().fill(pal.accent)
                Image(systemName: session.running ? "stop.fill" : "arrow.up")
                    .font(.system(size: session.running ? 11 : 13, weight: .bold))
                    .foregroundColor(pal.onAccent)
                    .id(session.running)
                    .transition(.opacity.combined(with: .scale))
            }
            .frame(width: 30, height: 30)
            .scaleEffect(session.running ? 0.94 : 1)
            .animation(.easeInOut(duration: 0.18), value: session.running)
        }
        .buttonStyle(.plain)
        .disabled(!session.running && ((session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.attachments.isEmpty) || session.cliMissing))
        .help(session.running ? "Stop" : "Send (Enter)")
    }

    private func submit() {
        if voice.listening { voice.commit() }
        session.send()
    }

    private func submitOrStop() {
        if session.running { session.stop() } else { submit() }
    }
}

// Small breathing dot shown while a turn is running (opacity loop → Mono-legal).
struct BreathingDot: View {
    let pal: Pal
    @State private var on = false
    var body: some View {
        Circle().fill(pal.text).frame(width: 7, height: 7)
            .opacity(on ? 0.9 : 0.25)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// Assistant-style bubble with three staggered pulsing dots — shown while the agent
// is working but hasn't produced visible output yet.
struct ThinkingRow: View {
    let pal: Pal
    @State private var on = false
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(pal.text).frame(width: 6, height: 6)
                    .opacity(on ? 0.85 : 0.2)
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.16), value: on)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.line, lineWidth: 1))
        .onAppear { on = true }
    }
}

// One transcript row. Assistant/user get bubbles (fade in); tool/error/note are dim
// one-liners (slide in 4px). Context is a dim pill.
struct AgentRow: View {
    let msg: AgentMsg
    let pal: Pal
    let fontSize: CGFloat
    @State private var appeared = false
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : slideX)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
    }

    // Dim hover-reveal copy affordance for assistant bubbles (flashes "copied" ~1s).
    private var copyButton: some View {
        Button(action: copy) {
            Text(copied ? "copied" : "⧉")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(pal.faint)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(6)
        .opacity(hovering || copied ? 1 : 0)
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help("Copy")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(msg.text, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withAnimation { copied = false } }
    }

    private var slideX: CGFloat {
        switch msg.role {
        case .assistant, .user: return 0
        default: return 4
        }
    }

    @ViewBuilder private var content: some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg.text).font(.system(size: fontSize)).foregroundColor(pal.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    // Image attachments (whiteboard looks + agent-mode images) render as tappable
                    // thumbnails that open full-size; non-image files fall back to a filename line.
                    let imgPaths = msg.attachmentPaths.filter { AgentAttachment.isImagePath($0) }
                    let docNames = msg.attachments.filter { !AgentAttachment.isImagePath($0) }
                    if !imgPaths.isEmpty {
                        BubbleThumbs(paths: imgPaths, pal: pal)
                    }
                    if !docNames.isEmpty {
                        Text("\(Image(systemName: "paperclip")) " + docNames.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundColor(pal.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(pal.surface3))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.lineStrong, lineWidth: 1))
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg.text).font(.system(size: fontSize)).foregroundColor(pal.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if msg.stopped {
                        Text("stopped").font(.system(size: 10, design: .monospaced)).foregroundColor(pal.faint)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.line, lineWidth: 1))
                .overlay(alignment: .bottomTrailing) { copyButton }
                .onHover { hovering = $0 }
                Spacer(minLength: 44)
            }
        case .tool:
            HStack {
                Text(msg.text).font(.system(size: fontSize - 1, design: .monospaced)).foregroundColor(pal.faint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        case .error:
            HStack {
                Text("⚠︎ " + msg.text).font(.system(size: fontSize - 1)).foregroundColor(pal.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        case .note:
            HStack {
                Text(msg.text).font(.system(size: fontSize - 1.5)).foregroundColor(pal.faint)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        case .context:
            HStack {
                Text(msg.text).font(.system(size: fontSize - 2)).foregroundColor(pal.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(pal.surface2))
                    .overlay(Capsule().stroke(pal.line, lineWidth: 1))
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Settings

enum CodexAuthStatus {
    case connected(plan: String?)
    case expired
    case missing

    // Decode the JWT payload from ~/.codex/auth.json (shared by check() + expiry()).
    static func claims() -> [String: Any]? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let payload = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return claims
    }

    // Token expiry as a Date (nil when there's no readable login).
    static func expiry() -> Date? {
        guard let exp = claims()?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func check() -> CodexAuthStatus {
        guard let claims = claims(), let exp = claims["exp"] as? Double else { return .missing }
        if exp < Date().timeIntervalSince1970 { return .expired }
        let plan = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        return .connected(plan: plan)
    }
}

// MARK: - Health checks

// Every silent failure in live use traced to an invisible cause: Accessibility not
// granted, mic/camera/speech denied, a CLI missing, a ChatGPT token expired, node not
// on PATH. The Health panel makes all of them visible in one place — a live checklist
// a non-technical user (or his dad) can read when anything misbehaves.

enum HealthLevel: Sendable { case ok, warn, bad, checking
    var dotColor: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        case .checking: return .gray
        }
    }
}

struct HealthRow: Identifiable, Sendable {
    let id: String
    let title: String
    let level: HealthLevel
    let detail: String
    // Where a one-click fix exists (permissions), a System Settings deep-link.
    let fixLabel: String?
    let fixURL: String?

    init(_ id: String, _ title: String, _ level: HealthLevel, _ detail: String,
         fixLabel: String? = nil, fixURL: String? = nil) {
        self.id = id; self.title = title; self.level = level; self.detail = detail
        self.fixLabel = fixLabel; self.fixURL = fixURL
    }
}

// Privacy deep-links (open the exact pane so the user isn't hunting).
enum PrivacyPane {
    static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let speech = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    static let camera = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    static let screenCapture = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}

// Permissions that bind at process launch — a fresh grant only takes effect after a
// relaunch. Health surfaces a "Relaunch app" button + caption on these when red.
private let relaunchBoundHealthIDs: Set<String> = ["ax", "screen"]

// Standard self-relaunch: spawn a detached `open <bundle>` (delayed briefly so the
// old instance is gone), then terminate. Used by the Accessibility / Screen-recording
// rows whose grants only apply to a freshly-launched process.
@MainActor func relaunchApp() {
    let path = Bundle.main.bundlePath
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 0.3; open \"\(path)\""]
    try? p.run()
    NSApp.terminate(nil)
}

@MainActor
final class HealthMonitor: ObservableObject {
    static let shared = HealthMonitor()
    @Published var rows: [HealthRow] = HealthMonitor.instantRows()
    @Published var checking = false
    private var lastRun = Date.distantPast

    // Recompute only if the cache is older than ~10s (Settings/Welcome both poll on open).
    func refreshIfStale() {
        guard !checking, Date().timeIntervalSince(lastRun) > 10 else { return }
        Task { await refresh() }
    }

    func refresh() async {
        checking = true
        let computed = await HealthMonitor.computeAll()
        rows = computed
        lastRun = Date()
        checking = false
    }

    // Force a full recompute regardless of the 10s cache — busts every row including the
    // CLI/backend probes (their own resolve caches self-validate each call). Wired to the
    // explicit refresh button.
    func forceRefresh() {
        lastRun = .distantPast
        Task { await refresh() }
    }

    // Cheap, sync-only refresh of the TCC permission rows (Accessibility, Screen recording,
    // mic, speech, camera). These are instant status calls — no CLI/network probes — so the
    // Health panel can poll them every ~2s while visible and flip a row green within seconds
    // of the user granting a permission in System Settings. Leaves the expensive rows intact.
    func refreshFast() {
        let fresh = [Self.accessibilityRow(), Self.screenRecordingRow(),
                     Self.microphoneRow(), Self.speechRow(), Self.cameraRow()]
        var updated = rows
        for f in fresh {
            if let i = updated.firstIndex(where: { $0.id == f.id }) { updated[i] = f }
        }
        rows = updated
    }

    // Instant (sync-only) subset for the very first paint, before the async probes land.
    static func instantRows() -> [HealthRow] {
        [accessibilityRow(), screenRecordingRow(), microphoneRow(), speechRow(), cameraRow(),
         HealthRow("claude", "Claude Code CLI", .checking, "Checking…"),
         HealthRow("codex", "Codex CLI / ChatGPT login", .checking, "Checking…"),
         HealthRow("backend", "Active rewrite backend", .checking, "Checking…"),
         HealthRow("localvoice", "Local voice (Parakeet + Kokoro)", .checking, "Checking…")]
    }

    // Full async sweep. Runs off the main actor (nonisolated) so the CLI shell-outs
    // never block the UI; the @Published assignment hops back on the main actor.
    nonisolated static func computeAll() async -> [HealthRow] {
        var rows: [HealthRow] = [accessibilityRow(), screenRecordingRow(),
                                 microphoneRow(), speechRow(), cameraRow()]

        // Claude CLI
        let (claudeMsg, claudeOK) = await ClaudeCLI.status()
        rows.append(HealthRow("claude", "Claude Code CLI", claudeOK ? .ok : .bad, claudeMsg))

        // Codex CLI + ChatGPT token freshness
        rows.append(codexRow())

        // Active rewrite backend reachability (lightweight probe — never a paid call)
        rows.append(await backendRow())

        // Node — only relevant when Codex resolves (its shebang needs node on PATH)
        if CodexCLI.resolve() != nil {
            if let node = LoginShell.which("node") {
                rows.append(HealthRow("node", "Node (for Codex)", .ok, "Found at \(node)"))
            } else {
                rows.append(HealthRow("node", "Node (for Codex)", .bad,
                    "node not found in your login shell — Codex needs it. Install Node, then reopen."))
            }
        }

        // Local voice engines (optional) — venv present, helper ping, model cache state.
        rows.append(await localVoiceRow())
        return rows
    }

    // Optional local-voice health: venv present → ping the helper → report + model cache state.
    nonisolated static func localVoiceRow() async -> HealthRow {
        guard FileManager.default.isExecutableFile(atPath: VoicePaths.python.path) else {
            return HealthRow("localvoice", "Local voice (Parakeet + Kokoro)", .warn,
                "Not installed (optional) — install in Settings › Agent › Voice to run ASR/TTS offline.")
        }
        // Model cache state (Parakeet in the HF hub cache; Kokoro next to the helper).
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hf = home.appendingPathComponent(".cache/huggingface/hub")
        let parakeetCached = ["models--istupakov--parakeet-tdt-0.6b-v3-onnx", "models--istupakov--parakeet-tdt-0.6b-v2-onnx"]
            .contains { FileManager.default.fileExists(atPath: hf.appendingPathComponent($0).path) }
        let kokoroCached = FileManager.default.fileExists(atPath: VoicePaths.root.appendingPathComponent("kokoro-v1.0.onnx").path)
        let models = (parakeetCached && kokoroCached) ? "models cached"
            : ((parakeetCached || kokoroCached) ? "models download on first use (partial cache)" : "models download on first use")
        // Live ping (also refreshes VoiceStatus). Bounded by the helper's own request watchdog.
        let (asr, tts): (Bool, Bool) = await withCheckedContinuation { cont in
            VoiceEngine.shared.ping { a, t in cont.resume(returning: (a, t)) }
        }
        await MainActor.run { VoiceStatus.shared.refreshVenv(); VoiceStatus.shared.asrReady = asr; VoiceStatus.shared.ttsReady = tts; VoiceStatus.shared.pinged = true }
        if asr && tts {
            return HealthRow("localvoice", "Local voice (Parakeet + Kokoro)", .ok, "Installed, helper responds; \(models).")
        }
        return HealthRow("localvoice", "Local voice (Parakeet + Kokoro)", .warn,
            "venv present but the helper didn't verify — try Reinstall in Settings. \(models).")
    }

    // ---- individual checks ----

    nonisolated static func accessibilityRow() -> HealthRow {
        if AXIsProcessTrusted() {
            return HealthRow("ax", "Accessibility", .ok,
                             "Granted — selection buttons and paste-back work.")
        }
        return HealthRow("ax", "Accessibility", .bad,
                         "Not granted — selection buttons and paste-back won't work.",
                         fixLabel: "Open System Settings", fixURL: PrivacyPane.accessibility)
    }

    // Screen Recording — the ✂ snip flow shells out to `screencapture`, which inherits the
    // app's Screen Recording TCC. Preflight is instant and never triggers the prompt itself.
    nonisolated static func screenRecordingRow() -> HealthRow {
        if CGPreflightScreenCaptureAccess() {
            return HealthRow("screen", "Screen recording", .ok, "Granted — snips can capture the screen.")
        }
        return HealthRow("screen", "Screen recording", .bad,
                         "Not granted — the snip button can't capture the screen.",
                         fixLabel: "Open System Settings", fixURL: PrivacyPane.screenCapture)
    }

    nonisolated static func microphoneRow() -> HealthRow {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return HealthRow("mic", "Microphone", .ok, "Granted — voice input works.")
        case .notDetermined:
            return HealthRow("mic", "Microphone", .warn,
                             "Not asked yet — you'll be prompted the first time you use voice.")
        default:
            return HealthRow("mic", "Microphone", .bad,
                             "Denied — voice input (Agent + Whiteboard) won't work.",
                             fixLabel: "Open System Settings", fixURL: PrivacyPane.microphone)
        }
    }

    nonisolated static func speechRow() -> HealthRow {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return HealthRow("speech", "Speech recognition", .ok, "Granted — dictation works.")
        case .notDetermined:
            return HealthRow("speech", "Speech recognition", .warn,
                             "Not asked yet — you'll be prompted the first time you dictate.")
        default:
            return HealthRow("speech", "Speech recognition", .bad,
                             "Denied — dictation won't transcribe.",
                             fixLabel: "Open System Settings", fixURL: PrivacyPane.speech)
        }
    }

    nonisolated static func cameraRow() -> HealthRow {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return HealthRow("camera", "Camera", .ok, "Granted — Whiteboard mode can see the board.")
        case .notDetermined:
            return HealthRow("camera", "Camera", .warn,
                             "Not asked yet — you'll be prompted when you open Whiteboard.")
        default:
            return HealthRow("camera", "Camera", .bad,
                             "Denied — Whiteboard mode can't see the board.",
                             fixLabel: "Open System Settings", fixURL: PrivacyPane.camera)
        }
    }

    // Codex CLI presence + ChatGPT JWT freshness folded into one row.
    nonisolated static func codexRow() -> HealthRow {
        guard CodexCLI.resolve() != nil else {
            return HealthRow("codex", "Codex CLI / ChatGPT login", .bad,
                             "Codex CLI not found — npm i -g @openai/codex, then run `codex login`.")
        }
        switch CodexAuthStatus.check() {
        case .missing:
            return HealthRow("codex", "Codex CLI / ChatGPT login", .warn,
                             "CLI found, but not logged in — run `codex login` in a terminal.")
        case .expired:
            return HealthRow("codex", "Codex CLI / ChatGPT login", .bad,
                             "ChatGPT token expired — run `codex` in a terminal once to refresh.")
        case .connected(let plan):
            let p = plan.map { " (\($0) plan)" } ?? ""
            if let exp = CodexAuthStatus.expiry() {
                let days = exp.timeIntervalSinceNow / 86400
                if days < 2 {
                    let hrs = max(0, Int(exp.timeIntervalSinceNow / 3600))
                    return HealthRow("codex", "Codex CLI / ChatGPT login", .warn,
                                     "Logged in\(p) — token expires in ~\(hrs)h. Run `codex` to refresh.")
                }
                return HealthRow("codex", "Codex CLI / ChatGPT login", .ok,
                                 "Logged in\(p) — token valid for ~\(Int(days)) more days.")
            }
            return HealthRow("codex", "Codex CLI / ChatGPT login", .ok, "Logged in\(p).")
        }
    }

    // Reachability probe for whichever backend is currently selected for rewrites.
    nonisolated static func backendRow() async -> HealthRow {
        let backend = defaults().string(forKey: Keys.backend) ?? "ollama"
        switch backend {
        case "ollama":
            let base = defaults().string(forKey: Keys.ollamaURL) ?? "http://localhost:11434"
            guard let url = URL(string: base + "/api/tags") else {
                return HealthRow("backend", "Rewrite backend · Ollama", .bad, "Bad server URL: \(base)")
            }
            var req = URLRequest(url: url); req.timeoutInterval = 4
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    return HealthRow("backend", "Rewrite backend · Ollama", .ok, "Reachable at \(base).")
                }
                return HealthRow("backend", "Rewrite backend · Ollama", .bad,
                                 "Reached \(base) but got an unexpected response.")
            } catch {
                return HealthRow("backend", "Rewrite backend · Ollama", .bad,
                                 "Can't reach Ollama at \(base) — is `ollama serve` running?")
            }
        case "chatgpt":
            switch CodexAuthStatus.check() {
            case .connected:
                return HealthRow("backend", "Rewrite backend · ChatGPT", .ok, "ChatGPT login is valid.")
            case .expired:
                return HealthRow("backend", "Rewrite backend · ChatGPT", .bad,
                                 "ChatGPT token expired — run `codex` in a terminal to refresh.")
            case .missing:
                return HealthRow("backend", "Rewrite backend · ChatGPT", .bad,
                                 "No ChatGPT login — run `codex login` in a terminal.")
            }
        case "claude":
            if ClaudeCLI.resolve() != nil {
                return HealthRow("backend", "Rewrite backend · Claude", .ok, "Claude Code CLI is available.")
            }
            return HealthRow("backend", "Rewrite backend · Claude", .bad,
                             "Claude Code CLI not found — install it and run `claude` once.")
        default: // openai-compatible
            let key = (defaults().string(forKey: Keys.apiKey) ?? "").trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                return HealthRow("backend", "Rewrite backend · API", .bad,
                                 "No API key set — add one in Settings.")
            }
            return HealthRow("backend", "Rewrite backend · API", .ok, "API key is set.")
        }
    }
}

// Renders the HealthMonitor's rows as a mono checklist. `compact` trims the chrome
// for the welcome window; full mode adds the section header + refresh control.
struct HealthView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var monitor = HealthMonitor.shared
    var compact = false
    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    // Polls the cheap TCC rows while the panel is on screen, so a permission granted in
    // System Settings flips its row green in front of the user within ~2s.
    @State private var poll: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if !compact {
                HStack(spacing: 8) {
                    Text("Health").font(.system(size: 13, weight: .semibold))
                    if monitor.checking { ProgressView().controlSize(.small) }
                    Spacer()
                    // Force-bust every cache (incl. CLI/backend probes).
                    Button(action: { monitor.forceRefresh() }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Recheck everything now")
                }
                Text("If a feature seems dead, look here first. Red rows are the cause.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(monitor.rows) { row in healthRow(row) }
            }
        }
        .onAppear {
            Task { await monitor.refresh() }
            poll?.invalidate()
            poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in monitor.refreshFast() }
            }
        }
        .onDisappear { poll?.invalidate(); poll = nil }
    }

    private func healthRow(_ row: HealthRow) -> some View {
        // Bind-at-launch permissions (Accessibility, Screen recording) need a relaunch after a
        // fresh grant — offer it inline when the row is red.
        let needsRelaunch = row.level == .bad && relaunchBoundHealthIDs.contains(row.id)
        return HStack(alignment: .top, spacing: 9) {
            Circle().fill(row.level.dotColor).frame(width: 8, height: 8)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 12, weight: .semibold))
                Text(row.detail).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if needsRelaunch {
                    Text("after granting, relaunch to apply")
                        .font(.system(size: 10)).foregroundColor(.secondary).opacity(0.7)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                if let label = row.fixLabel, let urlStr = row.fixURL, let url = URL(string: urlStr) {
                    Button(label) { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
                if needsRelaunch {
                    Button("Relaunch app") { relaunchApp() }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - First-run welcome

// One mono screen (not a wizard): what the app does + the triggers, then the same
// Health checklist so permissions get granted UP FRONT with guidance, instead of
// ambush prompts the first time a feature is used. Reopenable from the menu.
struct WelcomeView: View {
    @Environment(\.colorScheme) private var scheme
    var onDismiss: () -> Void
    private var pal: Pal { Pal.of(dark: scheme == .dark) }

    // Descriptions are Text so the agent/snip lines can carry an inline SF Symbol that
    // tints with the theme (no color emoji). ✦ stays a text glyph (brand).
    private let features: [(String, Text)] = [
        ("Clean up text", Text("Select text → ✦ chips or ⌃⌘E popup · ⌃⌘R instant rewrite in place")),
        ("Agent", Text("\(Image(systemName: "cpu")) chip or the menu — an agent that can actually do work in a project")),
        ("Snip → Agent", Text("\(Image(systemName: "scissors")) screenshot a region and hand it to the agent")),
        ("Whiteboard", Text("point a webcam at a physical board and brainstorm out loud")),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleanup").font(.system(size: 24, weight: .semibold)).foregroundColor(pal.text)
                    Text("Rewrite what you select, run agents, and think out loud — from the menu bar.")
                        .font(.system(size: 12)).foregroundColor(pal.muted)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(features, id: \.0) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.0).font(.system(size: 13, weight: .semibold)).foregroundColor(pal.text)
                            f.1.font(.system(size: 11.5)).foregroundColor(pal.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("Whiteboard listens for a wake phrase — say “hey board” before talking to it (change it in the whiteboard window).")
                    .font(.system(size: 11)).foregroundColor(pal.faint)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(pal.line)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Grant permissions now so nothing silently fails later:")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(pal.text)
                    HealthView(compact: true)
                }

                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Text("Get started")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(pal.onAccent)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(pal.accent))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(28)
        }
        .frame(width: 460, height: 620)
        .background(pal.surface)
    }
}

// MARK: - Discoverability "?" help overlay

// Compact cheat-sheet dropped over the popup / agent / whiteboard when the "?" chip
// is tapped. Dim, unobtrusive, Mono; dismiss on click-away, "?" again, or Esc.
struct HelpOverlay: View {
    let title: String
    let lines: [(String, String)]   // (glyph/key, what it does)
    let pal: Pal
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            // click-away scrim
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(pal.text)
                    Spacer()
                    Button(action: onDismiss) {
                        Text("✕").font(.system(size: 11)).foregroundColor(pal.muted)
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(lines, id: \.0) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.0)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(pal.text)
                                .frame(width: 74, alignment: .leading)
                            Text(line.1).font(.system(size: 11.5)).foregroundColor(pal.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: 12).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.lineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .padding(24)
        }
    }
}

// Small "?" title-bar chip that toggles a HelpOverlay.
struct HelpChip: View {
    let pal: Pal
    @Binding var on: Bool
    var body: some View {
        Button(action: { on.toggle() }) {
            Text("?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(on ? pal.text : pal.muted)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? pal.surface3 : pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? pal.lineStrong : pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Keyboard shortcuts & tips")
    }
}

struct CodexStatusView: View {
    @State private var status = CodexAuthStatus.check()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(headline).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Check again") { status = CodexAuthStatus.check() }
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step.0).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                        step.1
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var dotColor: Color {
        switch status {
        case .connected: return .green
        case .expired: return .orange
        case .missing: return .red
        }
    }

    private var headline: String {
        switch status {
        case .connected(let plan):
            let p = plan.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
            return "Connected — using your ChatGPT \(p) plan"
        case .expired: return "Login expired — quick fix below"
        case .missing: return "Not connected yet — one-time setup"
        }
    }

    private func plain(_ s: String) -> Text { Text(s).font(.system(size: 11.5)).foregroundColor(.secondary) }
    private func code(_ s: String) -> Text {
        Text(s).font(.system(size: 11.5, design: .monospaced)).foregroundColor(.primary)
    }

    private var steps: [(String, Text)] {
        switch status {
        case .connected:
            return [("✓", plain("Nothing else to do. If it ever stops working, run ") + code("codex")
                        + plain(" once in Terminal — any run refreshes the login."))]
        case .expired:
            return [
                ("1.", plain("Open Terminal and run ") + code("codex") + plain(" — then quit it. Any run refreshes the token.")),
                ("2.", plain("Come back here and hit Check again.")),
            ]
        case .missing:
            return [
                ("1.", plain("Open Terminal and run ") + code("npm install -g @openai/codex")
                        + plain(" (skip if you have Codex).")),
                ("2.", plain("Run ") + code("codex login") + plain(" — a browser opens; sign in with your ChatGPT account.")),
                ("3.", plain("Come back here and hit Check again.")),
            ]
        }
    }
}

// Claude Code CLI status box (mirrors CodexStatusView). Resolving the CLI +
// reading `claude --version` shell out, so it loads async and never blocks the UI.
struct ClaudeStatusView: View {
    @State private var message = "Checking for the Claude Code CLI…"
    @State private var healthy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(healthy ? .green : .red).frame(width: 7, height: 7)
                Text(message).font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button("Check again") { Task { await load() } }
                    .controlSize(.small)
            }
            Text("Uses your Claude Code subscription — no API key. Slower than API backends (~8-10s per rewrite).")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .task { await load() }
    }

    private func load() async {
        let (msg, ok) = await ClaudeCLI.status()
        message = msg
        healthy = ok
    }
}

// The five Settings sections, surfaced as a persistent left sidebar. Health lands
// first — it's the "why is something broken" surface.
enum SettingsTab: String, CaseIterable, Identifiable {
    case health, rewrite, triggers, agent, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .health: return "Health"
        case .rewrite: return "Rewrite"
        case .triggers: return "Triggers"
        case .agent: return "Agent"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .health: return "heart.text.square"
        case .rewrite: return "wand.and.stars"
        case .triggers: return "cursorarrow.click"
        case .agent: return "cpu"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .health: return "If a feature seems dead, look here first. Red rows are the cause."
        case .rewrite: return "Where your rewrites come from, and their defaults."
        case .triggers: return "How you invoke Cleanup and the popup's look."
        case .agent: return "An agent that can actually do work — independent of the rewrite backend."
        case .about: return "Version and first-run help."
        }
    }
}

// The 54 Kokoro v1.0 voices (from voices-v1.0.bin), labelled by accent + gender.
// Prefix: 1st char = accent (a US, b UK, e Spanish, f French, h Hindi, i Italian,
// j Japanese, p Portuguese, z Chinese), 2nd char = gender (f/m). English first.
let kokoroVoices: [(tag: String, label: String)] = {
    let tags = ["af_heart","af_bella","af_nicole","af_sarah","af_sky","af_alloy","af_aoede",
                "af_jessica","af_kore","af_nova","af_river","am_michael","am_adam","am_echo",
                "am_eric","am_fenrir","am_liam","am_onyx","am_puck","am_santa",
                "bf_emma","bf_alice","bf_isabella","bf_lily","bm_george","bm_daniel","bm_fable","bm_lewis",
                "ef_dora","em_alex","em_santa","ff_siwis","hf_alpha","hf_beta","hm_omega","hm_psi",
                "if_sara","im_nicola","jf_alpha","jf_gongitsune","jf_nezumi","jf_tebukuro","jm_kumo",
                "pf_dora","pm_alex","pm_santa","zf_xiaobei","zf_xiaoni","zf_xiaoxiao","zf_xiaoyi",
                "zm_yunjian","zm_yunxi","zm_yunxia","zm_yunyang"]
    let accent = ["a": "US", "b": "UK", "e": "Spanish", "f": "French", "h": "Hindi",
                  "i": "Italian", "j": "Japanese", "p": "Portuguese", "z": "Chinese"]
    return tags.map { t in
        let acc = accent[String(t.prefix(1))] ?? "—"
        let gender = t.dropFirst().prefix(1) == "f" ? "female" : "male"
        let name = t.split(separator: "_").last.map { $0.capitalized } ?? t
        return (t, "\(name) — \(acc) \(gender)")
    }
}()

struct SettingsView: View {
    @AppStorage(Keys.backend) private var backend = "ollama"
    @AppStorage(Keys.ollamaURL) private var ollamaURL = "http://localhost:11434"
    @AppStorage(Keys.ollamaModel) private var ollamaModel = "llama3.2:3b"
    @AppStorage(Keys.apiBase) private var apiBase = "https://api.openai.com"
    @AppStorage(Keys.apiKey) private var apiKey = ""
    @AppStorage(Keys.apiModel) private var apiModel = "gpt-4o-mini"
    @AppStorage(Keys.chatgptModel) private var chatgptModel = "gpt-5.5"
    @AppStorage(Keys.chatgptEffort) private var chatgptEffort = "low"
    @AppStorage(Keys.claudeModel) private var claudeModel = "haiku"
    @AppStorage(Keys.defaultTone) private var defaultTone = "Clean"
    @AppStorage(Keys.defaultCount) private var defaultCount = 3
    @AppStorage(Keys.autoClose) private var autoClose = false
    @AppStorage(Keys.fontSize) private var fontSize = 13.0
    @AppStorage(Keys.floatingButton) private var floatingButton = true
    @AppStorage(Keys.chipStar) private var chipStar = true
    @AppStorage(Keys.chipBolt) private var chipBolt = true
    @AppStorage(Keys.chipAgent) private var chipAgent = true
    @AppStorage(Keys.chipSnip) private var chipSnip = true
    @AppStorage(Keys.buttonSize) private var buttonSize = 30.0
    @AppStorage(Keys.agentEngine) private var agentEngine = "claude"
    @AppStorage(Keys.agentModel) private var agentModel = "sonnet"
    @AppStorage(Keys.agentPermission) private var agentPermission = "safe"
    @AppStorage(Keys.agentContext) private var agentContext = ""
    @AppStorage(Keys.voiceASR) private var voiceASR = "system"
    @AppStorage(Keys.voiceTTS) private var voiceTTS = "system"
    @AppStorage(Keys.kokoroVoice) private var kokoroVoice = "af_heart"
    @State private var ollamaModels: [String] = []
    @StateObject private var audition = VoiceAudition()
    private let chatgptModels = ModelCatalog.chatgpt
    private let claudeModels = ModelCatalog.claude

    @Environment(\.colorScheme) private var scheme
    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    @State private var tab: SettingsTab = .health
    @ObservedObject private var health = HealthMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(pal.line).frame(width: 1)
            content
        }
        .frame(minWidth: 640, minHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.surface)
        .task { ollamaModels = await ModelCatalog.ollama() }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundColor(pal.faint)
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
            ForEach(SettingsTab.allCases) { sidebarRow($0) }
            Spacer()
        }
        .frame(width: 178)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(pal.surface2.opacity(scheme == .dark ? 0.5 : 0.6))
    }

    private func sidebarRow(_ t: SettingsTab) -> some View {
        let selected = tab == t
        return Button(action: { tab = t }) {
            HStack(spacing: 9) {
                Image(systemName: t.icon).font(.system(size: 12)).frame(width: 17)
                Text(t.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? pal.text : pal.muted)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? pal.surface3 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("settingsTab-\(t.rawValue)")
    }

    // MARK: content shell

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionHeader
                Group {
                    switch tab {
                    case .health:   healthSection
                    case .rewrite:  rewriteSection
                    case .triggers: triggersSection
                    case .agent:    agentSection
                    case .about:    aboutSection
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title).font(.system(size: 16, weight: .semibold)).foregroundColor(pal.text)
                Text(tab.subtitle).font(.system(size: 11.5)).foregroundColor(pal.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if tab == .health {
                if health.checking { ProgressView().controlSize(.small) }
                Button(action: { health.forceRefresh() }) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        .foregroundColor(pal.muted)
                }
                .buttonStyle(.plain)
                .help("Recheck everything now")
            }
        }
    }

    // MARK: shared building blocks

    @ViewBuilder
    private func card<C: View>(_ title: String? = nil, @ViewBuilder _ inner: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(pal.muted)
            }
            inner()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(pal.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.line, lineWidth: 1))
    }

    // Column-aligned label + control on one row.
    private func labeledRow<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundColor(pal.muted)
                .frame(width: 100, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    // A caption that lives UNDER its control, in Faint.
    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(pal.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        labeledRow(label) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: 1)
                Text("\(Int(value.wrappedValue))").font(.system(size: 12, design: .monospaced))
                    .foregroundColor(pal.text).frame(width: 22, alignment: .trailing)
            }
        }
    }

    // MARK: Health

    private var healthSection: some View {
        card { HealthView(compact: true) }
    }

    // MARK: Rewrite

    private var rewriteSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Backend") {
                labeledRow("Backend") {
                    Picker("", selection: $backend) {
                        Text("Ollama (local)").tag("ollama")
                        Text("ChatGPT subscription (Codex login)").tag("chatgpt")
                        Text("Claude Code subscription (CLI login)").tag("claude")
                        Text("OpenAI-compatible API").tag("openai")
                    }.labelsHidden()
                }
                backendPanel
            }
            card("Defaults") {
                labeledRow("Default tone") {
                    Picker("", selection: $defaultTone) {
                        ForEach(["Clean", "Professional", "Casual", "Blunt"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 220)
                }
                labeledRow("Variants") {
                    Stepper("\(defaultCount)", value: $defaultCount, in: 1...5)
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var backendPanel: some View {
        if backend == "ollama" {
            labeledRow("Server URL") {
                TextField("http://localhost:11434", text: $ollamaURL).textFieldStyle(.roundedBorder)
            }
            labeledRow("Model") {
                if ollamaModels.isEmpty {
                    TextField("llama3.2:3b", text: $ollamaModel).textFieldStyle(.roundedBorder)
                } else {
                    Picker("", selection: $ollamaModel) {
                        // keep the saved model selectable even if it's gone from the server
                        ForEach(ollamaModels.contains(ollamaModel) ? ollamaModels : [ollamaModel] + ollamaModels,
                                id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
            }
        } else if backend == "chatgpt" {
            labeledRow("Model") {
                Picker("", selection: $chatgptModel) {
                    ForEach(chatgptModels, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 220)
            }
            labeledRow("Reasoning") {
                Picker("", selection: $chatgptEffort) {
                    ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 220)
            }
            caption("Low reasoning is ~3x faster for short rewrites. gpt-5.4-mini is the fastest model (~1s).")
            CodexStatusView()
        } else if backend == "claude" {
            labeledRow("Model") {
                Picker("", selection: $claudeModel) {
                    ForEach(claudeModels, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 220)
            }
            ClaudeStatusView()
        } else {
            labeledRow("Base URL") {
                TextField("https://api.openai.com", text: $apiBase).textFieldStyle(.roundedBorder)
            }
            labeledRow("API key") {
                SecureField("sk-…", text: $apiKey).textFieldStyle(.roundedBorder)
            }
            labeledRow("Model") {
                TextField("gpt-4o-mini", text: $apiModel).textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: Triggers

    private var triggersSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Hotkeys") {
                caption("Select text, then ⌃⌘E to open the popup or ⌃⌘R to instantly rewrite it in place. You can also right-click → Clean Up Message.")
                caption("Hotkeys are fixed on macOS.")
            }
            card("Selection buttons") {
                Toggle("Show buttons when I select text", isOn: $floatingButton)
                    .foregroundColor(pal.text)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("✦ Clean up (opens the popup)", isOn: $chipStar)
                    Toggle(isOn: $chipBolt) { Text("\(Image(systemName: "bolt.fill")) Instant rewrite") }
                    Toggle(isOn: $chipAgent) { Text("\(Image(systemName: "cpu")) Agent mode") }
                    Toggle(isOn: $chipSnip) { Text("\(Image(systemName: "scissors")) Snip → Agent (screenshot a region)") }
                }
                .foregroundColor(pal.text)
                .padding(.leading, 14)
                .disabled(!floatingButton)
                if floatingButton {
                    sliderRow("Button size", value: $buttonSize, range: 22...48)
                }
            }
            card("Popup") {
                sliderRow("Text size", value: $fontSize, range: 11...18)
                Toggle("Auto-close when clicking away", isOn: $autoClose)
                    .foregroundColor(pal.text)
            }
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            card("Engine & permissions") {
                labeledRow("Engine") {
                    Picker("", selection: $agentEngine) {
                        Text("Codex (ChatGPT login)").tag("codex")
                        Text("Claude (Claude Code login)").tag("claude")
                    }
                    .labelsHidden().frame(maxWidth: 220)
                    .onChange(of: agentEngine) { _, newValue in
                        agentModel = AgentModels.defaultModel(newValue)
                    }
                }
                caption("More engines coming soon (Ollama, API keys).")
                labeledRow("Model") {
                    Picker("", selection: $agentModel) {
                        let list = AgentModels.list(agentEngine)
                        ForEach(list.contains(agentModel) ? list : [agentModel] + list, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 220)
                }
                labeledRow("Permissions") {
                    Picker("", selection: $agentPermission) {
                        Text("Safe — read & analyze only").tag("safe")
                        Text("Standard — can edit files").tag("standard")
                        Text("Full — no sandbox (dangerous)").tag("full")
                    }.labelsHidden().frame(maxWidth: 260)
                }
                if agentPermission == "full" {
                    Text("Full gives the agent unrestricted access to your machine. Use only when you trust the task.")
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AgentEngineStatusView(engine: agentEngine)
                caption("Agent and Whiteboard both use this provider and model. Whiteboard stays read-only.")
            }
            card("Personal context") {
                caption("Things the agent should know about you (pasted ChatGPT memories work great here). Applies to all projects.")
                TextEditor(text: $agentContext)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(pal.surface3))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(pal.line, lineWidth: 1))
                    // personal context is global — regenerate every project's CLAUDE.md / AGENTS.md
                    .onChange(of: agentContext) { _, _ in ProjectStore.regenerateAll() }
            }
            card("Voice") {
                caption("Whiteboard + agent voice. Local engines run fully offline once installed; the Apple defaults need no setup.")
                labeledRow("Transcription") {
                    Picker("", selection: $voiceASR) {
                        Text("System (Apple)").tag("system")
                        Text("Parakeet (local)").tag("parakeet")
                    }.labelsHidden().frame(maxWidth: 220)
                }
                if voiceASR == "parakeet" {
                    caption("More accurate, no live preview (transcribes each utterance after you pause).")
                }
                labeledRow("Speech output") {
                    Picker("", selection: $voiceTTS) {
                        Text("System voice").tag("system")
                        Text("Kokoro (local)").tag("kokoro")
                    }.labelsHidden().frame(maxWidth: 220)
                    Button(action: { audition.test(tts: voiceTTS, voice: kokoroVoice) }) {
                        HStack(spacing: 5) {
                            if audition.busy { ProgressView().controlSize(.small) }
                            Text(audition.busy ? "…" : "Test voice")
                        }
                    }
                    .controlSize(.small)
                    .disabled(audition.busy)
                    .help("Speak a sample through the selected output engine")
                }
                if !audition.note.isEmpty { caption(audition.note) }
                if voiceTTS == "kokoro" {
                    labeledRow("Kokoro voice") {
                        Picker("", selection: $kokoroVoice) {
                            ForEach(kokoroVoices, id: \.tag) { v in
                                Text(v.label).tag(v.tag)
                            }
                        }.labelsHidden().frame(maxWidth: 240)
                    }
                    caption("54 voices across 9 accents. English (US/UK) first; hit Test voice to hear the pick.")
                }
                VoiceInstallView()
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1.0"
        return card {
            labeledRow("Version") {
                Text("Cleanup \(version)").font(.system(size: 12)).foregroundColor(pal.text)
            }
            Rectangle().fill(pal.line).frame(height: 1).padding(.vertical, 2)
            Button(action: { AppDelegate.shared?.openWelcome() }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text("Open Welcome & health…").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(pal.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            caption("Source: github.com/AbhiPoluri/cleanup-app")
        }
    }
}

// Agent-engine CLI status box (mirrors ClaudeStatusView). Re-probes when the engine
// picker changes via .task(id:).
struct AgentEngineStatusView: View {
    let engine: String
    @State private var message = "Checking…"
    @State private var healthy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(healthy ? .green : .red).frame(width: 7, height: 7)
                Text(message).font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button("Check again") { Task { await load() } }
                    .controlSize(.small)
            }
            Text(engine == "codex"
                 ? "Uses your ChatGPT (Codex) login — no API key."
                 : "Uses your Claude Code login — no API key.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .task(id: engine) { await load() }
    }

    private func load() async {
        let (msg, ok) = engine == "codex" ? await CodexCLI.status() : await ClaudeCLI.status()
        message = msg
        healthy = ok
    }
}

// Install/status row for the local voice engines. Drives VoiceEngine.install() and reflects its
// phase (installing… / installed vX / failed + log pointer) from VoiceStatus.shared.
struct VoiceInstallView: View {
    @ObservedObject private var status = VoiceStatus.shared

    private var dot: Color {
        if status.venvPresent && status.asrReady && status.ttsReady { return .green }
        if status.venvPresent { return .yellow }
        return .secondary
    }
    private var installing: Bool {
        if case .installing = status.install { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(message).font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                if installing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(status.venvPresent ? "Reinstall" : "Install local voice engines") {
                        VoiceEngine.shared.install()
                    }
                    .controlSize(.small)
                }
            }
            Text("Downloads Parakeet (ASR) + Kokoro (TTS) into a managed Python venv at ~/Documents/Cleanup/voice. First use fetches the models (~1 GB) once, then runs offline.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onAppear {
            VoiceStatus.shared.refreshVenv()
            VoiceEngine.shared.refreshAvailability()
        }
    }

    private var message: String {
        switch status.install {
        case .installing(let step): return step
        case .installed(let v): return "Installed — \(v)"
        case .failed(let why): return why
        case .idle:
            if !status.venvPresent { return "Not installed — click Install to enable local voice." }
            if !status.pinged { return "Installed — checking…" }
            if status.asrReady && status.ttsReady { return "Installed — Parakeet + Kokoro ready." }
            return "Installed, but the helper didn't verify. Try Reinstall."
        }
    }
}

// Pure audition: speaks one sample sentence through the CURRENTLY selected output engine + voice.
// Independent of the whiteboard mute (this is its own synthesizer/player). Surfaces a brief busy
// state + inline status/error for the Settings "Test voice" button.
@MainActor
final class VoiceAudition: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var busy = false
    @Published var note = ""        // transient status ("synthesizing…"/"downloading model…") or error

    static let sample = "Hi — this is how I'll sound at the whiteboard."
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var slowTimer: Timer?

    override init() { super.init(); synth.delegate = self }

    func test(tts: String, voice: String) {
        guard !busy else { return }
        note = ""
        if tts == "kokoro" {
            guard VoiceEngine.shared.venvPresent else {
                note = "not installed — install local voice engines above"; return
            }
            busy = true; note = "synthesizing…"
            // If the helper is slow, it's almost always the one-time model download.
            slowTimer?.invalidate()
            slowTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                Task { @MainActor in if self?.busy == true { self?.note = "downloading model…" } }
            }
            let out = (((NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")) as NSString)
                .appendingPathComponent("audition-\(Int(Date().timeIntervalSince1970 * 1000)).wav")
            try? FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            VoiceEngine.shared.tts(text: Self.sample, voice: voice.isEmpty ? "af_heart" : voice, out: out) { [weak self] ok in
                guard let self else { return }
                self.slowTimer?.invalidate()
                if ok { self.playWav(out) }
                else { self.busy = false; self.note = "couldn't synthesize — check the install above" }
            }
        } else {
            busy = true; note = ""
            let u = AVSpeechUtterance(string: Self.sample)
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
            synth.speak(u)
        }
    }

    private func playWav(_ path: String) {
        note = ""
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            busy = false; note = "couldn't play the sample"; return
        }
        p.delegate = self
        player = p
        p.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.busy = false; self.player = nil }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.busy = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.busy = false }
    }
}

// MARK: - Whiteboard mode
//
// The user points a webcam at a physical whiteboard and brainstorms with a persistent
// selected agent session. The board is manually pinned via a
// draggable 4-corner quad; dewarped snapshots are auto-attached when the board is
// stable AND has meaningfully changed. Voice out (TTS) + open-mic voice in + a typed
// fallback. No auto quad detection, no OpenCV — pure downscaled-pixel differencing.

enum WBStatus { case watching, writing, looking }
enum WBCamera { case starting, running, denied, unavailable }

// MARK: Whiteboard session (uses the provider/model selected for Agent mode)

@MainActor
final class WhiteboardSession: StreamingSession {
    @Published var running = false
    @Published var input = ""
    // The project supplying cwd + per-project resume state. @Published so the chip reflects switches.
    @Published var project: Project
    let engine: String
    let model: String
    let permission: String
    let cliMissing: Bool

    // Spoken aloud → keep replies short. Prepended to the FIRST task as the framing.
    static let framing = "You are a whiteboard brainstorming partner. The user is writing on a physical whiteboard; you receive photos of it as it evolves. Respond conversationally and briefly (2-4 sentences — your replies are spoken aloud): build on new ideas, cluster or connect things, ask at most one sharp question, or point out what's missing. Never enumerate the whole board back. If the user has drawn a question mark in a box or circle, treat the content near it as a direct question to you and answer it specifically."
    static let lookPrompt = "Board update photo attached. Comment on what's new or answer any boxed/circled ? question."

    private var framingSeeded = false   // framing prepended to the FIRST task only
    private var proc: Process?
    private var runTask: Task<Void, Never>?
    var onAssistantComplete: ((String) -> Void)?   // fired with the final text (for TTS)

    var projectList: [Project] { ProjectStore.list() }

    // User turns so far — drives the auto-export-on-close threshold (≥2).
    var userTurnCount: Int { messages.filter { $0.role == .user }.count }

    init(engine: String, model: String, permission: String, project: Project) {
        self.engine = engine
        self.model = model
        self.permission = permission
        self.project = project
        self.cliMissing = (engine == "codex" ? CodexCLI.resolve() : ClaudeCLI.resolve()) == nil
        super.init()
        messages.append(AgentMsg(role: .note, text: cliMissing
            ? (engine == "codex"
                ? "Codex CLI not found. Install it and run `codex login`, then reopen. — see Health in Settings"
                : "Claude Code CLI not found. Install it and run `claude` once to log in, then reopen. — see Health in Settings")
            : "Pin the board with the four corners, then write on it or just talk — I'll watch and chime in."))
        // Continuity: if this project has exported past whiteboard summaries, say so — the agent
        // can read them from ./sessions/ (they live in its cwd) to refer back.
        if !cliMissing {
            let priors = Self.priorSessionCount(project)
            if priors > 0 {
                messages.append(AgentMsg(role: .note,
                    text: "This project has \(priors) past whiteboard session\(priors == 1 ? "" : "s") — I can refer back to them."))
            }
        }
    }

    static func priorSessionCount(_ p: Project) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: p.sessionsDir.path)) ?? []
        return files.filter { $0.hasSuffix("-whiteboard.md") }.count
    }

    // ---- project switching (chip menu) — swaps cwd for subsequent turns ----

    func switchProject(_ p: Project) {
        guard p.slug != project.slug else { return }
        project = p
        ProjectStore.setCurrent(p.slug)
        messages.append(AgentMsg(role: .note, text: "— switched to \(p.name) —"))
        logLine("wb: switch project=\(p.slug) resume=\(p.hasSession ? "continue" : "fresh")")
    }

    func editBrief(_ brief: String) {
        project.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        ProjectStore.save(project)
        ProjectStore.writeInstructionFiles(project)
        messages.append(AgentMsg(role: .note, text: "updated \(project.name)'s brief"))
    }

    // A spoken or typed user turn. If `imagePath` is supplied (a look request), a fresh
    // dewarped snapshot rides along with the user's own words so "look at the board — which
    // idea is strongest?" is one turn: message + image.
    func sendTyped(_ raw: String, imagePath: String? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, !cliMissing else { if !running && !cliMissing { NSSound.beep() }; return }
        if let imagePath, FileManager.default.fileExists(atPath: imagePath) {
            messages.append(AgentMsg(role: .user, text: text,
                                     attachments: [(imagePath as NSString).lastPathComponent],
                                     attachmentPaths: [imagePath]))
            var task = text
            if !framingSeeded { task = Self.framing + "\n\n" + task }
            task += "\n\nA fresh photo of the board is attached (read it before answering):\n- \(imagePath)"
            run(task: task, imagePath: imagePath)
        } else {
            messages.append(AgentMsg(role: .user, text: text))
            var task = text
            if !framingSeeded { task = Self.framing + "\n\n" + task }
            run(task: task)
        }
    }

    // Swap the ready/seed note text (kept for the two-verb explainer). No-op if the CLI is
    // missing (that note stays) or no note is present.
    func setReadyNote(_ text: String) {
        guard !cliMissing, let i = messages.firstIndex(where: { $0.role == .note }) else { return }
        messages[i] = AgentMsg(role: .note, text: text)
    }

    // A board look — the dewarped snapshot is attached (Claude reads it via its Read tool,
    // allowed in the safe tier). Mirrors AgentSession's "Attached files" convention.
    func sendLook(imagePath: String) {
        guard !running, !cliMissing, FileManager.default.fileExists(atPath: imagePath) else { return }
        messages.append(AgentMsg(role: .user, text: "board photo",
                                 attachments: [(imagePath as NSString).lastPathComponent],
                                 attachmentPaths: [imagePath]))
        var task = Self.lookPrompt
        if !framingSeeded { task = Self.framing + "\n\n" + task }
        task += "\n\nAttached files (read them before answering):\n- \(imagePath)"
        run(task: task, imagePath: imagePath)
    }

    private func run(task: String, imagePath: String? = nil) {
        // Claude resumes by cwd; Codex must have a project-owned id (hasSession may have been
        // set by a Claude turn before the user changed providers in Settings).
        let turnProject = project
        let followup = engine == "codex"
            ? !(turnProject.codexSessionId ?? "").isEmpty
            : turnProject.hasSession
        if !project.hasSession { project.hasSession = true; ProjectStore.save(project) }
        framingSeeded = true
        running = true
        curAssistant = nil
        resetSeg()
        runTask = Task { [weak self] in
            await self?.launch(task: task, imagePath: imagePath,
                               followup: followup, turnProject: turnProject)
        }
    }

    func stop() {
        runTask?.cancel(); runTask = nil
        if let p = proc, p.isRunning {
            p.terminate()
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
        }
        proc = nil
        flushText()
        curAssistant = nil
        running = false
    }

    private func launch(task: String, imagePath: String?, followup: Bool, turnProject: Project) async {
        let cli = engine == "codex" ? CodexCLI.resolve() : ClaudeCLI.resolve()
        guard let cli else {
            messages.append(AgentMsg(role: .error, text: engine == "codex" ? "Codex CLI not found" : "Claude Code CLI not found"))
            running = false; return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = buildArgs(task: task, imagePath: imagePath,
                                followup: followup, turnProject: turnProject)
        p.environment = engine == "codex" ? CodexCLI.env() : ClaudeCLI.env()
        // Per-project workdir (~/Documents/Cleanup/projects/<slug>), NOT $HOME — keeps the user's
        // personal ~/CLAUDE.md out of the run; --continue is cwd-scoped, so it resumes this
        // project's board conversation. Snapshots still ride via --add-dir (temp dir, outside cwd).
        p.currentDirectoryURL = ProjectStore.ensureDir(turnProject)
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() }
        catch {
            messages.append(AgentMsg(role: .error, text: "\(engine == "codex" ? "Codex" : "Claude") CLI failed to start — \(error.localizedDescription)"))
            running = false; return
        }
        proc = p
        let resumeDesc = followup ? (engine == "codex"
            ? (turnProject.codexSessionId?.isEmpty == false ? "resume-id" : "resume-last") : "continue") : "fresh"
        logLine("wb: project=\(turnProject.slug) resume=\(resumeDesc) engine=\(engine) model=\(model) tasklen=\(task.count)")

        let stderrTask = Task<String, Never>.detached {
            let d = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return String(data: d, encoding: .utf8) ?? ""
        }
        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { break }
                if line.isEmpty { continue }
                if engine == "codex" { handleWhiteboardCodex(line) } else { handleClaude(line) }
            }
        } catch { /* stream ended / cancelled */ }

        flushText()
        let finalText = currentAssistantText
        curAssistant = nil
        p.waitUntilExit()
        if !Task.isCancelled && p.terminationStatus != 0 {
            var tail = (await stderrTask.value).trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.count > 300 { tail = "…" + String(tail.suffix(300)) }
            messages.append(AgentMsg(role: .error, text: tail.isEmpty ? "exit \(p.terminationStatus)" : tail))
        }
        proc = nil
        running = false
        if let finalText, !Task.isCancelled { onAssistantComplete?(finalText) }
    }

    // Whiteboard remains read-only even if the regular Agent has edit permissions: it only
    // needs to inspect snapshots and converse. Provider and model still match Agent Settings.
    private func buildArgs(task: String, imagePath: String?, followup: Bool, turnProject: Project) -> [String] {
        if engine == "codex" {
            var a = ["exec"]
            if followup {
                a.append("resume")
                // followup is true for Codex only when this project owns an id.
                a.append(turnProject.codexSessionId!)
            }
            a.append("--json")
            if followup { a += ["-c", "sandbox_mode=\"read-only\""] }
            else { a += ["-s", "read-only"] }
            a.append("--skip-git-repo-check")
            if !model.isEmpty { a += ["-m", model] }
            if let imagePath { a += ["-i", imagePath] }
            a.append(task)
            return a
        }

        // --add-dir is load-bearing for Claude: snapshots live outside the project cwd.
        var a = ["-p"]
        if followup { a.append("--continue") }
        a.append(task)
        if !model.isEmpty { a += ["--model", model] }
        a += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        a += ["--permission-mode", "dontAsk", "--disallowedTools", "Bash Edit Write NotebookEdit",
              "--allowedTools", "Read"]
        a += ["--add-dir", (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")]
        a += ["--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
              "--settings", "{\"disableAllHooks\":true}"]
        return a
    }

    // Codex JSONL parsing mirrors AgentSession so Whiteboard gets streaming text and captures
    // the thread id required for this project's next turn.
    private func handleWhiteboardCodex(_ line: String) {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            event(line); return
        }
        var ev = root
        if let m = root["msg"] as? [String: Any] { ev = m }
        else if let item = root["item"] as? [String: Any] { ev = item }

        captureWhiteboardCodexSession(root, ev)
        let type = ((ev["type"] as? String) ?? (root["type"] as? String) ?? "").lowercased()
        if type.isEmpty || type.contains("reasoning") { return }
        if type.contains("delta") {
            appendDelta((ev["delta"] as? String) ?? (ev["text"] as? String) ?? "")
            return
        }
        if type.contains("agent_message") || type == "assistant" || type == "message" ||
            (type.contains("message") && !type.contains("user") && !type.contains("system")) {
            if let text = whiteboardCodexText(ev) { setFull(text) }
            return
        }
        if type.contains("exec") || type.contains("command") || type.contains("shell") {
            if !type.contains("end") && !type.contains("output") && !type.contains("delta") {
                event("▸ inspecting the board")
            }
            return
        }
        if type.contains("patch") || type.contains("apply") || type.contains("edit") || type.contains("write") {
            if !type.contains("end") { event("▸ processing") }
        }
    }

    private func captureWhiteboardCodexSession(_ root: [String: Any], _ ev: [String: Any]) {
        guard (project.codexSessionId ?? "").isEmpty else { return }
        func direct(_ e: [String: Any]) -> String? {
            for key in ["session_id", "thread_id", "sessionId", "threadId"] {
                if let value = e[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        func nested(_ e: [String: Any]) -> String? {
            for key in ["thread", "session"] {
                guard let object = e[key] as? [String: Any] else { continue }
                for idKey in ["id", "thread_id", "session_id"] {
                    if let value = object[idKey] as? String, !value.isEmpty { return value }
                }
            }
            return nil
        }
        guard let id = direct(ev) ?? direct(root) ?? nested(ev) ?? nested(root) else { return }
        project.codexSessionId = id
        ProjectStore.save(project)
        logLine("wb: codex resume id=\(id)")
    }

    private func whiteboardCodexText(_ ev: [String: Any]) -> String? {
        if let value = ev["message"] as? String { return value }
        if let value = ev["text"] as? String { return value }
        if let value = ev["content"] as? String { return value }
        guard let content = ev["content"] as? [Any] else { return nil }
        let text = content.compactMap { block -> String? in
            if let value = block as? String { return value }
            return (block as? [String: Any])?["text"] as? String
        }.joined()
        return text.isEmpty ? nil : text
    }
}

// MARK: Session export → project memory
//
// On "End session" (or auto on close of a ≥2-turn session) fire ONE final --continue turn asking
// for a compact markdown recap, and save it to <project>/sessions/<ts>-whiteboard.md. This is
// DETACHED and owns its OWN Process — the engine's kill discipline (session.stop()) touches only
// the live turn's process, never this one, so the summary survives the window closing. Capped at
// 60s. The instruction files already tell agents summaries live in ./sessions/.
enum WhiteboardExport {
    static let prompt = "Write a compact markdown summary of this whiteboard session: the board's final state, key ideas, decisions, and open questions. Reply with only the markdown."

    static func run(project: Project, engine: String, model: String) {
        let cli = engine == "codex" ? CodexCLI.resolve() : ClaudeCLI.resolve()
        guard let cli else { logLine("wb: session export failed — no selected agent CLI"); return }
        if engine == "codex", (project.codexSessionId ?? "").isEmpty {
            logLine("wb: session export failed — no Codex session id")
            return
        }
        let cwd = ProjectStore.ensureDir(project)
        let sessionsDir = project.sessionsDir
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            var a: [String]
            if engine == "codex" {
                a = ["exec", "resume", project.codexSessionId!, "--json",
                     "-c", "sandbox_mode=\"read-only\"", "--skip-git-repo-check"]
                if !model.isEmpty { a += ["-m", model] }
                a.append(prompt)
            } else {
                a = ["-p", "--continue", prompt]
                if !model.isEmpty { a += ["--model", model] }
                a += ["--permission-mode", "dontAsk", "--disallowedTools", "Bash Edit Write NotebookEdit",
                      "--allowedTools", "Read", "--add-dir", tmp,
                      "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                      "--settings", "{\"disableAllHooks\":true}"]
            }
            p.arguments = a
            p.environment = engine == "codex" ? CodexCLI.env() : ClaudeCLI.env()
            p.currentDirectoryURL = cwd
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() }
            catch { logLine("wb: session export failed — \(error.localizedDescription)"); return }
            // 60s cap — terminate, then SIGKILL if it clings on.
            let pid = p.processIdentifier
            let killer = DispatchWorkItem {
                if p.isRunning {
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            p.waitUntilExit()
            killer.cancel()
            let raw = String(data: data, encoding: .utf8) ?? ""
            let text = (engine == "codex" ? codexSummary(from: raw) : raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                logLine("wb: session export failed — empty summary (exit \(p.terminationStatus))"); return
            }
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd-HHmm"
            let url = sessionsDir.appendingPathComponent("\(fmt.string(from: Date()))-whiteboard.md")
            do {
                try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                logLine("wb: session export saved → \(url.path)")
            } catch { logLine("wb: session export failed — write \(error.localizedDescription)") }
        }
    }

    private static func codexSummary(from jsonl: String) -> String {
        var latest = ""
        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ev = (root["item"] as? [String: Any]) ?? (root["msg"] as? [String: Any]) ?? root
            let type = ((ev["type"] as? String) ?? "").lowercased()
            guard type.contains("agent_message") || type == "assistant" || type == "message" else { continue }
            if let value = ev["text"] as? String { latest = value }
            else if let value = ev["message"] as? String { latest = value }
            else if let value = ev["content"] as? String { latest = value }
        }
        return latest
    }
}

// MARK: Kokoro playback — sentence-chunked local TTS with barge-in-safe cancellation
//
// Splits a reply into sentences and synthesizes+plays them SEQUENTIALLY via the helper +
// AVAudioPlayer, so the first audio starts as soon as the first sentence is ready (not after
// the whole reply) and stop()/barge-in can cut in cleanly between chunks. A generation counter
// (lock-guarded so main can bump it while the worker queue reads it) supersedes an in-flight
// reply. onStart fires exactly once when the first chunk begins; onDone fires exactly once at
// the natural end OR on an external stop — identical semantics to AVSpeech's delegate, so the
// engine's echo guard (mic gate + barge listener) behaves the same in both TTS modes.
final class KokoroPlayer {
    var onStart: (() -> Void)?   // invoked from the worker queue; caller hops to main
    var onDone: (() -> Void)?

    private let q = DispatchQueue(label: "com.abhiram.cleanup.kokoro")
    private let lock = NSLock()
    private var _gen = 0
    private var _speaking = false

    private func gen() -> Int { lock.lock(); defer { lock.unlock() }; return _gen }
    private func setSpeaking(_ v: Bool) { lock.lock(); _speaking = v; lock.unlock() }

    // Begin speaking `text`. Supersedes any in-flight reply. If we were already speaking
    // (kokoro→kokoro replacement), onStart is NOT re-fired and onDone is NOT fired — the
    // "speaking" state carries across so the mic never briefly re-opens.
    func speak(text: String, voice: String) {
        lock.lock()
        let wasSpeaking = _speaking
        _gen += 1
        let g = _gen
        lock.unlock()
        let sentences = Self.splitSentences(text)
        q.async { [weak self] in self?.playSentences(sentences, voice: voice, g: g, alreadySpeaking: wasSpeaking) }
    }

    // External stop (mute / barge-in / window close). Supersedes the worker and fires onDone
    // once iff we were speaking, so the mic re-opens.
    func stop() {
        lock.lock()
        let was = _speaking
        _gen += 1
        _speaking = false
        lock.unlock()
        if was { onDone?() }
    }

    private func playSentences(_ sentences: [String], voice: String, g: Int, alreadySpeaking: Bool) {
        var announced = alreadySpeaking
        for s in sentences {
            if gen() != g { return }
            guard let wav = synthSync(s, voice: voice) else { continue }
            if gen() != g { try? FileManager.default.removeItem(atPath: wav); return }
            if !announced { announced = true; setSpeaking(true); onStart?() }
            playAndWait(wav, g: g)
            try? FileManager.default.removeItem(atPath: wav)
            if gen() != g { return }
        }
        // natural end — fire onDone only if we're still the current generation
        lock.lock()
        let mine = (_gen == g)
        if mine { _speaking = false }
        lock.unlock()
        if mine { onDone?() }
    }

    // Blocking single-chunk synth via the helper (semaphore bridges the async completion; the
    // completion hops to main, the worker queue waits — no deadlock, different queues).
    private func synthSync(_ text: String, voice: String) -> String? {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = (dir as NSString).appendingPathComponent("tts-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 0...9999)).wav")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        VoiceEngine.shared.tts(text: text, voice: voice, out: out) { success in ok = success; sem.signal() }
        sem.wait()
        return ok ? out : nil
    }

    // Play one WAV and block until it finishes or the generation is superseded (checked every
    // 20ms so barge-in cuts within ~20ms). player is local — no shared mutable playback state.
    private func playAndWait(_ wav: String, g: Int) {
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: wav)) else { return }
        player.prepareToPlay()
        player.play()
        let bound = player.duration + 1.0
        let start = Date()
        usleep(40_000)   // let playback ramp before polling isPlaying
        while gen() == g && player.isPlaying && Date().timeIntervalSince(start) < bound { usleep(20_000) }
        player.stop()
    }

    // Sentence split (keeps terminal punctuation), then break any overlong chunk on word
    // boundaries so the first audio still starts fast.
    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        var final: [String] = []
        for s in out {
            if s.count <= 240 { final.append(s); continue }
            var piece = ""
            for w in s.split(separator: " ") {
                if piece.count + w.count > 200 {
                    let p = piece.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty { final.append(p) }
                    piece = ""
                }
                piece += w + " "
            }
            let p = piece.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { final.append(p) }
        }
        return final.isEmpty ? [text] : final
    }
}

// MARK: Voice out — speaks each completed assistant reply (echo-guard hooks)
//
// System path = AVSpeechSynthesizer (default + fallback). Local path = KokoroPlayer. Both drive
// the SAME onStart/onDone hooks the engine relies on for the echo guard, so mic-gating and the
// barge listener behave identically regardless of which engine is selected.
@MainActor
final class BoardSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let kokoro = KokoroPlayer()
    var onStart: (() -> Void)?
    var onDone: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        // KokoroPlayer callbacks arrive off-main; hop to the MainActor before touching the hooks.
        kokoro.onStart = { [weak self] in Task { @MainActor in self?.onStart?() } }
        kokoro.onDone  = { [weak self] in Task { @MainActor in self?.onDone?() } }
    }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if VoiceModes.kokoroTTS {
            stopSystem()                                   // ensure AVSpeech isn't also going
            kokoro.speak(text: t, voice: VoiceModes.kokoroVoiceName)
        } else {
            kokoro.stop()                                  // stop any local playback first
            stopSystem()
            let u = AVSpeechUtterance(string: t)
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92   // a touch below default
            synth.speak(u)
        }
    }

    func stop() { stopSystem(); kokoro.stop() }
    private func stopSystem() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) } }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.onStart?() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.onDone?() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.onDone?() }
    }
}

// MARK: Barge-in — a limited wake-only recognizer kept alive DURING TTS
//
// The full mic is torn down while the agent speaks (echo guard). This slim recognizer runs in its
// place, matching ONLY the wake phrase, so the user can cut in across the room. Echo risk: the TTS
// voice could theoretically utter the phrase — we require the FULL contiguous phrase and log every
// trigger ("wb: barge-in") so a self-trigger is visible and tunable. Its own AVAudioEngine never
// overlaps the main listener's (that one is stopped during playback).
@MainActor
final class BargeListener: NSObject {
    var onBarge: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var phraseTokens: [String] = []
    private var active = false

    private func norm(_ s: Substring) -> String {
        String(String(s).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    func start(phrase: String) {
        let toks = phrase.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(norm).filter { !$0.isEmpty }
        guard !toks.isEmpty, recognizer?.isAvailable == true,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        stop()
        phraseTokens = toks
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        let input = audio.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        audio.prepare()
        do { try audio.start() } catch { return }
        active = true
        logLine("wb: barge listener start")
        task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString, !text.isEmpty else { return }
            Task { @MainActor in self?.check(text) }
        }
    }

    // Contiguous full-phrase match anywhere in the heard text.
    private func check(_ text: String) {
        guard active else { return }
        let toks = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(norm).filter { !$0.isEmpty }
        let n = phraseTokens.count
        guard toks.count >= n, n > 0 else { return }
        for start in 0...(toks.count - n) {
            var ok = true
            for k in 0..<n where toks[start + k] != phraseTokens[k] { ok = false; break }
            if ok {
                logLine("wb: barge-in")
                let cb = onBarge
                stop()
                cb?()
                return
            }
        }
    }

    func stop() {
        guard active || audio.isRunning else { return }
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        active = false
        logLine("wb: barge listener stop")
    }
}

// Which voice path is active right now. `available` = the local engines are actually installed
// (venv present) — kept deliberately loose (not requiring a resolved ping) so a fresh install
// engages immediately; a failed helper request degrades transparently to the system path.
enum VoiceModes {
    static var parakeetASR: Bool {
        (defaults().string(forKey: Keys.voiceASR) ?? "system") == "parakeet" && VoiceEngine.shared.venvPresent
    }
    static var kokoroTTS: Bool {
        (defaults().string(forKey: Keys.voiceTTS) ?? "system") == "kokoro" && VoiceEngine.shared.venvPresent
    }
    static var kokoroVoiceName: String {
        let v = (defaults().string(forKey: Keys.kokoroVoice) ?? "af_heart").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "af_heart" : v
    }
}

// MARK: Voice in — continuous open-mic with silence segmentation + rolling restart
//
// Continuous SFSpeechRecognizer (system path). A spoken utterance is committed after ~1.7s of
// silence (or on isFinal). To dodge the ~60s per-request limit — and to keep the echo guard
// simple — the whole engine is torn down and rebuilt on every commit and on any recognition
// error (logged). Listening is gated by the engine (setGateOpen) so it pauses while the agent
// is speaking/streaming. When Parakeet is selected, a LocalSpeechCapture replaces the SFSpeech
// machinery (raw PCM → silence-segmented WAVs → helper ASR; no live partials, no rolling
// restart — that machinery stays ONLY on the system path).
@MainActor
final class BoardListener: NSObject, ObservableObject {
    @Published var listening = false
    @Published var partial = ""
    @Published var statusHelp = "Voice input"

    var onUtterance: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?

    private var userEnabled = false      // the mic toggle
    private var gateOpen = true          // false while the agent is speaking / streaming
    private var authorized = false
    private let silenceInterval: TimeInterval = 1.7
    private var local: LocalSpeechCapture?   // Parakeet path (nil on the system path)
    private var capturing = false            // either SFSpeech audio OR local capture is live

    var disabled: Bool {
        guard recognizer != nil else { return true }
        let s = SFSpeechRecognizer.authorizationStatus()
        return s == .denied || s == .restricted
    }

    func setEnabled(_ on: Bool) {
        userEnabled = on
        if on { authorize { _ in self.reconcile() } } else { reconcile() }
    }
    func setGateOpen(_ open: Bool) { gateOpen = open; reconcile() }

    // Start/stop the capture engine to match the desired state (idempotent).
    private func reconcile() {
        let want = userEnabled && gateOpen && authorized && !disabled
        if want && !capturing { begin() }
        else if !want && capturing { teardown() }
    }

    private func authorize(_ done: @escaping (Bool) -> Void) {
        guard recognizer != nil else { statusHelp = "Voice input unavailable — no recognizer"; done(false); return }
        func micStep() {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: self.authorized = true; done(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in
                        self.authorized = ok
                        if !ok { self.statusHelp = "Microphone access denied — enable it in System Settings › Privacy" }
                        done(ok)
                    }
                }
            default: self.authorized = false; self.statusHelp = "Microphone access denied — enable it in System Settings › Privacy"; done(false)
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: micStep()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { st in
                Task { @MainActor in
                    if st == .authorized { micStep() }
                    else { self.authorized = false; self.statusHelp = "Speech access denied — enable it in System Settings › Privacy"; done(false) }
                }
            }
        default: self.authorized = false; statusHelp = "Speech access denied — enable it in System Settings › Privacy"; done(false)
        }
    }

    private func begin() {
        teardown()   // clean slate (rolling restart)
        if VoiceModes.parakeetASR { beginLocal() } else { beginSystem() }
    }

    // Parakeet path: continuous raw-PCM capture, silence-segmented, each segment → helper ASR.
    // No live partials and no rolling restart (the local capture has no per-request time cap).
    private func beginLocal() {
        let cap = LocalSpeechCapture(continuous: true)
        cap.onUtterance = { [weak self] text in
            guard let self, self.capturing else { return }
            self.onUtterance?(text)
        }
        cap.onActive = { [weak self] active in Task { @MainActor in self?.listening = active } }
        local = cap
        capturing = true
        partial = ""
        cap.start()
        logLine("wb: mic using Parakeet (local)")
    }

    private func beginSystem() {
        guard recognizer?.isAvailable == true else { statusHelp = "Voice input unavailable"; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        let input = audio.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        audio.prepare()
        do { try audio.start() } catch { statusHelp = "Microphone unavailable"; return }
        capturing = true
        listening = true
        partial = ""
        // Generation guard: stale callbacks from a torn-down task can arrive after the next
        // engine is already running (observed as the same utterance committing twice) — tag
        // each task and ignore callbacks that aren't from the current generation.
        gen += 1
        let myGen = gen
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.gen == myGen, self.audio.isRunning else { return }
                if let text, !text.isEmpty {
                    self.partial = text
                    self.armSilence()
                }
                if isFinal { self.commit() }
                else if failed { self.restart(reason: "recognition error") }
            }
        }
    }

    private var gen = 0

    // Debounce: after each partial, a pause of `silenceInterval` closes the utterance.
    private func armSilence() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.commit() }
        }
    }

    // Close the current utterance and hand it up. Noise filtering now lives downstream in the
    // wake gate, so short phrases (a 2-word wake phrase, a 1-word "yes" in the wake window)
    // must pass through here — we only drop the empty string.
    private func commit() {
        silenceTimer?.invalidate(); silenceTimer = nil
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        if !text.isEmpty { onUtterance?(text) }
        restart(reason: "utterance committed")
    }

    // Rolling restart so the ~60s per-request cap never bites. Error restarts back off:
    // SFSpeech can fail instantly after a rebuild (observed as a ~120ms hot loop flooding
    // the log), so consecutive error restarts wait 1s instead of spinning.
    private var lastErrorRestart: Date = .distantPast
    private func restart(reason: String) {
        teardown()
        if reason == "recognition error" {
            let rapid = Date().timeIntervalSince(lastErrorRestart) < 1.5
            lastErrorRestart = Date()
            if rapid {
                logLine("wb: mic restart — recognition error (backing off 1s)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.reconcile() }
                return
            }
        }
        logLine("wb: mic restart — \(reason)")
        reconcile()   // begins again if still wanted + gate open
    }

    private func teardown() {
        silenceTimer?.invalidate(); silenceTimer = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        local?.stop(); local = nil
        capturing = false
        listening = false
    }
}

// MARK: Frame processor — dewarp + downscaled-pixel differencing + auto-look gating
//
// Runs on its own serial queue (the video-data-output delegate queue). All the pixel
// math is here; it emits status + snapshot decisions up to the engine on the main actor.
// Thresholds are deliberately generous and every gate decision is logged so they can be
// tuned straight from the log.
final class BoardFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "com.abhiram.cleanup.wb.video")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Tunables (0–255 mean-abs-diff on a 64×48 grayscale dewarp).
    private let smallW = 64, smallH = 48
    private let tStable: Double = 2.5      // consecutive-frame MAD below this ⇒ no hand motion
    private let stableHold: TimeInterval = 2.5  // must hold that still this long ⇒ stable
    private let tChange: Double = 6.0      // MAD vs last snapshot above this ⇒ new content
    private let lookInterval: TimeInterval = 20 // min seconds between auto-looks

    // Callbacks (set once before the session starts; invoked on `queue`, they hop to main).
    var onStatus: ((WBStatus) -> Void)?
    var onLook: ((String) -> Void)?
    var onAspect: ((CGFloat) -> Void)?
    var onDewarpedPreview: ((CGImage) -> Void)?   // ~5fps live dewarp for the "board" preview mode

    // State — touched only on `queue`.
    private var corners: [CGPoint] = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                                      CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]
    private var autoLook = true
    private var inFlight = false
    private var latestBoard: CIImage?
    private var currentSmall: [UInt8]?
    private var lastSmall: [UInt8]?
    private var lastSnapshotSmall: [UInt8]?
    private var stableSince: Date?
    private var lastLookAt: Date = .distantPast
    private var lastStatus: WBStatus = .writing
    private var lastMotionMAD: Double = 0
    private var lastProcessed: TimeInterval = 0
    private var lastGateLog: TimeInterval = 0
    private var firstFrameLogged = false
    private var lastAspect: CGFloat = 0
    private var wantDewarpedPreview = false
    private var lastPreviewEmit: TimeInterval = 0
    private var enhanceLogged = false

    // ---- setters (dispatched onto the video queue) ----
    func setCorners(_ c: [CGPoint]) { queue.async { self.corners = c; self.lastSnapshotSmall = nil } } // re-pin ⇒ next stable frame looks
    func setAutoLook(_ v: Bool) { queue.async { self.autoLook = v } }
    func setInFlight(_ v: Bool) { queue.async { self.inFlight = v; if !v { self.lastLookAt = Date() } } }
    func setDewarpedPreview(_ v: Bool) { queue.async { self.wantDewarpedPreview = v; self.lastPreviewEmit = 0 } }
    // Camera switch: forget the differencing history so the new feed doesn't fire a spurious look.
    func resetChangeBaseline() { queue.async { self.lastSnapshotSmall = nil; self.lastSmall = nil; self.stableSince = nil } }
    func forceLook() {
        queue.async {
            guard !self.inFlight, let board = self.latestBoard, let s = self.currentSmall,
                  let path = self.renderPNG(board) else { return }
            self.inFlight = true
            self.lastLookAt = Date()
            self.lastSnapshotSmall = s
            logLine("wb: look now → snapshot")
            self.onLook?(path)
        }
    }

    // Capture a fresh dewarped snapshot immediately (no stability wait) and hand the path
    // back on the main queue. Used to attach a photo to a spoken/typed look request — the
    // user just asked, so we don't wait for the board to settle. Does NOT set inFlight;
    // the engine flips that when it actually sends the turn.
    func snapshotNow(_ done: @escaping (String?) -> Void) {
        queue.async {
            guard let board = self.latestBoard, let s = self.currentSmall,
                  let path = self.renderPNG(board) else {
                logLine("wb: look-on-request → no frame yet")
                DispatchQueue.main.async { done(nil) }
                return
            }
            self.lastLookAt = Date()
            self.lastSnapshotSmall = s
            logLine("wb: look-on-request → snapshot")
            DispatchQueue.main.async { done(path) }
        }
    }

    // ---- capture ----
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !firstFrameLogged {   // proves the delegate wiring is live, before any throttle/gate
            firstFrameLogged = true
            logLine("wb: first frame received (\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)))")
        }
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastProcessed < 0.12 { return }   // throttle to ~8fps
        lastProcessed = now
        let src = CIImage(cvPixelBuffer: pb)
        let a = src.extent.width / max(1, src.extent.height)
        if abs(a - lastAspect) > 0.001 { lastAspect = a; onAspect?(a) }
        guard let board = dewarp(src) else { return }
        latestBoard = board
        // Live "board" preview: hand a fresh dewarped CGImage up at ~5fps (only when the toggle
        // asks for it, so raw mode never pays the render cost).
        if wantDewarpedPreview, now - lastPreviewEmit > 0.2, board.extent.width.isFinite, board.extent.width > 0 {
            lastPreviewEmit = now
            if let cg = ciContext.createCGImage(board, from: board.extent) { onDewarpedPreview?(cg) }
        }
        guard let small = smallGray(board) else { return }
        processDiff(small)
    }

    private func processDiff(_ small: [UInt8]) {
        var stable = false
        if let last = lastSmall {
            let m = mad(small, last)
            lastMotionMAD = m
            if m >= tStable { stableSince = nil }
            else {
                if stableSince == nil { stableSince = Date() }
                if Date().timeIntervalSince(stableSince!) >= stableHold { stable = true }
            }
        } else { stableSince = nil }
        lastSmall = small
        currentSmall = small

        let desired: WBStatus = inFlight ? .looking : (stable ? .watching : .writing)
        if desired != lastStatus { lastStatus = desired; onStatus?(desired) }

        let changeMAD = lastSnapshotSmall == nil ? 999 : mad(small, lastSnapshotSmall!)
        let t = Date().timeIntervalSinceReferenceDate
        // Heartbeat: prove frames are flowing even while writing / in-flight (fires
        // regardless of stability, capped to ~2s so it can't flood the log).
        if t - lastGateLog > 2.0 {
            lastGateLog = t
            logLine(String(format: "wb: gate motionMAD=%.2f stable=%d changeMAD=%.1f status=%@",
                           lastMotionMAD, stable ? 1 : 0, changeMAD, "\(desired)"))
        }

        guard !inFlight, stable, autoLook else { return }
        let changed = lastSnapshotSmall == nil || changeMAD > tChange
        let intervalOK = Date().timeIntervalSince(lastLookAt) >= lookInterval
        guard changed, intervalOK else { return }
        logLine(String(format: "wb: motionMAD=%.2f stable=1 changeMAD=%.1f changed=%d interval=%d → look",
                       lastMotionMAD, changeMAD, changed ? 1 : 0, intervalOK ? 1 : 0))
        if let board = latestBoard, let path = renderPNG(board) {
            inFlight = true
            lastLookAt = Date()
            lastSnapshotSmall = small
            onLook?(path)
        }
    }

    // ---- image ops ----
    private func dewarp(_ src: CIImage) -> CIImage? {
        let W = src.extent.width, H = src.extent.height
        guard W > 0, H > 0, corners.count == 4, let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        func vec(_ n: CGPoint) -> CIVector { CIVector(x: n.x * W, y: (1 - n.y) * H) } // top-left norm → CI (bottom-left) px
        f.setValue(src, forKey: kCIInputImageKey)
        f.setValue(vec(corners[0]), forKey: "inputTopLeft")
        f.setValue(vec(corners[1]), forKey: "inputTopRight")
        f.setValue(vec(corners[2]), forKey: "inputBottomRight")
        f.setValue(vec(corners[3]), forKey: "inputBottomLeft")
        return f.outputImage
    }

    private func smallGray(_ img: CIImage) -> [UInt8]? {
        let ext = img.extent
        guard ext.width > 0, ext.height > 0, ext.width.isFinite, ext.height.isFinite else { return nil }
        let sx = CGFloat(smallW) / ext.width, sy = CGFloat(smallH) / ext.height
        let scaled = img
            .transformed(by: CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let count = smallW * smallH
        var rgba = [UInt8](repeating: 0, count: count * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { raw in
            ciContext.render(scaled, toBitmap: raw.baseAddress!, rowBytes: smallW * 4,
                             bounds: CGRect(x: 0, y: 0, width: smallW, height: smallH),
                             format: .RGBA8, colorSpace: cs)
        }
        var gray = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let r = Int(rgba[i*4]), g = Int(rgba[i*4+1]), b = Int(rgba[i*4+2])
            gray[i] = UInt8((r*299 + g*587 + b*114) / 1000)
        }
        return gray
    }

    private func mad(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 999 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    // Whiteboard-tuned legibility pass applied ONLY to the PNG that gets sent (never to the 64×48
    // gating stream — those thresholds were tuned on the raw dewarp). Conservative by design:
    // a touch more contrast/saturation, lifted shadows, tamed highlights (glare). Any filter
    // failure returns the original so a good frame is never made worse.
    private func enhance(_ img: CIImage) -> CIImage {
        var out = img
        if let cc = CIFilter(name: "CIColorControls") {
            cc.setValue(out, forKey: kCIInputImageKey)
            cc.setValue(1.15, forKey: kCIInputContrastKey)
            cc.setValue(1.1, forKey: kCIInputSaturationKey)
            if let r = cc.outputImage { out = r }
        }
        if let hs = CIFilter(name: "CIHighlightShadowAdjust") {
            hs.setValue(out, forKey: kCIInputImageKey)
            hs.setValue(0.3, forKey: "inputShadowAmount")     // lift shadows
            hs.setValue(0.7, forKey: "inputHighlightAmount")  // tame highlights / glare
            if let r = hs.outputImage { out = r }
        }
        if !enhanceLogged { enhanceLogged = true; logLine("wb: snapshot enhanced") }
        return out
    }

    private func renderPNG(_ raw: CIImage) -> String? {
        let img = enhance(raw)
        guard img.extent.width > 0, img.extent.height > 0, img.extent.width.isFinite,
              let cg = ciContext.createCGImage(img, from: img.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let path = (dir as NSString).appendingPathComponent("board-\(fmt.string(from: Date())).png")
        guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return nil }
        return path
    }
}

// MARK: - Phone remote (LAN web server for whiteboard mode)
//
// SECURITY POSTURE — read before touching this:
//  • Practical exposure is the local Wi-Fi/LAN only. We bind 0.0.0.0 (any interface)
//    so a phone on the same network can reach it, but there is no port-forwarding and
//    the port is OS-assigned/random.
//  • Every route (including GET /) requires a per-session random 16-char alphanumeric
//    token, passed as ?t=… or an X-Token header. Wrong/missing → 403. The token is
//    generated fresh for each whiteboard session and is never persisted.
//  • HTTPS uses a per-LAN-address self-signed certificate so iPhone Safari exposes
//    getUserMedia. The user accepts its warning on first visit; the route token still gates access.
//  • Server lifetime == whiteboard window lifetime: started on open, and on close the
//    listener + every connection is torn down, so the link genuinely dies with the window.
//  All connection I/O runs on a private serial queue (off-main). Session reads are
//  marshalled to the MainActor by the engine, which pushes value-typed snapshots here.

// One transcript line the phone renders. Value type (Sendable) so it can cross to the net queue.
struct WireMsg {
    let id: String
    let role: String      // user | assistant | tool | error | note
    let text: String
    let image: Int?       // index into the look-PNG list, or nil
}

// getifaddrs → first non-loopback IPv4, preferring en0 (Wi-Fi/Ethernet on a Mac).
func lanIPv4() -> String? {
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
    defer { freeifaddrs(ifaddrPtr) }
    var en0: String?
    var other: String?
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
        guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host)
        if ip.hasPrefix("169.254") || ip == "0.0.0.0" { continue }   // skip link-local
        let name = String(cString: ptr.pointee.ifa_name)
        if name == "en0" { if en0 == nil { en0 = ip } }
        else if other == nil { other = ip }
    }
    return en0 ?? other
}

// Crisp mono QR for a URL — black modules, scaled up with nearest-neighbour so edges stay sharp.
func makeRemoteQR(_ string: String) -> NSImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = filter.outputImage else { return nil }
    let scaled = out.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let rep = NSCIImageRep(ciImage: scaled)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

final class BoardRemote {
    let token: String
    private let queue = DispatchQueue(label: "com.abhiram.cleanup.boardremote")
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var usingTLS = false            // true once served over https (getUserMedia needs it)

    // MainActor-hopping action hooks, wired by the engine.
    var onSay: ((String) -> Void)?
    var onLook: (() -> Void)?
    var onMute: ((Bool) -> Void)?
    var onVoiceText: ((String) -> Void)?   // final transcription of a phone-recorded clip → same path as /say
    var onPhoto: ((String) -> Void)?       // a photo uploaded from the phone → look-style turn (imagePath)

    // Published state — all touched only on `queue`.
    private var wire: [WireMsg] = []
    private var lastText: [String: String] = [:]
    private var imagePaths: [String] = []
    private var lastImgCount = 0
    private var statusLine = ""
    private var running = false
    private var project = ""
    private var muted = false
    private var sounds = true
    private var sse: [ObjectIdentifier: NWConnection] = [:]
    private var heartbeat: DispatchSourceTimer?
    private let headerTerminator = Data("\r\n\r\n".utf8)
    // File-based transcription of phone voice clips (owned here so stop() can cancel any in flight).
    private let voiceRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var voiceTask: SFSpeechRecognitionTask?
    private var voiceTimeout: DispatchWorkItem?
    private let maxBody = 12_000_000        // hard cap on any request body (covers /upload's 10MB)

    init() {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        token = String((0..<16).map { _ in chars.randomElement()! })
    }

    // ---- lifecycle ----
    func start() { queue.async { [weak self] in self?._start() } }

    private func _start() {
        do {
            // TLS makes the phone a secure context so getUserMedia (hold-to-talk mic) works. If the
            // self-signed identity can't be built, fall back to plain http with a logged warning —
            // everything else (token, routes, page) is identical; only mic capture is lost.
            let params: NWParameters
            let ip = lanIPv4()
            if let ip, let identity = RemoteTLS.identity(for: ip) {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
                params = NWParameters(tls: tls)
                usingTLS = true
            } else {
                logLine("wb: remote TLS unavailable — falling back to http (phone mic capture disabled)")
                params = NWParameters.tcp
                usingTLS = false
            }
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)   // OS-assigned free port, all interfaces
            let scheme = usingTLS ? "https" : "http"
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let p = l.port?.rawValue { self.boundPort = p }
                    logLine("wb: remote serving on \(scheme)://\(ip ?? "0.0.0.0"):\(self.boundPort) (token \(self.token))")
                case .failed(let e):
                    logLine("wb: remote listener failed — \(e)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            listener = l
            startHeartbeat()
        } catch {
            logLine("wb: remote listener error — \(error.localizedDescription)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.heartbeat?.cancel(); self.heartbeat = nil
            self.voiceTimeout?.cancel(); self.voiceTimeout = nil
            self.voiceTask?.cancel(); self.voiceTask = nil   // drop any in-flight /voice transcription
            for (_, c) in self.sse { c.cancel() }
            self.sse.removeAll()
            self.listener?.cancel(); self.listener = nil
            self.boundPort = 0
        }
    }

    // Full remote URL for the QR/popover. Called on the main actor; a serial-queue sync read
    // of the (write-once) port avoids a data race without risking deadlock (different queue).
    func remoteURL() -> String? {
        let (port, tls) = queue.sync { (boundPort, usingTLS) }
        guard port != 0, let ip = lanIPv4() else { return nil }
        return "\(tls ? "https" : "http")://\(ip):\(port)/?t=\(token)"
    }

    // ---- state publishing (engine → phones) ----
    // Called on the MainActor with a value-typed snapshot; diffs against last-sent state and
    // pushes only what changed. Streaming text updates arrive as the same id with new text →
    // the phone replaces the bubble in place. Coalescing is inherent (only changed ids emit).
    func publish(project: String, messages: [WireMsg], imagePaths: [String],
                 status: String, running: Bool, muted: Bool, sounds: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.project = project
            self.imagePaths = imagePaths
            if muted != self.muted || sounds != self.sounds {
                self.muted = muted
                self.sounds = sounds
                self.broadcast(self.settingsEvent())
            }
            if imagePaths.count != self.lastImgCount { self.lastImgCount = imagePaths.count; self.broadcast(self.imgsEvent(imagePaths.count)) }
            if status != self.statusLine { self.statusLine = status; self.broadcast(self.statusEvent(status)) }
            if running != self.running { self.running = running; self.broadcast(self.runningEvent(running)) }
            for m in messages where self.lastText[m.id] != m.text {
                self.lastText[m.id] = m.text
                self.broadcast(self.msgEvent(m))
            }
            self.wire = messages
        }
    }

    // ---- SSE frame builders ----
    private func jsonData(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
    private func sseFrame(_ json: Data) -> Data {
        var d = Data("data: ".utf8); d.append(json); d.append(Data("\n\n".utf8)); return d
    }
    private func msgEvent(_ m: WireMsg) -> Data {
        var obj: [String: Any] = ["type": "msg", "role": m.role, "text": m.text, "id": m.id]
        obj["image"] = m.image.map { "/img/\($0)?t=\(token)" } ?? NSNull()
        return sseFrame(jsonData(obj))
    }
    private func statusEvent(_ s: String) -> Data { sseFrame(jsonData(["type": "status", "text": s])) }
    private func runningEvent(_ r: Bool) -> Data { sseFrame(jsonData(["type": "running", "value": r])) }
    private func settingsEvent() -> Data {
        sseFrame(jsonData(["type": "settings", "muted": muted, "sounds": sounds]))
    }
    private func speechEvent(_ text: String) -> Data {
        sseFrame(jsonData(["type": "speech", "text": text]))
    }
    // Live thumbnail-strip count. The phone builds /img/<i> tiles for i in 0..<count on receipt.
    private func imgsEvent(_ n: Int) -> Data { sseFrame(jsonData(["type": "imgs", "count": n])) }

    private func broadcast(_ data: Data) {
        for (id, c) in sse {
            c.send(content: data, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.queue.async { self?.sse[id] = nil } }
            })
        }
    }

    // Completed assistant replies are spoken by the phone's native speech synthesizer. Sending a
    // dedicated completion event avoids re-speaking every streaming transcript delta.
    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.muted else { return }
            self.broadcast(self.speechEvent(clean))
        }
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let ping = Data(":\n\n".utf8)   // SSE comment — keeps proxies/phones from timing out
            for (_, c) in self.sse { c.send(content: ping, completion: .contentProcessed { _ in }) }
        }
        t.resume()
        heartbeat = t
    }

    // ---- connection handling (off-main) ----
    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.queue.async { self?.sse[ObjectIdentifier(conn)] = nil }
            default: break
            }
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let hdr = buf.range(of: self.headerTerminator) else {
                if buf.count > 262144 { self.respond(conn, "400 Bad Request", "text/plain", Data("bad request".utf8)); return }
                if isComplete { conn.cancel(); return }
                self.receive(conn, buffer: buf); return
            }
            guard let req = self.parse(buf.subdata(in: buf.startIndex..<hdr.lowerBound)) else {
                self.respond(conn, "400 Bad Request", "text/plain", Data("bad request".utf8)); return
            }
            if req.contentLength > self.maxBody {
                self.respond(conn, "413 Payload Too Large", "text/plain", Data("too large".utf8)); return
            }
            let bodyStart = hdr.upperBound
            let have = buf.count - bodyStart
            if have < req.contentLength {
                if isComplete { conn.cancel(); return }
                self.receive(conn, buffer: buf); return   // wait for the rest of the body
            }
            let body = req.contentLength > 0 ? buf.subdata(in: bodyStart..<(bodyStart + req.contentLength)) : Data()
            self.route(conn, req, body)
        }
    }

    private struct Req { let method: String; let path: String; let query: [String: String]; let headers: [String: String]; let contentLength: Int }

    private func parse(_ data: Data) -> Req? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { headers[k] = v }
        }
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let val = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = val
            }
        }
        return Req(method: method, path: path, query: query, headers: headers,
                   contentLength: Int(headers["content-length"] ?? "") ?? 0)
    }

    // ---- routing (all routes require the session token) ----
    private func route(_ conn: NWConnection, _ req: Req, _ body: Data) {
        let tok = req.query["t"] ?? req.headers["x-token"]
        guard tok == token else {
            logLine("wb: remote client denied")
            respond(conn, "403 Forbidden", "text/plain", Data("forbidden".utf8))
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/"):
            respond(conn, "200 OK", "text/html; charset=utf-8", Data(BoardRemote.page.utf8))
        case ("GET", "/events"):
            startSSE(conn)
        case ("GET", "/state"):
            respond(conn, "200 OK", "application/json",
                    jsonData(["project": project, "status": statusLine, "running": running,
                              "muted": muted, "sounds": sounds, "imgs": imagePaths.count]))
        case ("POST", "/say"):
            let text = extractText(body)
            logLine("wb: remote say len=\(text.count)")
            if !text.isEmpty { onSay?(text) }
            respond(conn, "200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case ("POST", "/look"):
            onLook?()
            respond(conn, "200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case ("POST", "/mute"):
            onMute?(extractBool(body))
            respond(conn, "200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
        case ("POST", "/voice"):
            handleVoice(conn, req, body)   // holds the connection open until transcription resolves
        case ("POST", "/upload"):
            handleUpload(conn, req, body)
        default:
            if req.method == "GET", req.path.hasPrefix("/img/") {
                serveImage(conn, String(req.path.dropFirst(5)))   // "/img/".count == 5
            } else {
                respond(conn, "404 Not Found", "text/plain", Data("not found".utf8))
            }
        }
    }

    private func extractText(_ body: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        return (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func extractBool(_ body: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        if let b = obj["value"] as? Bool { return b }
        if let n = obj["value"] as? NSNumber { return n.boolValue }
        return false
    }

    private func serveImage(_ conn: NWConnection, _ nStr: String) {
        guard let n = Int(nStr), n >= 0, n < imagePaths.count,
              let data = try? Data(contentsOf: URL(fileURLWithPath: imagePaths[n])) else {
            respond(conn, "404 Not Found", "text/plain", Data("no image".utf8)); return
        }
        // Look snapshots are PNG; phone uploads may be JPEG/HEIC/etc — serve the right type so
        // Safari renders the strip thumbnail instead of guessing.
        let ext = (imagePaths[n] as NSString).pathExtension.lowercased()
        let ct: String
        switch ext {
        case "jpg", "jpeg": ct = "image/jpeg"
        case "heic": ct = "image/heic"
        case "heif": ct = "image/heif"
        case "webp": ct = "image/webp"
        case "gif": ct = "image/gif"
        default: ct = "image/png"
        }
        respond(conn, "200 OK", ct, data)
    }

    // ---- phone voice: save the recorded clip → SFSpeech file transcription → engine.remoteSay ----
    // The connection is held open (no immediate respond) until the transcription resolves, times
    // out (15s), or the server is torn down. Exactly one response is sent.
    private func handleVoice(_ conn: NWConnection, _ req: Req, _ body: Data) {
        guard !body.isEmpty else {
            respond(conn, "400 Bad Request", "application/json", Data(#"{"ok":false,"reason":"empty"}"#.utf8)); return
        }
        guard body.count <= 2_200_000 else {          // ~2MB / ~25s cap
            logLine("wb: remote voice rejected — \(body.count) bytes")
            respond(conn, "413 Payload Too Large", "application/json", Data(#"{"ok":false,"reason":"toobig"}"#.utf8)); return
        }
        let ext = Self.audioExt(req.headers["content-type"] ?? "")
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
        do { try body.write(to: URL(fileURLWithPath: path)) }
        catch {
            logLine("wb: remote voice save failed — \(error.localizedDescription)")
            respond(conn, "500 Internal Server Error", "application/json", Data(#"{"ok":false,"reason":"save"}"#.utf8)); return
        }
        transcribeVoice(path: path, conn: conn)
    }

    // Route to Parakeet (afconvert → helper ASR) when selected + installed; else the system path.
    // defaults()/venvPresent are safe to read off-main, so no MainActor hop is needed here.
    private func transcribeVoice(path: String, conn: NWConnection) {
        let wantLocal = (defaults().string(forKey: Keys.voiceASR) ?? "system") == "parakeet" && VoiceEngine.shared.venvPresent
        if wantLocal { transcribeVoiceLocal(path: path, conn: conn) }
        else { transcribeVoiceSystem(path: path, conn: conn) }
    }

    // Parakeet: convert the uploaded m4a/aac/webm → 16 kHz mono WAV via afconvert, then helper ASR.
    // Any failure (afconvert, helper, empty) transparently falls back to the system SFSpeech path.
    private func transcribeVoiceLocal(path: String, conn: NWConnection) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let wavPath = path + ".16k.wav"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, wavPath]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            do { try p.run() } catch {
                logLine("wb: remote voice afconvert spawn failed — fallback to system")
                self.transcribeVoiceSystem(path: path, conn: conn); return
            }
            p.waitUntilExit()
            guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: wavPath) else {
                logLine("wb: remote voice afconvert failed (\(p.terminationStatus)) — fallback to system")
                self.transcribeVoiceSystem(path: path, conn: conn); return
            }
            VoiceEngine.shared.asr(wav: wavPath) { text in
                try? FileManager.default.removeItem(atPath: wavPath)
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.queue.async {
                        try? FileManager.default.removeItem(atPath: path)
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        logLine("wb: remote voice (parakeet) len=\(t.count)")
                        self.onVoiceText?(t)
                        self.respond(conn, "200 OK", "application/json", self.jsonData(["ok": true, "text": t]))
                    }
                } else {
                    logLine("wb: remote voice parakeet empty/failed — fallback to system")
                    self.transcribeVoiceSystem(path: path, conn: conn)
                }
            }
        }
    }

    private func transcribeVoiceSystem(path: String, conn: NWConnection) {
        guard let rec = voiceRecognizer, rec.isAvailable,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            logLine("wb: remote voice — recognizer unavailable")
            try? FileManager.default.removeItem(atPath: path)
            respond(conn, "200 OK", "application/json", Data(#"{"ok":false,"reason":"unavailable"}"#.utf8)); return
        }
        voiceTimeout?.cancel(); voiceTask?.cancel()
        let sreq = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
        sreq.shouldReportPartialResults = false

        var settled = false
        // Single-fire resolver, always run on `queue` so `settled`, voiceTask/voiceTimeout are race-free.
        func finish(ok: Bool, text: String, reason: String) {
            self.queue.async {
                guard !settled else { return }
                settled = true
                self.voiceTimeout?.cancel(); self.voiceTimeout = nil
                self.voiceTask?.cancel(); self.voiceTask = nil
                try? FileManager.default.removeItem(atPath: path)
                if ok {
                    logLine("wb: remote voice len=\(text.count)")
                    self.onVoiceText?(text)
                    self.respond(conn, "200 OK", "application/json", self.jsonData(["ok": true, "text": text]))
                } else {
                    logLine("wb: remote voice failed — \(reason)")
                    self.broadcast(self.statusEvent("couldn't hear that"))   // transient; next publish restores
                    self.respond(conn, "200 OK", "application/json", self.jsonData(["ok": false, "reason": reason]))
                }
            }
        }

        let to = DispatchWorkItem { finish(ok: false, text: "", reason: "timeout") }
        voiceTimeout = to
        queue.asyncAfter(deadline: .now() + 15, execute: to)

        voiceTask = rec.recognitionTask(with: sreq) { result, error in
            if error != nil {
                // webm/opus containers frequently error here — report a distinct "format" reason so
                // the phone can fall back (the big button is labelled iOS-first: iPhone yields m4a/AAC).
                finish(ok: false, text: "", reason: "format"); return
            }
            guard let result = result, result.isFinal else { return }
            let t = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { finish(ok: false, text: "", reason: "empty") } else { finish(ok: true, text: t, reason: "") }
        }
    }

    // ---- phone photo: save the uploaded image → engine.onPhoto → look-style turn ----
    private func handleUpload(_ conn: NWConnection, _ req: Req, _ body: Data) {
        guard !body.isEmpty else {
            respond(conn, "400 Bad Request", "application/json", Data(#"{"ok":false,"reason":"empty"}"#.utf8)); return
        }
        guard body.count <= 10_500_000 else {          // ~10MB cap
            logLine("wb: remote upload rejected — \(body.count) bytes")
            respond(conn, "413 Payload Too Large", "application/json", Data(#"{"ok":false,"reason":"toobig"}"#.utf8)); return
        }
        let ext = Self.imageExt(req.headers["content-type"] ?? "")
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("upload-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
        do { try body.write(to: URL(fileURLWithPath: path)) }
        catch {
            logLine("wb: remote upload save failed — \(error.localizedDescription)")
            respond(conn, "500 Internal Server Error", "application/json", Data(#"{"ok":false,"reason":"save"}"#.utf8)); return
        }
        logLine("wb: remote upload bytes=\(body.count) ext=\(ext)")
        onPhoto?(path)
        respond(conn, "200 OK", "application/json", Data(#"{"ok":true}"#.utf8))
    }

    // Container extension from the phone's Content-Type. iOS Safari → audio/mp4 (AAC) → m4a;
    // Chrome → audio/webm (opus). SFSpeech handles m4a/mp4/wav/caf; webm it usually cannot.
    private static func audioExt(_ ct: String) -> String {
        let c = ct.lowercased()
        if c.contains("webm") { return "webm" }
        if c.contains("ogg") { return "ogg" }
        if c.contains("wav") || c.contains("wave") { return "wav" }
        if c.contains("mpeg") || c.contains("mp3") { return "mp3" }
        if c.contains("caf") { return "caf" }
        return "m4a"   // mp4 / aac / x-m4a / m4a / unknown
    }
    private static func imageExt(_ ct: String) -> String {
        let c = ct.lowercased()
        if c.contains("png") { return "png" }
        if c.contains("heic") { return "heic" }
        if c.contains("heif") { return "heif" }
        if c.contains("webp") { return "webp" }
        if c.contains("gif") { return "gif" }
        return "jpg"   // jpeg / jpg / unknown
    }

    private func startSSE(_ conn: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sse[ObjectIdentifier(conn)] = conn
        logLine("wb: remote client connected")
        // Replay the full transcript + current status/running so a fresh (or reconnecting) phone
        // rebuilds via message ids — reconnection is de-duped by id, not cleared.
        for m in wire { conn.send(content: msgEvent(m), completion: .contentProcessed { _ in }) }
        conn.send(content: statusEvent(statusLine), completion: .contentProcessed { _ in })
        conn.send(content: runningEvent(running), completion: .contentProcessed { _ in })
        conn.send(content: imgsEvent(imagePaths.count), completion: .contentProcessed { _ in })
        conn.send(content: settingsEvent(), completion: .contentProcessed { _ in })
        drainSSE(conn)   // notice client disconnects
    }

    // Keep reading the SSE socket only to detect the client going away (FIN/error).
    private func drainSSE(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.sse[ObjectIdentifier(conn)] = nil
                conn.cancel(); return
            }
            self.drainSSE(conn)
        }
    }

    private func respond(_ conn: NWConnection, _ status: String, _ contentType: String, _ body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var d = Data(head.utf8); d.append(body)
        conn.send(content: d, completion: .contentProcessed { _ in conn.cancel() })
    }

    // ---- the single-file mobile page (no external assets; Mono dark theme) ----
    static let page = ##"""
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, maximum-scale=1">
<meta name="color-scheme" content="dark">
<title>Whiteboard remote</title>
<style>
  :root{--bg:#141414;--surface:#1c1c1c;--surface2:#262626;--surface3:#303030;--text:#f2f2f2;--muted:#9e9e9e;--faint:#6e6e6e;--line:rgba(255,255,255,.10);--lineStrong:rgba(255,255,255,.22);--accent:#f2f2f2;}
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent;}
  html,body{margin:0;height:100%;}
  body{display:flex;flex-direction:column;height:100dvh;background:var(--bg);color:var(--text);
       font-family:-apple-system,system-ui,sans-serif;overflow:hidden;}
  header{padding:calc(env(safe-area-inset-top) + 10px) 14px 10px;border-bottom:1px solid var(--line);background:var(--surface);flex:0 0 auto;}
  .ttl{display:flex;align-items:center;gap:8px;font-weight:600;font-size:15px;}
  #dot{width:9px;height:9px;border-radius:50%;background:var(--faint);flex:0 0 auto;}
  #dot.on{background:var(--accent);animation:pulse 1.2s ease-in-out infinite;}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  #status{font-size:11px;color:var(--muted);font-family:ui-monospace,SFMono-Regular,monospace;margin-top:3px;min-height:14px;}
  #certhint{font-size:10px;color:var(--faint);margin-top:2px;}
  /* 1) TRANSCRIPT — top, takes the free space (~half the screen). */
  #feed{flex:1 1 auto;min-height:0;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px;-webkit-overflow-scrolling:touch;}
  .msg{max-width:82%;font-size:14px;line-height:1.42;}
  .msg.user{align-self:flex-end;background:var(--surface2);border:1px solid var(--line);padding:8px 11px;border-radius:13px 13px 3px 13px;}
  .msg.assistant{align-self:flex-start;background:var(--surface);border:1px solid var(--line);padding:8px 11px;border-radius:13px 13px 13px 3px;}
  .msg.tool,.msg.note{align-self:center;color:var(--faint);font-size:11px;font-family:ui-monospace,SFMono-Regular,monospace;text-align:center;max-width:92%;}
  .msg.error{align-self:center;color:#f97583;font-size:12px;max-width:92%;text-align:center;}
  .msg img{max-width:100%;border-radius:9px;margin-top:6px;display:block;}
  .txt{white-space:pre-wrap;word-break:break-word;}
  /* 2) THUMBNAIL STRIP — every board photo this session, horizontally scrollable. */
  #strip{flex:0 0 auto;display:none;gap:7px;overflow-x:auto;overflow-y:hidden;white-space:nowrap;
         padding:7px 10px;border-top:1px solid var(--line);background:var(--surface);-webkit-overflow-scrolling:touch;}
  #strip::-webkit-scrollbar{height:0;}
  .thumb{flex:0 0 auto;width:52px;height:52px;border:1px solid var(--line);border-radius:8px;overflow:hidden;display:block;background:var(--surface2);}
  .thumb img{width:100%;height:100%;object-fit:cover;display:block;}
  /* Final phone-mic transcription. Kept separate from the feed so it appears immediately when
     Parakeet finishes, even before the agent turn starts streaming. */
  #heard{display:none;flex:0 0 auto;padding:7px 12px;border-top:1px solid var(--line);background:var(--surface2);
         color:var(--muted);font-size:12px;line-height:1.35;white-space:pre-wrap;word-break:break-word;}
  #heard.show{display:block;}
  #heard strong{color:var(--text);font-weight:600;}
  /* 3) TEXT INPUT — slim single row: input + small send arrow. */
  #inputrow{flex:0 0 auto;display:flex;gap:7px;align-items:center;padding:8px 10px;border-top:1px solid var(--line);background:var(--surface);}
  #inp{flex:1;background:var(--surface2);color:var(--text);border:1px solid var(--line);border-radius:11px;
       padding:9px 12px;font-size:16px;font-family:inherit;line-height:1.3;min-width:0;}
  #send{flex:0 0 auto;background:var(--accent);color:#111;border:none;border-radius:11px;font-weight:700;
        font-size:17px;width:40px;height:40px;display:flex;align-items:center;justify-content:center;cursor:pointer;}
  #send:active{opacity:.6;}
  /* 4) HOLD-TO-TALK ZONE — the hero, bottom band. */
  #talk{flex:0 0 auto;display:flex;flex-direction:column;align-items:center;gap:9px;
        padding:14px 10px calc(env(safe-area-inset-bottom) + 14px);border-top:1px solid var(--line);background:var(--surface);}
  #ptt{position:relative;width:min(40vw,190px);aspect-ratio:1/1;border-radius:50%;background:var(--surface2);
       border:2px solid var(--lineStrong);color:var(--text);display:flex;align-items:center;justify-content:center;
       cursor:pointer;user-select:none;-webkit-user-select:none;touch-action:none;transition:background .12s ease,transform .08s ease;}
  #ptt .lbl{font-size:12px;font-weight:700;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);}
  #ptt.rec{background:var(--surface3);border-color:var(--accent);transform:scale(.97);animation:ptt 1.1s ease-in-out infinite;}
  #ptt.rec .lbl{color:var(--text);}
  @keyframes ptt{0%,100%{opacity:1}50%{opacity:.62}}
  /* secondary controls: a "+" that expands a compact row of look / mute / photo. */
  #tools{display:flex;gap:8px;align-items:center;justify-content:center;overflow:hidden;max-width:0;opacity:0;
         transition:max-width .18s ease,opacity .18s ease;}
  #tools.open{max-width:220px;opacity:1;}
  .bar{display:flex;gap:8px;align-items:center;}
  button.ic{background:var(--surface2);color:var(--text);border:1px solid var(--line);border-radius:11px;
            width:42px;height:38px;display:flex;align-items:center;justify-content:center;cursor:pointer;flex:0 0 auto;padding:0;}
  button.ic:active{opacity:.6;}
  button.ic svg{width:20px;height:20px;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;display:block;}
  #mute.on{color:var(--accent);border-color:var(--accent);}
  #plus{font-size:22px;font-weight:400;color:var(--muted);transition:transform .18s ease;}
  #plus.open{transform:rotate(45deg);color:var(--text);}
</style></head>
<body>
  <header>
    <div class="ttl"><span id="dot"></span><span id="project">Whiteboard</span></div>
    <div id="status">connecting…</div>
    <div id="certhint">first visit: accept the certificate warning</div>
  </header>
  <div id="feed"></div>
  <div id="strip"></div>
  <div id="heard" role="status" aria-live="polite"></div>
  <div id="inputrow">
    <input id="inp" type="text" placeholder="type a message…" autocomplete="off" enterkeyhint="send">
    <button id="send" title="Send">↑</button>
  </div>
  <div id="talk">
    <button id="ptt"><span class="lbl">Hold</span></button>
    <div class="bar">
      <button id="plus" class="ic" title="More">+</button>
      <div id="tools">
        <button id="look" class="ic" title="Look at the board"></button>
        <button id="mute" class="ic" title="Mute spoken replies"></button>
        <button id="photo" class="ic" title="Send a photo"></button>
        <input id="file" type="file" accept="image/*" capture="environment" hidden>
      </div>
    </div>
  </div>
<script>
(function(){
  var token = new URLSearchParams(location.search).get('t') || '';
  var q = function(s){ return document.querySelector(s); };
  var feed = q('#feed'), strip = q('#strip'), els = {}, userScrolled = false, muted = false, imgCount = 0;
  var audioUnlocked = false, pendingSpeech = '', speakingText = '';

  // Monochrome stroke icons (currentColor → theme text). No external assets.
  var SVG_EYE = '<svg viewBox="0 0 24 24"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7z"/><circle cx="12" cy="12" r="3"/></svg>';
  var SVG_SOUND = '<svg viewBox="0 0 24 24"><path d="M11 5 6 9H2v6h4l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7"/><path d="M18.5 5.5a9 9 0 0 1 0 13"/></svg>';
  var SVG_MUTE = '<svg viewBox="0 0 24 24"><path d="M11 5 6 9H2v6h4l5 4z"/><line x1="22" y1="9" x2="16" y2="15"/><line x1="16" y1="9" x2="22" y2="15"/></svg>';
  var SVG_CAM = '<svg viewBox="0 0 24 24"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/></svg>';
  q('#look').innerHTML = SVG_EYE;
  q('#photo').innerHTML = SVG_CAM;

  function setStatus(t){ q('#status').textContent = t || ''; }
  var heardTimer = null;
  function showTranscript(text){
    text = (text || '').trim(); if(!text){ return; }
    var h = q('#heard'); h.innerHTML = '';
    var label = document.createElement('strong'); label.textContent = 'Heard: ';
    h.appendChild(label); h.appendChild(document.createTextNode(text)); h.classList.add('show');
    if(heardTimer){ clearTimeout(heardTimer); }
    heardTimer = setTimeout(function(){ h.classList.remove('show'); }, 12000);
  }

  // iOS permits speech only after a user gesture. Any interaction unlocks it; if a reply arrived
  // before that, the newest one is spoken immediately after the first tap/press.
  function unlockAudio(){
    audioUnlocked = true;
    if(window.speechSynthesis){ try { speechSynthesis.resume(); } catch(_){} }
    if(pendingSpeech){ var t = pendingSpeech; pendingSpeech = ''; speakReply(t); }
  }
  function speakReply(text){
    text = (text || '').trim();
    if(!text || muted || text === speakingText){ return; }
    if(!audioUnlocked || !window.speechSynthesis){ pendingSpeech = text; return; }
    try {
      speechSynthesis.cancel();
      var u = new SpeechSynthesisUtterance(text);
      u.rate = 0.96; u.pitch = 1.0;
      u.onstart = function(){ speakingText = text; };
      u.onend = u.onerror = function(){ speakingText = ''; };
      speechSynthesis.speak(u);
    } catch(_){ setStatus('audio output unavailable'); }
  }

  feed.addEventListener('scroll', function(){
    userScrolled = feed.scrollHeight - feed.scrollTop - feed.clientHeight > 60;
  });
  function toBottom(){ if(!userScrolled){ feed.scrollTop = feed.scrollHeight; } }

  function upsert(m){
    var el = els[m.id];
    if(!el){ el = document.createElement('div'); el.className = 'msg ' + (m.role||'note'); els[m.id] = el; feed.appendChild(el); }
    el.innerHTML = '';
    if(m.text){ var t = document.createElement('div'); t.className = 'txt'; t.textContent = m.text; el.appendChild(t); }
    if(m.image){ var a = document.createElement('a'); a.href = m.image; a.target = '_blank'; a.rel = 'noopener';
                 var img = document.createElement('img'); img.src = m.image; img.loading = 'lazy';
                 a.appendChild(img); el.appendChild(a); }
    toBottom();
  }

  // Thumbnail strip: tiles for /img/0 .. /img/(n-1). Only appends the new ones (no flicker); a
  // shrink (transcript rebuilt) resets and repaints. Tap opens full-size in a new tab.
  function setImgs(n){
    n = n|0;
    if(n < imgCount){ imgCount = 0; strip.innerHTML = ''; }
    for(var i = imgCount; i < n; i++){
      var url = '/img/' + i + '?t=' + encodeURIComponent(token);
      var a = document.createElement('a'); a.href = url; a.target = '_blank'; a.rel = 'noopener'; a.className = 'thumb';
      var im = document.createElement('img'); im.src = url; im.loading = 'lazy'; a.appendChild(im); strip.appendChild(a);
    }
    imgCount = n;
    strip.style.display = n > 0 ? 'flex' : 'none';
    strip.scrollLeft = strip.scrollWidth;
  }

  function connect(){
    var es = new EventSource('/events?t=' + encodeURIComponent(token));
    es.onmessage = function(e){
      var d; try { d = JSON.parse(e.data); } catch(_){ return; }
      if(d.type === 'msg'){ upsert(d); }
      else if(d.type === 'status'){ setStatus(d.text); }
      else if(d.type === 'running'){ q('#dot').classList.toggle('on', !!d.value); }
      else if(d.type === 'imgs'){ setImgs(d.count); }
      else if(d.type === 'settings'){
        muted = !!d.muted; updateMute();
        if(muted && window.speechSynthesis){ speechSynthesis.cancel(); pendingSpeech = ''; speakingText = ''; }
      }
      else if(d.type === 'speech'){ speakReply(d.text); }
    };
    es.onerror = function(){ /* EventSource auto-reconnects; replay repopulates via ids */ };
  }

  function post(path, obj){
    return fetch(path + '?t=' + encodeURIComponent(token), {
      method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(obj||{})
    }).catch(function(){});
  }
  function send(){
    var inp = q('#inp'), v = inp.value.trim(); if(!v){ return; }
    inp.value = ''; post('/say', {text: v});
  }
  function updateMute(){ q('#mute').innerHTML = muted ? SVG_MUTE : SVG_SOUND; q('#mute').classList.toggle('on', muted); }

  q('#send').onclick = function(){ unlockAudio(); send(); };
  q('#look').onclick = function(){ unlockAudio(); post('/look', {}); };
  q('#mute').onclick = function(){
    unlockAudio(); muted = !muted; updateMute();
    if(muted && window.speechSynthesis){ speechSynthesis.cancel(); pendingSpeech = ''; speakingText = ''; }
    post('/mute', {value: muted});
  };
  q('#inp').addEventListener('keydown', function(e){ if(e.key === 'Enter' && !e.shiftKey){ e.preventDefault(); send(); } });

  // "+" expands the secondary controls row.
  q('#plus').onclick = function(){ q('#tools').classList.toggle('open'); q('#plus').classList.toggle('open'); };

  // ---- photo → board eyes ----
  q('#photo').onclick = function(){ q('#file').click(); };
  q('#file').addEventListener('change', function(){
    var f = this.files && this.files[0]; this.value = '';
    if(!f){ return; }
    if(f.size > 10*1024*1024){ setStatus('photo too big (10MB max)'); return; }
    setStatus('sending photo…');
    fetch('/upload?t=' + encodeURIComponent(token), {
      method:'POST', headers:{'Content-Type': f.type || 'image/jpeg'}, body: f
    }).then(function(r){ return r.json(); }).then(function(d){
      if(!d || d.ok === false){ setStatus('photo failed'); }   // success shows up via the transcript
    }).catch(function(){ setStatus('photo failed'); });
  });

  // ---- HOLD-TO-TALK: MediaRecorder over getUserMedia; POST the blob to /voice on release ----
  // iOS Safari yields audio/mp4 (AAC); Chrome yields audio/webm (opus). We send whatever container
  // MediaRecorder produced with its own mimeType so the server picks the right file extension.
  var mediaStream = null, rec = null, chunks = [], recording = false, holding = false, wantSend = false, holdStart = 0, capTimer = null;
  var ptt = q('#ptt'), lbl = ptt.querySelector('.lbl');

  function ensureStream(){
    if(mediaStream){ return Promise.resolve(mediaStream); }
    if(!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia){ return Promise.reject(new Error('insecure')); }
    return navigator.mediaDevices.getUserMedia({audio:true}).then(function(s){ mediaStream = s; return s; });
  }
  function pickMime(){
    var cands = ['audio/mp4','audio/aac','audio/webm;codecs=opus','audio/webm','audio/ogg;codecs=opus'];
    if(window.MediaRecorder && MediaRecorder.isTypeSupported){
      for(var i=0;i<cands.length;i++){ if(MediaRecorder.isTypeSupported(cands[i])){ return cands[i]; } }
    }
    return '';
  }
  function startRec(){
    ensureStream().then(function(s){
      var mime = pickMime(), r;
      try { r = mime ? new MediaRecorder(s, {mimeType:mime}) : new MediaRecorder(s); }
      catch(e){ try { r = new MediaRecorder(s); } catch(e2){ setStatus('recording not supported'); return; } }
      rec = r; chunks = [];
      r.ondataavailable = function(e){ if(e.data && e.data.size){ chunks.push(e.data); } };
      r.onstop = function(){ recording = false; finishRec(); };
      r.start(); recording = true;
      capTimer = setTimeout(function(){ if(holding){ wantSend = true; releaseUI(); stopRec(); } }, 25000); // ~25s cap
      if(!holding){ stopRec(); }   // released before the stream came up
    }).catch(function(e){
      setStatus(e && e.message === 'insecure' ? 'voice needs a secure (https) link' : 'mic blocked — allow it in Settings');
    });
  }
  function stopRec(){ if(recording && rec){ try { rec.stop(); } catch(_){} } }
  function finishRec(){
    if(capTimer){ clearTimeout(capTimer); capTimer = null; }
    var blob = new Blob(chunks, {type: (rec && rec.mimeType) || 'audio/mp4'}); chunks = [];
    if(!wantSend){ return; }
    if(!blob.size){ setStatus('nothing recorded'); return; }
    setStatus('sending…');
    fetch('/voice?t=' + encodeURIComponent(token), {
      method:'POST', headers:{'Content-Type': blob.type}, body: blob
    }).then(function(r){ return r.json(); }).then(function(d){
      // The recognition result is returned only after Parakeet/system ASR finishes. Show it now;
      // the same text also lands in the conversation via the server's onVoiceText path.
      if(d && d.ok === true && d.text){ showTranscript(d.text); setStatus('sent'); }
      else if(d && d.ok === false && d.reason === 'format'){ setStatus('voice format unsupported — try iPhone Safari'); }
      else if(d && d.ok === false && d.reason === 'unavailable'){ setStatus('speech recognition unavailable'); }
    }).catch(function(){ setStatus('send failed'); });
  }
  function pressUI(){ ptt.classList.add('rec'); lbl.textContent = 'Release'; }
  function releaseUI(){ ptt.classList.remove('rec'); lbl.textContent = 'Hold'; }

  ptt.addEventListener('pointerdown', function(e){
    e.preventDefault();
    if(holding){ return; }
    unlockAudio();
    try { ptt.setPointerCapture(e.pointerId); } catch(_){}
    holding = true; wantSend = false; holdStart = Date.now();
    pressUI(); startRec();
  });
  function onUp(e){
    if(!holding){ return; }
    e.preventDefault();
    holding = false; releaseUI();
    if(Date.now() - holdStart < 300){ wantSend = false; stopRec(); setStatus('hold to talk'); return; }  // tap → ignore
    wantSend = true; stopRec();
  }
  function onCancel(){ if(!holding){ return; } holding = false; wantSend = false; releaseUI(); stopRec(); }
  ptt.addEventListener('pointerup', onUp);
  ptt.addEventListener('pointercancel', onCancel);
  // Pointer capture keeps a slightly drifting finger attached to the button; pointerleave used
  // to cancel otherwise-valid iPhone recordings before pointerup arrived.

  fetch('/state?t=' + encodeURIComponent(token)).then(function(r){ return r.json(); }).then(function(s){
    q('#project').textContent = s.project || 'Whiteboard';
    setStatus(s.status);
    q('#dot').classList.toggle('on', !!s.running);
    muted = !!s.muted; updateMute();
    if(typeof s.imgs === 'number'){ setImgs(s.imgs); }
  }).catch(function(){ updateMute(); });
  connect();
})();
</script>
</body></html>
"""##
}

// MARK: Whiteboard engine — wires camera + processor + session + voice together

@MainActor
final class WhiteboardEngine: NSObject, ObservableObject {
    @Published var statusText = "starting camera…"
    @Published var camera: WBCamera = .starting
    @Published var autoLook: Bool
    @Published var muted: Bool
    @Published var micEnabled: Bool
    @Published var wakePhrase: String
    @Published var wakeActive = false          // in the post-wake "listening…" window
    @Published var lookInFlight = false
    @Published var frameAspect: CGFloat = 4.0 / 3.0
    @Published var corners: [CGPoint]
    @Published var previewMode: String            // "raw" | "board"
    @Published var dewarpedPreview: NSImage?       // live dewarp for the "board" preview
    @Published var selectedCameraID = ""           // uniqueID of the running camera
    @Published var sounds: Bool
    @Published var lookFlash = false               // brief accent flash on the preview when a look fires

    let captureSession = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    let session: WhiteboardSession
    let listener = BoardListener()
    let remote = BoardRemote()          // LAN phone remote (started on open, stopped on close)

    private let speaker = BoardSpeaker()
    private let barge = BargeListener()
    private let processor = BoardFrameProcessor()
    private let output = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var speaking = false
    private var prevRunning = false
    private var exported = false
    private var boardStatus: WBStatus = .watching   // latest board-motion status (for the status line)
    private var wakeTask: Task<Void, Never>?         // ~10s post-wake listening window
    private let wakeWindow: TimeInterval = 10
    private var queuedTurn: (text: String, imagePath: String?)?  // single-slot: turn waiting on an in-flight run
    private var bag = Set<AnyCancellable>()

    override init() {
        self.autoLook = defaults().bool(forKey: Keys.whiteboardAutoLook)
        self.muted = defaults().bool(forKey: Keys.whiteboardMuted)
        self.micEnabled = defaults().bool(forKey: Keys.whiteboardMic)
        self.wakePhrase = (defaults().string(forKey: Keys.whiteboardWakePhrase) ?? "hey board")
        self.corners = WhiteboardEngine.loadCorners()
        self.sounds = defaults().bool(forKey: Keys.whiteboardSounds)
        // Preview default: raw, unless corners have been pinned once and the user hasn't picked a
        // mode themselves — then default to the dewarped board (they've done the pinning work).
        let savedMode = defaults().string(forKey: Keys.whiteboardPreviewMode) ?? "raw"
        if defaults().bool(forKey: Keys.whiteboardPreviewUserSet) {
            self.previewMode = savedMode
        } else {
            self.previewMode = defaults().bool(forKey: Keys.whiteboardPinnedOnce) ? "board" : "raw"
        }
        // Use the exact provider/model selected for regular Agent mode (Codex defaults to gpt-5.5).
        self.session = WhiteboardSession(engine: AgentCLI.engine, model: AgentCLI.model,
                                         permission: AgentCLI.permission, project: ProjectStore.current())
        super.init()

        previewLayer.session = captureSession
        // aspect-FIT: the whole camera frame must be visible (letterboxed) — with
        // fill, any box shape that isn't exactly 16:9 crops the frame and the user
        // can't see or pin the board edges ("preview doesn't fit in the box").
        previewLayer.videoGravity = .resizeAspect

        session.onAssistantComplete = { [weak self] text in
            guard let self, !self.muted else { return }
            self.remote.speak(text)
            self.speaker.speak(text)
        }
        // While the agent speaks, the full mic tears down (echo guard) and the barge listener takes
        // its place so the wake phrase can still cut in.
        speaker.onStart = { [weak self] in
            guard let self else { return }
            self.speaking = true
            self.updateMicGate()          // tears the main mic down first
            self.startBargeIfWanted()     // …then the wake-only listener runs in its place
            self.recomputeStatus()
        }
        speaker.onDone = { [weak self] in
            guard let self else { return }
            self.speaking = false
            self.barge.stop()
            self.recomputeStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.updateMicGate() }  // ~300ms mic-reopen tail
        }
        // Wake phrase heard mid-speech → cut the TTS, cue, open the listening window.
        barge.onBarge = { [weak self] in
            guard let self else { return }
            self.speaker.stop()   // → onDone reopens the main mic after the tail
            self.playCue("Tink")
            self.beginWakeWindow()
        }
        listener.onUtterance = { [weak self] text in self?.handleUtterance(text) }

        processor.onStatus = { [weak self] s in Task { @MainActor in self?.applyStatus(s) } }
        processor.onLook = { [weak self] path in Task { @MainActor in self?.handleLook(path) } }
        processor.onAspect = { [weak self] a in Task { @MainActor in self?.frameAspect = a } }
        processor.onDewarpedPreview = { [weak self] cg in
            Task { @MainActor in self?.dewarpedPreview = NSImage(cgImage: cg, size: .zero) }
        }

        // A run finishing ⇒ clear the in-flight flag, drain any queued turn, refresh the mic gate
        // (which now tracks only TTS playback, not run state) and the status line.
        session.$running.receive(on: RunLoop.main).sink { [weak self] running in
            guard let self else { return }
            self.lookInFlight = running
            if self.prevRunning && !running { self.playCue("Pop") }   // response complete
            self.prevRunning = running
            if !running { self.processor.setInFlight(false); self.drainQueue() }
            self.updateMicGate()
            self.recomputeStatus()
            self.publishRemote()
        }.store(in: &bag)

        // Phone remote: forward its actions onto the same paths as local input, and mirror all
        // transcript/status/state changes out to connected phones (diffed by BoardRemote).
        remote.onSay = { [weak self] t in Task { @MainActor in self?.remoteSay(t) } }
        remote.onLook = { [weak self] in Task { @MainActor in self?.lookNow() } }
        remote.onMute = { [weak self] v in Task { @MainActor in self?.setMuted(v) } }
        remote.onVoiceText = { [weak self] t in Task { @MainActor in self?.remoteSay(t) } }   // transcribed clip → same path as /say
        remote.onPhoto = { [weak self] p in Task { @MainActor in self?.remotePhoto(p) } }
        session.$messages.receive(on: RunLoop.main).sink { [weak self] _ in self?.publishRemote() }.store(in: &bag)
        $statusText.receive(on: RunLoop.main).sink { [weak self] _ in self?.publishRemote() }.store(in: &bag)
        $muted.receive(on: RunLoop.main).sink { [weak self] _ in self?.publishRemote() }.store(in: &bag)
        $sounds.receive(on: RunLoop.main).sink { [weak self] _ in self?.publishRemote() }.store(in: &bag)

        // Two-verb explainer seed: how to talk, how to ask for eyes on the board.
        let phrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let talkVerb = phrase.isEmpty ? "Just talk" : "Say '\(phrase)'"
        session.setReadyNote("\(talkVerb) to talk to me. Ask me to 'look at the board' whenever you want my eyes on it. Pin the board with the four corners first.")
    }

    // ---- lifecycle ----
    func start() {
        listener.setEnabled(micEnabled)
        updateMicGate()
        remote.start()          // LAN web server — dies with the window (stop())
        publishRemote()         // seed the initial transcript/state for any early phone
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in ok ? self.configureCamera() : self.denyCamera() }
            }
        default: denyCamera()
        }
    }

    func stop() {
        remote.stop()           // close the listener + every phone connection
        speaker.stop()
        barge.stop()
        listener.setEnabled(false)
        session.stop()
        if captureSession.isRunning {
            let s = captureSession
            DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        }
    }

    private func denyCamera() { camera = .denied; statusText = "camera access denied" }

    // Discover every camera we support choosing, incl. iPhone Continuity Camera (far more legible
    // for a whiteboard than most built-in webcams).
    private func discoverCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    // Resolve the saved uniqueID → device, falling back to the system default (then any) if it's gone.
    private func resolveCamera() -> AVCaptureDevice? {
        let saved = defaults().string(forKey: Keys.whiteboardCamera) ?? ""
        let devs = discoverCameras()
        if !saved.isEmpty, let d = devs.first(where: { $0.uniqueID == saved }) { return d }
        return AVCaptureDevice.default(for: .video) ?? devs.first
    }

    private func applyMirroringOff() {
        for conn in [output.connection(with: .video), previewLayer.connection] {
            if let conn, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
        }
    }

    private func configureCamera() {
        guard let device = resolveCamera() else {
            camera = .unavailable; statusText = "no camera found"; return
        }
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) { captureSession.addInput(input); videoInput = input }
        } catch {
            captureSession.commitConfiguration()
            camera = .unavailable; statusText = "couldn't open camera"; return
        }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: processor.queue)
        if captureSession.canAddOutput(output) { captureSession.addOutput(output) }
        applyMirroringOff()   // preview matches the buffer we dewarp from
        captureSession.commitConfiguration()
        selectedCameraID = device.uniqueID
        camera = .running
        recomputeStatus()
        processor.setCorners(corners)
        processor.setAutoLook(autoLook)
        processor.setDewarpedPreview(previewMode == "board")
        let s = captureSession
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
        logLine("wb: camera started device=\(device.localizedName) id=\(device.uniqueID)")
        logLine("wb: cameras available → " + discoverCameras().map { $0.localizedName }.joined(separator: ", "))
    }

    // ---- camera picker ----
    struct CameraOption: Identifiable { let id: String; let name: String }
    func availableCameras() -> [CameraOption] { discoverCameras().map { CameraOption(id: $0.uniqueID, name: $0.localizedName) } }
    var selectedCameraName: String {
        discoverCameras().first(where: { $0.uniqueID == selectedCameraID })?.localizedName ?? "camera"
    }

    // Switch cameras live: swap the input on the running session and forget the change baseline so
    // the new feed doesn't fire a spurious first look.
    func selectCamera(_ id: String) {
        guard id != selectedCameraID else { return }
        defaults().set(id, forKey: Keys.whiteboardCamera)
        guard let device = resolveCamera() else { return }
        let s = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            let wasRunning = s.isRunning
            if wasRunning { s.stopRunning() }
            s.beginConfiguration()
            for inp in s.inputs { s.removeInput(inp) }
            if let input = try? AVCaptureDeviceInput(device: device), s.canAddInput(input) {
                s.addInput(input)
                Task { @MainActor in self.videoInput = input }
            }
            s.commitConfiguration()
            Task { @MainActor in self.applyMirroringOff() }
            if wasRunning { s.startRunning() }
        }
        processor.resetChangeBaseline()
        selectedCameraID = device.uniqueID
        logLine("wb: camera switched device=\(device.localizedName) id=\(device.uniqueID)")
    }

    // ---- UI actions ----
    func updateCorners(_ c: [CGPoint]) {
        corners = c
        defaults().set([c[0].x, c[0].y, c[1].x, c[1].y, c[2].x, c[2].y, c[3].x, c[3].y].map { Double($0) },
                       forKey: Keys.whiteboardCorners)
        processor.setCorners(c)
        // Remember the board has been pinned so future opens can default to the dewarped view.
        if !defaults().bool(forKey: Keys.whiteboardPinnedOnce) { defaults().set(true, forKey: Keys.whiteboardPinnedOnce) }
    }
    // Preview toggle. userInitiated marks the choice sticky so the pin auto-suggest won't override it.
    func setPreviewMode(_ m: String, userInitiated: Bool = true) {
        previewMode = m
        defaults().set(m, forKey: Keys.whiteboardPreviewMode)
        if userInitiated { defaults().set(true, forKey: Keys.whiteboardPreviewUserSet) }
        processor.setDewarpedPreview(m == "board")
        if m != "board" { dewarpedPreview = nil }
        logLine("wb: preview mode=\(m)")
    }
    func setSounds(_ v: Bool) { sounds = v; defaults().set(v, forKey: Keys.whiteboardSounds) }
    // Subtle across-the-room cue via a system sound; respects the toggle. Engine only exists while
    // the window is open, so cues are inherently window-scoped.
    private func playCue(_ name: String) {
        guard sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
    // Visible cause→effect when a snapshot is taken: flash the preview border + a camera-ish cue.
    private func didFireLook() {
        playCue("Purr")
        lookFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.3)) { self.lookFlash = false }
        }
    }
    private func startBargeIfWanted() {
        guard micEnabled, !listener.disabled else { return }
        let phrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }   // no phrase ⇒ nothing to match against TTS
        barge.start(phrase: phrase)
    }
    // End-of-session summary → project memory. Idempotent (once per engine), only for real sessions.
    func exportSession() {
        guard !exported, session.userTurnCount >= 2, !session.cliMissing else { return }
        exported = true
        session.messages.append(AgentMsg(role: .note, text: "wrapping up — saving a summary to this project's memory"))
        WhiteboardExport.run(project: session.project, engine: session.engine, model: session.model)
        logLine("wb: session export started project=\(session.project.slug)")
    }
    func endSession() { exportSession(); AppDelegate.shared.closeWhiteboard() }
    func setAutoLook(_ v: Bool) { autoLook = v; defaults().set(v, forKey: Keys.whiteboardAutoLook); processor.setAutoLook(v) }
    func setMuted(_ v: Bool) { muted = v; defaults().set(v, forKey: Keys.whiteboardMuted); if v { speaker.stop() } }
    func setMic(_ v: Bool) { micEnabled = v; defaults().set(v, forKey: Keys.whiteboardMic); listener.setEnabled(v); updateMicGate(); recomputeStatus() }
    func setWakePhrase(_ v: String) {
        wakePhrase = v
        defaults().set(v, forKey: Keys.whiteboardWakePhrase)
        recomputeStatus()
    }
    func lookNow() { processor.forceLook() }

    // ---- phone remote glue ----
    // Snapshot the transcript + live state into value types and hand it to the server (off-main).
    // Look PNGs are collected in transcript order so /img/<n> lines up with each message's image.
    private func publishRemote() {
        var paths: [String] = []
        var wire: [WireMsg] = []
        for m in session.messages {
            var idx: Int? = nil
            if let p = m.attachmentPaths.first(where: { AgentAttachment.isImagePath($0) }) {
                idx = paths.count; paths.append(p)
            }
            wire.append(WireMsg(id: m.id.uuidString, role: roleWire(m.role), text: m.text, image: idx))
        }
        remote.publish(project: session.project.name, messages: wire, imagePaths: paths,
                       status: statusText, running: session.running, muted: muted, sounds: sounds)
    }
    private func roleWire(_ r: AgentRole) -> String {
        switch r {
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        case .error: return "error"
        case .note, .context: return "note"
        }
    }
    // A phone /say lands on the exact same path as typed/spoken input (look-on-request + queue),
    // and plays the wake-caught cue so the room hears the turn landed (respects the sounds toggle).
    private func remoteSay(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        playCue("Tink")
        dispatchTurn(t)
    }

    // A photo snapped on the phone → a look-style turn that carries the image straight into the
    // transcript (thumbnail + strip) and hands it to the agent to read. It bypasses dispatchTurn's
    // keyword sniff (which wouldn't attach the image for "(photo from phone)") and rides the exact
    // same imagePath path as a board look — the temp Cleanup dir is already inside --add-dir.
    private func remotePhoto(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        playCue("Tink")
        sendOrQueue(text: "(photo from phone)", imagePath: path)
    }

    // Typed input is NEVER wake-gated — typing IS intent. It still gets look-on-request
    // (a look/board phrase attaches a fresh snapshot) and honours the in-flight queue.
    func submitTyped() {
        let t = session.input
        session.input = ""
        let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dispatchTurn(text)
    }

    func openSystemCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // ---- voice-in interaction model ----
    //
    // The mic is always listening, but a committed utterance is only *sent* when it clears
    // the wake gate. Three outcomes:
    //   • wake-window active  → this utterance goes verbatim (no phrase needed).
    //   • wake phrase matched → strip it and send the remainder; bare phrase → open a window.
    //   • no wake phrase      → discard with a compact log (never sent).
    private func handleUtterance(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        // In the post-wake window: the next utterance is sent verbatim, no phrase required.
        if wakeActive {
            endWakeWindow()
            logLine("wb: mic heard (wake window): \(String(t.prefix(40)))")
            dispatchTurn(t)
            return
        }

        switch stripWake(t) {
        case .pass(let msg):
            logLine("wb: mic heard (wake ok): \(String(msg.prefix(40)))")
            playCue("Tink")
            dispatchTurn(msg)
        case .wakeOnly:
            logLine("wb: mic heard (wake only) → listening window")
            playCue("Tink")
            beginWakeWindow()
        case .noWake:
            logLine("wb: mic heard (no wake): \(String(t.prefix(40)))")
        }
    }

    // Where wake-cleared turns (voice) and all typed turns land: attach a snapshot if it's a
    // look request, then send-or-queue.
    private func dispatchTurn(_ text: String) {
        if looksLikeLookRequest(text) {
            processor.snapshotNow { [weak self] path in self?.sendOrQueue(text: text, imagePath: path) }
        } else {
            sendOrQueue(text: text, imagePath: nil)
        }
    }

    // Single-slot queue: if a run is in flight, hold the newest turn and send it when the run
    // completes; a newer arrival replaces the queued one (logged).
    private func sendOrQueue(text: String, imagePath: String?) {
        guard !session.cliMissing else { return }
        if imagePath != nil { didFireLook() }   // a fresh snapshot was just captured for this turn
        if session.running {
            if queuedTurn != nil { logLine("wb: queue replaced (newer utterance): \(String(text.prefix(40)))") }
            else { logLine("wb: queued turn (run in flight): \(String(text.prefix(40)))") }
            queuedTurn = (text, imagePath)
            return
        }
        processor.setInFlight(true)
        session.sendTyped(text, imagePath: imagePath)
    }

    private func drainQueue() {
        guard let q = queuedTurn else { return }
        queuedTurn = nil
        logLine("wb: sending queued turn: \(String(q.text.prefix(40)))")
        processor.setInFlight(true)
        session.sendTyped(q.text, imagePath: q.imagePath)
    }

    // Generous, simple intent match: any "look" / "board", or "see this/the".
    private func looksLikeLookRequest(_ text: String) -> Bool {
        text.range(of: "look|board|see (this|the)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // ---- wake-phrase matching ----
    private enum WakeResult { case pass(String), wakeOnly, noWake }

    private func normToken(_ s: Substring) -> String {
        String(String(s).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // Match the wake phrase within the first ~4 words (punctuation/case-insensitive) and strip
    // it. Empty phrase ⇒ everything passes (old behavior).
    private func stripWake(_ utterance: String) -> WakeResult {
        let phrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if phrase.isEmpty { return .pass(utterance) }
        let pw = phrase.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(normToken).filter { !$0.isEmpty }
        if pw.isEmpty { return .pass(utterance) }
        let tokens = utterance.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        let norm = tokens.map(normToken)
        let maxStart = min(3, norm.count - pw.count)
        if maxStart < 0 { return .noWake }
        for start in 0...maxStart {
            var ok = true
            for k in 0..<pw.count where norm[start + k] != pw[k] { ok = false; break }
            if ok {
                let rest = tokens[(start + pw.count)...].joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return rest.isEmpty ? .wakeOnly : .pass(rest)
            }
        }
        return .noWake
    }

    private func beginWakeWindow() {
        wakeActive = true
        recomputeStatus()
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.wakeWindow ?? 10) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.endWakeWindow() }
        }
    }

    private func endWakeWindow() {
        wakeTask?.cancel(); wakeTask = nil
        if wakeActive { wakeActive = false; recomputeStatus() }
    }

    private func handleLook(_ path: String) {
        guard !session.cliMissing else { return }
        lookInFlight = true
        didFireLook()
        session.sendLook(imagePath: path)
        recomputeStatus()
    }

    private func applyStatus(_ s: WBStatus) { boardStatus = s; recomputeStatus() }

    // Single source of truth for the status line — reflects the interaction model, not just
    // board motion. Priority: look > speak > wake-window > idle(listening-for-phrase).
    private func recomputeStatus() {
        switch camera {
        case .denied: statusText = "camera access denied"; return
        case .unavailable: return   // keep the specific message set at configure time
        case .starting: statusText = "starting camera…"; return
        case .running: break
        }
        if lookInFlight || boardStatus == .looking { statusText = "looking…"; return }
        if speaking { statusText = "speaking…"; return }
        if wakeActive { statusText = "listening…"; return }
        let phrase = wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !micEnabled {
            statusText = boardStatus == .writing ? "writing detected…" : "watching — board stable"
        } else if phrase.isEmpty {
            statusText = "listening — say anything"
        } else {
            statusText = "listening for '\(phrase)'"
        }
    }

    // Mic is gated ONLY during actual TTS playback (+~300ms tail via the delayed onDone), so the
    // user can talk while the agent is generating. Wake-gating filters the spurious commits.
    private func updateMicGate() { listener.setGateOpen(!speaking) }

    // ---- corner persistence ----
    static func loadCorners() -> [CGPoint] {
        let def: [CGPoint] = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                              CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.9)]
        guard let arr = defaults().array(forKey: Keys.whiteboardCorners) as? [Double], arr.count == 8 else { return def }
        return [CGPoint(x: arr[0], y: arr[1]), CGPoint(x: arr[2], y: arr[3]),
                CGPoint(x: arr[4], y: arr[5]), CGPoint(x: arr[6], y: arr[7])]
    }
}

// MARK: Camera preview (AVCaptureVideoPreviewLayer host)

// Unified "menu chip" label for custom dropdown menus (project chip, model chip,
// camera picker): raised surface + border + trailing chevron + hover raise, so a
// clickable menu never reads as a flat label in the Mono theme.
struct MenuChipLabel<Content: View>: View {
    let pal: Pal
    var radius: CGFloat = 5
    var vPad: CGFloat = 4
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            content()
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(pal.muted)
        }
        .padding(.horizontal, 8).padding(.vertical, vPad)
        .background(RoundedRectangle(cornerRadius: radius).fill(pal.surface2))
        .overlay(RoundedRectangle(cornerRadius: radius)
            .stroke(hovering ? pal.lineStrong : pal.line, lineWidth: 1))
        .opacity(hovering ? 1.0 : 0.92)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

// Transparent backing view that refuses window-move on mouse-down. Placed under
// interactive regions (pin overlay) inside movable-by-background windows so drags
// reach the SwiftUI gesture instead of relocating the window.
final class NoWindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

struct NoWindowDrag: NSViewRepresentable {
    func makeNSView(context: Context) -> NoWindowDragNSView { NoWindowDragNSView() }
    func updateNSView(_ nsView: NoWindowDragNSView, context: Context) {}
}

final class CameraPreviewNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    let previewLayer: AVCaptureVideoPreviewLayer
    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.frame = bounds
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}

struct CameraPreview: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> CameraPreviewNSView { CameraPreviewNSView(previewLayer: previewLayer) }
    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {}
}

// MARK: Pinning overlay — 4 draggable corners over the preview (aspect-fill mapping)

struct PinningOverlay: View {
    let corners: [CGPoint]        // normalized top-left image coords, TL TR BR BL
    let frameAspect: CGFloat      // image width / height
    let pal: Pal
    let onDrag: (Int, CGPoint) -> Void   // live (index, new normalized)
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = corners.map { toView($0, size) }
            ZStack {
                if pts.count == 4 {
                    Path { p in
                        p.move(to: pts[0]); p.addLine(to: pts[1])
                        p.addLine(to: pts[2]); p.addLine(to: pts[3]); p.closeSubpath()
                    }
                    .stroke(pal.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(pal.accent)
                            .overlay(Circle().stroke(pal.onAccent, lineWidth: 1.5))
                            .frame(width: 15, height: 15)
                            .contentShape(Rectangle().inset(by: -12))
                            .position(pts[i])
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { g in onDrag(i, clamp(toNorm(g.location, size))) }
                                    .onEnded { _ in onCommit() }
                            )
                    }
                }
            }
        }
    }

    // aspect-FIT content rect (matches previewLayer .resizeAspect — whole frame
    // visible, letterboxed; overlay coords must map to the same rect)
    private func fit(_ size: CGSize) -> (CGPoint, CGFloat, CGFloat) {
        let scale = min(size.width / frameAspect, size.height)   // image intrinsic = (aspect, 1)
        let w = frameAspect * scale, h = scale
        return (CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2), w, h)
    }
    private func toView(_ n: CGPoint, _ size: CGSize) -> CGPoint {
        let (o, w, h) = fit(size)
        return CGPoint(x: o.x + n.x * w, y: o.y + n.y * h)
    }
    private func toNorm(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let (o, w, h) = fit(size)
        return CGPoint(x: (p.x - o.x) / max(1, w), y: (p.y - o.y) / max(1, h))
    }
    private func clamp(_ n: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, n.x)), y: min(1, max(0, n.y)))
    }
}

// MARK: Whiteboard window + view

final class WhiteboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { AppDelegate.shared.closeWhiteboard() }
}

private struct WBBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct WBHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct WhiteboardView: View {
    @ObservedObject var engine: WhiteboardEngine
    @ObservedObject var session: WhiteboardSession
    @ObservedObject var listener: BoardListener
    @Environment(\.colorScheme) private var scheme
    @State private var appeared = false
    @State private var atBottom = true
    @State private var scrollHeight: CGFloat = 0
    @State private var showNewProject = false
    @State private var showEditBrief = false
    @State private var showHelp = false
    @State private var showRemote = false

    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    private var fontSize: CGFloat { contentFontSize() }

    private let helpLines: [(String, String)] = [
        ("pin", "drag the four corners over the board so I see it flat"),
        ("raw｜board", "flip the preview between the camera+pins and the live dewarped crop I actually see"),
        ("camera", "pick the camera — an iPhone Continuity Camera reads a board far better than a webcam"),
        ("wake", "say the wake phrase (default “hey board”) before talking to me"),
        ("barge-in", "say the wake phrase WHILE I'm talking to cut me off and start over"),
        ("look", "say “look at the board” / “what do you think?” and I'll snapshot it"),
        ("Look now", "snapshot the board immediately, bypassing the gates"),
        ("thumbnail", "each look shows the exact photo I got — click it to open full size"),
        ("auto-look", "watch continuously and chime in on changes (off by default)"),
        ("mic / voice / cues", "mute the mic · mute my spoken replies · mute the sound cues"),
        ("remote", "transcript, photos, hold-to-talk from your phone — scan the QR to read replies, send a snapshot, or hold the big button to talk (same Wi-Fi)"),
        ("End session", "save a markdown recap to this project's memory, then close"),
    ]

    var body: some View {
        GeometryReader { geo in
            let leftW = max(280, min(geo.size.width * 0.42, geo.size.width - 320))
            HStack(spacing: 0) {
                leftPane.frame(width: leftW)
                Divider().overlay(pal.line)
                rightPane
            }
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 440, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(pal.surface))
        .overlay {
            if showHelp {
                HelpOverlay(title: "Whiteboard — how it works", lines: helpLines, pal: pal) { showHelp = false }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.lineStrong, lineWidth: 1))
        .foregroundColor(pal.text)
        .scaleEffect(appeared ? 1 : 0.98)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.16)) { appeared = true } }
        .sheet(isPresented: $showNewProject) {
            ProjectSheet(mode: .create) { name, brief in
                session.switchProject(ProjectStore.create(name: name, brief: brief))
            }
        }
        .sheet(isPresented: $showEditBrief) {
            ProjectSheet(mode: .edit, name: session.project.name, brief: session.project.brief) { _, brief in
                session.editBrief(brief)
            }
        }
    }

    // ---- LEFT: camera + pinning + controls ----
    private var leftPane: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(pal.line)
            preview
            Divider().overlay(pal.line)
            controls
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("Whiteboard").font(.system(size: 12, weight: .semibold))
            ProjectChipMenu(current: session.project, projects: session.projectList, pal: pal,
                            onSwitch: { session.switchProject($0) },
                            onNew: { showNewProject = true },
                            onEditBrief: { showEditBrief = true })
            if engine.lookInFlight { BreathingDot(pal: pal) }
            Spacer()
            remoteChip
            HelpChip(pal: pal, on: $showHelp)
            Text("\(session.engine) · \(session.model)")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(pal.faint)
            Button(action: { AppDelegate.shared.closeWhiteboard() }) {
                Text("✕").font(.system(size: 11)).foregroundColor(pal.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(pal.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(pal.line, lineWidth: 1))
            }
            .buttonStyle(.plain).help("Close (Esc)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // Phone-remote chip — scan a QR to drive the board from a phone on the same Wi-Fi.
    private var remoteChip: some View {
        Button(action: { showRemote.toggle() }) {
            Image(systemName: "iphone")
                .font(.system(size: 12))
                .foregroundColor(showRemote ? pal.text : pal.muted)
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(showRemote ? pal.surface3 : pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(showRemote ? pal.lineStrong : pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Phone remote — scan a QR to control the board from your phone (same Wi-Fi)")
        .popover(isPresented: $showRemote, arrowEdge: .bottom) {
            RemoteQRView(engine: engine, pal: pal)
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            // Blocks isMovableByWindowBackground in the preview region — without it,
            // dragging a pin corner moves the whole window instead of the handle
            // (SwiftUI DragGesture doesn't preempt background window-drag).
            NoWindowDrag()
            Color.black
            switch engine.camera {
            case .running:
                if engine.previewMode == "board" {
                    // What the agent actually sends: the live dewarped crop. Pin overlay hidden here.
                    if let img = engine.dewarpedPreview {
                        // fit, not fill — the whole dewarped board must be visible
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Text("dewarping…").font(.system(size: 12)).foregroundColor(pal.muted)
                    }
                } else {
                    CameraPreview(previewLayer: engine.previewLayer)
                    PinningOverlay(corners: engine.corners, frameAspect: engine.frameAspect, pal: pal,
                                   onDrag: { i, n in
                                       var c = engine.corners; c[i] = n; engine.corners = c
                                   },
                                   onCommit: { engine.updateCorners(engine.corners) })
                }
            case .starting:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("starting camera…").font(.system(size: 12)).foregroundColor(pal.muted)
                }
            case .denied:
                VStack(spacing: 10) {
                    Text("Camera access denied").font(.system(size: 13, weight: .semibold)).foregroundColor(pal.text)
                    Text("Cleanup needs the camera to watch your whiteboard.")
                        .font(.system(size: 11)).foregroundColor(pal.muted).multilineTextAlignment(.center)
                    Button("Open System Settings") { engine.openSystemCameraSettings() }
                        .controlSize(.small)
                }
                .padding(20)
            case .unavailable:
                Text(engine.statusText).font(.system(size: 12)).foregroundColor(pal.muted).padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // brief accent flash on the preview when a look fires — cause→effect you can see across the room
        .overlay(
            Rectangle().strokeBorder(pal.accent, lineWidth: 3)
                .opacity(engine.lookFlash ? 1 : 0)
                .allowsHitTesting(false)
        )
        // "raw | board" — see the camera+pins, or exactly what the agent sees
        .overlay(alignment: .topLeading) {
            if engine.camera == .running { previewToggle.padding(8) }
        }
    }

    // Two-segment mono switch over the preview.
    private var previewToggle: some View {
        HStack(spacing: 0) {
            ForEach(["raw", "board"], id: \.self) { mode in
                let on = engine.previewMode == mode
                Button(action: { engine.setPreviewMode(mode) }) {
                    Text(mode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(on ? pal.onAccent : pal.muted)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(on ? pal.accent : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(pal.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help("raw: camera + pin corners · board: the live dewarped crop the agent actually sees")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(statusDotColor).frame(width: 7, height: 7)
                Text(engine.statusText).font(.system(size: 11, design: .monospaced)).foregroundColor(pal.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if engine.lookInFlight { BreathingDot(pal: pal) }
            }
            HStack(spacing: 8) {
                toggleChip("auto-look", on: engine.autoLook) { engine.setAutoLook(!engine.autoLook) }
                Button(action: { engine.lookNow() }) {
                    Text("Look now").font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(pal.surface2))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(pal.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(engine.camera != .running || engine.lookInFlight)
                .help("Snapshot the board now (bypasses the change/interval gates)")
                Spacer(minLength: 0)
                soundsButton
                micButton
                muteButton
            }
            wakeRow
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // Wake-phrase field — edit inline, mono styled. Empty = every utterance goes through.
    private var wakeRow: some View {
        HStack(spacing: 6) {
            Text("wake").font(.system(size: 10, design: .monospaced)).foregroundColor(pal.faint)
            TextField("hey board", text: Binding(
                get: { engine.wakePhrase },
                set: { engine.setWakePhrase($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(pal.text)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(engine.wakeActive ? pal.accent : pal.line, lineWidth: 1))
                .frame(maxWidth: 120)
                .help("Spoken wake phrase — say it to talk to me. Empty = all speech goes through.")
            Spacer(minLength: 4)
            cameraMenu
            Button(action: { engine.endSession() }) {
                Text("End session").font(.system(size: 11))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(pal.surface2))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(pal.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Save a markdown summary to this project's memory, then close")
        }
    }

    // Camera picker — includes iPhone Continuity Camera, far more legible than most webcams.
    private var cameraMenu: some View {
        Menu {
            ForEach(engine.availableCameras()) { c in
                Button(action: { engine.selectCamera(c.id) }) {
                    Text((c.id == engine.selectedCameraID ? "✓  " : "    ") + c.name)
                }
            }
        } label: {
            MenuChipLabel(pal: pal, radius: 7, vPad: 5) {
                HStack(spacing: 4) {
                    Text("\(Image(systemName: "video"))").font(.system(size: 11))
                    Text(engine.selectedCameraName).font(.system(size: 10, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                }
                .foregroundColor(pal.muted)
                .frame(maxWidth: 88, alignment: .leading)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: 132)
        .help("Choose the camera (built-in, external, or iPhone Continuity Camera)")
    }

    private var soundsButton: some View {
        Button(action: { engine.setSounds(!engine.sounds) }) {
            Image(systemName: engine.sounds ? "bell.fill" : "bell.slash")
                .font(.system(size: 12))
                .foregroundColor(engine.sounds ? pal.text : pal.muted)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(engine.sounds ? "Sound cues on (wake / look / done) — click to mute" : "Sound cues off (click to enable)")
    }

    private var statusDotColor: Color {
        switch engine.camera {
        case .running: return pal.muted
        case .denied, .unavailable: return .red
        case .starting: return pal.faint
        }
    }

    private func toggleChip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(on ? pal.accent : pal.faint).frame(width: 6, height: 6)
                Text(label).font(.system(size: 11)).foregroundColor(on ? pal.text : pal.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? pal.lineStrong : pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @State private var micPulse = false
    // Mic glyph tints to accent during the post-wake "listening…" window, and pulses whenever
    // the recogniser is live — so the wake handshake is visible.
    private var micGlyphColor: Color {
        if listener.disabled { return pal.faint }
        if engine.wakeActive { return pal.accent }
        return engine.micEnabled ? pal.text : pal.muted
    }
    private var micButton: some View {
        Button(action: { engine.setMic(!engine.micEnabled) }) {
            Image(systemName: engine.micEnabled ? (listener.listening ? "mic.fill" : "mic") : "mic.slash")
                .font(.system(size: 13))
                .foregroundColor(micGlyphColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(listener.listening ? pal.surface3 : pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(engine.wakeActive ? pal.accent : (listener.listening ? pal.lineStrong : pal.line), lineWidth: 1))
                .opacity((listener.listening || engine.wakeActive) && micPulse ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(listener.disabled)
        .help(listener.disabled ? listener.statusHelp : (engine.micEnabled ? "Open mic — listening (click to mute)" : "Mic off (click to listen)"))
        .onChange(of: listener.listening) { _, now in
            if now {
                micPulse = false
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { micPulse = true }
            } else { withAnimation(.default) { micPulse = false } }
        }
    }

    private var muteButton: some View {
        Button(action: { engine.setMuted(!engine.muted) }) {
            Image(systemName: engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundColor(engine.muted ? pal.muted : pal.text)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(pal.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(pal.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(engine.muted ? "Voice muted (click to unmute)" : "Speaking replies (click to mute)")
    }

    // ---- RIGHT: transcript + typed input ----
    private var rightPane: some View {
        VStack(spacing: 0) {
            transcript
            Divider().overlay(pal.line)
            inputBar
        }
        .frame(minWidth: 300)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.messages) { m in
                        AgentRow(msg: m, pal: pal, fontSize: fontSize)
                    }
                    if session.running && session.messages.last?.role != .assistant {
                        ThinkingRow(pal: pal).transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("WBBOTTOM")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: WBBottomKey.self, value: g.frame(in: .named("wbScroll")).maxY)
                        })
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .coordinateSpace(name: "wbScroll")
            .background(GeometryReader { g in
                Color.clear.preference(key: WBHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(WBHeightKey.self) { scrollHeight = $0 }
            .onPreferenceChange(WBBottomKey.self) { atBottom = $0 <= scrollHeight + 40 }
            .onReceive(session.$messages) { _ in
                guard atBottom else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("WBBOTTOM", anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if listener.listening && !listener.partial.isEmpty {
                HStack(spacing: 6) {
                    Text("● listening").font(.system(size: 10, design: .monospaced)).foregroundColor(pal.faint)
                    Text(listener.partial).font(.system(size: fontSize - 1)).italic().foregroundColor(pal.faint).lineLimit(2)
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if session.input.isEmpty {
                        Text(engine.micEnabled ? "talk, or type…" : "type a message…")
                            .font(.system(size: fontSize)).foregroundColor(pal.faint.opacity(0.7))
                            .padding(.leading, 4).padding(.top, 4)
                    }
                    AgentInput(text: $session.input, fontSize: fontSize,
                               onSend: { engine.submitTyped() },
                               onEscape: { AppDelegate.shared.closeWhiteboard() },
                               onPasteImage: { false })
                        .frame(minHeight: 22, maxHeight: 100)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(session.cliMissing)
                }
                Button(action: { engine.submitTyped() }) {
                    ZStack {
                        Circle().fill(pal.accent)
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(pal.onAccent)
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(session.running || session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.cliMissing)
                .help("Send (Enter)")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.lineStrong, lineWidth: 1))
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
    }
}

// MARK: Phone-remote QR popover

struct RemoteQRView: View {
    let engine: WhiteboardEngine
    let pal: Pal

    var body: some View {
        VStack(spacing: 10) {
            Text("Phone remote").font(.system(size: 12, weight: .semibold)).foregroundColor(pal.text)
            if let url = engine.remote.remoteURL(), let qr = makeRemoteQR(url) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 190, height: 190)
                    .padding(9)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(pal.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text("Read the transcript, hold to talk, or send a photo from your phone. Same Wi-Fi only; the link dies when this window closes. First visit: accept the certificate warning.")
                    .font(.system(size: 10)).foregroundColor(pal.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No Wi-Fi/LAN address found")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(pal.text)
                Text("Join a Wi-Fi network to use the phone remote.")
                    .font(.system(size: 10)).foregroundColor(pal.faint)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(width: 250)
        .background(pal.surface2)
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var agentMenuItem: NSMenuItem!
    private var whiteboardMenuItem: NSMenuItem!
    private var panel: PopupPanel?
    private var session: Session?
    private var settingsWindow: NSWindow?
    private var diffWindow: NSWindow?          // pop-out diff (one instance, tied to the popup)
    private var agentWindow: AgentWindow?      // agent mode (single instance, own CLI session)
    private var agentSession: AgentSession?
    private var whiteboardWindow: WhiteboardWindow?  // whiteboard mode (single instance)
    private var whiteboardEngine: WhiteboardEngine?
    private var welcomeWindow: NSWindow?             // first-run welcome + health (single instance)
    private var targetApp: NSRunningApplication?
    private var closingProgrammatically = false
    // in-flight hands-free generation (nil when idle) + its progress chip panel
    private var autoTask: Task<Void, Never>?
    private var progressPanel: NSPanel?
    // floating ✦ ⚡ selection chips + the gesture watcher that drives them
    private var chipPanel: NSPanel?
    private var chipHideWork: DispatchWorkItem?
    private var pendingGesture: DispatchWorkItem?
    private var watchDownAt: NSPoint = .zero
    private var watchDragMax: CGFloat = 0
    private var didPromptAccessibility = false
    private var didRequestScreenCapture = false   // one-shot: prompt for Screen Recording on first snip
    private var emptyCaptureCount = 0   // consecutive empty captures → surface Health

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // never leak the agent's child CLI process tree on quit
        agentSession?.stop()
        whiteboardEngine?.stop()
        VoiceEngine.shared.terminate()   // kill the persistent local-voice helper
    }

    // LSUIElement apps have no visible menu bar — but WITHOUT a main menu, macOS
    // never dispatches the standard editing key equivalents, so ⌘V/⌘C/⌘X/⌘A were
    // silently dead in every text field app-wide (refine bar, API keys, agent
    // input, wake phrase). An invisible main menu with an Edit menu routes them
    // to the first responder — including PasteTextView's image-paste override.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = NSMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        registerDefaults()
        installEditMenu()
        // seed the agent workdir's CLAUDE.md / AGENTS.md from the saved personal context
        ProjectStore.bootstrap()
        setupStatusBar()
        requestAccessibility()
        registerHotkey()
        setupSelectionWatcher()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Warm the local-voice helper if it's installed, so the ASR/TTS paths engage promptly
        // and Health/Settings reflect real availability. No-op (and cheap) when not installed.
        VoiceEngine.shared.refreshAvailability()

        // First launch: open the welcome window so permissions get granted up front
        // (with guidance) instead of ambushing the user later. Menu reopens it anytime.
        if !defaults().bool(forKey: Keys.didOnboard) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openWelcome() }
        }

        if CommandLine.arguments.contains("--test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPopup(text: "hey can u send me the notes from todays lecture i missed it cuz my bus was late lol also did prof say anything abt the midterm format")
            }
        }
        if CommandLine.arguments.contains("--voicetest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openSettings() }
        }

    }

    // MARK: status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "✦"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Select text → ⌃⌘E popup · ⌃⌘R instant", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let test = NSMenuItem(title: "Test Popup", action: #selector(testPopup), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        // Agent task… — enabled only when the selected agent engine's CLI resolves
        // (refreshed in menuWillOpen, since the CLI may be installed mid-session).
        agentMenuItem = NSMenuItem(title: "Agent task…", action: #selector(agentTaskAction), keyEquivalent: "")
        agentMenuItem.target = self
        menu.addItem(agentMenuItem)
        // Whiteboard uses the same selected provider/model as Agent mode.
        whiteboardMenuItem = NSMenuItem(title: "Whiteboard…", action: #selector(whiteboardAction), keyEquivalent: "")
        whiteboardMenuItem.target = self
        menu.addItem(whiteboardMenuItem)
        let snip = NSMenuItem(title: "Snip → Agent", action: #selector(snipAction), keyEquivalent: "")
        snip.target = self
        menu.addItem(snip)
        menu.addItem(NSMenuItem.separator())
        let welcome = NSMenuItem(title: "Welcome & health…", action: #selector(welcomeAction), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Cleanup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    // Refresh the agent item's enabled state each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        agentMenuItem?.isEnabled = AgentCLI.available
        agentMenuItem?.title = "Agent task (\(ProjectStore.current().name))…"
        whiteboardMenuItem?.isEnabled = AgentCLI.available
    }

    @objc private func agentTaskAction() { openAgent(context: nil) }

    @objc private func whiteboardAction() { openWhiteboard() }

    @objc private func snipAction() { startSnip(.area) }

    @objc private func testPopup() {
        showPopup(text: "hey can u send me the notes from todays lecture i missed it cuz my bus was late lol also did prof say anything abt the midterm format")
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func welcomeAction() { openWelcome() }

    // First-run welcome + reopenable "Welcome & health…". Single instance; a live
    // health sweep runs as it opens so the checklist is real by the time it's seen.
    func openWelcome() {
        HealthMonitor.shared.refreshIfStale()
        if welcomeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Welcome to Cleanup"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView(onDismiss: { [weak self] in
                defaults().set(true, forKey: Keys.didOnboard)
                self?.welcomeWindow?.close()
            }))
            w.center()
            welcomeWindow = w
        }
        welcomeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: hotkeys (⌃⌘E popup · ⌃⌘R instant)

    private func registerHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.shift) else { return }
            switch event.keyCode {
            case 14:  // E → open the popup
                DispatchQueue.main.async { self?.captureSelectionAndShow() }
            case 15:  // R → hands-free instant auto-replace
                DispatchQueue.main.async { self?.instantTrigger(source: "hotkey") }
            default: return
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    // MARK: selection watcher + floating chips

    // Global mouse monitors drive the PopClip-style ✦ ⚡ chips (and, while auto mode
    // is on, the live recapture). Needs Accessibility to fire; if it silently
    // doesn't, that's acceptable — logged once here. Global monitors never fire for
    // events delivered to our own windows, and we additionally hit-test our frames.
    private func setupSelectionWatcher() {
        NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            self?.handleWatch(event)
        }
        logLine("selection watcher installed (needs Accessibility to fire)")
    }

    private func handleWatch(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            watchDownAt = NSEvent.mouseLocation
            watchDragMax = 0
            pendingGesture?.cancel(); pendingGesture = nil
            // a click elsewhere dismisses the chips (unless it lands on them)
            if !isOverChip(NSEvent.mouseLocation) { hideChips() }
        case .leftMouseDragged:
            let p = NSEvent.mouseLocation
            let d = hypot(p.x - watchDownAt.x, p.y - watchDownAt.y)
            if d > watchDragMax { watchDragMax = d }
        case .leftMouseUp:
            handleGesture(event)
        case .scrollWheel:
            hideChips()
        default:
            break
        }
    }

    // Gesture = mouse-up after >15pt cumulative drag, OR a double-click. We never
    // capture the selection to DECIDE whether to react (no clipboard churn) — the
    // clipboard is only touched once a chip is clicked (or an auto recapture fires).
    private func handleGesture(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dragged = watchDragMax > 15
        let doubleClick = event.clickCount >= 2
        if !dragged && !doubleClick { return }
        if isOverOwnWindow(p) { return }   // selections inside our own windows never trigger

        // Auto mode: the popup is the receiver — recapture and feed it in (no chips).
        if panel != nil, let session, session.autoMode {
            scheduleSettle { [weak self] in self?.autoCapture() }
            return
        }
        // Floating chips: only when the popup is closed and the feature is enabled.
        guard panel == nil, defaults().bool(forKey: Keys.floatingButton) else { return }
        scheduleSettle { [weak self] in self?.showChips(at: p) }
    }

    // ~250ms settle so the chips/recapture don't fire mid-interaction.
    private func scheduleSettle(_ block: @escaping () -> Void) {
        pendingGesture?.cancel()
        let work = DispatchWorkItem(block: block)
        pendingGesture = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func isOverChip(_ p: NSPoint) -> Bool {
        guard let f = chipPanel?.frame else { return false }
        return f.contains(p)
    }

    private func isOverOwnWindow(_ p: NSPoint) -> Bool {
        for w: NSWindow? in [panel, chipPanel, settingsWindow, diffWindow, progressPanel, agentWindow, whiteboardWindow] {
            if let f = w?.frame, f.contains(p) { return true }
        }
        return false
    }

    // Auto recapture: grab the fresh selection (retargets targetApp to the now-
    // frontmost app) and feed it into the live session WITHOUT stealing focus.
    private func autoCapture() {
        guard panel != nil, let session, session.autoMode else { return }
        captureSelection { [weak self] text in
            guard let session = self?.session, session.autoMode else { return }
            session.updateSource(text)
        }
    }

    // Two circular chips near the selection, in a borderless nonactivating floating
    // panel (mirrors the ProgressChip panel style) — never made key, so the source
    // app keeps its selection. Auto-hides after 4s / on scroll / on a click away.
    private func showChips(at p: NSPoint) {
        hideChips()
        if panel != nil { return }
        let size = floatingButtonSize()
        let gap = max(4, size * 0.2)
        // Per-chip toggles decide what renders; 🤖 additionally needs its engine's CLI.
        let showStar = defaults().bool(forKey: Keys.chipStar)
        let showBolt = defaults().bool(forKey: Keys.chipBolt)
        let showAgent = defaults().bool(forKey: Keys.chipAgent) && AgentCLI.available
        let showSnip = defaults().bool(forKey: Keys.chipSnip)
        let count = CGFloat([showStar, showBolt, showAgent, showSnip].filter { $0 }.count)
        // nothing enabled (or only 🤖 with no CLI) → skip the bar entirely, no empty panel
        guard count > 0 else { return }
        let w = size * count + gap * (count - 1), h = size
        let pnl = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        pnl.isOpaque = false
        pnl.backgroundColor = .clear
        pnl.hasShadow = true
        pnl.level = .floating
        pnl.isReleasedWhenClosed = false
        pnl.ignoresMouseEvents = false
        // Never become key (would drop the source app's selection). becomesKeyOnlyIfNeeded
        // keeps it that way while still letting embedded controls act; the real fix for
        // chip clicks is FirstMouseHostingView accepting the first (non-key) mouse click.
        pnl.becomesKeyOnlyIfNeeded = true
        pnl.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pnl.contentView = FirstMouseHostingView(rootView: FloatingChips(
            size: size,
            showStar: showStar,
            showBolt: showBolt,
            showAgent: showAgent,
            showSnip: showSnip,
            onStar: { [weak self] in self?.chipStar() },
            onBolt: { [weak self] in self?.chipBolt() },
            onAgent: { [weak self] in self?.chipAgent() },
            onSnip: { [weak self] mode in self?.chipSnip(mode) }))

        // just above-right of the cursor, clamped to that cursor's screen
        var origin = NSPoint(x: p.x + 12, y: p.y + 10)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            origin.x = max(vis.minX + 6, min(origin.x, vis.maxX - w - 6))
            origin.y = max(vis.minY + 6, min(origin.y, vis.maxY - h - 6))
        }
        pnl.setFrameOrigin(origin)
        pnl.alphaValue = 1
        pnl.orderFrontRegardless()   // show without stealing focus
        chipPanel = pnl
        logLine("chips: shown (agent=\(showAgent)) at \(Int(origin.x)),\(Int(origin.y))")

        let work = DispatchWorkItem { [weak self] in self?.hideChips() }
        chipHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // ✦ → capture + open the popup (same as ⌃⌘E). Capture happens here, on click —
    // never earlier — so idle selections never churn the clipboard.
    private func chipStar() {
        logLine("chip: ✦ tapped")
        hideChips()
        if panel != nil { return }
        // Degrade visibly: if capture comes back empty (no selection / lost
        // Accessibility), still open the popup so the user sees a response.
        captureSelection({ [weak self] in self?.showPopup(text: $0) },
                         onEmpty: { [weak self] in
                             logLine("chip: ✦ empty capture — opening empty popup")
                             self?.showPopup(text: "")
                         })
    }

    // ⚡ → the existing instant flow, which captures the selection itself.
    private func chipBolt() {
        logLine("chip: ⚡ tapped")
        hideChips()
        instantTrigger(source: "chip")
    }

    // 🤖 → capture the selection and open the agent window seeded with it as context.
    private func chipAgent() {
        logLine("chip: 🤖 tapped")
        hideChips()
        // Degrade visibly: open the agent window even with no context so the user
        // can still type a task, rather than the click appearing to do nothing.
        captureSelection({ [weak self] in self?.openAgent(context: $0) },
                         onEmpty: { [weak self] in
                             logLine("chip: 🤖 empty capture — opening agent with no context")
                             self?.openAgent(context: nil)
                         })
    }

    // ✂ → screenshot a region (or window / full screen), then attach the PNG to the agent.
    private func chipSnip(_ mode: SnipMode) {
        logLine("chip: ✂ tapped mode=\(mode)")
        hideChips()
        startSnip(mode)
    }

    // Drive the built-in `screencapture` CLI. We do NOT activate our app first — screencapture
    // runs its own crosshair/overlay and Cleanup must not steal focus during capture. A non-zero
    // exit or a missing file means the user cancelled → silent no-op.
    //   area  : -i   interactive crosshair (press Space during it to switch to window capture)
    //   window: -iW  window-selection interactive
    //   full  : (no flag) whole main display, immediate
    private func startSnip(_ mode: SnipMode) {
        // Screen Recording binds at launch; if it isn't granted, fire the system prompt once
        // (with the app in context) and point the user at Health. The current capture will
        // still come up empty until they grant + relaunch, which Health now spells out.
        if !CGPreflightScreenCaptureAccess() && !didRequestScreenCapture {
            didRequestScreenCapture = true
            CGRequestScreenCaptureAccess()
            logLine("snip: Screen Recording not granted — requested access; see Health")
            openWelcome()
        }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("Cleanup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let path = (dir as NSString).appendingPathComponent("snip-\(fmt.string(from: Date())).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        switch mode {
        case .area:   p.arguments = ["-i", path]
        case .window: p.arguments = ["-iW", path]
        case .full:   p.arguments = [path]
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                let ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
                if ok { AppDelegate.shared.snipCaptured(path) }
                else { logLine("snip: cancelled or failed (status \(proc.terminationStatus))") }
            }
        }
        do { try p.run() }
        catch { logLine("snip: failed to launch screencapture — \(error.localizedDescription)") }
    }

    // After a capture: copy the image to the clipboard (bonus — paste-able anywhere) and attach
    // it to the agent, reusing the open agent window if there is one, else opening one pre-attached.
    func snipCaptured(_ path: String) {
        if let img = NSImage(contentsOfFile: path) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        }
        if let session = agentSession {
            session.addAttachment(path)
            agentWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openAgent(context: nil)          // no-op → Settings if no CLI; image stays on the clipboard
            agentSession?.addAttachment(path)
        }
        logLine("snip: captured \(path) → agent")
    }

    private func hideChips() {
        chipHideWork?.cancel(); chipHideWork = nil
        guard let pnl = chipPanel else { return }
        chipPanel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            pnl.animator().alphaValue = 0
        }, completionHandler: { pnl.orderOut(nil) })
    }

    // MARK: services (right-click → Clean Up Message)

    @objc func cleanUpMessage(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async {
            self.targetApp = NSWorkspace.shared.frontmostApplication
            self.showPopup(text: text)
        }
    }

    // MARK: selection capture (simulated ⌘C, clipboard restored)

    // Shared: simulate ⌘C, wait for the copy to land, restore the clipboard, then
    // hand the captured text to `completion`. Beeps and bails on an empty capture.
    private func captureSelection(_ completion: @escaping (String) -> Void,
                                  onEmpty: (() -> Void)? = nil) {
        targetApp = NSWorkspace.shared.frontmostApplication
        // Simulated ⌘C needs Accessibility; if a rebuild lost the grant, capture
        // silently returns empty. Surface it and prompt once so the flow doesn't
        // just look like a dead button.
        if !AXIsProcessTrusted() {
            logLine("captureSelection: NOT Accessibility-trusted — capture will fail")
            if !didPromptAccessibility {
                didPromptAccessibility = true
                requestAccessibility()   // opens System Settings > Accessibility w/ prompt
            }
        }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let beforeCount = pb.changeCount
        keystroke("c")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            let captured = pb.string(forType: .string)
            let changed = pb.changeCount != beforeCount
            // put the user's clipboard back immediately
            pb.clearContents()
            if let saved = saved { pb.setString(saved, forType: .string) }
            logLine("captureSelection: changed=\(changed) len=\(captured?.count ?? 0)")
            guard changed, let text = captured,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                self.emptyCaptureCount += 1
                // Empty capture almost always means Accessibility isn't granted (⌘C didn't
                // land). Don't fail silently: surface the Health panel so the cause + fix are
                // visible. Open on the first untrusted miss, or after a couple of repeats.
                if !AXIsProcessTrusted() || self.emptyCaptureCount >= 2 {
                    self.emptyCaptureCount = 0
                    logLine("captureSelection: empty — surfacing Health (AX trusted=\(AXIsProcessTrusted()))")
                    self.openWelcome()
                }
                onEmpty?()
                return
            }
            self.emptyCaptureCount = 0
            completion(text)
        }
    }

    // Main trigger (⌃⌘E): capture → open the popup. An open popup swallows it.
    private func captureSelectionAndShow() {
        if panel != nil { return }
        captureSelection { self.showPopup(text: $0) }
    }

    // Instant trigger (⌃⌘R): hands-free auto-replace, regardless of popup state.
    // A second instant trigger while a generation is in flight cancels it; a stray
    // popup is closed first so they don't fight over the clipboard.
    private func instantTrigger(source: String) {
        if let t = autoTask {
            t.cancel()
            autoTask = nil
            hideProgressChip()
            logLine("autoreplace: cancelled by second trigger (\(source))")
            return
        }
        if panel != nil { closePopup() }
        captureSelection { self.autoReplace(text: $0, source: source) }
    }

    // MARK: hands-free auto-replace

    // Generate ONE balanced variant (no popup, no streaming) and paste it straight
    // back over the selection. On any failure (LLM error / empty result) fall back
    // to the normal popup, which surfaces errors well.
    private func autoReplace(text: String, source: String) {
        let start = Date()
        let target = targetApp
        let tone = defaults().string(forKey: Keys.defaultTone) ?? "Clean"
        showProgressChip()
        logLine("autoreplace: start src=\(source) len=\(text.count) backend=\(defaults().string(forKey: Keys.backend) ?? "ollama")")
        autoTask = Task { [weak self] in
            guard let self else { return }
            do {
                let out = try await LLM.complete(system: Prompts.system,
                                                 user: Prompts.variant(text: text, tone: tone, index: 0))
                if Task.isCancelled { return }
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.autoReplaceFailed(text: text, reason: "empty result")
                    return
                }
                self.hideProgressChip()
                self.autoTask = nil
                self.pasteBack(text: out, target: target)
                logLine("autoreplace: done total=\(Int(Date().timeIntervalSince(start) * 1000))ms")
            } catch {
                if Task.isCancelled { return }
                self.autoReplaceFailed(text: text, reason: error.localizedDescription)
            }
        }
    }

    private func autoReplaceFailed(text: String, reason: String) {
        hideProgressChip()
        autoTask = nil
        logLine("autoreplace: failed — \(reason) (falling back to popup)")
        showPopup(text: text)
    }

    private func showProgressChip() {
        hideProgressChip()
        let size: CGFloat = 30
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ProgressChip())
        let mouse = NSEvent.mouseLocation
        p.setFrameOrigin(NSPoint(x: mouse.x + 12, y: mouse.y - 40))
        p.orderFrontRegardless()   // show without stealing focus (keeps the selection)
        progressPanel = p
    }

    private func hideProgressChip() {
        progressPanel?.orderOut(nil)
        progressPanel = nil
    }

    // Refocus the target app, swap in our text, ⌘V, then restore the clipboard.
    private func pasteBack(text: String, target: NSRunningApplication?) {
        target?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let pb = NSPasteboard.general
            let saved = pb.string(forType: .string)
            pb.clearContents()
            pb.setString(text, forType: .string)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                self.keystroke("v")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.60) {
                    pb.clearContents()
                    if let saved = saved { pb.setString(saved, forType: .string) }
                }
            }
        }
    }

    private func keystroke(_ key: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "tell application \"System Events\" to keystroke \"\(key)\" using {command down}"]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: popup lifecycle

    func showPopup(text: String) {
        closePopup()
        hideChips()
        if targetApp == nil { targetApp = NSWorkspace.shared.frontmostApplication }
        let session = Session(original: text)
        self.session = session

        // restore last size (clamped to the mins), then to the mouse's screen below
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        var w = max(480, CGFloat(defaults().double(forKey: Keys.popupWidth)))
        var h = max(360, CGFloat(defaults().double(forKey: Keys.popupHeight)))
        if let vis = screen?.visibleFrame {
            w = min(w, vis.width - 16)
            h = min(h, vis.height - 16)
        }

        let p = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.borderless, .nonactivatingPanel, .resizable],
                           backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 480, height: 360)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.contentView = NSHostingView(rootView: PopupView(session: session))

        // position near the mouse, clamped to the screen
        var origin = NSPoint(x: mouse.x - 40, y: mouse.y - h - 10)
        if let vis = screen?.visibleFrame {
            origin.x = max(vis.minX + 8, min(origin.x, vis.maxX - w - 8))
            origin.y = max(vis.minY + 8, min(origin.y, vis.maxY - h - 8))
        }
        p.setFrameOrigin(origin)

        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopup() {
        guard let p = panel else { return }
        closingProgrammatically = true
        savePopupSize(p)
        // the pop-out diff window tears down with the popup
        diffWindow?.orderOut(nil)
        diffWindow = nil
        session?.cancelTasks()
        session = nil
        p.orderOut(nil)
        panel = nil
        closingProgrammatically = false
    }

    private func savePopupSize(_ p: NSWindow) {
        let s = p.frame.size
        guard s.width >= 480, s.height >= 360 else { return }
        defaults().set(Double(s.width), forKey: Keys.popupWidth)
        defaults().set(Double(s.height), forKey: Keys.popupHeight)
    }

    // Pop out the side-by-side diff. Single instance: re-click focuses it. Observes
    // the live Session so it stays in lockstep with the popup selection.
    func togglePopOut() {
        if let w = diffWindow { w.makeKeyAndOrderFront(nil); return }
        guard let session else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Diff — Cleanup"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 460, height: 260)
        w.level = .floating
        w.delegate = self
        w.contentView = NSHostingView(rootView: DiffPopOutView(session: session, fontSize: contentFontSize()))
        w.center()
        diffWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: agent mode (single instance)

    // Open the agent workspace window. Single instance: re-open focuses it. Seeded with
    // the captured selection (chip) or nil (menu). Independent Agent-mode settings drive
    // engine / model / permission tier.
    func openAgent(context: String?) {
        if let w = agentWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // gently steer to Settings when neither engine's CLI is available yet
        guard AgentCLI.available else { openSettings(); return }

        let session = AgentSession(engine: AgentCLI.engine, model: AgentCLI.model,
                                   permission: AgentCLI.permission, seededContext: context,
                                   project: ProjectStore.current())
        agentSession = session

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        var w = max(420, CGFloat(defaults().double(forKey: Keys.agentWidth)))
        var h = max(380, CGFloat(defaults().double(forKey: Keys.agentHeight)))
        if let vis = screen?.visibleFrame {
            w = min(w, vis.width - 16)
            h = min(h, vis.height - 16)
        }

        let win = AgentWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.borderless, .resizable],
                              backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 420, height: 380)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.delegate = self
        win.contentView = NSHostingView(rootView: AgentView(session: session))

        var origin = NSPoint(x: mouse.x - 40, y: mouse.y - h - 10)
        if let vis = screen?.visibleFrame {
            origin.x = max(vis.minX + 8, min(origin.x, vis.maxX - w - 8))
            origin.y = max(vis.minY + 8, min(origin.y, vis.maxY - h - 8))
        }
        win.setFrameOrigin(origin)

        agentWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logLine("agent window opened (context=\(context != nil ? "\(context!.count) chars" : "none"))")
    }

    // Animated close (exit fade ~120ms); kills any live run.
    func closeAgent() {
        guard let w = agentWindow else { return }
        saveAgentSize(w)
        agentSession?.stop()
        agentSession = nil
        agentWindow = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    private func saveAgentSize(_ w: NSWindow) {
        let s = w.frame.size
        guard s.width >= 420, s.height >= 380 else { return }
        defaults().set(Double(s.width), forKey: Keys.agentWidth)
        defaults().set(Double(s.height), forKey: Keys.agentHeight)
    }

    // MARK: whiteboard mode

    func openWhiteboard() {
        if let w = whiteboardWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Steer to Settings when the currently selected Agent provider is unavailable.
        guard AgentCLI.available else { openSettings(); return }

        let engine = WhiteboardEngine()
        whiteboardEngine = engine

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        var w = max(640, CGFloat(defaults().double(forKey: Keys.whiteboardWidth)))
        var h = max(440, CGFloat(defaults().double(forKey: Keys.whiteboardHeight)))
        if let vis = screen?.visibleFrame {
            w = min(w, vis.width - 16)
            h = min(h, vis.height - 16)
        }

        let win = WhiteboardWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                                   styleMask: [.borderless, .resizable],
                                   backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false   // stay visible when the user switches to other apps
        win.minSize = NSSize(width: 640, height: 440)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.delegate = self
        win.contentView = NSHostingView(rootView: WhiteboardView(engine: engine, session: engine.session, listener: engine.listener))

        var origin = NSPoint(x: mouse.x - w / 2, y: mouse.y - h + 40)
        if let vis = screen?.visibleFrame {
            origin.x = max(vis.minX + 8, min(origin.x, vis.maxX - w - 8))
            origin.y = max(vis.minY + 8, min(origin.y, vis.maxY - h - 8))
        }
        win.setFrameOrigin(origin)

        whiteboardWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        engine.start()
        logLine("whiteboard window opened")
    }

    func closeWhiteboard() {
        guard let w = whiteboardWindow else { return }
        saveWhiteboardSize(w)
        whiteboardEngine?.exportSession()   // save a session summary if it earned one (idempotent)
        whiteboardEngine?.stop()
        whiteboardEngine = nil
        whiteboardWindow = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    private func saveWhiteboardSize(_ w: NSWindow) {
        let s = w.frame.size
        guard s.width >= 640, s.height >= 440 else { return }
        defaults().set(Double(s.width), forKey: Keys.whiteboardWidth)
        defaults().set(Double(s.height), forKey: Keys.whiteboardHeight)
    }

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w == panel { savePopupSize(w) }
        else if w == agentWindow { saveAgentSize(w) }
        else if w == whiteboardWindow { saveWhiteboardSize(w) }
        else if w == settingsWindow { saveSettingsSize(w) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w == diffWindow { diffWindow = nil }
        if w == agentWindow {
            agentSession?.stop()
            agentSession = nil
            agentWindow = nil
        }
        if w == whiteboardWindow {
            whiteboardEngine?.exportSession()   // system-driven close still earns a summary
            whiteboardEngine?.stop()
            whiteboardEngine = nil
            whiteboardWindow = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--test"),
              !closingProgrammatically,
              let w = notification.object as? NSWindow, w == panel else { return }
        // Click-away closes only when the user opts in — and never while the pop-out
        // diff window is open (clicking it must not dismiss the popup), nor while
        // auto mode is on (it needs the popup to stay open across selections).
        guard defaults().bool(forKey: Keys.autoClose), diffWindow == nil,
              session?.autoMode != true else { return }
        closePopup()
    }

    // MARK: results

    func copyResult() {
        guard let text = session?.selectedText else { NSSound.beep(); return }
        closePopup()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func replaceResult() {
        guard let text = session?.selectedText else { NSSound.beep(); return }
        let target = targetApp
        closePopup()
        pasteBack(text: text, target: target)
    }

    // MARK: settings window

    func openSettings() {
        HealthMonitor.shared.refreshIfStale()
        if settingsWindow == nil {
            let w0 = max(640, CGFloat(defaults().double(forKey: Keys.settingsWidth)))
            let h0 = max(480, CGFloat(defaults().double(forKey: Keys.settingsHeight)))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w0, height: h0),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Cleanup Settings"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 640, height: 480)
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Persist the Settings window's CONTENT size (not the frame — that includes the
    // title bar and would drift on each open/save cycle).
    private func saveSettingsSize(_ w: NSWindow) {
        let s = w.contentRect(forFrameRect: w.frame).size
        guard s.width >= 640, s.height >= 480 else { return }
        defaults().set(Double(s.width), forKey: Keys.settingsWidth)
        defaults().set(Double(s.height), forKey: Keys.settingsHeight)
    }
}

// MARK: - main

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
