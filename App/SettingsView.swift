import AppKit
import SwiftUI
import UserNotifications
import PGSCore

/// General, Recognition, and Notifications. The last pane is restored next time.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsPane.storageKey) private var pane = SettingsPane.general.rawValue
    @State private var notificationsOff = false

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettings()
                .settingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general.rawValue)
            RecognitionSettings()
                .settingsPane()
                .tabItem { Label("Recognition", systemImage: SettingsSymbol.recognition) }
                .tag(SettingsPane.recognition.rawValue)
            NotificationsSettings(notificationsOff: notificationsOff)
                .settingsPane()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsPane.notifications.rawValue)
        }
        .background(SettingsWindowChrome())
        .onAppear { refreshNotificationAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationAccess()
        }
    }

    private func refreshNotificationAccess() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let off: Bool
            switch settings.authorizationStatus {
            case .denied:
                off = true
            case .authorized, .provisional:
                off = settings.alertSetting == .disabled
            default:
                off = false
            }
            Task { @MainActor in
                notificationsOff = off
            }
        }
    }
}

private enum SettingsPane: String {
    static let storageKey = "settingsPane"
    case general
    case recognition
    case notifications
}

private enum SettingsSymbol {
    /// `text.viewfinder` is not on every macOS 13 system. The older symbol is the fallback.
    static var recognition: String {
        if NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) != nil {
            return "text.viewfinder"
        }
        return "doc.text.magnifyingglass"
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(ConversionPreferenceKey.placement) private var placement = ConversionPreferenceKey.placementNextToSource
    @AppStorage(ConversionPreferenceKey.folder) private var outputFolder = ""
    @AppStorage(ConversionPreferenceKey.existingFile) private var existingFile = ExistingSubtitleAction.overwrite.rawValue
    @AppStorage(ConversionPreferenceKey.saveTiming) private var saveTiming = SaveTiming.immediately.rawValue
    @AppStorage(ConversionPreferenceKey.chooseMKVTrack) private var chooseMKVTrack = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Save .srt files") {
                    Picker("Save .srt files", selection: $placement) {
                        Text("Next to the source file").tag(ConversionPreferenceKey.placementNextToSource)
                        Text("In a folder I choose").tag(ConversionPreferenceKey.placementFolder)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                if placement == ConversionPreferenceKey.placementFolder {
                    LabeledContent("Folder") {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(outputFolder.isEmpty ? "No folder chosen" : outputFolder)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(outputFolder.isEmpty ? .secondary : .primary)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
                Picker("If the .srt already exists", selection: $existingFile) {
                    Text("Overwrite it").tag(ExistingSubtitleAction.overwrite.rawValue)
                    Text("Add a number").tag(ExistingSubtitleAction.addNumber.rawValue)
                    Text("Skip that file").tag(ExistingSubtitleAction.skip.rawValue)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Output")
            }

            Section {
                Picker("After a file is converted", selection: $saveTiming) {
                    Text("Save the .srt right away").tag(SaveTiming.immediately.rawValue)
                    Text("Hold it for review before saving").tag(SaveTiming.afterReview.rawValue)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("Held files wait in the queue with a Review button. Nothing is written until you save from Review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("After a file is converted")
            }

            Section {
                Toggle(isOn: $chooseMKVTrack) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Choose subtitle tracks for each MKV")
                        Text("PGS2SRT reads MKV files itself. MKVToolNix is only a fallback.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            } header: {
                Text("MKV files")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { push() }
        .onChange(of: placement) { _ in push() }
        .onChange(of: outputFolder) { _ in push() }
        .onChange(of: existingFile) { _ in push() }
        .onChange(of: saveTiming) { _ in push() }
        .onChange(of: chooseMKVTrack) { _ in push() }
    }

    private func chooseFolder() {
        guard let path = model.chooseOutputFolder() else { return }
        outputFolder = path
        placement = ConversionPreferenceKey.placementFolder
    }

    private func push() {
        var preferences = model.preferences
        preferences.placement = placement == ConversionPreferenceKey.placementFolder
            ? .folder(outputFolder)
            : .nextToSource
        preferences.existingFile = ExistingSubtitleAction(rawValue: existingFile) ?? .overwrite
        preferences.saveTiming = SaveTiming(rawValue: saveTiming) ?? .immediately
        preferences.chooseMKVTrack = chooseMKVTrack
        model.updatePreferences(preferences)
    }
}

private struct RecognitionSettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(ConversionPreferenceKey.language) private var language = ConversionPreferences.defaultLanguage
    @AppStorage(ConversionPreferenceKey.concurrency) private var concurrency = ConversionPreferences.defaultConcurrency
    @AppStorage(ConversionPreferenceKey.italics) private var experimentalItalics = false

    var body: some View {
        Form {
            Section {
                Picker("Subtitle language", selection: $language) {
                    ForEach(languageOptions, id: \.tag) { option in
                        Text(option.label).tag(option.tag)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent {
                    Stepper(value: $concurrency, in: 1...8) {
                        Text("\(concurrency)")
                            .monospacedDigit()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pictures to read at once")
                        Text("1 to 8. Files still convert one at a time; this is how many pictures of the current file are read together.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Text")
            }

            Section {
                Toggle(isOn: $experimentalItalics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Detect italics")
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Not reliable yet. Leave this off unless you'll check every italic line.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            } header: {
                Text("Experimental")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recognition")
        .onAppear { push() }
        .onChange(of: language) { _ in push() }
        .onChange(of: concurrency) { _ in push() }
        .onChange(of: experimentalItalics) { _ in push() }
    }

    private var languageOptions: [(label: String, tag: String)] {
        var options = LanguageChoices.all
        if !options.contains(where: { $0.tag == language }) {
            options.append((language, language))
        }
        return options
    }

    private func push() {
        var preferences = model.preferences
        preferences.language = language
        preferences.concurrency = concurrency
        preferences.experimentalItalics = experimentalItalics
        model.updatePreferences(preferences)
    }
}

private struct NotificationsSettings: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(ConversionPreferenceKey.batchNotification) private var batchNotification = BatchNotificationPolicy.whenBatchFinishes.rawValue
    var notificationsOff: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Picker("Send a notification", selection: $batchNotification) {
                        Text("When a batch finishes").tag(BatchNotificationPolicy.whenBatchFinishes.rawValue)
                        Text("Only when something fails").tag(BatchNotificationPolicy.onlyOnFailure.rawValue)
                        Text("Never").tag(BatchNotificationPolicy.never.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send a notification")
                        Text("Only when PGS2SRT isn't the active app. The alert uses the window's summary, for example \"3 done, 1 failed, 1 skipped in 2m 14s\".")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if notificationsOff && batchNotification != BatchNotificationPolicy.never.rawValue {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "bell.slash")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notifications are off for PGS2SRT in System Settings.")
                                    .fontWeight(.semibold)
                                Text("Turn them on to get these alerts. The summary line in the window still works.")
                            }
                        }
                        Button("Open System Settings") {
                            NotificationSettingsLink.open()
                        }
                    }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                }
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .onAppear { push() }
        .onChange(of: batchNotification) { _ in push() }
    }

    private func push() {
        var preferences = model.preferences
        preferences.batchNotification = BatchNotificationPolicy(rawValue: batchNotification) ?? .whenBatchFinishes
        model.updatePreferences(preferences)
    }
}

private extension View {
    func settingsPane() -> some View {
        frame(minWidth: 540, idealWidth: 620, maxWidth: 760, minHeight: 300, maxHeight: 640)
    }
}

/// Minimize and zoom stay visible and do nothing.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsChromeView {
        SettingsChromeView()
    }

    func updateNSView(_ nsView: SettingsChromeView, context: Context) {
        nsView.dimButtons()
    }
}

private final class SettingsChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dimButtons()
    }

    func dimButtons() {
        guard let window else { return }
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }
}
