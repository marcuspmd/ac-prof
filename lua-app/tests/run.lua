-- Headless regression runner for the track-painter coaching logic.
-- Feeds REAL track telemetry (lua-app/tracks/*.lua) through the corner scan +
-- safe-speed profile under many car / speed / grip / dirt scenarios and checks:
--   A) no braking paint in the middle of a straight (the reported bug)
--   B) every unambiguous real corner is detected (no "accelerate into the corner")
--
-- Run from the repo root:  lua lua-app/tests/run.lua
-- Exits non-zero if any scenario fails.

local here = (arg and arg[0]) or "lua-app/tests/run.lua"
local luaApp = here:match("^(.*)[/\\]tests[/\\]run%.lua$") or "lua-app"
package.path = luaApp .. "/?.lua;" .. package.path

require('tests.mock_runtime')        -- installs ac / vec3 / rgbm (must be first)
local H = require('tests.harness')

-- Representative layouts: long straights (phantom-red prone) + technical sections.
local TRACKS = {
  "ks_monza66_road",
  "ks_monza66_full",
  "imola",
  "ks_silverstone_gp",
  "ks_nurburgring_layout_gp_a",
  "ks_laguna_seca",
  "ks_highlands_layout_long",
  "ks_vallelunga_classic_circuit",
  "ks_drag_drag2000",   -- pure straight: must detect 0 corners and paint 0 false red
}

local CARS = { "street", "gt", "formula" }

-- Build the scenario matrix.
local scenarios = {}
local function add(track, car, mult, grip, dirty)
  scenarios[#scenarios + 1] = { track = track, car = car, mult = mult, grip = grip, dirty = dirty }
end

-- Core sweep: every track x car at nominal and high relative speed, full grip, clean tyres.
for _, t in ipairs(TRACKS) do
  for _, c in ipairs(CARS) do
    add(t, c, 1.0, 1.0, 0.0)
    add(t, c, 1.3, 1.0, 0.0)
  end
end

-- Adverse conditions: low grip + dirty tyres on a few representative tracks.
for _, t in ipairs({ "ks_monza66_road", "ks_silverstone_gp", "ks_nurburgring_layout_gp_a" }) do
  for _, c in ipairs(CARS) do
    add(t, c, 1.0, 0.85, 0.30)
  end
end

----------------------------------------------------------------------
-- Execute + report
----------------------------------------------------------------------
local results = {}
local failures = {}

print(string.format("%-32s %-8s %5s %5s %5s | %4s %5s %8s %5s %s",
  "track", "car", "mult", "grip", "dirt", "crn", "real", "falseRm", "miss", ""))
print(string.rep("-", 100))

for _, s in ipairs(scenarios) do
  local ok, r = pcall(H.run, s.track, s.car, { speedMult = s.mult, roadGrip = s.grip, dirty = s.dirty })
  if not ok then
    print(string.format("%-32s %-8s  ERROR: %s", s.track, s.car, tostring(r)))
    failures[#failures + 1] = { scenario = s, err = r }
  else
    results[#results + 1] = r
    print(string.format("%-32s %-8s %5.2f %5.2f %5.2f | %4d %5d %8.1f %5d %s",
      r.track, r.car, r.speedMult, r.roadGrip, r.dirty,
      r.cornerCount, r.realCorners, r.worstFalseRedM, #r.missed,
      r.pass and "ok" or "**FAIL**"))
    if not r.pass then failures[#failures + 1] = { scenario = s, result = r } end
  end
end

-- Synthetic teeth-test: a straight with a telemetry ripple must never become a
-- braking zone. Run across the conditions where the regression bit hardest.
print(string.rep("-", 100))
print("Synthetic oval (ripple-on-straight regression):")
local synthScenarios = {
  { car = "street",  mult = 1.0, grip = 0.85, dirty = 0.30 },
  { car = "street",  mult = 1.3, grip = 1.00, dirty = 0.00 },
  { car = "gt",      mult = 1.0, grip = 1.00, dirty = 0.00 },
  { car = "formula", mult = 1.3, grip = 1.00, dirty = 0.00 },
}
local synthCount = 0
for _, s in ipairs(synthScenarios) do
  synthCount = synthCount + 1
  local ok, r = pcall(H.runSynthetic, s.car, { speedMult = s.mult, roadGrip = s.grip, dirty = s.dirty })
  if not ok then
    print(string.format("  %-8s mult=%.2f -> ERROR: %s", s.car, s.mult, tostring(r)))
    failures[#failures + 1] = { synth = s, err = r }
  else
    print(string.format("  %-8s mult=%.2f grip=%.2f dirt=%.2f | corners=%d on-straight=%d falseRedM=%.1f  %s",
      s.car, s.mult, s.grip, s.dirty, r.cornerCount, r.cornerOnStraight, r.worstFalseRedM,
      r.pass and "ok" or "**FAIL**"))
    if not r.pass then failures[#failures + 1] = { synth = s, result = r } end
  end
end

print(string.rep("-", 100))
print(string.format("Scenarios: %d   Passed: %d   Failed: %d",
  #scenarios + synthCount, #scenarios + synthCount - #failures, #failures))

if #failures > 0 then
  print("\nFAILURE DETAIL:")
  for _, f in ipairs(failures) do
    if f.err then
      local who = f.synth and ("synthetic/" .. f.synth.car) or (f.scenario.track .. "/" .. f.scenario.car)
      print(string.format("  %s -> error: %s", who, tostring(f.err)))
    elseif f.synth then
      local r = f.result
      print(string.format("  synthetic/%s mult=%.2f grip=%.2f dirt=%.2f -> %d corner(s) on straight, false-red stripe %.0f m",
        f.synth.car, f.synth.mult, f.synth.grip, f.synth.dirty, r.cornerOnStraight, r.worstFalseRedM))
    else
      local r = f.result
      local why = {}
      if r.worstFalseRedM >= 15 then
        why[#why + 1] = string.format("false-red stripe %.0f m on a straight", r.worstFalseRedM)
      end
      if #r.missed > 0 then
        local locs = {}
        for _, m in ipairs(r.missed) do
          locs[#locs + 1] = string.format("%.3f(%.0fkm/h)", m.progress, m.speedKmh)
        end
        why[#why + 1] = string.format("%d real corner(s) undetected @ %s",
          #r.missed, table.concat(locs, ", "))
      end
      print(string.format("  %s/%s mult=%.2f grip=%.2f dirt=%.2f -> %s",
        r.track, r.car, r.speedMult, r.roadGrip, r.dirty, table.concat(why, "; ")))
    end
  end
  os.exit(1)
end

print("\nAll scenarios passed.")
os.exit(0)
