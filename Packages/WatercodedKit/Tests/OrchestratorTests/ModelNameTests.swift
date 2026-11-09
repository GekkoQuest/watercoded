import AgentKit
import Testing

@Suite("Model names")
struct ModelNameTests {
    @Test(arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5"),
        ("claude-opus-5-5[1m]", "Opus 5.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("opus", "Opus")
    ])
    func `claude IDs become short names`(id: String, expected: String) {
        #expect(ModelName.display(id) == expected)
    }

    @Test
    func `other IDs are left alone`() {
        #expect(ModelName.display("gpt-5") == "gpt-5")
        #expect(ModelName.display("my-model") == "my-model")
    }
}
