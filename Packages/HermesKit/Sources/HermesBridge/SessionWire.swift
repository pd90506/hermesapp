import Foundation
import HermesKit
import HermesProtocol

/// The chat's state the desktop app draws outside the transcript: the pending request
/// cards (approval, clarify, sudo, secret), the subagents pill, the context gauge, and
/// the session search's results. The cron tab is connection state (`CronWire`).
/// See docs/desktop-bridge.md, "Requests", "Subagents", "Usage" and "Search".
enum SessionWire {}

// MARK: - Pending requests

extension SessionWire {
    /// A blocking server→client request (`transcript.pendingRequests`), as the Mac's
    /// `RequestCardView` draws it. The agent waits until it is answered or times out.
    struct Request: Encodable, Sendable, Equatable {
        struct Choice: Encodable, Sendable, Equatable {
            /// `once`, `session`, `always` or `deny`.
            var value: String
            var label: String
        }

        struct Question: Encodable, Sendable, Equatable {
            var qid: String
            var question: String
            /// The choices to offer, blanks and over-long ones dropped.
            var choices: [String]
            /// Offered as checkboxes with an optional typed answer.
            var multiSelect: Bool
            /// An answer was locked via `clarify.lock` (a replayed request): the question
            /// shows it and takes no input.
            var isLocked: Bool
        }

        var id: String
        /// `approval`, `clarify`, `sudo`, `secret` or `unsupported`.
        var kind: String
        var method: String
        /// The card's heading line ("Approval needed", "Hermes has a question", …).
        var headline: String
        var description: String?
        /// The command an approval asks about, a sudo request's command.
        var command: String?
        /// An approval's buttons, in order.
        var choices: [Choice]?
        /// A clarify's questions, in order.
        var questions: [Question]?
        /// A secret request's variable, and its own prompt line.
        var envVar: String?
        var prompt: String?

        init(_ request: ServerRequest) {
            id = request.id
            method = request.method
            switch request.kind {
            case .approval(let approval):
                kind = "approval"
                headline = "Approval needed"
                description = approval.description
                command = approval.command
                choices = approval.offeredChoices.map {
                    Choice(value: $0.rawValue, label: Self.label($0))
                }
            case .clarify(let clarify):
                kind = "clarify"
                headline = clarify.questions.count > 1
                    ? "Hermes has \(clarify.questions.count) questions" : "Hermes has a question"
                questions = clarify.questions.map { question in
                    Question(qid: question.qid, question: question.question,
                             choices: question.offeredChoices, multiSelect: question.allowsMultipleChoices,
                             isLocked: clarify.lockedSelection(for: question) != nil)
                }
            case .sudo(let sudo):
                kind = "sudo"
                headline = "Sudo password requested"
                command = sudo.command
            case .secret(let secret):
                kind = "secret"
                headline = secret.prompt
                envVar = secret.envVar
                prompt = secret.prompt
            case .unsupported:
                kind = "unsupported"
                headline = "Unsupported request"
            }
        }

        /// The Mac's button titles (`RequestCardView.title(for:)`).
        static func label(_ choice: ApprovalChoice) -> String {
            switch choice {
            case .once: "Allow Once"
            case .session: "Allow for Session"
            case .always: "Always Allow"
            case .deny: "Deny"
            }
        }
    }
}

// MARK: - Subagents

extension SessionWire {
    /// The chat's running subagents (`ChatSession.subagents.live`), as the Mac's
    /// `SubagentsPill` lists them above the composer. Live rows only: a finished child
    /// keeps its row on the Mac only until the next prompt, and the pill is gone
    /// entirely once no child runs.
    struct SubagentsSnapshot: Encodable, Sendable, Equatable {
        struct Activity: Encodable, Sendable, Equatable {
            /// `tool`, `progress`, `thinking` or `summary`.
            var kind: String
            var text: String
            var isError: Bool

            init(_ activity: SubagentRun.Activity) {
                kind = switch activity.kind {
                case .tool: "tool"
                case .progress: "progress"
                case .thinking: "thinking"
                case .summary: "summary"
                }
                text = activity.text
                isError = activity.isError
            }
        }

        struct Run: Encodable, Sendable, Equatable {
            var id: String
            var goal: String
            var model: String?
            /// `queued` or `running` (a live row).
            var status: String
            var taskIndex: Int
            var taskCount: Int
            /// Unix seconds.
            var startedAt: Double
            var updatedAt: Double
            /// The tool it is running, while it runs.
            var currentTool: String?
            /// The newest lines, oldest first (`SubagentRoster.activityLimit`).
            var activity: [Activity]
            var summary: String?
            var childSessionID: String?

            init(_ run: SubagentRun) {
                id = run.id
                goal = run.goal
                model = run.model
                status = run.status.rawValue
                taskIndex = run.taskIndex
                taskCount = run.taskCount
                startedAt = run.startedAt.timeIntervalSince1970
                updatedAt = run.updatedAt.timeIntervalSince1970
                currentTool = run.currentTool
                activity = run.activity.map(Activity.init)
                summary = run.summary
                childSessionID = run.childSessionID
            }
        }

        var sessionID: String
        var runs: [Run]

        @MainActor init(_ chat: ChatSession) {
            sessionID = chat.sessionID
            runs = chat.subagents.live.map(Run.init)
        }
    }
}

// MARK: - Context usage

extension SessionWire {
    /// How full the chat's context is and the session's counters, as the Mac's
    /// `ContextGaugeButton` shows them (`ChatSession.contextGauge`, `usage`,
    /// `contextBreakdown`). The gauge is nil until the gateway reports any use.
    struct UsageSnapshot: Encodable, Sendable, Equatable {
        struct Gauge: Encodable, Sendable, Equatable {
            var used: Int
            var max: Int
            /// 0…100.
            var percent: Int
            /// The occupancy is an estimate, not the provider's count.
            var isEstimated: Bool

            init(_ gauge: ContextGauge) {
                used = gauge.used
                max = gauge.max
                percent = gauge.percent
                isEstimated = gauge.isEstimated
            }
        }

        struct Usage: Encodable, Sendable, Equatable {
            var input: Int
            var output: Int
            var total: Int
            var calls: Int
            var reasoning: Int?
            var compressions: Int?
            /// The prompt cache's hit rate, 0…100; absent before any cache read.
            var cacheHitPercent: Int?
            /// Output tokens per second over the last calls.
            var tokensPerSecond: Double?
            var costUSD: Double?
            var model: String?

            init(_ usage: SessionUsage) {
                input = usage.input
                output = usage.output
                total = usage.total
                calls = usage.calls
                reasoning = usage.reasoning
                compressions = usage.compressions
                cacheHitPercent = usage.cacheHitPercent
                tokensPerSecond = usage.tokensPerSecond
                costUSD = usage.costUSD
                model = usage.model
            }
        }

        struct Breakdown: Encodable, Sendable, Equatable {
            struct Category: Encodable, Sendable, Equatable {
                var id: String
                var label: String
                var tokens: Int
            }

            var contextUsed: Int
            var contextMax: Int
            var contextPercent: Int
            var isEstimated: Bool
            var categories: [Category]

            init(_ breakdown: ContextBreakdown) {
                contextUsed = breakdown.contextUsed
                contextMax = breakdown.contextMax
                contextPercent = breakdown.contextPercent
                isEstimated = breakdown.contextEstimated
                categories = breakdown.categories.map {
                    Category(id: $0.id, label: $0.label, tokens: $0.tokens)
                }
            }
        }

        var sessionID: String
        var gauge: Gauge?
        var usage: Usage?
        var breakdown: Breakdown?

        @MainActor init(_ chat: ChatSession) {
            sessionID = chat.sessionID
            gauge = chat.contextGauge.map(Gauge.init)
            usage = chat.usage.map(Usage.init)
            breakdown = chat.contextBreakdown.map(Breakdown.init)
        }
    }
}

// MARK: - Session search

extension SessionWire {
    /// The session list's search (`GatewayConnection.search`): the profile's chats whose
    /// messages, title or id match, best first, as the Mac's `SessionSearchResultsList`
    /// shows them. A row opens as the list's row does (its Bot Chat as the Bot Chat).
    struct SearchSnapshot: Encodable, Sendable, Equatable {
        struct Result: Encodable, Sendable, Equatable {
            /// `profile/storedID`, what `openSession` takes.
            var id: String
            var profile: String
            var storedID: String
            /// The Mac's `SessionSearchRow.title`: the Bot Chat's own, else the row's.
            var title: String
            var preview: String?
            /// The matched text in order, matched runs marked (`snippetSegments`); the
            /// `>>>`/`<<<` markers never show.
            var segments: [Segment]
            /// Whose message matched (`user`, `assistant`, …); nil for id and title matches.
            var role: String?
            /// Unix seconds, when the chat was last active else started.
            var date: Double?
            var messageCount: Int?
            /// The hit's row is the profile's Bot Chat, which opens as the Bot Chat.
            var isBotChat: Bool

            init(_ result: SessionSearchResult) {
                id = result.entry.id
                profile = result.entry.profile
                storedID = result.entry.summary.id
                title = result.isBotChat ? Bot.chatTitle
                    : (result.entry.summary.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat")
                preview = result.hit.preview
                segments = result.hit.snippetSegments.map { Segment(text: $0.text, isMatch: $0.isMatch) }
                role = result.hit.role
                date = result.hit.date?.timeIntervalSince1970
                messageCount = result.hit.messageCount
                isBotChat = result.isBotChat
            }
        }

        struct Segment: Encodable, Sendable, Equatable {
            var text: String
            var isMatch: Bool
        }

        /// The profile the results are for; nil when the connection lists none.
        var profile: String?
        /// The query the results answer, trimmed; empty when nothing was searched.
        var query: String
        var results: [Result]
        var isSearching: Bool
        var error: String?
        /// False when the connection has no REST access, so nothing can be searched.
        var isAvailable: Bool

        @MainActor init(_ connection: GatewayConnection) {
            let search = connection.search
            profile = connection.listProfile
            query = search.query
            results = search.results.map(Result.init)
            isSearching = search.isSearching
            error = search.error
            isAvailable = search.isAvailable
        }
    }
}

// MARK: - Cron jobs

extension SessionWire {
    /// The list profile's scheduled jobs, as the sidebar's Cron tab shows them
    /// (`GatewayConnection.cron`), with each expanded job's recent runs and the
    /// server's delivery targets.
    struct CronSnapshot: Encodable, Sendable, Equatable {
        struct Job: Encodable, Sendable, Equatable {
            var id: String
            /// The Mac's `CronJobRow.title`: the name, else the start of the prompt or
            /// script, else the id.
            var title: String
            var name: String?
            var prompt: String?
            var script: String?
            /// A script that runs without an agent: no prompt, no model to pick.
            var isScriptOnly: Bool
            /// The stated state, else one from `enabled` (`effectiveState`).
            var state: String
            /// Unix seconds; nil when the job is not waiting to fire.
            var nextRunAt: Double?
            var lastRunAt: Double?
            var lastStatus: String?
            var lastError: String?
            var lastDeliveryError: String?
            var pausedReason: String?
            /// The human line ("Every day at 9:00 AM").
            var scheduleDisplay: String?
            /// The raw expression, for the editor.
            var scheduleExpression: String?
            var model: String?
            var provider: String?
            /// The targets the job delivers to, `local` when it names none.
            var deliver: [String]
            /// Unix seconds when the next run passed more than 15 minutes ago: a
            /// scheduler that stopped ticking (`overdueSince`).
            var overdueSince: Double?
            /// The job's last run failed or wasn't delivered (`needsAttention`).
            var needsAttention: Bool

            init(_ job: CronJob, now: Date) {
                id = job.id
                title = job.title
                name = job.name
                prompt = job.prompt
                script = job.script
                isScriptOnly = job.isScriptOnly
                state = job.effectiveState
                nextRunAt = job.nextRunAt?.timeIntervalSince1970
                lastRunAt = job.lastRunAt?.timeIntervalSince1970
                lastStatus = job.lastStatus
                lastError = job.lastError
                lastDeliveryError = job.lastDeliveryError
                pausedReason = job.pausedReason
                scheduleDisplay = job.scheduleDisplay
                scheduleExpression = job.scheduleExpression
                model = job.model
                provider = job.provider
                deliver = job.deliveryTargets
                overdueSince = job.overdueSince(now: now)?.timeIntervalSince1970
                needsAttention = ["error", "blocked_config", "delivery_failed"].contains(job.lastStatus ?? "")
            }
        }

        struct Run: Encodable, Sendable, Equatable {
            var id: String
            var title: String?
            /// A script run's output; an agent run's preview is the scheduler's own
            /// instructions, so the row shows only the time (the Mac's `CronRunRow`).
            var preview: String?
            /// Unix seconds: when the run was last active, else when it started.
            var startedAt: Double?
            var lastActive: Double?
            var endedAt: Double?
            var messageCount: Int?
            /// `cron_output`: the run's output document, not a session.
            var isOutputDocument: Bool
            /// What `openCronRun` takes, for a run that is a session.
            var entryID: String?

            init(_ run: CronRun, profile: String?) {
                id = run.id
                title = run.title
                preview = run.preview
                startedAt = run.startedAt
                lastActive = run.lastActive
                endedAt = run.endedAt
                messageCount = run.messageCount
                isOutputDocument = run.isOutputDocument
                entryID = run.isOutputDocument ? nil : run.historyEntry(profile: profile ?? "").id
            }
        }

        struct Target: Encodable, Sendable, Equatable {
            var id: String
            var name: String
            /// A platform without a cron home channel is listed with false.
            var homeTargetSet: Bool
        }

        struct Blueprint: Encodable, Sendable, Equatable {
            struct Field: Encodable, Sendable, Equatable {
                /// `text`, `time`, `weekdays` or `enum`; an unknown kind filled in as text.
                var kind: String
                var name: String
                var label: String
                var defaultValue: String?
                var options: [String]
                var isOptional: Bool
                var help: String
                /// The deliver blank, offered as delivery toggles, not its options.
                var isDeliver: Bool
            }

            var key: String
            var title: String
            var description: String
            var fields: [Field]

            init(_ blueprint: CronBlueprint) {
                key = blueprint.key
                title = blueprint.title
                description = blueprint.description
                fields = blueprint.fields.map {
                    Field(kind: $0.kind.rawValue, name: $0.name, label: $0.label, defaultValue: $0.defaultValue,
                          options: $0.options, isOptional: $0.isOptional, help: $0.help, isDeliver: $0.isDeliver)
                }
            }
        }

        /// The profile whose jobs `jobs` holds; nil until the first read comes back.
        var profile: String?
        var isLoading: Bool
        var error: String?
        var isAvailable: Bool
        var jobs: [Job]
        /// Recent runs by job id, newest first, for the jobs whose runs were read.
        var runs: [String: [Run]]
        var runErrors: [String: String]
        var targets: [Target]
        /// Jobs being run now from the app.
        var triggering: [String]
        /// The ready-made jobs the profile can start from, once read.
        var blueprints: [Blueprint]

        @MainActor init(_ connection: GatewayConnection, now: Date = .now) {
            let cron = connection.cron
            profile = cron.profile
            isLoading = cron.isLoading
            error = cron.error
            isAvailable = cron.isAvailable
            jobs = cron.jobs.map { Job($0, now: now) }
            runs = cron.runs.mapValues { $0.map { Run($0, profile: cron.profile) } }
            runErrors = cron.runErrors
            targets = cron.targets.map { Target(id: $0.id, name: $0.name, homeTargetSet: $0.homeTargetSet) }
            triggering = cron.triggering.sorted()
            blueprints = cron.blueprints.map(Blueprint.init)
        }
    }
}
