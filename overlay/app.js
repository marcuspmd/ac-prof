"use strict";
// Configurações e Variáveis do Veículo (GT3 padrão)
const WHEELBASE = 2.65; // metros (entre-eixos aproximado)
const MAX_STEER_RAD = 0.45; // ~26 graus de esterço máximo da roda dianteira
const SLIP_ANGLE_PEAK = 7.0; // graus (pico de aderência dos pneus)
const G_SCALE = 35; // Pixels por G no canvas
// Histórico para o Diagrama G-G
const ggHistory = [];
const MAX_GG_HISTORY = 40;
// Estado de Coaching e Debounce de Voz
let lastFeedbackTime = 0;
const FEEDBACK_COOLDOWN = 4000; // 4 segundos entre mensagens faladas
// Elementos DOM
const speedIndicator = document.getElementById("speed-indicator");
const gearIndicator = document.getElementById("gear-indicator");
const rpmBar = document.getElementById("rpm-bar");
const throttleBar = document.getElementById("throttle-bar");
const brakeBar = document.getElementById("brake-bar");
const coachMessage = document.getElementById("coach-message");
const coachPanel = document.getElementById("coach-panel");
const tyreFL = document.getElementById("tyre-fl");
const tyreFR = document.getElementById("tyre-fr");
const tyreRL = document.getElementById("tyre-rl");
const tyreRR = document.getElementById("tyre-rr");
// Setup Canvas G-G
const canvas = document.getElementById("gg-canvas");
const ctx = canvas.getContext("2d");
function initGGCanvas() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    const cx = canvas.width / 2;
    const cy = canvas.height / 2;
    // Desenhar círculos de referência (1G, 1.5G)
    ctx.strokeStyle = "rgba(255, 255, 255, 0.1)";
    ctx.lineWidth = 1;
    // 1G Circle
    ctx.beginPath();
    ctx.arc(cx, cy, 1.0 * G_SCALE, 0, 2 * Math.PI);
    ctx.stroke();
    // 1.5G Circle
    ctx.beginPath();
    ctx.arc(cx, cy, 1.5 * G_SCALE, 0, 2 * Math.PI);
    ctx.stroke();
    // Eixos Cruzados
    ctx.strokeStyle = "rgba(255, 255, 255, 0.05)";
    ctx.beginPath();
    ctx.moveTo(0, cy);
    ctx.lineTo(canvas.width, cy);
    ctx.moveTo(cx, 0);
    ctx.lineTo(cx, canvas.height);
    ctx.stroke();
}
function updateGGDiagram(accX, accZ) {
    const cx = canvas.width / 2;
    const cy = canvas.height / 2;
    // Inverter o X porque forças G laterais são opostas ao sentido físico de curva
    const px = cx - accX * G_SCALE;
    const py = cy + accZ * G_SCALE; // accZ negativo é aceleração, positivo é frenagem
    // Adiciona ao histórico
    ggHistory.push({ x: px, y: py });
    if (ggHistory.length > MAX_GG_HISTORY) {
        ggHistory.shift();
    }
    // Redesenha a base
    initGGCanvas();
    // Desenha o rastro histórico (fading)
    for (let i = 0; i < ggHistory.length; i++) {
        const pt = ggHistory[i];
        const alpha = (i / ggHistory.length) * 0.4;
        ctx.fillStyle = `rgba(59, 130, 246, ${alpha})`;
        ctx.beginPath();
        ctx.arc(pt.x, pt.y, 2, 0, 2 * Math.PI);
        ctx.fill();
    }
    // Desenha o ponto atual em destaque
    ctx.fillStyle = "#60a5fa";
    ctx.shadowColor = "#3b82f6";
    ctx.shadowBlur = 8;
    ctx.beginPath();
    ctx.arc(px, py, 5, 0, 2 * Math.PI);
    ctx.fill();
    ctx.shadowBlur = 0; // Reset
}
// Atualização de Cores dos Pneus baseados em Slip Angle
function setTyreVisual(element, slipAngle) {
    const absSlip = Math.abs(slipAngle);
    element.className = "tyre-indicator";
    if (absSlip > SLIP_ANGLE_PEAK * 1.4) {
        element.classList.add("tyre-slip-high");
    }
    else if (absSlip > SLIP_ANGLE_PEAK * 0.9) {
        element.classList.add("tyre-slip-mid");
    }
    else if (absSlip > 1.5) {
        element.classList.add("tyre-slip-low");
    }
}
// Envia feedback de áudio via Text-To-Speech (SpeechSynthesis)
function speakFeedback(message, type) {
    const now = Date.now();
    if (now - lastFeedbackTime < FEEDBACK_COOLDOWN)
        return;
    // Define as classes visuais do painel do coach
    coachPanel.className = "";
    if (type === "warning")
        coachPanel.classList.add("coach-warning");
    else if (type === "danger")
        coachPanel.classList.add("coach-danger");
    else if (type === "success")
        coachPanel.classList.add("coach-success");
    else
        coachPanel.classList.add("coach-neutral");
    coachMessage.innerText = message;
    // Utiliza a Web Speech API para dar voz ao Engenheiro de Corrida
    if ('speechSynthesis' in window) {
        window.speechSynthesis.cancel(); // Cancela áudios pendentes
        const utterance = new SpeechSynthesisUtterance(message);
        utterance.lang = "pt-BR";
        utterance.rate = 1.0;
        utterance.pitch = 0.9;
        window.speechSynthesis.speak(utterance);
    }
    lastFeedbackTime = now;
}
// Motor de Análise Física (Heurísticas)
function analyzePhysics(data) {
    const speed = data.speedMs;
    const steer = data.steer; // -1 a 1
    const yawRate = data.yawRate; // rad/s
    const brake = data.brake;
    const throttle = data.throttle;
    // Ângulo de esterço nas rodas em radianos
    const steerRad = steer * MAX_STEER_RAD;
    // Slip angles dos pneus em graus
    const slipFL = data.tyres[0].slipAngle;
    const slipFR = data.tyres[1].slipAngle;
    const slipRL = data.tyres[2].slipAngle;
    const slipRR = data.tyres[3].slipAngle;
    const avgFrontSlip = (Math.abs(slipFL) + Math.abs(slipFR)) / 2;
    const avgRearSlip = (Math.abs(slipRL) + Math.abs(slipRR)) / 2;
    // 1. Heurística de Entrada Excessiva (Velocidade)
    if (speed > 15 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.3 && brake > 0.1) {
        speakFeedback("Entrada rápida demais! Alivie a pressão no freio para recuperar aderência.", "danger");
        return;
    }
    // 2. Heurística de Understeer (Subesterço)
    if (speed > 8 && Math.abs(steer) > 0.15) {
        // Calculo do Yaw Esperado (Ackermann)
        const expectedYaw = (speed * steerRad) / WHEELBASE;
        const yawDelta = Math.abs(expectedYaw) - Math.abs(yawRate);
        // Se o carro vira menos do que deveria e os pneus dianteiros estão deslizando
        if (yawDelta > 0.12 && avgFrontSlip > SLIP_ANGLE_PEAK) {
            speakFeedback("Subesterço! Reduza o ângulo de esterço das rodas.", "warning");
            return;
        }
    }
    // 3. Heurística de Oversteer (Sobresterço / Traseira Escorregando)
    if (Math.abs(yawRate) > 0.15 && speed > 10) {
        // Contra-esterço: esterçando no sentido contrário da guinada
        const counterSteer = Math.sign(steer) !== Math.sign(yawRate);
        if (counterSteer && avgRearSlip > SLIP_ANGLE_PEAK) {
            speakFeedback("Sobresterço! Mantenha o contra-esterço controlado.", "danger");
            return;
        }
    }
    // 4. Heurística de Trail Braking
    if (brake > 0.05 && Math.abs(steer) > 0.2) {
        if (brake > 0.6) {
            speakFeedback("Sobrecarga de frenagem! Alivie o freio na entrada da curva.", "warning");
            return;
        }
        else if (brake < 0.2 && brake > 0.05) {
            speakFeedback("Belo Trail Braking. Segure o nariz do carro até o ápice.", "success");
            return;
        }
    }
    // 5. Heurística de Aceleração Precoce
    if (throttle > 0.5 && Math.abs(steer) > 0.3 && speed < 30) {
        if (avgRearSlip > SLIP_ANGLE_PEAK * 0.8) {
            speakFeedback("Patinando na tração! Suavize a aplicação de aceleração.", "warning");
            return;
        }
    }
    // Feedback padrão
    if (speed > 5) {
        coachMessage.innerText = "Pilotagem limpa. Mantenha os olhos nos pontos de frenagem.";
        coachPanel.className = "coach-neutral";
    }
}
// Ponto de Entrada da Telemetria (Chamado a partir do CSP Lua)
window.onTelemetryUpdate = function (data) {
    if (!data)
        return;
    // Atualizar Velocidade e Marcha
    speedIndicator.innerText = Math.round(data.speedKmh).toString();
    const gear = data.gear;
    if (gear === 0)
        gearIndicator.innerText = "R";
    else if (gear === 1)
        gearIndicator.innerText = "N";
    else
        gearIndicator.innerText = (gear - 1).toString();
    // Acelerador e Freio
    throttleBar.style.width = `${Math.min(data.throttle * 100, 100)}%`;
    brakeBar.style.width = `${Math.min(data.brake * 100, 100)}%`;
    // Barra de RPM
    const rpmPercent = (data.engineRPM / 8500) * 100;
    rpmBar.style.width = `${Math.min(rpmPercent, 100)}%`;
    // Visual do Pneus (FL: 0, FR: 1, RL: 2, RR: 3)
    setTyreVisual(tyreFL, data.tyres[0].slipAngle);
    setTyreVisual(tyreFR, data.tyres[1].slipAngle);
    setTyreVisual(tyreRL, data.tyres[2].slipAngle);
    setTyreVisual(tyreRR, data.tyres[3].slipAngle);
    // G-G Diagram
    updateGGDiagram(data.accG.x, data.accG.z);
    // Executar análises e feedback
    analyzePhysics(data);
};
// Inicialização
initGGCanvas();
