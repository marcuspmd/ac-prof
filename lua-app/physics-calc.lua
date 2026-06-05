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
-- Automatically calibrate session G limits based on vehicle behavior with crash/off-track filtering
function M.updateGLimits(car)
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

  -- Calibrate lateral G-forces (capped at 5.0G to filter out curb spikes/glitches)
  local acc = safeGet(car, "acceleration", nil)
  local accX = acc and math.abs(acc.x) or 0
  M.smoothedLatG = M.smoothedLatG + (accX - M.smoothedLatG) * 0.3
  if M.smoothedLatG > M.maxObservedLatG and M.smoothedLatG < 5.0 then
    M.maxObservedLatG = M.smoothedLatG
  end

  -- Calibrate deceleration G-forces (capped at 5.0G to filter out curb spikes/glitches)
  local accZ = acc and acc.z or 0
  local decelG = -accZ
  if car.brake > 0.5 then
    M.smoothedDecelG = M.smoothedDecelG + (decelG - M.smoothedDecelG) * 0.3
    if M.smoothedDecelG > M.maxObservedDecelG and M.smoothedDecelG < 5.0 then
      M.maxObservedDecelG = M.smoothedDecelG
    end
  else
    M.smoothedDecelG = M.smoothedDecelG + (0 - M.smoothedDecelG) * 0.3
  end

  -- Calibrate acceleration G-forces (capped at 2.0G to filter out spikes/glitches)
  local accelG = accZ
  if car.gas > 0.8 then
    M.smoothedAccelG = M.smoothedAccelG + (accelG - M.smoothedAccelG) * 0.3
    if M.smoothedAccelG > M.maxObservedAccelG and M.smoothedAccelG < 2.0 then
      M.maxObservedAccelG = M.smoothedAccelG
    end
  else
    M.smoothedAccelG = M.smoothedAccelG + (0 - M.smoothedAccelG) * 0.3
  end
end

-- Calculate target speed and required braking distance for a specific angle
function M.calculateTurnPhysicsForAngle(car, angle, roadGrip, speedMs)
  local absAngle = math.abs(angle)
  local baseTargetKmh = 850 / math.sqrt(math.max(1.0, absAngle))
  baseTargetKmh = math.max(50, math.min(290, baseTargetKmh))

  -- Grip factor based on road conditions (stable)
  local gripFactor = math.sqrt(math.max(0.1, roadGrip))
  
  -- Performance factor based on observed limits (capped at 1.8G equivalent)
  local basePerformanceFactor = math.min(1.8, math.sqrt(M.maxObservedLatG / 1.4))

  -- Estimate target speed without downforce/tyre conditions to break circular dependency
  local estimatedTargetKmh = baseTargetKmh * gripFactor * basePerformanceFactor * config.cornerSpeedBias
  local estimatedTargetMs = estimatedTargetKmh / 3.6

  -- Calculate physics factors at the estimated corner speed (downforce and current tyres state)
  local factors = M.getPhysicsFactors(car, estimatedTargetMs)
  
  -- Performance factor adjusted by aero and tyre grip state
  local carPerformanceFactor = basePerformanceFactor * math.sqrt(factors.aeroGripMultiplier) * math.sqrt(factors.tyreGrip)
  
  local vTargetKmh = baseTargetKmh * gripFactor * carPerformanceFactor * config.cornerSpeedBias
  local vTarget = vTargetKmh / 3.6

  -- Braking deceleration adjusted by observed decel limit, road grip, average braking aero multiplier, and brake efficiency
  local avgBrakingSpeedMs = (speedMs + vTarget) / 2
  local brakingFactors = M.getPhysicsFactors(car, avgBrakingSpeedMs)
  local targetDecel = M.maxObservedDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip) * brakingFactors.aeroGripMultiplier * brakingFactors.brakeEfficiency
  
  local reactionDistance = speedMs * 0.3

  local physicalBrakingDistance = 0
  if speedMs > vTarget then
    physicalBrakingDistance = (speedMs * speedMs - vTarget * vTarget) / (2 * targetDecel)
  end
  local totalBrakingDistanceNeeded = (physicalBrakingDistance + reactionDistance) * config.brakingMargin

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
      local targetDecel = M.maxObservedDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip) * brakingFactors.aeroGripMultiplier * brakingFactors.brakeEfficiency
      local reactionDistance = car.speedMs * 0.3
      local physicalBrakingDistance = 0
      if car.speedMs > vTarget then
        physicalBrakingDistance = (car.speedMs * car.speedMs - vTarget * vTarget) / (2 * targetDecel)
      end
      totalBrakingDistanceNeeded = (physicalBrakingDistance + reactionDistance) * config.brakingMargin
    end
  end

  return nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded
end

return M
