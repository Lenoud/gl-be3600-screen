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
  [' ']={0,0,0,0,0,0,0}, ['-']={0,0,0,31,0,0,0}, ['_']={0,0,0,0,0,0,31}, ['.']={0,0,0,0,0,12,12}, [':']={0,12,12,0,12,12,0}, ['*']={0,21,14,31,14,21,0}, ['/']={1,2,4,8,16,0,0},
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

local DEVICE_POSITIONS = {{82,18},{82,36},{82,54},{180,18},{180,36},{180,54}}
local PER_PAGE = #DEVICE_POSITIONS

-- Draws the dashboard for a given 0-based page of the device list.
-- Returns the clamped page and the total page count so the caller can keep
-- its paging state in sync after the list size changes.
local function draw_page(message, page)
  set_screen_awake(true)
  local clients = read_clients()
  local counts = {}
  for _, c in ipairs(clients) do
    local k = c.iface ~= '' and c.iface or '?'
    counts[k] = (counts[k] or 0) + 1
  end

  local total_pages = math.max(1, math.ceil(#clients / PER_PAGE))
  page = page or 0
  if page < 0 then page = 0 end
  if page > total_pages - 1 then page = total_pages - 1 end
  local base = page * PER_PAGE

  local buf = newbuf(BLACK)
  fill(buf, 0, 0, 74, 75, BLUE)
  text(buf, 6, 5, 'ONLINE', CYAN, 1)
  text(buf, 10, 22, tostring(#clients), GREEN, 2)
  local y = 48
  for _, label in ipairs({'2.4G', '5G', 'cable', '?'}) do
    if counts[label] then
      text(buf, 5, y, label .. ':' .. counts[label], WHITE, 1)
      y = y + 10
    end
  end

  fill(buf, 228, 0, 283, 16, BUTTON)
  rect(buf, 228, 0, 283, 16, YELLOW)
  text(buf, 234, 5, 'OEM60', YELLOW, 1)

  text(buf, 82, 2, 'Devices', WHITE, 1)
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
  -- Page indicator: swipe left/down for next, right/up for previous.
  if total_pages > 1 then
    text(buf, 246, 62, (page + 1) .. '/' .. total_pages, CYAN, 1)
  end
  if message then text(buf, 82, 66, message, RED, 1) end

  local f = assert(io.open(FB, 'wb'))
  f:write(rotate_cw_to_fb(buf))
  f:close()
  return page, total_pages
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
  run('/etc/init.d/gl_screen stop')
  stock_settings = read_stock_screen_settings()
  local awake = true
  local last_activity = now()
  local page = 0
  log('settings brightness=' .. stock_settings.brightness .. ' auto_lock=' .. stock_settings.auto_lock_time .. ' always_on=' .. tostring(stock_settings.always_on))
  page = draw_page(nil, page)

  while true do
    local g = poll_gesture(5)
    local t = now()

    if g then
      last_activity = t
      stock_settings = read_stock_screen_settings()
      if not awake then
        -- First touch after sleep only wakes the screen.
        awake = true
        log('wake')
        page = draw_page('WAKE', page)
      elseif g.kind == 'tap' and g.x >= 228 and g.y <= 20 then
        restore_oem_60(page)
        last_activity = now()
        awake = true
        stock_settings = read_stock_screen_settings()
        page = draw_page(nil, page)
      elseif g.kind == 'swipe' then
        -- Swipe left or down -> next page; right or up -> previous page.
        if g.dir == 'left' or g.dir == 'down' then
          page = page + 1
        elseif g.dir == 'right' or g.dir == 'up' then
          page = page - 1
        end
        page = draw_page(nil, page)
      else
        page = draw_page('REFRESH', page)
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
        page = draw_page(nil, page)
      end
    end
  end
end

local cmd = arg[1] or 'once'
if cmd == 'once' then
  run('/etc/init.d/gl_screen stop')
  draw_page()
elseif cmd == 'daemon' then
  start_daemon()
elseif cmd == 'oem60' then
  restore_oem_60()
elseif cmd == 'restore' then
  run('/etc/init.d/gl_screen restart')
elseif cmd == 'stop' then
  run("pkill -f 'lua /usr/bin/skyris_screen_clients' || true")
  run('/etc/init.d/gl_screen restart')
else
  io.stderr:write('usage: skyris_screen_clients once|daemon|oem60|restore|stop\n')
  os.exit(1)
end
