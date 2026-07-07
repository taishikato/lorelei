//
//  CodexAppServerJSONValueTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct CodexAppServerJSONValueTests {
    @Test func integerZeroAndOneDecodeAsNumbersNotBooleans() async throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"n0":0,"n1":1}"#.utf8))
        let value = try #require(CodexAppServerJSONValue(object))

        guard case .object(let fields) = value else {
            Issue.record("expected .object")
            return
        }
        #expect(fields["n0"] == .number(0))
        #expect(fields["n1"] == .number(1))
    }

    @Test func trueAndFalseDecodeAsBooleans() async throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"t":true,"f":false}"#.utf8))
        let value = try #require(CodexAppServerJSONValue(object))

        guard case .object(let fields) = value else {
            Issue.record("expected .object")
            return
        }
        #expect(fields["t"] == .bool(true))
        #expect(fields["f"] == .bool(false))
    }

    @Test func nonIntegerNumberDecodesAsNumber() async throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"pi":3.5}"#.utf8))
        let value = try #require(CodexAppServerJSONValue(object))

        guard case .object(let fields) = value else {
            Issue.record("expected .object")
            return
        }
        #expect(fields["pi"] == .number(3.5))
    }

    @Test func roundTripKeepsIntegersNumericAndBooleansBoolean() async throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"n1":1,"t":true}"#.utf8))
        let value = try #require(CodexAppServerJSONValue(object))

        let roundTripData = try JSONSerialization.data(withJSONObject: value.jsonObject)
        let roundTripped = try JSONSerialization.jsonObject(with: roundTripData)

        guard let roundTrippedFields = roundTripped as? [String: Any] else {
            Issue.record("expected round-tripped object")
            return
        }
        let n1 = try #require(roundTrippedFields["n1"] as? NSNumber)
        let t = try #require(roundTrippedFields["t"] as? NSNumber)

        #expect(CFGetTypeID(n1) != CFBooleanGetTypeID())
        #expect(n1 == 1)
        #expect(CFGetTypeID(t) == CFBooleanGetTypeID())
        #expect(t.boolValue == true)
    }

    @Test func nestedArrayInsideObjectKeepsIntegersAndBooleansDistinct() async throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"items":[0,true]}"#.utf8))
        let value = try #require(CodexAppServerJSONValue(object))

        guard case .object(let fields) = value, case .array(let items) = fields["items"] else {
            Issue.record("expected .object with .array items")
            return
        }
        #expect(items[0] == .number(0))
        #expect(items[1] == .bool(true))
    }
}
