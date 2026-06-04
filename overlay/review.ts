// Lógica do Dashboard de Review de Telemetria

interface TelemetrySample {
  t: number;      // lapTimeMs
  x: number;      // world x
  z: number;      // world z
  speed: number;  // speedKmh
  gear: number;
  rpm: number;
  steer: number;  // normalized steering (-1.0 a 1.0)
  thr: number;    // throttle (0.0 a 1.0)
  brk: number;    // brake (0.0 a 1.0)
  clt: number;    // clutch (0.0 a 1.0)
  slpA: number[]; // slip angles [FL, FR, RL, RR]
  slpR: number[]; // slip ratios [FL, FR, RL, RR]
  gLat: number;   // lateral G
  gLong: number;  // longitudinal G
  posLat: number; // trackPosLat
  und?: number;   // understeer intensity
  ove?: number;   // oversteer intensity
  spin?: number;  // wheelspin intensity
  lock?: number;  // lockup intensity
}

interface CornerRating {
  grade: string;
  score: number;
  minSpeedKmh: number;
  targetSpeedKmh: number;
  trailScore: number;
  apexTiming: string;
  gripUtilization: number;
  startIndex?: number;
  endIndex?: number;
}

interface TelemetrySession {
  metadata: {
    trackId: string;
    trackName: string;
    trackLayout: string;
    carId: string;
    carName: string;
    lapNumber: number;
    lapTimeMs: number;
    sectorTimes: number[];
    timestamp: string;
    bestLatG: number;
    bestDecelG: number;
  };
  trackMap: {
    center: number[][]; // [x, z][]
    left: number[][];   // [x, z][]
    right: number[][];  // [x, z][]
  };
  corners: CornerRating[];
  samples: TelemetrySample[];
}

let sessionData: TelemetrySession | null = null;
let currentSampleIndex = 0;
let trackMapColorMode: "THR" | "SPD" = "THR"; // "THR" = Throttle/Brake, "SPD" = Speed

// Canvas drawing state
let mapZoom = 1.0;
let mapOffsetX = 0;
let mapOffsetY = 0;
let isPanning = false;
let startPanX = 0;
let startPanY = 0;

// DOM Elements
const fileLoader = document.getElementById("file-loader") as HTMLInputElement;
const dropZone = document.getElementById("drop-zone");
const emptyState = document.getElementById("dashboard-empty");
const mainDashboard = document.getElementById("dashboard-main");

// Resumo elements
const sumTrack = document.getElementById("sum-track");
const sumCar = document.getElementById("sum-car");
const sumLapTime = document.getElementById("sum-laptime");
const sumDate = document.getElementById("sum-date");
const sumS1 = document.getElementById("sum-s1");
const sumS2 = document.getElementById("sum-s2");
const sumS3 = document.getElementById("sum-s3");

// HUD elements
const svgSteering = document.getElementById("svg-steering") as unknown as SVGSVGElement | null;
const hudSteer = document.getElementById("hud-steer");
const hudThr = document.getElementById("hud-thr");
const hudBrk = document.getElementById("hud-brk");
const hudClt = document.getElementById("hud-clt");
const lblThr = document.getElementById("lbl-thr");
const lblBrk = document.getElementById("lbl-brk");
const lblClt = document.getElementById("lbl-clt");
const hudSpeed = document.getElementById("hud-speed");
const hudGear = document.getElementById("hud-gear");
const hudRpm = document.getElementById("hud-rpm");
const tFL = document.getElementById("t-fl");
const tFR = document.getElementById("t-fr");
const tRL = document.getElementById("t-rl");
const tRR = document.getElementById("t-rr");

// Prompter elements
const aiPromptBox = document.getElementById("ai-prompt-box") as HTMLTextAreaElement;
const btnCopyPrompt = document.getElementById("btn-copy-prompt");

// Timeline elements
const scrubber = document.getElementById("telemetry-scrubber") as HTMLInputElement;
const scrubberTime = document.getElementById("scrubber-time");

// Canvas elements
const trackCanvas = document.getElementById("track-canvas") as HTMLCanvasElement;
const telemetryCanvas = document.getElementById("telemetry-canvas") as HTMLCanvasElement;

// Zoom buttons
const btnZoomIn = document.getElementById("btn-zoom-in");
const btnZoomOut = document.getElementById("btn-zoom-out");
const btnZoomFit = document.getElementById("btn-zoom-fit");
const btnToggleColor = document.getElementById("btn-toggle-color");

// Corner scorecard
const cornerRowsAnchor = document.getElementById("corner-rows-anchor");

// Helper function to format time (ms) to mm:ss.fff
function formatTime(ms: number): string {
  if (isNaN(ms) || ms <= 0) return "--:--.---";
  const minutes = Math.floor(ms / 60000);
  const seconds = Math.floor((ms % 60000) / 1000);
  const milliseconds = Math.floor(ms % 1000);
  return `${minutes}:${seconds.toString().padStart(2, "0")}.${milliseconds.toString().padStart(3, "0")}`;
}

// Initializing the loaders
if (fileLoader) {
  fileLoader.addEventListener("change", (e) => {
    const file = (e.target as HTMLInputElement).files?.[0];
    if (file) handleFile(file);
  });
}

if (dropZone) {
  dropZone.addEventListener("dragover", (e) => {
    e.preventDefault();
    dropZone.classList.add("dragover");
  });

  dropZone.addEventListener("dragleave", () => {
    dropZone.classList.remove("dragover");
  });

  dropZone.addEventListener("drop", (e) => {
    e.preventDefault();
    dropZone.classList.remove("dragover");
    const file = e.dataTransfer?.files[0];
    if (file) handleFile(file);
  });

  dropZone.addEventListener("click", () => {
    fileLoader?.click();
  });
}

function handleFile(file: File): void {
  const reader = new FileReader();
  reader.onload = (e) => {
    try {
      const json = JSON.parse(e.target?.result as string);
      if (json && json.metadata && json.samples && json.samples.length > 0) {
        sessionData = json as TelemetrySession;
        loadDashboard();
      } else {
        alert("O arquivo selecionado não parece ser um arquivo de telemetria válido.");
      }
    } catch (err) {
      console.error(err);
      alert("Erro ao ler o arquivo JSON de telemetria.");
    }
  };
  reader.readAsText(file);
}

function loadDashboard(): void {
  if (!sessionData) return;

  // Toggle visible sections
  emptyState?.classList.add("hidden");
  mainDashboard?.classList.remove("hidden");

  // Load summary info
  if (sumTrack) sumTrack.innerText = sessionData.metadata.trackName + (sessionData.metadata.trackLayout ? ` (${sessionData.metadata.trackLayout})` : "");
  if (sumCar) sumCar.innerText = sessionData.metadata.carName;
  if (sumLapTime) sumLapTime.innerText = formatTime(sessionData.metadata.lapTimeMs);
  if (sumDate) sumDate.innerText = sessionData.metadata.timestamp;

  // Sector times
  const sectors = sessionData.metadata.sectorTimes || [];
  if (sumS1) sumS1.innerText = sectors[0] ? formatTime(sectors[0]) : "--:--.---";
  if (sumS2) sumS2.innerText = sectors[1] ? formatTime(sectors[1]) : "--:--.---";
  if (sumS3) sumS3.innerText = sectors[2] ? formatTime(sectors[2]) : "--:--.---";

  // Timeline setup
  if (scrubber) {
    scrubber.max = (sessionData.samples.length - 1).toString();
    scrubber.value = "0";
  }
  currentSampleIndex = 0;
  updateSelectedPoint();

  // Load corner table list
  renderCornerTable();

  // Generate prompt
  generateAIPrompt();

  // Set fit zoom
  resetZoomFit();

  // Handle Resize for Canvases
  resizeCanvases();

  // Draw
  drawTrackMap();
  drawCharts();
}

function renderCornerTable(): void {
  if (!sessionData || !cornerRowsAnchor) return;
  cornerRowsAnchor.innerHTML = "";

  sessionData.corners.forEach((c, idx) => {
    const row = document.createElement("div");
    row.className = "corner-row";
    row.dataset.index = idx.toString();
    
    let gradeClass = "grade-blue";
    if (c.grade === "S") gradeClass = "grade-gold";
    else if (c.grade.startsWith("A")) gradeClass = "grade-green";
    else if (c.grade.startsWith("B")) gradeClass = "grade-blue";
    else if (c.grade.startsWith("D")) gradeClass = "grade-red";

    row.innerHTML = `
      <span style="font-weight: 600;">C${idx + 1}</span>
      <span style="text-align: center;"><span class="grade-badge ${gradeClass}">${c.grade}</span></span>
      <span style="text-align: right; font-family: monospace;">${Math.round(c.minSpeedKmh)}/${Math.round(c.targetSpeedKmh)}</span>
      <span style="text-align: right; font-family: monospace;">${c.trailScore}%</span>
      <span style="text-align: right; font-family: monospace;">${c.gripUtilization}%</span>
    `;

    row.addEventListener("click", () => {
      // Highlight row
      document.querySelectorAll(".corner-row").forEach(r => r.classList.remove("selected"));
      row.classList.add("selected");
      
      // Zoom into corner
      if (c.startIndex !== undefined && c.endIndex !== undefined) {
        focusMapOnSamples(c.startIndex, c.endIndex);
        
        // Scrub timeline to start of corner
        if (scrubber) {
          scrubber.value = c.startIndex.toString();
          currentSampleIndex = c.startIndex;
          updateSelectedPoint();
        }
      }
    });

    cornerRowsAnchor.appendChild(row);
  });
}

function generateAIPrompt(): void {
  if (!sessionData || !aiPromptBox) return;

  // Counting events
  let underCount = 0;
  let overCount = 0;
  let spinCount = 0;
  let lockCount = 0;

  sessionData.samples.forEach(s => {
    if (s.und && s.und > 0) underCount++;
    if (s.ove && s.ove > 0) overCount++;
    if (s.spin && s.spin > 0) spinCount++;
    if (s.lock && s.lock > 0) lockCount++;
  });

  // Calculate sector durations
  const sectors = sessionData.metadata.sectorTimes || [];
  const s1Str = sectors[0] ? formatTime(sectors[0]) : "N/D";
  const s2Str = sectors[1] ? formatTime(sectors[1]) : "N/D";
  const s3Str = sectors[2] ? formatTime(sectors[2]) : "N/D";

  let cornerDetails = "";
  sessionData.corners.forEach((c, idx) => {
    cornerDetails += `- Curva ${idx + 1}: Nota ${c.grade} (V. Mínima: ${Math.round(c.minSpeedKmh)} km/h | Ideal: ${Math.round(c.targetSpeedKmh)} km/h). Trail braking: ${c.trailScore}%. Uso do Grip: ${c.gripUtilization}%. Timing do Ápice: ${c.apexTiming}.\n`;
  });

  const prompt = `Você é um engenheiro de pista e coach de pilotagem profissional de automobilismo.
Analise a telemetria desta volta no simulador Assetto Corsa para me ajudar a melhorar meu tempo de volta.

=== Informações Gerais ===
- Carro: ${sessionData.metadata.carName} (${sessionData.metadata.carId})
- Pista: ${sessionData.metadata.trackName} (${sessionData.metadata.trackId} - ${sessionData.metadata.trackLayout})
- Tempo da Volta: ${formatTime(sessionData.metadata.lapTimeMs)}
- Tempos de Setor: Setor 1: ${s1Str} | Setor 2: ${s2Str} | Setor 3: ${s3Str}
- Aceleração Lateral Máxima: ${sessionData.metadata.bestLatG} G
- Desaceleração Máxima: ${sessionData.metadata.bestDecelG} G

=== Instantes de Perda de Aderência (Frequência a 10Hz) ===
- Subesterço (Understeer): ${underCount} instantes amostrados (dianteira escorregando por entrar rápido demais ou esterçar em excesso)
- Sobresterço (Oversteer): ${overCount} instantes amostrados (traseira deslizando/contra-esterço)
- Patinamento (Wheelspin): ${spinCount} instantes amostrados (aceleração agressiva na saída de curva)
- Travamento de Rodas (Lockup): ${lockCount} instantes amostrados (excesso de pressão de freio na entrada)

=== Desempenho Curva por Curva ===
${cornerDetails}

Por favor, faça um review detalhado sobre o meu estilo de pilotagem. Destaque quais curvas ou setores me custaram mais tempo, analise o meu trail braking e uso de grip nas curvas com notas mais baixas, e me dê dicas acionáveis de pilotagem para que eu consiga abaixar meu tempo de volta nesta pista.`;

  aiPromptBox.value = prompt;
}

if (btnCopyPrompt) {
  btnCopyPrompt.addEventListener("click", () => {
    if (aiPromptBox) {
      aiPromptBox.select();
      document.execCommand("copy");
      
      const originalText = btnCopyPrompt.innerHTML;
      btnCopyPrompt.innerHTML = "<span>✅</span> Prompt Copiado!";
      setTimeout(() => {
        btnCopyPrompt.innerHTML = originalText;
      }, 2000);
    }
  });
}

// Scrubber change
if (scrubber) {
  scrubber.addEventListener("input", (e) => {
    currentSampleIndex = parseInt((e.target as HTMLInputElement).value);
    updateSelectedPoint();
    drawTrackMap();
    drawCharts();
  });
}

function updateSelectedPoint(): void {
  if (!sessionData) return;
  const sample = sessionData.samples[currentSampleIndex];
  if (!sample) return;

  if (scrubberTime) scrubberTime.innerText = formatTime(sample.t);

  // Speed, Gear, RPM
  if (hudSpeed) hudSpeed.innerHTML = `${Math.round(sample.speed)} <span style="font-size: 10px; color: var(--text-muted);">km/h</span>`;
  if (hudGear) {
    const g = sample.gear;
    if (g === -1) hudGear.innerText = "R";
    else if (g === 0) hudGear.innerText = "N";
    else hudGear.innerText = g.toString();
  }
  if (hudRpm) hudRpm.innerText = Math.round(sample.rpm).toString();

  // Pedals
  if (hudThr) hudThr.style.width = `${sample.thr * 100}%`;
  if (hudBrk) hudBrk.style.width = `${sample.brk * 100}%`;
  if (hudClt) hudClt.style.width = `${sample.clt * 100}%`;

  if (lblThr) lblThr.innerText = `${Math.round(sample.thr * 100)}%`;
  if (lblBrk) lblBrk.innerText = `${Math.round(sample.brk * 100)}%`;
  if (lblClt) lblClt.innerText = `${Math.round(sample.clt * 100)}%`;

  // Steering wheel rotation
  if (svgSteering) {
    // Steer input is -1.0 to 1.0. We rotate the steering wheel -360° to 360°
    const rotationAngle = sample.steer * 360;
    svgSteering.style.transform = `rotate(${rotationAngle}deg)`;
  }
  if (hudSteer) hudSteer.innerText = `${Math.round(sample.steer * 450)}°`; // Assume max 450 deg steer lock each side

  // Tyres slip angle
  const tyres = ["fl", "fr", "rl", "rr"];
  const elements = [tFL, tFR, tRL, tRR];
  elements.forEach((el, idx) => {
    if (!el) return;
    const slip = sample.slpA[idx];
    el.innerText = `${tyres[idx].toUpperCase()}: ${slip.toFixed(1)}°`;
    
    // Tyre styling based on slip angle (same as overlay)
    const absSlip = Math.abs(slip);
    el.className = "tyre-dot";
    if (absSlip > 7.0 * 1.4) {
      el.style.backgroundColor = "rgba(239, 68, 68, 0.25)";
      el.style.borderColor = "rgba(239, 68, 68, 0.6)";
      el.style.color = "#ef4444";
    } else if (absSlip > 7.0 * 0.9) {
      el.style.backgroundColor = "rgba(245, 158, 11, 0.2)";
      el.style.borderColor = "rgba(245, 158, 11, 0.5)";
      el.style.color = "#f59e0b";
    } else if (absSlip > 1.5) {
      el.style.backgroundColor = "rgba(16, 185, 129, 0.15)";
      el.style.borderColor = "rgba(16, 185, 129, 0.3)";
      el.style.color = "#10b981";
    } else {
      el.style.backgroundColor = "rgba(255, 255, 255, 0.04)";
      el.style.borderColor = "rgba(255, 255, 255, 0.05)";
      el.style.color = "var(--text-primary)";
    }
  });
}

// Track Map Canvas Zoom/Pan Logic
function resetZoomFit(): void {
  if (!sessionData || !trackCanvas) return;
  const samples = sessionData.samples;
  
  let minX = Infinity, maxX = -Infinity;
  let minZ = Infinity, maxZ = -Infinity;

  samples.forEach(s => {
    if (s.x < minX) minX = s.x;
    if (s.x > maxX) maxX = s.x;
    if (s.z < minZ) minZ = s.z;
    if (s.z > maxZ) maxZ = s.z;
  });

  const width = maxX - minX;
  const height = maxZ - minZ;

  mapZoom = Math.min((trackCanvas.width * 0.85) / width, (trackCanvas.height * 0.85) / height);
  mapOffsetX = trackCanvas.width / 2 - (minX + width / 2) * mapZoom;
  mapOffsetY = trackCanvas.height / 2 - (minZ + height / 2) * mapZoom;
}

function focusMapOnSamples(startIdx: number, endIdx: number): void {
  if (!sessionData || !trackCanvas) return;
  const samples = sessionData.samples.slice(startIdx, endIdx + 1);
  if (samples.length === 0) return;

  let minX = Infinity, maxX = -Infinity;
  let minZ = Infinity, maxZ = -Infinity;

  samples.forEach(s => {
    if (s.x < minX) minX = s.x;
    if (s.x > maxX) maxX = s.x;
    if (s.z < minZ) minZ = s.z;
    if (s.z > maxZ) maxZ = s.z;
  });

  const width = maxX - minX;
  const height = maxZ - minZ;
  
  // Set zoom higher for focus
  mapZoom = Math.min((trackCanvas.width * 0.6) / Math.max(10, width), (trackCanvas.height * 0.6) / Math.max(10, height));
  mapOffsetX = trackCanvas.width / 2 - (minX + width / 2) * mapZoom;
  mapOffsetY = trackCanvas.height / 2 - (minZ + height / 2) * mapZoom;
  
  drawTrackMap();
}

function resizeCanvases(): void {
  if (trackCanvas && trackCanvas.parentElement) {
    trackCanvas.width = trackCanvas.parentElement.clientWidth;
    trackCanvas.height = trackCanvas.parentElement.clientHeight;
  }
  if (telemetryCanvas && telemetryCanvas.parentElement) {
    telemetryCanvas.width = telemetryCanvas.parentElement.clientWidth;
    telemetryCanvas.height = telemetryCanvas.parentElement.clientHeight;
  }
}

window.addEventListener("resize", () => {
  resizeCanvases();
  resetZoomFit();
  drawTrackMap();
  drawCharts();
});

// Canvas Panning Handlers
if (trackCanvas) {
  trackCanvas.addEventListener("mousedown", (e) => {
    isPanning = true;
    startPanX = e.clientX - mapOffsetX;
    startPanY = e.clientY - mapOffsetY;
  });

  window.addEventListener("mousemove", (e) => {
    if (isPanning) {
      mapOffsetX = e.clientX - startPanX;
      mapOffsetY = e.clientY - startPanY;
      drawTrackMap();
    }
  });

  window.addEventListener("mouseup", () => {
    isPanning = false;
  });

  trackCanvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const zoomIntensity = 0.15;
    
    // Zoom centered on mouse position
    const mouseX = e.offsetX;
    const mouseY = e.offsetY;
    
    const wheel = e.deltaY < 0 ? 1 : -1;
    const zoomFactor = Math.exp(wheel * zoomIntensity);
    
    // Adjust offsets to keep mouse coordinate pinned
    const worldX = (mouseX - mapOffsetX) / mapZoom;
    const worldY = (mouseY - mapOffsetY) / mapZoom;
    
    mapZoom *= zoomFactor;
    mapZoom = Math.max(0.1, Math.min(100, mapZoom));
    
    mapOffsetX = mouseX - worldX * mapZoom;
    mapOffsetY = mouseY - worldY * mapZoom;
    
    drawTrackMap();
  });
}

// Controls buttons
btnZoomIn?.addEventListener("click", () => {
  mapZoom *= 1.25;
  drawTrackMap();
});

btnZoomOut?.addEventListener("click", () => {
  mapZoom /= 1.25;
  drawTrackMap();
});

btnZoomFit?.addEventListener("click", () => {
  resetZoomFit();
  drawTrackMap();
});

btnToggleColor?.addEventListener("click", () => {
  if (trackMapColorMode === "THR") {
    trackMapColorMode = "SPD";
    btnToggleColor.innerText = "SPD";
  } else {
    trackMapColorMode = "THR";
    btnToggleColor.innerText = "THR";
  }
  drawTrackMap();
});

// Draw track layout on HTML5 Canvas
function drawTrackMap(): void {
  if (!sessionData || !trackCanvas) return;
  const ctx = trackCanvas.getContext("2d");
  if (!ctx) return;

  // Clear
  ctx.clearRect(0, 0, trackCanvas.width, trackCanvas.height);

  const samples = sessionData.samples;
  const trackMap = sessionData.trackMap;

  // 1. Draw track boundaries (road shape)
  if (trackMap && trackMap.left && trackMap.left.length > 0) {
    ctx.lineWidth = 1;
    ctx.strokeStyle = "rgba(255, 255, 255, 0.12)";
    
    // Left boundary
    ctx.beginPath();
    trackMap.left.forEach((pt, i) => {
      const screenX = pt[0] * mapZoom + mapOffsetX;
      const screenY = pt[1] * mapZoom + mapOffsetY;
      if (i === 0) ctx.moveTo(screenX, screenY);
      else ctx.lineTo(screenX, screenY);
    });
    ctx.closePath();
    ctx.stroke();

    // Right boundary
    ctx.beginPath();
    trackMap.right.forEach((pt, i) => {
      const screenX = pt[0] * mapZoom + mapOffsetX;
      const screenY = pt[1] * mapZoom + mapOffsetY;
      if (i === 0) ctx.moveTo(screenX, screenY);
      else ctx.lineTo(screenX, screenY);
    });
    ctx.closePath();
    ctx.stroke();

    // Dotted track center spline (Desired line)
    ctx.strokeStyle = "rgba(255, 255, 255, 0.25)";
    ctx.setLineDash([4, 6]);
    ctx.beginPath();
    trackMap.center.forEach((pt, i) => {
      const screenX = pt[0] * mapZoom + mapOffsetX;
      const screenY = pt[1] * mapZoom + mapOffsetY;
      if (i === 0) ctx.moveTo(screenX, screenY);
      else ctx.lineTo(screenX, screenY);
    });
    ctx.closePath();
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // 2. Draw actual driven trajectory line colored by Throttle/Brake or Speed
  ctx.lineWidth = 3.5;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  let maxSpeed = 1;
  let minSpeed = Infinity;
  if (trackMapColorMode === "SPD") {
    samples.forEach(s => {
      if (s.speed > maxSpeed) maxSpeed = s.speed;
      if (s.speed < minSpeed) minSpeed = s.speed;
    });
  }

  for (let i = 0; i < samples.length - 1; i++) {
    const s1 = samples[i];
    const s2 = samples[i + 1];

    const x1 = s1.x * mapZoom + mapOffsetX;
    const y1 = s1.z * mapZoom + mapOffsetY;
    const x2 = s2.x * mapZoom + mapOffsetX;
    const y2 = s2.z * mapZoom + mapOffsetY;

    ctx.beginPath();
    ctx.moveTo(x1, y1);
    ctx.lineTo(x2, y2);

    if (trackMapColorMode === "THR") {
      // Color based on inputs: Green = Throttle, Red = Brake, Gray = Coasting
      if (s1.brk > 0.1) {
        ctx.strokeStyle = `rgba(239, 68, 68, ${0.4 + s1.brk * 0.6})`; // Red
      } else if (s1.thr > 0.15) {
        ctx.strokeStyle = `rgba(16, 185, 129, ${0.4 + s1.thr * 0.6})`; // Green
      } else {
        ctx.strokeStyle = "rgba(156, 163, 175, 0.4)"; // Gray
      }
    } else {
      // Speed Gradient (Red = Slow, Green = Fast)
      const ratio = (s1.speed - minSpeed) / (maxSpeed - minSpeed || 1);
      const r = Math.round(239 - ratio * (239 - 16));
      const g = Math.round(68 + ratio * (185 - 68));
      const b = Math.round(68 + ratio * (129 - 68));
      ctx.strokeStyle = `rgb(${r}, ${g}, ${b})`;
    }
    ctx.stroke();
  }

  // 3. Draw Loss of Grip / Warnings Indicators (understeer, oversteer, spin, lock)
  samples.forEach((s, idx) => {
    if (idx % 2 !== 0) return; // Sample down indicators slightly to prevent overlap clutter

    const screenX = s.x * mapZoom + mapOffsetX;
    const screenY = s.z * mapZoom + mapOffsetY;

    if (s.lock && s.lock > 0) {
      ctx.fillStyle = "rgba(239, 68, 68, 0.55)";
      ctx.beginPath();
      ctx.arc(screenX, screenY, 4, 0, 2 * Math.PI);
      ctx.fill();
    } else if (s.spin && s.spin > 0) {
      ctx.fillStyle = "rgba(250, 204, 21, 0.6)";
      ctx.beginPath();
      ctx.arc(screenX, screenY, 4, 0, 2 * Math.PI);
      ctx.fill();
    } else if (s.und && s.und > 0) {
      ctx.fillStyle = "rgba(255, 123, 0, 0.7)";
      ctx.beginPath();
      ctx.arc(screenX, screenY, 4.5, 0, 2 * Math.PI);
      ctx.fill();
    } else if (s.ove && s.ove > 0) {
      ctx.fillStyle = "rgba(236, 72, 153, 0.7)";
      ctx.beginPath();
      ctx.arc(screenX, screenY, 4.5, 0, 2 * Math.PI);
      ctx.fill();
    }
  });

  // 4. Draw current car scrubber position marker (blue dot with outer white halo)
  const currentSample = samples[currentSampleIndex];
  if (currentSample) {
    const markerX = currentSample.x * mapZoom + mapOffsetX;
    const markerY = currentSample.z * mapZoom + mapOffsetY;

    // Draw outer halo
    ctx.fillStyle = "rgba(59, 130, 246, 0.35)";
    ctx.beginPath();
    ctx.arc(markerX, markerY, 12, 0, 2 * Math.PI);
    ctx.fill();

    // Draw solid center dot
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 2;
    ctx.fillStyle = "#3b82f6";
    ctx.beginPath();
    ctx.arc(markerX, markerY, 6, 0, 2 * Math.PI);
    ctx.fill();
    ctx.stroke();
  }
}

// Render the detailed multi-channel line charts on canvas
function drawCharts(): void {
  if (!sessionData || !telemetryCanvas) return;
  const ctx = telemetryCanvas.getContext("2d");
  if (!ctx) return;

  const w = telemetryCanvas.width;
  const h = telemetryCanvas.height;
  ctx.clearRect(0, 0, w, h);

  const samples = sessionData.samples;
  const totalSamples = samples.length;
  if (totalSamples === 0) return;

  // Find max speed
  let maxSpeed = 1;
  samples.forEach(s => {
    if (s.speed > maxSpeed) maxSpeed = s.speed;
  });

  // Drawing backgrounds & gridlines
  ctx.strokeStyle = "rgba(255, 255, 255, 0.05)";
  ctx.lineWidth = 1;
  const linesCount = 4;
  for (let i = 1; i < linesCount; i++) {
    const y = (h / linesCount) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }

  // Draw 1: Speed curve (cyan line)
  ctx.strokeStyle = "#06b6d4";
  ctx.lineWidth = 2.0;
  ctx.beginPath();
  for (let i = 0; i < totalSamples; i++) {
    const x = (i / totalSamples) * w;
    // Map speed to upper 75% of chart
    const y = h - (samples[i].speed / maxSpeed) * (h - 20) - 10;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();

  // Draw 2: Throttle curve (green line)
  ctx.strokeStyle = "rgba(16, 185, 129, 0.65)";
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  for (let i = 0; i < totalSamples; i++) {
    const x = (i / totalSamples) * w;
    const y = h - (samples[i].thr * (h / 3)) - 10;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();

  // Draw 3: Brake curve (red line)
  ctx.strokeStyle = "rgba(239, 68, 68, 0.7)";
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  for (let i = 0; i < totalSamples; i++) {
    const x = (i / totalSamples) * w;
    const y = h - (samples[i].brk * (h / 3)) - 10;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();

  // Draw 4: Steer curve (orange line, centered around mid)
  ctx.strokeStyle = "rgba(245, 158, 11, 0.4)";
  ctx.lineWidth = 1.2;
  ctx.beginPath();
  const centerY = h - (h / 6) - 10;
  for (let i = 0; i < totalSamples; i++) {
    const x = (i / totalSamples) * w;
    // steer is -1.0 to 1.0, map to bottom height region
    const y = centerY - (samples[i].steer * (h / 8));
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();

  // Draw vertical scrubber location cursor line
  const cursorX = (currentSampleIndex / totalSamples) * w;
  ctx.strokeStyle = "#ffffff";
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(cursorX, 0);
  ctx.lineTo(cursorX, h);
  ctx.stroke();

  // Text labels on charts
  ctx.fillStyle = "#9ca3af";
  ctx.font = "9px 'JetBrains Mono', monospace";
  ctx.fillText("Velocidade (km/h)", 10, 15);
  ctx.fillStyle = "rgba(16, 185, 129, 0.9)";
  ctx.fillText("Acel.", 10, 27);
  ctx.fillStyle = "rgba(239, 68, 68, 0.9)";
  ctx.fillText("Freio", 50, 27);
  ctx.fillStyle = "rgba(245, 158, 11, 0.8)";
  ctx.fillText("Esterço", 90, 27);
}
