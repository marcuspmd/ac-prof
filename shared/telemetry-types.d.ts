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
}
