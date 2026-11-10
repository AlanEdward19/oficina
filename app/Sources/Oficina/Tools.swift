import AppKit
import ApplicationServices
import Carbon.HIToolbox
import IOKit.ps
import IOKit.pwr_mgt
import SwiftUI
import Vision

// Utilitários do dia a dia. Nada aqui roda em ciclo sem pedido: cada recurso
// só existe depois de ligado, e o monitor só mede com a janela aberta.

struct ClipEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var pinned = false
    var date = Date()
}

enum Snap: UInt32, CaseIterable {
    case left = 2, right, top, bottom, full

    var key: Int {
        switch self {
        case .left: return kVK_LeftArrow
        case .right: return kVK_RightArrow
        case .top: return kVK_UpArrow
        case .bottom: return kVK_DownArrow
        case .full: return kVK_Return
        }
    }
}

private let tracking = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "si", "ref_src", "yclid", "_hsenc", "_hsmi"]

/// Tira do link só os parâmetros de rastreamento.
func cleanedURL(_ text: String) -> String? {
    guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme?.hasPrefix("http") == true, let items = parts.queryItems else { return nil }
    let kept = items.filter { !tracking.contains($0.name.lowercased()) }
    guard kept.count != items.count else { return nil }
    parts.queryItems = kept.isEmpty ? nil : kept
    return parts.string
}

private let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Oficina")

@MainActor
final class Tools: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var tab = "sistema"
    @Published var toast: String?

    // MARK: Manter acordado

    @Published private(set) var awakeUntil: Date?
    @Published private(set) var awake = false
    @Published var awakeChoice = 0
    private var assertion: IOPMAssertionID = 0
    private var awakeTimer: Timer?

    func keepAwake(minutes: Int?) {
        stopAwake()
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Oficina: manter acordado" as CFString, &assertion) == kIOReturnSuccess else { return }
        awake = true
        if let minutes {
            awakeUntil = Date().addingTimeInterval(Double(minutes) * 60)
            awakeTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.stopAwake() } }
        }
    }

    func stopAwake() {
        awakeTimer?.invalidate()
        awakeTimer = nil
        awakeUntil = nil
        if awake { IOPMAssertionRelease(assertion) }
        awake = false
    }

    // MARK: Área de transferência

    @Published private(set) var clips: [ClipEntry] = []
    private var clipTimer: Timer?
    private var lastChange = 0
    private var clipFile: URL { supportDir.appendingPathComponent("clipboard.json") }
    private let maxClips = 200
    private let maxClipChars = 16_000

    var clipboardOn: Bool {
        get { defaults.bool(forKey: "clipboardOn") }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "clipboardOn")
            applyClipboard()
        }
    }

    private func applyClipboard() {
        clipTimer?.invalidate()
        clipTimer = nil
        guard clipboardOn else { return }
        if clips.isEmpty, let data = try? Data(contentsOf: clipFile), let saved = try? JSONDecoder().decode([ClipEntry].self, from: data) { clips = saved }
        lastChange = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollClipboard() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        clipTimer = t
    }

    private func pollClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        let types = board.types?.map(\.rawValue) ?? []
        // Gerenciadores de senha marcam o que não deve ser guardado.
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxClipChars else { return }
        if let i = clips.firstIndex(where: { $0.text == text }) {
            var e = clips.remove(at: i)
            e.date = Date()
            clips.insert(e, at: 0)
        } else {
            clips.insert(ClipEntry(text: text), at: 0)
        }
        trimClips()
        saveClips()
    }

    private func trimClips() {
        while clips.count > maxClips, let i = clips.lastIndex(where: { !$0.pinned }) { clips.remove(at: i) }
    }

    private func saveClips() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: clipFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clipFile.path)
    }

    func copy(_ text: String, say: String = "Copiado") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChange = NSPasteboard.general.changeCount
        show(say)
    }

    func togglePin(_ e: ClipEntry) {
        guard let i = clips.firstIndex(of: e) else { return }
        clips[i].pinned.toggle()
        saveClips()
    }

    func removeClip(_ e: ClipEntry) {
        clips.removeAll { $0.id == e.id }
        saveClips()
    }

    func clearClips() {
        clips.removeAll { !$0.pinned }
        saveClips()
    }

    /// Avisos também saem pela Faísca: o painel pode já ter fechado.
    var onToast: (String) -> Void = { _ in }

    func show(_ text: String) {
        onToast(text)
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    // MARK: Janelas

    private var snapKeys: [EventHotKeyRef] = []

    var snapOn: Bool {
        get { defaults.bool(forKey: "snapOn") }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: "snapOn")
            applySnap()
        }
    }

    private func applySnap() {
        snapKeys.forEach { UnregisterEventHotKey($0) }
        snapKeys = []
        guard snapOn else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        for s in Snap.allCases {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(s.key), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4F46_4943), id: s.rawValue), GetApplicationEventTarget(), 0, &ref)
            if let ref { snapKeys.append(ref) }
        }
    }

    /// Encaixa a janela da frente usando a área útil da tela em que ela está.
    func snap(_ s: Snap) {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else {
            show("Permita a Acessibilidade em Ajustes do Sistema")
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success, let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { return }
        let w = window as! AXUIElement
        var posValue: CFTypeRef?
        var origin = CGPoint.zero
        if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posValue) == .success, let posValue { AXValueGetValue(posValue as! AXValue, .cgPoint, &origin) }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: origin.x + 1, y: primary - origin.y - 1)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        var r = area
        switch s {
        case .left: r.size.width /= 2
        case .right: r.size.width /= 2; r.origin.x += r.width
        case .top: r.size.height /= 2; r.origin.y += r.height
        case .bottom: r.size.height /= 2
        case .full: break
        }
        var pos = CGPoint(x: r.minX, y: primary - r.maxY)
        var size = r.size
        if let p = AXValueCreate(.cgPoint, &pos), let z = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p)
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, z)
            // Algumas janelas só aceitam o tamanho final depois de mover.
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p)
        }
    }

    // MARK: Ações rápidas

    /// Atividade que o Finder registra com "ocultar ícones da mesa".
    var desktopHidden: Bool { UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool == false }

    func toggleDesktopIcons() {
        let hide = !desktopHidden
        run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hide ? "false" : "true"])
        run("/usr/bin/killall", ["Finder"])
        objectWillChange.send()
    }

    func toggleDarkMode() {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")?.executeAndReturnError(&error)
        if error != nil { show("Permita a automação em Ajustes do Sistema") }
    }

    func screenOff() { run("/usr/bin/pmset", ["displaysleepnow"]) }

    func ejectDisks() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var count = 0
        for v in volumes where (try? v.resourceValues(forKeys: Set(keys)))?.volumeIsEjectable == true {
            if (try? NSWorkspace.shared.unmountAndEjectDevice(at: v)) != nil { count += 1 }
        }
        show(count == 0 ? "Nenhum disco para ejetar" : "\(count) disco(s) ejetado(s)")
    }

    private func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    func pickColor() {
        NSColorSampler().show { [weak self] color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            MainActor.assumeIsolated { self?.copy(hex, say: "\(hex) copiado") }
        }
    }

    func screenshotToClipboard() { run("/usr/sbin/screencapture", ["-i", "-c"]) }

    /// Seleciona uma área da tela e lê o texto ou QR code, sem sair do Mac.
    func recognizeScreen() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("oficina-ocr-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", file.path]
        p.terminationHandler = { [weak self] _ in
            let found = Tools.readImage(file)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let found { self?.copy(found, say: "Texto copiado") } else { self?.show("Não encontrei texto") }
                }
            }
        }
        try? p.run()
    }

    nonisolated private static func readImage(_ file: URL) -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let codes = VNDetectBarcodesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLanguages = ["pt-BR", "en-US"]
        text.usesLanguageCorrection = true
        try? VNImageRequestHandler(url: file).perform([codes, text])
        if let payload = codes.results?.compactMap(\.payloadStringValue).first { return payload }
        let lines = text.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func cleanClipboardURL() {
        guard let text = NSPasteboard.general.string(forType: .string), let clean = cleanedURL(text) else {
            show("Nenhum rastreador no link copiado")
            return
        }
        copy(clean, say: "Link limpo copiado")
    }

    func plainClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        copy(text, say: "Agora é só colar sem formatação")
    }

    func restoreOnLaunch() {
        applyClipboard()
        applySnap()
    }
}

// MARK: Medições

struct SystemSnapshot: Equatable {
    var cpu = 0.0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var battery: Int?
    var charging = false
    var down: UInt64 = 0
    var up: UInt64 = 0
}

@MainActor
final class SystemProbe: ObservableObject {
    @Published var now = SystemSnapshot()
    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: (down: UInt64, up: UInt64)?

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        var s = now
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        if ok == KERN_SUCCESS {
            let (user, sys, nice, idle) = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.3), UInt64(info.cpu_ticks.2))
            let busy = user + sys + nice
            let total = busy + idle
            if let l = lastTicks, total > l.total { s.cpu = Double(busy - l.busy) / Double(total - l.total) }
            lastTicks = (busy, total)
        }
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmOk = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) } }
        if vmOk == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            s.memoryUsed = (UInt64(vm.active_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        if let a = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            s.diskFree = (a[.systemFreeSize] as? Int64) ?? 0
            s.diskTotal = (a[.systemSize] as? Int64) ?? 0
        }
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef], let first = list.first,
           let d = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] {
            s.battery = d[kIOPSCurrentCapacityKey] as? Int
            s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
        }
        let net = Self.netBytes()
        if let l = lastNet {
            s.down = (net.down &- l.down) / 2
            s.up = (net.up &- l.up) / 2
        }
        lastNet = net
        now = s
    }

    private static func netBytes() -> (down: UInt64, up: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }
        var out: (down: UInt64, up: UInt64) = (0, 0)
        var p = head
        while let a = p {
            if a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), String(cString: a.pointee.ifa_name).hasPrefix("en"), let d = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                out.down += UInt64(d.pointee.ifi_ibytes)
                out.up += UInt64(d.pointee.ifi_obytes)
            }
            p = a.pointee.ifa_next
        }
        return out
    }
}

struct PortEntry: Identifiable, Equatable {
    var id: String { "\(pid)-\(port)" }
    let command: String
    let pid: Int32
    let port: String
}

/// Saída do `lsof -nP -iTCP -sTCP:LISTEN`, uma linha por porta.
func parsePorts(_ output: String) -> [PortEntry] {
    var seen = Set<String>()
    return output.split(separator: "\n").dropFirst().compactMap { line -> PortEntry? in
        let f = line.split(whereSeparator: \.isWhitespace)
        guard f.count >= 9, let pid = Int32(f[1]), let port = f[8].split(separator: ":").last else { return nil }
        let e = PortEntry(command: String(f[0]), pid: pid, port: String(port))
        return seen.insert(e.id).inserted ? e : nil
    }
}

// MARK: Painel da barra de menus

/// Velocidade curta: a coluna da rede não comporta "bytes/s".
private func rateText(_ n: UInt64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useKB, .useMB, .useGB]
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: Int64(min(n, UInt64(Int64.max)))) + "/s"
}

private func memoryText(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))), countStyle: .memory)
}

/// Ícone da navegação do painel.
private struct TabIcon: View {
    let title: String
    let icon: String
    let on: Bool
    var tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.primary : hover ? Color.primary : Bench.faint)
                    .frame(width: 26, height: 18)
                Rectangle().fill(on ? tint : .clear).frame(width: 16, height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(loc(title))
        .accessibilityLabel(loc(title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Atalho em grade: o símbolo e o nome, sem caixa.
private struct ActionTile: View {
    let title: String
    let icon: String
    var tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 19, weight: .light)).frame(height: 24).accessibilityHidden(true)
                Text(loc(title)).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(hover ? tint : Color.primary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(loc(title))
    }
}

struct MenuBarPanel: View {
    @ObservedObject var tools: Tools
    var tint: Color
    let openCleaner: () -> Void
    let close: () -> Void
    @StateObject private var probe = SystemProbe()
    @State private var search = ""
    @State private var running: [NSRunningApplication] = []
    @State private var ports: [PortEntry] = []
    @State private var confirming: String?
    @AppStorage("rascunho") private var notes = ""
    @AppStorage("dockClickHide") private var dockClickHide = true

    private let tabs: [(id: String, title: String, icon: String)] = [
        ("sistema", "Sistema", "gauge.with.dots.needle.33percent"),
        ("acoes", "Controles", "switch.2"),
        ("clipboard", "Cópias", "doc.on.clipboard"),
        ("apps", "Apps Abertos", "macwindow"),
        ("portas", "Portas", "cable.connector"),
        ("notas", "Rascunho", "note.text"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Bench.line).frame(height: 1).padding(.horizontal, 18)
            footer
        }
        .padding(.top, 13)
        .frame(width: 340, height: 482)
        .background(Bench.canvas.padding(-40))
        .onChange(of: tools.tab) { enter() }
        .onAppear(perform: enter)
        .onDisappear { probe.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc(tabs.first { $0.id == tools.tab }?.title ?? "")).font(Bench.display(26)).tracking(-0.6).lineLimit(1)
            HStack(spacing: 18) {
                ForEach(tabs, id: \.id) { t in
                    TabIcon(title: t.title, icon: t.icon, on: tools.tab == t.id, tint: tint) { tools.tab = t.id }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(loc("Limpeza do Disco…")) {
                close()
                openCleaner()
            }
            Spacer(minLength: 4)
            if let t = tools.toast {
                Text(t).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else if tools.tab == "apps" {
                Menu {
                    Button(loc("Todos Menos o da Frente")) {
                        let front = NSWorkspace.shared.frontmostApplication
                        running.filter { $0 != front }.forEach { $0.terminate() }
                        refreshAppsSoon()
                    }
                    Button(loc("Todos")) { running.forEach { $0.terminate() }; refreshAppsSoon() }
                } label: {
                    Text(loc("Encerrar Vários")).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .buttonStyle(QuietStyle(tint: tint))
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private func enter() {
        if tools.tab == "sistema" { probe.start() } else { probe.stop() }
        if tools.tab == "apps" { loadApps() }
        if tools.tab == "portas" { loadPorts() }
        confirming = nil
    }

    @ViewBuilder private var page: some View {
        switch tools.tab {
        case "acoes": controls
        case "clipboard": clipboard
        case "apps": apps
        case "portas": portList
        case "notas": scratch
        default: system
        }
    }

    private func emptyNote(_ t: String) -> some View {
        Text(loc(t)).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sistema

    private var system: some View {
        let n = probe.now
        return VStack(spacing: 20) {
            meter("CPU", "\(Int(n.cpu * 100))%", n.cpu)
            meter("Memória", "\(memoryText(n.memoryUsed)) / \(memoryText(n.memoryTotal))", Double(n.memoryUsed) / Double(max(n.memoryTotal, 1)))
            meter("Disco", loc("%@ livres", bytesText(UInt64(max(n.diskFree, 0)))), 1 - Double(n.diskFree) / Double(max(n.diskTotal, 1)))
            if let b = n.battery {
                meter(n.charging ? "Bateria, Carregando" : "Bateria", "\(b)%", Double(b) / 100, warnHigh: false)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(loc("Rede")).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text("↓ \(rateText(n.down))  ↑ \(rateText(n.up))").font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private func meter(_ title: String, _ value: String, _ part: Double, warnHigh: Bool = true) -> some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc(title)).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            LevelLine(part: part, tint: warnHigh && part >= 0.9 ? .red : tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Controles

    private var awakeChoice: Binding<String> {
        Binding(
            get: { String(tools.awake ? (tools.awakeUntil == nil ? -1 : tools.awakeChoice) : 0) },
            set: { raw in
                let v = Int(raw) ?? 0
                tools.awakeChoice = v
                if v == 0 { tools.stopAwake() } else { tools.keepAwake(minutes: v < 0 ? nil : v) }
            }
        )
    }

    private func switchRow(_ title: String, note: String? = nil, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: 6) {
                Text(loc(title)).font(.system(size: 13)).lineLimit(1)
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(Bench.faint) }
            }
        }
        .toggleStyle(RowSwitch(tint: tint))
        .frame(height: 28)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                switchRow("Histórico de Cópias", Binding(get: { tools.clipboardOn }, set: { tools.clipboardOn = $0 }))
                switchRow("Encaixar Janelas", note: "⌃⌥ e Setas", Binding(get: { tools.snapOn }, set: { tools.snapOn = $0 }))
                switchRow("Clique na Dock Oculta o App", $dockClickHide)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(loc("Manter Acordado")).font(.system(size: 13))
                WordPicker(options: [("0", "Desligado"), ("30", "30 min"), ("60", "1 h"), ("180", "3 h"), ("-1", "Sempre")], selection: awakeChoice, tint: tint)
            }
            Rectangle().fill(Bench.line).frame(height: 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 13) {
                ActionTile(title: "Ler Texto", icon: "text.viewfinder", tint: tint) { act(tools.recognizeScreen) }
                ActionTile(title: "Capturar", icon: "camera.viewfinder", tint: tint) { act(tools.screenshotToClipboard) }
                ActionTile(title: "Conta-gotas", icon: "eyedropper", tint: tint) { act(tools.pickColor) }
                ActionTile(title: "Limpar Link", icon: "link", tint: tint) { tools.cleanClipboardURL() }
                ActionTile(title: "Sem Formatação", icon: "textformat", tint: tint) { tools.plainClipboard() }
                ActionTile(title: "Modo Escuro", icon: "circle.lefthalf.filled", tint: tint) { tools.toggleDarkMode() }
                ActionTile(title: tools.desktopHidden ? "Mostrar Mesa" : "Ocultar Mesa", icon: "menubar.dock.rectangle", tint: tint) { tools.toggleDesktopIcons() }
                ActionTile(title: "Apagar Tela", icon: "moon", tint: tint) { act(tools.screenOff) }
                ActionTile(title: "Ejetar Discos", icon: "eject", tint: tint) { tools.ejectDisks() }
            }
        }
        .padding(.horizontal, 18)
    }

    /// O que usa a tela inteira precisa do painel fora do caminho.
    private func act(_ run: @escaping () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: run)
    }

    // MARK: Rascunho

    private var scratch: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notes).font(.system(size: 14)).scrollContentBackground(.hidden)
            if notes.isEmpty {
                Text(loc("Escreva o que quiser guardar aqui."))
                    .font(.system(size: 14))
                    .foregroundStyle(Bench.faint)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: Área de transferência

    @ViewBuilder private var clipboard: some View {
        if !tools.clipboardOn {
            VStack(alignment: .leading, spacing: 14) {
                Text(loc("Guarda textos copiados só neste Mac e ignora o que gerenciadores de senha marcam."))
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                Button(loc("Ligar histórico")) { tools.clipboardOn = true }.buttonStyle(SolidStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let shown = tools.clips.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }.sorted { $0.pinned && !$1.pinned }
            VStack(spacing: 8) {
                HairField(prompt: "Buscar", text: $search).padding(.horizontal, 18)
                if shown.isEmpty {
                    emptyNote(search.isEmpty ? "Nada copiado ainda" : "Nada encontrado")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(shown) { clipRow($0) } }
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
    }

    private func clipRow(_ e: ClipEntry) -> some View {
        HoverRow(keepTrailing: e.pinned) {
            Text(e.text).lineLimit(2).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
        } trailing: {
            Button {
                tools.togglePin(e)
            } label: {
                Image(systemName: e.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(QuietStyle(tint: tint))
            .help(loc(e.pinned ? "Desafixar" : "Fixar"))
            .accessibilityLabel(loc(e.pinned ? "Desafixar" : "Fixar"))
        }
        .onTapGesture { tools.copy(e.text) }
        .contextMenu {
            Button(loc(e.pinned ? "Desafixar" : "Fixar")) { tools.togglePin(e) }
            Button(loc("Apagar"), role: .destructive) { tools.removeClip(e) }
        }
    }

    // MARK: Apps e portas

    private func loadApps() {
        running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func refreshAppsSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { loadApps() } }

    private var apps: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(running, id: \.processIdentifier) { a in
                    HoverRow {
                        if let i = a.icon { Image(nsImage: i).resizable().frame(width: 22, height: 22).accessibilityHidden(true) }
                        Text(a.localizedName ?? "App").font(.system(size: 13)).lineLimit(1)
                    } trailing: {
                        Button(loc("Encerrar")) { a.terminate(); refreshAppsSoon() }.buttonStyle(QuietStyle(tint: .red))
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func loadPorts() {
        Task.detached {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let list = parsePorts(String(decoding: data, as: UTF8.self))
            await MainActor.run { ports = list }
        }
    }

    @ViewBuilder private var portList: some View {
        if ports.isEmpty {
            emptyNote("Nenhuma porta em uso")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(ports) { portRow($0) } }
                    .padding(.horizontal, 10)
            }
        }
    }

    private func portRow(_ p: PortEntry) -> some View {
        HoverRow(keepTrailing: confirming == p.id) {
            Text(p.port).font(.system(size: 14, weight: .semibold)).monospacedDigit().frame(width: 56, alignment: .leading)
            Text(p.command).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        } trailing: {
            HStack(spacing: 12) {
                if confirming == p.id {
                    Button(loc("Cancelar")) { confirming = nil }.buttonStyle(QuietStyle(tint: tint))
                    Button(loc("Encerrar")) {
                        kill(p.pid, SIGTERM)
                        confirming = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loadPorts() }
                    }
                    .buttonStyle(QuietStyle(tint: .red))
                } else {
                    Button(loc("Encerrar…")) { confirming = p.id }.buttonStyle(QuietStyle(tint: .red))
                }
            }
        }
    }
}

/// Linha inteira: o rótulo à esquerda e a chave à direita.
private struct RowSwitch: ToggleStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 4)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(BenchSwitch(tint: tint))
        }
    }
}
