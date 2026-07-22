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
    private var operationGeneration: UInt64 = 0
    private var hostGeneration: UInt64 = 0

    private struct Snapshot {
        let state: State
        let devices: [GoodCloudDeviceSummary]
        let association: GoodCloudAssociation?
        let errorMessage: String?
        let sessionState: GoodCloudSessionState
    }

    private struct Operation {
        let generation: UInt64
        let hostGeneration: UInt64
        let prior: Snapshot
        let priorRoute: RouterConnectionModel.GoodCloudRemoteAccessRouteSnapshot
    }

    private var lastCommittedSnapshot = Snapshot(
        state: .loggedOut,
        devices: [],
        association: nil,
        errorMessage: nil,
        sessionState: .loggedOut
    )

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
        hostGeneration &+= 1
        let generation = hostGeneration
        activeHostID = hostID
        association = nil
        recordCommittedAssociation(nil)
        let host = savedHost
        Task { @MainActor [weak self] in
            guard let self else { return }
            let loaded = await self.associationSnapshot(for: host)
            guard self.hostGeneration == generation,
                  self.activeHostID == hostID,
                  !Task.isCancelled
            else { return }
            self.association = loaded
            self.recordCommittedAssociation(loaded)
        }
    }

    func load() async {
        let operation = beginAccountOperation()
        await connections.reloadSavedHosts(refreshGoodCloudRemoteAccess: false)
        guard canContinue(operation) else { return }
        let session: GoodCloudSessionState
        if let account {
            session = await account.validateStoredSession()
            guard canContinue(operation) else { return }
        } else {
            session = .loggedOut
        }
        await finishAccountOperation(operation, session: session)
    }

    func login(email: String, password: String) async {
        let operation = beginAccountOperation()
        let session: GoodCloudSessionState
        if let account {
            session = await account.login(email: email, password: password)
            guard canContinue(operation) else { return }
        } else {
            session = .failed("GoodCloud request failed.")
        }
        await finishAccountOperation(operation, session: session)
    }

    func logout() async {
        let operation = beginAccountOperation()
        let session: GoodCloudSessionState
        if let account {
            session = await account.logout()
            guard canContinue(operation) else { return }
        } else {
            session = .loggedOut
        }
        await finishAccountOperation(operation, session: session)
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
        let operation = beginMutation()
        do {
            try await associations.save(newAssociation)
        } catch {
            rollback(operation)
            throw error
        }
        guard canContinue(operation) else { return }
        guard hostGeneration == operation.hostGeneration,
              savedHost?.id == host.id
        else { return }
        guard await publishRoute(operation.prior.sessionState, for: operation) else { return }
        guard hostGeneration == operation.hostGeneration,
              savedHost?.id == host.id
        else { return }
        association = newAssociation
        errorMessage = nil
        recordCommittedSnapshot()
    }

    func removeAssociation() async throws {
        guard let host = savedHost else {
            throw GoodCloudSettingsError.noSavedRouter
        }
        guard let associations else {
            throw GoodCloudSettingsError.associationUnavailable
        }
        let operation = beginMutation()
        do {
            try await associations.remove(hostID: host.id)
        } catch {
            rollback(operation)
            throw error
        }
        guard canContinue(operation) else { return }
        guard hostGeneration == operation.hostGeneration,
              savedHost?.id == host.id
        else { return }
        guard await publishRoute(operation.prior.sessionState, for: operation) else { return }
        guard hostGeneration == operation.hostGeneration,
              savedHost?.id == host.id
        else { return }
        association = nil
        errorMessage = nil
        recordCommittedSnapshot()
    }

    private func associationSnapshot(for host: RouterHostMetadata?) async -> GoodCloudAssociation? {
        guard let associations, let host else { return nil }
        return await associations.association(forHostID: host.id)
    }

    private func beginAccountOperation() -> Operation {
        let operation = beginMutation()
        state = .loading
        errorMessage = nil
        return operation
    }

    private func beginMutation() -> Operation {
        let prior = lastCommittedSnapshot
        operationGeneration &+= 1
        return Operation(
            generation: operationGeneration,
            hostGeneration: hostGeneration,
            prior: prior,
            priorRoute: connections.goodCloudRemoteAccessRouteSnapshot()
        )
    }

    private func finishAccountOperation(
        _ operation: Operation,
        session: GoodCloudSessionState
    ) async {
        let associationGeneration = hostGeneration
        let host = savedHost
        let loadedAssociation = await associationSnapshot(for: host)
        guard canContinue(operation) else { return }
        guard hostGeneration == associationGeneration, savedHost?.id == host?.id else {
            await finishAccountOperation(operation, session: session)
            return
        }
        guard await publishRoute(session, for: operation) else { return }
        guard hostGeneration == associationGeneration, savedHost?.id == host?.id else {
            await finishAccountOperation(operation, session: session)
            return
        }
        sessionState = session
        apply(session)
        association = loadedAssociation
        recordCommittedSnapshot()
    }

    private var snapshot: Snapshot {
        Snapshot(
            state: state,
            devices: devices,
            association: association,
            errorMessage: errorMessage,
            sessionState: sessionState
        )
    }

    private func canContinue(_ operation: Operation) -> Bool {
        guard operationGeneration == operation.generation else { return false }
        guard !Task.isCancelled else {
            rollback(operation)
            return false
        }
        return true
    }

    private func publishRoute(
        _ session: GoodCloudSessionState,
        for operation: Operation
    ) async -> Bool {
        while canContinue(operation) {
            let committed = await connections.publishGoodCloudRemoteAccess(session)
            guard operationGeneration == operation.generation else { return false }
            if Task.isCancelled {
                rollback(operation)
                return false
            }
            if committed { return true }
        }
        return false
    }

    private func rollback(_ operation: Operation) {
        guard operationGeneration == operation.generation else { return }
        operationGeneration &+= 1
        restore(lastCommittedSnapshot)
        connections.publishGoodCloudRemoteAccess(operation.priorRoute)
    }

    private func restore(_ snapshot: Snapshot) {
        state = snapshot.state
        devices = snapshot.devices
        association = snapshot.association
        errorMessage = snapshot.errorMessage
        sessionState = snapshot.sessionState
    }

    private func recordCommittedSnapshot() {
        lastCommittedSnapshot = snapshot
    }

    private func recordCommittedAssociation(_ association: GoodCloudAssociation?) {
        lastCommittedSnapshot = Snapshot(
            state: lastCommittedSnapshot.state,
            devices: lastCommittedSnapshot.devices,
            association: association,
            errorMessage: lastCommittedSnapshot.errorMessage,
            sessionState: lastCommittedSnapshot.sessionState
        )
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
