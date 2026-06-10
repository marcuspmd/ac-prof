-- Main coordinator for the Race Coach Overlay Lua app
local physics = require('physics-calc')
local uiBrowser = require('ui-browser')
local painter = require('track-painter')
local recorder = require('telemetry-recorder')
local config = require('config')
local lapDelta = require('lap-delta')


local function log(msg)
  ac.log("[Race Coach Overlay] " .. tostring(msg))
end

-- Browser instances for each window
local browserHud = nil
local browserNextTurn = nil
local browserGG = nil
local browserColors = nil
local browserSpeed = nil
local browserDelta = nil

-- Size trackers to prevent frame-flicker resize loops
local trackerHud = { x = 0, y = 0 }
local trackerNextTurn = { x = 0, y = 0 }
local trackerGG = { x = 0, y = 0 }
local trackerColors = { x = 0, y = 0 }
local trackerSpeed = { x = 0, y = 0 }
local trackerDelta = { x = 0, y = 0 }

-- Primary Window: HUD (Speed, Gear, Pedals, Tyres, Engineer Feedback)
function windowMain(dt)
  if not browserHud then
    browserHud = uiBrowser.createBrowser("#hud", vec2(350, 180))
  end
  uiBrowser.updateAndDraw(browserHud, trackerHud)
end

-- Secondary Window: Next Turn Info Board
function windowNextTurn(dt)
  if not browserNextTurn then
    browserNextTurn = uiBrowser.createBrowser("#next-turn", vec2(140, 110))
  end
  uiBrowser.updateAndDraw(browserNextTurn, trackerNextTurn)
end

-- Tertiary Window: G-G Diagram (Friction Circle)
function windowGG(dt)
  if not browserGG then
    browserGG = uiBrowser.createBrowser("#gg", vec2(160, 180))
  end
  uiBrowser.updateAndDraw(browserGG, trackerGG)
end

-- Quaternary Window: Color Semaphore (Peripheral vision braking color)
function windowColors(dt)
  if not browserColors then
    browserColors = uiBrowser.createBrowser("#colors", vec2(80, 80))
  end
  uiBrowser.updateAndDraw(browserColors, trackerColors)
end

-- Quinary Window: Speed Match Widget (Only Current Speed / Desired Speed)
function windowSpeed(dt)
  if not browserSpeed then
    browserSpeed = uiBrowser.createBrowser("#speed", vec2(220, 100))
  end
  uiBrowser.updateAndDraw(browserSpeed, trackerSpeed)
end

-- Senary Window: Lap Delta Widget
function windowDelta(dt)
  if not browserDelta then
    browserDelta = uiBrowser.createBrowser("#delta", vec2(200, 95))
  end
  uiBrowser.updateAndDraw(browserDelta, trackerDelta)
end

-- Shared tab content functions
local function tabGeral()
  ui.offsetCursorY(6)
  if ui.checkbox("Ativar Vozes (Feedback de Áudio)", config.voiceEnabled) then
    config.voiceEnabled = not config.voiceEnabled
  end
  ui.textColored("Ativa o feedback falado em tempo real do engenheiro de pista.", rgbm(0.6, 0.6, 0.6, 1.0))
  ui.offsetCursorY(6)
  if ui.checkbox("Mostrar Linha Ideal na Pista", config.showRacingLine) then
    config.showRacingLine = not config.showRacingLine
  end
  ui.textColored("Desenha a linha de trajetória ideal colorida no asfalto.", rgbm(0.6, 0.6, 0.6, 1.0))
  ui.offsetCursorY(6)
  if ui.checkbox("Desenhar Círculo do Ápice", config.drawEntryApexExit) then
    config.drawEntryApexExit = not config.drawEntryApexExit
  end
  ui.textColored("Mostra a marcação circular em 3D no ápice de cada curva.", rgbm(0.6, 0.6, 0.6, 1.0))
  ui.offsetCursorY(6)
  if ui.checkbox("Mostrar Marcadores de Frenagem", config.showBrakeMarkers) then
    config.showBrakeMarkers = not config.showBrakeMarkers
  end
  ui.textColored("Desenha faixa laranja no asfalto no ponto ideal de início de frenagem.", rgbm(0.6, 0.6, 0.6, 1.0))
  ui.offsetCursorY(6)
  local opacityVal, opacityChanged = ui.slider("Opacidade do HUD", config.overlayOpacity * 100, 0, 100, "%.0f%%")
  if opacityChanged then config.overlayOpacity = opacityVal / 100 end
  ui.textColored("Ajusta a opacidade de fundo dos painéis do HUD.", rgbm(0.6, 0.6, 0.6, 1.0))
end

local function tabPilotagem()
  ui.offsetCursorY(6)
  local speedVal, speedChanged = ui.slider("Velocidade nas Curvas", config.cornerSpeedBias * 100, 80, 120, "%.1f%%")
  if speedChanged then config.cornerSpeedBias = speedVal / 100 end
  ui.textColored("↑ Maior → velocidade alvo sobe, carro vai mais rápido nas curvas.", rgbm(0.5, 0.8, 0.5, 1.0))
  ui.textColored("↓ Menor → alvo mais baixo, freie antes e entre mais devagar.", rgbm(0.8, 0.5, 0.5, 1.0))
  ui.offsetCursorY(6)
  local brakeVal, brakeChanged = ui.slider("Margem de Frenagem", config.brakingMargin * 100, 70, 130, "%.1f%%")
  if brakeChanged then config.brakingMargin = brakeVal / 100 end
  ui.textColored("↑ Maior → ponto de frenagem mais cedo (mais conservador).", rgbm(0.5, 0.8, 0.5, 1.0))
  ui.textColored("↓ Menor → ponto mais tardio (mais agressivo).", rgbm(0.8, 0.5, 0.5, 1.0))
  ui.offsetCursorY(6)
  local brakeIntVal, brakeIntChanged = ui.slider("Intensidade de Frenagem", config.brakeIntensityFactor * 100, 65, 100, "%.1f%%")
  if brakeIntChanged then config.brakeIntensityFactor = brakeIntVal / 100 end
  ui.textColored("↑ Maior → assume freio mais forte → avisa mais tarde.", rgbm(0.5, 0.8, 0.5, 1.0))
  ui.textColored("↓ Menor → assume frenagem mais suave → avisa mais cedo.", rgbm(0.8, 0.5, 0.5, 1.0))
  ui.offsetCursorY(6)
  local trailVal, trailChanged = ui.slider("Trail Braking (Freio na Curva)", config.trailBrakingFactor * 100, 10, 70, "%.1f%%")
  if trailChanged then config.trailBrakingFactor = trailVal / 100 end
  ui.textColored("↑ Maior → sustenta freio na entrada → ponto mais tardio.", rgbm(0.5, 0.8, 0.5, 1.0))
  ui.textColored("↓ Menor → sem trail brake → freia bem antes da curva.", rgbm(0.8, 0.5, 0.5, 1.0))
  ui.offsetCursorY(6)
  local reactVal, reactChanged = ui.slider("Buffer de Reação", config.reactionMargin * 100, 50, 200, "%.0f%%")
  if reactChanged then config.reactionMargin = reactVal / 100 end
  ui.textColored("↑ Maior → mais espaço antes do freio para cobrir reação humana.", rgbm(0.5, 0.8, 0.5, 1.0))
  ui.textColored("↓ Menor → aviso mais próximo e preciso, para pilotos experientes.", rgbm(0.8, 0.5, 0.5, 1.0))
end

local function tabCalibracao()
  ui.offsetCursorY(6)
  ui.header("Calibração por Curva")
  local corners = painter.allTrackCorners
  local calibCount = 0
  for _, turn in ipairs(corners) do
    if turn.calibratedVTarget then calibCount = calibCount + 1 end
  end
  if #corners > 0 then
    local pct = math.floor(calibCount / #corners * 100)
    ui.text(string.format("Calibradas: %d/%d (%d%%)", calibCount, #corners, pct))
    ui.textColored("Calibra automaticamente ao passar pelos ápices. Completa em ~3 voltas.", rgbm(0.6, 0.6, 0.6, 1.0))
  else
    ui.textColored("Aguardando dados da pista...", rgbm(0.6, 0.6, 0.6, 1.0))
  end
  ui.offsetCursorY(4)
  if ui.button("Resetar Calibração", vec2(-1, 0)) then
    for _, turn in ipairs(corners) do
      turn.observedSpeeds = {}
      turn.calibratedVTarget = nil
      turn.apexObsCooldown = false
    end
    painter.safeSpeedProfile = {}
  end
  ui.textColored("Limpa os dados aprendidos e volta ao baseline do AI line.", rgbm(0.6, 0.6, 0.6, 1.0))

  ui.separator()
  ui.offsetCursorY(6)
  ui.header("Consistência por Curva")
  local hasAnyObs = false
  for ci, turn in ipairs(corners) do
    if #turn.observedSpeeds >= 3 then
      hasAnyObs = true
      local sum = 0
      for _, v in ipairs(turn.observedSpeeds) do sum = sum + v * 3.6 end
      local mean = sum / #turn.observedSpeeds
      local varSum = 0
      for _, v in ipairs(turn.observedSpeeds) do
        local d = v * 3.6 - mean; varSum = varSum + d * d
      end
      local stddev = math.sqrt(varSum / #turn.observedSpeeds)
      local cv = stddev / mean * 100
      local col
      if cv < 3 then col = rgbm(0.2, 0.9, 0.2, 1)
      elseif cv < 6 then col = rgbm(0.9, 0.8, 0.1, 1)
      else col = rgbm(0.9, 0.2, 0.2, 1) end
      ui.textColored(string.format("C%-2d  %.0f km/h  ±%.1f  CV:%.1f%%  (n=%d)",
        ci, mean, stddev, cv, #turn.observedSpeeds), col)
    end
  end
  if not hasAnyObs then
    ui.textColored("Nenhum dado ainda — complete pelo menos 3 passagens.", rgbm(0.5, 0.5, 0.5, 1))
  end
end

local function tabDados()
  ui.offsetCursorY(6)
  ui.header("Lap Delta")
  ui.textColored("O delta ao vivo está disponível como janela separada (widget Delta).", rgbm(0.6, 0.6, 0.6, 1.0))
  local key = lapDelta.getSessionKey()
  if key then ui.textColored("Cache: " .. key, rgbm(0.4, 0.4, 0.4, 1.0)) end
  ui.offsetCursorY(4)
  if ui.button("Resetar Delta", vec2(-1, 0)) then lapDelta.reset() end
  ui.textColored("Remove a referência desta sessão (não apaga o cache em disco).", rgbm(0.6, 0.6, 0.6, 1.0))

  ui.separator()
  ui.offsetCursorY(6)
  ui.header("Gravação de Telemetria")
  local sampleCount = recorder.getSampleCount()
  ui.text(string.format("Amostras coletadas nesta volta: %d", sampleCount))
  ui.offsetCursorY(4)
  if ui.button("Gravar Telemetria Parcial", vec2(-1, 0)) then recorder.savePartialSession() end
  ui.textColored("Grava as amostras acumuladas em JSON na pasta 'telemetry_logs'.", rgbm(0.6, 0.6, 0.6, 1.0))
end

-- Control Panel Window (Native ImGui Interface)
function windowSettings(dt)
  ui.pushFont(ui.Font.Title)
  ui.text("Race Coach - Configurações")
  ui.popFont()
  ui.separator()
  ui.offsetCursorY(4)

  ui.tabBar('rcoach_win_tabs', function()
    ui.tabItem('Geral',      function() tabGeral()      end)
    ui.tabItem('Pilotagem',  function() tabPilotagem()  end)
    ui.tabItem('Calibração', function() tabCalibracao() end)
    ui.tabItem('Dados',      function() tabDados()      end)
  end)
end

-- Register settings panel in Content Manager / AC side bar settings context
ui.addSettings({
  name = "Race Coach",
  id = "RaceCoachSettingsPanel",
  icon = ui.Icons.Settings,
  size = {
    default = vec2(360, 500),
    min = vec2(300, 400)
  }
}, function()
  ui.tabBar('rcoach_sidebar_tabs', function()
    ui.tabItem('Geral',      function() tabGeral()      end)
    ui.tabItem('Pilotagem',  function() tabPilotagem()  end)
    ui.tabItem('Calibração', function() tabCalibracao() end)
    ui.tabItem('Dados',      function() tabDados()      end)
  end)
end)



-- Main physics loop updates and 3D track painter drawings
function script.update(dt)
  local car = ac.getCar(0)
  if not car then return end

  -- 1. Calibrate dynamic G limits based on vehicle state
  physics.updateGLimits(car)

  -- 1b. Update lap delta tracker
  lapDelta.update(car)

  -- 2. Obtain track simulation details
  local sim = ac.getSim()
  local roadGrip = sim and sim.roadGrip or 1.0
  local upcomingTurn = ac.getTrackUpcomingTurn(0)
  if upcomingTurn and math.abs(upcomingTurn.y) < 15 then
    upcomingTurn = nil
  end

  -- 3. Calculate ideal velocity and braking distance
  local nextTurnDist, nextTurnAngle, vTarget, totalBrakingDistanceNeeded = 
    physics.calculateTurnPhysics(car, upcomingTurn, roadGrip)

  -- 4. Draw speed-relative racing line and optimized braking point on track
  local drawSuccess, drawErr = pcall(painter.drawRacingLine,
    car, 
    sim, 
    nextTurnDist, 
    nextTurnAngle, 
    vTarget, 
    totalBrakingDistanceNeeded,
    physics.maxObservedDecelG
  )
  if not drawSuccess then
    ac.log("[Race Coach Coordinator] Draw racing line error: " .. tostring(drawErr))
    ac.setMessage("Race Coach Error", "Erro ao desenhar linha: " .. tostring(drawErr))
  end

  -- 5. Record telemetry data (safely encapsulated to protect paint loop from telemetry crashes)
  local recordSuccess, scorecard = pcall(recorder.update, dt)
  if not recordSuccess then
    ac.log("[Race Coach Coordinator] Telemetry recording error: " .. tostring(scorecard))
  elseif scorecard then
    local jsonSuccess, jsonStr = pcall(JSON.stringify, scorecard)
    if jsonSuccess and jsonStr then
      if browserHud then
        browserHud:execute(string.format("if (window.onCornerCompleted) window.onCornerCompleted(%s);", jsonStr))
      end
    end
  end

  -- 6. Fire apex result event when a corner observation produced a new comparison
  local apexResult = painter.popApexResult()
  if apexResult then
    local jsonSuccess, jsonStr = pcall(JSON.stringify, apexResult)
    if jsonSuccess and jsonStr then
      if browserHud then
        browserHud:execute(string.format("if (window.onApexResult) window.onApexResult(%s);", jsonStr))
      end
    end
  end
end
