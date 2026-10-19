import Foundation

@main struct DutyActivityAppearanceChecks {
    static func main() {
        var count = 0
        func expect(_ appearance: String, _ supported: Bool, _ reduced: Bool, _ dimmed: Bool,
                    _ system: Bool, _ expected: DutyActivityBackdrop) {
            precondition(DutyActivityAppearancePolicy.backdrop(appearance: appearance, supportsGlass: supported,
                reduceTransparency: reduced, dimmed: dimmed, systemBackground: system) == expected)
            count += 1
        }
        expect("glass", true, false, false, true, .glass)
        expect("glass", true, false, false, false, .glass)
        expect("glass", false, false, false, true, .material)
        expect("glass", false, false, false, false, .material)
        for appearance in ["glass", "frosted", "solid"] {
            expect(appearance, true, true, false, true, .opaque)
            expect(appearance, true, false, true, true, .opaque)
            expect(appearance, true, false, true, false, .opaque)
        }
        expect("solid", true, false, false, true, .opaque)
        expect("frosted", true, false, false, true, .system)
        expect("frosted", true, false, false, false, .material)
        print("Passed \(count) Live Activity glass, dimmed-display and transparency fallback checks")
    }
}
