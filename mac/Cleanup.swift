import Cocoa
import SwiftUI
import Combine
import Speech
import AVFoundation

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
    static let buttonSize = "buttonSize"          // floating chip size (22–48, default 30)
    // Agent mode — independent of the rewrite backend above.
    static let agentEngine = "agentEngine"        // "claude" | "codex"
    static let agentModel = "agentModel"          // engine-specific alias (custom allowed)
    static let agentPermission = "agentPermission"// "safe" | "standard" | "full"
    static let agentWidth = "agentWidth"          // last agent-window size, restored next open
    static let agentHeight = "agentHeight"
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
        Keys.buttonSize: 30.0,
        // Agent work deserves a stronger default than the rewrite backend's haiku.
        Keys.agentEngine: "claude",
        Keys.agentModel: "sonnet",
        Keys.agentPermission: "safe",
        Keys.agentWidth: 560.0,
        Keys.agentHeight: 640.0,
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
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
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
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
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

    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    private var fontSize: CGFloat { contentFontSize() }
    private let tones = ["Clean", "Professional", "Casual", "Blunt"]

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
        .onAppear { sliderVal = Double(session.count) }
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
                Text(backendLabel)
                    .font(.system(size: 11))
                    .foregroundColor(pal.faint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(pal.line, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
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
        case "openai": return "\(d.string(forKey: Keys.apiModel) ?? "api") ▾"
        case "chatgpt": return "\(d.string(forKey: Keys.chatgptModel) ?? "gpt-5.5") · ChatGPT ▾"
        case "claude": return "\(d.string(forKey: Keys.claudeModel) ?? "haiku") · Claude ▾"
        default: return "\(d.string(forKey: Keys.ollamaModel) ?? "ollama") · Ollama ▾"
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
    let onStar: () -> Void
    let onBolt: () -> Void
    let onAgent: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var shown = false
    private var pal: Pal { Pal.of(dark: scheme == .dark) }

    var body: some View {
        HStack(spacing: max(4, size * 0.2)) {
            if showStar {
                FloatingChip(glyph: "✦", size: size, pal: pal, help: "Clean up — open the popup", action: onStar)
            }
            if showBolt {
                FloatingChip(glyph: "⚡", size: size, pal: pal, help: "Instant rewrite in place", action: onBolt)
            }
            // 🤖 spins up an agent on the selection — only when its toggle is on AND the
            // selected agent engine's CLI is present (robot emoji is the sanctioned Mono
            // exception).
            if showAgent {
                FloatingChip(glyph: "🤖", size: size, pal: pal, help: "Agent mode — spin up an agent", action: onAgent)
            }
        }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.8)
        .onAppear { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
    }
}

struct FloatingChip: View {
    let glyph: String
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
            Text(glyph)
                .font(.system(size: size * 0.43))
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

    // Disabled when unsupported, or when the user has previously denied Speech access.
    var disabled: Bool {
        guard recognizer != nil else { return true }
        let s = SFSpeechRecognizer.authorizationStatus()
        return s == .denied || s == .restricted
    }

    func toggle() { listening ? commit() : start() }

    private func start() {
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

    // Toggle off / send / final: stop capture and hand the finalised text over.
    func commit() {
        guard listening else { return }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        stopEngine()
        listening = false
        partial = ""
        if !text.isEmpty { onFinal?(text) }
    }

    func cancel() {
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
}

// MARK: - Agent session (runs a Codex / Claude CLI turn, streams JSONL in)

// Owns one agentic CLI session for the life of an Agent window. The first turn starts
// a fresh session; follow-ups resume it (claude -p --continue / codex exec resume
// --last), so context persists. Engine / model / permission come from Agent settings
// (captured at init — independent of the rewrite Backend). Parsing is defensive: a
// single malformed line can never crash a run, and non-JSON output is never lost.
@MainActor
final class AgentSession: ObservableObject {
    @Published var messages: [AgentMsg] = []
    @Published var running = false
    @Published var input = ""

    let engine: String       // "claude" | "codex"
    let model: String
    let permission: String   // "safe" | "standard" | "full"
    let cliMissing: Bool

    private let seededContext: String?
    private var started = false          // false = first turn, true = follow-ups resume
    private var proc: Process?
    private var runTask: Task<Void, Never>?

    // live assistant segment (mirrors windows/AgentEngine's seg/segStreamed/throttle)
    private var curAssistant: Int?
    private var seg = ""
    private var segStreamed = false
    private var lastEmit: TimeInterval = -1
    private var dirty = false

    init(engine: String, model: String, permission: String, seededContext: String?) {
        self.engine = engine
        self.model = model
        self.permission = permission
        let ctx = seededContext?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.seededContext = (ctx?.isEmpty == false) ? ctx : nil
        self.cliMissing = (AgentCLI.resolve() == nil)

        if let ctx = self.seededContext {
            let head = ctx.replacingOccurrences(of: "\n", with: " ")
            let snippet = head.count > 80 ? String(head.prefix(80)) + "…" : head
            messages.append(AgentMsg(role: .context, text: "context: \(snippet)"))
        }
        if cliMissing {
            messages.append(AgentMsg(role: .note, text: engine == "codex"
                ? "Codex CLI not found. Install it (npm i -g @openai/codex) and run `codex login`, then reopen."
                : "Claude Code CLI not found. Install it and run `claude` once to log in, then reopen."))
        } else {
            messages.append(AgentMsg(role: .note, text: "Ready — ask the agent to do anything. Follow-ups keep the same session."))
        }
    }

    // Enter / send: append the user bubble, seed context into the FIRST task, run.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running, !cliMissing else {
            if text.isEmpty { NSSound.beep() }
            return
        }
        input = ""
        messages.append(AgentMsg(role: .user, text: text))

        var task = text
        if !started, let ctx = seededContext {
            task += "\n\nContext — the user had this text selected:\n" + ctx
        }
        let followup = started
        started = true              // subsequent turns resume, even if this one errors
        running = true
        curAssistant = nil
        resetSeg()
        runTask = Task { [weak self] in await self?.launch(task: task, followup: followup) }
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

    private func launch(task: String, followup: Bool) async {
        guard let cli = AgentCLI.resolve() else {
            messages.append(AgentMsg(role: .error, text: engine == "codex"
                ? "Codex CLI not found" : "Claude Code CLI not found"))
            running = false
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = buildArgs(task: task, followup: followup)
        p.environment = (engine == "codex" ? CodexCLI.env() : ClaudeCLI.env())
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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
        logLine("agent run engine=\(engine) resume=\(followup) perm=\(permission) tasklen=\(task.count)")

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

    private func buildArgs(task: String, followup: Bool) -> [String] {
        if engine == "codex" {
            // codex exec [resume --last] --json -s <sandbox> [-m model] "<task>"
            var a = ["exec"]
            if followup { a += ["resume", "--last"] }
            a += ["--json", "-s", codexSandbox()]
            if !model.isEmpty { a += ["-m", model] }
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
        switch permission {
        case "standard": return ["--permission-mode", "acceptEdits"]
        case "full": return ["--dangerously-skip-permissions"]
        default: return ["--permission-mode", "dontAsk", "--disallowedTools", "Bash Edit Write NotebookEdit"]
        }
    }

    // ---- streaming text segment (throttled ~80ms, segment-aware) ----

    private func resetSeg() { seg = ""; segStreamed = false; lastEmit = -1; dirty = false }

    private func appendDelta(_ d: String) {
        guard !d.isEmpty else { return }
        seg += d; segStreamed = true; dirty = true
        offer()
    }

    // A full (non-delta) message: authoritative only if nothing streamed this segment.
    private func setFull(_ full: String) {
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

    private func flushText() {
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
    private func event(_ line: String) {
        flushText()
        resetSeg()
        curAssistant = nil
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { messages.append(AgentMsg(role: .tool, text: t)) }
    }

    // ---- Claude stream-json parsing ----

    private func handleClaude(_ line: String) {
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

    private func claudeVerb(_ name: String, _ block: [String: Any]) -> String {
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

    private func short(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(60)) + "…" : t
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

struct AgentInput: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let onSend: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
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

struct AgentView: View {
    @ObservedObject var session: AgentSession
    @StateObject private var voice = SpeechDictation()
    @Environment(\.colorScheme) private var scheme
    @State private var appeared = false
    @State private var atBottom = true
    @State private var scrollHeight: CGFloat = 0

    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    private var fontSize: CGFloat { contentFontSize() }

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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.lineStrong, lineWidth: 1))
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
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("Agent").font(.system(size: 12, weight: .semibold)).foregroundColor(pal.text)
            if session.running { BreathingDot(pal: pal) }
            Spacer()
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
                               onSend: submit, onEscape: { AppDelegate.shared.closeAgent() })
                        .frame(minHeight: 22, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                        .disabled(session.cliMissing)
                }
                micButton
                sendStopButton
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(pal.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(pal.lineStrong, lineWidth: 1))
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
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
        .disabled(!session.running && (session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.cliMissing))
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

    var body: some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : slideX)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { appeared = true } }
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
                Text(msg.text).font(.system(size: fontSize)).foregroundColor(pal.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
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
                Spacer(minLength: 44)
            }
        case .tool:
            HStack {
                Text(msg.text).font(.system(size: fontSize - 1, design: .monospaced)).foregroundColor(pal.faint)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        case .error:
            HStack {
                Text("⚠︎ " + msg.text).font(.system(size: fontSize - 1)).foregroundColor(pal.muted)
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

    static func check() -> CodexAuthStatus {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return .missing }
        // decode the JWT payload to read expiry and plan
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return .missing }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let payload = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = claims["exp"] as? Double else { return .missing }
        if exp < Date().timeIntervalSince1970 { return .expired }
        let plan = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        return .connected(plan: plan)
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
    @AppStorage(Keys.buttonSize) private var buttonSize = 30.0
    @AppStorage(Keys.agentEngine) private var agentEngine = "claude"
    @AppStorage(Keys.agentModel) private var agentModel = "sonnet"
    @AppStorage(Keys.agentPermission) private var agentPermission = "safe"
    @State private var ollamaModels: [String] = []
    private let chatgptModels = ModelCatalog.chatgpt
    private let claudeModels = ModelCatalog.claude

    var body: some View {
        Form {
            Picker("Backend", selection: $backend) {
                Text("Ollama (local)").tag("ollama")
                Text("ChatGPT subscription (Codex login)").tag("chatgpt")
                Text("Claude Code subscription (CLI login)").tag("claude")
                Text("OpenAI-compatible API").tag("openai")
            }
            if backend == "ollama" {
                TextField("Server URL", text: $ollamaURL)
                if ollamaModels.isEmpty {
                    TextField("Model", text: $ollamaModel)
                } else {
                    Picker("Model", selection: $ollamaModel) {
                        // keep the saved model selectable even if it's gone from the server
                        ForEach(ollamaModels.contains(ollamaModel) ? ollamaModels : [ollamaModel] + ollamaModels,
                                id: \.self) { Text($0).tag($0) }
                    }
                }
            } else if backend == "chatgpt" {
                Picker("Model", selection: $chatgptModel) {
                    ForEach(chatgptModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Reasoning", selection: $chatgptEffort) {
                    ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
                Text("Low reasoning is ~3x faster for short rewrites. gpt-5.4-mini is the fastest model (~1s).")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                CodexStatusView()
            } else if backend == "claude" {
                Picker("Model", selection: $claudeModel) {
                    ForEach(claudeModels, id: \.self) { Text($0).tag($0) }
                }
                ClaudeStatusView()
            } else {
                TextField("Base URL", text: $apiBase)
                SecureField("API key", text: $apiKey)
                TextField("Model", text: $apiModel)
            }
            Divider()
            Picker("Default tone", selection: $defaultTone) {
                ForEach(["Clean", "Professional", "Casual", "Blunt"], id: \.self) { Text($0).tag($0) }
            }
            Stepper("Default variants: \(defaultCount)", value: $defaultCount, in: 1...5)
            Toggle("Auto-close when clicking away", isOn: $autoClose)
            Toggle("Show buttons when I select text", isOn: $floatingButton)
            // Per-chip toggles; greyed out (disabled) when the master is off.
            VStack(alignment: .leading, spacing: 4) {
                Toggle("✦ Clean up (opens the popup)", isOn: $chipStar)
                Toggle("⚡ Instant rewrite", isOn: $chipBolt)
                Toggle("🤖 Agent mode", isOn: $chipAgent)
            }
            .padding(.leading, 16)
            .disabled(!floatingButton)
            if floatingButton {
                HStack {
                    Text("Button size: \(Int(buttonSize))")
                    Slider(value: $buttonSize, in: 22...48, step: 1)
                }
            }
            HStack {
                Text("Text size: \(Int(fontSize))")
                Slider(value: $fontSize, in: 11...18, step: 1)
            }
            Text("Trigger: select text, then ⌃⌘E to open the popup or ⌃⌘R to instantly rewrite it in place. Or right-click → Clean Up Message. (Hotkeys are fixed.)")
                .font(.system(size: 11)).foregroundColor(.secondary)

            Divider()
            Text("Agent mode").font(.system(size: 13, weight: .semibold))
            Text("Spin up an agent (🤖 chip or the menu) that can actually do work — independent of the rewrite backend above.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Picker("Engine", selection: $agentEngine) {
                Text("Codex (ChatGPT login)").tag("codex")
                Text("Claude (Claude Code login)").tag("claude")
            }
            .onChange(of: agentEngine) { _, newValue in
                agentModel = AgentModels.defaultModel(newValue)
            }
            Text("More engines coming soon (Ollama, API keys).")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Picker("Model", selection: $agentModel) {
                let list = AgentModels.list(agentEngine)
                ForEach(list.contains(agentModel) ? list : [agentModel] + list, id: \.self) { Text($0).tag($0) }
            }
            Picker("Permissions", selection: $agentPermission) {
                Text("Safe — read & analyze only").tag("safe")
                Text("Standard — can edit files").tag("standard")
                Text("Full — no sandbox (dangerous)").tag("full")
            }
            if agentPermission == "full" {
                Text("Full gives the agent unrestricted access to your machine. Use only when you trust the task.")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.orange)
            }
            AgentEngineStatusView(engine: agentEngine)
        }
        .padding(20)
        .frame(width: 440)
        .task { ollamaModels = await ModelCatalog.ollama() }
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

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var agentMenuItem: NSMenuItem!
    private var panel: PopupPanel?
    private var session: Session?
    private var settingsWindow: NSWindow?
    private var diffWindow: NSWindow?          // pop-out diff (one instance, tied to the popup)
    private var agentWindow: AgentWindow?      // agent mode (single instance, own CLI session)
    private var agentSession: AgentSession?
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

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        // never leak the agent's child CLI process tree on quit
        agentSession?.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        registerDefaults()
        setupStatusBar()
        requestAccessibility()
        registerHotkey()
        setupSelectionWatcher()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        if CommandLine.arguments.contains("--test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPopup(text: "hey can u send me the notes from todays lecture i missed it cuz my bus was late lol also did prof say anything abt the midterm format")
            }
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
    }

    @objc private func agentTaskAction() { openAgent(context: nil) }

    @objc private func testPopup() {
        showPopup(text: "hey can u send me the notes from todays lecture i missed it cuz my bus was late lol also did prof say anything abt the midterm format")
    }

    @objc private func openSettingsAction() { openSettings() }

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
        for w: NSWindow? in [panel, chipPanel, settingsWindow, diffWindow, progressPanel, agentWindow] {
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
        let count = CGFloat([showStar, showBolt, showAgent].filter { $0 }.count)
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
            onStar: { [weak self] in self?.chipStar() },
            onBolt: { [weak self] in self?.chipBolt() },
            onAgent: { [weak self] in self?.chipAgent() }))

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
                onEmpty?()
                return
            }
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
                                   permission: AgentCLI.permission, seededContext: context)
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

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w == panel { savePopupSize(w) }
        else if w == agentWindow { saveAgentSize(w) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w == diffWindow { diffWindow = nil }
        if w == agentWindow {
            agentSession?.stop()
            agentSession = nil
            agentWindow = nil
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
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Cleanup Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
