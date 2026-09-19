"""Rough structural check for the plug-in's Lua sources.

Not a Lua parser: it tokenizes enough to strip comments and strings, then
verifies that block keywords and brackets balance. Catches the typos that
otherwise only surface as a Lightroom plug-in load error.
"""

import pathlib
import re
import sys

# 'for' and 'while' are not counted: their block is opened by the 'do' that
# always follows, so counting both would need two 'end' keywords.
BLOCK_OPENERS = {"function", "if", "do"}
BLOCK_CLOSERS = {"end"}
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def strip_noise(source: str) -> str:
    out = []
    i = 0
    n = len(source)
    while i < n:
        two = source[i : i + 2]
        if two == "--":
            long_open = re.match(r"--\[(=*)\[", source[i:])
            if long_open:
                level = long_open.group(1)
                close = source.find(f"]{level}]", i)
                i = n if close == -1 else close + len(level) + 2
            else:
                newline = source.find("\n", i)
                i = n if newline == -1 else newline
            continue

        long_open = re.match(r"\[(=*)\[", source[i:])
        if long_open:
            level = long_open.group(1)
            close = source.find(f"]{level}]", i)
            i = n if close == -1 else close + len(level) + 2
            out.append(' "" ')
            continue

        char = source[i]
        if char in "\"'":
            i += 1
            while i < n and source[i] != char:
                i += 2 if source[i] == "\\" else 1
            i += 1
            out.append(' "" ')
            continue

        out.append(char)
        i += 1

    return "".join(out)


def check(path: pathlib.Path) -> list[str]:
    raw = path.read_bytes()
    problems = []

    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        problems.append("file is UTF-16; Lightroom requires UTF-8")
        return problems
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append("file starts with a UTF-8 BOM; Lightroom requires none")
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.append(f"not valid UTF-8: {exc}")
        return problems

    code = strip_noise(raw.decode("utf-8"))

    depth = 0
    for match in WORD.finditer(code):
        word = match.group(0)
        if word in BLOCK_OPENERS:
            depth += 1
        elif word in BLOCK_CLOSERS:
            depth -= 1
            if depth < 0:
                line = code.count("\n", 0, match.start()) + 1
                problems.append(f"unexpected 'end' at line {line}")
                depth = 0
    if depth:
        problems.append(f"{depth} unclosed block(s): missing 'end'")

    for opener, closer, label in (("(", ")", "paren"), ("{", "}", "brace"), ("[", "]", "bracket")):
        balance = code.count(opener) - code.count(closer)
        if balance:
            problems.append(f"{label} imbalance: {balance:+d}")

    return problems


def main() -> int:
    plugin = pathlib.Path(__file__).resolve().parent.parent / "PublishAll.lrplugin"
    failed = False

    for path in sorted(plugin.glob("*.lua")):
        problems = check(path)
        if problems:
            failed = True
            print(f"FAIL {path.name}")
            for problem in problems:
                print(f"     {problem}")
        else:
            print(f"ok   {path.name}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
