#!/usr/bin/lua
-- Minimal GL.iNet BE3600 screen client page for /dev/fb0.
-- Visual canvas is 284x76 landscape; framebuffer is 76x284 RGB565 LE, rotated clockwise.

local bit = require('bit')
local cjson = require('cjson')

local LOG_W, LOG_H = 284, 76
local FB_W, FB_H = 76, 284
local FB = '/dev/fb0'
local TOUCH = '/dev/input/event0'
local BACKLIGHT = '/sys/class/backlight/soc:backlight/brightness'
local PIDFILE = '/tmp/skyris_screen_clients.pid'
local OEM_FLAG = '/tmp/skyris_screen_clients.oem_until'

local function rgb565(r, g, b)
  local v = bit.bor(bit.lshift(bit.band(r, 0xF8), 8), bit.lshift(bit.band(g, 0xFC), 3), bit.rshift(b, 3))
  return string.char(bit.band(v, 0xff), bit.band(bit.rshift(v, 8), 0xff))
end

local BLACK = rgb565(0, 0, 0)
local WHITE = rgb565(255, 255, 255)
local GREEN = rgb565(0, 255, 120)
local BLUE = rgb565(0, 34, 56)
local CYAN = rgb565(160, 220, 255)
local YELLOW = rgb565(255, 210, 80)
local RED = rgb565(255, 80, 80)
local GRAY = rgb565(80, 80, 80)
local BUTTON = rgb565(60, 42, 0)

local FONT = {
  [' ']={0,0,0,0,0,0,0}, ['-']={0,0,0,31,0,0,0}, ['_']={0,0,0,0,0,0,31}, ['.']={0,0,0,0,0,12,12}, [':']={0,12,12,0,12,12,0}, ['*']={0,21,14,31,14,21,0}, ['/']={1,2,4,8,16,0,0}, ['<']={1,2,4,8,4,2,1}, ['>']={16,8,4,2,4,8,16}, ['%']={25,25,2,4,8,19,19},
  ['0']={14,17,19,21,25,17,14}, ['1']={4,12,4,4,4,4,14}, ['2']={14,17,1,2,4,8,31}, ['3']={30,1,1,14,1,1,30}, ['4']={2,6,10,18,31,2,2}, ['5']={31,16,30,1,1,17,14}, ['6']={6,8,16,30,17,17,14}, ['7']={31,1,2,4,8,8,8}, ['8']={14,17,17,14,17,17,14}, ['9']={14,17,17,15,1,2,12},
  ['A']={14,17,17,31,17,17,17}, ['B']={30,17,17,30,17,17,30}, ['C']={14,17,16,16,16,17,14}, ['D']={30,17,17,17,17,17,30}, ['E']={31,16,16,30,16,16,31}, ['F']={31,16,16,30,16,16,16}, ['G']={14,17,16,23,17,17,14}, ['H']={17,17,17,31,17,17,17}, ['I']={14,4,4,4,4,4,14}, ['J']={7,2,2,2,18,18,12}, ['K']={17,18,20,24,20,18,17}, ['L']={16,16,16,16,16,16,31}, ['M']={17,27,21,21,17,17,17}, ['N']={17,25,21,19,17,17,17}, ['O']={14,17,17,17,17,17,14}, ['P']={30,17,17,30,16,16,16}, ['Q']={14,17,17,17,21,18,13}, ['R']={30,17,17,30,20,18,17}, ['S']={15,16,16,14,1,1,30}, ['T']={31,4,4,4,4,4,4}, ['U']={17,17,17,17,17,17,14}, ['V']={17,17,17,17,17,10,4}, ['W']={17,17,17,21,21,21,10}, ['X']={17,17,10,4,10,17,17}, ['Y']={17,17,10,4,4,4,4}, ['Z']={31,1,2,4,8,16,31},
}
for c = string.byte('a'), string.byte('z') do FONT[string.char(c)] = FONT[string.char(c - 32)] end

local function run(cmd)
  os.execute(cmd .. ' >/dev/null 2>&1')
end

local function read_cmd(cmd)
  local p = io.popen(cmd .. ' 2>/dev/null')
  if not p then return '' end
  local out = p:read('*a') or ''
  p:close()
  return out
end

local function now()
  return tonumber(read_cmd('date +%s')) or os.time()
end

-- Our own PID. io.popen spawns a shell whose parent ($PPID) is this process,
-- so this is a portable getpid() that does not rely on luaposix.
local function getpid()
  return tonumber(read_cmd('echo $PPID')) or 0
end

local function pid_alive(pid)
  if not pid or pid <= 0 then return false end
  return read_cmd('kill -0 ' .. pid .. ' 2>/dev/null; echo $?'):match('0') ~= nil
end

-- Kill a previously recorded daemon (this busybox has no pkill), then record
-- our own PID. Called at daemon start so relaunching cleanly replaces the old
-- instance instead of leaving two processes fighting over the framebuffer.
local function claim_pidfile()
  local f = io.open(PIDFILE, 'r')
  if f then
    local old = tonumber((f:read('*a') or ''):match('%d+'))
    f:close()
    local self = getpid()
    if old and old ~= self and pid_alive(old) then
      run('kill ' .. old)
      os.execute('sleep 1')
    end
  end
  local w = io.open(PIDFILE, 'w')
  if w then w:write(tostring(getpid()), '\n'); w:close() end
end

local function kill_pidfile()
  local f = io.open(PIDFILE, 'r')
  if not f then return end
  local pid = tonumber((f:read('*a') or ''):match('%d+'))
  f:close()
  if pid and pid_alive(pid) then run('kill ' .. pid) end
  os.remove(PIDFILE)
end

local function read_stock_screen_settings()
  local settings = {
    brightness = 5,
    auto_lock_time = 600,
    always_on = false,
  }
  local out = read_cmd('/usr/bin/gl_screen -l')
  for key, value in out:gmatch('([A-Z_]+)%s+([^\n]+)') do
    value = tostring(value):gsub('^%s+', ''):gsub('%s+$', ''):gsub('^"(.*)"$', '%1')
    if key == 'BRIGHTNESS' then
      settings.brightness = tonumber(value) or settings.brightness
    elseif key == 'AUTO_LOCK_TIME' then
      settings.auto_lock_time = tonumber(value) or settings.auto_lock_time
    elseif key == 'ALWAYS_ON' then
      settings.always_on = tonumber(value) == 1
    end
  end
  if settings.brightness < 1 then settings.brightness = 1 end
  if settings.brightness > 10 then settings.brightness = 10 end
  if settings.auto_lock_time < 0 then settings.auto_lock_time = 0 end
  return settings
end

local stock_settings = read_stock_screen_settings()

local function backlight_value()
  -- GL.iNet's platform helper maps UI brightness 10 to sysfs value 11.
  if stock_settings.brightness >= 10 then return 11 end
  return stock_settings.brightness
end

local function set_screen_awake(on)
  local value = on and backlight_value() or 0
  local f = io.open(BACKLIGHT, 'w')
  if f then
    f:write(tostring(value), '\n')
    f:close()
  end
end

local function newbuf(color)
  local b = {}
  local row = color:rep(LOG_W)
  for y = 1, LOG_H do b[y] = row end
  return b
end

local function setpix(buf, x, y, color)
  if x < 0 or x >= LOG_W or y < 0 or y >= LOG_H then return end
  local row = buf[y + 1]
  local p = x * 2 + 1
  buf[y + 1] = row:sub(1, p - 1) .. color .. row:sub(p + 2)
end

local function fill(buf, x0, y0, x1, y1, color)
  if x0 < 0 then x0 = 0 end
  if y0 < 0 then y0 = 0 end
  if x1 >= LOG_W then x1 = LOG_W - 1 end
  if y1 >= LOG_H then y1 = LOG_H - 1 end
  for y = y0, y1 do
    local row = buf[y + 1]
    local left = x0 * 2 + 1
    local right = (x1 + 1) * 2
    buf[y + 1] = row:sub(1, left - 1) .. color:rep(x1 - x0 + 1) .. row:sub(right + 1)
  end
end

local function rect(buf, x0, y0, x1, y1, color)
  fill(buf, x0, y0, x1, y0, color)
  fill(buf, x0, y1, x1, y1, color)
  fill(buf, x0, y0, x0, y1, color)
  fill(buf, x1, y0, x1, y1, color)
end

local function text(buf, x, y, s, color, scale)
  scale = scale or 1
  s = tostring(s or '')
  for i = 1, #s do
    local ch = s:sub(i, i)
    local glyph = FONT[ch] or FONT['*']
    for gy = 1, 7 do
      local bits = glyph[gy]
      for gx = 0, 4 do
        if bit.band(bits, bit.lshift(1, 4 - gx)) ~= 0 then
          for sy = 0, scale - 1 do
            for sx = 0, scale - 1 do
              setpix(buf, x + gx * scale + sx, y + (gy - 1) * scale + sy, color)
            end
          end
        end
      end
    end
    x = x + 6 * scale
    if x > LOG_W - 6 then break end
  end
end

local function sanitize(s, maxlen)
  s = tostring(s or '*'):gsub('[^%w%._%-]', '')
  if s == '' then s = 'device' end
  maxlen = maxlen or 16
  if #s > maxlen then s = s:sub(1, maxlen) end
  return s
end

local function read_clients()
  local raw = read_cmd('ubus call gl-clients list')
  local ok, data = pcall(cjson.decode, raw)
  if not ok or type(data) ~= 'table' or type(data.clients) ~= 'table' then return {} end
  local list = {}
  for mac, c in pairs(data.clients) do
    if type(c) == 'table' and c.online == true then
      local name = c.name or c.hostname or tostring(mac):gsub(':', ''):sub(-6)
      local ip = tostring(c.ip or '')
      table.insert(list, {
        iface = tostring(c.iface or ''),
        name = sanitize(name, 9),
        tail = ip:match('%.(%d+)$') or '--',
      })
    end
  end
  table.sort(list, function(a, b) return (a.iface .. a.tail .. a.name) < (b.iface .. b.tail .. b.name) end)
  return list
end

local function rotate_cw_to_fb(buf)
  local out = {}
  for fby = 0, FB_H - 1 do
    local row = {}
    for fbx = 0, FB_W - 1 do
      local lx = LOG_W - 1 - fby
      local ly = fbx
      local src = buf[ly + 1]
      local p = lx * 2 + 1
      row[#row + 1] = src:sub(p, p + 1)
    end
    out[#out + 1] = table.concat(row)
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- System metrics (all read-only: /proc, /sys, df).
-- Download/upload rate and CPU% need two samples over time, so sample_rates()
-- keeps the previous counters and computes deltas; the daemon calls it once
-- per loop so the cached values stay ~5s fresh regardless of the current view.
-- ---------------------------------------------------------------------------
local WAN_IFACE = 'eth0'
local metrics_prev = nil   -- {t, rx, tx, cpu_idle, cpu_total}
local metrics_cache = nil  -- {down, up, cpu}  (bytes/s, bytes/s, percent)

local function read_net_bytes()
  local f = io.open('/proc/net/dev', 'r')
  if not f then return nil, nil end
  local rx, tx
  for line in f:lines() do
    local name, rest = line:match('%s*([%w%-]+):%s*(.*)')
    if name == WAN_IFACE then
      local n = {}
      for v in rest:gmatch('%d+') do n[#n + 1] = tonumber(v) end
      rx, tx = n[1], n[9]  -- rx bytes, tx bytes
    end
  end
  f:close()
  return rx, tx
end

local function read_cpu_times()
  local f = io.open('/proc/stat', 'r')
  if not f then return nil, nil end
  local line = f:read('*l') or ''
  f:close()
  local total, idle, i = 0, 0, 0
  for v in line:gmatch('%d+') do
    v = tonumber(v); i = i + 1; total = total + v
    if i == 4 or i == 5 then idle = idle + v end  -- idle + iowait
  end
  return idle, total
end

local function sample_rates()
  local t = now()
  local rx, tx = read_net_bytes()
  local cidle, ctotal = read_cpu_times()
  if metrics_prev and rx and cidle then
    local dt = t - metrics_prev.t
    if dt > 0 then
      local cpu = 0
      local dtotal = ctotal - metrics_prev.cpu_total
      if dtotal > 0 then
        cpu = math.floor((1 - (cidle - metrics_prev.cpu_idle) / dtotal) * 100 + 0.5)
        if cpu < 0 then cpu = 0 elseif cpu > 100 then cpu = 100 end
      end
      metrics_cache = {
        down = math.max(0, (rx - metrics_prev.rx) / dt),
        up = math.max(0, (tx - metrics_prev.tx) / dt),
        cpu = cpu,
      }
    end
  end
  metrics_prev = {t = t, rx = rx, tx = tx, cpu_idle = cidle, cpu_total = ctotal}
  return metrics_cache
end

-- Guarantee a rate sample exists (one-shot render path takes a 1s sample).
local function ensure_rates()
  if metrics_cache then return metrics_cache end
  sample_rates()
  os.execute('sleep 1')
  sample_rates()
  return metrics_cache or {down = 0, up = 0, cpu = 0}
end

local function read_mem_pct()
  local total, avail
  local f = io.open('/proc/meminfo', 'r')
  if not f then return 0 end
  for line in f:lines() do
    local k, v = line:match('(%w+):%s*(%d+)')
    if k == 'MemTotal' then total = tonumber(v)
    elseif k == 'MemAvailable' then avail = tonumber(v) end
  end
  f:close()
  if total and avail and total > 0 then return math.floor((total - avail) / total * 100 + 0.5) end
  return 0
end

local function read_temp_c()
  local mx = 0
  for z = 0, 9 do
    local f = io.open('/sys/class/thermal/thermal_zone' .. z .. '/temp', 'r')
    if not f then break end
    local v = tonumber(f:read('*a'))
    f:close()
    if v and v > mx then mx = v end
  end
  return math.floor(mx / 1000 + 0.5)
end

local function read_flash_pct()
  return tonumber(read_cmd('df /overlay'):match('(%d+)%%')) or 0
end

local function read_load()
  local f = io.open('/proc/loadavg', 'r')
  if not f then return '0.00' end
  local l = f:read('*l') or ''
  f:close()
  return l:match('^(%S+)') or '0.00'
end

local function read_uptime()
  local f = io.open('/proc/uptime', 'r')
  if not f then return '?' end
  local s = tonumber((f:read('*l') or ''):match('^(%d+)')) or 0
  f:close()
  local d = math.floor(s / 86400); s = s % 86400
  local h = math.floor(s / 3600); s = s % 3600
  local m = math.floor(s / 60)
  if d > 0 then return d .. 'd' .. h .. 'h' end
  return h .. 'h' .. m .. 'm'
end

local function fmt_rate(bps)
  if bps >= 1048576 then return string.format('%.1f MB/s', bps / 1048576)
  elseif bps >= 1024 then return string.format('%.0f KB/s', bps / 1024)
  else return string.format('%.0f B/s', bps) end
end

-- Device grid for the dedicated device view (full width is available here).
local DEVICE_COLS = {8, 100, 192}
local DEVICE_ROWS = {12, 21, 30, 39, 48, 57}
local DEVICE_POSITIONS = {}
for _, ry in ipairs(DEVICE_ROWS) do
  for _, cx in ipairs(DEVICE_COLS) do
    DEVICE_POSITIONS[#DEVICE_POSITIONS + 1] = {cx, ry}
  end
end
local PER_PAGE = #DEVICE_POSITIONS  -- 18 devices per device page

local function text_w(s, scale)
  return #tostring(s) * 6 * (scale or 1)
end

local function center_x(s, scale)
  return math.floor((LOG_W - text_w(s, scale)) / 2)
end

-- Left/right chevrons hint that there are more views to swipe to.
local function draw_nav(buf, page, total)
  if page > 0 then text(buf, 1, 34, '<', GRAY, 1) end
  if page < total - 1 then text(buf, 278, 34, '>', GRAY, 1) end
end

-- A styled menu button: filled body, accent border, accent top bar,
-- centered label, and a centered description line.
local function draw_button(buf, b)
  fill(buf, b.x0, b.y0, b.x1, b.y1, BUTTON)
  fill(buf, b.x0, b.y0, b.x1, b.y0 + 2, b.accent)
  rect(buf, b.x0, b.y0, b.x1, b.y1, b.accent)
  text(buf, b.x0 + math.max(2, math.floor((b.x1 - b.x0 - text_w(b.label)) / 2)), b.y0 + 7, b.label, b.accent, 1)
  if b.desc then
    text(buf, b.x0 + math.max(2, math.floor((b.x1 - b.x0 - text_w(b.desc)) / 2)), b.y0 + 20, b.desc, WHITE, 1)
  end
end

local MENU_BUTTONS = {
  {x0=6,   y0=22, x1=91,  y1=62, label='OEM60',   desc='Stock 60s',  action='oem60',   accent=YELLOW},
  {x0=99,  y0=22, x1=184, y1=62, label='REFRESH', desc='Reload',     action='refresh', accent=GREEN},
  {x0=192, y0=22, x1=277, y1=62, label='SLEEP',   desc='Screen off', action='sleep',   accent=CYAN},
}

local function menu_button_at(x, y)
  for _, b in ipairs(MENU_BUTTONS) do
    if x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1 then return b.action end
  end
  return nil
end

-- View model (navigate by swipe left/down = next, right/up = previous):
--   view 0                : clean home overview
--   view 1                : realtime network speed
--   view 2                : system status
--   view 3..2+dp          : device list pages (PER_PAGE each)
--   view 3+dp (last)      : function menu
-- Returns the clamped page index and the total number of views.
local DEV_START = 3  -- first device-page view index

local function draw_page(message, page)
  set_screen_awake(true)
  local clients = read_clients()
  local counts = {}
  for _, c in ipairs(clients) do
    local k = c.iface ~= '' and c.iface or '?'
    counts[k] = (counts[k] or 0) + 1
  end

  local device_pages = math.max(1, math.ceil(#clients / PER_PAGE))
  local total_views = DEV_START + device_pages + 1  -- + menu
  page = page or 0
  if page < 0 then page = 0 end
  if page > total_views - 1 then page = total_views - 1 end

  local buf = newbuf(BLACK)

  if page == 0 then
    -- Home: clean overview only.
    text(buf, center_x('ONLINE DEVICES'), 6, 'ONLINE DEVICES', CYAN, 1)
    text(buf, center_x(#clients, 3), 22, tostring(#clients), GREEN, 3)
    local parts = {}
    for _, label in ipairs({'2.4G', '5G', 'cable', '?'}) do
      if counts[label] then parts[#parts + 1] = label .. ' ' .. counts[label] end
    end
    local line = (#parts > 0) and table.concat(parts, '  ') or 'no clients'
    text(buf, center_x(line), 60, line, WHITE, 1)
  elseif page == 1 then
    -- Realtime network speed (WAN).
    local m = ensure_rates()
    text(buf, center_x('NETWORK SPEED'), 4, 'NETWORK SPEED', CYAN, 1)
    text(buf, 10, 24, 'DL', CYAN, 1)
    text(buf, 40, 20, fmt_rate(m.down), GREEN, 2)
    text(buf, 10, 50, 'UL', CYAN, 1)
    text(buf, 40, 46, fmt_rate(m.up), YELLOW, 2)
  elseif page == 2 then
    -- System status.
    local m = ensure_rates()
    local mem = read_mem_pct()
    local temp = read_temp_c()
    text(buf, center_x('SYSTEM'), 4, 'SYSTEM', CYAN, 1)
    text(buf, 8, 22, 'CPU ' .. m.cpu .. '%', m.cpu >= 90 and RED or WHITE, 1)
    text(buf, 8, 38, 'MEM ' .. mem .. '%', mem >= 85 and RED or WHITE, 1)
    text(buf, 8, 54, 'TEMP ' .. temp .. 'C', temp >= 85 and RED or WHITE, 1)
    text(buf, 150, 22, 'LOAD ' .. read_load(), WHITE, 1)
    text(buf, 150, 38, 'FLASH ' .. read_flash_pct() .. '%', WHITE, 1)
    text(buf, 150, 54, 'UP ' .. read_uptime(), GREEN, 1)
  elseif page <= DEV_START - 1 + device_pages then
    -- Device list page.
    local dpage = page - DEV_START
    local base = dpage * PER_PAGE
    text(buf, 8, 2, 'DEVICES', CYAN, 1)
    text(buf, 64, 2, #clients .. ' on', GREEN, 1)
    if device_pages > 1 then
      local ind = (dpage + 1) .. '/' .. device_pages
      text(buf, LOG_W - text_w(ind) - 10, 2, ind, YELLOW, 1)
    end
    for i = 1, PER_PAGE do
      local idx = base + i
      local c = clients[idx]
      if c then
        local x, yy = DEVICE_POSITIONS[i][1], DEVICE_POSITIONS[i][2]
        local color = (idx % 2 == 1) and WHITE or GREEN
        text(buf, x, yy, c.name, color, 1)
        text(buf, x + 58, yy, c.tail, YELLOW, 1)
      end
    end
  else
    -- Menu page.
    text(buf, 6, 5, 'MENU', CYAN, 1)
    text(buf, LOG_W - text_w('< BACK') - 10, 5, '< BACK', GRAY, 1)
    for _, b in ipairs(MENU_BUTTONS) do draw_button(buf, b) end
  end

  draw_nav(buf, page, total_views)
  if message then text(buf, center_x(message), 68, message, RED, 1) end

  local f = assert(io.open(FB, 'wb'))
  f:write(rotate_cw_to_fb(buf))
  f:close()
  return page, total_views
end

local function log(msg)
  local f = io.open('/tmp/skyris_screen_clients.log', 'a')
  if f then
    f:write(os.date('%H:%M:%S '), tostring(msg), '\n')
    f:close()
  end
end

local function parse_touch_events(hex)
  local events = {}
  for line in tostring(hex or ''):gmatch('[^\n]+') do
    if #line >= 48 then
      local function le16(pos)
        local b1 = tonumber(line:sub(pos, pos + 1), 16) or 0
        local b2 = tonumber(line:sub(pos + 2, pos + 3), 16) or 0
        return b1 + b2 * 256
      end
      local function le32(pos)
        local b1 = tonumber(line:sub(pos, pos + 1), 16) or 0
        local b2 = tonumber(line:sub(pos + 2, pos + 3), 16) or 0
        local b3 = tonumber(line:sub(pos + 4, pos + 5), 16) or 0
        local b4 = tonumber(line:sub(pos + 6, pos + 7), 16) or 0
        local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        if v >= 2147483648 then v = v - 4294967296 end
        return v
      end
      table.insert(events, {
        type = le16(33),
        code = le16(37),
        value = le32(41),
      })
    end
  end
  return events
end

local function read_touch_events(timeout_sec)
  local cmd = "timeout " .. tostring(timeout_sec or 1) .. " dd if=" .. TOUCH .. " bs=24 count=32 2>/dev/null | hexdump -v -e '24/1 \"%02x\" \"\\n\"'"
  return parse_touch_events(read_cmd(cmd))
end

local function map_touch_to_log(rawx, rawy)
  if not rawx or not rawy then return nil, nil end
  -- Current framebuffer rotation maps logical landscape to portrait fb as:
  -- fb_x = logical_y; fb_y = LOG_W - 1 - logical_x.
  -- Invert it for raw touch coordinates reported in framebuffer space.
  local x = LOG_W - 1 - rawy
  local y = rawx
  if x < 0 then x = 0 elseif x >= LOG_W then x = LOG_W - 1 end
  if y < 0 then y = 0 elseif y >= LOG_H then y = LOG_H - 1 end
  return x, y
end

-- Movement (in logical pixels) beyond which a touch is treated as a swipe
-- rather than a tap. The canvas is 284 wide x 76 tall, so the vertical
-- threshold is smaller than the horizontal one.
local SWIPE_X = 30
local SWIPE_Y = 16

-- Polls touch input for up to `seconds` and classifies the gesture.
-- Returns nil if nothing happened, otherwise a table:
--   {kind='tap',   x=, y=}                logical tap point
--   {kind='swipe', dir='left'|'right'|'up'|'down', x=, y=}
local function poll_gesture(seconds)
  local rawx, rawy = nil, nil
  local sx, sy = nil, nil  -- logical start point
  local lx, ly = nil, nil  -- logical last point

  local function sample()
    if not rawx or not rawy then return end
    local x, y = map_touch_to_log(rawx, rawy)
    if not sx then sx, sy = x, y end
    lx, ly = x, y
  end

  local function finalize()
    if not sx then return nil end
    local dx, dy = lx - sx, ly - sy
    local adx, ady = math.abs(dx), math.abs(dy)
    if adx < SWIPE_X and ady < SWIPE_Y then
      log('tap log=' .. lx .. ',' .. ly)
      return {kind = 'tap', x = lx, y = ly}
    end
    local dir
    if adx >= ady then
      dir = (dx < 0) and 'left' or 'right'
    else
      dir = (dy < 0) and 'up' or 'down'
    end
    log('swipe ' .. dir .. ' d=' .. dx .. ',' .. dy)
    return {kind = 'swipe', dir = dir, x = lx, y = ly}
  end

  for _ = 1, seconds do
    local events = read_touch_events(1)
    for _, e in ipairs(events) do
      -- Common single-touch ABS axes on this driver.
      if e.type == 3 and (e.code == 0 or e.code == 53) then rawx = e.value; sample() end
      if e.type == 3 and (e.code == 1 or e.code == 54) then rawy = e.value; sample() end
      -- Finger lift: BTN_TOUCH up, or MT slot tracking id cleared.
      if (e.type == 1 and e.code == 330 and e.value == 0)
        or (e.type == 3 and e.code == 57 and e.value == -1) then
        local g = finalize()
        if g then return g end
        rawx, rawy, sx, sy, lx, ly = nil, nil, nil, nil, nil, nil
      end
    end
  end
  -- No explicit lift seen within the window: classify whatever we collected.
  return finalize()
end

local function restore_oem_60(page)
  log('OEM60 start')
  draw_page('OEM 60s', page)
  run('/etc/init.d/gl_screen restart')
  os.execute('sleep 60')
  run('/etc/init.d/gl_screen stop')
  draw_page(nil, page)
  log('OEM60 end')
end

local function start_daemon()
  claim_pidfile()
  run('/etc/init.d/gl_screen stop')
  stock_settings = read_stock_screen_settings()
  local awake = true
  local last_activity = now()
  local page = 0
  local views = DEV_START + 2
  log('settings brightness=' .. stock_settings.brightness .. ' auto_lock=' .. stock_settings.auto_lock_time .. ' always_on=' .. tostring(stock_settings.always_on))
  sample_rates()  -- seed the rate baseline
  page, views = draw_page(nil, page)

  while true do
    local g = poll_gesture(5)
    local t = now()
    sample_rates()  -- keep speed/cpu deltas ~5s fresh regardless of view

    if g then
      last_activity = t
      stock_settings = read_stock_screen_settings()
      if not awake then
        -- First touch after sleep only wakes the screen.
        awake = true
        log('wake')
        page, views = draw_page('WAKE', page)
      elseif g.kind == 'swipe' then
        -- Swipe left or down -> next view; right or up -> previous view.
        if g.dir == 'left' or g.dir == 'down' then
          page = page + 1
        elseif g.dir == 'right' or g.dir == 'up' then
          page = page - 1
        end
        page, views = draw_page(nil, page)
      elseif page >= views - 1 then
        -- Tap on the menu page: dispatch the button under the finger.
        local action = menu_button_at(g.x, g.y)
        if action == 'oem60' then
          restore_oem_60(page)
          last_activity = now()
          awake = true
          stock_settings = read_stock_screen_settings()
          page, views = draw_page(nil, page)
        elseif action == 'sleep' then
          awake = false
          log('sleep (button)')
          set_screen_awake(false)
        elseif action == 'refresh' then
          page, views = draw_page('REFRESH', page)
        elseif g.x <= 10 then
          page, views = draw_page(nil, page - 1)
        else
          page, views = draw_page(nil, page)
        end
      else
        -- Tap on home/device view: edge taps navigate, otherwise refresh.
        if g.x <= 10 and page > 0 then
          page = page - 1
        elseif g.x >= 272 and page < views - 1 then
          page = page + 1
        end
        page, views = draw_page(nil, page)
      end
    elseif awake then
      stock_settings = read_stock_screen_settings()
      local should_sleep = (not stock_settings.always_on)
        and stock_settings.auto_lock_time > 0
        and (t - last_activity) >= stock_settings.auto_lock_time
      if should_sleep then
        awake = false
        log('sleep after ' .. tostring(t - last_activity) .. 's')
        set_screen_awake(false)
      else
        page, views = draw_page(nil, page)
      end
    end
  end
end

local cmd = arg[1] or 'once'
if cmd == 'once' then
  run('/etc/init.d/gl_screen stop')
  draw_page(nil, tonumber(arg[2]) or 0)
elseif cmd == 'daemon' then
  start_daemon()
elseif cmd == 'oem60' then
  restore_oem_60()
elseif cmd == 'restore' then
  run('/etc/init.d/gl_screen restart')
elseif cmd == 'stop' then
  kill_pidfile()
  run('/etc/init.d/gl_screen restart')
else
  io.stderr:write('usage: skyris_screen_clients once|daemon|oem60|restore|stop\n')
  os.exit(1)
end
