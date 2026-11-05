import Testing
@testable import ArticulateCore

@Test("短口述加速（離線替身）")
@MainActor func dictationSpeed() async {
    #expect(await DictationSpeedSelfTest.run())
}
