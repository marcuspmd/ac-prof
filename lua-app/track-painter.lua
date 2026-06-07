-- 3D Track Paint rendering for Race Coach Overlay
local config = require('config')
local physics = require('physics-calc')
local aiLoader = require('ai-loader')
local logger = require('logger')
local M = {}

local racingPainter = ac.TrackPaint()
racingPainter.forceRecast = true
racingPainter.ageFactor = 0.1
racingPainter.bulgeFactor = 0.4

local brakingPainter = ac.TrackPaint()
brakingPainter.forceRecast = true
brakingPainter.ageFactor = 0.1
brakingPainter.bulgeFactor = 0.4

local accelerationPainter = ac.TrackPaint()
accelerationPainter.forceRecast = true
accelerationPainter.ageFactor = 0.1
accelerationPainter.bulgeFactor = 0.4

local allTrackCorners = {}
local isTrackScanned = false
local lastTrackLength = 0
local maxObservedSpeedKmh = 0

-- Cache variables for the pre-calculated safe speed profile
M.safeSpeedProfile = {}
local lastSpeedMult = -1
local lastMaxObservedDecelG = -1
local lastRoadGrip = -1

-- Helper function to interpolate between two rgbm colors
local function lerpColor(c1, c2, t)
  return rgbm(
    c1.r + (c2.r - c1.r) * t,
    c1.g + (c2.g - c1.g) * t,
    c1.b + (c2.b - c1.b) * t,
    c1.mult + (c2.mult - c1.mult) * t
  )
end

-- Map a speed delta (actual - local ideal in km/h) to a smooth color gradient
local function getSpeedRelativeColor(deltaKmh)
  local cDarkGreen = rgbm(0, 0.4, 0, 0.6)
  local cLightGreen = rgbm(0.2, 0.9, 0.2, 0.6)
  local cLightYellow = rgbm(0.9, 0.9, 0.2, 0.6)
  local cDarkYellow = rgbm(0.9, 0.6, 0, 0.6)
  local cLightRed = rgbm(0.9, 0.2, 0.2, 0.6)
  local cDarkRed = rgbm(0.5, 0, 0, 0.7)

  if deltaKmh <= -10 then
    return cDarkGreen
  elseif deltaKmh > -10 and deltaKmh <= -3 then
    local t = (deltaKmh - (-10)) / (-3 - (-10))
    return lerpColor(cDarkGreen, cLightGreen, t)
  elseif deltaKmh > -3 and deltaKmh <= 0 then
    local t = (deltaKmh - (-3)) / (0 - (-3))
    return lerpColor(cLightYellow, cDarkYellow, t)
  elseif deltaKmh > 0 and deltaKmh <= 12 then
    local t = (deltaKmh - 0) / (12 - 0)
    return lerpColor(cLightRed, cDarkRed, t)
  else
    return cDarkRed
  end
end

-- Helper function to pre-scan track spline for corners on session startup
-- Uses the AI speed profile and braking/throttle triggers to detect real apexes
local function preScanTrackCorners(sim)
  if not sim or not sim.trackLengthM or sim.trackLengthM <= 100 then return M end
  
  local trackLength = sim.trackLengthM
  
  -- Make sure AI line is loaded
  aiLoader.loadAiLine()
  
  allTrackCorners = {}
  
  local detailCount = aiLoader.detailCount
  if detailCount <= 0 then return end
  
  local mPerPoint = trackLength / detailCount
  local w1 = math.max(2, math.floor(8 / mPerPoint)) -- 8m window
  local w2 = math.max(5, math.floor(15 / mPerPoint)) -- 15m window
  local lookBackWindow = math.max(5, math.floor(40 / mPerPoint))
  
  local detectedApexes = {} -- map: idx -> speedKmh
  
  local function runScanPass(windowSize, dropThreshold)
    for i = 1, detailCount do
      local progress = (i - 1) / detailCount
      local _, _, speedKmh = aiLoader.getAiInputAtProgress(progress)
      
      -- Check if it's a local minimum of speed
      local isMin = true
      local maxSpeedInWindow = speedKmh
      for w = -windowSize, windowSize do
        if w ~= 0 then
          local checkP = (progress + w / detailCount + 1.0) % 1.0
          local _, _, wSpeedKmh = aiLoader.getAiInputAtProgress(checkP)
          if wSpeedKmh < speedKmh then
            isMin = false
            break
          end
          if wSpeedKmh > maxSpeedInWindow then
            maxSpeedInWindow = wSpeedKmh
          end
        end
      end
      
      if isMin and (maxSpeedInWindow - speedKmh) >= dropThreshold then
        -- Verify decel trigger
        local hasDecelTrigger = false
        for w = -lookBackWindow, 0 do
          local checkP = (progress + w / detailCount + 1.0) % 1.0
          local wGas, wBrake, _ = aiLoader.getAiInputAtProgress(checkP)
          if wBrake > 0.01 or wGas < 0.90 then
            hasDecelTrigger = true
            break
          end
        end
        
        if hasDecelTrigger then
          detectedApexes[i] = speedKmh
        end
      end
    end
  end
  
  -- Pass 1: 8m search for chicanes / hairpins (requires at least 0.4 km/h speed drop)
  runScanPass(w1, 0.4)
  
  -- Pass 2: 15m search for sweeping corners (requires at least 0.8 km/h speed drop)
  runScanPass(w2, 0.8)
  
  -- Collect detected apexes
  local tempApexes = {}
  for idx, speedKmh in pairs(detectedApexes) do
    table.insert(tempApexes, {
      idx = idx,
      speedKmh = speedKmh,
      progress = (idx - 1) / detailCount
    })
  end
  
  -- Sort by index
  table.sort(tempApexes, function(a, b) return a.idx < b.idx end)
  
  -- Proximity merge (< 15 meters)
  for _, current in ipairs(tempApexes) do
    if #allTrackCorners == 0 then
      table.insert(allTrackCorners, {
        idx = current.idx,
        apexProgress = current.progress,
        vTargetAI = current.speedKmh / 3.6,
        speedKmh = current.speedKmh
      })
    else
      local last = allTrackCorners[#allTrackCorners]
      local diff = current.progress - last.apexProgress
      if diff > 0.5 then diff = diff - 1.0
      elseif diff < -0.5 then diff = diff + 1.0 end
      local dist = math.abs(diff * trackLength)
      
      if dist < 15.0 then
        -- Merge: keep the slower one
        if current.speedKmh < last.speedKmh then
          last.idx = current.idx
          last.apexProgress = current.progress
          last.vTargetAI = current.speedKmh / 3.6
          last.speedKmh = current.speedKmh
        end
      else
        table.insert(allTrackCorners, {
          idx = current.idx,
          apexProgress = current.progress,
          vTargetAI = current.speedKmh / 3.6,
          speedKmh = current.speedKmh
        })
      end
    end
  end
  
  isTrackScanned = true
  logger.log(string.format("[Pre-Scan] Dual Pass + Proximity Merge: Found %d corners.", #allTrackCorners))
end

-- Pre-calculate maximum safe speed profile for the entire track to avoid runtime lookahead lag
function M.recalculateSafeSpeedProfile(car, roadGrip)
  local trackLength = lastTrackLength or 1.0
  local detailCount = aiLoader.detailCount
  if detailCount <= 0 then return end

  local maxDecelG = physics.maxObservedDecelG or 1.1
  local speedMult = M.speedMult or 1.0
  
  -- Scale corner target speeds relative to a baseline reference car of 1.3G lateral capability
  local gripRatio = math.sqrt(physics.maxObservedLatG / 1.3)
  
  -- Combination grip speed factor
  local physicsFactors = physics.getPhysicsFactors(car, car.speedMs)
  local totalGrip = roadGrip * physicsFactors.tyreGrip * physicsFactors.aeroGripMultiplier
  local gripSpeedScale = math.sqrt(math.max(0.1, totalGrip))
  local cornerSpeedBias = config.cornerSpeedBias or 1.0
  local brakingMargin = config.brakingMargin or 1.0

  -- Cache active corner targets to avoid calling physics API inside the points loop
  local activeCorners = {}
  for _, turn in ipairs(allTrackCorners) do
    local vTargetCorner = turn.vTargetAI * gripRatio * gripSpeedScale * cornerSpeedBias
    
    -- Deceleration capability at corner speed
    local brakingFactors = physics.getPhysicsFactors(car, vTargetCorner)
    local targetDecel = maxDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip) * brakingFactors.aeroGripMultiplier * brakingFactors.brakeEfficiency
    
    table.insert(activeCorners, {
      turn = turn,
      vTarget = vTargetCorner,
      targetDecel = targetDecel
    })
  end

  M.safeSpeedProfile = {}
  local reactionTime = 0.3

  for i = 1, detailCount do
    local p = (i - 1) / detailCount
    local minVSafe = 999.0 -- infinity fallback
    
    for _, acCorner in ipairs(activeCorners) do
      local diff = acCorner.turn.apexProgress - p
      if diff > 0.5 then diff = diff - 1.0
      elseif diff < -0.5 then diff = diff + 1.0 end
      local distToApex = diff * trackLength
      
      if distToApex >= 0 then
        local vTargetCorner = acCorner.vTarget
        local targetDecel = acCorner.targetDecel
        
        -- Solve quadratic equation for physical deceleration + reaction time
        local B = targetDecel * reactionTime
        local C = -(vTargetCorner * vTargetCorner + (2 * targetDecel * distToApex) / brakingMargin)
        local vSafeCorner = -B + math.sqrt(B * B - C)
        
        if vSafeCorner < minVSafe then
          minVSafe = vSafeCorner
        end
      end
    end
    M.safeSpeedProfile[i] = minVSafe
  end

  lastSpeedMult = speedMult
  lastMaxObservedDecelG = maxDecelG
  lastRoadGrip = roadGrip
  
  logger.log(string.format("[Safe Speed Profile] Recalculated for %d points. activeCorners: %d", detailCount, #activeCorners))
end

-- Render the 3D racing line and optimized braking point indicators on the track surface
function M.drawRacingLine(car, sim, nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded, maxObservedDecelG)
  local trackLength = sim and sim.trackLengthM or 1.0
  local roadGrip = sim and sim.roadGrip or 1.0

  -- If track length changes or scan has not run yet, perform pre-scan for apexes
  if not isTrackScanned or trackLength ~= lastTrackLength then
    preScanTrackCorners(sim)
    lastTrackLength = trackLength
    maxObservedSpeedKmh = 0 -- Reset speed calibration on new session/track!
    lastSpeedMult = -1
    lastMaxObservedDecelG = -1
    lastRoadGrip = -1
  end

  -- Make sure AI line is loaded
  aiLoader.loadAiLine()

  local carSpeedKmh = car.speedMs * 3.6
  local aiMaxSpeed = aiLoader.aiMaxSpeedKmh or 100
  if aiMaxSpeed < 10 then aiMaxSpeed = 100 end

  -- Initialize maxObservedSpeedKmh with a smart class-based performance guess at start
  if maxObservedSpeedKmh < 10 then
    local playerTopSpeedGuess = 180
    local successDrs, drs = pcall(function() return car.drsPresent end)
    local successOpen, open = pcall(function() return car.isOpenWheeler end)
    local successRacing, racing = pcall(function() return car.isRacingCar end)
    if successDrs and drs then
      playerTopSpeedGuess = 320
    elseif successOpen and open then
      playerTopSpeedGuess = 280
    elseif successRacing and racing then
      playerTopSpeedGuess = 240
    end
    maxObservedSpeedKmh = playerTopSpeedGuess
  end

  local speedMult = maxObservedSpeedKmh / aiMaxSpeed

  -- Local dynamic calibration at full throttle on straights to prevent speed-trap deadlock
  local aiGas, aiBrake, aiSpeedKmh = aiLoader.getAiInputAtProgress(car.splinePosition)
  if car.gas > 0.90 and aiGas > 0.90 and aiBrake < 0.01 and aiSpeedKmh > 50.0 and carSpeedKmh > 80.0 then
    local localMult = carSpeedKmh / aiSpeedKmh
    if localMult > speedMult then
      maxObservedSpeedKmh = math.max(maxObservedSpeedKmh, localMult * aiMaxSpeed)
      speedMult = maxObservedSpeedKmh / aiMaxSpeed
      physics.speedMult = speedMult
      logger.log(string.format("[Calibration] Local scale update: speedMult = %.2f (localMult = %.2f)", speedMult, localMult))
    end
  end

  -- Global top speed calibration fallback
  if carSpeedKmh > maxObservedSpeedKmh + 2.0 then
    maxObservedSpeedKmh = carSpeedKmh
    speedMult = maxObservedSpeedKmh / aiMaxSpeed
    physics.speedMult = speedMult
    logger.log(string.format("[Calibration] New Player Max Speed = %.1f km/h, AI Max Speed = %.1f km/h, Multiplier = %.2f", maxObservedSpeedKmh, aiMaxSpeed, speedMult))
  end

  physics.speedMult = speedMult
  M.speedMult = speedMult

  -- Check if calibration or physics factors changed enough to warrant profile recalculation
  local currentMaxDecelG = physics.maxObservedDecelG
  if math.abs(speedMult - lastSpeedMult) > 0.01 or
     math.abs(currentMaxDecelG - lastMaxObservedDecelG) > 0.02 or
     math.abs(roadGrip - lastRoadGrip) > 0.02 or
     #M.safeSpeedProfile == 0 then
    M.recalculateSafeSpeedProfile(car, roadGrip)
  end

  -- Reset all painters
  racingPainter:reset()
  brakingPainter:reset()
  accelerationPainter:reset()

  local lookAheadDistance = math.max(400, math.min(800, car.speedMs * 10))
  local detailCount = aiLoader.detailCount

  if config.showRacingLine and detailCount > 0 then
    if aiLoader.isPreCalculated then
      local carIdx = math.floor((car.splinePosition % 1.0) * detailCount) + 1
      
      -- ds is approximately trackLength / detailCount
      local ds = trackLength / detailCount
      if ds <= 0.001 then ds = 5.0 end
      
      local startOffset = -math.floor(40 / ds)
      local endOffset = math.floor(lookAheadDistance / ds)
      
      local prevPt = nil
      local prevBrakingPos = nil
      local prevAccelPos = nil
      
      for offset = startOffset, endOffset do
        local idx = ((carIdx + offset - 1) % detailCount) + 1
        local pt = aiLoader.points[idx]
        
        if pt then
          local vSafePt = M.safeSpeedProfile[idx] or 999.0
          local deltaKmh = (car.speedMs - vSafePt) * 3.6
          local color = getSpeedRelativeColor(deltaKmh)
          
          -- Smooth gas input over a 7-point window to filter out recording noise
          local sumGas = 0
          local count = 0
          for w = -3, 3 do
            local wIdx = ((idx + w - 1) % detailCount) + 1
            local wPt = aiLoader.points[wIdx]
            if wPt then
              sumGas = sumGas + wPt.gas
              count = count + 1
            end
          end
          local smoothGas = count > 0 and (sumGas / count) or pt.gas
          
          local inAnyBrakingZone = (deltaKmh > 0)
          local inAnyAccelerationZone = false
          local inAnyCoastingZone = false
          
          if inAnyBrakingZone then
            -- Braking
          elseif smoothGas > 0.05 then
            inAnyAccelerationZone = true
          else
            inAnyCoastingZone = true
          end
          
          if prevPt then
            -- Draw main racing line segment
            racingPainter:line(prevPt.worldPos, pt.worldPos, color, 0.5)
            
            -- Draw braking zone (Red line offset to the Left side)
            if inAnyBrakingZone then
              local brakingWorldPos = pt.worldPos + pt.perp * 0.6
              if prevBrakingPos then
                brakingPainter:line(prevBrakingPos, brakingWorldPos, rgbm(1, 0, 0, 0.75), 0.15)
              end
              prevBrakingPos = brakingWorldPos
            else
              prevBrakingPos = nil
            end
            
            -- Draw acceleration / coasting zone (Green / Light Blue line offset to the Right side)
            if inAnyAccelerationZone or inAnyCoastingZone then
              local sideColor = inAnyAccelerationZone and rgbm(0, 1, 0, 0.75) or rgbm(0.1, 0.7, 1.0, 0.75)
              local accelerationWorldPos = pt.worldPos - pt.perp * 0.6
              if prevAccelPos then
                accelerationPainter:line(prevAccelPos, accelerationWorldPos, sideColor, 0.15)
              end
              prevAccelPos = accelerationWorldPos
            else
              prevAccelPos = nil
            end
          end
          prevPt = pt
        end
      end
    else
      -- Fallback: original dynamic scan and binary reading code but unified with safeSpeedProfile
      local stepSizeMeters = 2
      local points = {}
      local idx = 1

      for d = -40, lookAheadDistance, stepSizeMeters do
        local p = car.splinePosition + d / trackLength
        if p > 1.0 then p = p - 1.0
        elseif p < 0.0 then p = p + 1.0 end
        local worldPos = ac.trackProgressToWorldCoordinate(p, true)
        if worldPos then
          local aiGas, aiBrake, aiSpeedKmh = aiLoader.getAiInputAtProgress(p)
          points[idx] = {
            p = p,
            worldPos = worldPos,
            aiGas = aiGas,
            aiBrake = aiBrake,
            aiSpeedKmh = aiSpeedKmh,
            splineIdx = math.floor((p % 1.0) * detailCount) + 1
          }
          idx = idx + 1
        end
      end

      local numPoints = #points
      if numPoints >= 2 then
        local prevPt = points[1]
        local prevBrakingPos = nil
        local prevAccelPos = nil

        for i = 2, numPoints do
          local pt = points[i]
          local worldPos = pt.worldPos

          local sIdx = pt.splineIdx
          if sIdx <= 0 then sIdx = 1
          elseif sIdx > detailCount then sIdx = detailCount end

          local vSafePt = M.safeSpeedProfile[sIdx] or 999.0
          local deltaKmh = (car.speedMs - vSafePt) * 3.6
          local color = getSpeedRelativeColor(deltaKmh)

          -- Smooth gas input over a 5-point window
          local sumGas = 0
          local count = 0
          for w = -2, 2 do
            local wIdx = i + w
            if wIdx >= 1 and wIdx <= numPoints then
              sumGas = sumGas + points[wIdx].aiGas
              count = count + 1
            end
          end
          local smoothGas = count > 0 and (sumGas / count) or pt.aiGas

          local inAnyBrakingZone = (deltaKmh > 0)
          local inAnyAccelerationZone = false
          local inAnyCoastingZone = false
          
          if inAnyBrakingZone then
            -- Braking
          elseif smoothGas > 0.05 then
            inAnyAccelerationZone = true
          else
            inAnyCoastingZone = true
          end

          -- Draw main racing line segment
          racingPainter:line(prevPt.worldPos, worldPos, color, 0.5)

          -- Calculate perpendicular offset vector for dual-side lines
          local perpendicular = nil
          if inAnyBrakingZone or inAnyAccelerationZone or inAnyCoastingZone then
            local tangent = worldPos - prevPt.worldPos
            tangent.y = 0
            local tangentLen = tangent:length()
            if tangentLen > 0.001 then
              perpendicular = vec3(-tangent.z, 0, tangent.x) * (1 / tangentLen)
            end
          end

          -- Draw braking zone (Red line offset to the Left side)
          if inAnyBrakingZone and perpendicular then
            local brakingWorldPos = worldPos + perpendicular * 0.6
            if prevBrakingPos then
              brakingPainter:line(prevBrakingPos, brakingWorldPos, rgbm(1, 0, 0, 0.75), 0.15)
            end
            prevBrakingPos = brakingWorldPos
          else
            prevBrakingPos = nil
          end

          -- Draw acceleration / coasting zone (Green / Light Blue line offset to the Right side)
          if (inAnyAccelerationZone or inAnyCoastingZone) and perpendicular then
            local sideColor = inAnyAccelerationZone and rgbm(0, 1, 0, 0.75) or rgbm(0.1, 0.7, 1.0, 0.75)
            local accelerationWorldPos = worldPos - perpendicular * 0.6
            if prevAccelPos then
              accelerationPainter:line(prevAccelPos, accelerationWorldPos, sideColor, 0.15)
            end
            prevAccelPos = accelerationWorldPos
          else
            prevAccelPos = nil
          end

          prevPt = pt
        end
      end
    end
  end

  -- Draw Apex marking for the closest upcoming turn only (using pre-scanned corners)
  if config.drawEntryApexExit then
    local closestTurn = nil
    local minUpcomingDist = 9999

    for _, turn in ipairs(allTrackCorners) do
      local diff = turn.apexProgress - car.splinePosition
      if diff > 0.5 then diff = diff - 1.0
      elseif diff < -0.5 then diff = diff + 1.0 end
      local distToApex = diff * trackLength

      -- Draw markings for the turn we are approaching or currently in (up to 15m past apex)
      if distToApex > -15 and distToApex < minUpcomingDist and distToApex < 400 then
        minUpcomingDist = distToApex
        closestTurn = turn
      end
    end

    if closestTurn then
      local turn = closestTurn
      local distToApex = minUpcomingDist
      local apexWorldPos = ac.trackProgressToWorldCoordinate(turn.apexProgress, true)

      if apexWorldPos then
        -- Apex point (Gold circle)
        local apexColor = rgbm(1, 0.8, 0, 0.8) -- Gold/Yellow
        if distToApex < 15 then
          apexColor = rgbm(0, 0.9, 0.2, 0.8) -- Light Green when passing the apex
        end
        racingPainter:circle(apexWorldPos, 1.2, false, apexColor)
      end
    end
  end
end

return M
