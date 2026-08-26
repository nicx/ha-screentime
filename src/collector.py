#!/usr/bin/env python3
"""
Apple Screen Time Exporter - Collector
Collects screen time data from Mac (knowledgeC.db) and iPhone (Biome)
"""

import csv
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from dotenv import load_dotenv

from config import APP_MAP, TITLE_NORMALIZE, normalize_title

# Load .env from parent directory
load_dotenv(Path(__file__).parent.parent / ".env")

# --- CONFIGURATION ---
SCRIPT_DIR = Path(__file__).parent.parent

# Datenverzeichnis und aw-import-screentime-Binary sind überschreibbar, damit
# derselbe Code sowohl standalone (Entwicklung) als auch aus dem App-Bundle
# heraus läuft (dort: gebündelte Runtime + Datenverzeichnis im Benutzer-Home).
DATA_DIR = Path(os.getenv("SCREENTIME_DATA_DIR") or (SCRIPT_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

OUTPUT_CSV = DATA_DIR / "screentime.csv"
LAST_TIMESTAMP_FILE = DATA_DIR / "screentime.csv.last"
AW_BIN = Path(
    os.getenv("SCREENTIME_AW_BIN")
    or (SCRIPT_DIR / "aw-import-screentime" / ".venv" / "bin" / "aw-import-screentime")
)

# Diagnose des Laufs. Landet in diagnostics.json und von dort als Attribute an
# sensor.screentime_diagnose -- der Sammel-Benutzer hat ein eigenes Home, in das
# von aussen niemand hineinsieht, und ohne diese Bruecke ist bei einer stummen
# Stoerung nicht feststellbar, WARUM nichts ankommt.
DIAG = {"sync_db": None, "devices_seen": [], "devices": {}, "hard_error": False}
DIAG_FILE = DATA_DIR / "diagnostics.json"


def list_sync_db_devices() -> list[dict]:
    """Alle Geraete, die Biome aktuell kennt -- zum Abgleich mit der Konfiguration."""
    try:
        uri = f"file:{SYNC_DB.as_posix()}?mode=ro&immutable=1"
        with sqlite3.connect(uri, uri=True) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                """SELECT device_identifier, me, platform, model,
                          datetime(last_sync_date,'unixepoch','localtime') AS last_sync
                   FROM DevicePeer ORDER BY platform;"""
            ).fetchall()
        DIAG["sync_db"] = "ok"
        return [dict(r) for r in rows]
    except Exception as e:
        # Haeufigster Fall: fehlender Festplattenvollzugriff.
        DIAG["sync_db"] = f"nicht lesbar: {e}"
        DIAG["hard_error"] = True
        return []


def write_diagnostics() -> None:
    try:
        DIAG["written_at"] = datetime.now().astimezone().isoformat()
        DIAG_FILE.write_text(json.dumps(DIAG, ensure_ascii=False, indent=2))
    except Exception as e:
        print(f"[Diag] konnte {DIAG_FILE} nicht schreiben: {e}")

# Mac knowledgeC.db - the official Screen Time database
KNOWLEDGE_DB = Path.home() / "Library" / "Application Support" / "Knowledge" / "knowledgeC.db"

# Biome sync database - maps device IDs to their platform code
SYNC_DB = Path.home() / "Library" / "Biome" / "sync" / "sync.db"

# Mac-Nutzung mitzählen? Hier läuft der Sammel-Account (Mac mini), dessen
# "Nutzung" nur aus Wartungs-Sessions besteht -> würde die Werte verfälschen.
COLLECT_MAC = os.getenv("COLLECT_MAC", "false").strip().lower() in ("1", "true", "yes")

# Apple Epoch offset (seconds between 1970-01-01 and 2001-01-01)
APPLE_EPOCH_OFFSET = 978307200


def parse_devices() -> list[tuple[str, str]]:
    """
    Parses device configuration from .env.
    Returns: List of (device_name, device_id) tuples
    """
    devices_str = os.getenv("DEVICES", "")
    if devices_str:
        # Format: "Name1:UUID1,Name2:UUID2"
        devices = []
        for entry in devices_str.split(","):
            entry = entry.strip()
            if ":" in entry:
                name, uuid = entry.split(":", 1)
                devices.append((name.strip(), uuid.strip()))
        return devices

    # Fallback: Legacy DEVICE_ID
    device_id = os.getenv("DEVICE_ID", "")
    if device_id:
        return [("iPhone", device_id)]

    return []


def get_app_title(bundle_id):
    """Returns a display name for the app with intelligent fallback."""
    # 1. Exaktes Mapping
    if bundle_id in APP_MAP:
        return APP_MAP[bundle_id]

    # 2. Fallback: Take last part of bundle ID and format it
    if "." in bundle_id:
        name = bundle_id.split(".")[-1]
        # CamelCase to spaces: "MobileSMS" -> "Mobile SMS"
        name = re.sub(r'([a-z])([A-Z])', r'\1 \2', name)
        # Capitalize first letters
        name = name.title()
        return name

    return bundle_id

def get_last_timestamp():
    """Reads the last extraction timestamp from a separate file."""
    if LAST_TIMESTAMP_FILE.exists():
        try:
            with open(LAST_TIMESTAMP_FILE, "r") as f:
                return float(f.read().strip())
        except:
            pass
    return 0.0

def save_last_timestamp(ts):
    """Saves the last extraction timestamp."""
    with open(LAST_TIMESTAMP_FILE, "w") as f:
        f.write(str(ts))

def get_mac_data(last_created_at):
    """Extracts Mac Screen Time from knowledgeC.db."""
    if not KNOWLEDGE_DB.exists():
        print(f"[Mac] knowledgeC.db not found: {KNOWLEDGE_DB}")
        return []

    if not os.access(KNOWLEDGE_DB, os.R_OK):
        print("[Mac] knowledgeC.db not readable. Terminal needs Full Disk Access.")
        return []

    print(f"[{datetime.now().strftime('%H:%M:%S')}] Extracting Mac data...")

    query = """
    SELECT
        ZOBJECT.ZVALUESTRING AS "app",
        (ZOBJECT.ZENDDATE - ZOBJECT.ZSTARTDATE) AS "usage",
        (ZOBJECT.ZSTARTDATE + 978307200) as "start_time",
        (ZOBJECT.ZENDDATE + 978307200) as "end_time",
        (ZOBJECT.ZCREATIONDATE + 978307200) as "created_at"
    FROM ZOBJECT
    WHERE
        ZSTREAMNAME = "/app/usage" AND
        (ZOBJECT.ZCREATIONDATE + 978307200) > ?
    ORDER BY ZSTARTDATE ASC
    """

    try:
        with sqlite3.connect(f"file:{KNOWLEDGE_DB}?mode=ro", uri=True) as conn:
            cursor = conn.cursor()
            cursor.execute(query, (last_created_at,))
            rows = cursor.fetchall()

            events = []
            for row in rows:
                app, usage, start_time, end_time, created_at = row
                if not app or usage is None:
                    continue

                ts_iso = datetime.fromtimestamp(start_time).astimezone().isoformat()
                title = get_app_title(app)

                events.append({
                    "timestamp": ts_iso,
                    "app": app,
                    "title": title,
                    "duration": round(usage, 2),
                    "source": "Mac",
                    "_created_at": created_at
                })

            print(f"[Mac] {len(events)} new entries found")
            return events
    except Exception as e:
        print(f"[Mac] Error: {e}")
        return []

def get_device_platform(device_id: str) -> int:
    """
    Looks up the Biome platform code for a device (2=iPhone, 1=iPad, 3=Mac, ...).

    aw-import-screentime filters by platform (default 2), so an iPad (platform 1)
    would silently return no events if we don't pass the correct one.
    """
    try:
        uri = f"file:{SYNC_DB.as_posix()}?mode=ro&immutable=1"
        with sqlite3.connect(uri, uri=True) as conn:
            row = conn.execute(
                "SELECT platform FROM DevicePeer WHERE device_identifier = ?;",
                (device_id,),
            ).fetchone()
        if row and row[0] is not None:
            return int(row[0])
    except Exception as e:
        print(f"[WARN] Could not determine platform for {device_id}: {e}")
    return 2  # sensible default: iPhone


def get_mobile_data(device_name, device_id, last_created_at):
    """Extracts mobile Screen Time via aw-import-screentime."""
    d = DIAG["devices"].setdefault(device_name, {"device_id": device_id})

    if not device_id:
        print(f"[{device_name}] Device ID not set - skipping")
        d["status"] = "keine Geraete-ID konfiguriert"
        return []

    if not AW_BIN.exists():
        print(f"[{device_name}] aw-import-screentime not found: {AW_BIN}")
        d["status"] = f"aw-import-screentime fehlt: {AW_BIN}"
        DIAG["hard_error"] = True
        return []

    platform = get_device_platform(device_id)
    d["platform"] = platform
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Extracting {device_name} data (platform {platform})...")

    # Always query 28 days, deduplication happens via created_at
    cmd = [str(AW_BIN), "events", "preview", "--device", device_id,
           "--platform", str(platform), "--since", "28d"]

    try:
        # Bewusst ohne check=True: ein Fehlschlag soll als solcher erkennbar
        # bleiben und nicht als "0 Ereignisse" durchgehen.
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        d["returncode"] = result.returncode
        if result.returncode != 0:
            err = (result.stderr or "").strip().splitlines()
            d["status"] = "aw-import-screentime fehlgeschlagen"
            d["stderr"] = err[-3:] if err else []
            DIAG["hard_error"] = True
            print(f"[{device_name}] FEHLER: aw-import-screentime endete mit {result.returncode}")
            for line in d["stderr"]:
                print(f"    {line}")
            return []

        data = json.loads(result.stdout or "[]")
        events = []
        total_seen = 0

        for entry in data:
            for event in entry.get("events", []):
                total_seen += 1
                ts = event["timestamp"]
                duration = event.get("duration_seconds", 0)

                try:
                    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    created_at = dt.timestamp() + duration
                    if created_at <= last_created_at:
                        continue
                except Exception:
                    continue

                bundle_id = event["data"].get("app", "unknown")
                title = event["data"].get("title", "unknown")
                if title == "unknown" or not title:
                    title = APP_MAP.get(bundle_id, bundle_id.split(".")[-1])
                title = normalize_title(title)

                events.append({
                    "timestamp": ts,
                    "app": bundle_id,
                    "title": title,
                    "duration": round(duration, 2),
                    "source": device_name,
                    "_created_at": created_at,
                })

        # Zwischen "liefert gar nichts" und "nichts NEUES" unterscheiden: nur
        # Ersteres deutet auf eine Stoerung (falsche Geraete-ID, Sync steht).
        d["events_total_28d"] = total_seen
        d["events_new"] = len(events)
        d["status"] = "ok" if total_seen else "Biome liefert fuer diese Geraete-ID keine Ereignisse"
        print(f"[{device_name}] {len(events)} new entries found ({total_seen} in 28 Tagen)")
        return events

    except Exception as e:
        print(f"[{device_name}] Error: {e}")
        d["status"] = f"Ausnahme: {e}"
        DIAG["hard_error"] = True
        return []


def save_to_csv(events):
    if not events:
        print("\nNo new data since last run.")
        return

    # Remove internal _created_at fields before writing
    max_created_at = max(ev.get("_created_at", 0) for ev in events)
    for ev in events:
        ev.pop("_created_at", None)

    file_exists = OUTPUT_CSV.exists()
    with open(OUTPUT_CSV, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["timestamp", "app", "title", "duration", "source"])
        if not file_exists:
            writer.writeheader()
        writer.writerows(events)

    # Save last timestamp for deduplication
    if max_created_at > 0:
        save_last_timestamp(max_created_at)

    print(f"\nSuccess: {len(events)} NEW entries added.")

if __name__ == "__main__":
    print(f"=== Screen Time Collection - {datetime.now().isoformat()} ===\n")

    last_ts = get_last_timestamp()
    if last_ts > 0:
        print(f"Last extraction: {datetime.fromtimestamp(last_ts).isoformat()}")
    else:
        print("First run - extracting all available data")

    # Parse configured devices
    devices = parse_devices()
    if not devices:
        print("\nNo mobile devices configured.")
        print("Tip: Set DEVICE_ID or DEVICES in .env")
        print("     Run: cd aw-import-screentime && .venv/bin/aw-import-screentime devices")

    # Collect from all mobile devices
    all_mobile_events = []
    for device_name, device_id in devices:
        events = get_mobile_data(device_name, device_id, last_ts)
        all_mobile_events.extend(events)

    # Collect Mac data (nur wenn ausdrücklich aktiviert, s. COLLECT_MAC)
    if COLLECT_MAC:
        mac_events = get_mac_data(last_ts)
    else:
        print("[Mac] Übersprungen (COLLECT_MAC=false)")
        mac_events = []

    # Combine and sort by timestamp
    all_events = all_mobile_events + mac_events
    all_events.sort(key=lambda x: x["timestamp"])

    # Print summary
    print()
    for device_name, device_id in devices:
        count = sum(1 for e in all_mobile_events if e["source"] == device_name)
        print(f"  {device_name}: {count} Events")
    print(f"  Mac: {len(mac_events)} Events")

    save_to_csv(all_events)

    # --- Diagnose ---
    # Welche Geraete kennt Biome gerade wirklich? Der Abgleich mit der
    # Konfiguration deckt den Fall auf, dass sich eine Geraete-ID geaendert hat
    # (Biome vergibt sie je Apple-ID neu) -- dann liefert die alte ID stumm 0.
    seen = list_sync_db_devices()
    DIAG["devices_seen"] = [
        {"id": d["device_identifier"], "platform": d.get("platform"),
         "me": d.get("me"), "last_sync": d.get("last_sync")}
        for d in seen
    ]
    seen_ids = {d["device_identifier"] for d in seen}
    sync_ok = DIAG["sync_db"] == "ok"
    for name, dev_id in devices:
        entry = DIAG["devices"].setdefault(name, {"device_id": dev_id})
        # Nur aussagekraeftig, wenn sync.db ueberhaupt lesbar war -- sonst waere
        # jedes Geraet "nicht gefunden" und wuerde die echte Ursache verdecken.
        entry["in_sync_db"] = dev_id in seen_ids if sync_ok else None
        if sync_ok and not entry["in_sync_db"]:
            entry["status"] = "Geraete-ID steht nicht mehr in Biomes Geraeteliste"

    print()
    print(f"[Diag] sync.db: {DIAG['sync_db']} | Geraete in Biome: {len(seen)}")
    for name, info in DIAG["devices"].items():
        print(f"[Diag] {name}: {info.get('status')} "
              f"(28d={info.get('events_total_28d')}, neu={info.get('events_new')}, "
              f"in_sync_db={info.get('in_sync_db')})")
    write_diagnostics()

    # Echte Stoerungen muessen den Lauf scheitern lassen, sonst gilt "0 Ereignisse
    # wegen kaputter Sammlung" als Erfolg und niemand erfaehrt davon.
    if DIAG["hard_error"]:
        print("\n[Diag] Lauf mit Fehlern beendet.")
        sys.exit(1)