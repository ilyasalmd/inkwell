import SwiftUI
import BackgroundTasks

@main
struct InkwellApp: App {
    @State private var store = LibraryStore()
    @State private var calendar = CalendarService()
    @State private var settings = AppSettings()
    @State private var notifications = NotificationService()
    @State private var linked = LinkedFolderService()
    @State private var editor = EditorModel()
    @State private var tabs = NotebookTabs()

    init() {
        #if !targetEnvironment(macCatalyst)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: NotificationService.refreshTaskID, using: nil) { task in
            Self.handleRefresh(task as! BGAppRefreshTask)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(calendar)
                .environment(settings)
                .environment(notifications)
                .environment(linked)
                .environment(editor)
                .environment(tabs)
                .environment(\.inkTheme, settings.theme)
                .tint(settings.theme.accent)
                .preferredColorScheme(settings.appearance.scheme)
        }
    }

    #if !targetEnvironment(macCatalyst)
    /// Runs when the system grants background time: create anything the schedules owe, then tell the user.
    private static func handleRefresh(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            let store = LibraryStore()
            let created = store.runSchedules()
            store.flush()
            if created > 0, UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true {
                let service = NotificationService()
                await service.refreshStatus()
                await service.notifyCreated(store.lastCreated.map(\.name))
            }
            NotificationService.scheduleRefresh(rules: store.rules)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }
    #endif
}
