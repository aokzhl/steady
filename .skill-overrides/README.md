# Local skill overrides

`software-factory` comes from `mattpocock/skills`, commit `4ae2317ddb22b046e26455e4f9c9b3aaaf62212d`, path `skills/in-progress/software-factory`.

The only source change is quoting the YAML `description` in `SKILL.md`, so skills.sh can parse the colon in its value. The instruction body and bundled references are unchanged. `skills-lock.json` uses this project-local directory to restore the skill through skills.sh.
