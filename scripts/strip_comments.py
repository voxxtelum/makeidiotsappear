"""Strip Lua comments from .lua files in place under a given root directory.

Used by the release workflow to build a clean copy of the addon before
packaging, so shipped code has no source comments. Understands Lua string
and long-bracket syntax so it never touches "--" inside string literals.
"""

import argparse
import pathlib


def _match_long_bracket_open(s, i):
    # s[i] == '['. Returns (level, index_after_open) or None.
    j = i + 1
    level = 0
    while j < len(s) and s[j] == "=":
        level += 1
        j += 1
    if j < len(s) and s[j] == "[":
        return level, j + 1
    return None


def _match_long_bracket_close(s, i, level):
    # s[i] == ']'. Returns index_after_close or None.
    j = i + 1
    count = 0
    while j < len(s) and s[j] == "=":
        count += 1
        j += 1
    if count == level and j < len(s) and s[j] == "]":
        return j + 1
    return None


def strip_lua_comments(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]

        if c == "-" and i + 1 < n and s[i + 1] == "-":
            i += 2
            opened = s[i] == "[" if i < n else False
            if opened:
                m = _match_long_bracket_open(s, i)
                if m is not None:
                    level, after = m
                    i = after
                    while i < n:
                        if s[i] == "]":
                            close = _match_long_bracket_close(s, i, level)
                            if close is not None:
                                i = close
                                break
                        if s[i] == "\n":
                            out.append("\n")
                        i += 1
                    continue
            # line comment: skip to (not including) the newline
            while i < n and s[i] != "\n":
                i += 1
            continue

        if c == '"' or c == "'":
            quote = c
            out.append(c)
            i += 1
            while i < n:
                ch = s[i]
                if ch == "\\" and i + 1 < n:
                    out.append(ch)
                    out.append(s[i + 1])
                    i += 2
                    continue
                out.append(ch)
                i += 1
                if ch == quote:
                    break
            continue

        if c == "[":
            m = _match_long_bracket_open(s, i)
            if m is not None:
                level, after = m
                out.append(s[i:after])
                i = after
                while i < n:
                    if s[i] == "]":
                        close = _match_long_bracket_close(s, i, level)
                        if close is not None:
                            out.append(s[i:close])
                            i = close
                            break
                    out.append(s[i])
                    i += 1
                continue
            out.append(c)
            i += 1
            continue

        out.append(c)
        i += 1

    return "".join(out)


def main():
    parser = argparse.ArgumentParser(
        description="Strip Lua comments from .lua files in place."
    )
    parser.add_argument("root", help="Directory to process")
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        metavar="DIR",
        help="Directory name to skip anywhere under root (repeatable)",
    )
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    exclude = set(args.exclude)

    for path in root.rglob("*.lua"):
        rel_parts = path.relative_to(root).parts
        if exclude.intersection(rel_parts):
            continue
        text = path.read_text(encoding="utf-8")
        path.write_text(strip_lua_comments(text), encoding="utf-8")


if __name__ == "__main__":
    main()
