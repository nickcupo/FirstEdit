import Foundation

// An app extension starts in Foundation's NSExtensionMain, which Xcode names
// with `-e _NSExtensionMain`. The package has no Xcode project, so this is
// the whole of main: find it and hand it the arguments. It never returns
// while Finder wants thumbnails, and it finds RollThumbnailProvider by the
// name the extension's Info.plist gives (NSExtensionPrincipalClass).
typealias ExtensionMain = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "NSExtensionMain") else {   // RTLD_DEFAULT
    FileHandle.standardError.write(Data("NSExtensionMain is not in this process\n".utf8))
    exit(1)
}
_ = RollThumbnailProvider.self     // linked in, whatever the optimiser thinks of it
exit(unsafeBitCast(sym, to: ExtensionMain.self)(CommandLine.argc, CommandLine.unsafeArgv))
