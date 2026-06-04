"use strict";
(() => {
  // overlay/review.ts
  var sessionData = null;
  var currentSampleIndex = 0;
  var trackMapColorMode = "THR";
  var mapZoom = 1;
  var mapOffsetX = 0;
  var mapOffsetY = 0;
  var isPanning = false;
  var startPanX = 0;
  var startPanY = 0;
  var fileLoader = document.getElementById("file-loader");
  var dropZone = document.getElementById("drop-zone");
  var emptyState = document.getElementById("dashboard-empty");
  var mainDashboard = document.getElementById("dashboard-main");
  var sumTrack = document.getElementById("sum-track");
  var sumCar = document.getElementById("sum-car");
  var sumLapTime = document.getElementById("sum-laptime");
  var sumDate = document.getElementById("sum-date");
  var sumS1 = document.getElementById("sum-s1");
  var sumS2 = document.getElementById("sum-s2");
  var sumS3 = document.getElementById("sum-s3");
  var svgSteering = document.getElementById("svg-steering");
  var hudSteer = document.getElementById("hud-steer");
  var hudThr = document.getElementById("hud-thr");
  var hudBrk = document.getElementById("hud-brk");
  var hudClt = document.getElementById("hud-clt");
  var lblThr = document.getElementById("lbl-thr");
  var lblBrk = document.getElementById("lbl-brk");
  var lblClt = document.getElementById("lbl-clt");
  var hudSpeed = document.getElementById("hud-speed");
  var hudGear = document.getElementById("hud-gear");
  var hudRpm = document.getElementById("hud-rpm");
  var tFL = document.getElementById("t-fl");
  var tFR = document.getElementById("t-fr");
  var tRL = document.getElementById("t-rl");
  var tRR = document.getElementById("t-rr");
  var aiPromptBox = document.getElementById("ai-prompt-box");
  var btnCopyPrompt = document.getElementById("btn-copy-prompt");
  var scrubber = document.getElementById("telemetry-scrubber");
  var scrubberTime = document.getElementById("scrubber-time");
  var trackCanvas = document.getElementById("track-canvas");
  var telemetryCanvas = document.getElementById("telemetry-canvas");
  var btnZoomIn = document.getElementById("btn-zoom-in");
  var btnZoomOut = document.getElementById("btn-zoom-out");
  var btnZoomFit = document.getElementById("btn-zoom-fit");
  var btnToggleColor = document.getElementById("btn-toggle-color");
  var cornerRowsAnchor = document.getElementById("corner-rows-anchor");
  function formatTime(ms) {
    if (isNaN(ms) || ms <= 0) return "--:--.---";
    const minutes = Math.floor(ms / 6e4);
    const seconds = Math.floor(ms % 6e4 / 1e3);
    const milliseconds = Math.floor(ms % 1e3);
    return `${minutes}:${seconds.toString().padStart(2, "0")}.${milliseconds.toString().padStart(3, "0")}`;
  }
  if (fileLoader) {
    fileLoader.addEventListener("change", (e) => {
      const file = e.target.files?.[0];
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
  function handleFile(file) {
    const reader = new FileReader();
    reader.onload = (e) => {
      try {
        const json = JSON.parse(e.target?.result);
        if (json && json.metadata && json.samples && json.samples.length > 0) {
          sessionData = json;
          loadDashboard();
        } else {
          alert("O arquivo selecionado n\xE3o parece ser um arquivo de telemetria v\xE1lido.");
        }
      } catch (err) {
        console.error(err);
        alert("Erro ao ler o arquivo JSON de telemetria.");
      }
    };
    reader.readAsText(file);
  }
  function loadDashboard() {
    if (!sessionData) return;
    emptyState?.classList.add("hidden");
    mainDashboard?.classList.remove("hidden");
    if (sumTrack) sumTrack.innerText = sessionData.metadata.trackName + (sessionData.metadata.trackLayout ? ` (${sessionData.metadata.trackLayout})` : "");
    if (sumCar) sumCar.innerText = sessionData.metadata.carName;
    if (sumLapTime) sumLapTime.innerText = formatTime(sessionData.metadata.lapTimeMs);
    if (sumDate) sumDate.innerText = sessionData.metadata.timestamp;
    const sectors = sessionData.metadata.sectorTimes || [];
    if (sumS1) sumS1.innerText = sectors[0] ? formatTime(sectors[0]) : "--:--.---";
    if (sumS2) sumS2.innerText = sectors[1] ? formatTime(sectors[1]) : "--:--.---";
    if (sumS3) sumS3.innerText = sectors[2] ? formatTime(sectors[2]) : "--:--.---";
    if (scrubber) {
      scrubber.max = (sessionData.samples.length - 1).toString();
      scrubber.value = "0";
    }
    currentSampleIndex = 0;
    updateSelectedPoint();
    renderCornerTable();
    generateAIPrompt();
    resetZoomFit();
    resizeCanvases();
    drawTrackMap();
    drawCharts();
  }
  function renderCornerTable() {
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
        document.querySelectorAll(".corner-row").forEach((r) => r.classList.remove("selected"));
        row.classList.add("selected");
        if (c.startIndex !== void 0 && c.endIndex !== void 0) {
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
  function generateAIPrompt() {
    if (!sessionData || !aiPromptBox) return;
    let underCount = 0;
    let overCount = 0;
    let spinCount = 0;
    let lockCount = 0;
    sessionData.samples.forEach((s) => {
      if (s.und && s.und > 0) underCount++;
      if (s.ove && s.ove > 0) overCount++;
      if (s.spin && s.spin > 0) spinCount++;
      if (s.lock && s.lock > 0) lockCount++;
    });
    const sectors = sessionData.metadata.sectorTimes || [];
    const s1Str = sectors[0] ? formatTime(sectors[0]) : "N/D";
    const s2Str = sectors[1] ? formatTime(sectors[1]) : "N/D";
    const s3Str = sectors[2] ? formatTime(sectors[2]) : "N/D";
    let cornerDetails = "";
    sessionData.corners.forEach((c, idx) => {
      cornerDetails += `- Curva ${idx + 1}: Nota ${c.grade} (V. M\xEDnima: ${Math.round(c.minSpeedKmh)} km/h | Ideal: ${Math.round(c.targetSpeedKmh)} km/h). Trail braking: ${c.trailScore}%. Uso do Grip: ${c.gripUtilization}%. Timing do \xC1pice: ${c.apexTiming}.
`;
    });
    const prompt = `Voc\xEA \xE9 um engenheiro de pista e coach de pilotagem profissional de automobilismo.
Analise a telemetria desta volta no simulador Assetto Corsa para me ajudar a melhorar meu tempo de volta.

=== Informa\xE7\xF5es Gerais ===
- Carro: ${sessionData.metadata.carName} (${sessionData.metadata.carId})
- Pista: ${sessionData.metadata.trackName} (${sessionData.metadata.trackId} - ${sessionData.metadata.trackLayout})
- Tempo da Volta: ${formatTime(sessionData.metadata.lapTimeMs)}
- Tempos de Setor: Setor 1: ${s1Str} | Setor 2: ${s2Str} | Setor 3: ${s3Str}
- Acelera\xE7\xE3o Lateral M\xE1xima: ${sessionData.metadata.bestLatG} G
- Desacelera\xE7\xE3o M\xE1xima: ${sessionData.metadata.bestDecelG} G

=== Instantes de Perda de Ader\xEAncia (Frequ\xEAncia a 10Hz) ===
- Subester\xE7o (Understeer): ${underCount} instantes amostrados (dianteira escorregando por entrar r\xE1pido demais ou ester\xE7ar em excesso)
- Sobrester\xE7o (Oversteer): ${overCount} instantes amostrados (traseira deslizando/contra-ester\xE7o)
- Patinamento (Wheelspin): ${spinCount} instantes amostrados (acelera\xE7\xE3o agressiva na sa\xEDda de curva)
- Travamento de Rodas (Lockup): ${lockCount} instantes amostrados (excesso de press\xE3o de freio na entrada)

=== Desempenho Curva por Curva ===
${cornerDetails}

Por favor, fa\xE7a um review detalhado sobre o meu estilo de pilotagem. Destaque quais curvas ou setores me custaram mais tempo, analise o meu trail braking e uso de grip nas curvas com notas mais baixas, e me d\xEA dicas acion\xE1veis de pilotagem para que eu consiga abaixar meu tempo de volta nesta pista.`;
    aiPromptBox.value = prompt;
  }
  if (btnCopyPrompt) {
    btnCopyPrompt.addEventListener("click", () => {
      if (aiPromptBox) {
        aiPromptBox.select();
        document.execCommand("copy");
        const originalText = btnCopyPrompt.innerHTML;
        btnCopyPrompt.innerHTML = "<span>\u2705</span> Prompt Copiado!";
        setTimeout(() => {
          btnCopyPrompt.innerHTML = originalText;
        }, 2e3);
      }
    });
  }
  if (scrubber) {
    scrubber.addEventListener("input", (e) => {
      currentSampleIndex = parseInt(e.target.value);
      updateSelectedPoint();
      drawTrackMap();
      drawCharts();
    });
  }
  function updateSelectedPoint() {
    if (!sessionData) return;
    const sample = sessionData.samples[currentSampleIndex];
    if (!sample) return;
    if (scrubberTime) scrubberTime.innerText = formatTime(sample.t);
    if (hudSpeed) hudSpeed.innerHTML = `${Math.round(sample.speed)} <span style="font-size: 10px; color: var(--text-muted);">km/h</span>`;
    if (hudGear) {
      const g = sample.gear;
      if (g === -1) hudGear.innerText = "R";
      else if (g === 0) hudGear.innerText = "N";
      else hudGear.innerText = g.toString();
    }
    if (hudRpm) hudRpm.innerText = Math.round(sample.rpm).toString();
    if (hudThr) hudThr.style.width = `${sample.thr * 100}%`;
    if (hudBrk) hudBrk.style.width = `${sample.brk * 100}%`;
    if (hudClt) hudClt.style.width = `${sample.clt * 100}%`;
    if (lblThr) lblThr.innerText = `${Math.round(sample.thr * 100)}%`;
    if (lblBrk) lblBrk.innerText = `${Math.round(sample.brk * 100)}%`;
    if (lblClt) lblClt.innerText = `${Math.round(sample.clt * 100)}%`;
    if (svgSteering) {
      const rotationAngle = sample.steer * 360;
      svgSteering.style.transform = `rotate(${rotationAngle}deg)`;
    }
    if (hudSteer) hudSteer.innerText = `${Math.round(sample.steer * 450)}\xB0`;
    const tyres = ["fl", "fr", "rl", "rr"];
    const elements = [tFL, tFR, tRL, tRR];
    elements.forEach((el, idx) => {
      if (!el) return;
      const slip = sample.slpA[idx];
      el.innerText = `${tyres[idx].toUpperCase()}: ${slip.toFixed(1)}\xB0`;
      const absSlip = Math.abs(slip);
      el.className = "tyre-dot";
      if (absSlip > 7 * 1.4) {
        el.style.backgroundColor = "rgba(239, 68, 68, 0.25)";
        el.style.borderColor = "rgba(239, 68, 68, 0.6)";
        el.style.color = "#ef4444";
      } else if (absSlip > 7 * 0.9) {
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
  function resetZoomFit() {
    if (!sessionData || !trackCanvas) return;
    const samples = sessionData.samples;
    let minX = Infinity, maxX = -Infinity;
    let minZ = Infinity, maxZ = -Infinity;
    samples.forEach((s) => {
      if (s.x < minX) minX = s.x;
      if (s.x > maxX) maxX = s.x;
      if (s.z < minZ) minZ = s.z;
      if (s.z > maxZ) maxZ = s.z;
    });
    const width = maxX - minX;
    const height = maxZ - minZ;
    mapZoom = Math.min(trackCanvas.width * 0.85 / width, trackCanvas.height * 0.85 / height);
    mapOffsetX = trackCanvas.width / 2 - (minX + width / 2) * mapZoom;
    mapOffsetY = trackCanvas.height / 2 - (minZ + height / 2) * mapZoom;
  }
  function focusMapOnSamples(startIdx, endIdx) {
    if (!sessionData || !trackCanvas) return;
    const samples = sessionData.samples.slice(startIdx, endIdx + 1);
    if (samples.length === 0) return;
    let minX = Infinity, maxX = -Infinity;
    let minZ = Infinity, maxZ = -Infinity;
    samples.forEach((s) => {
      if (s.x < minX) minX = s.x;
      if (s.x > maxX) maxX = s.x;
      if (s.z < minZ) minZ = s.z;
      if (s.z > maxZ) maxZ = s.z;
    });
    const width = maxX - minX;
    const height = maxZ - minZ;
    mapZoom = Math.min(trackCanvas.width * 0.6 / Math.max(10, width), trackCanvas.height * 0.6 / Math.max(10, height));
    mapOffsetX = trackCanvas.width / 2 - (minX + width / 2) * mapZoom;
    mapOffsetY = trackCanvas.height / 2 - (minZ + height / 2) * mapZoom;
    drawTrackMap();
  }
  function resizeCanvases() {
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
      const mouseX = e.offsetX;
      const mouseY = e.offsetY;
      const wheel = e.deltaY < 0 ? 1 : -1;
      const zoomFactor = Math.exp(wheel * zoomIntensity);
      const worldX = (mouseX - mapOffsetX) / mapZoom;
      const worldY = (mouseY - mapOffsetY) / mapZoom;
      mapZoom *= zoomFactor;
      mapZoom = Math.max(0.1, Math.min(100, mapZoom));
      mapOffsetX = mouseX - worldX * mapZoom;
      mapOffsetY = mouseY - worldY * mapZoom;
      drawTrackMap();
    });
  }
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
  function drawTrackMap() {
    if (!sessionData || !trackCanvas) return;
    const ctx = trackCanvas.getContext("2d");
    if (!ctx) return;
    ctx.clearRect(0, 0, trackCanvas.width, trackCanvas.height);
    const samples = sessionData.samples;
    const trackMap = sessionData.trackMap;
    if (trackMap && trackMap.left && trackMap.left.length > 0) {
      ctx.lineWidth = 1;
      ctx.strokeStyle = "rgba(255, 255, 255, 0.12)";
      ctx.beginPath();
      trackMap.left.forEach((pt, i) => {
        const screenX = pt[0] * mapZoom + mapOffsetX;
        const screenY = pt[1] * mapZoom + mapOffsetY;
        if (i === 0) ctx.moveTo(screenX, screenY);
        else ctx.lineTo(screenX, screenY);
      });
      ctx.closePath();
      ctx.stroke();
      ctx.beginPath();
      trackMap.right.forEach((pt, i) => {
        const screenX = pt[0] * mapZoom + mapOffsetX;
        const screenY = pt[1] * mapZoom + mapOffsetY;
        if (i === 0) ctx.moveTo(screenX, screenY);
        else ctx.lineTo(screenX, screenY);
      });
      ctx.closePath();
      ctx.stroke();
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
    ctx.lineWidth = 3.5;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    let maxSpeed = 1;
    let minSpeed = Infinity;
    if (trackMapColorMode === "SPD") {
      samples.forEach((s) => {
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
        if (s1.brk > 0.1) {
          ctx.strokeStyle = `rgba(239, 68, 68, ${0.4 + s1.brk * 0.6})`;
        } else if (s1.thr > 0.15) {
          ctx.strokeStyle = `rgba(16, 185, 129, ${0.4 + s1.thr * 0.6})`;
        } else {
          ctx.strokeStyle = "rgba(156, 163, 175, 0.4)";
        }
      } else {
        const ratio = (s1.speed - minSpeed) / (maxSpeed - minSpeed || 1);
        const r = Math.round(239 - ratio * (239 - 16));
        const g = Math.round(68 + ratio * (185 - 68));
        const b = Math.round(68 + ratio * (129 - 68));
        ctx.strokeStyle = `rgb(${r}, ${g}, ${b})`;
      }
      ctx.stroke();
    }
    samples.forEach((s, idx) => {
      if (idx % 2 !== 0) return;
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
    const currentSample = samples[currentSampleIndex];
    if (currentSample) {
      const markerX = currentSample.x * mapZoom + mapOffsetX;
      const markerY = currentSample.z * mapZoom + mapOffsetY;
      ctx.fillStyle = "rgba(59, 130, 246, 0.35)";
      ctx.beginPath();
      ctx.arc(markerX, markerY, 12, 0, 2 * Math.PI);
      ctx.fill();
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 2;
      ctx.fillStyle = "#3b82f6";
      ctx.beginPath();
      ctx.arc(markerX, markerY, 6, 0, 2 * Math.PI);
      ctx.fill();
      ctx.stroke();
    }
  }
  function drawCharts() {
    if (!sessionData || !telemetryCanvas) return;
    const ctx = telemetryCanvas.getContext("2d");
    if (!ctx) return;
    const w = telemetryCanvas.width;
    const h = telemetryCanvas.height;
    ctx.clearRect(0, 0, w, h);
    const samples = sessionData.samples;
    const totalSamples = samples.length;
    if (totalSamples === 0) return;
    let maxSpeed = 1;
    samples.forEach((s) => {
      if (s.speed > maxSpeed) maxSpeed = s.speed;
    });
    ctx.strokeStyle = "rgba(255, 255, 255, 0.05)";
    ctx.lineWidth = 1;
    const linesCount = 4;
    for (let i = 1; i < linesCount; i++) {
      const y = h / linesCount * i;
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
      ctx.stroke();
    }
    ctx.strokeStyle = "#06b6d4";
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < totalSamples; i++) {
      const x = i / totalSamples * w;
      const y = h - samples[i].speed / maxSpeed * (h - 20) - 10;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    ctx.strokeStyle = "rgba(16, 185, 129, 0.65)";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (let i = 0; i < totalSamples; i++) {
      const x = i / totalSamples * w;
      const y = h - samples[i].thr * (h / 3) - 10;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    ctx.strokeStyle = "rgba(239, 68, 68, 0.7)";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    for (let i = 0; i < totalSamples; i++) {
      const x = i / totalSamples * w;
      const y = h - samples[i].brk * (h / 3) - 10;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    ctx.strokeStyle = "rgba(245, 158, 11, 0.4)";
    ctx.lineWidth = 1.2;
    ctx.beginPath();
    const centerY = h - h / 6 - 10;
    for (let i = 0; i < totalSamples; i++) {
      const x = i / totalSamples * w;
      const y = centerY - samples[i].steer * (h / 8);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
    const cursorX = currentSampleIndex / totalSamples * w;
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(cursorX, 0);
    ctx.lineTo(cursorX, h);
    ctx.stroke();
    ctx.fillStyle = "#9ca3af";
    ctx.font = "9px 'JetBrains Mono', monospace";
    ctx.fillText("Velocidade (km/h)", 10, 15);
    ctx.fillStyle = "rgba(16, 185, 129, 0.9)";
    ctx.fillText("Acel.", 10, 27);
    ctx.fillStyle = "rgba(239, 68, 68, 0.9)";
    ctx.fillText("Freio", 50, 27);
    ctx.fillStyle = "rgba(245, 158, 11, 0.8)";
    ctx.fillText("Ester\xE7o", 90, 27);
  }
})();
