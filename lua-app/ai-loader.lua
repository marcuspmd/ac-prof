-- Binary fast_lane.ai reader and parser for Race Coach Overlay
local logger = require('logger')
local M = {}

M.aiMaxSpeedKmh = 100 -- Default fallback
M.isPreCalculated = false
M.detailCount = 0
M.points = {}

local aiTelemetry = {}
local isLoaded = false
local lastLoadedPath = ""

local function log(msg)
  logger.log("[AI Loader] " .. tostring(msg))
end

-- Parse fast_lane.ai binary file or load pre-calculated track data
function M.loadAiLine()
  local trackDir = ac.getFolder(ac.FolderID.CurrentTrackLayout)
  local filePath = trackDir:gsub("\\", "/") .. "/ai/fast_lane.ai"

  if isLoaded and filePath == lastLoadedPath then
    return true
  end

  logger.clear() -- Clear log when a new track/session is loaded!

  aiTelemetry = {}
  isLoaded = false
  lastLoadedPath = filePath
  M.isPreCalculated = false
  M.points = {}
  M.detailCount = 0

  -- 1. Try to load pre-calculated track geometry
  local trackId = ac.getTrackID()
  local layoutId = ac.getTrackLayout()
  local trackName = trackId or "unknown"
  if layoutId and layoutId ~= "" then
    trackName = trackName .. "_" .. layoutId
  end
  trackName = trackName:gsub("[^%w%-_]", "_"):lower()

  log("Tentando carregar dados de pista pre-calculados para: " .. trackName)
  local ok, trackData = pcall(require, "tracks." .. trackName)
  if ok and trackData and type(trackData.points) == "table" then
    log("Dados de pista pre-calculados carregados com sucesso para: " .. trackName)
    M.isPreCalculated = true
    M.aiMaxSpeedKmh = trackData.refMaxSpeedKmh or 250.0
    M.detailCount = trackData.detailCount or #trackData.points
    M.trackLength = trackData.trackLength
    
    -- Pre-allocate vec3 positions and perpendiculars to avoid runtime allocations
    M.points = {}
    for i = 1, #trackData.points do
      local pt = trackData.points[i]
      M.points[i] = {
        worldPos = vec3(pt[1], pt[2], pt[3]),
        speedKmh = pt[4],
        gas = pt[5],
        brake = pt[6],
        perp = vec3(pt[7], 0, pt[8])
      }
    end
    
    isLoaded = true
    return true
  end

  log("Dados pre-calculados nao encontrados ou invalidos. Usando fallback binario fast_lane.ai em: " .. filePath)
  local f = io.open(filePath, "rb")
  if not f then
    log("Arquivo fast_lane.ai nao encontrado em: " .. filePath)
    return false
  end

  local content = f:read("a")
  f:close()

  if #content < 32 then
    log("Arquivo fast_lane.ai invalido (tamanho muito pequeno)")
    return false
  end

  local pos = 1
  local header, detailCount, u1, u2
  header, pos = string.unpack("<I4", content, pos)
  detailCount, pos = string.unpack("<I4", content, pos)
  u1, pos = string.unpack("<I4", content, pos)
  u2, pos = string.unpack("<I4", content, pos)

  log("Arquivo IA aberto. Header=" .. tostring(header) .. ", Contagem de Pontos=" .. tostring(detailCount))
  if detailCount <= 0 or #content < (16 + detailCount * 20) then
    log("Arquivo fast_lane.ai corrompido ou contagem de pontos invalida")
    return false
  end

  M.detailCount = detailCount

  -- Skip block 1 (point positions, 20 bytes per point: 4 floats + 1 uint)
  local block1Size = detailCount * 20
  -- Gap of 18 floats (72 bytes) before block 2 starts
  local gapSize = 18 * 4
  local detailBlockStart = 1 + 16 + block1Size + gapSize

  if #content < (detailBlockStart + detailCount * 18 * 4) then
    log("Arquivo IA muito pequeno para os blocos de detalhe")
    return false
  end

  -- Parse block 2 (details, 18 floats per point = 72 bytes)
  pos = detailBlockStart
  local maxSpeedKmh = 1.0
  for i = 1, detailCount do
    local speed, gas, brake
    -- Unpack first 4 floats: unk, speed, gas, brake
    local unk
    unk, pos = string.unpack("<f", content, pos)
    speed, pos = string.unpack("<f", content, pos)
    gas, pos = string.unpack("<f", content, pos)
    brake, pos = string.unpack("<f", content, pos)

    -- Skip the remaining 14 floats (obsoleteLatG, radius, sideLeft, sideRight, camber, normal, forward, etc.)
    pos = pos + 14 * 4

    local sKmh = speed * 3.6
    table.insert(aiTelemetry, {
      speedKmh = sKmh,
      gas = math.max(0, math.min(1, gas)),
      brake = math.max(0, math.min(1, brake))
    })
    if sKmh > maxSpeedKmh then
      maxSpeedKmh = sKmh
    end
  end

  -- Recalculate gas and brake for fallback mode (binary fast_lane.ai) to have correct physical inputs
  local sim = ac.getSim()
  local trackLength = sim and sim.trackLengthM or 2000
  local ds = trackLength / detailCount
  if ds <= 0.1 then ds = 1.5 end

  local rawInputs = {}
  for i = 1, detailCount do
    local data = aiTelemetry[i]
    local nextIdx = (i % detailCount) + 1
    local dataNext = aiTelemetry[nextIdx]
    
    local vCurr = data.speedKmh / 3.6
    local vNext = dataNext.speedKmh / 3.6
    
    local a = (vNext * vNext - vCurr * vCurr) / (2 * ds)
    
    local newGas = 0
    local newBrake = 0
    
    if a < -1.0 then
      newBrake = math.min(1.0, math.abs(a + 1.0) / 8.0)
      newGas = 0.0
    elseif a >= 0.0 then
      newBrake = 0.0
      newGas = 1.0
    else
      newBrake = 0.0
      newGas = 0.0
    end
    rawInputs[i] = { gas = newGas, brake = newBrake }
  end
  
  -- Smooth the inputs over a 5-point window
  for i = 1, detailCount do
    local sumGas = 0
    local sumBrake = 0
    local count = 0
    for w = -2, 2 do
      local idx = ((i + w - 1) % detailCount) + 1
      sumGas = sumGas + rawInputs[idx].gas
      sumBrake = sumBrake + rawInputs[idx].brake
      count = count + 1
    end
    aiTelemetry[i].gas = sumGas / count
    aiTelemetry[i].brake = sumBrake / count
  end

  -- Smooth the speed profile over a 15-point window to eliminate recording noise/jitter
  local smoothSpeed = {}
  local speedWindow = 7 -- 7 points ahead, 7 points behind (15 total)
  for i = 1, detailCount do
    local sumSpeed = 0
    local count = 0
    for w = -speedWindow, speedWindow do
      local idx = ((i + w - 1) % detailCount) + 1
      sumSpeed = sumSpeed + aiTelemetry[idx].speedKmh
      count = count + 1
    end
    smoothSpeed[i] = sumSpeed / count
  end
  for i = 1, detailCount do
    aiTelemetry[i].speedKmh = smoothSpeed[i]
  end

  isLoaded = true
  M.aiMaxSpeedKmh = maxSpeedKmh
  log(string.format("Arquivo fast_lane.ai lido com sucesso. Pontos carregados: %d, Velocidade Maxima IA: %.1f km/h", #aiTelemetry, maxSpeedKmh))
  for i = 1, math.min(10, #aiTelemetry) do
    log(string.format("  Ponto %d: speedKmh=%.1f, gas=%.2f, brake=%.2f", i, aiTelemetry[i].speedKmh, aiTelemetry[i].gas, aiTelemetry[i].brake))
  end
  return true
end

-- Get AI inputs (gas and brake) at a given spline progress (0.0 to 1.0)
function M.getAiInputAtProgress(progress)
  if not isLoaded then
    local success = M.loadAiLine()
    if not success then
      return 0, 0, 0 -- fallback values
    end
  end

  if M.isPreCalculated then
    local count = #M.points
    if count == 0 then
      return 0, 0, 0
    end
    local idx = math.floor((progress % 1.0) * count) + 1
    if idx <= 0 then idx = 1
    elseif idx > count then idx = count end
    local pt = M.points[idx]
    return pt.gas, pt.brake, pt.speedKmh
  else
    local count = #aiTelemetry
    if count == 0 then
      return 0, 0, 0
    end
    local idx = math.floor((progress % 1.0) * count) + 1
    if idx <= 0 then idx = 1
    elseif idx > count then idx = count end
    local data = aiTelemetry[idx]
    return data.gas, data.brake, data.speedKmh
  end
end

return M
