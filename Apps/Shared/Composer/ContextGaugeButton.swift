import HermesKit
import SwiftUI

/// How full the chat's context is (`ChatSession.contextGauge`), in the composer's toolbar
/// as Desktop's status bar shows it: a ring filling with the context used (on the Mac
/// with its percentage), which opens the details: what fills the context and the
/// session's tokens, calls, cache hits and speed. Hidden until the gateway reports any.
///
/// Its numbers are read again when the chat shows, when a turn ends and after a
/// compression (`ChatSession.refreshUsage`); a running turn streams its own.
struct ContextGaugeButton: View {
    let composer: ChatComposer
    @State private var isShowingDetails = false

    private var session: ChatSession { composer.session }

    var body: some View {
        let gauge = session.contextGauge
        Group {
            if gauge != nil || session.usage != nil {
                Button { isShowingDetails.toggle() } label: { label(gauge) }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .help(gauge.map { "Context: \(ContextGaugeText.summary($0))" } ?? "Token use")
                    .accessibilityLabel("Context")
                    .accessibilityValue(gauge.map(ContextGaugeText.summary) ?? "")
                    .accessibilityIdentifier("contextGauge")
                    .popover(isPresented: $isShowingDetails, arrowEdge: .top) {
                        ContextUsageDetails(gauge: gauge, breakdown: session.contextBreakdown, usage: session.usage)
                            .presentationCompactAdaptation(.popover)
                    }
            }
        }
        .task(id: RefreshKey(sessionID: session.sessionID, isRunning: session.transcript.isRunning,
                             isCompressing: composer.isCompressing)) {
            guard !session.transcript.isRunning, !composer.isCompressing else { return }
            await session.refreshUsage()
        }
    }

    private struct RefreshKey: Hashable {
        var sessionID: String
        var isRunning: Bool
        var isCompressing: Bool
    }

    private func label(_ gauge: ContextGauge?) -> some View {
        HStack(spacing: 4) {
            ContextRing(fraction: gauge?.fraction ?? 0)
                .frame(width: 14, height: 14)
            #if os(macOS)
            if let gauge {
                Text("\(gauge.isEstimated ? "~" : "")\(gauge.percent)%")
                    .monospacedDigit()
                    .uiFont(.caption)
            }
            #endif
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 30)
        .contentShape(.rect)
    }
}

/// A ring that fills clockwise from the top; orange past 80 %, red past 95 %, as the
/// context nears the point Hermes compresses it.
struct ContextRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.35), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1)
        .animation(.default, value: fraction)
    }

    private var tint: Color {
        if fraction > 0.95 { return .red }
        if fraction > 0.8 { return .orange }
        return .accentColor
    }
}

enum ContextGaugeText {
    /// "30K of 200K tokens (15%)", "~" before an estimate.
    static func summary(_ gauge: ContextGauge) -> String {
        "\(gauge.isEstimated ? "~" : "")\(tokens(gauge.used)) of \(tokens(gauge.max)) tokens (\(gauge.percent)%)"
    }

    /// 950, 12.8K, 1.2M.
    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}

/// The gauge's popover: the context, what fills it, then the session's counters.
struct ContextUsageDetails: View {
    let gauge: ContextGauge?
    let breakdown: ContextBreakdown?
    let usage: SessionUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let gauge {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Context").font(.headline)
                    ProgressView(value: gauge.fraction)
                        .tint(gauge.fraction > 0.8 ? .orange : .accentColor)
                    Text(ContextGaugeText.summary(gauge))
                        .font(.callout)
                        .monospacedDigit()
                    if gauge.isEstimated {
                        Text("Estimated until a reply measures it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let breakdown, !breakdown.categories.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(breakdown.categories) { category in
                        row(category.label, ContextGaugeText.tokens(category.tokens))
                    }
                }
                .font(.callout)
            }
            if let usage {
                if gauge != nil { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    Text("This Session").font(.headline).padding(.bottom, 2)
                    row("Tokens", "\(ContextGaugeText.tokens(usage.total)) (\(ContextGaugeText.tokens(usage.input)) in · \(ContextGaugeText.tokens(usage.output)) out)")
                    row("Model calls", usage.calls.formatted())
                    if let hits = usage.cacheHitPercent { row("Cache hits", "\(hits)%") }
                    if let speed = usage.tokensPerSecond { row("Speed", "\(Int(speed.rounded())) tokens/s") }
                    if let compressions = usage.compressions, compressions > 0 {
                        row("Compressions", compressions.formatted())
                    }
                    if let cost = usage.costUSD, cost > 0 {
                        row("Cost", cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                    }
                }
                .font(.callout)
            }
        }
        .padding(16)
        .frame(minWidth: 260, alignment: .leading)
        .accessibilityIdentifier("contextDetails")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).monospacedDigit()
        }
    }
}
