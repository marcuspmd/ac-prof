// Lógica de Modos de Exibição (Janelas Separadas)
import { state } from './state';
import { updateGGDiagram, initGG } from './gg-diagram';
import { drawInputsTrace, initTrace } from './inputs-trace';
import { setTyreVisual, checkSteeringScrub } from './tyre-slip';
import { updateUpcomingTurn, analyzePhysics, processCornerStats, initUpcomingTurn } from './upcoming-turn';

const mode = window.location.hash ? window.location.hash.substring(1) : "full";
document.body.className = `mode-${mode}`;
console.log(`[Overlay] Initialized in mode: ${mode}`);

// DOM Elements
let speedIndicator: HTMLElement | null = null;
let gearIndicator: HTMLElement | null = null;
let rpmBar: HTMLElement | null = null;
let throttleBar: HTMLElement | null = null;
let brakeBar: HTMLElement | null = null;
let trackPosTarget: HTMLElement | null = null;
let trackPosCar: HTMLElement | null = null;
let tyreFL: HTMLElement | null = null;
let tyreFR: HTMLElement | null = null;
let tyreRL: HTMLElement | null = null;
let tyreRR: HTMLElement | null = null;

function initDOM(): void {
  speedIndicator = document.getElementById("speed-indicator");
  gearIndicator = document.getElementById("gear-indicator");
  rpmBar = document.getElementById("rpm-bar");
  throttleBar = document.getElementById("throttle-bar");
  brakeBar = document.getElementById("brake-bar");
  trackPosTarget = document.getElementById("track-pos-target");
  trackPosCar = document.getElementById("track-pos-car");
  tyreFL = document.getElementById("tyre-fl");
  tyreFR = document.getElementById("tyre-fr");
  tyreRL = document.getElementById("tyre-rl");
  tyreRR = document.getElementById("tyre-rr");

  initGG();
  initTrace();
  initUpcomingTurn();
}

// Track Position Widget Update
function updateTrackPositionWidget(data: TelemetryData): void {
  if (!trackPosTarget || !trackPosCar) return;

  const dist = data.nextTurnDist;
  const angle = data.nextTurnAngle;
  const currentPos = data.trackPosLat; // -1 to 1

  // Update car position dot (blue)
  const carLeftPct = ((currentPos + 1) / 2) * 100;
  trackPosCar.style.left = `${Math.max(2, Math.min(98, carLeftPct))}%`;

  // Calculate target position based on track progress
  let targetPos = 0; // center by default

  if (dist > 0 && dist < 90) {
    const isRight = angle > 0;
    const apexSide = isRight ? 0.85 : -0.85;     // Inside apex
    const outsideSide = isRight ? -0.9 : 0.9;     // Outside preparation

    if (dist > 50) {
      targetPos = outsideSide; // Open up the corner entry
    } else if (dist > 15) {
      const ratio = (dist - 15) / 35; // 0 to 1 progressive transition
      targetPos = apexSide + (outsideSide - apexSide) * ratio;
    } else {
      targetPos = apexSide; // Hit the apex
    }
  } else if (state.inCorner && state.cornerSamples.length > 0) {
    const isRight = state.currentCornerAngle > 0;
    targetPos = isRight ? -0.8 : 0.8; // Open up track on corner exit
  }

  // Update green target marker position
  const targetLeftPct = ((targetPos + 1) / 2) * 100;
  trackPosTarget.style.left = `${Math.max(2, Math.min(98, targetLeftPct))}%`;
}

declare global {
  interface Window {
    onTelemetryUpdate: (data: TelemetryData) => void;
  }
}

let updateCount = 0;

// Main telemetry update entrypoint called by CEF interface
window.onTelemetryUpdate = function(data: TelemetryData): void {
  if (!data) {
    console.warn("[Overlay] Received empty telemetry data");
    return;
  }

  if (updateCount === 0) {
    initDOM();
  }

  updateCount++;
  
  // Read dynamic G limits calibrated from Lua (which has low-pass filters)
  state.maxObservedLatG = data.maxObservedLatG || 1.4;
  state.maxObservedDecelG = data.maxObservedDecelG || 1.0;

  // Sync configurations from Lua telemetry
  state.voiceEnabled = data.voiceEnabled ?? false;
  state.drawEntryApexExit = data.drawEntryApexExit ?? true;
  state.showSpeedHolograms = data.showSpeedHolograms ?? true;

  // Calibrate acceleration G max (kept local as it's not physical grip capacity)
  const currentAccelG = data.accG.z;
  if (currentAccelG > state.maxObservedAccelG && currentAccelG < 1.0 && data.throttle > 0.8) {
    state.maxObservedAccelG = currentAccelG;
  }

  if (updateCount % 60 === 1) {
    console.log(`[Overlay] Telemetry update #${updateCount} received. Speed: ${data.speedKmh.toFixed(1)} km/h, Gear: ${data.gear}, RPM: ${Math.round(data.engineRPM)}`);
  }

  // Update basic speed & gear
  if (speedIndicator) {
    speedIndicator.innerText = Math.round(data.speedKmh).toString();
  }
  
  if (gearIndicator) {
    const gear = data.gear;
    if (gear === -1) gearIndicator.innerText = "R";
    else if (gear === 0) gearIndicator.innerText = "N";
    else gearIndicator.innerText = gear.toString();
  }

  // Pedals
  if (throttleBar) {
    throttleBar.style.width = `${Math.min(data.throttle * 100, 100)}%`;
  }
  if (brakeBar) {
    brakeBar.style.width = `${Math.min(data.brake * 100, 100)}%`;
  }

  // RPM bar
  if (rpmBar) {
    const rpmPercent = (data.engineRPM / 8500) * 100;
    rpmBar.style.width = `${Math.min(rpmPercent, 100)}%`;
  }

  // Tyres FL, FR, RL, RR
  if (tyreFL) setTyreVisual(tyreFL, data.tyres[0].slipAngle);
  if (tyreFR) setTyreVisual(tyreFR, data.tyres[1].slipAngle);
  if (tyreRL) setTyreVisual(tyreRL, data.tyres[2].slipAngle);
  if (tyreRR) setTyreVisual(tyreRR, data.tyres[3].slipAngle);

  // G-G Diagram
  updateGGDiagram(data.accG.x, data.accG.z);

  // Next Turn HUD
  updateUpcomingTurn(data);

  // Physics Coach
  analyzePhysics(data);

  // Trace Graph
  drawInputsTrace(data.throttle, data.brake, data.steer);

  // Track Position Target
  updateTrackPositionWidget(data);

  // Front tire scrub check
  checkSteeringScrub(data.speedMs, data.steer, data.tyres[0].slipAngle, data.tyres[1].slipAngle);

  // Corner Scorecard telemetry accumulator
  const dist = data.nextTurnDist;
  const angle = data.nextTurnAngle;
  if (dist > 0 && dist < 80) {
    if (!state.inCorner) {
      state.inCorner = true;
      state.cornerSamples = [];
      state.currentCornerStartDist = dist;
      state.currentCornerAngle = angle;
    }
    state.cornerSamples.push({
      speedMs: data.speedMs,
      roadGrip: data.roadGrip,
      accG: { x: data.accG.x, z: data.accG.z },
      brake: data.brake,
      steer: data.steer,
      trackPosLat: data.trackPosLat
    });
  } else if (state.inCorner && (dist <= 0 || dist > state.currentCornerStartDist + 50)) {
    state.inCorner = false;
    processCornerStats();
  }
};

// Mock Simulation Engine for standard web browsers
function startMockSimulation(): void {
  console.log("[Overlay] Iniciando Simulador de Telemetria Integrado...");
  let mockDistance = 0;
  let mockSpeedMs = 60;
  let mockSteer = 0;
  let mockThrottle = 1.0;
  let mockBrake = 0.0;
  let mockGear = 5;
  let mockRPM = 6000;

  setInterval(() => {
    mockDistance += mockSpeedMs * 0.0167;
    if (mockDistance > 800) {
      mockDistance = 0;
      mockSpeedMs = 50;
      mockGear = 4;
    }

    let nextTurnDist = -1;
    let nextTurnAngle = 65;
    let trackPosLat = 0.0;
    let accX = 0;
    let accZ = 0;

    const tyres = [
      { slipAngle: 0, slipRatio: 0, load: 5000, ndSlip: 0 },
      { slipAngle: 0, slipRatio: 0, load: 5000, ndSlip: 0 },
      { slipAngle: 0, slipRatio: 0, load: 4000, ndSlip: 0 },
      { slipAngle: 0, slipRatio: 0, load: 4000, ndSlip: 0 }
    ];

    if (mockDistance < 250) {
      mockThrottle = 1.0;
      mockBrake = 0.0;
      mockSteer = 0.0;
      mockSpeedMs += 0.35;
      if (mockSpeedMs > 66) mockSpeedMs = 66;
      mockGear = 5;
      mockRPM = 4000 + (mockSpeedMs - 50) * 150;
      trackPosLat = -0.6;
      accZ = -0.3;
    } 
    else if (mockDistance >= 250 && mockDistance < 370) {
      nextTurnDist = 370 - mockDistance;
      trackPosLat = -0.88;

      if (nextTurnDist > 65) {
        mockThrottle = 1.0;
        mockBrake = 0.0;
        accZ = -0.1;
      } else if (nextTurnDist > 15) {
        mockThrottle = 0.0;
        const brakeProgress = (nextTurnDist - 15) / 50;
        mockBrake = 0.15 + brakeProgress * 0.75;
        mockSteer = (1 - brakeProgress) * 0.44;
        mockSpeedMs -= 0.65;
        if (mockSpeedMs < 24) mockSpeedMs = 24;
        mockGear = 3;
        mockRPM = 5200 - (65 - nextTurnDist) * 35;
        
        accZ = mockBrake * 1.1;
        accX = mockSteer * 2.4;
        
        tyres[0].slipAngle = -mockSteer * 14;
        tyres[1].slipAngle = -mockSteer * 12;
        tyres[0].slipRatio = -mockBrake * 0.15;
      } else {
        mockThrottle = 0.15;
        mockBrake = 0.08;
        mockSteer = 0.49;
        mockSpeedMs = 23.5;
        mockRPM = 4600;
        mockGear = 2;
        trackPosLat = 0.82;
        accX = 1.39;
        accZ = 0.08;

        tyres[0].slipAngle = -9.6;
        tyres[1].slipAngle = -8.2;
      }
    } 
    else if (mockDistance >= 370 && mockDistance < 500) {
      nextTurnDist = -1;
      const exitProgress = Math.min(1, (mockDistance - 370) / 130);
      mockThrottle = 0.3 + exitProgress * 0.7;
      mockBrake = 0.0;
      mockSteer = 0.49 * (1 - exitProgress);
      mockSpeedMs += 0.28;
      mockGear = 3;
      mockRPM = 4200 + exitProgress * 1800;
      trackPosLat = 0.82 - exitProgress * 1.62;
      accX = 1.39 * (1 - exitProgress);
      accZ = -mockThrottle * 0.45;

      tyres[0].slipAngle = -mockSteer * 6;
      tyres[1].slipAngle = -mockSteer * 5;
    } 
    else {
      mockThrottle = 1.0;
      mockBrake = 0.0;
      mockSteer = 0.0;
      mockSpeedMs += 0.35;
      mockGear = 4;
      mockRPM = 4800 + (mockSpeedMs - 40) * 80;
      trackPosLat = -0.8;
      accZ = -0.3;
    }

    const mockData: TelemetryData = {
      speedMs: mockSpeedMs,
      speedKmh: mockSpeedMs * 3.6,
      gear: mockGear,
      engineRPM: mockRPM,
      steer: mockSteer,
      throttle: mockThrottle,
      brake: mockBrake,
      clutch: 0,
      yaw: 0,
      yawRate: mockSteer * (mockSpeedMs / 30),
      accG: { x: accX, y: 0.0, z: -accZ },
      tyres: tyres,
      nextTurnDist: nextTurnDist,
      nextTurnAngle: nextTurnAngle,
      roadGrip: 1.0,
      trackPosLat: trackPosLat,
      maxObservedLatG: 1.4,
      maxObservedDecelG: 1.0,
      voiceEnabled: true,
      drawEntryApexExit: true,
      showSpeedHolograms: true
    };

    window.onTelemetryUpdate(mockData);
  }, 16.7);
}

// Check if running in mock/simulation mode
if (window.location.search.includes("mock=true")) {
  initDOM();
  startMockSimulation();
}
