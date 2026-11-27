#!/usr/bin/env python3
"""Inspect APT source files directly, including entries APT deduplicates."""

import argparse
from pathlib import Path
import posixpath
import re
import sys
from urllib.parse import urlsplit


def repository(uri):
    try:
        url = urlsplit(uri)
        if url.scheme not in {"http", "https"}:
            return None
        port = url.port
    except ValueError:
        return None
    if port == {"http": 80, "https": 443}[url.scheme]:
        port = None
    def normalize_escape(match):
        char = chr(int(match[0][1:], 16))
        return char if re.fullmatch(r"[A-Za-z0-9_.~-]", char) else match[0].upper()

    decoded = re.sub(r"%[0-9a-fA-F]{2}", normalize_escape, url.path)
    path = posixpath.normpath("/" + decoded.lstrip("/"))
    return url.hostname, port, path


def one_line(text):
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.partition("#")[0].strip()
        if not line:
            continue
        match = re.fullmatch(r"(deb(?:-src)?)\s+(?:\[([^\]]*)\]\s+)?(\S+)\s+(\S+)(?:\s+(.*))?", line)
        if match is None:
            yield lineno, None, line
            continue
        kind, options, uri, suite, components = match.groups()
        fields = {"types": kind, "uris": uri, "suites": suite, "components": components or ""}
        for option in (options or "").split():
            key, _, value = option.partition("=")
            key = {"arch": "architectures", "arch+": "architectures-add",
                   "arch-": "architectures-remove"}.get(key, key)
            if key in fields:
                fields["_duplicate"] = "yes"
            fields[key] = value.replace(",", " ") if key.startswith("architectures") else value
        yield lineno, fields, line


def deb822(text):
    fields = {}
    start = 1
    key = None
    for lineno, line in enumerate([*text.splitlines(), ""], 1):
        if line.startswith("#"):
            continue
        if not line.strip():
            if fields:
                yield start, fields, ""
            fields = {}
            key = None
        elif line[0].isspace() and key:
            fields[key] += "\n" + line.strip()
        elif ":" in line:
            if not fields:
                start = lineno
            key, value = line.split(":", 1)
            key = key.lower()
            if key in fields:
                fields["_duplicate"] = "yes"
                if key == "uris":
                    value = fields[key] + " " + value
            fields[key] = value.strip()


def active_entries(path, *, recover=False):
    parser = deb822 if path.suffix == ".sources" else one_line
    text = path.read_text(encoding="utf-8", errors="replace" if recover else "strict")
    for lineno, fields, line in parser(text):
        if (path.suffix == ".sources" and fields and "_duplicate" not in fields
                and fields.get("enabled", "yes").lower() in {"no", "false", "off", "0"}):
            continue
        yield f"{path}:{lineno}", fields, line


def compatible(fields, uri):
    types = fields.get("types", "").split()
    uris = fields.get("uris", "").split()
    suites = fields.get("suites", "").split()
    components = fields.get("components", "").split()
    architectures = set(fields.get("architectures", "").split())
    additions = set(fields.get("architectures-add", "").split())
    removals = set(fields.get("architectures-remove", "").split())
    if ("_duplicate" in fields or types != ["deb"] or len(uris) != 1
            or repository(uris[0]) != uri or suites != ["stable"] or "main" not in components
            or (architectures and "amd64" not in architectures | additions) or "amd64" in removals):
        return False
    url = urlsplit(uris[0])
    if url.scheme != "https" or url.username is not None or url.query or url.fragment:
        return False
    return not any(fields.get(option, "no").lower() not in {"no", "false", "off", "0"}
                   for option in ("trusted", "allow-insecure", "allow-weak", "allow-downgrade-to-insecure"))


def source_plan(main, parts, managed, keyring, archive_url):
    uri = repository(archive_url)
    managed_lines = [f"deb [{arch}signed-by={keyring}] {archive_url} stable main"
                     for arch in ("arch=amd64 ", "")]
    if managed.is_symlink() or (managed.exists() and not managed.is_file()):
        raise ValueError(f"{managed} is not a regular managed file. Resolve it before rerunning.")
    paths = [main] if main.is_file() else []
    if parts.is_dir():
        paths.extend(sorted(p for p in parts.iterdir() if not p.name.startswith(".")
                            and re.fullmatch(r"[A-Za-z0-9_.-]+\.(?:list|sources)", p.name) and p.is_file()))
    external = []
    owned = []
    for path in dict.fromkeys(paths):
        for location, fields, line in active_entries(path, recover=path == managed):
            # An old in-place write could have stopped anywhere in the line.
            if path == managed and any(line != full and full.startswith(line) for full in managed_lines):
                continue
            if fields is None:
                if path == managed:
                    urls = re.findall(r"[a-zA-Z][\w+.-]*://[^\s\]]+", line)
                    if any(repository(url) != uri for url in urls):
                        raise ValueError(f"{location} may contain an unrelated source. Resolve it manually.")
                continue
            matches = sum(repository(value) == uri for value in fields.get("uris", "").split())
            if path == managed:
                if (not compatible(fields, uri) or fields["components"].split() != ["main"]
                        or fields.get("signed-by") != str(keyring)
                        or fields.get("architectures", "amd64") != "amd64"
                        or set(fields) - {"types", "uris", "suites", "components", "signed-by", "architectures"}):
                    raise ValueError(f"{location} contains a custom source definition. Resolve it manually.")
                owned.append(location)
            elif matches:
                external.extend([(location, fields)] * matches)
    if len(external) + len(owned) > 1:
        locations = owned + [location for location, _ in external]
        raise ValueError("Duplicate or conflicting personal APT sources at " + ", ".join(locations))
    if external:
        location, fields = external[0]
        if managed.exists():
            raise ValueError(f"{location} conflicts with the reserved managed file {managed}. Resolve it manually.")
        signed_by = fields.get("signed-by", "").strip()
        if not compatible(fields, uri) or not signed_by:
            raise ValueError(f"{location} conflicts with the HTTPS stable/main archive or lacks scoped Signed-By.")
        print(location)
        print(signed_by)
    else:
        print("managed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate-managed", type=Path)
    parser.add_argument("main", type=Path)
    parser.add_argument("parts", type=Path)
    parser.add_argument("managed", type=Path)
    parser.add_argument("keyring", type=Path)
    parser.add_argument("uri")
    args = parser.parse_args()
    try:
        if args.validate_managed:
            entries = list(active_entries(args.validate_managed))
            if len(entries) == 1:
                _, fields, _ = entries[0]
                if (fields and compatible(fields, repository(args.uri)) and fields["components"] == "main"
                        and fields.get("signed-by") == str(args.keyring)
                        and fields.get("architectures") == "amd64"):
                    return 0
            raise ValueError("The staged managed source is invalid.")
        source_plan(args.main, args.parts, args.managed, args.keyring, args.uri)
    except (OSError, ValueError) as error:
        print(f"Personal APT source: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
