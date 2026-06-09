#!/usr/bin/env python3
"""
build_catalog.py — TCGdex (https://tcgdex.dev) -> catalog.sqlite for Binder Builder.

Pulls every English set + card from api.tcgdex.net, downloads low-res card
images, computes 64-bit dHash + pHash at 4 orientations, and writes the
bundled read-only catalog database (schema v1, fixed contract with the app).

All raw API JSON and downloaded images are mirrored under tools/cache/ so
re-runs are incremental/resumable (cached entries are skipped).

Usage:
  .venv/bin/python build_catalog.py                       # full build
  .venv/bin/python build_catalog.py --sets base1,base2    # subset build
  .venv/bin/python build_catalog.py --refresh-prices-only # re-fetch card JSON
  .venv/bin/python build_catalog.py --skip-images         # no images/hashes

Deps (tools/.venv): requests, Pillow, imagehash.
"""

import argparse
import concurrent.futures
import datetime
import io
import json
import os
import re
import sqlite3
import sys
import threading
import time

import requests

API_BASE = "https://api.tcgdex.net/v2/en"
ASSETS_PREFIX = "https://assets.tcgdex.net/"

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOLS_DIR)
CACHE_DIR = os.path.join(TOOLS_DIR, "cache")
SETS_CACHE = os.path.join(CACHE_DIR, "sets")
CARDS_CACHE = os.path.join(CACHE_DIR, "cards")
IMAGES_CACHE = os.path.join(CACHE_DIR, "images")
PROGRESS_FILE = os.path.join(CACHE_DIR, "progress.txt")

DEFAULT_OUT = os.path.join(REPO_ROOT, "binderBuilder", "Resources", "catalog.sqlite")

WORKERS = 12
MIN_CARD_COUNT = 15000  # hard-fail threshold for full builds
RETRIES = 6
TIMEOUT = 30

# tcgplayer pricing key -> CardVariant raw value
TCGPLAYER_VARIANT_MAP = {
    "normal": "normal",
    "holofoil": "holo",
    "reverse-holofoil": "reverse",
    "1st-edition": "firstEdition",
    "1st-edition-holofoil": "firstEdition",  # tolerated alias; OR IGNORE on PK clash
    "1st-edition-normal": "firstEdition",
}

SCHEMA = """
CREATE TABLE set_info (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  series_id TEXT, series_name TEXT,
  card_count_official INTEGER, card_count_total INTEGER,
  release_date TEXT, symbol_url TEXT, logo_url TEXT
);
CREATE TABLE card (
  id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES set_info(id),
  name TEXT NOT NULL, local_number TEXT NOT NULL, sort_number INTEGER,
  category TEXT, rarity TEXT, types TEXT, hp INTEGER, illustrator TEXT,
  image_base TEXT,
  has_normal INTEGER NOT NULL DEFAULT 0, has_holo INTEGER NOT NULL DEFAULT 0,
  has_reverse INTEGER NOT NULL DEFAULT 0, has_first_edition INTEGER NOT NULL DEFAULT 0,
  regulation_mark TEXT
);
CREATE INDEX idx_card_set ON card(set_id, sort_number);
CREATE INDEX idx_card_name ON card(name COLLATE NOCASE);
CREATE VIRTUAL TABLE card_fts USING fts5(
  card_id UNINDEXED, name, set_name, local_number,
  tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
);
CREATE TABLE price_snapshot (
  card_id TEXT NOT NULL REFERENCES card(id),
  source TEXT NOT NULL, variant TEXT NOT NULL, currency TEXT NOT NULL,
  market REAL, low REAL, mid REAL, high REAL, updated_at TEXT,
  PRIMARY KEY (card_id, source, variant)
);
CREATE TABLE card_hash (
  card_id TEXT NOT NULL REFERENCES card(id),
  orientation INTEGER NOT NULL,
  dhash BLOB NOT NULL,
  phash BLOB NOT NULL,
  PRIMARY KEY (card_id, orientation)
);
CREATE TABLE catalog_meta (key TEXT PRIMARY KEY, value TEXT);
"""

_print_lock = threading.Lock()
_session_local = threading.local()


def log(msg):
    with _print_lock:
        print(msg, flush=True)


def write_progress(text):
    try:
        with open(PROGRESS_FILE, "w") as f:
            f.write(text + "\n")
    except OSError:
        pass


def session():
    s = getattr(_session_local, "s", None)
    if s is None:
        s = requests.Session()
        s.headers["User-Agent"] = "binderBuilder-catalog-tool/1.0"
        _session_local.s = s
    return s


def fetch(url, binary=False):
    """GET with retry + exponential backoff. Returns bytes or parsed JSON.
    Returns None for a definitive 404. Raises after exhausting retries."""
    last_err = None
    for attempt in range(RETRIES):
        try:
            r = session().get(url, timeout=TIMEOUT)
            if r.status_code == 404:
                return None
            if r.status_code in (429, 500, 502, 503, 504):
                raise requests.HTTPError(f"HTTP {r.status_code}")
            r.raise_for_status()
            return r.content if binary else r.json()
        except (requests.RequestException, ValueError) as e:
            last_err = e
            sleep = min(60, 2 ** attempt) + 0.25 * attempt
            time.sleep(sleep)
    raise RuntimeError(f"giving up on {url}: {last_err}")


def cached_json(cache_path, url, force=False):
    """Fetch JSON through the raw-mirror cache. None is cached as 'null'."""
    if not force and os.path.exists(cache_path):
        try:
            with open(cache_path) as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass  # corrupt cache entry -> refetch
    data = fetch(url)
    tmp = cache_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, cache_path)
    return data


# ---------------------------------------------------------------- fetching

def fetch_set_list():
    """Sets index. Always tries the network (it's one small request), falls
    back to the cached copy if the API is down."""
    cache_path = os.path.join(CACHE_DIR, "sets_index.json")
    try:
        data = fetch(f"{API_BASE}/sets")
        with open(cache_path, "w") as f:
            json.dump(data, f)
        return data
    except RuntimeError:
        if os.path.exists(cache_path):
            log("WARN: /sets unreachable, using cached sets index")
            with open(cache_path) as f:
                return json.load(f)
        raise


def fetch_set_details(set_ids):
    done = [0]
    lock = threading.Lock()
    total = len(set_ids)
    results = {}

    def work(sid):
        data = cached_json(os.path.join(SETS_CACHE, f"{sid}.json"),
                           f"{API_BASE}/sets/{sid}")
        with lock:
            done[0] += 1
            n = done[0]
        if n % 10 == 0 or n == total:
            log(f"set {n}/{total}")
            write_progress(f"phase=sets set {n}/{total}")
        return sid, data

    with concurrent.futures.ThreadPoolExecutor(WORKERS) as ex:
        for sid, data in ex.map(work, set_ids):
            if data is None:
                log(f"WARN: set {sid} returned 404, skipping")
            else:
                results[sid] = data
    return results


def fetch_card_details(card_ids, force=False):
    done = [0]
    failed = []
    lock = threading.Lock()
    total = len(card_ids)
    results = {}

    def work(cid):
        try:
            data = cached_json(os.path.join(CARDS_CACHE, f"{cid}.json"),
                               f"{API_BASE}/cards/{cid}", force=force)
        except RuntimeError as e:
            log(f"WARN: card {cid} fetch failed: {e}")
            data = "FAILED"
        with lock:
            done[0] += 1
            n = done[0]
        if n % 100 == 0 or n == total:
            log(f"cards {n}/{total}")
            write_progress(f"phase=cards cards {n}/{total}")
        return cid, data

    with concurrent.futures.ThreadPoolExecutor(WORKERS) as ex:
        for cid, data in ex.map(work, card_ids):
            if data == "FAILED":
                failed.append(cid)
            elif data is None:
                log(f"WARN: card {cid} returned 404")
            else:
                results[cid] = data
    return results, failed


# ---------------------------------------------------------------- images / hashes

def image_base_of(image_url):
    """'https://assets.tcgdex.net/en/base/base1/4' -> 'en/base/base1/4'."""
    if not image_url or not isinstance(image_url, str):
        return None
    if image_url.startswith(ASSETS_PREFIX):
        return image_url[len(ASSETS_PREFIX):].strip("/") or None
    return None


def compute_hashes_for_card(cid, image_base, allow_download=True):
    """Returns list of (card_id, orientation, dhash8bytes, phash8bytes) or []."""
    from PIL import Image
    import imagehash
    import numpy as np

    img_path = os.path.join(IMAGES_CACHE, f"{cid}.webp")
    if not os.path.exists(img_path) or os.path.getsize(img_path) == 0:
        if not allow_download:
            return []
        url = f"{ASSETS_PREFIX}{image_base}/low.webp"
        data = fetch(url, binary=True)
        if data is None:
            log(f"WARN: image 404 for {cid} ({url})")
            return []
        tmp = img_path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, img_path)

    try:
        with open(img_path, "rb") as f:
            raw = f.read()
        img = Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception as e:
        log(f"WARN: undecodable image for {cid}: {e}")
        try:
            os.remove(img_path)  # poison entry; refetch next run
        except OSError:
            pass
        return []

    rows = []
    for orientation in (0, 90, 180, 270):
        rotated = img if orientation == 0 else img.rotate(-orientation, expand=True)
        dh = imagehash.dhash(rotated, hash_size=8)
        ph = imagehash.phash(rotated, hash_size=8)
        rows.append((cid, orientation,
                     np.packbits(dh.hash.flatten()).tobytes(),
                     np.packbits(ph.hash.flatten()).tobytes()))
    return rows


def compute_all_hashes(cards_with_images, allow_download=True):
    """cards_with_images: list of (card_id, image_base). Returns hash rows."""
    done = [0]
    lock = threading.Lock()
    total = len(cards_with_images)
    all_rows = []

    def work(item):
        cid, base = item
        try:
            rows = compute_hashes_for_card(cid, base, allow_download)
        except Exception as e:
            log(f"WARN: hash failed for {cid}: {e}")
            rows = []
        with lock:
            done[0] += 1
            n = done[0]
        if n % 100 == 0 or n == total:
            log(f"images {n}/{total}")
            write_progress(f"phase=images images {n}/{total}")
        return rows

    with concurrent.futures.ThreadPoolExecutor(WORKERS) as ex:
        for rows in ex.map(work, cards_with_images):
            all_rows.extend(rows)
    return all_rows


# ---------------------------------------------------------------- normalization

def sort_number_of(local_id):
    """int(leading digits): '4' -> 4, '4a' -> 4; none ('TG12') -> 9999."""
    if local_id is None:
        return 9999
    m = re.match(r"\s*(\d+)", str(local_id))
    return int(m.group(1)) if m else 9999


def as_float(v):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return float(v)
    return None


def first_float(*vals):
    for v in vals:
        f = as_float(v)
        if f is not None:
            return f
    return None


def price_rows_of(cid, pricing):
    """Tolerant extraction of price_snapshot rows from a card's 'pricing'."""
    rows = []
    if not isinstance(pricing, dict):
        return rows

    tp = pricing.get("tcgplayer")
    if isinstance(tp, dict):
        updated = tp.get("updated") if isinstance(tp.get("updated"), str) else None
        for key, val in tp.items():
            if not isinstance(val, dict):
                continue
            variant = TCGPLAYER_VARIANT_MAP.get(key)
            if variant is None:
                continue  # unknown variant bucket (e.g. 'unlimited') — skip
            rows.append((cid, "tcgplayer", variant, "USD",
                         as_float(val.get("marketPrice")),
                         as_float(val.get("lowPrice")),
                         as_float(val.get("midPrice")),
                         as_float(val.get("highPrice")),
                         updated))

    cm = pricing.get("cardmarket")
    if isinstance(cm, dict):
        market = first_float(cm.get("trendPrice"), cm.get("trend"),
                             cm.get("avg30"), cm.get("avg"))
        low = first_float(cm.get("lowPrice"), cm.get("low"))
        if market is not None or low is not None:
            updated = cm.get("updated") if isinstance(cm.get("updated"), str) else None
            rows.append((cid, "cardmarket", "normal", "EUR",
                         market, low, None, None, updated))
    return rows


def card_row_of(cid, set_id, brief, detail):
    """Build the card table row. detail may be None (fetch failed) — fall back
    to the set-detail brief."""
    d = detail if isinstance(detail, dict) else {}
    b = brief if isinstance(brief, dict) else {}
    name = d.get("name") or b.get("name") or cid
    local_id = d.get("localId") or b.get("localId") or cid.rsplit("-", 1)[-1]
    variants = d.get("variants") if isinstance(d.get("variants"), dict) else {}
    types = d.get("types")
    types_txt = ",".join(types) if isinstance(types, list) and types else None
    hp = d.get("hp")
    if not isinstance(hp, int) or isinstance(hp, bool):
        hp = None
    image_base = image_base_of(d.get("image") or b.get("image"))
    return (
        cid, set_id, str(name), str(local_id), sort_number_of(local_id),
        d.get("category"), d.get("rarity"), types_txt, hp, d.get("illustrator"),
        image_base,
        1 if variants.get("normal") else 0,
        1 if variants.get("holo") else 0,
        1 if variants.get("reverse") else 0,
        1 if variants.get("firstEdition") else 0,
        d.get("regulationMark"),
    )


def set_row_of(sid, detail):
    d = detail if isinstance(detail, dict) else {}
    serie = d.get("serie") if isinstance(d.get("serie"), dict) else {}
    counts = d.get("cardCount") if isinstance(d.get("cardCount"), dict) else {}
    return (
        sid, str(d.get("name") or sid),
        serie.get("id"), serie.get("name"),
        counts.get("official"), counts.get("total"),
        d.get("releaseDate"), d.get("symbol"), d.get("logo"),
    )


# ---------------------------------------------------------------- db build

def build_db(out_path, set_rows, card_rows, fts_rows, price_rows, hash_rows):
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    if os.path.exists(out_path):
        os.remove(out_path)
    for suffix in ("-wal", "-shm", "-journal"):
        p = out_path + suffix
        if os.path.exists(p):
            os.remove(p)

    conn = sqlite3.connect(out_path)
    try:
        conn.executescript(SCHEMA)
        conn.executemany(
            "INSERT INTO set_info VALUES (?,?,?,?,?,?,?,?,?)", set_rows)
        conn.executemany(
            "INSERT INTO card VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", card_rows)
        conn.executemany(
            "INSERT INTO card_fts (card_id, name, set_name, local_number) "
            "VALUES (?,?,?,?)", fts_rows)
        conn.executemany(
            "INSERT OR IGNORE INTO price_snapshot VALUES (?,?,?,?,?,?,?,?,?)",
            price_rows)
        conn.executemany(
            "INSERT OR IGNORE INTO card_hash VALUES (?,?,?,?)", hash_rows)

        meta = {
            "schema_version": "1",
            "build_date": datetime.datetime.now(datetime.timezone.utc)
                .isoformat(timespec="seconds").replace("+00:00", "Z"),
            "card_count": str(len(card_rows)),
            "set_count": str(len(set_rows)),
        }
        conn.executemany("INSERT INTO catalog_meta VALUES (?,?)", meta.items())
        conn.commit()
        conn.execute("PRAGMA journal_mode=DELETE")
        conn.execute("VACUUM")
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT,
                    help=f"output sqlite path (default {DEFAULT_OUT})")
    ap.add_argument("--sets", default=None,
                    help="comma-separated set ids for a subset build (e.g. base1,base2)")
    ap.add_argument("--refresh-prices-only", action="store_true",
                    help="force re-fetch of all card detail JSON (fresh pricing); "
                         "images are reused from cache, never re-downloaded")
    ap.add_argument("--skip-images", action="store_true",
                    help="skip image download + hashing (card_hash will be empty)")
    args = ap.parse_args()

    for d in (CACHE_DIR, SETS_CACHE, CARDS_CACHE, IMAGES_CACHE):
        os.makedirs(d, exist_ok=True)

    t0 = time.time()
    write_progress("phase=start")

    # 1. set list
    set_list = fetch_set_list()
    all_set_ids = [s["id"] for s in set_list if isinstance(s, dict) and s.get("id")]
    if args.sets:
        wanted = [s.strip() for s in args.sets.split(",") if s.strip()]
        unknown = [s for s in wanted if s not in all_set_ids]
        for s in unknown:
            log(f"WARN: requested set '{s}' not in /sets index (trying anyway)")
        set_ids = wanted
    else:
        set_ids = all_set_ids
    log(f"sets to process: {len(set_ids)}")

    # 2. set details (-> card briefs)
    set_details = fetch_set_details(set_ids)

    set_rows = []
    briefs = {}          # card_id -> brief dict
    card_set = {}        # card_id -> set_id
    set_names = {}       # set_id -> set name
    for sid in set_ids:
        detail = set_details.get(sid)
        if detail is None:
            continue
        set_rows.append(set_row_of(sid, detail))
        set_names[sid] = set_rows[-1][1]
        for brief in detail.get("cards") or []:
            cid = brief.get("id") if isinstance(brief, dict) else None
            if not cid:
                continue
            briefs[cid] = brief
            card_set[cid] = sid

    card_ids = sorted(briefs.keys())
    log(f"total card briefs: {len(card_ids)}")
    write_progress(f"phase=cards cards 0/{len(card_ids)}")

    # 3. card details
    details, failed = fetch_card_details(card_ids, force=args.refresh_prices_only)
    if failed:
        log(f"WARN: {len(failed)} cards failed to fetch (using brief fallback): "
            f"{failed[:20]}{'...' if len(failed) > 20 else ''}")

    # 4. normalize rows
    card_rows, fts_rows, price_rows = [], [], []
    for cid in card_ids:
        detail = details.get(cid)
        try:
            row = card_row_of(cid, card_set[cid], briefs[cid], detail)
        except Exception as e:
            log(f"WARN: normalize failed for {cid}: {e} — minimal row")
            row = (cid, card_set[cid], cid, cid.rsplit("-", 1)[-1], 9999,
                   None, None, None, None, None, None, 1, 0, 0, 0, None)
        card_rows.append(row)
        fts_rows.append((cid, row[2], set_names.get(card_set[cid], ""), row[3]))
        if isinstance(detail, dict):
            try:
                price_rows.extend(price_rows_of(cid, detail.get("pricing")))
            except Exception as e:
                log(f"WARN: pricing parse failed for {cid}: {e}")

    # 5. images + hashes
    hash_rows = []
    if not args.skip_images:
        with_images = [(r[0], r[10]) for r in card_rows if r[10]]
        log(f"cards with images: {len(with_images)}")
        hash_rows = compute_all_hashes(
            with_images, allow_download=not args.refresh_prices_only)

    # 6. write db
    write_progress("phase=db")
    log(f"writing {args.out} — {len(set_rows)} sets, {len(card_rows)} cards, "
        f"{len(price_rows)} price rows, {len(hash_rows)} hash rows")
    build_db(args.out, set_rows, card_rows, fts_rows, price_rows, hash_rows)

    size_mb = os.path.getsize(args.out) / 1e6
    elapsed = time.time() - t0
    log(f"done in {elapsed:.0f}s — {args.out} ({size_mb:.1f} MB)")
    write_progress(f"phase=done cards={len(card_rows)} sets={len(set_rows)} "
                   f"prices={len(price_rows)} hashes={len(hash_rows)} "
                   f"size_mb={size_mb:.1f} elapsed_s={elapsed:.0f}")

    # 7. sanity gate (full builds only)
    if not args.sets and len(card_rows) < MIN_CARD_COUNT:
        log(f"FATAL: only {len(card_rows)} cards (< {MIN_CARD_COUNT}) — "
            f"refusing to ship this catalog")
        sys.exit(1)


if __name__ == "__main__":
    main()
