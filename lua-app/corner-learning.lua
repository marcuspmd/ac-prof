-- Per-corner observation of the driver: validates each corner pass ("good pass"),
-- learns apex speeds (p85), and feeds validated segments to line-learning.
-- Owns the apex-result event (moved here from track-painter — rendering should not
-- own learning).
local physics = require('physics-calc')
local lineLearning = require('line-learning')
local logger = require('logger')

local M = {}

-- Set when calibratedVTarget changed; the coordinator tells track-painter to
-- recalculate the safe speed profile (max once per corner pass)
M.dirtyCalibration = false
M.lastApexResult = nil
M.pendingTip = nil

-- Cooldown so the same tip for the same corner waits at least 2 laps
local TIP_COOLDOWN_LAPS = 2
local lastTipLap = {}  -- "ci:type" -> lapCount when last emitted

-- Per-corner UI stats: stats[ci] = { valid, invalid, lastReason }
M.stats = {}

-- Runtime pass state per corner index
local passState = {}

local SEG_BEFORE_ENTRY_M = 30.0
local SEG_AFTER_APEX_M   = 60.0

local function safeGet(obj, field, default)
  if not obj then return default end
  local success, val = pcall(function() return obj[field] end)
  if success and val ~= nil then return val end
  return default
end

local function circularDistM(a, b, trackLength)
  local diff = a - b
  if diff > 0.5 then diff = diff - 1.0
  elseif diff < -0.5 then diff = diff + 1.0 end
  return diff * trackLength
end

-- Strong loss-of-control check: countersteer against a high yaw rate with the rear
-- sliding hard. Thresholds are well above the telemetry-recorder event ones so that
-- normal sliding does not invalidate a pass — only clear spins/big moments do.
local function isLosingControl(car)
  local angVel = safeGet(car, "localAngularVelocity", nil)
  local yawRate = angVel and angVel.y or 0
  if math.abs(yawRate) > 0.35 and car.speedMs > 10.0 then
    local steerLock = safeGet(car, "steerLock", 0)
    local steerNorm = (steerLock and steerLock > 0) and (car.steer / steerLock) or (car.steer / 20.0)
    local counterSteer = (steerNorm > 0) ~= (yawRate > 0)
    if counterSteer and car.wheels then
      local rearSlip = 0
      for i = 2, 3 do
        local w = car.wheels[i]
        rearSlip = rearSlip + math.abs(safeGet(w, "slipAngle", 0))
      end
      rearSlip = rearSlip / 2
      if rearSlip > 12.0 then return true end
    end
  end
  return false
end

local function isOffTrack(car)
  if not car.wheels then return false end
  local offCount = 0
  for i = 0, 3 do
    local w = car.wheels[i]
    if w and safeGet(w, "surfaceValidTrack", true) == false then
      offCount = offCount + 1
    end
  end
  return offCount >= 2
end

local function startPass(state, car)
  state.inPass = true
  state.startLapMs = car.lapTimeMs or 0
  state.startStamp = lineLearning.currentStamp()
  state.invalidReason = nil
  state.apexCandidateMs = nil
  state.brakeStartProgress = nil
  -- Trail-braking accumulators
  state.trailDecelSum = 0
  state.trailDecelCount = 0
  -- Coaching observations: brake pressure profile in 5 slices of entry→apex
  state.brakeProfileSum = { 0, 0, 0, 0, 0 }
  state.brakeProfileCount = { 0, 0, 0, 0, 0 }
  state.brakeTooDeep = false
  state.lockupFlag = false
  state.wheelspinFlag = false
end

-- Build all applicable coaching tips for this pass; only the most severe one
-- (respecting per-corner cooldowns) is actually shown
local function buildTips(ci, turn, state, car, trackLength)
  local tips = {}
  local function add(tipType, severity, text)
    table.insert(tips, { type = tipType, severity = severity, text = text, cornerIndex = ci })
  end

  local apexMs = state.apexCandidateMs
  local vPhys = turn.vPhysics

  if state.invalidReason == "perda de controle" then
    add("corner_speed_risky", 3, string.format("C%d: perdeu o carro — entre mais devagar e acelere só depois do ápice", ci))
  end

  if apexMs and vPhys then
    local gapKmh = (vPhys - apexMs) * 3.6
    if gapKmh < -2 then
      add("corner_speed_risky", 3, string.format("C%d: %.0f km/h acima do limite físico — risco de rodar", ci, -gapKmh))
    elseif gapKmh > 8 and (turn.passCount or 0) >= 2 then
      add("corner_speed_low", 2, string.format("C%d: entrou %.0f km/h abaixo do possível (teto %.0f km/h)", ci, gapKmh, vPhys * 3.6))
    end
  end

  if state.brakeStartProgress and turn.brakePointProgress and (turn.brakeObsCount or 0) >= 3 then
    -- positive = braked before the learned point (early)
    local dM = circularDistM(turn.brakePointProgress, state.brakeStartProgress, trackLength)
    if dM > 15 then
      add("brake_early", 1, string.format("C%d: freou %.0fm antes do seu melhor ponto", ci, dM))
    elseif dM < -12 and state.invalidReason then
      add("brake_late", 2, string.format("C%d: freou %.0fm tarde demais para essa entrada", ci, -dM))
    end
  end

  -- Trail braking: all the braking dumped at entry, nothing held toward the apex,
  -- and still slower than target = released too early
  local p = {}
  for s = 1, 5 do
    p[s] = state.brakeProfileCount[s] > 0 and (state.brakeProfileSum[s] / state.brakeProfileCount[s]) or 0
  end
  local lateAvg = (p[3] + p[4] + p[5]) / 3
  if p[1] > 0.5 and lateAvg < 0.08 and apexMs and turn.vTargetEffective
     and apexMs < turn.vTargetEffective - 1.5 then
    add("trail_release_early", 2, string.format("C%d: soltou o freio cedo — sustente leve até perto do ápice (trail braking)", ci))
  end
  if state.brakeTooDeep then
    add("brake_too_deep", 2, string.format("C%d: muito freio no ápice — termine a frenagem mais cedo", ci))
  end
  if state.lockupFlag then
    add("lockup", 2, string.format("C%d: travou roda na frenagem — module a pressão", ci))
  end
  if state.wheelspinFlag then
    add("wheelspin", 1, string.format("C%d: patinou na saída — acelere mais progressivo", ci))
  end

  -- Tyre temperature window, per axle (front = wheels 0-1, rear = 2-3)
  if car.wheels then
    local axles = { { 0, 1, "Dianteiros" }, { 2, 3, "Traseiros" } }
    for _, axle in ipairs(axles) do
      local tSum, oSum, n = 0, 0, 0
      for i = axle[1], axle[2] do
        local w = car.wheels[i]
        local tCore = safeGet(w, "tyreCoreTemperature", 0)
        local tOpt = safeGet(w, "tyreOptimumTemperature", 0)
        if tCore > 0 then
          tSum = tSum + tCore
          oSum = oSum + (tOpt > 0 and tOpt or 85)
          n = n + 1
        end
      end
      if n > 0 then
        local tAvg, oAvg = tSum / n, oSum / n
        local diff = tAvg - oAvg
        if math.abs(diff) > 15 then
          -- Same grip-loss model as physics-calc getPhysicsFactors
          local gripLossPct = math.floor(math.min(0.25, (math.abs(diff) / 40) ^ 2 * 0.25) * 100 + 0.5)
          if diff < 0 then
            add("tyre_cold", 1, string.format("%s frios (%.0f°C vs %.0f°C): −%d%% grip", axle[3], tAvg, oAvg, gripLossPct))
          else
            add("tyre_hot", 1, string.format("%s superaquecidos (%.0f°C vs %.0f°C): −%d%% grip", axle[3], tAvg, oAvg, gripLossPct))
          end
        end
      end
    end
  end

  return tips
end

local function emitBestTip(tips, car)
  if #tips == 0 then return end
  table.sort(tips, function(a, b) return a.severity > b.severity end)
  local lapCount = car.lapCount or 0
  for _, tip in ipairs(tips) do
    local key = tip.cornerIndex .. ":" .. tip.type
    local last = lastTipLap[key]
    if not last or (lapCount - last) >= TIP_COOLDOWN_LAPS then
      lastTipLap[key] = lapCount
      M.pendingTip = tip
      return
    end
  end
end

local function finalizePass(ci, turn, state, car, trackLength, roadGrip)
  state.inPass = false

  local st = M.stats[ci]
  if not st then
    st = { valid = 0, invalid = 0, lastReason = nil }
    M.stats[ci] = st
  end

  -- Criterion 4: plausible apex speed — filters out-laps, pit exits and traffic
  if not state.invalidReason then
    local vRef = turn.vTargetEffective or turn.vTargetAI or 0
    if not state.apexCandidateMs then
      state.invalidReason = "sem leitura no ápice"
    elseif vRef > 0 and state.apexCandidateMs < vRef * 0.7 then
      state.invalidReason = "lento demais (out-lap?)"
    end
  end

  -- Coaching tips fire for valid and invalid passes alike (a spin is exactly
  -- when "entre mais devagar" matters)
  emitBestTip(buildTips(ci, turn, state, car, trackLength), car)

  if state.invalidReason then
    st.invalid = st.invalid + 1
    st.lastReason = state.invalidReason
    return
  end

  st.valid = st.valid + 1
  st.lastReason = nil
  turn.passCount = (turn.passCount or 0) + 1

  -- ── Apex speed calibration (deferred to pass exit so a spin after the apex
  -- still invalidates the sample) ──────────────────────────────────────────
  local prevBestMs = 0
  for _, v in ipairs(turn.observedSpeeds) do
    if v > prevBestMs then prevBestMs = v end
  end

  table.insert(turn.observedSpeeds, state.apexCandidateMs)
  if #turn.observedSpeeds > 15 then table.remove(turn.observedSpeeds, 1) end

  if #turn.observedSpeeds >= 3 then
    local sorted = {}
    for _, v in ipairs(turn.observedSpeeds) do table.insert(sorted, v) end
    table.sort(sorted)
    local p85idx = math.max(1, math.floor(#sorted * 0.85))
    turn.calibratedVTarget = sorted[p85idx]
    M.dirtyCalibration = true
  end

  if prevBestMs > 0 then
    local apexMs = state.apexCandidateMs
    local deltaKmh = (apexMs - prevBestMs) * 3.6
    local targetKmh = turn.calibratedVTarget and turn.calibratedVTarget * 3.6
                      or turn.vTargetAI * 3.6
    M.lastApexResult = {
      cornerIndex = ci,
      currentKmh  = math.floor(apexMs * 3.6 * 10 + 0.5) / 10,
      bestKmh     = math.floor(prevBestMs * 3.6 * 10 + 0.5) / 10,
      deltaKmh    = math.floor(deltaKmh * 10 + 0.5) / 10,
      targetKmh   = math.floor(targetKmh * 10 + 0.5) / 10,
      isPB        = (apexMs > prevBestMs),
      obsCount    = #turn.observedSpeeds,
      physicsKmh  = turn.vPhysics and math.floor(turn.vPhysics * 3.6 * 10 + 0.5) / 10 or nil,
      gapToPhysicsKmh = turn.vPhysics and math.floor((turn.vPhysics - apexMs) * 3.6 * 10 + 0.5) / 10 or nil,
      confidence  = math.min(1, #turn.observedSpeeds / 5),
    }
  end

  -- ── Trail braking: real deceleration between entry and apex, normalized by the
  -- same full-braking capability the safe-speed profile uses (so the learned ratio
  -- replaces the fixed config.trailBrakingFactor consistently) ─────────────────
  if state.trailDecelCount >= 10 then
    local factors = physics.getPhysicsFactors(car, state.apexCandidateMs or car.speedMs)
    local fullDecelG = physics.maxObservedDecelG * 0.80 * math.max(0.5, roadGrip or 1.0)
                       * factors.aeroGripMultiplier * factors.brakeEfficiency
    if fullDecelG > 0.1 then
      local ratio = (state.trailDecelSum / state.trailDecelCount) / fullDecelG
      ratio = math.max(0.20, math.min(0.70, ratio))
      local before = turn.trailDecelRatio
      if before then
        turn.trailDecelRatio = before + 0.3 * (ratio - before)
      else
        turn.trailDecelRatio = ratio
      end
      turn.trailObsCount = (turn.trailObsCount or 0) + 1
      M.dirtyCalibration = true
      logger.log(string.format("[Corner Learning] C%d: trailRatio %.2f→%.2f (n=%d)",
        ci, before or 0.40, turn.trailDecelRatio, turn.trailObsCount))
    end
  end

  -- ── Braking point: where the driver actually starts braking on good passes ──
  if state.brakeStartProgress then
    if turn.brakePointProgress then
      local diff = state.brakeStartProgress - turn.brakePointProgress
      if diff > 0.5 then diff = diff - 1.0 elseif diff < -0.5 then diff = diff + 1.0 end
      turn.brakePointProgress = (turn.brakePointProgress + 0.3 * diff) % 1.0
    else
      turn.brakePointProgress = state.brakeStartProgress
    end
    turn.brakeObsCount = (turn.brakeObsCount or 0) + 1
    -- Brake markers live in the safe-speed profile recalc, so refresh it
    M.dirtyCalibration = true
    if turn.brakeObsCount == 3 then
      logger.log(string.format("[Corner Learning] C%d: ponto de frenagem aprendido (n=3)", ci))
    end
  end

  -- ── Line learning gate: only segment times proven fast may move the line ──
  local segTimeMs = nil
  local endLapMs = car.lapTimeMs or 0
  if endLapMs > state.startLapMs then
    segTimeMs = endLapMs - state.startLapMs
  end
  if not segTimeMs then return end  -- lap rollover inside the segment: skip line learning

  local best = turn.bestSegmentMs
  local isPB = (not best) or segTimeMs < best
  local isNearPB = best and segTimeMs <= best * 1.02

  if isPB or isNearPB then
    local segStart = turn.entryProgress - SEG_BEFORE_ENTRY_M / trackLength
    local segEnd = turn.apexProgress + SEG_AFTER_APEX_M / trackLength
    local alpha = isPB and 0.5 or 0.25
    local merged = lineLearning.mergePass(segStart, segEnd, alpha, state.startStamp)
    if merged > 0 then
      logger.log(string.format("[Corner Learning] C%d: traçado aprendido (%d buckets, α=%.2f, seg=%.0fms%s)",
        ci, merged, alpha, segTimeMs, isPB and ", PB" or ""))
    end
  end
  if isPB then
    turn.bestSegmentMs = segTimeMs
  end
end

-- Per-frame update. corners = track-painter's allTrackCorners.
function M.update(car, sim, corners)
  if not car or not corners or #corners == 0 then return end
  local trackLength = sim and sim.trackLengthM or 0
  if trackLength <= 100 then return end

  local pos = car.splinePosition % 1.0

  for ci, turn in ipairs(corners) do
    local state = passState[ci]
    if not state then
      state = { inPass = false }
      passState[ci] = state
    end

    local distToApex = circularDistM(turn.apexProgress, pos, trackLength)
    local distEntryToApex = math.abs(circularDistM(turn.apexProgress, turn.entryProgress or turn.apexProgress, trackLength))
    local inSegment = distToApex >= -SEG_AFTER_APEX_M and distToApex <= (distEntryToApex + SEG_BEFORE_ENTRY_M)

    if inSegment and not state.inPass then
      startPass(state, car)
    elseif not inSegment and state.inPass then
      finalizePass(ci, turn, state, car, trackLength, sim and sim.roadGrip or 1.0)
    end

    if state.inPass and not state.invalidReason then
      -- Criteria 1-3 accumulate over the whole pass
      if safeGet(car, "collisionDepth", 0) > 0.01 then
        state.invalidReason = "colisão"
      elseif isOffTrack(car) then
        state.invalidReason = "fora da pista"
      elseif isLosingControl(car) then
        state.invalidReason = "perda de controle"
      end

      -- Apex speed candidate: same window and conditions as the old painter logic
      if not state.invalidReason and not state.apexCandidateMs
         and distToApex > -15 and distToApex < 5
         and car.speedMs > 5.5 and (car.brake or 0) < 0.5 then
        state.apexCandidateMs = car.speedMs
      end

      -- Braking observations
      local brake = car.brake or 0
      if distToApex > 0 then
        if not state.brakeStartProgress and brake > 0.3 then
          state.brakeStartProgress = pos
        end
        if distToApex < distEntryToApex and brake > 0.05 then
          local acc = safeGet(car, "acceleration", nil)
          if acc then
            state.trailDecelSum = state.trailDecelSum + math.max(0, -acc.z)
            state.trailDecelCount = state.trailDecelCount + 1
          end
        end
        -- Brake pressure profile: slice 1 = entry, slice 5 = at the apex
        if distToApex < distEntryToApex and distEntryToApex > 5 then
          local slice = math.min(5, math.max(1, math.ceil((1 - distToApex / distEntryToApex) * 5)))
          state.brakeProfileSum[slice] = state.brakeProfileSum[slice] + brake
          state.brakeProfileCount[slice] = state.brakeProfileCount[slice] + 1
        end
      end
      if distToApex > -2 and distToApex < 10 and brake > 0.4 then
        state.brakeTooDeep = true
      end

      -- Lockup / wheelspin flags (high thresholds — clear events only)
      if car.wheels and (brake > 0.15 or (car.gas or 0) > 0.2) then
        for i = 0, 3 do
          local sr = safeGet(car.wheels[i], "slipRatio", 0)
          if brake > 0.15 and sr < -0.25 then state.lockupFlag = true end
          if (car.gas or 0) > 0.2 and i >= 2 and sr > 0.25 then state.wheelspinFlag = true end
        end
      end
    end
  end
end

-- Returns and clears the last apex result (call once per frame from coordinator)
function M.popApexResult()
  local r = M.lastApexResult
  M.lastApexResult = nil
  return r
end

-- Returns and clears the pending coach tip as an array (overlay payload)
function M.popCoachTips()
  if not M.pendingTip then return nil end
  local tips = { M.pendingTip }
  M.pendingTip = nil
  return tips
end

function M.reset()
  passState = {}
  M.stats = {}
  M.dirtyCalibration = false
  M.lastApexResult = nil
  M.pendingTip = nil
  lastTipLap = {}
end

return M
