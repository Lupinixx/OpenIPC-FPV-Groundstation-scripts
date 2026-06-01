#!/bin/sh
# Trigger firstboot on the groundstation.

set -eu

echo "[gs] Starting firstboot ..."
firstboot || {
    rc=$?
    echo "[gs] firstboot exited with code ${rc}."
    echo "[gs] If a reboot happened mid-session, this is expected."
    exit 0
}

echo "[gs] firstboot finished."
