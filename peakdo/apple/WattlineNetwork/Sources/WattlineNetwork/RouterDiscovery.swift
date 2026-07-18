import Foundation
#if canImport(Network)
import Network
#endif

public struct RouterServiceRecord: Equatable, Sendable {
    public let serviceName: String
    public let domain: String
    public let txt: [String: Data]

    public init(serviceName: String, domain: String, txt: [String: Data]) {
        self.serviceName = serviceName
        self.domain = domain
        self.txt = txt
    }
}

public struct DiscoveredRouter: Equatable, Sendable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let serviceName: String
    public let domain: String
    public let certificateFingerprint: String?
}

public protocol RouterDiscoverySource: Sendable {
    func snapshots(serviceType: String) -> AsyncStream<[RouterServiceRecord]>
}

public struct RouterDiscovery: Sendable {
    public static let serviceType = "_wattline._tcp"
    private let source: any RouterDiscoverySource

    public init(source: any RouterDiscoverySource) {
        self.source = source
    }

    public func routers() -> AsyncStream<[DiscoveredRouter]> {
        let sourceStream = source.snapshots(serviceType: Self.serviceType)
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in sourceStream {
                    continuation.yield(Self.parseAndDeduplicate(snapshot))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parseAndDeduplicate(_ records: [RouterServiceRecord]) -> [DiscoveredRouter] {
        var byID: [String: DiscoveredRouter] = [:]
        for record in records {
            guard let idData = record.txt["id"],
                  let idText = String(data: idData, encoding: .utf8),
                  let deviceID = DeviceIdentityDeduplicator.normalizedMAC(idText)
            else { continue }
            let fingerprint = record.txt["fingerprint"]
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(RouterHostValidator.normalizeFingerprint)
            byID[deviceID] = DiscoveredRouter(
                deviceID: deviceID,
                serviceName: record.serviceName,
                domain: record.domain,
                certificateFingerprint: fingerprint
            )
        }
        return byID.values.sorted { $0.deviceID < $1.deviceID }
    }
}

#if canImport(Network)
public final class NWBrowserRouterDiscoverySource: RouterDiscoverySource, @unchecked Sendable {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "WattlineNetwork.RouterDiscovery")) {
        self.queue = queue
    }

    public func snapshots(serviceType: String) -> AsyncStream<[RouterServiceRecord]> {
        AsyncStream { continuation in
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                using: .tcp
            )
            let lifetime = BrowserLifetime(browser)
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results.compactMap(Self.record))
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            continuation.onTermination = { _ in lifetime.cancel() }
            browser.start(queue: queue)
        }
    }

    private static func record(_ result: NWBrowser.Result) -> RouterServiceRecord? {
        guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
        var values: [String: Data] = [:]
        if case let .bonjour(txt) = result.metadata {
            for key in ["id", "fingerprint"] {
                guard let entry = txt.getEntry(for: key), let data = entry.data else { continue }
                values[key] = data
            }
        }
        return RouterServiceRecord(serviceName: name, domain: domain, txt: values)
    }
}

private final class BrowserLifetime: @unchecked Sendable {
    private let browser: NWBrowser
    init(_ browser: NWBrowser) { self.browser = browser }
    func cancel() { browser.cancel() }
}
#endif
