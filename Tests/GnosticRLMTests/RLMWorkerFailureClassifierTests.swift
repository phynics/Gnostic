// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM
import Testing

@Suite("RLM worker failure classification")
struct RLMWorkerFailureClassifierTests {
    @Test("per-cell timeout and recursion bounds are repairable cell failures")
    func cellLimitsAreRepairable() {
        #expect(
            RLMWorkerFailureClassifier.classify("cell time limit exceeded")
                == .cellRuntimeFailed("cell time limit exceeded")
        )
        #expect(
            RLMWorkerFailureClassifier.classify("cell recursion limit exceeded")
                == .cellRuntimeFailed("cell recursion limit exceeded")
        )
    }

    @Test("the process-wide heap exhaustion remains terminal")
    func processResourceLimitIsTerminal() {
        #expect(
            RLMWorkerFailureClassifier.classify("resource limit exceeded")
                == .evaluatorFailed("resource limit exceeded")
        )
    }
}
