import AVFoundation
import AppKit
import Speech
import SwiftUI

// MARK: Modelos

struct BodyData: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let room: String
    let kind: String
    let online: Bool
}

/// Onde a Faísca está: "casa" é o Mac; os outros são dispositivos.
struct PresenceData: Decodable, Equatable {
    let holder: String
    let name: String
    let room: String
    let since: UInt64
    let reason: String
    let importance: String?
    let bodies: [BodyData]
    let network: Bool
    let pairing: String?

    var away: Bool { holder != "casa" }
}

struct CallResult: Decodable {
    let outcome: String
    let farewell: String?
    let notice: String?
    let message: String?
}

struct PairingData: Decodable {
    let code: String
    let port: String
}

struct VoiceJobData: Decodable {
    let id: String
    let kind: String
    let text: String?
}

// MARK: Voz dos dispositivos

/// O Mac é a voz da caixa de som: transforma texto em fala (WAV 16 kHz) e a
/// fala gravada lá em texto, sem internet.
@MainActor
final class DeviceVoice {
    private let core: Core
    private var synthesizers: [String: AVSpeechSynthesizer] = [:]

    init(core: Core) {
        self.core = core
    }

    func handle(_ job: VoiceJobData) {
        switch job.kind {
        case "render": if let t = job.text { render(job.id, t) }
        case "transcribe": transcribe(job.id)
        default: break
        }
    }

    private func render(_ id: String, _ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "pt-BR")
        let synth = AVSpeechSynthesizer()
        synthesizers[id] = synth
        let pcm = PCMCollector(target: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!)
        synth.write(utterance) { [weak self] buffer in
            guard let buffer = buffer as? AVAudioPCMBuffer else { return }
            if buffer.frameLength == 0 {
                let wav = pcm.wav()
                Task { @MainActor in
                    self?.synthesizers[id] = nil
                    await self?.core.uploadVoice(id, wav: wav)
                }
            } else {
                pcm.append(buffer)
            }
        }
    }

    private func transcribe(_ id: String) {
        Task {
            guard let wav = await core.voiceClip(id) else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("oficina-\(id).wav")
            guard (try? wav.write(to: url)) != nil else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                    SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
                }
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR")), recognizer.supportsOnDeviceRecognition else { return }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            let text: String = await withCheckedContinuation { c in
                let once = Once()
                recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        once.run { c.resume(returning: result.bestTranscription.formattedString) }
                    } else if error != nil {
                        once.run { c.resume(returning: "") }
                    }
                }
            }
            await core.voiceText(id, text)
        }
    }
}

/// Garante que uma continuação só é retomada uma vez.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

/// Junta o áudio sintetizado, já convertido, e monta o WAV.
private final class PCMCollector: @unchecked Sendable {
    private let resampler: Resampler
    private let format: AVAudioFormat
    private var data = Data()
    private let lock = NSLock()

    init(target: AVAudioFormat) {
        format = target
        resampler = Resampler(target: target)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let out = resampler.convert(buffer), let ch = out.int16ChannelData else { return }
        let bytes = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        lock.lock()
        data.append(bytes)
        lock.unlock()
    }

    func wav() -> Data {
        lock.lock()
        let pcm = data
        lock.unlock()
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        let rate = UInt32(format.sampleRate)
        h.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + pcm.count))
        h.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        h.append("data".data(using: .ascii)!)
        u32(UInt32(pcm.count))
        return h + pcm
    }
}

// MARK: Tela

/// Os lugares onde a Faísca pode estar: o Mac e as caixas de som pareadas.
struct DevicesView: View {
    @ObservedObject var core: Core
    var tint: Color
    @State private var pairing: PairingData?
    @State private var error: String?
    @State private var busy = false

    private var p: PresenceData? { core.presence }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dispositivos").font(Bench.display(26))
                    Text("Existe uma Faísca só. Ela pode ir até uma caixa de som em outro cômodo, falar e ouvir por lá, e volta quando a conversa acaba ou quando você chama.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                whereIs
                Rectangle().fill(Bench.line).frame(height: 1)
                list
                Rectangle().fill(Bench.line).frame(height: 1)
                pair
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .padding(.horizontal, 44)
            .padding(.top, 52)
            .padding(.bottom, 40)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Bench.canvas)
        .ignoresSafeArea()
    }

    private var whereIs: some View {
        HStack(spacing: 16) {
            Circle().fill(tint).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(p?.away == true ? "Na \(p?.room ?? "")" : "No Mac").font(.system(size: 17, weight: .semibold))
                if let p, p.away {
                    Text([p.reason, p.importance.map { "conversa \($0)" }].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if p?.away == true {
                Button("Chamar de volta") { Task { _ = await core.callPresence(force: false) } }.buttonStyle(QuietStyle(tint: tint))
                Button("Vem agora") { Task { _ = await core.callPresence(force: true) } }.buttonStyle(SolidStyle())
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Caixas de som").font(.system(size: 13, weight: .semibold))
            if (p?.bodies ?? []).isEmpty {
                Text("Nenhuma ainda.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(p?.bodies ?? []) { b in
                HoverRow(keepTrailing: p?.holder == b.id) {
                    Circle().fill(b.online ? tint : Bench.line).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name).font(.system(size: 13, weight: p?.holder == b.id ? .semibold : .regular))
                        Text("\(b.room) · \(b.online ? "ligada" : "desligada")").font(.caption).foregroundStyle(.secondary)
                    }
                } trailing: {
                    HStack(spacing: 14) {
                        if p?.holder == b.id {
                            Text("Ela está aqui").font(.caption).foregroundStyle(tint)
                        } else if b.online {
                            Button("Levar a Faísca") { go(b.id) }.buttonStyle(QuietStyle(tint: tint))
                        }
                        Button("Esquecer") { Task { await core.forgetDevice(b.id) } }.buttonStyle(QuietStyle(tint: tint))
                    }
                }
            }
        }
    }

    private var pair: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Aceitar dispositivos na rede").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { p?.network ?? false }, set: { on in Task { error = await core.setDeviceNetwork(on) } }))
                    .toggleStyle(BenchSwitch(tint: tint))
            }
            Text("Abre uma porta só para dispositivos, com token próprio. O resto da Oficina continua só neste Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if let code = pairing?.code ?? p?.pairing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(code).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(tint).textSelection(.enabled)
                    Text("Vale 10 minutos e uma vez. Na caixa, preencha o código, o cômodo e o endereço deste Mac (porta \(port)). Para testar sem caixa:")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("python3 devices/caixa/simulador.py --codigo \(code) --comodo Sala")
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            Button(busy ? "Gerando…" : "Parear caixa de som") { startPairing() }
                .buttonStyle(SolidStyle())
                .disabled(busy)
        }
    }

    private var port: String { (pairing?.port ?? "0.0.0.0:7879").split(separator: ":").last.map(String.init) ?? "7879" }

    private func go(_ id: String) {
        Task { error = await core.movePresence(to: id, text: "Oi! Cheguei.") }
    }

    private func startPairing() {
        busy = true
        Task {
            pairing = await core.startPairing()
            if pairing == nil { error = "Não consegui abrir a porta dos dispositivos." }
            busy = false
        }
    }
}
