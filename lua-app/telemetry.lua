local M = {}

-- Captura a telemetria física completa do carro do jogador usando a API do CSP
function M.getTelemetry(carIndex)
  local carState = ac.getCarState(carIndex or 0)
  if not carState then return nil end

  local tyres = {}
  for i = 0, 3 do
    local tyre = carState.tyres[i]
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

  return {
    speedMs = carState.speedMs or 0,
    speedKmh = carState.speedKmh or 0,
    gear = carState.gear or 0,
    engineRPM = carState.engineRPM or 0,
    steer = carState.steer or 0,
    throttle = carState.gas or 0,
    brake = carState.brake or 0,
    clutch = carState.clutch or 0,
    yaw = carState.yaw or 0,
    yawRate = carState.yawRate or 0,
    accG = {
      x = carState.accG and carState.accG.x or 0, -- Lateral G
      y = carState.accG and carState.accG.y or 0, -- Vertical G
      z = carState.accG and carState.accG.z or 0  -- Longitudinal G
    },
    tyres = tyres
  }
end

return M
