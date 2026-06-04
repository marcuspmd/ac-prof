"use strict";
(() => {
  // overlay/state.ts
  var state = {
    // Session dynamic G limits (calibrated via telemetry)
    maxObservedLatG: 1.4,
    maxObservedDecelG: 1,
    maxObservedAccelG: 0.5,
    // Corner tracking state
    inCorner: false,
    cornerSamples: [],
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
    showSpeedHolograms: true
  };

  // overlay/config.ts
  var WHEELBASE = 2.65;
  var MAX_STEER_RAD = 0.45;
  var SLIP_ANGLE_PEAK = 7;
  var G_SCALE = 35;
  var FEEDBACK_COOLDOWN = 8e3;

  // overlay/gg-diagram.ts
  var ggHistory = [];
  var MAX_GG_HISTORY = 40;
  var canvas = null;
  var ctx = null;
  function initGG() {
    canvas = document.getElementById("gg-canvas");
    if (canvas) {
      ctx = canvas.getContext("2d");
    }
  }
  function drawGGCanvas(currentAccX = 0, currentAccZ = 0) {
    if (!canvas || !ctx) return;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    const cx = canvas.width / 2;
    const cy = canvas.height / 2;
    ctx.strokeStyle = "rgba(255, 255, 255, 0.1)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(cx, cy, 1 * G_SCALE, 0, 2 * Math.PI);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx, cy, 1.5 * G_SCALE, 0, 2 * Math.PI);
    ctx.stroke();
    ctx.strokeStyle = "rgba(255, 255, 255, 0.05)";
    ctx.beginPath();
    ctx.moveTo(0, cy);
    ctx.lineTo(canvas.width, cy);
    ctx.moveTo(cx, 0);
    ctx.lineTo(cx, canvas.height);
    ctx.stroke();
    ctx.strokeStyle = "rgba(239, 68, 68, 0.22)";
    ctx.lineWidth = 1.2;
    ctx.setLineDash([2, 3]);
    const rx = state.maxObservedLatG * G_SCALE;
    const ryAccel = state.maxObservedAccelG * G_SCALE;
    const ryDecel = state.maxObservedDecelG * G_SCALE;
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ryAccel, 0, Math.PI, 2 * Math.PI);
    ctx.stroke();
    ctx.beginPath();
    ctx.ellipse(cx, cy, rx, ryDecel, 0, 0, Math.PI);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = "rgba(255, 255, 255, 0.35)";
    ctx.font = "8px 'Outfit', sans-serif";
    ctx.textAlign = "left";
    const currentTotalG = Math.sqrt(currentAccX * currentAccX + currentAccZ * currentAccZ);
    const maxPossibleG = currentAccZ < 0 ? Math.sqrt(state.maxObservedLatG * state.maxObservedLatG + state.maxObservedAccelG * state.maxObservedAccelG) : Math.sqrt(state.maxObservedLatG * state.maxObservedLatG + state.maxObservedDecelG * state.maxObservedDecelG);
    const utilization = Math.min(100, Math.round(currentTotalG / Math.max(0.1, maxPossibleG) * 100));
    ctx.fillText(`USO: ${utilization}%`, 6, canvas.height - 6);
  }
  function updateGGDiagram(accX, accZ) {
    if (!canvas || !ctx) {
      initGG();
      if (!canvas || !ctx) return;
    }
    const cx = canvas.width / 2;
    const cy = canvas.height / 2;
    const px = cx - accX * G_SCALE;
    const py = cy + accZ * G_SCALE;
    ggHistory.push({ x: px, y: py });
    if (ggHistory.length > MAX_GG_HISTORY) {
      ggHistory.shift();
    }
    drawGGCanvas(accX, accZ);
    for (let i = 0; i < ggHistory.length; i++) {
      const pt = ggHistory[i];
      const alpha = i / ggHistory.length * 0.4;
      ctx.fillStyle = `rgba(59, 130, 246, ${alpha})`;
      ctx.beginPath();
      ctx.arc(pt.x, pt.y, 2, 0, 2 * Math.PI);
      ctx.fill();
    }
    ctx.fillStyle = "#60a5fa";
    ctx.shadowColor = "#3b82f6";
    ctx.shadowBlur = 8;
    ctx.beginPath();
    ctx.arc(px, py, 5, 0, 2 * Math.PI);
    ctx.fill();
    ctx.shadowBlur = 0;
  }

  // overlay/inputs-trace.ts
  var inputHistory = [];
  var MAX_INPUT_HISTORY = 120;
  var traceCanvas = null;
  var traceCtx = null;
  function initTrace() {
    traceCanvas = document.getElementById("trace-canvas");
    if (traceCanvas) {
      traceCtx = traceCanvas.getContext("2d");
    }
  }
  function drawInputsTrace(throttle, brake, steer) {
    if (!traceCanvas || !traceCtx) {
      initTrace();
      if (!traceCanvas || !traceCtx) return;
    }
    inputHistory.push({ throttle, brake, steer });
    if (inputHistory.length > MAX_INPUT_HISTORY) {
      inputHistory.shift();
    }
    traceCtx.clearRect(0, 0, traceCanvas.width, traceCanvas.height);
    const w = traceCanvas.width;
    const h = traceCanvas.height;
    traceCtx.strokeStyle = "rgba(255, 255, 255, 0.08)";
    traceCtx.lineWidth = 1;
    traceCtx.beginPath();
    traceCtx.moveTo(0, h / 2);
    traceCtx.lineTo(w, h / 2);
    traceCtx.stroke();
    traceCtx.strokeStyle = "rgba(59, 130, 246, 0.7)";
    traceCtx.lineWidth = 1.2;
    traceCtx.beginPath();
    for (let i = 0; i < inputHistory.length; i++) {
      const x = i / MAX_INPUT_HISTORY * w;
      const val = inputHistory[i].steer;
      const y = h / 2 + val * (h / 2 - 3);
      if (i === 0) traceCtx.moveTo(x, y);
      else traceCtx.lineTo(x, y);
    }
    traceCtx.stroke();
    traceCtx.strokeStyle = "rgba(239, 68, 68, 0.85)";
    traceCtx.lineWidth = 1.5;
    traceCtx.beginPath();
    for (let i = 0; i < inputHistory.length; i++) {
      const x = i / MAX_INPUT_HISTORY * w;
      const val = inputHistory[i].brake;
      const y = h - val * (h - 6) - 3;
      if (i === 0) traceCtx.moveTo(x, y);
      else traceCtx.lineTo(x, y);
    }
    traceCtx.stroke();
    traceCtx.strokeStyle = "rgba(16, 185, 129, 0.85)";
    traceCtx.lineWidth = 1.5;
    traceCtx.beginPath();
    for (let i = 0; i < inputHistory.length; i++) {
      const x = i / MAX_INPUT_HISTORY * w;
      const val = inputHistory[i].throttle;
      const y = h - val * (h - 6) - 3;
      if (i === 0) traceCtx.moveTo(x, y);
      else traceCtx.lineTo(x, y);
    }
    traceCtx.stroke();
  }

  // overlay/tyre-slip.ts
  function setTyreVisual(element, slipAngle) {
    const absSlip = Math.abs(slipAngle);
    element.className = "tyre-indicator";
    if (absSlip > SLIP_ANGLE_PEAK * 1.4) {
      element.classList.add("tyre-slip-high");
    } else if (absSlip > SLIP_ANGLE_PEAK * 0.9) {
      element.classList.add("tyre-slip-mid");
    } else if (absSlip > 1.5) {
      element.classList.add("tyre-slip-low");
    }
  }
  function checkSteeringScrub(speed, steer, slipFL, slipFR) {
    const avgFrontSlip = (Math.abs(slipFL) + Math.abs(slipFR)) / 2;
    const flEl = document.getElementById("tyre-fl");
    const frEl = document.getElementById("tyre-fr");
    if (flEl && frEl) {
      flEl.classList.remove("tyre-scrub");
      frEl.classList.remove("tyre-scrub");
      if (speed > 4.5 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.3 && Math.abs(steer) > 0.22) {
        flEl.classList.add("tyre-scrub");
        frEl.classList.add("tyre-scrub");
      }
    }
  }

  // overlay/upcoming-turn.ts
  var nextTurnDisplay = null;
  var nextTurnArrow = null;
  var nextTurnDistance = null;
  var nextTurnTargetSpeed = null;
  var nextTurnAction = null;
  var nextTurnStatusIndicator = null;
  var colorsPanel = null;
  var scorecardOverlay = null;
  var scorecardGrade = null;
  var scorecardApexSpeed = null;
  var scorecardTrailScore = null;
  var scorecardApexTiming = null;
  var scorecardGripUtil = null;
  var coachPanel = null;
  var coachMessage = null;
  var scorecardTimeout = null;
  function initUpcomingTurn() {
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
  function speakFeedback(message, type, speak = true) {
    if (!coachPanel || !coachMessage) return false;
    const now = Date.now();
    if (speak && state.voiceEnabled && now - state.lastFeedbackTime < FEEDBACK_COOLDOWN) return false;
    coachPanel.className = "";
    if (type === "warning") coachPanel.classList.add("coach-warning");
    else if (type === "danger") coachPanel.classList.add("coach-danger");
    else if (type === "success") coachPanel.classList.add("coach-success");
    else coachPanel.className = "coach-neutral";
    coachMessage.innerText = message;
    if (speak && state.voiceEnabled && "speechSynthesis" in window) {
      window.speechSynthesis.cancel();
      const utterance = new SpeechSynthesisUtterance(message);
      utterance.lang = "pt-BR";
      utterance.rate = 1;
      utterance.pitch = 0.9;
      window.speechSynthesis.speak(utterance);
      state.lastFeedbackTime = now;
    }
    return true;
  }
  function analyzePhysics(data) {
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
    if (speed > 15 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.3 && brake > 0.1) {
      speakFeedback("Entrada r\xE1pida demais! Alivie a press\xE3o no freio para recuperar ader\xEAncia.", "danger");
      return;
    }
    if (speed > 8 && Math.abs(steer) > 0.15) {
      const expectedYawRaw = speed * steerRad / WHEELBASE;
      const maxPhysicalYaw = 1.35 * 9.81 * Math.max(0.1, data.roadGrip) / Math.max(speed, 1);
      const expectedYaw = Math.min(Math.abs(expectedYawRaw), maxPhysicalYaw) * Math.sign(steerRad);
      const yawDelta = Math.abs(expectedYaw) - Math.abs(yawRate);
      if (yawDelta > 0.15 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.2 && avgFrontSlip > avgRearSlip) {
        speakFeedback("Subester\xE7o! Reduza o \xE2ngulo de ester\xE7o.", "warning");
        return;
      }
    }
    if (Math.abs(yawRate) > 0.15 && speed > 10) {
      const counterSteer = Math.sign(steer) !== Math.sign(yawRate);
      if (counterSteer && avgRearSlip > SLIP_ANGLE_PEAK * 1.2) {
        speakFeedback("Sobrester\xE7o! Mantenha o contra-ester\xE7o controlado.", "danger");
        return;
      }
    }
    if (brake > 0.05 && Math.abs(steer) > 0.2) {
      if (brake > 0.6) {
        speakFeedback("Sobrecarga de frenagem! Alivie o freio na entrada da curva.", "warning", false);
        return;
      } else if (brake < 0.2 && brake > 0.05) {
        speakFeedback("Belo Trail Braking. Segure o nariz do carro at\xE9 o \xE1pice.", "success", false);
        return;
      }
    }
    if (throttle > 0.5 && Math.abs(steer) > 0.3 && speed < 30) {
      if (avgRearSlip > SLIP_ANGLE_PEAK * 0.8) {
        speakFeedback("Patinando na tra\xE7\xE3o! Suavize a aplica\xE7\xE3o de acelera\xE7\xE3o.", "warning");
        return;
      }
    }
    const slipRatioFL = data.tyres[0].slipRatio;
    const slipRatioFR = data.tyres[1].slipRatio;
    const slipRatioRL = data.tyres[2].slipRatio;
    const slipRatioRR = data.tyres[3].slipRatio;
    if (brake > 0.15) {
      if (slipRatioFL < -0.22 || slipRatioFR < -0.22) {
        speakFeedback("Travando rodas dianteiras! Alivie o freio para n\xE3o passar reto.", "danger", false);
        return;
      }
      if (slipRatioRL < -0.22 || slipRatioRR < -0.22) {
        speakFeedback("Travando rodas traseiras! Risco de rodar, alivie o freio.", "danger", false);
        return;
      }
    }
    if (speed > 5) {
      coachMessage.innerText = "Pilotagem limpa. Mantenha os olhos nos pontos de frenagem.";
      coachPanel.className = "coach-neutral";
    }
  }
  function updateUpcomingTurn(data) {
    if (!nextTurnDistance || !nextTurnArrow || !nextTurnDisplay || !nextTurnStatusIndicator || !nextTurnTargetSpeed || !nextTurnAction) {
      initUpcomingTurn();
      if (!nextTurnDistance || !nextTurnArrow || !nextTurnDisplay || !nextTurnStatusIndicator || !nextTurnTargetSpeed || !nextTurnAction) return;
    }
    const dist = data.nextTurnDist;
    const angle = data.nextTurnAngle;
    if (dist <= 0) {
      nextTurnDistance.innerText = "--m";
      nextTurnArrow.innerText = "\u21A9\uFE0F";
      nextTurnDisplay.className = "panel-glass";
      nextTurnStatusIndicator.className = "status-neutral";
      nextTurnTargetSpeed.innerText = "Ideal: -- km/h";
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
    nextTurnArrow.innerText = isRight ? "\u27A1\uFE0F" : "\u2B05\uFE0F";
    const speed = data.speedMs;
    const absAngle = Math.abs(angle);
    let baseTargetKmh = 800 / Math.sqrt(Math.max(1, absAngle));
    baseTargetKmh = Math.max(50, Math.min(290, baseTargetKmh));
    const gripFactor = Math.sqrt(Math.max(0.1, data.roadGrip));
    const carPerformanceFactor = Math.min(1.25, Math.sqrt(state.maxObservedLatG / 1.4));
    let vTargetKmh = baseTargetKmh * gripFactor * carPerformanceFactor;
    const pLat = data.trackPosLat;
    const wrongSideFactor = isRight ? pLat : -pLat;
    if (dist < 60 && wrongSideFactor > 0) {
      const proximityScale = (60 - dist) / 60;
      vTargetKmh = vTargetKmh * (1 - 0.2 * wrongSideFactor * proximityScale);
    }
    const vTarget = vTargetKmh / 3.6;
    nextTurnTargetSpeed.innerText = `Ideal: ${Math.round(vTargetKmh)} km/h`;
    const targetDecelMs2 = state.maxObservedDecelG * 9.81 * 0.8 * Math.max(0.5, data.roadGrip);
    const reactionTime = 0.3;
    const reactionDistance = speed * reactionTime;
    let physicalBrakingDistance = 0;
    if (speed > vTarget) {
      physicalBrakingDistance = (speed * speed - vTarget * vTarget) / (2 * targetDecelMs2);
    }
    const totalBrakingDistanceNeeded = physicalBrakingDistance + reactionDistance;
    let aReq = 0;
    if (speed > vTarget) {
      aReq = (speed * speed - vTarget * vTarget) / (2 * Math.max(1, dist));
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
    if (speed > 10 && speed < vTarget - 5 && dist < 100) {
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
      if (dist <= totalBrakingDistanceNeeded + 12) {
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
        if (dist < 70) {
          nextTurnDisplay.className = "panel-glass next-turn-warning";
          if (nextTurnStatusIndicator) nextTurnStatusIndicator.className = "status-warning";
          nextTurnAction.innerText = "PREPARE-SE";
          if (colorsPanel) colorsPanel.className = "state-warning";
        } else {
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
  function processCornerStats() {
    if (state.cornerSamples.length < 5) return;
    if (!scorecardOverlay || !scorecardGrade || !scorecardApexSpeed || !scorecardTrailScore || !scorecardApexTiming || !scorecardGripUtil) {
      initUpcomingTurn();
      if (!scorecardOverlay || !scorecardGrade || !scorecardApexSpeed || !scorecardTrailScore || !scorecardApexTiming || !scorecardGripUtil) return;
    }
    const speedKmhList = state.cornerSamples.map((s) => s.speedMs * 3.6);
    const minSpeedKmh = Math.min(...speedKmhList);
    let baseTargetKmh = 800 / Math.sqrt(Math.max(1, Math.abs(state.currentCornerAngle)));
    baseTargetKmh = Math.max(50, Math.min(290, baseTargetKmh));
    const gripFactor = Math.sqrt(Math.max(0.1, state.cornerSamples[0].roadGrip));
    const carPerformanceFactor = Math.min(1.25, Math.sqrt(state.maxObservedLatG / 1.4));
    const targetKmh = baseTargetKmh * gripFactor * carPerformanceFactor;
    const speedDiff = minSpeedKmh - targetKmh;
    let speedScore = 100;
    if (speedDiff < 0) {
      speedScore = Math.max(0, 100 - Math.abs(speedDiff) * 4.5);
    } else {
      speedScore = Math.max(0, 100 - Math.abs(speedDiff) * 2.5);
    }
    let trailBrakingSamples = 0;
    let perfectTrailSamples = 0;
    let highBrakeSteerSamples = 0;
    let earlyRelease = true;
    state.cornerSamples.forEach((s) => {
      if (Math.abs(s.steer) > 0.15) {
        if (s.brake > 0.05) {
          earlyRelease = false;
          trailBrakingSamples++;
          if (s.brake <= 0.3) {
            perfectTrailSamples++;
          } else {
            highBrakeSteerSamples++;
          }
        }
      }
    });
    let trailScore = 0;
    if (earlyRelease) {
      trailScore = 35;
    } else if (trailBrakingSamples > 0) {
      const perfectRatio = perfectTrailSamples / trailBrakingSamples;
      const highBrakeRatio = highBrakeSteerSamples / trailBrakingSamples;
      trailScore = Math.round(50 + 55 * perfectRatio - 35 * highBrakeRatio);
      trailScore = Math.max(0, Math.min(100, trailScore));
    } else {
      trailScore = 100;
    }
    let apexTimingText = "Ideal";
    const minSpeedIndex = state.cornerSamples.findIndex((s) => s.speedMs * 3.6 === minSpeedKmh);
    const pct = minSpeedIndex / state.cornerSamples.length;
    const insideDirection = state.currentCornerAngle > 0 ? 1 : -1;
    const maxInsideDev = Math.max(...state.cornerSamples.map((s) => s.trackPosLat * insideDirection));
    if (maxInsideDev < 0.45) {
      apexTimingText = "Longe do \xC1pice";
    } else if (pct < 0.28) {
      apexTimingText = "\xC1pice Cedo";
    } else if (pct > 0.72) {
      apexTimingText = "\xC1pice Atrasado";
    } else {
      apexTimingText = "Perfeito";
    }
    let totalEff = 0;
    state.cornerSamples.forEach((s) => {
      const g = Math.sqrt(s.accG.x * s.accG.x + s.accG.z * s.accG.z);
      const eff = g / state.maxObservedLatG;
      totalEff += eff;
    });
    const avgGripUtil = Math.round(totalEff / state.cornerSamples.length * 100);
    const finalGripUtil = Math.min(100, Math.max(0, avgGripUtil));
    const gripScore = Math.min(100, finalGripUtil / 85 * 100);
    const finalScore = Math.round(speedScore * 0.4 + trailScore * 0.3 + gripScore * 0.3);
    let grade = "C";
    let gradeClass = "grade-blue";
    if (finalScore >= 95) {
      grade = "S";
      gradeClass = "grade-gold";
    } else if (finalScore >= 88) {
      grade = "A+";
      gradeClass = "grade-green";
    } else if (finalScore >= 80) {
      grade = "A";
      gradeClass = "grade-green";
    } else if (finalScore >= 70) {
      grade = "B";
      gradeClass = "grade-blue";
    } else if (finalScore >= 60) {
      grade = "C";
      gradeClass = "grade-blue";
    } else {
      grade = "D";
      gradeClass = "grade-red";
    }
    scorecardGrade.innerText = grade;
    scorecardGrade.className = gradeClass;
    scorecardApexSpeed.innerText = `${Math.round(minSpeedKmh)} km/h (Ideal: ${Math.round(targetKmh)})`;
    scorecardTrailScore.innerText = `${Math.round(trailScore)}%`;
    scorecardApexTiming.innerText = apexTimingText;
    scorecardGripUtil.innerText = `${Math.round(finalGripUtil)}%`;
    scorecardOverlay.classList.remove("scorecard-hidden");
    if (scorecardTimeout) clearTimeout(scorecardTimeout);
    scorecardTimeout = setTimeout(() => {
      if (scorecardOverlay) {
        scorecardOverlay.classList.add("scorecard-hidden");
      }
    }, 4500);
  }

  // overlay/app.ts
  var mode = window.location.hash ? window.location.hash.substring(1) : "full";
  document.body.className = `mode-${mode}`;
  console.log(`[Overlay] Initialized in mode: ${mode}`);
  var speedIndicator = null;
  var gearIndicator = null;
  var rpmBar = null;
  var throttleBar = null;
  var brakeBar = null;
  var trackPosTarget = null;
  var trackPosCar = null;
  var tyreFL = null;
  var tyreFR = null;
  var tyreRL = null;
  var tyreRR = null;
  function initDOM() {
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
  function updateTrackPositionWidget(data) {
    if (!trackPosTarget || !trackPosCar) return;
    const dist = data.nextTurnDist;
    const angle = data.nextTurnAngle;
    const currentPos = data.trackPosLat;
    const carLeftPct = (currentPos + 1) / 2 * 100;
    trackPosCar.style.left = `${Math.max(2, Math.min(98, carLeftPct))}%`;
    let targetPos = 0;
    if (dist > 0 && dist < 90) {
      const isRight = angle > 0;
      const apexSide = isRight ? 0.85 : -0.85;
      const outsideSide = isRight ? -0.9 : 0.9;
      if (dist > 50) {
        targetPos = outsideSide;
      } else if (dist > 15) {
        const ratio = (dist - 15) / 35;
        targetPos = apexSide + (outsideSide - apexSide) * ratio;
      } else {
        targetPos = apexSide;
      }
    } else if (state.inCorner && state.cornerSamples.length > 0) {
      const isRight = state.currentCornerAngle > 0;
      targetPos = isRight ? -0.8 : 0.8;
    }
    const targetLeftPct = (targetPos + 1) / 2 * 100;
    trackPosTarget.style.left = `${Math.max(2, Math.min(98, targetLeftPct))}%`;
  }
  var updateCount = 0;
  window.onTelemetryUpdate = function(data) {
    if (!data) {
      console.warn("[Overlay] Received empty telemetry data");
      return;
    }
    if (updateCount === 0) {
      initDOM();
    }
    updateCount++;
    state.maxObservedLatG = data.maxObservedLatG || 1.4;
    state.maxObservedDecelG = data.maxObservedDecelG || 1;
    state.voiceEnabled = data.voiceEnabled ?? false;
    state.drawEntryApexExit = data.drawEntryApexExit ?? true;
    state.showSpeedHolograms = data.showSpeedHolograms ?? true;
    const currentAccelG = data.accG.z;
    if (currentAccelG > state.maxObservedAccelG && currentAccelG < 1 && data.throttle > 0.8) {
      state.maxObservedAccelG = currentAccelG;
    }
    if (updateCount % 60 === 1) {
      console.log(`[Overlay] Telemetry update #${updateCount} received. Speed: ${data.speedKmh.toFixed(1)} km/h, Gear: ${data.gear}, RPM: ${Math.round(data.engineRPM)}`);
    }
    if (speedIndicator) {
      speedIndicator.innerText = Math.round(data.speedKmh).toString();
    }
    if (gearIndicator) {
      const gear = data.gear;
      if (gear === -1) gearIndicator.innerText = "R";
      else if (gear === 0) gearIndicator.innerText = "N";
      else gearIndicator.innerText = gear.toString();
    }
    if (throttleBar) {
      throttleBar.style.width = `${Math.min(data.throttle * 100, 100)}%`;
    }
    if (brakeBar) {
      brakeBar.style.width = `${Math.min(data.brake * 100, 100)}%`;
    }
    if (rpmBar) {
      const rpmPercent = data.engineRPM / 8500 * 100;
      rpmBar.style.width = `${Math.min(rpmPercent, 100)}%`;
    }
    if (tyreFL) setTyreVisual(tyreFL, data.tyres[0].slipAngle);
    if (tyreFR) setTyreVisual(tyreFR, data.tyres[1].slipAngle);
    if (tyreRL) setTyreVisual(tyreRL, data.tyres[2].slipAngle);
    if (tyreRR) setTyreVisual(tyreRR, data.tyres[3].slipAngle);
    updateGGDiagram(data.accG.x, data.accG.z);
    updateUpcomingTurn(data);
    analyzePhysics(data);
    drawInputsTrace(data.throttle, data.brake, data.steer);
    updateTrackPositionWidget(data);
    checkSteeringScrub(data.speedMs, data.steer, data.tyres[0].slipAngle, data.tyres[1].slipAngle);
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
  function startMockSimulation() {
    console.log("[Overlay] Iniciando Simulador de Telemetria Integrado...");
    let mockDistance = 0;
    let mockSpeedMs = 60;
    let mockSteer = 0;
    let mockThrottle = 1;
    let mockBrake = 0;
    let mockGear = 5;
    let mockRPM = 6e3;
    setInterval(() => {
      mockDistance += mockSpeedMs * 0.0167;
      if (mockDistance > 800) {
        mockDistance = 0;
        mockSpeedMs = 50;
        mockGear = 4;
      }
      let nextTurnDist = -1;
      let nextTurnAngle = 65;
      let trackPosLat = 0;
      let accX = 0;
      let accZ = 0;
      const tyres = [
        { slipAngle: 0, slipRatio: 0, load: 5e3, ndSlip: 0 },
        { slipAngle: 0, slipRatio: 0, load: 5e3, ndSlip: 0 },
        { slipAngle: 0, slipRatio: 0, load: 4e3, ndSlip: 0 },
        { slipAngle: 0, slipRatio: 0, load: 4e3, ndSlip: 0 }
      ];
      if (mockDistance < 250) {
        mockThrottle = 1;
        mockBrake = 0;
        mockSteer = 0;
        mockSpeedMs += 0.35;
        if (mockSpeedMs > 66) mockSpeedMs = 66;
        mockGear = 5;
        mockRPM = 4e3 + (mockSpeedMs - 50) * 150;
        trackPosLat = -0.6;
        accZ = -0.3;
      } else if (mockDistance >= 250 && mockDistance < 370) {
        nextTurnDist = 370 - mockDistance;
        trackPosLat = -0.88;
        if (nextTurnDist > 65) {
          mockThrottle = 1;
          mockBrake = 0;
          accZ = -0.1;
        } else if (nextTurnDist > 15) {
          mockThrottle = 0;
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
      } else if (mockDistance >= 370 && mockDistance < 500) {
        nextTurnDist = -1;
        const exitProgress = Math.min(1, (mockDistance - 370) / 130);
        mockThrottle = 0.3 + exitProgress * 0.7;
        mockBrake = 0;
        mockSteer = 0.49 * (1 - exitProgress);
        mockSpeedMs += 0.28;
        mockGear = 3;
        mockRPM = 4200 + exitProgress * 1800;
        trackPosLat = 0.82 - exitProgress * 1.62;
        accX = 1.39 * (1 - exitProgress);
        accZ = -mockThrottle * 0.45;
        tyres[0].slipAngle = -mockSteer * 6;
        tyres[1].slipAngle = -mockSteer * 5;
      } else {
        mockThrottle = 1;
        mockBrake = 0;
        mockSteer = 0;
        mockSpeedMs += 0.35;
        mockGear = 4;
        mockRPM = 4800 + (mockSpeedMs - 40) * 80;
        trackPosLat = -0.8;
        accZ = -0.3;
      }
      const mockData = {
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
        accG: { x: accX, y: 0, z: -accZ },
        tyres,
        nextTurnDist,
        nextTurnAngle,
        roadGrip: 1,
        trackPosLat,
        maxObservedLatG: 1.4,
        maxObservedDecelG: 1,
        voiceEnabled: true,
        drawEntryApexExit: true,
        showSpeedHolograms: true
      };
      window.onTelemetryUpdate(mockData);
    }, 16.7);
  }
  if (window.location.search.includes("mock=true")) {
    initDOM();
    startMockSimulation();
  }
})();
