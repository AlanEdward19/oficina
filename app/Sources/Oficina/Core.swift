import Foundation

struct TaskItem: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    var target: String
    var machine: String?
    var kind: String?
    var prompt: String?
    var status: String
    var output: String
    var url: String?
    var error: String?
    let createdAt: UInt64

    enum CodingKeys: String, CodingKey {
        case id, text, target, machine, kind, prompt, status, output, url, error
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

struct UsageData: Decodable, Equatable {
    let limits: [UsageLimit]
    let limitsNote: String?
    let today: UInt64
    let week: UInt64
    let models: [ModelUsage]
    let activeSessions: Int

    enum CodingKeys: String, CodingKey {
        case limits, today, week, models
        case limitsNote = "limits_note"
        case activeSessions = "active_sessions"
    }
}

private struct CoreEvent: Decodable {
    let kind: String
    let task: TaskItem?
    let id: String?
    let text: String?
    let usage: UsageData?
    let mind: MindBrief?
}

/// Fala com o `oficinad` e guarda o estado que as telas mostram.
@MainActor
final class Core: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var usage: UsageData?
    @Published private(set) var mind: MindBrief?
    @Published private(set) var connected = false
    @Published private(set) var problem: String?

    private let base = URL(string: "http://127.0.0.1:7878/v1/")!
    private let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Oficina")
    private var token = ""
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
                if let s = await mindSnapshot() {
                    mind = MindBrief(mood: s.mood, sleeping: s.sleeping, thought: s.thought, initiative: s.initiative, outfit: s.outfit, decor: s.decor)
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
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
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

    private func refresh() async throws {
        let (data, resp) = try await URLSession.shared.data(for: request("tasks"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        tasks = try JSONDecoder().decode([TaskItem].self, from: data)
    }

    private func listen() async throws {
        var req = request("events")
        req.timeoutInterval = .infinity
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
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
            }
        case "usage":
            if let u = ev.usage { usage = u }
        case "mind":
            if let m = ev.mind { mind = m }
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
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "target": target])
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode != 201 { problem = "O core recusou a mensagem." }
            } catch {
                problem = "Sem contato com o core."
            }
        }
    }

    /// Devolve o que o core já sabe; o valor novo chega depois pelo evento.
    func loadUsage(fresh: Bool) {
        let req = fresh ? request("usage/refresh", method: "POST") : request("usage")
        Task {
            guard let (data, _) = try? await URLSession.shared.data(for: req),
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
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, code < 300 else { return nil }
        return data
    }

    /// Conta à mente o que aconteceu (app em foco, presença, gestos no pet).
    func mindEvents(_ events: [[String: Any]]) {
        guard connected, !events.isEmpty else { return }
        Task { _ = await post("mind/events", json: events) }
    }

    func mindSnapshot() async -> MindSnapshot? {
        guard let (data, _) = try? await URLSession.shared.data(for: request("mind")) else { return nil }
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

    /// A próxima mensagem começa uma conversa nova no cérebro.
    func resetBrain() {
        let req = request("brain/reset", method: "POST")
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    func act(_ id: String, _ action: String) {
        let req = request("tasks/\(id)/\(action)", method: "POST")
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}
