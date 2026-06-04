-- 3D Track Paint rendering for Race Coach Overlay
local config = require('config')
local M = {}

local trackPainter = ac.TrackPaint()

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

-- Render the 3D racing line and optimized braking point indicators on the track surface
function M.drawRacingLine(car, sim, nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded, maxObservedDecelG)
  local trackLength = sim and sim.trackLengthM or 1.0
  local roadGrip = sim and sim.roadGrip or 1.0

  -- 1. Reset the painter path
  trackPainter:reset()

  -- 2. Draw the main racing line ahead (80 meters sampled every 2 meters)
  local currentSegmentColor = nil
  local stepSizeMeters = 2
  local totalDistMeters = 80
  local targetDecel = maxObservedDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip)

  for d = 0, totalDistMeters, stepSizeMeters do
    local p = car.splinePosition + d / trackLength
    if p > 1.0 then p = p - 1.0 end
    local worldPos = ac.trackProgressToWorldCoordinate(p, true)

    -- Determine speed-relative color
    local color
    if nextTurnDist > 0 then
      local distToCorner = nextTurnDist - d
      if distToCorner > 0 then
        -- Calculate the ideal speed at this specific point on the track approach
        local vIdeal = math.sqrt(vTarget * vTarget + 2 * targetDecel * distToCorner)
        local deltaKmh = (car.speedMs - vIdeal) * 3.6
        color = getSpeedRelativeColor(deltaKmh)
      else
        -- Inside/past the apex, color is Dark Green since we can start accelerating
        color = rgbm(0, 0.4, 0, 0.6)
      end
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

  -- 3. Draw the optimized braking point parallel thin red line
  if nextTurnDist > 0 and car.speedMs > vTarget and totalBrakingDistanceNeeded > 0 then
    local drawingBraking = false

    for d = 0, totalDistMeters, stepSizeMeters do
      local distToCorner = nextTurnDist - d
      if distToCorner >= 0 and distToCorner <= totalBrakingDistanceNeeded then
        local p = car.splinePosition + d / trackLength
        if p > 1.0 then p = p - 1.0 end
        local worldPos = ac.trackProgressToWorldCoordinate(p, true)

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

  -- Helper functions for 3D track markings
  local function drawTrackCrossLine(p, color, thickness)
    local widths = ac.getTrackAISplineSides(p)
    local pos = ac.trackProgressToWorldCoordinate(p, true)
    local dp = 0.0001
    local posNext = ac.trackProgressToWorldCoordinate(p + dp, true)
    local tangent = posNext - pos
    tangent.y = 0
    local perpendicular = vec3(-tangent.z, 0, tangent.x):normalize()
    local leftPos = pos + perpendicular * widths.x
    local rightPos = pos - perpendicular * widths.y
    
    trackPainter:line(leftPos, rightPos, color, thickness)
  end

  local function drawTrackLabel(p, text, color)
    local pos = ac.trackProgressToWorldCoordinate(p, true)
    local dp = 0.0001
    local posNext = ac.trackProgressToWorldCoordinate(p + dp, true)
    local tangent = posNext - pos
    tangent.y = 0
    
    local textAngle = math.deg(math.atan2(tangent.x, tangent.z)) - 90
    
    -- Lift slightly off the ground to prevent Z-fighting/clipping
    local textPos = pos + vec3(0, 0.08, 0)
    
    -- Center text on the track line, size 5.0m wide by 1.2m high
    trackPainter:text("Arial", text, textPos, vec2(5.0, 1.2), textAngle, color)
  end

  -- 4. Draw Entry, Apex, Exit markings and Speed Holograms
  if nextTurnDist > 0 and nextTurnDist < 100 then
    local apexProgress = car.splinePosition + nextTurnDist / trackLength
    if apexProgress > 1.0 then apexProgress = apexProgress - 1.0 end
    local apexWorldPos = ac.trackProgressToWorldCoordinate(apexProgress, true)

    local entryDist = math.max(30, totalBrakingDistanceNeeded)
    local entryProgress = apexProgress - entryDist / trackLength
    if entryProgress < 0.0 then entryProgress = entryProgress + 1.0 end

    -- Draw Entry, Apex, Exit points
    if config.drawEntryApexExit then
      -- Entry point (Red line and label)
      drawTrackCrossLine(entryProgress, rgbm(1.0, 0.2, 0.2, 0.8), 0.4)
      drawTrackLabel(entryProgress, "ENTRADA", rgbm(1.0, 0.2, 0.2, 0.8))

      -- Apex point (Gold circle and label)
      local apexColor = rgbm(1, 0.8, 0, 0.8) -- Gold/Yellow
      if nextTurnDist < 15 then
        apexColor = rgbm(0, 0.9, 0.2, 0.8) -- Light Green when passing the apex
      end
      trackPainter:circle(apexWorldPos, 1.2, false, apexColor)
      drawTrackLabel(apexProgress, "APICE", apexColor)

      -- Exit point (Green line and label)
      local exitProgress = apexProgress + 30 / trackLength
      if exitProgress > 1.0 then exitProgress = exitProgress - 1.0 end
      drawTrackCrossLine(exitProgress, rgbm(0.2, 1.0, 0.2, 0.8), 0.4)
      drawTrackLabel(exitProgress, "SAIDA", rgbm(0.2, 1.0, 0.2, 0.8))
    end

    -- Draw Speed Holograms before the entry point
    if config.showSpeedHolograms then
      local p_actual = entryProgress - 8 / trackLength
      if p_actual < 0.0 then p_actual = p_actual + 1.0 end

      local p_ideal = entryProgress - 4 / trackLength
      if p_ideal < 0.0 then p_ideal = p_ideal + 1.0 end

      local actualKmh = car.speedMs * 3.6
      local idealKmh = vTarget * 3.6
      local actualColor = rgbm(1, 1, 1, 0.8)

      if actualKmh <= idealKmh + 5 then
        actualColor = rgbm(0.2, 1.0, 0.2, 0.8) -- Green
      elseif actualKmh <= idealKmh + 15 then
        actualColor = rgbm(1.0, 0.8, 0.2, 0.8) -- Yellow
      else
        actualColor = rgbm(1.0, 0.2, 0.2, 0.8) -- Red
      end

      local actualText = string.format("ATUAL: %.0f km/h", actualKmh)
      local idealText = string.format("IDEAL: %.0f km/h", idealKmh)

      drawTrackLabel(p_actual, actualText, actualColor)
      drawTrackLabel(p_ideal, idealText, rgbm(0.2, 0.8, 1.0, 0.8)) -- Cyan
    end
  end
end

return M
