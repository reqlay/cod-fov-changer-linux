#!/usr/bin/env bash
# Sourced by cod-fov-changer.sh when --debug is passed. Not meant to run standalone.

# Picks the first available terminal for --debug output when stdout isn't a TTY.
pick_terminal() {
    if [[ -n "${TERMINAL:-}" ]] && command -v "$TERMINAL" >/dev/null 2>&1; then
        echo "$TERMINAL"
        return 0
    fi

    if command -v xdg-terminal-exec >/dev/null 2>&1; then
        echo "xdg-terminal-exec"
        return 0
    fi

    case "${XDG_CURRENT_DESKTOP:-}" in
        *KDE*)   command -v konsole >/dev/null 2>&1 && { echo konsole; return 0; } ;;
        *GNOME*) command -v gnome-terminal >/dev/null 2>&1 && { echo gnome-terminal; return 0; } ;;
        *XFCE*)  command -v xfce4-terminal >/dev/null 2>&1 && { echo xfce4-terminal; return 0; } ;;
    esac

    local t
    for t in konsole gnome-terminal xfce4-terminal alacritty kitty foot wezterm xterm; do
        command -v "$t" >/dev/null 2>&1 && { echo "$t"; return 0; }
    done

    return 1
}

DEBUG_TERM_UNIT=""

# Runs the terminal as a systemd --user service, not a plain background job:
# Steam's process tracking walks descendants of the launched wrapper PID and
# attributes them to the game, so a plain child here was getting swept into
# the game's overlay/IPC bookkeeping too.
open_terminal() {
    local term="$1" cmd="$2"
    local -a argv

    case "$term" in
        xdg-terminal-exec) argv=(xdg-terminal-exec bash -c "$cmd") ;;
        konsole)           argv=(konsole --separate -e bash -c "$cmd") ;;
        gnome-terminal)    argv=(gnome-terminal -- bash -c "$cmd") ;;
        xfce4-terminal)    argv=(xfce4-terminal -x bash -c "$cmd") ;;
        wezterm)           argv=(wezterm start -- bash -c "$cmd") ;;
        *)                 argv=("$term" -e bash -c "$cmd") ;;
    esac

    if command -v systemd-run >/dev/null 2>&1; then
        DEBUG_TERM_UNIT="cod-fov-changer-debug-$$"
        systemd-run --user --unit="$DEBUG_TERM_UNIT" --collect --quiet -- "${argv[@]}"
    else
        # On non-systemd setups the terminal stays a child of this script,
        # so Steam's process scan still attributes it to the game.
        #
        # LD_LIBRARY_PATH is cleared here: Steam points it at its own bundled
        # runtime libs for the game's benefit, which shadowed a system lib
        # konsole needed and broke its startup.
        ( unset LD_LIBRARY_PATH; exec "${argv[@]}" ) &
        DEBUG_TERM_PID=$!
    fi
}

# Redirects the caller's stdout/stderr into DEBUG_LOG, and if stdout isn't a
# TTY and a game command was given (wrapper mode), spawns a terminal tailing
# that log. Sets DEBUG_LOG and DEBUG_TERM_UNIT/DEBUG_TERM_PID for the caller.
start_debug_output() {
    DEBUG_LOG="${XDG_RUNTIME_DIR:-/tmp}/cod-fov-changer-debug.log"
    {
        log "DISPLAY=${DISPLAY:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}" \
            "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"

        if [[ ! -t 1 && $# -gt 0 ]]; then
            DEBUG_TERM_APP=$(pick_terminal) || DEBUG_TERM_APP=""

            if [[ -n "$DEBUG_TERM_APP" ]]; then
                open_terminal "$DEBUG_TERM_APP" \
                    "tail -f '$DEBUG_LOG' | grep --line-buffered -E '^\[cod-fov|(WARN|ERROR).*pika'" >>"$DEBUG_LOG" 2>&1
            else
                log "No terminal emulator found for --debug; check $DEBUG_LOG manually."
            fi
        fi
    } >"$DEBUG_LOG" 2>&1

    exec > >(tee -a "$DEBUG_LOG") 2>&1
    log "Debug log: $DEBUG_LOG"
}

# Stops the systemd-run unit if the terminal used one, otherwise kills the
# fallback's background job.
stop_debug_terminal() {
    if [[ -n "$DEBUG_TERM_UNIT" ]]; then
        systemctl --user stop "$DEBUG_TERM_UNIT.service" >/dev/null 2>&1 || true
    elif [[ -n "$DEBUG_TERM_PID" ]]; then
        kill "$DEBUG_TERM_PID" 2>/dev/null || true
    fi
}
