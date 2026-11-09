import Testing
@testable import OnDeviceIntelligence

@Suite("On-device summarizer")
struct OnDeviceSummarizerTests {
    @Test(arguments: [
        ("\"Repo UX review\"", "Repo UX review"),
        ("Title: Fix token refresh race", "Fix token refresh race"),
        ("**Bold title**\nSecond line", "Bold title"),
        ("", nil)
    ])
    func `cleans model output`(raw: String, expected: String?) {
        #expect(OnDeviceSummarizer.clean(raw, maxLength: 60) == expected)
    }

    @Test func `rejects rambling output`() {
        #expect(OnDeviceSummarizer.clean(String(repeating: "word ", count: 30), maxLength: 60) == nil)
    }
}
