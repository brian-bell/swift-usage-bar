import SwiftUI

@main
struct AIUsageBarApp: App {
    @State private var model: UsageBarShellModel

    init() {
        let model = UsageBarShellModel.live()
        _model = State(initialValue: model)
        Task {
            await model.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            MenuBarLabelView(segments: model.menuBarSegments)
        }
        .menuBarExtraStyle(.window)
    }
}
