import AppKit
import SwiftUI

// MARK: Modelos

struct AssistantSettings: Codable, Equatable {
    var name = "Faísca"
    var personality = "Curta, direta e carinhosa."
    var brain_model = "haiku"
    var brain_effort = ""
    var body_color = "#FF9E29"
    var spark_color = "#FFD60A"
    var eyes = "tall"
    var antenna = true
    var size = 1.0
}

struct MissionLog: Decodable, Equatable {
    let stage: String
    let verdict: String
    let evidence: [String]
}

struct MissionItem: Decodable, Equatable {
    let goal: String
    let stage: Int
    let status: String
    let log: [MissionLog]
}

struct AgentItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let model: String
    let effort: String
    let place: String
    let project: String?
    let team: String?
    let conversation: String
    let mission: MissionItem?
    let status: String?
}

struct TeamItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let conversation: String
}

struct FactoryState: Decodable, Equatable {
    var agents: [AgentItem] = []
    var teams: [TeamItem] = []
}

let brainModels = ["haiku", "sonnet", "opus", "fable"]
let effortLevels = ["low", "medium", "high", "xhigh", "max"]
private let effortNames = ["low": "Baixo", "medium": "Médio", "high": "Alto", "xhigh": "Muito alto", "max": "Máximo"]

func colorFromHex(_ hex: String) -> Color {
    var v: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

private func hexFromColor(_ c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .orange
    return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
}

// MARK: Personalizar

struct PersonalizeView: View {
    @ObservedObject var core: Core
    @State private var s = AssistantSettings()
    @State private var saved = false

    private let presets: [(String, String)] = [
        ("Carinhosa", "Curta, direta e carinhosa."),
        ("Engraçada", "Bem-humorada, faz piadas leves, mas resolve o que foi pedido."),
        ("Séria", "Formal, objetiva e sem brincadeiras."),
        ("Mentora", "Paciente, explica o porquê das coisas e sugere próximos passos."),
    ]

    var body: some View {
        Form {
            Section("Identidade") {
                HStack(spacing: 14) {
                    FaiscaAvatar(size: 54, mood: .idle, body: colorFromHex(s.body_color), spark: s.antenna ? colorFromHex(s.spark_color) : .clear)
                    TextField("Nome", text: $s.name)
                }
                Picker("Jeito de falar", selection: Binding(
                    get: { presets.first { $0.1 == s.personality }?.1 ?? "" },
                    set: { if !$0.isEmpty { s.personality = $0 } }
                )) {
                    ForEach(presets, id: \.1) { Text($0.0).tag($0.1) }
                    Text("Personalizado").tag("")
                }
                TextField("Personalidade", text: $s.personality, axis: .vertical).lineLimit(2...5)
            }
            Section("Cérebro") {
                Picker("Modelo", selection: $s.brain_model) {
                    ForEach(brainModels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Esforço", selection: $s.brain_effort) {
                    Text("Padrão").tag("")
                    ForEach(effortLevels, id: \.self) { Text(effortNames[$0] ?? $0).tag($0) }
                }
                Text("Modelos maiores pensam melhor e gastam mais da sua cota.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Aparência") {
                ColorPicker("Corpo", selection: Binding(get: { colorFromHex(s.body_color) }, set: { s.body_color = hexFromColor($0) }), supportsOpacity: false)
                ColorPicker("Antena", selection: Binding(get: { colorFromHex(s.spark_color) }, set: { s.spark_color = hexFromColor($0) }), supportsOpacity: false)
                Picker("Olhos", selection: $s.eyes) {
                    Text("Compridos").tag("tall")
                    Text("Redondos").tag("round")
                    Text("Pontinhos").tag("dots")
                }
                .pickerStyle(.segmented)
                Toggle("Antena", isOn: $s.antenna)
                HStack {
                    Text("Tamanho")
                    Slider(value: $s.size, in: 0.7...1.4)
                }
            }
            HStack {
                if saved { Label("Salvo", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Button("Salvar") {
                    core.saveSettings(s)
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)
        .onAppear { s = core.settings }
        .onChange(of: s) { saved = false }
    }
}

// MARK: Fábrica

struct FactoryView: View {
    @ObservedObject var core: Core
    let openConversation: (String) -> Void
    @State private var state = FactoryState()
    @State private var creating = false
    @State private var name = ""
    @State private var role = ""
    @State private var model = "sonnet"
    @State private var effort = "medium"
    @State private var place = "mac"
    @State private var project = ""
    @State private var teamName = ""
    @State private var missionFor: AgentItem?
    @State private var goal = ""
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Agentes").font(.title3.weight(.semibold))
                    Spacer()
                    Button(creating ? "Fechar" : "Novo agente") { creating.toggle() }
                }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                if creating { form }
                if state.agents.isEmpty && !creating {
                    Text("Nenhum agente ainda. Crie um aqui ou peça no chat.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(state.agents) { agentCard($0) }
                Divider()
                Text("Equipes").font(.title3.weight(.semibold))
                Text("Num canal de equipe, escreva @Nome para chamar um agente. Eles também chamam uns aos outros.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(state.teams) { team in
                    HStack {
                        Image(systemName: "number")
                        Text(team.name)
                        Text(members(team)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Abrir canal") { openConversation(team.conversation) }
                        Button("Apagar", role: .destructive) { Task { await core.factoryDelete("teams/\(team.id)"); await refresh() } }
                    }
                    .controlSize(.small)
                }
                HStack {
                    TextField("Nome da nova equipe", text: $teamName).textFieldStyle(.roundedBorder)
                    Button("Criar equipe") {
                        let n = teamName
                        teamName = ""
                        Task { problem = await core.factoryPost("teams", ["name": n, "members": []]); await refresh() }
                    }
                    .disabled(teamName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(18)
        }
        .frame(width: 620, height: 640)
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $missionFor) { agent in
            VStack(alignment: .leading, spacing: 10) {
                Text("Missão para \(agent.name)").font(.headline)
                Text("Investigar → Propor → Executar (com sua aprovação) → Verificar. Cada etapa precisa citar evidência.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Objetivo", text: $goal, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancelar") { missionFor = nil }
                    Button("Iniciar") {
                        let g = goal
                        goal = ""
                        missionFor = nil
                        Task { problem = await core.factoryPost("agents/\(agent.id)/missions", ["goal": g]); await refresh() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(18)
            .frame(width: 420)
        }
    }

    private func refresh() async {
        if let s = await core.loadFactory() { state = s }
    }

    private func members(_ team: TeamItem) -> String {
        state.agents.filter { $0.team == team.id }.map(\.name).joined(separator: ", ")
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Nome (ex.: Revisora)", text: $name).textFieldStyle(.roundedBorder)
            TextField("Papel: o que este agente faz", text: $role, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Modelo", selection: $model) { ForEach(brainModels, id: \.self) { Text($0.capitalized).tag($0) } }
                Picker("Esforço", selection: $effort) { ForEach(effortLevels, id: \.self) { Text(effortNames[$0] ?? $0).tag($0) } }
            }
            HStack {
                Picker("Onde roda", selection: $place) {
                    Text("Este Mac").tag("mac")
                    Text("Nuvem").tag("nuvem")
                }
                Picker("Projeto", selection: $project) {
                    Text("Nenhum").tag("")
                    ForEach(core.usage?.projects ?? [], id: \.path) { Text($0.name).tag($0.path) }
                }
            }
            HStack {
                Spacer()
                Button("Criar agente") {
                    let body: [String: Any] = ["name": name, "role": role, "model": model, "effort": effort, "place": place, "project": project]
                    Task {
                        problem = await core.factoryPost("agents", body)
                        if problem == nil {
                            name = ""
                            role = ""
                            creating = false
                        }
                        await refresh()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || role.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func agentCard(_ a: AgentItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(statusColor(a.status)).frame(width: 9, height: 9).accessibilityHidden(true)
                Text(a.name).font(.headline)
                Text(statusName(a.status)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(a.model.capitalized) · \(effortNames[a.effort] ?? a.effort) · \(a.place == "nuvem" ? "Nuvem" : "Este Mac")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(a.role).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            if let p = a.project { Label(p.components(separatedBy: "/").last ?? p, systemImage: "folder").font(.caption) }
            if let m = a.mission { missionView(m) }
            HStack {
                Button("Conversar") { openConversation(a.conversation) }
                Button("Missão…") { missionFor = a }
                Picker("Equipe", selection: Binding(
                    get: { a.team ?? "" },
                    set: { new in Task { _ = await core.factoryPost("agents/\(a.id)/team", ["team": new.isEmpty ? NSNull() : new]); await refresh() } }
                )) {
                    Text("Sem equipe").tag("")
                    ForEach(state.teams) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 170)
                Spacer()
                Button("Apagar", role: .destructive) { Task { await core.factoryDelete("agents/\(a.id)"); await refresh() } }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func missionView(_ m: MissionItem) -> some View {
        let stages = ["Investigar", "Propor", "Executar", "Verificar"]
        return VStack(alignment: .leading, spacing: 4) {
            Text("Missão: \(m.goal)").font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 4) {
                ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                    Text(s)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stageColor(i, m).opacity(0.3), in: Capsule())
                }
                Text(missionName(m.status)).font(.caption).foregroundStyle(.secondary)
            }
            if let last = m.log.last, let e = last.evidence.first {
                Text("Evidência: \(e)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if m.log.last?.verdict == "sem-evidencia" {
                Text("Parou: a etapa não citou evidência.").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private func stageColor(_ i: Int, _ m: MissionItem) -> Color {
        if i < m.stage { return .green }
        if i == m.stage { return m.status == "rodando" ? .cyan : m.status == "aguardando" ? .yellow : m.status == "concluida" ? .green : .red }
        return .gray
    }

    private func missionName(_ s: String) -> String {
        ["rodando": "Em andamento", "aguardando": "Aguardando sua aprovação no chat", "concluida": "Concluída",
         "bloqueada": "Bloqueada", "falhou": "Falhou", "cancelada": "Cancelada"][s] ?? s
    }

    private func statusColor(_ s: String?) -> Color {
        switch s {
        case "trabalhando": return .cyan
        case "aguardando": return .yellow
        case "erro": return .red
        default: return .green
        }
    }

    private func statusName(_ s: String?) -> String {
        ["trabalhando": "trabalhando", "aguardando": "aguardando você", "erro": "com erro"][s ?? ""] ?? "livre"
    }
}
