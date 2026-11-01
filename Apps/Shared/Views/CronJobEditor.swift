import HermesKit
import HermesProtocol
import SwiftUI

/// What the job editor is open for.
enum CronEditorTarget: Identifiable {
    case new
    case edit(CronJob)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let job): job.id
        }
    }
}

/// New and Edit Cron Job: Desktop's `CronEditorDialog` (`apps/desktop/src/app/cron/index.tsx`)
/// as a sheet with a grouped form. A new job can start from one of the server's blueprints,
/// whose blanks replace the form. The presets' time, weekday and day of the month can be
/// picked, where Desktop fixes them at 9:00 on Mondays and the 1st.
struct CronJobEditor: View {
    let target: CronEditorTarget
    let server: ServerConnection
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CronJobDraft
    /// The blueprint started from; `nil` is the form itself.
    @State private var blueprintKey: String?
    @State private var blueprintValues: [String: String] = [:]
    @State private var catalog: ModelCatalog?
    @State private var isSaving = false
    @State private var error: String?

    init(target: CronEditorTarget, server: ServerConnection) {
        self.target = target
        self.server = server
        switch target {
        case .new: _draft = State(initialValue: CronJobDraft())
        case .edit(let job): _draft = State(initialValue: CronJobDraft(job))
        }
    }

    private var cron: CronBoard { server.connection.cron }
    private var isNew: Bool { if case .new = target { true } else { false } }
    private var blueprint: CronBlueprint? { cron.blueprints.first { $0.key == blueprintKey } }

    var body: some View {
        NavigationStack {
            ThemedForm {
                if isNew && !cron.blueprints.isEmpty { startFrom }
                if let blueprint {
                    blueprintFields(blueprint)
                } else {
                    jobFields
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("cronEditorError")
                    }
                }
            }
            .navigationTitle(isNew ? "New Cron Job" : "Edit Cron Job")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(isNew ? "Create" : "Save", action: save)
                            .accessibilityIdentifier("cronEditorSave")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 540, minHeight: 560, idealHeight: 620)
        #endif
        .interactiveDismissDisabled(isSaving)
        .task {
            await server.connection.loadCronBlueprints()
            await server.connection.loadCronDeliveryTargets()
            if !draft.isScriptOnly { catalog = try? await server.connection.cronModelCatalog() }
        }
    }

    // MARK: The form

    private var startFrom: some View {
        Section {
            Picker("Start From", selection: Binding(get: { blueprintKey }, set: { pick($0) })) {
                Text("Custom").tag(String?.none)
                ForEach(cron.blueprints) { blueprint in
                    Text(blueprint.plugin.map { "\(blueprint.title) · \($0)" } ?? blueprint.title)
                        .tag(Optional(blueprint.key))
                }
            }
            .accessibilityIdentifier("cronEditorStartFrom")
        } footer: {
            if let description = blueprint?.description, !description.isEmpty { Text(description) }
        }
    }

    @ViewBuilder private var jobFields: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Optional"))
                .accessibilityIdentifier("cronEditorName")
            TextField("Prompt", text: $draft.prompt,
                      prompt: Text(draft.isScriptOnly ? "Optional for a script" : "What should Hermes do?"),
                      axis: .vertical)
                .lineLimit(3...10)
                .accessibilityIdentifier("cronEditorPrompt")
        } footer: {
            if draft.isScriptOnly { Text("This job runs a script without an agent, so it uses no prompt or model.") }
        }
        scheduleSection
        deliverySection(isOn: { draft.deliveryTargets.contains($0) },
                        set: { target, on in draft.setDelivery(target, on: on) }, selected: draft.deliveryTargets)
        if !draft.isScriptOnly { modelSection }
    }

    private var scheduleSection: some View {
        Section {
            Picker("Repeat", selection: $draft.schedule.frequency) {
                ForEach(CronSchedule.Frequency.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("cronEditorFrequency")
            switch draft.schedule.frequency {
            case .weekly:
                Picker("Day", selection: $draft.schedule.weekday) {
                    ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) }
                }
            case .monthly:
                Picker("Day of Month", selection: $draft.schedule.dayOfMonth) {
                    ForEach(1...28, id: \.self) { Text("\($0)").tag($0) }
                }
            case .hourly:
                Picker("Minute", selection: $draft.schedule.minute) {
                    ForEach(Array(stride(from: 0, through: 55, by: 5)), id: \.self) {
                        Text(String(format: ":%02d", $0)).tag($0)
                    }
                }
            case .custom:
                TextField("Schedule", text: $draft.schedule.custom, prompt: Text("0 9 * * 1-5"))
                    .monospaced()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityIdentifier("cronEditorCustomSchedule")
            case .daily, .weekdays, .every15Minutes:
                EmptyView()
            }
            if draft.schedule.frequency.hasTime {
                DatePicker("Time", selection: timeBinding(hour: $draft.schedule.hour, minute: $draft.schedule.minute),
                           displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, Self.wallClock)
            }
        } header: {
            Text("Schedule")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let summary = draft.schedule.summary() {
                    Text("\(summary)  ·  \(draft.schedule.expression)")
                } else {
                    Text("A cron expression (minute hour day month weekday), or “every 2h”, “30m”, or a date and time.")
                }
                Text("Times are in the Hermes server's time zone.")
            }
        }
    }

    private func deliverySection(isOn: @escaping (String) -> Bool, set: @escaping (String, Bool) -> Void,
                                 selected: [String]) -> some View {
        let options = CronDeliveryTarget.options(server: cron.targets, job: CronJob(id: "", deliver: selected.joined(separator: ",")))
        return Section("Deliver To") {
            ForEach(options) { target in
                Toggle(isOn: Binding(get: { isOn(target.id) }, set: { set(target.id, $0) })) {
                    Text(target.homeTargetSet ? target.name : "\(target.name) (no home channel)")
                }
                .accessibilityIdentifier("cronEditorDeliver.\(target.id)")
            }
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $draft.model) {
                Text("Profile's default").tag(ModelChoice?.none)
                if let picked = draft.model, catalog?.providers.contains(where: { row in
                    row.slug == picked.provider && row.models.contains(picked.model)
                }) != true {
                    // A pinned model the catalog no longer offers stays shown and picked.
                    Text(ModelLabel.displayName(picked.model)).tag(Optional(picked))
                }
                ForEach(catalog?.providers.filter { $0.authenticated != false } ?? [], id: \.slug) { provider in
                    Section(provider.name) {
                        ForEach(provider.models, id: \.self) { model in
                            Text(ModelLabel.displayName(model))
                                .tag(Optional(ModelChoice(provider: provider.slug, model: model)))
                        }
                    }
                }
            }
            .accessibilityIdentifier("cronEditorModel")
        } footer: {
            Text("A job without its own model uses the profile's default when it runs.")
        }
    }

    // MARK: A blueprint's blanks

    @ViewBuilder private func blueprintFields(_ blueprint: CronBlueprint) -> some View {
        let fields = blueprint.fields.filter { !$0.isDeliver }
        if !fields.isEmpty {
            Section(blueprint.title) {
                ForEach(fields) { field in
                    blueprintControl(field)
                }
            }
        }
        if let deliver = blueprint.fields.first(where: \.isDeliver) {
            let selected = CronJob.parseTargets(blueprintValues[deliver.name])
            deliverySection(isOn: { selected.contains($0) }, set: { target, on in
                blueprintValues[deliver.name] = CronJob(id: "", deliver: blueprintValues[deliver.name])
                    .deliver(toggling: target, on: on)
            }, selected: selected)
        }
    }

    @ViewBuilder private func blueprintControl(_ field: CronBlueprint.Field) -> some View {
        let value = Binding(get: { blueprintValues[field.name] ?? "" }, set: { blueprintValues[field.name] = $0 })
        VStack(alignment: .leading, spacing: 2) {
            switch field.kind {
            case .enum, .weekdays:
                Picker(field.label, selection: value) {
                    ForEach(options(field, current: value.wrappedValue), id: \.self) { Text($0).tag($0) }
                }
            case .time:
                DatePicker(field.label, selection: Binding(
                    get: { Self.date(fromClock: value.wrappedValue) },
                    set: { value.wrappedValue = Self.clock(from: $0) }), displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, Self.wallClock)
            case .text:
                TextField(field.label, text: value, prompt: Text(field.help.isEmpty ? (field.isOptional ? "Optional" : "") : field.help))
            }
            if field.kind != .text, !field.help.isEmpty {
                Text(field.help).uiFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A blank's options, with its current value when it's none of them.
    private func options(_ field: CronBlueprint.Field, current: String) -> [String] {
        field.options.contains(current) || current.isEmpty ? field.options : [current] + field.options
    }

    private func pick(_ key: String?) {
        blueprintKey = key
        blueprintValues = blueprint?.initialValues ?? [:]
        error = nil
    }

    // MARK: Saving

    private func save() {
        error = nil
        if blueprint == nil, let problem = draft.problem {
            error = problem.message
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let connection = server.connection
                if let blueprint {
                    try await connection.createCronJob(from: blueprint, values: blueprintValues)
                } else if case .edit(let job) = target {
                    try await connection.saveCronJob(job, draft)
                } else {
                    try await connection.createCronJob(draft)
                }
                dismiss()
            } catch {
                self.error = GatewayConnection.describe(error)
            }
        }
    }

    // MARK: Times as wall-clock values

    /// The pickers show hours and minutes as given: the server applies its own time zone.
    private static let wallClock = TimeZone(identifier: "UTC")!

    private static var wallCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = wallClock
        return calendar
    }

    private func timeBinding(hour: Binding<Int>, minute: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Self.wallCalendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour.wrappedValue,
                                                        minute: minute.wrappedValue)) ?? Date()
        }, set: { date in
            let parts = Self.wallCalendar.dateComponents([.hour, .minute], from: date)
            hour.wrappedValue = parts.hour ?? 9
            minute.wrappedValue = parts.minute ?? 0
        })
    }

    /// `"HH:MM"`, as a blueprint's time blank holds it.
    private static func date(fromClock text: String) -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        let components = DateComponents(year: 2000, month: 1, day: 1, hour: parts.first ?? 9,
                                        minute: parts.count > 1 ? parts[1] : 0)
        return wallCalendar.date(from: components) ?? Date()
    }

    private static func clock(from date: Date) -> String {
        let parts = wallCalendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
    }
}
