-- Persists per-corner learned calibration (apex speeds, G-limits, speed multiplier)
-- per (track, car, grip-category), so a new session starts where the last one ended.
local physics = require('physics-calc')
local lineLearning = require('line-learning')
local logger = require('logger')

local M = {}

local SCHEMA_VERSION = 1
local MATCH_TOLERANCE_M = 25.0

-- Learned per-corner fields worth persisting (apexProgress is the matching key, not data).
-- F5 fields (trailDecelRatio etc.) are already listed so the schema doesn't change later.
local LEARNED_FIELDS = {
  "calibratedVTarget",
  "trailDecelRatio", "trailObsCount",
  "brakePointProgress", "brakeObsCount",
  "passCount", "bestSegmentMs",
}

local sessionKey     = nil
local cacheDir       = nil
local sessionInited  = false
local lastLapCount   = -1

M.restoredCount = 0   -- corners matched on last restore (for settings UI)
M.lastSavedAt   = nil

-- ─── Session / paths ─────────────────────────────────────────────────────────

local function gripCategory(roadGrip)
  if roadGrip >= 0.93 then return "seco"
  elseif roadGrip >= 0.68 then return "molhado"
  else return "chuva" end
end

local function initSession()
  if sessionInited then return end
  sessionInited = true

  local sim     = ac.getSim()
  local grip    = sim and sim.roadGrip or 1.0
  local trackId = (ac.getTrackID() or "unknown"):gsub("[^%w%-_]", "_")
  local carId   = (ac.getCarID(0) or "unknown"):gsub("[^%w%-_]", "_")

  sessionKey = string.format("%s__%s__%s", trackId, carId, gripCategory(grip))

  local scriptDir = ac.getFolder(ac.FolderID.ScriptOrigin):gsub("\\", "/")
  cacheDir = scriptDir .. "/learning_cache"
  io.createDir(cacheDir)

  logger.log(string.format("[Corner Store] Sessão: key=%s grip=%.2f", sessionKey, grip))
end

local function getCachePath()
  if not cacheDir or not sessionKey then return nil end
  return cacheDir .. "/" .. sessionKey .. ".json"
end

-- Circular distance in meters between two spline progress values
local function progressDistM(a, b, trackLength)
  local diff = a - b
  if diff > 0.5 then diff = diff - 1.0
  elseif diff < -0.5 then diff = diff + 1.0 end
  return math.abs(diff * trackLength)
end

-- ─── Save ────────────────────────────────────────────────────────────────────

function M.save(corners, trackLength)
  initSession()
  local path = getCachePath()
  if not path or not corners or #corners == 0 or not trackLength or trackLength <= 100 then return end

  local outCorners = {}
  local calibCount = 0
  for _, turn in ipairs(corners) do
    local oc = { apexProgress = turn.apexProgress }
    if turn.observedSpeeds and #turn.observedSpeeds > 0 then
      oc.observedSpeeds = turn.observedSpeeds
    end
    for _, f in ipairs(LEARNED_FIELDS) do
      oc[f] = turn[f]
    end
    if turn.calibratedVTarget then calibCount = calibCount + 1 end
    outCorners[#outCorners + 1] = oc
  end

  local data = {
    schemaVersion = SCHEMA_VERSION,
    track       = (ac.getTrackID() or ""):gsub("[^%w%-_]", "_"),
    car         = (ac.getCarID(0) or ""):gsub("[^%w%-_]", "_"),
    gripCat     = sessionKey and sessionKey:match("__(.-)$") or "?",
    trackLength = trackLength,
    speedMult   = physics.speedMult,
    gLimits = {
      lat   = physics.maxObservedLatG,
      decel = physics.maxObservedDecelG,
      accel = physics.maxObservedAccelG,
    },
    corners = outCorners,
    line = lineLearning.serialize(),
    savedAt = os.date("%Y-%m-%d %H:%M:%S"),
  }

  local ok, jsonStr = pcall(JSON.stringify, data)
  if not ok or not jsonStr then return end

  local file = io.open(path, "w")
  if file then
    file:write(jsonStr)
    file:close()
    M.lastSavedAt = data.savedAt
    logger.log(string.format("[Corner Store] Cache salvo: %s (%d curvas, %d calibradas)",
      sessionKey, #outCorners, calibCount))
  end
end

-- ─── Restore ─────────────────────────────────────────────────────────────────

-- Loads the cache and applies it onto freshly detected corners. Matching is by
-- apexProgress (circular, tolerance 25m): preScanTrackCorners is deterministic over
-- the AI line, so progress values are stable unless the AI line itself changed.
-- Returns the parsed data table (caller may use speedMult) or nil.
function M.restore(corners, trackLength)
  initSession()
  M.restoredCount = 0

  local path = getCachePath()
  if not path or not corners or #corners == 0 then return nil end

  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*all")
  file:close()
  if not content or #content < 10 then return nil end

  local ok, data = pcall(JSON.parse, content)
  if not ok or type(data) ~= "table" then return nil end

  if data.schemaVersion ~= SCHEMA_VERSION then
    logger.log(string.format("[Corner Store] Schema %s ≠ %d — cache descartado",
      tostring(data.schemaVersion), SCHEMA_VERSION))
    return nil
  end
  if type(data.corners) ~= "table" or type(data.trackLength) ~= "number" then return nil end
  if math.abs(data.trackLength - trackLength) > trackLength * 0.01 then
    logger.log(string.format("[Corner Store] trackLength divergiu (%.0f vs %.0f) — cache descartado",
      data.trackLength, trackLength))
    return nil
  end

  local matched, discarded = 0, 0
  local taken = {}  -- detected corner index -> already matched
  for _, saved in ipairs(data.corners) do
    if type(saved.apexProgress) == "number" then
      local bestIdx, bestDist = nil, MATCH_TOLERANCE_M
      for ci, turn in ipairs(corners) do
        if not taken[ci] then
          local d = progressDistM(saved.apexProgress, turn.apexProgress, trackLength)
          if d < bestDist then
            bestIdx, bestDist = ci, d
          end
        end
      end
      if bestIdx then
        local turn = corners[bestIdx]
        if type(saved.observedSpeeds) == "table" then
          turn.observedSpeeds = saved.observedSpeeds
        end
        for _, f in ipairs(LEARNED_FIELDS) do
          if saved[f] ~= nil then turn[f] = saved[f] end
        end
        taken[bestIdx] = true
        matched = matched + 1
      else
        discarded = discarded + 1
      end
    else
      discarded = discarded + 1
    end
  end

  -- G-limits only ratchet upward in-session, so taking the max is always safe
  local g = data.gLimits
  if type(g) == "table" then
    physics.restoreGLimits(g.lat, g.decel, g.accel)
  end

  if data.line then
    pcall(lineLearning.restore, data.line)
  end

  M.restoredCount = matched
  logger.log(string.format("[Corner Store] %d curvas casadas, %d descartadas (de %d salvas)",
    matched, discarded, #data.corners))
  return data
end

-- ─── Per-lap auto-save ───────────────────────────────────────────────────────

function M.update(car, sim, corners)
  if not car then return end
  initSession()

  local lapCount = car.lapCount or 0
  if lastLapCount < 0 then lastLapCount = lapCount end
  if lapCount > lastLapCount then
    lastLapCount = lapCount
    M.save(corners, sim and sim.trackLengthM or 0)
  end
end

-- ─── Settings UI helpers ─────────────────────────────────────────────────────

function M.getSessionKey()
  return sessionKey
end

function M.deleteFile()
  local path = getCachePath()
  if not path then return end
  local ok = pcall(io.deleteFile, path)
  if ok then
    M.restoredCount = 0
    M.lastSavedAt = nil
    logger.log("[Corner Store] Cache em disco apagado: " .. tostring(sessionKey))
  end
end

return M
