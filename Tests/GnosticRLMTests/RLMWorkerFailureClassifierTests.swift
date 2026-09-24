// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticRLM
import Testing

@Suite("RLM worker failure classification")
struct RLMWorkerFailureClassifierTests {
    @Test("worker resource bounds are repairable cell failures")
    func cellLimitsAreRepairable() {
        #expect(
            RLMWorkerFailureClassifier.classify("cell time limit exceeded")
                == .cellRuntimeFailed("cell time limit exceeded")
        )
        #expect(
            RLMWorkerFailureClassifier.classify("cell recursion limit exceeded")
                == .cellRuntimeFailed("cell recursion limit exceeded")
        )
        #expect(
            RLMWorkerFailureClassifier.classify("resource limit exceeded")
                == .cellRuntimeFailed("resource limit exceeded")
        )
    }

    @Test("bounded host-call failures remain terminal")
    func hostCallFailureIsTerminal() {
        #expect(
            RLMWorkerFailureClassifier.classify("host call failed: Leaf model call limit reached: 2")
                == .evaluatorFailed("host call failed: Leaf model call limit reached: 2")
        )
    }
}
