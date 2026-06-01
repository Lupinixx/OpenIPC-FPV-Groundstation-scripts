#!/bin/sh
# Perform an online firmware upgrade on the groundstation.

set -eu

echo "[gs] Starting online firmware upgrade (sysupgrade -u -r) ..."
sysupgrade -u -r || {
    rc=$?
    echo "[gs] sysupgrade exited with code ${rc}."
    echo "[gs] If a reboot happened mid-session, this is expected."
    exit 0
}

echo "[gs] sysupgrade finished."
