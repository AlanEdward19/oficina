import AppKit
import CoreAudio

/// Percebe chamadas pelo microfone: qual app está usando a entrada de áudio.
/// Não olha janelas, títulos nem tela.
///
/// O Core Audio avisa quando o microfone liga ou desliga; enquanto ele está
/// ligado, a cada 3 s ela confere qual processo está capturando áudio. Precisa
/// de 10 s seguidos de um app de chamada para começar e 20 s sem ele para acabar.
let unknownAudioObject = AudioObjectID(kAudioObjectUnknown)
let systemAudioObject = AudioObjectID(kAudioObjectSystemObject)

@MainActor
final class CallWatcher {
    struct CallApp: Equatable {
        let bundle: String
        let name: String
    }

    /// Prefixo do bundle → nome. Prefixo porque o áudio costuma sair de um processo auxiliar.
    static let known: [(String, String)] = [
        ("us.zoom.", "Zoom"),
        ("com.hnc.Discord", "Discord"),
        ("com.microsoft.teams", "Teams"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.skype.", "Skype"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("company.thebrowser.", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"),
        ("com.microsoft.edgemac", "Edge"),
    ]

    var onStart: (CallApp) -> Void = { _ in }
    var onEnd: (CallApp) -> Void = { _ in }
    private(set) var current: CallApp?

    private var candidate: (app: CallApp, since: Date)?
    private var silentSince: Date?
    private var timer: Timer?
    private var device = unknownAudioObject
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    func start() {
        var addr = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        defaultListener = block
        AudioObjectAddPropertyListenerBlock(systemAudioObject, &addr, DispatchQueue.main, block)
        attach()
    }

    /// Escuta o microfone padrão (e troca de escuta quando ele muda).
    private func attach() {
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        if device != unknownAudioObject, let old = deviceListener {
            AudioObjectRemovePropertyListenerBlock(device, &addr, DispatchQueue.main, old)
        }
        device = Self.defaultInput()
        guard device != unknownAudioObject else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.wake() }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(device, &addr, DispatchQueue.main, block)
        wake()
    }

    private func wake() {
        check()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let running = device != unknownAudioObject && Self.flag(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        let app = running ? Self.capturingApp() : nil
        let now = Date()
        if let cur = current {
            if app == cur {
                silentSince = nil
            } else if let s = silentSince {
                if now.timeIntervalSince(s) >= 20 {
                    current = nil
                    silentSince = nil
                    onEnd(cur)
                }
            } else {
                silentSince = now
            }
        } else if let app {
            if let c = candidate, c.app == app {
                if now.timeIntervalSince(c.since) >= 10 {
                    candidate = nil
                    current = app
                    onStart(app)
                }
            } else {
                candidate = (app, now)
            }
        } else {
            candidate = nil
        }
        // Sem microfone e sem chamada para encerrar: dorme até o próximo aviso.
        if !running, current == nil, candidate == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Processos de áudio do app (o principal e os auxiliares), para ouvir só ele.
    func processObjects(of app: CallApp) -> [AudioObjectID] {
        Self.processes().filter { Self.name(for: Self.bundle(of: $0) ?? "") == app.name }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInput() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = unknownAudioObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(systemAudioObject, &addr, 0, nil, &size, &id)
        return err == noErr ? id : unknownAudioObject
    }

    static func flag(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    static func processes() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = systemAudioObject
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func bundle(of process: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(process, &addr, 0, nil, &size, $0) }
        guard err == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func name(for bundle: String) -> String? {
        known.first { bundle.hasPrefix($0.0) }?.1
    }

    /// O app de chamada que está capturando áudio agora. Apps de chamada
    /// ganham de navegadores; a própria Oficina e o ditado ficam de fora.
    private static func capturingApp() -> CallApp? {
        let me = Bundle.main.bundleIdentifier ?? "dev.oficina.app"
        var browser: CallApp?
        for p in processes() where flag(p, kAudioProcessPropertyIsRunningInput) {
            guard let b = bundle(of: p), !b.hasPrefix(me), let name = name(for: b) else { continue }
            guard let root = known.first(where: { b.hasPrefix($0.0) })?.0 else { continue }
            let app = CallApp(bundle: root.hasSuffix(".") ? String(root.dropLast()) : root, name: name)
            if ["Chrome", "Safari", "Arc", "Firefox", "Brave", "Edge"].contains(name) {
                browser = browser ?? app
            } else {
                return app
            }
        }
        return browser
    }
}
