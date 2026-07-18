import WattlineCore

public enum RouterEndpointCapability: String, CaseIterable, Hashable, Sendable {
    case controls
    case usbCLimit
}

public enum RouterSurfaceCapability: String, CaseIterable, Hashable, Sendable {
    case dcControl
    case typeCOutput
    case powerLimits
    case bypassControl
    case restart
    case shutdown
}

/// Intersects the device feature mask with routes advertised by wattlined.
/// Callers use `supportedSurfaces` to omit unavailable controls entirely.
public struct RouterCapabilities: Equatable, Sendable {
    public let features: FeatureFlags
    public let endpoints: Set<RouterEndpointCapability>

    public init(features: UInt32, endpoints: Set<RouterEndpointCapability>) {
        self.features = FeatureFlags(rawValue: features)
        self.endpoints = endpoints
    }

    public func supports(_ surface: RouterSurfaceCapability) -> Bool {
        switch surface {
        case .dcControl:
            features.contains(.dcControl) && endpoints.contains(.controls)
        case .typeCOutput:
            features.contains(.usbOutputControl) && endpoints.contains(.controls)
        case .powerLimits:
            features.contains(.usbPowerLimit) && endpoints.contains(.usbCLimit)
        case .bypassControl:
            features.contains(.dcBypassControl) && endpoints.contains(.controls)
        case .restart, .shutdown:
            features.contains(.shutdown) && endpoints.contains(.controls)
        }
    }

    public var supportedSurfaces: Set<RouterSurfaceCapability> {
        Set(RouterSurfaceCapability.allCases.filter(supports))
    }
}
