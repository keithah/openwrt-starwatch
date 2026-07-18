import Foundation
#if canImport(Network)
import Network
#endif

public struct RouterServiceRecord: Equatable, Sendable {
    public let serviceName: String
    public let domain: String
    public let host: String?
    public let port: Int?
    public let txt: [String: Data]

    public init(
        serviceName: String,
        domain: String,
        host: String? = nil,
        port: Int? = nil,
        txt: [String: Data]
    ) {
        self.serviceName = serviceName
        self.domain = domain
        self.host = host
        self.port = port
        self.txt = txt
    }
}

public struct DiscoveredRouter: Equatable, Sendable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let serviceName: String
    public let domain: String
    public let model: String?
    public let cid: UInt16?
    public let features: UInt32?
    public let certificateFingerprint: String?
    public let endpoint: RouterEndpoint
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
            guard text("api", in: record) == "1",
                  text("auth", in: record) == "pin",
                  let host = record.host,
                  let port = record.port,
                  (1...65_535).contains(port),
                  let idText = text("id", in: record),
                  let deviceID = DeviceIdentityDeduplicator.normalizedMAC(idText),
                  let tls = text("tls", in: record),
                  let security = security(tls),
                  let rawModel = text("model", in: record),
                  let rawCID = text("cid", in: record),
                  let rawFeatures = text("features", in: record)
            else { continue }

            let cid: UInt16?
            if !rawCID.isEmpty {
                guard isLowercaseHex(rawCID, count: 4), let value = UInt16(rawCID, radix: 16) else { continue }
                cid = value
            } else {
                cid = nil
            }
            let features: UInt32?
            if !rawFeatures.isEmpty {
                guard isLowercaseHex(rawFeatures, count: 8),
                      let value = UInt32(rawFeatures, radix: 16) else { continue }
                features = value
            } else {
                features = nil
            }
            let model = rawModel.isEmpty ? nil : rawModel
            let endpoint = RouterEndpoint(
                scheme: security.scheme,
                host: normalizedHost(host),
                port: port,
                certificateFingerprint: security.fingerprint,
                allowsInsecureWAN: false
            )
            byID[deviceID] = DiscoveredRouter(
                deviceID: deviceID,
                serviceName: record.serviceName,
                domain: record.domain,
                model: model,
                cid: cid,
                features: features,
                certificateFingerprint: security.fingerprint,
                endpoint: endpoint
            )
        }
        return byID.values.sorted { $0.deviceID < $1.deviceID }
    }

    private static func text(_ key: String, in record: RouterServiceRecord) -> String? {
        record.txt[key].flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func security(_ tls: String) -> (scheme: String, fingerprint: String?)? {
        if tls == "none" { return ("http", nil) }
        guard isLowercaseHex(tls, count: 64),
              let fingerprint = RouterHostValidator.normalizeFingerprint(tls) else { return nil }
        return ("https", fingerprint)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func normalizedHost(_ value: String) -> String {
        let lowercase = value.lowercased()
        return lowercase.last == "." ? String(lowercase.dropLast()) : lowercase
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
                let task = Task {
                    let records = await withTaskGroup(of: RouterServiceRecord?.self) { group in
                        for result in results {
                            group.addTask { await Self.resolve(result) }
                        }
                        var values: [RouterServiceRecord] = []
                        for await record in group {
                            if let record { values.append(record) }
                        }
                        return values
                    }
                    guard !Task.isCancelled else { return }
                    continuation.yield(records)
                }
                lifetime.replaceResolution(with: task)
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

    private static func resolve(_ result: NWBrowser.Result) async -> RouterServiceRecord? {
        guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
        var values: [String: Data] = [:]
        if case let .bonjour(txt) = result.metadata {
            for key in ["ver", "api", "id", "model", "cid", "features", "tls", "auth"] {
                guard let entry = txt.getEntry(for: key), let data = entry.data else { continue }
                values[key] = data
            }
        }
        let resolvedTXT = values
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        let pair = AsyncStream<RouterServiceRecord?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else {
                    pair.continuation.yield(nil)
                    pair.continuation.finish()
                    connection.cancel()
                    return
                }
                pair.continuation.yield(RouterServiceRecord(
                    serviceName: name,
                    domain: domain,
                    host: String(describing: host),
                    port: Int(port.rawValue),
                    txt: resolvedTXT
                ))
                pair.continuation.finish()
                connection.cancel()
            case .failed, .cancelled:
                pair.continuation.yield(nil)
                pair.continuation.finish()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "WattlineNetwork.RouterDiscovery.Resolve"))
        return await withTaskCancellationHandler {
            var iterator = pair.stream.makeAsyncIterator()
            return await iterator.next() ?? nil
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class BrowserLifetime: @unchecked Sendable {
    private let browser: NWBrowser
    private let lock = NSLock()
    private var resolutionTask: Task<Void, Never>?
    init(_ browser: NWBrowser) { self.browser = browser }
    func replaceResolution(with task: Task<Void, Never>) {
        lock.withLock {
            resolutionTask?.cancel()
            resolutionTask = task
        }
    }
    func cancel() {
        lock.withLock {
            resolutionTask?.cancel()
            resolutionTask = nil
        }
        browser.cancel()
    }
}
#endif
