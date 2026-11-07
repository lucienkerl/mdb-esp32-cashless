"""Tiny helpers for slicing KiCad S-expression text (no full parser needed)."""
import re


def block_at(s, start):
    """Return the balanced (...) block starting at index `start`."""
    depth = 0
    in_str = False
    i = start
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return s[start:i + 1]
        i += 1
    raise ValueError("unbalanced block")


def children(block):
    """Top-level child blocks of `block` (list of strings)."""
    out = []
    depth = 0
    in_str = False
    i = 0
    start = None
    while i < len(block):
        c = block[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
            if depth == 2:
                start = i
        elif c == ")":
            if depth == 2 and start is not None:
                out.append(block[start:i + 1])
                start = None
            depth -= 1
        i += 1
    return out


def find_symbol(lib_text, name):
    m = re.search(r'\n\s*\(symbol "%s"' % re.escape(name), lib_text)
    if not m:
        raise KeyError(name)
    return block_at(lib_text, lib_text.index("(", m.start()))
