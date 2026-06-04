-- Telemetry recording module for post-race review
local physics = require('physics-calc')

local M = {}

-- Vehicle constants (dynamics configuration)
local WHEELBASE = 2.65
local MAX_STEER_RAD = 0.45
local SLIP_ANGLE_PEAK = 7.0

-- Session state
local trackMap = nil
local lastLapCount = 0
local lastResetCounter = 0
local sampleTimer = 0
local sampleInterval = 0.1 -- 10Hz recording

-- Session buffers & metrics
local sessionLaps = {}
local sessionTimestamp = nil
local sessionFilename = nil
local sessionBestLatG = 0
local sessionBestDecelG = 0

local function initSession()
  if sessionTimestamp then return end
  
  sessionTimestamp = os.date("%Y-%m-%d %H:%M:%S")
  local safeTimestamp = os.date("%Y%m%d_%H%M%S")
  local safeTrack = (ac.getTrackID() or "track"):gsub("[^%w%-_]", "_")
  local safeCar = (ac.getCarID(0) or "car"):gsub("[^%w%-_]", "_")
  
  local scriptDir = ac.getFolder(ac.FolderID.ScriptOrigin):gsub("\\", "/")
  local logDir = scriptDir .. "/telemetry_logs"
  io.createDir(logDir)
  
  sessionFilename = string.format("%s/telemetry_%s_%s_session_%s.json", logDir, safeTrack, safeCar, safeTimestamp)
end

-- Buffers for the current lap
local lapSamples = {}
local lapCorners = {}
local sectorEndTimes = {}
local lastSector = 0

-- Helper round function
local function round(val)
  return math.floor(val + 0.5)
end

-- Helper sign function
local function sign(x)
  return x > 0 and 1 or (x < 0 and -1 or 0)
end

-- Generates coordinate map of the track (centerline, left, right borders)
local function generateTrackMap()
  local map = {
    center = {},
    left = {},
    right = {}
  }
  
  if not ac.hasTrackSpline() then
    ac.log("[Telemetry Recorder] No track AI spline available for track map generation.")
    return map
  end

  local sim = ac.getSim()
  local trackLength = sim and sim.trackLengthM or 1.0
  if trackLength <= 10.0 then return map end

  ac.log("[Telemetry Recorder] Generating track map layout...")
  
  local steps = 500 -- 500 points for a compact, high-quality outline
  local step = 1.0 / steps
  
  for i = 0, steps do
    local p = i * step
    if p > 1.0 then p = 1.0 end
    local pos = ac.trackProgressToWorldCoordinate(p, true)
    
    -- Calculate tangent and perpendicular vectors
    local dp = 0.0001
    local posNext = ac.trackProgressToWorldCoordinate(p + dp, true)
    local tangent = posNext - pos
    tangent.y = 0
    local perpendicular = vec3(-tangent.z, 0, tangent.x):normalize()
    
    -- Get track widths (X: left, Y: right)
    local widths = ac.getTrackAISplineSides(p)
    local leftWidth = widths.x
    local rightWidth = widths.y
    
    local leftPos = pos + perpendicular * leftWidth
    local rightPos = pos - perpendicular * rightWidth
    
    table.insert(map.center, { round(pos.x * 10) / 10, round(pos.z * 10) / 10 })
    table.insert(map.left, { round(leftPos.x * 10) / 10, round(leftPos.z * 10) / 10 })
    table.insert(map.right, { round(rightPos.x * 10) / 10, round(rightPos.z * 10) / 10 })
  end

  ac.log("[Telemetry Recorder] Track map generated successfully with " .. #map.center .. " samples.")
  return map
end

-- Understeer physical check
local function checkUndersteer(car, avgFrontSlip, avgRearSlip)
  if car.speedMs > 8.0 and math.abs(car.steer) > 0.15 then
    local steerNormalized = 0
    if car.steerLock and car.steerLock > 0 then
      steerNormalized = car.steer / car.steerLock
    else
      steerNormalized = car.steer / 20.0
    end
    
    local steerRad = steerNormalized * MAX_STEER_RAD
    local expectedYawRaw = (car.speedMs * steerRad) / WHEELBASE
    
    local sim = ac.getSim()
    local roadGrip = sim and sim.roadGrip or 1.0
    local maxPhysicalYaw = (1.35 * 9.81 * math.max(0.1, roadGrip)) / math.max(car.speedMs, 1.0)
    
    local expectedYaw = math.min(math.abs(expectedYawRaw), maxPhysicalYaw) * sign(steerRad)
    local yawRate = car.localAngularVelocity.y
    local yawDelta = math.abs(expectedYaw) - math.abs(yawRate)
    
    if yawDelta > 0.15 and avgFrontSlip > SLIP_ANGLE_PEAK * 1.2 and avgFrontSlip > avgRearSlip then
      return round(yawDelta * 100) / 100
    end
  end
  return 0
end

-- Oversteer physical check
local function checkOversteer(car, avgRearSlip)
  local yawRate = car.localAngularVelocity.y
  if math.abs(yawRate) > 0.15 and car.speedMs > 10.0 then
    local steerNormalized = 0
    if car.steerLock and car.steerLock > 0 then
      steerNormalized = car.steer / car.steerLock
    else
      steerNormalized = car.steer / 20.0
    end
    
    local counterSteer = sign(steerNormalized) ~= sign(yawRate)
    if counterSteer and avgRearSlip > SLIP_ANGLE_PEAK * 1.2 then
      return round(avgRearSlip * 100) / 100
    end
  end
  return 0
end

-- Wheel spin check (high positive slip ratio on power)
local function checkWheelSpin(car)
  if car.gas > 0.1 then
    local maxSpin = 0
    for i = 0, 3 do
      local tyre = car.wheels[i]
      if tyre and tyre.slipRatio > 0.15 then
        if tyre.slipRatio > maxSpin then
          maxSpin = tyre.slipRatio
        end
      end
    end
    if maxSpin > 0 then
      return round(maxSpin * 100) / 100
    end
  end
  return 0
end

-- Lockup check (high negative slip ratio on heavy braking)
local function checkLockup(car)
  if car.brake > 0.15 then
    local maxLock = 0
    for i = 0, 3 do
      local tyre = car.wheels[i]
      if tyre and tyre.slipRatio < -0.22 then
        local val = -tyre.slipRatio
        if val > maxLock then
          maxLock = val
        end
      end
    end
    if maxLock > 0 then
      return round(maxLock * 100) / 100
    end
  end
  return 0
end

-- Scorecard calculator for corners completed
local function processCornerStats(samples, cornerAngle, maxObservedLatG)
  if #samples < 5 then return nil end

  local minSpeedMs = math.huge
  for _, s in ipairs(samples) do
    if s.speedMs < minSpeedMs then
      minSpeedMs = s.speedMs
    end
  end
  local minSpeedKmh = minSpeedMs * 3.6

  local absAngle = math.abs(cornerAngle)
  local baseTargetKmh = 3500 / (absAngle + 15) + 45
  baseTargetKmh = math.max(50, math.min(290, baseTargetKmh))
  local gripFactor = math.sqrt(math.max(0.1, samples[1].roadGrip))
  local carPerformanceFactor = math.min(1.25, math.sqrt(maxObservedLatG / 1.4))
  local targetKmh = baseTargetKmh * gripFactor * carPerformanceFactor

  local speedDiff = minSpeedKmh - targetKmh
  local speedScore = 100
  if speedDiff < 0 then
    speedScore = math.max(0, 100 - math.abs(speedDiff) * 4.5)
  else
    speedScore = math.max(0, 100 - math.abs(speedDiff) * 2.5)
  end

  local trailBrakingSamples = 0
  local perfectTrailSamples = 0
  local highBrakeSteerSamples = 0
  local earlyRelease = true

  for _, s in ipairs(samples) do
    if math.abs(s.steer) > 0.15 then
      if s.brake > 0.05 then
        earlyRelease = false
        trailBrakingSamples = trailBrakingSamples + 1
        if s.brake <= 0.3 then
          perfectTrailSamples = perfectTrailSamples + 1
        else
          highBrakeSteerSamples = highBrakeSteerSamples + 1
        end
      end
    end
  end

  local trailScore = 0
  if earlyRelease then
    trailScore = 35
  elseif trailBrakingSamples > 0 then
    local perfectRatio = perfectTrailSamples / trailBrakingSamples
    local highBrakeRatio = highBrakeSteerSamples / trailBrakingSamples
    trailScore = round(50 + 55 * perfectRatio - 35 * highBrakeRatio)
    trailScore = math.max(0, math.min(100, trailScore))
  else
    trailScore = 100
  end

  local apexTimingText = "Ideal"
  local minSpeedIndex = 1
  for i, s in ipairs(samples) do
    if s.speedMs * 3.6 == minSpeedKmh then
      minSpeedIndex = i
      break
    end
  end
  local pct = minSpeedIndex / #samples
  local insideDirection = cornerAngle > 0 and 1 or -1
  local maxInsideDev = -math.huge
  for _, s in ipairs(samples) do
    local dev = s.trackPosLat * insideDirection
    if dev > maxInsideDev then
      maxInsideDev = dev
    end
  end

  if maxInsideDev < 0.45 then
    apexTimingText = "Longe do Ápice"
  elseif pct < 0.28 then
    apexTimingText = "Ápice Cedo"
  elseif pct > 0.72 then
    apexTimingText = "Ápice Atrasado"
  else
    apexTimingText = "Perfeito"
  end

  local totalEff = 0
  for _, s in ipairs(samples) do
    local g = math.sqrt(s.accG.x * s.accG.x + s.accG.z * s.accG.z)
    local eff = g / maxObservedLatG
    totalEff = totalEff + eff
  end
  local avgGripUtil = round((totalEff / #samples) * 100)
  local finalGripUtil = math.min(100, math.max(0, avgGripUtil))

  local gripScore = math.min(100, (finalGripUtil / 85) * 100)
  local finalScore = round((speedScore * 0.4) + (trailScore * 0.3) + (gripScore * 0.3))

  local grade = "C"
  if finalScore >= 95 then grade = "S"
  elseif finalScore >= 88 then grade = "A+"
  elseif finalScore >= 80 then grade = "A"
  elseif finalScore >= 70 then grade = "B"
  elseif finalScore >= 60 then grade = "C"
  else grade = "D" end

  return {
    grade = grade,
    score = finalScore,
    minSpeedKmh = round(minSpeedKmh * 10) / 10,
    targetSpeedKmh = round(targetKmh * 10) / 10,
    trailScore = trailScore,
    apexTiming = apexTimingText,
    gripUtilization = finalGripUtil
  }
end

-- Saves the accumulated session telemetry data to a JSON file
local function saveSessionFile(lapNumber, lapTimeMs)
  if #lapSamples == 0 then return end

  initSession()

  -- Calculate sector split times from cumulative sectorEndTimes
  local finalSectors = {}
  if #sectorEndTimes >= 1 then
    table.insert(finalSectors, sectorEndTimes[1])
    for i = 2, #sectorEndTimes do
      table.insert(finalSectors, sectorEndTimes[i] - sectorEndTimes[i-1])
    end
    -- Last sector time
    table.insert(finalSectors, lapTimeMs - sectorEndTimes[#sectorEndTimes])
  else
    -- Fallback if no sector splits captured
    table.insert(finalSectors, lapTimeMs)
  end

  -- Update session bests
  if physics.maxObservedLatG > sessionBestLatG then
    sessionBestLatG = physics.maxObservedLatG
  end
  if physics.maxObservedDecelG > sessionBestDecelG then
    sessionBestDecelG = physics.maxObservedDecelG
  end

  local lapData = {
    lapNumber = lapNumber,
    lapTimeMs = lapTimeMs,
    sectorTimes = finalSectors,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    bestLatG = round(physics.maxObservedLatG * 100) / 100,
    bestDecelG = round(physics.maxObservedDecelG * 100) / 100,
    corners = lapCorners,
    samples = lapSamples
  }

  table.insert(sessionLaps, lapData)

  local sessionData = {
    metadata = {
      trackId = ac.getTrackID() or "unknown",
      trackName = ac.getTrackName() or "Unknown Track",
      trackLayout = ac.getTrackLayout() or "",
      carId = ac.getCarID(0) or "unknown",
      carName = ac.getCarName(0) or "Unknown Car",
      timestamp = sessionTimestamp,
      bestLatG = round(sessionBestLatG * 100) / 100,
      bestDecelG = round(sessionBestDecelG * 100) / 100,
      totalLaps = #sessionLaps
    },
    trackMap = trackMap,
    laps = sessionLaps
  }

  local success, jsonStr = pcall(JSON.stringify, sessionData)
  if not success or not jsonStr then
    ac.log("[Telemetry Recorder] Failed to serialize telemetry JSON data.")
    return
  end

  io.saveAsync(sessionFilename, jsonStr, function(err)
    if err then
      ac.log("[Telemetry Recorder] Failed to save session telemetry file: " .. tostring(err))
    else
      ac.log("[Telemetry Recorder] Saved session telemetry to: " .. sessionFilename)
      ac.setMessage("Race Coach", string.format("Telemetria da volta %d gravada na sessão!", lapNumber))
    end
  end)
end

-- Corner tracking state for the current lap
local inCorner = false
local cornerStartDist = -1
local cornerAngle = 0
local currentCornerSamples = {}
local cornerStartTelemetryIndex = 0
local cornerStartProgress = 0
local cornerEntered = false
local cornerExitTimer = 0

-- Main recorder update loop
function M.update(dt)
  local car = ac.getCar(0)
  if not car then return end

  -- Initialize session if not done yet
  initSession()

  -- 1. Initialize track map once if needed
  if not trackMap then
    trackMap = generateTrackMap()
  end

  -- 2. Detect session reset/car teleportation
  if car.resetCounter > lastResetCounter then
    ac.log("[Telemetry Recorder] Car reset detected. Resetting buffers.")
    lapSamples = {}
    lapCorners = {}
    sectorEndTimes = {}
    lastSector = 0
    inCorner = false
    currentCornerSamples = {}
    lastResetCounter = car.resetCounter
    lastLapCount = car.lapCount
    return
  end

  -- 3. Detect lap completion
  if car.lapCount > lastLapCount then
    -- Save the telemetry for the completed lap if we have enough samples
    if #lapSamples > 50 and lastLapCount > 0 then
      saveSessionFile(lastLapCount, car.previousLapTimeMs)
    end
    
    -- Clear buffers for the new lap
    lapSamples = {}
    lapCorners = {}
    sectorEndTimes = {}
    lastSector = 0
    inCorner = false
    currentCornerSamples = {}
    lastLapCount = car.lapCount
  end

  -- 4. Track sector times
  local currentSec = car.currentSector
  if currentSec > lastSector then
    -- Sector has increased, capture cumulative time
    sectorEndTimes[currentSec] = car.lapTimeMs
    lastSector = currentSec
  end

  -- 5. Track corners for scorecard computation
  local upcomingTurn = ac.getTrackUpcomingTurn(0)
  if upcomingTurn and math.abs(upcomingTurn.y) < 12 then
    upcomingTurn = nil
  end
  local dist = upcomingTurn and upcomingTurn.x or -1
  local angle = upcomingTurn and upcomingTurn.y or 0

  if not inCorner then
    if dist > 0 and dist < 80 then
      inCorner = true
      cornerStartDist = dist
      cornerAngle = angle
      currentCornerSamples = {}
      cornerStartTelemetryIndex = #lapSamples
      cornerStartProgress = car.splinePosition
      cornerEntered = false
      cornerExitTimer = 0
    end
  else
    -- We are in the corner tracking phase
    local sim = ac.getSim()
    local trackLength = sim and sim.trackLengthM or 1.0
    local diffProgress = car.splinePosition - cornerStartProgress
    if diffProgress > 0.5 then
      diffProgress = diffProgress - 1.0
    elseif diffProgress < -0.5 then
      diffProgress = diffProgress + 1.0
    end
    local distTraveled = diffProgress * trackLength

    -- Check if we entered the corner
    if not cornerEntered then
      if dist <= 0 or distTraveled > cornerStartDist then
        cornerEntered = true
      end
    end

    -- Collect corner sample
    local trackPos = ac.worldCoordinateToTrack(car.position)
    local trackPosLat = trackPos and trackPos.x or 0

    table.insert(currentCornerSamples, {
      speedMs = car.speedMs,
      roadGrip = ac.getSim() and ac.getSim().roadGrip or 1.0,
      accG = {
        x = car.acceleration and car.acceleration.x or 0,
        z = car.acceleration and car.acceleration.z or 0
      },
      brake = car.brake,
      steer = car.steer,
      trackPosLat = trackPosLat
    })

    -- Check corner exit condition
    local shouldExit = false
    if distTraveled > 200 then
      shouldExit = true
    elseif cornerEntered and distTraveled > 30 then
      local steerNormalized = 0
      if car.steerLock and car.steerLock > 0 then
        steerNormalized = car.steer / car.steerLock
      end
      local isStraight = math.abs(car.acceleration.x) < 0.20 and math.abs(steerNormalized) < 0.10
      if isStraight then
        cornerExitTimer = cornerExitTimer + dt
        if cornerExitTimer >= 0.4 then
          shouldExit = true
        end
      else
        cornerExitTimer = 0
      end
    end

    -- Chicane / successive corner check
    if not shouldExit and dist > 0 and dist < 80 and distTraveled > 30 then
      local isNewCorner = (sign(angle) ~= sign(cornerAngle)) or (dist > 30)
      if isNewCorner then
        shouldExit = true
      end
    end

    if shouldExit then
      inCorner = false
      local scorecard = processCornerStats(currentCornerSamples, cornerAngle, physics.maxObservedLatG)
      currentCornerSamples = {}
      if scorecard then
        scorecard.startIndex = cornerStartTelemetryIndex
        scorecard.endIndex = math.max(cornerStartTelemetryIndex, #lapSamples - 1)
        table.insert(lapCorners, scorecard)
        return scorecard
      end
    end
  end

  -- 6. Collect 10Hz telemetry samples (only record when car is moving)
  sampleTimer = sampleTimer + dt
  if sampleTimer >= sampleInterval then
    sampleTimer = sampleTimer - sampleInterval
    
    if car.speedKmh > 1.0 then
      local tyres = {}
      local avgFrontSlip = 0
      local avgRearSlip = 0
      
      for i = 0, 3 do
        local tyre = car.wheels[i]
        if tyre then
          table.insert(tyres, {
            sa = round(tyre.slipAngle * 10) / 10,
            sr = round(tyre.slipRatio * 1000) / 1000
          })
          if i <= 1 then
            avgFrontSlip = avgFrontSlip + math.abs(tyre.slipAngle)
          else
            avgRearSlip = avgRearSlip + math.abs(tyre.slipAngle)
          end
        else
          table.insert(tyres, { sa = 0, sr = 0 })
        end
      end
      
      avgFrontSlip = avgFrontSlip / 2
      avgRearSlip = avgRearSlip / 2
      
      local steerNormalized = 0
      if car.steerLock and car.steerLock > 0 then
        steerNormalized = car.steer / car.steerLock
      end
      
      local trackPos = ac.worldCoordinateToTrack(car.position)
      local trackPosLat = trackPos and trackPos.x or 0
      
      local sim = ac.getSim()
      local trackTemp = sim and round(sim.roadTemperature * 10) / 10 or 0
      local ambTemp = sim and round(sim.ambientTemperature * 10) / 10 or 0
      
      -- Understeer / oversteer / spin / lockup detections
      local undVal = checkUndersteer(car, avgFrontSlip, avgRearSlip)
      local oveVal = checkOversteer(car, avgRearSlip)
      local spinVal = checkWheelSpin(car)
      local lockVal = checkLockup(car)
      
      -- Compact key-optimized sample point
      local sample = {
        t = car.lapTimeMs,
        x = round(car.position.x * 10) / 10,
        z = round(car.position.z * 10) / 10,
        speed = round(car.speedKmh * 10) / 10,
        gear = car.gear,
        rpm = round(car.rpm),
        steer = round(steerNormalized * 100) / 100,
        thr = round(car.gas * 100) / 100,
        brk = round(car.brake * 100) / 100,
        clt = round(car.clutch * 100) / 100,
        slpA = { tyres[1].sa, tyres[2].sa, tyres[3].sa, tyres[4].sa },
        slpR = { tyres[1].sr, tyres[2].sr, tyres[3].sr, tyres[4].sr },
        gLat = round(car.acceleration.x * 100) / 100,
        gLong = round(car.acceleration.z * 100) / 100,
        posLat = round(trackPosLat * 100) / 100,
        und = undVal > 0 and undVal or nil,
        ove = oveVal > 0 and oveVal or nil,
        spin = spinVal > 0 and spinVal or nil,
        lock = lockVal > 0 and lockVal or nil,
        tCore = {
          car.wheels[0] and round(car.wheels[0].tyreCoreTemperature) or 0,
          car.wheels[1] and round(car.wheels[1].tyreCoreTemperature) or 0,
          car.wheels[2] and round(car.wheels[2].tyreCoreTemperature) or 0,
          car.wheels[3] and round(car.wheels[3].tyreCoreTemperature) or 0
        },
        tGrip = {
          car.wheels[0] and round(car.wheels[0].surfaceGrip * 100) / 100 or 0,
          car.wheels[1] and round(car.wheels[1].surfaceGrip * 100) / 100 or 0,
          car.wheels[2] and round(car.wheels[2].surfaceGrip * 100) / 100 or 0,
          car.wheels[3] and round(car.wheels[3].surfaceGrip * 100) / 100 or 0
        },
        rTemp = trackTemp,
        aTemp = ambTemp
      }
      
      table.insert(lapSamples, sample)
    end
  end
end

return M
