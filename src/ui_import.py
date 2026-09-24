#!/usr/bin/env python3
"""
Baut screentime.csv aus den Tageswerten, die die Menüleisten-App aus den
Systemeinstellungen (Familie → Bildschirmzeit) liest.

Warum ein eigener Weg: Seit iOS 27 bieten die Geräte eines Kinder-Accounts
ihre App-Nutzung nicht mehr über Biome an (collector.py findet dort nichts
mehr). Die App legt stattdessen je Kind und Tag eine Datei
children/<kind>/days/<datum>.json ab; dieser Lauf bekommt das Verzeichnis des
Kindes als SCREENTIME_DATA_DIR.

Beide CSVs werden bei jedem Lauf komplett neu geschrieben: screentime.csv mit
einer Zeile je App und Tag, categories.csv mit Apples Kategorien je Tag.
"""

import csv
import json
import os
from datetime import date, datetime, time, timedelta
from pathlib import Path

from config import APP_MAP, UNATTRIBUTED_TITLE, normalize_title

SCRIPT_DIR = Path(__file__).parent.parent
DATA_DIR = Path(os.getenv("SCREENTIME_DATA_DIR") or (SCRIPT_DIR / "data"))
DAYS_DIR = DATA_DIR / "days"
CSV_FILE = DATA_DIR / "screentime.csv"
# Apples Kategorien je Tag (Kennung, Name, Sekunden) -- seit iOS 27 korrekt und
# vom Nutzer erweiterbar, deshalb statt unserer eigenen Zuordnung.
CATEGORIES_FILE = DATA_DIR / "categories.csv"
SOURCE_NAME = os.getenv("SCREENTIME_CHILD") or "Kind"

# So weit reicht die Tagesstatistik (statistics_backfill.DAYS_BACK) zurück.
KEEP_DAYS = 35
# Ältere Tagesdateien werden gelöscht; sie tragen nichts mehr bei.
PRUNE_DAYS = 60

UNATTRIBUTED_APP = "hascreentime.unattributed"
# Differenz unterhalb dieser Grenze ist Messrauschen, keine eigene Zeile wert.
MIN_UNATTRIBUTED_SECONDS = 30


def display_title(bundle_id: str, name: str) -> str:
    """Gleiche Titel wie bisher: erst die Bundle-ID-Tabelle, dann Normalisierung."""
    if bundle_id in APP_MAP:
        return APP_MAP[bundle_id]
    title = normalize_title(name)
    if title != name:
        return title
    # App-Store-Namen tragen oft einen Untertitel ("CapCut: Foto- und
    # Video-Editor", "mydealz – Gutscheine, Angebote") -- der Teil davor ist
    # der eigentliche Name.
    for sep in (": ", " – ", " - "):
        head = name.split(sep, 1)[0].strip()
        if head and head != name:
            return head
    return name


def load_days() -> list[dict]:
    if not DAYS_DIR.exists():
        return []
    today = date.today()
    out = []
    for path in sorted(DAYS_DIR.glob("*.json")):
        try:
            day = date.fromisoformat(path.stem)
        except ValueError:
            continue
        age = (today - day).days
        if age > PRUNE_DAYS:
            path.unlink(missing_ok=True)
            continue
        if age > KEEP_DAYS:
            continue
        try:
            snap = json.loads(path.read_text())
        except Exception as e:
            print(f"[UI] {path.name} unlesbar: {e}")
            continue
        snap["_day"] = day
        out.append(snap)
    return out


def rows_for(snap: dict) -> list[dict]:
    # Mitternacht lokal: der Exporter ordnet Zeilen über die lokale Zeit dem Tag zu.
    ts = datetime.combine(snap["_day"], time(0, 0)).astimezone().isoformat()
    rows = []
    apps_total = 0
    for app in snap.get("apps") or []:
        secs = app.get("seconds")
        if not secs:
            continue
        apps_total += secs
        rows.append({
            "timestamp": ts,
            "app": app.get("bundle_id") or "unknown",
            "title": display_title(app.get("bundle_id") or "", app.get("name") or "Unknown"),
            "duration": secs,
            "source": SOURCE_NAME,
        })
    # Apple zeigt jede App auf volle Minuten abgerundet; die Tagessumme ist
    # genauer. Den Rest als eigene Zeile, damit die Gesamtzeit Apples Wert trifft.
    total = snap.get("total_seconds")
    if total and total - apps_total >= MIN_UNATTRIBUTED_SECONDS:
        rows.append({
            "timestamp": ts,
            "app": UNATTRIBUTED_APP,
            "title": UNATTRIBUTED_TITLE,
            "duration": total - apps_total,
            "source": SOURCE_NAME,
        })
    return rows


def category_rows_for(snap: dict) -> list[dict]:
    return [{"date": snap["_day"].isoformat(), "id": c.get("id") or "", "name": c["name"],
             "seconds": c["seconds"]}
            for c in snap.get("categories") or [] if c.get("name") and c.get("seconds")]


def write_csv(path: Path, fields: list[str], rows: list[dict]) -> None:
    tmp = path.with_suffix(".csv.tmp")
    with tmp.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    tmp.replace(path)


def main() -> int:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    days = load_days()
    rows = [r for snap in days for r in rows_for(snap)]
    write_csv(CSV_FILE, ["timestamp", "app", "title", "duration", "source"], rows)
    write_csv(CATEGORIES_FILE, ["date", "id", "name", "seconds"],
              [r for snap in days for r in category_rows_for(snap)])

    if days:
        newest = max(days, key=lambda s: s["_day"])
        print(f"[UI] {SOURCE_NAME}: {len(days)} Tage, {len(rows)} Zeilen -> {CSV_FILE.name} "
              f"(jüngster Tag {newest['_day']}, {newest.get('apple_updated') or 'ohne Stand'})")
    else:
        print("[UI] Noch keine Tageswerte vorhanden")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
