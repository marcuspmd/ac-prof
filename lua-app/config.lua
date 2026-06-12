-- Persistent settings configuration layer for Race Coach Overlay
local config = ac.storage{
  voiceEnabled = false,
  drawEntryApexExit = true,
  showRacingLine = true,
  brakingMargin = 1.0,
  cornerSpeedBias = 1.0,
  overlayOpacity = 0.75,
  brakeIntensityFactor = 0.80,
  trailBrakingFactor = 0.40,
  reactionMargin = 1.0,
  showBrakeMarkers = true,
  vTargetPushFactor = 0.30,
  beginnerMode = true,
  beginnerMargin = 0.90,
}

-- Clamp loaded values to safe UI slider ranges
config.brakingMargin = math.min(1.3, math.max(0.7, config.brakingMargin))
config.cornerSpeedBias = math.min(1.2, math.max(0.8, config.cornerSpeedBias))
config.brakeIntensityFactor = math.min(1.00, math.max(0.65, config.brakeIntensityFactor))
config.trailBrakingFactor = math.min(0.70, math.max(0.10, config.trailBrakingFactor))
config.reactionMargin = math.min(2.00, math.max(0.50, config.reactionMargin))
config.vTargetPushFactor = math.min(0.80, math.max(0.0, config.vTargetPushFactor))
config.beginnerMargin = math.min(1.00, math.max(0.80, config.beginnerMargin))

return config
