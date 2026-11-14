# Issue tracker: GitHub

Specifications and tickets live in GitHub Issues in `aokzhl/steady`: https://github.com/aokzhl/steady/issues.
Use the `gh` CLI with an explicit repository argument. Before the first write of a session, verify the target with `gh repo view aokzhl/steady --json nameWithOwner,url`.

## Conventions

- Create an issue: `gh issue create --repo aokzhl/steady --title "..." --body-file <file>`. Write multiline Markdown to a UTF-8 file with actual newlines.
- Read an issue and comments: `gh issue view <number> --repo aokzhl/steady --json number,title,body,labels,comments`.
- List issues: `gh issue list --repo aokzhl/steady --state open --limit 100 --json number,title,labels,assignees`; use filters and pagination when the task needs more results.
- Update a body: `gh issue edit <number> --repo aokzhl/steady --body-file <file>`.
- Add or remove labels: `gh issue edit <number> --repo aokzhl/steady --add-label "..."` or `--remove-label "..."`. Use the role mapping in `docs/agents/triage-labels.md`.
- Post an authorized comment: `gh issue comment <number> --repo aokzhl/steady --body-file <file>`.
- Close completed work according to the invoked skill or agreed workflow. When an explanation is required, post it before `gh issue close <number> --repo aokzhl/steady`; an already-closed issue must still receive the explanation.
- Fetch a specification or ticket by reading its full body and comments. Publishing to the tracker means creating a GitHub issue; it does not deploy an application.

## Parents and blocking dependencies

Prefer GitHub's native sub-issues and blocking dependencies. Check `gh issue create --help` and `gh issue edit --help` before using version-dependent flags.

When the installed CLI lacks parent/dependency flags, use the REST operations below:

- Get the issue's numeric database ID: `gh api repos/aokzhl/steady/issues/<number> --jq .id`. This is distinct from its issue number and node ID.
- Link a child: `gh api --method POST repos/aokzhl/steady/issues/<parent-number>/sub_issues -F sub_issue_id=<child-database-id>`.
- Add a blocker: `gh api --method POST repos/aokzhl/steady/issues/<child-number>/dependencies/blocked_by -F issue_id=<blocker-database-id>`.
- Count open native blockers: `gh api repos/aokzhl/steady/issues/<number> --jq .issue_dependencies_summary.blocked_by`. Read the relationships to identify specific blockers when needed; a missing field is not proof of zero blockers.

If native relationships are unavailable, record `Part of #<parent>` and `Blocked by: #<number>, #<number>` in ticket bodies, and maintain a child task list in the parent when the active skill requires it. Record native/textual fallback explicitly so a later skill reads the same dependency representation. Publish blockers first so references use real issue numbers.

A ticket is ready to start when all its blockers are closed. The `ready-for-agent` label alone does not prove that it is unblocked. For each ticket retain its deliverable and acceptance criteria; use the originating specification as context. Skills that produce agent-ready specs or tickets apply `ready-for-agent` directly.

## Pull requests as a triage surface

**PRs as a request surface: no.**

Issue and PR numbers share a namespace. For an ambiguous reference, resolve its type before operating on it.

## Wayfinding operations

When `/wayfinder` is invoked, its map is one issue with label `wayfinder:map`. Decision tickets are child issues with the appropriate `wayfinder:<type>` label; create missing labels only when that flow is used.

- Link children and blockers as described above.
- Query open children; ready work has no open blockers or assignee.
- Claim work with `gh issue edit <number> --repo aokzhl/steady --add-assignee @me`.
- On resolution, post the decision, close the ticket and update the map's Decisions-so-far with a short summary and link.
