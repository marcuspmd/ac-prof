// Shared dynamic state for the Race Coach Overlay

export interface CornerSample {
  speedMs: number;
  roadGrip: number;
  accG: { x: number; z: number };
  brake: number;
  steer: number;
  trackPosLat: number;
}

export const state = {
  // Session dynamic G limits (calibrated via telemetry)
  maxObservedLatG: 0.9,
  maxObservedDecelG: 0.8,
  maxObservedAccelG: 0.3,

  // Corner tracking state
  inCorner: false,
  cornerSamples: [] as CornerSample[],
  currentCornerStartDist: -1,
  currentCornerAngle: 0,

  // Audio / Speech State
  lastFeedbackTime: 0,
  hasAnnouncedCurrentTurn: false,
  hasAnnouncedBrakingPoint: false,
  lastNextTurnDist: -1,
  lastNextTurnAngle: 0,

  // Configuration settings synced from Lua
  voiceEnabled: false,
  drawEntryApexExit: true,
  overlayOpacity: 0.75,
};

