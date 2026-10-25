import SwiftUI
import PGSCore

/// Output folder, language, collisions, concurrency, and the italics opt-in.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @AppStorage(ConversionPreferenceKey.placement) private var placement = ConversionPreferenceKey.placementNextToSource
    @AppStorage(ConversionPreferenceKey.folder) private var outputFolder = ""
    @AppStorage(ConversionPreferenceKey.language) private var language = ConversionPreferences.defaultLanguage
    @AppStorage(ConversionPreferenceKey.existingFile) private var existingFile = ExistingSubtitleAction.overwrite.rawValue
    @AppStorage(ConversionPreferenceKey.concurrency) private var concurrency = ConversionPreferences.defaultConcurrency
    @AppStorage(ConversionPreferenceKey.italics) private var experimentalItalics = false

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
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 560, height: 520)
        .onAppear { push() }
        .onChange(of: placement) { _ in push() }
        .onChange(of: outputFolder) { _ in push() }
        .onChange(of: language) { _ in push() }
        .onChange(of: existingFile) { _ in push() }
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
            experimentalItalics: experimentalItalics
        ))
    }
}
