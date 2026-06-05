-- 3D Track Paint rendering for Race Coach Overlay
local config = require('config')
local physics = require('physics-calc')
local M = {}

local trackPainter = ac.TrackPaint()
trackPainter.forceRecast = true
trackPainter.ageFactor = 0.1
trackPainter.bulgeFactor = 0.4
local activeTurns = {}

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

-- Helper function to scan track spline ahead for corners
local function scanTrackCorners(car, sim)
  local detected = {}
  if not ac.hasTrackSpline() then return detected end
  
  local trackLength = sim and sim.trackLengthM or 1.0
  if trackLength <= 100 then return detected end

  local stepM = 5.0 -- sample every 5 meters
  local step = stepM / trackLength
  local lookAheadSteps = 160 -- scan 800 meters ahead

  local curCandidate = nil
  
  for i = 2, lookAheadSteps do
    local p1 = car.splinePosition + i * step
    if p1 > 1.0 then p1 = p1 - 1.0 end
    local pos1 = ac.trackProgressToWorldCoordinate(p1, true)
    
    local p0 = p1 - step
    if p0 < 0.0 then p0 = p0 + 1.0 end
    local pos0 = ac.trackProgressToWorldCoordinate(p0, true)
    
    local p2 = p1 + step
    if p2 > 1.0 then p2 = p2 - 1.0 end
    local pos2 = ac.trackProgressToWorldCoordinate(p2, true)
    
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
      if not curCandidate then
        curCandidate = {
          startIndex = i,
          endIndex = i,
          sumAngle = curvature,
          maxCurvature = math.abs(curvature),
          apexStepIdx = i
        }
      else
        curCandidate.endIndex = i
        curCandidate.sumAngle = curCandidate.sumAngle + curvature
        if math.abs(curvature) > curCandidate.maxCurvature then
          curCandidate.maxCurvature = math.abs(curvature)
          curCandidate.apexStepIdx = i
        end
      end
    else
      if curCandidate then
        if math.abs(curCandidate.sumAngle) >= 15.0 then
          table.insert(detected, curCandidate)
        end
        curCandidate = nil
      end
    end
  end
  
  if curCandidate and math.abs(curCandidate.sumAngle) >= 15.0 then
    table.insert(detected, curCandidate)
  end
  
  return detected
end

-- Render the 3D racing line and optimized braking point indicators on the track surface
function M.drawRacingLine(car, sim, nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded, maxObservedDecelG)
  local trackLength = sim and sim.trackLengthM or 1.0
  local roadGrip = sim and sim.roadGrip or 1.0

  -- 1. Reset the painter path
  trackPainter:reset()

  -- 2. Scan track ahead for all corners in look-ahead distance
  local scannedCorners = scanTrackCorners(car, sim)

  for _, c in ipairs(scannedCorners) do
    local apexProgress = car.splinePosition + c.apexStepIdx * (5.0 / trackLength)
    if apexProgress > 1.0 then apexProgress = apexProgress - 1.0 end
    
    local vTargetLocal, totalBrakingLocal = physics.calculateTurnPhysicsForAngle(
      car, c.sumAngle, roadGrip, car.speedMs
    )

    -- Check if this turn is already in our activeTurns cache list
    local found = false
    for _, turn in ipairs(activeTurns) do
      local diff = math.abs(turn.apexProgress - apexProgress)
      if diff > 0.5 then diff = 1.0 - diff end
      local diffM = diff * trackLength
      if diffM < 15 then
        -- Update dynamically calibrated values
        turn.vTarget = vTargetLocal
        turn.totalBrakingDistanceNeeded = totalBrakingLocal
        turn.nextTurnAngle = c.sumAngle
        found = true
        break
      end
    end

    if not found then
      table.insert(activeTurns, {
        apexProgress = apexProgress,
        vTarget = vTargetLocal,
        totalBrakingDistanceNeeded = totalBrakingLocal,
        nextTurnAngle = c.sumAngle
      })
    end
  end

  -- 3. Also add/update native upcoming turn if valid
  if nextTurnDist > 0 and math.abs(nextTurnAngle) >= 15 then
    local nativeApexProgress = car.splinePosition + nextTurnDist / trackLength
    if nativeApexProgress > 1.0 then nativeApexProgress = nativeApexProgress - 1.0 end

    local found = false
    for _, turn in ipairs(activeTurns) do
      local diff = math.abs(turn.apexProgress - nativeApexProgress)
      if diff > 0.5 then diff = 1.0 - diff end
      local diffM = diff * trackLength
      if diffM < 15 then
        -- Update with native values if they are more accurate or to keep updated
        turn.vTarget = vTarget
        turn.totalBrakingDistanceNeeded = totalBrakingDistanceNeeded
        turn.nextTurnAngle = nextTurnAngle
        found = true
        break
      end
    end

    if not found then
      table.insert(activeTurns, {
        apexProgress = nativeApexProgress,
        vTarget = vTarget,
        totalBrakingDistanceNeeded = totalBrakingDistanceNeeded,
        nextTurnAngle = nextTurnAngle
      })
    end
  end

  -- 4. Clean up expired turns from cache
  local idx = 1
  while idx <= #activeTurns do
    local turn = activeTurns[idx]
    local diff = turn.apexProgress - car.splinePosition
    if diff > 0.5 then diff = diff - 1.0
    elseif diff < -0.5 then diff = diff + 1.0 end
    local distToApex = diff * trackLength

    -- Keep turn active if it is within 800 meters ahead or up to 60 meters behind the car
    if distToApex > -60 and distToApex < 800 then
      idx = idx + 1
    else
      table.remove(activeTurns, idx)
    end
  end

  local lookAheadDistance = math.max(400, math.min(800, car.speedMs * 10))

  -- 5. Draw the main racing line ahead (dynamic meters ahead, 40 meters behind)
  if config.showRacingLine then
    local currentSegmentColor = nil
    local stepSizeMeters = 2
    local totalDistMeters = lookAheadDistance
    local targetDecel = maxObservedDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip)

    for d = -40, totalDistMeters, stepSizeMeters do
      local p = car.splinePosition + d / trackLength
      if p > 1.0 then p = p - 1.0
      elseif p < 0.0 then p = p + 1.0 end
      local worldPos = ac.trackProgressToWorldCoordinate(p, true)

      -- Determine speed-relative color from the most restrictive active turn
      local color
      local minVIdeal = nil

      for _, turn in ipairs(activeTurns) do
        -- Calculate distance from point p to this turn's apex
        local diff = turn.apexProgress - p
        if diff > 0.5 then diff = diff - 1.0
        elseif diff < -0.5 then diff = diff + 1.0 end
        local distToApex = diff * trackLength

        if distToApex > 0 then
          local vIdealLocal = math.sqrt(turn.vTarget * turn.vTarget + 2 * targetDecel * distToApex)
          if minVIdeal == nil or vIdealLocal < minVIdeal then
            minVIdeal = vIdealLocal
          end
        elseif distToApex >= -30 then
          -- Inside the turn
          local vIdealLocal = turn.vTarget
          if minVIdeal == nil or vIdealLocal < minVIdeal then
            minVIdeal = vIdealLocal
          end
        end
      end

      if minVIdeal then
        local deltaKmh = (car.speedMs - minVIdeal) * 3.6
        color = getSpeedRelativeColor(deltaKmh)
      else
        -- Straight line is Dark Green
        color = rgbm(0, 0.4, 0, 0.6)
      end

      -- Draw main segment path
      if currentSegmentColor == nil then
        currentSegmentColor = color
        trackPainter:to(worldPos)
      elseif color ~= currentSegmentColor then
        trackPainter:to(worldPos)
        trackPainter:stroke(false, currentSegmentColor, 0.5)
        currentSegmentColor = color
        trackPainter:to(worldPos)
      else
        trackPainter:to(worldPos)
      end
    end

    if currentSegmentColor then
      trackPainter:stroke(false, currentSegmentColor, 0.5)
    end

    -- 6. Draw the optimized braking point parallel thin red line(s)
    local drawingBraking = false

    for d = -40, totalDistMeters, stepSizeMeters do
      local p = car.splinePosition + d / trackLength
      if p > 1.0 then p = p - 1.0
      elseif p < 0.0 then p = p + 1.0 end
      local worldPos = ac.trackProgressToWorldCoordinate(p, true)

      -- Check if point p is in a braking zone for any active turn
      local inAnyBrakingZone = false
      for _, turn in ipairs(activeTurns) do
        -- Calculate distance from point p to this turn's apex
        local diff = turn.apexProgress - p
        if diff > 0.5 then diff = diff - 1.0
        elseif diff < -0.5 then diff = diff + 1.0 end
        local distToApex = diff * trackLength

        -- If point p is before apex and within required braking distance, and car speed is above target speed
        if distToApex >= 0 and distToApex <= turn.totalBrakingDistanceNeeded and car.speedMs > turn.vTarget then
          inAnyBrakingZone = true
          break
        end
      end

      if inAnyBrakingZone then
        -- Calculate tangent vector using a tiny spline step
        local dp = 0.0001
        local nextPos = ac.trackProgressToWorldCoordinate(p + dp, true)
        local tangent = nextPos - worldPos
        tangent.y = 0
        local perpendicular = vec3(-tangent.z, 0, tangent.x):normalize()
        -- Offset parallel line by 60cm
        local brakingWorldPos = worldPos + perpendicular * 0.6

        if not drawingBraking then
          drawingBraking = true
          trackPainter:to(brakingWorldPos)
        else
          trackPainter:to(brakingWorldPos)
        end
      else
        if drawingBraking then
          trackPainter:stroke(false, rgbm(1, 0, 0, 0.75), 0.15) -- Thin red line
          drawingBraking = false
        end
      end
    end

    if drawingBraking then
      trackPainter:stroke(false, rgbm(1, 0, 0, 0.75), 0.15)
    end
  end

  -- 7. Draw Apex marking for the closest upcoming turn only
  if config.drawEntryApexExit then
    local closestTurn = nil
    local minUpcomingDist = 9999

    for _, turn in ipairs(activeTurns) do
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

      -- Apex point (Gold circle)
      local apexColor = rgbm(1, 0.8, 0, 0.8) -- Gold/Yellow
      if distToApex < 15 then
        apexColor = rgbm(0, 0.9, 0.2, 0.8) -- Light Green when passing the apex
      end
      trackPainter:circle(apexWorldPos, 1.2, false, apexColor)
    end
  end
end

return M
