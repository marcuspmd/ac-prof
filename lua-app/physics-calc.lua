-- Physics calculations and G-Force auto-calibration for Race Coach Overlay
local config = require('config')
local M = {}

-- Peak G-forces observed during the session (starts with sensible defaults)
M.maxObservedLatG = 1.4
M.maxObservedDecelG = 1.1
M.maxObservedAccelG = 0.5

-- Smooth values for calibration (starts at baseline to prevent initial catch-up delay)
M.smoothedLatG = 1.3
M.smoothedDecelG = 1.0
M.smoothedAccelG = 0.4

M.speedMult = 1.0

-- Helper to safely access object fields that might not exist in older CSP versions
local function safeGet(obj, field, default)
  if not obj then return default end
  local success, val = pcall(function() return obj[field] end)
  if success and val ~= nil then
    return val
  end
  return default
end

-- Get real-time factors for tyre grip, brake efficiency, and aerodynamic downforce
function M.getPhysicsFactors(car, speedMs)
  local tyresCount = 0
  local totalTyreGrip = 0
  local totalBrakeEff = 0
  local hasBrakeSim = false

  if car.wheels then
    for i = 0, 3 do
      local wheel = car.wheels[i]
      if wheel then
        tyresCount = tyresCount + 1

        -- 1. Tyre Temperature Factor: bell curve around optimum temp
        local tCore = safeGet(wheel, "tyreCoreTemperature", 0)
        local tOpt = safeGet(wheel, "tyreOptimumTemperature", 0)
        if tOpt <= 0 then tOpt = 85 end -- Default fallback for missing data

        local tempDiff = math.abs(tCore - tOpt)
        local tFactor = 1.0 - math.min(0.25, (tempDiff / 40.0) ^ 2 * 0.25)

        -- 2. Tyre Wear Factor: linear drop off
        local tWear = safeGet(wheel, "tyreWear", 1.0)
        local wFactor = 0.85 + 0.15 * tWear

        -- 2b. Tyre Dirt Factor: loss of grip if tyres went off-track (grass/sand)
        local tDirt = safeGet(wheel, "tyreDirty", 0)
        local dFactor = 1.0 - math.min(0.30, tDirt * 0.30)

        totalTyreGrip = totalTyreGrip + (tFactor * wFactor * dFactor)

        -- 3. Brake Temperature Factor: cold brakes and brake fade
        local bTemp = safeGet(wheel, "brakeTemperature", 0)
        if bTemp > 15 then
          hasBrakeSim = true
          local bFactor = 1.0
          if bTemp < 150 then
            -- Cold brakes: linear drop from 1.0 down to 0.80 at 20C
            local t = math.max(0, (bTemp - 20) / 130)
            bFactor = 0.80 + 0.20 * t
          elseif bTemp > 600 then
            -- Hot brakes / Fade: linear drop from 1.0 at 600C to 0.65 at 850C
            local t = math.min(1.0, (bTemp - 600) / 250)
            bFactor = 1.0 - 0.35 * t
          end
          totalBrakeEff = totalBrakeEff + bFactor
        end
      end
    end
  end

  local tyreGrip = tyresCount > 0 and (totalTyreGrip / tyresCount) or 1.0
  local brakeEfficiency = (hasBrakeSim and tyresCount > 0) and (totalBrakeEff / tyresCount) or 1.0

  -- 4. Aerodynamic Grip Multiplier (Downforce)
  local aeroGripMultiplier = 1.0
  speedMs = speedMs or car.speedMs or 0
  if speedMs > 1.0 then
    local liftFront = safeGet(car, "aeroLiftFront", 0)
    local liftRear = safeGet(car, "aeroLiftRear", 0)
    
    -- In Assetto Corsa, mod cars can have extremely large lift forces (in N) or lift coefficients (CL).
    -- We cap kDownforce to a maximum CL equivalent of 6.0 to prevent physics bugs or mod misconfiguration.
    -- If lift values are huge (representing Newtons), we scale them down.
    local rawDownforce = -(liftFront + liftRear)
    if rawDownforce > 50 then
      -- It's a force in Newtons. Scale down to a reasonable equivalent coefficient.
      rawDownforce = rawDownforce / 1000
    end

    local kDownforce = math.min(6.0, math.max(0, rawDownforce))

    -- Vertical load increases with speed squared.
    -- Let's normalize it so that at 250 km/h (approx 70 m/s), kDownforce of 3.0 gives 30% extra vertical load.
    local speedFactor = math.min(70, speedMs) / 70
    local verticalLoadIncrease = (kDownforce * 0.10) * (speedFactor * speedFactor)
    
    -- Cap the maximum grip increase to 40% (aeroGripMultiplier = 1.4) to keep it safe and realistic
    aeroGripMultiplier = math.min(1.4, 1.0 + verticalLoadIncrease)
  end

  return {
    tyreGrip = tyreGrip,
    brakeEfficiency = brakeEfficiency,
    aeroGripMultiplier = aeroGripMultiplier
  }
end

-- Restore persisted G-limits from a previous session. Limits only ratchet upward
-- in-session, so taking the max of saved vs current is always safe.
function M.restoreGLimits(lat, decel, accel)
  if type(lat) == "number" and lat > M.maxObservedLatG then
    M.maxObservedLatG = lat
    M.smoothedLatG = lat
  end
  if type(decel) == "number" and decel > M.maxObservedDecelG then
    M.maxObservedDecelG = decel
    M.smoothedDecelG = decel
  end
  if type(accel) == "number" and accel > M.maxObservedAccelG then
    M.maxObservedAccelG = accel
    M.smoothedAccelG = accel
  end
end

local isLimitsInitialized = false
function M.initializeCarLimits(car)
  if isLimitsInitialized then return end
  
  if safeGet(car, "isOpenWheeler", false) then
    M.maxObservedLatG = 2.1
    M.maxObservedDecelG = 1.5
    M.maxObservedAccelG = 0.8
  elseif safeGet(car, "isRacingCar", false) then
    M.maxObservedLatG = 1.4
    M.maxObservedDecelG = 1.1
    M.maxObservedAccelG = 0.55
  else
    M.maxObservedLatG = 1.05
    M.maxObservedDecelG = 0.9
    M.maxObservedAccelG = 0.35
  end
  
  M.smoothedLatG = M.maxObservedLatG
  M.smoothedDecelG = M.maxObservedDecelG
  M.smoothedAccelG = M.maxObservedAccelG
  
  isLimitsInitialized = true
end

-- Automatically calibrate session G limits based on vehicle behavior with crash/off-track filtering
function M.updateGLimits(car)
  M.initializeCarLimits(car)

  -- 1. Ignore updates during collisions to filter out G spikes
  local collisionDepth = safeGet(car, "collisionDepth", 0)
  if collisionDepth > 0.01 then
    return
  end

  -- 2. Ignore updates if the car is mostly off-track (on grass/gravel, hitting barriers)
  if car.wheels then
    local offTrackCount = 0
    for i = 0, 3 do
      local wheel = car.wheels[i]
      local surfaceValid = safeGet(wheel, "surfaceValidTrack", true)
      if wheel and not surfaceValid then
        offTrackCount = offTrackCount + 1
      end
    end
    if offTrackCount >= 2 then
      return
    end
  end

  -- Define realistic maximum safety ceilings based on car class
  local maxLatCap = 1.3
  local maxDecelCap = 1.15
  if safeGet(car, "isOpenWheeler", false) then
    maxLatCap = 2.8
    maxDecelCap = 2.0
  elseif safeGet(car, "isRacingCar", false) then
    maxLatCap = 1.8
    maxDecelCap = 1.45
  end

  local acc = safeGet(car, "acceleration", nil)

  -- Calibrate lateral G-forces. Filter rate 0.015 converges ~84% of peak in a 2s corner at 60fps.
  local accX = acc and math.abs(acc.x) or 0
  M.smoothedLatG = M.smoothedLatG + (accX - M.smoothedLatG) * 0.015
  if M.smoothedLatG > M.maxObservedLatG and M.smoothedLatG < maxLatCap then
    M.maxObservedLatG = M.smoothedLatG
  end

  -- Calibrate deceleration G-forces. Hold last value between braking events so the next
  -- corner starts from a useful baseline instead of decaying to zero on every straight.
  local accZ = acc and acc.z or 0
  local decelG = -accZ
  if car.brake > 0.5 then
    M.smoothedDecelG = M.smoothedDecelG + (decelG - M.smoothedDecelG) * 0.015
    if M.smoothedDecelG > M.maxObservedDecelG and M.smoothedDecelG < maxDecelCap then
      M.maxObservedDecelG = M.smoothedDecelG
    end
  end

  -- Calibrate acceleration G-forces. Same hold-last-value approach.
  local accelG = accZ
  if car.gas > 0.8 then
    M.smoothedAccelG = M.smoothedAccelG + (accelG - M.smoothedAccelG) * 0.015
    if M.smoothedAccelG > M.maxObservedAccelG and M.smoothedAccelG < 2.0 then
      M.maxObservedAccelG = M.smoothedAccelG
    end
  end
end

-- Tyre load sensitivity exponent. In AC's sim tyre model the grip coefficient µ FALLS
-- as vertical load rises (the LS_EXPY curve, typically 0.10–0.25), so extra load from
-- aero downforce yields diminishing grip — never the full linear gain an arcade
-- v=sqrt(µgR) model assumes. This is the single biggest "arcade vs sim" difference.
local TYRE_LOAD_SENSITIVITY = 0.20

-- Solve maximum corner speed from the geometric radius using available lateral grip.
-- Aero downforce depends on speed, so fixed-point iterate until it settles.
function M.solveCornerSpeed(car, radiusM, roadGrip)
  if not radiusM or radiusM <= 0 then return nil end

  -- Tyre temp/wear/dirt factors are speed-independent; aero is resolved in the loop
  local tyreFactors = M.getPhysicsFactors(car, 0)
  local latGBase = M.maxObservedLatG * math.max(0.1, roadGrip) * tyreFactors.tyreGrip

  local v = math.sqrt(latGBase * 9.81 * radiusM)
  for _ = 1, 4 do
    local aeroMult = M.getPhysicsFactors(car, v).aeroGripMultiplier
    -- Load-sensitivity-corrected aero grip: the load multiplier (1+r) only converts to
    -- grip as (1+r)^(1-LS), so downforce gives diminishing — not linear — returns.
    local effectiveAero = aeroMult ^ (1.0 - TYRE_LOAD_SENSITIVITY)
    v = math.sqrt(latGBase * effectiveAero * 9.81 * radiusM)
  end

  -- Usable-grip margin (8%). The geometric radius is the drawn line's centreline and the
  -- calibrated latG is a near-peak value; neither is sustainable to the last percent. For
  -- a coaching line, staying on the achievable side of the limit (the car holds the corner)
  -- matters more than shaving the final tenth.
  return v * 0.92
end

-- Required braking distance to slow from speedMs to vTarget (shared by the angle
-- heuristic and by corner-based targets from the track scan)
function M.brakingDistanceTo(car, speedMs, vTarget, roadGrip, absAngle)
  if speedMs <= vTarget then return 0 end

  local avgBrakingSpeedMs = (speedMs + vTarget) / 2
  local brakingFactors = M.getPhysicsFactors(car, avgBrakingSpeedMs)
  local targetDecel = M.maxObservedDecelG * 9.81 * config.brakeIntensityFactor * math.max(0.5, roadGrip) * brakingFactors.aeroGripMultiplier * brakingFactors.brakeEfficiency

  local physicalBrakingDistance = (speedMs * speedMs - vTarget * vTarget) / (2 * targetDecel)
  local reactionDistance = speedMs * 0.15 * config.reactionMargin

  -- Adjustment for trail braking phase (from corner entry to apex)
  -- Deceleration is lower during turn-in, so we must brake earlier.
  local trailDist = math.max(12, math.min(45, 12 + (absAngle or 45) * 0.2))
  local trailAdjustment = trailDist * (1.0 - config.trailBrakingFactor)

  return (physicalBrakingDistance + reactionDistance + trailAdjustment) * config.brakingMargin
end

-- Calculate target speed and required braking distance for a specific angle
function M.calculateTurnPhysicsForAngle(car, angle, roadGrip, speedMs)
  local absAngle = math.abs(angle)
  local baseTargetKmh = 850 / math.sqrt(math.max(1.0, absAngle))
  baseTargetKmh = math.max(50, math.min(290, baseTargetKmh))

  -- Grip factor based on road conditions (stable)
  local gripFactor = math.sqrt(math.max(0.1, roadGrip))
  
  -- Lateral performance relative to the AI baseline. Decoupled from speedMult: corner speed
  -- scales with sqrt(grip), NOT with straight-line top speed. A car much faster on the
  -- straights (power/drag) can have similar mechanical grip, so coupling the two asked for
  -- impossible mid-corner speeds — the car would understeer/slide off the target line.
  local basePerformanceFactor = math.min(2.0, math.sqrt(M.maxObservedLatG / 1.4))

  -- Modo iniciante: margem extra na heurística (curvas sem alvo geométrico)
  local beginnerScale = config.beginnerMode and (config.beginnerMargin or 0.90) or 1.0

  -- Estimate target speed without downforce/tyre conditions to break circular dependency
  local estimatedTargetKmh = baseTargetKmh * gripFactor * basePerformanceFactor * config.cornerSpeedBias * beginnerScale
  local estimatedTargetMs = estimatedTargetKmh / 3.6

  -- Calculate physics factors at the estimated corner speed (downforce and current tyres state)
  local factors = M.getPhysicsFactors(car, estimatedTargetMs)
  
  -- Performance factor adjusted by aero and tyre grip state
  local carPerformanceFactor = basePerformanceFactor * math.sqrt(factors.aeroGripMultiplier) * math.sqrt(factors.tyreGrip)
  
  local vTargetKmh = baseTargetKmh * gripFactor * carPerformanceFactor * config.cornerSpeedBias * beginnerScale
  local vTarget = vTargetKmh / 3.6

  local totalBrakingDistanceNeeded = M.brakingDistanceTo(car, speedMs, vTarget, roadGrip, absAngle)

  return vTarget, totalBrakingDistanceNeeded
end

-- Calculate target speed and required braking distance for the upcoming corner
function M.calculateTurnPhysics(car, upcomingTurn, roadGrip)
  local nextTurnDist = -1
  local nextTurnAngle = 0
  if upcomingTurn then
    nextTurnDist = upcomingTurn.x
    nextTurnAngle = upcomingTurn.y
  end

  local vTarget = 0
  local totalBrakingDistanceNeeded = 0

  if nextTurnDist > 0 then
    vTarget, totalBrakingDistanceNeeded = M.calculateTurnPhysicsForAngle(car, nextTurnAngle, roadGrip, car.speedMs)

    -- Track positioning penalty (if on the wrong side of the track on entry)
    local trackPos = ac.worldCoordinateToTrack and ac.worldCoordinateToTrack(car.position)
    local pLat = trackPos and trackPos.x or 0
    local isRight = nextTurnAngle > 0
    local wrongSideFactor = isRight and pLat or -pLat
    if nextTurnDist < 60 and wrongSideFactor > 0 then
      local proximityScale = (60 - nextTurnDist) / 60
      vTarget = vTarget * (1.0 - 0.2 * wrongSideFactor * proximityScale)

      -- Recalculate braking distance with the new (lower) target speed
      local avgBrakingSpeedMs = (car.speedMs + vTarget) / 2
      local brakingFactors = M.getPhysicsFactors(car, avgBrakingSpeedMs)
      local targetDecel = M.maxObservedDecelG * 9.81 * config.brakeIntensityFactor * math.max(0.5, roadGrip) * brakingFactors.aeroGripMultiplier * brakingFactors.brakeEfficiency
      if car.speedMs > vTarget then
        local physicalBrakingDistance = (car.speedMs * car.speedMs - vTarget * vTarget) / (2 * targetDecel)
        local reactionDistance = car.speedMs * 0.3 * config.reactionMargin
        totalBrakingDistanceNeeded = (physicalBrakingDistance + reactionDistance) * config.brakingMargin
      else
        totalBrakingDistanceNeeded = 0
      end
    end
  end

  return nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded
end

return M
