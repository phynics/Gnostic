// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import Testing
import GnosticRLM

@Suite("RLM path normalization")
struct RLMPathTests {
    @Test("normalizes separators and dot components")
    func normalizes() throws {
        #expect(try RLMPath.normalize("Sources//GnosticCore/./Runtime") == "Sources/GnosticCore/Runtime")
        #expect(try RLMPath.normalize("README.md") == "README.md")
    }

    @Test("rejects absolute paths")
    func rejectsAbsolute() {
        #expect(throws: RLMFailure.absolutePathRejected("/etc/passwd")) {
            try RLMPath.normalize("/etc/passwd")
        }
        #expect(throws: RLMFailure.absolutePathRejected("~/secrets")) {
            try RLMPath.normalize("~/secrets")
        }
        #expect(throws: RLMFailure.absolutePathRejected("C:/Windows")) {
            try RLMPath.normalize("C:/Windows")
        }
    }

    @Test("rejects parent traversal")
    func rejectsTraversal() {
        #expect(throws: RLMFailure.parentTraversalRejected("../outside")) {
            try RLMPath.normalize("../outside")
        }
        #expect(throws: RLMFailure.parentTraversalRejected("Sources/../../etc")) {
            try RLMPath.normalize("Sources/../../etc")
        }
    }

    @Test("rejects malformed paths")
    func rejectsMalformed() {
        #expect(throws: RLMFailure.invalidPath("")) {
            try RLMPath.normalize("")
        }
        #expect(throws: RLMFailure.invalidPath("Sources\\Runtime")) {
            try RLMPath.normalize("Sources\\Runtime")
        }
    }

    @Test("applies allowed prefixes by path boundary")
    func prefixBoundary() {
        #expect(RLMPath.isWithin("Sources/A/x.swift", prefixes: ["Sources/A"]))
        #expect(!RLMPath.isWithin("Sources/AB/x.swift", prefixes: ["Sources/A"]))
        #expect(!RLMPath.isWithin("Other/x.swift", prefixes: ["Sources/A"]))
        #expect(RLMPath.isWithin("Anything", prefixes: []))
    }
}
