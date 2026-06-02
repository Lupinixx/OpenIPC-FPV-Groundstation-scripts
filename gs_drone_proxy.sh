#!/bin/sh
# Publish drone services on GS ports:
#   http://<groundstation-lan-ip>:1080 -> http://<drone-ip>:80
#   ssh  root@<groundstation-lan-ip> -p 1022 -> <drone-ip>:22
# Works on this Buildroot image using ssh/sshpass (no iptables/nft required).

set -eu

HTTP_LISTEN_PORT="${HTTP_LISTEN_PORT:-1080}"
SSH_LISTEN_PORT="${SSH_LISTEN_PORT:-1022}"
PID_FILE="/var/run/gs_drone_webui_proxy.pid"
SSH_LOG="/tmp/gs_drone_webui_proxy.log"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[gs] ERROR: required command '$1' not found."
        exit 1
    }
}

for c in ip ssh sshpass grep awk cut; do
    need_cmd "$c"
done

get_uplink_iface() {
    ip -4 route show default | awk 'NR==1 {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}

get_iface_ip() {
    ip -4 addr show dev "$1" | awk '/inet / {print $2; exit}' | cut -d/ -f1
}

detect_drone_ip() {
    if ip -4 addr show | grep -q '10\.5\.0\.1/24'; then
        DRONE_IP="10.5.0.10"
        return 0
    fi
    if ip -4 addr show | grep -q '192\.168\.0\.1/24'; then
        DRONE_IP="192.168.0.10"
        return 0
    fi
    echo "[gs] ERROR: Could not detect active drone link (expected 10.5.0.1/24 or 192.168.0.1/24 on GS)."
    exit 1
}

find_proxy_pid() {
    # Optional exact drone IP filter in $1; if empty, match any target IP.
    target_ip="${1:-}"
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [ -r "${p}/cmdline" ] || continue
        cmd="$(tr '\000' ' ' < "${p}/cmdline" 2>/dev/null || true)"
        case "${cmd}" in
            *"ssh "*"-L 0.0.0.0:${HTTP_LISTEN_PORT}:"*":80"*"-L 0.0.0.0:${SSH_LISTEN_PORT}:"*":22"*)
                if [ -n "${target_ip}" ]; then
                    case "${cmd}" in
                        *"0.0.0.0:${HTTP_LISTEN_PORT}:${target_ip}:80"*"0.0.0.0:${SSH_LISTEN_PORT}:${target_ip}:22"*"root@${target_ip}"*)
                            echo "${pid}"
                            return 0
                            ;;
                    esac
                else
                    echo "${pid}"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

is_running() {
    [ -f "${PID_FILE}" ] || return 1
    PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
    [ -n "${PID}" ] || return 1
    [ -r "/proc/${PID}/cmdline" ] || return 1
    cmd="$(tr '\000' ' ' < "/proc/${PID}/cmdline" 2>/dev/null || true)"
    case "${cmd}" in
        *"ssh "*"-L 0.0.0.0:${HTTP_LISTEN_PORT}:"*":80"*"-L 0.0.0.0:${SSH_LISTEN_PORT}:"*":22"*)
            kill -0 "${PID}" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

stop_proxy() {
    if is_running; then
        PID="$(cat "${PID_FILE}")"
        echo "[gs] Stopping proxy (pid ${PID}) ..."
        kill "${PID}" 2>/dev/null || true
        sleep 1
        kill -9 "${PID}" 2>/dev/null || true
        rm -f "${PID_FILE}"
        echo "[gs] Proxy stopped."
    else
        # Fallback: kill any matching stale proxy process if pid file is stale.
        PID="$(find_proxy_pid "" || true)"
        if [ -n "${PID}" ]; then
            echo "[gs] Stopping proxy (pid ${PID}) ..."
            kill "${PID}" 2>/dev/null || true
            sleep 1
            kill -9 "${PID}" 2>/dev/null || true
            echo "[gs] Proxy stopped."
        else
            echo "[gs] Proxy is not running."
        fi
        rm -f "${PID_FILE}"
    fi
}

start_proxy() {
    if is_running; then
        PID="$(cat "${PID_FILE}")"
        echo "[gs] Proxy already running (pid ${PID})."
        return 0
    fi

    # PID file may be stale or missing while a matching tunnel is already alive.
    PID="$(find_proxy_pid "" || true)"
    if [ -n "${PID}" ]; then
        echo "${PID}" > "${PID_FILE}"
        echo "[gs] Proxy already running (pid ${PID})."
        return 0
    fi

    UPLINK_IFACE="$(get_uplink_iface || true)"
    [ -n "${UPLINK_IFACE}" ] || {
        echo "[gs] ERROR: Could not determine uplink interface."
        exit 1
    }
    UPLINK_IP="$(get_iface_ip "${UPLINK_IFACE}" || true)"
    [ -n "${UPLINK_IP}" ] || {
        echo "[gs] ERROR: Could not determine uplink IP."
        exit 1
    }

    detect_drone_ip

    echo "[gs] Starting service proxy ..."
    echo "[gs]   0.0.0.0:${HTTP_LISTEN_PORT} -> ${DRONE_IP}:80 (HTTP)"
    echo "[gs]   0.0.0.0:${SSH_LISTEN_PORT} -> ${DRONE_IP}:22 (SSH)"

    # -N: no remote command
    # -f: background after auth
    # -L 0.0.0.0:port:target:targetport : listen on all GS interfaces
    sshpass -p 12345 ssh \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -N -f \
        -L "0.0.0.0:${HTTP_LISTEN_PORT}:${DRONE_IP}:80" \
        -L "0.0.0.0:${SSH_LISTEN_PORT}:${DRONE_IP}:22" \
        root@"${DRONE_IP}" >>"${SSH_LOG}" 2>&1 || {
            echo "[gs] ERROR: Failed to start SSH port forward."
            echo "[gs] Check ${SSH_LOG} for details."
            exit 1
        }

    # Find the ssh process that matches our local forward tuple.
    # Retry briefly because process visibility can lag right after -f backgrounding.
    PID=""
    for _try in 1 2 3 4 5; do
        PID="$(find_proxy_pid "${DRONE_IP}" || true)"
        [ -n "${PID}" ] && break
        sleep 1
    done
    if [ -z "${PID}" ]; then
        echo "[gs] ERROR: Proxy process started but PID could not be resolved."
        exit 1
    fi

    echo "${PID}" > "${PID_FILE}"

    echo "[gs] Proxy running (pid ${PID})."
    echo "[gs] HTTP on your PC: http://${UPLINK_IP}:${HTTP_LISTEN_PORT}/"
    echo "[gs] SSH  on your PC: ssh root@${UPLINK_IP} -p ${SSH_LISTEN_PORT}"
}

status_proxy() {
    UPLINK_IFACE="$(get_uplink_iface || true)"
    UPLINK_IP=""
    if [ -n "${UPLINK_IFACE}" ]; then
        UPLINK_IP="$(get_iface_ip "${UPLINK_IFACE}" || true)"
    fi

    if is_running; then
        PID="$(cat "${PID_FILE}")"
        echo "[gs] Proxy status: running (pid ${PID})"
        if [ -n "${UPLINK_IP}" ]; then
            echo "[gs] HTTP URL: http://${UPLINK_IP}:${HTTP_LISTEN_PORT}/"
            echo "[gs] SSH cmd : ssh root@${UPLINK_IP} -p ${SSH_LISTEN_PORT}"
        fi
    else
        PID="$(find_proxy_pid "" || true)"
        if [ -n "${PID}" ]; then
            echo "${PID}" > "${PID_FILE}"
            echo "[gs] Proxy status: running (pid ${PID})"
            if [ -n "${UPLINK_IP}" ]; then
                echo "[gs] HTTP URL: http://${UPLINK_IP}:${HTTP_LISTEN_PORT}/"
                echo "[gs] SSH cmd : ssh root@${UPLINK_IP} -p ${SSH_LISTEN_PORT}"
            fi
        else
            echo "[gs] Proxy status: stopped"
            if [ -n "${UPLINK_IP}" ]; then
                echo "[gs] HTTP URL (when started): http://${UPLINK_IP}:${HTTP_LISTEN_PORT}/"
                echo "[gs] SSH cmd  (when started): ssh root@${UPLINK_IP} -p ${SSH_LISTEN_PORT}"
            fi
        fi
    fi
}

# PixelPilot actions call scripts without parameters.
# This script intentionally behaves as a start-only, idempotent action.
start_proxy
