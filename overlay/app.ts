// Lógica de Modos de Exibição (Janelas Separadas)
const mode = window.location.hash ? window.location.hash.substring(1) : "full";
document.body.className = `mode-${mode}`;
console.log(`[Overlay] Initialized in mode: ${mode}`);

// Configurações e Variáveis do Veículo (GT3 padrão)
const WHEELBASE = 2.65; // metros (entre-eixos aproximado)
const MAX_STEER_RAD = 0.45; // ~26 graus de esterço máximo da roda dianteira
const SLIP_ANGLE_PEAK = 7.0; // graus (pico de aderência dos pneus)
const G_SCALE = 35; // Pixels por G no canvas

interface GGPoint {
  x: number;
  y: number;
}

// Histórico para o Diagrama G-G
const ggHistory: GGPoint[] = [];
const MAX_GG_HISTORY = 40;

// Estado de Coaching e Debounce de Voz
let lastFeedbackTime = 0;
const FEEDBACK_COOLDOWN = 8000; // 8 segundos entre mensagens faladas para reduzir o ruído
const AUDIO_ENABLED = false; // Desabilitar som / fala por enquanto conforme solicitado pelo usuário

// Elementos DOM
const speedIndicator = document.getElementById("speed-indicator") as HTMLElement;
const gearIndicator = document.getElementById("gear-indicator") as HTMLElement;
const rpmBar = document.getElementById("rpm-bar") as HTMLElement;
const throttleBar = document.getElementById("throttle-bar") as HTMLElement;
const brakeBar = document.getElementById("brake-bar") as HTMLElement;
const coachMessage = document.getElementById("coach-message") as HTMLElement;
const coachPanel = document.getElementById("coach-panel") as HTMLElement;
const nextTurnDisplay = document.getElementById("next-turn-display") as HTMLElement;
const nextTurnArrow = document.getElementById("next-turn-arrow") as HTMLElement;
const nextTurnDistance = document.getElementById("next-turn-distance") as HTMLElement;
const nextTurnTargetSpeed = document.getElementById("next-turn-target-speed") as HTMLElement;
const nextTurnAction = document.getElementById("next-turn-action") as HTMLElement;
const nextTurnStatusIndicator = document.getElementById("next-turn-status-indicator") as HTMLElement;

// Estado de rastreamento de curva
let hasAnnouncedCurrentTurn = false;
let hasAnnouncedBrakingPoint = false;
let lastNextTurnDist = -1;
let lastNextTurnAngle = 0;
let maxObservedLatG = 1.4; // Capacidade G lateral máxima padrão (se auto-calibra com a telemetria)

const tyreFL = document.getElementById("tyre-fl") as HTMLElement;
const tyreFR = document.getElementById("tyre-fr") as HTMLElement;
const tyreRL = document.getElementById("tyre-rl") as HTMLElement;
const tyreRR = document.getElementById("tyre-rr") as HTMLElement;

// Setup Canvas G-G
const canvas = document.getElementById("gg-canvas") as HTMLCanvasElement;
const ctx = canvas.getContext("2d") as CanvasRenderingContext2D;

function initGGCanvas(): void {
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
  ctx.moveTo(0, cy); ctx.lineTo(canvas.width, cy);
  ctx.moveTo(cx, 0); ctx.lineTo(cx, canvas.height);
  ctx.stroke();
}

function updateGGDiagram(accX: number, accZ: number): void {
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
function setTyreVisual(element: HTMLElement, slipAngle: number): void {
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

// Envia feedback de áudio via Text-To-Speech (SpeechSynthesis) com opção de silenciamento de fala
function speakFeedback(message: string, type: "neutral" | "warning" | "danger" | "success", speak: boolean = true): boolean {
  const now = Date.now();
  if (speak && AUDIO_ENABLED && (now - lastFeedbackTime < FEEDBACK_COOLDOWN)) return false;

  // Define as classes visuais do painel do coach
  coachPanel.className = "";
  if (type === "warning") coachPanel.classList.add("coach-warning");
  else if (type === "danger") coachPanel.classList.add("coach-danger");
  else if (type === "success") coachPanel.classList.add("coach-success");
  else coachPanel.className = "coach-neutral";

  coachMessage.innerText = message;
  
  // Utiliza a Web Speech API para dar voz ao Engenheiro de Corrida apenas se solicitado e áudio habilitado
  if (speak && AUDIO_ENABLED && 'speechSynthesis' in window) {
    window.speechSynthesis.cancel(); // Cancela áudios pendentes
    const utterance = new SpeechSynthesisUtterance(message);
    utterance.lang = "pt-BR";
    utterance.rate = 1.0;
    utterance.pitch = 0.9;
    window.speechSynthesis.speak(utterance);
    lastFeedbackTime = now;
  }

  return true;
}

// Motor de Análise Física (Heurísticas)
function analyzePhysics(data: TelemetryData): void {
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
    // Cálculo do Yaw Esperado (Ackermann)
    const expectedYawRaw = (speed * steerRad) / WHEELBASE;
    // Cap físico do Yaw rate dinâmico baseado na aceleração lateral máxima aproximada (~1.35G)
    const maxPhysicalYaw = (1.35 * 9.81 * Math.max(0.1, data.roadGrip)) / Math.max(speed, 1.0);
    const expectedYaw = Math.min(Math.abs(expectedYawRaw), maxPhysicalYaw) * Math.sign(steerRad);

    const yawDelta = Math.abs(expectedYaw) - Math.abs(yawRate);

    // Se o carro vira menos do que deveria, os pneus dianteiros estão deslizando além do pico,
    // e o escorregamento dianteiro é superior ao traseiro (para evitar falsos positivos de sobresterço/tração)
    if (yawDelta > 0.15 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.2 && avgFrontSlip > avgRearSlip) {
      speakFeedback("Subesterço! Reduza o ângulo de esterço.", "warning");
      return;
    }
  }

  // 3. Heurística de Oversteer (Sobresterço / Traseira Escorregando)
  if (Math.abs(yawRate) > 0.15 && speed > 10) {
    // Contra-esterço: esterçando no sentido contrário da guinada
    const counterSteer = Math.sign(steer) !== Math.sign(yawRate);
    if (counterSteer && avgRearSlip > SLIP_ANGLE_PEAK * 1.2) {
      speakFeedback("Sobresterço! Mantenha o contra-esterço controlado.", "danger");
      return;
    }
  }

  // 4. Heurística de Trail Braking
  if (brake > 0.05 && Math.abs(steer) > 0.2) {
    if (brake > 0.6) {
      speakFeedback("Sobrecarga de frenagem! Alivie o freio na entrada da curva.", "warning", false); // Apenas visual
      return;
    } else if (brake < 0.2 && brake > 0.05) {
      speakFeedback("Belo Trail Braking. Segure o nariz do carro até o ápice.", "success", false); // Apenas visual
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

// Declaração do escopo global para o compilador TS
interface Window {
  onTelemetryUpdate: (data: TelemetryData) => void;
}

console.log("[Overlay] app.js loaded successfully!");

// Lógica de Atualização Visual e por Voz da Próxima Curva
function updateUpcomingTurn(data: TelemetryData): void {
  const dist = data.nextTurnDist;
  const angle = data.nextTurnAngle;

  // Se a distância for inválida ou menor/igual a zero, mostra valores neutros (sem ocultar o widget)
  if (dist <= 0) {
    nextTurnDistance.innerText = "--m";
    nextTurnArrow.innerText = "↩️";
    nextTurnDisplay.className = "panel-glass";
    nextTurnStatusIndicator.className = "status-neutral";
    nextTurnTargetSpeed.innerText = "Ideal: -- km/h";
    nextTurnAction.innerText = "MANTENHA VELOCIDADE";
    hasAnnouncedCurrentTurn = false;
    hasAnnouncedBrakingPoint = false;
    lastNextTurnDist = dist;
    lastNextTurnAngle = angle;
    return;
  }

  // Detecta transição para uma nova curva
  const distIncreased = dist > lastNextTurnDist + 50;
  const angleChanged = Math.abs(angle - lastNextTurnAngle) > 20;

  if (distIncreased || angleChanged) {
    hasAnnouncedCurrentTurn = false;
    hasAnnouncedBrakingPoint = false;
  }

  lastNextTurnDist = dist;
  lastNextTurnAngle = angle;

  // Atualiza o widget visual com a distância
  nextTurnDistance.innerText = `${Math.round(dist)}m`;
  
  // Direção da curva (corrigido: positivo = direita, negativo = esquerda)
  const isRight = angle > 0;
  if (isRight) {
    nextTurnArrow.innerText = "➡️";
  } else {
    nextTurnArrow.innerText = "⬅️";
  }

  // --- LÓGICA DE VELOCIDADE DE ENTRADA (Cálculo Físico-Dinâmico) ---
  const speed = data.speedMs; // velocidade atual em m/s
  const absAngle = Math.abs(angle);

  // Estimativa contínua e realista da velocidade ideal (km/h) baseada na angulação da curva
  // Usamos a fórmula baseada no limite físico de contorno de curva
  let baseTargetKmh = 800 / Math.sqrt(Math.max(1.0, absAngle));
  // Limita os extremos de velocidade alvo para curvas muito abertas ou fechadas
  baseTargetKmh = Math.max(50, Math.min(290, baseTargetKmh));

  // Multiplicadores físicos:
  // 1. Grip da pista (velocidade proporcional à raiz do grip)
  const gripFactor = Math.sqrt(Math.max(0.1, data.roadGrip));
  
  // 2. Capacidade dinâmica do veículo (calculada com base no G lateral máximo observado)
  const carPerformanceFactor = Math.sqrt(maxObservedLatG / 1.4);

  let vTargetKmh = baseTargetKmh * gripFactor * carPerformanceFactor;

  // 3. Penalidade por posicionamento incorreto de entrada na curva (aplica-se apenas perto da curva < 60m)
  const pLat = data.trackPosLat; // -1.0 = esquerda, 1.0 = direita
  const wrongSideFactor = isRight ? pLat : -pLat;
  if (dist < 60 && wrongSideFactor > 0) {
    const proximityScale = (60 - dist) / 60;
    vTargetKmh = vTargetKmh * (1.0 - 0.2 * wrongSideFactor * proximityScale);
  }

  // Velocidade alvo convertida para m/s para os cálculos de física
  const vTarget = vTargetKmh / 3.6;

  // Atualiza a velocidade ideal na placa
  nextTurnTargetSpeed.innerText = `Ideal: ${Math.round(vTargetKmh)} km/h`;

  // Desaceleração necessária para chegar na velocidade alvo da curva (v^2 = u^2 + 2ad => a = (v^2 - u^2) / 2d)
  let aReq = 0;
  if (speed > vTarget) {
    aReq = (speed * speed - vTarget * vTarget) / (2 * Math.max(1.0, dist));
  }

  // Deceleração real do veículo estimada (accG.z negativo é desaceleração física)
  const aActual = Math.max(0, -data.accG.z * 9.81);
  const isBraking = data.brake > 0.15;
  const isBrakingSufficiently = isBraking && (data.brake > 0.4 || aActual >= aReq - 1.5);

  // Define os estilos visuais de acordo com o status
  if (aReq <= 3.5) {
    // Velocidade segura
    nextTurnDisplay.className = "panel-glass next-turn-safe";
    nextTurnStatusIndicator.className = "status-safe";
    nextTurnAction.innerText = "VELOCIDADE OK";
  } else if (aReq <= 7.5) {
    // Velocidade limítrofe (atenção, zona de aproximação)
    nextTurnDisplay.className = "panel-glass next-turn-warning";
    nextTurnStatusIndicator.className = "status-warning";
    nextTurnAction.innerText = "PREPARE-SE";
  } else {
    // Zona de frenagem necessária (aReq > 7.5)
    if (isBrakingSufficiently) {
      // Piloto já está freando o suficiente
      nextTurnDisplay.className = "panel-glass next-turn-braking";
      nextTurnStatusIndicator.className = "status-braking";
      nextTurnAction.innerText = "FRENAGEM OK";
    } else {
      // Rápido demais, precisa começar a frear
      nextTurnDisplay.className = "panel-glass next-turn-danger";
      nextTurnStatusIndicator.className = "status-danger";
      nextTurnAction.innerText = "FREIE AGORA!";
      
      // Alerta sonoro apenas no momento de entrar na zona de perigo de frenagem (1x por curva)
      if (!hasAnnouncedBrakingPoint) {
        if (speakFeedback("Freie!", "danger")) {
          hasAnnouncedBrakingPoint = true;
        }
      }
    }
  }
}

let updateCount = 0;

// Ponto de Entrada da Telemetria (Chamado a partir do CSP Lua)
window.onTelemetryUpdate = function(data: TelemetryData): void {
  if (!data) {
    console.warn("[Overlay] Received empty telemetry data");
    return;
  }

  updateCount++;
  
  // Atualiza a capacidade lateral G máxima observada do veículo (com limite de segurança de 6G para colisões)
  const currentLatG = Math.abs(data.accG.x);
  if (currentLatG > maxObservedLatG && currentLatG < 6.0) {
    maxObservedLatG = currentLatG;
  }

  if (updateCount % 60 === 1) {
    console.log(`[Overlay] Telemetry update #${updateCount} received. Speed: ${data.speedKmh.toFixed(1)} km/h, Gear: ${data.gear}, RPM: ${Math.round(data.engineRPM)}`);
  }

  // Atualizar Velocidade e Marcha
  speedIndicator.innerText = Math.round(data.speedKmh).toString();
  
  const gear = data.gear;
  if (gear === -1) gearIndicator.innerText = "R";
  else if (gear === 0) gearIndicator.innerText = "N";
  else gearIndicator.innerText = gear.toString();

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

  // Atualizar widget e coaching da próxima curva
  updateUpcomingTurn(data);

  // Executar análises e feedback
  analyzePhysics(data);
};

// Inicialização
initGGCanvas();
