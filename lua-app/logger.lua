-- Shared logging utility for Race Coach Overlay
local M = {}

local logPath = nil

local function getLogPath()
  if not logPath then
    local folder = ac.getFolder(ac.FolderID.Logs)
    logPath = folder:gsub("\\", "/") .. "/race_coach_debug.log"
  end
  return logPath
end

-- Clear/Initialize log file
function M.clear()
  local path = getLogPath()
  local f = io.open(path, "w")
  if f then
    f:write("=== Race Coach Debug Log Started: " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n")
    f:close()
  end
end

-- Append a line to the log
function M.log(msg)
  local path = getLogPath()
  local f = io.open(path, "a")
  if f then
    f:write(os.date("[%H:%M:%S] ") .. tostring(msg) .. "\n")
    f:close()
  end
  -- Keep fallback writing to standard CSP log
  ac.log("[Race Coach] " .. tostring(msg))
end

return M
