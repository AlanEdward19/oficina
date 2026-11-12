import Foundation

struct TaskItem: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    var target: String
    var machine: String?
    var conversation: String?
    var agent: String?
    var model: String?
    var kind: String?
    var prompt: String?
    var status: String
    var output: String
    var url: String?
    var error: String?
    let createdAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id, text, target, machine, conversation, agent, model, kind, prompt, status, output, url, error
        case createdAt = "created_at"
    }

    var isActive: Bool { status == "queued" || status == "running" }
}

struct UsageLimit: Decodable, Equatable {
    let kind: String
    let scope: String?
    let percent: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case kind, scope, percent
        case resetsAt = "resets_at"
    }
}

struct ModelUsage: Decodable, Equatable {
    let model: String
    let tokens: UInt64
}

struct ProjectUse: Decodable, Equatable {
    let name: String
    let path: String
    let branch: String?
    let today: UInt64
    let week: UInt64
}

struct UsageData: Decodable, Equatable {
    let limits: [UsageLimit]
    let limitsNote: String?
    let today: UInt64
    let week: UInt64
    let models: [ModelUsage]
    let activeSessions: Int
    let projects: [ProjectUse]?

    enum CodingKeys: String, CodingKey {
        case limits, today, week, models, projects
        case limitsNote = "limits_note"
        case activeSessions = "active_sessions"
    }
}

struct ConversationItem: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let session: String?
    let agent: String?
    let team: String?
    let createdAt: UInt64
    let updatedAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id, title, session, agent, team
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct ConversationDetail: Decodable {
    let conversation: ConversationItem
    let tasks: [TaskItem]
}

private struct CoreEvent: Decodable {
    let kind: String
    let task: TaskItem?
    let id: String?
    let text: String?
    let usage: UsageData?
    let mind: MindBrief?
    let presence: PresenceData?
    let voice: VoiceJobData?
}

/// Fala com o `oficinad` e guarda o estado que as telas mostram.
@MainActor
final class Core: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var usage: UsageData?
    @Published private(set) var settings = AssistantSettings()
    @Published private(set) var agentNames: [String: String] = [:]
    @Published private(set) var conversations: [ConversationItem] = []
    /// Conversa aberta no chat (nil = nova, ainda sem mensagens).
    @Published private(set) var current: String? = UserDefaults.standard.string(forKey: "conversaAtual")
    /// Mensagens antigas da conversa aberta (as recentes vêm de `tasks`).
    @Published private(set) var history: [TaskItem] = []

    /// A conversa aberta: arquivo + o que está vivo, em ordem.
    var thread: [TaskItem] {
        guard let current else { return [] }
        let live = tasks.filter { $0.conversation == current }
        let ids = Set(live.map(\.id))
        return (history.filter { !ids.contains($0.id) } + live).sorted { $0.createdAt < $1.createdAt }
    }
    @Published private(set) var mind: MindBrief?
    /// Onde a Faísca está agora (uma só, em um lugar de cada vez).
    @Published private(set) var presence: PresenceData?
    /// Pedidos de voz para os dispositivos: o Mac sintetiza e transcreve.
    var onVoice: (VoiceJobData) -> Void = { _ in }
    @Published private(set) var connected = false
    @Published private(set) var problem: String?

    private let base = URL(string: "http://127.0.0.1:7878/v1/")!
    private let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Oficina")
    private var token = ""
    /// Sessão própria, sem cache HTTP: tudo aqui é local e muda o tempo todo.
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()
    private var daemon: Process?

    func start() {
        Task { await run() }
    }

    func stop() {
        daemon?.terminate()
    }

    private func run() async {
        await ensureDaemon()
        while !Task.isCancelled {
            do {
                token = try String(contentsOf: home.appendingPathComponent("token"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try await refresh()
                connected = true
                problem = nil
                loadUsage(fresh: false)
                loadConversations()
                loadSettings()
                _ = await loadFactory()
                presence = await get("presence")
                if let s = await mindSnapshot() {
                    mind = MindBrief(mood: s.mood, sleeping: s.sleeping, thought: s.thought, initiative: s.initiative, outfit: s.outfit, decor: s.decor, call: s.context?.call)
                }
                try await listen()
            } catch {
                problem = "Sem contato com o core."
            }
            connected = false
            try? await Task.sleep(for: .seconds(2))
            await ensureDaemon()
        }
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Reaproveita um core já de pé; senão, sobe o que vem dentro do app.
    private func ensureDaemon() async {
        if await healthy() { return }
        if daemon?.isRunning == true { return }
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "oficinad") else {
            problem = "oficinad não encontrado no app."
            return
        }
        let p = Process()
        p.executableURL = url
        do {
            try p.run()
            daemon = p
        } catch {
            problem = "Não consegui iniciar o core."
            return
        }
        for _ in 0..<20 {
            if await healthy() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Operações de disco podem levar minutos: tempo maior que o padrão.
    func get<T: Decodable>(_ path: String) async -> T? {
        var req = request(path)
        req.timeoutInterval = 600
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, _ body: [String: Any]) async -> T? {
        var req = request(path, method: "POST")
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode ?? 500 < 300 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func refresh() async throws {
        let (data, resp) = try await session.data(for: request("tasks"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        tasks = try JSONDecoder().decode([TaskItem].self, from: data)
    }

    private func listen() async throws {
        var req = request("events")
        req.timeoutInterval = .infinity
        let (bytes, _) = try await session.bytes(for: req)
        let decoder = JSONDecoder()
        for try await line in bytes.lines where line.hasPrefix("data:") {
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let ev = try? decoder.decode(CoreEvent.self, from: Data(json.utf8)) else { continue }
            apply(ev)
        }
    }

    private func apply(_ ev: CoreEvent) {
        switch ev.kind {
        case "task":
            guard let t = ev.task else { return }
            if let i = tasks.firstIndex(where: { $0.id == t.id }) {
                tasks[i] = t
            } else {
                tasks.append(t)
                // Mensagem nova (inclusive da própria Faísca): a lista se reordena.
                loadConversations()
            }
        case "usage":
            if let u = ev.usage { usage = u }
        case "mind":
            if let m = ev.mind { mind = m }
        case "presence":
            if let p = ev.presence { presence = p }
        case "voice":
            if let v = ev.voice { onVoice(v) }
        case "delta":
            guard let id = ev.id, let text = ev.text,
                  let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].output += text
        default:
            Task { try? await refresh() }
        }
    }

    func send(_ text: String, target: String) {
        var req = request("messages", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": text, "target": target]
        if let current { body["conversation"] = current }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task {
            do {
                let (data, resp) = try await session.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 201 else {
                    problem = "O core recusou a mensagem."
                    return
                }
                // Primeira mensagem de uma conversa nova: o core criou a conversa.
                if let t = try? JSONDecoder().decode(TaskItem.self, from: data), let conv = t.conversation, conv != current {
                    setCurrent(conv)
                }
                loadConversations()
            } catch {
                problem = "Sem contato com o core."
            }
        }
    }

    // MARK: Ajustes e fábrica

    func loadSettings() {
        Task {
            guard let (data, _) = try? await session.data(for: request("settings")),
                  let s = try? JSONDecoder().decode(AssistantSettings.self, from: data) else { return }
            settings = s
        }
    }

    func saveSettings(_ s: AssistantSettings) {
        var req = request("settings", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(s)
        Task {
            guard let (data, _) = try? await session.data(for: req),
                  let saved = try? JSONDecoder().decode(AssistantSettings.self, from: data) else { return }
            settings = saved
        }
    }

    func loadFactory() async -> FactoryState? {
        guard let (data, _) = try? await session.data(for: request("factory")),
              let s = try? JSONDecoder().decode(FactoryState.self, from: data) else { return nil }
        agentNames = Dictionary(uniqueKeysWithValues: s.agents.map { ($0.id, $0.name) })
        return s
    }

    /// Devolve o erro em texto, ou nil se deu certo.
    func factoryPost(_ path: String, _ body: [String: Any]) async -> String? {
        var req = request(path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else {
            return "Sem contato com o core."
        }
        loadConversations()
        return code < 300 ? nil : String(decoding: data, as: UTF8.self)
    }

    func factoryDelete(_ path: String) async {
        _ = try? await session.data(for: request(path, method: "DELETE"))
        loadConversations()
    }

    // MARK: Conversas

    private func setCurrent(_ id: String?) {
        current = id
        UserDefaults.standard.set(id, forKey: "conversaAtual")
    }

    func loadConversations() {
        Task {
            guard let (data, _) = try? await session.data(for: request("conversations")),
                  let list = try? JSONDecoder().decode([ConversationItem].self, from: data) else { return }
            conversations = list
            if let c = current, !list.contains(where: { $0.id == c }) {
                setCurrent(nil)
                history = []
            } else if history.isEmpty, let c = current {
                loadHistory(c)
            }
        }
    }

    private func loadHistory(_ id: String) {
        Task {
            guard let (data, _) = try? await session.data(for: request("conversations/\(id)")),
                  let d = try? JSONDecoder().decode(ConversationDetail.self, from: data), current == id else { return }
            history = d.tasks
        }
    }

    func select(_ id: String) {
        guard id != current else { return }
        setCurrent(id)
        history = []
        loadHistory(id)
    }

    /// Começa uma conversa nova; ela passa a existir com a primeira mensagem.
    func newConversation() {
        setCurrent(nil)
        history = []
    }

    func renameConversation(_ id: String, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Task {
            _ = await post("conversations/\(id)/rename", json: ["title": t])
            loadConversations()
        }
    }

    func deleteConversation(_ id: String) {
        var req = request("conversations/\(id)", method: "DELETE")
        req.timeoutInterval = 10
        Task {
            _ = try? await session.data(for: req)
            if current == id { newConversation() }
            loadConversations()
        }
    }

    /// Devolve o que o core já sabe; o valor novo chega depois pelo evento.
    func loadUsage(fresh: Bool) {
        let req = fresh ? request("usage/refresh", method: "POST") : request("usage")
        Task {
            guard let (data, _) = try? await session.data(for: req),
                  let u = try? JSONDecoder().decode(UsageData.self, from: data) else { return }
            // Antes da primeira leitura o core responde vazio; não apaga nada.
            if usage == nil || !u.models.isEmpty || !u.limits.isEmpty { usage = u }
        }
    }

    // MARK: Mente

    private func post(_ path: String, json: Any? = nil) async -> Data? {
        var req = request(path, method: "POST")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        guard let (data, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, code < 300 else { return nil }
        return data
    }

    /// Conta à mente o que aconteceu (app em foco, presença, gestos no pet).
    func mindEvents(_ events: [[String: Any]]) {
        guard connected, !events.isEmpty else { return }
        Task { _ = await post("mind/events", json: events) }
    }

    func mindSnapshot() async -> MindSnapshot? {
        guard let (data, _) = try? await session.data(for: request("mind")) else { return nil }
        return try? JSONDecoder().decode(MindSnapshot.self, from: data)
    }

    func suggest() {
        Task { _ = await post("mind/suggest") }
    }

    func answer(_ id: String, accept: Bool) async -> InitiativeData? {
        let data = await post("mind/initiatives/\(id)/\(accept ? "accept" : "decline")")
        return data.flatMap { try? JSONDecoder().decode(InitiativeData.self, from: $0) }
    }

    func forgetMind() {
        Task { _ = await post("mind/forget") }
    }

    /// Pedido de melhoria: vira uma issue no GitHub (e, se quiser, um agente).
    func sendRequest(kind: String, text: String, agent: Bool) {
        Task { _ = await post("requests", json: ["kind": kind, "text": text, "agent": agent]) }
    }

    func createDecor(suggestion: String?) {
        Task { _ = await post("mind/decor", json: ["suggestion": suggestion as Any]) }
    }

    func useDecor(_ id: String?) {
        Task { _ = await post("mind/decor/use", json: ["id": id as Any]) }
    }

    func wear(_ id: String?) {
        Task { _ = await post("mind/outfit", json: ["id": id as Any]) }
    }

    func act(_ id: String, _ action: String) {
        let req = request("tasks/\(id)/\(action)", method: "POST")
        Task { _ = try? await session.data(for: req) }
    }

    /// "Nunca no Zoom": recusa e não pergunta mais nesse app.
    func never(_ id: String) {
        Task { _ = await post("mind/initiatives/\(id)/never") }
    }

    // MARK: Presença e dispositivos

    /// Você chamou: ela pesa a conversa de lá; `force` sempre traz.
    func callPresence(force: Bool) async -> CallResult? {
        let data = await post("presence/call", json: ["force": force])
        return data.flatMap { try? JSONDecoder().decode(CallResult.self, from: $0) }
    }

    /// Leva a Faísca até um dispositivo ("casa" é o Mac).
    func movePresence(to: String, text: String = "") async -> String? {
        await factoryPost("presence/move", ["to": to, "text": text])
    }

    func startPairing() async -> PairingData? {
        let data = await post("bodies/pairing")
        return data.flatMap { try? JSONDecoder().decode(PairingData.self, from: $0) }
    }

    func setDeviceNetwork(_ on: Bool) async -> String? {
        await factoryPost("bodies/network", ["on": on])
    }

    func forgetDevice(_ id: String) async {
        await factoryDelete("bodies/\(id)")
    }

    func voiceClip(_ id: String) async -> Data? {
        guard let (data, resp) = try? await session.data(for: request("voice/\(id)")),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    func uploadVoice(_ id: String, wav: Data) async {
        var req = request("voice/\(id)", method: "POST")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = wav
        _ = try? await session.data(for: req)
    }

    func voiceText(_ id: String, _ text: String) async {
        _ = await post("voice/\(id)/text", json: ["text": text])
    }

    // MARK: Reuniões

    func startMeeting(app: String, title: String) async -> String? {
        let data = await post("meetings", json: ["app": app, "title": title])
        return data.flatMap { try? JSONDecoder().decode(MeetingData.self, from: $0) }?.id
    }

    func appendMeeting(_ id: String, _ segments: [[String: Any]]) {
        guard !segments.isEmpty else { return }
        Task { _ = await post("meetings/\(id)/segments", json: segments) }
    }

    func endMeeting(_ id: String) {
        Task { _ = await post("meetings/\(id)/end") }
    }

    func meetings() async -> [MeetingItem] {
        await get("meetings") ?? []
    }

    func meeting(_ id: String) async -> MeetingData? {
        await get("meetings/\(id)")
    }

    /// Gasta tokens: quem chama já perguntou.
    func summarizeMeeting(_ id: String) async -> Bool {
        await post("meetings/\(id)/summarize") != nil
    }

    func deleteMeeting(_ id: String) async {
        _ = try? await session.data(for: request("meetings/\(id)", method: "DELETE"))
    }

    // MARK: Oficina de hardware

    func hardware() async -> HardwareOverview? {
        await get("hardware")
    }

    func hardwareProject(_ id: String) async -> HardwareProject? {
        await get("hardware/\(id)")
    }

    /// Devolve o erro em texto, ou nil se deu certo.
    func createHardware(name: String, idea: String) async -> String? {
        await factoryPost("hardware", ["name": name, "idea": idea])
    }

    func runHardware(_ id: String, _ what: String) async -> HardwareRun? {
        let data = await post("hardware/\(id)/run/\(what)")
        return data.flatMap { try? JSONDecoder().decode(HardwareRun.self, from: $0) }
    }

    func hardwareDiagram(_ id: String) async -> BlockDiagram? {
        await get("hardware/\(id)/diagram")
    }

    func setupHardware() {
        Task { _ = await post("hardware/setup") }
    }

    func deleteHardware(_ id: String) async {
        await factoryDelete("hardware/\(id)")
    }
}
