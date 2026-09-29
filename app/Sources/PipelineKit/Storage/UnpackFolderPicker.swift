import AppKit
import Foundation

/// Where Unpack to a Folder puts the RAWs: a folder he picks, starting on the
/// Desktop, with New Folder on so one can be made on the way. It only asks;
/// the engine writes, and never over a file that is there.
@MainActor
enum UnpackFolderPicker {
    static func pick(shoot: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = Strings.Storage.unpackHere
        panel.message = Strings.Storage.unpackMessage(shoot)
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
