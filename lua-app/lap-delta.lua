-- Real-time lap delta tracking against the session's best lap
-- Reference lap is persisted per (track, car, grip-category) so no warm-up lap is needed.
local M = {}

local BUCKET_COUNT = 1000

M.refBuckets     = {}
M.isRefSet       = false
M.bestRefLapMs   = math.huge
M.lastLapCount   = -1
M.lastLapTimeMs  = 0
M.currentSamples = {}
M.deltaSeconds   = nil

-- Session-level cache metadata (populated on first update call)
local sessionKey    = nil   -- "track__car__gripcat"
local cacheDir      = nil
local sessionInited = false

-- ─── Grip category ──────────────────────────────────────────────────────────

local function gripCategory(roadGrip)
  if roadGrip >= 0.93 then return "seco"
  elseif roadGrip >= 0.68 then return "molhado"
  else return "chuva" end
end

-- ─── Bucket helpers ─────────────────────────────────────────────────────────

local function bucket(pos)
  return math.floor((pos % 1.0) * BUCKET_COUNT) + 1
end

local function refTimeAt(pos)
  if not M.isRefSet then return nil end
  local b = bucket(pos)
  for i = 0, 20 do
    local idx = (b + i - 1) % BUCKET_COUNT + 1
    if M.refBuckets[idx] then return M.refBuckets[idx] end
  end
  return nil
end

-- ─── Persistence ────────────────────────────────────────────────────────────

local function getCachePath()
  if not cacheDir or not sessionKey then return nil end
  return cacheDir .. "/" .. sessionKey .. ".json"
end

local function loadCache()
  local path = getCachePath()
  if not path then return end

  local file = io.open(path, "r")
  if not file then return end
  local content = file:read("*all")
  file:close()

  if not content or #content < 10 then return end

  local ok, cached = pcall(JSON.parse, content)
  if not ok or not cached then return end

  if type(cached.bestLapMs) ~= "number" or type(cached.buckets) ~= "table" then return end

  M.refBuckets = {}
  local filled = 0
  for i = 1, BUCKET_COUNT do
    local t = cached.buckets[i]
    if type(t) == "number" and t > 0 then
      M.refBuckets[i] = t
      filled = filled + 1
    end
  end

  if filled > 50 then
    M.bestRefLapMs = cached.bestLapMs
    M.isRefSet = true
    ac.log(string.format(
      "[Lap Delta] Cache carregado: %s  melhor=%.3fs  (%d buckets preenchidos)",
      sessionKey, M.bestRefLapMs / 1000, filled))
  end
end

local function saveCache()
  local path = getCachePath()
  if not path then return end

  -- Serialize as flat array (0 for empty buckets)
  local bucketsArr = {}
  for i = 1, BUCKET_COUNT do
    bucketsArr[i] = M.refBuckets[i] or 0
  end

  local data = {
    track      = (ac.getTrackID() or ""):gsub("[^%w%-_]", "_"),
    car        = (ac.getCarID(0) or ""):gsub("[^%w%-_]", "_"),
    gripCat    = sessionKey and sessionKey:match("__(.-)$") or "?",
    bestLapMs  = M.bestRefLapMs,
    buckets    = bucketsArr,
    savedAt    = os.date("%Y-%m-%d %H:%M:%S"),
  }

  local ok, jsonStr = pcall(JSON.stringify, data)
  if not ok or not jsonStr then return end

  local file = io.open(path, "w")
  if file then
    file:write(jsonStr)
    file:close()
    ac.log(string.format("[Lap Delta] Cache salvo: %s  melhor=%.3fs", sessionKey, M.bestRefLapMs / 1000))
  end
end

-- ─── Session init ────────────────────────────────────────────────────────────

local function initSession()
  if sessionInited then return end
  sessionInited = true

  local sim     = ac.getSim()
  local grip    = sim and sim.roadGrip or 1.0
  local gripCat = gripCategory(grip)

  local trackId = (ac.getTrackID() or "unknown"):gsub("[^%w%-_]", "_")
  local carId   = (ac.getCarID(0) or "unknown"):gsub("[^%w%-_]", "_")

  sessionKey = string.format("%s__%s__%s", trackId, carId, gripCat)

  local scriptDir = ac.getFolder(ac.FolderID.ScriptOrigin):gsub("\\", "/")
  cacheDir = scriptDir .. "/delta_cache"
  io.createDir(cacheDir)

  ac.log(string.format("[Lap Delta] Sessão inicializada: key=%s  grip=%.2f (%s)", sessionKey, grip, gripCat))
  loadCache()
end

-- ─── Reference lap save ──────────────────────────────────────────────────────

local function saveRef(lapDurationMs)
  if #M.currentSamples < 100 then return end
  M.refBuckets = {}
  for _, s in ipairs(M.currentSamples) do
    local b = bucket(s.pos)
    if not M.refBuckets[b] then
      M.refBuckets[b] = s.timeMs
    end
  end
  M.bestRefLapMs = lapDurationMs
  M.isRefSet     = true
  saveCache()
end

-- ─── Public API ──────────────────────────────────────────────────────────────

function M.update(car)
  if not car then return end

  -- One-time session init (needs AC APIs, so deferred to first frame)
  initSession()

  local splinePos = car.splinePosition % 1.0
  local lapTimeMs = car.lapTimeMs
  local lapCount  = car.lapCount

  if M.lastLapCount < 0 then
    M.lastLapCount = lapCount
  end

  -- Detect lap completion
  if lapCount > M.lastLapCount then
    local completedMs = M.lastLapTimeMs
    if completedMs > 10000 and completedMs < M.bestRefLapMs then
      saveRef(completedMs)
    end
    M.currentSamples = {}
    M.lastLapCount   = lapCount
  end

  -- Record sample for current lap
  if lapTimeMs > 0 then
    M.currentSamples[#M.currentSamples + 1] = { pos = splinePos, timeMs = lapTimeMs }
    if #M.currentSamples > 3000 then table.remove(M.currentSamples, 1) end
  end

  M.lastLapTimeMs = lapTimeMs

  -- Calculate delta
  if M.isRefSet and lapTimeMs > 500 then
    local refTime = refTimeAt(splinePos)
    if refTime then
      M.deltaSeconds = (lapTimeMs - refTime) / 1000.0
    end
  else
    M.deltaSeconds = nil
  end
end

-- Returns delta in seconds vs reference lap (negative = ahead, positive = behind). Nil if no ref.
function M.getDelta()
  return M.deltaSeconds
end

-- Returns best reference lap time in ms, or nil
function M.getBestLapMs()
  return M.isRefSet and M.bestRefLapMs or nil
end

-- Returns current session key (for display in settings panel)
function M.getSessionKey()
  return sessionKey
end

function M.reset()
  M.refBuckets     = {}
  M.isRefSet       = false
  M.bestRefLapMs   = math.huge
  M.lastLapCount   = -1
  M.lastLapTimeMs  = 0
  M.currentSamples = {}
  M.deltaSeconds   = nil
  -- Note: does NOT delete the cache file — reset is session-only
end

return M
