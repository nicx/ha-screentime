#!/usr/bin/env bash
#
# Baut eine autarke Python-Runtime nach ./Runtime, fertig zum Einbetten ins .app.
#
# Anders als bei esphome/home-assistant (die nur den nackten Interpreter bündeln
# und beim ersten Start eine venv in ~/Library anlegen) werden hier ALLE
# Abhängigkeiten schon zur Build-Zeit mit installiert — nach dem Muster von
# matter-server. Ergebnis: die App ist beim ersten Start sofort lauffähig und
# hängt an keiner externen Python-Installation oder venv.
#
# Layout:
#   Runtime/python/bin/python3        relocatable CPython (arm64)
#   Runtime/python/lib/python3.13/…   Stdlib + site-packages (requests,
#                                     python-dotenv, aw-import-screentime …)
#   Runtime/python/bin/aw-import-screentime   CLI-Entrypoint
#
# Env-Overrides:
#   PBS_RELEASE   python-build-standalone Release-Tag (default: 20260610)
#   PY_VERSION    CPython-Version                    (default: 3.13.14)
#
# CPython 3.13, nicht 3.14: aw-import-screentime deklariert Python >=3.10,<3.14.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/Runtime"

PBS_RELEASE="${PBS_RELEASE:-20260610}"
PY_VERSION="${PY_VERSION:-3.13.14}"

case "$(uname -m)" in
  arm64) ARCH=aarch64 ;;
  *)
    echo "error: baut eine Apple-Silicon-Runtime (arm64); Host ist $(uname -m)." >&2
    exit 1
    ;;
esac

ASSET="cpython-${PY_VERSION}+${PBS_RELEASE}-${ARCH}-apple-darwin-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${ASSET}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Lade $ASSET"
curl -fSL "$URL" -o "$WORK/$ASSET"

echo "==> Entpacke CPython-Runtime"
rm -rf "$RUNTIME/python"
mkdir -p "$RUNTIME"
tar -xzf "$WORK/$ASSET" -C "$RUNTIME"

PY="$RUNTIME/python/bin/python3"
if [[ ! -x "$PY" ]]; then
  echo "error: kein Interpreter unter $PY nach dem Entpacken." >&2
  exit 1
fi
echo "    Interpreter: $("$PY" -c 'import platform,sys; print(platform.python_version(), sys.platform, platform.machine())')"

echo "==> Installiere Abhängigkeiten in die Runtime"
# --no-cache-dir hält das Bundle frei von pip-Cache-Resten.
"$PY" -m pip install --quiet --no-cache-dir --upgrade pip
"$PY" -m pip install --quiet --no-cache-dir requests python-dotenv

# aw-import-screentime liegt als Unterordner im Repo (SEGB/Biome-Parser).
if [[ ! -d "$ROOT/aw-import-screentime" ]]; then
  echo "error: $ROOT/aw-import-screentime fehlt." >&2
  exit 1
fi

# ccl-segb steht nicht auf PyPI; aw-import-screentime bezieht es über
# [tool.uv.sources] direkt aus Git. pip kennt diese uv-Syntax nicht, also
# installieren wir es hier explizit vorab aus derselben Quelle.
CCL_SEGB_GIT="${CCL_SEGB_GIT:-git+https://github.com/cclgroupltd/ccl-segb.git@main}"
"$PY" -m pip install --quiet --no-cache-dir "$CCL_SEGB_GIT"

"$PY" -m pip install --quiet --no-cache-dir "$ROOT/aw-import-screentime"

AW="$RUNTIME/python/bin/aw-import-screentime"
if [[ ! -x "$AW" ]]; then
  echo "error: aw-import-screentime-Entrypoint fehlt unter $AW." >&2
  exit 1
fi

echo "==> Verkleinere Runtime"
PYLIB="$RUNTIME/python/lib/python${PY_VERSION%.*}"
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/turtledemo" \
       "$PYLIB/tkinter" "$PYLIB/lib2to3" \
       "$RUNTIME/python/share" 2>/dev/null || true
find "$RUNTIME/python" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> Selbsttest"
"$PY" -c 'import requests, dotenv; print("    imports ok:", requests.__version__)'
"$AW" --help >/dev/null && echo "    aw-import-screentime ok"

echo "==> Fertig: $RUNTIME ($(du -sh "$RUNTIME" | cut -f1))"
