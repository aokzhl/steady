# #16 — Ordinary countdown timer

Uses the accepted TaskWorkspace boundary, real local SQLite, and injected now/calendar. An ordinary timer shares the existing one-session slot and run/segment result identity with the stopwatch.

- Timer durations must be positive and fit the signed native integer seconds representation (the largest supported Double is `Double(Int.max).nextDown`). This is a technical representation bound, not a day-based product limit. Launch and adjustment reject overflow before committing; the prompt validates the same bound. All duration labels use checked integer conversion and full-width hours.
- The shared tools menu shows the persisted task timer duration, or «Не задано» when unset, and starts Timer. An unset duration opens a minutes prompt; Cancel starts nothing. Confirm saves that duration for this task and starts atomically. Subsequent task launches reuse it. Free launches prompt each time.
- The session bar shows remaining time separately from actual active work, with Pause/Resume/Stop and navigation to the exact active occurrence, including recurring owners. Pause excludes waiting from both measured work and countdown.
- Hovering the time or pressing the plus/minus control opens an integer −20…+20 minute stepper with a live resulting-time preview. Apply adds to the current remainder, clamps at zero, retains the selected delta for repeated Apply, and preserves the owner/run/running-or-paused state. It never changes the saved task duration.
- Reducing remainder to zero ends manually. Natural expiry records the exact active-time deadline even when delivery is late. Stop and expiry share one transaction and save each segment once. Neither ends the task or awards a pomodoro.
- Results retain a reason (`stopped`, `manual`, `natural`), tool kind, UTC bounds and actual disjoint segments. Task completion still atomically closes the owner's run; another task's completion does not.
- Save failure freezes work and asks for retry. A failed natural end freezes at the actual deadline; retry completes that same result. Reopening an unfinished run pauses at the last committed command and excludes absence.

Migration v8 → v9 adds nullable timer budget/end-reason fields to existing runs and a per-task duration table. Shipped migration bodies v3–v8 are unchanged, including v7 labels and v8 recurrence. Budget is active seconds available for this run; actual time remains derived from its segments. A running adjustment closes/reopens a segment at its command instant to preserve explicit-command durability without charging its work twice.

The editor's one-second notification invokes `updateTimer()` for expiry and continues while windows are closed. It is not a crash checkpoint. Periodic crash checkpoints and sleep/lock handling remain #18; pomodoro remains #17. Native verification is owned by the coordinating agent.
