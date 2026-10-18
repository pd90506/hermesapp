import Foundation
import HermesProtocol

/// A tool result as readable text, and the failure a result reports, ported from
/// Desktop's `tool-result-summary.ts` (`apps/desktop/src/lib/tool-result-summary.ts`).
///
/// Desktop walks objects in their keys' JSON order; `JSONValue` keeps no order, so
/// keys that aren't ranked first are taken in alphabetical order here.
enum ToolResultText {
    static let wrapperKeys = ["data", "result", "output", "response", "payload"]
    static let priorityKeys = ["title", "name", "path", "file", "filepath", "url", "href", "link", "status", "id",
                               "message", "summary", "description"]
    static let errorKeys = ["error", "errors", "failure", "exception"]
    static let errorMessageKeys = ["message", "reason", "detail"]
    static let nonErrorText: Set<String> = ["", "0", "false", "none", "null", "nil", "ok", "success", "n/a", "na"]

    /// The result as a short block: a message, a list of fields, or a list of items.
    static func summary(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        let unwrapped = summaryValue(unwrapPayload(value), depth: 0)
        return unwrapped.isEmpty ? summaryValue(value, depth: 0) : unwrapped
    }

    /// The failure the result reports, nested anywhere under an error key, or "".
    static func errorMessage(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        return nestedError(value, depth: 0, failed: false)
    }

    // MARK: Parsing

    /// A string holding JSON (an object, an array or a quoted string) as that JSON.
    static func norm(_ value: JSONValue) -> JSONValue {
        guard case .string(let text) = value else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .string("") }
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("\"") else { return value }
        return ToolCallView.parseJSON(trimmed) ?? value
    }

    static func unwrapPayload(_ value: JSONValue) -> JSONValue {
        var current = norm(value)
        for _ in 0..<4 {
            guard case .object(let record) = current else { return current }
            guard let key = wrapperKeys.first(where: { record[$0].map { !$0.isNull } ?? false }) else { return current }
            current = norm(record[key]!)
        }
        return current
    }

    // MARK: Summary

    static func titleCase(_ key: String) -> String {
        key.split(whereSeparator: { "_-.".contains($0) }).map { ToolCallView.capitalize(String($0)) }
            .joined(separator: " ")
    }

    static func pluralize(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    static func clipInline(_ value: String, _ max: Int = 180) -> String {
        let line = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    static func clipBlock(_ value: String, maxCharacters: Int = 1800, maxLines: Int = 18) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        var text = lines.prefix(maxLines).joined(separator: "\n")
        let clipped = lines.count > maxLines || text.count > maxCharacters
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters - 1))
            while text.last?.isWhitespace == true { text.removeLast() }
        }
        return clipped && !text.hasSuffix("…") ? text + "…" : text
    }

    static func firstString(_ record: [String: JSONValue], _ keys: [String]) -> String {
        ToolCallView.firstString(record, keys)
    }

    static func orderedKeys(_ keys: some Collection<String>) -> [String] {
        let priority = priorityKeys.filter(keys.contains)
        return priority + keys.filter { !priorityKeys.contains($0) }.sorted()
    }

    static func isWrapperKey(_ key: String) -> Bool { wrapperKeys.contains(key) }

    static func skipField(_ key: String, _ value: JSONValue?) -> Bool {
        isWrapperKey(key) || ((key == "success" || key == "ok") && value == .bool(true))
    }

    static func scalar(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): clipInline(text)
        case .number: ToolCallView.numberText(value)
        case .bool(let flag): flag ? "true" : "false"
        default: ""
        }
    }

    static func recordInline(_ record: [String: JSONValue], depth: Int) -> String {
        if depth > 3 { return pluralize(record.count, "field") }
        let title = firstString(record, ["title", "name", "path", "file", "filepath", "url", "href", "link", "id"])
        let status = firstString(record, ["status", "category", "type"])
        let message = firstString(record, ["snippet", "summary", "description", "message"])
        if !title.isEmpty, !status.isEmpty { return "\(clipInline(title, 110)) (\(clipInline(status, 54)))" }
        if !title.isEmpty, !message.isEmpty, title != message {
            return "\(clipInline(title, 90)) - \(clipInline(message, 84))"
        }
        if !title.isEmpty { return clipInline(title, 150) }
        let pairs = orderedKeys(record.keys).filter { !skipField($0, record[$0]) }.compactMap { key -> String? in
            let text = record[key].map(scalar) ?? ""
            return text.isEmpty ? nil : "\(titleCase(key)): \(text)"
        }.prefix(2)
        return pairs.isEmpty ? pluralize(record.count, "field") : pairs.joined(separator: " · ")
    }

    static func listItem(_ item: JSONValue, depth: Int) -> String {
        switch norm(item) {
        case .string(let text): clipInline(text)
        case .number, .bool: scalar(norm(item))
        case .null: ""
        case .array(let values): pluralize(values.count, "item")
        case .object(let record): recordInline(record, depth: depth + 1)
        }
    }

    static func fieldValue(_ value: JSONValue, depth: Int) -> String {
        let value = norm(value)
        let text = scalar(value)
        if !text.isEmpty { return text }
        switch value {
        case .array(let values):
            if values.isEmpty { return "" }
            let scalars = values.map(scalar).filter { !$0.isEmpty }
            if scalars.count == values.count, values.count <= 4 { return clipInline(scalars.joined(separator: ", ")) }
            let first = listItem(values[0], depth: depth + 1)
            return first.isEmpty ? pluralize(values.count, "item") : "\(pluralize(values.count, "item")) (\(first))"
        case .object(let record):
            return recordInline(record, depth: depth + 1)
        default:
            return ""
        }
    }

    static func arraySummary(_ values: [JSONValue], depth: Int) -> String {
        if values.isEmpty { return "" }
        let max = 6
        var lines = values.prefix(max).map { listItem($0, depth: depth + 1) }.filter { !$0.isEmpty }.map { "- \($0)" }
        if lines.isEmpty { return "" }
        if values.count > max {
            let remaining = values.count - max
            lines.append("- … \(remaining) more \(remaining == 1 ? "item" : "items")")
        }
        return lines.joined(separator: "\n")
    }

    static func recordSummary(_ record: [String: JSONValue], depth: Int) -> String {
        if record.isEmpty { return "" }
        if depth <= 2 {
            let direct = firstString(record, ["message", "summary", "description", "preview", "text", "content"])
            let meaningful = record.keys.filter { !skipField($0, record[$0]) && !isWrapperKey($0) }
            if !direct.isEmpty, meaningful.count <= 1 { return clipBlock(direct) }
        }
        let candidates = orderedKeys(record.keys).filter { !skipField($0, record[$0]) }
        var lines: [String] = []
        for key in candidates {
            let text = fieldValue(record[key]!, depth: depth + 1)
            if text.isEmpty { continue }
            lines.append("- \(titleCase(key)): \(text)")
            if lines.count >= 8 { break }
        }
        if lines.isEmpty { return "" }
        if candidates.count > lines.count {
            let remaining = candidates.count - lines.count
            lines.append("- … \(remaining) more \(remaining == 1 ? "field" : "fields")")
        }
        return lines.joined(separator: "\n")
    }

    static func summaryValue(_ value: JSONValue, depth: Int) -> String {
        if depth > 4 { return "" }
        switch norm(value) {
        case .string(let text): return clipBlock(text)
        case .number, .bool: return scalar(norm(value))
        case .null: return ""
        case .array(let values): return arraySummary(values, depth: depth + 1)
        case .object(let record): return recordSummary(record, depth: depth + 1)
        }
    }

    // MARK: Errors

    static func meaningfulError(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch norm(value) {
        case .null: return false
        case .string(let text): return !nonErrorText.contains(text.trimmingCharacters(in: .whitespaces).lowercased())
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .array(let values): return values.contains { meaningfulError($0) }
        case .object(let record): return !record.isEmpty
        }
    }

    static func errorSignal(_ record: [String: JSONValue]) -> Bool {
        let status = record["status"]?.stringValue ?? ""
        return record["success"] == .bool(false) || record["ok"] == .bool(false)
            || isFailureStatus(status) || errorKeys.contains { meaningfulError(record[$0]) }
    }

    static func isFailureStatus(_ status: String) -> Bool {
        status.trimmingCharacters(in: .whitespaces)
            .range(of: "^(error|failed|failure|fatal|exception)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func valueErrorText(_ value: JSONValue) -> String {
        switch norm(value) {
        case .string(let text):
            return meaningfulError(.string(text)) ? clipBlock(text, maxCharacters: 700, maxLines: 12) : ""
        case .array(let values):
            let texts = values.map(valueErrorText).filter { !$0.isEmpty }.prefix(3)
            return clipBlock(texts.joined(separator: "; "), maxCharacters: 700, maxLines: 12)
        case .object(let record):
            let direct = firstString(record, errorMessageKeys)
            return direct.isEmpty ? "" : clipBlock(direct, maxCharacters: 700, maxLines: 12)
        default:
            return ""
        }
    }

    static func nestedError(_ value: JSONValue, depth: Int, failed: Bool) -> String {
        if depth > 5 { return "" }
        switch norm(value) {
        case .array(let values):
            for item in values {
                let nested = nestedError(item, depth: depth + 1, failed: failed)
                if !nested.isEmpty { return nested }
            }
            return ""
        case .object(let record):
            if record["success"] == .bool(true) || record["ok"] == .bool(true) { return "" }
            for key in errorKeys where meaningfulError(record[key]) {
                let text = valueErrorText(record[key]!)
                if !text.isEmpty { return text }
            }
            if errorSignal(record) {
                let direct = firstString(record, errorMessageKeys)
                if !direct.isEmpty { return clipBlock(direct, maxCharacters: 700, maxLines: 12) }
            }
            // Returned data and stdout can describe failures without the tool failing.
            // Only unwrap them to explain a failure already declared by the envelope.
            let declared = failed || errorSignal(record)
            let keys = declared ? errorKeys + wrapperKeys + ["details"] : errorKeys
            for key in keys {
                guard let child = record[key] else { continue }
                let nested = nestedError(child, depth: depth + 1, failed: declared)
                if !nested.isEmpty { return nested }
            }
            return ""
        default:
            return ""
        }
    }
}
