import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval

    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .disabled:
            return false
        }
    }
}

enum LaunchAtLoginError: Error, Equatable {
    case requiresApproval
}

protocol LaunchAtLoginManaging: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func setEnabled(_ enabled: Bool) throws
}

final class SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    private let serviceClient: any LaunchAtLoginServiceClient

    init(serviceClient: any LaunchAtLoginServiceClient = MainAppServiceClient()) {
        self.serviceClient = serviceClient
    }

    var status: LaunchAtLoginStatus {
        serviceClient.status
    }

    func setEnabled(_ enabled: Bool) throws {
        switch (enabled, serviceClient.status) {
        case (true, .enabled):
            return
        case (true, .requiresApproval):
            throw LaunchAtLoginError.requiresApproval
        case (true, .disabled):
            try serviceClient.register()
        case (false, .enabled), (false, .requiresApproval):
            try serviceClient.unregister()
        case (false, .disabled):
            return
        }
    }
}

protocol LaunchAtLoginServiceClient: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() throws
}

final class MainAppServiceClient: LaunchAtLoginServiceClient {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
