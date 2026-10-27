# syntax=docker/dockerfile:1
FROM scratch
COPY SKILL.md /usr/share/sandbox/kit/pr-review/SKILL.md
COPY checks/ /usr/share/sandbox/kit/pr-review/checks/
