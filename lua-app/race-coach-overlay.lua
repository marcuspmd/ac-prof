local telemetry = require('telemetry')
local WebBrowser = require('shared/web/browser')

local function log(msg)
  ac.log("[Race Coach Overlay] " .. tostring(msg))
end

-- Instâncias dos navegadores para cada janela
local browserHud = nil
local browserNextTurn = nil
local browserGG = nil

-- Rastreadores de tamanho para evitar redimensionamento a cada frame (flicker)
local trackerHud = { x = 0, y = 0 }
local trackerNextTurn = { x = 0, y = 0 }
local trackerGG = { x = 0, y = 0 }

-- Função auxiliar para inicializar um navegador CEF
local function createBrowser(hash, defaultSize)
  local acRoot = ac.getFolder(ac.FolderID.Root):gsub("\\", "/")
  local htmlUrl = "file:///" .. acRoot .. "/apps/lua/race-coach-overlay/overlay/index.html" .. hash
  htmlUrl = htmlUrl:gsub(" ", "%%20")
  
  log("Initializing browser for " .. hash .. " with URL: " .. htmlUrl)
  
  local success, res = pcall(function()
    return WebBrowser({
      url = htmlUrl,
      size = defaultSize,
      backgroundColor = rgbm(0, 0, 0, 0), -- Transparente
      redirectAudio = false
    })
    :onLoadStart(function(b)
      log("Browser load start: " .. tostring(b:url()))
    end)
    :onLoadEnd(function(b)
      local currentUrl = b:url()
      log("Browser load end: " .. tostring(currentUrl))
      if currentUrl == "" or currentUrl:startsWith("about:blank") then
        b:navigate(htmlUrl)
      end
    end)
    :onLoadError(function(b, data)
      log(string.format("Browser load error: failedURL=%s, errorCode=%s, errorText=%s", tostring(data.failedURL), tostring(data.errorCode), tostring(data.errorText)))
    end)
    :navigate(htmlUrl)
  end)
  
  if success and res then
    return res
  else
    log("Failed to create browser for " .. hash .. ": " .. tostring(res))
    return nil
  end
end

-- Função auxiliar para desenhar o browser e enviar a telemetria
local function updateAndDraw(browserInstance, tracker)
  if not browserInstance then return end

  -- Desenha o componente WebBrowser preenchendo a janela do app usando ImGui
  local size = ui.availableSpace()
  ui.dummy(size)
  local r1, r2 = ui.itemRect()
  
  -- Redimensiona o navegador apenas se o tamanho mudou
  if size.x ~= tracker.x or size.y ~= tracker.y then
    tracker.x = size.x
    tracker.y = size.y
    browserInstance:resize(size)
  end
  browserInstance:draw(r1, r2, false)

  -- Envia os dados de telemetria
  local telemetrySuccess, data = pcall(telemetry.getTelemetry, 0)
  if telemetrySuccess and data then
    local jsonSuccess, jsonStr = pcall(JSON.stringify, data)
    if jsonSuccess and jsonStr then
      browserInstance:execute(string.format("if (window.onTelemetryUpdate) window.onTelemetryUpdate(%s);", jsonStr))
    end
  end
end

-- Janela principal: HUD (Velocidade, Marcha, Pedais, Pneus, Engenheiro)
function windowMain(dt)
  if not browserHud then
    browserHud = createBrowser("#hud", vec2(350, 180))
  end
  updateAndDraw(browserHud, trackerHud)
end

-- Janela secundária: Placa da Próxima Curva
function windowNextTurn(dt)
  if not browserNextTurn then
    browserNextTurn = createBrowser("#next-turn", vec2(140, 110))
  end
  updateAndDraw(browserNextTurn, trackerNextTurn)
end

-- Janela terciária: Diagrama G-G
function windowGG(dt)
  if not browserGG then
    browserGG = createBrowser("#gg", vec2(160, 180))
  end
  updateAndDraw(browserGG, trackerGG)
end
