import { G_SCALE } from './config';
import { state } from './state';

interface GGPoint {
  x: number;
  y: number;
}

const ggHistory: GGPoint[] = [];
const MAX_GG_HISTORY = 40;

let canvas: HTMLCanvasElement | null = null;
let ctx: CanvasRenderingContext2D | null = null;

// Initialize DOM elements lazily to ensure DOM is ready
export function initGG(): void {
  canvas = document.getElementById("gg-canvas") as HTMLCanvasElement;
  if (canvas) {
    ctx = canvas.getContext("2d");
  }
}

export function drawGGCanvas(currentAccX: number = 0, currentAccZ: number = 0): void {
  if (!canvas || !ctx) return;

  ctx.clearRect(0, 0, canvas.width, canvas.height);
  const cx = canvas.width / 2;
  const cy = canvas.height / 2;

  // Draw reference circles (1G, 1.5G)
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

  // Axes
  ctx.strokeStyle = "rgba(255, 255, 255, 0.05)";
  ctx.beginPath();
  ctx.moveTo(0, cy); ctx.lineTo(canvas.width, cy);
  ctx.moveTo(cx, 0); ctx.lineTo(cx, canvas.height);
  ctx.stroke();

  // Draw Maximum Session Grip Envelope (dotted ellipse)
  ctx.strokeStyle = "rgba(239, 68, 68, 0.22)";
  ctx.lineWidth = 1.2;
  ctx.setLineDash([2, 3]);
  
  const rx = state.maxObservedLatG * G_SCALE;
  const ryAccel = state.maxObservedAccelG * G_SCALE;
  const ryDecel = state.maxObservedDecelG * G_SCALE;

  // Top (Acceleration, negative Z)
  ctx.beginPath();
  ctx.ellipse(cx, cy, rx, ryAccel, 0, Math.PI, 2 * Math.PI);
  ctx.stroke();

  // Bottom (Braking, positive Z)
  ctx.beginPath();
  ctx.ellipse(cx, cy, rx, ryDecel, 0, 0, Math.PI);
  ctx.stroke();
  
  ctx.setLineDash([]); // Reset line dash

  // Write instantaneous G usage in the bottom-left corner
  ctx.fillStyle = "rgba(255, 255, 255, 0.35)";
  ctx.font = "8px 'Outfit', sans-serif";
  ctx.textAlign = "left";
  const currentTotalG = Math.sqrt(currentAccX * currentAccX + currentAccZ * currentAccZ);
  const maxPossibleG = currentAccZ < 0 
    ? Math.sqrt(state.maxObservedLatG * state.maxObservedLatG + state.maxObservedAccelG * state.maxObservedAccelG) 
    : Math.sqrt(state.maxObservedLatG * state.maxObservedLatG + state.maxObservedDecelG * state.maxObservedDecelG);
  const utilization = Math.min(100, Math.round((currentTotalG / Math.max(0.1, maxPossibleG)) * 100));
  ctx.fillText(`USO: ${utilization}%`, 6, canvas.height - 6);
}

export function updateGGDiagram(accX: number, accZ: number): void {
  if (!canvas || !ctx) {
    // Attempt lazy init if not initialized
    initGG();
    if (!canvas || !ctx) return;
  }

  const cx = canvas.width / 2;
  const cy = canvas.height / 2;

  // Invert X because lateral G forces are opposite to the physical corner direction
  const px = cx - accX * G_SCALE;
  const py = cy + accZ * G_SCALE; // Negative accZ is acceleration, positive is braking

  // Add to history
  ggHistory.push({ x: px, y: py });
  if (ggHistory.length > MAX_GG_HISTORY) {
    ggHistory.shift();
  }

  // Redraw G-G canvas
  drawGGCanvas(accX, accZ);

  // Draw fading historical trail
  for (let i = 0; i < ggHistory.length; i++) {
    const pt = ggHistory[i];
    const alpha = (i / ggHistory.length) * 0.4;
    ctx.fillStyle = `rgba(59, 130, 246, ${alpha})`;
    ctx.beginPath();
    ctx.arc(pt.x, pt.y, 2, 0, 2 * Math.PI);
    ctx.fill();
  }

  // Draw highlighted current point
  ctx.fillStyle = "#60a5fa";
  ctx.shadowColor = "#3b82f6";
  ctx.shadowBlur = 8;
  ctx.beginPath();
  ctx.arc(px, py, 5, 0, 2 * Math.PI);
  ctx.fill();
  ctx.shadowBlur = 0; // Reset shadow
}
