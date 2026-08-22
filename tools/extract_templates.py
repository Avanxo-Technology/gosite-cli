#!/usr/bin/env python3
"""One-off extractor: turns the heredoc templates in cmd_create.sh and
templates.sh into real files under src/templates/.

Replicates the byte semantics of the old writers exactly:
  - cat > FILE <<'EOF'          -> file ends with a newline
  - write_if_changed FILE <<EOF -> $(cat) strips the trailing newline
  - cat >> MEMORY.md <<'EOF'    -> flavor-specific append parts

Flavor mapping (TAILWIND=1|0) comes from the enclosing function
(_write_views_tailwind / _write_views_plain) and the if/else around the
MEMORY.md appends.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "src", "templates")

HEREDOC_START = re.compile(
    r"""^\s*(cat\s*>>?|write_if_changed)\s+"\$1/([^"]+)"\s*<<'(\w+)'\s*$"""
)

FILES = [
    os.path.join(ROOT, "src", "commands", "cmd_create.sh"),
    os.path.join(ROOT, "src", "lib", "templates.sh"),
]


def extract(path):
    """Yields (context, op, dest, body_lines) per heredoc, where context is
    the enclosing function name plus recent condition lines."""
    with open(path) as fh:
        lines = fh.readlines()
    fn = "?"
    recent = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^_?[a-zA-Z0-9_]+\(\)\s*\{", line)
        if m:
            fn = line.split("(")[0]
        hm = HEREDOC_START.match(line)
        if hm:
            op, dest, term = hm.group(1), hm.group(2), hm.group(3)
            op = op.replace(" ", "")
            body = []
            i += 1
            while i < len(lines) and lines[i].rstrip("\n") != term:
                body.append(lines[i])
                i += 1
            yield fn, list(recent[-3:]), op, dest, body
        recent.append(line.rstrip("\n"))
        if len(recent) > 6:
            recent.pop(0)
        i += 1


def append_flavor(recent):
    """Which branch of the TAILWIND if/else surrounds a MEMORY.md append?"""
    joined = "\n".join(recent)
    if "-eq 1 ]]" in joined and "else" not in joined.split("-eq 1 ]]")[-1]:
        return "tailwind"
    if "else" in joined:
        return "plain"
    return None


def main():
    if os.path.isdir(OUT):
        sys.exit(f"refusing to run: {OUT} already exists")
    os.makedirs(OUT)

    written = []
    for src in FILES:
        for fn, recent, op, dest, body in extract(src):
            content = "".join(body)

            # The .gosite.env marker: destination name is runtime config.
            if dest == "${GOSITE_MARKER}":
                rel = "gosite.env"
            elif fn == "_write_views_tailwind":
                rel = f"flavors/tailwind/{dest}"
            elif fn == "_write_views_plain":
                rel = f"flavors/plain/{dest}"
            elif op == "cat>>" and dest == "MEMORY.md":
                flavor = append_flavor(recent)
                if flavor is None:
                    sys.exit(f"cannot classify MEMORY.md append in {fn}")
                rel = f"flavors/{flavor}/MEMORY.md.part"
            else:
                rel = dest

            path = os.path.join(OUT, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as fh:
                fh.write(content)
            written.append((rel, op))

    for rel, op in sorted(written):
        print(f"{rel}\t{op}")
    print(f"\n{len(written)} template files written to {OUT}")


if __name__ == "__main__":
    main()
