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
ssh root@192.168.3.1 'pkill -f "lua /usr/bin/skyris_screen_clients" 2>/dev/null || true; /usr/bin/skyris_screen_clients daemon >/tmp/skyris_screen_clients.log 2>&1 &'

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

- **Stock-screen coordination.** The custom UI and the stock `gl_screen` both own `/dev/fb0`, so they must never run simultaneously. The daemon calls `/etc/init.d/gl_screen stop` on start; `oem60` restarts stock for 60s then stops it again; `stop`/`restore` hand control back to stock. `read_stock_screen_settings()` parses `gl_screen -l` to reuse the user's brightness / auto-lock / always-on preferences rather than inventing its own.

- **Daemon loop** (`start_daemon`): each iteration calls `poll_gesture()` (a 5s touch window that classifies the touch as a `tap` or a `swipe` with a direction, using `SWIPE_X`/`SWIPE_Y` thresholds in logical pixels). It then either wakes a sleeping screen (first touch only wakes — it does not also act), triggers OEM60 when a *tap* lands in the top-right hit-box, pages the device list on a *swipe* (left/down = next page, right/up = previous), or refreshes. The device list is paginated `PER_PAGE` (6) at a time via `draw_page(message, page)`, which clamps `page` against the live client count and returns the clamped page so the daemon's `page` state stays valid as devices come and go. When idle and not `always_on`, it blanks the backlight after `auto_lock_time`. Settings are re-read on each tap/idle tick so changes made in the stock UI take effect live.

## Deployment notes

- The router installs the script as `/usr/bin/skyris_screen_clients` (no `.lua` extension). `stop` matches the running process with `pkill -f 'lua /usr/bin/skyris_screen_clients'`, which assumes the daemon was launched as a `lua` argument — verify the process command line if `stop` ever fails to kill it.
- Hardware specifics (framebuffer geometry, pixel format, touch device, observed stock binary strings) are documented in `README.md` under "Hardware notes" and "Stock screen analysis".
