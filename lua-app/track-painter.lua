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

-- Helper function to pre-scan track spline for corners on session startup
local function preScanTrackCorners(sim)
  if not sim or not sim.trackLengthM or sim.trackLengthM <= 100 then return end
  
  local trackLength = sim.trackLengthM
  local stepM = 5.0 -- sample every 5 meters
  local step = stepM / trackLength
  local totalSteps = math.floor(trackLength / stepM)
  
  -- Shift scan start backwards by 200m to capture corners crossing the start/finish line continuously
  local wrapM = 200.0
  local wrapSteps = math.floor(wrapM / stepM)

  local curCandidate = nil
  local lowCurvatureSteps = 0
  local maxLowCurvatureSteps = 6 -- 30 meters low-curvature tolerance (e.g. for double-apex)
  local rawCorners = {}

  for i = -wrapSteps, totalSteps - 1 do
    local p1 = (i * step) % 1.0
    local pos1 = ac.trackProgressToWorldCoordinate(p1, true)
    
    local p0 = (p1 - step + 1.0) % 1.0
    local pos0 = ac.trackProgressToWorldCoordinate(p0, true)
    
    local p2 = (p1 + step) % 1.0
    local pos2 = ac.trackProgressToWorldCoordinate(p2, true)
    
    if pos1 and pos0 and pos2 then
      local v1 = (pos1 - pos0)
      v1.y = 0
      v1:normalize()
      
      local v2 = (pos2 - pos1)
      v2.y = 0
      v2:normalize()
      
      local dot = v1:dot(v2)
      dot = math.max(-1.0, math.min(1.0, dot))
      local angleDiff = math.deg(math.acos(dot))
      
      -- Cross product to get turn direction
      local crossY = v1.x * v2.z - v1.z * v2.x
      local turnSign = crossY >= 0 and 1 or -1
      local curvature = angleDiff * turnSign
      
      if math.abs(curvature) > 0.6 then
        local directionChanged = false
        if curCandidate then
          local currentSign = curCandidate.sumAngle >= 0 and 1 or -1
          local newSign = curvature >= 0 and 1 or -1
          if newSign ~= currentSign then
            directionChanged = true
          end
        end

        if directionChanged then
          -- Close current candidate and start new one
          if math.abs(curCandidate.sumAngle) >= 15.0 then
            table.insert(rawCorners, curCandidate)
          end
          curCandidate = {
            startStep = i,
            endStep = i,
            sumAngle = curvature,
            maxCurvature = math.abs(curvature),
            apexStep = i
          }
          lowCurvatureSteps = 0
        elseif not curCandidate then
          curCandidate = {
            startStep = i,
            endStep = i,
            sumAngle = curvature,
            maxCurvature = math.abs(curvature),
            apexStep = i
          }
          lowCurvatureSteps = 0
        else
          curCandidate.endStep = i
          curCandidate.sumAngle = curCandidate.sumAngle + curvature
          if math.abs(curvature) > curCandidate.maxCurvature then
            curCandidate.maxCurvature = math.abs(curvature)
            curCandidate.apexStep = i
          end
          lowCurvatureSteps = 0
        end
      else
        if curCandidate then
          lowCurvatureSteps = lowCurvatureSteps + 1
          if lowCurvatureSteps > maxLowCurvatureSteps then
            -- Close candidate (it ends at curCandidate.endStep automatically)
            if math.abs(curCandidate.sumAngle) >= 15.0 then
              table.insert(rawCorners, curCandidate)
            end
            curCandidate = nil
            lowCurvatureSteps = 0
          else
            -- Keep open through brief straight, sum curvature
            curCandidate.sumAngle = curCandidate.sumAngle + curvature
          end
        end
      end
    end
  end
  
  if curCandidate and math.abs(curCandidate.sumAngle) >= 15.0 then
    table.insert(rawCorners, curCandidate)
  end

  -- Post-process: Map steps to progress and sort corners by apex progress
  local processed = {}
  for _, rc in ipairs(rawCorners) do
    local apexProgress = (rc.apexStep * step) % 1.0
    local startProgress = (rc.startStep * step) % 1.0
    local endProgress = (rc.endStep * step) % 1.0
    
    table.insert(processed, {
      apexProgress = apexProgress,
      startProgress = startProgress,
      endProgress = endProgress,
      sumAngle = rc.sumAngle,
      maxCurvature = rc.maxCurvature
    })
  end

  -- Sort corners by apex progress
  table.sort(processed, function(a, b) return a.apexProgress < b.apexProgress end)
  
  allTrackCorners = processed
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
          -- Speed-relative color compared directly with the scaled AI speed profile
          local targetSpeedKmh = pt.speedKmh * speedMult * config.cornerSpeedBias
          local deltaKmh = carSpeedKmh - targetSpeedKmh
          local color = getSpeedRelativeColor(deltaKmh)
          
          if shouldLog and offset == 0 then
            logger.log(string.format("[Debug] [Pre-Calculated] Point[0] - pt.speedKmh: %.1f km/h, targetSpeedKmh: %.1f km/h, deltaKmh: %.1f, speedMult: %.2f", pt.speedKmh, targetSpeedKmh, deltaKmh, speedMult))
          end
          
          if prevPt then
            -- Draw main racing line segment
            racingPainter:line(prevPt.worldPos, pt.worldPos, color, 0.5)
            
            -- Guide lines conditions from pre-calculated gas/brake
            local inAnyBrakingZone = (pt.brake > 0.01)
            local inAnyAccelerationZone = (pt.gas > 0.05 and pt.brake <= 0.01)
            
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
            
            -- Draw acceleration zone (Green line offset to the Right side)
            if inAnyAccelerationZone then
              local accelerationWorldPos = pt.worldPos - pt.perp * 0.6
              if prevAccelPos then
                accelerationPainter:line(prevAccelPos, accelerationWorldPos, rgbm(0, 1, 0, 0.75), 0.15)
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

          -- Speed-relative color compared directly with the scaled AI speed profile
          local targetSpeedKmh = pt.aiSpeedKmh * speedMult * config.cornerSpeedBias
          local deltaKmh = carSpeedKmh - targetSpeedKmh
          local color = getSpeedRelativeColor(deltaKmh)

          if shouldLog and i == 2 then
            logger.log(string.format("[Debug] [Fallback] Point[2] - pt.aiSpeedKmh: %.1f km/h, targetSpeedKmh: %.1f km/h, deltaKmh: %.1f, speedMult: %.2f", pt.aiSpeedKmh, targetSpeedKmh, deltaKmh, speedMult))
          end

          -- Draw main racing line segment
          racingPainter:line(prevPt.worldPos, worldPos, color, 0.5)

          -- Guide lines conditions from AI inputs
          local inAnyBrakingZone = (pt.aiBrake > 0.01)
          local inAnyAccelerationZone = (pt.aiGas > 0.05 and pt.aiBrake <= 0.01)

          -- Calculate perpendicular offset vector for dual-side lines
          local perpendicular = nil
          if inAnyBrakingZone or inAnyAccelerationZone then
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

          -- Draw acceleration zone (Green line offset to the Right side)
          if inAnyAccelerationZone and perpendicular then
            local accelerationWorldPos = worldPos - perpendicular * 0.6
            if prevAccelPos then
              accelerationPainter:line(prevAccelPos, accelerationWorldPos, rgbm(0, 1, 0, 0.75), 0.15)
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
