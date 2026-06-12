interface TyreTelemetry {
  slipAngle: number; // Ângulo de deriva do pneu em graus
  slipRatio: number; // Razão de escorregamento longitudinal
  load: number;      // Carga vertical no pneu em Newtons
  ndSlip: number;    // Escorregamento normalizado
}

interface GForces {
  x: number; // Aceleração lateral em Gs
  y: number; // Aceleração vertical em Gs
  z: number; // Aceleração longitudinal em Gs
}

interface TelemetryData {
  speedMs: number;     // Velocidade longitudinal em m/s
  speedKmh: number;    // Velocidade longitudinal em km/h
  gear: number;        // Marcha atual (0: R, 1: N, 2: 1ª, etc.)
  engineRPM: number;   // Rotações por minuto do motor
  steer: number;       // Entrada do volante (-1.0 a 1.0)
  throttle: number;    // Posição do acelerador (0.0 a 1.0)
  brake: number;       // Posição do pedal de freio (0.0 a 1.0)
  clutch: number;      // Posição do pedal de embreagem (0.0 a 1.0)
  yaw: number;         // Ângulo de guinada em radianos
  yawRate: number;     // Taxa de rotação em torno do eixo vertical (rad/s)
  accG: GForces;       // Forças G no centro de gravidade
  tyres: TyreTelemetry[]; // Telemetria de pneus (FL, FR, RL, RR)
  nextTurnDist: number;   // Distância para a próxima curva em metros (-1 se inválido/indisponível)
  nextTurnAngle: number;  // Ângulo da curva em graus (positivo = esquerda, negativo = direita)
  roadGrip: number;       // Nível de aderência da pista (0.0 a 1.0)
  trackPosLat: number;    // Posição lateral do carro na pista (-1.0 = esquerda, 1.0 = direita, 0.0 = centro)
  maxObservedLatG: number;   // Calibração de força G lateral máxima do Lua
  maxObservedDecelG: number; // Calibração de desaceleração G máxima do Lua
  voiceEnabled?: boolean;
  drawEntryApexExit?: boolean;
  overlayOpacity?: number;
  vTargetKmh?: number;
  totalBrakingDistanceNeeded?: number;
  lapDelta?: number | null;
  bestLapMs?: number | null;
  lapTimeMs?: number;
}

interface ApexResult {
  cornerIndex: number;
  currentKmh: number;
  bestKmh: number;
  deltaKmh: number;       // positive = faster than PB, negative = slower
  targetKmh: number;
  isPB: boolean;
  obsCount: number;
  physicsKmh?: number;        // physical ceiling for this corner (geometry × grip × aero)
  gapToPhysicsKmh?: number;   // positive = time left on the table
  confidence?: number;        // 0-1, grows with observation count
}

interface CoachTip {
  type: string;           // corner_speed_low | corner_speed_risky | brake_early | brake_late
                          // | trail_release_early | brake_too_deep | lockup | wheelspin
                          // | tyre_cold | tyre_hot
  severity: 1 | 2 | 3;    // 1 = info, 2 = improvement, 3 = warning
  text: string;           // pre-formatted message in pt-BR
  cornerIndex: number;
}

