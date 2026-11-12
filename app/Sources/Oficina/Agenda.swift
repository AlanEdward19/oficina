import EventKit
import Foundation

/// A agenda do Mac, só se você ligar: título, início e fim dos eventos das
/// próximas horas. Serve para avisar antes de uma reunião e dar nome às
/// anotações. Nada de participantes, notas ou local.
@MainActor
final class Agenda {
    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    var onEvents: ([[String: Any]]) -> Void = { _ in }

    static let key = "usarAgenda"

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: Self.key) && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// Liga ou desliga. Ligar pede a permissão do Calendário uma vez.
    func setEnabled(_ on: Bool) async -> Bool {
        if on {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            UserDefaults.standard.set(granted, forKey: Self.key)
            refresh()
            return granted
        }
        UserDefaults.standard.set(false, forKey: Self.key)
        refresh()
        return true
    }

    private func upcoming() -> [EKEvent] {
        guard enabled else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(4 * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.availability != .free }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Manda à mente só título e horários. Desligada, manda a lista vazia.
    func refresh() {
        let events: [[String: Any]] = upcoming().prefix(10).map {
            ["title": ($0.title ?? "Reunião"), "start": Int($0.startDate.timeIntervalSince1970), "end": Int($0.endDate.timeIntervalSince1970)]
        }
        onEvents([["kind": "calendar", "events": events]])
    }

    /// O evento acontecendo agora (com 10 min de folga antes), para nomear a reunião.
    func current() -> String? {
        let now = Date()
        return upcoming().first { $0.startDate.addingTimeInterval(-600) <= now && $0.endDate > now }?.title
    }
}
