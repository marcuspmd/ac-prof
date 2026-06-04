-- Physics calculations and G-Force auto-calibration for Race Coach Overlay
local M = {}

-- Peak G-forces observed during the session (starts with sensible defaults)
M.maxObservedLatG = 1.4
M.maxObservedDecelG = 1.0
M.maxObservedAccelG = 0.5

-- Smooth values for calibration (starts at baseline to prevent initial catch-up delay)
M.smoothedLatG = 1.0
M.smoothedDecelG = 0.8
M.smoothedAccelG = 0.3

-- Automatically calibrate session G limits based on vehicle behavior with spike filtering
function M.updateGLimits(car)
  local accX = math.abs(car.acceleration.x)
  M.smoothedLatG = M.smoothedLatG + (accX - M.smoothedLatG) * 0.1
  if M.smoothedLatG > M.maxObservedLatG and M.smoothedLatG < 1.8 then
    M.maxObservedLatG = M.smoothedLatG
  end

  local decelG = -car.acceleration.z
  if car.brake > 0.5 then
    M.smoothedDecelG = M.smoothedDecelG + (decelG - M.smoothedDecelG) * 0.1
    if M.smoothedDecelG > M.maxObservedDecelG and M.smoothedDecelG < 1.6 then
      M.maxObservedDecelG = M.smoothedDecelG
    end
  else
    M.smoothedDecelG = M.smoothedDecelG + (0 - M.smoothedDecelG) * 0.1
  end

  local accelG = car.acceleration.z
  if car.gas > 0.8 then
    M.smoothedAccelG = M.smoothedAccelG + (accelG - M.smoothedAccelG) * 0.1
    if M.smoothedAccelG > M.maxObservedAccelG and M.smoothedAccelG < 0.9 then
      M.maxObservedAccelG = M.smoothedAccelG
    end
  else
    M.smoothedAccelG = M.smoothedAccelG + (0 - M.smoothedAccelG) * 0.1
  end
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
    local absAngle = math.abs(nextTurnAngle)
    local baseTargetKmh = 800 / math.sqrt(math.max(1.0, absAngle))
    baseTargetKmh = math.max(50, math.min(290, baseTargetKmh))

    local gripFactor = math.sqrt(math.max(0.1, roadGrip))
    local carPerformanceFactor = math.min(1.25, math.sqrt(M.maxObservedLatG / 1.4))
    local vTargetKmh = baseTargetKmh * gripFactor * carPerformanceFactor
    vTarget = vTargetKmh / 3.6

    local targetDecel = M.maxObservedDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip)
    local reactionDistance = car.speedMs * 0.3

    local physicalBrakingDistance = 0
    if car.speedMs > vTarget then
      physicalBrakingDistance = (car.speedMs * car.speedMs - vTarget * vTarget) / (2 * targetDecel)
    end
    totalBrakingDistanceNeeded = physicalBrakingDistance + reactionDistance
  end

  return nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded
end

return M
