# Triage Labels

Use this mapping whenever a skill names a canonical triage role.

| Role in mattpocock/skills | Label in this tracker | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate the issue. |
| `needs-info` | `needs-info` | Waiting for information needed to proceed. |
| `ready-for-agent` | `ready-for-agent` | Specified sufficiently for agent implementation. |
| `ready-for-human` | `ready-for-human` | Requires human implementation. |
| `wontfix` | `wontfix` | Will not be actioned. |

A readiness label does not start an agent; implementation is a separate invocation or configured automation. Check blocking dependencies before starting a ticket.
