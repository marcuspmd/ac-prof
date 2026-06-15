-- 3D Track Paint rendering for Race Coach Overlay
local config = require('config')
local physics = require('physics-calc')
local aiLoader = require('ai-loader')
local cornerStore = require('corner-store')
local lineLearning = require('line-learning')
local logger = require('logger')
local M = {}

local racingPainter = ac.TrackPaint()
racingPainter.forceRecast = true
racingPainter.ageFactor = 0.1
racingPainter.bulgeFactor = 0.4

local brakingPainter = ac.TrackPaint()
brakingPainter.forceRecast = true
brakingPainter.ageFactor = 0.1
brakingPainter.bulgeFactor = 0.4

local accelerationPainter = ac.TrackPaint()
accelerationPainter.forceRecast = true
accelerationPainter.ageFactor = 0.1
accelerationPainter.bulgeFactor = 0.4

local brakeMarkerPainter = ac.TrackPaint()
brakeMarkerPainter.forceRecast = true
brakeMarkerPainter.ageFactor = 0.05
brakeMarkerPainter.bulgeFactor = 0.1

local allTrackCorners = {}
local isTrackScanned = false
local lastTrackLength = 0
local maxObservedSpeedKmh = 0

-- Cache variables for the pre-calculated safe speed profile
M.safeSpeedProfile = {}
M.brakeMarkers = {}         -- {progress, worldPos, perp, apexProgress}
local lastSpeedMult = -1
local lastMaxObservedDecelG = -1
local lastRoadGrip = -1
local lastTyreGrip = -1
local hasLoggedCornerTargets = false

-- Helper function to interpolate between two rgbm colors
local function lerpColor(c1, c2, t)
  return rgbm(
    c1.r + (c2.r - c1.r) * t,
    c1.g + (c2.g - c1.g) * t,
    c1.b + (c2.b - c1.b) * t,
    c1.mult + (c2.mult - c1.mult) * t
  )
end

-- Map speed delta (car.speedMs - vSafe) to a green/red intensity gradient.
-- Intensity indicates how much the driver can push (green) or must brake (red).
local function getSpeedRelativeColor(deltaKmh)
  local cDarkGreen  = rgbm(0, 0.55, 0, 0.75)
  local cLightGreen = rgbm(0.3, 0.9, 0.3, 0.65)
  local cLightRed   = rgbm(0.9, 0.3, 0.3, 0.65)
  local cDarkRed    = rgbm(0.6, 0, 0, 0.8)

  if deltaKmh <= -10 then
    return cDarkGreen
  elseif deltaKmh < 0 then
    local t = (deltaKmh + 10) / 10
    return lerpColor(cDarkGreen, cLightGreen, t)
  elseif deltaKmh <= 12 then
    local t = deltaKmh / 12
    return lerpColor(cLightRed, cDarkRed, t)
  else
    return cDarkRed
  end
end

-- Helper function to get world position of a spline point. Prefers the hybrid
-- display line once it is built: curvature/radius must follow the drawn line.
local function getSplineWorldPos(idx, detailCount)
  local dp = lineLearning.getDisplayPos(idx)
  if dp then return dp end
  if aiLoader.points[idx] and aiLoader.points[idx].worldPos then
    return aiLoader.points[idx].worldPos
  else
    local p = (idx - 1) / detailCount
    return ac.trackProgressToWorldCoordinate(p, true)
  end
end

-- Helper function to calculate track curvature at a given spline index
local function getCurvatureAt(idx, detailCount)
  local prevIdx = ((idx - 2) % detailCount) + 1
  local currIdx = idx
  local nextIdx = (idx % detailCount) + 1

  local pos1 = getSplineWorldPos(prevIdx, detailCount)
  local pos2 = getSplineWorldPos(currIdx, detailCount)
  local pos3 = getSplineWorldPos(nextIdx, detailCount)

  if not pos1 or not pos2 or not pos3 then return 0 end

  -- Calculate tangent vectors in XZ plane (ignoring vertical changes)
  local t1x, t1z = pos2.x - pos1.x, pos2.z - pos1.z
  local t2x, t2z = pos3.x - pos2.x, pos3.z - pos2.z

  local len1 = math.sqrt(t1x * t1x + t1z * t1z)
  local len2 = math.sqrt(t2x * t2x + t2z * t2z)

  if len1 < 0.001 or len2 < 0.001 then return 0 end

  local nt1x, nt1z = t1x / len1, t1z / len1
  local nt2x, nt2z = t2x / len2, t2z / len2

  -- Curvature = dt / ds
  local dtx = nt2x - nt1x
  local dtz = nt2z - nt1z
  local dtLen = math.sqrt(dtx * dtx + dtz * dtz)

  return dtLen / len1
end

-- Curvature averaged over ±5 spline points to filter out mesh noise in the
-- second differences of worldPos (pre-calculated tracks have sub-meter spacing)
local function getSmoothedCurvatureAt(idx, detailCount)
  local sum, count = 0, 0
  for w = -5, 5 do
    local checkIdx = ((idx + w - 1) % detailCount) + 1
    sum = sum + getCurvatureAt(checkIdx, detailCount)
    count = count + 1
  end
  return sum / count
end

-- Derive the geometric radius of each corner from the spline curvature around the
-- apex (±15m). The tightest point governs the speed ceiling. Clamped to [8, 500]m:
-- below 8m is hairpin-noise territory, above 500m the corner barely limits speed.
local function computeCornerRadii(detailCount, mPerPoint)
  local zoneWindow = math.max(1, math.floor(15 / mPerPoint))
  for _, turn in ipairs(allTrackCorners) do
    local maxCurv = 0
    for w = -zoneWindow, zoneWindow do
      local checkIdx = ((turn.idx + w - 1) % detailCount) + 1
      local c = getSmoothedCurvatureAt(checkIdx, detailCount)
      if c > maxCurv then maxCurv = c end
    end
    if maxCurv > 1e-6 then
      turn.radiusM = math.max(8, math.min(500, 1 / maxCurv))
    end
  end
end

-- Helper function to pre-scan track spline for corners on session startup
-- Uses the AI speed profile and braking/throttle triggers to detect real apexes
local function preScanTrackCorners(sim)
  if not sim or not sim.trackLengthM or sim.trackLengthM <= 100 then return M end
  
  local trackLength = sim.trackLengthM
  
  -- Make sure AI line is loaded
  aiLoader.loadAiLine()
  
  allTrackCorners = {}
  
  local detailCount = aiLoader.detailCount
  if detailCount <= 0 then return end
  
  local mPerPoint = trackLength / detailCount
  local w1 = math.max(2, math.floor(8 / mPerPoint)) -- 8m window
  local w2 = math.max(5, math.floor(15 / mPerPoint)) -- 15m window
  local lookBackWindow = math.max(5, math.floor(40 / mPerPoint))
  
  local detectedApexes = {} -- map: idx -> speedKmh
  
  local function runScanPass(windowSize, dropThreshold)
    for i = 1, detailCount do
      local progress = (i - 1) / detailCount
      local _, _, speedKmh = aiLoader.getAiInputAtProgress(progress)
      
      -- Check if it's a local minimum of speed
      local isMin = true
      local maxSpeedInWindow = speedKmh
      for w = -windowSize, windowSize do
        if w ~= 0 then
          local checkP = (progress + w / detailCount + 1.0) % 1.0
          local _, _, wSpeedKmh = aiLoader.getAiInputAtProgress(checkP)
          if wSpeedKmh < speedKmh - 0.1 then
            isMin = false
            break
          end
          if wSpeedKmh > maxSpeedInWindow then
            maxSpeedInWindow = wSpeedKmh
          end
        end
      end
      
      if isMin and (maxSpeedInWindow - speedKmh) >= dropThreshold then
        -- Verify decel trigger: require real braking or a meaningful lift, not the
        -- micro-throttle ripples the AI line has along straights (those were spawning
        -- phantom "corners" that painted braking zones mid-straight).
        local hasDecelTrigger = false
        for w = -lookBackWindow, 0 do
          local checkP = (progress + w / detailCount + 1.0) % 1.0
          local wGas, wBrake, _ = aiLoader.getAiInputAtProgress(checkP)
          if wBrake > 0.02 or wGas < 0.80 then
            hasDecelTrigger = true
            break
          end
        end
        
        if hasDecelTrigger then
          detectedApexes[i] = speedKmh
        end
      end
    end
  end
  
  -- Detection stays sensitive on purpose: within a ±8/±15 m window even a real fast
  -- sweeper only drops a couple km/h at the apex, so a high threshold would miss it.
  -- Phantom "corners" on straights are removed afterwards by the geometric radius
  -- filter (a straight has no curvature), so we don't need an aggressive drop gate here.
  -- Pass 1: 8m search for chicanes / hairpins
  runScanPass(w1, 0.8)

  -- Pass 2: 15m search for sweeping corners
  runScanPass(w2, 1.2)
  
  -- Collect detected apexes
  local tempApexes = {}
  for idx, speedKmh in pairs(detectedApexes) do
    table.insert(tempApexes, {
      idx = idx,
      speedKmh = speedKmh,
      progress = (idx - 1) / detailCount
    })
  end
  
  -- Sort by index
  table.sort(tempApexes, function(a, b) return a.idx < b.idx end)
  
  -- Proximity merge (< 15 meters)
  for _, current in ipairs(tempApexes) do
    if #allTrackCorners == 0 then
      local apexIdx = current.idx
      local entryIdx = apexIdx
      local minCurvature = 0.004
      local maxSearchBack = math.floor(200 / mPerPoint)
      for w = -1, -maxSearchBack, -1 do
        local checkIdx = ((apexIdx + w - 1) % detailCount) + 1
        local c = getCurvatureAt(checkIdx, detailCount)
        if c < minCurvature then
          entryIdx = checkIdx
          break
        end
      end
      local entryProgress = (entryIdx - 1) / detailCount

      table.insert(allTrackCorners, {
        idx = current.idx,
        apexProgress = current.progress,
        entryProgress = entryProgress,
        vTargetAI = current.speedKmh / 3.6,
        speedKmh = current.speedKmh,
        observedSpeeds = {},
        calibratedVTarget = nil,
      })
    else
      local last = allTrackCorners[#allTrackCorners]
      local diff = current.progress - last.apexProgress
      if diff > 0.5 then diff = diff - 1.0
      elseif diff < -0.5 then diff = diff + 1.0 end
      local dist = math.abs(diff * trackLength)
      
      if dist < 15.0 then
        -- Merge: keep the slower one
        if current.speedKmh < last.speedKmh then
          last.idx = current.idx
          last.apexProgress = current.progress
          last.vTargetAI = current.speedKmh / 3.6
          last.speedKmh = current.speedKmh
          
          -- Recalculate entry progress for merged corner
          local apexIdx = current.idx
          local entryIdx = apexIdx
          local minCurvature = 0.004
          local maxSearchBack = math.floor(200 / mPerPoint)
          for w = -1, -maxSearchBack, -1 do
            local checkIdx = ((apexIdx + w - 1) % detailCount) + 1
            local c = getCurvatureAt(checkIdx, detailCount)
            if c < minCurvature then
              entryIdx = checkIdx
              break
            end
          end
          last.entryProgress = (entryIdx - 1) / detailCount
        end
      else
        local apexIdx = current.idx
        local entryIdx = apexIdx
        local minCurvature = 0.004
        local maxSearchBack = math.floor(200 / mPerPoint)
        for w = -1, -maxSearchBack, -1 do
          local checkIdx = ((apexIdx + w - 1) % detailCount) + 1
          local c = getCurvatureAt(checkIdx, detailCount)
          if c < minCurvature then
            entryIdx = checkIdx
            break
          end
        end
        local entryProgress = (entryIdx - 1) / detailCount

        table.insert(allTrackCorners, {
          idx = current.idx,
          apexProgress = current.progress,
          entryProgress = entryProgress,
          vTargetAI = current.speedKmh / 3.6,
          speedKmh = current.speedKmh,
          observedSpeeds = {},
          calibratedVTarget = nil,
          lastApexObsIdx = -999,
        })
      end
    end
  end

  computeCornerRadii(detailCount, mPerPoint)

  -- Keep only corners with real geometry. A straight has no curvature, so
  -- computeCornerRadii never sets radiusM (stays nil); near-zero curvature noise
  -- clamps to the 500 m ceiling. Either way the "corner" does not actually limit
  -- speed and must not pull the safe-speed profile below the straight speed
  -- (that was painting braking zones in the middle of straights).
  local RADIUS_LIMIT = 480
  local keptCorners = {}
  for _, turn in ipairs(allTrackCorners) do
    if turn.radiusM and turn.radiusM < RADIUS_LIMIT then
      table.insert(keptCorners, turn)
    end
  end
  local droppedCount = #allTrackCorners - #keptCorners
  allTrackCorners = keptCorners

  isTrackScanned = (#allTrackCorners > 0)
  M.allTrackCorners = allTrackCorners
  hasLoggedCornerTargets = false
  logger.log(string.format("[Pre-Scan] Dual Pass + Proximity Merge: %d real corners kept (%d phantom/straight discarded).",
    #allTrackCorners, droppedCount))
end

-- Pre-calculate maximum safe speed profile for the entire track to avoid runtime lookahead lag
function M.recalculateSafeSpeedProfile(car, roadGrip)
  local trackLength = lastTrackLength or 1.0
  local detailCount = aiLoader.detailCount
  if detailCount <= 0 then return end

  local maxDecelG = physics.maxObservedDecelG or 1.1
  -- speedMult (player vs AI top speed) only governs straight-line approach speed for brake
  -- markers below — NOT corner targets.
  local speedMult = M.speedMult or 1.0

  -- Lateral grip scaling vs the AI reference. Corner speed scales with sqrt(grip ratio),
  -- not with straight-line top speed: a car faster on the straights can corner the same.
  -- Coupling this to speedMult was the "arcade" inflation that demanded impossible
  -- mid-corner speeds and made the car slide. maxObservedLatG already reflects the
  -- player car's real measured lateral grip.
  local gripRatio = math.min(2.0, math.sqrt(physics.maxObservedLatG / 1.3))
  
  -- Tyre grip factors are speed-independent (temp, wear, dirt). Aero is computed per-corner at
  -- the corner's own speed to avoid using the car's current speed as a proxy for all corners.
  local tyreFactors = physics.getPhysicsFactors(car, 0)
  local tyreGripScale = math.sqrt(math.max(0.1, roadGrip * tyreFactors.tyreGrip))
  local cornerSpeedBias = config.cornerSpeedBias or 1.0
  local brakingMargin = config.brakingMargin or 1.0

  -- Cache active corner targets to avoid calling physics API inside the points loop
  local pushFactor = config.vTargetPushFactor or 0.3
  local activeCorners = {}
  for _, turn in ipairs(allTrackCorners) do
    -- Physical ceiling from corner geometry: v = sqrt(latG_available × g × R),
    -- with aero resolved iteratively at the corner's own speed
    local vPhysics = turn.radiusM and physics.solveCornerSpeed(car, turn.radiusM, roadGrip) or nil
    turn.vPhysics = vPhysics

    local vTargetCorner
    if config.beginnerMode then
      -- Modo Iniciante: ignora velocidades observadas do piloto. Teto físico
      -- limitado pela velocidade da AI line (alcançável por construção), com
      -- margem extra para quem ainda não está na linha ideal.
      if vPhysics then
        local vCeil = vPhysics
        if turn.vTargetAI then
          local vEstimate = turn.vTargetAI * gripRatio * tyreGripScale
          local aiAero = physics.getPhysicsFactors(car, vEstimate)
          local vAIScaled = vEstimate * math.sqrt(aiAero.aeroGripMultiplier)
          if vAIScaled < vCeil then vCeil = vAIScaled end
        end
        vTargetCorner = vCeil * (config.beginnerMargin or 0.90) * cornerSpeedBias
      elseif turn.vTargetAI then
        -- Sem raio geométrico (não deveria ocorrer após o filtro de pré-scan): nunca
        -- rebaixar o alvo abaixo da velocidade da AI line, senão pintaríamos frenagem
        -- onde a AI vai a fundo. Usa a própria velocidade da AI como teto.
        vTargetCorner = turn.vTargetAI * cornerSpeedBias
      end
    end
    if vTargetCorner then -- modo iniciante resolvido acima
    elseif turn.calibratedVTarget then
      local vObs = turn.calibratedVTarget
      if vPhysics and vPhysics > vObs then
        -- Push the target gradually from what the driver has proven toward the
        -- physical ceiling — never below the proven speed, never above physics
        vTargetCorner = (vObs + pushFactor * (vPhysics - vObs)) * cornerSpeedBias
      else
        -- Physics model underestimated (or no radius): trust the observation
        vTargetCorner = vObs * cornerSpeedBias
      end
    elseif vPhysics then
      -- No observations yet (lap 1): start from the physical ceiling
      vTargetCorner = vPhysics * cornerSpeedBias
    else
      -- Legacy fallback: estimate from AI line × grip ratio
      local vEstimate = turn.vTargetAI * gripRatio * tyreGripScale * cornerSpeedBias
      local cornerAeroFactors = physics.getPhysicsFactors(car, vEstimate)
      vTargetCorner = vEstimate * math.sqrt(cornerAeroFactors.aeroGripMultiplier)
    end
    turn.vTargetEffective = vTargetCorner

    -- Deceleration capability at corner speed
    local brakingFactors = physics.getPhysicsFactors(car, vTargetCorner)
    local targetDecel = maxDecelG * 9.81 * 0.80 * math.max(0.5, roadGrip) * brakingFactors.aeroGripMultiplier * brakingFactors.brakeEfficiency
    
    -- Calculate Entry-to-Apex distance
    local diffEntryToApex = turn.apexProgress - (turn.entryProgress or turn.apexProgress)
    if diffEntryToApex > 0.5 then diffEntryToApex = diffEntryToApex - 1.0
    elseif diffEntryToApex < -0.5 then diffEntryToApex = diffEntryToApex + 1.0 end
    local distEntryToApex = math.abs(diffEntryToApex * trackLength)
    
    -- Target speed at Corner Entry: trail deceleration is lower than straight-line
    -- braking. Uses the per-corner learned ratio when available, config seed otherwise.
    local trailDecel = targetDecel * (turn.trailDecelRatio or config.trailBrakingFactor or 0.40)
    local vTargetEntry = math.sqrt(vTargetCorner * vTargetCorner + 2 * trailDecel * distEntryToApex)
    
    table.insert(activeCorners, {
      turn = turn,
      vTargetApex = vTargetCorner,
      vTargetEntry = vTargetEntry,
      targetDecelFull = targetDecel,
      targetDecelTrail = trailDecel,
      distEntryToApex = distEntryToApex
    })
  end

  -- For each corner, compute the distance to the next corner's apex and store the next
  -- corner's target speed. Both are used by the post-apex exit ramp gate (see below).
  local CHICANE_MAX_M = 300.0
  local nc = #activeCorners
  for ci = 1, nc do
    local next = activeCorners[(ci % nc) + 1]
    local thisApex = activeCorners[ci].turn.apexProgress
    local nextApex = next.turn.apexProgress
    local diff = nextApex - thisApex
    if diff < 0 then diff = diff + 1.0 end
    activeCorners[ci].distToNextCorner = diff * trackLength
    activeCorners[ci].nextVTarget      = next.vTargetApex
  end

  if not hasLoggedCornerTargets then
    hasLoggedCornerTargets = true
    for ci, acCorner in ipairs(activeCorners) do
      local t = acCorner.turn
      logger.log(string.format("[Corner Targets] C%d: R=%sm vAI=%.0f vPhys=%s vObs85=%s alvo=%.0f km/h%s",
        ci,
        t.radiusM and string.format("%.0f", t.radiusM) or "?",
        t.vTargetAI * 3.6,
        t.vPhysics and string.format("%.0f", t.vPhysics * 3.6) or "?",
        t.calibratedVTarget and string.format("%.0f", t.calibratedVTarget * 3.6) or "-",
        acCorner.vTargetApex * 3.6,
        config.beginnerMode and " [iniciante]" or ""))
      if t.vPhysics and t.calibratedVTarget and t.calibratedVTarget > t.vPhysics then
        logger.log(string.format("[Corner Targets] C%d: observado %.0f > teto físico %.0f km/h — modelo subestimou (R ou latG)",
          ci, t.calibratedVTarget * 3.6, t.vPhysics * 3.6))
      end
    end
  end

  M.safeSpeedProfile = {}
  local reactionTime = 0.15

  for i = 1, detailCount do
    local p = (i - 1) / detailCount
    local minVSafe = 999.0 -- infinity fallback

    for _, acCorner in ipairs(activeCorners) do
      -- Distance from current point to Entry
      local diffEntry = (acCorner.turn.entryProgress or acCorner.turn.apexProgress) - p
      if diffEntry > 0.5 then diffEntry = diffEntry - 1.0
      elseif diffEntry < -0.5 then diffEntry = diffEntry + 1.0 end
      local distToEntry = diffEntry * trackLength

      -- Distance from current point to Apex
      local diffApex = acCorner.turn.apexProgress - p
      if diffApex > 0.5 then diffApex = diffApex - 1.0
      elseif diffApex < -0.5 then diffApex = diffApex + 1.0 end
      local distToApex = diffApex * trackLength

      if distToApex >= 0 then
        local vSafeCorner = 999.0

        if distToEntry >= 0 then
          -- Before Entry: full braking deceleration to vTargetEntry at the Entry point
          local B = acCorner.targetDecelFull * reactionTime
          local C = -(acCorner.vTargetEntry * acCorner.vTargetEntry + (2 * acCorner.targetDecelFull * distToEntry) / brakingMargin)
          vSafeCorner = -B + math.sqrt(math.max(0, B * B - C))
        else
          -- Past Entry, before Apex: trail braking deceleration to vTargetApex at the Apex
          local B = acCorner.targetDecelTrail * reactionTime
          local C = -(acCorner.vTargetApex * acCorner.vTargetApex + (2 * acCorner.targetDecelTrail * distToApex) / brakingMargin)
          vSafeCorner = -B + math.sqrt(math.max(0, B * B - C))
        end

        if vSafeCorner < minVSafe then
          minVSafe = vSafeCorner
        end
      elseif (acCorner.distToNextCorner or math.huge) <= CHICANE_MAX_M
          and (acCorner.nextVTarget or 0) < acCorner.vTargetApex * 1.5 then
        -- Post-apex exit ramp — tight chicane complexes only (≤ 300 m to next apex AND
        -- next corner is not dramatically faster than this one). When the next corner is
        -- fast (ratio > 1.5×), its own braking profile handles the approach; applying the
        -- ramp there would show a misleading "brake" signal on an acceleration zone.
        local distFromApex = -distToApex
        if distFromApex <= acCorner.distToNextCorner then
          local accelMs2 = physics.maxObservedAccelG * 9.81
          local vExitMax = math.sqrt(acCorner.vTargetApex * acCorner.vTargetApex + 2.0 * accelMs2 * distFromApex)
          if vExitMax < minVSafe then minVSafe = vExitMax end
        end
      end
    end
    M.safeSpeedProfile[i] = minVSafe
  end

  lastSpeedMult = speedMult
  lastMaxObservedDecelG = maxDecelG
  lastRoadGrip = roadGrip
  lastTyreGrip = tyreFactors.tyreGrip

  -- Build brake markers: calculate the braking point for each corner
  M.brakeMarkers = {}
  local nc = #activeCorners
  for ci, acCorner in ipairs(activeCorners) do
    local entryProgress = acCorner.turn.entryProgress or acCorner.turn.apexProgress
    local entryIdx = math.floor(entryProgress * detailCount) + 1

    -- Find max approach speed: scan back to the AI's last full-throttle point.
    -- A 60-pt window puts us deep inside the AI's own braking zone on long
    -- approaches (e.g. San Donato), so AI_speed × speedMult severely
    -- underestimates slower cars' real approach speed. Stopping at the
    -- gas→brake transition gives the actual flat-out approach speed.
    local maxApproachMs = acCorner.vTargetEntry
    local mPP = trackLength / detailCount
    local approachScanLimit = math.min(detailCount - 1, math.floor(600.0 / mPP))
    for w = 5, approachScanLimit do
      local checkIdx = ((entryIdx - w - 1 + detailCount) % detailCount) + 1
      local wGas, _, wKmh = aiLoader.getAiInputAtProgress((checkIdx - 1) / detailCount)
      local wMs = wKmh * speedMult / 3.6
      if wMs > maxApproachMs then maxApproachMs = wMs end
      if wGas >= 0.90 and w > 10 then break end
    end

    -- Cap approach speed at what the car can physically achieve accelerating from
    -- the previous corner's apex. Prevents the extended scan from reaching back
    -- through a prior braking zone and inflating the brake distance for
    -- closely-spaced corners (e.g. C14 right after C13 at Mugello).
    if nc > 1 then
      local prevAcCorner = activeCorners[ci > 1 and ci-1 or nc]
      local prevApexProg = prevAcCorner.turn.apexProgress
      local diffProg = entryProgress - prevApexProg
      if diffProg < -0.5 then diffProg = diffProg + 1.0
      elseif diffProg > 0.5 then diffProg = diffProg - 1.0 end
      if diffProg > 0 then
        local distPrevToEntry = diffProg * trackLength
        local accelMs2 = physics.maxObservedAccelG * 9.81
        local maxFromPrev = math.sqrt(prevAcCorner.vTargetApex^2 + 2.0 * accelMs2 * distPrevToEntry)
        if maxFromPrev < maxApproachMs then maxApproachMs = maxFromPrev end
      end
    end

    -- Prefer the braking point actually observed on the driver's good passes (F5);
    -- fall back to the physical estimate until 3 observations exist.
    -- Modo iniciante: sempre a estimativa física — o ponto aprendido vem das voltas do piloto.
    local brakingProgress = nil
    if not config.beginnerMode and (acCorner.turn.brakeObsCount or 0) >= 3 and acCorner.turn.brakePointProgress then
      brakingProgress = acCorner.turn.brakePointProgress % 1.0
    elseif maxApproachMs > acCorner.vTargetEntry + 2.0 then
      local brakeDist = (maxApproachMs * maxApproachMs - acCorner.vTargetEntry * acCorner.vTargetEntry)
                        / (2 * acCorner.targetDecelFull)
      local reactDist = maxApproachMs * 0.15 * (config.reactionMargin or 1.0)
      local totalDist  = (brakeDist + reactDist) * (brakingMargin or 1.0)
      brakingProgress = entryProgress - totalDist / trackLength
      while brakingProgress < 0 do brakingProgress = brakingProgress + 1.0 end
    end

    if brakingProgress then
      local bpWorldPos = ac.trackProgressToWorldCoordinate(brakingProgress, true)
      if bpWorldPos then
        -- Calculate perpendicular vector at braking point
        local perpVec = vec3(0, 0, 0)
        if aiLoader.isPreCalculated then
          local bpIdx = math.max(1, math.min(math.floor(brakingProgress * detailCount) + 1, detailCount))
          if aiLoader.points[bpIdx] and aiLoader.points[bpIdx].perp then
            perpVec = aiLoader.points[bpIdx].perp
          end
        end
        if perpVec:length() < 0.001 then
          local bpNext = ac.trackProgressToWorldCoordinate(brakingProgress + 2.0 / trackLength, true)
          if bpNext then
            local tang = bpNext - bpWorldPos
            tang.y = 0
            local len = tang:length()
            if len > 0.001 then perpVec = vec3(-tang.z, 0, tang.x) * (1.0 / len) end
          end
        end

        table.insert(M.brakeMarkers, {
          progress     = brakingProgress,
          worldPos     = bpWorldPos,
          perp         = perpVec,
          apexProgress = acCorner.turn.apexProgress,
        })
      end
    end
  end

  logger.log(string.format("[Safe Speed Profile] Recalculated for %d points. activeCorners: %d", detailCount, #activeCorners))
end

-- Render the 3D racing line and optimized braking point indicators on the track surface
function M.drawRacingLine(car, sim, nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded, maxObservedDecelG)
  local trackLength = sim and sim.trackLengthM or 1.0
  local roadGrip = sim and sim.roadGrip or 1.0

  -- If track length changes or scan has not run yet, perform pre-scan for apexes
  if not isTrackScanned or trackLength ~= lastTrackLength then
    preScanTrackCorners(sim)
    lastTrackLength = trackLength
    maxObservedSpeedKmh = 0 -- Reset speed calibration on new session/track!
    lastSpeedMult = -1
    lastMaxObservedDecelG = -1
    lastRoadGrip = -1
    lastTyreGrip = -1

    -- Restore persisted calibration (apex speeds, G-limits, speed multiplier)
    -- for this track+car+grip so no warm-up laps are needed
    if isTrackScanned then
      local okRestore, restored = pcall(cornerStore.restore, allTrackCorners, trackLength)
      if okRestore and restored and type(restored.speedMult) == "number" and restored.speedMult > 0.1 then
        local aiMax = aiLoader.aiMaxSpeedKmh or 0
        if aiMax > 10 then
          maxObservedSpeedKmh = restored.speedMult * aiMax
        end
      end
    end
  end

  -- Make sure AI line is loaded
  aiLoader.loadAiLine()

  local carSpeedKmh = car.speedMs * 3.6
  local aiMaxSpeed = aiLoader.aiMaxSpeedKmh or 100
  if aiMaxSpeed < 10 then aiMaxSpeed = 100 end

  -- Initialize maxObservedSpeedKmh with a smart class-based performance guess at start
  if maxObservedSpeedKmh < 10 then
    local playerTopSpeedGuess = 180
    local successDrs, drs = pcall(function() return car.drsPresent end)
    local successOpen, open = pcall(function() return car.isOpenWheeler end)
    local successRacing, racing = pcall(function() return car.isRacingCar end)
    if successDrs and drs then
      playerTopSpeedGuess = 320
    elseif successOpen and open then
      playerTopSpeedGuess = 280
    elseif successRacing and racing then
      playerTopSpeedGuess = 240
    end
    maxObservedSpeedKmh = playerTopSpeedGuess
  end

  local speedMult = maxObservedSpeedKmh / aiMaxSpeed

  -- Local dynamic calibration at full throttle on straights to prevent speed-trap deadlock
  local aiGas, aiBrake, aiSpeedKmh = aiLoader.getAiInputAtProgress(car.splinePosition)
  if car.gas > 0.90 and aiGas > 0.90 and aiBrake < 0.01 and aiSpeedKmh > 50.0 and carSpeedKmh > 80.0 then
    local localMult = carSpeedKmh / aiSpeedKmh
    if localMult > speedMult then
      maxObservedSpeedKmh = math.max(maxObservedSpeedKmh, localMult * aiMaxSpeed)
      speedMult = maxObservedSpeedKmh / aiMaxSpeed
      physics.speedMult = speedMult
      logger.log(string.format("[Calibration] Local scale update: speedMult = %.2f (localMult = %.2f)", speedMult, localMult))
    end
  end

  -- Global top speed calibration fallback
  if carSpeedKmh > maxObservedSpeedKmh + 2.0 then
    maxObservedSpeedKmh = carSpeedKmh
    speedMult = maxObservedSpeedKmh / aiMaxSpeed
    physics.speedMult = speedMult
    logger.log(string.format("[Calibration] New Player Max Speed = %.1f km/h, AI Max Speed = %.1f km/h, Multiplier = %.2f", maxObservedSpeedKmh, aiMaxSpeed, speedMult))
  end

  physics.speedMult = speedMult
  M.speedMult = speedMult

  -- Recalculate safe speed profile when calibration or physics factors change significantly.
  -- Tyre grip evolves as tyres warm up / wear, shifting the physical ceiling of every corner.
  local currentMaxDecelG = physics.maxObservedDecelG
  local currentTyreGrip = physics.getPhysicsFactors(car, 0).tyreGrip
  if math.abs(speedMult - lastSpeedMult) > 0.01 or
     math.abs(currentMaxDecelG - lastMaxObservedDecelG) > 0.02 or
     math.abs(roadGrip - lastRoadGrip) > 0.02 or
     math.abs(currentTyreGrip - lastTyreGrip) > 0.03 or
     #M.safeSpeedProfile == 0 then
    M.recalculateSafeSpeedProfile(car, roadGrip)
  end

  -- Reset all painters
  racingPainter:reset()
  brakingPainter:reset()
  accelerationPainter:reset()
  brakeMarkerPainter:reset()

  local lookAheadDistance = math.max(400, math.min(800, car.speedMs * 10))
  local detailCount = aiLoader.detailCount

  if config.showRacingLine and detailCount > 0 then
    if aiLoader.isPreCalculated then
      local carIdx = math.floor((car.splinePosition % 1.0) * detailCount) + 1
      
      -- ds is approximately trackLength / detailCount
      local ds = trackLength / detailCount
      if ds <= 0.001 then ds = 5.0 end
      
      local startOffset = -math.floor(40 / ds)
      local endOffset = math.floor(lookAheadDistance / ds)
      
      local prevPos = nil
      local prevBrakingPos = nil
      local prevAccelPos = nil
      
      for offset = startOffset, endOffset do
        local idx = ((carIdx + offset - 1) % detailCount) + 1
        local pt = aiLoader.points[idx]
        
        if pt then
          -- Hybrid line: draw the learned/blended position when available
          local ptPos = lineLearning.getDisplayPos(idx) or pt.worldPos
          local ptPerp = lineLearning.getDisplayPerp(idx) or pt.perp

          local vSafePt = M.safeSpeedProfile[idx] or 999.0
          local deltaKmh = (car.speedMs - vSafePt) * 3.6
          local color = getSpeedRelativeColor(deltaKmh)

          -- Smooth gas over a 7-point window to determine accel/coasting side-line zones
          local sumGas = 0
          local count = 0
          for w = -3, 3 do
            local wIdx = ((idx + w - 1) % detailCount) + 1
            local wPt = aiLoader.points[wIdx]
            if wPt then sumGas = sumGas + wPt.gas; count = count + 1 end
          end
          local smoothGas = count > 0 and (sumGas / count) or pt.gas

          local inAnyBrakingZone      = (deltaKmh > 0)
          local inAnyAccelerationZone = (smoothGas > 0.05 and not inAnyBrakingZone)
          local inAnyCoastingZone     = (smoothGas <= 0.05 and not inAnyBrakingZone)
          
          if prevPos then
            -- Draw main racing line segment
            racingPainter:line(prevPos, ptPos, color, 0.5)

            -- Draw braking zone (Red line offset to the Left side). Width scales with
            -- how much braking is still required, tapering toward the apex — a visual
            -- cue for progressive brake release (trail braking)
            if inAnyBrakingZone then
              local brakingWorldPos = ptPos + ptPerp * 0.6
              if prevBrakingPos then
                local brkWidth = 0.10 + math.min(0.20, deltaKmh / 80)
                brakingPainter:line(prevBrakingPos, brakingWorldPos, rgbm(1, 0, 0, 0.75), brkWidth)
              end
              prevBrakingPos = brakingWorldPos
            else
              prevBrakingPos = nil
            end

            -- Draw acceleration / coasting zone (Green / Light Blue line offset to the Right side)
            if inAnyAccelerationZone or inAnyCoastingZone then
              local sideColor = inAnyAccelerationZone and rgbm(0, 1, 0, 0.75) or rgbm(0.1, 0.7, 1.0, 0.75)
              local accelerationWorldPos = ptPos - ptPerp * 0.6
              if prevAccelPos then
                accelerationPainter:line(prevAccelPos, accelerationWorldPos, sideColor, 0.15)
              end
              prevAccelPos = accelerationWorldPos
            else
              prevAccelPos = nil
            end
          end
          prevPos = ptPos
        end
      end
    else
      -- Fallback: original dynamic scan and binary reading code but unified with safeSpeedProfile
      local stepSizeMeters = 2
      local points = {}
      local idx = 1

      for d = -40, lookAheadDistance, stepSizeMeters do
        local p = car.splinePosition + d / trackLength
        if p > 1.0 then p = p - 1.0
        elseif p < 0.0 then p = p + 1.0 end
        local worldPos = ac.trackProgressToWorldCoordinate(p, true)
        if worldPos then
          local aiGas, aiBrake, aiSpeedKmh = aiLoader.getAiInputAtProgress(p)
          points[idx] = {
            p = p,
            worldPos = worldPos,
            aiGas = aiGas,
            aiBrake = aiBrake,
            aiSpeedKmh = aiSpeedKmh,
            splineIdx = math.floor((p % 1.0) * detailCount) + 1
          }
          idx = idx + 1
        end
      end

      local numPoints = #points
      if numPoints >= 2 then
        local prevPt = points[1]
        local prevBrakingPos = nil
        local prevAccelPos = nil

        for i = 2, numPoints do
          local pt = points[i]
          local worldPos = pt.worldPos

          local sIdx = pt.splineIdx
          if sIdx <= 0 then sIdx = 1
          elseif sIdx > detailCount then sIdx = detailCount end

          local vSafePt = M.safeSpeedProfile[sIdx] or 999.0
          local deltaKmh = (car.speedMs - vSafePt) * 3.6
          local color = getSpeedRelativeColor(deltaKmh)

          -- Smooth gas over a 5-point window to determine accel/coasting side-line zones
          local sumGas = 0
          local count = 0
          for w = -2, 2 do
            local wIdx = i + w
            if wIdx >= 1 and wIdx <= numPoints then sumGas = sumGas + points[wIdx].aiGas; count = count + 1 end
          end
          local smoothGas = count > 0 and (sumGas / count) or pt.aiGas

          local inAnyBrakingZone      = (deltaKmh > 0)
          local inAnyAccelerationZone = (smoothGas > 0.05 and not inAnyBrakingZone)
          local inAnyCoastingZone     = (smoothGas <= 0.05 and not inAnyBrakingZone)

          -- Draw main racing line segment
          racingPainter:line(prevPt.worldPos, worldPos, color, 0.5)

          -- Calculate perpendicular offset vector for dual-side lines
          local perpendicular = nil
          if inAnyBrakingZone or inAnyAccelerationZone or inAnyCoastingZone then
            local tangent = worldPos - prevPt.worldPos
            tangent.y = 0
            local tangentLen = tangent:length()
            if tangentLen > 0.001 then
              perpendicular = vec3(-tangent.z, 0, tangent.x) * (1 / tangentLen)
            end
          end

          -- Draw braking zone (Red line offset to the Left side)
          if inAnyBrakingZone and perpendicular then
            local brakingWorldPos = worldPos + perpendicular * 0.6
            if prevBrakingPos then
              brakingPainter:line(prevBrakingPos, brakingWorldPos, rgbm(1, 0, 0, 0.75), 0.15)
            end
            prevBrakingPos = brakingWorldPos
          else
            prevBrakingPos = nil
          end

          -- Draw acceleration / coasting zone (Green / Light Blue line offset to the Right side)
          if (inAnyAccelerationZone or inAnyCoastingZone) and perpendicular then
            local sideColor = inAnyAccelerationZone and rgbm(0, 1, 0, 0.75) or rgbm(0.1, 0.7, 1.0, 0.75)
            local accelerationWorldPos = worldPos - perpendicular * 0.6
            if prevAccelPos then
              accelerationPainter:line(prevAccelPos, accelerationWorldPos, sideColor, 0.15)
            end
            prevAccelPos = accelerationWorldPos
          else
            prevAccelPos = nil
          end

          prevPt = pt
        end
      end
    end
  end

  -- Draw Apex marking for the closest upcoming turn only (using pre-scanned corners)
  if config.drawEntryApexExit then
    local closestTurn = nil
    local minUpcomingDist = 9999

    for _, turn in ipairs(allTrackCorners) do
      local diff = turn.apexProgress - car.splinePosition
      if diff > 0.5 then diff = diff - 1.0
      elseif diff < -0.5 then diff = diff + 1.0 end
      local distToApex = diff * trackLength

      -- Draw markings for the turn we are approaching or currently in (up to 15m past apex)
      if distToApex > -15 and distToApex < minUpcomingDist and distToApex < 400 then
        minUpcomingDist = distToApex
        closestTurn = turn
      end
    end

    if closestTurn then
      local turn = closestTurn
      local distToApex = minUpcomingDist
      local apexWorldPos = ac.trackProgressToWorldCoordinate(turn.apexProgress, true)

      if apexWorldPos then
        -- Apex point (Gold circle)
        local apexColor = rgbm(1, 0.8, 0, 0.8) -- Gold/Yellow
        if distToApex < 15 then
          apexColor = rgbm(0, 0.9, 0.2, 0.8) -- Light Green when passing the apex
        end
        racingPainter:circle(apexWorldPos, 1.2, false, apexColor)
      end
    end
  end

  -- Draw 3D braking point markers (orange stripe across track at braking point for each corner)
  if config.showBrakeMarkers then
    local markerColor = rgbm(1.0, 0.50, 0.0, 0.9)
    for _, marker in ipairs(M.brakeMarkers) do
      local diff = marker.apexProgress - (car.splinePosition % 1.0)
      if diff > 0.5 then diff = diff - 1.0 elseif diff < -0.5 then diff = diff + 1.0 end
      local distToCorner = diff * trackLength

      if distToCorner > -30 and distToCorner < lookAheadDistance then
        local p1 = marker.worldPos + marker.perp * 2.5
        local p2 = marker.worldPos - marker.perp * 2.5
        brakeMarkerPainter:line(p1, p2, markerColor, 0.40)
        -- Second thinner line 0.5 m ahead for visibility
        local fwd = marker.perp:cross(vec3(0, 1, 0)):normalize() * 0.5
        brakeMarkerPainter:line(p1 + fwd, p2 + fwd, rgbm(1.0, 0.75, 0.0, 0.6), 0.20)
      end
    end
  end

end

-- Returns the next detected corner ahead of the car and its distance in meters.
-- Used by the coordinator to prefer the geometric/learned target over the
-- ac.getTrackUpcomingTurn angle heuristic for the speed widget.
function M.getCornerAhead(car, sim)
  local trackLength = sim and sim.trackLengthM or 0
  if trackLength <= 100 or #allTrackCorners == 0 then return nil end

  local pos = car.splinePosition % 1.0
  local best, bestDist = nil, math.huge
  for _, turn in ipairs(allTrackCorners) do
    local diff = turn.apexProgress - pos
    if diff < 0 then diff = diff + 1.0 end
    local d = diff * trackLength
    if d < bestDist then
      best, bestDist = turn, d
    end
  end
  if best and bestDist < 1000 then return best, bestDist end
  return nil
end

-- Forces the safe speed profile to be rebuilt on the next frame (called by the
-- coordinator when corner-learning updated a calibrated target)
function M.invalidateSafeSpeedProfile()
  lastSpeedMult = -1
end

-- Re-derive corner radii after the hybrid display line changed: the radius that
-- matters is the one of the line actually drawn (getSplineWorldPos prefers it)
function M.refreshCornerRadii()
  local detailCount = aiLoader.detailCount
  if detailCount <= 0 or lastTrackLength <= 100 or #allTrackCorners == 0 then return end
  computeCornerRadii(detailCount, lastTrackLength / detailCount)
end

M.allTrackCorners = allTrackCorners

-- Test seam (headless): run the corner pre-scan + safe-speed profile deterministically,
-- without the calibration/draw frame. Mirrors what drawRacingLine sets up so the
-- lua-app/tests harness can feed real track telemetry and inspect the result.
-- Not used by the live overlay. Returns the safe-speed profile and the detected corners.
function M.buildProfileForTest(car, sim, roadGrip, speedMult)
  M.speedMult = speedMult or 1.0
  physics.speedMult = M.speedMult
  preScanTrackCorners(sim)
  lastTrackLength = sim.trackLengthM
  M.recalculateSafeSpeedProfile(car, roadGrip)
  return M.safeSpeedProfile, allTrackCorners
end

return M
