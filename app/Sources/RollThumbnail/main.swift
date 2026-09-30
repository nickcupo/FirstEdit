// Never runs. The binary starts in NSExtensionMain (the linker's -e in
// Package.swift), which finds RollThumbnailProvider by the name the
// extension's Info.plist gives (NSExtensionPrincipalClass). SwiftPM wants an
// executable target to have a main.swift; its code is renamed so that
// NSExtensionMain, which calls a main if the executable has one, finds none.
