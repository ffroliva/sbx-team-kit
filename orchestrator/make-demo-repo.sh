#!/usr/bin/env bash
# Creates the demo repository the orchestrator PoC hands to workers: three independent bugs,
# one failing test each. Usage: make-demo-repo.sh <dir>
set -eu
d=${1:?target dir}
mkdir -p "$d" && cd "$d"
git init -q -b main
git config user.name "orchestrator"; git config user.email "orchestrator@example.invalid"

cat > textkit.py <<'EOF'
"""Three small utilities, each with one bug."""


def slugify(title: str) -> str:
    """'Hello, World!' -> 'hello-world'"""
    words = "".join(c if c.isalnum() or c == " " else " " for c in title).split()
    return "_".join(words).lower()  # BUG: should join with '-'


def parse_duration(text: str) -> int:
    """'1h30m' -> 5400 seconds; supports h, m, s."""
    total, num = 0, ""
    units = {"h": 3600, "m": 60, "s": 1}
    for ch in text:
        if ch.isdigit():
            num += ch
        else:
            total += int(num) * units[ch]
            num = ""
    return total + int(num or 0) * 60  # BUG: a trailing bare number is seconds, not minutes


def chunk(items: list, size: int) -> list:
    """chunk([1,2,3,4,5], 2) -> [[1,2],[3,4],[5]]"""
    return [items[i:i + size] for i in range(0, len(items) - size, size)]  # BUG: drops the tail
EOF

cat > test_textkit.py <<'EOF'
import unittest

from textkit import chunk, parse_duration, slugify


class TestSlugify(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(slugify("Hello, World!"), "hello-world")


class TestParseDuration(unittest.TestCase):
    def test_hours_minutes(self):
        self.assertEqual(parse_duration("1h30m"), 5400)

    def test_bare_seconds(self):
        self.assertEqual(parse_duration("90"), 90)


class TestChunk(unittest.TestCase):
    def test_tail_kept(self):
        self.assertEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])


if __name__ == "__main__":
    unittest.main()
EOF
printf '* text=auto eol=lf\n' > .gitattributes
git add -A && git commit -q -m "textkit with three known bugs"
echo "demo repo at $d: $(git log --oneline | wc -l) commit"
