# Agent Guidelines

## Environment

- Always work under `$WORKSPACE`

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

## Development guidelines

- Default branch to start from is `main`
- Only one feature/bug should be worked on at a time
- Each feature should get a new branch
- Follow existing code style. Check neighboring files for patterns
- Never co-author commits
- Use "conventional commit" style
