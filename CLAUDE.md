@AGENTS.md

## Claude Code only

- Subagents must not spawn subagents. Give every subagent or dispatched session what it can and cannot do (files, commands, what to report back).
- Subagents report to the parent session with `SendMessage` (find the agent ID with `ListAgents`), not to the user.
- Use the session scratchpad for temporary files, not `/tmp`.
- After a refactor, consider `/simplify`.
