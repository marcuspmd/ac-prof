# Race Coach Overlay — Assetto Corsa

Este projeto é um sistema de overlay inteligente para Assetto Corsa utilizando o Custom Shaders Patch (CSP) Lua Runtime e Chromium Embedded Framework (CEF) para renderizar uma interface moderna em HTML5/TypeScript e fornecer feedback físico e por voz (coaching) em tempo real.

---

## 📁 Estrutura do Projeto

*   `lua-app/` — Contém o aplicativo Lua que roda dentro do Assetto Corsa, captura a telemetria do motor de física e a envia ao frontend.
*   `overlay/` — O frontend em HTML5/CSS3/JavaScript (e TypeScript) que processa as heurísticas e renderiza o HUD com o diagrama G-G, barras de pedal inputs e tyre slip.
*   `shared/` — Tipagens TypeScript compartilhadas.
*   `project.md` — Documento de Arquitetura e Decisões Técnicas (ADR).

---

## 🚀 Instalação no Assetto Corsa

1.  **Pré-requisitos**:
    *   Assetto Corsa instalado.
    *   **Content Manager** instalado.
    *   **Custom Shaders Patch (CSP)** v0.1.79 ou superior habilitado.
2.  **Copiar os arquivos**:
    *   Navegue até a pasta raiz do seu Assetto Corsa (ex: `C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\`).
    *   Vá para o diretório `apps/lua/`.
    *   Crie uma pasta chamada `race-coach-overlay`.
    *   Copie o conteúdo das pastas `lua-app/` e `overlay/` para dentro dela, de forma que a estrutura final seja:
        ```text
        assettocorsa/
        └── apps/
            └── lua/
                └── race-coach-overlay/
                    ├── manifest.ini
                    ├── app.lua
                    ├── telemetry.lua
                    └── overlay/
                        ├── index.html
                        ├── style.css
                        ├── app.js
                        └── app.ts
        ```
3.  **Habilitar o Aplicativo**:
    *   Abra o **Content Manager**.
    *   Vá em **Settings** > **Assetto Corsa** > **Apps** e marque a caixa ao lado de **Race Coach Overlay**.
4.  **Ativar na Pista**:
    *   Inicie qualquer sessão de pista (Hotlap, Practice, Race).
    *   Leve o mouse até a borda direita da tela para abrir o menu lateral de aplicativos.
    *   Encontre o **Race Coach Overlay** e clique para abri-lo. A janela do HUD em Glassmorphism aparecerá na sua tela.

---

## 🧪 Como Testar no Navegador (Sem Entrar no Jogo)

Você não precisa abrir o Assetto Corsa toda vez que quiser testar ou fazer alterações visuais no overlay. A página HTML foi desenhada para rodar de forma autônoma em qualquer navegador web moderno.

### Passo a Passo de Teste Local:

1.  Abra o arquivo [overlay/index.html](file:///home/mazzon/projetos/ac-prof/overlay/index.html) diretamente no seu navegador de preferência (Chrome, Edge, Firefox, etc.).
2.  A interface aparecerá exibindo "Aguardando telemetria na pista...".
3.  Abra o **Console do Desenvolvedor** do navegador (pressione `F12` ou clique com o botão direito e selecione *Inspecionar* > aba *Console*).
4.  Copie e cole qualquer um dos comandos a seguir no console e aperte `Enter` para simular o recebimento de telemetria física:

#### Simular Pilotagem Normal (Aceleração em Reta):
```javascript
window.onTelemetryUpdate({
  speedMs: 44.4, speedKmh: 160, gear: 5, engineRPM: 6200,
  steer: 0, throttle: 1.0, brake: 0, clutch: 0, yaw: 0, yawRate: 0,
  accG: { x: 0, y: 1.0, z: -0.4 },
  tyres: [
    { slipAngle: 0.1 }, { slipAngle: 0.1 },
    { slipAngle: 0.2 }, { slipAngle: 0.2 }
  ]
});
```

#### Simular Frenagem Forte com Rastro no Diagrama G-G:
```javascript
window.onTelemetryUpdate({
  speedMs: 25, speedKmh: 90, gear: 3, engineRPM: 4000,
  steer: 0, throttle: 0, brake: 0.9, clutch: 0, yaw: 0, yawRate: 0,
  accG: { x: 0, y: 1.0, z: 1.2 }, // 1.2G de desaceleração
  tyres: [
    { slipAngle: 0.2 }, { slipAngle: 0.2 },
    { slipAngle: 0.1 }, { slipAngle: 0.1 }
  ]
});
```

#### Simular Subesterço (Understeer) — *Isto ativará o feedback de voz*:
```javascript
window.onTelemetryUpdate({
  speedMs: 22, speedKmh: 80, gear: 3, engineRPM: 4500,
  steer: 0.8, throttle: 0.2, brake: 0, clutch: 0, yaw: 0.1, yawRate: 0.2, // Yaw Rate baixo em relação ao esterço
  accG: { x: 0.8, y: 1.0, z: 0 },
  tyres: [
    { slipAngle: 9.5 }, { slipAngle: 9.8 }, // Escorregamento dianteiro alto
    { slipAngle: 2.1 }, { slipAngle: 2.1 }
  ]
});
```

#### Simular Sobresterço (Oversteer / Escorregamento Traseiro) — *Isto ativará o feedback de voz*:
```javascript
window.onTelemetryUpdate({
  speedMs: 18, speedKmh: 65, gear: 2, engineRPM: 5200,
  steer: -0.6, throttle: 0.4, brake: 0, clutch: 0, yaw: 0.3, yawRate: 0.4, // Contra-esterço (sinais opostos de steer e yawRate)
  accG: { x: -1.1, y: 1.0, z: -0.2 },
  tyres: [
    { slipAngle: 3.2 }, { slipAngle: 3.2 },
    { slipAngle: 10.5 }, { slipAngle: 11.0 } // Traseira patinando além do limite
  ]
});
```

#### Simular Trail Braking Perfeito:
```javascript
window.onTelemetryUpdate({
  speedMs: 20, speedKmh: 72, gear: 3, engineRPM: 4200,
  steer: 0.3, throttle: 0, brake: 0.15, clutch: 0, yaw: 0.2, yawRate: 0.3,
  accG: { x: 0.7, y: 1.0, z: 0.3 },
  tyres: [
    { slipAngle: 3.5 }, { slipAngle: 3.5 },
    { slipAngle: 2.5 }, { slipAngle: 2.5 }
  ]
});
```

---

## 🛠️ Desenvolvimento e Compilação

Caso deseje modificar os arquivos TypeScript (`.ts`):

1.  Instale as dependências com o NPM (se necessário configurar build pack):
    ```bash
    npm install
    ```
2.  Compile o TypeScript para JavaScript nativo:
    ```bash
    npx tsc overlay/app.ts --outDir overlay/
    ```
3.  Utilize os scripts automatizados configurados no `package.json` para facilitar seu fluxo de trabalho:
    *   **Compilar tudo**: `npm run build` (roda o TypeScript compiler em todo o projeto)
    *   **Observador em tempo real**: `npm run watch` (recompila o TypeScript dinamicamente a cada alteração salva)
    *   **Gerar instalador ZIP**: `npm run zip` (cria automaticamente a pasta com a estrutura correta e empacota tudo em um arquivo `race-coach-overlay.zip` pronto para ser arrastado e instalado no Content Manager, sem necessitar da ferramenta de zip do sistema, utilizando o Python 3 nativo do seu Linux/WSL).

