#!/usr/bin/env python3
"""
Shared store-lookup util — confirm iOS/Android app identifiers against the LIVE
public stores. Reused by:
  * ctweb_check_proto.py  — batch iTunes lookup by store-id (validate cTWeb config)
  * ibundle / _mut_app_id_fields — single lookup by bundleId (release pre-flight)

iOS: Apple iTunes Lookup API (official, no key). It batches — comma-separated
`id=` — and can also be queried `bundleId=`. Apps are frequently
"region-locked" (e.g. published everywhere *except* the US), so one storefront
is not enough; several markets are queried
broad ex-US markets (gb, de, au) and fall back per-country for region-locked apps.
Android: Play-Store existence via the reusable app_availability_proto.zsh probe.

Soft by design: any network/rate-limit error is swallowed and the id is reported
as "unresolved" (couldn't check) — callers decide whether that blocks. Never
raises on lookup failure.

CLI:
  store_lookup.py --itunes-ids 123456789,987654321      # -> storeId<TAB>bundleId
  # -> 0=taken(+info) 3=available 4=unknown           # exit 0=taken(+info) 3=available 4=unknown
  store_lookup.py --play com.example.app,com.example.other            # -> pkg<TAB>exists|absent
"""
import os, sys, json, subprocess, urllib.request, urllib.parse

ITUNES = "https://itunes.apple.com/lookup"
# Markets that between them cover most region-locked apps; order = cheapest first.
DEFAULT_COUNTRIES = ("gb", "de", "au")


def _get_json(url):
    """GET + parse JSON; return None on ANY failure (network / rate-limit / parse)."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        return json.loads(urllib.request.urlopen(req, timeout=20).read().decode("utf-8", "replace"))
    except Exception:
        return None


def itunes_lookup_ids(store_ids, countries=DEFAULT_COUNTRIES):
    """Batch-resolve numeric App Store ids -> bundleId. Returns (found, unresolved):
    found = {storeId: bundleId}, unresolved = [storeId, ...] (not in any market /
    couldn't check). One call per country over the still-unresolved set."""
    ids = [s for s in dict.fromkeys(str(x).strip() for x in store_ids) if s.isdigit()]
    found, remaining = {}, list(ids)
    for c in countries:
        if not remaining:
            break
        data = _get_json(f"{ITUNES}?id={','.join(remaining)}&country={c}&entity=software")
        if not data:
            continue  # this country failed/limited — try the next; ids stay unresolved
        for r in data.get("results", []):
            tid, bid = str(r.get("trackId") or ""), r.get("bundleId")
            if tid and bid:
                found[tid] = bid
        remaining = [s for s in remaining if s not in found]
    return found, remaining


def itunes_lookup_bundle(bundle_id, countries=("us", "gb", "de", "au")):
    """Is `bundle_id` already a PUBLISHED App Store app? -> (status, info):
      ("taken", {bundleId,name,storeId}) — a live app already uses it (can't reuse),
      ("available", None)               — not published in any queried market,
      ("unknown", None)                 — every query failed (couldn't check).
    NB: 'available' only rules out *published* apps; a reserved-but-unpublished App
    ID isn't visible via iTunes. Queries include US since a colliding app can be
    anywhere. Distinguishing 'available' from 'unknown' lets the caller hard-error
    on TAKEN but stay soft when it merely couldn't reach the store."""
    bl = (bundle_id or "").strip()
    if not bl:
        return ("unknown", None)
    q = urllib.parse.quote(bl)
    any_ok = False
    for c in countries:
        data = _get_json(f"{ITUNES}?bundleId={q}&country={c}&entity=software")
        if data is None:
            continue
        any_ok = True
        for r in data.get("results", []):
            if (r.get("bundleId") or "").lower() == bl.lower():
                return ("taken", {"bundleId": r["bundleId"], "name": r.get("trackName"),
                                  "storeId": str(r.get("trackId") or "")})
    return ("available", None) if any_ok else ("unknown", None)


def play_exists(packages, here=None):
    """Android: which of `packages` are live on Google Play. Reuses the scaled
    parallel probe app_availability_proto.zsh --packages. Returns a set (empty on
    any failure — soft)."""
    pkgs = sorted({p.strip() for p in packages if (p or "").strip()})
    if not pkgs:
        return set()
    here = here or os.path.dirname(os.path.abspath(__file__))
    helper = os.path.join(here, "app_availability_proto.zsh")
    if not os.path.isfile(helper):
        return set()
    try:
        out = subprocess.run(["zsh", helper, "--packages", *pkgs],
                             capture_output=True, text=True, timeout=180)
    except Exception:
        return set()
    return {ln.split("\t")[0] for ln in out.stdout.splitlines() if ln.endswith("\texists")}


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--itunes-ids":
        found, unresolved = itunes_lookup_ids(a[1].split(","))
        for sid, bid in found.items():
            print(f"{sid}\t{bid}")
        for sid in unresolved:
            print(f"{sid}\t", file=sys.stderr)
    elif len(a) == 2 and a[0] == "--itunes-bundle":
        # exit: 0 = taken (prints bundleId<TAB>name<TAB>storeId) · 3 = available
        #       (not a published app) · 4 = unknown (couldn't check).
        status, info = itunes_lookup_bundle(a[1])
        if status == "taken":
            print(f"{info['bundleId']}\t{info['name']}\t{info['storeId']}")
            sys.exit(0)
        sys.exit(3 if status == "available" else 4)
    elif len(a) == 2 and a[0] == "--play":
        ex = play_exists(a[1].split(","))
        for p in a[1].split(","):
            print(f"{p.strip()}\t{'exists' if p.strip() in ex else 'absent'}")
    else:
        sys.exit("usage: store_lookup.py --itunes-ids <csv> | --itunes-bundle <id> | --play <csv>")


if __name__ == "__main__":
    main()
