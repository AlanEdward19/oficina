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

    private var tint: Color { colorFromHex(core.settings.body_color) }

    var body: some View {
        HStack(spacing: 0) {
            rail.frame(width: 210)
            Rectangle().fill(Bench.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                top
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 780, minHeight: 500)
        .background(Bench.canvas)
        .ignoresSafeArea()
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

    private var rail: some View {
        VStack(alignment: .leading, spacing: 22) {
            railGroup("Limpeza", [.junk, .large, .duplicates, .leftovers])
            railGroup("Apps", [.uninstall, .startup])
            railGroup("Disco", [.map, .trash])
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 22)
        .padding(.top, 52)
    }

    private func railGroup(_ title: String, _ list: [Channel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Bench.faint)
            ForEach(list) { c in
                let on = channel == c
                Button { selection = c } label: {
                    Text(loc(c.title))
                        .font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var top: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc(channel.title)).font(Bench.display(38)).tracking(-1).lineLimit(1)
                Text(scan.map { loc("%@ encontrados", bytesText($0.total)) } ?? loc(channel.blurb))
                    .font(.system(size: 14)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if isList && scan != nil && !busy {
                Button(loc("Varrer de novo")) { runScan() }.buttonStyle(QuietStyle(tint: tint))
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 52)
        .padding(.bottom, 20)
    }

    @ViewBuilder private var content: some View {
        if busy {
            waiting
        } else {
            switch channel {
            case .uninstall where appChosen == nil: appList
            case .trash: trash
            case .map: diskMap
            case .startup: startupList
            default: resultList
            }
        }
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            Bob(active: true, content: AgentAvatar(name: "Faísca", size: 36)).frame(width: 36, height: 36)
            Text(loc("Medindo…")).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func start(_ text: String?, action: String?, _ run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let text { Text(loc(text)).font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading) }
            if let action { Button(loc(action), action: run).buttonStyle(SolidStyle()) }
        }
        .padding(.horizontal, 36)
    }

    // MARK: Listas

    @ViewBuilder private var resultList: some View {
        if let scan {
            if scan.groups.isEmpty {
                start("Nada para limpar aqui.", action: "Varrer de novo") { runScan() }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(scan.groups) { group($0) }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 16)
                    }
                    footer
                }
            }
        } else {
            start(message, action: "Varrer") { runScan() }
        }
    }

    private func group(_ g: CleanGroup) -> some View {
        let all = g.items.allSatisfy { picked.contains($0.id) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                BenchCheck(on: all, tint: tint) { for i in g.items { if all { picked.remove(i.id) } else { picked.insert(i.id) } } }
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                    .accessibilityLabel(g.title)
                Text(g.title).font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                if !g.note.isEmpty { Text(g.note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Text(bytesText(g.items.reduce(0) { $0 + $1.size })).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Rectangle().fill(Bench.line).frame(height: 1).padding(.horizontal, 8)
            ForEach(g.items) { row($0) }
        }
    }

    private func toggle(_ id: Int) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    private func row(_ i: CleanItem) -> some View {
        HoverRow(keepTrailing: true) {
            BenchCheck(on: picked.contains(i.id), tint: tint) { toggle(i.id) }.accessibilityLabel(i.name)
            Text(i.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle).help(i.path)
            if !i.note.isEmpty { Text(i.note).font(.system(size: 12)).foregroundStyle(.secondary) }
        } trailing: {
            Text(bytesText(i.size)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
        }
        .onTapGesture { toggle(i.id) }
        .contextMenu {
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: i.path)]) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Bench.line).frame(height: 1)
            HStack(spacing: 16) {
                if channel == .uninstall {
                    Button(loc("Voltar")) {
                        appChosen = nil
                        scans[channel.rawValue] = nil
                    }
                    .buttonStyle(QuietStyle(tint: tint))
                }
                Text(message ?? loc("%@ selecionados, %@", "\(picked.count)", bytesText(pickedBytes))).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(loc(channel == .uninstall ? "Desinstalar" : "Mover para o Lixo")) { clean() }
                    .buttonStyle(SolidStyle())
                    .disabled(picked.isEmpty)
            }
            .padding(.horizontal, 36)
            .frame(height: 58)
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HairField(prompt: "Buscar", text: $appFilter).padding(.horizontal, 36)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps.filter { appFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(appFilter) }) { a in
                        HoverRow {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path)).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                            Text(a.name).font(.system(size: 14)).lineLimit(1)
                            Spacer()
                            Text(bytesText(a.size)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                        } trailing: {
                            Button(loc("Desinstalar…")) {
                                appChosen = a
                                runScan()
                            }
                            .buttonStyle(QuietStyle(tint: .red))
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
    }

    private var trash: some View {
        VStack(alignment: .leading, spacing: 16) {
            if trashKnown {
                Text(bytesText(trashBytes ?? 0)).font(Bench.display(64)).tracking(-2).monospacedDigit()
            }
            Text(message ?? loc(trashKnown ? "Itens no Lixo." : "Para medir o Lixo, dê Acesso Total ao Disco à Oficina em Ajustes do Sistema."))
                .font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading)
            Button(loc("Esvaziar Lixo…")) { askEmpty = true }.buttonStyle(SolidStyle())
        }
        .padding(.horizontal, 36)
    }

    private var diskMap: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if !mapPath.isEmpty {
                    Button(loc("Voltar")) {
                        mapPath.removeLast()
                        loadMap()
                    }
                    .buttonStyle(QuietStyle(tint: tint))
                }
                Text(mapPath.last ?? loc("Pasta de Usuário")).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 36)
            let top = max(entries.first?.size ?? 1, 1)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries) { e in
                        HoverRow(keepTrailing: true) {
                            Text(e.name).font(.system(size: 13, weight: e.dir ? .medium : .regular)).lineLimit(1).frame(width: 220, alignment: .leading)
                            LevelLine(part: Double(e.size) / Double(top), tint: tint)
                        } trailing: {
                            Text(bytesText(e.size)).font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary).frame(width: 76, alignment: .trailing)
                        }
                        .onTapGesture {
                            guard e.dir else { return }
                            mapPath.append(e.path)
                            loadMap()
                        }
                        .accessibilityAddTraits(e.dir ? .isButton : [])
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
    }

    private var startupList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(startup) { e in
                    HoverRow(keepTrailing: true) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(e.orphan ? loc("Não encontrado: %@", e.program) : e.program)
                                .font(.system(size: 12)).foregroundStyle(e.orphan ? Color.orange : Color.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.vertical, 5)
                    } trailing: {
                        Text(e.place).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
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
            if result == nil { message = loc("Não foi possível varrer. Tente novamente.") }
        }
    }

    private func clean() {
        let mode = channel.rawValue
        let ids = Array(picked)
        work {
            guard let out: CleanOutcome = await core.post("clean/run", ["mode": mode, "ids": ids]) else {
                message = loc("Sem contato com o core.")
                return
            }
            message = loc(out.moved == 1 ? "%@ item movido para o Lixo, %@." : "%@ itens movidos para o Lixo, %@.", "\(out.moved)", bytesText(out.bytes))
                + (out.failed.isEmpty ? "" : " " + loc(out.failed.count == 1 ? "%@ não pôde ser movido." : "%@ não puderam ser movidos.", "\(out.failed.count)"))
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
        message = loc(error == nil ? "Lixo esvaziado." : "Permita a automação do Finder em Ajustes do Sistema.")
        loadTrash()
    }
}
