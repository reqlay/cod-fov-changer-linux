#!/usr/bin/env bash
# Sourced by mw2-fov-changer.sh when --debug is passed. Not meant to run standalone.

# Terminal used for --debug output if stdout isn't a TTY. Picks the first available.
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

# LD_LIBRARY_PATH is cleared for the launched terminal: Steam points it
# at its own bundled runtime libs for the game's benefit, which shadowed
# a system lib konsole needed and broke its startup.
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

    ( unset LD_LIBRARY_PATH; exec "${argv[@]}" ) &
}

# Redirects the caller's stdout/stderr into DEBUG_LOG, and if stdout isn't a
# TTY (e.g. launched via Steam), spawns a terminal tailing that log. Sets
# DEBUG_LOG and DEBUG_TERM_PID for the caller.
start_debug_output() {
    DEBUG_LOG="${XDG_RUNTIME_DIR:-/tmp}/mw2-fov-changer-debug.log"
    {
        log "DISPLAY=${DISPLAY:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}" \
            "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-<unset>} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"

        if [[ ! -t 1 ]]; then
            DEBUG_TERM_APP=$(pick_terminal) || DEBUG_TERM_APP=""

            if [[ -n "$DEBUG_TERM_APP" ]]; then
                open_terminal "$DEBUG_TERM_APP" \
                    "tail -f '$DEBUG_LOG' | grep --line-buffered -E '^\[mw2-fov|(WARN|ERROR).*pika'" >>"$DEBUG_LOG" 2>&1
                DEBUG_TERM_PID=$!
            else
                log "No terminal emulator found for --debug; check $DEBUG_LOG manually."
            fi
        fi
    } >"$DEBUG_LOG" 2>&1

    exec > >(tee -a "$DEBUG_LOG") 2>&1
    log "Debug log: $DEBUG_LOG"
}
