import Foundation
import UserNotifications
import BackgroundTasks

@MainActor @Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let refreshTaskID = "com.ilyas.inkwell.refresh"

    var authorized = false
    var denied = false
    /// Set when the user taps a schedule notification; consumed by the root view.
    var pendingOpenRule: UUID?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        let s = await center.notificationSettings()
        authorized = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        denied = s.authorizationStatus == .denied
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        return ok
    }

    /// Rebuilds the weekly reminders for every enabled rule. Passing `enabled: false` clears them all.
    func reschedule(rules: [ScheduleRule], enabled: Bool) async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix("inkwell.rule.") }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard enabled else { return }
        if !authorized { _ = await requestAuthorization() }
        guard authorized else { return }

        for rule in rules where rule.isEnabled && rule.notify {
            for weekday in rule.weekdays {
                let content = UNMutableNotificationContent()
                content.title = rule.title
                content.body = "Your notebook for today is ready. Tap to start writing."
                content.sound = .default
                content.userInfo = ["rule": rule.id.uuidString]
                var comps = DateComponents()
                comps.weekday = weekday
                comps.hour = rule.notifyHour
                comps.minute = rule.notifyMinute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                let req = UNNotificationRequest(identifier: "inkwell.rule.\(rule.id.uuidString).\(weekday)",
                                                content: content, trigger: trigger)
                try? await center.add(req)
            }
        }
    }

    /// Posted when a schedule creates something while the app isn't on screen (background refresh).
    func notifyCreated(_ names: [String]) async {
        guard authorized, !names.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = names.count == 1 ? "New notebook ready" : "\(names.count) new notebooks ready"
        content.body = names.prefix(3).joined(separator: ", ")
        content.sound = .default
        let req = UNNotificationRequest(identifier: "inkwell.created.\(UUID().uuidString)", content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try? await center.add(req)
    }

    // MARK: Background refresh (iPad; the system decides when it actually runs)

    static func scheduleRefresh(rules: [ScheduleRule]) {
        #if !targetEnvironment(macCatalyst)
        let cal = Calendar.current
        let now = Date()
        var soonest: Date?
        for rule in rules where rule.isEnabled {
            for weekday in rule.weekdays {
                var comps = DateComponents()
                comps.weekday = weekday
                comps.hour = max(rule.notifyHour - 1, 0)
                comps.minute = rule.notifyMinute
                if let d = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime), soonest == nil || d < soonest! {
                    soonest = d
                }
            }
        }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = soonest ?? now.addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["rule"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { self.pendingOpenRule = id }
    }
}
