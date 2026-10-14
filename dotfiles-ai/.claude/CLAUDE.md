# Agent Guidelines

## Environment

- Always work under `$WORKSPACE`

## Workspace layout

- Clone repositories into `$WORKSPACE/<repo-name>`
- Use git worktrees for all feature work — create them as `$WORKSPACE/<repo-name>-<branch-name>`
- Never work directly on a branch in the main clone — keep it on the default branch and up to date
- Remove worktrees once the PR is merged

## GitHub

- Use `gh` for all GitHub interactions (PRs, issues, releases, API calls) rather than raw git or curl
- Any issue opened must include `🤖 Authored by claude` as the first line of the body

## Python

- Always use `uv` for Python work (projects, dependencies, virtual environments)
- Install Python-based tools with `uv tool` where possible rather than pip or pipx

## Security

- Never use `sudo` or attempt to escalate privileges
- Never commit files containing credentials, tokens, API keys, or secrets

## Behaviour

- If something unexpected is encountered mid-task, stop and report rather than attempting to work around it
- Ask for approval before editing code unless explicitly instructed to work autonomously

## Writing style

Choose the style by who reads the text, not by the type of the file.

### Text that a person reads — use ASD-STE100

Applies to chat replies, commit messages, PR and issue bodies, code comments,
`README` files, and all other documentation for people.

Write in ASD-STE100 Simplified Technical English:

- Use the active voice. Write "The script starts the firewall", not "The firewall
  is started by the script"
- Give one instruction per sentence. Use the imperative: "Run the installer"
- Keep procedural sentences to 20 words or less, and descriptive sentences to 25
  words or less
- Keep paragraphs to 6 sentences or less. Give one topic to each paragraph
- Use one word for one meaning. Do not use a different word for the same thing in
  the same document
- Keep the same term for the same item every time. Do not change "container" to
  "image" to "instance"
- Do not use a noun as a verb. Do not write "action the change" or "leverage the
  cache"
- Do not use more than 3 words in a noun cluster. Write the cluster as a phrase
- Do not remove the articles "a" and "the", or the word "that"
- Do not use an `-ing` form of a verb unless it is a technical name
- Do not use idioms, metaphors, or humour
- Put a warning or a caution before the step that it applies to

### Text that only an agent reads — no style constraint

Applies to plans, TODO and progress trackers, scratch notes, handover context,
and `CLAUDE.md` files.

Use the format that is the most dense and the least ambiguous for a model to
read. Fragments, tables, symbols, and jargon are correct here.

If both a person and an agent read a document, use ASD-STE100.

## Development guidelines

- Default branch to start from is `main`
- Only one feature/bug should be worked on at a time
- Each feature should get a new branch
- Follow existing code style. Check neighboring files for patterns
- Never co-author commits
- Use "conventional commit" style
