# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-file Lua program that renders a custom online-clients dashboard onto the GL.iNet BE3600 / IPQ5332 router's built-in touchscreen, replacing the stock `gl_screen` UI. There is no build step and no test suite — the entire runtime is `src/skyris_screen_clients.lua`, which runs **on the router** under the router's `/usr/bin/lua`.

## Development workflow

This code cannot run on the dev machine — it depends on router-only resources (`/dev/fb0`, `/dev/input/event0`, `ubus`, `/etc/init.d/gl_screen`, `gl_screen -l`). The loop is: edit locally → syntax check → push to router → observe over SSH.

```sh
# Syntax check before deploying (only static check available locally)
luac -p src/skyris_screen_clients.lua

# Deploy local script to the router (streams over SSH; works even without sftp-server)
./scripts/install.sh root@192.168.3.1

# Render one frame (stops stock screen first)
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients once'

# Restart the refresh daemon
# Restart the refresh daemon (relaunching self-replaces a running instance)
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients daemon >/tmp/skyris_screen_clients.log 2>&1 &'

# Tail runtime log (tap coordinates, sleep/wake, OEM60, settings)
ssh root@192.168.3.1 'tail -50 /tmp/skyris_screen_clients.log'

# Restore the stock screen and kill the daemon
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients stop'
```

The script's CLI verbs (dispatched at the bottom of the file): `once`, `daemon`, `oem60`, `restore`, `stop`.

## Architecture

Everything is in `src/skyris_screen_clients.lua`. The key concepts that span the file:

- **Two coordinate systems.** All drawing happens on a logical `284x76` landscape canvas (`LOG_W`/`LOG_H`). The physical framebuffer is `76x284` portrait (`FB_W`/`FB_H`). `rotate_cw_to_fb()` rotates the logical buffer clockwise into framebuffer bytes at write time. Touch input arrives in framebuffer space and is inverted back to logical coordinates by `map_touch_to_log()`. Any change to drawing positions, the OEM60 hit-box, or touch handling must keep these two spaces consistent.

- **Framebuffer model.** The canvas is a Lua table of rows, each row a string of RGB565 little-endian byte-pairs (2 bytes/pixel). `setpix`/`fill`/`rect`/`text` mutate rows via string slicing; `draw_page()` builds a frame and writes the rotated result to `/dev/fb0` in one `io.write`. Colors are precomputed with `rgb565()`. Text uses a built-in 5x7 bitmap `FONT` table (ASCII only — non-alphanumeric chars are stripped by `sanitize()`, so device names with CJK/symbols won't render).

- **Data source.** `read_clients()` shells out to `ubus call gl-clients list`, decodes JSON with `cjson`, and keeps only `online == true` entries, grouping by `iface` (`2.4G` / `5G` / `cable`).

- **Stock-screen coordination.** The custom UI and the stock `gl_screen` both own `/dev/fb0`, so they must never run simultaneously. The daemon calls `/etc/init.d/gl_screen stop` on start; `oem60` restarts stock for 60s then stops it again; `stop`/`restore` hand control back to stock. `read_stock_screen_settings()` reads the user's preferences straight from **uci** (`gl_screen.generic` for brightness / auto-lock / always-on, `gl_timer.screen` for the scheduled on/off timer) so they match the GL admin UI exactly — `gl_screen -l` is only a fallback because it can report stale defaults (e.g. AUTO_LOCK_TIME 600 vs the configured 180).

- **Screen power state.** The daemon tracks `awake` plus an `off_reason` (`schedule` | `idle` | `manual` | `temp`). Each loop it reads settings once and computes `sched = scheduled_off(settings)`. A `prev_sched`→`sched` falling edge is the scheduled turn-on moment (lights the screen regardless of why it was off). During a scheduled-off window a tap is a *temporary* wake (`off_reason = 'temp'`) that re-blanks after `TEMP_WAKE_SECS` (20s) of inactivity; taps extend it. Outside a scheduled window the normal auto-lock idle timeout applies. `active_gesture()` holds the shared awake-state gesture handling (swipe nav / menu dispatch / edge nav) used by both the normal-wake and temporary-wake paths.

- **View model.** The UI is a linear list of swipeable views rendered by `draw_page(message, page)`: view 0 is the clean **Home** overview, view 1 is **Network speed**, view 2 is **System** status, views `DEV_START..` are paginated **Device** list pages (`PER_PAGE` = 18, a 3-col × 6-row grid built into `DEVICE_POSITIONS`), and the last view is the **Menu** of function buttons. `draw_page` computes `total_views = DEV_START + device_pages + 1`, clamps `page` into range, and returns `(page, total_views)` so the daemon's paging state stays valid as the client count changes. The daemon decides how a tap is handled by index (`page >= total-1` → menu button dispatch; otherwise edge-tap navigates or refreshes).

- **Metrics.** All system data is read-only (`/proc`, `/sys/class/thermal`, `df`). Download/upload rate (WAN = `eth0`, `/proc/net/dev`) and CPU% (`/proc/stat`) require two samples over time: `sample_rates()` keeps the previous counters and computes deltas into `metrics_cache`, and the daemon calls it once per loop so values stay ~5s fresh regardless of the visible view. `ensure_rates()` is the one-shot path (used by `once`) — it samples, sleeps 1s, and samples again. Memory/temperature/load/flash/uptime are instantaneous reads done at draw time. The System page also shows a temperature trend (`draw_temp_sparkline`, fixed 40–90 °C band): `sample_temp()` appends `read_temp_c()` to `temp_hist` each daemon loop and persists it to `/tmp/skyris_temp_hist`, so a one-shot `once 2` render (which `load_temp_hist()`s when its in-memory history is empty) shows the trend the daemon accumulated, and the series survives a restart.

- **Navigation.** `draw_nav` draws tappable left/right page-turn buttons in the narrow edge gutters (only when that direction exists). Their tap targets (`NAV_LEFT_MAX` / `NAV_RIGHT_MIN`) are wider than the drawn tabs. Swipes navigate too (left/down = next, right/up = previous).

- **Menu buttons.** Defined once in the `MENU_BUTTONS` table (rect + label + desc + accent + action) so drawing (`draw_button`) and hit-testing (`menu_button_at`) share the same geometry — change a button's position in one place. Actions: `oem60`, `refresh`, `sleep`. They are positioned to leave the nav gutters clear; on the menu page `menu_button_at` is checked before the nav zones so a gutter tap still pages back.

- **Daemon loop** (`start_daemon`): each iteration calls `poll_gesture()` (a 5s touch window that classifies the touch as a `tap` or a directional `swipe` using `SWIPE_X`/`SWIPE_Y` thresholds in logical pixels). Swipe left/down = next view, right/up = previous. A tap is routed by current view: on the menu it dispatches the button under the finger; on home/device an edge tap navigates, otherwise it refreshes. First touch after sleep only wakes (it does not also act). When idle and not `always_on`, it blanks the backlight after `auto_lock_time`. Settings are re-read on each tap/idle tick so changes made in the stock UI take effect live.

- **Process lifecycle.** This router's busybox has **no `pkill`**, so the script manages a PID file at `PIDFILE` (`/tmp/skyris_screen_clients.pid`). `getpid()` reads `$PPID` from a popen'd shell (whose parent is the Lua process) since vanilla Lua lacks getpid. `claim_pidfile()` (on daemon start) kills any previously recorded live instance then records its own PID, so relaunching replaces the old daemon instead of leaving two fighting over `/dev/fb0`; `kill_pidfile()` (the `stop` verb) kills the recorded PID. Do not reintroduce `pkill` here.

- **Boot autostart.** `scripts/skyris_screen_clients.init` is an OpenWrt procd init script installed to `/etc/init.d/skyris_screen_clients` by `install.sh`, which also `enable`s it (boot start) and restarts it. It runs `skyris_screen_clients daemon` with `respawn`, and its `stop_service` restarts stock `gl_screen` to hand back the framebuffer. Prefer `/etc/init.d/skyris_screen_clients {start,stop,restart}` over launching the daemon by hand; a manual `skyris_screen_clients stop` kills the process but procd's respawn will bring it back.

## Deployment notes

- The router installs the script as `/usr/bin/skyris_screen_clients` (no `.lua` extension). Process management is via the PID file (see "Process lifecycle" above), not `pkill`.
- `once [page]` renders a single view (default 0) and exits — handy for capturing a specific view's framebuffer for debugging.
- The router has no `sftp-server`, so `scp` to it fails; `scripts/install.sh` streams the file over `ssh` instead.
- Hardware specifics (framebuffer geometry, pixel format, touch device, observed stock binary strings) are documented in `README.md` under "Hardware notes" and "Stock screen analysis".
