import Foundation
import Observation
import WattlineNetwork

enum GoodCloudSettingsError: Error, Equatable {
    case noSavedRouter
    case deviceNotFound
    case deviceOffline
    case associationUnavailable
}

enum GoodCloudRemoteAvailability: Equatable {
    case unavailable
    case online
    case offline
}

@MainActor
@Observable
final class GoodCloudSettingsModel {
    enum State: Equatable {
        case loggedOut
        case loading
        case authenticated
        case requiresLogin
        case failed
    }

    private(set) var state: State = .loggedOut
    private(set) var devices: [GoodCloudDeviceSummary] = []
    private(set) var association: GoodCloudAssociation?
    private(set) var errorMessage: String?
    private(set) var activeHostID: UUID?

    private let account: (any GoodCloudAccountServing)?
    private let associations: GoodCloudAssociationStore?
    private let connections: RouterConnectionModel
    private var sessionState: GoodCloudSessionState = .loggedOut

    init(
        account: (any GoodCloudAccountServing)?,
        associations: GoodCloudAssociationStore?,
        connections: RouterConnectionModel,
        hostID: UUID? = nil
    ) {
        self.account = account
        self.associations = associations
        self.connections = connections
        activeHostID = hostID
    }

    convenience init(connections: RouterConnectionModel, hostID: UUID? = nil) {
        self.init(
            account: connections.goodCloudAccount?.account,
            associations: connections.goodCloudAssociations,
            connections: connections,
            hostID: hostID
        )
    }

    var savedHost: RouterHostMetadata? {
        if let activeHostID {
            return connections.savedHosts.first { $0.id == activeHostID }
        }
        guard connections.savedHosts.count == 1 else { return nil }
        return connections.savedHosts[0]
    }

    var suggestedDevice: GoodCloudDeviceSummary? {
        guard let associations, let routerMAC = savedHost?.deviceID else { return nil }
        return associations.suggestedDevice(forRouterMAC: routerMAC, devices: devices)
    }

    var associatedDevice: GoodCloudDeviceSummary? {
        guard let deviceID = association?.goodCloudDeviceID else { return nil }
        return devices.first { $0.id == deviceID }
    }

    var remoteAvailability: GoodCloudRemoteAvailability {
        guard state == .authenticated, association != nil, let associatedDevice else {
            return .unavailable
        }
        return associatedDevice.isOnline ? .online : .offline
    }

    func selectHost(_ hostID: UUID?) {
        guard activeHostID != hostID else { return }
        activeHostID = hostID
        association = nil
        Task { @MainActor [weak self] in
            await self?.loadAssociation()
        }
    }

    func load() async {
        await connections.reloadSavedHosts(refreshGoodCloudRemoteAccess: false)
        guard let account else {
            await accept(.loggedOut)
            return
        }
        state = .loading
        errorMessage = nil
        await accept(await account.validateStoredSession())
    }

    func login(email: String, password: String) async {
        guard let account else {
            await accept(.failed("GoodCloud request failed."))
            return
        }
        state = .loading
        errorMessage = nil
        await accept(await account.login(email: email, password: password))
    }

    func logout() async {
        guard let account else {
            await accept(.loggedOut)
            return
        }
        state = .loading
        errorMessage = nil
        await accept(await account.logout())
    }

    func associate(deviceID: String) async throws {
        guard state == .authenticated else {
            throw GoodCloudSettingsError.associationUnavailable
        }
        guard let host = savedHost, let routerMAC = host.deviceID else {
            throw GoodCloudSettingsError.noSavedRouter
        }
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            throw GoodCloudSettingsError.deviceNotFound
        }
        guard device.isOnline else {
            throw GoodCloudSettingsError.deviceOffline
        }
        guard let associations else {
            throw GoodCloudSettingsError.associationUnavailable
        }

        let newAssociation = GoodCloudAssociation(
            hostID: host.id,
            routerMAC: routerMAC,
            device: device
        )
        try await associations.save(newAssociation)
        association = newAssociation
        errorMessage = nil
        await connections.publishGoodCloudRemoteAccess(sessionState)
    }

    func removeAssociation() async throws {
        guard let host = savedHost else {
            throw GoodCloudSettingsError.noSavedRouter
        }
        guard let associations else {
            throw GoodCloudSettingsError.associationUnavailable
        }
        try await associations.remove(hostID: host.id)
        association = nil
        errorMessage = nil
        await connections.publishGoodCloudRemoteAccess(sessionState)
    }

    private func loadAssociation() async {
        guard let associations, let host = savedHost else {
            association = nil
            return
        }
        let loaded = await associations.association(forHostID: host.id)
        guard savedHost?.id == host.id else { return }
        association = loaded
    }

    private func accept(_ session: GoodCloudSessionState) async {
        sessionState = session
        apply(session)
        await loadAssociation()
        await connections.publishGoodCloudRemoteAccess(session)
    }

    private func apply(_ session: GoodCloudSessionState) {
        switch session {
        case .loggedOut:
            publish(.loggedOut)
        case .loading:
            state = .loading
            errorMessage = nil
        case let .authenticated(devices):
            self.devices = devices
            publish(.authenticated)
        case .requiresLogin:
            publish(.requiresLogin)
        case .failed:
            publish(.failed)
        }
    }

    private func publish(_ newState: State) {
        state = newState
        if newState != .authenticated {
            devices = []
        }
        errorMessage = GoodCloudSettingsPresentation(modelState: newState).message
    }
}

struct GoodCloudSettingsPresentation: Equatable, CustomStringConvertible {
    let title: String
    let message: String?

    init(modelState state: GoodCloudSettingsModel.State) {
        switch state {
        case .loggedOut:
            title = "GoodCloud signed out"
            message = nil
        case .loading:
            title = "Contacting GoodCloud"
            message = nil
        case .authenticated:
            title = "GoodCloud connected"
            message = nil
        case .requiresLogin:
            title = "GoodCloud sign-in required"
            message = "Your GoodCloud session ended. Sign in again."
        case .failed:
            title = "GoodCloud unavailable"
            message = "Remote access is unavailable. Please try again."
        }
    }

    init(_ state: GoodCloudSessionState) {
        switch state {
        case .loggedOut:
            self.init(modelState: .loggedOut)
        case .loading:
            self.init(modelState: .loading)
        case .authenticated:
            self.init(modelState: .authenticated)
        case .requiresLogin:
            self.init(modelState: .requiresLogin)
        case .failed:
            self.init(modelState: .failed)
        }
    }

    var description: String {
        "GoodCloudSettingsPresentation(title: \(title), message: \(message ?? "none"))"
    }
}
