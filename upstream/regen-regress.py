#!/usr/bin/env python3
"""Rewrite a Makefile's REGRESS list from the test files actually present.

Every commit that adds a test touches the same REGRESS list, so reordering the
series conflicts there on almost every commit.  Deriving the list from the files on
disk removes the conflict class entirely: there is nothing to merge.

The reference layout is preserved rather than re-rendered -- entries are filtered out
of the reference block line by line, so upstream's several-per-line style for its own
tests survives.  With every test present the output is byte-identical to the
reference, which is the check that this script is faithful.

Usage: regen-regress.py [Makefile] [reference-Makefile]
"""
import re, sys, pathlib


def block(text):
    m = re.search(r"^REGRESS = (?:[^\n]*\\\n)*[^\n]*\n", text, re.M)
    if not m:
        raise SystemExit("no REGRESS assignment found")
    return m


def main():
    mk = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Makefile")
    ref = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else mk

    text = mk.read_text()
    here = block(text)
    there = block(ref.read_text())

    present = {p.stem for p in pathlib.Path("sql").glob("*.sql")}

    # Filter the reference block line by line, keeping its shape.
    kept_lines = []
    for line in there.group(0).rstrip("\n").split("\n"):
        prefix = "REGRESS = " if line.startswith("REGRESS = ") else ""
        body = line[len(prefix):].rstrip()
        if body.endswith("\\"):
            body = body[:-1]
        indent = "" if prefix else "\t"
        names = [n for n in body.split() if n in present]
        if names:
            kept_lines.append((prefix or indent) + " ".join(names))

    if not kept_lines:
        raise SystemExit("no tests found under sql/")

    # Any test on disk that the reference does not list, appended deterministically.
    listed = {n for l in kept_lines for n in l.replace("REGRESS = ", "").split()}
    for extra in sorted(present - listed):
        kept_lines.append("\t" + extra)

    rendered = " \\\n".join(kept_lines) + "\n"
    mk.write_text(text[: here.start()] + rendered + text[here.end():])
    total = sum(len(l.replace("REGRESS = ", "").split()) for l in kept_lines)
    print(f"REGRESS: {total} tests across {len(kept_lines)} lines")


main()
