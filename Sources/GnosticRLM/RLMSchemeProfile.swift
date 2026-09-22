// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The host-owned `gnostic-rlm-scheme-0` program profile.
///
/// The parent parses and validates every generated cell before it reaches a
/// worker. The worker is the evaluator; this profile is the policy authority.
public enum RLMSchemeProfile {
    public static let name = "gnostic-rlm-scheme-0"

    /// Host-owned structural limits for one generated cell.
    public struct Limits: Sendable, Equatable {
        public var maxSourceBytes: Int
        public var maxDepth: Int
        public var maxNodes: Int
        public var maxForms: Int
        public var maxLiteralCollectionElements: Int
        public var maxIntegerMagnitude: Int
        public var maxStringLength: Int

        public init(
            maxSourceBytes: Int,
            maxDepth: Int,
            maxNodes: Int,
            maxForms: Int,
            maxLiteralCollectionElements: Int,
            maxIntegerMagnitude: Int,
            maxStringLength: Int
        ) {
            self.maxSourceBytes = maxSourceBytes
            self.maxDepth = maxDepth
            self.maxNodes = maxNodes
            self.maxForms = maxForms
            self.maxLiteralCollectionElements = maxLiteralCollectionElements
            self.maxIntegerMagnitude = maxIntegerMagnitude
            self.maxStringLength = maxStringLength
        }

        public static let standard = Limits(
            maxSourceBytes: 32 * 1_024,
            maxDepth: 64,
            maxNodes: 8_192,
            maxForms: 512,
            maxLiteralCollectionElements: 2_048,
            maxIntegerMagnitude: 1_000_000_000_000,
            maxStringLength: 16 * 1_024
        )
    }

    public static let specialForms: Set<String> = [
        "quote", "if", "cond", "and", "or", "begin",
        "lambda", "let", "let*", "letrec", "define",
    ]

    public static let hostCalls: Set<String> = [
        "corpus-search", "corpus-read", "corpus-read-many",
        "lm-query", "lm-query-batched", "progress", "finish",
    ]

    public static let pureOperations: Set<String> = [
        "+", "-", "*", "/", "quotient", "remainder", "modulo", "abs", "min", "max",
        "expt", "sqrt", "gcd", "lcm", "floor", "ceiling", "round", "truncate",
        "=", "<", ">", "<=", ">=", "zero?", "positive?", "negative?", "odd?", "even?",
        "number?", "integer?", "exact?", "inexact?", "not",
        "eq?", "eqv?", "equal?",
        "string?", "string-append", "string-length", "string-ref", "substring",
        "string=?", "string<?", "string>?", "string<=?", "string>=?",
        "string-contains", "string-split", "string-join",
        "string-upcase", "string-downcase", "string->list", "list->string",
        "make-string", "number->string", "string->number",
        "symbol?", "symbol->string", "string->symbol",
        "list", "list?", "pair?", "null?", "cons", "car", "cdr",
        "caar", "cadr", "cdar", "cddr", "caddr", "cadddr",
        "length", "append", "reverse", "list-ref", "list-tail", "make-list",
        "member", "memq", "memv", "assoc", "assq", "assv",
        "map", "for-each", "filter", "sort", "apply",
        "vector?", "vector", "vector-length", "vector-ref",
        "vector->list", "list->vector", "make-vector",
    ]

    public static let reservedNames: Set<String> = specialForms.union(hostCalls)

    public static let disallowedSymbols: Set<String> = [
        "set!", "define-syntax", "let-syntax", "letrec-syntax", "define-macro",
        "syntax-rules", "syntax-case", "macroexpand", "eval", "load", "include",
        "import", "use-modules", "dynamic-wind", "call/cc",
        "call-with-current-continuation", "call-with-values", "values",
        "open-input-file", "open-output-file", "open-input-string",
        "open-output-string", "with-input-from-file", "with-output-to-file",
        "file-exists?", "delete-file", "system", "open-pipe", "getenv", "setenv",
        "environ", "current-time", "get-internal-real-time", "random", "random:uniform",
        "string-match", "make-regexp", "regexp-exec", "vector-set!", "set-car!",
        "set-cdr!", "list-set!", "string-set!", "display", "write", "newline",
        "read", "read-line", "sleep", "usleep", "primitive-eval", "procedure->pointer",
        "dynamic-link", "dynamic-func", "load-extension", "make-thread",
        "call-with-input-file", "call-with-output-file", "chdir", "mkdir", "rmdir",
    ]

    fileprivate static let hostArities: [String: ClosedRange<Int>] = [
        "corpus-search": 2...2,
        "corpus-read": 1...1,
        "corpus-read-many": 1...1,
        "lm-query": 1...2,
        "lm-query-batched": 1...2,
        "progress": 1...1,
        "finish": 2...2,
    ]

    /// Parses and validates one generated cell.
    ///
    /// `definitions` carries the names accepted from earlier cells in the same
    /// invocation, so a later cell may reference an earlier `define`.
    public static func validate(
        _ source: String,
        limits: Limits = .standard,
        definitions: Set<String> = []
    ) throws -> RLMSchemeValidation {
        guard source.utf8.count <= limits.maxSourceBytes else {
            throw RLMSchemeValidationError.excessiveProgramSize(limit: limits.maxSourceBytes)
        }
        let forms: [RLMSExpression]
        do {
            forms = try RLMSExpressionParser.parse(source)
        } catch let error as RLMSExpressionParseError {
            throw RLMSchemeValidationError.malformedProgram(error.description)
        }
        guard !forms.isEmpty else {
            throw RLMSchemeValidationError.malformedProgram("empty cell")
        }
        guard forms.count <= limits.maxForms else {
            throw RLMSchemeValidationError.excessiveProgramSize(limit: limits.maxForms)
        }
        var validator = Validator(limits: limits, definitions: definitions)
        try validator.run(forms)
        return RLMSchemeValidation(
            profile: name,
            forms: forms,
            usage: validator.usage,
            hostCallCount: validator.hostCallCount
        )
    }

    /// Validates a cell and reports the profile features it uses.
    public static func analyze(
        _ source: String,
        limits: Limits = .standard,
        definitions: Set<String> = []
    ) throws -> RLMSchemeFeatureUsage {
        try validate(source, limits: limits, definitions: definitions).usage
    }
}

/// The profile features used by one accepted cell.
public struct RLMSchemeFeatureUsage: Sendable, Equatable {
    public var specialForms: Set<String> = []
    public var hostCalls: Set<String> = []
    public var pureOperations: Set<String> = []
    public var userDefinitions: Set<String> = []
    public var literalStrings = 0
    public var literalNumbers = 0
    public var literalBooleans = 0
    public var literalCollections = 0
    public var maxDepth = 0

    public init() {}
}

/// The accepted program and its recorded feature usage.
public struct RLMSchemeValidation: Sendable, Equatable {
    public let profile: String
    public let forms: [RLMSExpression]
    public let usage: RLMSchemeFeatureUsage
    public let hostCallCount: Int

    public init(
        profile: String,
        forms: [RLMSExpression],
        usage: RLMSchemeFeatureUsage,
        hostCallCount: Int
    ) {
        self.profile = profile
        self.forms = forms
        self.usage = usage
        self.hostCallCount = hostCallCount
    }
}

/// Why a generated cell was rejected before evaluation.
public enum RLMSchemeValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformedProgram(String)
    case disallowedForm(String)
    case disallowedSymbol(String)
    case reservedRedefinition(String)
    case excessiveDepth(limit: Int)
    case excessiveProgramSize(limit: Int)
    case excessiveLiteral(limit: Int)
    case invalidArity(symbol: String, expected: String, actual: Int)
    case unorderedHostCalls
    case invalidFinishPlacement
    case invalidFinishArgument(String)
    case unsupportedValue(String)

    public var description: String {
        switch self {
        case let .malformedProgram(reason):
            return "malformed program: \(reason)"
        case let .disallowedForm(name):
            return "disallowed form '\(name)'"
        case let .disallowedSymbol(name):
            return "disallowed symbol '\(name)'"
        case let .reservedRedefinition(name):
            return "reserved name '\(name)' cannot be redefined"
        case let .excessiveDepth(limit):
            return "program nesting exceeds \(limit)"
        case let .excessiveProgramSize(limit):
            return "program size exceeds \(limit)"
        case let .excessiveLiteral(limit):
            return "literal collection exceeds \(limit) elements"
        case let .invalidArity(symbol, expected, actual):
            return "host call '\(symbol)' expects \(expected) arguments, got \(actual)"
        case .unorderedHostCalls:
            return "multiple host calls in one unordered expression"
        case .invalidFinishPlacement:
            return "finish appears in a non-terminal position"
        case let .invalidFinishArgument(reason):
            return "invalid finish argument: \(reason)"
        case let .unsupportedValue(reason):
            return "unsupported value: \(reason)"
        }
    }
}

private struct Validator {
    let limits: RLMSchemeProfile.Limits
    let knownDefinitions: Set<String>
    var usage = RLMSchemeFeatureUsage()
    var hostCallCount = 0

    private var scopes: [Set<String>] = []
    private var nodeCount = 0

    init(limits: RLMSchemeProfile.Limits, definitions: Set<String>) {
        self.limits = limits
        self.knownDefinitions = definitions
    }

    mutating func run(_ forms: [RLMSExpression]) throws {
        scopes = [Self.collectDefinitions(forms).union(knownDefinitions)]
        try walkSequence(forms, depth: 0, allowFinish: true)
    }

    private static func collectDefinitions(_ forms: [RLMSExpression]) -> Set<String> {
        var names = Set<String>()
        for form in forms {
            guard case let .list(elements) = form, elements.count >= 2 else { continue }
            guard case let .symbol(head) = elements[0], head == "define" else { continue }
            switch elements[1] {
            case let .symbol(name):
                if isAllowedBoundName(name) { names.insert(name) }
            case let .list(parts):
                if let first = parts.first, case let .symbol(name) = first, isAllowedBoundName(name) {
                    names.insert(name)
                }
            default:
                break
            }
        }
        return names
    }

    private static func isAllowedBoundName(_ name: String) -> Bool {
        !RLMSchemeProfile.reservedNames.contains(name)
            && !RLMSchemeProfile.disallowedSymbols.contains(name)
            && !name.hasSuffix("!")
    }

    private mutating func walkSequence(
        _ expressions: [RLMSExpression],
        depth: Int,
        allowFinish: Bool
    ) throws {
        for (index, expression) in expressions.enumerated() {
            let isLast = index == expressions.count - 1
            try walk(expression, depth: depth, allowFinish: allowFinish && isLast)
        }
    }

    private mutating func walk(
        _ expression: RLMSExpression,
        depth: Int,
        allowFinish: Bool
    ) throws {
        nodeCount += 1
        guard nodeCount <= limits.maxNodes else {
            throw RLMSchemeValidationError.excessiveProgramSize(limit: limits.maxNodes)
        }
        usage.maxDepth = max(usage.maxDepth, depth)
        guard depth <= limits.maxDepth else {
            throw RLMSchemeValidationError.excessiveDepth(limit: limits.maxDepth)
        }

        switch expression {
        case let .symbol(name):
            try resolveValue(name)

        case let .list(elements):
            guard let head = elements.first else {
                throw RLMSchemeValidationError.malformedProgram("empty application")
            }
            let arguments = Array(elements.dropFirst())
            if case let .symbol(name) = head, RLMSchemeProfile.specialForms.contains(name) {
                try walkSpecial(name, arguments: arguments, depth: depth, allowFinish: allowFinish)
            } else {
                if !allowFinish, Self.containsFinishCall(expression) {
                    throw RLMSchemeValidationError.invalidFinishPlacement
                }
                try walkApplication(elements, depth: depth)
            }

        case let .vector(elements):
            usage.literalCollections += 1
            guard elements.count <= limits.maxLiteralCollectionElements else {
                throw RLMSchemeValidationError.excessiveLiteral(limit: limits.maxLiteralCollectionElements)
            }
            for element in elements {
                try walk(element, depth: depth + 1, allowFinish: false)
            }

        case let .string(value):
            usage.literalStrings += 1
            guard value.utf8.count <= limits.maxStringLength else {
                throw RLMSchemeValidationError.excessiveLiteral(limit: limits.maxStringLength)
            }

        case let .integer(value):
            usage.literalNumbers += 1
            guard value.magnitude <= limits.maxIntegerMagnitude else {
                throw RLMSchemeValidationError.unsupportedValue("integer literal out of range")
            }

        case let .double(value):
            usage.literalNumbers += 1
            guard value.isFinite else {
                throw RLMSchemeValidationError.unsupportedValue("non-finite number")
            }

        case .boolean:
            usage.literalBooleans += 1

        case .character:
            throw RLMSchemeValidationError.unsupportedValue("character literals are not in the profile")
        }
    }

    private mutating func walkSpecial(
        _ name: String,
        arguments: [RLMSExpression],
        depth: Int,
        allowFinish: Bool
    ) throws {
        usage.specialForms.insert(name)
        switch name {
        case "quote":
            try requireArity(name, arguments.count, 1...1)
            try checkLiteral(arguments[0], depth: depth + 1)

        case "if":
            try requireArity(name, arguments.count, 2...3)
            try walk(arguments[0], depth: depth + 1, allowFinish: false)
            try walk(arguments[1], depth: depth + 1, allowFinish: allowFinish)
            if arguments.count == 3 {
                try walk(arguments[2], depth: depth + 1, allowFinish: allowFinish)
            }

        case "cond":
            guard !arguments.isEmpty else {
                throw RLMSchemeValidationError.malformedProgram("cond requires clauses")
            }
            try walkCondClauses(arguments, depth: depth, allowFinish: allowFinish)

        case "and", "or", "begin":
            try walkSequence(arguments, depth: depth, allowFinish: allowFinish)

        case "lambda":
            guard arguments.count >= 2 else {
                throw RLMSchemeValidationError.invalidArity(symbol: name, expected: "2 or more", actual: arguments.count)
            }
            let parameters = try parameterNames(arguments[0])
            scopes.append(parameters)
            defer { scopes.removeLast() }
            try walkSequence(Array(arguments.dropFirst()), depth: depth + 1, allowFinish: allowFinish)

        case "let", "let*", "letrec":
            guard arguments.count >= 2 else {
                throw RLMSchemeValidationError.invalidArity(symbol: name, expected: "2 or more", actual: arguments.count)
            }
            if name == "let*" {
                scopes.append([])
                try walkSequentialBindings(arguments[0], depth: depth)
            } else {
                try walkBindings(arguments[0], depth: depth)
                scopes.append(try bindingNames(arguments[0]))
            }
            try walkSequence(Array(arguments.dropFirst()), depth: depth + 1, allowFinish: allowFinish)
            scopes.removeLast()

        case "define":
            try walkDefine(arguments, depth: depth, allowFinish: allowFinish)

        default:
            throw RLMSchemeValidationError.disallowedForm(name)
        }
    }

    private mutating func walkCondClauses(
        _ clauses: [RLMSExpression],
        depth: Int,
        allowFinish: Bool
    ) throws {
        for (index, clause) in clauses.enumerated() {
            guard case let .list(parts) = clause, let first = parts.first else {
                throw RLMSchemeValidationError.malformedProgram("cond clause must be a list")
            }
            let isElse = Self.isSymbol(first, "else")
            if isElse, index != clauses.count - 1 {
                throw RLMSchemeValidationError.malformedProgram("else must be the last cond clause")
            }
            if isElse {
                try walkSequence(Array(parts.dropFirst()), depth: depth + 1, allowFinish: allowFinish)
                continue
            }
            if parts.count >= 3, Self.isSymbol(parts[1], "=>") {
                guard parts.count == 3 else {
                    throw RLMSchemeValidationError.malformedProgram("cond => clause requires exactly one receiver")
                }
                try walk(parts[0], depth: depth + 1, allowFinish: false)
                try walk(parts[2], depth: depth + 1, allowFinish: false)
                continue
            }
            try walk(first, depth: depth + 1, allowFinish: false)
            try walkSequence(Array(parts.dropFirst()), depth: depth + 1, allowFinish: allowFinish)
        }
    }

    private mutating func walkDefine(
        _ arguments: [RLMSExpression],
        depth: Int,
        allowFinish: Bool
    ) throws {
        guard arguments.count >= 2 else {
            throw RLMSchemeValidationError.invalidArity(symbol: "define", expected: "2 or more", actual: arguments.count)
        }
        let target = arguments[0]
        switch target {
        case let .symbol(name):
            try validateDefinitionName(name)
            recordDefinition(name, depth: depth)
            guard arguments.count == 2 else {
                throw RLMSchemeValidationError.invalidArity(symbol: "define", expected: "2", actual: arguments.count)
            }
            try walk(arguments[1], depth: depth + 1, allowFinish: false)

        case let .list(parts):
            guard let first = parts.first, case let .symbol(name) = first else {
                throw RLMSchemeValidationError.malformedProgram("define requires a symbol or a procedure header")
            }
            try validateDefinitionName(name)
            recordDefinition(name, depth: depth)
            let parameters = try parameterNames(.list(Array(parts.dropFirst())))
            scopes.append(parameters)
            defer { scopes.removeLast() }
            try walkSequence(Array(arguments.dropFirst()), depth: depth + 1, allowFinish: allowFinish)

        default:
            throw RLMSchemeValidationError.malformedProgram("define requires a symbol or a procedure header")
        }
    }

    /// Records a definition for later cells only when it is top-level.
    ///
    /// Internal definitions bind over one body. Exporting their names would let
    /// a later cell resolve a symbol that is not bound in the run module, so a
    /// body-local `define` must not widen the accepted symbol surface.
    private mutating func recordDefinition(_ name: String, depth: Int) {
        guard depth == 0 else { return }
        usage.userDefinitions.insert(name)
    }

    private mutating func validateDefinitionName(_ name: String) throws {
        try validateBoundName(name)
    }

    private func validateBoundName(_ name: String) throws {
        if RLMSchemeProfile.reservedNames.contains(name) {
            throw RLMSchemeValidationError.reservedRedefinition(name)
        }
        if RLMSchemeProfile.disallowedSymbols.contains(name) || name.hasSuffix("!") {
            throw RLMSchemeValidationError.disallowedSymbol(name)
        }
    }

    private func validateFinishArguments(_ arguments: [RLMSExpression]) throws {
        guard arguments.count == 2 else { return }
        try validateFinishAnswer(arguments[0])
        try validateFinishEvidence(arguments[1])
    }

    private func validateFinishAnswer(_ expression: RLMSExpression) throws {
        switch expression {
        case .string, .symbol, .list:
            return
        case .vector, .integer, .double, .boolean, .character:
            throw RLMSchemeValidationError.invalidFinishArgument("finish answer must evaluate to a string")
        }
    }

    private func validateFinishEvidence(_ expression: RLMSExpression) throws {
        switch expression {
        case .symbol:
            return
        case .vector, .string, .integer, .double, .boolean, .character:
            throw RLMSchemeValidationError.invalidFinishArgument("finish evidence must evaluate to a list of chunk identifiers")
        case let .list(elements):
            guard let head = elements.first else {
                throw RLMSchemeValidationError.invalidFinishArgument("finish evidence must evaluate to a list of chunk identifiers")
            }
            if case let .symbol(name) = head, name == "quote" {
                try validateQuotedEvidence(elements)
                return
            }
            if case let .symbol(name) = head, name == "list" {
                for element in elements.dropFirst() {
                    switch element {
                    case .string, .symbol, .list:
                        continue
                    case .vector, .integer, .double, .boolean, .character:
                        throw RLMSchemeValidationError.invalidFinishArgument("finish evidence entries must be chunk identifier strings")
                    }
                }
                return
            }
            return
        }
    }

    private func validateQuotedEvidence(_ elements: [RLMSExpression]) throws {
        guard elements.count == 2, case let .list(values) = elements[1] else {
            throw RLMSchemeValidationError.invalidFinishArgument("finish evidence must evaluate to a list of chunk identifiers")
        }
        for value in values {
            guard case .string = value else {
                throw RLMSchemeValidationError.invalidFinishArgument("finish evidence entries must be chunk identifier strings")
            }
        }
    }

    private mutating func walkApplication(_ elements: [RLMSExpression], depth: Int) throws {
        guard let head = elements.first else {
            throw RLMSchemeValidationError.malformedProgram("empty application")
        }
        let arguments = Array(elements.dropFirst())
        try walkCallable(head, depth: depth)
        if case let .symbol(name) = head,
           RLMSchemeProfile.hostCalls.contains(name),
           let arity = RLMSchemeProfile.hostArities[name],
           !arity.contains(arguments.count) {
            throw RLMSchemeValidationError.invalidArity(
                symbol: name,
                expected: "\(arity.lowerBound)...\(arity.upperBound)",
                actual: arguments.count
            )
        }
        if case let .symbol(name) = head, name == "finish" {
            try validateFinishArguments(arguments)
        }

        var effectful = 0
        for argument in arguments {
            effectful += Self.countHostCalls(argument)
        }
        if effectful > 1 {
            throw RLMSchemeValidationError.unorderedHostCalls
        }
        for argument in arguments {
            try walk(argument, depth: depth + 1, allowFinish: false)
        }
    }

    private mutating func walkCallable(_ expression: RLMSExpression, depth: Int) throws {
        switch expression {
        case let .symbol(name):
            if RLMSchemeProfile.hostCalls.contains(name) {
                usage.hostCalls.insert(name)
                hostCallCount += 1
                return
            }
            if RLMSchemeProfile.specialForms.contains(name) {
                throw RLMSchemeValidationError.disallowedForm(name)
            }
            try resolveValue(name)
        default:
            try walk(expression, depth: depth + 1, allowFinish: false)
        }
    }

    private mutating func resolveValue(_ name: String) throws {
        if scopes.contains(where: { $0.contains(name) }) {
            return
        }
        if RLMSchemeProfile.pureOperations.contains(name) {
            usage.pureOperations.insert(name)
            return
        }
        if RLMSchemeProfile.hostCalls.contains(name) {
            throw RLMSchemeValidationError.disallowedSymbol(name)
        }
        if RLMSchemeProfile.specialForms.contains(name) {
            throw RLMSchemeValidationError.disallowedForm(name)
        }
        if RLMSchemeProfile.disallowedSymbols.contains(name) || name.hasSuffix("!") {
            throw RLMSchemeValidationError.disallowedSymbol(name)
        }
        throw RLMSchemeValidationError.disallowedSymbol(name)
    }

    private mutating func walkBindings(
        _ expression: RLMSExpression,
        depth: Int
    ) throws {
        guard case let .list(bindings) = expression else {
            throw RLMSchemeValidationError.malformedProgram("bindings must be a list")
        }
        var effectful = 0
        for binding in bindings {
            guard case let .list(parts) = binding, parts.count == 2, case let .symbol(name) = parts[0] else {
                throw RLMSchemeValidationError.malformedProgram("binding must be (name value)")
            }
            try validateBoundName(name)
            effectful += Self.countHostCalls(parts[1])
        }
        if effectful > 1 {
            throw RLMSchemeValidationError.unorderedHostCalls
        }
        for binding in bindings {
            guard case let .list(parts) = binding else { continue }
            try walk(parts[1], depth: depth + 1, allowFinish: false)
        }
    }

    private mutating func walkSequentialBindings(
        _ expression: RLMSExpression,
        depth: Int
    ) throws {
        guard case let .list(bindings) = expression else {
            throw RLMSchemeValidationError.malformedProgram("bindings must be a list")
        }
        for binding in bindings {
            guard case let .list(parts) = binding, parts.count == 2, case let .symbol(name) = parts[0] else {
                throw RLMSchemeValidationError.malformedProgram("binding must be (name value)")
            }
            try validateBoundName(name)
            try walk(parts[1], depth: depth + 1, allowFinish: false)
            scopes[scopes.count - 1].insert(name)
        }
    }

    private func bindingNames(_ expression: RLMSExpression) throws -> Set<String> {
        guard case let .list(bindings) = expression else {
            throw RLMSchemeValidationError.malformedProgram("bindings must be a list")
        }
        var names = Set<String>()
        for binding in bindings {
            guard case let .list(parts) = binding, let first = parts.first, case let .symbol(name) = first else {
                throw RLMSchemeValidationError.malformedProgram("binding must be (name value)")
            }
            try validateBoundName(name)
            names.insert(name)
        }
        return names
    }

    private func parameterNames(_ expression: RLMSExpression) throws -> Set<String> {
        guard case let .list(parameters) = expression else {
            throw RLMSchemeValidationError.malformedProgram("parameters must be a list")
        }
        var names = Set<String>()
        for parameter in parameters {
            guard case let .symbol(name) = parameter else {
                throw RLMSchemeValidationError.malformedProgram("parameter must be a symbol")
            }
            try validateBoundName(name)
            names.insert(name)
        }
        return names
    }

    private mutating func checkLiteral(_ expression: RLMSExpression, depth: Int) throws {
        guard depth <= limits.maxDepth else {
            throw RLMSchemeValidationError.excessiveDepth(limit: limits.maxDepth)
        }
        switch expression {
        case let .list(elements):
            usage.literalCollections += 1
            guard elements.count <= limits.maxLiteralCollectionElements else {
                throw RLMSchemeValidationError.excessiveLiteral(limit: limits.maxLiteralCollectionElements)
            }
            for element in elements {
                try checkLiteral(element, depth: depth + 1)
            }
        case let .vector(elements):
            usage.literalCollections += 1
            guard elements.count <= limits.maxLiteralCollectionElements else {
                throw RLMSchemeValidationError.excessiveLiteral(limit: limits.maxLiteralCollectionElements)
            }
            for element in elements {
                try checkLiteral(element, depth: depth + 1)
            }
        case let .string(value):
            usage.literalStrings += 1
            guard value.utf8.count <= limits.maxStringLength else {
                throw RLMSchemeValidationError.excessiveLiteral(limit: limits.maxStringLength)
            }
        case let .integer(value):
            usage.literalNumbers += 1
            guard value.magnitude <= limits.maxIntegerMagnitude else {
                throw RLMSchemeValidationError.unsupportedValue("integer literal out of range")
            }
        case let .double(value):
            usage.literalNumbers += 1
            guard value.isFinite else {
                throw RLMSchemeValidationError.unsupportedValue("non-finite number")
            }
        case .boolean:
            usage.literalBooleans += 1
        case .symbol, .character:
            break
        }
    }

    private func requireArity(_ name: String, _ actual: Int, _ range: ClosedRange<Int>) throws {
        guard range.contains(actual) else {
            throw RLMSchemeValidationError.invalidArity(
                symbol: name,
                expected: "\(range.lowerBound)...\(range.upperBound)",
                actual: actual
            )
        }
    }

    private static func isSymbol(_ expression: RLMSExpression, _ name: String) -> Bool {
        if case let .symbol(value) = expression { return value == name }
        return false
    }

    private static func containsFinishCall(_ expression: RLMSExpression) -> Bool {
        switch expression {
        case let .list(elements):
            if let head = elements.first, case let .symbol(name) = head, name == "finish" {
                return true
            }
            return elements.contains(where: containsFinishCall)
        case let .vector(elements):
            return elements.contains(where: containsFinishCall)
        case .symbol, .string, .integer, .double, .boolean, .character:
            return false
        }
    }

    private static func countHostCalls(_ expression: RLMSExpression) -> Int {
        switch expression {
        case let .list(elements):
            if let head = elements.first,
               case let .symbol(name) = head,
               RLMSchemeProfile.hostCalls.contains(name) {
                return 1
            }
            return elements.reduce(0) { $0 + countHostCalls($1) }
        case let .vector(elements):
            return elements.reduce(0) { $0 + countHostCalls($1) }
        case .symbol, .string, .integer, .double, .boolean, .character:
            return 0
        }
    }
}
