import AppKit
import SwiftUI

// A tela só mostra e marca. Quem varre e remove é o core, que aceita apenas
// ids da última varredura e sempre manda para a Lixeira.

struct CleanItem: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let path: String
    let size: UInt64
    let checked: Bool
    let note: String
}

struct CleanGroup: Decodable, Identifiable, Equatable {
    var id: String { title + note }
    let title: String
    let note: String
    let items: [CleanItem]
}

struct CleanScan: Decodable, Equatable {
    let groups: [CleanGroup]
    let total: UInt64
}

struct CleanOutcome: Decodable {
    let moved: Int
    let bytes: UInt64
    let failed: [String]
}

struct CleanApp: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let bundle: String
    let path: String
    let size: UInt64
}

struct DiskEntry: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let size: UInt64
    let dir: Bool
}

struct StartupEntry: Decodable, Identifiable {
    var id: String { label + place }
    let label: String
    let program: String
    let place: String
    let orphan: Bool
}

private struct TrashInfo: Decodable { let bytes: UInt64? }

func bytesText(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))), countStyle: .file)
}

private enum Channel: String, CaseIterable, Identifiable {
    case junk, large, duplicates, leftovers, uninstall, trash, map, startup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: return "Caches e Logs"
        case .large: return "Grandes e Antigos"
        case .duplicates: return "Duplicados"
        case .leftovers: return "Restos de Apps"
        case .uninstall: return "Desinstalador"
        case .trash: return "Lixo"
        case .map: return "Mapa do Disco"
        case .startup: return "Itens de Início"
        }
    }

    var icon: String {
        switch self {
        case .junk: return "sparkles"
        case .large: return "archivebox"
        case .duplicates: return "doc.on.doc"
        case .leftovers: return "puzzlepiece.extension"
        case .uninstall: return "xmark.bin"
        case .trash: return "trash"
        case .map: return "chart.pie"
        case .startup: return "power"
        }
    }

    var blurb: String {
        switch self {
        case .junk: return "Caches, logs e sobras que os apps recriam."
        case .large: return "Arquivos de 100 MB ou mais nas suas pastas."
        case .duplicates: return "Cópias idênticas, conferidas byte a byte."
        case .leftovers: return "Dados de apps que você já apagou."
        case .uninstall: return "Remova um app junto com o que ele deixou."
        case .trash: return "Veja o tamanho do Lixo e esvazie."
        case .map: return "Descubra o que ocupa espaço."
        case .startup: return "O que abre junto com o Mac."
        }
    }
}

struct CleanView: View {
    @ObservedObject var core: Core
    @State private var selection: Channel? = .junk
    @State private var scans: [String: CleanScan] = [:]
    @State private var picked: Set<Int> = []
    @State private var busy = false
    @State private var message: String?
    @State private var apps: [CleanApp] = []
    @State private var appFilter = ""
    @State private var appChosen: CleanApp?
    @State private var entries: [DiskEntry] = []
    @State private var mapPath: [String] = []
    @State private var startup: [StartupEntry] = []
    @State private var trashBytes: UInt64?
    @State private var trashKnown = false
    @State private var askEmpty = false

    private var channel: Channel { selection ?? .junk }
    private var scan: CleanScan? { scans[channel.rawValue] }
    private var pickedBytes: UInt64 {
        scan?.groups.flatMap(\.items).filter { picked.contains($0.id) }.reduce(0) { $0 + $1.size } ?? 0
    }
    private var isList: Bool { [.junk, .large, .duplicates, .leftovers].contains(channel) || (channel == .uninstall && appChosen != nil) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Limpeza") { rows([.junk, .large, .duplicates, .leftovers]) }
                Section("Apps") { rows([.uninstall, .startup]) }
                Section("Disco") { rows([.map, .trash]) }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(channel.title)
                .navigationSubtitle(scan.map { bytesText($0.total) } ?? "")
                .toolbar {
                    if isList && scan != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Varrer Novamente", systemImage: "arrow.clockwise") { runScan() }.disabled(busy)
                        }
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 500)
        .task {
            // Só para teste visual: o core ainda está subindo no início do app.
            guard CommandLine.arguments.contains("--varrer-agora") else { return }
            try? await Task.sleep(for: .seconds(3))
            runScan()
        }
        .onChange(of: selection) {
            message = nil
            picked = Set(scan?.groups.flatMap(\.items).filter(\.checked).map(\.id) ?? [])
            enter()
        }
        .alert("Deseja apagar permanentemente os itens do Lixo?", isPresented: $askEmpty) {
            Button("Esvaziar Lixo", role: .destructive) { emptyTrash() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Esta ação não pode ser desfeita.")
        }
    }

    private func rows(_ list: [Channel]) -> some View {
        ForEach(list) { Label($0.title, systemImage: $0.icon).tag($0) }
    }

    @ViewBuilder private var content: some View {
        if busy {
            ProgressView("Medindo…")
        } else {
            switch channel {
            case .uninstall where appChosen == nil: appList
            case .trash: trash
            case .map: diskMap
            case .startup: startupTable
            default: resultList
            }
        }
    }

    // MARK: Listas

    @ViewBuilder private var resultList: some View {
        if let scan {
            if scan.groups.isEmpty {
                ContentUnavailableView {
                    Label("Nada para Limpar", systemImage: "checkmark.circle")
                } actions: {
                    Button("Varrer Novamente") { runScan() }
                }
            } else {
                List {
                    ForEach(scan.groups) { group($0) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            }
        } else {
            ContentUnavailableView {
                Label(channel.title, systemImage: channel.icon)
            } description: {
                Text(message ?? channel.blurb)
            } actions: {
                Button("Varrer") { runScan() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    private func group(_ g: CleanGroup) -> some View {
        Section {
            ForEach(g.items) { row($0) }
        } header: {
            HStack {
                Toggle(g.title, isOn: Binding(
                    get: { g.items.allSatisfy { picked.contains($0.id) } },
                    set: { on in for i in g.items { if on { picked.insert(i.id) } else { picked.remove(i.id) } } }
                ))
                .toggleStyle(.checkbox)
                if !g.note.isEmpty { Text(g.note).fontWeight(.regular).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Text(bytesText(g.items.reduce(0) { $0 + $1.size })).monospacedDigit()
            }
        }
    }

    private func row(_ i: CleanItem) -> some View {
        HStack {
            Toggle(i.name, isOn: Binding(get: { picked.contains(i.id) }, set: { if $0 { picked.insert(i.id) } else { picked.remove(i.id) } }))
                .toggleStyle(.checkbox)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(i.path)
            if !i.note.isEmpty { Text(i.note).foregroundStyle(.secondary) }
            Spacer()
            Text(bytesText(i.size)).monospacedDigit().foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.path)]) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if channel == .uninstall {
                    Button("Voltar") {
                        appChosen = nil
                        scans[channel.rawValue] = nil
                    }
                }
                Text(message ?? "\(picked.count) selecionados, \(bytesText(pickedBytes))").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(channel == .uninstall ? "Desinstalar" : "Mover para o Lixo") { clean() }
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty)
            }
            .padding(10)
        }
        .background(.bar)
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Buscar", text: $appFilter).textFieldStyle(.roundedBorder).padding(10)
            List(apps.filter { appFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(appFilter) }) { a in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                    Text(a.name)
                    Spacer()
                    Text(bytesText(a.size)).monospacedDigit().foregroundStyle(.secondary)
                    Button("Desinstalar…") {
                        appChosen = a
                        runScan()
                    }
                    .controlSize(.small)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var trash: some View {
        ContentUnavailableView {
            Label(trashKnown ? bytesText(trashBytes ?? 0) : "Lixo", systemImage: "trash")
        } description: {
            Text(message ?? (trashKnown ? "Itens no Lixo." : "Para medir o Lixo, dê Acesso Total ao Disco à Oficina em Ajustes do Sistema."))
        } actions: {
            Button("Esvaziar Lixo…") { askEmpty = true }
        }
    }

    private var diskMap: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Voltar", systemImage: "chevron.left") {
                    mapPath.removeLast()
                    loadMap()
                }
                .disabled(mapPath.isEmpty)
                Text(mapPath.last ?? "Pasta de Usuário").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .padding(10)
            Divider()
            let top = max(entries.first?.size ?? 1, 1)
            List(entries) { e in
                Button {
                    if e.dir {
                        mapPath.append(e.path)
                        loadMap()
                    }
                } label: {
                    HStack {
                        Label(e.name, systemImage: e.dir ? "folder" : "doc").lineLimit(1).frame(width: 240, alignment: .leading)
                        ProgressView(value: Double(e.size) / Double(top)).progressViewStyle(.linear)
                        Text(bytesText(e.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var startupTable: some View {
        Table(startup) {
            TableColumn("Nome", value: \.label)
            TableColumn("Programa") { Text($0.orphan ? "Não encontrado: \($0.program)" : $0.program).foregroundStyle($0.orphan ? .orange : .secondary) }
            TableColumn("Para") { Text($0.place) }.width(70)
        }
    }

    // MARK: Ações

    private func enter() {
        switch channel {
        case .uninstall where apps.isEmpty: work { apps = await core.get("clean/apps") ?? [] }
        case .trash: loadTrash()
        case .startup where startup.isEmpty: work { startup = await core.get("clean/startup") ?? [] }
        case .map where entries.isEmpty: loadMap()
        default: break
        }
    }

    private func work(_ job: @escaping () async -> Void) {
        busy = true
        Task {
            await job()
            busy = false
        }
    }

    private func loadTrash() {
        work {
            let info: TrashInfo? = await core.get("clean/trash")
            trashBytes = info?.bytes
            trashKnown = info?.bytes != nil
        }
    }

    private func loadMap() {
        var body: [String: Any] = [:]
        if let p = mapPath.last { body["path"] = p }
        work { entries = await core.post("clean/map", body) ?? [] }
    }

    private func runScan() {
        let mode = channel.rawValue
        var body: [String: Any] = ["mode": mode]
        if let a = appChosen, channel == .uninstall { body["app"] = a.path }
        message = nil
        work {
            let result: CleanScan? = await core.post("clean/scan", body)
            scans[mode] = result
            picked = Set(result?.groups.flatMap(\.items).filter(\.checked).map(\.id) ?? [])
            if result == nil { message = "Não foi possível varrer. Tente novamente." }
        }
    }

    private func clean() {
        let mode = channel.rawValue
        let ids = Array(picked)
        work {
            guard let out: CleanOutcome = await core.post("clean/run", ["mode": mode, "ids": ids]) else {
                message = "Sem contato com o core."
                return
            }
            message = "\(out.moved) \(out.moved == 1 ? "item movido" : "itens movidos") para o Lixo, \(bytesText(out.bytes))."
                + (out.failed.isEmpty ? "" : " \(out.failed.count) não \(out.failed.count == 1 ? "pôde ser movido" : "puderam ser movidos").")
            scans[mode] = nil
            picked = []
            if channel == .uninstall {
                appChosen = nil
                apps = await core.get("clean/apps") ?? []
            }
        }
    }

    private func emptyTrash() {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        message = error == nil ? "Lixo esvaziado." : "Permita a automação do Finder em Ajustes do Sistema."
        loadTrash()
    }
}
