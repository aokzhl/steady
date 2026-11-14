# #15 — Stopwatch and durable time-tool results

TaskWorkspace is the agreed public seam. Its injected `now` and `calendar` drive deterministic tests against real temporary SQLite databases. The workspace owns one local session; selecting a task is a separate editor concern.

## Behavior

- One tool menu in each row and its details starts a stopwatch. The header also starts without a task. Timer/pomodoro entries remain unavailable until their own slices.
- “К текущей задаче” opens the active owner in its project and the All period after pending editor input saves; free sessions have no owner navigation.
- A session has one stable UUID, tool kind, optional task/occurrence IDs, an owner-title snapshot, its real start instant and its initial time zone.
- The lower bar counts active seconds upward and offers Pause/Resume/Stop. A paused session still owns the single session slot. Stop preserves measured work and leaves completion unchanged.
- Completing the actual owner closes its session and records completion in the same SQLite transaction. Completing another task leaves the session untouched.
- Closed results appear in task details and the header's history. Repeated stop/pause/resume commands do not duplicate runs or segments.
- Failed session writes freeze the in-memory session at the failed command's instant. Retry saves this paused snapshot before applying further commands. Unsaved work remains visible, and UI offers retry.

## Persistence and handoff

Migration v5 → v6 adds `time_tool_runs` and `time_tool_segments`. Real instants are numeric UTC epochs (`REAL`); duration is derived from disjoint work intervals in seconds. The session's time zone is fixed at start, independent of later Mac-zone changes. Segment IDs survive pause/resume and save retries; the run ID also identifies the completed result. A partial unique index enforces one unfinished run, including paused runs. Transactions commit commands immediately; closed results use the same durable records, suitable for a later delivery queue without manufacturing another result identity.

`TimeToolSession.elapsedSeconds(at:)` includes the currently open segment. `durationSeconds` describes closed work/results. `TaskWorkspace.timeToolResults` contains stopped runs; `activeSession` contains the unfinished run. `reload()` refreshes these without changing its clock state. This slice does not implement countdown/pomodoro, delivery, reporting or system-event handling.

Opening a new TaskWorkspace is a process-lifecycle boundary: any persisted open segment is closed at its start, leaving the session paused at the last explicit committed boundary. Normal application quit first pauses and commits actual work. This minimal restart safeguard excludes process absence. #18 adds periodic checkpoints (≤1 second loss), recovery UX and sleep/lock handling; until then, an abrupt exit may lose work since the last explicit command. Keep one TaskWorkspace instance for the application's local space and use `reload()` for refreshes.
