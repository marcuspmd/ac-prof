-- Test harness: builds cars/sims, loads real track telemetry, runs the track-painter
-- corner scan + safe-speed profile, and evaluates it against the AI telemetry ground
-- truth. Requires mock_runtime to be loaded first (run.lua does that).

local physics = require('physics-calc')
local painter = require('track-painter')

local H = {}

-- Local geometric radius (m) at spline index i, from the XZ positions (pt[1], pt[3]).
-- Large (1e9) on a straight. Used to assert "no braking paint" only where the track is
-- geometrically straight -- in corners a weak car legitimately needs to slow, which is
-- not the "red in the middle of a straight" bug we are guarding.
local function radiusAt(pts, n, i, arm)
  local a = ((i - arm - 1) % n) + 1
  local c = ((i + arm - 1) % n) + 1
  local p1, p2, p3 = pts[a], pts[i], pts[c]
  local t1x, t1z = p2[1] - p1[1], p2[3] - p1[3]
  local t2x, t2z = p3[1] - p2[1], p3[3] - p2[3]
  local l1 = math.sqrt(t1x * t1x + t1z * t1z)
  local l2 = math.sqrt(t2x * t2x + t2z * t2z)
  if l1 < 1e-6 or l2 < 1e-6 then return 1e9 end
  local dx = t2x / l2 - t1x / l1
  local dz = t2z / l2 - t1z / l1
  local curv = math.sqrt(dx * dx + dz * dz) / l1
  if curv < 1e-6 then return 1e9 end
  return 1.0 / curv
end
local STRAIGHT_RADIUS = 400.0  -- radius above this counts as "straight" for the paint check

----------------------------------------------------------------------
-- Car presets. G-limits mirror physics-calc.initializeCarLimits per class.
----------------------------------------------------------------------
local CAR_PRESETS = {
  street  = { latG = 1.05, decelG = 0.90, accelG = 0.35, liftF = 0.0,  liftR = 0.0,  racing = false, openWheel = false, drs = false },
  gt      = { latG = 1.40, decelG = 1.10, accelG = 0.55, liftF = -1.0, liftR = -1.5, racing = true,  openWheel = false, drs = false },
  formula = { latG = 2.10, decelG = 1.50, accelG = 0.80, liftF = -3.0, liftR = -4.0, racing = true,  openWheel = true,  drs = true  },
}
H.CAR_PRESETS = CAR_PRESETS

-- Build a mock car. opts: { dirty=0..1 }
function H.makeCar(presetName, opts)
  opts = opts or {}
  local p = assert(CAR_PRESETS[presetName], "unknown car preset: " .. tostring(presetName))
  local dirty = opts.dirty or 0.0

  local wheels = {}
  for i = 0, 3 do
    wheels[i] = {
      tyreCoreTemperature    = 85,
      tyreOptimumTemperature = 85,
      tyreWear               = 1.0,
      tyreDirty              = dirty,
      brakeTemperature       = 300,
    }
  end

  return {
    speedMs        = 50,
    gas            = 1.0,
    brake          = 0.0,
    splinePosition = 0.0,
    collisionDepth = 0,
    position       = vec3(0, 0, 0),
    acceleration   = { x = 0, y = 0, z = 0 },
    wheels         = wheels,
    aeroLiftFront  = p.liftF,
    aeroLiftRear   = p.liftR,
    isRacingCar    = p.racing,
    isOpenWheeler  = p.openWheel,
    drsPresent     = p.drs,
    _preset        = presetName,
  }
end

-- Reset the global physics G-limits to this car class (physics state is module-global)
function H.applyPhysics(presetName)
  local p = assert(CAR_PRESETS[presetName])
  physics.maxObservedLatG   = p.latG
  physics.maxObservedDecelG = p.decelG
  physics.maxObservedAccelG = p.accelG
  physics.smoothedLatG      = p.latG
  physics.smoothedDecelG    = p.decelG
  physics.smoothedAccelG    = p.accelG
end

----------------------------------------------------------------------
-- Track loading
----------------------------------------------------------------------
-- Loads a tracks/<filename>.lua, points the runtime at it, and returns the raw data.
function H.applyTrack(filename)
  local data = require('tracks.' .. filename)
  assert(type(data.points) == "table", "track has no points: " .. filename)
  local detailCount = data.detailCount or #data.points
  -- layout left empty -> ai-loader trackName resolves to the filename itself
  ac.__setTrack(filename, "", data.points, detailCount, data.trackLength)
  return data
end

function H.makeSim(trackLengthM, roadGrip)
  return { trackLengthM = trackLengthM, roadGrip = roadGrip or 1.0 }
end

----------------------------------------------------------------------
-- Evaluation oracles (vs AI telemetry ground truth)
----------------------------------------------------------------------
-- Run the painter and score the result. Returns a result table.
function H.run(filename, presetName, opts)
  opts = opts or {}
  local speedMult = opts.speedMult or 1.0
  local roadGrip  = opts.roadGrip or 1.0

  local data = H.applyTrack(filename)
  H.applyPhysics(presetName)
  local car = H.makeCar(presetName, { dirty = opts.dirty })
  local sim = H.makeSim(data.trackLength, roadGrip)

  local profile, corners = painter.buildProfileForTest(car, sim, roadGrip, speedMult)

  local n = data.detailCount or #data.points
  local trackLen = data.trackLength
  local mPerPoint = trackLen / n
  local pts = data.points

  local function gasAt(i)   return pts[i][5] end
  local function brakeAt(i) return pts[i][6] end
  local function spdAt(i)   return pts[i][4] end -- km/h

  ------------------------------------------------------------------
  -- Oracle A: no braking paint deep inside a straight.
  -- A point is "painted red" when a player following the AI speed (scaled by
  -- speedMult) is above the safe profile. It is a FALSE red if, within the
  -- adaptive braking-distance window ahead, the AI never brakes or lifts — i.e.
  -- there is genuinely no corner to brake for. Grouped into runs; a run >= 15 m
  -- is a visible bogus stripe and fails.
  ------------------------------------------------------------------
  -- Flag braking paint that lands on a geometric STRAIGHT with no real reason to brake.
  -- A point is a false-red iff: (1) a player at the AI speed is over the safe profile,
  -- (2) the track is straight there (lateral grip irrelevant -- going fast is fine), and
  -- (3) no real slowdown is coming within braking distance ahead (>=20 km/h drop or hard
  -- braking). A momentary throttle lift / few-km/h ripple does NOT count -- that is what
  -- seeds the phantom corners this guards against.
  local arm = math.max(1, math.floor(15 / mPerPoint))
  local falseRedFlags = {}
  for i = 1, n do
    local playerMs = spdAt(i) * speedMult / 3.6
    local vSafe = profile[i] or 999.0
    if playerMs > vSafe + 0.5 and radiusAt(pts, n, i, arm) > STRAIGHT_RADIUS then
      local lookM = playerMs * playerMs / (2 * 5.0) + 80 -- generous stop dist + margin
      local lookPts = math.min(n - 1, math.ceil(lookM / mPerPoint))
      local sHere = spdAt(i)
      local minAhead, hardBrake = sHere, false
      for w = 0, lookPts do
        local j = ((i + w - 1) % n) + 1
        if spdAt(j) < minAhead then minAhead = spdAt(j) end
        if brakeAt(j) > 0.30 then hardBrake = true end
      end
      local reason = hardBrake or (sHere - minAhead) >= 20.0
      falseRedFlags[i] = not reason
    end
  end
  -- group consecutive false-red points into runs (circular)
  local worstFalseRedM = 0
  local falseRedCount = 0
  do
    local runLen = 0
    for k = 1, n * 2 do -- wrap once to catch a run crossing the start/finish line
      local i = ((k - 1) % n) + 1
      if falseRedFlags[i] then
        runLen = runLen + 1
        if k <= n then falseRedCount = falseRedCount + 1 end
      else
        if runLen > 0 then worstFalseRedM = math.max(worstFalseRedM, runLen * mPerPoint) end
        runLen = 0
      end
    end
  end

  ------------------------------------------------------------------
  -- Oracle B: every unambiguous real corner must be covered by a detected corner.
  -- Ground truth = a wide-window (+/-60 m) local speed minimum whose drop from the
  -- surrounding maxima is >= 35 km/h. A wide window merges compound braking into one
  -- apex and ignores brief brake-stabs on fast kinks (which recover within a few m).
  -- Assert a detected corner apex sits within 40 m, else the painter would let the
  -- player accelerate into a corner that genuinely demands slowing.
  ------------------------------------------------------------------
  local apexProgs = {}
  for _, c in ipairs(corners) do apexProgs[#apexProgs + 1] = c.apexProgress end

  local function nearestCornerDistM(progress)
    local best = math.huge
    for _, ap in ipairs(apexProgs) do
      local d = math.abs(ap - progress)
      if d > 0.5 then d = 1.0 - d end
      best = math.min(best, d * trackLen)
    end
    return best
  end

  local mWin = math.max(3, math.floor(60 / mPerPoint))
  local DROP_KMH = 35.0
  local realCorners, missed = 0, {}
  for i = 1, n do
    local s = spdAt(i)
    local isMin, maxInWin = true, s
    for w = -mWin, mWin do
      if w ~= 0 then
        local j = ((i + w - 1) % n) + 1
        local sj = spdAt(j)
        if sj < s - 0.05 then isMin = false break end
        if sj > maxInWin then maxInWin = sj end
      end
    end
    if isMin and (maxInWin - s) >= DROP_KMH then
      realCorners = realCorners + 1
      local prog = (i - 1) / n
      if nearestCornerDistM(prog) > 40 then
        missed[#missed + 1] = { progress = prog, speedKmh = s }
      end
    end
  end

  local pass = (worstFalseRedM < 15.0) and (#missed == 0)
  return {
    track = filename, car = presetName, speedMult = speedMult, roadGrip = roadGrip,
    dirty = opts.dirty or 0,
    cornerCount = #corners,
    falseRedCount = falseRedCount,
    worstFalseRedM = worstFalseRedM,
    realCorners = realCorners,
    missed = missed,
    pass = pass,
  }
end

----------------------------------------------------------------------
-- Synthetic track: an oval (two long straights + two real hairpin ends) with a
-- telemetry RIPPLE on one straight (a brief throttle lift + ~4 km/h speed dip).
-- That ripple is exactly what seeded phantom corners on real straights. A correct
-- system must NOT turn it into a braking zone. This is the deterministic teeth-test
-- for the "red in the middle of a straight" regression (real track data is too clean
-- to reproduce it). Built procedurally so we control the geometry and telemetry.
----------------------------------------------------------------------
function H.makeOval(opts)
  opts = opts or {}
  local R = opts.R or 50.0          -- hairpin radius (real corner -> detected)
  local S = opts.S or 500.0         -- straight length
  local spacing = 2.0
  local total = 2 * S + 2 * math.pi * R
  local N = math.floor(total / spacing)
  local straightKmh = opts.straightKmh or 280.0
  local cornerKmh   = opts.cornerKmh or 80.0
  local brakeZone   = 120.0         -- m of braking before each arc
  local accelZone   = 120.0         -- m of acceleration after each arc

  local pts = {}
  for i = 1, N do
    local d = (i - 1) * spacing      -- arc length along centreline
    local x, z, gas, brake, spd

    local dRightArc = S
    local dTop      = S + math.pi * R
    local dLeftArc  = 2 * S + math.pi * R

    if d < dRightArc then            -- bottom straight (-S/2,-R) -> (S/2,-R)
      x = -S / 2 + d; z = -R
    elseif d < dTop then             -- right hairpin
      local a = (d - dRightArc) / R
      local ang = -math.pi / 2 + a
      x = S / 2 + R * math.cos(ang); z = R * math.sin(ang)
    elseif d < dLeftArc then         -- top straight (S/2,R) -> (-S/2,R)
      x = S / 2 - (d - dTop); z = R
    else                             -- left hairpin
      local a = (d - dLeftArc) / R
      local ang = math.pi / 2 + a
      x = -S / 2 + R * math.cos(ang); z = R * math.sin(ang)
    end

    -- Speed/throttle profile: full speed on straights, braking before each arc,
    -- corner speed through the arc, acceleration out.
    local inArc = (d >= dRightArc and d < dTop) or (d >= dLeftArc)
    local distToArc = math.min((dRightArc - d) % total, (dLeftArc - d) % total)
    local distFromArc = math.min((d - dTop) % total, (d - 0) % total)
    if inArc then
      spd = cornerKmh; gas = 0.4; brake = 0.0
    elseif distToArc < brakeZone then
      local f = distToArc / brakeZone -- 1 far -> 0 at arc
      spd = cornerKmh + (straightKmh - cornerKmh) * f
      gas = 0.0; brake = 1.0
    elseif distFromArc < accelZone then
      local f = distFromArc / accelZone
      spd = cornerKmh + (straightKmh - cornerKmh) * f
      gas = 1.0; brake = 0.0
    else
      spd = straightKmh; gas = 1.0; brake = 0.0
    end

    pts[i] = { x, 0, z, spd, gas, brake, 0, 1 }
  end

  -- Inject the ripple in the clean middle of the bottom straight.
  local rippleCenter = math.floor((S / 2) / spacing)
  for w = -3, 3 do
    local i = ((rippleCenter + w - 1) % N) + 1
    pts[i][4] = (opts.rippleKmh or 276.0)  -- ~4 km/h dip
    pts[i][5] = (opts.rippleGas or 0.6)    -- throttle lift that seeds a phantom
  end

  return { trackLength = total, detailCount = N, refMaxSpeedKmh = straightKmh, points = pts }
end

-- Run the synthetic oval and return false-red diagnostics (uses Oracle A only;
-- the oval has two real corners that the main oracle covers).
function H.runSynthetic(presetName, opts)
  opts = opts or {}
  local data = H.makeOval(opts)
  -- Register the in-memory oval so ai-loader's require('tracks.synthetic_oval') resolves
  -- it (it is not a file on disk).
  package.loaded["tracks.synthetic_oval"] = data
  ac.__setTrack("synthetic_oval", "", data.points, data.detailCount, data.trackLength)
  H.applyPhysics(presetName)
  local car = H.makeCar(presetName, { dirty = opts.dirty })
  local sim = H.makeSim(data.trackLength, opts.roadGrip or 1.0)
  local profile, corners = painter.buildProfileForTest(car, sim, opts.roadGrip or 1.0, opts.speedMult or 1.0)

  local n = data.detailCount
  local mPerPoint = data.trackLength / n
  local pts = data.points
  local speedMult = opts.speedMult or 1.0

  local worstRunM, runLen = 0, 0
  local arm = math.max(1, math.floor(15 / mPerPoint))

  -- A detected corner is bogus if it sits on geometrically straight track (the phantom
  -- the ripple would seed). Real hairpin apexes have a small radius and don't count.
  local cornerOnStraight = 0
  for _, c in ipairs(corners) do
    local i = ((math.floor(c.apexProgress * n)) % n) + 1
    if radiusAt(pts, n, i, arm) > STRAIGHT_RADIUS then cornerOnStraight = cornerOnStraight + 1 end
  end
  for i = 1, n do
    local playerMs = pts[i][4] * speedMult / 3.6
    local vSafe = profile[i] or 999.0
    -- braking paint on a geometric straight with no real slowdown ahead = false red
    local flagged = false
    if playerMs > vSafe + 0.5 and radiusAt(pts, n, i, arm) > STRAIGHT_RADIUS then
      local lookM = playerMs * playerMs / (2 * 5.0) + 80
      local lookPts = math.min(n - 1, math.ceil(lookM / mPerPoint))
      local sHere, minAhead, hard = pts[i][4], pts[i][4], false
      for w = 0, lookPts do
        local j = ((i + w - 1) % n) + 1
        if pts[j][4] < minAhead then minAhead = pts[j][4] end
        if pts[j][6] > 0.30 then hard = true end
      end
      flagged = not (hard or (sHere - minAhead) >= 20.0)
    end
    if flagged then
      runLen = runLen + 1
    else
      if runLen > 0 then worstRunM = math.max(worstRunM, runLen * mPerPoint) end
      runLen = 0
    end
  end
  if runLen > 0 then worstRunM = math.max(worstRunM, runLen * mPerPoint) end

  return {
    cornerCount = #corners,
    cornerOnStraight = cornerOnStraight,
    worstFalseRedM = worstRunM,
    pass = (worstRunM < 15.0) and (cornerOnStraight == 0),
  }
end

return H
