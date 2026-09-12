#!/usr/bin/env bash
set -euo pipefail

# Usage and flags: see README.md.

CG_FOV="90.0"
CG_FOVSCALE="1.0"
COM_MAXFPS="250"
FORCE_CONFIG=0
CONFIG_FILE_OVERRIDE=""
DEBUG=0
GAME_EXES="iw4mp.exe iw4sp.exe iw5mp.exe iw5sp.exe"

# Always stderr, not stdout: several functions' stdout is a data channel
# (mapfile/command substitution reads addresses from it) that a tagged
# line would corrupt. The "[cod-fov]" prefix lets --debug's filter exclude noise.
log() {
    echo "[cod-fov] $*" >&2
}

debug() {
    [[ "$DEBUG" -eq 1 ]] || return 0
    echo "[cod-fov:debug] $*" >&2
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

if [[ "$DEBUG" -eq 1 ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/debug.sh"
    start_debug_output "$@"
fi

GAME_PID=""

if [[ $# -gt 0 ]]; then
    "$@" &
    GAME_PID=$!
    log "Launched game (PID $GAME_PID), waiting for ${GAME_EXES// //}..."
fi

STARTED_DAEMON=0
PIKA_PID=""
PIKA_LOG=""
FROZEN_ADDRS=()

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
    local addr
    for addr in "${FROZEN_ADDRS[@]}"; do
        debug "Unfreezing $addr"
        pika unfreeze "$addr" >/dev/null 2>&1 || true
    done

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
    match=$(pika ps | awk -v exes="$GAME_EXES" '
        BEGIN { n = split(exes, arr, " ") }
        { for (i = 1; i <= n; i++) if ($2 == arr[i]) { print $1, $2; exit } }
    ')
    PID="${match%% *}"
    GAME_EXE="${match#* }"

    if [[ -z "${PID:-}" ]]; then
        log "${GAME_EXES// //} is not running."
        exit 1
    fi

    log "Found $GAME_EXE with PID $PID"
else
    while :; do
        match=$(pika ps 2>/dev/null | awk -v exes="$GAME_EXES" '
            BEGIN { n = split(exes, arr, " ") }
            { for (i = 1; i <= n; i++) if ($2 == arr[i]) { print $1, $2; exit } }
        ') || true
        PID="${match%% *}"
        GAME_EXE="${match#* }"

        if [[ -n "$PID" ]]; then
            break
        fi

        if ! kill -0 "$GAME_PID" 2>/dev/null; then
            log "Game process exited before ${GAME_EXES// //} was detected."
            wait "$GAME_PID" 2>/dev/null
            exit $?
        fi

        sleep 1
    done

    log "Found $GAME_EXE with PID $PID"

    # Sleeping for 5 seconds to let the game finish loading.
    sleep 5
fi

CONFIG_FILE="${CONFIG_FILE_OVERRIDE:-${XDG_CONFIG_HOME:-$HOME/.config}/cod-fov-changer.conf}"

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
# actually the right dvars can crash the game once the dvar values are frozen.
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

# Locates each dvar's address by pattern-scanning memory 
# for the name string, then scanning for a pointer to check it's plausability.

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

# Prints "<start> <end>" spanning every mapped region backed by the game's
# own exe file, so scans can exclude a duplicate string/pointer elsewhere in
# the process (e.g. a separate module only loaded once a level is loaded)
game_module_range() {
    pika maps "$PID" --json 2>/dev/null | jq -r --arg exe "$GAME_EXE" '
        [.[] | select((.pathname | ascii_downcase) | endswith($exe | ascii_downcase))]
        | select(length > 0)
        | "\(map(.start) | min) \(map(.end) | max)"
    '
}

# Name string constants live in read-only memory (.rdata/.rodata),
# which pika's aob scan excludes unless told otherwise. Filtered to
# MODULE_START/MODULE_END (see game_module_range) to exclude the same
# string appearing in a different module.
find_name_string_candidates() {
    local addr
    while read -r addr; do
        (( addr >= MODULE_START && addr < MODULE_END )) && echo "$addr"
    done < <(aob_addresses "$(name_to_hex "$1")" --include-readonly)
}

find_field_pointers_for() {
    local addr
    while read -r addr; do
        (( addr >= MODULE_START && addr < MODULE_END )) && echo "$addr"
    done < <(aob_addresses "$(addr_to_le_hex "$1")")
}

# Pools field-pointer candidates across every name-string match for $1,
# tolerating a dvar's name string having an unrelated second copy
# elsewhere in the module (observed for cg_fov and cg_fovScale).
pool_field_candidates() {
    local name="$1"
    local -a name_hits ptr_hits all_hits=()
    local addr

    mapfile -t name_hits < <(find_name_string_candidates "$name")
    debug "'$name' name string: ${#name_hits[@]} match(es) (${name_hits[*]:-none})"

    if [[ "${#name_hits[@]}" -eq 0 ]]; then
        log "Discovery: no '$name' name string found."
        return 1
    fi

    for addr in "${name_hits[@]}"; do
        mapfile -t ptr_hits < <(find_field_pointers_for "$addr")
        debug "'$name' field pointer for $addr: ${#ptr_hits[@]} candidate(s) (${ptr_hits[*]:-none})"
        all_hits+=("${ptr_hits[@]}")
    done

    if [[ "${#all_hits[@]}" -eq 0 ]]; then
        log "Discovery: no field pointer found for '$name'."
        return 1
    fi

    printf '%s\n' "${all_hits[@]}"
}

# Picks whichever pooled candidate for $1 has a plausible current value for
# $2 (the key is_plausible_value expects) at the already-known $3
# value_offset - cg_fovScale/com_maxfps have no known factory default to
# calibrate against like cg_fov does, so plausibility is the disambiguator.
resolve_dvar_field() {
    local name="$1" plausibility_key="$2" value_offset="$3"
    local -a candidates plausible=()
    local field

    mapfile -t candidates < <(pool_field_candidates "$name") || return 1

    for field in "${candidates[@]}"; do
        is_plausible_value "$plausibility_key" "$(printf '0x%x' $(( field + value_offset )))" && plausible+=("$field")
    done

    if [[ "${#plausible[@]}" -ne 1 ]]; then
        log "Discovery: '$name' has ${#candidates[@]} field candidate(s), ${#plausible[@]} plausible - expected exactly 1."
        return 1
    fi

    echo "${plausible[0]}"
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
    local field value_offset fovscale_field maxfps_field
    local -a fov_candidates

    read -r MODULE_START MODULE_END < <(game_module_range) || {
        log "Discovery: couldn't find $GAME_EXE's own module in memory."
        return 1
    }
    debug "$GAME_EXE module range: $(printf '0x%x-0x%x' "$MODULE_START" "$MODULE_END")"

    mapfile -t fov_candidates < <(pool_field_candidates "cg_fov")
    [[ "${#fov_candidates[@]}" -gt 0 ]] || return 1

    read -r field value_offset < <(calibrate_value_offset "${fov_candidates[@]}") || {
        log "Discovery: couldn't calibrate cg_fov's value offset (no candidate held 65.0 in the expected window)."
        return 1
    }

    CG_FOV_VALUE=$(printf '0x%x' $(( field + value_offset )))

    fovscale_field=$(resolve_dvar_field "cg_fovScale" "cg_fovscale" "$value_offset") || return 1
    maxfps_field=$(resolve_dvar_field "com_maxfps" "com_maxfps" "$value_offset") || return 1

    CG_FOVSCALE_VALUE=$(printf '0x%x' $(( fovscale_field + value_offset )))
    COM_MAXFPS_VALUE=$(printf '0x%x' $(( maxfps_field + value_offset )))
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

        # Dvars can be unregistered until the game is past its main menu
        # (e.g. singleplayer only creates cg_fov's dvar_t once a level is
        # loaded), so a single discovery attempt right after launch can
        # find the name string but no dvar_t referencing it yet.
        DISCOVERY_RETRY_INTERVAL=3
        DISCOVERY_TIMEOUT=120
        elapsed=0

        until discover_dvar_addresses; do
            if ! kill -0 "$PID" 2>/dev/null; then
                log "Game process exited during discovery."
                exit 1
            fi

            elapsed=$(( elapsed + DISCOVERY_RETRY_INTERVAL ))
            if [[ "$elapsed" -ge "$DISCOVERY_TIMEOUT" ]]; then
                log "Dynamic address discovery timed out after ${DISCOVERY_TIMEOUT}s."
                exit 1
            fi

            log "Retrying in ${DISCOVERY_RETRY_INTERVAL}s (make sure you're past the main menu, in a loaded level/match)..."
            sleep "$DISCOVERY_RETRY_INTERVAL"
        done

        log "Discovered cg_fov=$CG_FOV_VALUE cg_fovScale=$CG_FOVSCALE_VALUE com_maxfps=$COM_MAXFPS_VALUE"
        save_config
    fi
fi

is_game_running() {
    pika ps 2>/dev/null | awk -v pid="$PID" -v exe="$GAME_EXE" '$1 == pid && $2 == exe { found=1 } END { exit !found }'
}

debug "Freezing cg_fov=$CG_FOV at $CG_FOV_VALUE (f32, interval 250ms)"
pika freeze --dtype f32 --interval 250 "$PID" "$CG_FOV_VALUE" "$CG_FOV"
FROZEN_ADDRS+=("$CG_FOV_VALUE")
debug "Freezing cg_fovScale=$CG_FOVSCALE at $CG_FOVSCALE_VALUE (f32, interval 250ms)"
pika freeze --dtype f32 --interval 250 "$PID" "$CG_FOVSCALE_VALUE" "$CG_FOVSCALE"
FROZEN_ADDRS+=("$CG_FOVSCALE_VALUE")
debug "Freezing com_maxfps=$COM_MAXFPS at $COM_MAXFPS_VALUE (i32, interval 250ms)"
pika freeze --dtype i32 --interval 250 "$PID" "$COM_MAXFPS_VALUE" "$COM_MAXFPS"
FROZEN_ADDRS+=("$COM_MAXFPS_VALUE")

log "Set cg_fov      = $CG_FOV at $CG_FOV_VALUE"
log "Set cg_fovScale = $CG_FOVSCALE at $CG_FOVSCALE_VALUE"
log "Set com_maxfps  = $COM_MAXFPS at $COM_MAXFPS_VALUE"

while is_game_running; do
    sleep 1
done

log "$GAME_EXE exited."

if [[ "$DEBUG" -eq 1 ]]; then
    stop_debug_terminal
fi

if [[ -n "$GAME_PID" ]]; then
    wait "$GAME_PID" 2>/dev/null
    exit $?
fi
