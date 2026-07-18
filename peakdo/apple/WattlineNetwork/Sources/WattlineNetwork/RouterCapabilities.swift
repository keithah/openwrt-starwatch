import WattlineCore

public enum RouterEndpointCapability: String, CaseIterable, Hashable, Sendable {
    case actions
    case usbCLimit
    case bypassThreshold
    case schedules
}

public enum RouterSurfaceCapability: String, CaseIterable, Hashable, Sendable {
    case dcControl
    case typeCOutput
    case powerLimits
    case bypassControl
    case bypassThreshold
    case schedules
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
            features.contains(.dcControl) && endpoints.contains(.actions)
        case .typeCOutput:
            features.contains(.usbOutputControl) && endpoints.contains(.actions)
        case .powerLimits:
            features.contains(.usbPowerLimit) && endpoints.contains(.usbCLimit)
        case .bypassControl:
            features.contains(.dcBypassControl) && endpoints.contains(.actions)
        case .bypassThreshold:
            features.contains(.dcBypassControl) && endpoints.contains(.bypassThreshold)
        case .schedules:
            features.contains(.dcScheduler) && endpoints.contains(.schedules)
        case .restart, .shutdown:
            features.contains(.shutdown) && endpoints.contains(.actions)
        }
    }

    public var supportedSurfaces: Set<RouterSurfaceCapability> {
        Set(RouterSurfaceCapability.allCases.filter(supports))
    }
}
