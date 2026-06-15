-- Diagnóstico comparativo: sistema vs telemetria real (Mugello)
-- Roda fora do AC: lua lua-app/tests/diagnose_mugello.lua

package.path = "lua-app/?.lua;lua-app/tests/?.lua;lua-app/tracks/?.lua;" .. package.path
require('mock_runtime')

local physics = require('physics-calc')
local painter  = require('track-painter')
local data     = require('tracks.mugello')

-- Configura o ambiente
ac.__setTrack("mugello", "", data.points, data.detailCount, data.trackLength)

local n       = data.detailCount
local pts     = data.points
local trackLen= data.trackLength
local mPerPt  = trackLen / n

-- === Car: GT (médio, interessante para comparar) ===
local p = { latG=1.40, decelG=1.10, accelG=0.55, liftF=-1.0, liftR=-1.5 }
physics.maxObservedLatG   = p.latG
physics.maxObservedDecelG = p.decelG
physics.maxObservedAccelG = p.accelG
physics.smoothedLatG      = p.latG
physics.smoothedDecelG    = p.decelG
physics.smoothedAccelG    = p.accelG

local wheels = {}
for i = 0,3 do
  wheels[i] = { tyreCoreTemperature=85, tyreOptimumTemperature=85,
                tyreWear=1.0, tyreDirty=0.0, brakeTemperature=300 }
end
local car = {
  speedMs=50, gas=1.0, brake=0.0, splinePosition=0.0,
  collisionDepth=0, position=vec3(0,0,0),
  acceleration={x=0,y=0,z=0}, wheels=wheels,
  aeroLiftFront=p.liftF, aeroLiftRear=p.liftR,
  isRacingCar=true, isOpenWheeler=false, drsPresent=false,
}
local sim  = { trackLengthM=trackLen, roadGrip=1.0 }

-- Roda o sistema
local profile, corners = painter.buildProfileForTest(car, sim, 1.0, 1.0)

-- === Encontra mínimos reais de velocidade na telemetria AI ===
local WIN_M = 60                         -- janela ±60m para oracle B
local mWin  = math.max(3, math.floor(WIN_M / mPerPt))
local DROP  = 20.0                       -- km/h mínimo de queda (mostrar candidatos)

local function spdAt(i)   return pts[i][4] end  -- km/h
local function gasAt(i)   return pts[i][5] end
local function brkAt(i)   return pts[i][6] end

-- Coleta mínimos da AI
local aiMinima = {}
for i = 1, n do
  local s = spdAt(i)
  local isMin, maxWin = true, s
  for w = -mWin, mWin do
    if w ~= 0 then
      local j = ((i+w-1)%n)+1
      if spdAt(j) < s - 0.05 then isMin=false; break end
      if spdAt(j) > maxWin then maxWin=spdAt(j) end
    end
  end
  if isMin and (maxWin-s) >= DROP then
    table.insert(aiMinima, { idx=i, progress=(i-1)/n, spdKmh=s, drop=maxWin-s })
  end
end

-- === Encontra início da frenagem real da AI para cada mínimo ===
local function findAiBrakeStart(apexIdx)
  -- Scan FORWARD from 600m before apex to find the last gas→brake transition.
  -- (The old backward scan found brake=0.1 in the exit-trail phase and then
  -- failed to find brake<0.02 within 30 steps, reporting 0–9m for everything.)
  local lookBackPts = math.min(n-1, math.floor(600/mPerPt))
  local prevBrk = 0
  local brkStartIdx = apexIdx  -- default: no distinct brake start found
  for w = lookBackPts, 1, -1 do
    local i = ((apexIdx - w - 1 + n) % n) + 1
    local bk = brkAt(i)
    if prevBrk < 0.05 and bk >= 0.05 then
      brkStartIdx = i  -- keep overwriting: last transition = start of final braking event
    end
    prevBrk = bk
  end
  local d = apexIdx - brkStartIdx
  if d < 0 then d = d + n end
  return brkStartIdx, d * mPerPt
end

-- === Cabeçalho ===
print(string.rep("=", 110))
print("DIAGNÓSTICO: Mugello • GT (latG=1.40, decelG=1.10)")
print(string.format("Pista: %.0f m  |  Pontos: %d  |  %.2f m/pt", trackLen, n, mPerPt))
print(string.rep("=", 110))
print(string.format("  %-5s %-8s  %-7s  %-8s  %-7s  %-8s  %-8s  %-8s  %-10s",
  "#", "ApexProg", "AI_kmh", "Sys_kmh", "Diff%",
  "R_m", "BrkAI_m", "BrkSys_m", "BrkDiff_m"))
print(string.rep("-", 110))

-- Para cada canto detectado pelo sistema, acha o mínimo AI mais próximo
local aiMaxSpeedKmh = data.refMaxSpeedKmh  -- 325 km/h
local speedMult = 1.0

for ci, turn in ipairs(corners) do
  local apexIdx = turn.idx
  -- Sys target speed
  local vSysMs  = turn.vTargetEffective or (turn.vTargetAI or 0)
  local vSysKmh = vSysMs * 3.6

  -- AI minimum speed perto do apex detectado
  local bestAiIdx, bestAiKmh, bestDist = apexIdx, spdAt(apexIdx), math.huge
  for _, m in ipairs(aiMinima) do
    local d = math.abs(m.idx - apexIdx)
    if d > n/2 then d = n - d end
    if d < bestDist then bestDist=d; bestAiIdx=m.idx; bestAiKmh=m.spdKmh end
  end
  -- Se muito longe, usa velocidade direta no apex detectado
  if bestDist * mPerPt > 80 then
    bestAiKmh = spdAt(apexIdx)
  end

  local diff = vSysKmh - bestAiKmh
  local diffPct = bestAiKmh > 1 and (diff/bestAiKmh*100) or 0

  -- Braking point do sistema (em metros antes do apex)
  local sysBrkProg = nil
  for _, bm in ipairs(painter.brakeMarkers) do
    if math.abs(bm.apexProgress - turn.apexProgress) < 0.01 then
      sysBrkProg = bm.progress; break
    end
  end
  local sysBrkDistM = 9999
  if sysBrkProg then
    local d = turn.apexProgress - sysBrkProg
    if d < 0 then d = d + 1.0 end
    sysBrkDistM = d * trackLen
  end

  -- Braking point real da AI
  local aiBrkIdx, _ = findAiBrakeStart(apexIdx)
  local aiBrkDistM = 9999
  do
    local d = apexIdx - aiBrkIdx
    if d < 0 then d = d + n end
    aiBrkDistM = d * mPerPt
  end

  local brkDiffM = sysBrkDistM - aiBrkDistM

  print(string.format("  C%-3d p=%.4f  AI=%5.1f  Sys=%5.1f  %+.1f%%  R=%s  AiBrk=%5.0fm  SysBrk=%s  Δ=%s",
    ci,
    turn.apexProgress,
    bestAiKmh,
    vSysKmh,
    diffPct,
    turn.radiusM and string.format("%5.0f", turn.radiusM) or "  ?  ",
    aiBrkDistM < 9990 and aiBrkDistM or 0,
    sysBrkDistM < 9990 and string.format("%5.0f", sysBrkDistM) or "  ?  ",
    sysBrkDistM < 9990 and string.format("%+5.0f", brkDiffM) or "  ?  "
  ))
end

-- === Perfil vSafe vs AI por segmento de 500m ===
print()
print(string.rep("=", 110))
print("PERFIL vSafe vs AI  (por segmento de 500m)")
print(string.format("  %-6s  %-8s  %-8s  %-8s  %-8s  %-8s",
  "Dist_m", "AI_avg", "vSafe_avg", "AI_min", "vSafe_min", "Diff_min"))
print(string.rep("-", 110))

local seg = math.floor(500 / mPerPt)
local i = 1
while i <= n do
  local j = math.min(i + seg - 1, n)
  local sumAI, sumSafe, minAI, minSafe = 0, 0, 1e9, 1e9
  local cnt = 0
  for k = i, j do
    local ai = spdAt(k)
    local vs = (profile[k] or 999) * 3.6
    sumAI   = sumAI + ai
    sumSafe = sumSafe + vs
    if ai < minAI   then minAI   = ai end
    if vs < minSafe then minSafe = vs end
    cnt = cnt + 1
  end
  local distM = (i-1)*mPerPt
  local avgAI   = sumAI/cnt
  local avgSafe = math.min(999, sumSafe/cnt)
  minSafe = math.min(999, minSafe)
  print(string.format("  %6.0f  %8.1f  %9.1f  %8.1f  %9.1f  %+8.1f",
    distM, avgAI, avgSafe, minAI, minSafe, minSafe - minAI))
  i = i + seg
end

-- === Zonas de falso-vermelho / vermelho ausente ===
print()
print(string.rep("=", 110))
print("ZONAS PROBLEMÁTICAS (vSafe < AI_speed-5  OU  vSafe > AI_speed+30 numa reta)")
print(string.format("  %-8s  %-8s  %-8s  %-6s",
  "Dist_m", "AI_kmh", "vSafe_kmh", "Tipo"))
print(string.rep("-", 80))

local STRAIGHT_R = 400
local function radiusAt(i, arm)
  local a = ((i-arm-1)%n)+1
  local c = ((i+arm-1)%n)+1
  local t1x,t1z = pts[i][1]-pts[a][1], pts[i][3]-pts[a][3]
  local t2x,t2z = pts[c][1]-pts[i][1], pts[c][3]-pts[i][3]
  local l1 = math.sqrt(t1x*t1x+t1z*t1z)
  local l2 = math.sqrt(t2x*t2x+t2z*t2z)
  if l1<1e-6 or l2<1e-6 then return 1e9 end
  local dx,dz = t2x/l2-t1x/l1, t2z/l2-t1z/l1
  local curv = math.sqrt(dx*dx+dz*dz)/l1
  if curv<1e-6 then return 1e9 end
  return 1/curv
end
local arm = math.max(1, math.floor(15/mPerPt))

local lastPrint = -100
local issues = 0
for i = 1, n do
  local ai   = spdAt(i)
  local vs   = (profile[i] or 999)*3.6
  local distM = (i-1)*mPerPt
  local R = radiusAt(i, arm)
  local isStraight = (R > STRAIGHT_R)

  local tipo = nil
  if vs < ai - 5 and isStraight then
    tipo = "RED-FALSO (reta)"
  elseif vs < ai - 10 then
    tipo = "RED-EARLY (curva)"
  elseif vs > ai + 30 and not isStraight then
    tipo = "MISS-CRN (curva alta)"
  end

  if tipo and (distM - lastPrint) > 30 then
    print(string.format("  %8.0f  %8.1f  %9.1f  %s", distM, ai, vs, tipo))
    lastPrint = distM
    issues = issues + 1
  end
end
if issues == 0 then
  print("  (nenhum problema evidente detectado)")
end
print()
print(string.format("Total de zonas problemáticas: %d", issues))
