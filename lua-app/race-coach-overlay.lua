-- Main coordinator for the Race Coach Overlay Lua app
local physics = require('physics-calc')
local uiBrowser = require('ui-browser')
local painter = require('track-painter')
local recorder = require('telemetry-recorder')
local config = require('config')


local function log(msg)
  ac.log("[Race Coach Overlay] " .. tostring(msg))
end

-- Browser instances for each window
local browserHud = nil
local browserNextTurn = nil
local browserGG = nil
local browserColors = nil
local browserSpeed = nil

-- Size trackers to prevent frame-flicker resize loops
local trackerHud = { x = 0, y = 0 }
local trackerNextTurn = { x = 0, y = 0 }
local trackerGG = { x = 0, y = 0 }
local trackerColors = { x = 0, y = 0 }
local trackerSpeed = { x = 0, y = 0 }

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

-- Control Panel Window (Native ImGui Interface)
function windowSettings(dt)
  ui.pushFont(ui.Font.Title)
  ui.text("Race Coach - Configurações")
  ui.popFont()
  
  ui.separator()
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
  
  local opacityVal, opacityChanged = ui.slider("Opacidade do HUD", config.overlayOpacity * 100, 0, 100, "%.0f%%")
  if opacityChanged then
    config.overlayOpacity = opacityVal / 100
  end
  ui.textColored("Ajusta a opacidade de fundo dos painéis do HUD.", rgbm(0.6, 0.6, 0.6, 1.0))
  
  ui.separator()
  ui.offsetCursorY(6)
  ui.header("Ajuste Fino de Pilotagem")
  
  local speedVal, speedChanged = ui.slider("Ajuste de Velocidade Curva", config.cornerSpeedBias * 100, 80, 120, "%.0f%%")
  if speedChanged then
    config.cornerSpeedBias = speedVal / 100
  end
  ui.textColored("Altera a velocidade ideal alvo nas curvas (maior = mais rápido/agressivo).", rgbm(0.6, 0.6, 0.6, 1.0))
  
  ui.offsetCursorY(6)
  
  local brakeVal, brakeChanged = ui.slider("Margem da Zona de Frenagem", config.brakingMargin * 100, 70, 130, "%.0f%%")
  if brakeChanged then
    config.brakingMargin = brakeVal / 100
  end
  ui.textColored("Ajusta a distância de frenagem (menor = freia mais tarde/perigoso).", rgbm(0.6, 0.6, 0.6, 1.0))
  
  ui.separator()
  ui.offsetCursorY(6)
  ui.header("Gravação de Telemetria")
  
  local sampleCount = recorder.getSampleCount()
  ui.text(string.format("Amostras coletadas nesta volta: %d", sampleCount))
  
  if ui.button("Gravar Telemetria Parcial", vec2(-1, 0)) then
    recorder.savePartialSession()
  end
  ui.textColored("Grava as amostras acumuladas até o momento em um arquivo JSON na pasta 'telemetry_logs' (útil para voltas incompletas).", rgbm(0.6, 0.6, 0.6, 1.0))
end

-- Register settings panel in Content Manager / AC side bar settings context
ui.addSettings({
  name = "Race Coach",
  id = "RaceCoachSettingsPanel",
  icon = ui.Icons.Settings,
  size = {
    default = vec2(350, 420),
    min = vec2(280, 300)
  }
}, function()
  ui.header("Geral")
  if ui.checkbox("Ativar Vozes do Engenheiro", config.voiceEnabled) then
    config.voiceEnabled = not config.voiceEnabled
  end
  ui.offsetCursorY(4)
  if ui.checkbox("Mostrar Linha Ideal", config.showRacingLine) then
    config.showRacingLine = not config.showRacingLine
  end
  ui.offsetCursorY(4)
  if ui.checkbox("Marcar Ponto de Ápice", config.drawEntryApexExit) then
    config.drawEntryApexExit = not config.drawEntryApexExit
  end
  ui.offsetCursorY(4)
  local opacityVal, opacityChanged = ui.slider("Opacidade HUD", config.overlayOpacity * 100, 0, 100, "%.0f%%")
  if opacityChanged then
    config.overlayOpacity = opacityVal / 100
  end

  ui.separator()
  ui.header("Ajuste Fino de Pilotagem")
  
  local speedVal, speedChanged = ui.slider("Ajuste de Velocidade Curva", config.cornerSpeedBias * 100, 80, 120, "%.0f%%")
  if speedChanged then
    config.cornerSpeedBias = speedVal / 100
  end
  ui.offsetCursorY(4)
  local brakeVal, brakeChanged = ui.slider("Margem de Frenagem", config.brakingMargin * 100, 70, 130, "%.0f%%")
  if brakeChanged then
    config.brakingMargin = brakeVal / 100
  end

  ui.separator()
  ui.header("Telemetria")
  local sampleCount = recorder.getSampleCount()
  ui.text(string.format("Amostras coletadas: %d", sampleCount))
  if ui.button("Gravar Telemetria Parcial", vec2(-1, 0)) then
    recorder.savePartialSession()
  end
end)



-- Main physics loop updates and 3D track painter drawings
function script.update(dt)
  local car = ac.getCar(0)
  if not car then return end

  -- 1. Calibrate dynamic G limits based on vehicle state
  physics.updateGLimits(car)

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
end
