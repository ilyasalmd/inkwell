import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    @Environment(EditorModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var cloudBusy = false
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
                         ? "Your notebooks, ink and imported PDFs are stored in iCloud Drive and sync between your devices. \"Share with Claude\" keeps page images in iCloud Drive for the Inkwell plugin on your Mac. Nothing leaves your own iCloud."
                         : "Notebooks are stored on this device only. Turn on iCloud sync to share pages with Claude.")
                    #endif
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
                    Toggle("Scribble to erase", isOn: $editor.scribbleErase)
                    Picker("Writing hand", selection: $settings.leftHanded) {
                        Text("Right").tag(false)
                        Text("Left").tag(true)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Apple Pencil")
                } footer: {
                    Text("Palm rejection stops the page scrolling or panning under your resting hand while the Pencil is writing. Turn off Draw with finger and only the Pencil leaves ink. Scribble to erase: zig-zag over ink with the pen to remove it. Left-handed mirrors the pen tray and page strip. Squeeze needs Apple Pencil Pro.")
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
