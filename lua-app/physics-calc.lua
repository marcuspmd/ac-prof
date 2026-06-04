-- Physics calculations and G-Force auto-calibration for Race Coach Overlay
local M = {}

-- Peak G-forces observed during the session (starts with sensible defaults)
M.maxObservedLatG = 1.4
M.maxObservedDecelG = 1.0
M.maxObservedAccelG = 0.5

-- Automatically calibrate session G limits based on vehicle behavior
function M.updateGLimits(car)
  local accX = math.abs(car.acceleration.x)
  if accX > M.maxObservedLatG and accX < 2.0 then
    M.maxObservedLatG = accX
  end

  local decelG = -car.acceleration.z
  if decelG > M.maxObservedDecelG and decelG < 1.8 and car.brake > 0.5 then
    M.maxObservedDecelG = decelG
  end

  local accelG = car.acceleration.z
  if accelG > M.maxObservedAccelG and accelG < 1.0 and car.gas > 0.8 then
    M.maxObservedAccelG = accelG
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
