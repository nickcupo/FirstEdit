import SwiftUI

/// The trailing inspector, 280 pt. Its contents are whatever the selected
/// step registered with `InspectorRegistry`; the shell owns only the column.
public struct InspectorHost: View {
    let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var body: some View {
        Group {
            if let shoot = app.navigation.shoot,
               let step = app.navigation.step,
               let session = app.library.cachedSession(for: shoot),
               let v = InspectorRegistry.view(step, session) {
                v
            } else {
                Text(Strings.Shell.nothingToShow)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .inspectorColumnWidth(min: 240, ideal: Tokens.Metric.inspector, max: 360)
    }
}
