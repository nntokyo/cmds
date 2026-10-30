#!/usr/bin/env python3
"""Checks that relative links in the repository's Markdown files resolve.

    python3 scripts/check-links.py            # from anywhere in the checkout

For every Markdown file (vendor/, build output and hidden directories are skipped) it checks:

- relative links and images, `[text](path)`, `[text](path#anchor)`, `[text](#anchor)` and `<img src="…">` /
  `<a href="…">`: the file or directory must exist and the anchor must match a heading of the target
  (GitHub's rules: lower case, punctuation dropped, spaces to `-`, `-1`, `-2`… for repeats);
- reference-style definitions, `[label]: path`.

It also checks `docs/….md` paths mentioned in source files (code comments, CLI help, project.yml, scripts), so
moving a document cannot silently break them.

External links (http, https, mailto, …) are not fetched. Links inside code blocks and inline code are ignored.
Exit status: 0 when everything resolves, 1 otherwise (each failure is printed as `file:line: message`).
"""
import os
import re
import sys
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
SKIP_DIRS = {"vendor", "build", "DerivedData", "node_modules", "candidates"}
SOURCE_EXTENSIONS = {".swift", ".sh", ".py", ".yml", ".yaml", ".plist", ".md"}

INLINE_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
REFERENCE_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
HTML_LINK = re.compile(r"<(?:a|img)\b[^>]*?\b(?:href|src)\s*=\s*\"([^\"]+)\"", re.IGNORECASE)
HTML_ANCHOR = re.compile(r"<a\b[^>]*?\b(?:id|name)\s*=\s*\"([^\"]+)\"", re.IGNORECASE)
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
DOC_PATH = re.compile(r"(?<![\w./-])((?:\.\./)*docs/[\w./-]+\.md)")


def walk(extensions):
    for directory, subdirs, files in os.walk(ROOT):
        subdirs[:] = sorted(d for d in subdirs if not d.startswith(".") and d not in SKIP_DIRS)
        for name in sorted(files):
            if os.path.splitext(name)[1] in extensions:
                yield os.path.join(directory, name)


def strip_inline_code(line):
    return re.sub(r"(`+)(?:(?!\1).)+\1", "", line)


def prose_lines(path):
    """(line number, text) of the lines outside fenced code blocks."""
    fence = None
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            match = FENCE.match(line)
            if match:
                marker = match.group(1)
                if fence is None:
                    fence = marker[0] * len(marker)
                    continue
                if marker.startswith(fence):
                    fence = None
                    continue
            if fence is None:
                yield number, line.rstrip("\n")


def slug(heading):
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # links → their text
    text = re.sub(r"<[^>]+>", "", text)  # inline HTML
    text = text.replace("`", "").lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


_anchor_cache = {}


def anchors(path):
    if path not in _anchor_cache:
        found, seen = set(), {}
        for _, line in prose_lines(path):
            for anchor in HTML_ANCHOR.findall(line):
                found.add(anchor)
            match = HEADING.match(line)
            if not match:
                continue
            base = slug(match.group(2))
            count = seen.get(base, 0)
            seen[base] = count + 1
            found.add(base if count == 0 else f"{base}-{count}")
        _anchor_cache[path] = found
    return _anchor_cache[path]


def is_external(target):
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target)) or target.startswith("//")


def check_target(source, number, target, failures):
    if is_external(target):
        return
    path_part, _, fragment = target.partition("#")
    path_part = urllib.parse.unquote(path_part.split("?", 1)[0])
    if path_part:
        resolved = os.path.normpath(os.path.join(os.path.dirname(source), path_part))
        if not resolved.startswith(ROOT):
            failures.append((source, number, f"link leaves the repository: {target}"))
            return
        if not os.path.exists(resolved):
            failures.append((source, number, f"missing file: {target}"))
            return
    else:
        resolved = source
    if fragment:
        if os.path.isdir(resolved) or not resolved.endswith(".md"):
            failures.append((source, number, f"anchor on a non-Markdown target: {target}"))
        elif urllib.parse.unquote(fragment) not in anchors(resolved):
            failures.append((source, number, f"missing anchor #{fragment} in {os.path.relpath(resolved, ROOT)}"))


def check_markdown(failures):
    count = 0
    for path in walk({".md"}):
        for number, line in prose_lines(path):
            definition = REFERENCE_DEF.match(line)
            if definition:
                check_target(path, number, definition.group(1), failures)
                count += 1
                continue
            text = strip_inline_code(line)
            for target in INLINE_LINK.findall(text) + HTML_LINK.findall(text):
                check_target(path, number, target, failures)
                count += 1
    return count


def check_doc_paths(failures):
    """`docs/….md` mentioned anywhere in sources, relative to the repository root (or `../` chains)."""
    count = 0
    for path in walk(SOURCE_EXTENSIONS):
        with open(path, encoding="utf-8", errors="replace") as handle:
            for number, line in enumerate(handle, 1):
                for mention in DOC_PATH.findall(line):
                    count += 1
                    relative = re.sub(r"^(?:\.\./)+", "", mention)
                    candidates = [os.path.join(ROOT, relative),
                                  os.path.normpath(os.path.join(os.path.dirname(path), mention))]
                    if not any(os.path.isfile(candidate) for candidate in candidates):
                        failures.append((path, number, f"mentions a missing document: {mention}"))
    return count


def main():
    failures = []
    links = check_markdown(failures)
    mentions = check_doc_paths(failures)
    for path, number, message in sorted(set(failures)):
        print(f"{os.path.relpath(path, ROOT)}:{number}: {message}")
    print(f"checked {links} Markdown links and {mentions} doc path mentions: "
          f"{'all resolve' if not failures else f'{len(set(failures))} broken'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
