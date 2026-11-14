# Domain Docs

## Read before exploring or changing product behavior

This repository uses one domain documentation context: the root `GLOSSARY.md` and `docs/adr/`. The planned multi-platform monorepo does not create separate domain glossaries at this stage.

1. Read `GLOSSARY.md` for product vocabulary. Use its terms in specifications, issues, test names and implementation discussions.
2. Read `docs/MVP.md` for the accepted scope, behavior and unresolved questions of the current MVP.
3. For interface work, read `docs/design/steady-current-design.md` and follow its pointer to the current November 11, 2026 mockup. Read `docs/design/steady-focus-design-handoff.md` for detailed behavior within the current MVP; older snapshots remain historical references.
4. Read the ADRs relevant to the area being changed, including later amendments and superseding decisions.

If a referenced domain file is absent in a future checkout, proceed with available sources without creating placeholder domain documents. Domain modeling records terms and decisions when they are actually resolved.

## Source precedence

- Explicit user decisions take precedence over earlier documentation.
- The current MVP defines the release scope; the current design defines its latest layout. A field visible in a mockup is not by itself an accepted business rule.
- Later accepted ADR amendments supersede earlier decisions in the area they explicitly replace. ADR-0008 establishes the unified Steady application and replaces the independent Focus/Fit application model; sso and Focus remain the technical services.
- The November 11 mockup supersedes earlier A/B/C layouts. The November 5 design spec and November 7 baseline are historical sources, not alternative current MVPs.
- If a conflict remains, state the affected sources and unresolved decision instead of silently choosing new behavior.

## Vocabulary and boundaries

Use the glossary's definitions, including the distinction between a task occurrence, a time tool and a time-tool result. A missing term is a question for domain modeling, not permission to invent a synonym silently.

Keep future product vocabulary separate from current release scope. Specialized project types, workouts and specialized Islamic features in the glossary or ADRs do not expand this MVP. Preserve existing product documents and design artifacts during skills setup.

## Layout

- `GLOSSARY.md`: shared domain language.
- `docs/adr/`: accepted architectural and product decisions with their amendments.
- `docs/MVP.md`: current release boundaries and open questions.
- `docs/design/steady-current-design.md`: pointer to the current UI reference.
