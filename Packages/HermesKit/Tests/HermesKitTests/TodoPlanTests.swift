import Foundation
import HermesProtocol
import Testing

@testable import HermesKit

/// The task list above the composer, read from the Todo tool's rows (`TodoPlan`).
@Suite struct TodoPlanTests {
    private func event(_ type: String, _ payload: JSONValue? = nil) -> GatewayEvent {
        GatewayEvent(type: type, sessionID: "sid-1", payload: payload)
    }

    private func todo(_ id: String, _ status: String, parent: String? = nil) -> JSONValue {
        var item: [String: JSONValue] = ["id": .string(id), "content": .string("task \(id)"), "status": .string(status)]
        if let parent { item["parent"] = .string(parent) }
        return .object(item)
    }

    /// The Todo tool's answer (`tools/todo_tool.py:218`), which `tool.complete` carries as its
    /// JSON-parsed `result`, with `todos`/`revision` merged in (`tool_progress.py:358-364`).
    private func todoResult(_ todos: [JSONValue], revision: Int) -> JSONValue {
        ["todos": .array(todos), "revision": .number(Double(revision)), "summary": ["total": .number(Double(todos.count))]]
    }

    private func runTodo(_ transcript: inout Transcript, id: String, _ todos: [JSONValue], revision: Int) {
        transcript.apply(event("tool.start", ["tool_id": .string(id), "name": "todo_list"]))
        let result = todoResult(todos, revision: revision)
        transcript.apply(event("tool.complete", [
            "tool_id": .string(id), "name": "todo_list", "result": result,
            "todos": .array(todos), "revision": .number(Double(revision)),
        ]))
    }

    @Test func aTodoResultParsesItsItemsAndRevision() throws {
        let plan = try #require(TodoPlan.parse(todoResult([
            todo("a", "completed"), todo("b", "in_progress"), todo("c", "pending"), todo("d", "cancelled"),
            ["id": "e", "content": "", "status": "pending"], ["id": "f", "content": "x", "status": "someday"],
        ], revision: 3)))
        #expect(plan.revision == 3)
        #expect(plan.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(plan.completed == 1 && plan.total == 3)
        #expect(plan.current?.id == "b")
        #expect(!plan.isFinished)
    }

    @Test func aResultStoredAsTextParsesToo() throws {
        let text = #"{"todos":[{"id":"1","content":"Read it","status":"completed"}],"revision":2,"summary":{}}"#
        let plan = try #require(TodoPlan.parse(.string(text)))
        #expect(plan.items == [TodoPlan.Item(id: "1", content: "Read it", status: .completed)])
        #expect(plan.isFinished)
        #expect(TodoPlan.parse(.string(#"{"error":"todos must be a list"}"#)) == nil)
    }

    @Test func subtasksFollowTheirParent() throws {
        let plan = try #require(TodoPlan.parse(todoResult([
            todo("a", "pending"), todo("b", "pending"), todo("a1", "pending", parent: "a"),
            todo("x", "pending", parent: "missing"),
        ], revision: 1)))
        #expect(plan.rows.map(\.id) == ["a", "a1", "b", "x"])
        #expect(plan.rows.map(\.depth) == [0, 1, 0, 0])
    }

    @Test func theListShowsWhileTheAgentWorksThroughIt() {
        var transcript = Transcript()
        transcript.appendUserPrompt("ship it")
        #expect(transcript.todoPlan == nil)
        runTodo(&transcript, id: "t1", [todo("a", "in_progress"), todo("b", "pending")], revision: 1)
        #expect(transcript.todoPlan?.completed == 0)
        #expect(transcript.todoPlan?.current?.id == "a")
        // A Todo call in flight leaves the last list showing.
        transcript.apply(event("tool.start", ["tool_id": "t2", "name": "todo_list"]))
        #expect(transcript.todoPlan?.revision == 1)
        transcript.apply(event("tool.complete", ["tool_id": "t2", "name": "todo_list",
                                                 "result": todoResult([todo("a", "completed"), todo("b", "completed")],
                                                                      revision: 2)]))
        #expect(transcript.todoPlan?.revision == 2)
        #expect(transcript.todoPlan?.isFinished == true)
        transcript.apply(event("message.complete", ["text": "Done.", "status": "complete"]))
        // Finished, it stays after the turn, until the next prompt.
        #expect(transcript.todoPlan?.completed == 2)
        transcript.appendUserPrompt("thanks")
        #expect(transcript.todoPlan == nil)
    }

    @Test func anUnfinishedListStaysWhileTheNextTurnRuns() {
        var transcript = Transcript()
        transcript.appendUserPrompt("plan it")
        runTodo(&transcript, id: "t1", [todo("a", "completed"), todo("b", "pending")], revision: 1)
        transcript.apply(event("message.complete", ["text": "Paused.", "status": "complete"]))
        #expect(transcript.todoPlan?.total == 2)
        transcript.appendUserPrompt("go on")
        transcript.apply(event("message.start"))
        #expect(transcript.isRunning)
        #expect(transcript.todoPlan?.total == 2)
        // That turn ended without touching it: the list was left behind.
        transcript.apply(event("message.complete", ["text": "Something else.", "status": "complete"]))
        #expect(transcript.todoPlan == nil)
    }

    @Test func aSteerDoesNotEndTheList() {
        var transcript = Transcript()
        transcript.appendUserPrompt("ship it")
        runTodo(&transcript, id: "t1", [todo("a", "completed")], revision: 1)
        transcript.appendUserPrompt("also the docs", displayKind: "steer")
        #expect(transcript.todoPlan?.isFinished == true)
    }

    @Test func anEmptyOrFailedTodoCallShowsNothing() {
        var transcript = Transcript()
        transcript.appendUserPrompt("plan it")
        runTodo(&transcript, id: "t1", [todo("a", "pending")], revision: 1)
        runTodo(&transcript, id: "t2", [], revision: 2)
        #expect(transcript.todoPlan == nil)

        var failed = Transcript()
        failed.appendUserPrompt("plan it")
        runTodo(&failed, id: "t1", [todo("a", "pending")], revision: 1)
        failed.apply(event("tool.start", ["tool_id": "t2", "name": "todo_list"]))
        failed.apply(event("tool.complete", ["tool_id": "t2", "name": "todo_list", "error": "boom",
                                             "result": todoResult([], revision: 1)]))
        #expect(failed.todoPlan?.items.map(\.id) == ["a"])
    }

    @Test func otherToolsWithTodoShapedResultsAreNotTheList() {
        var transcript = Transcript()
        transcript.appendUserPrompt("read it")
        transcript.apply(event("tool.start", ["tool_id": "t1", "name": "read_file"]))
        transcript.apply(event("tool.complete", ["tool_id": "t1", "name": "read_file",
                                                 "result": todoResult([todo("a", "pending")], revision: 1)]))
        #expect(transcript.todoPlan == nil)
    }

    /// A reopened chat: the stored Todo row (its content is the tool's JSON) is the list,
    /// through the `tool_call` bridge too (`todo_tool.py:296-310`).
    @Test func aStoredListShowsUntilAPromptFollowsIt() {
        func rows(name: String, promptAfter: Bool) -> [StoredMessage] {
            var call = StoredMessage(id: 2, role: "assistant", content: .string(""))
            call.toolCalls = [["id": "c1", "type": "function", "function": ["name": .string(name), "arguments": "{}"]]]
            let text = #"{"todos":[{"id":"1","content":"Read it","status":"completed"}],"revision":4}"#
            var result = StoredMessage(id: 3, role: "tool", content: .string(text))
            result.toolCallID = "c1"
            var rows = [StoredMessage(id: 1, role: "user", content: "go"), call, result,
                        StoredMessage(id: 4, role: "assistant", content: "Done.")]
            if promptAfter {
                rows += [StoredMessage(id: 5, role: "user", content: "thanks"),
                         StoredMessage(id: 6, role: "assistant", content: "You're welcome.")]
            }
            return rows
        }
        for name in ["todo_list", "todo", "tool_call"] {
            var transcript = Transcript()
            transcript.installLatestPage(rows(name: name, promptAfter: false), hasOlder: false)
            #expect(transcript.todoPlan?.revision == 4, "\(name)")
        }
        var later = Transcript()
        later.installLatestPage(rows(name: "todo_list", promptAfter: true), hasOlder: false)
        #expect(later.todoPlan == nil)
    }
}
