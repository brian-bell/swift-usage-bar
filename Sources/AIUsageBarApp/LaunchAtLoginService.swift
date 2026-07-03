import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging: AnyObject {
    var isEnabled: Bool { get }

    func setEnabled(_ enabled: Bool) throws
}

final class SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    private let serviceClient: any LaunchAtLoginServiceClient

    init(serviceClient: any LaunchAtLoginServiceClient = MainAppServiceClient()) {
        self.serviceClient = serviceClient
    }

    var isEnabled: Bool {
        serviceClient.isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard !serviceClient.isEnabled else {
                return
            }

            try serviceClient.register()
        } else {
            guard serviceClient.isEnabled else {
                return
            }

            try serviceClient.unregister()
        }
    }
}

protocol LaunchAtLoginServiceClient: AnyObject {
    var isEnabled: Bool { get }

    func register() throws
    func unregister() throws
}

final class MainAppServiceClient: LaunchAtLoginServiceClient {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
