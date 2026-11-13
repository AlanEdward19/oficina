import AppKit
import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

// MARK: Modelos

struct HardwareCheck: Decodable, Equatable, Identifiable {
    let nome: String
    let valor: String
    let limite: String
    let ok: Bool?
    let detalhe: String
    var id: String { nome }
}

struct HardwareReport: Decodable, Equatable {
    let checks: [HardwareCheck]
    let avisos: [String]
}

struct HardwareProject: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let idea: String
    let created: UInt64
    let agent: String?
    let dir: String
    let files: [String]
    let report: HardwareReport?
    let mission: String?
    let stage: Int?
}

struct HardwareOverview: Decodable, Equatable {
    let setup: String
    let root: String
    let projects: [HardwareProject]
}

struct HardwareRun: Decodable {
    let ok: Bool
    let output: String
}

private let stageNames = ["Investigar", "Propor", "Executar", "Verificar"]
private let tabs: [(id: String, title: String)] = [
    ("requisitos", "Requisitos"), ("pesquisa", "Pesquisa"), ("eletrica", "Eletrônica"), ("pecas", "Peças"),
    ("modelo", "Modelo 3D"), ("simulacao", "Simulação"), ("montagem", "Montagem"), ("firmware", "Firmware"),
]

// MARK: Tela

/// Uma ideia vira um pacote de projeto: um agente pesquisa, desenha o mapa
/// elétrico, escolhe peças, modela em 3D, simula e escreve a montagem.
struct HardwareView: View {
    @ObservedObject var core: Core
    var tint: Color
    var openConversation: (String) -> Void

    @State private var overview: HardwareOverview?
    @State private var selected: String?
    @State private var creating = false
    @State private var tab = "requisitos"

    private var project: HardwareProject? { overview?.projects.first { $0.id == selected } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Rectangle().fill(Bench.line).frame(width: 1)
            Group {
                if creating || overview?.projects.isEmpty == true {
                    NewHardwareForm(core: core, tint: tint) { id in
                        creating = false
                        selected = id
                        Task { overview = await core.hardware() }
                    }
                } else if let p = project {
                    HardwareDetail(core: core, project: p, setup: overview?.setup ?? "ausente", tint: tint, tab: $tab, openConversation: openConversation)
                } else {
                    Text("Escolha um projeto.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 600)
        .background(Bench.canvas)
        .ignoresSafeArea()
        .task {
            while !Task.isCancelled {
                if let o = await core.hardware() {
                    overview = o
                    if selected == nil { selected = o.projects.first?.id }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Oficina de hardware").font(Bench.display(20)).padding(.horizontal, 20).padding(.top, 44).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(overview?.projects ?? []) { p in
                        HoverRow(keepTrailing: selected == p.id && !creating) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 13, weight: selected == p.id ? .semibold : .regular)).lineLimit(1)
                                Text(status(p)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } trailing: {
                            Circle().fill(tint).frame(width: 6, height: 6)
                        }
                        .onTapGesture {
                            creating = false
                            selected = p.id
                        }
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 12)
            }
            Spacer(minLength: 0)
            Button("Novo projeto") { creating = true }
                .buttonStyle(QuietStyle(tint: tint))
                .padding(20)
        }
    }

    private func status(_ p: HardwareProject) -> String {
        guard let m = p.mission else { return "sem missão" }
        let stage = stageNames[min(p.stage ?? 0, stageNames.count - 1)]
        switch m {
        case "rodando": return "\(stage)…"
        case "aguardando": return "esperando sua aprovação"
        case "concluida": return "pacote pronto"
        case "bloqueada": return "bloqueado em \(stage)"
        case "falhou": return "falhou em \(stage)"
        default: return m
        }
    }
}

// MARK: Novo projeto

private struct NewHardwareForm: View {
    @ObservedObject var core: Core
    var tint: Color
    var done: (String?) -> Void
    @State private var name = ""
    @State private var idea = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nova ideia").font(Bench.display(26))
                Text("Descreva o que quer construir. Um agente pesquisa, faz o mapa elétrico, escolhe as peças, modela em 3D, simula e escreve a montagem. Antes de mexer nos arquivos, ele pede sua aprovação.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HairField(prompt: "Nome (ex.: Óculos com IA)", text: $name)
            HairField(prompt: "A ideia (ex.: óculos com câmera, microfone e alto-falante, IA pelo celular, 4 h de bateria, menos de 50 g)", text: $idea, lines: 3...8)
            HStack(spacing: 16) {
                Button(busy ? "Criando…" : "Começar projeto") { create() }
                    .buttonStyle(SolidStyle())
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || idea.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Gasta tokens do Claude em cada etapa.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Spacer()
        }
        .padding(.horizontal, 44)
        .padding(.top, 52)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func create() {
        busy = true
        Task {
            error = await core.createHardware(name: name, idea: idea)
            busy = false
            if error == nil {
                let o = await core.hardware()
                done(o?.projects.first?.id)
            }
        }
    }
}

// MARK: Projeto

private struct HardwareDetail: View {
    @ObservedObject var core: Core
    let project: HardwareProject
    let setup: String
    var tint: Color
    @Binding var tab: String
    var openConversation: (String) -> Void
    @State private var output: String?
    @State private var running = false
    @State private var explode = 0.0
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 40).padding(.top, 44)
            WordPicker(options: tabs, selection: $tab, tint: tint).padding(.horizontal, 40).padding(.top, 20)
            Rectangle().fill(Bench.line).frame(height: 1).padding(.top, 2)
            Group {
                switch tab {
                case "modelo": model
                case "simulacao": ScrollView { simulation.padding(40) }
                case "pecas": ScrollView { parts.padding(40) }
                case "eletrica": ScrollView { electrical.padding(40) }
                case "firmware": ScrollView { firmwareTab.padding(40) }
                default: ScrollView { document(tab == "pesquisa" ? "pesquisa.md" : tab == "montagem" ? "montagem.md" : "requisitos.md").padding(40) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .confirmationDialog("Apagar \(project.name)?", isPresented: $confirmDelete) {
            Button("Apagar projeto e agente", role: .destructive) { Task { await core.deleteHardware(project.id) } }
        } message: {
            Text("A pasta do projeto e o agente dele somem. Não dá para desfazer.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(project.name).font(Bench.display(26))
            Text(project.idea).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 18) {
                stages
                Spacer()
                if project.agent != nil {
                    if project.mission == "aguardando" {
                        Button("Aprovar no chat do agente") { openAgent() }.buttonStyle(SolidStyle())
                    } else {
                        Button("Conversar com o agente") { openAgent() }.buttonStyle(QuietStyle(tint: tint))
                    }
                }
                Button("Abrir pasta") { NSWorkspace.shared.open(URL(fileURLWithPath: project.dir)) }.buttonStyle(QuietStyle(tint: tint))
                Button("Apagar…") { confirmDelete = true }.buttonStyle(QuietStyle(tint: tint))
            }
        }
    }

    /// Investigar → Propor → Executar → Verificar, no traço da Bancada.
    private var stages: some View {
        let current = project.stage ?? 0
        let done = project.mission == "concluida"
        return HStack(spacing: 10) {
            ForEach(Array(stageNames.enumerated()), id: \.offset) { i, name in
                let reached = done || i < current
                let now = !done && i == current
                HStack(spacing: 5) {
                    Circle().fill(reached ? tint : now ? tint.opacity(0.5) : Bench.line).frame(width: 7, height: 7)
                    Text(name).font(.system(size: 12, weight: now ? .semibold : .regular)).foregroundStyle(reached || now ? Color.primary : Bench.faint)
                }
            }
        }
    }

    private func openAgent() {
        Task {
            guard let agent = project.agent, let f = await core.loadFactory(), let a = f.agents.first(where: { $0.id == agent }) else { return }
            openConversation(a.conversation)
        }
    }

    private func url(_ rel: String) -> URL { URL(fileURLWithPath: project.dir).appendingPathComponent(rel) }

    private func read(_ rel: String) -> String? { try? String(contentsOf: url(rel), encoding: .utf8) }

    @ViewBuilder private func document(_ rel: String) -> some View {
        if let text = read(rel), !text.isEmpty {
            MarkdownBlock(text: text)
        } else {
            waiting
        }
    }

    private var waiting: some View {
        Text("O agente ainda não escreveu esta parte.").font(.callout).foregroundStyle(.secondary)
    }

    private var electrical: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let d = read("eletrica/diagrama.mmd") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diagrama de blocos").font(.system(size: 13, weight: .semibold))
                    DiagramPanel(core: core, project: project.id, source: d, tint: tint)
                }
            }
            document("eletrica/mapa.md")
            files(project.files.filter { $0.hasPrefix("eletrica/") && !$0.hasSuffix(".md") && !$0.hasSuffix(".mmd") })
            runButton("erc", "Checar o esquemático")
        }
    }

    private var firmwareTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            folder("firmware")
            if let fw = project.report?.checks.first(where: { $0.nome == "Firmware" }) {
                Text("\(fw.valor) · \(fw.detalhe)").font(.callout)
            }
            if let log = read("simulacoes/uart.log"), !log.isEmpty {
                Text("Serial simulada").font(.system(size: 13, weight: .semibold))
                Text(String(log.suffix(3000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
            runButton("firmware", "Compilar e simular")
            Text("Compila com PlatformIO e, se houver firmware/renode.resc, simula no Renode (placas Cortex-M e RISC-V). O ESP32-S3 só compila.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var parts: some View {
        VStack(alignment: .leading, spacing: 10) {
            let rows = csv(read("bom.csv") ?? "")
            if rows.count <= 1 {
                waiting
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        ForEach(["Peça", "Função", "Qtd", "R$", "g"], id: \.self) { Text($0).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { _, r in
                        GridRow {
                            if let link = URL(string: r[safe: 5] ?? ""), link.scheme?.hasPrefix("http") == true {
                                Link(r[safe: 0] ?? "", destination: link)
                            } else {
                                Text(r[safe: 0] ?? "")
                            }
                            Text(r[safe: 1] ?? "").foregroundStyle(.secondary)
                            Text(r[safe: 2] ?? "").monospacedDigit()
                            Text(r[safe: 3] ?? "").monospacedDigit()
                            Text(r[safe: 4] ?? "").monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                Text("Preços e estoque mudam: confira antes de comprar. Nada é comprado sem você.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var simulation: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let r = project.report {
                ForEach(r.checks) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(c.nome).font(.system(size: 14, weight: .semibold)).frame(width: 90, alignment: .leading)
                            Text(c.valor).font(.system(size: 14)).monospacedDigit()
                            Text(c.limite).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(c.ok == true ? "passou" : c.ok == false ? "reprovou" : "sem limite")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(c.ok == false ? Color.red : c.ok == true ? tint : Bench.faint)
                        }
                        Text(c.detalhe).font(.caption).foregroundStyle(.secondary)
                    }
                    Rectangle().fill(Bench.line).frame(height: 1)
                }
                ForEach(r.avisos, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout) }
            } else {
                Text("Ainda sem simulações. Elas rodam no Mac, sem gastar tokens.").font(.callout).foregroundStyle(.secondary)
            }
            runButton("sim", "Rodar simulações")
        }
    }

    private var stls: [URL] {
        project.files.filter { $0.hasPrefix("mecanica/") && $0.hasSuffix(".stl") && $0 != "mecanica/montagem.stl" }.map(url)
    }

    @ViewBuilder private var model: some View {
        if stls.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Ainda sem modelo 3D.").font(.callout).foregroundStyle(.secondary)
                if setup == "ausente" || setup.hasPrefix("erro") {
                    Text("Para modelar, a Oficina instala o build123d num ambiente só dela (cerca de 2 GB, sem tokens).\(setup.hasPrefix("erro") ? " Última tentativa: \(setup)." : "")")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Instalar ambiente de CAD") { core.setupHardware() }.buttonStyle(SolidStyle())
                } else if setup == "instalando" {
                    Text("Instalando o ambiente de CAD…").font(.callout)
                } else if project.files.contains("mecanica/modelo.py") {
                    runButton("build", "Gerar modelo")
                } else {
                    waiting
                }
            }
            .padding(40)
        } else {
            VStack(spacing: 0) {
                ModelView(urls: stls, explode: explode, tint: NSColor(tint)).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 14) {
                    Text("Vista explodida").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $explode, in: 0...1.5).frame(width: 200)
                    Spacer()
                    if setup == "pronto", project.files.contains("mecanica/modelo.py") {
                        runButton("build", "Gerar de novo")
                    }
                    Button("Abrir STEP") { NSWorkspace.shared.open(url("mecanica/montagem.step")) }.buttonStyle(QuietStyle(tint: tint))
                }
                .padding(.horizontal, 40).padding(.vertical, 14)
            }
        }
    }

    private func folder(_ prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            document("\(prefix)/README.md")
            files(project.files.filter { $0.hasPrefix("\(prefix)/") && !$0.hasSuffix("README.md") })
        }
    }

    private func files(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list, id: \.self) { f in
                Button(f) { NSWorkspace.shared.open(url(f)) }.buttonStyle(QuietStyle(tint: tint))
            }
        }
    }

    private func runButton(_ what: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(running ? "Rodando…" : title) { run(what) }
                .buttonStyle(QuietStyle(tint: tint))
                .disabled(running)
            if let output {
                Text(output).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(30)
            }
        }
    }

    private func run(_ what: String) {
        running = true
        Task {
            let r = await core.runHardware(project.id, what)
            output = r?.output ?? "Sem contato com o core."
            running = false
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// CSV simples, com aspas.
private func csv(_ text: String) -> [[String]] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        var fields: [String] = []
        var cur = ""
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted, i + 1 < chars.count, chars[i + 1] == "\"" {
                    cur.append("\"")
                    i += 1
                } else {
                    quoted.toggle()
                }
            } else if c == ",", !quoted {
                fields.append(cur)
                cur = ""
            } else {
                cur.append(c)
            }
            i += 1
        }
        fields.append(cur)
        return fields
    }
}

/// Markdown em blocos: títulos, listas, tabelas e parágrafos.
struct MarkdownBlock: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("# ") {
            markdownText(String(t.dropFirst(2))).font(Bench.display(20)).padding(.top, 6)
        } else if t.hasPrefix("## ") {
            markdownText(String(t.dropFirst(3))).font(.system(size: 15, weight: .semibold)).padding(.top, 8)
        } else if t.hasPrefix("### ") {
            markdownText(String(t.dropFirst(4))).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
        } else if t.hasPrefix("|") {
            if !t.contains("---") {
                Text(t.trimmingCharacters(in: CharacterSet(charactersIn: "|")).replacingOccurrences(of: "|", with: "  ·  "))
                    .font(.system(size: 12, design: .monospaced))
            }
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                markdownText(String(t.dropFirst(2))).font(.callout)
            }
        } else if !t.isEmpty {
            markdownText(t).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 3D

/// Peças em STL num SceneKit: girar, aproximar e explodir a montagem.
struct ModelView: NSViewRepresentable {
    let urls: [URL]
    let explode: Double
    let tint: NSColor

    final class Coordinator {
        var loaded: [URL] = []
        var parts: [(node: SCNNode, offset: SCNVector3)] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.scene = SCNScene()
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let c = context.coordinator
        if c.loaded != urls {
            load(v, c)
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for p in c.parts {
            p.node.position = SCNVector3(p.offset.x * CGFloat(explode), p.offset.y * CGFloat(explode), p.offset.z * CGFloat(explode))
        }
        SCNTransaction.commit()
    }

    private func load(_ v: SCNView, _ c: Coordinator) {
        let scene = SCNScene()
        let palette: [NSColor] = [tint, .systemGray, .systemTeal, .systemIndigo, .systemBrown, .systemPink, .systemGreen]
        var parts: [(SCNNode, SCNVector3)] = []
        for (i, url) in urls.enumerated() {
            let asset = MDLAsset(url: url)
            let holder = SCNNode()
            let loaded = SCNScene(mdlAsset: asset)
            for child in loaded.rootNode.childNodes { holder.addChildNode(child) }
            let material = SCNMaterial()
            material.diffuse.contents = palette[i % palette.count]
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.6
            holder.enumerateChildNodes { n, _ in n.geometry?.materials = [material] }
            holder.name = url.deletingPathExtension().lastPathComponent
            scene.rootNode.addChildNode(holder)
            let (lo, hi) = holder.boundingBox
            parts.append((holder, SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)))
        }
        // Explodir afasta cada peça do centro da montagem.
        let (lo, hi) = scene.rootNode.boundingBox
        let center = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
        c.parts = parts.map { ($0.0, SCNVector3($0.1.x - center.x, $0.1.y - center.y, $0.1.z - center.z)) }
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = Double(size) * 20
        camera.camera?.zNear = Double(size) / 1000
        camera.position = SCNVector3(center.x + size * 0.9, center.y + size * 0.7, center.z + size * 1.6)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        v.scene = scene
        v.pointOfView = camera
        c.loaded = urls
    }
}

// MARK: Diagrama de blocos

struct DiagramNode: Decodable, Equatable {
    let id: String
    let label: String
    let layer: Int
    let row: Int
    let shape: String
}

struct DiagramEdge: Decodable, Equatable {
    let from: String
    let to: String
    let label: String?
    let dashed: Bool
    let thick: Bool
}

/// O Mermaid do agente, já posicionado pelo core.
struct BlockDiagram: Decodable, Equatable {
    let direction: String
    let nodes: [DiagramNode]
    let edges: [DiagramEdge]
    let layers: Int
}

/// Busca o desenho de novo quando o arquivo muda; sem desenho, mostra o texto.
private struct DiagramPanel: View {
    @ObservedObject var core: Core
    let project: String
    let source: String
    var tint: Color
    @State private var diagram: BlockDiagram?
    @State private var showSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = diagram, !d.nodes.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    DiagramCanvas(diagram: d, tint: tint).padding(8)
                }
                .frame(minHeight: 220, maxHeight: 460)
                Button(showSource ? "Esconder o Mermaid" : "Ver o Mermaid") { showSource.toggle() }.buttonStyle(QuietStyle(tint: tint))
            }
            if diagram == nil || showSource {
                Text(source).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
        }
        .task(id: source) { diagram = await core.hardwareDiagram(project) }
    }
}

/// Blocos em camadas e setas, desenhados no Canvas: sem navegador.
struct DiagramCanvas: View {
    let diagram: BlockDiagram
    var tint: Color

    private let box = CGSize(width: 150, height: 54)
    private let gap = CGSize(width: 70, height: 26)
    private var horizontal: Bool { diagram.direction == "LR" }

    private var size: CGSize {
        let rows = (diagram.nodes.map(\.row).max() ?? 0) + 1
        let layers = max(diagram.layers, 1)
        let along = CGFloat(layers) * box.width + CGFloat(layers - 1) * gap.width
        let across = CGFloat(rows) * box.height + CGFloat(rows - 1) * gap.height
        if horizontal { return CGSize(width: along, height: across) }
        return CGSize(width: CGFloat(rows) * box.width + CGFloat(rows - 1) * gap.height,
                      height: CGFloat(layers) * box.height + CGFloat(layers - 1) * gap.width)
    }

    private func center(_ n: DiagramNode) -> CGPoint {
        if horizontal {
            return CGPoint(x: CGFloat(n.layer) * (box.width + gap.width) + box.width / 2,
                           y: CGFloat(n.row) * (box.height + gap.height) + box.height / 2)
        }
        return CGPoint(x: CGFloat(n.row) * (box.width + gap.height) + box.width / 2,
                       y: CGFloat(n.layer) * (box.height + gap.width) + box.height / 2)
    }

    var body: some View {
        let nodes = Dictionary(diagram.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Canvas { ctx, _ in
            for e in diagram.edges {
                guard let a = nodes[e.from], let b = nodes[e.to] else { continue }
                let (p, q) = endpoints(center(a), center(b))
                var path = Path()
                path.move(to: p)
                path.addLine(to: q)
                let style = StrokeStyle(lineWidth: e.thick ? 2.4 : 1.2, dash: e.dashed ? [5, 4] : [])
                ctx.stroke(path, with: .color(.secondary), style: style)
                ctx.fill(arrowHead(from: p, to: q), with: .color(.secondary))
                if let label = e.label {
                    let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2 - 9)
                    ctx.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(tint), at: mid)
                }
            }
            for n in diagram.nodes {
                let c = center(n)
                let rect = CGRect(x: c.x - box.width / 2, y: c.y - box.height / 2, width: box.width, height: box.height)
                let shape: Path
                switch n.shape {
                case "circle": shape = Path(ellipseIn: rect)
                case "round": shape = Path(roundedRect: rect, cornerRadius: box.height / 2)
                case "diamond":
                    var d = Path()
                    d.move(to: CGPoint(x: rect.midX, y: rect.minY))
                    d.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                    d.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    d.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                    d.closeSubpath()
                    shape = d
                default: shape = Path(roundedRect: rect, cornerRadius: 6)
                }
                ctx.fill(shape, with: .color(Bench.canvas))
                ctx.stroke(shape, with: .color(n.layer == 0 ? tint : Color.primary.opacity(0.45)), lineWidth: 1.2)
                ctx.draw(Text(n.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.primary), in: rect.insetBy(dx: 8, dy: 6))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityLabel(diagram.edges.map { "\(nodes[$0.from]?.label ?? $0.from) para \(nodes[$0.to]?.label ?? $0.to)" }.joined(separator: ", "))
    }

    /// A seta sai da borda de um bloco e chega na borda do outro.
    private func endpoints(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let ux = dx / len, uy = dy / len
        let tx = ux == 0 ? CGFloat.infinity : (box.width / 2) / abs(ux)
        let ty = uy == 0 ? CGFloat.infinity : (box.height / 2) / abs(uy)
        let t = min(tx, ty) + 2
        return (CGPoint(x: a.x + ux * t, y: a.y + uy * t), CGPoint(x: b.x - ux * t, y: b.y - uy * t))
    }

    private func arrowHead(from p: CGPoint, to q: CGPoint) -> Path {
        let angle = atan2(q.y - p.y, q.x - p.x)
        let size: CGFloat = 7
        var path = Path()
        path.move(to: q)
        path.addLine(to: CGPoint(x: q.x - size * cos(angle - .pi / 7), y: q.y - size * sin(angle - .pi / 7)))
        path.addLine(to: CGPoint(x: q.x - size * cos(angle + .pi / 7), y: q.y - size * sin(angle + .pi / 7)))
        path.closeSubpath()
        return path
    }
}
