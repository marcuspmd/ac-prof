import { SLIP_ANGLE_PEAK } from './config';

// Update tyre visual state based on its current slip angle
export function setTyreVisual(element: HTMLElement, slipAngle: number): void {
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

// Monitor front steering slip (scrub) and apply a visual warning if front tires are overloading
export function checkSteeringScrub(speed: number, steer: number, slipFL: number, slipFR: number): void {
  const avgFrontSlip = (Math.abs(slipFL) + Math.abs(slipFR)) / 2;

  const flEl = document.getElementById("tyre-fl");
  const frEl = document.getElementById("tyre-fr");

  if (flEl && frEl) {
    flEl.classList.remove("tyre-scrub");
    frEl.classList.remove("tyre-scrub");

    // If front tyre slip exceeds optimal angle drastically (> 30%) and steering angle is significant
    if (speed > 4.5 && avgFrontSlip > SLIP_ANGLE_PEAK * 1.3 && Math.abs(steer) > 0.22) {
      flEl.classList.add("tyre-scrub");
      frEl.classList.add("tyre-scrub");
    }
  }
}
