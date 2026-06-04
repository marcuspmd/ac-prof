local physics = require('physics-calc')
local config = require('config')
local M = {}


-- Captura a telemetria física completa do carro do jogador usando a API do CSP
function M.getTelemetry(carIndex)
  local carState = ac.getCar(carIndex or 0)
  if not carState then return nil end

  local tyres = {}
  for i = 0, 3 do
    local tyre = carState.wheels[i]
    if tyre then
      table.insert(tyres, {
        slipAngle = tyre.slipAngle,
        slipRatio = tyre.slipRatio,
        load = tyre.load,
        ndSlip = tyre.ndSlip
      })
    else
      table.insert(tyres, { slipAngle = 0, slipRatio = 0, load = 0, ndSlip = 0 })
    end
  end

  local steerNormalized = 0
  if carState.steerLock and carState.steerLock > 0 then
    steerNormalized = carState.steer / carState.steerLock
  end

  local upcomingTurn = ac.getTrackUpcomingTurn(carIndex or 0)
  local nextTurnDist = -1
  local nextTurnAngle = 0
  if upcomingTurn then
    nextTurnDist = upcomingTurn.x
    nextTurnAngle = upcomingTurn.y
  end

  local sim = ac.getSim()
  local roadGrip = sim and sim.roadGrip or 1.0

  local trackPos = ac.worldCoordinateToTrack(carState.position)
  local trackPosLat = trackPos and trackPos.x or 0

  return {
    speedMs = carState.speedMs or 0,
    speedKmh = carState.speedKmh or 0,
    gear = carState.gear or 0,
    engineRPM = carState.rpm or 0,
    steer = steerNormalized,
    throttle = carState.gas or 0,
    brake = carState.brake or 0,
    clutch = carState.clutch or 0,
    yaw = 0,
    yawRate = carState.localAngularVelocity.y,
    accG = {
      x = carState.acceleration and carState.acceleration.x or 0, -- Lateral G
      y = carState.acceleration and carState.acceleration.y or 0, -- Vertical G
      z = carState.acceleration and carState.acceleration.z or 0  -- Longitudinal G
    },
    tyres = tyres,
    nextTurnDist = nextTurnDist,
    nextTurnAngle = nextTurnAngle,
    roadGrip = roadGrip,
    trackPosLat = trackPosLat,
    maxObservedLatG = physics.maxObservedLatG or 1.4,
    maxObservedDecelG = physics.maxObservedDecelG or 1.0,
    voiceEnabled = config.voiceEnabled,
    drawEntryApexExit = config.drawEntryApexExit,
    showSpeedHolograms = config.showSpeedHolograms
  }
end


return M
