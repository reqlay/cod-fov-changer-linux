#!/usr/bin/env bash
set -euo pipefail

# Usage and flags: see README.md.

CG_FOV="90.0"
CG_FOVSCALE="1.0"
COM_MAXFPS="250"
FORCE_CONFIG=0
CONFIG_FILE_OVERRIDE=""
DEBUG=0

# Always stderr, not stdout: several functions' stdout is a data channel
# (mapfile/command substitution reads addresses from it) that a tagged
# line would corrupt. The "[mw2-fov]" prefix lets --debug's filter exclude noise.
log() {
    echo "[mw2-fov] $*" >&2
}

debug() {
    [[ "$DEBUG" -eq 1 ]] || return 0
    echo "[mw2-fov:debug] $*" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fov)
            CG_FOV="$2"
            shift 2
            ;;
        --fovscale)
            CG_FOVSCALE="$2"
            shift 2
            ;;
        --fps)
            COM_MAXFPS="$2"
            shift 2
            ;;
        --force-config)
            FORCE_CONFIG=1
            shift
            ;;
        --config-file)
            CONFIG_FILE_OVERRIDE="$2"
            shift 2
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

DEBUG_LOG=""
DEBUG_TERM_PID=""

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

if [[ "$DEBUG" -eq 1 ]]; then
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
fi

GAME_PID=""

if [[ $# -gt 0 ]]; then
    "$@" &
    GAME_PID=$!
    log "Launched game (PID $GAME_PID), waiting for iw4mp.exe/iw4sp.exe..."
fi

STARTED_DAEMON=0
PIKA_PID=""
PIKA_LOG=""
CORRECTOR_PID=""

pika() { command pika $([[ "$DEBUG" -eq 1 ]] && echo -v) "$@"; }

if ! pika sessions >/dev/null 2>&1; then
    PIKA_LOG=$(mktemp)

    # pika is a function, so pika serve & would background a subshell
    # running it, making $! name that subshell rather than the pika
    # process it execs — exec inside the subshell fixes that.
    if [[ "$DEBUG" -eq 1 ]]; then
        ( exec pika -v serve > >(tee -a "$PIKA_LOG" >>"$DEBUG_LOG") 2>&1 ) &
    else
        ( exec pika serve >"$PIKA_LOG" 2>&1 ) &
    fi
    PIKA_PID=$!
    STARTED_DAEMON=1

    for _ in {1..50}; do
        if pika sessions >/dev/null 2>&1; then
            break
        fi

        if ! kill -0 "$PIKA_PID" 2>/dev/null; then
            log "pika serve exited unexpectedly:"
            cat "$PIKA_LOG"
            exit 1
        fi

        sleep 0.1
    done

    if ! pika sessions >/dev/null 2>&1; then
        log "Pika daemon did not become ready."
        cat "$PIKA_LOG"
        exit 1
    fi
fi

cleanup() {
    if [[ -n "$CORRECTOR_PID" ]]; then
        kill "$CORRECTOR_PID" 2>/dev/null || true
        wait "$CORRECTOR_PID" 2>/dev/null || true
    fi

    if [[ "$STARTED_DAEMON" -eq 1 && -n "$PIKA_PID" ]]; then
        kill "$PIKA_PID" 2>/dev/null || true
        wait "$PIKA_PID" 2>/dev/null || true
    fi

    if [[ -n "$PIKA_LOG" ]]; then
        rm -f "$PIKA_LOG"
    fi

    # Debug terminal is closed explicitly on normal exit (below), not here —
    # this runs on every exit, and a window that vanishes with the error is
    # useless for reading it.
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PID=""
GAME_EXE=""

if [[ -z "$GAME_PID" ]]; then
    match=$(pika ps | awk '$2 == "iw4mp.exe" || $2 == "iw4sp.exe" { print $1, $2; exit }')
    PID="${match%% *}"
    GAME_EXE="${match#* }"

    if [[ -z "${PID:-}" ]]; then
        log "iw4mp.exe/iw4sp.exe is not running."
        exit 1
    fi

    log "Found $GAME_EXE with PID $PID"
else
    while :; do
        match=$(pika ps 2>/dev/null | awk '$2 == "iw4mp.exe" || $2 == "iw4sp.exe" { print $1, $2; exit }') || true
        PID="${match%% *}"
        GAME_EXE="${match#* }"

        if [[ -n "$PID" ]]; then
            break
        fi

        if ! kill -0 "$GAME_PID" 2>/dev/null; then
            log "Game process exited before iw4mp.exe/iw4sp.exe was detected."
            wait "$GAME_PID" 2>/dev/null
            exit $?
        fi

        sleep 1
    done

    log "Found $GAME_EXE with PID $PID"

    # Sleeping for 5 seconds to let the game finish loading
    sleep 5
fi

CONFIG_FILE="${CONFIG_FILE_OVERRIDE:-${XDG_CONFIG_HOME:-$HOME/.config}/mw2-fov-changer.conf}"

# Config sections are keyed by process name (e.g. "[iw4mp.exe]") so one
# file can hold addresses for multiple binaries/games without collision.
config_section() {
    awk -v exe="$GAME_EXE" '
        $0 == "[" exe "]" { found=1; next }
        /^\[/ { found=0 }
        found { print }
    ' "$CONFIG_FILE"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 1

    CG_FOV_VALUE="" CG_FOVSCALE_VALUE="" COM_MAXFPS_VALUE=""
    # shellcheck disable=SC1090
    source <(config_section) 2>/dev/null || return 1

    [[ -n "$CG_FOV_VALUE" && -n "$CG_FOVSCALE_VALUE" && -n "$COM_MAXFPS_VALUE" ]]
}

# Only call after a verified discover_dvar_addresses success — not after
# --force-config, which doesn't confirm this build's address.
save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"

    local tmp
    tmp=$(mktemp)

    if [[ -f "$CONFIG_FILE" ]]; then
        awk -v exe="$GAME_EXE" '
            $0 == "[" exe "]" { skip=1; next }
            /^\[/ { skip=0 }
            !skip { print }
        ' "$CONFIG_FILE" > "$tmp"
    fi

    {
        echo "[$GAME_EXE]"
        echo "CG_FOV_VALUE=$CG_FOV_VALUE"
        echo "CG_FOVSCALE_VALUE=$CG_FOVSCALE_VALUE"
        echo "COM_MAXFPS_VALUE=$COM_MAXFPS_VALUE"
    } >> "$tmp"

    mv "$tmp" "$CONFIG_FILE"
    log "Saved discovered addresses to $CONFIG_FILE (section [$GAME_EXE])"
}

# Not currently called (see config_values_plausible below, the active
# check) — kept as a faster, less-strict fallback if that one ever
# proves too slow or too strict in practice.
config_addresses_readable() {
    local addr
    for addr in "$CG_FOV_VALUE" "$CG_FOVSCALE_VALUE" "$COM_MAXFPS_VALUE"; do
        pika read "$PID" "$addr" -l 4 --json >/dev/null 2>&1 || return 1
    done
    return 0
}

# A wrong address can still read successfully  
# a manually-corrupted config with addresses that read fine but weren't
# actually the right dvars can crash the game once correct_dvars are written.
is_plausible_value() {
    local dvar="$1" addr="$2" dtype="f32" val

    [[ "$dvar" == "com_maxfps" ]] && dtype="i32"

    val=$(pika read "$PID" "$addr" -l 4 --json 2>/dev/null | jq -r ".interpretations.${dtype} // empty") || return 1
    [[ -n "$val" ]] || return 1

    case "$dvar" in
        cg_fov)      awk -v v="$val" 'BEGIN { exit !(v >= 1 && v <= 180) }' ;;
        cg_fovscale) awk -v v="$val" 'BEGIN { exit !(v >= 0.2 && v <= 2) }' ;;
        com_maxfps)  awk -v v="$val" 'BEGIN { exit !(v >= 0 && v <= 1000) }' ;;
        *)           return 1 ;;
    esac
}

config_values_plausible() {
    is_plausible_value cg_fov "$CG_FOV_VALUE" &&
    is_plausible_value cg_fovscale "$CG_FOVSCALE_VALUE" &&
    is_plausible_value com_maxfps "$COM_MAXFPS_VALUE"
}

# Locates each dvar's address by pattern-scanning memory instead of
# trusting one tied to a specific build (see AGENTS.md). Only cg_fov's
# calibration probe can disambiguate multiple pointer candidates, so
# cg_fovScale/com_maxfps treat any ambiguity as a hard failure rather than guess.

name_to_hex() {
    local name="$1" out="" i
    for ((i = 0; i < ${#name}; i++)); do
        printf -v byte '%02x' "'${name:$i:1}"
        out+="$byte "
    done
    echo "${out}00"
}

addr_to_le_hex() {
    local addr_dec=$(( $1 )) i byte out=""
    for ((i = 0; i < 8; i++)); do
        byte=$(( (addr_dec >> (i * 8)) & 0xFF ))
        printf -v hex '%02x' "$byte"
        out+="$hex "
    done
    echo "${out% }"
}

aob_addresses() {
    local pattern="$1" extra_flags="${2:-}" hits
    hits=$(pika aob "$PID" "$pattern" $extra_flags --json 2>/dev/null) || return 1
    jq -r '.addresses[]' <<<"$hits" 2>/dev/null
}

find_dvar_field_candidates() {
    local name="$1" ptr_pattern
    local -a name_hits ptr_hits

    # Name string constants live in read-only memory (.rdata/.rodata),
    # which pika's aob scan excludes unless told otherwise.
    mapfile -t name_hits < <(aob_addresses "$(name_to_hex "$name")" --include-readonly)
    debug "'$name' name string: ${#name_hits[@]} match(es) (${name_hits[*]:-none})"

    if [[ "${#name_hits[@]}" -ne 1 ]]; then
        log "Discovery: expected exactly one '$name' name string, found ${#name_hits[@]}."
        return 1
    fi

    ptr_pattern=$(addr_to_le_hex "${name_hits[0]}")
    mapfile -t ptr_hits < <(aob_addresses "$ptr_pattern")
    debug "'$name' field pointer: ${#ptr_hits[@]} candidate(s) (${ptr_hits[*]:-none})"

    # printf with an empty array still prints one blank line, which the
    # caller's mapfile would count as a single (bogus, empty) candidate —
    # bypassing the "-ne 1 candidates" check that's supposed to catch this.
    if [[ "${#ptr_hits[@]}" -gt 0 ]]; then
        printf '%s\n' "${ptr_hits[@]}"
    fi
}

# Prints "<field_addr> <value_offset>" for whichever candidate matches.
calibrate_value_offset() {
    local field off candidate_dec hex_addr val

    for field in "$@"; do
        for off in 0x28 0x2c 0x30 0x34 0x38 0x3c; do
            candidate_dec=$(( field + off ))
            printf -v hex_addr '0x%x' "$candidate_dec"
            val=$(pika read "$PID" "$hex_addr" -l 4 --json 2>/dev/null | jq -r '.interpretations.f32 // empty') || true

            if [[ -n "$val" ]] && awk -v v="$val" 'BEGIN { exit !(v == 65) }'; then
                debug "calibration: field 0x$(printf %x "$field") + $off = 65.0, value_offset=$(( off - 0x20 ))"
                echo "$field $(( off - 0x20 ))"
                return 0
            fi
        done
    done

    return 1
}

discover_dvar_addresses() {
    local field value_offset
    local -a fov_candidates fovscale_candidates maxfps_candidates

    mapfile -t fov_candidates < <(find_dvar_field_candidates "cg_fov") || return 1

    read -r field value_offset < <(calibrate_value_offset "${fov_candidates[@]}") || {
        log "Discovery: couldn't calibrate cg_fov's value offset (no candidate held 65.0 in the expected window)."
        return 1
    }

    CG_FOV_VALUE=$(printf '0x%x' $(( field + value_offset )))

    mapfile -t fovscale_candidates < <(find_dvar_field_candidates "cg_fovScale") || return 1
    mapfile -t maxfps_candidates < <(find_dvar_field_candidates "com_maxfps") || return 1

    if [[ "${#fovscale_candidates[@]}" -ne 1 ]]; then
        log "Discovery: cg_fovScale name pointer found ${#fovscale_candidates[@]} candidates, expected exactly 1."
        return 1
    fi

    if [[ "${#maxfps_candidates[@]}" -ne 1 ]]; then
        log "Discovery: com_maxfps name pointer found ${#maxfps_candidates[@]} candidates, expected exactly 1."
        return 1
    fi

    CG_FOVSCALE_VALUE=$(printf '0x%x' $(( fovscale_candidates[0] + value_offset )))
    COM_MAXFPS_VALUE=$(printf '0x%x' $(( maxfps_candidates[0] + value_offset )))
}

if [[ "$FORCE_CONFIG" -eq 1 ]]; then
    if ! load_config; then
        log "Error: --force-config given but no usable [$GAME_EXE] section in $CONFIG_FILE."
        exit 1
    fi
    log "Using addresses from config (--force-config, unverified):" \
        "cg_fov=$CG_FOV_VALUE cg_fovScale=$CG_FOVSCALE_VALUE com_maxfps=$COM_MAXFPS_VALUE"
else
    USED_CONFIG=0

    if load_config && config_values_plausible; then
        USED_CONFIG=1
        log "Using saved addresses from $CONFIG_FILE:" \
            "cg_fov=$CG_FOV_VALUE cg_fovScale=$CG_FOVSCALE_VALUE com_maxfps=$COM_MAXFPS_VALUE"
    fi

    if [[ "$USED_CONFIG" -eq 0 ]]; then
        log "Locating dvar addresses..."
        if ! discover_dvar_addresses; then
            log "Dynamic address discovery failed."
            exit 1
        fi
        log "Discovered cg_fov=$CG_FOV_VALUE cg_fovScale=$CG_FOVSCALE_VALUE com_maxfps=$COM_MAXFPS_VALUE"
        save_config
    fi
fi

is_game_running() {
    pika ps 2>/dev/null | awk -v pid="$PID" -v exe="$GAME_EXE" '$1 == pid && $2 == exe { found=1 } END { exit !found }'
}

correct_dvars() {
    while is_game_running; do
        for entry in \
            "$CG_FOV_VALUE:$CG_FOV:f32" \
            "$CG_FOVSCALE_VALUE:$CG_FOVSCALE:f32" \
            "$COM_MAXFPS_VALUE:$COM_MAXFPS:i32"; do
            addr="${entry%%:*}"
            rest="${entry#*:}"
            target="${rest%%:*}"
            dtype="${rest#*:}"

            current=$(pika read "$PID" "$addr" -l 4 --json 2>/dev/null | jq -r ".interpretations.${dtype} // empty" 2>/dev/null) || true

            if [[ -n "$current" ]]; then
                differs=$(awk -v a="$current" -v b="$target" 'BEGIN { print (a != b) }')
                if [[ "$differs" -eq 1 ]]; then
                    debug "$addr drifted ($current -> $target), rewriting"
                    pika write --dtype "$dtype" "$PID" "$addr" "$target" >/dev/null
                fi
            fi
        done

        sleep 0.25
    done
}

pika write --dtype f32 "$PID" "$CG_FOV_VALUE" "$CG_FOV"
pika write --dtype f32 "$PID" "$CG_FOVSCALE_VALUE" "$CG_FOVSCALE"
pika write --dtype i32 "$PID" "$COM_MAXFPS_VALUE" "$COM_MAXFPS"

correct_dvars &
CORRECTOR_PID=$!

log "Set cg_fov      = $CG_FOV at $CG_FOV_VALUE"
log "Set cg_fovScale = $CG_FOVSCALE at $CG_FOVSCALE_VALUE"
log "Set com_maxfps  = $COM_MAXFPS at $COM_MAXFPS_VALUE"

while is_game_running; do
    sleep 1
done

log "$GAME_EXE exited."

if [[ -n "$DEBUG_TERM_PID" ]]; then
    kill "$DEBUG_TERM_PID" 2>/dev/null || true
fi

if [[ -n "$GAME_PID" ]]; then
    wait "$GAME_PID" 2>/dev/null
    exit $?
fi
