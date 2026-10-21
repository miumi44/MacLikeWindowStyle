import Foundation

public enum WindowFeaturePreference: String {
    case switcher = "windowSwitcherEnabled"
    case windowManagement = "windowManagementEnabled"

    public var enabled: Bool { enabled(in: .standard) }

    public func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey:rawValue) as? Bool ?? false
    }

    public func persist(_ enabled: Bool, started: Bool, userInitiated: Bool, defaults: UserDefaults = .standard) {
        guard userInitiated, !enabled || started else { return }
        defaults.set(enabled,forKey:rawValue)
    }
}
