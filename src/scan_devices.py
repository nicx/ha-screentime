#!/usr/bin/env python3
"""
Listet alle per iCloud synchronisierten Geräte samt ihrer meistgenutzten Apps
und gibt das Ergebnis als JSON aus.

Damit findet man heraus, welche Geräte-UUID zu welchem Gerät gehört — die
Namen in Apples `DevicePeer` sind meist leer, erkennbar sind die Geräte nur an
ihren Apps. Die Menüleisten-App ruft das über "Geräte suchen" auf; früher tat
das ein separates Shell-Skript, das dafür eine eigene Kopie des Projekts an
einem für beide Benutzer lesbaren Ort brauchte.

Benötigt Festplattenvollzugriff für den aufrufenden Prozess.
"""

import json
import os
import sqlite3
import subprocess
import sys
from collections import Counter
from pathlib import Path

SYNC_DB = Path.home() / "Library" / "Biome" / "sync" / "sync.db"
KNOWLEDGE_DB = Path.home() / "Library" / "Application Support" / "Knowledge" / "knowledgeC.db"

AW_BIN = Path(
    os.getenv("SCREENTIME_AW_BIN")
    or (Path(__file__).parent.parent / "aw-import-screentime" / ".venv" / "bin" / "aw-import-screentime")
)

# Plattform-Codes aus Apples DevicePeer-Tabelle.
PLATFORM_NAMES = {
    1: "iPad",
    2: "iPhone",
    3: "Mac",
    5: "Apple TV",
    7: "HomePod",
}


def read_devices() -> list[dict]:
    if not SYNC_DB.exists():
        raise FileNotFoundError(f"{SYNC_DB} nicht gefunden")
    uri = f"file:{SYNC_DB.as_posix()}?mode=ro&immutable=1"
    with sqlite3.connect(uri, uri=True) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """SELECT device_identifier, me, platform, model,
                      datetime(last_sync_date,'unixepoch','localtime') AS last_sync
               FROM DevicePeer ORDER BY platform;"""
        ).fetchall()
    return [dict(r) for r in rows]


def top_apps(device_id: str, platform: int, limit: int = 8) -> tuple[int, list[list]]:
    """Liefert (Anzahl Events, Top-Apps) der letzten 14 Tage für ein Gerät."""
    cmd = [
        str(AW_BIN), "events", "preview",
        "--device", device_id,
        "--platform", str(platform),
        "--since", "14 days ago",
        "--limit", "0",
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        if out.returncode != 0:
            return 0, []
        data = json.loads(out.stdout or "[]")
    except Exception:
        return 0, []

    counter: Counter = Counter()
    total = 0
    for entry in data:
        for ev in entry.get("events", []):
            total += 1
            d = ev.get("data", {})
            name = d.get("title") or d.get("app") or "?"
            counter[name] += 1
    return total, [[n, c] for n, c in counter.most_common(limit)]


def knowledge_devices(limit: int = 8) -> list[dict]:
    """
    Fremdgeraete aus knowledgeC.db -- die zweite Quelle neben Biome. Seit iOS 27
    liefert Biome fuer Kinder-Geraete keine App-Nutzung mehr, knowledgeC dagegen
    schon. Die IDs beider Datenbanken sind verschieden, ein Geraet kann also in
    beiden Listen mit unterschiedlicher ID auftauchen.
    """
    if not KNOWLEDGE_DB.exists() or not os.access(KNOWLEDGE_DB, os.R_OK):
        return []
    try:
        uri = f"file:{KNOWLEDGE_DB.as_posix()}?mode=ro"
        with sqlite3.connect(uri, uri=True) as conn:
            # Bewusst ALLE Geraete listen, nicht nur solche mit App-Nutzung: ein
            # Geraet, das nur Sperr-Ereignisse schickt, muss sichtbar sein --
            # sonst sucht man vergeblich nach einer ID, die es sehr wohl gibt.
            rows = conn.execute(
                """SELECT s.ZDEVICEID,
                          sum(o.ZSTREAMNAME = '/app/usage'),
                          datetime(max(o.ZSTARTDATE) + 978307200,'unixepoch','localtime')
                   FROM ZOBJECT o JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
                   WHERE s.ZDEVICEID IS NOT NULL
                   GROUP BY s.ZDEVICEID;"""
            ).fetchall()
            out = []
            for dev_id, app_events, newest in rows:
                app_events = app_events or 0
                if app_events:
                    detail = conn.execute(
                        """SELECT o.ZVALUESTRING, count(*) AS n
                           FROM ZOBJECT o JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
                           WHERE s.ZDEVICEID = ? AND o.ZSTREAMNAME = '/app/usage'
                             AND o.ZVALUESTRING IS NOT NULL
                           GROUP BY 1 ORDER BY n DESC LIMIT ?;""",
                        (dev_id, limit),
                    ).fetchall()
                    label = "knowledgeC · App-Nutzung"
                else:
                    # Ersatzweise die gelieferten Datenstroeme zeigen -- daran ist
                    # erkennbar, dass das Geraet zwar synchronisiert, aber eben
                    # keine App-Nutzung meldet.
                    detail = conn.execute(
                        """SELECT o.ZSTREAMNAME, count(*) AS n
                           FROM ZOBJECT o JOIN ZSOURCE s ON s.Z_PK = o.ZSOURCE
                           WHERE s.ZDEVICEID = ?
                           GROUP BY 1 ORDER BY n DESC LIMIT ?;""",
                        (dev_id, limit),
                    ).fetchall()
                    label = "knowledgeC · keine App-Nutzung"
                out.append({
                    "device_id": dev_id,
                    "platform": None,
                    "platform_name": label,
                    "model": "",
                    "last_sync": newest or "",
                    "is_self": False,
                    "events": app_events,
                    "top_apps": [[a, n] for a, n in detail],
                })
            return out
    except Exception:
        return []


def main() -> int:
    try:
        devices = read_devices()
    except Exception as e:
        # Biome kann fehlen oder leer sein -- knowledgeC ist davon unabhaengig
        # und seit iOS 27 oft die einzige Quelle mit App-Nutzung.
        known = knowledge_devices()
        json.dump({"error": None if known else str(e), "devices": known}, sys.stdout,
                  ensure_ascii=False)
        return 0 if known else 1

    result = []
    for d in devices:
        platform = d.get("platform")
        # Der eigene Mac (me=1) sammelt nur, er ist als Ziel uninteressant.
        events, apps = (0, [])
        if platform is not None and not d.get("me"):
            events, apps = top_apps(d["device_identifier"], int(platform))
        result.append({
            "device_id": d["device_identifier"],
            "platform": platform,
            "platform_name": PLATFORM_NAMES.get(platform, f"Plattform {platform}"),
            "model": d.get("model") or "",
            "last_sync": d.get("last_sync") or "",
            "is_self": bool(d.get("me")),
            "events": events,
            "top_apps": apps,
        })

    result.extend(knowledge_devices())
    json.dump({"error": None, "devices": result}, sys.stdout, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
