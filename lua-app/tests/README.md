# Testes headless do Race Coach Overlay

Suíte de regressão que roda a lógica de coaching do **track-painter** (detecção de
curvas + perfil de velocidade segura) **fora do Assetto Corsa**, alimentada com a
telemetria real das pistas em `lua-app/tracks/*.lua`, sob vários carros, velocidades,
grip e condição de pneu.

## Por que existe

O painter pintava **zona de frenagem (vermelho) no meio da reta** e, às vezes, deixava
passar curvas reais ("continue acelerando" onde era pra frear). A correção (filtro
geométrico de raio + guard do modo iniciante + thresholds de detecção em
`track-painter.lua`) precisava de uma forma de ser verificada de forma repetível, em
muitas pistas/carros, sem abrir o jogo. Esta suíte faz isso.

## Como rodar

```bash
lua lua-app/tests/run.lua
```

- Requer apenas o interpretador `lua` (testado com Lua 5.5).
- Imprime uma tabela por cenário e um resumo. **Sai com código ≠ 0 se algo falhar** —
  dá pra plugar num pre-commit ou CI.

## Arquitetura

| Arquivo | Papel |
|---|---|
| `mock_runtime.lua` | Instala os globais que os módulos do overlay tocam (`ac.*`, `vec3`, `rgbm`). Precisa ser carregado **antes** de qualquer módulo do app (o `config` chama `ac.storage` no load). |
| `harness.lua` | Fábricas de carro/sim, carregador de pista, geração da pista sintética e os oráculos de avaliação. |
| `run.lua` | Monta a matriz de cenários, executa e gera o relatório. |

O runner faz `require('tests.mock_runtime')` primeiro e então `track-painter`, que por sua
vez carrega `config`, `physics-calc`, `ai-loader`, `corner-store`, `line-learning`,
`logger`. Todos rodam contra o runtime mockado.

### Costura de teste no código de produção

`track-painter.lua` expõe **uma** função só para testes:

```lua
function M.buildProfileForTest(car, sim, roadGrip, speedMult)
```

Ela roda `preScanTrackCorners` + `recalculateSafeSpeedProfile` de forma determinística,
sem o frame de calibração/desenho (o `preScanTrackCorners` é `local`, então não dá pra
chamá-lo direto de fora). **Não é usada pelo overlay ao vivo.**

## O que é verificado (oráculos)

Os dois oráculos codificam exatamente as duas queixas, usando a telemetria da AI como
verdade de referência (não a própria detecção do painter — senão um bug se "auto-aprovaria").

### Oráculo A — vermelho na reta
Um jogador seguindo a velocidade da AI (escalada por `speedMult`) é considerado "pintado
de vermelho" quando está acima do perfil seguro. Isso é um **falso vermelho** quando, ao
mesmo tempo:
1. o ponto é **geometricamente reto** (raio local `> 400 m`, calculado da geometria — em
   curva um carro fraco *legitimamente* precisa reduzir, e isso não é o bug que guardamos); e
2. **não há desaceleração real à frente** dentro da distância de frenagem (queda
   `≥ 20 km/h` ou freada forte). Um aliviozinho de acelerador / ondulação de 1–2 km/h
   **não** conta — é justamente o que semeava a curva-fantasma.

Falha se houver uma faixa contínua de falso-vermelho `≥ 15 m` (estria visível na reta).

### Oráculo B — curva real ignorada
Verdade de referência = um **mínimo de velocidade em janela larga (±60 m)** cuja queda
para os máximos vizinhos é `≥ 35 km/h`. A janela larga funde frenagens compostas num só
ápice e ignora "pisadas" breves de freio em kinks rápidos. Exige uma curva detectada a
`≤ 40 m`, senão o painter deixaria o piloto acelerar para dentro dela.

## Matriz de cenários

`run.lua` cobre:

- **9 pistas** com retas longas + trechos técnicos (Monza road/full, Imola, Silverstone GP,
  Nürburgring GP-A, Laguna Seca, Highlands long, Vallelunga classic) + uma reta pura
  (`ks_drag_drag2000`, que deve detectar **0 curvas** e **0 falso-vermelho**).
- **3 carros**: `street`, `gt`, `formula` (limites de G por classe + aero/pneu/freio
  espelhando `physics-calc.initializeCarLimits`).
- **velocidade relativa** (`speedMult`) 1.0 e 1.3.
- **condições adversas**: grip 0.85 + pneu sujo 0.30 num subconjunto de pistas.

Total: 63 cenários de pista real + 4 sintéticos.

### Teste sintético (dentes)

As retas das pistas reais têm telemetria limpa demais para reproduzir o bug. Por isso
`harness.lua` gera um **oval procedural** (duas retas longas + duas hairpins reais) com
uma **ondulação na reta** (alívio de acelerador + queda de ~4 km/h) — exatamente o que
semeava a fantasma. Asserções:

- **nenhuma curva detectada pode cair em geometria reta** (`cornerOnStraight == 0`);
- **nenhuma faixa de falso-vermelho na reta**.

Verificação de "dentes": revertendo a correção em `track-painter.lua`, o sintético
**falha** (a fantasma reaparece: curva detectada na reta). Com a correção, passa.

## Lendo o relatório

```
track                car      mult  grip  dirt | crn real falseRm miss
ks_monza66_road      gt       1.00  1.00  0.00 |  16    1     0.0    0 ok
```

- `crn` — curvas detectadas (pós-filtro).
- `real` — curvas reais inequívocas encontradas pelo Oráculo B.
- `falseRm` — pior faixa de falso-vermelho em metros (Oráculo A); falha se `≥ 15`.
- `miss` — curvas reais sem detecção próxima; falha se `> 0`.

## Estendendo

- **Nova pista**: adicione o nome do arquivo (sem `.lua`) em `TRACKS` no `run.lua`.
- **Novo carro**: adicione um preset em `CAR_PRESETS` no `harness.lua`.
- **Novo cenário**: chame `add(track, car, mult, grip, dirty)` no `run.lua`.
- **Novo invariante sintético**: ajuste `H.makeOval` / `H.runSynthetic` no `harness.lua`.

## Limitações conhecidas

- O modelo de jogador segue a velocidade da AI escalada por `speedMult`; para carros bem
  diferentes da AI de referência, vermelho **em curva** pode ser legítimo (carro fraco na
  linha de um carro de corrida) — por isso o Oráculo A só avalia em geometria reta.
- O filtro de raio descarta curvas de raio `≥ 480 m` (kinks muito rápidos): é um trade-off
  deliberado de coaching, então o Oráculo B só cobra curvas com queda `≥ 35 km/h`.
- O jogo em si não roda aqui; a validação visual final (cores 3D na pista) continua sendo
  manual no AC.
