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
    let autoAccept: Bool
    let pairing: String?

    enum CodingKeys: String, CodingKey {
        case holder, name, room, since, reason, importance, bodies, network, pairing
        case autoAccept = "auto_accept"
    }

    var away: Bool { holder != "casa" }
}

struct CallResult: Decodable {
    let outcome: String
    let farewell: String?
    let notice: String?
    let message: String?
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

/// Os lugares onde a Faísca pode estar: o Mac e as caixas de som da casa.
struct DevicesView: View {
    @ObservedObject var core: Core
    var tint: Color
    @State private var error: String?
    @State private var editing: String?
    @State private var newName = ""
    @State private var newRoom = ""

    private var p: PresenceData? { core.presence }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dispositivos").font(Bench.display(26))
                    Text("Existe uma Faísca só. Ela vai até a caixa de som de outro cômodo, fala e ouve por lá, e volta quando a conversa acaba ou quando você chama.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                whereIs
                Rectangle().fill(Bench.line).frame(height: 1)
                places
                Rectangle().fill(Bench.line).frame(height: 1)
                network
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

    /// Onde ela está agora, com o avatar e o jeito de chamar de volta.
    private var whereIs: some View {
        HStack(spacing: 16) {
            FaiscaAvatar(size: 44, mood: .idle)
                .opacity(p?.away == true ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(p?.away == true ? "Na \(p?.room ?? "")" : "No Mac, com você").font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if p?.away == true {
                Button("Chamar de volta") { Task { _ = await core.callPresence(force: false) } }.buttonStyle(QuietStyle(tint: tint))
                Button("Vem agora") { Task { _ = await core.callPresence(force: true) } }.buttonStyle(SolidStyle())
            }
        }
    }

    private var subtitle: String {
        guard let p, p.away else { return "Ela vai aonde você pedir: “vai chamar a Ana na sala”." }
        let talk = ["alta": "ajudando com um pedido", "media": "conversando", "baixa": "esperando alguém falar"][p.importance ?? ""]
        return [talk, p.reason.isEmpty ? nil : "“\(p.reason)”"].compactMap { $0 }.joined(separator: " · ")
    }

    private var places: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Caixas e computadores").font(.system(size: 13, weight: .semibold))
            if (p?.bodies ?? []).isEmpty {
                Text("Nenhum ainda. Ligue uma caixa ou abra a Faísca no notebook: aparece aqui sozinho.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(p?.bodies ?? []) { b in
                if editing == b.id {
                    HStack(spacing: 16) {
                        HairField(prompt: "Nome", text: $newName).frame(width: 180)
                        HairField(prompt: "Cômodo", text: $newRoom).frame(width: 140)
                        Spacer()
                        Button("Salvar") { save(b.id) }.buttonStyle(SolidStyle())
                        Button("Cancelar") { editing = nil }.buttonStyle(QuietStyle(tint: tint))
                    }
                    .padding(.vertical, 6)
                } else {
                    row(b)
                }
            }
        }
    }

    private func row(_ b: BodyData) -> some View {
        let here = p?.holder == b.id
        return HoverRow(keepTrailing: here) {
            Image(systemName: b.kind == "pc" ? "laptopcomputer" : "hifispeaker.fill")
                .font(.system(size: 15))
                .foregroundStyle(here ? tint : b.online ? Color.primary : Bench.faint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.room).font(.system(size: 14, weight: here ? .semibold : .regular))
                Text("\(b.name) · \(b.online ? "ligada" : "desligada")").font(.caption).foregroundStyle(.secondary)
            }
        } trailing: {
            HStack(spacing: 14) {
                if here {
                    Text("Ela está aqui").font(.caption.weight(.semibold)).foregroundStyle(tint)
                } else if b.online {
                    Button("Levar a Faísca") { go(b.id) }.buttonStyle(QuietStyle(tint: tint))
                }
                Button("Renomear") {
                    newName = b.name
                    newRoom = b.room
                    editing = b.id
                }.buttonStyle(QuietStyle(tint: tint))
                Button("Esquecer") { Task { await core.forgetDevice(b.id) } }.buttonStyle(QuietStyle(tint: tint))
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 16) {
            setting("Aceitar dispositivos sozinha", "Uma caixa nova na sua rede entra sem código, e ela te avisa. Desligue se a rede for compartilhada.",
                    on: p?.autoAccept ?? true) { on in Task { error = await core.setAutoAccept(on) } }
            setting("Procurar dispositivos na rede", "Abre uma porta só para dispositivos, com token próprio para cada um. O resto da Oficina continua só neste Mac.",
                    on: p?.network ?? true) { on in Task { error = await core.setDeviceNetwork(on) } }
            Text("Caixa nova: no primeiro uso ela abre a rede “Faísca-Caixa”. Entre pelo celular, escolha o seu Wi-Fi e o cômodo, e pronto.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setting(_ title: String, _ detail: String, on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: set)).toggleStyle(BenchSwitch(tint: tint))
        }
    }

    private func go(_ id: String) {
        Task { error = await core.movePresence(to: id, text: "Oi! Cheguei.") }
    }

    private func save(_ id: String) {
        Task {
            error = await core.renameDevice(id, name: newName, room: newRoom)
            if error == nil { editing = nil }
        }
    }
}
