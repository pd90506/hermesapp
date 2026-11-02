import Foundation
import HermesProtocol

/// A live session's token use, as `_get_usage` reports it (`tui_gateway/server.py:1389-1438`):
/// on `session.info`, `message.complete`, `session.usage` (event and call). The session's
/// counters, and how full the model's context is once a turn measured it
/// (`agent/context_breakdown.py:130-140`). Desktop's status bar shows the same.
public struct SessionUsage: Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var total: Int
    /// Model calls this session made.
    public var calls: Int
    public var reasoning: Int?
    /// Tokens the last prompt filled, of `contextMax`.
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?
    /// The occupancy is an estimate, not the provider's count.
    public var contextEstimated: Bool
    public var compressions: Int?
    /// The prompt cache's hit rate, 0…100; absent before any cache read.
    public var cacheHitPercent: Int?
    /// Output tokens per second over the last calls.
    public var tokensPerSecond: Double?
    public var costUSD: Double?
    public var model: String?

    public init(input: Int = 0, output: Int = 0, total: Int = 0, calls: Int = 0, contextUsed: Int? = nil,
                contextMax: Int? = nil, contextPercent: Int? = nil, contextEstimated: Bool = false) {
        self.input = input
        self.output = output
        self.total = total
        self.calls = calls
        self.contextUsed = contextUsed
        self.contextMax = contextMax
        self.contextPercent = contextPercent
        self.contextEstimated = contextEstimated
    }

    /// The usage object; nil for anything else, or one with no counter at all.
    public init?(_ value: JSONValue?) {
        guard let value, value.objectValue != nil else { return nil }
        func int(_ key: String) -> Int? { value[key]?.doubleValue.map { Int($0.rounded()) } }
        guard int("total") != nil || int("calls") != nil || int("context_max") != nil else { return nil }
        input = int("input") ?? 0
        output = int("output") ?? 0
        total = int("total") ?? 0
        calls = int("calls") ?? 0
        reasoning = int("reasoning")
        contextUsed = int("context_used")
        contextMax = int("context_max").flatMap { $0 > 0 ? $0 : nil }
        contextPercent = int("context_percent")
        contextEstimated = value["context_estimated"]?.boolValue ?? false
        compressions = int("compressions")
        cacheHitPercent = int("cache_hit_pct")
        tokensPerSecond = value["avg_tps"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
        costUSD = value["cost_usd"]?.doubleValue
        model = value["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `newer`, keeping this one's context occupancy when `newer` has none: a resumed
    /// runtime reports none until its first turn, which must not blank the gauge
    /// (Desktop merges its usage store the same way).
    func merged(with newer: SessionUsage) -> SessionUsage {
        var next = newer
        if next.contextMax == nil {
            next.contextUsed = contextUsed
            next.contextMax = contextMax
            next.contextPercent = contextPercent
            next.contextEstimated = contextEstimated
        }
        return next
    }
}

/// What fills a session's context (`session.context_breakdown`,
/// `tui_gateway/methods_session.py:1459-1490`, `agent/context_breakdown.py:143`): the
/// system prompt, tools, memory, skills and messages, estimated from the live runtime
/// at about four characters a token. It answers for a chat no turn has measured yet.
public struct ContextBreakdown: Sendable, Hashable {
    public struct Category: Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var tokens: Int
    }

    public var categories: [Category]
    public var contextUsed: Int
    public var contextMax: Int
    public var contextPercent: Int
    public var contextEstimated: Bool
    public var model: String?

    /// Nil for a zeroed answer (a runtime without an agent sends `context_max: 0`), which
    /// isn't data (Desktop's `isZeroedBreakdown`).
    public init?(_ value: JSONValue?) {
        guard let value, let max = value["context_max"]?.doubleValue, max > 0 else { return nil }
        contextMax = Int(max)
        contextUsed = Int(value["context_used"]?.doubleValue ?? 0)
        contextPercent = Int((value["context_percent"]?.doubleValue ?? 0).rounded())
        contextEstimated = value["context_estimated"]?.boolValue ?? true
        model = value["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        categories = (value["categories"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["id"]?.stringValue, let tokens = row["tokens"]?.doubleValue, tokens > 0 else { return nil }
            return Category(id: id, label: row["label"]?.stringValue ?? id, tokens: Int(tokens))
        }
    }
}

/// How full the chat's context is, as the composer's gauge shows it.
public struct ContextGauge: Sendable, Hashable {
    public var used: Int
    public var max: Int
    /// 0…100.
    public var percent: Int
    public var isEstimated: Bool

    public var fraction: Double { Swift.min(1, Swift.max(0, Double(percent) / 100)) }
}

extension ChatSession {
    /// The gauge's numbers. While a turn runs, or with no breakdown read, the usage the
    /// gateway streams; otherwise the breakdown, which reports the measured occupancy once
    /// there is one and an estimate before (Desktop's `gaugeUsage`).
    public var contextGauge: ContextGauge? {
        if !transcript.isRunning, let breakdown = contextBreakdown {
            return ContextGauge(used: breakdown.contextUsed, max: breakdown.contextMax,
                                percent: Swift.min(100, Swift.max(0, breakdown.contextPercent)),
                                isEstimated: breakdown.contextEstimated)
        }
        guard let usage, let max = usage.contextMax else { return nil }
        let used = usage.contextUsed ?? 0
        let percent = usage.contextPercent ?? Int((Double(used) / Double(max) * 100).rounded())
        return ContextGauge(used: used, max: max, percent: Swift.min(100, Swift.max(0, percent)),
                            isEstimated: usage.contextEstimated)
    }

    /// Reads the session's usage and context breakdown again (`session.usage`,
    /// `session.context_breakdown`): when the chat shows, after a turn, after a compression.
    /// The breakdown is skipped while a turn runs (its snapshot predates the turn). A
    /// failure (an older gateway, a reclaimed runtime) keeps what was read before.
    public func refreshUsage() async {
        guard !isRuntimeGone, let client = connection?.client else { return }
        let id = sessionID
        let params: JSONValue = ["session_id": .string(id)]
        if let answer = try? await client.call(GatewayMethod.sessionUsage, params: params),
           id == sessionID, let read = SessionUsage(answer) {
            takeUsage(read)
        }
        guard !transcript.isRunning,
              let answer = try? await client.call(GatewayMethod.sessionContextBreakdown, params: params),
              id == sessionID else { return }
        if let breakdown = ContextBreakdown(answer) {
            if breakdown != contextBreakdown { contextBreakdown = breakdown }
        } else {
            contextBreakdown = nil
        }
    }
}
