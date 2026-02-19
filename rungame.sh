#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# ── Build the C++ server if needed ───────────────────────────────────────────
# TCP-only.
SERVER_BIN="server/build/omphalos_tcp_server"
SERVER_ARGS=(7778 12)
GODOT_ENV=("OMPH_TCP=1")
LOG_FILE="server_tcp.log"
MODE_LABEL="TCP"

# Always (re)configure so option changes take effect.
echo "Configuring C++ server (TCP-only)..."
cmake -S server -B server/build -DCMAKE_BUILD_TYPE=Release -Wno-dev --log-level=WARNING

echo "Building C++ server (incremental)..."
cmake --build server/build --target omphalos_tcp_server -j"$(nproc)"

# ── Start the C++ server ──────────────────────────────────────────────────────
# Line-buffer logs so early failures show up immediately.
SERVER_CMD=("$SERVER_BIN" "${SERVER_ARGS[@]}")
if command -v stdbuf >/dev/null 2>&1; then
    SERVER_CMD=(stdbuf -oL -eL "${SERVER_CMD[@]}")
fi

echo "Mode: $MODE_LABEL"
echo "Server: $SERVER_BIN ${SERVER_ARGS[*]}"

# Refuse to start if something else is already bound to the TCP port.
if command -v ss >/dev/null 2>&1; then
    if ss -ltn | grep -q ":${SERVER_ARGS[0]}"; then
        echo "Error: TCP port ${SERVER_ARGS[0]} is already in use." >&2
        echo "If it's a stale Omphalos server: pkill -f omphalos_tcp_server" >&2
        exit 1
    fi
fi

"${SERVER_CMD[@]}" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "Started Omphalos server (pid $SERVER_PID), logs -> $LOG_FILE"

# If the server fails immediately (port in use, bind error, crash), fail fast
# and show logs instead of continuing and then killing it via trap.
sleep 0.2
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Server exited during startup. Showing $LOG_FILE:" >&2
    tail -n 200 "$LOG_FILE" >&2 || true
    exit 1
fi

cleanup() {
    set +e
    set +u
    if [[ -n "${SERVER_PID:-}" ]]; then
        echo "Stopping Omphalos server (pid $SERVER_PID)"
        kill "$SERVER_PID" 2>/dev/null || true
        # Give it a moment to exit cleanly; then force-kill.
        for _ in 1 2 3 4 5; do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            kill -9 "$SERVER_PID" 2>/dev/null || true
        fi
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap cleanup EXIT

# ── Launch Godot (run game directly) ─────────────────────────────────────────
# Prefer a local Godot binary if one exists, else fall back to PATH.
GODOT_BIN=""
if [ -x "../Godot_v4.5.1-stable_linux.x86_64" ]; then
    GODOT_BIN="../Godot_v4.5.1-stable_linux.x86_64"
elif command -v godot >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot)"
elif command -v godot4 >/dev/null 2>&1; then
    GODOT_BIN="$(command -v godot4)"
fi

if [ -n "$GODOT_BIN" ]; then
    echo "Launching Godot: $GODOT_BIN"
    echo "Running project (main scene) so it should connect to the server immediately."
    env "${GODOT_ENV[@]}" "$GODOT_BIN" --path .
else
    echo "Godot not found. Run the game from the editor (F5) or set GODOT_BIN in this script."
    echo "Server is running; logs -> $LOG_FILE"
    # Keep the server alive until the user Ctrl-C's.
    while true; do sleep 3600; done
fi
