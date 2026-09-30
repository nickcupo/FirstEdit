// Never runs. The binary starts in NSExtensionMain (the linker's -e in
// Package.swift), which finds RollPreviewProvider by the name the
// extension's Info.plist gives (NSExtensionPrincipalClass). As in
// RollThumbnail, its code is renamed so NSExtensionMain finds no main to call.
