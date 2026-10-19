import Foundation

enum DutyActivityBackdrop: Equatable { case glass, system, material, opaque }

enum DutyActivityAppearancePolicy {
    static func backdrop(appearance: String, supportsGlass: Bool, reduceTransparency: Bool,
                         dimmed: Bool, systemBackground: Bool) -> DutyActivityBackdrop {
        // Keep information readable in Always-On. Only the backdrop changes;
        // the labels and iOS-rendered countdown keep the same view identity.
        if appearance == "solid" || reduceTransparency || dimmed { return .opaque }
        if appearance == "glass" { return supportsGlass ? .glass : .material }
        return systemBackground ? .system : .material
    }
}
