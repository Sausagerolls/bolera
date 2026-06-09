import Foundation
import Combine

/// The result the mood-mix pipeline needs from ANY analyzer (on-device or
/// remote): a few Last.fm-style tags, an optional decade, and a playlist name.
/// Mirrors the on-device `MoodAnalysis` so the generator maps 1:1.
public struct RemoteMoodAnalysis: Sendable {
    public let tags: [String]
    public let decade: String
    public let mood: String
    public init(tags: [String], decade: String, mood: String) {
        self.tags = tags; self.decade = decade; self.mood = mood
    }
}

/// A curated provider preset. Every preset speaks the OpenAI-compatible
/// `/chat/completions` contract (OpenAI, OpenRouter, Groq, and self-hosted
/// Ollama / LM Studio / llama.cpp / LocalAI all expose it), so a single
/// transport serves them all — the preset just supplies sensible defaults.
public struct AIProviderPreset: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let defaultBaseURL: String
    public let defaultModel: String
    /// Cloud providers need an API key; self-hosted ones usually don't.
    public let requiresKey: Bool
    /// Self-hosted on the user's own network (an http LAN address is expected).
    public let isLocal: Bool
    public let helpURL: String?
}

public enum AIProviders {
    public static let all: [AIProviderPreset] = [
        .init(id: "openai",     name: "OpenAI",                defaultBaseURL: "https://api.openai.com/v1",     defaultModel: "gpt-4o-mini",               requiresKey: true,  isLocal: false, helpURL: "https://platform.openai.com/api-keys"),
        .init(id: "openrouter", name: "OpenRouter",            defaultBaseURL: "https://openrouter.ai/api/v1",  defaultModel: "openai/gpt-4o-mini",        requiresKey: true,  isLocal: false, helpURL: "https://openrouter.ai/keys"),
        .init(id: "groq",       name: "Groq",                  defaultBaseURL: "https://api.groq.com/openai/v1",defaultModel: "llama-3.3-70b-versatile",   requiresKey: true,  isLocal: false, helpURL: "https://console.groq.com/keys"),
        .init(id: "ollama",     name: "Ollama (self-hosted)",  defaultBaseURL: "http://localhost:11434/v1",     defaultModel: "llama3.1",                  requiresKey: false, isLocal: true,  helpURL: "https://ollama.com"),
        .init(id: "lmstudio",   name: "LM Studio (self-hosted)",defaultBaseURL: "http://localhost:1234/v1",     defaultModel: "local-model",               requiresKey: false, isLocal: true,  helpURL: "https://lmstudio.ai"),
        .init(id: "custom",     name: "Custom (OpenAI-compatible)", defaultBaseURL: "",                         defaultModel: "",                          requiresKey: false, isLocal: false, helpURL: nil),
    ]
    public static func preset(_ id: String) -> AIProviderPreset { all.first { $0.id == id } ?? all[0] }
}

public enum CustomAIError: LocalizedError {
    case notConfigured
    case consentRequired
    case badURL
    case network(String)
    case server(Int, String)
    case parse(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .notConfigured:    return "Custom AI isn't fully configured. Add a server URL and model in Settings."
        case .consentRequired:  return "Allow sending your mood text to your AI server in Settings → AI Features first."
        case .badURL:           return "The AI server URL isn't valid."
        case .network(let m):   return "Couldn't reach the AI server: \(m)"
        case .server(let c, let b): return "AI server returned \(c). \(b)"
        case .parse(let m):     return "Couldn't read the AI server's reply: \(m)"
        case .emptyResult:      return "The AI server didn't return any usable tags."
        }
    }
}

/// User-configured, opt-in alternative to the on-device model for Make-a-Mix.
/// Holds the (Pro-gated) config, the explicit data-sharing consent state, and
/// the OpenAI-compatible call. The API key lives in the Keychain; everything
/// else is small config in UserDefaults.
///
/// COMPLIANCE (App Store 5.1.2(i) — disclosing data shared with third-party
/// AI): `isActive` is true only when the user has both enabled a custom server
/// AND granted consent for the EXACT endpoint host currently configured. The
/// generator must never call `analyze` unless `isActive` is true; changing the
/// host revokes consent until re-granted. Only the typed mood phrase is sent —
/// never the library, account, or tokens.
@MainActor
public final class CustomAIStore: ObservableObject {
    public static let shared = CustomAIStore()

    private enum Keys {
        static let enabled  = "bolera.ai.custom.enabled"
        static let provider = "bolera.ai.custom.provider"
        static let baseURL  = "bolera.ai.custom.baseURL"
        static let model    = "bolera.ai.custom.model"
        static let consent  = "bolera.ai.custom.consentHost"   // host the user consented to
        static let keychain = "ai.custom.apiKey"
    }

    @Published public var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }
    @Published public var providerId: String {
        didSet {
            UserDefaults.standard.set(providerId, forKey: Keys.provider)
            // Switching provider fills in that preset's sensible defaults.
            let p = preset
            baseURL = p.defaultBaseURL
            model = p.defaultModel
        }
    }
    @Published public var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }
    @Published public var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }
    /// Bound to a SecureField; persisted to the Keychain (never UserDefaults).
    @Published public var apiKey: String {
        didSet {
            if apiKey.isEmpty { Keychain.delete(Keys.keychain) }
            else { Keychain.set(apiKey, for: Keys.keychain) }
        }
    }
    /// The endpoint host the user has explicitly consented to share data with.
    @Published public private(set) var consentedHost: String?

    public init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        providerId = d.string(forKey: Keys.provider) ?? "openai"
        let preset = AIProviders.preset(d.string(forKey: Keys.provider) ?? "openai")
        baseURL = d.string(forKey: Keys.baseURL) ?? preset.defaultBaseURL
        model = d.string(forKey: Keys.model) ?? preset.defaultModel
        apiKey = Keychain.get(Keys.keychain) ?? ""
        consentedHost = d.string(forKey: Keys.consent)
    }

    public var preset: AIProviderPreset { AIProviders.preset(providerId) }

    /// Host extracted from the configured base URL — the unit of consent.
    public var endpointHost: String {
        URLComponents(string: baseURL)?.host ?? ""
    }

    public var isConfigured: Bool {
        guard let url = URLComponents(string: baseURL), url.host?.isEmpty == false,
              !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if preset.requiresKey && apiKey.isEmpty { return false }
        return true
    }

    /// True only when the user has consented to the CURRENTLY configured host.
    public var consentGranted: Bool {
        guard let c = consentedHost, !c.isEmpty else { return false }
        return c == endpointHost
    }

    /// The generator gate: enabled + fully configured + consent for this host.
    public var isActive: Bool { enabled && isConfigured && consentGranted }

    /// Record explicit consent for the current endpoint host (call from the UI's
    /// consent confirmation). No-op if not configured.
    public func grantConsent() {
        guard !endpointHost.isEmpty else { return }
        consentedHost = endpointHost
        UserDefaults.standard.set(endpointHost, forKey: Keys.consent)
    }

    public func revokeConsent() {
        consentedHost = nil
        UserDefaults.standard.removeObject(forKey: Keys.consent)
    }

    // MARK: - Inference

    private static let systemPrompt = """
    You translate a user's mood phrase into music metadata to build a playlist.
    Respond with ONLY a JSON object — no prose, no markdown fences — in exactly this shape:
    {"tags": ["genre1","genre2","mood1"], "decade": "80s", "mood": "Playlist Name"}
    Rules:
    - tags: 4 to 5 lowercase Last.fm-style tags. The FIRST 2+ MUST be specific MUSIC GENRES (e.g. indie pop, folk, soul, jazz, rock, hip hop, r&b, electronic, synthwave, pop, country), then 1-3 mood/descriptor adjectives (e.g. chill, melancholic, driving, upbeat, energetic). Avoid obscure or compound tags.
    - decade: one of "70s","80s","90s","00s","10s","20s", or "" if the mood suggests none.
    - mood: a short 2-4 word Title Case playlist name.
    """

    /// Run the mood phrase through the configured OpenAI-compatible endpoint.
    /// Throws `CustomAIError`. Sends ONLY the mood phrase.
    public func analyze(prompt: String) async throws -> RemoteMoodAnalysis {
        guard isConfigured else { throw CustomAIError.notConfigured }
        guard consentGranted else { throw CustomAIError.consentRequired }
        return try await Self.run(prompt: prompt, baseURL: baseURL, model: model,
                                  apiKey: apiKey, requiresKey: preset.requiresKey)
    }

    /// Configuration-only round trip for the "Test" button — bypasses the
    /// consent gate (the user is actively setting it up and pressed Test).
    public func test(prompt: String = "happy summer drive with the windows down") async throws -> RemoteMoodAnalysis {
        guard isConfigured else { throw CustomAIError.notConfigured }
        return try await Self.run(prompt: prompt, baseURL: baseURL, model: model,
                                  apiKey: apiKey, requiresKey: preset.requiresKey)
    }

    private static func run(prompt: String, baseURL: String, model: String,
                            apiKey: String, requiresKey: Bool) async throws -> RemoteMoodAnalysis {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + "/chat/completions") else { throw CustomAIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if requiresKey || !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.7,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Mood phrase: \(prompt)"]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw CustomAIError.network(error.localizedDescription) }

        guard let http = resp as? HTTPURLResponse else { throw CustomAIError.network("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw CustomAIError.server(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        let content = try extractMessageContent(data)
        return try parseAnalysis(content)
    }

    /// Pull `choices[0].message.content` out of an OpenAI-compatible response.
    private static func extractMessageContent(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CustomAIError.parse("unexpected response shape")
        }
        return content
    }

    /// Tolerantly parse the model's JSON (some local models wrap it in prose or
    /// ```json fences) by scanning for the outermost { ... } object.
    private static func parseAnalysis(_ content: String) throws -> RemoteMoodAnalysis {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start < end else {
            throw CustomAIError.parse("no JSON object found")
        }
        let json = String(content[start...end])
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw CustomAIError.parse("invalid JSON")
        }
        let tags = (obj["tags"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty } ?? []
        guard !tags.isEmpty else { throw CustomAIError.emptyResult }
        let decade = (obj["decade"] as? String) ?? ""
        let mood = ((obj["mood"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteMoodAnalysis(tags: tags, decade: decade, mood: mood.isEmpty ? "Mood Mix" : mood)
    }
}
