import Foundation
import Testing
@testable import WatercodedCore

@Suite("MCP forms")
struct FormRecordTests {
    @Test func `every MCP field type is parsed, in the requested order`() {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "email": ["type": "string", "format": "email", "title": "Email"],
                "age": ["type": "integer", "minimum": 0, "maximum": 130],
                "agree": ["type": "boolean", "title": "Agree", "default": true],
                "role": ["type": "string", "oneOf": [["const": "dev", "title": "Developer"]]],
                "size": ["type": "string", "enum": ["s", "m"], "enumNames": ["Small", "Medium"]],
                "tags": ["type": "array", "minItems": 1, "items": ["enum": ["a", "b"]]],
                "nested": ["type": "object"]
            ],
            "required": ["email", "role"]
        ]
        let fields = FormRecord.fields(from: schema, order: ["role", "email"])
        #expect(fields.map(\.key) == ["role", "email", "age", "agree", "size", "tags"]) // `nested` isn't supported
        #expect(fields[0].kind == .choice([.init(value: "dev", title: "Developer")]))
        #expect(fields[0].isRequired && fields[1].isRequired && !fields[2].isRequired)
        #expect(fields[1].kind == .text(format: "email", minLength: nil, maxLength: nil))
        #expect(fields[2].kind == .number(integer: true, minimum: 0, maximum: 130))
        #expect(fields[2].title == "age") // falls back to the key
        #expect(fields[3].defaultValue == true)
        #expect(fields[4].kind == .choice([.init(value: "s", title: "Small"), .init(value: "m", title: "Medium")]))
        #expect(fields[5].kind == .multipleChoice(
            [.init(value: "a", title: "a"), .init(value: "b", title: "b")],
            minItems: 1,
            maxItems: nil
        ))
    }

    @Test func `an empty or missing schema has no fields`() {
        #expect(FormRecord.fields(from: ["type": "object", "properties": [:]]).isEmpty)
        #expect(FormRecord.fields(from: nil).isEmpty)
    }
}
