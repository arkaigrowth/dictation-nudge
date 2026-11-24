-- ═══════════════════════════════════════════════════════════════
-- Dictation Nudge
-- A Hammerspoon module that nudges you to dictate instead of type.
-- https://github.com/arkaigrowth/dictation-nudge   (MIT)
-- ═══════════════════════════════════════════════════════════════
-- Typing spends a refillable allowance (`nudgeAfterSeconds`). When it
-- runs out you get an escalating reminder to switch to dictation.
--   * Only confirmed typing intervals spend allowance: the time between
--     two counted keys, capped at 0.25s per interval.
--   * A lone key spends nothing. Stopping stops the spending.
--   * After a 0.25s pause the allowance refills at 1s per second.
--   * Holding the reset chord (default Control+Option) refills it at once.
--
-- What the event tap sees, and what it keeps:
--   * It taps keyDown and flagsChanged events for the whole session.
--   * From an event macOS delivers to it, it can read, in memory: the
--     event type, the keycode (Esc handling and the excluded-key filter),
--     the modifier flags (shortcut filter and reset chord), and the
--     autorepeat flag. Nothing else. It never asks for the characters an
--     event would produce.
--   * What it remembers is timing, never keys: when the last counted key
--     arrived, how many seconds of allowance are used, when the last
--     nudge fired, and when a lockdown ends. No keycode, flag, or
--     character is stored, logged, or sent anywhere.
--   * It logs state changes to the Hammerspoon console (for example:
--     started, nudge fired, lockdown began or ended, snoozed, limit or
--     snooze-gate count changed). Ordinary typing logs nothing, and
--     the text typed into the card's fields is never logged.
--   * On disk it persists three preferences through hs.settings: the
--     allowance, the last snooze length, and the snooze-gate problem
--     count.
--   * The module makes no network calls of its own. The card's Start
--     button asks macOS to open `dictationURL`, which is whatever you
--     configure, with whatever app is registered for it.
--   * It does change what reaches your apps in two cases: an Esc key
--     press is consumed while the card or the lockdown is showing, and
--     every other key press is consumed during the lockdown. Modifier
--     changes and key releases are never consumed.
--   * macOS stops delivering keystrokes to event taps while secure input
--     is on (password fields). That is the OS, not this code. To this
--     module it looks like a pause, and it also means the lockdown
--     neither blocks keys nor sees Esc there.
--
-- Escalation tiers:
--   Tier 1 @ allowance used: sound + banner + nudge card with a
--        "Start <dictation app>" button (opens `dictationURL`), the
--        allowance slider, snooze, and "Keep typing". Fires only on a
--        counted key; idle time never triggers a nudge. Esc closes the
--        card from anywhere (no focus needed).
--   Tier 2 @ +escalateAfterSeconds of typing THROUGH tier 1:
--        the module tries to draw an overlay over each display, and
--        swallows the key presses the tap receives for lockdownSeconds
--        whether or not the drawing worked. Esc ends it.
--        Set lockdownEnabled = false to turn the automatic lockdown off.
--
-- Keys that never count (they neither spend allowance nor break a burst):
--   * autorepeat events (a key held down)
--   * any keyDown with Command or Control held (shortcuts)
--   * F1-F20, arrow keys, Tab, plus anything in `extraExcludedKeys`
--   * lone modifiers: macOS sends those as flagsChanged, never keyDown
--   Shift+letter still counts: capitals are typing.
--
-- Controls:
--   * Colored seconds in the menubar: click to open the card.
--   * URL events (for a launcher app, Raycast, Alfred, Shortcuts):
--       hammerspoon://dictationNudgeSettings
--       hammerspoon://dictationNudgeSnooze
--       hammerspoon://dictationNudgeTest   (a preview: no cooldown, no lockdown)
--   * The allowance ("Never" = off) and snooze length persist across reloads.
--   * Custom snooze lengths are typed in minutes and hours: 45m, 1.5h,
--     1h 30m, 2 hours, 1:30, "an hour and a half". A bare number is
--     minutes. 1 minute to 12 hours; days and longer are refused.
--   * Disable/Enable is session-only: a reload re-enables.
--
-- Snooze gate (optional, off by default):
--   Set "Math to snooze" under the card's gear (or `snoozeMathProblems` in
--   config) to 1 or more, and Snooze and Disable first show that many
--   short money-math problems: tips, discounts, interest, the rule of 72,
--   runway, fees. The snooze starts
--   only after the last correct answer. Esc or "Never mind" drops it.
--   "Tip" shows the mental-math shortcut for that kind of problem.
--   It is friction for a reflex, not a lock: ending a snooze, re-enabling,
--   the allowance slider, and the setting itself are never gated.
--   While a problem is showing, digit keys don't spend allowance. The answer
--   box is the card's own text field; the event tap still reads no characters.
--
-- Requires Accessibility AND Input Monitoring for Hammerspoon
-- (System Settings -> Privacy & Security). A missing Input Monitoring
-- grant fails SILENTLY (the tap never fires); dictationNudgeStatus() shows it.
--
-- Usage in ~/.hammerspoon/init.lua:
--   local ok, dictation_nudge = pcall(require, "dictation_nudge")
--   if ok then dictation_nudge.start({}) end

local M = {}

local log = hs.logger.new("dictation_nudge", "info")

-- ═══ Config (override via start({...})) ═══
local DEFAULTS = {
  gapSeconds           = 3,      -- max gap joining a typing burst / continuing escalation
  refillDelaySeconds   = 0.25,   -- short pause allowance, independent of the 3s burst boundary
  refillPerSecond      = 1,      -- one second of typing credit restored per idle second
  nudgeAfterSeconds    = 15,     -- typing allowance that triggers tier 1 (-1 = Never)
  escalateAfterSeconds = 12,     -- typing past tier 1 this long -> tier 2
  lockdownSeconds      = 15,     -- full-screen input block duration
  lockdownEnabled      = true,   -- false = dialog-only (gentle) mode
  cooldownSeconds      = 120,    -- minimum time between tier-1 nudges
  soundName            = "Glass",-- system sound on tier 1 (false = silent)
  dictationName        = "Wispr Flow", -- shown on the card, banner, and lockdown overlay
  dictationURL         = "wispr-flow://start-hands-free", -- opened by the card's Start button;
                                 -- false = launch the app called dictationName instead
  extraExcludedKeys    = {},     -- hs.keycodes.map names that never count, e.g. {"r", "u"}
  resetModifiers       = {"ctrl", "alt"}, -- holding exactly these refills the allowance
                                 -- (match your dictation hotkey); false = no reset chord
  snoozeMinutes        = 30,     -- snooze duration
  snoozeMathProblems   = 0,      -- money-math problems to solve before Snooze or Disable
                                 -- takes effect (0 = off, max 10); see "Snooze gate" above
  menubarEnabled       = true,   -- native remaining-seconds indicator
  menubarAutosaveName  = "DictationNudge", -- macOS remembers the item's position under this name
  settingsKey          = "dictationNudge.nudgeAfterSeconds", -- hs.settings persistence key
  snoozeSettingsKey    = "dictationNudge.snoozeMinutes",     -- last-used snooze duration
  snoozeMathSettingsKey = "dictationNudge.snoozeMathProblems", -- snooze-gate count set on the card
}

-- The live config: defaults, then whatever start({...}) passed.
local config = {}
for key, value in pairs(DEFAULTS) do config[key] = value end

local SNOOZE_MAX_MINUTES = 720
local SNOOZE_MATH_MAX = 10

-- Called by start() before it touches anything. A wrong type would otherwise
-- surface later as an error inside the keyboard callback, and a misspelled
-- option (say, lockdownEnable) would be silently ignored.
local function validateConfig(candidate)
  local function fail(key, want)
    error(string.format("dictation_nudge: option '%s' must be %s", tostring(key), want), 0)
  end
  local function isNumber(value) return type(value) == "number" and value == value and math.abs(value) ~= math.huge end
  for key in pairs(candidate) do
    if DEFAULTS[key] == nil then error("dictation_nudge: unknown option '" .. tostring(key) .. "'", 0) end
  end
  for _, key in ipairs({"gapSeconds", "refillDelaySeconds", "refillPerSecond", "escalateAfterSeconds", "cooldownSeconds"}) do
    if not isNumber(candidate[key]) or candidate[key] < 0 then fail(key, "a number, zero or more") end
  end
  if not isNumber(candidate.lockdownSeconds) or candidate.lockdownSeconds <= 0 then
    fail("lockdownSeconds", "a number above zero")
  end
  local allowance = candidate.nudgeAfterSeconds
  if not isNumber(allowance) or (allowance ~= -1 and allowance < 1) then
    fail("nudgeAfterSeconds", "1 or more, or -1 for never")
  end
  local snooze = candidate.snoozeMinutes
  if not isNumber(snooze) or snooze < 1 or snooze > SNOOZE_MAX_MINUTES then
    fail("snoozeMinutes", "between 1 and " .. SNOOZE_MAX_MINUTES)
  end
  local problems = candidate.snoozeMathProblems
  if not isNumber(problems) or problems ~= math.floor(problems) or problems < 0 or problems > SNOOZE_MATH_MAX then
    fail("snoozeMathProblems", "a whole number from 0 to " .. SNOOZE_MATH_MAX)
  end
  for _, key in ipairs({"lockdownEnabled", "menubarEnabled"}) do
    if type(candidate[key]) ~= "boolean" then fail(key, "true or false") end
  end
  for _, key in ipairs({"dictationName", "menubarAutosaveName", "settingsKey", "snoozeSettingsKey", "snoozeMathSettingsKey"}) do
    if type(candidate[key]) ~= "string" or candidate[key] == "" then fail(key, "a non-empty string") end
  end
  for _, key in ipairs({"soundName", "dictationURL"}) do
    if candidate[key] ~= false and type(candidate[key]) ~= "string" then fail(key, "a string, or false") end
  end
  -- A plain list: {"a", "b"}. Rejects keyed tables such as {ctrl = true},
  -- which ipairs would silently read as empty, and lists with holes.
  local function isListOf(value, accept)
    if type(value) ~= "table" then return false end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    for index = 1, count do -- every entry must sit at 1..count
      if not accept(value[index]) then return false end
    end
    return true
  end
  if not isListOf(candidate.extraExcludedKeys, function(name) return type(name) == "string" end) then
    fail("extraExcludedKeys", "a list of key names, like {\"r\", \"u\"}")
  end
  local modifiers = { cmd = true, ctrl = true, alt = true, shift = true, fn = true }
  if candidate.resetModifiers ~= false
    and not isListOf(candidate.resetModifiers, function(name) return modifiers[name] == true end) then
    fail("resetModifiers", "a list of cmd, ctrl, alt, shift, fn, like {\"ctrl\", \"alt\"}, or false")
  end
end

-- Slider stops for the settings panel (seconds; -1 = Never/off)
local THRESHOLD_STOPS = {15, 30, 45, 60, 90, 120, 180, 240, 300, -1}

-- Snooze duration choices (minutes) offered in the card dropdown and menubar
local SNOOZE_PRESETS = {5, 10, 15, 20, 30}

-- ═══ State (kept in _G so Hammerspoon reloads don't leak taps/timers) ═══
local function resetTypingProgress()
  _G.dictationNudgeUsedSeconds = 0
  _G.dictationNudgeLastKeyAt = nil
  _G.dictationNudgeTier1At = nil
end

-- Shared by the real trigger and the ring. Compute from timestamps, so refill
-- needs no background timer and works identically with the card closed.
-- Usage is charged ONLY by onKeyDown for intervals ending in a counted key.
-- This read-only projection can hold or refill usage; it must never add usage
-- after the last key, regardless of whether a card/display timer is running.
local function typingUsedSeconds(ts)
  local lastKey = _G.dictationNudgeLastKeyAt
  local threshold = config.nudgeAfterSeconds
  if not lastKey or threshold <= 0 then return 0 end
  local elapsed = math.max(0, ts - lastKey)
  local used = math.min(threshold, _G.dictationNudgeUsedSeconds or 0)
  return math.max(0, used - math.max(0, elapsed - config.refillDelaySeconds) * config.refillPerSecond)
end

local function clearState()
  resetTypingProgress()
  _G.dictationNudgeLastNudgeAt   = 0
  _G.dictationNudgeLockdownUntil = nil
  _G.dictationNudgeSnoozeUntil   = nil
  _G.dictationNudgeDisabled      = false
  _G.dictationNudgeCanvases      = _G.dictationNudgeCanvases or {}
  _G.dictationNudgeLockTimers    = _G.dictationNudgeLockTimers or {}
end

local function now()
  return hs.timer.secondsSinceEpoch()
end

local function snoozeRemaining()
  if not _G.dictationNudgeSnoozeUntil then return nil end
  local rem = _G.dictationNudgeSnoozeUntil - now()
  if rem <= 0 then
    _G.dictationNudgeSnoozeUntil = nil -- lazy expiry
    return nil
  end
  return rem
end

local function fmtMinutes(m)
  m = math.floor(m + 0.5)
  if m < 60 then return m .. "m" end
  local h = math.floor(m / 60)
  local r = m % 60
  if r == 0 then return h .. "h" end
  return h .. "h " .. r .. "m"
end

local function fmtThreshold(v)
  if not v or v < 0 then return "Never" end
  v = math.floor(v + 0.5) -- hs.settings round-trips numbers as floats ("30.0s")
  if v < 60 then return v .. "s" end
  local m = math.floor(v / 60)
  local s = v % 60
  if s == 0 then return m .. "m" end
  return m .. "m " .. s .. "s"
end

-- ═══ Snooze gate: everyday money math ═══
-- Pure and deterministic given `pick`. No Hammerspoon calls in here, so the
-- whole bank runs under plain `lua` in the tests.
--
-- Every template takes pick(list) -> one element, and returns
--   question (string), answer (whole number), hint (string shown after a miss).
-- `tip` is the mental-math shortcut for that kind of problem, shown when the
-- Tip button is pressed. A hint uses the problem's numbers. A tip is fixed for
-- its template: it may name common rates and rule constants, never an answer.
-- Parameter lists are chosen so every answer is a whole number you can reach
-- in your head. If you add a template, keep that property: the tests draw
-- every template thousands of times and fail on a fractional answer.

local MoneyMath = {}

-- 1200 -> "$1,200"
local function money(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return "$" .. out:gsub("^,", "")
end
MoneyMath.money = money

local TEMPLATES = {
  { name = "tip",
    tip = "10% = move the decimal one place left. 5% = half of that. 15% = 10% + 5%. 20% = 10% doubled.",
    make = function(pick)
      local bill, pct = pick({20, 40, 60, 80, 120, 140, 160}), pick({10, 15, 20})
      return string.format("%d%% tip on a %s bill. Tip in dollars?", pct, money(bill)),
        bill * pct / 100,
        pct == 10 and "10% is the bill with the decimal point moved one place left."
          or string.format("10%% of %s is %s. Build %d%% from that.", money(bill), money(bill / 10), pct)
    end },

  { name = "discount",
    tip = "Flip it: 25% off means you pay 75%. Or build the discount from 10% chunks and subtract.",
    make = function(pick)
      local price, off = pick({40, 60, 80, 120, 160, 200}), pick({10, 20, 25, 30, 50})
      return string.format("%s jacket, %d%% off. Sale price?", money(price), off),
        price - price * off / 100,
        string.format("Work out %d%% of %s first, then subtract it.", off, money(price))
    end },

  { name = "sales_tax",
    tip = "10% = move the decimal one place left. 5% = half of that. Add it to the price.",
    make = function(pick)
      local price, tax = pick({20, 40, 60, 80, 120, 200}), pick({5, 10})
      return string.format("%s item plus %d%% sales tax. Total?", money(price), tax),
        price + price * tax / 100,
        string.format("%d%% of %s is %s. Add it on.", tax, money(price), money(price * tax / 100))
    end },

  { name = "percent_change",
    tip = "Divide the size of the change by the starting price. Simplify the fraction, then turn it into a percent.",
    make = function(pick)
      local old, pct, up = pick({40, 60, 80, 200}), pick({10, 20, 25, 50}), pick({true, false})
      local change = old * pct / 100
      local new = up and old + change or old - change
      return string.format("A stock goes from %s to %s. Percent %s?", money(old), money(new), up and "gain" or "drop"),
        pct,
        string.format("Change divided by the starting price: %s / %s.", money(change), money(old))
    end },

  { name = "rule_of_72",
    tip = "Years to double ≈ 72 ÷ the rate in percent. Backward: rate in percent ≈ 72 ÷ years.",
    make = function(pick)
      local rate = pick({2, 3, 4, 6, 8, 9, 12})
      if pick({true, false}) then
        return string.format("Rule of 72: at %d%% a year, about how many years for money to double?", rate),
          72 / rate, string.format("72 / %d.", rate)
      end
      return string.format("Rule of 72: you want to double your money in %d years. Yearly return needed, in percent?", 72 / rate),
        rate, string.format("72 / %d.", 72 / rate)
    end },

  { name = "card_interest",
    tip = "Monthly rate = APR ÷ 12. 1% of the balance = drop two zeros. Scale from there.",
    make = function(pick)
      local balance, apr = pick({1000, 2000, 3000, 4000, 5000, 6000}), pick({12, 18, 24, 30})
      return string.format("%s card balance at %d%% APR. Roughly how much interest this month?", money(balance), apr),
        balance * apr / 1200,
        string.format("%d%% a year is %s%% a month. Take that share of %s.", apr, tostring(apr / 12):gsub("%.0$", ""), money(balance))
    end },

  { name = "subscription_year",
    tip = "× 12 is × 10, plus × 2.",
    make = function(pick)
      local monthly = pick({5, 8, 10, 12, 15, 20, 25, 30, 40, 50})
      return string.format("A %s a month subscription. Cost per year?", money(monthly)),
        monthly * 12,
        string.format("%s x 12 = %s x 10, plus %s x 2.", money(monthly), money(monthly), money(monthly))
    end },

  { name = "daily_habit",
    tip = "Count the days first: days a week × 50. Multiplying by 50 is × 100, halved.",
    make = function(pick)
      local cost, days = pick({4, 5, 6, 8, 10}), pick({3, 5})
      return string.format("%s coffee, %d days a week, 50 weeks a year. Yearly cost?", money(cost), days),
        cost * days * 50,
        string.format("%d days x 50 weeks = %d days. Then x %s.", days, days * 50, money(cost))
    end },

  { name = "hourly_salary",
    tip = "Full time is about 2,000 hours. To a salary: double, add three zeros. To hourly: drop three zeros, halve.",
    make = function(pick)
      if pick({true, false}) then
        local rate = pick({20, 25, 30, 35, 40, 50, 60, 75})
        return string.format("%s an hour, full time (2,000 hours a year). Annual pay?", money(rate)),
          rate * 2000, "Double the hourly rate, then add three zeros."
      end
      local salary = pick({50000, 60000, 80000, 90000, 100000, 120000, 150000})
      return string.format("%s salary, 2,000 work hours a year. Hourly rate in dollars?", money(salary)),
        salary / 2000, "Drop three zeros, then halve."
    end },

  { name = "savings_rate",
    tip = "Saved ÷ take-home. Count the tenths of take-home you saved, half tenths included, then multiply by ten.",
    make = function(pick)
      local income, pct = pick({4000, 5000, 6000, 8000}), pick({5, 10, 15, 20, 25})
      local saved = income * pct / 100
      return string.format("You take home %s a month and save %s. Savings rate, in percent?", money(income), money(saved)),
        pct,
        string.format("Savings divided by take-home pay: %s / %s.", money(saved), money(income))
    end },

  { name = "split_with_tip",
    tip = "A 20% tip adds a fifth: take 10% and double it. To split four ways, halve twice.",
    make = function(pick)
      local people, share = pick({2, 3, 4, 5}), pick({12, 18, 24, 30, 36})
      local bill = people * share / 1.2 -- shares are multiples of 6, so this stays whole
      bill = math.floor(bill + 0.5)
      return string.format("%s dinner plus a 20%% tip, split %d ways. What does each person pay?", money(bill), people),
        share,
        string.format("Tip first: %s + %s = %s. Then divide by %d.", money(bill), money(bill / 5), money(bill * 1.2), people)
    end },

  { name = "four_percent_rule",
    tip = "Nest egg = 25 × yearly spending: × 100, then ÷ 4. Backward: 4% is 1%, four times.",
    make = function(pick)
      local spend = pick({30000, 40000, 50000, 60000, 80000, 100000})
      if pick({true, false}) then
        return string.format("You spend %s a year. Nest egg needed under the 4%% rule (25 x yearly spending)?", money(spend)),
          spend * 25, "Multiply by 100, then divide by 4."
      end
      return string.format("A %s portfolio at a 4%% withdrawal rate. How many dollars a year?", money(spend * 25)),
        spend, "1% is the portfolio with two zeros dropped. Take four of those."
    end },

  { name = "employer_match",
    tip = "1% of a salary = drop two zeros. Multiply by the match percent.",
    make = function(pick)
      local salary, match = pick({50000, 60000, 80000, 100000, 120000}), pick({3, 4, 5, 6})
      return string.format("Your employer matches 401(k) contributions dollar for dollar, up to %d%% of your %s salary. Most free money per year?", match, money(salary)),
        salary * match / 100,
        string.format("1%% of %s is %s. Times %d.", money(salary), money(salary / 100), match)
    end },

  { name = "compound_two_years",
    tip = "One year at a time: add the percent, then add the same percent of the new total. Year two gains more.",
    make = function(pick)
      local principal, rate = pick({1000, 2000, 5000, 10000}), pick({10, 20})
      local year1 = principal + principal * rate / 100
      return string.format("Invest %s at %d%% a year, compounded once a year. Value after 2 years?", money(principal), rate),
        year1 + year1 * rate / 100,
        string.format("Year 1 ends at %s. Year 2 grows that, not the original %s.", money(year1), money(principal))
    end },

  { name = "profit_margin",
    tip = "Margin = profit ÷ sale price. Markup = profit ÷ cost. Same profit, different base.",
    make = function(pick)
      local sale, margin = pick({60, 80, 120, 200}), pick({10, 20, 25, 40, 50})
      local cost = sale - sale * margin / 100
      return string.format("Buy for %s, sell for %s. Profit margin, as a percent of the sale price?", money(cost), money(sale)),
        margin,
        string.format("Profit / sale price: %s / %s. (Markup would divide by cost instead.)", money(sale - cost), money(sale))
    end },

  { name = "runway",
    tip = "Savings ÷ monthly spend. Cancel the matching zeros first.",
    make = function(pick)
      local spend, months = pick({2000, 3000, 4000, 5000}), pick({3, 6, 8, 12})
      return string.format("You have %s saved and spend %s a month. Months of runway?", money(spend * months), money(spend)),
        months,
        string.format("%s / %s. Drop the zeros first.", money(spend * months), money(spend))
    end },

  { name = "payback",
    tip = "Cost ÷ monthly saving = months to break even.",
    make = function(pick)
      local saving, months = pick({10, 20, 25, 50}), pick({4, 6, 8, 12, 18})
      return string.format("A %s purchase saves you %s a month. Months until it pays for itself?", money(saving * months), money(saving)),
        months,
        string.format("%s / %s.", money(saving * months), money(saving))
    end },

  { name = "fee_drag",
    tip = "1% = move the decimal two places left. Multiply by the fee percent. The fee repeats every year.",
    make = function(pick)
      local balance, fee = pick({50000, 100000, 200000, 400000}), pick({1, 2})
      return string.format("A fund charges a %d%% fee each year. On a %s balance, how many dollars a year?", fee, money(balance)),
        balance * fee / 100,
        fee == 1 and "1% is the balance with two zeros dropped."
          or string.format("1%% of %s is %s. Double it.", money(balance), money(balance / 100))
    end },

  { name = "drawdown_recovery",
    tip = "Gain needed = loss ÷ what is left. The deeper the fall, the bigger the climb back.",
    make = function(pick)
      local drop = pick({20, 50, 60, 75, 80})
      return string.format("A stock falls %d%%. What percent gain gets it back to even?", drop),
        drop * 100 / (100 - drop),
        string.format("You have %d%% left. Winning back the %d%% you lost is a gain on that smaller base.", 100 - drop, drop)
    end },

  { name = "real_return",
    tip = "Real return ≈ return − inflation. It measures what your money can buy.",
    make = function(pick)
      local nominal, inflation = pick({5, 6, 7, 8, 10}), pick({2, 3, 4})
      return string.format("Your portfolio returns %d%% in a year with %d%% inflation. Roughly what real return, in percent?", nominal, inflation),
        nominal - inflation, "Subtract inflation from the return."
    end },

  { name = "tax_set_aside",
    tip = "30% = 10%, three times. 25% = a quarter: halve it twice.",
    make = function(pick)
      local invoice, pct = pick({1000, 2000, 4000, 5000, 8000}), pick({25, 30})
      return string.format("You invoice %s as a contractor and set aside %d%% for taxes. Dollars set aside?", money(invoice), pct),
        invoice * pct / 100,
        pct == 25 and string.format("A quarter of %s.", money(invoice))
          or string.format("10%% of %s is %s. Times 3.", money(invoice), money(invoice / 10))
    end },

  { name = "raise_after_tax",
    tip = "You keep 100% − the tax rate. Build the tax from 10% and 1% chunks, then subtract.",
    make = function(pick)
      local raise, rate = pick({5000, 10000, 20000}), pick({22, 24, 32})
      return string.format("A %s raise, taxed at a %d%% marginal rate. Extra take-home per year?", money(raise), rate),
        raise - raise * rate / 100,
        string.format("Tax is %d%% of %s = %s. Subtract it.", rate, money(raise), money(raise * rate / 100))
    end },

  { name = "down_payment",
    tip = "10% = drop a zero. 20% = double that. 5% = half of it.",
    make = function(pick)
      local price, pct = pick({200000, 300000, 400000, 500000}), pick({5, 10, 20})
      return string.format("%d%% down on a %s home. Down payment in dollars?", pct, money(price)),
        price * pct / 100,
        pct == 10 and "10% is the price with one zero dropped."
          or string.format("10%% of %s is %s. Scale from there.", money(price), money(price / 10))
    end },
}
MoneyMath.TEMPLATES = TEMPLATES

-- Build `count` problems. `rand(n)` returns a whole number 1..n (math.random
-- has this shape). Templates are not repeated until the bank runs out.
function MoneyMath.newChallenge(count, rand)
  rand = rand or math.random
  local function pick(list) return list[rand(#list)] end
  local order, problems = {}, {}
  for i = 1, #TEMPLATES do order[i] = i end
  for i = #order, 2, -1 do -- Fisher-Yates
    local j = rand(i)
    order[i], order[j] = order[j], order[i]
  end
  for i = 1, count do
    local template = TEMPLATES[order[(i - 1) % #order + 1]]
    local question, answer, hint = template.make(pick)
    problems[i] = { kind = template.name, question = question, answer = answer, hint = hint, tip = template.tip }
  end
  return problems
end

-- Reads "9", "$1,200", "15%", " 1210.00 " as sign, whole digits, fraction
-- digits. One optional "$" in front, one optional "%" behind, commas only as
-- thousands separators. Returns nil when the text is not exactly one number.
local function numberParts(text)
  if type(text) ~= "string" then return nil end
  local sign, whole, fraction = text:match("^%s*(%-?)%$?%s*([%d,]*)%.?(%d*)%s*%%?%s*$")
  if not whole or (whole == "" and fraction == "") then return nil end
  if whole:find(",", 1, true) then
    local head, groups = whole:match("^(%d%d?%d?)(.*)$")
    if not head or groups == "" or groups:gsub(",%d%d%d", "") ~= "" then return nil end
  end
  return sign, (whole:gsub(",", "")), fraction
end

function MoneyMath.parseAnswer(text)
  local sign, whole, fraction = numberParts(text)
  if not sign then return nil end
  return tonumber(sign .. (whole == "" and "0" or whole) .. (fraction ~= "" and ("." .. fraction) or ""))
end

-- Exact: the digits typed must be the answer's digits. Trailing ".00" is fine;
-- 24.999999999999999 is not 25, however a float would round it.
function MoneyMath.isCorrect(problem, text)
  local sign, whole, fraction = numberParts(text)
  if not sign or sign == "-" or fraction:find("[^0]") then return false end
  return (whole:gsub("^0+", "")) == string.format("%d", problem.answer)
end

-- ═══ Dictation trigger ═══
local function startDictation()
  if config.dictationURL then
    hs.urlevent.openURL(config.dictationURL)
    log.i("Requested to open the dictation URL")
  else
    hs.application.open(config.dictationName)
  end
end

-- "Ctrl+Option" style label for the reset chord, or nil when it is off.
local MODIFIER_LABELS = { {"ctrl", "Ctrl"}, {"alt", "Option"}, {"shift", "Shift"}, {"cmd", "Cmd"}, {"fn", "Fn"} }
local resetWanted -- set of modifier names, built in start(); nil = no reset chord
local function resetChordLabel()
  if not resetWanted then return nil end
  local parts = {}
  for _, pair in ipairs(MODIFIER_LABELS) do
    if resetWanted[pair[1]] then table.insert(parts, pair[2]) end
  end
  return table.concat(parts, "+")
end

local function htmlEscape(text)
  return (tostring(text):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }))
end

-- ═══ Lockdown overlay (tier 2) ═══
local function clearLockTimers()
  for _, timer in ipairs(_G.dictationNudgeLockTimers) do
    timer:stop()
  end
  _G.dictationNudgeLockTimers = {}
end

local function destroyCanvases()
  for _, canvas in ipairs(_G.dictationNudgeCanvases) do
    canvas:delete()
  end
  _G.dictationNudgeCanvases = {}
end

local function endLockdown()
  if not _G.dictationNudgeLockdownUntil and #_G.dictationNudgeCanvases == 0 then return end
  _G.dictationNudgeLockdownUntil = nil
  clearLockTimers()
  destroyCanvases()
  log.i("Lockdown ended")
end

local function updateCountdownText()
  local remaining = math.max(0, math.ceil((_G.dictationNudgeLockdownUntil or now()) - now()))
  for _, canvas in ipairs(_G.dictationNudgeCanvases) do
    canvas[3].text = "Keyboard back in " .. remaining .. "s  ·  Esc to override"
  end
end

local function startLockdown()
  if _G.dictationNudgeLockdownUntil and _G.dictationNudgeLockdownUntil > now() then return end -- already locked
  endLockdown() -- clear anything left from an expired one

  _G.dictationNudgeLockdownUntil = now() + config.lockdownSeconds
  -- Schedule the release before drawing anything: if the overlay fails, the
  -- keyboard still comes back. onKeyDown checks the deadline as well.
  table.insert(_G.dictationNudgeLockTimers, hs.timer.doAfter(config.lockdownSeconds, endLockdown))
  log.i(string.format("Lockdown engaged for %gs", config.lockdownSeconds))

  for _, screen in ipairs(hs.screen.allScreens()) do
    local canvas = hs.canvas.new(screen:fullFrame())
    canvas:appendElements({
      {
        type = "rectangle",
        action = "fill",
        fillColor = { red = 0.05, green = 0.05, blue = 0.07, alpha = 0.94 },
      },
      {
        type = "text",
        frame = { x = "10%", y = "38%", w = "80%", h = "12%" },
        text = "🎙️  Use " .. config.dictationName,
        textSize = 64,
        textColor = { white = 1 },
        textAlignment = "center",
      },
      {
        type = "text",
        frame = { x = "10%", y = "52%", w = "80%", h = "8%" },
        text = "",
        textSize = 24,
        textColor = { white = 0.75 },
        textAlignment = "center",
      },
    })
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:clickActivating(false)
    canvas:bringToFront(true) -- above dock/menubar; fullscreen *spaces* would need hs.dockicon.hide()
    canvas:show()
    table.insert(_G.dictationNudgeCanvases, canvas)
  end

  updateCountdownText()
  table.insert(_G.dictationNudgeLockTimers, hs.timer.doEvery(1, updateCountdownText))
end

-- ═══ Snooze ═══
-- Typed snooze lengths, minutes and hours only. Deterministic: a fixed
-- grammar, no guessing, no rounding. Returns whole minutes, or nil plus a
-- short reason the card can show.
--   90 | 45m | 90 mins | 2h | 1.5 hours | 1h30 | 1h 30m | 1 hr, 15 min
--   1 hour and 30 minutes | 1:30 | an hour | half an hour | an hour and a half
local SNOOZE_UNITS = {
  h = 60, hr = 60, hrs = 60, hour = 60, hours = 60,
  m = 1, min = 1, mins = 1, minute = 1, minutes = 1,
}
local SNOOZE_REFUSED_UNITS = {}
for _, word in ipairs({
  "s", "sec", "secs", "second", "seconds", "d", "day", "days", "w", "wk", "wks", "week", "weeks",
  "mo", "mos", "month", "months", "y", "yr", "yrs", "year", "years",
}) do SNOOZE_REFUSED_UNITS[word] = true end
local SNOOZE_HELP = "Try 45m, 1.5h, or 1h 30m."
local SNOOZE_UNITS_ONLY = "Minutes and hours only."
local SNOOZE_WHOLE = "Use a whole number of minutes."
local SNOOZE_RANGE = "Snooze can be 1 minute to 12 hours."

-- One number token at `scale` minutes per unit -> ten-thousandths of a
-- minute, exactly. Integer arithmetic only: no rounding, and short tokens so
-- nothing overflows.
local function minuteParts(number, scale)
  local whole, fraction = number:match("^(%d*)%.?(%d*)$")
  whole = whole:gsub("^0+", "")
  fraction = fraction:gsub("0+$", "")
  if #whole > 4 then return nil, SNOOZE_RANGE end
  if #fraction > 4 then return nil, SNOOZE_HELP end
  local digits = whole .. fraction
  return (digits == "" and 0 or tonumber(digits)) * scale * math.tointeger(10 ^ (4 - #fraction))
end

local function parseSnoozeLength(text)
  if type(text) ~= "string" then return nil, SNOOZE_HELP end
  local s = text:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if s == "" then return nil, SNOOZE_HELP end

  local total
  local clockHours, clockMinutes = s:match("^0*(%d%d?%d?):(%d%d)$") -- 1:30
  if clockHours then
    if tonumber(clockMinutes) >= 60 then return nil, SNOOZE_HELP end
    total = (tonumber(clockHours) * 60 + tonumber(clockMinutes)) * 10000
  else
    if s == "half an hour" or s == "half a hour" or s == "half hour" or s == "a half hour" then s = "30m" end
    s = s:gsub("(%d) and a half ", "%1.5 ")      -- "2 and a half hours"
    local plusHalf = false
    local head = s:match("^(.-) and a half$")      -- "an hour and a half"
    if head then s, plusHalf = head, true end
    -- "and" and "," are read only between the hours and the minutes
    -- ("1 hour and 30 minutes", "1 hr, 15 min"); anywhere else they refuse.
    s = s:gsub("(%a) and ([%d%.])", "%1 %2"):gsub("(%a), ?([%d%.])", "%1 %2"):gsub("^an? ", "1 ")
    if s:find(",", 1, true) then return nil, SNOOZE_HELP end

    -- One hours term, then one minutes term, each optional, in that order.
    local rest, sawHours, sawMinutes = s, false, false
    total = 0
    while rest ~= "" do
      local number, after = rest:match("^(%d+%.?%d*)%s*(.*)$")
      if not number then number, after = rest:match("^(%.%d+)%s*(.*)$") end
      if not number then
        local word = rest:match("^(%a+)")
        return nil, (word and SNOOZE_REFUSED_UNITS[word]) and SNOOZE_UNITS_ONLY or SNOOZE_HELP
      end
      local word, tail = after:match("^(%a+)%s*(.*)$")
      local scale = 1
      if word then
        scale = SNOOZE_UNITS[word]
        if not scale then return nil, SNOOZE_REFUSED_UNITS[word] and SNOOZE_UNITS_ONLY or SNOOZE_HELP end
        if sawMinutes or (scale == 60 and sawHours) then return nil, SNOOZE_HELP end
        rest = tail
      else
        -- A bare number is minutes: either the whole input, or what follows the hours ("1h30").
        if after ~= "" or sawMinutes then return nil, SNOOZE_HELP end
        rest = ""
      end
      if scale == 60 then sawHours = true else sawMinutes = true end
      local parts, reason = minuteParts(number, scale)
      if not parts then return nil, reason end
      total = total + parts
    end
    if plusHalf then
      if not sawHours or sawMinutes then return nil, SNOOZE_HELP end
      total = total + 30 * 10000
    end
  end

  -- `total` is in ten-thousandths of a minute; only an exact whole number of minutes passes.
  if total % 10000 ~= 0 then return nil, SNOOZE_WHOLE end
  local minutes = total // 10000
  if minutes < 1 or minutes > SNOOZE_MAX_MINUTES then return nil, SNOOZE_RANGE end
  return minutes
end

local updateMenubar -- forward declarations (mutual references)
local openPanel
local closePanel
local toggleDisabled
local requestGated

local lastSnoozeToggleAt = 0

-- Snooze gate state: nil, or the challenge in progress
-- { action = {kind=, minutes=}, problems = {...}, index = n, misses = n }.
-- It lives and dies with the card: closePanel() clears it.
local gate
local gateSerial = 0
local panelReady = false -- the open card's page has finished loading

-- 0 = gate off. start() validates the option and the card can only set 0..10.
local function snoozeMathCount()
  return config.snoozeMathProblems or 0
end

local function cancelSnooze()
  _G.dictationNudgeSnoozeUntil = nil
  log.i("Snooze cancelled")
  hs.alert.show("🎙️ Dictation nudge resumed", 1.5)
  updateMenubar()
end

-- Starting a snooze remembers the duration: it becomes the main
-- snooze button's default (persisted via hs.settings).
local function startSnooze(minutes)
  minutes = math.floor(minutes)
  config.snoozeMinutes = minutes
  hs.settings.set(config.snoozeSettingsKey, minutes)
  _G.dictationNudgeSnoozeUntil = now() + minutes * 60
  endLockdown()
  -- fresh runway: post-snooze typing starts a new streak
  resetTypingProgress()
  log.i("Snoozed for " .. fmtMinutes(minutes))
  hs.alert.show("🎙️💤 Nudge snoozed " .. fmtMinutes(minutes), 2)
  updateMenubar()
end

local function toggleSnooze()
  local ts = now()
  if ts - lastSnoozeToggleAt < 1 then return end -- debounce double-fire
  lastSnoozeToggleAt = ts

  if snoozeRemaining() then
    cancelSnooze()
  elseif snoozeMathCount() == 0 then
    startSnooze(config.snoozeMinutes)
  else
    requestGated({ kind = "snooze", minutes = config.snoozeMinutes })
  end
end

local function promptCustomSnooze()
  hs.focus() -- dialog only takes keystrokes with Hammerspoon frontmost
  local button, text = hs.dialog.textPrompt(
    "Custom snooze",
    string.format("Snooze the dictation nudge for how many minutes? (1-%d)", SNOOZE_MAX_MINUTES),
    tostring(config.snoozeMinutes), "Snooze", "Cancel")
  if button ~= "Snooze" then return end
  local minutes = tonumber(text)
  if minutes and minutes >= 1 and minutes <= SNOOZE_MAX_MINUTES then
    startSnooze(minutes)
  else
    hs.alert.show(string.format("Snooze needs 1-%d minutes", SNOOZE_MAX_MINUTES), 2)
  end
end

local function snoozeSubmenu()
  local sub = {}
  for _, m in ipairs(SNOOZE_PRESETS) do
    table.insert(sub, {
      title = m .. " minutes",
      checked = (m == config.snoozeMinutes),
      fn = function() startSnooze(m) end,
    })
  end
  table.insert(sub, { title = "-" })
  table.insert(sub, { title = "Custom…", fn = promptCustomSnooze })
  return sub
end

-- ═══ Disable (session-only; "Never" on the slider is the persisted one) ═══
toggleDisabled = function()
  _G.dictationNudgeDisabled = not _G.dictationNudgeDisabled
  if _G.dictationNudgeDisabled then
    endLockdown()
    closePanel()
    resetTypingProgress()
    log.i("Disabled")
    hs.alert.show("🎙️ Dictation nudge disabled", 1.5)
  else
    log.i("Enabled")
    hs.alert.show("🎙️ Dictation nudge enabled", 1.5)
  end
  updateMenubar()
end

-- ═══ Snooze gate (optional) ═══
-- With snoozeMathProblems > 0, the card's Snooze and Disable buttons and the
-- snooze URL event first show that many money-math problems. Lua owns the
-- problems and checks the answers; the card only renders what it is sent.
local function setSnoozeMathCount(value)
  if gate then return end -- not while a challenge is showing
  if type(value) ~= "number" or value ~= math.floor(value)
    or value < 0 or value > SNOOZE_MATH_MAX then return end
  config.snoozeMathProblems = math.floor(value)
  hs.settings.set(config.snoozeMathSettingsKey, config.snoozeMathProblems)
  log.i("Snooze math: " .. (value == 0 and "off" or (config.snoozeMathProblems .. " problem(s)")))
end

local rebuildGateAnswerKeycodes -- defined with the keystroke handler

local function newGate(action)
  gateSerial = gateSerial + 1
  rebuildGateAnswerKeycodes() -- the keyboard layout may have changed since the last challenge
  return { id = gateSerial, action = action, problems = MoneyMath.newChallenge(snoozeMathCount()), index = 1, misses = 0 }
end

-- What the card shows for the current problem (nil = no challenge).
local function gateView(feedback, wrong)
  if not gate then return nil end
  local total = #gate.problems
  local goal = gate.action.kind == "snooze"
    and ("snooze " .. fmtMinutes(gate.action.minutes)) or "disable the nudge"
  return {
    title = string.format("Solve %d to %s", total, goal),
    id = gate.id, index = gate.index, total = total,
    question = gate.problems[gate.index].question,
    tip = gate.problems[gate.index].tip,
    feedback = feedback or "", wrong = wrong == true,
  }
end

-- Run one statement in the open card, once its page has loaded. `onFailure`
-- runs if the card does not acknowledge it (success is an explicit `true`;
-- this Hammerspoon build hands the callback an error table either way).
local function pushCard(script, onFailure)
  local panel = _G.dictationNudgePanel
  if not panel or not panelReady then return end
  local sent = pcall(function()
    panel:evaluateJavaScript(script .. "; true", function(result)
      if result ~= true and onFailure and _G.dictationNudgePanel == panel then onFailure() end
    end)
  end)
  if not sent and onFailure then onFailure() end
end

-- A challenge the card cannot show (its web content died, say) must not stay
-- alive in here: close the card, which drops the challenge with it. A late
-- failure for an earlier challenge must not close the one showing now.
local function pushGate(feedback, wrong)
  local view = gateView(feedback, wrong)
  pushCard("showGate(" .. (view and hs.json.encode(view) or "null") .. ")",
    view and function() if gate and gate.id == view.id then closePanel() end end or nil)
end

local function runAction(action)
  if action.kind == "snooze" then
    startSnooze(action.minutes)
  elseif not _G.dictationNudgeDisabled then
    toggleDisabled()
  end
  closePanel()
end

requestGated = function(action)
  if snoozeMathCount() == 0 then runAction(action); return end
  if gate then            -- already mid-challenge: keep the problems, retarget
    gate.action = action
    pushGate()
  elseif _G.dictationNudgePanel then
    gate = newGate(action)
    pushGate()
  else
    openPanel("settings", action) -- the card opens straight into the challenge
  end
end

-- `id` and `index` say which challenge and problem the card was showing when
-- the answer was sent. A second click on Check, or a message from a card that
-- has since been replaced, names an old one and is dropped.
local function answerGate(id, index, text)
  if not gate or id ~= gate.id or index ~= gate.index then return end
  local problem = gate.problems[gate.index]
  if MoneyMath.parseAnswer(text) == nil then
    pushGate("Type a number, like 45 or 1,200.", true)
  elseif not MoneyMath.isCorrect(problem, text) then
    gate.misses = gate.misses + 1
    pushGate("Not quite. " .. problem.hint, true)
  elseif gate.index >= #gate.problems then
    local action = gate.action
    gate = nil
    runAction(action)
  else
    gate.index = gate.index + 1
    pushGate("Correct. Next one.")
  end
end

local function cancelGate(id)
  if not gate or id ~= gate.id then return end
  gate = nil
  pushGate() -- hides the challenge; the card stays open
end

-- ═══ Menubar ═══
-- Native text only: no image generation, WebKit, subprocess, or per-key redraw.
-- Reuse one timer; sleep entirely when full/off, and poll snooze only every 30s.
local menuSignature
updateMenubar = function()
  local menu = _G.dictationNudgeMenu
  if not menu then return end
  local ts = now()
  local threshold = config.nudgeAfterSeconds
  local rem = snoozeRemaining()
  local title, color, signature, nextRefresh
  if _G.dictationNudgeDisabled or threshold < 0 then
    title, color = "🎙 off", { white = 0.6 }
  elseif rem then
    title, color = "🎙 zZ " .. math.ceil(rem / 60) .. "m", { white = 0.6 }
    nextRefresh = math.min(30, rem)
  else
    local used = typingUsedSeconds(ts)
    local locked = _G.dictationNudgeLockdownUntil and _G.dictationNudgeLockdownUntil > ts
    local seconds = locked and 0 or math.ceil(math.max(0, threshold - used))
    title = "🎙 " .. seconds .. "s"
    -- Same HSL gradient as the ring (hue 0 to 110 degrees, saturation 65%, lightness 55%),
    -- expressed as native HSV. Quantize with the displayed whole seconds.
    color = { hue = (110 / 360) * math.min(1, seconds / threshold),
      saturation = 0.585 / 0.8425, brightness = 0.8425 }
    if used > 0 or locked then nextRefresh = 0.5 end
  end
  signature = title .. ":" .. tostring(color.hue)
  if signature ~= menuSignature then
    menu:setTitle(hs.styledtext.new(title, { color = color }))
    menuSignature = signature
  end
  local timer = _G.dictationNudgeMenuTimer
  if timer then
    if nextRefresh then timer:setNextTrigger(nextRefresh) else timer:stop() end
  end
end

local function startMenubar()
  if _G.dictationNudgeMenuTimer then
    _G.dictationNudgeMenuTimer:stop()
    _G.dictationNudgeMenuTimer = nil
  end
  if _G.dictationNudgeMenu then
    _G.dictationNudgeMenu:delete()
    _G.dictationNudgeMenu = nil
  end
  menuSignature = nil
  if not config.menubarEnabled then return end
  _G.dictationNudgeMenu = hs.menubar.new(true, config.menubarAutosaveName)
  if not _G.dictationNudgeMenu then return end
  _G.dictationNudgeMenu:setTooltip("Dictation Nudge · remaining typing allowance · click to open")
  -- An attached dropdown suppresses click callbacks, so controls live in the card.
  _G.dictationNudgeMenu:setMenu(nil)
  _G.dictationNudgeMenu:setClickCallback(function() openPanel("settings") end)
  _G.dictationNudgeMenuTimer = hs.timer.new(0.5, updateMenubar)
  updateMenubar()
end

-- ═══ Unified nudge/settings card (hs.webview) ═══
-- One card, two modes:
--   "nudge"    : tier-1 popup: dictation CTA + slider + snooze + Keep typing
--   "settings" : same card without the CTA (from menubar/app/URL)
-- Esc closes it via a global watch in onKeyDown (no focus required).

-- Read-only projection of the same refillable budget used by the real trigger.
local function panelRingState(ts)
  local threshold = config.nudgeAfterSeconds
  local function state(fraction, label, muted, remaining)
    return { fraction = math.floor(math.max(0, math.min(1, fraction)) * 200 + 0.5) / 200,
      label = label, muted = muted or false,
      remaining = remaining or math.max(0, threshold) * fraction }
  end
  if _G.dictationNudgeDisabled then return state(1, "Disabled", true) end
  if threshold < 0 then return state(1, "Nudges off", true) end
  if _G.dictationNudgeSnoozeUntil and _G.dictationNudgeSnoozeUntil > ts then
    local snoozed = state(1, "Snoozed · " .. fmtThreshold(math.ceil(_G.dictationNudgeSnoozeUntil - ts)), true)
    snoozed.snoozed = true -- card shows the ✕ (end snooze) next to the status line
    return snoozed
  end
  if _G.dictationNudgeLockdownUntil and _G.dictationNudgeLockdownUntil > ts then
    return state(0, "Keyboard blocked · " .. math.ceil(_G.dictationNudgeLockdownUntil - ts) .. "s · Esc to exit")
  end
  local used = typingUsedSeconds(ts)
  local remaining = math.max(0, threshold - used)
  local active = _G.dictationNudgeLastKeyAt
    and ts - _G.dictationNudgeLastKeyAt <= config.refillDelaySeconds
  if active and _G.dictationNudgeTier1At then
    if config.lockdownEnabled then
      local remaining = config.escalateAfterSeconds - (ts - _G.dictationNudgeTier1At)
      return state((threshold - used) / threshold, remaining > 0 and ("Nudged · " .. math.ceil(remaining) .. "s to block if typing continues")
        or "Nudged · next typing key blocks", false, threshold - used)
    end
    return state(remaining / threshold, "Nudge reached", false, remaining)
  end
  local cooldown = config.cooldownSeconds - (ts - (_G.dictationNudgeLastNudgeAt or 0))
  if cooldown > 0 then
    return state(remaining / threshold, (not active and used > 0 and "Refilling · " or "")
      .. "Cooldown · " .. fmtThreshold(math.ceil(cooldown)), false, remaining)
  end
  if not active then
    return state(remaining / threshold, used > 0
      and ("Refilling · " .. fmtThreshold(math.floor(remaining)) .. " available") or "Ready")
  end
  return state(remaining / threshold, remaining > 0 and (fmtThreshold(math.ceil(remaining)) .. " to nudge") or "Nudge due")
end

local function stopPanelRing()
  if _G.dictationNudgePanelTimer then
    _G.dictationNudgePanelTimer:stop()
    _G.dictationNudgePanelTimer = nil
  end
end

local function startPanelRing(panel)
  stopPanelRing()
  local lastState, inFlight
  local function update()
    if _G.dictationNudgePanel ~= panel or not _G.dictationNudgePanelVisible or inFlight then return end
    local state = panelRingState(now())
    local signature = state.fraction .. ":" .. math.ceil(state.remaining) .. ":" .. tostring(state.muted) .. ":" .. state.label
    -- Unchanged states are skipped, except while a snooze-gate problem is up:
    -- then the refresh doubles as a check that the page is still there.
    if signature == lastState and not gate then return end
    inFlight = true -- never queue multiple WebKit requests behind a slow render
    local ok = pcall(function()
      -- This Hammerspoon build supplies {code=0} even on success. Require an
      -- explicit JS acknowledgement instead of testing the error table's truthiness.
      panel:evaluateJavaScript("updateRing(" .. hs.json.encode(state) .. "); true", function(result, err)
        inFlight = false
        if _G.dictationNudgePanel ~= panel then return end
        if result == true then
          lastState = signature
        else
          log.w("Ring update failed: " .. tostring(err and (err.description or err.code) or "no acknowledgement"))
          stopPanelRing()
          if gate then closePanel() end -- nothing can show the problem any more
        end
      end)
    end)
    if not ok then
      inFlight = false
      stopPanelRing()
      if gate then closePanel() end
    end
  end
  _G.dictationNudgePanelTimer = hs.timer.doEvery(0.25, update)
  update()
end

local CARD_HTML = [[
<!doctype html><html><head><meta charset="utf-8"><style>
body { background:#16171d; color:#fff; font-family:-apple-system, sans-serif; margin:0; padding:20px 24px; user-select:none; }
h1 { font-size:17px; margin:0 0 3px; font-weight:650; }
.sub { color:#98a0ae; font-size:12px; line-height:1.45; margin-bottom:12px; }
#duration { text-align:center; margin:8px 0 2px; }
#durationdial { position:relative; height:128px; display:flex; align-items:center; justify-content:center; }
#durationdial svg { position:absolute; left:50%; top:0; transform:translateX(-50%); width:128px; height:128px; pointer-events:none; }
#durationtrack, #durationarc { fill:none; stroke-width:8; }
#durationtrack { stroke:#343842; }
#durationarc { stroke:#79cc52; stroke-linecap:round; }
#durationstatus { color:#98a0ae; font-size:11px; line-height:16px; min-height:16px; margin:2px 0 8px; }
/* ✕ hangs off the right edge of the status text so the text itself stays centered. */
#statuswrap { position:relative; display:inline-block; }
#unsnooze { position:absolute; left:100%; top:0; margin-left:5px; width:16px; height:16px; padding:0; border-radius:50%; background:#2a2d38; color:#98a0ae; font-size:9px; line-height:16px; text-align:center; }
#unsnooze:hover, #unsnooze:focus-visible { background:#5a3a3e; color:#fff; outline:none; }
#durationremaining { position:relative; max-width:104px; overflow:hidden; font-size:26px; font-weight:700; font-variant-numeric:tabular-nums; white-space:nowrap; }
#durationlimit { display:flex; align-items:baseline; justify-content:center; gap:7px; margin:4px 0; color:#98a0ae; font-size:12px; }
#durationlimit #val { min-width:0; font-size:18px; }
#val { width:3.5ch; max-width:100%; box-sizing:border-box; font-family:inherit; font-size:30px; font-weight:700; text-align:center; color:#fff; background:transparent; border:0; border-bottom:2px dotted #78808e; border-radius:0; padding:0 2px 3px; user-select:text; }
#val:hover, #val:focus { border-color:#a9c3ff; }
#val:focus { outline:none; }
#val[aria-invalid=true] { color:#ffb4ad; border-color:#ffb4ad; }
#durationerror { color:#ffb4ad; font-size:11px; line-height:1.4; margin-top:4px; }
input[type=range] { width:100%; accent-color:#5b8cff; margin:6px 0 2px; }
.ticks { display:flex; justify-content:space-between; font-size:10px; color:#78808e; }
button { border:none; border-radius:8px; cursor:pointer; color:#fff; font-weight:600; }
.dictate { display:block; width:100%; padding:11px; font-size:16px; background:#2f6bff; margin:2px 0 12px; }
.dictate:hover { background:#3d78ff; }
.row { display:flex; gap:10px; margin-top:16px; }
.row > button, .split > button { padding:9px; font-size:14px; }
.split { position:relative; flex:1.3; display:flex; }
#snooze { flex:1; background:#2a2d38; border-radius:8px 0 0 8px; }
#snooze:hover { background:#363a48; }
#snoozemore { width:26px; background:#2a2d38; border-left:1px solid #16171d; border-radius:0 8px 8px 0; font-size:12px; color:#98a0ae; }
#snoozemore:hover { background:#363a48; color:#fff; }
#snoozemenu { position:absolute; bottom:calc(100% + 6px); left:0; width:240px; background:#232631; border:1px solid #3a3f4e; border-radius:10px; padding:6px; box-shadow:0 8px 24px rgba(0,0,0,.5); }
.chips { display:flex; gap:4px; margin-bottom:4px; }
.chips button { flex:1; padding:7px 0; font-size:13px; background:#2a2d38; border-radius:6px; }
.chips button:hover { background:#2f6bff; }
#customopt { display:block; width:100%; text-align:center; padding:7px 0; background:#2a2d38; font-weight:500; font-size:13px; border-radius:6px; }
#customopt:hover { background:#2f6bff; }
#customrow { display:flex; gap:6px; margin-top:4px; }
#custommin { flex:1; min-width:0; background:#16171d; border:1px solid #3a3f4e; border-radius:6px; color:#fff; font-family:inherit; padding:6px 8px; font-size:13px; user-select:text; }
#customgo { background:#2f6bff; padding:6px 12px; font-size:13px; }
.hidden { display:none !important; }
.row > #dismiss { flex:1; }
.row > #disable { flex:0.7; }
#dismiss { background:#2a2d38; }
#dismiss:hover { background:#363a48; }
#disable { background:#3a2a2d; flex:0.7; }
#disable:hover { background:#4a3538; }
.esc { text-align:center; color:#5c6470; font-size:10px; margin-top:12px; }
#customerror { color:#ffb4ad; font-size:11px; line-height:1.4; margin-top:5px; }
/* Gear in the corner opens the less-used settings. It tints when the snooze gate is on. */
#gear { position:absolute; top:14px; right:16px; width:28px; height:28px; padding:0; display:flex; align-items:center; justify-content:center; background:transparent; color:#98a0ae; border-radius:6px; }
#gear.on { color:#a9c3ff; }
#gear:hover, #gear[aria-expanded=true] { background:#2a2d38; color:#fff; }
#prefs { position:absolute; top:46px; right:16px; z-index:4; width:252px; box-sizing:border-box; background:#232631; border:1px solid #3a3f4e; border-radius:10px; padding:10px; box-shadow:0 8px 24px rgba(0,0,0,.5); }
#mathlabel { font-size:12px; font-weight:600; margin-bottom:6px; }
#mathchips { margin:0; }
#mathchips button { padding:6px 0; font-size:12px; font-weight:500; color:#c9ced8; }
#mathchips button[aria-checked=true] { background:#2f6bff; color:#fff; }
#prefs .prefhelp { color:#98a0ae; font-size:11px; line-height:1.4; margin-top:7px; }
/* The challenge covers the whole card, so nothing behind it can be clicked. */
#gate { position:fixed; top:0; left:0; right:0; bottom:0; z-index:5; box-sizing:border-box; background:#16171d; padding:24px 32px; display:flex; flex-direction:column; justify-content:center; text-align:center; }
#gatetitle { font-size:17px; font-weight:650; }
#gateprogress { color:#98a0ae; font-size:12px; margin:4px 0 22px; }
#gatequestion { font-size:19px; line-height:1.4; font-weight:500; min-height:54px; }
#gateentry { display:flex; gap:8px; justify-content:center; margin:18px 0 10px; }
#gateanswer { width:150px; box-sizing:border-box; background:#0f1014; border:1px solid #3a3f4e; border-radius:8px; color:#fff; font-family:inherit; font-size:20px; font-weight:600; font-variant-numeric:tabular-nums; text-align:center; padding:8px 10px; user-select:text; }
#gateanswer:focus { outline:none; border-color:#5b8cff; }
#gatecheck { background:#2f6bff; padding:8px 18px; font-size:15px; }
#gatecheck:hover { background:#3d78ff; }
#gatefeedback { min-height:36px; font-size:12px; line-height:1.5; color:#98a0ae; }
#gatefeedback.wrong { color:#ffb4ad; }
#gatefeedback.tip { color:#a9c3ff; }
#gatelinks { display:flex; justify-content:center; gap:8px; margin-top:8px; }
#gatelinks button { background:transparent; color:#98a0ae; font-weight:500; font-size:12px; padding:6px 10px; }
#gatelinks button:hover { color:#fff; background:#2a2d38; }
</style></head><body>
<button id="gear" title="Settings" aria-label="Settings" aria-haspopup="true" aria-expanded="false"><svg viewBox="0 0 20 20" width="18" height="18" fill="currentColor" fill-rule="evenodd" aria-hidden="true"><path d="M8.42 3.90L8.73 1.49L11.27 1.49L11.58 3.90L13.20 4.57L15.12 3.09L16.91 4.88L15.43 6.80L16.10 8.42L18.51 8.73L18.51 11.27L16.10 11.58L15.43 13.20L16.91 15.12L15.12 16.91L13.20 15.43L11.58 16.10L11.27 18.51L8.73 18.51L8.42 16.10L6.80 15.43L4.88 16.91L3.09 15.12L4.57 13.20L3.90 11.58L1.49 11.27L1.49 8.73L3.90 8.42L4.57 6.80L3.09 4.88L4.88 3.09L6.80 4.57ZM12.70 10.00A2.7 2.7 0 1 0 7.30 10.00A2.7 2.7 0 1 0 12.70 10.00Z"/></svg></button>
<div id="prefs" class="hidden" role="group" aria-labelledby="mathlabel">
<div id="mathlabel">Math to snooze</div>
<div class="chips" id="mathchips" role="radiogroup" aria-labelledby="mathlabel"></div>
<div class="prefhelp">Solve this many quick money-math problems before Snooze or Disable takes effect.</div>
</div>
<h1>__TITLE__</h1>
<div class="sub">__SUB__</div>
__CTA__
<div id="duration">
<div id="durationdial">
<svg viewBox="0 0 128 128" aria-hidden="true">
<circle id="durationtrack" cx="64" cy="64" r="54" />
<circle id="durationarc" cx="64" cy="64" r="54" transform="rotate(-90 64 64)" stroke-dasharray="339.292" stroke-dashoffset="0" />
</svg>
<span id="durationremaining" aria-label="Remaining typing allowance">__LABEL__</span>
</div>
<label id="durationlimit">Limit
<input id="val" type="text" value="__LABEL__" maxlength="80" aria-label="Custom nudge duration" aria-describedby="durationerror" title="Click to edit: 20s, 2 minutes, or 1 min 30 sec. Enter to save. A number alone means seconds." autocomplete="off" spellcheck="false">
</label>
<div id="durationstatus"><span id="statuswrap"><span id="statustext">Ready</span><button id="unsnooze" class="hidden" title="End snooze now" aria-label="End snooze now">✕</button></span></div>
<div id="durationerror" class="hidden" role="status" aria-live="polite"></div>
</div>
<input id="s" type="range" min="0" max="9" step="1" value="__CURRENT__" aria-label="Preset nudge duration">
<div class="ticks"><span>15s</span><span>30s</span><span>45s</span><span>1m</span><span>1m30</span><span>2m</span><span>3m</span><span>4m</span><span>5m</span><span>Never</span></div>
<div class="row">
<div class="split">
<button id="snooze">💤 Snooze __SNOOZELABEL__</button><button id="snoozemore" title="More snooze durations" aria-label="More snooze durations" aria-haspopup="menu">▾</button>
<div id="snoozemenu" class="hidden" role="menu">
<div class="chips">
<button data-m="5" role="menuitem">5m</button>
<button data-m="10" role="menuitem">10m</button>
<button data-m="15" role="menuitem">15m</button>
<button data-m="20" role="menuitem">20m</button>
<button data-m="30" role="menuitem">30m</button>
</div>
<button id="customopt" role="menuitem">Custom&hellip;</button>
<div id="customrow" class="hidden">
<input id="custommin" type="text" maxlength="40" placeholder="45m, 1.5h, 2 hours" aria-label="Custom snooze length, in minutes or hours" aria-describedby="customerror" autocomplete="off" spellcheck="false">
<button id="customgo">Go</button>
</div>
<div id="customerror" class="hidden" role="status" aria-live="polite"></div>
</div>
</div>
<button id="dismiss">__DISMISS__</button>
<button id="disable">__DISABLELABEL__</button>
</div>
<div class="esc">Esc closes this</div>
<div id="gate" class="hidden" role="dialog" aria-modal="true" aria-labelledby="gatetitle">
<div id="gatetitle"></div>
<div id="gateprogress"></div>
<div id="gatequestion"></div>
<div id="gateentry"><input id="gateanswer" type="text" inputmode="decimal" maxlength="16" autocomplete="off" spellcheck="false" aria-label="Your answer"><button id="gatecheck">Check</button></div>
<div id="gatefeedback" role="status" aria-live="polite"></div>
<div id="gatelinks"><button id="gatetip" title="Show the mental-math shortcut for this kind of problem">💡 Tip</button><button id="gatecancel">Never mind</button></div>
<div class="esc">Answers are whole numbers. Digits typed here don't use your allowance. Esc cancels.</div>
</div>
<script>
var stops=[15,30,45,60,90,120,180,240,300,-1];
var threshold=__SECONDS__;
function send(o){ window.webkit.messageHandlers.dictationNudgePanel.postMessage(o); }
var s=document.getElementById('s'), v=document.getElementById('val');
var durationError=document.getElementById('durationerror');
var durationArc=document.getElementById('durationarc');
var durationStatus=document.getElementById('statustext');
var unsnooze=document.getElementById('unsnooze');
var durationRemaining=document.getElementById('durationremaining');
// Native state is pushed at most four times/second while this card is open.
// No JS timers, animation frames, or CSS animation; unchanged states are skipped.
function updateRing(state){
  durationArc.setAttribute('stroke-dashoffset',String(339.292*(1-state.fraction)));
  durationArc.style.visibility=state.fraction>0?'visible':'hidden';
  durationArc.style.stroke=state.muted?'#78808e':'hsl('+Math.round(state.fraction*110)+', 65%, 55%)';
  durationStatus.textContent=state.label;
  unsnooze.classList.toggle('hidden',!state.snoozed);
  durationRemaining.textContent=threshold<0?'Off':durationLabel(Math.ceil(state.remaining));
}
updateRing(__RINGSTATE__);
function parseDuration(text){
  text=text.trim().toLowerCase().replace(/\s+/g,' ');
  if(/^(?:\d+(?:\.\d+)?|\.\d+)$/.test(text)) text+='s';
  text=text.replace(/^(\d+)\s*m\s*(\d+)$/,'$1m $2s');
  var total=0, seen={};
  if(!text) return null;
  while(text){
    var part=text.match(/^(\d+(?:\.\d+)?|\.\d+)\s*(seconds?|secs?|s|minutes?|mins?|m)(?=$|[\s,\d])/);
    if(!part) return null;
    var unit=part[2][0];
    if(seen[unit]) return null;
    seen[unit]=true;
    total+=Number(part[1])*(unit==='m'?60:1);
    text=text.slice(part[0].length).trim();
    if(/^(?:,|and\b)/.test(text)){
      text=text.replace(/^(?:,\s*(?:and\b)?|and\b)\s*/,'');
      if(!text) return null;
    }
  }
  return Number.isSafeInteger(Math.round(total)) && total>=1 && Math.abs(total-Math.round(total))<1e-7 ? Math.round(total) : null;
}
function durationLabel(seconds){
  if(seconds<0) return 'Never';
  if(seconds<60) return seconds+'s';
  return Math.floor(seconds/60)+'m'+(seconds%60?' '+seconds%60+'s':'');
}
function resizeDuration(){ v.style.width=Math.max(3.5,v.value.length+0.5)+'ch'; }
function markDuration(valid){
  v.setAttribute('aria-invalid',String(!valid));
  durationError.textContent=valid?'':'Use seconds or minutes, e.g. 20s or 1 min 30 sec (whole seconds, above zero).';
  durationError.classList.toggle('hidden',valid);
}
function renderDuration(){
  v.value=durationLabel(threshold); resizeDuration(); markDuration(true);
  var index=stops.indexOf(threshold);
  if(index<0){
    index=0;
    for(var i=1;i<stops.length-1;i++) if(Math.abs(stops[i]-threshold)<Math.abs(stops[index]-threshold)) index=i;
  }
  s.value=index;
  s.setAttribute('aria-valuetext',v.value+(stops[index]!==threshold?' (custom)':''));
}
function commitDuration(){
  if(v.value===durationLabel(threshold)) { markDuration(true); return true; }
  var seconds=parseDuration(v.value);
  markDuration(seconds!==null);
  if(seconds===null) return false;
  threshold=seconds; renderDuration(); send({action:'set',value:seconds}); return true;
}
v.addEventListener('focus',function(){ v.select(); });
v.addEventListener('input',function(){ resizeDuration(); markDuration(v.value===durationLabel(threshold) || parseDuration(v.value)!==null); });
v.addEventListener('blur',commitDuration);
v.addEventListener('keydown',function(e){
  if(e.key==='Enter'){ e.preventDefault(); if(commitDuration()) v.blur(); }
});
s.addEventListener('input',function(){
  var i=+s.value;
  threshold=stops[i]; renderDuration();
  send({action:'set', value:stops[i]});
});
renderDuration();
var w=document.getElementById('dictate');
if(w){ w.addEventListener('click',function(){ send({action:'dictate'}); }); }
var menu=document.getElementById('snoozemenu');
var customrow=document.getElementById('customrow');
var custommin=document.getElementById('custommin');
var customError=document.getElementById('customerror');
function hideSnoozeMenu(){ menu.classList.add('hidden'); customrow.classList.add('hidden'); customError.classList.add('hidden'); }
unsnooze.addEventListener('click',function(){ send({action:'unsnooze'}); });
document.getElementById('snooze').addEventListener('click',function(){ send({action:'snooze', minutes:__SNOOZE__}); });
document.getElementById('snoozemore').addEventListener('click',function(e){
  e.stopPropagation();
  customrow.classList.add('hidden');
  menu.classList.toggle('hidden');
});
menu.querySelectorAll('button[data-m]').forEach(function(b){
  b.addEventListener('click',function(){ send({action:'snooze', minutes:+b.dataset.m}); });
});
document.getElementById('customopt').addEventListener('click',function(e){
  e.stopPropagation();
  customrow.classList.remove('hidden');
  custommin.focus();
});
// The length is parsed in Lua (minutes and hours only); it answers with
// snoozeError() when it can't read what was typed.
function goCustom(){
  if(custommin.value.trim()){ customError.classList.add('hidden'); send({action:'snooze', text:custommin.value}); } else { custommin.focus(); }
}
function snoozeError(error){
  menu.classList.remove('hidden'); customrow.classList.remove('hidden');
  customError.textContent=error.message; customError.classList.remove('hidden');
  custommin.focus(); custommin.select();
}
custommin.addEventListener('input',function(){ customError.classList.add('hidden'); });
document.getElementById('customgo').addEventListener('click',goCustom);
custommin.addEventListener('keydown',function(e){ if(e.key==='Enter'){ goCustom(); } });
document.addEventListener('click',function(e){
  if(!menu.classList.contains('hidden') && !e.target.closest('.split')) hideSnoozeMenu();
});
document.getElementById('dismiss').addEventListener('click',function(){
  if(commitDuration()) send({action:'close'}); else v.focus();
});
document.getElementById('disable').addEventListener('click',function(){ send({action:'disable'}); });
var gear=document.getElementById('gear'), prefs=document.getElementById('prefs');
function setPrefsOpen(open){ prefs.classList.toggle('hidden',!open); gear.setAttribute('aria-expanded',String(open)); }
gear.addEventListener('click',function(e){ e.stopPropagation(); hideSnoozeMenu(); setPrefsOpen(prefs.classList.contains('hidden')); });
document.addEventListener('click',function(e){
  if(!prefs.classList.contains('hidden') && !e.target.closest('#prefs')) setPrefsOpen(false);
});
var mathCount=__MATHCOUNT__, mathChips=document.getElementById('mathchips');
function renderMath(){
  mathChips.querySelectorAll('button').forEach(function(b){ b.setAttribute('aria-checked',String(+b.dataset.g===mathCount)); });
  gear.classList.toggle('on',mathCount>0);
  gear.title=mathCount>0?'Settings (math to snooze: '+mathCount+')':'Settings';
}
(function(){
  var options=[0,1,2,3,5];
  if(options.indexOf(mathCount)<0){ options.push(mathCount); options.sort(function(a,b){ return a-b; }); }
  options.forEach(function(n){
    var b=document.createElement('button');
    b.textContent=n?String(n):'Off'; b.dataset.g=n; b.setAttribute('role','radio');
    b.addEventListener('click',function(){ mathCount=n; renderMath(); send({action:'setGate', value:n}); });
    mathChips.appendChild(b);
  });
  renderMath();
})();
// Snooze gate. Lua owns the problems and checks the answers; this only
// renders the view it is sent (null = no challenge) and posts what was typed.
var gate=document.getElementById('gate'), gateAnswer=document.getElementById('gateanswer');
var gateQuestion=document.getElementById('gatequestion'), gateFeedback=document.getElementById('gatefeedback');
var gateShown=null;
// Everything behind the challenge goes inert, so Tab cannot reach it either.
function setGateOpen(open){
  gate.classList.toggle('hidden',!open);
  [].forEach.call(document.body.children,function(el){ if(el!==gate && el.tagName!=='SCRIPT') el.inert=open; });
}
function showGate(view){
  gateShown=view;
  if(!view){ setGateOpen(false); return; }
  hideSnoozeMenu(); setPrefsOpen(false);
  document.getElementById('gatetitle').textContent=view.title;
  document.getElementById('gateprogress').textContent='Problem '+view.index+' of '+view.total;
  if(gateQuestion.textContent!==view.question){ gateQuestion.textContent=view.question; gateAnswer.value=''; }
  gateFeedback.textContent=view.feedback;
  gateFeedback.classList.toggle('wrong',!!view.wrong);
  gateFeedback.classList.remove('tip');
  setGateOpen(true);
  gateAnswer.focus(); gateAnswer.select();
}
// id and index name the problem on screen, so a second click cannot answer the next one.
function submitGate(){
  if(!gateShown) return;
  if(gateAnswer.value.trim()){ send({action:'gateAnswer', id:gateShown.id, index:gateShown.index, value:gateAnswer.value}); } else { gateAnswer.focus(); }
}
document.getElementById('gatecheck').addEventListener('click',submitGate);
gateAnswer.addEventListener('keydown',function(e){ if(e.key==='Enter'){ e.preventDefault(); submitGate(); } });
// The shortcut for this kind of problem. It comes with the view; pressing Tip only shows it.
document.getElementById('gatetip').addEventListener('click',function(){
  if(!gateShown) return;
  gateFeedback.textContent=gateShown.tip;
  gateFeedback.classList.remove('wrong'); gateFeedback.classList.add('tip');
  gateAnswer.focus();
});
document.getElementById('gatecancel').addEventListener('click',function(){ if(gateShown) send({action:'gateCancel', id:gateShown.id}); });
showGate(__GATEVIEW__);
</script></body></html>
]]

closePanel = function()
  stopPanelRing()
  gate = nil
  panelReady = false
  if _G.dictationNudgePanel then
    pcall(function() _G.dictationNudgePanel:delete() end)
    _G.dictationNudgePanel = nil
  end
  _G.dictationNudgePanelVisible = false
end

local function setThreshold(value)
  if type(value) ~= "number" or (value ~= -1 and
    (value < 1 or value > 9007199254740991 or value ~= math.floor(value))) then return end
  config.nudgeAfterSeconds = value
  hs.settings.set(config.settingsKey, value)
  -- apply cleanly: reset streak so the new threshold takes effect fresh
  resetTypingProgress()
  updateMenubar()
  log.i("Threshold set to " .. fmtThreshold(value))
end

openPanel = function(mode, pendingAction)
  closePanel()
  if pendingAction and snoozeMathCount() > 0 then gate = newGate(pendingAction) end

  local isNudge = (mode == "nudge")
  local f = hs.screen.mainScreen():frame()
  local w, h = 480, isNudge and 490 or 420
  local rect = { x = f.x + (f.w - w) / 2, y = f.y + f.h / 3, w = w, h = h }

  local ucc = hs.webview.usercontent.new("dictationNudgePanel")
  ucc:setCallback(function(message)
    local body = message.body
    if type(body) ~= "table" then return end
    if body.action == "set" and type(body.value) == "number" then
      setThreshold(body.value)
    elseif body.action == "dictate" then
      startDictation()
      closePanel()
    elseif body.action == "snooze" then
      -- A typed length is parsed here; a preset arrives as minutes. Anything
      -- else is ignored and the card stays open.
      if type(body.text) == "string" then
        local minutes, reason = parseSnoozeLength(body.text)
        if minutes then
          requestGated({ kind = "snooze", minutes = minutes })
        else
          pushCard("snoozeError(" .. hs.json.encode({ message = reason }) .. ")")
        end
      elseif type(body.minutes) == "number" and body.minutes >= 1 and body.minutes <= SNOOZE_MAX_MINUTES then
        requestGated({ kind = "snooze", minutes = body.minutes })
      end
    elseif body.action == "unsnooze" then
      -- Card stays open: the ring timer flips the status back to live within 250ms.
      if snoozeRemaining() then cancelSnooze() end
    elseif body.action == "disable" then
      if _G.dictationNudgeDisabled then -- turning the nudge back on is never gated
        toggleDisabled()
        closePanel()
      else
        requestGated({ kind = "disable" })
      end
    elseif body.action == "gateAnswer" then
      answerGate(body.id, body.index, body.value)
    elseif body.action == "gateCancel" then
      cancelGate(body.id)
    elseif body.action == "setGate" then
      setSnoozeMathCount(body.value)
    elseif body.action == "close" then
      closePanel()
    end
  end)

  local currentIdx = 1
  for i, v in ipairs(THRESHOLD_STOPS) do
    if v == config.nudgeAfterSeconds then currentIdx = i end
  end

  local title, sub, cta, dismiss
  if isNudge then
    title = "🎙️ Dictate this instead?"
    sub = "You've used your " .. fmtThreshold(config.nudgeAfterSeconds) .. " typing allowance. " ..
      (config.lockdownEnabled
        and ("Switch to voice, or keep typing and I'll block the keyboard for " .. config.lockdownSeconds .. "s.")
        or "Switch to voice, or keep typing.")
    cta = '<button id="dictate" class="dictate">🎙️ Start ' .. htmlEscape(config.dictationName) .. '</button>'
    dismiss = "Keep typing"
  else
    local chord = resetChordLabel()
    title = "🎙️ Dictation nudge"
    sub = "Typing uses this time; resting refills it." .. (chord and (" " .. chord .. " resets it.") or "")
    cta = ""
    dismiss = "Done"
  end

  -- Function replacements: gsub would otherwise treat "%" in a configured
  -- name as a capture reference.
  local html = CARD_HTML
    :gsub("__TITLE__", function() return title end)
    :gsub("__SUB__", function() return sub end)
    :gsub("__CTA__", function() return cta end)
    :gsub("__CURRENT__", currentIdx - 1)
    :gsub("__SECONDS__", config.nudgeAfterSeconds)
    :gsub("__RINGSTATE__", function() return hs.json.encode(panelRingState(now())) end)
    :gsub("__LABEL__", fmtThreshold(config.nudgeAfterSeconds))
    :gsub("__SNOOZELABEL__", fmtMinutes(config.snoozeMinutes))
    :gsub("__SNOOZE__", config.snoozeMinutes)
    :gsub("__DISMISS__", dismiss)
    :gsub("__DISABLELABEL__", _G.dictationNudgeDisabled and "Enable" or "Disable")
    :gsub("__MATHCOUNT__", snoozeMathCount())
    :gsub("__GATEVIEW__", function()
      local view = gateView()
      return view and hs.json.encode(view) or "null"
    end)

  _G.dictationNudgePanel = hs.webview.new(rect, {}, ucc)
    -- no "utility": utility panels (NSPanel) auto-hide as soon as
    -- Hammerspoon loses focus, which made the card vanish instantly
    -- when launched via the Raycast applet. No "closable" either:
    -- Esc/buttons close it so the visibility flag stays accurate.
    :windowStyle({"titled"})
    :titleVisibility("hidden")
    :windowTitle("Dictation nudge")
    :level(hs.drawing.windowLevels.floating)
    :allowTextEntry(true)
    :navigationCallback(function(action, panel)
      if action == "didFinishNavigation" and panel == _G.dictationNudgePanel then
        panelReady = true
        startPanelRing(panel)
        if gate then pushGate() end -- one requested while the page was still loading
      elseif (action == "didFailNavigation" or action == "didFailProvisionalNavigation")
        and panel == _G.dictationNudgePanel and gate then
        closePanel() -- the page never arrived, so the problem cannot be shown
      end
    end)
    :windowCallback(function(action, panel)
      if action == "closing" and panel == _G.dictationNudgePanel then
        stopPanelRing()
        gate = nil
        panelReady = false
        _G.dictationNudgePanel = nil
        _G.dictationNudgePanelVisible = false
      end
    end)
    :html(html)
    :show()
  _G.dictationNudgePanelVisible = true
end

-- ═══ Tier 1: sound + banner + nudge card ═══
-- preview = true (console helper and the test URL) shows the same sound,
-- banner, and card without starting the cooldown or arming the lockdown.
local function fireTier1(preview)
  if not preview then
    local ts = now()
    _G.dictationNudgeTier1At = ts
    _G.dictationNudgeLastNudgeAt = ts
    log.i("Tier 1 nudge fired")
  end

  if config.soundName then
    local sound = hs.sound.getByName(config.soundName)
    if sound then sound:play() end
  end

  hs.alert.show(
    "🎙️  Typing allowance used. Switch to " .. config.dictationName .. "!",
    { textSize = 28, radius = 16, fadeInDuration = 0.15 },
    nil, -- default screen
    4
  )

  openPanel("nudge")
end

-- ═══ Keystroke handler ═══
-- Reads three things from an event, in memory: keycode, modifier flags, and
-- the autorepeat flag. It never asks for characters, and the only thing it
-- keeps is the timestamp of the last counted key plus the allowance used.
local ESC_KEYCODE = 53

-- Keycodes that never count as typing: F1-F20, arrows, Tab, and whatever
-- config.extraExcludedKeys names. Rebuilt in start() once config is known.
local excludedKeycodes = {}
local function rebuildExcludedKeycodes()
  for code in pairs(excludedKeycodes) do excludedKeycodes[code] = nil end
  local names = {"left", "right", "up", "down", "tab"}
  for i = 1, 20 do table.insert(names, "f" .. i) end
  for _, name in ipairs(config.extraExcludedKeys or {}) do table.insert(names, name) end
  for _, name in ipairs(names) do
    local code = hs.keycodes.map[name]
    if code then
      excludedKeycodes[code] = true
    else
      log.w("extraExcludedKeys: unknown key name " .. tostring(name))
    end
  end
end
rebuildExcludedKeycodes()

-- The reset chord matches when exactly the configured modifiers are held
-- (Fn is only checked when it is part of the chord).
local function rebuildResetModifiers()
  resetWanted = nil
  local mods = config.resetModifiers
  if type(mods) ~= "table" or #mods == 0 then return end
  resetWanted = {}
  for _, name in ipairs(mods) do resetWanted[name] = true end
end
rebuildResetModifiers()

local function isResetChord(flags)
  if not resetWanted then return false end
  for _, name in ipairs({"cmd", "ctrl", "alt", "shift"}) do
    if (flags[name] == true) ~= (resetWanted[name] == true) then return false end
  end
  if resetWanted.fn and not flags.fn then return false end
  return true
end

-- Keys needed to answer a snooze-gate problem: digits, separators, delete,
-- Return. While a problem is showing they are invisible, like Tab or the
-- arrows, so answering never spends allowance. Letters still count, so a
-- problem left on screen is not a free pass to keep typing. Looked up by
-- name each time a challenge starts, so it follows the keyboard layout.
local gateAnswerKeycodes = {}
rebuildGateAnswerKeycodes = function()
  for code in pairs(gateAnswerKeycodes) do gateAnswerKeycodes[code] = nil end
  local names = {".", ",", "-", "delete", "forwarddelete", "return", "padenter", "pad.", "pad,", "pad-"}
  for digit = 0, 9 do
    table.insert(names, tostring(digit))
    table.insert(names, "pad" .. digit)
  end
  for _, name in ipairs(names) do
    local code = hs.keycodes.map[name]
    if code then gateAnswerKeycodes[code] = true end
  end
end

-- A "typing key" is a genuine, intentional text-producing press.
local function isTypingKey(event)
  -- held key: macOS re-sends keyDown with autorepeat set; never counts
  if event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) ~= 0 then
    return false
  end
  -- ⌘/⌃ held = shortcut, not typing (also covers Hyper window keys)
  local flags = event:getFlags()
  if flags.cmd or flags.ctrl then
    return false
  end
  -- F-keys, arrows, Tab, extraExcludedKeys (keycodes are independent of Shift)
  if excludedKeycodes[event:getKeyCode()] then
    return false
  end
  return true
end

local function onKeyDown(event)
  local ts = now()

  -- A lockdown past its deadline is over, whether or not its release timer
  -- ran. Clear it before anything else so it can neither block a key nor
  -- eat an Esc.
  if _G.dictationNudgeLockdownUntil and ts >= _G.dictationNudgeLockdownUntil then
    endLockdown()
  end

  -- Esc with the card open: close it (and any lockdown). Global watch,
  -- works whether or not the card has focus. Consumed so it doesn't
  -- also fire in the app behind.
  if event:getKeyCode() == ESC_KEYCODE then
    if _G.dictationNudgePanelVisible or _G.dictationNudgeLockdownUntil then
      closePanel()
      endLockdown()
      return true
    end
    return false
  end

  -- During lockdown: swallow every other key press.
  if _G.dictationNudgeLockdownUntil then
    return true
  end

  -- Disabled: fully passive.
  if _G.dictationNudgeDisabled then return false end

  -- Not a typing key (autorepeat/held, ⌘⌃ shortcut, F-key, arrow, Tab, extras):
  -- invisible. It doesn't count toward the burst and doesn't break it.
  if not isTypingKey(event) then return false end

  -- Answering a snooze-gate problem: the answer keys are invisible too.
  if gate and gateAnswerKeycodes[event:getKeyCode()] then return false end

  -- Snoozed or switched off ("Never"): pass through, track nothing.
  if snoozeRemaining() then return false end
  if config.nudgeAfterSeconds < 0 then return false end

  -- Settle refill, then charge only a confirmed interval between two counted
  -- keys. Never predict additional typing after the key that just arrived.
  local used = typingUsedSeconds(ts)
  local gap = _G.dictationNudgeLastKeyAt and math.max(0, ts - _G.dictationNudgeLastKeyAt)
  if gap and gap <= config.gapSeconds then
    -- Only the pre-refill portion may be charged. Charging the entire gap
    -- here would claw back idle credit that the meter has already restored.
    used = math.min(config.nudgeAfterSeconds, used + math.min(gap, config.refillDelaySeconds))
  else
    _G.dictationNudgeTier1At = nil -- new burst: a pending escalation is off
  end
  _G.dictationNudgeUsedSeconds = used
  _G.dictationNudgeLastKeyAt = ts
  -- Wake the existing display timer only when needed. No native drawing on the
  -- input callback; it just observes this same budget at the next half-second tick.
  local menuTimer = _G.dictationNudgeMenuTimer
  if used > 0 and menuTimer and not menuTimer:running() then menuTimer:start() end

  -- Tier 2: kept typing through tier 1.
  if config.lockdownEnabled
    and _G.dictationNudgeTier1At
    and (ts - _G.dictationNudgeTier1At) >= config.escalateAfterSeconds then
    _G.dictationNudgeTier1At = nil
    startLockdown()
    return true
  end

  -- Only a real counted key can trigger a nudge; idle never fires one.
  if not _G.dictationNudgeTier1At then
    if used >= config.nudgeAfterSeconds and (ts - _G.dictationNudgeLastNudgeAt) >= config.cooldownSeconds then
      fireTier1()
    end
  end

  return false -- pass the keystroke through untouched
end

-- Modifier-only reset chord (a dictation hotkey): observe it without consuming
-- the event. Keep this callback lightweight: no window/Accessibility queries
-- or key posting.
local function onInputEvent(event)
  if event:getType() == hs.eventtap.event.types.flagsChanged then
    if isResetChord(event:getFlags()) then
      resetTypingProgress()
    end
    return false
  end
  return onKeyDown(event)
end

-- ═══ Lifecycle ═══
local URL_EVENTS = {
  { names = {"dictationnudgesettings", "dictationNudgeSettings"}, fn = function() openPanel("settings") end },
  { names = {"dictationnudgesnooze", "dictationNudgeSnooze"}, fn = function() toggleSnooze() end },
  { names = {"dictationnudgetest", "dictationNudgeTest"}, fn = function() fireTier1(true) end },
}

function M.start(userConfig)
  -- Build the new config on the side and validate it before any side effect.
  -- Every start begins from the defaults, so start({}) after start({...})
  -- does not inherit the earlier overrides.
  if userConfig ~= nil and type(userConfig) ~= "table" then
    error("dictation_nudge: start() takes a table of options, or nothing", 0)
  end
  local candidate = {}
  for key, value in pairs(DEFAULTS) do candidate[key] = value end
  for key, value in pairs(userConfig or {}) do candidate[key] = value end
  validateConfig(candidate)
  for key in pairs(config) do config[key] = nil end
  for key, value in pairs(candidate) do config[key] = value end

  -- persisted threshold preference wins over defaults/args
  local saved = hs.settings.get(config.settingsKey)
  if type(saved) == "number" and (saved == -1 or saved >= 1) then
    config.nudgeAfterSeconds = saved
  end

  -- persisted last-used snooze duration wins over defaults/args
  local savedSnooze = hs.settings.get(config.snoozeSettingsKey)
  if type(savedSnooze) == "number" and savedSnooze >= 1 and savedSnooze <= SNOOZE_MAX_MINUTES then
    config.snoozeMinutes = math.floor(savedSnooze)
  end

  -- persisted snooze-gate count (set on the card) wins over defaults/args
  local savedMath = hs.settings.get(config.snoozeMathSettingsKey)
  if type(savedMath) == "number" and savedMath >= 0 and savedMath <= SNOOZE_MATH_MAX then
    config.snoozeMathProblems = math.floor(savedMath)
  end

  rebuildExcludedKeycodes()
  rebuildResetModifiers()

  if _G.dictationNudgeTap then
    _G.dictationNudgeTap:stop()
    _G.dictationNudgeTap = nil
  end
  _G.dictationNudgeCanvases = _G.dictationNudgeCanvases or {}
  _G.dictationNudgeLockTimers = _G.dictationNudgeLockTimers or {}
  endLockdown()
  closePanel()
  clearState()

  if not hs.accessibilityState(true) then
    hs.alert.show("dictation_nudge: grant Hammerspoon Accessibility, then reload")
    log.w("Accessibility permission missing")
  end

  _G.dictationNudgeTap = hs.eventtap.new({
    hs.eventtap.event.types.keyDown, hs.eventtap.event.types.flagsChanged,
  }, onInputEvent)
  _G.dictationNudgeTap:start()

  local okMenu, errMenu = pcall(startMenubar)
  if not okMenu then
    log.e("menubar failed: " .. tostring(errMenu))
    hs.alert.show("dictation_nudge: menubar failed (see console)")
  end

  -- URL events for the launcher app, Raycast Quicklinks, Shortcuts, etc.
  -- Bound in both casings so a normalized URL host can't drop the event.
  local okBinds, errBinds = pcall(function()
    for _, event in ipairs(URL_EVENTS) do
      for _, name in ipairs(event.names) do hs.urlevent.bind(name, event.fn) end
    end
  end)
  if not okBinds then
    log.e("urlevent binds failed: " .. tostring(errBinds))
    hs.alert.show("dictation_nudge: URL binds failed (see console)")
  end

  log.i(string.format(
    "Started: nudge at %s used (gap %gs, refill %gs/s after %gs idle), escalate +%gs, lockdown %gs (%s), cooldown %gs, snooze %gm",
    fmtThreshold(config.nudgeAfterSeconds), config.gapSeconds, config.refillPerSecond, config.refillDelaySeconds, config.escalateAfterSeconds,
    config.lockdownSeconds, config.lockdownEnabled and "on" or "off",
    config.cooldownSeconds, config.snoozeMinutes
  ))
end

function M.stop()
  if _G.dictationNudgeTap then
    _G.dictationNudgeTap:stop()
    _G.dictationNudgeTap = nil
  end
  _G.dictationNudgeCanvases = _G.dictationNudgeCanvases or {}
  _G.dictationNudgeLockTimers = _G.dictationNudgeLockTimers or {}
  endLockdown()
  closePanel()
  pcall(function()
    for _, event in ipairs(URL_EVENTS) do
      for _, name in ipairs(event.names) do hs.urlevent.bind(name, nil) end
    end
  end)
  if _G.dictationNudgeMenu then
    _G.dictationNudgeMenu:delete()
    _G.dictationNudgeMenu = nil
  end
  if _G.dictationNudgeMenuTimer then
    _G.dictationNudgeMenuTimer:stop()
    _G.dictationNudgeMenuTimer = nil
  end
  clearState()
  log.i("Stopped")
end

-- ═══ Console helpers (Hammerspoon Console / `hs -c`) ═══
-- dictationNudgeTest()     -> preview tier 1 (sound + banner + nudge card);
--                             does not start the cooldown or arm the lockdown
-- dictationNudgeLock()     -> start a lockdown now, even with lockdownEnabled
--                             off (only while the tap is enabled, so Esc
--                             can end it)
-- dictationNudgeSnooze()   -> toggle snooze
-- dictationNudgeDisable()  -> toggle disable (session-only)
-- dictationNudgeSettings() -> open the card in settings mode
-- dictationNudgeStatus()   -> tap/state dump. lastCountedKeyAge is the age of the
--                          last key counted since the meter was last reset
--                          (reload, snooze, limit change, reset chord). If it
--                          stays "never seen" while you type plain letters
--                          with the tool on, the tap may not be receiving
--                          events; a missing Input Monitoring grant is one cause.
-- dictationNudgeFilterTest() -> builds synthetic events IN MEMORY (nothing
-- is posted to apps) and reports how the filter classifies them.
-- Offline tests of the allowance math live in tests/ (plain Lua, no Hammerspoon).
function dictationNudgeFilterTest()
  local function mk(mods, key, autorepeat)
    local e = hs.eventtap.event.newKeyEvent(mods or {}, key, true)
    if autorepeat then
      e:setProperty(hs.eventtap.event.properties.keyboardEventAutorepeat, 1)
    end
    return isTypingKey(e)
  end
  return string.format(
    "a=%s shift+a=%s alt+a=%s (want true) | f13=%s arrow=%s cmd+a=%s ctrl+a=%s held=%s (want false)",
    tostring(mk(nil, "a")), tostring(mk({"shift"}, "a")), tostring(mk({"alt"}, "a")),
    tostring(mk(nil, "f13")), tostring(mk(nil, "right")),
    tostring(mk({"cmd"}, "a")), tostring(mk({"ctrl"}, "a")),
    tostring(mk(nil, "a", true))
  )
end

function dictationNudgeTest() fireTier1(true) end
function dictationNudgeLock()
  if not (_G.dictationNudgeTap and _G.dictationNudgeTap:isEnabled()) then return "not running" end
  startLockdown()
end
function dictationNudgeSnooze() toggleSnooze() end
function dictationNudgeDisable() toggleDisabled() end
function dictationNudgeSettings() openPanel("settings") end
function dictationNudgeStatus()
  local tapRunning = _G.dictationNudgeTap and _G.dictationNudgeTap:isEnabled() or false
  local lastKeyAge = _G.dictationNudgeLastKeyAt and (now() - _G.dictationNudgeLastKeyAt) or nil
  local rem = snoozeRemaining()
  return string.format(
    "tap=%s threshold=%s used=%s lastCountedKeyAge=%s lockdown=%s snooze=%s card=%s disabled=%s snoozeMath=%s",
    tostring(tapRunning),
    fmtThreshold(config.nudgeAfterSeconds),
    string.format("%.1fs", typingUsedSeconds(now())),
    lastKeyAge and string.format("%.1fs", lastKeyAge) or "never seen",
    (_G.dictationNudgeLockdownUntil and _G.dictationNudgeLockdownUntil > now()) and "ACTIVE" or "off",
    rem and string.format("%dm left", math.ceil(rem / 60)) or "off",
    _G.dictationNudgePanelVisible and "open" or "closed",
    tostring(_G.dictationNudgeDisabled == true),
    snoozeMathCount() == 0 and "off" or (snoozeMathCount() .. (gate and " (solving)" or ""))
  )
end

-- Test seam for tests/run.lua. Not a public API; it can change without notice.
M._internal = {
  config = config,
  usedSeconds = typingUsedSeconds,
  ringState = panelRingState,
  isTypingKey = isTypingKey,
  onInputEvent = onInputEvent,
  moneyMath = MoneyMath,
  parseSnoozeLength = parseSnoozeLength,
  gate = function() return gate end,
}

return M
