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
    var router: RouterStats?
}

struct RouterStats: Decodable, Equatable {
    let haiku: Int
    let sonnet: Int
    let opus: Int
    let escalations: Int
    let learned: Int
}

let effortLevels = ["low", "medium", "high", "xhigh", "max"]
private let effortNames = ["auto": "Automático", "low": "Baixo", "medium": "Médio", "high": "Alto", "xhigh": "Muito alto", "max": "Máximo"]

func colorFromHex(_ hex: String) -> Color {
    var v: UInt64 = 0
    Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

func hexFromColor(_ c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB) ?? .orange
    return String(format: "#%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
}

// MARK: Personalizar

private struct Trait {
    let name: String
    let icon: String
    let text: String
    let tint: Color
}

private let traits = [
    Trait(name: "Carinhosa", icon: "heart.fill", text: "Curta, direta e carinhosa.", tint: .pink),
    Trait(name: "Engraçada", icon: "face.smiling.inverse", text: "Bem-humorada, faz piadas leves, mas resolve o que foi pedido.", tint: .orange),
    Trait(name: "Séria", icon: "briefcase.fill", text: "Formal, objetiva e sem brincadeiras.", tint: .blue),
    Trait(name: "Mentora", icon: "graduationcap.fill", text: "Paciente, explica o porquê das coisas e sugere próximos passos.", tint: .green),
]

private let swatches = ["#FF9E29", "#FF5C7A", "#B56CFF", "#4D8DFF", "#22C3A6", "#7ED957", "#FFD60A", "#E9E9EF"]

struct PersonalizeView: View {
    @ObservedObject var core: Core
    @State private var s = AssistantSettings()

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    block("Aparência", icon: "paintpalette.fill") { looks }
                    block("Jeito de falar", icon: "bubble.left.and.bubble.right.fill") { voice }
                    block("Cérebro", icon: "brain") { brain }
                }
                .padding(18)
            }
        }
        .background(.regularMaterial)
        .ignoresSafeArea()
        .frame(width: 540, height: 780)
        .onAppear { s = core.settings }
        // Salva sozinho, com uma pausa para não gravar a cada letra.
        .task(id: s) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled && s != core.settings { core.saveSettings(s) }
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            AuroraView(colors: [nsColor(s.body_color), nsColor(s.spark_color), nsColor(s.body_color)])
            HStack(alignment: .bottom, spacing: 12) {
                LivePet(settings: s, side: 150)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Nome", text: $s.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .accessibilityLabel("Nome da assistente")
                    Text(s.personality.isEmpty ? "Escolha um jeito de falar" : s.personality)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(2)
                }
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 200)
    }

    private func block<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
    }

    private var looks: some View {
        VStack(alignment: .leading, spacing: 12) {
            colorRow("Corpo", $s.body_color)
            colorRow("Antena", $s.spark_color)
            HStack(spacing: 8) {
                ForEach([("tall", "Compridos"), ("round", "Redondos"), ("dots", "Pontinhos")], id: \.0) { eye($0.0, $0.1) }
            }
            HStack(spacing: 14) {
                Toggle("Antena", isOn: $s.antenna.animation(.spring(response: 0.3)))
                    .toggleStyle(.switch)
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $s.size, in: 0.7...1.4).accessibilityLabel("Tamanho")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
        }
    }

    private func colorRow(_ title: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(width: 52, alignment: .leading)
            ForEach(swatches, id: \.self) { hex in
                let on = value.wrappedValue.caseInsensitiveCompare(hex) == .orderedSame
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { value.wrappedValue = hex }
                } label: {
                    Circle()
                        .fill(colorFromHex(hex))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.primary.opacity(on ? 0.9 : 0.12), lineWidth: on ? 2.5 : 1))
                        .scaleEffect(on ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title): cor \(hex)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            ColorPicker(title, selection: Binding(get: { colorFromHex(value.wrappedValue) }, set: { value.wrappedValue = hexFromColor($0) }), supportsOpacity: false)
                .labelsHidden()
        }
    }

    private func eye(_ id: String, _ title: String) -> some View {
        let on = s.eyes == id
        let tint = colorFromHex(s.body_color)
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { s.eyes = id }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(Color(white: 0.1)).frame(width: 5, height: id == "tall" ? 13 : id == "round" ? 7 : 4)
                    }
                }
                .frame(width: 28, height: 28)
                .background(tint, in: Circle())
                Text(title).font(.caption.weight(.semibold))
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(on ? tint.opacity(0.2) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? tint : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var voice: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(traits, id: \.name) { t in
                    let on = s.personality == t.text
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { s.personality = t.text }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: t.icon)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(t.tint.gradient, in: RoundedRectangle(cornerRadius: 9))
                            Text(t.name).font(.callout.weight(.semibold))
                            Spacer(minLength: 0)
                            if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(t.tint) }
                        }
                        .padding(8)
                        .background(on ? t.tint.opacity(0.17) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? t.tint : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            TextField("Ou descreva do seu jeito", text: $s.personality, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .padding(9)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        }
    }

    private var brain: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelCards(selection: $s.brain_model)
            HStack {
                Text("Esforço").font(.callout)
                Picker("Esforço", selection: $s.brain_effort) {
                    Text("Padrão").tag("")
                    ForEach(effortLevels, id: \.self) { Text(effortNames[$0] ?? $0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
        }
    }
}

// MARK: Fábrica

private let stageNames = ["Investigar", "Propor", "Executar", "Verificar"]

struct FactoryView: View {
    @ObservedObject var core: Core
    let openConversation: (String) -> Void
    @State private var state = FactoryState()
    @State private var creating = false
    @State private var name = ""
    @State private var role = ""
    @State private var model = "auto"
    @State private var effort = "auto"
    @State private var place = "mac"
    @State private var project = ""
    @State private var teamName = ""
    @State private var missionFor: AgentItem?
    @State private var goal = ""
    @State private var problem: String?

    private var busy: Int { state.agents.filter { $0.status == "trabalhando" }.count }
    private let columns = [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                    if creating { form.popIn() }
                    if let r = state.router { routerCard(r) }
                    if state.agents.isEmpty && !creating { empty }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(state.agents) { agentCard($0).popIn() }
                    }
                    teams
                }
                .padding(16)
            }
        }
        .background(.regularMaterial)
        .ignoresSafeArea()
        .frame(width: 720, height: 720)
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $missionFor) { missionSheet($0) }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            AuroraView(colors: [NSColor.systemOrange, NSColor.systemPink, NSColor.systemPurple, NSColor.systemTeal])
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fábrica").font(.system(size: 34, weight: .heavy, design: .rounded))
                    HStack(spacing: 8) {
                        stat("\(state.agents.count)", state.agents.count == 1 ? "agente" : "agentes", "person.2.fill")
                        stat("\(busy)", "trabalhando", "bolt.fill")
                        stat("\(state.teams.count)", state.teams.count == 1 ? "equipe" : "equipes", "number")
                    }
                }
                Spacer()
                HStack(spacing: -7) {
                    ForEach(state.agents.prefix(6)) { a in
                        AgentAvatar(name: a.name, size: 34, active: a.status == "trabalhando")
                            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
                    }
                }
                Button(creating ? "Fechar" : "Novo agente") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { creating.toggle() }
                }
                .buttonStyle(PillButton(tint: .orange, filled: true))
            }
            .padding(16)
        }
        .frame(height: 142)
    }

    private func stat(_ value: String, _ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(value).font(.callout.weight(.heavy)).contentTransition(.numericText())
            Text(title).font(.caption)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .animation(.default, value: value)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.3.sequence.fill").font(.largeTitle).foregroundStyle(.orange.gradient)
            Text("Sua fábrica está vazia").font(.headline)
            Text("Crie um agente aqui ou peça no chat.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func routerCard(_ r: RouterStats) -> some View {
        let total = r.haiku + r.sonnet + r.opus
        let parts: [(String, Int, Color)] = [("Haiku", r.haiku, .green), ("Sonnet", r.sonnet, .blue), ("Opus", r.opus, .purple)]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Modelo automático", systemImage: "wand.and.stars").font(.callout.weight(.semibold))
                Spacer()
                if total > 0 {
                    Text("\(r.escalations) \(r.escalations == 1 ? "subida" : "subidas") · aprendeu com \(r.learned) \(r.learned == 1 ? "resultado" : "resultados")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if total == 0 {
                Text("Cada tarefa vai para o modelo mais barato que dá conta. Se ele falhar, sobe um degrau e aprende.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts.filter { $0.1 > 0 }, id: \.0) { p in
                            RoundedRectangle(cornerRadius: 4).fill(p.2.gradient).frame(width: max(6, (geo.size.width - 4) * CGFloat(p.1) / CGFloat(total)))
                        }
                    }
                }
                .frame(height: 9)
                .animation(.spring(response: 0.5), value: total)
                HStack(spacing: 14) {
                    ForEach(parts, id: \.0) { p in
                        HStack(spacing: 5) {
                            Circle().fill(p.2).frame(width: 7, height: 7).accessibilityHidden(true)
                            Text("\(p.0) \(p.1)").font(.caption)
                        }
                    }
                }
            }
        }
        .card(.orange)
    }

    private var teams: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Equipes").font(.title3.weight(.bold))
            Text("Num canal, escreva @Nome para chamar um agente. Eles também chamam uns aos outros.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(state.teams) { team in
                let crew = state.agents.filter { $0.team == team.id }
                HStack(spacing: 10) {
                    Image(systemName: "number")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(agentColor(team.name).gradient, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(team.name).font(.callout.weight(.semibold))
                        Text(crew.isEmpty ? "Sem agentes ainda" : "\(crew.count) \(crew.count == 1 ? "agente" : "agentes")").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: -6) {
                        ForEach(crew.prefix(7)) { AgentAvatar(name: $0.name, size: 26, active: $0.status == "trabalhando") }
                    }
                    Spacer()
                    Button("Abrir canal") { openConversation(team.conversation) }
                        .buttonStyle(PillButton(tint: agentColor(team.name)))
                    Button("Apagar equipe", systemImage: "trash", role: .destructive) { Task { await core.factoryDelete("teams/\(team.id)"); await refresh() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .card(agentColor(team.name))
            }
            HStack {
                TextField("Nome da nova equipe", text: $teamName).textFieldStyle(.roundedBorder)
                Button("Criar equipe") {
                    let n = teamName
                    teamName = ""
                    Task { problem = await core.factoryPost("teams", ["name": n, "members": []]); await refresh() }
                }
                .buttonStyle(PillButton())
                .disabled(teamName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func missionSheet(_ agent: AgentItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(name: agent.name, size: 36)
                Text("Missão para \(agent.name)").font(.headline)
            }
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

    private func refresh() async {
        if let s = await core.loadFactory() { state = s }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(name: name.isEmpty ? "?" : name, size: 40)
                TextField("Nome (ex.: Revisora)", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            TextField("Papel: o que este agente faz", text: $role, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            ModelCards(selection: $model)
            HStack {
                Picker("Esforço", selection: $effort) {
                    Text("Automático").tag("auto")
                    ForEach(effortLevels, id: \.self) { Text(effortNames[$0] ?? $0).tag($0) }
                }
                Picker("Onde roda", selection: $place) {
                    Text("Este Mac").tag("mac")
                    Text("Nuvem").tag("nuvem")
                }
                Picker("Projeto", selection: $project) {
                    Text("Nenhum").tag("")
                    ForEach(core.usage?.projects ?? [], id: \.path) { Text($0.name).tag($0.path) }
                }
            }
            if place == "nuvem" {
                Text("Na nuvem, o modelo é o padrão do Claude na nuvem.").font(.caption).foregroundStyle(.secondary)
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
                            withAnimation { creating = false }
                        }
                        await refresh()
                    }
                }
                .buttonStyle(PillButton(tint: .orange, filled: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || role.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .card(name.isEmpty ? .orange : agentColor(name))
    }

    private func agentCard(_ a: AgentItem) -> some View {
        let tint = agentColor(a.name)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentAvatar(name: a.name, size: 42, active: a.status == "trabalhando")
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
                    HStack(spacing: 4) {
                        PulseDot(color: statusColor(a.status), active: a.status == "aguardando", size: 6)
                        Text(statusName(a.status)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if a.place != "nuvem" { ModelChip(model: a.model) }
            }
            Text(a.role).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack(spacing: 8) {
                Label(a.place == "nuvem" ? "Nuvem" : "Este Mac", systemImage: a.place == "nuvem" ? "cloud.fill" : "laptopcomputer")
                if let p = a.project { Label(p.components(separatedBy: "/").last ?? p, systemImage: "folder.fill").lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let m = a.mission { missionView(m, tint: tint) }
            HStack(spacing: 6) {
                Button("Conversar") { openConversation(a.conversation) }.buttonStyle(PillButton(tint: tint, filled: true))
                Button("Missão") { missionFor = a }.buttonStyle(PillButton(tint: tint))
                Spacer(minLength: 0)
                Menu {
                    Picker("Equipe", selection: Binding(
                        get: { a.team ?? "" },
                        set: { new in Task { _ = await core.factoryPost("agents/\(a.id)/team", ["team": new.isEmpty ? NSNull() : new]); await refresh() } }
                    )) {
                        Text("Sem equipe").tag("")
                        ForEach(state.teams) { Text($0.name).tag($0.id) }
                    }
                    Divider()
                    Button("Apagar agente", systemImage: "trash", role: .destructive) { Task { await core.factoryDelete("agents/\(a.id)"); await refresh() } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Mais opções de \(a.name)")
            }
        }
        .card(tint)
    }

    private func missionView(_ m: MissionItem, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(m.goal).font(.caption.weight(.semibold)).lineLimit(2)
            HStack(spacing: 0) {
                ForEach(Array(stageNames.enumerated()), id: \.offset) { i, s in
                    if i > 0 {
                        Rectangle().fill(i <= m.stage ? Color.green : Color.primary.opacity(0.15)).frame(height: 2)
                    }
                    VStack(spacing: 2) {
                        PulseDot(color: stageColor(i, m), active: i == m.stage && (m.status == "rodando" || m.status == "aguardando"), size: 9)
                            .frame(width: 22, height: 22)
                        Text(s).font(.system(size: 8.5)).fixedSize()
                    }
                }
            }
            .animation(.easeOut(duration: 0.4), value: m.stage)
            Text(missionName(m.status)).font(.caption2).foregroundStyle(.secondary)
            if let last = m.log.last, let e = last.evidence.first {
                Text("Evidência: \(e)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if m.log.last?.verdict == "sem-evidencia" {
                Text("Parou: a etapa não citou evidência.").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
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
