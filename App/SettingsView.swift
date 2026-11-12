import AppKit
import SwiftUI
import UserNotifications
import PGSCore

/// Output folder, language, collisions, concurrency, italics, and the MKV track picker.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(ConversionPreferenceKey.placement) private var placement = ConversionPreferenceKey.placementNextToSource
    @AppStorage(ConversionPreferenceKey.folder) private var outputFolder = ""
    @AppStorage(ConversionPreferenceKey.language) private var language = ConversionPreferences.defaultLanguage
    @AppStorage(ConversionPreferenceKey.existingFile) private var existingFile = ExistingSubtitleAction.overwrite.rawValue
    @AppStorage(ConversionPreferenceKey.concurrency) private var concurrency = ConversionPreferences.defaultConcurrency
    @AppStorage(ConversionPreferenceKey.italics) private var experimentalItalics = false
    @AppStorage(ConversionPreferenceKey.chooseMKVTrack) private var chooseMKVTrack = false
    @AppStorage(ConversionPreferenceKey.saveTiming) private var saveTiming = SaveTiming.immediately.rawValue
    @AppStorage(ConversionPreferenceKey.batchNotification) private var batchNotification = BatchNotificationPolicy.whenBatchFinishes.rawValue
    @State private var notificationsOff = false

    var body: some View {
        Form {
            Section {
                Picker("Save the .srt file", selection: $placement) {
                    Text("Next to the source file").tag(ConversionPreferenceKey.placementNextToSource)
                    Text("In a folder I choose").tag(ConversionPreferenceKey.placementFolder)
                }
                .pickerStyle(.radioGroup)

                if placement == ConversionPreferenceKey.placementFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(outputFolder.isEmpty ? "No folder chosen" : outputFolder)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(outputFolder.isEmpty ? .secondary : .primary)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }

                Picker("If the .srt file already exists", selection: $existingFile) {
                    Text("Overwrite it").tag(ExistingSubtitleAction.overwrite.rawValue)
                    Text("Add a number").tag(ExistingSubtitleAction.addNumber.rawValue)
                    Text("Skip that file").tag(ExistingSubtitleAction.skip.rawValue)
                }
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
                Text(saveTiming == SaveTiming.afterReview.rawValue
                    ? "The file waits as “Ready to review” until you click Save."
                    : "Review and re-save any time with Review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Flag lines below 60% confidence", isOn: .constant(false))
                    .disabled(true)
                Text("Shown as “to check”. Needs #19.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("After a file is converted")
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(languageOptions, id: \.tag) { option in
                        Text(option.label).tag(option.tag)
                    }
                }
                Stepper(value: $concurrency, in: 1...8) {
                    Text("Pictures to read at once: \(concurrency)")
                }
                Text("Files go one at a time. This is how many pictures inside the current file are read together.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Experimental italics", isOn: $experimentalItalics)
                Text("Guess which lines lean and wrap them in italics. Leave this off. Ordinary upright dialogue is often marked by mistake.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Recognition")
            }

            Section {
                Toggle("Choose the subtitle track for each MKV", isOn: $chooseMKVTrack)
                Text("Off uses the English PGS track, or the first PGS track when the file has no English one. On, an MKV with more than one PGS track lets you check which tracks to convert.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("The app reads an MKV itself. MKVToolNix is used only when that reader cannot handle the file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("MKV")
            }

            Section {
                Picker("Send a notification:", selection: $batchNotification) {
                    Text("When a batch finishes").tag(BatchNotificationPolicy.whenBatchFinishes.rawValue)
                    Text("Only when something fails").tag(BatchNotificationPolicy.onlyOnFailure.rawValue)
                    Text("Never").tag(BatchNotificationPolicy.never.rawValue)
                }
                Text("Only when PGS2SRT isn't the active app. The alert uses the window's summary, for example \"3 done, 1 failed, 1 skipped in 2m 14s\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if notificationsOff && batchNotification != BatchNotificationPolicy.never.rawValue {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bell.slash")
                        Text("**Notifications are off for PGS2SRT in System Settings.** Turn them on to get these alerts. The summary line in the window still works.")
                    }
                    .font(.callout)
                    Button("Open System Settings") {
                        NotificationSettingsLink.open()
                    }
                }
            } header: {
                Text("Notifications")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 560, height: 1040)
        .onAppear {
            push()
            refreshNotificationAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationAccess()
        }
        .onChange(of: placement) { _ in push() }
        .onChange(of: outputFolder) { _ in push() }
        .onChange(of: language) { _ in push() }
        .onChange(of: existingFile) { _ in push() }
        .onChange(of: concurrency) { _ in push() }
        .onChange(of: experimentalItalics) { _ in push() }
        .onChange(of: chooseMKVTrack) { _ in push() }
        .onChange(of: saveTiming) { _ in push() }
        .onChange(of: batchNotification) { _ in push() }
    }

    private var languageOptions: [(label: String, tag: String)] {
        var options = LanguageChoices.all
        if !options.contains(where: { $0.tag == language }) {
            options.append((language, language))
        }
        return options
    }

    private func chooseFolder() {
        guard let path = model.chooseOutputFolder() else { return }
        outputFolder = path
        placement = ConversionPreferenceKey.placementFolder
    }

    private func push() {
        let placementValue: OutputPlacement = placement == ConversionPreferenceKey.placementFolder
            ? .folder(outputFolder)
            : .nextToSource
        model.updatePreferences(ConversionPreferences(
            placement: placementValue,
            language: language,
            existingFile: ExistingSubtitleAction(rawValue: existingFile) ?? .overwrite,
            concurrency: concurrency,
            experimentalItalics: experimentalItalics,
            chooseMKVTrack: chooseMKVTrack,
            saveTiming: SaveTiming(rawValue: saveTiming) ?? .immediately,
            batchNotification: BatchNotificationPolicy(rawValue: batchNotification) ?? .whenBatchFinishes
        ))
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
