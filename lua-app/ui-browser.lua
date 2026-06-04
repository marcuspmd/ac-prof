-- CEF Web Browser instance management and telemetry streaming
local WebBrowser = require('shared/web/browser')
local telemetry = require('telemetry')

local M = {}

local function log(msg)
  ac.log("[Race Coach UI] " .. tostring(msg))
end

-- Helper function to initialize a CEF browser window
function M.createBrowser(hash, defaultSize)
  local acRoot = ac.getFolder(ac.FolderID.Root):gsub("\\", "/")
  local htmlUrl = "file:///" .. acRoot .. "/apps/lua/race-coach-overlay/overlay/index.html" .. hash
  htmlUrl = htmlUrl:gsub(" ", "%%20")
  
  log("Initializing browser for " .. hash .. " with URL: " .. htmlUrl)
  
  local success, res = pcall(function()
    return WebBrowser({
      url = htmlUrl,
      size = defaultSize,
      backgroundColor = rgbm(0, 0, 0, 0), -- Transparent background
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

-- Helper function to draw browser inside ImGui window and send telemetry
-- Tracker is a table {x = 0, y = 0} keeping size history to prevent frame-flicker resize loops
function M.updateAndDraw(browserInstance, tracker)
  if not browserInstance then return end

  -- Draw CEF container covering all available window space in ImGui
  local size = ui.availableSpace()
  ui.dummy(size)
  local r1, r2 = ui.itemRect()
  
  -- Only trigger heavy CEF resize call if size changes
  if size.x ~= tracker.x or size.y ~= tracker.y then
    tracker.x = size.x
    tracker.y = size.y
    browserInstance:resize(size)
  end
  browserInstance:draw(r1, r2, false)

  -- Fetch physics telemetry and execute frontend update function
  local telemetrySuccess, data = pcall(telemetry.getTelemetry, 0)
  if telemetrySuccess and data then
    local jsonSuccess, jsonStr = pcall(JSON.stringify, data)
    if jsonSuccess and jsonStr then
      browserInstance:execute(string.format("if (window.onTelemetryUpdate) window.onTelemetryUpdate(%s);", jsonStr))
    end
  end
end

return M
