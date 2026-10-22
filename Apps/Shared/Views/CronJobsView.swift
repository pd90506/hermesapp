import HermesKit
import HermesProtocol
import SwiftUI

/// The tabs at the bottom of the session list: the profile's sessions, or its scheduled
/// jobs (asked for by the user, 2026-10-19).
enum SessionListTab: String, CaseIterable {
    case sessions, cron

    var title: String {
        switch self {
        case .sessions: "Sessions"
        case .cron: "Cron Jobs"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: "bubble.left.and.bubble.right"
        case .cron: "clock"
        }
    }
}

#if os(macOS)
/// The two tabs on the Mac, side by side, a symbol beside each label, on a capsule of
/// clear Liquid Glass floating over the list's bottom: the glass of the window's other
/// buttons, the rail's Settings beside it and the toolbar's, and as tall (asked for by
/// the user, 2026-10-22). The picked tab is in the accent on a grey pill, as a segmented
/// control's in a toolbar, which slides to the other tab. The rows scroll under it.
/// macOS has no tab bar of the system's (its tab view is a segmented control over a box);
/// on iOS the tabs are the system's tab bar.
struct SessionListTabBar: View {
    @Binding var tab: SessionListTab
    /// Jobs whose last run failed, shown on the Cron Jobs tab.
    var cronAlerts = 0
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the capsule floats in from the list's edges.
    static let inset = Hover.rowInset
    /// The rail's Settings button's height (`ProfileRailView`).
    private static let height: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SessionListTab.allCases, id: \.self) { item in
                Button {
                    withAnimation(reduceMotion ? nil : Motion.swap) { tab = item }
                } label: {
                    HStack(spacing: 5) {
                        // Room for the symbol and the title in either look, picked or not:
                        // the filled symbol and the semibold title are a little bigger, and
                        // the bar grew and shrank by a hair at each switch.
                        ZStack {
                            Image(systemName: item.systemImage).symbolVariant(.fill).hidden()
                            Image(systemName: item.systemImage).symbolVariant(.none).hidden()
                            Image(systemName: item.systemImage)
                                .symbolVariant(tab == item ? .fill : .none)
                        }
                        .overlay(alignment: .topTrailing) {
                            if item == .cron && cronAlerts > 0 {
                                Circle().fill(.red).frame(width: 7, height: 7).offset(x: 4, y: -2)
                            }
                        }
                        ZStack {
                            Text(item.title).uiFont(.callout, weight: .semibold).hidden()
                            Text(item.title).uiFont(.callout).hidden()
                            Text(item.title)
                                .uiFont(.callout, weight: tab == item ? .semibold : nil)
                        }
                    }
                    .uiFont(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if tab == item {
                            Capsule()
                                .fill(.primary.opacity(0.1))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab == item ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .hoverHighlight(in: Capsule(), isEnabled: tab != item)
                .accessibilityIdentifier("sessionListTab.\(item.rawValue)")
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, Self.inset)
        .padding(.top, 6)
        .padding(.bottom, Self.bottomPadding)
    }

    /// Off the window's bottom.
    private static let bottomPadding = Hover.rowInset
}
#endif

/// The selected profile's scheduled jobs (the Cron Jobs tab): Desktop's sidebar Cron
/// section as a list (`apps/desktop/src/app/chat/sidebar/cron-jobs-section.tsx`). A
/// job's row shows its schedule, where it delivers and when it runs next; a tap shows
/// its recent runs under it, and a run opens as a chat. Run now, Pause or Resume,
/// Deliver to and Delete are in its context menu and its "…" button.
struct CronJobsList: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    var showChat: () -> Void = {}
    /// The job whose runs show under it: one at a time, as in Desktop.
    @State private var expanded: String?
    @State private var deleting: CronJob?
    /// The time the rows count from ("in 2 hours"), moved on with each re-read.
    @State private var now = Date()

    var body: some View {
        List(selection: $selection) {
            if let server = model.sessionsServer {
                Section {
                    content(server)
                } header: {
                    SidebarSectionTitle("Cron Jobs")
                }
                .themedRows()
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The job is removed from Hermes and won't run again.")
        }
        .task(id: refreshKey) {
            // While the tab shows: the jobs and the open job's runs, as often as the
            // session list's previews (Desktop's peek polls every 8 s).
            guard let server = model.sessionsServer, server.isConnected else { return }
            while !Task.isCancelled {
                await server.connection.refreshCronJobs()
                await server.connection.loadCronDeliveryTargets()
                now = Date()
                if let job = server.connection.cron.jobs.first(where: { $0.id == expanded }) {
                    await server.connection.refreshCronRuns(job)
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    @ViewBuilder private func content(_ server: ServerConnection) -> some View {
        let connection = server.connection
        let cron = connection.cron
        let isCurrent = cron.profile != nil && cron.profile == connection.listProfile
        if !server.isConnected {
            Text("Connect to see scheduled jobs").foregroundStyle(.secondary)
        } else if !cron.isAvailable {
            Text("This connection can't read scheduled jobs.").foregroundStyle(.secondary)
        } else if !isCurrent || (cron.isLoading && cron.jobs.isEmpty) {
            ProgressView("Loading jobs…")
        } else {
            if let error = cron.error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await connection.refreshCronJobs() } }
                    .hoverButtonStyle(padding: 4)
                    .foregroundStyle(.tint)
            }
            if cron.jobs.isEmpty && cron.error == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No cron jobs")
                    Text("Ask Hermes in a chat to schedule one, such as “every morning at 9, summarize the news”.")
                        .uiFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(cron.jobs) { job in
                jobRow(job, on: server, now: now)
                if expanded == job.id {
                    runRows(job, on: server)
                }
            }
        }
    }

    private func jobRow(_ job: CronJob, on server: ServerConnection, now: Date) -> some View {
        let cron = server.connection.cron
        // Not a Button: its "…" menu would be a button inside one, which on iOS took the
        // outer button's tap.
        return CronJobRow(job: job, isExpanded: expanded == job.id, isRunning: cron.triggering.contains(job.id),
                          targets: cron.targets, now: now, toggle: { toggle(job, on: server) }) {
            actions(job, on: server)
        }
        .sidebarRowHighlight(isSelected: false)
    }

    /// The job's recent runs, newest first, set in under it. A run with a session opens
    /// it as a chat; a script-only run shows the start of its output.
    @ViewBuilder private func runRows(_ job: CronJob, on server: ServerConnection) -> some View {
        let cron = server.connection.cron
        if let runs = cron.runs[job.id] {
            if runs.isEmpty {
                Text(cron.runErrors[job.id] ?? "No runs yet")
                    .uiFont(.caption)
                    .foregroundStyle(cron.runErrors[job.id] == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .padding(.leading, CronRunRow.indent)
            }
            ForEach(runs) { run in
                if run.isOutputDocument {
                    CronRunRow(run: run)
                        .padding(.leading, CronRunRow.indent)
                } else {
                    let item = SidebarItem.cronRun(server: server.id, profile: run.profile ?? cron.profile ?? "",
                                                   id: run.id)
                    CronRunRow(run: run)
                        .padding(.leading, CronRunRow.indent)
                        .sidebarRowHighlight(isSelected: selection == item)
                        .tag(item)
                        .accessibilityIdentifier("cronRun.\(run.id)")
                }
            }
        } else if let error = cron.runErrors[job.id] {
            Text(error)
                .uiFont(.caption)
                .foregroundStyle(.red)
                .padding(.leading, CronRunRow.indent)
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.leading, CronRunRow.indent)
        }
    }

    @ViewBuilder private func actions(_ job: CronJob, on server: ServerConnection) -> some View {
        let connection = server.connection
        let canChange = server.isConnected
        Button("Run Now", systemImage: "bolt") {
            expanded = job.id
            perform(on: server) { try await connection.triggerCronJob(job) }
        }
        .disabled(!canChange || connection.cron.triggering.contains(job.id))
        if job.isPaused {
            Button("Resume", systemImage: "play") { perform(on: server) { try await connection.resumeCronJob(job) } }
                .disabled(!canChange)
        } else {
            Button("Pause", systemImage: "pause") { perform(on: server) { try await connection.pauseCronJob(job) } }
                .disabled(!canChange)
        }
        Menu("Deliver To", systemImage: "paperplane") {
            ForEach(CronDeliveryTarget.options(server: connection.cron.targets, job: job)) { target in
                Toggle(isOn: Binding(
                    get: { job.deliveryTargets.contains(target.id) },
                    set: { on in
                        let deliver = job.deliver(toggling: target.id, on: on)
                        guard deliver != job.deliver else { return }
                        perform(on: server) { try await connection.setCronDelivery(job, to: deliver) }
                    })) {
                    Text(target.homeTargetSet ? target.name : "\(target.name) (no home channel)")
                }
            }
        }
        .disabled(!canChange)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = job }
            .disabled(!canChange)
    }

    private func toggle(_ job: CronJob, on server: ServerConnection) {
        if expanded == job.id {
            expanded = nil
            return
        }
        expanded = job.id
        Task { await server.connection.refreshCronRuns(job) }
    }

    private func perform(on server: ServerConnection, _ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                model.actionError = nil
            } catch {
                model.actionError = model.describe(error, on: server)
            }
        }
    }

    private func commitDelete() {
        guard let job = deleting, let server = model.sessionsServer else { return }
        deleting = nil
        if expanded == job.id { expanded = nil }
        perform(on: server) { try await server.connection.deleteCronJob(job) }
    }

    private var deleteQuestion: String {
        "Delete “\(deleting?.title ?? "this job")”?"
    }

    /// Re-reads when the server, profile or connection changes.
    private var refreshKey: String {
        guard let server = model.sessionsServer else { return "" }
        return "\(server.id):\(server.connection.listProfile ?? ""):\(server.isConnected)"
    }
}

/// A job: a state dot, its title, and when it runs next (or why it won't); under them
/// its schedule and where it delivers, and the last run's error, if it failed.
struct CronJobRow<Actions: View>: View {
    let job: CronJob
    let isExpanded: Bool
    let isRunning: Bool
    let targets: [CronDeliveryTarget]
    let now: Date
    /// Shows or hides the job's runs.
    let toggle: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: toggle)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("cronJob.\(job.id)")
                .accessibilityHint(isExpanded ? "Hides its runs" : "Shows its runs")
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .uiFont(.body, weight: .semibold)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("More")
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("cronJobMenu.\(job.id)")
        }
        .padding(.vertical, 2)
        .contextMenu { actions() }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .uiFont(.caption2, weight: .semibold)
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .accessibilityHidden(true)
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    meta
                        .uiFont(.caption2)
                        .foregroundStyle(job.overdueSince(now: now) != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Text(details)
                    .uiFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let problem {
                    Text(problem)
                        .uiFont(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    /// When it runs next, or its state when it isn't waiting to.
    @ViewBuilder private var meta: some View {
        if isRunning || job.isRunning {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Running")
            }
        } else if job.isInactive {
            Text(job.effectiveState.capitalized)
        } else if let overdue = job.overdueSince(now: now) {
            Text("Overdue since \(overdue.formatted(date: .omitted, time: .shortened))")
        } else if let next = job.nextRunAt {
            Text(next, format: .relative(presentation: .named))
        }
    }

    private var details: String {
        let delivery = job.deliveryTargets.map { CronDeliveryTarget.label($0, server: targets) }.joined(separator: ", ")
        return [job.scheduleDisplay, "→ \(delivery)"].compactMap { $0 }.joined(separator: "  ")
    }

    /// The last run's failure, as the scheduler recorded it.
    private var problem: String? {
        switch job.lastStatus {
        case "error", "blocked_config": job.lastError.map { "Last run failed: \($0)" } ?? "Last run failed"
        case "delivery_failed": job.lastDeliveryError.map { "Not delivered: \($0)" } ?? "Not delivered"
        default: nil
        }
    }

    private var dotColor: Color {
        switch job.effectiveState {
        case "paused": .orange
        case "error": .red
        case "completed", "disabled": .gray
        default: .accentColor
        }
    }
}

/// A run: when it ran. A script-only run also shows the start of its output; an agent
/// run's preview is the scheduler's own instructions, so it shows only the time, as in
/// Desktop (`cron-jobs-section.tsx:490-520`).
struct CronRunRow: View {
    /// Where a run's row starts: under its job's title, past the chevron and the dot.
    static var indent: CGFloat { 29 }

    let run: CronRun

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(run.time.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                .uiFont(.caption)
                .foregroundStyle(run.isOutputDocument ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.vertical, run.isOutputDocument ? 0 : 3)
            if run.isOutputDocument, let preview = run.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
                !preview.isEmpty {
                Text(preview)
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension CronJob {
    /// Jobs whose last run failed or wasn't delivered.
    var needsAttention: Bool {
        ["error", "blocked_config", "delivery_failed"].contains(lastStatus ?? "")
    }
}
