#!/usr/bin/env python3
"""mdtable — edit a markdown table held in a remote document.

Fetch → edit → compare → post back, safely:

    1. GET the document (field-based: description/body/content all work)
    2. transform the markdown table inside it, row by row
    3. in dry-run, print a diff and stop
    4. before posting, re-read the server's `updated` timestamp — if it moved,
       someone edited underneath you; abort instead of clobbering
    5. POST, then re-fetch and verify the server really stored your text

The transport is pluggable: any object with get_field()/post_field() works.
RestDoc is a generic REST adapter for field-oriented document stores — trackers
and knowledge bases that expose a body field at a predictable path. Configure
kind ("issues" or "articles") and field ("description" or "content") and the
path/field pair fits most products of that shape; anything quirkier needs only
a ~30-line adapter class. The editor itself never talks HTTP.

Table transforms are data-driven: pass a dict of {row_key: {column: value}}
and optionally a list of row keys to drop. Row matching is header-driven and
case/space-insensitive ('Branch Project' ≡ 'branch project' ≡ 'branchproject'),
so column names in the transform need not match the document's spelling.

Rows not mentioned in the transform are passed through untouched, byte for
byte — including any trailing per-row annotation cells — so unrelated rows
never drift.
"""

from __future__ import annotations

import difflib
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Markdown table model
# ---------------------------------------------------------------------------

_TABLE_RE = re.compile(r"(\|.*\|\s*)")


def split_table(text: str) -> tuple[list[str], str, list[str]]:
    """Split a document into (before, table, after) around its FIRST markdown
    table. Returns (before, "", original) when no table exists."""
    lines = text.split("\n")
    start = None
    for i, ln in enumerate(lines):
        if ln.lstrip().startswith("|") and ln.rstrip().endswith("|"):
            start = i
            break
    if start is None:
        return lines, "", lines
    end = start
    for j in range(start, len(lines)):
        ln = lines[j]
        if ln.lstrip().startswith("|"):
            end = j
        else:
            break
    before = "\n".join(lines[:start])
    table = "\n".join(lines[start:end + 1])
    after = "\n".join(lines[end + 1:])
    return before, table, after


def parse_header(table: str) -> tuple[list[str], int]:
    """Return (column names, index of the first data row).

    The separator row (---|---) is detected rather than assumed at line 1, so
    tables preceded by a caption or leading blank row still parse.
    """
    lines = [l for l in table.split("\n") if l.strip()]
    if not lines:
        return [], 0
    sep_idx = 0
    for i, ln in enumerate(lines[:3]):
        if re.fullmatch(r"\s*\|?[\s:|-]+\|?\s*", ln):
            sep_idx = i
            break
    header_cells = [c.strip() for c in lines[sep_idx - 1 if sep_idx else 0]
                    .strip().strip("|").split("|")]
    return header_cells, sep_idx + 1


def _key(s: str) -> str:
    """Normalise a column/row name for matching: lowercase, alnum only."""
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def transform_rows(
    table: str,
    updates: dict[str, dict[str, str]],
    drop_rows: list[str] | None = None,
    row_key_column: int = 0,
    add_rows: list[list[str]] | None = None,
) -> str:
    """Apply per-row cell updates / row drops / row additions to a table.

    updates:       {row_key: {column_name: new_value}} — column names match the
                   header case/space-insensitively; unknown columns are an error
    drop_rows:     row keys to delete entirely
    row_key_column: which column identifies a row (default 0, the first)
    add_rows:      raw cell lists appended after the last data row

    Rows absent from `updates` are emitted byte-identically.
    """
    header, first_data = parse_header(table)
    if not header:
        return table
    col_index = {_key(h): i for i, h in enumerate(header)}
    for row_updates in updates.values():
        for col in row_updates:
            if _key(col) not in col_index:
                raise KeyError(f"column {col!r} not in table header {header}")

    lines = table.split("\n")
    out_lines: list[str] = lines[:first_data]
    dropped = set(_key(d) for d in (drop_rows or []))

    for ln in lines[first_data:]:
        if not ln.strip():
            out_lines.append(ln)
            continue
        cells = ln.strip().strip("|").split("|")
        if len(cells) < 2 or not cells[row_key_column].strip():
            out_lines.append(ln)  # not a data row — pass through
            continue
        row_key = _key(cells[row_key_column].strip())

        if row_key in dropped:
            continue
        if row_key in updates:
            for col, val in updates[row_key].items():
                idx = col_index[_key(col)]
                while len(cells) <= idx:
                    cells.append(" ")
                cells[idx] = f" {val} "
            out_lines.append("|" + "|".join(cells) + "|")
        else:
            out_lines.append(ln)  # untouched: byte-identical passthrough

    if add_rows:
        for cells in add_rows:
            out_lines.append("| " + " | ".join(c.strip() for c in cells) + " |")
    return "\n".join(out_lines)


def diff_tables(before: str, after: str) -> str:
    """Unified diff with the boilerplate lines stripped."""
    d = list(difflib.unified_diff(
        before.split("\n"), after.split("\n"), lineterm="", n=0))
    return "\n".join(d[2:])


# ---------------------------------------------------------------------------
# Transport: generic REST adapter
# ---------------------------------------------------------------------------

@dataclass
class RestDoc:
    """Field-oriented document over REST: GET/POST /api/<kind>/<id>.

    kind/field drive both the path and the JSON body key. The canonical pairs
    are ("issues", "description") and ("articles", "content"), which is the
    shape most trackers and knowledge bases expose. Auth is a bearer token.
    """
    base_url: str
    doc_id: str
    token: str
    kind: str = "issues"          # path segment: issues | articles | ...
    field: str = "description"    # body key: description | content | ...
    timeout: int = 120

    def __post_init__(self) -> None:
        self.base_url = self.base_url.rstrip("/")

    def _url(self, suffix: str = "") -> str:
        return f"{self.base_url}/api/{self.kind}/{self.doc_id}{suffix}"

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    def _request(self, req: urllib.request.Request) -> tuple[int, str]:
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    def get_field(self) -> tuple[str, str, int]:
        """Fetch the document. Returns (text, updated_timestamp, http_code)."""
        url = f"{self._url()}?fields={self.field},updated"
        code, body = self._request(urllib.request.Request(url, headers=self._headers()))
        if code != 200:
            return "", "", code
        import json
        try:
            doc = json.loads(body)
        except json.JSONDecodeError:
            return "", "", -1
        return doc.get(self.field) or "", str(doc.get("updated") or ""), 200

    def post_field(self, text: str, updated_guard: str = "") -> tuple[str, int]:
        """Write the whole field back. With `updated_guard`, re-reads the
        server timestamp first and refuses (status 412-style, code 0) when it
        moved — optimistic concurrency without ETags. Returns (error_msg, code):
        ("", 200) on success."""
        if updated_guard:
            _, latest, code = self.get_field()
            if code != 200:
                return "re-read before post failed", code
            if latest != updated_guard:
                return (f"document changed underneath us "
                        f"(server updated={latest}, we fetched {updated_guard}) — aborting", 0)
        import json
        payload = json.dumps({self.field: text}).encode()
        req = urllib.request.Request(
            self._url(), data=payload, headers=self._headers(), method="POST")
        code, body = self._request(req)
        if code != 200:
            return f"post returned HTTP {code}: {body[:300]}", code
        return "", 200


# ---------------------------------------------------------------------------
# Safe edit cycle
# ---------------------------------------------------------------------------

def edit_document(
    transport,
    updates: dict[str, dict[str, str]] | None = None,
    drop_rows: list[str] | None = None,
    add_rows: list[list[str]] | None = None,
    dry_run: bool = False,
    verify_roundtrip: bool = True,
    out=sys.stderr,
) -> tuple[bool, str]:
    """Run the whole fetch → transform → (diff | guarded post → verify) cycle.

    Returns (changed, message). changed=False means nothing was written —
    either no edit was needed, dry-run was requested, or safety tripped.
    """
    text, updated, code = transport.get_field()
    if code != 200:
        return False, f"fetch failed (HTTP {code})"
    if not text.strip():
        return False, "document is empty"

    before, table, after = split_table(text)
    if not table:
        return False, "no markdown table found in document"

    new_table = transform_rows(table, updates or {}, drop_rows, add_rows=add_rows)
    if new_table == table:
        return False, "table already in the requested state — nothing to do"

    new_text = f"{before}\n{new_table}\n{after}".lstrip("\n")

    print(diff_tables(table, new_table), file=out)
    if dry_run:
        return False, "dry-run: no changes posted"

    err, code = transport.post_field(new_text, updated_guard=updated)
    if err:
        return False, err

    if verify_roundtrip:
        stored, _, rc = transport.get_field()
        if rc == 200 and stored.strip() != new_text.strip():
            return False, "posted, but server content does not match what we sent"
    return True, "posted and verified"


if __name__ == "__main__":  # pragma: no cover
    print(__doc__)
