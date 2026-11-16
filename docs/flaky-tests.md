# Flaky tests

Tests that failed now and then without a code change: why, and what was done. Add a row when
you meet a new one, with the evidence (CI run, platform, assertion), and keep the rules at the
end in mind when writing new tests.

## Package (`Packages/HermesKit`)

Seen in GitHub CI (Linux, Swift 6.2 and 6.4) and in full parallel runs on Windows and in WSL.
Every one passed when run alone: they lose only when the runner is loaded.

### `TranscriptObservationTests.streamedTextShowsABatchAtATime`

- **Seen**: CI, 5 of the 8 failed `package-tests` runs from 2026-10-31 to 2026-11-12 (main and
  branches, 6.2 and 6.4); Windows full runs. Always `gaps.allSatisfy { $0 >= .milliseconds(25) }`,
  for example `[…, 0.187, 0.084, 0.023, 0.033, …]` seconds.
- **Cause**: the test, not the queue. `StreamedTextQueue` waits at least 33 ms between batches
  (`Task.sleep(until:)` never wakes early). The test's `ChangeLog` took the time in the task that
  re-tracks the transcript, which runs some time after the change. Late for one batch and on
  time for the next, the measured gap came out shorter than the real one.
- **Fix**: the time is taken in `onChange`, which runs synchronously as the change is made.

### `ReclaimedRuntimeTests.goingBackDuringARevivalDoesNotResumeAgain`

- **Seen**: Windows full runs, about one in four (PR #153).
- **Cause**: the test waited a fixed 100 ms for the revisit to get past its Bot Chat lookup and
  join the revival in flight; nothing signalled it. On a loaded runner the test answered the
  revival first, so the revisit found a live chat and bound it with `session.activate`, which the
  test rules out.
- **Fix**: `ChatSession.reconcileWaitsOnRevival`, set while a reconcile waits on the revival
  (`GatewayConnection+Revisit.swift`), and the test waits for it. It changes no behaviour.

### `GatewayClientTests.heartbeatPingsAndDropsSilentConnection`

- **Seen**: WSL full run (PR #153).
- **Cause**: `GatewayClient.connectionEnded` tells subscribers of the drop before it closes the
  transport, and the test checked `transport.isClosed` as soon as it heard of the drop.
- **Fix**: the test waits for the close (`eventually`).
- **Still timing-bound**: a heartbeat task starved for more than the 2 s timeout drops the
  connection without pinging, and the test misses its ping. Not seen since the timeout went from
  a shorter value to 2 s.

### `LocalBackendTests.restartsAfterTheBackendDied`

- **Seen**: WSL full run (PR #153).
- **Cause**: the fake backend exits 0.3 s after its announcement, and the test looked a fixed
  1 s later. When Foundation's `Process` sees the exit depends on the load.
- **Fix**: the test polls `isRunning` (`eventuallyAsync`, up to 20 s).

### Fixed earlier

- `SessionNavigationTests.aProfilePickedAgainShowsItsListAtOnce` hit its 60 s limit on CI
  (2026-11-12): it waited for the loading flag, which turns on before the request is sent. Fixed
  in #149: it waits for the request itself.
- `TranscriptScenarioTests.aLateStartKeepsThePromptBubble` failed on a branch in CI
  (2026-11-07) on both toolchains: a real bug in the branch, not a flake.

### Seen once, no data

- `ChatComposerTests.anEffortChangeLostWithTheConnectionClearsOnReconnect` (one run in six,
  PR #114, 2026-10). Record the assertion if it fails again.

## Mac and iOS (VM)

The VM clears its results at each run (`scripts/vm-test.sh`), so the evidence is what threads
and PRs wrote down.

### `SessionUnreadUITests.testAReplyOffScreenMarksItsRowWithoutReorderingTheList`

- **Seen**: PR #140, failed 3 of 4 runs on its branch and 2 of 5 on main, same assertion
  ("only A is unread").
- **Cause**: B's prompt held B's expected reply (`PONG1234`), and `waitForMessage` matches
  text *containing* it, so the prompt's own bubble matched. The test left B while it was still
  answering, and B's reply then marked B unread as well.
- **Fix**: the prompt spells the marker in two parts ("the word PONG immediately followed by
  the digits 1234"), as `TodoPillUITests` and `BackgroundTasksUITests` do, and the test waits for
  B's turn to end before going back to the list.

### Fixed earlier

- `ComposerSlashListTests.theListSurvivesEveryKindOfChange` (window) hit the suite's 1-minute
  limit under a full run: the limit is 3 minutes and the test is in `SLOW_WINDOW_TESTS`, run
  only when named (#106).
- `NotificationSettingsUITests`, `SessionDateGroupsUITests` (iOS, full runs): #149.
- `SendStateUITests` took 40 minutes once waiting on the real model: #106 stopped that check.

### Not flaky

- `LazyTranscriptTests.foldOpenedBeforeScrollingAwayIsOpenWhenBack` and
  `lazyChatKeepsItsHeightWhileScrolling` fail every time, with the same numbers, on main since
  at least 2026-11-01 (PRs #132 and #146 checked unchanged main). They are broken tests or a regression, not
  timing; they need their own look.

### Known flaky, cause not yet recorded

Seen in full runs by earlier threads, without the failing assertion written down:
`LiveChatUITests.testNewChatKeepsItsDraftAndBotChatIsPlain` (macOS), the iOS reconnect banner,
drawer swipe timing and theme preview tests, `CronJobsUITests` on a slow model reply, and
`ClarifyCardUITests` (now attaches a screenshot when the waiting banner doesn't show). When one
fails, write the assertion, the run and a screenshot here before re-running.

## Rules for new tests

These follow from the causes above (and from Swift Testing's and XCTest's own guidance: wait
for a condition, not for a time).

- **Wait for a signal, not a fixed time.** Use `eventually` / `eventuallyAsync` (package) or
  `waitForExistence` / `XCTNSPredicateExpectation` (UI). They count polls, so the budget
  stretches with the load. When nothing observable marks the moment, add a small internal flag
  for it rather than a sleep.
- **A negative check after a sleep** ("nothing else happened") passes trivially if the sleep is
  too short; put it after a positive signal that the code got past the point in question.
- **Measure where the thing happens.** Times taken in a hop that follows the event (a `Task`, a
  main-queue block) include the scheduler's delay.
- **Close and finish steps that run after a notification** (closing a transport after
  telling subscribers) are not done when the notification arrives; wait for them.
- **UI tests that wait for a model's reply**: never put the expected marker whole in the
  prompt; spell it in parts, and wait for the turn to end (Send is back) before leaving the chat.
