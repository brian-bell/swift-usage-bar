import AppKit
import SwiftUI

@main
struct AIUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AIUsageBarAppDelegate.self) private var appDelegate
    @ViewState private var model: UsageBarShellModel

    init() {
        let model = UsageBarShellModel.live()
        _model = ViewState(initialValue: model)
        appDelegate.beforeTermination = {
            await model.stop()
        }
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

        Settings {
            AppSettingsView(model: model)
        }
    }
}

@MainActor
final class AIUsageBarAppDelegate: NSObject, NSApplicationDelegate {
    var beforeTermination: (() async -> Void)?
    private var isFinishingTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishingTermination else {
            return .terminateLater
        }
        isFinishingTermination = true
        Task {
            await beforeTermination?()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
