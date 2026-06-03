#!/bin/sh
# Minimal GS -> drone TCP forwards using socat:
#   GS :1080 -> drone :80
#   GS :1022 -> drone :22

set -eu

HTTP_LISTEN_PORT="${HTTP_LISTEN_PORT:-1080}"
SSH_LISTEN_PORT="${SSH_LISTEN_PORT:-1022}"
SOCAT_LOG="/tmp/gs_drone_proxy.log"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[gs] ERROR: required command '$1' not found."
        exit 1
    }
}

for c in ip socat grep; do
    need_cmd "$c"
done

detect_drone_ip() {
    if ip -4 addr show | grep -q '10\.5\.0\.1/24'; then
        DRONE_IP="10.5.0.10"
        return
    fi
    if ip -4 addr show | grep -q '192\.168\.0\.1/24'; then
        DRONE_IP="192.168.0.10"
        return
    fi

    echo "[gs] ERROR: Could not detect active drone link on GS."
    exit 1
}

start_forward() {
    # start_forward <listen_port> <target_ip> <target_port>
    listen_port="$1"
    target_ip="$2"
    target_port="$3"

    for p in /proc/[0-9]*; do
        [ -r "${p}/cmdline" ] || continue
        cmd="$(tr '\000' ' ' < "${p}/cmdline" 2>/dev/null || true)"
        case "${cmd}" in
            *"socat "*"TCP-LISTEN:${listen_port},"*"TCP:${target_ip}:${target_port}"*)
                echo "[gs] Forward ${listen_port} -> ${target_ip}:${target_port} already running."
                return
                ;;
        esac
    done

    nohup socat \
        "TCP-LISTEN:${listen_port},bind=0.0.0.0,reuseaddr,fork" \
        "TCP:${target_ip}:${target_port}" >>"${SOCAT_LOG}" 2>&1 &

    sleep 1
    if ! kill -0 "$!" 2>/dev/null; then
        echo "[gs] ERROR: Failed to start forward ${listen_port} -> ${target_ip}:${target_port}."
        echo "[gs] Check ${SOCAT_LOG} for details."
        exit 1
    fi
}

has_forward() {
    # has_forward <listen_port> <target_port>
    listen_port="$1"
    target_port="$2"

    for p in /proc/[0-9]*; do
        [ -r "${p}/cmdline" ] || continue
        cmd="$(tr '\000' ' ' < "${p}/cmdline" 2>/dev/null || true)"
        case "${cmd}" in
            *"socat "*"TCP-LISTEN:${listen_port},"*":${target_port}"*)
                return 0
                ;;
        esac
    done
    return 1
}

if has_forward "${HTTP_LISTEN_PORT}" "80" && has_forward "${SSH_LISTEN_PORT}" "22"; then
    echo "[gs] Forward 1080 -> drone:80 already running."
    echo "[gs] Forward 1022 -> drone:22 already running."
    echo "[gs] Proxy active:"
    echo "[gs]   0.0.0.0:${HTTP_LISTEN_PORT} -> drone:80"
    echo "[gs]   0.0.0.0:${SSH_LISTEN_PORT} -> drone:22"
    exit 0
fi

detect_drone_ip
start_forward "${HTTP_LISTEN_PORT}" "${DRONE_IP}" "80"
start_forward "${SSH_LISTEN_PORT}" "${DRONE_IP}" "22"

echo "[gs] Proxy active:"
echo "[gs]   0.0.0.0:${HTTP_LISTEN_PORT} -> ${DRONE_IP}:80"
echo "[gs]   0.0.0.0:${SSH_LISTEN_PORT} -> ${DRONE_IP}:22"
