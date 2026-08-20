#!/bin/zsh
#
# run.sh — Wrapper für den periodischen Lauf (launchd).
#
# Warum ein Wrapper: launchd-Jobs erben den Full Disk Access des Terminals NICHT.
# TCC hängt am ausführenden Programm; mit /bin/zsh als stabiler, Apple-signierter
# Binary lässt sich die Freigabe einmal erteilen und übersteht Python-Updates
# (der venv-Python ist nur ein Symlink auf die Homebrew-Version).
#
# Pfade relativ zum Skript, damit es aus /Users/Shared genauso läuft wie aus ~/Git.

SCRIPT_DIR="${0:A:h}"
exec "$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/run.py"
