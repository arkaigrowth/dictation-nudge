-- Offline tests for dictation_nudge.lua. Plain Lua 5.4, no Hammerspoon, no
-- macOS APIs, no key events. Run from the repo root:
--
--   lua tests/run.lua
--
-- Each test loads a fresh copy of the real module against tests/hs_stub.lua
-- and drives the real event-tap callback with a fake clock.

local root = arg[0]:match("^(.*)/tests/[^/]+$") or "."
local Stub = dofile(root .. "/tests/hs_stub.lua")
local MODULE_PATH = root .. "/dictation_nudge.lua"

local function readSource()
  local file = assert(io.open(MODULE_PATH, "r"))
  local source = file:read("a")
  file:close()
  return source
end

-- Fresh module + fresh fake hs. `saved` pre-seeds hs.settings.
local function load(userConfig, saved)
  for name in pairs(_G) do
    if type(name) == "string" and name:match("^dictationNudge") then _G[name] = nil end
  end
  local env = Stub.new()
  for key, value in pairs(saved or {}) do env.settings[key] = value end
  _G.hs = env.hs
  local module = dofile(MODULE_PATH)
  module.start(userConfig or {})
  env.module = module
  env.internal = module._internal
  function env.used() return env.internal.usedSeconds(env.now) end
  -- Type `count` keys, `interval` seconds apart. The first key lands now.
  function env.type(count, interval, name)
    local consumed = 0
    for index = 1, count do
      if index > 1 then env.advance(interval) end
      if env.key(name or "a") then consumed = consumed + 1 end
    end
    return consumed
  end
  return env
end

local tests, failures = {}, {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

local function eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function near(actual, expected, label)
  if math.abs(actual - expected) > 1e-9 then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

-- 0.125s is exact in binary floating point, so sums of it are exact too.
local STEP = 0.125

-- ═══ Allowance math ═══

test("a lone key spends nothing", function()
  local env = load()
  eq(env.key("a"), false, "key passes through")
  near(env.used(), 0, "used right after")
  env.advance(10)
  near(env.used(), 0, "used later")
end)

test("typing spends the time between counted keys", function()
  local env = load()
  env.type(9, STEP) -- 8 intervals
  near(env.used(), 1.0, "used")
end)

test("an interval is charged at most refillDelaySeconds", function()
  local env = load()
  env.type(2, 0.1875)
  near(env.used(), 0.1875, "short interval charged in full")
  local slow = load()
  slow.type(17, STEP) -- 2.0s used
  slow.advance(1)     -- pause: holds 0.25s, then refills 0.75s
  near(slow.used(), 1.25, "after pause")
  slow.key("a")       -- resume inside the 3s burst window: charge 0.25s, not 1s
  near(slow.used(), 1.5, "after resuming")
end)

test("the allowance holds briefly, then refills at 1s per second", function()
  local env = load()
  env.type(41, STEP) -- 5.0s used
  near(env.used(), 5, "used")
  env.advance(0.25)
  near(env.used(), 5, "held through the pause allowance")
  env.advance(2)
  near(env.used(), 3, "refilled 2s")
  env.advance(60)
  near(env.used(), 0, "never goes below zero")
end)

test("usage never rises without a key", function()
  local env = load()
  env.type(81, STEP) -- 10s used
  local previous = env.used()
  for _ = 1, 200 do
    env.advance(0.1)
    local current = env.used()
    assert(current <= previous + 1e-12, "usage rose while idle")
    previous = current
  end
  near(previous, 0, "fully refilled")
end)

test("a gap longer than gapSeconds starts a new burst with no charge", function()
  local env = load({ refillPerSecond = 0 }) -- freeze refill to isolate the charge
  env.type(9, STEP)
  env.advance(3.5)
  env.key("a")
  near(env.used(), 1.0, "no charge for the long gap")
end)

test("reading the allowance does not change it", function()
  local env = load()
  env.type(41, STEP)
  env.advance(1)
  local first = env.used()
  for _ = 1, 50 do env.internal.usedSeconds(env.now); env.internal.ringState(env.now) end
  near(env.used(), first, "repeated reads")
end)

-- ═══ Tier 1 ═══

test("tier 1 fires on the key that uses up the allowance, not before", function()
  local env = load()
  env.type(120, STEP) -- 119 intervals = 14.875s
  eq(#env.alerts, 0, "no banner yet")
  eq(env.openPanels(), 0, "no card yet")
  env.advance(STEP)
  eq(env.key("a"), false, "the triggering key still passes through")
  eq(#env.alerts, 1, "banner shown")
  eq(env.sounds, 1, "sound played")
  eq(env.openPanels(), 1, "card open")
end)

test("idle time never fires a nudge", function()
  local env = load()
  env.type(120, STEP)
  env.advance(3600)
  eq(#env.alerts, 0, "no banner")
  eq(env.openPanels(), 0, "no card")
end)

test("cooldown blocks a second nudge", function()
  local env = load({ lockdownEnabled = false })
  env.type(121, STEP)
  eq(#env.alerts, 1, "first nudge")
  env.key("escape")
  env.advance(5) -- new burst
  env.type(200, STEP)
  eq(#env.alerts, 1, "still one nudge inside the cooldown")
  env.advance(120)
  env.type(200, STEP)
  eq(#env.alerts, 2, "nudges again after the cooldown")
end)

test("the card's Start button opens the dictation URL and closes the card", function()
  local env = load()
  env.type(121, STEP)
  env.cardMessage({ action = "dictate" })
  eq(env.urls[1], "wispr-flow://start-hands-free", "URL opened")
  eq(env.openPanels(), 0, "card closed")
  local byName = load({ dictationURL = false, dictationName = "Some Dictation App" })
  byName.type(121, STEP)
  byName.cardMessage({ action = "dictate" })
  eq(#byName.urls, 0, "no URL opened")
  eq(byName.apps[1], "Some Dictation App", "app launched by name")
end)

-- ═══ Tier 2: lockdown ═══

test("typing through tier 1 for escalateAfterSeconds locks the keyboard", function()
  local env = load()
  env.type(121, STEP)
  eq(env.liveCanvases(), 0, "not locked at tier 1")
  eq(env.type(96, STEP), 0, "keys pass through until the lock") -- 11.875s past tier 1
  env.advance(STEP)
  eq(env.key("a"), true, "the key that reaches 12s is swallowed")
  eq(env.liveCanvases(), 1, "overlay shown")
  eq(env.key("s"), true, "keys are swallowed during the lockdown")
  eq(env.key("tab"), true, "excluded keys are swallowed too")
  eq(env.key("a", { flags = { cmd = true } }), true, "shortcuts are swallowed too")
end)

test("Esc ends the lockdown at once and is consumed", function()
  local env = load()
  env.type(121, STEP)
  env.type(97, STEP)
  eq(env.liveCanvases(), 1, "locked")
  eq(env.key("escape"), true, "Esc consumed")
  eq(env.liveCanvases(), 0, "overlay gone")
  eq(env.key("a"), false, "typing passes through again")
end)

test("the lockdown ends by itself after lockdownSeconds", function()
  local env = load()
  env.type(121, STEP)
  env.type(97, STEP)
  env.advance(14.9)
  eq(env.key("a"), true, "still locked just before the end")
  env.advance(0.2)
  eq(env.liveCanvases(), 0, "overlay gone")
  eq(env.key("a"), false, "typing passes through again")
end)

test("a pause after tier 1 calls off the escalation", function()
  local env = load()
  env.type(121, STEP)
  env.advance(3.5)
  env.type(200, STEP)
  eq(env.liveCanvases(), 0, "no lockdown")
end)

test("lockdownEnabled = false never locks", function()
  local env = load({ lockdownEnabled = false })
  env.type(121, STEP)
  eq(env.type(400, STEP), 0, "nothing consumed")
  eq(env.liveCanvases(), 0, "no overlay")
end)

-- ═══ Filters ═══

test("excluded keys neither spend nor break a burst", function()
  local env = load({ refillPerSecond = 0 }) -- freeze refill so any charge shows
  env.type(9, STEP)
  local before = env.used()
  local function excluded(label, name, options)
    env.advance(0.0625) -- a counted key here would be charged for this time
    eq(env.key(name, options), false, label .. " passes through")
    near(env.used(), before, label .. " spends nothing")
  end
  for _, name in ipairs({ "left", "right", "up", "down", "tab", "f1", "f13", "f20" }) do
    excluded(name, name)
  end
  excluded("Shift+Tab", "tab", { flags = { shift = true } })
  excluded("cmd shortcut", "a", { flags = { cmd = true } })
  excluded("ctrl shortcut", "a", { flags = { ctrl = true } })
  excluded("autorepeat", "a", { autorepeat = true })
  env.advance(STEP)
  env.key("a")
  -- 12 excluded presses (0.75s) + 0.125s since the last counted key: one
  -- interval, capped at 0.25s. Had any excluded key counted, the sum differs.
  near(env.used(), before + 0.25, "burst continued from the last counted key")
end)

test("Shift and Option keys count as typing", function()
  local env = load()
  env.key("a", { flags = { shift = true } })
  env.advance(STEP)
  env.key("a", { flags = { alt = true } })
  near(env.used(), STEP, "used")
end)

test("extraExcludedKeys adds keys; they count by default", function()
  local default = load()
  default.type(9, STEP, "r")
  near(default.used(), 1.0, "r counts by default")
  local excluded = load({ extraExcludedKeys = { "r", "u" } })
  excluded.type(9, STEP, "r")
  excluded.type(9, STEP, "u")
  near(excluded.used(), 0, "r and u excluded")
  excluded.key("u", { flags = { shift = true } })
  near(excluded.used(), 0, "Shift+u excluded")
end)

-- ═══ Reset chord ═══

test("Control+Option refills the allowance; it is never consumed", function()
  local env = load()
  env.type(41, STEP)
  eq(env.modifiers({ ctrl = true, alt = true }), false, "modifier event passes through")
  near(env.used(), 0, "refilled")
end)

test("the reset chord must match exactly", function()
  local env = load()
  env.type(41, STEP)
  env.modifiers({ ctrl = true })
  env.modifiers({ alt = true })
  env.modifiers({ ctrl = true, alt = true, shift = true })
  env.modifiers({ ctrl = true, alt = true, cmd = true })
  near(env.used(), 5, "no reset")
end)

test("resetModifiers is configurable and can be turned off", function()
  local fn = load({ resetModifiers = { "fn" } })
  fn.type(41, STEP)
  fn.modifiers({ ctrl = true, alt = true })
  near(fn.used(), 5, "old chord ignored")
  fn.modifiers({ fn = true })
  near(fn.used(), 0, "Fn resets")
  local off = load({ resetModifiers = false })
  off.type(41, STEP)
  off.modifiers({ ctrl = true, alt = true })
  near(off.used(), 5, "no chord")
end)

-- ═══ Snooze, disable, off ═══

test("snoozed: keys pass through and nothing is tracked", function()
  local env = load()
  env.cardMessage = nil
  _G.dictationNudgeSnooze()
  eq(env.type(400, STEP), 0, "nothing consumed")
  near(env.used(), 0, "nothing spent")
  eq(env.openPanels(), 0, "no card")
  env.advance(31 * 60) -- snooze expires lazily
  env.type(9, STEP)
  near(env.used(), 1.0, "tracking resumes after the snooze")
end)

test("the card's snooze and unsnooze messages work", function()
  local env = load()
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  eq(env.settings["dictationNudge.snoozeMinutes"], 10, "snooze length remembered")
  env.type(200, STEP)
  near(env.used(), 0, "snoozed")
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "unsnooze" })
  eq(env.openPanels(), 1, "card stays open")
  env.type(9, STEP)
  near(env.used(), 1.0, "tracking again")
end)

test("disabled: fully passive", function()
  local env = load()
  _G.dictationNudgeDisable()
  eq(env.type(400, STEP), 0, "nothing consumed")
  near(env.used(), 0, "nothing spent")
  eq(env.openPanels(), 0, "no card")
end)

test("threshold Never (-1): no tracking, no nudge", function()
  local env = load({}, { ["dictationNudge.nudgeAfterSeconds"] = -1 })
  eq(env.type(400, STEP), 0, "nothing consumed")
  near(env.used(), 0, "nothing spent")
  eq(#env.alerts, 0, "no banner")
end)

-- ═══ Esc and pass-through ═══

test("Esc passes through when nothing is showing", function()
  local env = load()
  eq(env.key("escape"), false, "not consumed")
end)

test("Esc closes an open card and is consumed", function()
  local env = load()
  _G.dictationNudgeSettings()
  eq(env.openPanels(), 1, "card open")
  eq(env.key("escape"), true, "consumed")
  eq(env.openPanels(), 0, "card closed")
end)

-- ═══ Preferences ═══

test("a saved allowance wins over the default and the config", function()
  local env = load({ nudgeAfterSeconds = 60 }, { ["dictationNudge.nudgeAfterSeconds"] = 30 })
  eq(env.internal.config.nudgeAfterSeconds, 30, "threshold")
end)

test("the card can set the allowance; bad values are ignored", function()
  local env = load()
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "set", value = 45 })
  eq(env.settings["dictationNudge.nudgeAfterSeconds"], 45, "saved")
  for _, bad in ipairs({ 0, -5, 1.5, "20", 0 / 0 }) do
    env.cardMessage({ action = "set", value = bad })
  end
  eq(env.internal.config.nudgeAfterSeconds, 45, "unchanged by bad values")
  env.cardMessage({ action = "set", value = -1 })
  eq(env.internal.config.nudgeAfterSeconds, -1, "Never accepted")
end)

-- ═══ Privacy claims in the README, checked against the code ═══

test("the tap listens to keyDown and flagsChanged only", function()
  local env = load()
  table.sort(env.tapTypes)
  eq(#env.tapTypes, 2, "event type count")
  eq(env.tapTypes[1], 10, "keyDown")
  eq(env.tapTypes[2], 12, "flagsChanged")
end)

test("the handler reads only type, keycode, flags, and autorepeat", function()
  -- The fake event raises on any other accessor, so a full run through every
  -- branch (counting, tier 1, lockdown, Esc, filters, chord) is the check.
  local env = load()
  env.type(121, STEP)
  env.type(97, STEP)
  env.key("escape")
  env.key("tab")
  env.key("a", { flags = { cmd = true } })
  env.key("a", { autorepeat = true })
  env.modifiers({ ctrl = true, alt = true })
end)

test("typing writes no log lines and no settings", function()
  local env = load()
  local logsBefore, writesBefore = #env.logs, #env.settingsWrites
  env.type(100, STEP)
  env.key("tab")
  env.modifiers({ ctrl = true, alt = true })
  eq(#env.logs, logsBefore, "log lines during ordinary typing")
  eq(#env.settingsWrites, writesBefore, "settings writes during typing")
end)

test("only two preference keys are ever written", function()
  local env = load()
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "set", value = 30 })
  env.cardMessage({ action = "snooze", minutes = 5 })
  env.type(300, STEP)
  local allowed = { ["dictationNudge.nudgeAfterSeconds"] = true, ["dictationNudge.snoozeMinutes"] = true }
  for _, key in ipairs(env.settingsWrites) do
    assert(allowed[key], "unexpected settings key: " .. tostring(key))
  end
  eq(#env.settingsWrites, 2, "write count")
end)

test("the source uses no character, network, file, shell, or clipboard APIs", function()
  local source = readSource()
  local forbidden = {
    "getCharacters", "getUnicodeString", "getRawEventData", "keyStrokes", "keyStroke",
    "hs%.http", "hs%.socket", "hs%.websocket", "hs%.httpserver", "hs%.network",
    "hs%.pasteboard", "hs%.task", "hs%.execute", "hs%.osascript", "hs%.applescript",
    "hs%.fs", "hs%.sqlite3", "hs%.ipc", "io%.", "os%.execute", "os%.remove", "os%.rename",
    "loadstring", "dofile", "load%(",
  }
  for _, pattern in ipairs(forbidden) do
    assert(not source:find(pattern), "source contains forbidden API: " .. pattern)
  end
  -- The event accessors that do appear are exactly the allowed ones.
  for accessor in source:gmatch("event:(%w+)") do
    assert(accessor == "getType" or accessor == "getKeyCode" or accessor == "getFlags" or accessor == "getProperty",
      "unexpected event accessor: " .. accessor)
  end
end)

test("the card loads nothing from outside the module", function()
  local env = load()
  env.type(121, STEP) -- nudge card
  local nudge = env.panels[#env.panels].html
  _G.dictationNudgeSettings()
  local settings = env.panels[#env.panels].html
  for _, html in ipairs({ nudge, settings }) do
    for _, pattern in ipairs({ "https?:", "src%s*=", "href%s*=", "@import", "url%(", "fetch%(", "XMLHttpRequest", "WebSocket", "<iframe", "<link" }) do
      assert(not html:find(pattern), "card HTML contains " .. pattern)
    end
  end
end)

-- ═══ Card text ═══

test("card text uses the configured names and escapes them", function()
  local env = load({ dictationName = "Talk <100%> & Go" })
  env.type(121, STEP)
  local html = env.panels[#env.panels].html
  assert(html:find("Start Talk &lt;100%%&gt; &amp; Go", 1, false), "dictation name escaped in the button")
  assert(not html:find("__%u+__"), "no unreplaced placeholders")
  local settings = load({ resetModifiers = { "fn" } })
  _G.dictationNudgeSettings()
  assert(settings.panels[1].html:find("Fn resets it.", 1, true), "reset chord named on the card")
  local none = load({ resetModifiers = false })
  _G.dictationNudgeSettings()
  assert(not none.panels[1].html:find("resets it", 1, true), "no chord sentence when off")
end)

test("stop() tears everything down", function()
  local env = load()
  env.type(121, STEP)
  env.type(97, STEP)
  env.module.stop()
  eq(env.liveCanvases(), 0, "overlay gone")
  eq(env.openPanels(), 0, "card gone")
  eq(_G.dictationNudgeTap, nil, "tap released")
end)

-- ═══ Runner ═══

for _, case in ipairs(tests) do
  local ok, err = xpcall(case.fn, debug.traceback)
  if ok then
    print("ok    " .. case.name)
  else
    print("FAIL  " .. case.name)
    table.insert(failures, case.name .. "\n" .. tostring(err))
  end
end

print(string.format("\n%d tests, %d passed, %d failed", #tests, #tests - #failures, #failures))
if #failures > 0 then
  print("")
  for _, failure in ipairs(failures) do print(failure .. "\n") end
  os.exit(1)
end
