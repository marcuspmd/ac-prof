# ADR-001 — Sistema de Overlay Inteligente para Assetto Corsa

## Status

Proposto

---

# Contexto

Deseja-se desenvolver um sistema de overlay inteligente para Assetto Corsa utilizando Content Manager e Custom Shaders Patch.

O objetivo é criar um “Race Coach Overlay” capaz de:

* analisar telemetria em tempo real
* detectar understeer/oversteer
* analisar entrada e saída de curva
* fornecer feedback de pilotagem
* exibir overlays modernos
* auxiliar no aprendizado do piloto

O sistema deve inicialmente focar em:

* baixo acoplamento
* feedback em tempo real
* MVP funcional rapidamente
* arquitetura expansível para IA futura

---

# Decisão

O sistema será integrado diretamente ao runtime do Assetto Corsa usando as capacidades de Chromium Embedded Framework (CEF) do Custom Shaders Patch (CSP), eliminando a necessidade de processos externos.

A arquitetura do sistema será:

```txt
Assetto Corsa (Motor de Física)
    ↓
CSP Lua Runtime (Coleta de telemetria e spline da pista)
    ↓ (Ponte interna nativa: ui.sendWebCommand)
Frontend Overlay CEF (HTML/CSS/TypeScript)
    ↓
Coach Engine (Algoritmos de análise em TS)
    ↓
HUD/UI Moderna & Audio Coach (Feedback em tempo real)
```

---

# Stack escolhida

## Runtime no jogo

* CSP Lua Apps (rodando no engine de física do jogo)

Motivos:

* API moderna e de baixo nível do CSP
* Acesso direto à física detalhada (`physics.CarState`)
* Acesso à spline da pista (`ac.getTrackSpline()`)
* Renderização customizada acelerada por hardware
* Latência de atualização na taxa física do jogo (até 333Hz)

---

## Overlay/UI

* HTML5 / CSS3 / TypeScript rodando sob o CEF integrado do CSP.

Motivos:

* Flexibilidade de design e animações premium
* Desenvolvimento rápido de componentes complexos
* Desempenho excelente com aceleração de hardware nativa do CEF do CSP
* Facilidade de portabilidade e renderização in-game sem janelas flutuantes externas

---

## Comunicação

* **Ponte de Mensagens CEF Nativa**: Comunicação bidirecional direta de ultrabaixa latência (<1ms) usando as funções de canal interno do CSP (`ui.sendWebCommand` para envio de telemetria e bindings JavaScript nativos para callbacks).
* **JSON Local**: Apenas para salvar históricos de voltas estruturados no disco local (Fase 3).

---

## Engine de análise

Inicialmente:

* heurísticas matemáticas
* regras determinísticas

Futuramente:

* machine learning
* análise histórica
* perfil do piloto

---

# Decisões arquiteturais

## NÃO utilizar apps Python antigas do Assetto Corsa

Motivos:

* legado
* limitações
* APIs antigas
* ecossistema menos ativo

---

## NÃO iniciar com IA/ML

Motivos:

* complexidade desnecessária
* heurísticas resolvem 80%
* validação mais rápida

---

## NÃO renderizar HUD complexo diretamente no Lua

Motivos:

* UI limitada
* manutenção difícil
* frontend moderno é superior

---

# Objetivos do MVP

## Detectar:

* understeer
* oversteer
* throttle agressivo
* braking ruim
* lockup
* entrada excessiva de curva

---

## Mostrar:

* velocidade
* ângulo da curva
* alertas
* brake timing
* pedal inputs
* grip status

---

# Heurísticas Físico-Matemáticas Avançadas

Para que o Race Coach forneça feedbacks técnicos e precisos, utilizaremos heurísticas baseadas em dinâmica veicular clássica, aproveitando os dados expostos pelo CSP Lua API.

## 1. Detecção de Understeer (Subesterço)

O subesterço ocorre quando os pneus dianteiros perdem aderência lateral, fazendo com que o carro vire menos do que o ângulo das rodas dianteiras exige.

### Modelo de Yaw Rate de Ackermann (Referência Neutra)
Calculamos a taxa de guinada esperada (Yaw Rate) em baixa velocidade (sem escorregamento) usando a geometria de Ackermann:

$$\omega_{\text{neutral}} = \frac{v \cdot \delta}{L}$$

Onde:
* $v$ é a velocidade longitudinal do carro (`carState.speedMs`).
* $\delta$ é o ângulo médio de esterço das rodas dianteiras em radianos (obtido via `carState.steer` e a relação de direção do carro).
* $L$ é o entre-eixos (wheelbase) do veículo.

### Heurística de Decisão:
1. **Diferença de Yaw Rate**:
   $$\Delta \omega = \omega_{\text{neutral}} - \omega_{\text{actual}}$$
   Se $\Delta \omega > \epsilon_{\text{under}}$ (onde $\epsilon_{\text{under}}$ é um limiar dinâmico ajustado pela velocidade), indica desvio da trajetória desejada.
2. **Ângulo de Deriva do Pneu (Slip Angle)**:
   Verificamos os ângulos de deriva dos pneus dianteiros (`carState.tyres[0].slipAngle` e `carState.tyres[1].slipAngle`).
   * Se $\text{slipAngle}_{\text{dianteiro}} > \text{slipAngle}_{\text{ótimo}}$ (geralmente entre $6^\circ$ e $10^\circ$, dependendo do composto), o pneu está deslizando além do pico de aderência.
3. **Condição de Subesterço**:
   $$\text{Understeer} = (\Delta \omega > \epsilon_{\text{under}}) \land (\text{slipAngle}_{\text{dianteiro}} > \text{slipAngle}_{\text{traseiro}})$$

---

## 2. Detecção de Oversteer (Sobresterço)

O sobresterço ocorre quando os pneus traseiros perdem aderência lateral, fazendo com que a traseira do carro deslize para fora da curva.

### Heurística de Decisão:
1. **Contra-esterço (Counter-steering)**:
   Detectamos se o piloto está esterçando no sentido contrário ao da curva (sinais opostos de esterço $\delta$ e yaw rate actual $\omega_{\text{actual}}$):
   $$\text{sign}(\delta) \neq \text{sign}(\omega_{\text{actual}}) \land |\omega_{\text{actual}}| > 0.05 \text{ rad/s}$$
2. **Ângulo de Deriva Traseiro**:
   Verificamos se o escorregamento traseiro excede o dianteiro:
   $$\text{slipAngle}_{\text{traseiro}} > \text{slipAngle}_{\text{dianteiro}} + \epsilon_{\text{over}}$$
3. **Condição de Sobresterço**:
   $$\text{Oversteer} = (\text{sign}(\delta) \neq \text{sign}(\omega_{\text{actual}})) \land (\text{slipAngle}_{\text{traseiro}} > \text{slipAngle}_{\text{ótimo}})$$

---

## 3. Círculo de Fricção (G-G Diagram) e Limite de Grip

A aderência total disponível em um pneu é compartilhada entre forças longitudinais (aceleração/frenagem) e forças laterais (curvas). Esta relação é governada pela elipse de aderência de Kamm:

$$G_{\text{total}} = \sqrt{G_{\text{lat}}^2 + G_{\text{long}}^2}$$

Onde:
* $G_{\text{lat}}$ é a aceleração lateral em Gs (`carState.accG.x`).
* $G_{\text{long}}$ é a aceleração longitudinal em Gs (`carState.accG.z`).

### Heurística de Grip:
* O overlay manterá um histórico da aceleração máxima registrada em diferentes velocidades para desenhar o **Envelope de Grip Máximo** (o círculo de fricção real do carro).
* **Eficiência de Aderência**:
  $$\text{Eficiência} = \frac{G_{\text{total}}}{G_{\text{max}}} \times 100\%$$
* Se a eficiência for $< 85\%$ durante o ápice da curva, o piloto não está explorando todo o potencial do carro.

---

## 4. Análise de Trail Braking

O Trail Braking consiste em frear forte em linha reta e aliviar o freio gradualmente conforme o piloto insere esterço na curva.

### Heurística de Análise:
Medimos a correlação entre a pressão de freio (`carState.brake`) e o ângulo de esterço ($\delta$):
1. **Sobrecarga de Frenagem (Lockup/Understeer por freio)**:
   Se $\delta$ aumenta enquanto `brake` permanece $> 70\%$. O pneu dianteiro satura instantaneamente.
2. **Liberação Precoce (Early Release)**:
   Se `brake` cai para $0\%$ antes de $\delta$ começar a subir. O nariz do carro levanta, removendo carga vertical dos pneus dianteiros e gerando subesterço de entrada.
3. **Trail Braking Ideal**:
   Durante a transição de entrada de curva, a soma normalizada das entradas deve seguir a borda da elipse de aderência:
   $$\left(\frac{\text{Brake}}{\text{Brake}_{\text{max}}}\right)^2 + \left(\frac{\delta}{\delta_{\text{max}}}\right)^2 \approx 1.0$$

---

## 5. Entrada Excessiva de Curva

Usando a spline da pista (`ac.getTrackSpline()`), calculamos o raio da curva atual ($R$) à frente do carro:

$$R = \frac{1}{\kappa}$$

Onde $\kappa$ é a curvatura local da spline.
A velocidade ideal teórica de entrada na curva ($v_{\text{ideal}}$) com base no limite de aceleração lateral máxima do carro ($G_{\text{lat\_max}}$) é:

$$v_{\text{ideal}} = \sqrt{G_{\text{lat\_max}} \cdot g \cdot R}$$

* Se $v_{\text{atual}} > v_{\text{ideal}} \cdot (1 + \epsilon_{\text{speed}})$, o coach emitirá o alerta imediato de "Entrada Rápida Demais" (Over-speed entry).

---

# Dados utilizados

## Telemetria do carro

* speed
* yaw
* steering angle
* throttle
* brake
* tyre slip
* wheel load
* lateral G

---

## Dados da pista

* spline
* direção da pista
* raio da curva
* distância
* setor

---

# Estratégia futura

## Fase 2

* histórico de voltas
* score do piloto
* comparação com ghost
* replay analysis

---

## Fase 3

* IA
* aprendizado do piloto
* coaching personalizado
* predição de perda de controle

---

# Consequências

## Positivas

* arquitetura moderna
* evolução incremental
* baixo custo inicial
* possibilidade de produto real

---

## Negativas

* dependência do CSP
* necessidade de estudar APIs Lua do AC
* tuning matemático complexo

---

# Estrutura inicial sugerida

```txt
race-coach/
├── lua-app/
│   ├── app.lua
│   ├── telemetry.lua
│   └── manifest.ini
│
├── overlay/
│   ├── src/
│   ├── components/
│   ├── coach/
│   └── ui/
│
├── shared/
│   ├── telemetry-types.ts
│   └── track-model.ts
│
└── docs/
    ├── adr/
    └── research/
```

---

# TASKS — Fase 1 (Infraestrutura & CEF Integration)

## TASK-001 — Instalar ambiente

* Configurar Content Manager e versão recente do CSP (v0.1.79 ou superior com suporte a CEF estendido).
* Configurar o SDK Lua local (`extension/internal/lua-sdk/`).

---

## TASK-002 — Criar App Lua de Acoplamento CEF

Objetivo:
* Criar uma janela no CSP Lua que carregue uma página HTML local.
* Implementar o ciclo `ui.WebBrowser` com carregamento de arquivo `.html` local e tamanho responsivo.

---

## TASK-003 — Capturar Telemetria Física Completa no Lua

Objetivo:
* Ler da API `physics.CarState` do CSP: velocidade, pedal inputs (throttle, brake, clutch), steer, yaw, slip angles individuais por pneu, tyre slip ratio, e acelerações (accG).
* Ler a spline da pista (`ac.getTrackSpline()`).

---

## TASK-004 — Implementar Ponte CEF de Alta Frequência

Objetivo:
* Enviar a telemetria via `ui.sendWebCommand(appId, "telemetry_update", data)` na taxa física (`script.update`).
* Tratar recepção do lado JS/TS no frontend.

---

## TASK-005 — Desenhar Interface de Telemetria Visual (HUD Premium)

Objetivo:
* Criar componentes visuais modernos com CSS customizado:
  * Medidor de velocidade e barras de inputs dos pedais.
  * **Componente Friction Circle (Diagrama G-G)** em tempo real.
  * **Tyre Slip Bars** com alertas dinâmicos de cor baseados na perda de aderência física.
  * Área de alertas e coaching por texto.

---

# TASKS — Fase 2 (Análise Física & Heurísticas)

## TASK-006 — Detector Avançado de Subesterço (Understeer)

Objetivo:
* Implementar no Coach Engine a comparação matemática de Ackermann ($\omega_{\text{neutral}}$ vs $\omega_{\text{actual}}$).
* Cruzar com os ângulos de deriva dianteiros (`slipAngle`).

---

## TASK-007 — Detector Avançado de Sobresterço (Oversteer)

Objetivo:
* Implementar a lógica de detecção de contra-esterço ($\text{sign}(\delta) \ne \text{sign}(\omega)$).
* Validar a perda de aderência traseira comparativa.

---

## TASK-007a — Algoritmo de Análise de Trail Braking

Objetivo:
* Monitorar a taxa de alívio do freio em relação à entrada do esterço.
* Classificar em: "Trail Braking Ideal", "Liberação Precoce" (Early Release), ou "Sobrecarga de Frenagem".

---

## TASK-008 — Análise de Linha de Corrida (Curvatura e Spline)

Objetivo:
* Extrair a curvatura da pista à frente do carro utilizando a spline local.
* Identificar o ápice físico da curva (Apex).

---

## TASK-009 — Cálculo de Velocidade de Curva Ideal

Objetivo:
* Estimar a velocidade ideal baseada no raio calculado da curva e no limite de aderência lateral do veículo.

---

## TASK-010 — Central de Coaching Visual e por Voz

Objetivo:
* Implementar mensagens visuais e sintetizador de voz (Web Speech API) com dicas em tempo real:
  * "Frenagem no limite", "Alivie o freio suavemente", "Aceleração precoce", "Entrada rápida demais".

---

# TASKS — Fase 3 (Análise Histórica & Coaching)

## TASK-011 — Banco de Dados Local de Voltas (JSON)

* Persistir traces de velocidade, pontos de frenagem e trajetórias em formato JSON comprimido no disco.

---

## TASK-012 — Sistema de Score e Estatísticas do Piloto

* Computar pontuações de $0$ a $100$ para: Consistência, Eficiência de Frenagem, Controle de Aceleração e Velocidade de Entrada.

---

## TASK-013 — Comparação com Volta Rápida (Ghost)

* Implementar linha de delta em tempo real mostrando milissegundos perdidos ou ganhos setor a setor.

---

## TASK-014 — Detector de Padrões e Erros Recorrentes

* Analisar em quais setores/curvas da pista o piloto comete subesterço ou frenagem inadequada de forma consistente.

---

# TASKS — Fase 4 (Avançado & Projeção 3D)

## TASK-015 — Machine Learning Aplicado (Classificação Automática de Estilo)

* Treinar modelos leves para categorizar o estilo de pilotagem (Agressivo, Conservador, Suave, Errático).

---

## TASK-016 — Modelo Preditivo de Perda de Controle

* Alertar o piloto com bipes curtos ou piscados de LED quando a combinação de escorregamento e ângulo de esterço apontar para um rodopio (spin) inevitável.

---

## TASK-017 — Projeção Holográfica 3D (Renderização na Pista)

* Utilizar o motor 3D do CSP (`sdk.render`) para desenhar lines de frenagem (marcadores vermelhos/verdes) e linha de trajetória ideal projetada diretamente no asfalto da pista.

---

# Critérios de sucesso

O MVP será considerado funcional quando:

1. **Eficiência Física**: Detectar subesterço e sobresterço com atraso menor que 50ms a partir do início do deslizamento físico das rodas.
2. **Coaching Ativo**: Fornecer pelo menos 3 tipos de avisos acionáveis por voz/visual durante uma volta de teste.
3. **Desempenho da UI**: Renderizar a interface de telemetria e o diagrama G-G em 60 FPS estáveis sem queda de performance no Assetto Corsa.
4. **Baixa Latência**: A ponte de mensagens CEF nativa funcionar sem perdas de pacotes ou engasgos de processamento.
5. **Portabilidade de Pistas**: Funcionar autonomamente em qualquer pista do Assetto Corsa usando o spline extraído dinamicamente pelo CSP.
