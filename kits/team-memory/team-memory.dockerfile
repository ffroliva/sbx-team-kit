# syntax=docker/dockerfile:1
FROM scratch
COPY <<'NOTE' /usr/share/sandbox/kit/team-memory/README.md
Test kit: /home/agent/.claude/projects is a per-sandbox volume; /home/agent/team-memory is shared across sandboxes using this kit.
NOTE
