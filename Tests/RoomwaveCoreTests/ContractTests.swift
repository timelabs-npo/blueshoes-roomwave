import Testing
@testable import RoomwaveCore

@Test func standardRulesHaveBoundedTiming() {
    let rules = RaceRules.standard
    #expect(rules.tickRate == 60)
    #expect(rules.durationTicks == 5400)
    #expect(rules.initialSpeed > 0)
    #expect(rules.maximumSpeed >= rules.initialSpeed)
}
