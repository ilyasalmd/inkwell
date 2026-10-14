import SwiftUI

struct SchedulesView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(AppSettings.self) private var settings
    @Environment(\.inkTheme) private var theme
    @State private var editing: ScheduleRule?
    @State private var isNew = false
    @State private var banner: String?

    var body: some View {
        @Bindable var store = store
        return List {
            Section {
                Text("Schedules create folders or notebooks for you on the days you choose, for example a new Cornell-notes notebook for every lecture.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.rules.isEmpty {
                Section {
                    ContentUnavailableView("No schedules yet", systemImage: "calendar.badge.clock",
                                           description: Text("Tap + to automate your first one."))
                }
            }
            ForEach($store.rules) { $rule in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.title).font(.headline)
                        Text(summary(rule)).font(.footnote).foregroundStyle(.secondary)
                        Text("\(rule.generated.count) created so far").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if rule.notify { Image(systemName: "bell.fill").font(.caption).foregroundStyle(.secondary) }
                    Toggle("", isOn: $rule.isEnabled).labelsHidden()
                        .onChange(of: rule.isEnabled) { _, _ in
                            store.saveRules(); store.runSchedules()
                            Task { await notifications.reschedule(rules: store.rules, enabled: settings.notificationsEnabled) }
                        }
                }
                .contentShape(Rectangle())
                .onTapGesture { isNew = false; editing = rule }
            }
            .onDelete { idx in
                store.rules.remove(atOffsets: idx)
                store.saveRules()
                Task { await notifications.reschedule(rules: store.rules, enabled: settings.notificationsEnabled) }
            }
        }
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Run now") {
                    let n = store.runSchedules()
                    banner = n == 0 ? "Everything is already up to date." : "Created \(n) new item\(n == 1 ? "" : "s")."
                }
                Button {
                    isNew = true
                    editing = ScheduleRule(title: "New course")
                } label: { Image(systemName: "plus") }
            }
        }
        .alert(banner ?? "", isPresented: Binding(get: { banner != nil }, set: { if !$0 { banner = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $editing) { rule in
            ScheduleEditor(rule: rule, isNew: !store.rules.contains { $0.id == rule.id })
                .presentationSizing(.page)
        }
    }

    private func summary(_ r: ScheduleRule) -> String {
        let cal = Calendar.current
        let days = r.weekdays.sorted().map { cal.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        let dest = store.node(r.destinationID)?.name ?? "All Notes"
        return "\(days.isEmpty ? "No days" : days) · \(r.output == .folder ? "folder" : "notebook") in \(dest) · \(r.template.title)"
    }
}

struct ScheduleEditor: View {
    @State var rule: ScheduleRule
    let isNew: Bool
    @Environment(LibraryStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(AppSettings.self) private var settings
    @State private var useCover = false
    @State private var cover = CoverDesign.random()
    @Environment(\.dismiss) private var dismiss
    @State private var hasEnd = false
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var pickFolder = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    TextField("Title (e.g. Linear Algebra)", text: $rule.title)
                    Picker("Create", selection: $rule.output) {
                        ForEach(ScheduleRule.Output.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Name format", text: $rule.nameFormat)
                    Text("Use {title}, {n} (session number) and {date}. Example: “\(LibraryStore.format(rule.nameFormat, title: rule.title, n: 3, date: Date()))”")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("When") {
                    HStack {
                        ForEach(1...7, id: \.self) { d in
                            let on = rule.weekdays.contains(d)
                            Button {
                                if on { rule.weekdays.remove(d) } else { rule.weekdays.insert(d) }
                            } label: {
                                Text(Calendar.current.veryShortWeekdaySymbols[d - 1])
                                    .font(.callout.weight(.semibold))
                                    .frame(width: 34, height: 34)
                                    .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
                                    .foregroundStyle(on ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    DatePicker("Starts", selection: $rule.startDate, displayedComponents: .date)
                    Toggle("Ends", isOn: $hasEnd)
                    if hasEnd { DatePicker("Last day", selection: $endDate, displayedComponents: .date) }
                    Stepper("Create \(rule.leadDays) day\(rule.leadDays == 1 ? "" : "s") ahead", value: $rule.leadDays, in: 0...14)
                }
                Section("Where") {
                    Button {
                        pickFolder = true
                    } label: {
                        HStack {
                            Text("Folder").foregroundStyle(.primary)
                            Spacer()
                            Text(store.node(rule.destinationID)?.name ?? "All Notes").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Reminder") {
                    Toggle("Remind me when it's ready", isOn: $rule.notify)
                    if rule.notify {
                        DatePicker("At", selection: Binding(
                            get: { Calendar.current.date(from: DateComponents(hour: rule.notifyHour, minute: rule.notifyMinute)) ?? Date() },
                            set: { d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                rule.notifyHour = c.hour ?? 8
                                rule.notifyMinute = c.minute ?? 0
                            }), displayedComponents: .hourAndMinute)
                        if !settings.notificationsEnabled {
                            Text("Notifications are turned off for all of Inkwell. Turn them on in Settings.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Section("Page style") {
                    TemplatePicker(template: $rule.template, paper: $rule.paper).padding(.vertical, 6)
                }
                Section("Cover") {
                    Toggle("Custom cover", isOn: $useCover)
                    if useCover {
                        CoverDesignerView(design: $cover, title: rule.title).padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle(isNew ? "New Schedule" : "Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        rule.endDate = hasEnd ? endDate : nil
                        rule.cover = useCover ? cover : nil
                        if let i = store.rules.firstIndex(where: { $0.id == rule.id }) {
                            store.rules[i] = rule
                        } else {
                            store.rules.append(rule)
                        }
                        store.saveRules()
                        store.runSchedules()
                        Task { await notifications.reschedule(rules: store.rules, enabled: settings.notificationsEnabled) }
                        dismiss()
                    }
                    .disabled(rule.title.isEmpty || rule.weekdays.isEmpty)
                }
            }
            .onAppear {
                if let e = rule.endDate { hasEnd = true; endDate = e }
                if let c = rule.cover { useCover = true; cover = c }
            }
            .sheet(isPresented: $pickFolder) {
                FolderPickerSheet(title: "Create in…", initial: rule.destinationID) { rule.destinationID = $0 }
            }
        }
    }
}

// MARK: - Calendar suggestions

struct SuggestionsView: View {
    var open: (UUID) -> Void
    @Environment(\.inkTheme) private var theme
    @Environment(LibraryStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @State private var newNotebookFor: CalendarEvent?

    var body: some View {
        List {
            if !calendar.authorized {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Connect your calendar", systemImage: "calendar").font(.headline)
                        Text("Inkwell suggests a notebook for each upcoming lecture or meeting, and can repeat it every week automatically.")
                            .foregroundStyle(.secondary)
                        if calendar.denied {
                            Text("Calendar access is turned off. Enable it for Inkwell in Settings.")
                                .font(.footnote).foregroundStyle(.orange)
                        } else {
                            Button("Allow calendar access") { Task { await calendar.requestAccess() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                let upcoming = calendar.events.filter { !store.notebookExists(forEvent: $0.id) }
                if upcoming.isEmpty {
                    Section {
                        ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                               description: Text("No upcoming events need a notebook this week."))
                    }
                }
                ForEach(upcoming) { event in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.title).font(.headline)
                        Text("\(event.start.formatted(.dateTime.weekday(.wide).hour().minute())) · \(event.calendar)")
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("Create notebook") { newNotebookFor = event }
                                .buttonStyle(.bordered)
                            Button("Repeat every week") { repeatWeekly(event) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Suggested")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .task { calendar.refresh() }
        .sheet(item: $newNotebookFor) { event in
            NewNotebookSheet(parent: nil, eventID: event.id,
                             suggestedName: "\(event.title) – \(event.start.formatted(.dateTime.day().month(.abbreviated)))") { open($0) }
        }
    }

    private func repeatWeekly(_ event: CalendarEvent) {
        let weekday = Calendar.current.component(.weekday, from: event.start)
        var rule = ScheduleRule(title: event.title)
        rule.weekdays = [weekday]
        rule.startDate = event.start
        rule.nameFormat = "{title} – {date}"
        store.rules.append(rule)
        store.saveRules()
        store.runSchedules()
    }
}
