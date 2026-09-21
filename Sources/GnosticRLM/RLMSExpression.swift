// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// A restricted, portable S-expression value.
///
/// This is the common value model for the parent-side cell validator and the
/// framed worker protocol. It carries only values that can cross a
/// JSON-compatible boundary: symbols, strings, numbers, booleans, characters,
/// proper lists, and vectors.
public indirect enum RLMSExpression: Sendable, Equatable {
    case symbol(String)
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case character(String)
    case list([RLMSExpression])
    case vector([RLMSExpression])

    /// The canonical Scheme text for this value.
    public var written: String {
        switch self {
        case let .symbol(name):
            return name
        case let .string(value):
            return Self.writeString(value)
        case let .integer(value):
            return String(value)
        case let .double(value):
            return Self.writeDouble(value)
        case let .boolean(value):
            return value ? "#t" : "#f"
        case let .character(value):
            return "#\\" + value
        case let .list(elements):
            return "(" + elements.map(\.written).joined(separator: " ") + ")"
        case let .vector(elements):
            return "#(" + elements.map(\.written).joined(separator: " ") + ")"
        }
    }

    private static func writeString(_ value: String) -> String {
        var output = "\""
        for character in value {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\t": output += "\\t"
            case "\r": output += "\\r"
            default: output.append(character)
            }
        }
        return output + "\""
    }

    private static func writeDouble(_ value: Double) -> String {
        if value.rounded() == value, value.magnitude < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }
}

/// A parse failure for a restricted S-expression source.
public enum RLMSExpressionParseError: Error, Sendable, Equatable, CustomStringConvertible {
    case unterminatedString
    case unterminatedList
    case unexpectedCloseParenthesis(offset: Int)
    case unexpectedToken(String)
    case invalidEscape(String)
    case invalidNumber(String)

    public var description: String {
        switch self {
        case .unterminatedString:
            return "unterminated string literal"
        case .unterminatedList:
            return "unterminated list"
        case let .unexpectedCloseParenthesis(offset):
            return "unexpected ')' at offset \(offset)"
        case let .unexpectedToken(token):
            return "unexpected token '\(token)'"
        case let .invalidEscape(escape):
            return "invalid string escape '\(escape)'"
        case let .invalidNumber(token):
            return "invalid number '\(token)'"
        }
    }
}

/// Parses restricted S-expressions without Foundation or a Scheme runtime.
public enum RLMSExpressionParser {
    /// Parses `source` into its top-level forms.
    public static func parse(_ source: String) throws -> [RLMSExpression] {
        var parser = Parser(source: source)
        return try parser.parseTopLevel()
    }
}

private struct Parser {
    private let characters: [Character]
    private var index = 0

    init(source: String) {
        self.characters = Array(source)
    }

    private var offset: Int { index }

    private var isAtEnd: Bool { index >= characters.count }

    private func peek() -> Character? {
        isAtEnd ? nil : characters[index]
    }

    private mutating func advance() -> Character? {
        guard !isAtEnd else { return nil }
        defer { index += 1 }
        return characters[index]
    }

    mutating func parseTopLevel() throws -> [RLMSExpression] {
        var forms: [RLMSExpression] = []
        while true {
            skipTrivia()
            guard !isAtEnd else { return forms }
            forms.append(try parseDatum())
        }
    }

    private mutating func parseDatum() throws -> RLMSExpression {
        skipTrivia()
        guard let character = peek() else {
            throw RLMSExpressionParseError.unterminatedList
        }
        switch character {
        case "(":
            return .list(try parseSequence(until: ")"))
        case ")":
            throw RLMSExpressionParseError.unexpectedCloseParenthesis(offset: offset)
        case "\"":
            return .string(try parseString())
        case "'":
            _ = advance()
            return .list([.symbol("quote"), try parseDatum()])
        case "`":
            _ = advance()
            return .list([.symbol("quasiquote"), try parseDatum()])
        case ",":
            _ = advance()
            if peek() == "@" {
                _ = advance()
                return .list([.symbol("unquote-splicing"), try parseDatum()])
            }
            return .list([.symbol("unquote"), try parseDatum()])
        case "#":
            return try parseHash()
        default:
            return try parseAtom()
        }
    }

    private mutating func parseSequence(until terminator: Character) throws -> [RLMSExpression] {
        _ = advance()
        var elements: [RLMSExpression] = []
        while true {
            skipTrivia()
            guard let character = peek() else {
                throw RLMSExpressionParseError.unterminatedList
            }
            if character == terminator {
                _ = advance()
                return elements
            }
            elements.append(try parseDatum())
        }
    }

    private mutating func parseHash() throws -> RLMSExpression {
        _ = advance()
        guard let character = peek() else {
            throw RLMSExpressionParseError.unexpectedToken("#")
        }
        switch character {
        case "t", "T":
            _ = advance()
            return .boolean(true)
        case "f", "F":
            _ = advance()
            return .boolean(false)
        case "(":
            return .vector(try parseSequence(until: ")"))
        case "\\":
            _ = advance()
            return .character(parseCharacter())
        case ";":
            _ = advance()
            _ = try parseDatum()
            return try parseDatum()
        default:
            throw RLMSExpressionParseError.unexpectedToken("#" + String(character))
        }
    }

    private mutating func parseCharacter() -> String {
        guard let first = advance() else { return "" }
        var token = String(first)
        while let character = peek(), !Self.isDelimiter(character) {
            token.append(character)
            _ = advance()
        }
        if token.count == 1 { return token }
        switch token.lowercased() {
        case "space": return " "
        case "newline", "linefeed": return "\n"
        case "tab": return "\t"
        case "return": return "\r"
        case "null": return "\0"
        default: return token
        }
    }

    private mutating func parseString() throws -> String {
        _ = advance()
        var output = ""
        while true {
            guard let character = advance() else {
                throw RLMSExpressionParseError.unterminatedString
            }
            if character == "\"" {
                return output
            }
            if character != "\\" {
                output.append(character)
                continue
            }
            guard let escaped = advance() else {
                throw RLMSExpressionParseError.unterminatedString
            }
            switch escaped {
            case "n": output.append("\n")
            case "t": output.append("\t")
            case "r": output.append("\r")
            case "a": output.append("\u{07}")
            case "0": output.append("\0")
            case "\"": output.append("\"")
            case "\\": output.append("\\")
            case "x":
                var hex = ""
                while let digit = peek(), digit.isHexDigit {
                    hex.append(digit)
                    _ = advance()
                }
                if peek() == ";" { _ = advance() }
                guard let scalar = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(scalar) else {
                    throw RLMSExpressionParseError.invalidEscape("\\x" + hex)
                }
                output.unicodeScalars.append(unicode)
            default:
                throw RLMSExpressionParseError.invalidEscape("\\" + String(escaped))
            }
        }
    }

    private mutating func parseAtom() throws -> RLMSExpression {
        var token = ""
        while let character = peek(), !Self.isDelimiter(character) {
            token.append(character)
            _ = advance()
        }
        if token.isEmpty {
            throw RLMSExpressionParseError.unexpectedToken(String(peek() ?? " "))
        }
        if let integer = Int(token) {
            return .integer(integer)
        }
        if Self.isNumberToken(token), let double = Double(token) {
            return .double(double)
        }
        return .symbol(token)
    }

    private mutating func skipTrivia() {
        while let character = peek() {
            if character.isWhitespace {
                _ = advance()
                continue
            }
            if character == ";" {
                while let current = peek(), current != "\n" {
                    _ = advance()
                }
                continue
            }
            return
        }
    }

    private static func isDelimiter(_ character: Character) -> Bool {
        character.isWhitespace
            || character == "(" || character == ")"
            || character == "\"" || character == ";"
            || character == "'" || character == "`" || character == ","
    }

    private static func isNumberToken(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        guard first.isNumber || first == "-" || first == "+" || first == "." else { return false }
        return token.contains(".") || token.contains("e") || token.contains("E")
    }
}
