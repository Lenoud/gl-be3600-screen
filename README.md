# GL-BE3600 Screen Tools

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

`src/skyris_screen_clients.lua` draws a small online-client dashboard:

- Online device count
- Per-interface counts (`2.4G`, `5G`, `cable`)
- Up to six online device names plus IP tail
- `OEM60` button is drawn in the top right; tapping it temporarily restores the stock screen for 60 seconds, then switches back.
- Tapping ordinary screen areas refreshes the dashboard.
- Auto-refresh daemon refreshes every 5 seconds.
- Reads the stock brightness / sleep / always-on settings; after sleep, the first touch only wakes the screen.

## Install to router

```sh
./scripts/install.sh root@192.168.3.1
```

Or manually:

```sh
scp src/skyris_screen_clients.lua root@192.168.3.1:/usr/bin/skyris_screen_clients
ssh root@192.168.3.1 'chmod +x /usr/bin/skyris_screen_clients'
```

If `scp` fails because the router lacks `sftp-server`, use the install script; it streams over SSH.

## Run

Show once:

```sh
ssh root@192.168.3.1 '/usr/bin/skyris_screen_clients once'
```

Refresh every 5 seconds:

```sh
ssh root@192.168.3.1 'pkill -f "lua /usr/bin/skyris_screen_clients" 2>/dev/null || true; /usr/bin/skyris_screen_clients daemon >/tmp/skyris_screen_clients.log 2>&1 &'
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
