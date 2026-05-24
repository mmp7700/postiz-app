#!/usr/bin/env python3
"""
One-shot migration: transform docker-compose.prod.override.yaml from inline
secrets to ${VAR} substitution syntax, extracting all environment values into
a .env additions file.

Line-based transformation that preserves comments, ordering, and unrelated
sections (ports, volumes, networks, image tags) verbatim. Only YAML scalars
inside an `environment:` block are touched.

Usage:
  ./scripts/migrate_override.py INPUT_YAML OUTPUT_YAML OUTPUT_ENV_ADDITIONS

Reads INPUT_YAML, writes the rewritten override to OUTPUT_YAML and a stream of
KEY="value" lines to OUTPUT_ENV_ADDITIONS for every value extracted.

Idempotent: values that already look like ${VAR} are left alone.

Skipped: empty values, list-style entries (`- KEY=value`), comments.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ENV_BLOCK_RE = re.compile(r"^(?P<indent>\s+)environment:\s*$")
KEY_VALUE_RE = re.compile(
    r"^(?P<indent>\s+)(?P<key>[A-Za-z_][A-Za-z0-9_]*):(?P<sep>\s+)(?P<value>.+?)\s*$"
)
INLINE_COMMENT_RE = re.compile(r"^(?P<value>.+?)(\s+#.*)$")


def is_substitution(value: str) -> bool:
    return value.startswith("${") and value.endswith("}")


def strip_quotes(value: str) -> tuple[str, str]:
    """Return (clean_value, quote_style) where quote_style is "'" or '"' or ""."""
    if len(value) >= 2:
        if value[0] == value[-1] == "'":
            return value[1:-1], "'"
        if value[0] == value[-1] == '"':
            return value[1:-1], '"'
    return value, ""


def env_quote(value: str) -> str:
    """Quote a value for safe inclusion in a .env file."""
    if '"' in value or "\\" in value or "$" in value or "`" in value:
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return f'"{value}"'


def transform(lines: list[str]) -> tuple[list[str], list[tuple[str, str]]]:
    out_lines: list[str] = []
    extracted: list[tuple[str, str]] = []
    in_env = False
    env_indent = -1

    for line in lines:
        raw = line.rstrip("\n")

        # Detect entering an environment: block
        m = ENV_BLOCK_RE.match(raw)
        if m:
            in_env = True
            env_indent = len(m.group("indent"))
            out_lines.append(line)
            continue

        # Detect leaving the environment: block (any non-blank line at <= env_indent)
        if in_env and raw.strip() and not raw.strip().startswith("#"):
            line_indent = len(raw) - len(raw.lstrip())
            if line_indent <= env_indent:
                in_env = False

        if in_env:
            # Skip list-style entries and comments; leave them as-is
            if raw.lstrip().startswith(("-", "#")):
                out_lines.append(line)
                continue

            m = KEY_VALUE_RE.match(raw)
            if m:
                indent = m.group("indent")
                key = m.group("key")
                value = m.group("value")

                # Strip optional inline comment
                cm = INLINE_COMMENT_RE.match(value)
                trailing_comment = ""
                if cm:
                    value = cm.group("value").rstrip()
                    trailing_comment = cm.group(2)

                clean, _quote = strip_quotes(value)

                # Idempotency: already a substitution → leave as-is
                if is_substitution(clean):
                    out_lines.append(line)
                    continue

                # Empty value → leave as-is (likely a placeholder)
                if clean == "":
                    out_lines.append(line)
                    continue

                # Rewrite: KEY: ${KEY}    (+ any prior inline comment)
                new_line = f"{indent}{key}: ${{{key}}}{trailing_comment}\n"
                out_lines.append(new_line)
                extracted.append((key, clean))
                continue

        # Default: passthrough
        out_lines.append(line)

    return out_lines, extracted


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        sys.stderr.write(
            "Usage: migrate_override.py INPUT_YAML OUTPUT_YAML OUTPUT_ENV_ADDITIONS\n"
        )
        return 2

    inp = Path(argv[1])
    out_yaml = Path(argv[2])
    out_env = Path(argv[3])

    if not inp.exists():
        sys.stderr.write(f"input not found: {inp}\n")
        return 1

    text = inp.read_text()
    new_lines, extracted = transform(text.splitlines(keepends=True))

    out_yaml.write_text("".join(new_lines))

    with out_env.open("w") as f:
        f.write("# Extracted from docker-compose.prod.override.yaml on migration.\n")
        f.write("# Merge into .env.prod, dedup against existing keys.\n\n")
        for key, value in extracted:
            f.write(f"{key}={env_quote(value)}\n")

    sys.stderr.write(
        f"Extracted {len(extracted)} env vars.\n"
        f"Wrote: {out_yaml}\n"
        f"Wrote: {out_env}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
