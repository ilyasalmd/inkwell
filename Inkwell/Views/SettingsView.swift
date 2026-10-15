import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(EditorModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var cloudBusy = false
    @State private var backingUp = false
    @AppStorage(ClaudeBridge.key) private var shareWithClaude = false

    var body: some View {
        @Bindable var settings = settings
        @Bindable var editor = editor
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Mode", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Theme").font(.subheadline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(ThemeID.allCases) { t in
                                    Button { withAnimation(.snappy) { settings.themeID = t } } label: {
                                        VStack(spacing: 6) {
                                            ZStack {
                                                RoundedRectangle(cornerRadius: 12).fill(t.theme.background)
                                                Circle().fill(t.theme.accent).frame(width: 22, height: 22)
                                            }
                                            .frame(width: 64, height: 48)
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.2), lineWidth: 1))
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: settings.themeID == t ? 3 : 0).padding(-3))
                                            Text(t.title).font(.caption)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4).padding(.horizontal, 4)
                        }
                    }
                }

                Section {
                    Toggle("Sync with iCloud", isOn: Binding(
                        get: { settings.iCloudEnabled },
                        set: { on in toggleCloud(on) }
                    ))
                    #if OPEN_BUILD
                    .disabled(true)
                    #else
                    .disabled(cloudBusy)
                    #endif
                    if cloudBusy { ProgressView() }
                    #if !OPEN_BUILD
                    Toggle("Share with Claude on my Mac", isOn: $shareWithClaude)
                        .disabled(!store.usingICloud)
                    #endif
                    if let msg = store.syncMessage {
                        Text(msg).font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    #if OPEN_BUILD
                    Text("iCloud sync isn't part of the open download. Notebooks are stored on this device. To enable sync, build Inkwell from source with your own developer team.")
                    #else
                    Text(store.usingICloud
                         ? "Your notebooks, ink and imported PDFs are stored in iCloud Drive and sync between your devices. \"Share with Claude\" keeps page images in iCloud Drive for the Inkwell plugin on your Mac, and hands each page straight to your Mac over Wi-Fi when they're on the same network. Nothing leaves your own devices and iCloud."
                         : "Notebooks are stored on this device only. Turn on iCloud sync to share pages with Claude.")
                    #endif
                }

                Section {
                    LabeledContent("Last backup") {
                        if let last = store.backups.first {
                            Text(last.date, format: .relative(presentation: .named))
                        } else {
                            Text("Not yet")
                        }
                    }
                    Button {
                        backingUp = true
                        Task {
                            await store.backUp(force: true)
                            backingUp = false
                        }
                    } label: {
                        HStack {
                            Text("Back up now")
                            if backingUp { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(backingUp)
                    NavigationLink("Restore from a backup") { BackupsList() }
                        .disabled(store.backups.isEmpty)
                } header: {
                    Text("Backups")
                } footer: {
                    Text(store.usingICloud
                         ? "Everything saves as you write. Inkwell also backs up all your notebooks automatically every few hours and keeps the last \(LibraryBackup.keep) backups in iCloud Drive (Inkwell › Backups), so they're safe even if this iPad is lost. Restoring adds a copy in a new folder and never changes your notebooks."
                         : "Everything saves as you write. Inkwell also backs up all your notebooks automatically every few hours and keeps the last \(LibraryBackup.keep) backups on this iPad, which your iPad's iCloud Backup includes. Turn on iCloud sync to keep them in iCloud Drive too. Restoring adds a copy in a new folder and never changes your notebooks.")
                }

                Section {
                    Toggle("Schedule reminders", isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { on in
                            settings.notificationsEnabled = on
                            Task { await notifications.reschedule(rules: store.rules, enabled: on) }
                        }
                    ))
                    if settings.notificationsEnabled && notifications.denied {
                        Text("Notifications are blocked for Inkwell in the system Settings app.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("A reminder arrives at the time you set for each schedule. You can also turn reminders off for a single schedule.")
                }

                Section {
                    Picker("Squeeze (Pencil Pro)", selection: $settings.squeezeAction) {
                        ForEach(PencilAction.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Double-tap", selection: $settings.doubleTapAction) {
                        ForEach(PencilAction.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Draw with finger", isOn: $settings.drawWithFinger)
                    Toggle("Palm rejection", isOn: $settings.palmRejection)
                    if settings.palmRejection {
                        Picker("Sensitivity", selection: $settings.palmSensitivity) {
                            ForEach(PalmSensitivity.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    LabeledContent("Writing hand") {
                        Picker("Writing hand", selection: $settings.leftHanded) {
                            Text("Right").tag(false)
                            Text("Left").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    Toggle("Scribble to erase", isOn: $editor.scribbleErase)
                    Toggle("Shape snapping", isOn: $editor.shapeSnap)
                } header: {
                    Text("Apple Pencil")
                } footer: {
                    Text("Palm rejection ignores your resting hand on the page; the toolbar and buttons always respond. Low ignores only a whole hand or arm. Medium (recommended) also ignores fingers on your writing-hand side of the Pencil while you write, so your other hand can still scroll and zoom. High ignores every finger on the page while the Pencil is in use. Set Writing hand so the guarded side matches yours; it also mirrors the pen tray and page strip. Turn off Draw with finger and only the Pencil leaves ink. Scribble to erase: zig-zag over ink with the pen to remove it. Shape snapping: draw a line or shape and hold the Pencil still at the end to straighten it. Squeeze needs Apple Pencil Pro.")
                }
            }
            .onChange(of: shareWithClaude) { _, on in if on { ClaudeBridge.shared.syncAll() } }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationSizing(.page)
    }

    private func toggleCloud(_ on: Bool) {
        cloudBusy = true
        Task {
            let ok = await store.setICloud(on)
            settings.iCloudEnabled = on ? ok : false
            cloudBusy = false
        }
    }
}

/// Every saved backup, newest first. Restoring one adds its notebooks as a copy in a new folder.
private struct BackupsList: View {
    @Environment(LibraryStore.self) private var store
    @State private var picked: LibraryBackup?
    @State private var restored: String?

    var body: some View {
        List(store.backups) { backup in
            Button { picked = backup } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backup.date, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                        .foregroundStyle(.primary)
                    Text(backup.date, format: .relative(presentation: .named))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Backups")
        .confirmationDialog("Restore this backup?", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible, presenting: picked) { backup in
            Button("Restore a Copy") {
                let n = store.restoreCopy(of: backup)
                restored = n == 0 ? "That backup has no notebooks in it."
                    : "\(n == 1 ? "1 notebook" : "\(n) notebooks") restored into a new folder in your library."
            }
        } message: { _ in
            Text("Its notebooks come back in a new folder. Your current notebooks stay exactly as they are.")
        }
        .alert(restored ?? "", isPresented: Binding(get: { restored != nil }, set: { if !$0 { restored = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
