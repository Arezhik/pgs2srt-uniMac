import Foundation

/// What Reveal in Finder should do after it checks the finished `.srt`.
public enum RevealPlan: Equatable, Sendable {
    /// The subtitle file is still there.
    case showFile(String)
    /// The subtitle file is missing. The buttons are in the order they should appear.
    case alert(RevealAlert)
}

/// A plain explanation and the actions that still make sense.
public struct RevealAlert: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// First button is the default. Cancel or OK is last when there is another choice.
    public var buttons: [RevealButton]
    public var outputFolder: String
    public var folderExists: Bool
    public var sourcePath: String

    public init(
        title: String,
        detail: String,
        buttons: [RevealButton],
        outputFolder: String,
        folderExists: Bool,
        sourcePath: String
    ) {
        self.title = title
        self.detail = detail
        self.buttons = buttons
        self.outputFolder = outputFolder
        self.folderExists = folderExists
        self.sourcePath = sourcePath
    }
}

public enum RevealButton: String, Equatable, Sendable {
    case showFolder = "Show Folder"
    case convertAgain = "Convert Again"
    case cancel = "Cancel"
    case ok = "OK"

    public var title: String { rawValue }
}

/// Decides the Reveal alert. The row itself is not changed.
public enum RevealFollowUp {
    public static func plan(
        outputPath: String,
        sourcePath: String,
        fileExists: (String) -> Bool,
        directoryExists: (String) -> Bool
    ) -> RevealPlan {
        if fileExists(outputPath) {
            return .showFile(outputPath)
        }
        let name = (outputPath as NSString).lastPathComponent
        let folder = (outputPath as NSString).deletingLastPathComponent
        let folderExists = !folder.isEmpty && directoryExists(folder)
        let sourceExists = fileExists(sourcePath)
        let quoted = "“\(name)”"
        if !sourceExists {
            var buttons: [RevealButton] = []
            if folderExists { buttons.append(.showFolder) }
            buttons.append(.ok)
            return .alert(RevealAlert(
                title: "\(quoted) can't be found.",
                detail: "The original file is gone too, so it can't be converted again.",
                buttons: buttons,
                outputFolder: folder,
                folderExists: folderExists,
                sourcePath: sourcePath
            ))
        }
        if !folderExists {
            return .alert(RevealAlert(
                title: "The folder for \(quoted) was moved or deleted.",
                detail: "Convert Again creates that folder and writes the subtitle there.",
                buttons: [.convertAgain, .cancel],
                outputFolder: folder,
                folderExists: false,
                sourcePath: sourcePath
            ))
        }
        return .alert(RevealAlert(
            title: "\(quoted) can't be found.",
            detail: "It may have been moved or deleted.",
            buttons: [.showFolder, .convertAgain, .cancel],
            outputFolder: folder,
            folderExists: true,
            sourcePath: sourcePath
        ))
    }

    /// The folder to recreate before converting again. Nil when the normal save location is used.
    public static func restoredFolder(for alert: RevealAlert) -> String? {
        guard alert.buttons.contains(.convertAgain), !alert.folderExists else { return nil }
        guard !alert.outputFolder.isEmpty else { return nil }
        return alert.outputFolder
    }
}
