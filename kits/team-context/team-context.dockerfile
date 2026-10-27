# syntax=docker/dockerfile:1
FROM scratch
COPY <<'RULES' /usr/share/sandbox/kit/team-context/memory-convention.md
Durable learnings go in docs/agent-memory.md in the workspace, never in ~/.claude (deleted by sbx rm).
RULES
