local telemetry = require('telemetry')
local WebBrowser = require('shared/web/browser')

local browser = nil
local initialized = false

local function log(msg)
  ac.log("[Race Coach Overlay] " .. tostring(msg))
end

function windowMain(dt)
  if not initialized then
    initialized = true
    
    -- Obtém a pasta raiz do Assetto Corsa e formata o caminho absoluto com barras normais
    local acRoot = ac.getFolder(ac.FolderID.Root):gsub("\\", "/")
    local htmlUrl = "file:///" .. acRoot .. "/apps/lua/race-coach-overlay/overlay/index.html"
    htmlUrl = htmlUrl:gsub(" ", "%%20")
    
    log("Initializing browser with URL: " .. htmlUrl)
    
    local success, res = pcall(function()
      return WebBrowser({
        url = htmlUrl,
        size = vec2(400, 300),
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
          log("CEF ready. Navigating to HTML overlay: " .. htmlUrl)
          b:navigate(htmlUrl)
        end
      end)
      :onLoadError(function(b, data)
        log(string.format("Browser load error: failedURL=%s, errorCode=%s, errorText=%s", tostring(data.failedURL), tostring(data.errorCode), tostring(data.errorText)))
      end)
      :onCrash(function(b, data)
        log(string.format("Browser engine crash: errorCode=%s, errorText=%s", tostring(data.errorCode), tostring(data.errorText)))
      end)
      :navigate(htmlUrl)
    end)
    
    if success and res then
      browser = res
      log("Browser initialized successfully.")
    else
      log("Failed to initialize WebBrowser: " .. tostring(res))
    end
  end

  if not browser then return end

  -- Desenha o componente WebBrowser preenchendo a janela do app usando o padrão ImGui do CSP
  local size = ui.availableSpace()
  ui.dummy(size)
  local r1, r2 = ui.itemRect()
  
  -- Redimensiona o navegador para corresponder ao tamanho da janela
  browser:resize(size)
  browser:draw(r1, r2, false)

  -- Obtém e repassa os dados de telemetria
  local data = telemetry.getTelemetry(0)
  if data then
    local success, jsonStr = pcall(json.encode, data)
    if success and jsonStr then
      -- Executa a função JavaScript no escopo global do CEF para repasse de telemetria
      browser:execute(string.format("if (window.onTelemetryUpdate) window.onTelemetryUpdate(%s);", jsonStr))
    end
  end
end
