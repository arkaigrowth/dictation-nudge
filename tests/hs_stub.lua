-- A plain-Lua stand-in for the parts of Hammerspoon's `hs` API that
-- dictation_nudge.lua touches. It has a controllable clock and a tiny timer
-- scheduler, records side effects (alerts, URLs, settings, log lines), and
-- hands the test the real event-tap callback so tests drive the real code.
--
-- Nothing here talks to macOS. No key events are created or posted.

local Stub = {}

-- macOS virtual keycodes for the names the module (and the tests) look up.
local KEYCODES = {
  a = 0, s = 1, d = 2, f = 3, r = 15, u = 32, tab = 48, space = 49, escape = 53,
  left = 123, right = 124, down = 125, up = 126,
  f1 = 122, f2 = 120, f3 = 99, f4 = 118, f5 = 96, f6 = 97, f7 = 98, f8 = 100,
  f9 = 101, f10 = 109, f11 = 103, f12 = 111, f13 = 105, f14 = 107, f15 = 113,
  f16 = 106, f17 = 64, f18 = 79, f19 = 80, f20 = 90,
  -- answer keys for the snooze gate
  ["0"] = 29, ["1"] = 18, ["2"] = 19, ["3"] = 20, ["4"] = 21, ["5"] = 23,
  ["6"] = 22, ["7"] = 26, ["8"] = 28, ["9"] = 25,
  ["."] = 47, [","] = 43, ["-"] = 27, delete = 51, forwarddelete = 117,
  ["return"] = 36, padenter = 76, ["pad."] = 65, ["pad,"] = 95, ["pad-"] = 78,
  pad0 = 82, pad1 = 83, pad2 = 84, pad3 = 85, pad4 = 86, pad5 = 87,
  pad6 = 88, pad7 = 89, pad8 = 91, pad9 = 92,
}

local EVENT_TYPES = { keyDown = 10, flagsChanged = 12 }
local EVENT_PROPERTIES = { keyboardEventAutorepeat = 8 }

-- Enough JSON for what the module sends to the card: flat tables of strings,
-- numbers, and booleans. Keys are sorted so the output is stable.
local function encodeJSON(value)
  local kind = type(value)
  if kind == "table" then
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = encodeJSON(key) .. ":" .. encodeJSON(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif kind == "string" then
    return '"' .. value:gsub('[%c"\\]', function(c)
      return c == '"' and '\\"' or c == "\\" and "\\\\" or string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif kind == "number" then
    return value == math.floor(value) and string.format("%d", value) or tostring(value)
  elseif kind == "boolean" then
    return tostring(value)
  end
  return "null"
end

-- An object whose unknown methods all return the object, so builder chains
-- like hs.webview.new(...):windowStyle(...):show() work.
local function chain(fields)
  return setmetatable(fields or {}, {
    __index = function() return function(self) return self end end,
  })
end

function Stub.new()
  local env = {
    now = 1700000000,
    timers = {},
    alerts = {},
    urls = {},
    apps = {},
    sounds = 0,
    settings = {},
    settingsWrites = {},
    logs = {},
    urlBinds = {},
    panels = {},        -- every card opened: { html = ..., deleted = bool, scripts = {...} }
    canvases = {},      -- every lockdown overlay: { deleted = bool }
    tapCallback = nil,  -- the function the module registered with hs.eventtap.new
    tapTypes = nil,
    panelCallback = nil, -- the card's JS -> Lua message handler
    menuTitle = nil,
    jsResult = true,        -- what the card "returns" to evaluateJavaScript callbacks
    holdNavigation = false, -- true: a new card's page stays unloaded until env.finishNavigation()
  }

  -- ── timers ──
  local function newTimer(interval, fn, repeats)
    local timer = { interval = interval, fn = fn, repeats = repeats, active = false, nextAt = nil }
    function timer:start() self.active = true; self.nextAt = env.now + self.interval; return self end
    function timer:stop() self.active = false; return self end
    function timer:running() return self.active end
    function timer:setNextTrigger(seconds) self.active = true; self.nextAt = env.now + seconds; return self end
    table.insert(env.timers, timer)
    return timer
  end

  -- Move the clock forward, firing due timers in time order.
  function env.advance(seconds)
    env.settle()
    local target = env.now + seconds
    while true do
      local due
      for _, timer in ipairs(env.timers) do
        if timer.active and timer.nextAt <= target and (not due or timer.nextAt < due.nextAt) then
          due = timer
        end
      end
      if not due then break end
      env.now = math.max(env.now, due.nextAt)
      if due.repeats then due.nextAt = due.nextAt + due.interval else due.active = false end
      due.fn()
    end
    env.now = target
  end

  -- ── events ──
  -- The module is only allowed these four accessors. Anything else (for
  -- example getCharacters) raises, which fails the test that triggered it.
  local ALLOWED = { getType = true, getKeyCode = true, getFlags = true, getProperty = true }
  local function event(kind, keycode, flags, autorepeat)
    local methods = {
      getType = function() return EVENT_TYPES[kind] end,
      getKeyCode = function() return keycode end,
      getFlags = function()
        local copy = {}
        for name, held in pairs(flags or {}) do copy[name] = held end
        return copy
      end,
      getProperty = function(_, property)
        if property ~= EVENT_PROPERTIES.keyboardEventAutorepeat then
          error("module read an event property other than autorepeat: " .. tostring(property))
        end
        return autorepeat and 1 or 0
      end,
    }
    return setmetatable({}, {
      __index = function(_, name)
        if not ALLOWED[name] then error("module called a forbidden event accessor: " .. tostring(name)) end
        return methods[name]
      end,
    })
  end

  -- Press a key through the real tap callback. Returns what the callback
  -- returned: true = the module consumed the event, false = passed through.
  function env.key(name, options)
    options = options or {}
    local code = KEYCODES[name]
    assert(code, "test used an unknown key name: " .. tostring(name))
    return env.tapCallback(event("keyDown", code, options.flags, options.autorepeat))
  end

  function env.modifiers(flags)
    return env.tapCallback(event("flagsChanged", 0, flags, false))
  end

  -- ── the fake hs ──
  local hs = {}

  hs.logger = { new = function()
    local function record(level) return function(message) table.insert(env.logs, level .. ": " .. tostring(message)) end end
    return { i = record("info"), w = record("warn"), e = record("error"), d = record("debug") }
  end }

  hs.timer = {
    secondsSinceEpoch = function() return env.now end,
    new = function(interval, fn) return newTimer(interval, fn, true) end,
    doEvery = function(interval, fn) return newTimer(interval, fn, true):start() end,
    doAfter = function(delay, fn) return newTimer(delay, fn, false):start() end,
  }

  hs.settings = {
    get = function(key) return env.settings[key] end,
    set = function(key, value)
      env.settings[key] = value
      table.insert(env.settingsWrites, key)
    end,
  }

  hs.keycodes = { map = KEYCODES }

  hs.eventtap = {
    event = { types = EVENT_TYPES, properties = EVENT_PROPERTIES },
    new = function(types, callback)
      env.tapTypes = types
      env.tapCallback = callback
      local tap = { enabled = false }
      function tap:start() self.enabled = true; return self end
      function tap:stop() self.enabled = false; return self end
      function tap:isEnabled() return self.enabled end
      return tap
    end,
  }

  hs.accessibilityState = function() return true end
  hs.alert = { show = function(message) table.insert(env.alerts, message) end }
  hs.sound = { getByName = function() return { play = function() env.sounds = env.sounds + 1 end } end }
  hs.urlevent = {
    openURL = function(url) table.insert(env.urls, url) end,
    bind = function(name, fn) env.urlBinds[name] = fn end,
  }
  hs.application = { open = function(name) table.insert(env.apps, name) end }
  hs.json = { encode = encodeJSON }
  hs.styledtext = { new = function(text) return text end }
  hs.focus = function() end
  hs.dialog = { textPrompt = function() return "Cancel", "" end }
  hs.drawing = { windowLevels = { floating = 3 } }

  hs.menubar = { new = function()
    return chain({ setTitle = function(self, title) env.menuTitle = title; return self end })
  end }

  hs.screen = {
    mainScreen = function() return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end } end,
    allScreens = function() return { { fullFrame = function() return { x = 0, y = 0, w = 1440, h = 900 } end } } end,
  }

  hs.canvas = {
    windowLevels = { overlay = 25 },
    new = function()
      local record = { deleted = false }
      table.insert(env.canvases, record)
      local canvas = chain({ {}, {}, {} }) -- canvas[3].text is the countdown line
      rawset(canvas, "delete", function() record.deleted = true end)
      return canvas
    end,
  }

  hs.webview = {
    usercontent = { new = function()
      return { setCallback = function(_, callback) env.panelCallback = callback end }
    end },
    new = function()
      local record = { html = nil, deleted = false, scripts = {} }
      table.insert(env.panels, record)
      return chain({
        html = function(self, html) record.html = html; return self end,
        navigationCallback = function(self, callback) record.navigation = callback; record.view = self; return self end,
        -- JavaScript the module pushes into the card. Never executed here; the
        -- callback gets env.jsResult (default true, the card's acknowledgement).
        evaluateJavaScript = function(self, script, callback)
          table.insert(record.scripts, script)
          if callback then callback(env.jsResult) end
          return self
        end,
        delete = function() record.deleted = true end,
      })
    end,
  }

  env.hs = hs

  -- Send what the card's JavaScript would post to Lua.
  function env.cardMessage(body) env.settle(); env.panelCallback({ body = body }) end

  -- The page in the newest card has finished loading. As in Hammerspoon, this
  -- happens after the call that opened the card has returned.
  function env.finishNavigation()
    local record = env.panels[#env.panels]
    if not record or record.loaded or record.deleted or not record.navigation then return end
    record.loaded = true
    record.navigation("didFinishNavigation", record.view)
  end

  -- Pages load by the time anything else happens, unless a test holds them back.
  function env.settle()
    if not env.holdNavigation then env.finishNavigation() end
  end

  function env.openPanels()
    local count = 0
    for _, panel in ipairs(env.panels) do if not panel.deleted then count = count + 1 end end
    return count
  end

  function env.liveCanvases()
    local count = 0
    for _, canvas in ipairs(env.canvases) do if not canvas.deleted then count = count + 1 end end
    return count
  end

  return env
end

return Stub
