// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Foundation
import GnosticCore
import Testing

@testable import GnosticCLI

@Suite("Structured error surfaces")
struct ErrorSurfaceTests {
    @Test("CLIConfigurationError exposes stable descriptions and reason codes")
    func cliConfigurationErrorSurface() {
        let malformed = CLIConfigurationError.malformedFile(URL(fileURLWithPath: "/tmp/config.json"))
        #expect(malformed.errorDescription?.contains("/tmp/config.json") == true)
        #expect(malformed.reasonCode == "malformedFile")

        let invalid = CLIConfigurationError.invalidValue(key: .mqttPort, value: "99999")
        #expect(invalid.errorDescription?.contains("99999") == true)
        #expect(invalid.errorDescription?.contains("mqtt.port") == true)
        #expect(invalid.reasonCode == "invalidValue")

        let unknown = CLIConfigurationError.unknownKey("bogus.key")
        #expect(unknown.errorDescription?.contains("bogus.key") == true)
        #expect(unknown.reasonCode == "unknownKey")
    }

    @Test("InspectError exposes stable descriptions and reason codes")
    func inspectErrorSurface() {
        let notFound = InspectError.notFound("abc")
        #expect(notFound.errorDescription?.contains("abc") == true)
        #expect(notFound.reasonCode == "notFound")

        let ambiguous = InspectError.ambiguous("abc", providers: ["p1", "p2"])
        #expect(ambiguous.errorDescription?.contains("p1") == true)
        #expect(ambiguous.errorDescription?.contains("p2") == true)
        #expect(ambiguous.reasonCode == "ambiguous")

        let unreachable = InspectError.brokerUnreachable("timed out")
        #expect(unreachable.errorDescription?.contains("timed out") == true)
        #expect(unreachable.reasonCode == "brokerUnreachable")
    }

}
