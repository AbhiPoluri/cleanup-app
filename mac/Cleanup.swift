import Cocoa
import SwiftUI

// MARK: - Settings keys

enum Keys {
    static let backend = "backend"                // "ollama" | "openai" | "chatgpt"
    static let chatgptModel = "chatgptModel"
    static let chatgptEffort = "chatgptEffort"    // "low" | "medium" | "high"
    static let ollamaURL = "ollamaURL"
    static let ollamaModel = "ollamaModel"
    static let apiBase = "apiBase"
    static let apiKey = "apiKey"
    static let apiModel = "apiModel"
    static let defaultTone = "defaultTone"
    static let defaultCount = "defaultCount"
}

func defaults() -> UserDefaults { UserDefaults.standard }

func registerDefaults() {
    defaults().register(defaults: [
        Keys.backend: "ollama",
        Keys.ollamaURL: "http://localhost:11434",
        Keys.ollamaModel: "llama3.2:3b",
        Keys.apiBase: "https://api.openai.com",
        Keys.apiModel: "gpt-4o-mini",
        Keys.chatgptModel: "gpt-5.5",
        Keys.chatgptEffort: "low",
        Keys.defaultTone: "Clean",
        Keys.defaultCount: 3,
    ])
}

// MARK: - Mono palette (locked visual spec: zero hue, dark/light pair)

struct Pal {
    let surface: Color, surface2: Color, surface3: Color
    let line: Color, lineStrong: Color
    let text: Color, muted: Color, faint: Color
    let accent: Color, onAccent: Color

    static let dark = Pal(
        surface: Color(hex: 0x1C1C1C), surface2: Color(hex: 0x262626), surface3: Color(hex: 0x303030),
        line: Color.white.opacity(0.10), lineStrong: Color.white.opacity(0.20),
        text: Color(hex: 0xF2F2F2), muted: Color(hex: 0x9E9E9E), faint: Color(hex: 0x6E6E6E),
        accent: Color(hex: 0xF2F2F2), onAccent: Color(hex: 0x111111))

    static let light = Pal(
        surface: Color(hex: 0xFCFCFB), surface2: Color(hex: 0xF1F1EF), surface3: Color(hex: 0xE4E4E1),
        line: Color.black.opacity(0.09), lineStrong: Color.black.opacity(0.18),
        text: Color(hex: 0x1A1A18), muted: Color(hex: 0x5F5F5C), faint: Color(hex: 0x93938F),
        accent: Color(hex: 0x1A1A18), onAccent: Color(hex: 0xFCFCFB))

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

enum LLM {
    static func complete(system: String, user: String) async throws -> String {
        let d = defaults()
        let backend = d.string(forKey: Keys.backend) ?? "ollama"
        let raw: String
        switch backend {
        case "openai": raw = try await openAI(system: system, user: user)
        case "chatgpt": raw = try await chatGPT(system: system, user: user)
        default: raw = try await ollama(system: system, user: user)
        }
        return clean(raw)
    }

    private static func ollama(system: String, user: String) async throws -> String {
        let d = defaults()
        let base = d.string(forKey: Keys.ollamaURL) ?? "http://localhost:11434"
        guard let url = URL(string: base + "/api/chat") else { throw LLMError.badResponse("Bad Ollama URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = [
            "model": d.string(forKey: Keys.ollamaModel) ?? "llama3.2:3b",
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.badResponse("Ollama HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.badResponse("Ollama: unexpected response shape")
        }
        return content
    }

    private static func validEffort(_ e: String?) -> String {
        switch e { case "low", "medium", "high": return e! default: return "low" }
    }

    private static func openAI(system: String, user: String) async throws -> String {
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
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": d.string(forKey: Keys.apiModel) ?? "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // surface the server's error message, not just the status code
            var detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                detail = msg
            }
            if detail.count > 200 { detail = String(detail.prefix(200)) + "…" }
            throw LLMError.badResponse("API HTTP \(code): \(detail.isEmpty ? "no response body" : detail)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw LLMError.badResponse("API: unexpected response shape")
        }
        return content
    }

    // ChatGPT subscription via Codex CLI login (~/.codex/auth.json).
    // The codex backend only serves models it allows for ChatGPT accounts (gpt-5.5 as of 2026-07)
    // and only speaks SSE, so stream:true is mandatory.
    private static func chatGPT(system: String, user: String) async throws -> String {
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

        var out = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let data = line.dropFirst(6).data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                out += (ev["delta"] as? String) ?? ""
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

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // models sometimes wrap the rewrite in quotes
        if t.count > 1, (t.first == "\"" && t.last == "\"") || (t.first == "“" && t.last == "”") {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}

// MARK: - Model catalog

enum ModelCatalog {
    // probed 2026-07-09: allowed for ChatGPT-sub accounts; gpt-5.5-mini and the
    // -codex-mini variants are rejected with 400
    static let chatgpt = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]

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
        case "openai": return []
        default: return await ollama()
        }
    }

    static var currentModelKey: String {
        switch defaults().string(forKey: Keys.backend) ?? "ollama" {
        case "chatgpt": return Keys.chatgptModel
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

// MARK: - Session model

enum VariantState {
    case loading
    case done(String)
    case failed(String)
}

@MainActor
final class Session: ObservableObject {
    let original: String
    @Published var tone: String
    @Published var count: Int
    @Published var variants: [VariantState] = []
    @Published var selected: Int = 0
    @Published var refining: Bool = false

    private var tasks: [Task<Void, Never>] = []

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

    var selectedText: String? {
        guard selected < variants.count, case .done(let s) = variants[selected] else { return nil }
        return s
    }

    func generateAll() {
        cancelTasks()
        variants = Array(repeating: .loading, count: count)
        selected = 0
        for i in 0..<count {
            let prompt = Prompts.variant(text: original, tone: tone, index: i)
            tasks.append(Task { [weak self] in
                do {
                    let out = try await LLM.complete(system: Prompts.system, user: prompt)
                    guard !Task.isCancelled else { return }
                    self?.setVariant(i, .done(out))
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.setVariant(i, .failed(error.localizedDescription))
                }
            })
        }
    }

    func refineSelected(_ instruction: String) {
        let inst = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inst.isEmpty, let current = selectedText, !refining else { return }
        refining = true
        let i = selected
        tasks.append(Task { [weak self] in
            do {
                let out = try await LLM.complete(system: Prompts.system,
                                                 user: Prompts.refine(current: current, instruction: inst))
                guard !Task.isCancelled else { return }
                self?.setVariant(i, .done(out))
            } catch {
                guard !Task.isCancelled else { return }
                self?.setVariant(i, .failed(error.localizedDescription))
            }
            self?.refining = false
        })
    }

    private func setVariant(_ i: Int, _ state: VariantState) {
        if i < variants.count { variants[i] = state }
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

    private var pal: Pal { Pal.of(dark: scheme == .dark) }
    private let tones = ["Clean", "Professional", "Casual", "Blunt"]

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(pal.line)
            VStack(alignment: .leading, spacing: 12) {
                chipsRow
                sliderRow
                cards
                refineBar
            }
            .padding(14)
            Divider().overlay(pal.line)
            footer
        }
        .frame(width: 620, height: 500)
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
        }
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
        case .done(let s):
            VStack(alignment: .leading, spacing: 4) {
                Text(s).font(.system(size: 13)).foregroundColor(pal.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if session.variants.count > 1 {
                    Text(Prompts.styles[i % Prompts.styles.count].label)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(pal.faint)
                }
            }
        case .failed(let e):
            Text("⚠︎ \(e) — check Settings")
                .font(.system(size: 12)).foregroundColor(pal.muted)
        }
    }

    private var refineBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $refineText,
                      prompt: Text("tune it…").foregroundColor(pal.faint.opacity(0.7)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
    }

    private func submitRefine() {
        session.refineSelected(refineText)
        refineText = ""
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("⌘1–5 select · ⌘R regenerate · esc cancel")
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
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

// MARK: - Popup panel

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        AppDelegate.shared.closePopup()
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

struct SettingsView: View {
    @AppStorage(Keys.backend) private var backend = "ollama"
    @AppStorage(Keys.ollamaURL) private var ollamaURL = "http://localhost:11434"
    @AppStorage(Keys.ollamaModel) private var ollamaModel = "llama3.2:3b"
    @AppStorage(Keys.apiBase) private var apiBase = "https://api.openai.com"
    @AppStorage(Keys.apiKey) private var apiKey = ""
    @AppStorage(Keys.apiModel) private var apiModel = "gpt-4o-mini"
    @AppStorage(Keys.chatgptModel) private var chatgptModel = "gpt-5.5"
    @AppStorage(Keys.chatgptEffort) private var chatgptEffort = "low"
    @AppStorage(Keys.defaultTone) private var defaultTone = "Clean"
    @AppStorage(Keys.defaultCount) private var defaultCount = 3
    @State private var ollamaModels: [String] = []
    private let chatgptModels = ModelCatalog.chatgpt

    var body: some View {
        Form {
            Picker("Backend", selection: $backend) {
                Text("Ollama (local)").tag("ollama")
                Text("ChatGPT subscription (Codex login)").tag("chatgpt")
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
            Text("Trigger: select text anywhere, then ⌃⌘E — or right-click → Clean Up Message.")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 440)
        .task { ollamaModels = await ModelCatalog.ollama() }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var panel: PopupPanel?
    private var session: Session?
    private var settingsWindow: NSWindow?
    private var targetApp: NSRunningApplication?
    private var closingProgrammatically = false

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        registerDefaults()
        setupStatusBar()
        requestAccessibility()
        registerHotkey()
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
        menu.addItem(NSMenuItem(title: "Select text, then ⌃⌘E", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let test = NSMenuItem(title: "Test Popup", action: #selector(testPopup), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Cleanup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func testPopup() {
        showPopup(text: "hey can u send me the notes from todays lecture i missed it cuz my bus was late lol also did prof say anything abt the midterm format")
    }

    @objc private func openSettingsAction() { openSettings() }

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: hotkey (⌃⌘E)

    private func registerHotkey() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 14,  // E
                  event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.shift) else { return }
            DispatchQueue.main.async { self?.captureSelectionAndShow() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event
        }
    }

    // MARK: services (right-click → Clean Up Message)

    @objc func cleanUpMessage(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { self.showPopup(text: text) }
    }

    // MARK: selection capture (simulated ⌘C, clipboard restored)

    private func captureSelectionAndShow() {
        guard panel == nil else { return }
        targetApp = NSWorkspace.shared.frontmostApplication
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
            guard changed, let text = captured,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSSound.beep()
                return
            }
            self.showPopup(text: text)
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
        if targetApp == nil { targetApp = NSWorkspace.shared.frontmostApplication }
        let session = Session(original: text)
        self.session = session

        let p = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.contentView = NSHostingView(rootView: PopupView(session: session))

        // position near the mouse, clamped to the screen
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - 40, y: mouse.y - 510)
        if let vis = screen?.visibleFrame {
            origin.x = max(vis.minX + 8, min(origin.x, vis.maxX - 628))
            origin.y = max(vis.minY + 8, min(origin.y, vis.maxY - 508))
        }
        p.setFrameOrigin(origin)

        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePopup() {
        guard let p = panel else { return }
        closingProgrammatically = true
        session?.cancelTasks()
        session = nil
        p.orderOut(nil)
        panel = nil
        closingProgrammatically = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--test"),
              !closingProgrammatically,
              let w = notification.object as? NSWindow, w == panel else { return }
        // clicking away dismisses the popup
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
