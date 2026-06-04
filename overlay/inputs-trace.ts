interface InputSample {
  throttle: number;
  brake: number;
  steer: number;
}

const inputHistory: InputSample[] = [];
const MAX_INPUT_HISTORY = 120; // 120 frames at 60Hz (~2 seconds)

let traceCanvas: HTMLCanvasElement | null = null;
let traceCtx: CanvasRenderingContext2D | null = null;

export function initTrace(): void {
  traceCanvas = document.getElementById("trace-canvas") as HTMLCanvasElement;
  if (traceCanvas) {
    traceCtx = traceCanvas.getContext("2d");
  }
}

export function drawInputsTrace(throttle: number, brake: number, steer: number): void {
  if (!traceCanvas || !traceCtx) {
    initTrace();
    if (!traceCanvas || !traceCtx) return;
  }

  // Store in history buffer
  inputHistory.push({ throttle, brake, steer });
  if (inputHistory.length > MAX_INPUT_HISTORY) {
    inputHistory.shift();
  }

  traceCtx.clearRect(0, 0, traceCanvas.width, traceCanvas.height);
  const w = traceCanvas.width;
  const h = traceCanvas.height;

  // Steering center line (dark gray)
  traceCtx.strokeStyle = "rgba(255, 255, 255, 0.08)";
  traceCtx.lineWidth = 1;
  traceCtx.beginPath();
  traceCtx.moveTo(0, h / 2);
  traceCtx.lineTo(w, h / 2);
  traceCtx.stroke();

  // Draw steer angle (electric blue)
  traceCtx.strokeStyle = "rgba(59, 130, 246, 0.7)";
  traceCtx.lineWidth = 1.2;
  traceCtx.beginPath();
  for (let i = 0; i < inputHistory.length; i++) {
    const x = (i / MAX_INPUT_HISTORY) * w;
    const val = inputHistory[i].steer; // -1.0 to 1.0
    const y = h / 2 + (val * (h / 2 - 3));
    if (i === 0) traceCtx.moveTo(x, y);
    else traceCtx.lineTo(x, y);
  }
  traceCtx.stroke();

  // Draw brake input (red)
  traceCtx.strokeStyle = "rgba(239, 68, 68, 0.85)";
  traceCtx.lineWidth = 1.5;
  traceCtx.beginPath();
  for (let i = 0; i < inputHistory.length; i++) {
    const x = (i / MAX_INPUT_HISTORY) * w;
    const val = inputHistory[i].brake; // 0.0 to 1.0
    const y = h - (val * (h - 6)) - 3;
    if (i === 0) traceCtx.moveTo(x, y);
    else traceCtx.lineTo(x, y);
  }
  traceCtx.stroke();

  // Draw throttle input (green)
  traceCtx.strokeStyle = "rgba(16, 185, 129, 0.85)";
  traceCtx.lineWidth = 1.5;
  traceCtx.beginPath();
  for (let i = 0; i < inputHistory.length; i++) {
    const x = (i / MAX_INPUT_HISTORY) * w;
    const val = inputHistory[i].throttle; // 0.0 to 1.0
    const y = h - (val * (h - 6)) - 3;
    if (i === 0) traceCtx.moveTo(x, y);
    else traceCtx.lineTo(x, y);
  }
  traceCtx.stroke();
}
