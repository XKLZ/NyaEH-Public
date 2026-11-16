import Testing
@testable import NyaEHCore

@Suite("Version label color roles")
struct VersionLabelColorRoleTests {
    @Test("built in labels have distinct stable roles")
    func presetRoles() {
        let roles = VersionLabelPreset.all.map(VersionLabelColorRole.role(for:))
        #expect(Set(roles).count == VersionLabelPreset.all.count)
        #expect(VersionLabelColorRole.role(for: " 原始 ") == .original)
    }

    @Test("custom label role is stable across equivalent spelling")
    func customRoles() {
        #expect(VersionLabelColorRole.role(for: "Alpha") == .custom(3))
        #expect(VersionLabelColorRole.role(for: " alpha ") == .custom(3))
        #expect(VersionLabelColorRole.role(for: "Beta") == .custom(5))
    }
}
