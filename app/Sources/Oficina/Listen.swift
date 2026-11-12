import AVFoundation
import CoreAudio
import Speech

/// Transcreve uma fonte de áudio em pedaços. Cada pedido de reconhecimento dura
/// até 25 s; quando termina, o texto final vira uma fala na reunião.
/// Recebe áudio de threads de tempo real, por isso cuida da própria trava.
final class SpeechChannel: @unchecked Sendable {
    let who: String
    private let recognizer: SFSpeechRecognizer?
    private let onDevice: Bool
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tasks: [SFSpeechRecognitionTask] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let onText: @Sendable (String, String) -> Void

    init(who: String, onText: @escaping @Sendable (String, String) -> Void) {
        self.who = who
        self.onText = onText
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR")) ?? SFSpeechRecognizer()
        onDevice = recognizer?.supportsOnDeviceRecognition ?? false
        rotate()
    }

    /// No Mac, sem rede: é o que mantém a reunião fora da internet.
    var isLocal: Bool { onDevice }

    /// Fecha o pedaço atual (o texto final chega depois) e abre outro.
    func rotate() {
        guard let recognizer, recognizer.isAvailable else { return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = false
        next.requiresOnDeviceRecognition = onDevice
        next.addsPunctuation = true
        let who = self.who
        let onText = self.onText
        let task = recognizer.recognitionTask(with: next) { result, _ in
            guard let result, result.isFinal else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onText(who, text) }
        }
        lock.lock()
        let old = request
        request = next
        tasks.append(task)
        if tasks.count > 4 { tasks.removeFirst() }
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        lock.lock()
        request?.append(converted)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let old = request
        request = nil
        lock.unlock()
        old?.endAudio()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        // O bloco pode ser @Sendable no SDK: nada de var capturada e alterada.
        let fed = Fed()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed.done {
                status.pointee = .noDataNow
                return nil
            }
            fed.done = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

private final class Fed: @unchecked Sendable {
    var done = false
}

/// Ouve só os processos do app da chamada, sem gravar a tela.
/// Pede a permissão "Gravação de áudio do sistema" (macOS 14.2+).
@available(macOS 14.2, *)
final class ProcessTap {
    private var tapID = unknownAudioObject
    private var aggregateID = unknownAudioObject
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "oficina.ouvir", qos: .userInitiated)

    enum TapError: Error { case failed(String, OSStatus) }

    func start(processes: [AudioObjectID], onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes.map { NSNumber(value: $0) })
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = unknownAudioObject
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else { throw TapError.failed("criar o tap", err) }
        tapID = tap

        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else { throw TapError.failed("ler o formato", err) }

        let output = Self.defaultOutputUID() ?? ""
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Oficina ouvindo",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = unknownAudioObject
        err = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard err == noErr else { throw TapError.failed("criar o dispositivo", err) }
        aggregateID = aggregate

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            onBuffer(buffer)
        }
        guard err == noErr else { throw TapError.failed("abrir o áudio", err) }
        err = AudioDeviceStart(aggregate, procID)
        guard err == noErr else { throw TapError.failed("começar a ouvir", err) }
    }

    func stop() {
        if aggregateID != unknownAudioObject {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = unknownAudioObject
        }
        procID = nil
        if tapID != unknownAudioObject {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = unknownAudioObject
        }
    }

    private static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = unknownAudioObject
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemAudioObject, &addr, 0, nil, &size, &device) == noErr else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
        guard err == noErr, let s = uid?.takeRetainedValue() else { return nil }
        return s as String
    }
}

/// Ouve a chamada que você autorizou: seu microfone vira "Você" e o áudio do
/// app da chamada vira "Outros". Só o texto vai para o core; o áudio não é guardado.
@MainActor
final class CallListener {
    private let core: Core
    private(set) var active = false
    private(set) var meeting: String?
    private var engine: AVAudioEngine?
    private var tap: AnyObject?
    private var me: SpeechChannel?
    private var others: SpeechChannel?
    private var rotation: Timer?
    var onChange: (Bool) -> Void = { _ in }

    init(core: Core) {
        self.core = core
    }

    /// Devolve o motivo, se não deu para começar.
    func start(app: CallWatcher.CallApp, processes: [AudioObjectID]) async -> String? {
        guard !active else { return nil }
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return "Preciso da permissão de Reconhecimento de Fala, em Ajustes do Sistema > Privacidade." }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return "Preciso da permissão do Microfone, em Ajustes do Sistema > Privacidade." }
        guard let id = await core.startMeeting(app: app.name, title: "") else { return "Não consegui falar com o core." }
        meeting = id

        let send: @Sendable (String, String) -> Void = { [weak core] who, text in
            let at = UInt64(Date().timeIntervalSince1970)
            Task { @MainActor in core?.appendMeeting(id, [["who": who, "text": text, "at": at]]) }
        }
        let mine = SpeechChannel(who: "Você", onText: send)
        guard mine.isLocal else {
            core.endMeeting(id)
            meeting = nil
            return "O reconhecimento de fala em português não está disponível no Mac. Baixe o idioma em Ajustes > Teclado > Ditado."
        }
        me = mine

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in mine.append(buffer) }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            core.endMeeting(id)
            meeting = nil
            return "Não consegui abrir o microfone."
        }
        self.engine = engine

        var note: String?
        if #available(macOS 14.2, *), !processes.isEmpty {
            let theirs = SpeechChannel(who: "Outros", onText: send)
            let t = ProcessTap()
            do {
                try t.start(processes: processes) { theirs.append($0) }
                tap = t
                others = theirs
            } catch {
                t.stop()
                note = "Não consegui ouvir o \(app.name); vou anotar só a sua voz."
            }
        } else {
            note = "Neste macOS só consigo anotar a sua voz."
        }

        let timer = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.me?.rotate()
                self?.others?.rotate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rotation = timer
        active = true
        onChange(true)
        return note.map { "Ouvindo. \($0)" }
    }

    func stop() {
        guard active else { return }
        active = false
        rotation?.invalidate()
        rotation = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if #available(macOS 14.2, *) { (tap as? ProcessTap)?.stop() }
        tap = nil
        me?.stop()
        others?.stop()
        me = nil
        others = nil
        onChange(false)
        // O texto final do último pedaço chega um pouco depois.
        if let id = meeting {
            meeting = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.core.endMeeting(id) }
        }
    }
}
