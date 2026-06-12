-- Learns the driver's real lateral path (normalized -1..1 across track width) in
-- fixed spline buckets, fed only with corner passes validated by corner-learning.
-- Also owns the hybrid display line: AI line blended toward the learned path,
-- rebuilt amortized over several frames whenever a merge lands.
local aiLoader = require('ai-loader')
local logger = require('logger')
local config = require('config')

local M = {}

local BUCKETS = 2048
M.BUCKETS = BUCKETS

local CAR_HALF_WIDTH_M = 0.9
local RAMP_METERS = 30.0       -- cosine-like ramp at learned-segment edges (via weight smoothing)
local SMOOTH_RADIUS = 4        -- ±4 buckets ≈ ±10m moving average on learned lat
local REBUILD_CHUNK = 500      -- display points converted per frame during a rebuild
local AILAT_CHUNK = 64         -- aiLat buckets computed per frame at session start

-- Learned state (persisted by corner-store as data.line)
M.learnedLat = {}     -- bucket -> -1..1 (ac.worldCoordinateToTrack convention)
M.learnedWeight = {}  -- bucket -> 0..1 confidence (full after ~5 good passes)

-- Current-pass sampling buffer. curStamp marks freshness so a merge only consumes
-- buckets actually driven during the validated pass, never stale data.
local curLat = {}
local curStamp = {}
local stamp = 0
local lastBucket = -1
local lastLat = 0

-- Display line state (built only for pre-calculated tracks)
local displayPos = nil        -- idx -> vec3, pre-allocated, aligned to aiLoader.points
local displayPerp = nil
local displayReady = false
local displayUnsupported = false
local dirtyLine = false
local rebuildIdx = 0          -- 0 = idle; >0 = next point index to convert
local rebuildCompleted = false
local displayLat = {}         -- bucket -> blended lat, frozen at rebuild start
local aiLat = {}              -- bucket -> AI line lat
local aiLatBuilt = 0          -- amortized progress of aiLat computation
local scratchTrackCoord = nil

local function bucketOf(progress)
  return math.floor((progress % 1.0) * BUCKETS) + 1
end
M.bucketOf = bucketOf

-- Per-frame, O(1): record the car's lateral position into the current bucket,
-- interpolating over buckets skipped between frames (a few at most at high speed)
function M.update(car, trackPos)
  stamp = stamp + 1
  if not car or not trackPos then return stamp end

  local lat = math.max(-1.0, math.min(1.0, trackPos.x))
  local b = bucketOf(car.splinePosition)

  if lastBucket > 0 and b ~= lastBucket then
    local gap = b - lastBucket
    if gap < 0 then gap = gap + BUCKETS end
    -- Forward gaps only; large gaps mean teleport/reset, do not interpolate those
    if gap >= 2 and gap <= 8 then
      for k = 1, gap - 1 do
        local bi = ((lastBucket - 1 + k) % BUCKETS) + 1
        curLat[bi] = lastLat + (lat - lastLat) * (k / gap)
        curStamp[bi] = stamp
      end
    end
  end

  curLat[b] = lat
  curStamp[b] = stamp
  lastBucket = b
  lastLat = lat
  return stamp
end

function M.currentStamp()
  return stamp
end

-- Merge a validated pass segment into the learned path.
-- alpha: 0.5 for a segment PB, 0.25 for near-PB passes.
-- minStamp: only buckets sampled at/after this stamp (i.e. during this pass) count.
function M.mergePass(startProgress, endProgress, alpha, minStamp)
  -- Modo iniciante: não aprender a linha — trajetórias de iniciante distorceriam
  -- o traçado salvo sem mecanismo corretivo
  if config.beginnerMode then return 0 end
  local b0 = bucketOf(startProgress)
  local b1 = bucketOf(endProgress)
  local n = b1 - b0
  if n < 0 then n = n + BUCKETS end
  if n <= 0 or n > BUCKETS / 2 then return 0 end

  local merged = 0
  for k = 0, n do
    local b = ((b0 - 1 + k) % BUCKETS) + 1
    if curStamp[b] and curStamp[b] >= minStamp then
      local w = M.learnedWeight[b] or 0
      if w <= 0 then
        M.learnedLat[b] = curLat[b]
      else
        M.learnedLat[b] = M.learnedLat[b] + alpha * (curLat[b] - M.learnedLat[b])
      end
      M.learnedWeight[b] = math.min(1.0, w + 0.2)
      merged = merged + 1
    end
  end
  if merged > 0 then dirtyLine = true end
  return merged
end

-- ─── Hybrid display line ─────────────────────────────────────────────────────

local function latAtBucketF(f)
  -- Linear interpolation between bucket centers (f in bucket-space, circular)
  local b0 = math.floor(f)
  local frac = f - b0
  local i0 = (b0 % BUCKETS) + 1
  local i1 = (i0 % BUCKETS) + 1
  return displayLat[i0] + (displayLat[i1] - displayLat[i0]) * frac
end

-- Freeze the blended per-bucket lat for the rebuild: smooth the learned path,
-- smooth the weights (this is the edge ramp — no jumps back to the AI line),
-- then blend AI→learned by smoothstep(weight).
local function computeDisplayLat(trackLength)
  local rampRadius = math.max(2, math.ceil(RAMP_METERS / (trackLength / BUCKETS)))

  local effLat = {}
  for b = 1, BUCKETS do
    local w = M.learnedWeight[b] or 0
    effLat[b] = (w > 0) and M.learnedLat[b] or (aiLat[b] or 0)
  end

  for b = 1, BUCKETS do
    -- Smoothed learned lat (±SMOOTH_RADIUS buckets)
    local sumLat, nLat = 0, 0
    for k = -SMOOTH_RADIUS, SMOOTH_RADIUS do
      local bi = ((b - 1 + k) % BUCKETS) + 1
      sumLat = sumLat + effLat[bi]
      nLat = nLat + 1
    end
    local smoothLat = sumLat / nLat

    -- Smoothed weight over the ramp radius: edges fade in/out over ~RAMP_METERS
    local sumW = 0
    for k = -rampRadius, rampRadius do
      local bi = ((b - 1 + k) % BUCKETS) + 1
      sumW = sumW + (M.learnedWeight[bi] or 0)
    end
    local w = sumW / (2 * rampRadius + 1)
    w = w * w * (3 - 2 * w)  -- smoothstep

    local base = aiLat[b] or 0
    displayLat[b] = base + w * (smoothLat - base)
  end
end

-- Convert one display point: blended lat -> clamped -> world position
local function convertDisplayPoint(idx, detailCount)
  local progress = (idx - 1) / detailCount
  local f = (progress * BUCKETS) % BUCKETS + 0.5 - 1  -- bucket-space coordinate of centers
  local lat = latAtBucketF(f)

  -- Clamp inside the track edges with half a car width of margin
  local okSides, sides = pcall(ac.getTrackAISplineSides, progress)
  if okSides and sides then
    local width = (lat < 0) and sides.x or sides.y
    if width and width > CAR_HALF_WIDTH_M then
      local maxLat = 1.0 - CAR_HALF_WIDTH_M / width
      lat = math.max(-maxLat, math.min(maxLat, lat))
    end
  end

  local pos = nil
  if ac.trackCoordinateToWorld then
    scratchTrackCoord = scratchTrackCoord or vec3()
    scratchTrackCoord:set(lat, 0, progress)
    local okW, world = pcall(ac.trackCoordinateToWorld, scratchTrackCoord)
    if okW and world then pos = world end
  end
  if not pos then
    -- Fallback for older CSP: offset the AI point along its perpendicular.
    -- +perp points to the LEFT of travel and lat is negative on the left.
    local pt = aiLoader.points[idx]
    if pt and pt.worldPos and pt.perp then
      local b = (math.floor(progress * BUCKETS) % BUCKETS) + 1
      local deltaLat = lat - (aiLat[b] or 0)
      local halfWidth = 5.0
      if okSides and sides and sides.x and sides.y then
        halfWidth = (sides.x + sides.y) / 2
      end
      pos = pt.worldPos - pt.perp * (deltaLat * halfWidth)
    elseif pt and pt.worldPos then
      pos = pt.worldPos
    else
      -- No data for this point: keep continuity with the previous one
      local prevIdx = ((idx - 2) % detailCount) + 1
      pos = displayPos[prevIdx]
    end
  end

  displayPos[idx]:set(pos.x, pos.y, pos.z)

  -- Perpendicular by finite difference against the previous display point
  local prevIdx = ((idx - 2) % detailCount) + 1
  local prev = displayPos[prevIdx]
  local tx, tz = pos.x - prev.x, pos.z - prev.z
  local len = math.sqrt(tx * tx + tz * tz)
  if len > 0.001 then
    displayPerp[idx]:set(-tz / len, 0, tx / len)
  else
    local pt = aiLoader.points[idx]
    if pt and pt.perp then displayPerp[idx]:set(pt.perp.x, pt.perp.y, pt.perp.z) end
  end
  return true
end

-- Amortized worker, call once per frame from the coordinator. Spreads the aiLat
-- baseline computation and full display rebuilds over many frames to keep the
-- frame budget flat (~500 conversions/frame, rebuild triggered ≤1× per lap).
function M.rebuildStep(trackLength)
  if displayUnsupported then return end
  if not trackLength or trackLength <= 100 then return end
  if not aiLoader.isPreCalculated then return end
  local detailCount = aiLoader.detailCount
  if not detailCount or detailCount <= 0 then return end

  if not ac.worldCoordinateToTrack then
    displayUnsupported = true
    logger.log("[Line Learning] ac.worldCoordinateToTrack indisponível — linha híbrida desativada")
    return
  end

  -- Phase A: build the AI-line lat baseline (once per session, amortized)
  if aiLatBuilt < BUCKETS then
    local target = math.min(BUCKETS, aiLatBuilt + AILAT_CHUNK)
    for b = aiLatBuilt + 1, target do
      local progress = (b - 0.5) / BUCKETS
      local idx = math.max(1, math.min(math.floor(progress * detailCount) + 1, detailCount))
      local pt = aiLoader.points[idx]
      if pt and pt.worldPos then
        local okT, tp = pcall(ac.worldCoordinateToTrack, pt.worldPos)
        aiLat[b] = (okT and tp) and math.max(-1.0, math.min(1.0, tp.x)) or 0
      else
        aiLat[b] = 0
      end
    end
    aiLatBuilt = target
    return
  end

  -- Phase B: start a rebuild when learning changed
  if dirtyLine and rebuildIdx == 0 then
    dirtyLine = false
    computeDisplayLat(trackLength)
    if not displayPos then
      displayPos = {}
      displayPerp = {}
      for i = 1, detailCount do
        displayPos[i] = vec3()
        displayPerp[i] = vec3()
      end
    end
    rebuildIdx = 1
  end

  -- Phase C: convert a chunk of points
  if rebuildIdx > 0 then
    local target = math.min(detailCount, rebuildIdx + REBUILD_CHUNK - 1)
    for idx = rebuildIdx, target do
      convertDisplayPoint(idx, detailCount)
    end
    rebuildIdx = target + 1
    if rebuildIdx > detailCount then
      rebuildIdx = 0
      -- First point's perp was computed against a stale neighbor; fix it now
      convertDisplayPoint(1, detailCount)
      if not displayReady then
        logger.log("[Line Learning] Linha híbrida ativa (primeiro rebuild completo)")
      end
      displayReady = true
      rebuildCompleted = true
    end
  end
end

-- Returns true once after each completed rebuild (coordinator refreshes radii)
function M.consumeRebuildCompleted()
  local r = rebuildCompleted
  rebuildCompleted = false
  return r
end

function M.getDisplayPos(idx)
  if config.beginnerMode then return nil end
  if displayReady and displayPos then return displayPos[idx] end
  return nil
end

function M.getDisplayPerp(idx)
  if config.beginnerMode then return nil end
  if displayReady and displayPerp then return displayPerp[idx] end
  return nil
end

function M.isDisplayActive()
  if config.beginnerMode then return false end
  return displayReady
end

-- Lateral da AI line (-1..1) no progress dado; nil enquanto a baseline amortizada
-- ainda não terminou. Usado pela penalidade de desvio do modo iniciante.
function M.getAiLat(progress)
  if aiLatBuilt < BUCKETS then return nil end
  return aiLat[bucketOf(progress)]
end

-- Fraction of the track with learned data (settings UI)
function M.coverage()
  local filled = 0
  for b = 1, BUCKETS do
    if (M.learnedWeight[b] or 0) > 0 then filled = filled + 1 end
  end
  return filled / BUCKETS
end

-- Restore persisted line data (corner-store passes data.line through here)
function M.restore(line)
  if type(line) ~= "table" or line.bucketCount ~= BUCKETS then return false end
  if type(line.lat) ~= "table" or type(line.weight) ~= "table" then return false end
  M.learnedLat = {}
  M.learnedWeight = {}
  local filled = 0
  for b = 1, BUCKETS do
    local lat = line.lat[b]
    local w = line.weight[b]
    if type(lat) == "number" and type(w) == "number" and w > 0 then
      M.learnedLat[b] = math.max(-1.0, math.min(1.0, lat))
      M.learnedWeight[b] = math.min(1.0, w)
      filled = filled + 1
    end
  end
  logger.log(string.format("[Line Learning] Traçado restaurado: %d/%d buckets", filled, BUCKETS))
  if filled > 0 then dirtyLine = true end
  return filled > 0
end

-- Serialize for persistence (rounded to keep the JSON compact)
function M.serialize()
  local lat, weight = {}, {}
  local any = false
  for b = 1, BUCKETS do
    local w = M.learnedWeight[b] or 0
    if w > 0 then any = true end
    lat[b] = math.floor((M.learnedLat[b] or 0) * 1000 + 0.5) / 1000
    weight[b] = math.floor(w * 100 + 0.5) / 100
  end
  if not any then return nil end
  return { bucketCount = BUCKETS, lat = lat, weight = weight }
end

function M.reset()
  M.learnedLat = {}
  M.learnedWeight = {}
  curLat = {}
  curStamp = {}
  lastBucket = -1
  displayReady = false
  dirtyLine = false
  rebuildIdx = 0
  rebuildCompleted = false
end

return M
