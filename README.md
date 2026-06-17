# GL-BE3600 Screen Tools

*[English](README.md) | [中文](README_ZH.md)*

Custom screen experiments for the GL.iNet BE3600 / IPQ5332 router touchscreen.

## Hardware notes

Observed on `192.168.3.1`:

- Model: `GL.iNet BE3600, Inc. IPQ5332/AP-MI04.1-C2`
- Stock screen process: `/usr/bin/gl_screen -c /tmp/gl_screen/config`
- Framebuffer: `/dev/fb0`
- Framebuffer sysfs:
  - `virtual_size=76,284`
  - `stride=152`
  - `bits_per_pixel=16`
  - driver/name: `fb_st7789p3`
- Visual design is landscape `284x76`; framebuffer write needs clockwise rotation into `76x284`.
- Pixel format: RGB565 little-endian.
- Touch input: `/dev/input/event0`
- Touch name: `Hynitron CST816X Touchscreen`

## Current script

`src/skyris_screen_clients.lua` draws a small online-client dashboard organised
into five swipeable views. Swipe **left/down** for the next view and
**right/up** for the previous; on-screen **`<` / `>` page buttons** on the left and
right edges do the same when tapped (shown only when that direction exists).

1. **Home** — a clean overview: title, large online device count, and per-interface
   counts (`2.4G`, `5G`, `cable`).
2. **Network speed** — realtime WAN download/upload rate (auto B/KB/MB units).
3. **System** — CPU %, memory %, temperature, load average, flash usage and uptime;
   CPU / memory / temperature turn red past their thresholds, plus a temperature
   trend sparkline (40–90 °C band, newest on the right).
4. **Devices** — the full client list, 18 per page across three columns (name + IP
   tail). With more clients it pages automatically; a `page/total` indicator shows
   top right, and swiping pages through them (e.g. 100 devices = 6 pages).
5. **Menu** — styled function buttons, each with a short description. Tap a button:
   - `OEM60` — restore the stock screen for 60 seconds, then switch back.
   - `REFRESH` — reload the client data now.
   - `SLEEP` — turn the screen off immediately.

### Screens

| Home | Network speed | System |
|------|---------------|--------|
| ![Home](docs/img/home.png) | ![Network speed](docs/img/speed.png) | ![System](docs/img/system.png) |

| Devices | Menu |
|---------|------|
| ![Devices](docs/img/devices.png) | ![Menu](docs/img/menu.png) |

Other behaviour:

- Auto-refresh daemon redraws the current view every 5 seconds.
- Honours the stock screen settings, read live from uci so they match exactly what the GL admin UI sets:
  - **Brightness / auto-lock timeout / always-on** (`gl_screen.generic`). After auto-lock the first touch only wakes the screen.
  - **Scheduled on/off timer** (`gl_timer.screen`): outside the configured on-window (on the selected weekdays) the screen blanks, and it auto-wakes when the window opens. The schedule overrides always-on so a nightly off-window still works.
- The daemon tracks its PID in `/tmp/skyris_screen_clients.pid`; relaunching cleanly replaces a running instance and `stop` reliably kills it (this router's busybox has no `pkill`).

## Install to router

```sh
./scripts/install.sh root@192.168.3.1
```

This copies the screen program to `/usr/bin/skyris_screen_clients`, installs the
procd init script to `/etc/init.d/skyris_screen_clients`, **enables autostart on
boot**, and (re)starts the service.

Or manually:

```sh
scp src/skyris_screen_clients.lua root@192.168.3.1:/usr/bin/skyris_screen_clients
scp scripts/skyris_screen_clients.init root@192.168.3.1:/etc/init.d/skyris_screen_clients
ssh root@192.168.3.1 'chmod +x /usr/bin/skyris_screen_clients /etc/init.d/skyris_screen_clients && /etc/init.d/skyris_screen_clients enable && /etc/init.d/skyris_screen_clients start'
```

If `scp` fails because the router lacks `sftp-server`, use the install script; it streams over SSH.

## Run

Once installed, manage it as a service (survives reboots):

```sh
ssh root@192.168.3.1 '/etc/init.d/skyris_screen_clients start'    # start now
ssh root@192.168.3.1 '/etc/init.d/skyris_screen_clients stop'     # stop and hand the screen back to stock
ssh root@192.168.3.1 '/etc/init.d/skyris_screen_clients restart'  # restart
ssh root@192.168.3.1 '/etc/init.d/skyris_screen_clients disable'  # stop starting on boot
```

The program itself also has lower-level verbs (used by the init script and for debugging):

Show once:

```sh
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients once'
```

Render a single view and exit (0 = home, 1 = network speed, 2 = system, then device pages, last = menu) — useful for debugging:

```sh
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients once 2'
```

Run the refresh daemon directly (unmanaged — prefer the init service above):

```sh
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients daemon >/tmp/skyris_screen_clients.log 2>&1 &'
```

Restore stock GL.iNet screen:

```sh
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients stop'
```

Temporarily show stock screen for 60 seconds:

```sh
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients oem60'
```

## Stock screen analysis

Copied binary: `/usr/bin/gl_screen` from router.

Key strings observed in the stock binary:

- `overview`
- `clients_speed`
- `client_count`
- `clients`
- `get_speed`
- `memory_total`
- `memory_free`
- `flash_total`
- `flash_free`
- `cpu_num`

Static analysis suggests the stock CPU/Memory/Flash `overview` page is hard-coded in the stripped AArch64 binary, not generated from Lua/JSON templates.
