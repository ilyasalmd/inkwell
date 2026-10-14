import Foundation
import EventKit

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
}

@MainActor @Observable
final class CalendarService {
    @ObservationIgnored private let ek = EKEventStore()
    var authorized = false
    var denied = false
    var events: [CalendarEvent] = []

    init() { refresh() }

    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorized = (status == .fullAccess)
        denied = (status == .denied || status == .restricted)
        if authorized { loadEvents() }
    }

    func requestAccess() async {
        _ = try? await ek.requestFullAccessToEvents()
        refresh()
    }

    func loadEvents(days: Int = 7) {
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return }
        let predicate = ek.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = ek.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                CalendarEvent(id: "\(e.eventIdentifier ?? e.title ?? "event")-\(Int(e.startDate.timeIntervalSince1970))",
                              title: e.title ?? "Untitled event",
                              start: e.startDate, end: e.endDate,
                              calendar: e.calendar?.title ?? "")
            }
    }
}
