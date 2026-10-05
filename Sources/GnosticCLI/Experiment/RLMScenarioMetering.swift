// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import GnosticKit

// The RLM scenario consumes the experiment kit's metering (GNO-PLAT-030). These
// aliases keep the scenario's existing vocabulary while the kit owns the
// behavior and the model seam. GNO-PLAT-038 retargets the scenario onto the kit
// types directly and deletes this file.

typealias RLMScenarioGeneration = ExperimentGeneration
typealias RLMScenarioModelTransport = ExperimentModelTransport
typealias RLMScenarioUsage = ExperimentUsage
typealias RLMScenarioMeteredModel = ExperimentMeteredModel
typealias RLMScenarioPricing = ExperimentPricing
