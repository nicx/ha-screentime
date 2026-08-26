#!/usr/bin/env python3
"""
Apple Screen Time Exporter - Exporter
Exports data to Home Assistant and InfluxDB
"""

import csv
import json
import os
import sys
import requests
from datetime import datetime, timedelta, timezone
from pathlib import Path
from collections import defaultdict
from dotenv import load_dotenv

from config import CATEGORIES, TITLE_NORMALIZE, get_category

# Load .env from parent directory
load_dotenv(Path(__file__).parent.parent / ".env")

# --- CONFIGURATION ---
SCRIPT_DIR = Path(__file__).parent.parent

# Home Assistant
HA_URL = os.getenv("HA_URL", "http://homeassistant.local:8123")
HA_TOKEN = os.getenv("HA_TOKEN", "")

# InfluxDB
INFLUX_URL = os.getenv("INFLUX_URL", "http://localhost:8086")
INFLUX_TOKEN = os.getenv("INFLUX_TOKEN", "")
INFLUX_ORG = os.getenv("INFLUX_ORG", "home")
INFLUX_BUCKET = os.getenv("INFLUX_BUCKET", "screentime")

# Paths (s. collector.py: per Env überschreibbar für den Betrieb im App-Bundle)
DATA_DIR = Path(os.getenv("SCREENTIME_DATA_DIR") or (SCRIPT_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

CSV_FILE = DATA_DIR / "screentime.csv"
LAST_EXPORT_FILE = DATA_DIR / ".last_export_timestamp"

# Maschinenlesbarer Stand des letzten Laufs. Die Menüleisten-App liest das
# statt stdout zu parsen (Anzeige, Schwellwert-Alarm, Tageszusammenfassung).
STATUS_FILE = DATA_DIR / "status.json"

# Diagnose des Collectors (schreibt collector.py). Wird als eigener Sensor nach
# HA gespiegelt: der Sammel-Benutzer hat ein privates Home, in das von aussen
# niemand hineinschaut -- ohne diese Bruecke bleibt bei einer stummen Stoerung
# unklar, WARUM keine Daten ankommen.
DIAG_FILE = DATA_DIR / "diagnostics.json"


def export_diagnostics() -> None:
    """Spiegelt diagnostics.json als sensor.screentime_diagnose nach HA."""
    try:
        diag = json.loads(DIAG_FILE.read_text())
    except Exception:
        return

    attrs = {
        "friendly_name": "Bildschirmzeit Diagnose",
        "icon": "mdi:stethoscope",
        "sync_db": diag.get("sync_db"),
        "geraete_in_biome": len(diag.get("devices_seen") or []),
        "geprueft_am": diag.get("written_at"),
    }
    for name, info in (diag.get("devices") or {}).items():
        attrs[f"{name} — Status"] = info.get("status")
        attrs[f"{name} — Ereignisse 28d"] = info.get("events_total_28d")
        attrs[f"{name} — juengstes Ereignis"] = info.get("newest_event")
        attrs[f"{name} — Datenalter (h)"] = info.get("newest_event_age_hours")
        attrs[f"{name} — ID in Biome"] = info.get("in_sync_db")
        if info.get("stderr"):
            attrs[f"{name} — Fehler"] = " | ".join(info["stderr"])[:250]
    # Fremde Geraete-IDs mit auflisten, damit eine geaenderte ID auffaellt.
    for i, d in enumerate((diag.get("devices_seen") or [])[:12], 1):
        newest = d.get("newest_event")
        extra = f" · juengstes Ereignis {newest}" if newest else ""
        attrs[f"Biome {i}"] = (f"platform {d.get('platform')} · sync {d.get('last_sync')}{extra}")

    stale = any((i.get("newest_event_age_hours") or 0) > 24
                for i in (diag.get("devices") or {}).values())
    state = "Fehler" if diag.get("hard_error") else ("veraltet" if stale else "ok")
    update_ha_sensor("sensor.screentime_diagnose", state, attrs, None, state_class=None)


CATEGORY_LABELS = {
    "AI": "KI",
    "Browser": "Browser",
    "Communication": "Kommunikation",
    "Finance": "Finanzen",
    "Games": "Spiele",
    "Media": "Medien",
    "Other": "Sonstiges",
    "Productivity": "Produktivität",
    "School": "Schule",
    "Shopping": "Einkaufen",
    "Social": "Social Media",
    "System": "System",
    "Utilities": "Werkzeuge",
}

CATEGORY_ICONS = {
    "AI": "mdi:robot",
    "Browser": "mdi:web",
    "Communication": "mdi:message-text",
    "Finance": "mdi:bank",
    "Games": "mdi:gamepad-variant",
    "Media": "mdi:play-circle",
    "Other": "mdi:dots-horizontal",
    "Productivity": "mdi:briefcase",
    "School": "mdi:school",
    "Shopping": "mdi:cart",
    "Social": "mdi:account-group",
    "System": "mdi:cog",
    "Utilities": "mdi:tools",
}


def slugify(name: str) -> str:
    """App-/Kategoriename -> Entity-ID-tauglicher Bestandteil."""
    out = "".join(c.lower() if c.isalnum() else "_" for c in name)
    while "__" in out:
        out = out.replace("__", "_")
    return out.strip("_") or "unknown"


def known_categories() -> list[str]:
    """Alle Kategorien, die vorkommen können — inkl. der Auffangwerte."""
    return sorted(set(CATEGORIES.values()) | {"Other", "System"})


def watched_apps() -> list[str]:
    """Apps, die eigene Sensoren bekommen (kommagetrennt aus WATCHED_APPS)."""
    raw = os.getenv("WATCHED_APPS", "")
    return [a.strip() for a in raw.split(",") if a.strip()]


def write_status(aggregates: dict) -> None:
    """Schreibt den aktuellen Tagesstand für die App."""
    try:
        payload = dict(aggregates)
        payload["updated_at"] = datetime.now().astimezone().isoformat()
        payload["date"] = datetime.now().date().isoformat()
        STATUS_FILE.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    except Exception as e:
        print(f"[Status] Could not write {STATUS_FILE}: {e}")


def get_last_export_timestamp() -> float:
    """Reads the last export timestamp."""
    if LAST_EXPORT_FILE.exists():
        try:
            return float(LAST_EXPORT_FILE.read_text().strip())
        except:
            pass
    return 0.0


def save_last_export_timestamp(ts: float):
    """Saves the last export timestamp."""
    LAST_EXPORT_FILE.write_text(str(ts))


def load_data(since_timestamp: float = 0) -> list[dict]:
    """
    Loads the CSV and filters for new data.

    Bewusst ohne pandas: die App bündelt ihre eigene Python-Runtime, und
    pandas/numpy wären die mit Abstand schwersten nativen Abhängigkeiten
    (Bundle-Größe + Signierung). Die Aggregation hier ist simpel genug.

    Returns: Liste von Zeilen-Dicts mit zusätzlich
             'dt' (datetime, UTC), 'unix_ts' (int), 'category' (str).
    """
    if not CSV_FILE.exists():
        print(f"CSV not found: {CSV_FILE}")
        return []

    rows: list[dict] = []
    with CSV_FILE.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            ts = (row.get("timestamp") or "").strip()
            if not ts:
                continue
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
            except ValueError:
                continue
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)

            unix_ts = int(dt.timestamp())
            if since_timestamp > 0 and unix_ts <= since_timestamp:
                continue

            try:
                duration = float(row.get("duration") or 0.0)
            except ValueError:
                duration = 0.0

            # Normalize titles (long App Store names -> short)
            title = row.get("title") or "Unknown"
            title = TITLE_NORMALIZE.get(title, title)

            row["dt"] = dt
            row["unix_ts"] = unix_ts
            row["duration"] = duration
            row["title"] = title
            row["category"] = get_category(title)
            rows.append(row)

    return rows


def export_to_influxdb(rows: list[dict]) -> bool:
    """
    Writes raw data to InfluxDB in Line Protocol format.

    Schema:
      screentime,source=iphone,app=com.google.Chrome,title=Chrome,category=browser duration=45.5 1707400000000000000
    """
    if not rows:
        print("[InfluxDB] No data to export")
        return True

    if not INFLUX_TOKEN:
        print("[InfluxDB] INFLUX_TOKEN not set - skipping")
        return False

    lines = []
    for row in rows:
        # Escape special characters in tag values
        source = row["source"].replace(" ", "\\ ").replace(",", "\\,")
        app = row["app"].replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")
        title = row["title"].replace(" ", "\\ ").replace(",", "\\,").replace("=", "\\=")
        category = row["category"].replace(" ", "\\ ").replace(",", "\\,")

        # Timestamp in nanoseconds
        ts_ns = int(row["dt"].timestamp() * 1e9)

        line = f'screentime,source={source},app={app},title={title},category={category} duration={row["duration"]} {ts_ns}'
        lines.append(line)

    # Batch write
    data = "\n".join(lines)

    try:
        response = requests.post(
            f"{INFLUX_URL}/api/v2/write",
            params={"org": INFLUX_ORG, "bucket": INFLUX_BUCKET, "precision": "ns"},
            headers={
                "Authorization": f"Token {INFLUX_TOKEN}",
                "Content-Type": "text/plain; charset=utf-8"
            },
            data=data.encode('utf-8'),
            timeout=30
        )

        if response.status_code == 204:
            print(f"[InfluxDB] {len(lines)} data points written")
            return True
        else:
            print(f"[InfluxDB] Error {response.status_code}: {response.text[:200]}")
            return False

    except Exception as e:
        print(f"[InfluxDB] Connection error: {e}")
        return False


def calculate_daily_aggregates(rows: list[dict], target_date=None) -> dict:
    """
    Calculates daily aggregates for Home Assistant sensors.

    Returns:
        {
            "total_minutes": 245.5,
            "by_device": {"iPhone": 180.0, "Mac": 65.5, ...},
            "top_app": "Chrome",
            "top_app_minutes": 45.0,
            "by_category": {"social": 90, "productivity": 60, ...},
            "by_app": {"Chrome": 45, "Discord": 30, ...},
            "session_count": 150,
        }
    """
    if target_date is None:
        target_date = datetime.now().date()

    # Filter for target day. Die Zeitstempel sind UTC; für die Tagesgrenze
    # zählt die lokale Zeit, sonst landen Abendstunden im falschen Tag.
    day_rows = [r for r in rows if r["dt"].astimezone().date() == target_date]
    if not day_rows:
        return None

    def sum_by(key: str) -> dict:
        out: dict[str, float] = defaultdict(float)
        for r in day_rows:
            out[r.get(key) or "Unknown"] += r["duration"]
        return dict(out)

    total_seconds = sum(r["duration"] for r in day_rows)

    by_device = {k: round(v / 60, 1) for k, v in sum_by("source").items()}
    by_category = {k: round(v / 60, 1) for k, v in sum_by("category").items()}

    app_totals = sorted(sum_by("title").items(), key=lambda kv: kv[1], reverse=True)
    top_app, top_app_seconds = app_totals[0] if app_totals else ("Unknown", 0.0)
    by_app = {k: round(v / 60, 1) for k, v in app_totals[:10]}
    # Vollständig, nicht nur Top 10: eine beobachtete App kann außerhalb der
    # Top 10 liegen und stünde sonst fälschlich auf 0.
    by_app_all = {k: round(v / 60, 1) for k, v in app_totals}

    return {
        "total_minutes": round(total_seconds / 60, 1),
        "by_device": by_device,
        "top_app": top_app,
        "top_app_minutes": round(top_app_seconds / 60, 1),
        "by_category": by_category,
        "by_app": by_app,
        "by_app_all": by_app_all,
        "session_count": len(day_rows),
    }


def update_ha_sensor(entity_id: str, state: any, attributes: dict = None,
                     unit: str = None, state_class: str | None = "total_increasing"):
    """Updates a Home Assistant sensor via REST API."""
    if not HA_TOKEN:
        print(f"[HA] HA_TOKEN not set - skipping {entity_id}")
        return False

    url = f"{HA_URL}/api/states/{entity_id}"

    payload = {
        "state": state,
        "attributes": attributes or {}
    }

    if unit:
        payload["attributes"]["unit_of_measurement"] = unit

    # state_class nur bei numerischen Sensoren: sonst versucht HA aus einem
    # App-NAMEN Statistik zu rechnen und meckert.
    # "total_increasing" statt "measurement": der Wert ist eine Tagessumme, die
    # um Mitternacht auf 0 zurückfällt. HA erkennt den Rücksprung als Reset und
    # rechnet die Tageswerte korrekt -- "max pro Tag" würde dagegen den Wert
    # mitnehmen, der nach Mitternacht bis zum ersten Lauf noch stehenbleibt.
    if state_class:
        payload["attributes"]["state_class"] = state_class
    payload["attributes"]["last_updated"] = datetime.now().isoformat()

    try:
        response = requests.post(
            url,
            headers={
                "Authorization": f"Bearer {HA_TOKEN}",
                "Content-Type": "application/json"
            },
            json=payload,
            timeout=10
        )

        if response.status_code in [200, 201]:
            print(f"[HA] {entity_id} = {state}")
            return True
        else:
            print(f"[HA] Error {response.status_code} for {entity_id}: {response.text[:100]}")
            return False

    except Exception as e:
        print(f"[HA] Connection error: {e}")
        return False


def export_to_homeassistant(rows: list[dict]) -> bool:
    """Aktualisiert alle Sensoren. Rückgabe: True nur, wenn ALLE Pushes klappten."""
    """Exports daily aggregates as Home Assistant sensors."""
    if not HA_TOKEN:
        print("[HA] HA_TOKEN not set - skipping Home Assistant export")
        return False

    today = datetime.now().date()
    aggregates = calculate_daily_aggregates(rows, today)

    if not aggregates:
        # Kein Eintrag für heute (z.B. kurz nach Mitternacht): bewusst Nullen
        # senden statt abzubrechen — sonst stünden die Werte von GESTERN
        # weiter als "heute" in HA.
        print("[HA] No data for today yet - resetting sensors to 0")
        aggregates = {
            "total_minutes": 0.0,
            "by_device": {},
            "top_app": "-",
            "top_app_minutes": 0.0,
            "by_category": {},
            "by_app": {},
            "by_app_all": {},
            "session_count": 0,
        }

    # Base sensors
    sensors = [
        ("sensor.screentime_total", aggregates["total_minutes"], "min", {
            "friendly_name": "Bildschirmzeit gesamt",
            "icon": "mdi:cellphone-screen",
            "session_count": aggregates["session_count"],
        }),
        ("sensor.screentime_top_app", aggregates["top_app"], None, {
            "friendly_name": "Bildschirmzeit Top-App",
            "icon": "mdi:trophy",
            "minutes": aggregates["top_app_minutes"],
        }),
    ]

    # Per-device sensors: ALLE konfigurierten Geräte melden, auch ungenutzte.
    # Sonst verschwindet die Entity an Tagen ohne Nutzung und reißt Lücken
    # in Dashboard und Verlauf.
    by_device = dict(aggregates["by_device"])
    for entry in os.getenv("DEVICES", "").split(","):
        entry = entry.strip()
        if ":" in entry:
            configured_name = entry.split(":", 1)[0].strip()
            by_device.setdefault(configured_name, 0.0)

    for device_name, minutes in by_device.items():
        # Create entity_id from device name (e.g., "iPhone 15 Pro" -> "screentime_iphone_15_pro")
        entity_suffix = device_name.lower().replace(" ", "_").replace("-", "_")
        entity_id = f"sensor.screentime_{entity_suffix}"

        # Choose icon based on device type
        if "mac" in device_name.lower():
            icon = "mdi:laptop"
        elif "ipad" in device_name.lower():
            icon = "mdi:tablet"
        else:
            icon = "mdi:cellphone"

        sensors.append((entity_id, minutes, "min", {
            "friendly_name": f"Bildschirmzeit {device_name}",
            "icon": icon,
        }))

    ok = True
    for entity_id, state, unit, attrs in sensors:
        # Der Top-App-Sensor hält einen App-NAMEN, keine Zahl -> keine Statistik.
        sc = None if entity_id.endswith("_top_app") else "total_increasing"
        ok = update_ha_sensor(entity_id, state, attrs, unit, state_class=sc) and ok

    # Category sensor with all values as attributes
    ok = update_ha_sensor(
        "sensor.screentime_by_category",
        aggregates["by_category"].get("Social", 0),
        {
            "friendly_name": "Bildschirmzeit Kategorien (Übersicht)",
            "icon": "mdi:chart-pie",
            **{f"category_{k}": v for k, v in aggregates["by_category"].items()}
        },
        "min",
        state_class=None
    ) and ok

    # Top apps as attributes
    ok = update_ha_sensor(
        "sensor.screentime_top_apps",
        len(aggregates["by_app"]),
        {
            "friendly_name": "Bildschirmzeit Top-Apps (Übersicht)",
            "icon": "mdi:format-list-numbered",
            **aggregates["by_app"]
        },
        "apps",
        state_class=None
    ) and ok

    # --- Einzelsensoren pro Kategorie ---
    # Bewusst IMMER alle bekannten Kategorien senden, auch mit 0 Minuten: sonst
    # verschwindet die Entity an ruhigen Tagen und reißt Lücken in Verlauf und
    # Langzeitstatistik.
    for category in known_categories():
        minutes = aggregates["by_category"].get(category, 0.0)
        ok = update_ha_sensor(
            f"sensor.screentime_cat_{slugify(category)}",
            minutes,
            {
                "friendly_name": f"Bildschirmzeit {CATEGORY_LABELS.get(category, category)}",
                "icon": CATEGORY_ICONS.get(category, "mdi:shape"),
            },
            "min"
        ) and ok

    # --- Einzelsensoren für beobachtete Apps ---
    # Nur eine feste Auswahl statt "jede gesehene App": sonst sammeln sich über
    # die Wochen hunderte Entities an, die kommen und gehen, und blähen den
    # Recorder auf. Die Beobachtungsliste hat stabile IDs und lückenlose Historie.
    by_app_all = aggregates.get("by_app_all", aggregates["by_app"])
    for app in watched_apps():
        minutes = by_app_all.get(app, 0.0)
        ok = update_ha_sensor(
            f"sensor.screentime_app_{slugify(app)}",
            minutes,
            {
                "friendly_name": f"Bildschirmzeit {app}",
                "icon": "mdi:application",
            },
            "min"
        ) and ok

    write_status(aggregates)
    export_diagnostics()
    return ok


def main():
    print(f"=== Screen Time Export - {datetime.now().isoformat()} ===\n")

    # Load last export timestamp
    last_export = get_last_export_timestamp()
    if last_export > 0:
        print(f"Last export: {datetime.fromtimestamp(last_export).isoformat()}")
    else:
        print("First export - all data will be exported")

    # Load data
    rows = load_data(since_timestamp=last_export)
    print(f"Loaded data: {len(rows)} new entries")

    # Bewusst KEIN vorzeitiges Ende bei "keine neuen Daten": die Tageswerte in
    # Home Assistant müssen auch dann stimmen, wenn nichts dazugekommen ist —
    # sonst stünde nach Mitternacht weiter der Stand von gestern als "heute".
    if not rows:
        print("Keine neuen Daten – Tageswerte werden trotzdem aktualisiert.")

    # Export to InfluxDB (raw data)
    influx_success = True
    if rows:
        print("\n--- InfluxDB Export ---")
        influx_success = export_to_influxdb(rows)

    # Export to Home Assistant (aggregates)
    print("\n--- Home Assistant Export ---")
    # For HA we need all data from today, not just new
    rows_full = load_data(since_timestamp=0)
    ha_ok = export_to_homeassistant(rows_full)

    # Save last timestamp.
    # Ohne InfluxDB (unser Fall) darf der Merker nicht am Influx-Ergebnis hängen,
    # sonst wird bei jedem Lauf die komplette CSV neu verarbeitet.
    # Ist InfluxDB konfiguriert, bleibt das Retry-Verhalten erhalten.
    influx_enabled = bool(os.getenv("INFLUX_TOKEN"))
    if rows and (influx_success or not influx_enabled):
        max_ts = max(r["unix_ts"] for r in rows)
        save_last_export_timestamp(max_ts)
        print(f"\nExport completed. Last timestamp: {datetime.fromtimestamp(max_ts).isoformat()}")

    # Exit-Code, damit die App einen kaputten HA-Export (Netz weg, Token
    # abgelaufen) als Fehler erkennt statt ihn nur ins Log zu schreiben.
    if not ha_ok:
        print("\n[HA] Export unvollständig – siehe Meldungen oben.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
