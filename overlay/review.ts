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
  tCore?: number[]; // tyre core temperatures [FL, FR, RL, RR]
  tGrip?: number[]; // tyre surface grips [FL, FR, RL, RR]
  rTemp?: number;   // road temperature
  aTemp?: number;   // ambient temperature
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

interface TelemetryLap {
  lapNumber: number;
  lapTimeMs: number;
  sectorTimes: number[];
  timestamp: string;
  bestLatG: number;
  bestDecelG: number;
  corners: CornerRating[];
  samples: TelemetrySample[];
}

interface TelemetrySession {
  metadata: {
    trackId: string;
    trackName: string;
    trackLayout: string;
    carId: string;
    carName: string;
    timestamp: string;
    bestLatG: number;
    bestDecelG: number;
    totalLaps?: number;
  };
  trackMap: {
    center: number[][]; // [x, z][]
    left: number[][];   // [x, z][]
    right: number[][];  // [x, z][]
  };
  laps: TelemetryLap[];
}

let sessionData: TelemetrySession | null = null;
let activeLapA: TelemetryLap | null = null;
let activeLapB: TelemetryLap | null = null;
let compareMode = false;
let currentSampleIndex = 0;
let trackMapColorMode: "THR" | "SPD" = "THR"; // "THR" = Throttle/Brake, "SPD" = Speed

// Playback states
let isPlaying = false;
let playSpeed = 1.0;
let lastFrameTime = 0;
let fractionalSampleIndex = 0;

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
const hudTrackTemp = document.getElementById("hud-track-temp");
const hudAmbTemp = document.getElementById("hud-amb-temp");

// Comparison elements
const selectLapA = document.getElementById("select-lap-a") as HTMLSelectElement | null;
const selectLapB = document.getElementById("select-lap-b") as HTMLSelectElement | null;
const compareModeCheckbox = document.getElementById("compare-mode-checkbox") as HTMLInputElement | null;
const lapSelectorContainer = document.getElementById("lap-selector-container");

const hudThrBContainer = document.getElementById("hud-thr-b-container");
const hudBrkBContainer = document.getElementById("hud-brk-b-container");
const hudCltBContainer = document.getElementById("hud-clt-b-container");
const hudThrB = document.getElementById("hud-thr-b");
const hudBrkB = document.getElementById("hud-brk-b");
const hudCltB = document.getElementById("hud-clt-b");

// Prompter elements
const aiPromptBox = document.getElementById("ai-prompt-box") as HTMLTextAreaElement;
const btnCopyPrompt = document.getElementById("btn-copy-prompt");

// Timeline elements
const scrubber = document.getElementById("telemetry-scrubber") as HTMLInputElement;
const scrubberTime = document.getElementById("scrubber-time");
const btnPlayPause = document.getElementById("btn-play-pause") as HTMLButtonElement | null;
const selectPlaySpeed = document.getElementById("select-play-speed") as HTMLSelectElement | null;

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
      if (json && json.metadata) {
        if (json.laps && json.laps.length > 0) {
          // New format (session file)
          sessionData = json as TelemetrySession;
        } else if (json.samples && json.samples.length > 0) {
          // Old format (single lap file) - normalize to session format
          sessionData = {
            metadata: {
              trackId: json.metadata.trackId || "unknown",
              trackName: json.metadata.trackName || "Unknown Track",
              trackLayout: json.metadata.trackLayout || "",
              carId: json.metadata.carId || "unknown",
              carName: json.metadata.carName || "Unknown Car",
              timestamp: json.metadata.timestamp || new Date().toISOString(),
              bestLatG: json.metadata.bestLatG || 0,
              bestDecelG: json.metadata.bestDecelG || 0
            },
            trackMap: json.trackMap || { center: [], left: [], right: [] },
            laps: [{
              lapNumber: json.metadata.lapNumber || 1,
              lapTimeMs: json.metadata.lapTimeMs || 0,
              sectorTimes: json.metadata.sectorTimes || [],
              timestamp: json.metadata.timestamp || new Date().toISOString(),
              bestLatG: json.metadata.bestLatG || 0,
              bestDecelG: json.metadata.bestDecelG || 0,
              corners: json.corners || [],
              samples: json.samples || []
            }]
          };
        } else {
          alert("O arquivo selecionado não parece ser um arquivo de telemetria válido.");
          return;
        }

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

function populateLapSelectors(): void {
  if (!sessionData || !selectLapA || !selectLapB || !lapSelectorContainer) return;

  lapSelectorContainer.classList.remove("hidden");
  selectLapA.innerHTML = "";
  selectLapB.innerHTML = "";

  sessionData.laps.forEach((lap, idx) => {
    const timeStr = formatTime(lap.lapTimeMs);
    const optionText = `Volta ${lap.lapNumber} (${timeStr})`;
    
    const optA = document.createElement("option");
    optA.value = idx.toString();
    optA.text = optionText;
    selectLapA.appendChild(optA);

    const optB = document.createElement("option");
    optB.value = idx.toString();
    optB.text = optionText;
    selectLapB.appendChild(optB);
  });

  // Find best lap
  let bestIdx = 0;
  let minTime = Infinity;
  sessionData.laps.forEach((lap, idx) => {
    if (lap.lapTimeMs < minTime) {
      minTime = lap.lapTimeMs;
      bestIdx = idx;
    }
  });

  selectLapA.value = bestIdx.toString();
  activeLapA = sessionData.laps[bestIdx];

  let bestBIdx = 0;
  if (sessionData.laps.length > 1) {
    let minTimeB = Infinity;
    sessionData.laps.forEach((lap, idx) => {
      if (idx !== bestIdx && lap.lapTimeMs < minTimeB) {
        minTimeB = lap.lapTimeMs;
        bestBIdx = idx;
      }
    });
  }
  selectLapB.value = bestBIdx.toString();
  activeLapB = sessionData.laps[bestBIdx];

  if (compareModeCheckbox) {
    compareModeCheckbox.checked = false;
    compareMode = false;
    selectLapB.disabled = true;
  }
  toggleCompareUI(false);
}

function toggleCompareUI(enabled: boolean): void {
  const elements = [hudThrBContainer, hudBrkBContainer, hudCltBContainer];
  elements.forEach(el => {
    if (enabled) {
      el?.classList.remove("hidden");
    } else {
      el?.classList.add("hidden");
    }
  });
}

if (selectLapA) {
  selectLapA.addEventListener("change", () => {
    if (!sessionData) return;
    const idx = parseInt(selectLapA.value);
    activeLapA = sessionData.laps[idx];

    Array.from(selectLapB?.options || []).forEach((opt: any) => {
      opt.disabled = (opt.value === selectLapA.value);
    });

    loadLapAData();
  });
}

if (selectLapB) {
  selectLapB.addEventListener("change", () => {
    if (!sessionData) return;
    const idx = parseInt(selectLapB.value);
    activeLapB = sessionData.laps[idx];
    loadLapAData();
  });
}

if (compareModeCheckbox) {
  compareModeCheckbox.addEventListener("change", () => {
    if (!sessionData) return;
    compareMode = compareModeCheckbox.checked;
    if (selectLapB) selectLapB.disabled = !compareMode;
    toggleCompareUI(compareMode);

    if (compareMode && selectLapB && selectLapA && selectLapB.value === selectLapA.value) {
      let newIdx = 0;
      for (let i = 0; i < sessionData.laps.length; i++) {
        if (i.toString() !== selectLapA.value) {
          newIdx = i;
          break;
        }
      }
      selectLapB.value = newIdx.toString();
      activeLapB = sessionData.laps[newIdx];
    }

    if (selectLapB) {
      Array.from(selectLapB.options).forEach((opt: any) => {
        opt.disabled = (opt.value === selectLapA?.value);
      });
    }

    loadLapAData();
  });
}

function loadDashboard(): void {
  if (!sessionData) return;

  emptyState?.classList.add("hidden");
  mainDashboard?.classList.remove("hidden");

  resizeCanvases();
  populateLapSelectors();
  resetZoomFit();
  loadLapAData();
}

function loadLapAData(): void {
  if (!sessionData || !activeLapA) return;

  // Reset playback state on lap reload
  isPlaying = false;
  if (btnPlayPause) btnPlayPause.innerText = "▶";
  fractionalSampleIndex = 0;

  if (sumTrack) sumTrack.innerText = sessionData.metadata.trackName + (sessionData.metadata.trackLayout ? ` (${sessionData.metadata.trackLayout})` : "");
  if (sumCar) sumCar.innerText = sessionData.metadata.carName;
  
  if (sumLapTime) {
    if (compareMode && activeLapB) {
      const delta = activeLapA.lapTimeMs - activeLapB.lapTimeMs;
      const deltaSign = delta <= 0 ? "-" : "+";
      const deltaStr = `${deltaSign}${formatTime(Math.abs(delta))}`;
      const deltaColor = delta <= 0 ? "#10b981" : "#ef4444";
      sumLapTime.innerHTML = `${formatTime(activeLapA.lapTimeMs)} <span style="font-size: 13px; color: ${deltaColor}; font-weight: normal; margin-left: 6px;">(${deltaStr})</span>`;
    } else {
      sumLapTime.innerText = formatTime(activeLapA.lapTimeMs);
    }
  }
  if (sumDate) sumDate.innerText = activeLapA.timestamp;

  const sectorsA = activeLapA.sectorTimes || [];
  const sectorsB = (compareMode && activeLapB) ? (activeLapB.sectorTimes || []) : [];

  if (sumS1) {
    if (compareMode && sectorsB[0]) {
      sumS1.innerHTML = `${formatTime(sectorsA[0])} <span style="font-size: 9px; color: var(--text-muted); font-weight: normal;">/ ${formatTime(sectorsB[0])}</span>`;
    } else {
      sumS1.innerText = sectorsA[0] ? formatTime(sectorsA[0]) : "--:--.---";
    }
  }
  if (sumS2) {
    if (compareMode && sectorsB[1]) {
      sumS2.innerHTML = `${formatTime(sectorsA[1])} <span style="font-size: 9px; color: var(--text-muted); font-weight: normal;">/ ${formatTime(sectorsB[1])}</span>`;
    } else {
      sumS2.innerText = sectorsA[1] ? formatTime(sectorsA[1]) : "--:--.---";
    }
  }
  if (sumS3) {
    if (compareMode && sectorsB[2]) {
      sumS3.innerHTML = `${formatTime(sectorsA[2])} <span style="font-size: 9px; color: var(--text-muted); font-weight: normal;">/ ${formatTime(sectorsB[2])}</span>`;
    } else {
      sumS3.innerText = sectorsA[2] ? formatTime(sectorsA[2]) : "--:--.---";
    }
  }

  if (scrubber) {
    scrubber.max = (activeLapA.samples.length - 1).toString();
    if (parseInt(scrubber.value) >= activeLapA.samples.length) {
      scrubber.value = "0";
      currentSampleIndex = 0;
    }
  }
  updateSelectedPoint();
  renderCornerTable();
  generateAIPrompt();

  drawTrackMap();
  drawCharts();
}

function renderCornerTable(): void {
  if (!activeLapA || !cornerRowsAnchor) return;
  cornerRowsAnchor.innerHTML = "";

  activeLapA.corners.forEach((c, idx) => {
    const row = document.createElement("div");
    row.className = "corner-row";
    row.dataset.index = idx.toString();
    
    let gradeClass = "grade-blue";
    if (c.grade === "S") gradeClass = "grade-gold";
    else if (c.grade.startsWith("A")) gradeClass = "grade-green";
    else if (c.grade.startsWith("B")) gradeClass = "grade-blue";
    else if (c.grade.startsWith("D")) gradeClass = "grade-red";

    const cB = (compareMode && activeLapB) ? activeLapB.corners[idx] : null;

    if (cB) {
      let gradeClassB = "grade-blue";
      if (cB.grade === "S") gradeClassB = "grade-gold";
      else if (cB.grade.startsWith("A")) gradeClassB = "grade-green";
      else if (cB.grade.startsWith("B")) gradeClassB = "grade-blue";
      else if (cB.grade.startsWith("D")) gradeClassB = "grade-red";

      row.innerHTML = `
        <span style="font-weight: 600;">C${idx + 1}</span>
        <span style="text-align: center; display: flex; align-items: center; justify-content: center; gap: 4px;">
          <span class="grade-badge ${gradeClass}">${c.grade}</span>
          <span class="grade-badge ${gradeClassB}" style="opacity: 0.65; transform: scale(0.95);">${cB.grade}</span>
        </span>
        <span style="text-align: right; font-family: monospace; font-size: 10px;">${Math.round(c.minSpeedKmh)} / ${Math.round(cB.minSpeedKmh)}</span>
        <span style="text-align: right; font-family: monospace; font-size: 10px;">${c.trailScore}% / ${cB.trailScore}%</span>
        <span style="text-align: right; font-family: monospace; font-size: 10px;">${c.gripUtilization}% / ${cB.gripUtilization}%</span>
      `;
    } else {
      row.innerHTML = `
        <span style="font-weight: 600;">C${idx + 1}</span>
        <span style="text-align: center;"><span class="grade-badge ${gradeClass}">${c.grade}</span></span>
        <span style="text-align: right; font-family: monospace;">${Math.round(c.minSpeedKmh)}/${Math.round(c.targetSpeedKmh)}</span>
        <span style="text-align: right; font-family: monospace;">${c.trailScore}%</span>
        <span style="text-align: right; font-family: monospace;">${c.gripUtilization}%</span>
      `;
    }

    row.addEventListener("click", () => {
      document.querySelectorAll(".corner-row").forEach(r => r.classList.remove("selected"));
      row.classList.add("selected");
      
      if (c.startIndex !== undefined && c.endIndex !== undefined) {
        focusMapOnSamples(c.startIndex, c.endIndex);
        
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

function getCornerPromptAnalysis(lap: TelemetryLap, c: CornerRating, idx: number): string {
  if (c.startIndex === undefined || c.endIndex === undefined || c.startIndex < 0 || c.endIndex >= lap.samples.length || c.startIndex > c.endIndex) {
    return `- Curva ${idx + 1}: Nota ${c.grade} (V. Mínima: ${Math.round(c.minSpeedKmh)} km/h | Ideal: ${Math.round(c.targetSpeedKmh)} km/h). Trail braking: ${c.trailScore}%. Uso do Grip: ${c.gripUtilization}%. Timing do Ápice: ${c.apexTiming}.\n`;
  }

  const samples = lap.samples.slice(c.startIndex, c.endIndex + 1);
  if (samples.length === 0) {
    return `- Curva ${idx + 1}: Nota ${c.grade} (V. Mínima: ${Math.round(c.minSpeedKmh)} km/h | Ideal: ${Math.round(c.targetSpeedKmh)} km/h). Trail braking: ${c.trailScore}%. Uso do Grip: ${c.gripUtilization}%. Timing do Ápice: ${c.apexTiming}.\n`;
  }

  const entry = samples[0];
  const exit = samples[samples.length - 1];

  let apex = samples[0];
  let minSpeed = samples[0].speed;
  samples.forEach(s => {
    if (s.speed < minSpeed) {
      minSpeed = s.speed;
      apex = s;
    }
  });

  // Calculate lost grip occurrences
  let undCount = 0, oveCount = 0, spinCount = 0, lockCount = 0;
  let maxUnd = 0, maxOve = 0, maxSpin = 0, maxLock = 0;

  samples.forEach(s => {
    if (s.und && s.und > 0) { undCount++; if (s.und > maxUnd) maxUnd = s.und; }
    if (s.ove && s.ove > 0) { oveCount++; if (s.ove > maxOve) maxOve = s.ove; }
    if (s.spin && s.spin > 0) { spinCount++; if (s.spin > maxSpin) maxSpin = s.spin; }
    if (s.lock && s.lock > 0) { lockCount++; if (s.lock > maxLock) maxLock = s.lock; }
  });

  const formatGear = (g: number) => g === -1 ? "R" : g === 0 ? "N" : g.toString();

  let detail = `- Curva ${idx + 1}: Nota ${c.grade} (V. Mínima: ${Math.round(c.minSpeedKmh)} km/h | Ideal: ${Math.round(c.targetSpeedKmh)} km/h | Trail: ${c.trailScore}% | Grip: ${c.gripUtilization}% | Ápice: ${c.apexTiming})\n`;
  detail += `  * Entrada: Vel: ${Math.round(entry.speed)} km/h, Marcha: ${formatGear(entry.gear)}, Acel: ${Math.round(entry.thr * 100)}%, Freio: ${Math.round(entry.brk * 100)}%, Esterço: ${Math.round(entry.steer * 100)}%, G-Lat: ${entry.gLat.toFixed(2)}G, G-Long: ${entry.gLong.toFixed(2)}G\n`;
  detail += `  * Ápice:   Vel: ${Math.round(apex.speed)} km/h, Marcha: ${formatGear(apex.gear)}, Acel: ${Math.round(apex.thr * 100)}%, Freio: ${Math.round(apex.brk * 100)}%, Esterço: ${Math.round(apex.steer * 100)}%, G-Lat: ${apex.gLat.toFixed(2)}G, G-Long: ${apex.gLong.toFixed(2)}G\n`;
  detail += `  * Saída:   Vel: ${Math.round(exit.speed)} km/h, Marcha: ${formatGear(exit.gear)}, Acel: ${Math.round(exit.thr * 100)}%, Freio: ${Math.round(exit.brk * 100)}%, Esterço: ${Math.round(exit.steer * 100)}%, G-Lat: ${exit.gLat.toFixed(2)}G, G-Long: ${exit.gLong.toFixed(2)}G\n`;

  const lossEvents: string[] = [];
  if (undCount > 0) lossEvents.push(`Subesterço: ${undCount} instantes (Max: ${maxUnd.toFixed(2)})`);
  if (oveCount > 0) lossEvents.push(`Sobresterço: ${oveCount} instantes (Max: ${maxOve.toFixed(2)})`);
  if (spinCount > 0) lossEvents.push(`Patinamento: ${spinCount} instantes (Max: ${maxSpin.toFixed(2)})`);
  if (lockCount > 0) lossEvents.push(`Travamento: ${lockCount} instantes (Max: ${maxLock.toFixed(2)})`);

  if (lossEvents.length > 0) {
    detail += `  * Perdas de Aderência no contorno: ${lossEvents.join(" | ")}\n`;
  }
  return detail;
}

function getCornerPromptCompareAnalysis(lapA: TelemetryLap, cA: CornerRating, lapB: TelemetryLap, cB: CornerRating, idx: number): string {
  let detail = `- Curva ${idx + 1}:\n`;

  const getPoints = (lap: TelemetryLap, c: CornerRating) => {
    if (c.startIndex === undefined || c.endIndex === undefined || c.startIndex < 0 || c.endIndex >= lap.samples.length || c.startIndex > c.endIndex) {
      return null;
    }
    const samples = lap.samples.slice(c.startIndex, c.endIndex + 1);
    if (samples.length === 0) return null;
    
    const entry = samples[0];
    const exit = samples[samples.length - 1];
    let apex = samples[0];
    let minSpeed = samples[0].speed;
    samples.forEach(s => {
      if (s.speed < minSpeed) {
        minSpeed = s.speed;
        apex = s;
      }
    });

    let undCount = 0, oveCount = 0, spinCount = 0, lockCount = 0;
    let maxUnd = 0, maxOve = 0, maxSpin = 0, maxLock = 0;
    samples.forEach(s => {
      if (s.und && s.und > 0) { undCount++; if (s.und > maxUnd) maxUnd = s.und; }
      if (s.ove && s.ove > 0) { oveCount++; if (s.ove > maxOve) maxOve = s.ove; }
      if (s.spin && s.spin > 0) { spinCount++; if (s.spin > maxSpin) maxSpin = s.spin; }
      if (s.lock && s.lock > 0) { lockCount++; if (s.lock > maxLock) maxLock = s.lock; }
    });

    return { entry, apex, exit, undCount, oveCount, spinCount, lockCount, maxUnd, maxOve, maxSpin, maxLock };
  };

  const pA = getPoints(lapA, cA);
  const pB = getPoints(lapB, cB);
  const formatGear = (g: number) => g === -1 ? "R" : g === 0 ? "N" : g.toString();

  detail += `  [Volta A (Principal)] Nota ${cA.grade} | V.Mínima: ${Math.round(cA.minSpeedKmh)} km/h | Ideal: ${Math.round(cA.targetSpeedKmh)} km/h | Trail: ${cA.trailScore}% | Grip: ${cA.gripUtilization}% | Ápice: ${cA.apexTiming}\n`;
  if (pA) {
    detail += `    * Entrada: Vel: ${Math.round(pA.entry.speed)} km/h, Marcha: ${formatGear(pA.entry.gear)}, Acel: ${Math.round(pA.entry.thr * 100)}%, Freio: ${Math.round(pA.entry.brk * 100)}%, Esterço: ${Math.round(pA.entry.steer * 100)}%, G-Lat: ${pA.entry.gLat.toFixed(2)}G, G-Long: ${pA.entry.gLong.toFixed(2)}G\n`;
    detail += `    * Ápice:   Vel: ${Math.round(pA.apex.speed)} km/h, Marcha: ${formatGear(pA.apex.gear)}, Acel: ${Math.round(pA.apex.thr * 100)}%, Freio: ${Math.round(pA.apex.brk * 100)}%, Esterço: ${Math.round(pA.apex.steer * 100)}%, G-Lat: ${pA.apex.gLat.toFixed(2)}G, G-Long: ${pA.apex.gLong.toFixed(2)}G\n`;
    detail += `    * Saída:   Vel: ${Math.round(pA.exit.speed)} km/h, Marcha: ${formatGear(pA.exit.gear)}, Acel: ${Math.round(pA.exit.thr * 100)}%, Freio: ${Math.round(pA.exit.brk * 100)}%, Esterço: ${Math.round(pA.exit.steer * 100)}%, G-Lat: ${pA.exit.gLat.toFixed(2)}G, G-Long: ${pA.exit.gLong.toFixed(2)}G\n`;
    const lossA: string[] = [];
    if (pA.undCount > 0) lossA.push(`Subesterço: ${pA.undCount} (Max: ${pA.maxUnd.toFixed(2)})`);
    if (pA.oveCount > 0) lossA.push(`Sobresterço: ${pA.oveCount} (Max: ${pA.maxOve.toFixed(2)})`);
    if (pA.spinCount > 0) lossA.push(`Patinamento: ${pA.spinCount} (Max: ${pA.maxSpin.toFixed(2)})`);
    if (pA.lockCount > 0) lossA.push(`Travamento: ${pA.lockCount} (Max: ${pA.maxLock.toFixed(2)})`);
    if (lossA.length > 0) {
      detail += `    * Perdas de Aderência: ${lossA.join(" | ")}\n`;
    }
  }

  detail += `  [Volta B (Referência)] Nota ${cB.grade} | V.Mínima: ${Math.round(cB.minSpeedKmh)} km/h | Ideal: ${Math.round(cB.targetSpeedKmh)} km/h | Trail: ${cB.trailScore}% | Grip: ${cB.gripUtilization}% | Ápice: ${cB.apexTiming}\n`;
  if (pB) {
    detail += `    * Entrada: Vel: ${Math.round(pB.entry.speed)} km/h, Marcha: ${formatGear(pB.entry.gear)}, Acel: ${Math.round(pB.entry.thr * 100)}%, Freio: ${Math.round(pB.entry.brk * 100)}%, Esterço: ${Math.round(pB.entry.steer * 100)}%, G-Lat: ${pB.entry.gLat.toFixed(2)}G, G-Long: ${pB.entry.gLong.toFixed(2)}G\n`;
    detail += `    * Ápice:   Vel: ${Math.round(pB.apex.speed)} km/h, Marcha: ${formatGear(pB.apex.gear)}, Acel: ${Math.round(pB.apex.thr * 100)}%, Freio: ${Math.round(pB.apex.brk * 100)}%, Esterço: ${Math.round(pB.apex.steer * 100)}%, G-Lat: ${pB.apex.gLat.toFixed(2)}G, G-Long: ${pB.apex.gLong.toFixed(2)}G\n`;
    detail += `    * Saída:   Vel: ${Math.round(pB.exit.speed)} km/h, Marcha: ${formatGear(pB.exit.gear)}, Acel: ${Math.round(pB.exit.thr * 100)}%, Freio: ${Math.round(pB.exit.brk * 100)}%, Esterço: ${Math.round(pB.exit.steer * 100)}%, G-Lat: ${pB.exit.gLat.toFixed(2)}G, G-Long: ${pB.exit.gLong.toFixed(2)}G\n`;
    const lossB: string[] = [];
    if (pB.undCount > 0) lossB.push(`Subesterço: ${pB.undCount} (Max: ${pB.maxUnd.toFixed(2)})`);
    if (pB.oveCount > 0) lossB.push(`Sobresterço: ${pB.oveCount} (Max: ${pB.maxOve.toFixed(2)})`);
    if (pB.spinCount > 0) lossB.push(`Patinamento: ${pB.spinCount} (Max: ${pB.maxSpin.toFixed(2)})`);
    if (pB.lockCount > 0) lossB.push(`Travamento: ${pB.lockCount} (Max: ${pB.maxLock.toFixed(2)})`);
    if (lossB.length > 0) {
      detail += `    * Perdas de Aderência: ${lossB.join(" | ")}\n`;
    }
  }

  return detail;
}

function generateAIPrompt(): void {
  const lapA = activeLapA;
  if (!lapA || !aiPromptBox) return;

  const sectorsA = lapA.sectorTimes || [];
  const s1StrA = sectorsA[0] ? formatTime(sectorsA[0]) : "N/D";
  const s2StrA = sectorsA[1] ? formatTime(sectorsA[1]) : "N/D";
  const s3StrA = sectorsA[2] ? formatTime(sectorsA[2]) : "N/D";

  let underCountA = 0, overCountA = 0, spinCountA = 0, lockCountA = 0;
  lapA.samples.forEach(s => {
    if (s.und && s.und > 0) underCountA++;
    if (s.ove && s.ove > 0) overCountA++;
    if (s.spin && s.spin > 0) spinCountA++;
    if (s.lock && s.lock > 0) lockCountA++;
  });

  let prompt = "";
  const lapB = activeLapB;

  if (compareMode && lapB && sessionData) {
    const sectorsB = lapB.sectorTimes || [];
    const s1StrB = sectorsB[0] ? formatTime(sectorsB[0]) : "N/D";
    const s2StrB = sectorsB[1] ? formatTime(sectorsB[1]) : "N/D";
    const s3StrB = sectorsB[2] ? formatTime(sectorsB[2]) : "N/D";

    let underCountB = 0, overCountB = 0, spinCountB = 0, lockCountB = 0;
    lapB.samples.forEach(s => {
      if (s.und && s.und > 0) underCountB++;
      if (s.ove && s.ove > 0) overCountB++;
      if (s.spin && s.spin > 0) spinCountB++;
      if (s.lock && s.lock > 0) lockCountB++;
    });

    let cornerDetails = "";
    const maxCorners = Math.max(lapA.corners.length, lapB.corners.length);
    for (let idx = 0; idx < maxCorners; idx++) {
      const cA = lapA.corners[idx];
      const cB = lapB.corners[idx];
      if (cA && cB) {
        cornerDetails += getCornerPromptCompareAnalysis(lapA, cA, lapB, cB, idx);
      } else if (cA) {
        cornerDetails += `- Curva ${idx + 1}: Volta A: Nota ${cA.grade} (V.Mínima: ${Math.round(cA.minSpeedKmh)} km/h | Trail: ${cA.trailScore}% | Grip: ${cA.gripUtilization}% | Ápice: ${cA.apexTiming}) vs Volta B: N/D\n`;
      } else if (cB) {
        cornerDetails += `- Curva ${idx + 1}: Volta A: N/D vs Volta B: Nota ${cB.grade} (V.Mínima: ${Math.round(cB.minSpeedKmh)} km/h | Trail: ${cB.trailScore}% | Grip: ${cB.gripUtilization}% | Ápice: ${cB.apexTiming})\n`;
      }
    }

    const delta = lapA.lapTimeMs - lapB.lapTimeMs;
    const deltaSign = delta <= 0 ? "-" : "+";
    const deltaStr = `${deltaSign}${formatTime(Math.abs(delta))}`;

    prompt = `Você é um engenheiro de pista e coach de pilotagem profissional de automobilismo.
Analise a telemetria comparativa de duas voltas (Volta A vs Volta B) no simulador Assetto Corsa para me ajudar a entender onde ganhei ou perdi tempo e como posso ser mais consistente.

=== Informações Gerais ===
- Carro: ${sessionData.metadata.carName} (${sessionData.metadata.carId})
- Pista: ${sessionData.metadata.trackName} (${sessionData.metadata.trackId} - ${sessionData.metadata.trackLayout})
- Tempo da Volta A (Principal): ${formatTime(lapA.lapTimeMs)}
- Tempo da Volta B (Referência): ${formatTime(lapB.lapTimeMs)}
- Diferença (A - B): ${deltaStr} (Volta A é ${delta <= 0 ? 'mais rápida' : 'mais lenta'} por ${formatTime(Math.abs(delta))})

=== Tempos de Setor ===
- Setor 1: Volta A: ${s1StrA} | Volta B: ${s1StrB}
- Setor 2: Volta A: ${s2StrA} | Volta B: ${s2StrB}
- Setor 3: Volta A: ${s3StrA} | Volta B: ${s3StrB}

=== Instantes Totais de Perda de Aderência (Frequência a 10Hz) ===
- Subesterço (Understeer): Volta A: ${underCountA} vs Volta B: ${underCountB}
- Sobresterço (Oversteer): Volta A: ${overCountA} vs Volta B: ${overCountB}
- Patinamento (Wheelspin): Volta A: ${spinCountA} vs Volta B: ${spinCountB}
- Travamento de Rodas (Lockup): Volta A: ${lockCountA} vs Volta B: ${lockCountB}

=== Desempenho Comparativo Curva por Curva ===
${cornerDetails}

Por favor, faça uma análise comparativa detalhada de ambas as voltas. Indique em quais curvas e setores a Volta A ganhou tempo em relação à Volta B e vice-versa. Analise as diferenças de velocidade na entrada, ápice e saída das curvas, o uso de marcha, trail braking e grip, e os incidentes de perda de aderência. Forneça recomendações acionáveis sobre como combinar o melhor de ambas as voltas para fazer um tempo de volta ideal mais baixo.`;
  } else if (sessionData) {
    let cornerDetails = "";
    lapA.corners.forEach((c, idx) => {
      cornerDetails += getCornerPromptAnalysis(lapA, c, idx);
    });

    prompt = `Você é um engenheiro de pista e coach de pilotagem profissional de automobilismo.
Analise a telemetria desta volta no simulador Assetto Corsa para me ajudar a melhorar meu tempo de volta.

=== Informações Gerais ===
- Carro: ${sessionData.metadata.carName} (${sessionData.metadata.carId})
- Pista: ${sessionData.metadata.trackName} (${sessionData.metadata.trackId} - ${sessionData.metadata.trackLayout})
- Tempo da Volta: ${formatTime(lapA.lapTimeMs)}
- Tempos de Setor: Setor 1: ${s1StrA} | Setor 2: ${s2StrA} | Setor 3: ${s3StrA}
- Aceleração Lateral Máxima: ${lapA.bestLatG || sessionData.metadata.bestLatG} G
- Desaceleração Máxima: ${lapA.bestDecelG || sessionData.metadata.bestDecelG} G

=== Instantes Totais de Perda de Aderência (Frequência a 10Hz) ===
- Subesterço (Understeer): ${underCountA} instantes amostrados
- Sobresterço (Oversteer): ${overCountA} instantes amostrados
- Patinamento (Wheelspin): ${spinCountA} instantes amostrados
- Travamento de Rodas (Lockup): ${lockCountA} instantes amostrados

=== Desempenho Curva por Curva ===
${cornerDetails}

Por favor, faça um review detalhado sobre o meu estilo de pilotagem. Destaque quais curvas ou setores me custaram mais tempo, analise detalhadamente a velocidade, uso de marchas e pedais na entrada, ápice e saída de curva (com foco nas notas baixas). Comente sobre o meu trail braking, uso de grip e perdas de aderência e me dê dicas acionáveis de pilotagem para que eu consiga abaixar meu tempo de volta nesta pista.`;
  }

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
    fractionalSampleIndex = currentSampleIndex; // Sync fractional index
    updateSelectedPoint();
    drawTrackMap();
    drawCharts();
  });
}

function runPlayback(timestamp: number): void {
  if (!isPlaying || !activeLapA) {
    lastFrameTime = 0;
    return;
  }

  if (lastFrameTime === 0) {
    lastFrameTime = timestamp;
    requestAnimationFrame(runPlayback);
    return;
  }

  const dt = (timestamp - lastFrameTime) / 1000; // seconds
  lastFrameTime = timestamp;

  // 10Hz sampling means 10 samples per second of driving
  fractionalSampleIndex += dt * 10.0 * playSpeed;

  if (fractionalSampleIndex >= activeLapA.samples.length) {
    fractionalSampleIndex = 0; // loop back
  }

  currentSampleIndex = Math.floor(fractionalSampleIndex);

  if (scrubber) {
    scrubber.value = currentSampleIndex.toString();
  }

  updateSelectedPoint();
  drawTrackMap();
  drawCharts();

  requestAnimationFrame(runPlayback);
}

if (btnPlayPause) {
  btnPlayPause.addEventListener("click", () => {
    if (!activeLapA) return;
    isPlaying = !isPlaying;
    if (isPlaying) {
      btnPlayPause.innerText = "⏸";
      lastFrameTime = 0;
      fractionalSampleIndex = currentSampleIndex;
      requestAnimationFrame(runPlayback);
    } else {
      btnPlayPause.innerText = "▶";
    }
  });

  // Keydown listener for spacebar to play/pause
  document.addEventListener("keydown", (e) => {
    if (e.code === "Space" || e.key === " ") {
      const target = e.target as HTMLElement;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable)) {
        if (target.tagName === "TEXTAREA" || (target.tagName === "INPUT" && (target as HTMLInputElement).type !== "range" && (target as HTMLInputElement).type !== "checkbox")) {
          return;
        }
      }
      e.preventDefault();
      btnPlayPause.click();
    }
  });
}

if (selectPlaySpeed) {
  selectPlaySpeed.addEventListener("change", () => {
    playSpeed = parseFloat(selectPlaySpeed.value);
  });
}

function updateSelectedPoint(): void {
  if (!activeLapA) return;
  const sampleA = activeLapA.samples[currentSampleIndex];
  if (!sampleA) return;

  const ratio = currentSampleIndex / (activeLapA.samples.length - 1 || 1);
  const idxB = compareMode && activeLapB ? Math.round(ratio * (activeLapB.samples.length - 1)) : 0;
  const sampleB = (compareMode && activeLapB) ? activeLapB.samples[idxB] : null;

  if (scrubberTime) scrubberTime.innerText = formatTime(sampleA.t);

  // Speed, Gear, RPM
  if (hudSpeed) {
    if (sampleB) {
      hudSpeed.innerHTML = `${Math.round(sampleA.speed)} <span style="font-size: 11px; color: var(--text-muted);">/</span> ${Math.round(sampleB.speed)} <span style="font-size: 10px; color: var(--text-muted);">km/h</span>`;
    } else {
      hudSpeed.innerHTML = `${Math.round(sampleA.speed)} <span style="font-size: 10px; color: var(--text-muted);">km/h</span>`;
    }
  }

  const formatGear = (g: number) => g === -1 ? "R" : g === 0 ? "N" : g.toString();
  if (hudGear) {
    if (sampleB) {
      hudGear.innerText = `${formatGear(sampleA.gear)} / ${formatGear(sampleB.gear)}`;
      hudGear.style.fontSize = "16px";
    } else {
      hudGear.innerText = formatGear(sampleA.gear);
      hudGear.style.fontSize = "20px";
    }
  }

  if (hudRpm) {
    if (sampleB) {
      hudRpm.innerText = `${Math.round(sampleA.rpm)} / ${Math.round(sampleB.rpm)}`;
      hudRpm.style.fontSize = "14px";
    } else {
      hudRpm.innerText = Math.round(sampleA.rpm).toString();
      hudRpm.style.fontSize = "20px";
    }
  }

  // Pedals
  if (hudThr) hudThr.style.width = `${sampleA.thr * 100}%`;
  if (hudBrk) hudBrk.style.width = `${sampleA.brk * 100}%`;
  if (hudClt) hudClt.style.width = `${sampleA.clt * 100}%`;

  if (sampleB) {
    if (hudThrB) hudThrB.style.width = `${sampleB.thr * 100}%`;
    if (hudBrkB) hudBrkB.style.width = `${sampleB.brk * 100}%`;
    if (hudCltB) hudCltB.style.width = `${sampleB.clt * 100}%`;
    
    if (lblThr) lblThr.innerText = `${Math.round(sampleA.thr * 100)}% / ${Math.round(sampleB.thr * 100)}%`;
    if (lblBrk) lblBrk.innerText = `${Math.round(sampleA.brk * 100)}% / ${Math.round(sampleB.brk * 100)}%`;
    if (lblClt) lblClt.innerText = `${Math.round(sampleA.clt * 100)}% / ${Math.round(sampleB.clt * 100)}%`;
  } else {
    if (lblThr) lblThr.innerText = `${Math.round(sampleA.thr * 100)}%`;
    if (lblBrk) lblBrk.innerText = `${Math.round(sampleA.brk * 100)}%`;
    if (lblClt) lblClt.innerText = `${Math.round(sampleA.clt * 100)}%`;
  }

  // Steering wheel rotation
  if (svgSteering) {
    const rotationAngle = sampleA.steer * 360;
    svgSteering.style.transform = `rotate(${rotationAngle}deg)`;
  }
  if (hudSteer) {
    if (sampleB) {
      hudSteer.innerText = `${Math.round(sampleA.steer * 450)}° / ${Math.round(sampleB.steer * 450)}°`;
    } else {
      hudSteer.innerText = `${Math.round(sampleA.steer * 450)}°`;
    }
  }

  // Tyres slip angle, temp and grip
  const tyres = ["fl", "fr", "rl", "rr"];
  const elements = [tFL, tFR, tRL, tRR];
  elements.forEach((el, idx) => {
    if (!el) return;
    const slipA = sampleA.slpA[idx];
    const slipB = sampleB ? sampleB.slpA[idx] : null;

    const slipEl = document.getElementById(`t-${tyres[idx]}-slip`);
    const tempEl = document.getElementById(`t-${tyres[idx]}-temp`);
    const gripEl = document.getElementById(`t-${tyres[idx]}-grip`);

    if (slipEl) {
      if (slipB !== null) {
        slipEl.innerText = `Esterço: ${slipA.toFixed(1)}° / ${slipB.toFixed(1)}°`;
      } else {
        slipEl.innerText = `Esterço: ${slipA.toFixed(1)}°`;
      }
    }

    const tempA = sampleA.tCore ? sampleA.tCore[idx] : null;
    const tempB = sampleB && sampleB.tCore ? sampleB.tCore[idx] : null;
    if (tempEl) {
      if (tempA !== null && tempA !== undefined) {
        if (tempB !== null && tempB !== undefined) {
          tempEl.innerText = `${Math.round(tempA)}°C / ${Math.round(tempB)}°C`;
        } else {
          tempEl.innerText = `${Math.round(tempA)}°C`;
        }
        tempEl.style.color = "var(--text-primary)";
      } else {
        tempEl.innerText = `-- °C`;
        tempEl.style.color = "var(--text-muted)";
      }
    }

    const gripA = sampleA.tGrip ? sampleA.tGrip[idx] : null;
    const gripB = sampleB && sampleB.tGrip ? sampleB.tGrip[idx] : null;
    if (gripEl) {
      if (gripA !== null && gripA !== undefined) {
        const gripPctA = Math.round(gripA * 100);
        if (gripB !== null && gripB !== undefined) {
          const gripPctB = Math.round(gripB * 100);
          gripEl.innerText = `Grip: ${gripPctA}% / ${gripPctB}%`;
        } else {
          gripEl.innerText = `Grip: ${gripPctA}%`;
        }
        gripEl.style.color = "var(--text-primary)";
      } else {
        gripEl.innerText = `Grip: --`;
        gripEl.style.color = "var(--text-muted)";
      }
    }
    
    const absSlip = Math.abs(slipA);
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

  // Environment conditions
  if (hudTrackTemp) {
    const trackTempA = sampleA.rTemp;
    const trackTempB = sampleB ? sampleB.rTemp : null;
    if (trackTempA !== undefined && trackTempA !== null) {
      if (trackTempB !== undefined && trackTempB !== null) {
        hudTrackTemp.innerText = `${trackTempA.toFixed(1)}°C / ${trackTempB.toFixed(1)}°C`;
      } else {
        hudTrackTemp.innerText = `${trackTempA.toFixed(1)}°C`;
      }
    } else {
      hudTrackTemp.innerText = "-- °C";
    }
  }

  if (hudAmbTemp) {
    const ambTempA = sampleA.aTemp;
    const ambTempB = sampleB ? sampleB.aTemp : null;
    if (ambTempA !== undefined && ambTempA !== null) {
      if (ambTempB !== undefined && ambTempB !== null) {
        hudAmbTemp.innerText = `${ambTempA.toFixed(1)}°C / ${ambTempB.toFixed(1)}°C`;
      } else {
        hudAmbTemp.innerText = `${ambTempA.toFixed(1)}°C`;
      }
    } else {
      hudAmbTemp.innerText = "-- °C";
    }
  }

  // Active event warning banner
  const eventBanner = document.getElementById("event-warning-banner");
  const eventTitle = document.getElementById("event-warning-title");
  const eventDesc = document.getElementById("event-warning-desc");

  if (eventBanner && eventTitle && eventDesc) {
    if (sampleA.lock && sampleA.lock > 0) {
      eventBanner.classList.remove("hidden");
      eventBanner.style.backgroundColor = "rgba(239, 68, 68, 0.2)";
      eventBanner.style.borderColor = "rgba(239, 68, 68, 0.6)";
      eventBanner.style.color = "#ef4444";
      eventTitle.innerText = "TRAVAMENTO DE RODA (LOCKUP)";
      eventDesc.innerText = `Intensidade: ${sampleA.lock.toFixed(2)}`;
    } else if (sampleA.ove && sampleA.ove > 0) {
      eventBanner.classList.remove("hidden");
      eventBanner.style.backgroundColor = "rgba(236, 72, 153, 0.2)";
      eventBanner.style.borderColor = "rgba(236, 72, 153, 0.6)";
      eventBanner.style.color = "#ec4899";
      eventTitle.innerText = "SOBRESTERÇO (OVERSTEER)";
      eventDesc.innerText = `Ângulo de Slip Traseiro: ${sampleA.ove.toFixed(1)}°`;
    } else if (sampleA.und && sampleA.und > 0) {
      eventBanner.classList.remove("hidden");
      eventBanner.style.backgroundColor = "rgba(255, 123, 0, 0.2)";
      eventBanner.style.borderColor = "rgba(255, 123, 0, 0.6)";
      eventBanner.style.color = "#ff7b00";
      eventTitle.innerText = "SUBESTERÇO (UNDERSTEER)";
      eventDesc.innerText = `Desvio de Guinada: ${sampleA.und.toFixed(2)} rad/s`;
    } else if (sampleA.spin && sampleA.spin > 0) {
      eventBanner.classList.remove("hidden");
      eventBanner.style.backgroundColor = "rgba(250, 204, 21, 0.2)";
      eventBanner.style.borderColor = "rgba(250, 204, 21, 0.6)";
      eventBanner.style.color = "#facc15";
      eventTitle.innerText = "PATINAMENTO (WHEELSPIN)";
      eventDesc.innerText = `Intensidade: ${sampleA.spin.toFixed(2)}`;
    } else {
      eventBanner.classList.add("hidden");
    }
  }
}

// Track Map Canvas Zoom/Pan Logic
function resetZoomFit(): void {
  if (!activeLapA || !trackCanvas) return;
  const samples = activeLapA.samples;
  
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
  if (!activeLapA || !trackCanvas) return;
  const samples = activeLapA.samples.slice(startIdx, endIdx + 1);
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

let startClickX = 0;
let startClickY = 0;

// Canvas Panning Handlers
if (trackCanvas) {
  trackCanvas.addEventListener("mousedown", (e) => {
    isPanning = true;
    startPanX = e.clientX - mapOffsetX;
    startPanY = e.clientY - mapOffsetY;
    startClickX = e.clientX;
    startClickY = e.clientY;
  });

  window.addEventListener("mousemove", (e) => {
    if (isPanning) {
      mapOffsetX = e.clientX - startPanX;
      mapOffsetY = e.clientY - startPanY;
      drawTrackMap();
    }
  });

  window.addEventListener("mouseup", (e) => {
    if (isPanning) {
      isPanning = false;
      
      const dx = e.clientX - startClickX;
      const dy = e.clientY - startClickY;
      const dist = Math.sqrt(dx * dx + dy * dy);
      
      if (dist < 5.0) {
        handleCanvasClick(e);
      }
    }
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

function handleCanvasClick(e: MouseEvent): void {
  if (!activeLapA || !trackCanvas) return;
  
  const rect = trackCanvas.getBoundingClientRect();
  const clickX = e.clientX - rect.left;
  const clickY = e.clientY - rect.top;
  
  let closestSampleIndex = -1;
  let minDistance = 15.0; // 15px radius for warning pins
  
  activeLapA.samples.forEach((s, idx) => {
    if (idx % 2 !== 0) return;
    if (!s.und && !s.ove && !s.spin && !s.lock) return;
    
    const screenX = s.x * mapZoom + mapOffsetX;
    const screenY = s.z * mapZoom + mapOffsetY;
    
    const dx = clickX - screenX;
    const dy = clickY - screenY;
    const dist = Math.sqrt(dx * dx + dy * dy);
    
    if (dist < minDistance) {
      minDistance = dist;
      closestSampleIndex = idx;
    }
  });
  
  if (closestSampleIndex !== -1) {
    currentSampleIndex = closestSampleIndex;
    fractionalSampleIndex = closestSampleIndex;
    if (scrubber) {
      scrubber.value = closestSampleIndex.toString();
    }
    updateSelectedPoint();
    drawTrackMap();
    drawCharts();
  }
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
  if (!sessionData || !activeLapA || !trackCanvas) return;
  const ctx = trackCanvas.getContext("2d");
  if (!ctx) return;

  // Clear
  ctx.clearRect(0, 0, trackCanvas.width, trackCanvas.height);

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

  // Helper to draw actual driven trajectory line colored by Throttle/Brake or Speed
  const drawTrajectory = (samples: TelemetrySample[], isPrimary: boolean) => {
    ctx.lineWidth = isPrimary ? 3.5 : 2.0;
    if (!isPrimary) {
      ctx.setLineDash([4, 4]);
    } else {
      ctx.setLineDash([]);
    }

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
          ctx.strokeStyle = isPrimary 
            ? `rgba(239, 68, 68, ${0.4 + s1.brk * 0.6})`
            : `rgba(239, 68, 68, ${0.2 + s1.brk * 0.4})`; // Red
        } else if (s1.thr > 0.15) {
          ctx.strokeStyle = isPrimary 
            ? `rgba(16, 185, 129, ${0.4 + s1.thr * 0.6})`
            : `rgba(16, 185, 129, ${0.2 + s1.thr * 0.4})`; // Green
        } else {
          ctx.strokeStyle = isPrimary 
            ? "rgba(156, 163, 175, 0.4)" 
            : "rgba(156, 163, 175, 0.2)"; // Gray
        }
      } else {
        // Speed Gradient (Red = Slow, Green = Fast)
        const ratio = (s1.speed - minSpeed) / (maxSpeed - minSpeed || 1);
        const r = Math.round(239 - ratio * (239 - 16));
        const g = Math.round(68 + ratio * (185 - 68));
        const b = Math.round(68 + ratio * (129 - 68));
        ctx.strokeStyle = isPrimary 
          ? `rgba(${r}, ${g}, ${b}, 1.0)`
          : `rgba(${r}, ${g}, ${b}, 0.5)`;
      }
      ctx.stroke();
    }
    ctx.setLineDash([]);
  };

  // Draw Lap A (primary)
  drawTrajectory(activeLapA.samples, true);

  // Draw Lap B if comparing
  if (compareMode && activeLapB) {
    drawTrajectory(activeLapB.samples, false);
  }

  // 3. Draw Loss of Grip / Warnings Indicators for Lap A
  activeLapA.samples.forEach((s, idx) => {
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

  // 4. Draw current car scrubber position marker for Lap A (blue dot)
  const currentSampleA = activeLapA.samples[currentSampleIndex];
  if (currentSampleA) {
    const markerX = currentSampleA.x * mapZoom + mapOffsetX;
    const markerY = currentSampleA.z * mapZoom + mapOffsetY;

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

  // 5. Draw current car scrubber position marker for Lap B if comparing (pink dot)
  if (compareMode && activeLapB) {
    const ratio = currentSampleIndex / (activeLapA.samples.length - 1 || 1);
    const idxB = Math.round(ratio * (activeLapB.samples.length - 1));
    const currentSampleB = activeLapB.samples[idxB];
    if (currentSampleB) {
      const markerX = currentSampleB.x * mapZoom + mapOffsetX;
      const markerY = currentSampleB.z * mapZoom + mapOffsetY;

      // Draw outer halo
      ctx.fillStyle = "rgba(236, 72, 153, 0.35)";
      ctx.beginPath();
      ctx.arc(markerX, markerY, 10, 0, 2 * Math.PI);
      ctx.fill();

      // Draw solid center dot
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 1.5;
      ctx.fillStyle = "#ec4899"; // Pink
      ctx.beginPath();
      ctx.arc(markerX, markerY, 5, 0, 2 * Math.PI);
      ctx.fill();
      ctx.stroke();
    }
  }
}

// Render the detailed multi-channel line charts on canvas
function drawCharts(): void {
  if (!activeLapA || !telemetryCanvas) return;
  const ctx = telemetryCanvas.getContext("2d");
  if (!ctx) return;

  const w = telemetryCanvas.width;
  const h = telemetryCanvas.height;
  ctx.clearRect(0, 0, w, h);

  const samplesA = activeLapA.samples;
  const totalSamplesA = samplesA.length;
  if (totalSamplesA === 0) return;

  const samplesB = (compareMode && activeLapB) ? activeLapB.samples : null;
  const totalSamplesB = samplesB ? samplesB.length : 0;

  // Find max speed across both laps
  let maxSpeed = 1;
  samplesA.forEach(s => {
    if (s.speed > maxSpeed) maxSpeed = s.speed;
  });
  if (samplesB) {
    samplesB.forEach(s => {
      if (s.speed > maxSpeed) maxSpeed = s.speed;
    });
  }

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

  // Draw helper for curves
  const drawChannelCurve = (
    samples: TelemetrySample[],
    getValue: (s: TelemetrySample) => number,
    maxVal: number,
    color: string,
    lineWidth: number,
    isPrimary: boolean,
    heightScale: number,
    yOffset: number
  ) => {
    ctx.strokeStyle = color;
    ctx.lineWidth = lineWidth;
    if (!isPrimary) {
      ctx.setLineDash([4, 4]);
    } else {
      ctx.setLineDash([]);
    }

    const total = samples.length;
    ctx.beginPath();
    for (let i = 0; i < total; i++) {
      const x = (i / total) * w;
      const val = getValue(samples[i]);
      const y = h - (val / maxVal) * heightScale - yOffset;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    ctx.setLineDash([]);
  };

  // Draw Speed Curves
  drawChannelCurve(samplesA, s => s.speed, maxSpeed, "#06b6d4", 2.0, true, h - 20, 10);
  if (samplesB) {
    drawChannelCurve(samplesB, s => s.speed, maxSpeed, "rgba(6, 182, 212, 0.5)", 1.5, false, h - 20, 10);
  }

  // Draw Throttle Curves
  drawChannelCurve(samplesA, s => s.thr, 1.0, "rgba(16, 185, 129, 0.65)", 1.5, true, h / 3, 10);
  if (samplesB) {
    drawChannelCurve(samplesB, s => s.thr, 1.0, "rgba(16, 185, 129, 0.35)", 1.2, false, h / 3, 10);
  }

  // Draw Brake Curves
  drawChannelCurve(samplesA, s => s.brk, 1.0, "rgba(239, 68, 68, 0.7)", 1.5, true, h / 3, 10);
  if (samplesB) {
    drawChannelCurve(samplesB, s => s.brk, 1.0, "rgba(239, 68, 68, 0.35)", 1.2, false, h / 3, 10);
  }

  // Draw Steer Curves
  const centerY = h - (h / 6) - 10;
  
  ctx.strokeStyle = "rgba(245, 158, 11, 0.4)";
  ctx.lineWidth = 1.2;
  ctx.beginPath();
  for (let i = 0; i < totalSamplesA; i++) {
    const x = (i / totalSamplesA) * w;
    const y = centerY - (samplesA[i].steer * (h / 8));
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();

  if (samplesB) {
    ctx.strokeStyle = "rgba(245, 158, 11, 0.25)";
    ctx.lineWidth = 1.0;
    ctx.setLineDash([4, 4]);
    ctx.beginPath();
    for (let i = 0; i < totalSamplesB; i++) {
      const x = (i / totalSamplesB) * w;
      const y = centerY - (samplesB[i].steer * (h / 8));
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // Draw vertical scrubber line
  const cursorX = (currentSampleIndex / totalSamplesA) * w;
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
