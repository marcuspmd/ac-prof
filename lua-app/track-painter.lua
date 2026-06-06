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

  if deltaKmh <= -15 then
    return cDarkGreen
  elseif deltaKmh > -15 and deltaKmh <= -2 then
    local t = (deltaKmh - (-15)) / (-2 - (-15))
    return lerpColor(cDarkGreen, cLightGreen, t)
  elseif deltaKmh > -2 and deltaKmh <= 5 then
    local t = (deltaKmh - (-2)) / (5 - (-2))
    return lerpColor(cLightYellow, cDarkYellow, t)
  elseif deltaKmh > 5 and deltaKmh <= 20 then
    local t = (deltaKmh - 5) / (20 - 5)
    return lerpColor(cLightRed, cDarkRed, t)
  else
    return cDarkRed
  end
end

-- Check if progress 'p' is within the dynamic braking zone of any active corner
local function checkDynamicBraking(p, activeCorners, trackLength)
  for _, acCorner in ipairs(activeCorners) do
    local diffPt = acCorner.turn.apexProgress - p
    if diffPt > 0.5 then diffPt = diffPt - 1.0
    elseif diffPt < -0.5 then diffPt = diffPt + 1.0 end
    local distPtToApex = diffPt * trackLength

    if distPtToApex >= 0 and distPtToApex <= acCorner.brakingDist then
      return true, acCorner.vTarget
    end
  end
  return false, nil
end

-- Helper function to pre-scan track spline for corners on session startup
-- Uses the AI speed profile and braking triggers to detect real apexes
local function preScanTrackCorners(sim)
  if not sim or not sim.trackLengthM or sim.trackLengthM <= 100 then return end
  
  local trackLength = sim.trackLengthM
  
  -- Make sure AI line is loaded
  aiLoader.loadAiLine()
  
  allTrackCorners = {}
  
  local detailCount = aiLoader.detailCount
  if detailCount <= 0 then return end
  
  -- Set search windows based on point spacing (~25m apex check, ~60m braking lookback)
  local mPerPoint = trackLength / detailCount
  local windowSize = math.max(5, math.floor(25 / mPerPoint)) 
  local lookBackWindow = math.max(10, math.floor(60 / mPerPoint))
  
  local maxSpeedKmh = aiLoader.aiMaxSpeedKmh or 100
  
  for i = 1, detailCount do
    local progress = (i - 1) / detailCount
    local _, _, speedKmh = aiLoader.getAiInputAtProgress(progress)
    
    -- Check if it's a local minimum of speed (apex)
    local isMin = true
    for w = -windowSize, windowSize do
      local checkP = (progress + w / detailCount) % 1.0
      local _, _, wSpeedKmh = aiLoader.getAiInputAtProgress(checkP)
      if wSpeedKmh < speedKmh then
        isMin = false
        break
      end
    end
    
    if isMin then
      -- Verify if the AI actually brakes before this point to filter out straights
      local hasBraking = false
      for w = -lookBackWindow, 0 do
        local checkP = (progress + w / detailCount) % 1.0
        local _, wBrake, _ = aiLoader.getAiInputAtProgress(checkP)
        if wBrake > 0.01 then
          hasBraking = true
          break
        end
      end
      
      -- Ensure it is a significant corner (speed drops below 92% of top speed)
      local isRealCorner = (speedKmh < maxSpeedKmh * 0.92)
      
      if hasBraking and isRealCorner then
        table.insert(allTrackCorners, {
          apexProgress = progress,
          vTargetAI = speedKmh / 3.6
        })
      end
    end
  end
  
  -- Sort corners by progress along the track
  table.sort(allTrackCorners, function(a, b) return a.apexProgress < b.apexProgress end)
  
  isTrackScanned = true
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
  end

  -- Make sure AI line is loaded
  aiLoader.loadAiLine()

  -- Identify active upcoming corners and their dynamic braking zones
  local activeCorners = {}
  local physicsFactors = physics.getPhysicsFactors(car, car.speedMs)
  local totalGrip = roadGrip * physicsFactors.tyreGrip * physicsFactors.aeroGripMultiplier
  local gripSpeedScale = math.sqrt(math.max(0.1, totalGrip))

  if isTrackScanned and #allTrackCorners > 0 then
    for _, turn in ipairs(allTrackCorners) do
      local diff = turn.apexProgress - car.splinePosition
      if diff > 0.5 then diff = diff - 1.0
      elseif diff < -0.5 then diff = diff + 1.0 end
      local distToApex = diff * trackLength

      if distToApex > -20 and distToApex < 500 then
        -- Calculate dynamic braking zone based on player speed and AI apex speed adjusted for grip
        local vTargetCorner = turn.vTargetAI * gripSpeedScale * config.cornerSpeedBias
        
        local avgBrakingSpeedMs = (car.speedMs + vTargetCorner) / 2
        local brakingFactors = physics.getPhysicsFactors(car, avgBrakingSpeedMs)
        local targetDecel = physics.maxObservedDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip) * brakingFactors.aeroGripMultiplier * brakingFactors.brakeEfficiency
        
        local reactionDistance = car.speedMs * 0.3
        local physicalBrakingDistance = 0
        if car.speedMs > vTargetCorner then
          physicalBrakingDistance = (car.speedMs * car.speedMs - vTargetCorner * vTargetCorner) / (2 * targetDecel)
        end
        local brakingDist = (physicalBrakingDistance + reactionDistance) * config.brakingMargin
        
        table.insert(activeCorners, {
          turn = turn,
          vTarget = vTargetCorner,
          brakingDist = brakingDist
        })
      end
    end
  end

  -- 1. Reset all painters
  racingPainter:reset()
  brakingPainter:reset()
  accelerationPainter:reset()

  -- Calibrate player's max observed speed to dynamically scale the AI speed profile
  local carSpeedKmh = car.speedMs * 3.6
  if carSpeedKmh > maxObservedSpeedKmh + 2.0 then
    maxObservedSpeedKmh = carSpeedKmh
    local aiMaxSpeed = aiLoader.aiMaxSpeedKmh or 100
    local speedMult = maxObservedSpeedKmh / aiMaxSpeed
    logger.log(string.format("[Calibration] New Player Max Speed = %.1f km/h, AI Max Speed = %.1f km/h, Multiplier = %.2f", maxObservedSpeedKmh, aiMaxSpeed, speedMult))
  end

  local aiMaxSpeed = aiLoader.aiMaxSpeedKmh or 100
  if aiMaxSpeed < 10 then aiMaxSpeed = 100 end

  -- Initialize maxObservedSpeedKmh if it's too small
  if maxObservedSpeedKmh < aiMaxSpeed then
    maxObservedSpeedKmh = aiMaxSpeed
  end

  local speedMult = maxObservedSpeedKmh / aiMaxSpeed
  local lookAheadDistance = math.max(400, math.min(800, car.speedMs * 10))

  -- Initialize log counter
  if not M.logCounter then M.logCounter = 0 end
  M.logCounter = M.logCounter + 1
  local shouldLog = (M.logCounter % 120 == 0)

  -- 2. Pre-compile track coordinates in a single pass to save spline API calls
  if config.showRacingLine then
    if aiLoader.isPreCalculated then
      local detailCount = aiLoader.detailCount
      local carIdx = math.floor((car.splinePosition % 1.0) * detailCount) + 1
      
      -- ds is approximately trackLength / detailCount
      local ds = trackLength / detailCount
      if ds <= 0.001 then ds = 5.0 end
      
      local startOffset = -math.floor(40 / ds)
      local endOffset = math.floor(lookAheadDistance / ds)
      
      local prevPt = nil
      local prevBrakingPos = nil
      local prevAccelPos = nil
      
      if shouldLog then
        logger.log(string.format("[Debug] [Pre-Calculated] Car Speed: %.1f km/h, Spline Pos: %.4f, Track Length: %.1f, carIdx: %d, startOffset: %d, endOffset: %d", carSpeedKmh, car.splinePosition, trackLength, carIdx, startOffset, endOffset))
      end
      
      for offset = startOffset, endOffset do
        local idx = ((carIdx + offset - 1) % detailCount) + 1
        local pt = aiLoader.points[idx]
        
        if pt then
          local p = (idx - 1) / detailCount
          local inDynamicBraking, targetSpeedAtPt = checkDynamicBraking(p, activeCorners, trackLength)
          
          -- Smooth gas and brake inputs over a 7-point window to filter out recording noise
          local sumGas = 0
          local sumBrake = 0
          local count = 0
          for w = -3, 3 do
            local wIdx = ((idx + w - 1) % detailCount) + 1
            local wPt = aiLoader.points[wIdx]
            if wPt then
              sumGas = sumGas + wPt.gas
              sumBrake = sumBrake + wPt.brake
              count = count + 1
            end
          end
          local smoothGas = count > 0 and (sumGas / count) or pt.gas
          local smoothBrake = count > 0 and (sumBrake / count) or pt.brake
          
          -- Speed-relative color compared directly with the scaled AI speed profile
          local targetSpeedKmh = pt.speedKmh * speedMult * config.cornerSpeedBias * gripSpeedScale
          local inAnyBrakingZone = false
          local inAnyAccelerationZone = false
          local inAnyCoastingZone = false
          
          if inDynamicBraking then
            inAnyBrakingZone = true
          else
            inAnyBrakingZone = (smoothBrake > 0.01)
          end
          
          if inAnyBrakingZone then
            -- Braking
          elseif smoothGas > 0.05 and carSpeedKmh < targetSpeedKmh + 2 then
            inAnyAccelerationZone = true
          else
            inAnyCoastingZone = true
          end
          
          local deltaKmh = carSpeedKmh - targetSpeedKmh
          local color = getSpeedRelativeColor(deltaKmh)
          
          if shouldLog and offset == 0 then
            logger.log(string.format("[Debug] [Pre-Calculated] Point[0] - pt.speedKmh: %.1f km/h, targetSpeedKmh: %.1f km/h, deltaKmh: %.1f, speedMult: %.2f", pt.speedKmh, targetSpeedKmh, deltaKmh, speedMult))
          end
          
          if prevPt then
            -- Draw main racing line segment
            racingPainter:line(prevPt.worldPos, pt.worldPos, color, 0.5)
            
            -- Guide lines conditions from pre-calculated gas/brake
            -- (Using dynamic variables calculated above)
            
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
      -- Fallback: original dynamic scan and binary reading code
      local stepSizeMeters = 2
      local points = {}
      local idx = 1

      for d = -40, lookAheadDistance, stepSizeMeters do
        local p = car.splinePosition + d / trackLength
        if p > 1.0 then p = p - 1.0
        elseif p < 0.0 then p = p + 1.0 end
        local worldPos = ac.trackProgressToWorldCoordinate(p, true)
        if worldPos then
          -- Retrieve AI telemetry inputs and speed at progress p
          local aiGas, aiBrake, aiSpeedKmh = aiLoader.getAiInputAtProgress(p)
          points[idx] = {
            p = p,
            worldPos = worldPos,
            aiGas = aiGas,
            aiBrake = aiBrake,
            aiSpeedKmh = aiSpeedKmh
          }
          idx = idx + 1
        end
      end

      local numPoints = #points
      if numPoints >= 2 then
        local prevPt = points[1]
        local prevBrakingPos = nil
        local prevAccelPos = nil

        if shouldLog then
          logger.log(string.format("[Debug] [Fallback] Car Speed: %.1f km/h, Spline Pos: %.4f, Track Length: %.1f, Num Lookahead Points: %d", carSpeedKmh, car.splinePosition, trackLength, numPoints))
        end

        -- Render paths segment by segment
        for i = 2, numPoints do
          local pt = points[i]
          local worldPos = pt.worldPos

          local inDynamicBraking, targetSpeedAtPt = checkDynamicBraking(pt.p, activeCorners, trackLength)
          
          -- Smooth gas and brake inputs over a 5-point window to filter out recording noise
          local sumGas = 0
          local sumBrake = 0
          local count = 0
          for w = -2, 2 do
            local wIdx = i + w
            if wIdx >= 1 and wIdx <= numPoints then
              local wPt = points[wIdx]
              sumGas = sumGas + wPt.aiGas
              sumBrake = sumBrake + wPt.aiBrake
              count = count + 1
            end
          end
          local smoothGas = count > 0 and (sumGas / count) or pt.aiGas
          local smoothBrake = count > 0 and (sumBrake / count) or pt.aiBrake
          
          -- Speed-relative color compared directly with the scaled AI speed profile
          local targetSpeedKmh = pt.aiSpeedKmh * speedMult * config.cornerSpeedBias * gripSpeedScale
          local inAnyBrakingZone = false
          local inAnyAccelerationZone = false
          local inAnyCoastingZone = false
          
          if inDynamicBraking then
            inAnyBrakingZone = true
          else
            inAnyBrakingZone = (smoothBrake > 0.01)
          end
          
          if inAnyBrakingZone then
            -- Braking
          elseif smoothGas > 0.05 and carSpeedKmh < targetSpeedKmh + 2 then
            inAnyAccelerationZone = true
          else
            inAnyCoastingZone = true
          end

          local deltaKmh = carSpeedKmh - targetSpeedKmh
          local color = getSpeedRelativeColor(deltaKmh)

          if shouldLog and i == 2 then
            logger.log(string.format("[Debug] [Fallback] Point[2] - pt.aiSpeedKmh: %.1f km/h, targetSpeedKmh: %.1f km/h, deltaKmh: %.1f, speedMult: %.2f", pt.aiSpeedKmh, targetSpeedKmh, deltaKmh, speedMult))
          end

          -- Draw main racing line segment
          racingPainter:line(prevPt.worldPos, worldPos, color, 0.5)

          -- Guide lines conditions from AI inputs
          -- (Using dynamic variables calculated above)

          -- Calculate perpendicular offset vector for dual-side lines
          local perpendicular = nil
          if inAnyBrakingZone or inAnyAccelerationZone or inAnyCoastingZone then
            local tangent = worldPos - prevPt.worldPos
            tangent.y = 0
            local tangentLen = tangent:length()
            if tangentLen > 0.001 then
              perpendicular = vec3(-tangent.z, 0, tangent.x):scale(1 / tangentLen)
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

  -- 4. Draw Apex marking for the closest upcoming turn only (using pre-scanned corners)
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
