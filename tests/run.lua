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

test("a failed overlay cannot leave the keyboard blocked", function()
  local env = load()
  env.hs.canvas.new = function() error("no overlay for you") end
  env.type(121, STEP)
  for index = 1, 97 do -- type on through tier 1; the lockdown attempt raises
    if index > 1 then env.advance(STEP) end
    pcall(env.key, "a")
  end
  eq(env.key("a"), true, "blocked while the lockdown is running")
  env.advance(15.1)
  eq(env.key("a"), false, "released on time even though drawing failed")
end)

test("the lockdown deadline holds even if the release timer never fires", function()
  local env = load()
  env.type(121, STEP)
  env.cardMessage({ action = "close" }) -- "Keep typing": no card left to catch Esc
  env.type(97, STEP)
  eq(env.key("a"), true, "locked")
  for _, timer in ipairs(env.timers) do timer.active = false end -- lose every timer
  env.advance(14.5)
  eq(env.key("a"), true, "still inside the deadline")
  env.advance(1)
  eq(env.key("escape"), false, "past the deadline: Esc is not eaten")
  eq(env.liveCanvases(), 0, "overlay cleaned up by the key handler")
  eq(env.key("a"), false, "past the deadline: keys pass")
end)

test("the test URL and console helper preview the card without arming anything", function()
  for _, fire in ipairs({ function(env) env.urlBinds.dictationNudgeTest() end, function() _G.dictationNudgeTest() end }) do
    local env = load()
    env.type(9, STEP) -- mid-burst
    fire(env)
    eq(env.openPanels(), 1, "nudge card shown")
    eq(_G.dictationNudgeTier1At, nil, "escalation not armed")
    eq(_G.dictationNudgeLastNudgeAt, 0, "cooldown not started")
    env.key("escape")
    eq(env.type(160, STEP), 0, "20s of typing after a preview is never blocked")
    eq(env.liveCanvases(), 0, "no lockdown")
  end
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

test("malformed card messages do nothing", function()
  local env = load()
  _G.dictationNudgeSettings()
  for _, body in ipairs({
    "snooze", 42, {}, { action = "snooze" }, { action = "snooze", minutes = "10" },
    { action = "snooze", minutes = 0 }, { action = "snooze", minutes = 100000 },
    { action = "set" }, { action = "set", value = {} }, { action = "nonsense" },
    { action = "snooze", text = 90 }, { action = "snooze", text = {} },
    { action = "setGate" }, { action = "setGate", value = "2" }, { action = "setGate", value = 2.5 },
    { action = "setGate", value = 11 }, { action = "gateAnswer" }, { action = "gateAnswer", value = "12" },
    { action = "gateAnswer", id = 1, index = 1, value = "12" }, { action = "gateAnswer", value = {} },
    { action = "gateCancel" }, { action = "gateCancel", id = 1 },
  }) do
    env.cardMessage(body)
  end
  eq(_G.dictationNudgeSnoozeUntil, nil, "not snoozed")
  eq(#env.settingsWrites, 0, "nothing saved")
  eq(env.openPanels(), 1, "card still open")
  eq(env.internal.config.nudgeAfterSeconds, 15, "limit unchanged")
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

-- ═══ Snooze gate ═══

local function isSnoozed() return _G.dictationNudgeSnoozeUntil ~= nil end

-- Send `text` as the answer to the problem the card is showing.
local function answerWith(env, text)
  local gate = env.internal.gate()
  env.cardMessage({ action = "gateAnswer", id = gate.id, index = gate.index, value = text })
end

-- Answer the problem that is showing, the way a person would type it.
local function answerCurrent(env)
  local gate = env.internal.gate()
  answerWith(env, string.format("%d", gate.problems[gate.index].answer))
end

local function nevermind(env)
  env.cardMessage({ action = "gateCancel", id = env.internal.gate().id })
end

local function lastScript(env)
  local scripts = env.panels[#env.panels].scripts
  return scripts[#scripts]
end

test("gate off (the default): snooze and disable are immediate", function()
  local env = load()
  eq(env.internal.config.snoozeMathProblems, 0, "default count")
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  assert(isSnoozed(), "snoozed at once")
  eq(env.internal.gate(), nil, "no challenge")
  eq(env.openPanels(), 0, "card closed")
  local fresh = load()
  _G.dictationNudgeSettings()
  fresh.cardMessage({ action = "disable" })
  eq(_G.dictationNudgeDisabled, true, "disabled at once")
  eq(fresh.internal.gate(), nil, "no challenge")
  eq(fresh.openPanels(), 0, "card closed")
end)

test("gate on: snooze starts only after every problem is answered correctly", function()
  local env = load({ snoozeMathProblems = 2 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 45 })
  assert(not isSnoozed(), "not snoozed yet")
  eq(env.openPanels(), 1, "card stays open for the challenge")
  local gate = env.internal.gate()
  eq(#gate.problems, 2, "problem count")
  eq(gate.index, 1, "starts on the first problem")
  assert(lastScript(env):find("showGate({", 1, true), "challenge pushed to the card")
  assert(lastScript(env):find('"title":"Solve 2 to snooze 45m"', 1, true), "title names the goal: " .. lastScript(env))
  assert(lastScript(env):find('"question":"' .. gate.problems[1].question .. '"', 1, true), "first question shown")
  for key in lastScript(env):gmatch('"(%w+)":') do
    assert(key ~= "answer" and key ~= "hint" and key ~= "problems", "view leaks " .. key)
  end

  answerWith(env, string.format("%d", gate.problems[1].answer + 1))
  assert(not isSnoozed(), "a wrong answer does not snooze")
  eq(env.internal.gate().index, 1, "still on problem 1")
  eq(env.internal.gate().misses, 1, "miss counted")
  assert(lastScript(env):find("Not quite. " .. gate.problems[1].hint, 1, true), "hint shown after a miss")
  assert(lastScript(env):find('"wrong":true', 1, true), "marked wrong")

  answerWith(env, "about nine")
  eq(env.internal.gate().misses, 1, "non-numbers are not a miss")
  assert(lastScript(env):find("Type a number", 1, true), "asks for a number")

  answerCurrent(env)
  assert(not isSnoozed(), "one of two is not enough")
  eq(env.internal.gate().index, 2, "moved to problem 2")
  assert(lastScript(env):find('"question":"' .. gate.problems[2].question .. '"', 1, true), "second question shown")

  answerCurrent(env)
  assert(isSnoozed(), "snoozed after the last correct answer")
  near(_G.dictationNudgeSnoozeUntil - env.now, 45 * 60, "for the requested length")
  eq(env.settings["dictationNudge.snoozeMinutes"], 45, "snooze length remembered")
  eq(env.internal.gate(), nil, "challenge cleared")
  eq(env.openPanels(), 0, "card closed")
end)

test("gate on: an answer counts only for the problem it was sent for", function()
  local env = load({ snoozeMathProblems = 2 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  local gate = env.internal.gate()
  gate.problems[2].answer = gate.problems[1].answer -- two problems that happen to share an answer
  local same = { action = "gateAnswer", id = gate.id, index = 1, value = string.format("%d", gate.problems[1].answer) }
  env.cardMessage(same)
  env.cardMessage(same) -- a second click on Check before the card showed problem 2
  assert(not isSnoozed(), "one answer does not pass two problems")
  eq(env.internal.gate().index, 2, "still waiting on problem 2")
  env.cardMessage({ action = "gateAnswer", id = gate.id, index = 3, value = same.value })
  env.cardMessage({ action = "gateAnswer", index = 2, value = same.value })
  env.cardMessage({ action = "gateAnswer", id = gate.id + 1, index = 2, value = same.value })
  assert(not isSnoozed(), "answers for another problem or another challenge are dropped")
  env.cardMessage({ action = "gateCancel", id = gate.id + 1 })
  env.cardMessage({ action = "gateCancel" })
  assert(env.internal.gate(), "a cancel for another challenge is dropped")
  answerCurrent(env)
  assert(isSnoozed(), "the answer for problem 2 finishes it")
end)

test("gate on: a challenge from an earlier card cannot be answered or cancelled on a new one", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  local old = env.internal.gate()
  local oldCard = env.panelCallback
  _G.dictationNudgeSettings() -- the card is replaced; its challenge goes with it
  env.cardMessage({ action = "snooze", minutes = 10 })
  local current = env.internal.gate()
  assert(current.id ~= old.id, "a new challenge has a new id")
  current.problems[1].answer = old.problems[1].answer
  oldCard({ body = { action = "gateCancel", id = old.id } })
  eq(env.internal.gate(), current, "the old card cannot cancel it")
  oldCard({ body = { action = "gateAnswer", id = old.id, index = 1, value = string.format("%d", old.problems[1].answer) } })
  assert(not isSnoozed(), "the old card cannot answer it")
end)

test("gate on: a challenge requested while the card is loading shows once it has loaded", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()   -- card created, page not loaded yet
  env.urlBinds["dictationNudgeSnooze"]()
  local panel = env.panels[#env.panels]
  local question = env.internal.gate().problems[1].question
  local before = #panel.scripts
  env.finishNavigation()
  local shown = false
  for index = before + 1, #panel.scripts do
    if panel.scripts[index]:find("showGate({", 1, true) and panel.scripts[index]:find(question, 1, true) then shown = true end
  end
  assert(shown, "the problem is sent again when the page finishes loading")
end)

test("gate on: the free answer keys follow the keyboard layout", function()
  local env = load({ snoozeMathProblems = 1 })
  local layout = {}
  for name, code in pairs(env.hs.keycodes.map) do layout[name] = code end
  layout["."], layout[","] = layout["s"], layout["d"] -- period and comma moved onto other keys
  layout["s"], layout["d"] = env.hs.keycodes.map["."], env.hs.keycodes.map[","]
  env.hs.keycodes.map = layout                         -- the user switched input source
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  env.type(9, STEP, "s")   -- the physical key that now types a period
  near(env.used(), 0, "the new period key is free")
  env.type(9, STEP, ".")   -- the physical key that used to be the period, now a letter
  near(env.used(), 1.0, "the old period key counts as typing")
end)

test("gate on: formatted answers are accepted", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 5 })
  local answer = env.internal.gate().problems[1].answer
  answerWith(env, " $" .. string.format("%d", answer) .. ".00 ")
  assert(isSnoozed(), "snoozed")
end)

test("gate on: Never mind and Esc drop the snooze", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  local cancelled = env.internal.gate()
  nevermind(env)
  eq(env.internal.gate(), nil, "challenge gone")
  eq(env.openPanels(), 1, "card stays open")
  assert(lastScript(env):find("showGate(null)", 1, true), "card told to hide the challenge")
  assert(not isSnoozed(), "not snoozed")
  env.cardMessage({ action = "gateAnswer", id = cancelled.id, index = 1,
    value = string.format("%d", cancelled.problems[1].answer) }) -- stale answer after cancelling
  assert(not isSnoozed(), "a stale answer does nothing")

  env.cardMessage({ action = "snooze", minutes = 10 })
  assert(env.internal.gate(), "challenge showing again")
  eq(env.key("escape"), true, "Esc consumed")
  eq(env.internal.gate(), nil, "Esc drops the challenge")
  eq(env.openPanels(), 0, "card closed")
  assert(not isSnoozed(), "not snoozed")
end)

test("gate on: Disable is gated, Enable is not", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "disable" })
  eq(_G.dictationNudgeDisabled, false, "not disabled yet")
  assert(lastScript(env):find('"title":"Solve 1 to disable the nudge"', 1, true), "title names the goal")
  answerCurrent(env)
  eq(_G.dictationNudgeDisabled, true, "disabled after solving")
  eq(env.openPanels(), 0, "card closed")
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "disable" }) -- the button now reads Enable
  eq(_G.dictationNudgeDisabled, false, "enabled at once")
  eq(env.internal.gate(), nil, "no challenge to turn it back on")
end)

test("gate on: ending a snooze is never gated", function()
  local env = load({ snoozeMathProblems = 3 })
  _G.dictationNudgeSnoozeUntil = env.now + 600
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "unsnooze" })
  assert(not isSnoozed(), "card ✕ ends the snooze")
  eq(env.internal.gate(), nil, "no challenge")
  _G.dictationNudgeSnoozeUntil = env.now + 600
  env.urlBinds["dictationNudgeSnooze"]()
  assert(not isSnoozed(), "URL toggle ends the snooze")
  eq(env.internal.gate(), nil, "no challenge")
end)

test("gate on: the snooze URL event opens the card straight into the challenge", function()
  local env = load({ snoozeMathProblems = 2 })
  env.urlBinds["dictationNudgeSnooze"]()
  assert(not isSnoozed(), "not snoozed")
  eq(env.openPanels(), 1, "card opened")
  local gate = env.internal.gate()
  eq(#gate.problems, 2, "challenge ready")
  local html = env.panels[#env.panels].html
  assert(html:find('showGate({', 1, true) and html:find('"question":"' .. gate.problems[1].question .. '"', 1, true),
    "first problem is in the page it opens with")
  assert(not html:find("__%u+__"), "no unreplaced placeholders")
  answerCurrent(env); answerCurrent(env)
  assert(isSnoozed(), "snoozed after solving")
  near(_G.dictationNudgeSnoozeUntil - env.now, 30 * 60, "default snooze length")

  local off = load()
  off.urlBinds["dictationNudgeSnooze"]()
  assert(isSnoozed(), "gate off: URL event snoozes at once")
  eq(off.openPanels(), 0, "and opens no card")
end)

test("gate on: answer keys spend nothing while a problem shows; letters still count", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  for _, name in ipairs({ "4", "5", ".", ",", "-", "delete", "return", "pad7", "padenter" }) do
    eq(env.type(9, STEP, name), 0, name .. " passes through")
    near(env.used(), 0, name .. " spends nothing during a challenge")
  end
  env.type(9, STEP, "a")
  near(env.used(), 1.0, "letters still spend during a challenge")
  nevermind(env)
  env.advance(60) -- refill
  env.type(9, STEP, "5")
  near(env.used(), 1.0, "digits count again once the challenge is gone")
end)

test("gate on: typing an answer refills the allowance like a pause", function()
  local env = load({ snoozeMathProblems = 1 })
  env.type(17, STEP, "a")      -- 2.0s used before the challenge
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  env.advance(STEP)
  env.type(8, STEP, "7")       -- one second of digits: 0.25s hold, then 0.75s of refill
  near(env.used(), 1.25, "digits do not reset the pause")
end)

test("gate on: a fresh nudge card drops an unfinished challenge", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  assert(env.internal.gate(), "challenge showing")
  env.type(121, STEP) -- uses the whole 15s allowance: tier 1 fires and reopens the card
  eq(env.internal.gate(), nil, "challenge dropped")
  assert(not isSnoozed(), "not snoozed")
  local html = env.panels[#env.panels].html
  assert(html:find("showGate(null)", 1, true), "the new card opens without a challenge")
end)

test("gate on: picking a second snooze length mid-challenge keeps the same problems", function()
  local env = load({ snoozeMathProblems = 2 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  local first = env.internal.gate().problems[1].question
  answerCurrent(env)
  env.cardMessage({ action = "snooze", minutes = 20 }) -- e.g. a second URL event
  eq(env.internal.gate().problems[1].question, first, "problems not redrawn")
  eq(env.internal.gate().index, 2, "progress kept")
  answerCurrent(env)
  near(_G.dictationNudgeSnoozeUntil - env.now, 20 * 60, "latest request wins")
end)

test("the problem count sets how many problems; start() rejects a bad count", function()
  for _, count in ipairs({ 1, 3, 10 }) do
    local env = load({ snoozeMathProblems = count })
    _G.dictationNudgeSettings()
    env.cardMessage({ action = "snooze", minutes = 10 })
    eq(#env.internal.gate().problems, count, "problems for count " .. count)
  end
  local module = load().module
  for _, bad in ipairs({ 11, 99, 2.5, -1, "3", 0 / 0, true }) do
    local ok, err = pcall(module.start, { snoozeMathProblems = bad })
    eq(ok, false, "rejected: " .. tostring(bad))
    assert(tostring(err):find("snoozeMathProblems", 1, true), "error names the option: " .. tostring(err))
  end
  local ok, err = pcall(module.start, { snoozeMathSettingsKey = "" })
  eq(ok, false, "empty settings key rejected")
end)

test("the card sets the problem count; bad values are ignored; the saved value wins", function()
  local env = load()
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "setGate", value = 3 })
  eq(env.internal.config.snoozeMathProblems, 3, "count set")
  eq(env.settings["dictationNudge.snoozeMathProblems"], 3, "count saved")
  for _, bad in ipairs({ -1, 1.5, 11, "2", 0 / 0 }) do
    env.cardMessage({ action = "setGate", value = bad })
    eq(env.internal.config.snoozeMathProblems, 3, "bad value ignored: " .. tostring(bad))
  end
  env.cardMessage({ action = "snooze", minutes = 10 })
  env.cardMessage({ action = "setGate", value = 0 })
  eq(env.internal.config.snoozeMathProblems, 3, "cannot be switched off from inside a challenge")
  nevermind(env)
  env.cardMessage({ action = "setGate", value = 0 })
  eq(env.internal.config.snoozeMathProblems, 0, "switched off from the card")
  local saved = load({ snoozeMathProblems = 1 }, { ["dictationNudge.snoozeMathProblems"] = 5 })
  eq(saved.internal.config.snoozeMathProblems, 5, "saved count wins over config")
  local junk = load({ snoozeMathProblems = 1 }, { ["dictationNudge.snoozeMathProblems"] = 400 })
  eq(junk.internal.config.snoozeMathProblems, 1, "out-of-range saved count ignored")
end)

test("the card shows the current count, including one set in config", function()
  local env = load({ snoozeMathProblems = 4 })
  _G.dictationNudgeSettings()
  assert(env.panels[1].html:find("var mathCount=4,", 1, true), "count reaches the card")
  assert(_G.dictationNudgeStatus():find("snoozeMath=4", 1, true), "status shows it")
  assert(load().module and _G.dictationNudgeStatus():find("snoozeMath=off", 1, true), "status shows off")
end)

-- ═══ Custom snooze lengths ═══

test("typed snooze lengths: minutes and hours in the usual spellings", function()
  local parse = load().internal.parseSnoozeLength
  local good = {
    ["90"] = 90, ["45m"] = 45, ["45 m"] = 45, ["90 mins"] = 90, ["1 minute"] = 1, ["20 minutes"] = 20, ["5 min"] = 5,
    ["2h"] = 120, ["2 h"] = 120, ["1 hour"] = 60, ["3 hours"] = 180, ["2 hrs"] = 120, ["1hr"] = 60,
    ["1.5h"] = 90, ["1.5 hours"] = 90, ["0.5h"] = 30, [".5h"] = 30, ["0.25 hours"] = 15, ["0.1h"] = 6, ["1.50000000h"] = 90, ["60.0"] = 60, ["1h,30m"] = 90,
    ["1 hour, 30"] = 90, ["an hour and 5 minutes"] = 65,
    ["1h30"] = 90, ["1h 30"] = 90, ["1h30m"] = 90, ["1h 30m"] = 90, ["1 hr, 15 min"] = 75,
    ["1 hour 30 minutes"] = 90, ["1 hour and 30 minutes"] = 90, ["2 hours and 5 minutes"] = 125,
    ["1:30"] = 90, ["0:45"] = 45, ["12:00"] = 720,
    ["an hour"] = 60, ["a minute"] = 1, ["half an hour"] = 30, ["half hour"] = 30,
    ["an hour and a half"] = 90, ["2 and a half hours"] = 150, ["2 hours and a half"] = 150,
    ["  1H   30M  "] = 90, ["12h"] = 720, ["720"] = 720, ["1"] = 1,
  }
  for text, minutes in pairs(good) do
    local got, reason = parse(text)
    eq(got, minutes, "'" .. text .. "' (" .. tostring(reason) .. ")")
  end
end)

test("typed snooze lengths: days and longer are refused, and so is anything unclear", function()
  local parse = load().internal.parseSnoozeLength
  local unitsOnly = "Minutes and hours only."
  for _, text in ipairs({ "2d", "2 days", "1 day", "1 week", "3 weeks", "1 month", "2 months", "1 year",
    "1h 2d", "1 day 2 hours", "30s", "90 seconds", "day", "month" }) do
    local got, reason = parse(text)
    eq(got, nil, "'" .. text .. "' refused")
    eq(reason, unitsOnly, "'" .. text .. "' reason")
  end
  local help = "Try 45m, 1.5h, or 1h 30m."
  for _, text in ipairs({ "", "   ", "soon", "tomorrow", "h", "m", "-5", "1e3", "1h 1h", "30m 1h", "30m 15",
    "1h30m15", "30 1h", "1:5", "1:75", "1:30:00", "1,5h", "ninety", "30m and a half", "and a half", "1 lightyear",
    "1 and h", "1h,,,30m", "1h, , 30m", ",1h", "1h,", "1h and", "and 1h", "1 and 30", "1h and and 30m", "1h , 30m",
    "4611686018427387905:00", "1:30pm", "h1", "1hh", "1 h m" }) do
    local got, reason = parse(text)
    eq(got, nil, "'" .. text .. "' refused")
    eq(reason, help, "'" .. text .. "' reason")
  end
  for _, text in ipairs({ "0", "0m", "0h", "721", "12h1m", "13h", "9999", "12:01", "99999", "100:00",
    "4611686018427387905h", "4611686018427387905", "18446744073709551616m", "0.0h" }) do
    local got, reason = parse(text)
    eq(got, nil, "'" .. text .. "' refused")
    eq(reason, "Snooze can be 1 minute to 12 hours.", "'" .. text .. "' reason")
  end
  for _, text in ipairs({ "1.5", "1.5m", "0.01h", "1.33 hours", "59.9999999", "0.9999999h", "1.00000001h",
    "89.99999999999999", "1.000001m" }) do
    local got, reason = parse(text)
    eq(got, nil, "'" .. text .. "' refused")
    eq(reason, "Use a whole number of minutes.", "'" .. text .. "' reason")
  end
  for _, value in ipairs({ 90, true, {} }) do eq(parse(value), nil, "non-string refused") end
  eq(parse(nil), nil, "nil refused")
end)

test("the card's typed snooze length snoozes, or explains why not", function()
  local env = load()
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", text = "3 days" })
  assert(not isSnoozed(), "days do not snooze")
  eq(env.openPanels(), 1, "card stays open")
  assert(lastScript(env):find('snoozeError({"message":"Minutes and hours only."})', 1, true), "reason sent to the card: " .. lastScript(env))
  env.cardMessage({ action = "snooze", text = "1h 30m" })
  assert(isSnoozed(), "snoozed")
  near(_G.dictationNudgeSnoozeUntil - env.now, 90 * 60, "for 90 minutes")
  eq(env.settings["dictationNudge.snoozeMinutes"], 90, "remembered as the default")
  eq(env.openPanels(), 0, "card closed")

  local gated = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  gated.cardMessage({ action = "snooze", text = "2 hours" })
  assert(not isSnoozed(), "typed lengths go through the gate too")
  assert(lastScript(gated):find('"title":"Solve 1 to snooze 2h"', 1, true), "gate names the typed length")
  answerCurrent(gated)
  near(_G.dictationNudgeSnoozeUntil - gated.now, 120 * 60, "for two hours")
end)

-- ═══ Money math bank ═══

-- A pick() that returns list[index] for each queued index, in order.
local function scripted(indices)
  local position = 0
  return function(list)
    position = position + 1
    assert(indices[position], "script ran out of picks")
    return list[indices[position]]
  end
end

test("money math: one hand-worked case per template", function()
  local bank = load().internal.moneyMath
  local byName = {}
  for _, template in ipairs(bank.TEMPLATES) do byName[template.name] = template end
  -- { template, picks, answer worked by hand, what it is }
  local golden = {
    { "tip",                { 3, 2 },    9,       "15% of $60" },
    { "discount",           { 3, 3 },    60,      "$80 less 25%" },
    { "sales_tax",          { 2, 2 },    44,      "$40 plus 10%" },
    { "percent_change",     { 4, 3, 1 }, 25,      "$80 to $100" },
    { "percent_change",     { 4, 3, 2 }, 25,      "$80 to $60" },
    { "rule_of_72",         { 5, 1 },    9,       "72 / 8" },
    { "rule_of_72",         { 4, 2 },    6,       "double in 12 years" },
    { "card_interest",      { 2, 3 },    40,      "$2,000 at 24% APR for a month" },
    { "card_interest",      { 1, 2 },    15,      "$1,000 at 18% APR for a month" },
    { "subscription_year",  { 5 },       180,     "$15 x 12" },
    { "daily_habit",        { 3, 2 },    1500,    "$6 x 5 x 50" },
    { "hourly_salary",      { 1, 5 },    80000,   "$40 x 2,000" },
    { "hourly_salary",      { 2, 4 },    45,      "$90,000 / 2,000" },
    { "savings_rate",       { 2, 3 },    15,      "$750 of $5,000" },
    { "split_with_tip",     { 3, 3 },    24,      "$80 + 20% = $96, / 4" },
    { "four_percent_rule",  { 2, 1 },    1000000, "$40,000 x 25" },
    { "four_percent_rule",  { 2, 2 },    40000,   "4% of $1,000,000" },
    { "employer_match",     { 2, 2 },    2400,    "4% of $60,000" },
    { "compound_two_years", { 1, 1 },    1210,    "$1,000 at 10%, twice" },
    { "compound_two_years", { 1, 2 },    1440,    "$1,000 at 20%, twice" },
    { "profit_margin",      { 4, 2 },    20,      "cost $80, sale $100" },
    { "runway",             { 3, 2 },    6,       "$24,000 at $4,000 a month" },
    { "payback",            { 3, 4 },    12,      "$300 at $25 a month" },
    { "fee_drag",           { 3, 1 },    2000,    "1% of $200,000" },
    { "drawdown_recovery",  { 2 },       100,     "down 50%: $50 back to $100" },
    { "drawdown_recovery",  { 1 },       25,      "down 20%: $80 back to $100" },
    { "drawdown_recovery",  { 4 },       300,     "down 75%: $25 back to $100" },
    { "real_return",        { 3, 2 },    4,       "7% less 3%" },
    { "tax_set_aside",      { 3, 2 },    1200,    "30% of $4,000" },
    { "tax_set_aside",      { 3, 1 },    1000,    "25% of $4,000" },
    { "raise_after_tax",    { 2, 2 },    7600,    "$10,000 less 24%" },
    { "down_payment",       { 3, 3 },    80000,   "20% of $400,000" },
  }
  local covered = {}
  for _, case in ipairs(golden) do
    local question, answer, hint = byName[case[1]].make(scripted(case[2]))
    covered[case[1]] = true
    eq(answer, case[3], case[1] .. " (" .. case[4] .. "): " .. question)
    assert(type(hint) == "string" and #hint > 0, case[1] .. ": hint missing")
  end
  for _, template in ipairs(bank.TEMPLATES) do
    assert(covered[template.name], template.name .. ": no hand-worked case")
  end
  eq((byName.split_with_tip.make(scripted({ 3, 3 }))),
    "$80 dinner plus a 20% tip, split 4 ways. What does each person pay?", "wording")
  eq((byName.percent_change.make(scripted({ 4, 3, 2 }))),
    "A stock goes from $80 to $60. Percent drop?", "wording")
end)

test("money math: every possible problem has a positive whole-number answer", function()
  local bank = load().internal.moneyMath
  local combinations = 0
  for _, template in ipairs(bank.TEMPLATES) do
    -- Walk every combination of picks by replaying make() with longer prefixes.
    local function walk(prefix)
      local position = 0
      local ok, question, answer, hint = pcall(template.make, function(list)
        position = position + 1
        if prefix[position] then return list[prefix[position]] end
        error({ branch = #list })
      end)
      if not ok then
        assert(type(question) == "table" and question.branch, tostring(question))
        for choice = 1, question.branch do
          local longer = { table.unpack(prefix) }
          longer[#longer + 1] = choice
          walk(longer)
        end
        return
      end
      combinations = combinations + 1
      local where = template.name .. " {" .. table.concat(prefix, ",") .. "}: " .. question
      assert(answer > 0 and answer == math.floor(answer), "answer not a positive whole number (" .. tostring(answer) .. "), " .. where)
      for _, text in ipairs({ question, hint }) do
        assert(not text:find("%f[%a]nan%f[%A]") and not text:find("%f[%a]inf%f[%A]"), "broken number, " .. where)
      end
      assert(not question:find("%d%.%d"), "fractional number in the question, " .. where)
      assert(not (question .. hint):find("\226\128\148"), "em dash, " .. where)
      -- The hint gives the method. It must not state the answer in the unit the
      -- question asks for: "25%" when it asks for a percent, "$25" otherwise.
      local shown = " " .. hint:gsub("[%.%?]$", "") .. " "
      if question:lower():find("percent", 1, true) then
        assert(not shown:find("%f[%S]" .. string.format("%d", answer) .. "%%%f[%s%.]"),
          "hint states the answer as a percent, " .. where .. " | " .. hint)
      else
        assert(not shown:find("%f[%S]" .. bank.money(answer):gsub("%$", "%%$") .. "%f[%s%.]"),
          "hint states the answer in dollars, " .. where .. " | " .. hint)
      end
      -- Same rule for the Tip button's shortcut, which is fixed per kind of problem.
      local tip = " " .. template.tip:gsub("[%.%?]$", "") .. " "
      if question:lower():find("percent", 1, true) then
        assert(not tip:find("%f[%S]" .. string.format("%d", answer) .. "%%%f[%s%.]"), "tip states the answer as a percent, " .. where)
      else
        assert(not tip:find("%f[%S]" .. bank.money(answer):gsub("%$", "%%$") .. "%f[%s%.]"), "tip states the answer in dollars, " .. where)
      end
      assert(bank.isCorrect({ answer = answer }, string.format("%d", answer)), "own answer rejected, " .. where)
      assert(not bank.isCorrect({ answer = answer }, string.format("%d", answer + 1)), "wrong answer accepted, " .. where)
    end
    walk({})
  end
  assert(combinations > 250, "enumerated " .. combinations .. " combinations")
end)

test("money math: every kind of problem has a short tip, and the card is sent it", function()
  local env = load({ snoozeMathProblems = 3 })
  for _, template in ipairs(env.internal.moneyMath.TEMPLATES) do
    assert(type(template.tip) == "string" and #template.tip >= 20, template.name .. ": tip missing")
    assert(utf8.len(template.tip) <= 120, template.name .. ": tip too long for the card (" .. utf8.len(template.tip) .. ")")
    assert(not template.tip:find("%$"), template.name .. ": a tip uses no dollar amounts")
    assert(not template.tip:find("\226\128\148"), template.name .. ": em dash")
  end
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 10 })
  local gate = env.internal.gate()
  for index = 1, 3 do
    assert(lastScript(env):find('"tip":"' .. gate.problems[index].tip .. '"', 1, true), "problem " .. index .. " is sent with its own tip")
    if index < 3 then answerCurrent(env) end
  end
end)

test("money math: a challenge never repeats a template; answers parse like a person types them", function()
  local bank = load().internal.moneyMath
  for count = 1, #bank.TEMPLATES do
    local kinds = {}
    for _, problem in ipairs(bank.newChallenge(count)) do
      assert(not kinds[problem.kind], "repeated " .. problem.kind .. " in a challenge of " .. count)
      kinds[problem.kind] = true
    end
  end
  eq(#bank.newChallenge(#bank.TEMPLATES + 3), #bank.TEMPLATES + 3, "longer than the bank still fills")
  for text, value in pairs({ ["9"] = 9, [" 9 "] = 9, ["$1,200"] = 1200, ["15%"] = 15, ["1210.00"] = 1210, ["$ 80,000"] = 80000 }) do
    eq(bank.parseAnswer(text), value, "parse '" .. text .. "'")
  end
  for text, value in pairs({ ["25."] = 25, [".5"] = 0.5, ["1,000,000"] = 1000000, ["$40"] = 40, ["40 %"] = 40, ["-3"] = -3 }) do
    eq(bank.parseAnswer(text), value, "parse '" .. text .. "'")
  end
  for _, bad in ipairs({ "", "abc", "12abc", "1.2.3", "--4", "$", "nine", "1e3", "0x10", "2%5", "2$5", "%25", "25$",
    "1,2,00", "12,00", ",200", "1200,", "1,0000", "$$5", "5%%", ".", "$.", "2 5", "1,200.5.0" }) do
    eq(bank.parseAnswer(bad), nil, "reject '" .. bad .. "'")
  end
  for _, close in ipairs({ "24.999", "25.004", "25.0001", "24", "26", "250", "2.5" }) do
    assert(not bank.isCorrect({ answer = 25 }, close), "'" .. close .. "' is not 25")
  end
  for _, same in ipairs({ "25", "25.0", "25.00", "$25", "25%", " 25 " }) do
    assert(bank.isCorrect({ answer = 25 }, same), "'" .. same .. "' is 25")
  end
  eq(bank.parseAnswer(nil), nil, "nil")
  eq(bank.parseAnswer(42), nil, "a number is not typed text")
  eq(bank.money(1200) .. bank.money(999) .. bank.money(1000000), "$1,200$999$1,000,000", "money formatting")
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

test("typing below the allowance writes no log lines and no settings", function()
  local env = load()
  local logsBefore, writesBefore = #env.logs, #env.settingsWrites
  env.type(100, STEP)
  env.key("tab")
  env.modifiers({ ctrl = true, alt = true })
  eq(#env.logs, logsBefore, "log lines during ordinary typing")
  eq(#env.settingsWrites, writesBefore, "settings writes during typing")
end)

test("a full run through both tiers logs fixed messages and leaks nothing", function()
  local env = load()
  local logsBefore = #env.logs
  -- Varied keys, modifiers, and held keys, through the nudge and the lockdown.
  local names = { "a", "s", "d", "f", "r", "u", "space" }
  for index = 1, 260 do
    env.advance(STEP)
    env.key(names[index % #names + 1], { flags = { shift = index % 5 == 0, alt = index % 11 == 0 } })
    if index % 17 == 0 then env.key("left") end
    if index % 23 == 0 then env.key("a", { autorepeat = true }) end
  end
  env.key("escape")
  env.modifiers({ ctrl = true, alt = true })
  local expected = { "info: Tier 1 nudge fired", "info: Lockdown engaged for 15s", "info: Lockdown ended" }
  eq(#env.logs - logsBefore, #expected, "log line count")
  for index, line in ipairs(expected) do
    eq(env.logs[logsBefore + index], line, "log line " .. index)
  end
  eq(#env.settingsWrites, 0, "settings writes")
  eq(#env.urls, 0, "URLs opened")
  eq(#env.apps, 0, "apps launched")
end)

test("only three preference keys are ever written", function()
  local env = load()
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "set", value = 30 })
  env.cardMessage({ action = "setGate", value = 1 })
  env.cardMessage({ action = "snooze", minutes = 5 })
  answerWith(env, "wrong")
  answerCurrent(env)
  env.type(300, STEP)
  local allowed = {
    ["dictationNudge.nudgeAfterSeconds"] = true, ["dictationNudge.snoozeMinutes"] = true,
    ["dictationNudge.snoozeMathProblems"] = true,
  }
  for _, key in ipairs(env.settingsWrites) do
    assert(allowed[key], "unexpected settings key: " .. tostring(key))
  end
  eq(#env.settingsWrites, 3, "write count")
  eq(env.settings["dictationNudge.nudgeAfterSeconds"], 30, "saved limit is the number that was set")
  eq(env.settings["dictationNudge.snoozeMinutes"], 5, "saved snooze is the number that was set")
end)

test("the text of an answer is never logged, saved, or sent back to the card", function()
  local env = load({ snoozeMathProblems = 1 })
  _G.dictationNudgeSettings()
  env.cardMessage({ action = "snooze", minutes = 5 })
  local logsBefore, writesBefore = #env.logs, #env.settingsWrites
  answerWith(env, "31337")
  answerWith(env, "not a number 424242")
  eq(#env.logs, logsBefore, "a rejected answer logs nothing")
  eq(#env.settingsWrites, writesBefore, "a rejected answer saves nothing")
  -- A correct answer in a distinctive format: only the snooze itself is logged and saved.
  local typed = "$ " .. string.format("%d", env.internal.gate().problems[1].answer) .. ".000 %"
  local panel = env.panels[#env.panels]
  answerWith(env, typed)
  assert(isSnoozed(), "the formatted answer was accepted")
  eq(#env.logs, logsBefore + 1, "one log line")
  eq(env.logs[#env.logs], "info: Snoozed for 5m", "and it is the snooze")
  eq(#env.settingsWrites, writesBefore + 1, "one settings write")
  eq(env.settingsWrites[#env.settingsWrites], "dictationNudge.snoozeMinutes", "the snooze length")
  eq(env.settings["dictationNudge.snoozeMinutes"], 5, "saved as the number of minutes")
  for _, script in ipairs(panel.scripts) do
    for _, text in ipairs({ "31337", "424242", ".000" }) do
      assert(not script:find(text, 1, true), "typed answer echoed back to the card: " .. text)
    end
  end
  for _, line in ipairs(env.logs) do
    assert(not line:find(".000", 1, true) and not line:find("31337", 1, true), "typed answer in the log: " .. line)
  end
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

-- ═══ Config and lifecycle ═══

test("start() rejects unknown and mistyped options before touching anything", function()
  for _, bad in ipairs({
    { lockdownEnable = false },          -- misspelled
    { lockdownSeconds = "15" },
    { lockdownSeconds = 0 },
    { nudgeAfterSeconds = 0 },
    { gapSeconds = -1 },
    { lockdownEnabled = "no" },
    { dictationName = "" },
    { dictationURL = 42 },
    { extraExcludedKeys = "r" },
    { resetModifiers = { "hyper" } },
    { resetModifiers = { ctrl = true, alt = true } }, -- keyed, not a list
    { resetModifiers = { "ctrl", nil, "alt" } },      -- hole
    { extraExcludedKeys = { r = true } },
    { snoozeMinutes = 100000 },
    false,                                            -- not a table at all
    "lockdownEnabled = false",
  }) do
    for name in pairs(_G) do
      if type(name) == "string" and name:match("^dictationNudge") then _G[name] = nil end
    end
    local env = Stub.new()
    _G.hs = env.hs
    local module = dofile(MODULE_PATH)
    local ok, err = pcall(module.start, bad)
    eq(ok, false, "start should fail")
    assert(tostring(err):find("dictation_nudge:", 1, true), "error names the module: " .. tostring(err))
    eq(env.tapCallback, nil, "no event tap was created")
    eq(next(env.urlBinds), nil, "no URL handler was bound")
  end
end)

test("fractional durations are accepted", function()
  local env = load({ lockdownSeconds = 7.5, gapSeconds = 2.5, escalateAfterSeconds = 1.5, cooldownSeconds = 0.5 })
  env.type(121, STEP)
  env.type(14, STEP)
  eq(env.liveCanvases(), 1, "locked without raising")
  env.advance(7.6)
  eq(env.key("a"), false, "released")
end)

test("each start() begins from the defaults", function()
  local env = load({ lockdownEnabled = false, extraExcludedKeys = { "r" } })
  env.module.start({})
  eq(env.internal.config.lockdownEnabled, true, "override not inherited")
  env.type(9, STEP, "r")
  near(env.used(), 1.0, "r counts again")
end)

test("stop() tears everything down", function()
  local env = load()
  env.type(121, STEP)
  env.type(97, STEP)
  env.module.stop()
  eq(env.liveCanvases(), 0, "overlay gone")
  eq(env.openPanels(), 0, "card gone")
  eq(_G.dictationNudgeTap, nil, "tap released")
  eq(next(env.urlBinds), nil, "URL handlers unbound")
  eq(_G.dictationNudgeLock(), "not running", "manual lock refused without the tap")
  eq(env.liveCanvases(), 0, "no overlay after stop")
end)

test("the manual lock needs an enabled tap", function()
  local env = load()
  _G.dictationNudgeTap:stop() -- the object exists but is not enabled
  eq(_G.dictationNudgeLock(), "not running", "refused")
  eq(env.liveCanvases(), 0, "no overlay")
  _G.dictationNudgeTap:start()
  _G.dictationNudgeLock()
  eq(env.liveCanvases(), 1, "locks when the tap is enabled")
  eq(env.key("escape"), true, "and Esc ends it")
  eq(env.liveCanvases(), 0, "overlay gone")
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
