import { AUDIO_ENABLED, FEEDBACK_COOLDOWN, WHEELBASE, MAX_STEER_RAD, SLIP_ANGLE_PEAK } from './config';
import { state, CornerSample } from './state';

let nextTurnDisplay: HTMLElement | null = null;
let nextTurnArrow: HTMLElement | null = null;
let nextTurnDistance: HTMLElement | null = null;
let nextTurnTargetSpeed: HTMLElement | null = null;
let nextTurnAction: HTMLElement | null = null;
let nextTurnStatusIndicator: HTMLElement | null = null;
let colorsPanel: HTMLElement | null = null;

let scorecardOverlay: HTMLElement | null = null;
let scorecardGrade: HTMLElement | null = null;
let scorecardApexSpeed: HTMLElement | null = null;
let scorecardTrailScore: HTMLElement | null = null;
let scorecardApexTiming: HTMLElement | null = null;
let scorecardGripUtil: HTMLElement | null = null;

let coachPanel: HTMLElement | null = null;
let coachMessage: HTMLElement | null = null;

let scorecardTimeout: any = null;

export function initUpcomingTurn(): void {
  nextTurnDisplay = document.getElementById("next-turn-display");
  nextTurnArrow = document.getElementById("next-turn-arrow");
  nextTurnDistance = document.getElementById("next-turn-distance");
  nextTurnTargetSpeed = document.getElementById("next-turn-target-speed");
  nextTurnAction = document.getElementById("next-turn-action");
  nextTurnStatusIndicator = document.getElementById("next-turn-status-indicator");
  colorsPanel = document.getElementById("colors-panel");

  scorecardOverlay = document.getElementById("scorecard-overlay");
  scorecardGrade = document.getElementById("scorecard-grade");
  scorecardApexSpeed = document.getElementById("scorecard-apex-speed");
  scorecardTrailScore = document.getElementById("scorecard-trail-score");
  scorecardApexTiming = document.getElementById("scorecard-apex-timing");
  scorecardGripUtil = document.getElementById("scorecard-grip-util");

  coachPanel = document.getElementById("coach-panel");
  coachMessage = document.getElementById("coach-message");
}

// Speaks feedback to player using Speech Synthesis API (race engineer voice overlay)
export function speakFeedback(message: string, type: "neutral" | "warning" | "danger" | "success", speak: boolean = true): boolean {
  if (!coachPanel || !coachMessage) return false;

  const now = Date.now();
  if (speak && state.voiceEnabled && (now - state.lastFeedbackTime < FEEDBACK_COOLDOWN)) return false;

  // Set visual feedback classes
  coachPanel.className = "";
  if (type === "warning") coachPanel.classList.add("coach-warning");
  else if (type === "danger") coachPanel.classList.add("coach-danger");
  else if (type === "success") coachPanel.classList.add("coach-success");
  else coachPanel.className = "coach-neutral";

  coachMessage.innerText = message;
  
  if (speak && state.voiceEnabled && 'speechSynthesis' in window) {
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(message);
    utterance.lang = "pt-BR";
    utterance.rate = 1.0;
    utterance.pitch = 0.9;
    window.speechSynthesis.speak(utterance);
    state.lastFeedbackTime = now;
  }


  return true;
}

// Heuristics Engine
export function analyzePhysics(data: TelemetryData): void {
  if (!coachMessage || !coachPanel) return;

  const speed = data.speedMs;
  const steer = data.steer;
  const yawRate = data.yawRate;
  const brake = data.brake;
  const throttle = data.throttle;
  
  const steerRad = steer * MAX_STEER_RAD;

  const slipFL = data.tyres[0].slipAngle;
  const slipFR = data.tyres[1].slipAngle;
  const slipRL = data.tyres[2].slipAngle;
  const slipRR = data.tyres[3].slipAngle;

  const avgFrontSlip = (Math.abs(slipFL) + Math.abs(slipFR)) / 2;
  const avgRearSlip = (Math.abs(slipRL) + Math.abs(slipRR)) / 2;

  // 1. Overspeed entry check
  if (speed > 15 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.3 && brake > 0.1) {
    speakFeedback("Entrada rápida demais! Alivie a pressão no freio para recuperar aderência.", "danger");
    return;
  }

  // 2. Understeer check
  if (speed > 8 && Math.abs(steer) > 0.15) {
    const expectedYawRaw = (speed * steerRad) / WHEELBASE;
    const maxPhysicalYaw = (1.35 * 9.81 * Math.max(0.1, data.roadGrip)) / Math.max(speed, 1.0);
    const expectedYaw = Math.min(Math.abs(expectedYawRaw), maxPhysicalYaw) * Math.sign(steerRad);

    const yawDelta = Math.abs(expectedYaw) - Math.abs(yawRate);

    if (yawDelta > 0.15 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.2 && avgFrontSlip > avgRearSlip) {
      speakFeedback("Subesterço! Reduza o ângulo de esterço.", "warning");
      return;
    }
  }

  // 3. Oversteer check
  if (Math.abs(yawRate) > 0.15 && speed > 10) {
    const counterSteer = Math.sign(steer) !== Math.sign(yawRate);
    if (counterSteer && avgRearSlip > SLIP_ANGLE_PEAK * 1.2) {
      speakFeedback("Sobresterço! Mantenha o contra-esterço controlado.", "danger");
      return;
    }
  }

  // 4. Trail braking check
  if (brake > 0.05 && Math.abs(steer) > 0.2) {
    if (brake > 0.6) {
      speakFeedback("Sobrecarga de frenagem! Alivie o freio na entrada da curva.", "warning", false);
      return;
    } else if (brake < 0.2 && brake > 0.05) {
      speakFeedback("Belo Trail Braking. Segure o nariz do carro até o ápice.", "success", false);
      return;
    }
  }

  // 5. Early throttle check
  if (throttle > 0.5 && Math.abs(steer) > 0.3 && speed < 30) {
    if (avgRearSlip > SLIP_ANGLE_PEAK * 0.8) {
      speakFeedback("Patinando na tração! Suavize a aplicação de aceleração.", "warning");
      return;
    }
  }

  // 6. Lockup check
  const slipRatioFL = data.tyres[0].slipRatio;
  const slipRatioFR = data.tyres[1].slipRatio;
  const slipRatioRL = data.tyres[2].slipRatio;
  const slipRatioRR = data.tyres[3].slipRatio;

  if (brake > 0.15) {
    if (slipRatioFL < -0.22 || slipRatioFR < -0.22) {
      speakFeedback("Travando rodas dianteiras! Alivie o freio para não passar reto.", "danger", false);
      return;
    }
    if (slipRatioRL < -0.22 || slipRatioRR < -0.22) {
      speakFeedback("Travando rodas traseiras! Risco de rodar, alivie o freio.", "danger", false);
      return;
    }
  }

  // Default feedback
  if (speed > 5) {
    coachMessage.innerText = "Pilotagem limpa. Mantenha os olhos nos pontos de frenagem.";
    coachPanel.className = "coach-neutral";
  }
}

// Update the upcoming corner alert HUD
export function updateUpcomingTurn(data: TelemetryData): void {
  if (!nextTurnDistance || !nextTurnArrow || !nextTurnDisplay || !nextTurnStatusIndicator || !nextTurnTargetSpeed || !nextTurnAction) {
    initUpcomingTurn();
    if (!nextTurnDistance || !nextTurnArrow || !nextTurnDisplay || !nextTurnStatusIndicator || !nextTurnTargetSpeed || !nextTurnAction) return;
  }

  const dist = data.nextTurnDist;
  const angle = data.nextTurnAngle;

  if (dist <= 0) {
    nextTurnDistance.innerText = "--m";
    nextTurnArrow.innerText = "↩️";
    nextTurnDisplay.className = "panel-glass";
    nextTurnStatusIndicator.className = "status-neutral";
    nextTurnTargetSpeed.innerHTML = `<span style="color: #ffffff;">${Math.round(data.speedKmh)}</span> <span style="color: #6b7280;">/</span> <span style="color: #6b7280;">--</span> <span style="font-size: 10px; color: #6b7280; margin-left: 2px;">km/h</span>`;
    nextTurnAction.innerText = "MANTENHA VELOCIDADE";
    if (colorsPanel) colorsPanel.className = "state-neutral";
    state.hasAnnouncedCurrentTurn = false;
    state.hasAnnouncedBrakingPoint = false;
    state.lastNextTurnDist = dist;
    state.lastNextTurnAngle = angle;
    return;
  }

  const distIncreased = dist > state.lastNextTurnDist + 50;
  const angleChanged = Math.abs(angle - state.lastNextTurnAngle) > 20;

  if (distIncreased || angleChanged) {
    state.hasAnnouncedCurrentTurn = false;
    state.hasAnnouncedBrakingPoint = false;
  }

  state.lastNextTurnDist = dist;
  state.lastNextTurnAngle = angle;

  nextTurnDistance.innerText = `${Math.round(dist)}m`;
  
  const isRight = angle > 0;
  nextTurnArrow.innerText = isRight ? "➡️" : "⬅️";

  const speed = data.speedMs;
  const absAngle = Math.abs(angle);

  const vTargetKmh = data.vTargetKmh || 0;
  const vTarget = vTargetKmh / 3.6;
  
  const actualKmh = data.speedKmh;
  let speedClass = "speed-safe";
  if (actualKmh > vTargetKmh + 15) {
    speedClass = "speed-danger";
  } else if (actualKmh > vTargetKmh + 5) {
    speedClass = "speed-warning";
  }
  nextTurnTargetSpeed.innerHTML = `<span class="${speedClass}">${Math.round(actualKmh)}</span> <span style="color: #6b7280; font-weight: normal;">/</span> <span style="color: #3b82f6;">${Math.round(vTargetKmh)}</span> <span style="font-size: 10px; color: #6b7280; margin-left: 2px;">km/h</span>`;

  // Braking distance calculations
  const totalBrakingDistanceNeeded = data.totalBrakingDistanceNeeded || 0;

  let aReq = 0;
  if (speed > vTarget) {
    aReq = (speed * speed - vTarget * vTarget) / (2 * Math.max(1.0, dist));
  }

  const aActual = Math.max(0, -data.accG.z * 9.81);
  const isBraking = data.brake > 0.15;
  const isBrakingSufficiently = isBraking && (data.brake > 0.4 || aActual >= aReq - 1.5);

  let frontLocked = false;
  let rearLocked = false;
  if (data.brake > 0.15) {
    if (data.tyres[0].slipRatio < -0.22 || data.tyres[1].slipRatio < -0.22) {
      frontLocked = true;
    }
    if (data.tyres[2].slipRatio < -0.22 || data.tyres[3].slipRatio < -0.22) {
      rearLocked = true;
    }
  }

  if (speed > 10.0 && speed < vTarget - 5.0 && dist < 100) {
    nextTurnDisplay.className = "panel-glass next-turn-safe";
    if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-safe";
    nextTurnAction.innerText = "ACELERE!";
    if (colorsPanel) colorsPanel.className = "state-safe";
  } else if (speed <= vTarget) {
    nextTurnDisplay.className = "panel-glass next-turn-safe";
    if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-safe";
    nextTurnAction.innerText = "VELOCIDADE OK";
    if (colorsPanel) colorsPanel.className = "state-safe";
  } else {
    // speed > vTarget (we need to slow down)
    if (dist <= totalBrakingDistanceNeeded + 12) {
      // Braking zone
      if (frontLocked) {
        nextTurnDisplay.className = "panel-glass next-turn-danger";
        if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-danger";
        nextTurnAction.innerText = "TRAVANDO FRENTE!";
        if (colorsPanel) colorsPanel.className = "state-danger";
      } else if (rearLocked) {
        nextTurnDisplay.className = "panel-glass next-turn-danger";
        if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-danger";
        nextTurnAction.innerText = "TRAVANDO TRASEIRA!";
        if (colorsPanel) colorsPanel.className = "state-danger";
      } else if (isBrakingSufficiently) {
        nextTurnDisplay.className = "panel-glass next-turn-braking";
        if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-braking";
        nextTurnAction.innerText = "FRENAGEM OK";
        if (colorsPanel) colorsPanel.className = "state-braking";
      } else {
        nextTurnDisplay.className = "panel-glass next-turn-danger";
        if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-danger";
        nextTurnAction.innerText = "FREIE AGORA!";
        if (colorsPanel) colorsPanel.className = "state-danger";
        
        if (!state.hasAnnouncedBrakingPoint) {
          if (speakFeedback("Freie!", "danger")) {
            state.hasAnnouncedBrakingPoint = true;
          }
        }
      }
    } else {
      // Approaching, but not in immediate braking zone yet
      if (dist < 70) {
        // Close to the corner, show PREPARE-SE (yellow) instead of green to avoid premature release
        nextTurnDisplay.className = "panel-glass next-turn-warning";
        if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-warning";
        nextTurnAction.innerText = "PREPARE-SE";
        if (colorsPanel) colorsPanel.className = "state-warning";
      } else {
        // Far away
        if (dist > totalBrakingDistanceNeeded + 25) {
          nextTurnDisplay.className = "panel-glass next-turn-safe";
          if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-safe";
          nextTurnAction.innerText = "VELOCIDADE OK";
          if (colorsPanel) colorsPanel.className = "state-safe";
        } else {
          nextTurnDisplay.className = "panel-glass next-turn-warning";
          if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-warning";
          nextTurnAction.innerText = "PREPARE-SE";
          if (colorsPanel) colorsPanel.className = "state-warning";
        }
      }
    }
  }
}

// Process corner score card overlay at exit of the corner (called by Lua backend or mock)
export function displayCornerScorecard(scorecard: any): void {
  if (!scorecardOverlay || !scorecardGrade || !scorecardApexSpeed || !scorecardTrailScore || !scorecardApexTiming || !scorecardGripUtil) {
    initUpcomingTurn();
    if (!scorecardOverlay || !scorecardGrade || !scorecardApexSpeed || !scorecardTrailScore || !scorecardApexTiming || !scorecardGripUtil) return;
  }

  let gradeClass = "grade-blue";
  if (scorecard.grade === "S") { gradeClass = "grade-gold"; }
  else if (scorecard.grade.startsWith("A")) { gradeClass = "grade-green"; }
  else if (scorecard.grade.startsWith("B")) { gradeClass = "grade-blue"; }
  else if (scorecard.grade.startsWith("C")) { gradeClass = "grade-blue"; }
  else { gradeClass = "grade-red"; }

  scorecardGrade.innerText = scorecard.grade;
  scorecardGrade.className = gradeClass;
  
  scorecardApexSpeed.innerText = `${Math.round(scorecard.minSpeedKmh)} km/h (Ideal: ${Math.round(scorecard.targetSpeedKmh)})`;
  scorecardTrailScore.innerText = `${Math.round(scorecard.trailScore)}%`;
  scorecardApexTiming.innerText = scorecard.apexTiming;
  scorecardGripUtil.innerText = `${Math.round(scorecard.gripUtilization)}%`;

  scorecardOverlay.classList.remove("scorecard-hidden");

  if (scorecardTimeout) clearTimeout(scorecardTimeout);
  scorecardTimeout = setTimeout(() => {
    if (scorecardOverlay) {
      scorecardOverlay.classList.add("scorecard-hidden");
    }
  }, 4500);
}
