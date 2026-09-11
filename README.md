# MW2 FOV Changer

Modern Warfare 2 (2009) FOV and FPS changer for Linux using [pika](https://github.com/delfianto/pika). Works against both `iw4mp.exe` (multiplayer) and `iw4sp.exe` (singleplayer).

## Requirements

- Linux, with the game running under Wine/Proton
- [`pika`](https://github.com/delfianto/pika) installed and on `PATH`
- `jq` (used to parse `pika read --json` output)
- `bash`

## Usage

**Standalone** - run after `iw4mp.exe`/`iw4sp.exe` is already up:

```bash
./mw2-fov-changer.sh
```

**Wrapper** - use in launch options:

```
/path/to/script/mw2-fov-changer.sh --fov 90 --fovscale 1.2 --fps 125 %command%
```

### Flags

| Flag                 | Controls        | Default |
|----------------------|------------------|---------|
| `--fov`              | `cg_fov`         | `90.0`  |
| `--fovscale`         | `cg_fovScale`    | `1.0`   |
| `--fps`              | `com_maxfps`     | `250`   |
| `--force-config`     | use the saved config's addresses directly, with no validity check | off |
| `--config-file <path>` | read/write the config at this path instead of the default | off |

## How it works

1. In wrapper mode, starts the script and game then
   waits for `iw4mp.exe` or `iw4sp.exe` to show up in `pika ps`. In
   standalone mode, the game needs to already be running.
2. Starts a `pika serve` daemon at its default socket
   (`/tmp/pika.sock`) if one isn't already reachable there.
3. Locates `cg_fov`/`cg_fovScale`/`com_maxfps`'s live addresses: uses the
   saved config if one exists and its values still look plausible,
   otherwise pattern-scans the game's memory (see "Dynamic address
   discovery" below) and saves the result for next time - unless
   `--force-config` was passed (see "Saved address config").
4. Writes all three values once via `pika write`.
5. Starts a background loop (`correct_dvars`) that polls each value every
   250ms via `pika read` and only re-writes it if it's drifted from the
   target, e.g. the game resets `cg_fov` on death.

## Dynamic address discovery

Scans are restricted to memory mapped from the game's own exe file (via
`pika maps`), excluding other loaded modules - the same restriction
[CoD-FoV-Changers](https://github.com/AgentRev/CoD-FoV-Changers) uses,
needed because a dvar's name string can have a duplicate copy elsewhere
in the process (observed on `iw4sp.exe` once a level is loaded).

1. AOB-scans process memory for the dvar's ASCII name (e.g. `"cg_fov\0"`)
   to find where the name string itself lives.
2. AOB-scans for an 8-byte pointer value equal to that address, to find
   the `dvar_t` struct field that references it.
3. For `cg_fov` only: probes a small offset window from that field for
   its known default value (`65.0`) to calibrate the byte offset
   from that field to the dvar's live value - the same struct-layout
   offset applies to every dvar, so it's derived once and reused.
4. Repeats steps 1-2 for `cg_fovScale`/`com_maxfps` and applies the same
   offset to each.

If discovery fails, it retries every 3 seconds for up to 2 minutes before
giving up - dvars can be unregistered until you're past the main menu
(e.g. `iw4sp.exe` only creates `cg_fov`'s `dvar_t` once a level is loaded).

## Config

Once discovery succeeds, the resolved addresses are saved to 
`${XDG_CONFIG_HOME:-$HOME/.config}/mw2-fov-changer.conf` overridable with `--config-file <path>` 
and reused on subsequent runs instead of re-scanning. Addresses are stored
under a section named for the running binary (e.g. `[iw4mp.exe]`,
`[iw4sp.exe]`), so mp and sp addresses never overwrite each other:

- **Default**: if the config has a section for the current binary and all
  three addresses in it read back a plausible value for their dvar
  (`config_values_plausible`, e.g. `cg_fov` between 1 and 180), use them
  directly, skipping discovery. Otherwise (missing, incomplete, or a value
  out of range) fall back to full discovery as normal, and save the fresh
  result on success.
- **`--force-config`**: use the saved config directly with no validity
  check at all - errors out if there's no usable section for the current
  binary yet.
