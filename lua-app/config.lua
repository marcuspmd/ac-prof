-- Persistent settings configuration layer for Race Coach Overlay
local config = ac.storage{
  voiceEnabled = false,
  drawEntryApexExit = true,
  showRacingLine = true,
  brakingMargin = 1.0,
  cornerSpeedBias = 1.0,
  overlayOpacity = 0.75
}

-- Clamp loaded values to safe UI slider ranges
config.brakingMargin = math.min(1.3, math.max(0.7, config.brakingMargin))
config.cornerSpeedBias = math.min(1.2, math.max(0.8, config.cornerSpeedBias))

return config
