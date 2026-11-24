# 01 — Engenharia de Latência, Frame Pacing e Geração Óptica de Quadros (`30 -> 60 FPS`)

Este documento detalha a física de sinais, a arquitetura de subsistemas do Windows 11 (WDDM 3.2 / DXGI / DWM / DirectShow) e as otimizações de microarquitetura GPU aplicadas para transformar um sinal nativo de **30 FPS** do **PlayStation 5** (como **GTA 6** em modo fidelidade/base) em **60 FPS contínuos (`30 / 60`)** com o menor *input lag* fisicamente alcançável via placa de captura USB 3.0 em um notebook híbrido **NVIDIA Optimus**.

---

## Sumário

1. [Matemática do Frame Pacing 30-em-60Hz e o Bug dos Quadros Duplicados (`60 / 120`)](#1-matemática-do-frame-pacing-30-em-60hz-e-o-bug-dos-quadros-duplicados-60--120)
2. [Óptica de Fluxo no LSFG 3.1 em Arquitetura sem Tensor Cores (`TU117`)](#2-óptica-de-fluxo-no-lsfg-31-em-arquitetura-sem-tensor-cores-tu117)
3. [Topologia Híbrida NVIDIA Optimus, Barramento PCIe e DWM Independent Flip](#3-topologia-híbrida-nvidia-optimus-barramento-pcie-e-dwm-independent-flip)
4. [Estados Dinâmicos de Energia (`P-states`) na GTX 1650 e Controle via `nvapi64.dll`](#4-estados-dinâmicos-de-energia-p-states-na-gtx-1650-e-controle-via-nvapi64dll)
5. [Engenharia de Captura USB 3.0 (`UGREEN 15390` / `MS2131`): `YUY2` vs. `MJPEG`](#5-engenharia-de-captura-usb-30-ugreen-15390--ms2131-yuy2-vs-mjpeg)
6. [Análise Física do Piso Teórico Irredutível (`33,33 ms`) vs. Latência Parasita](#6-análise-física-do-piso-teórico-irredutível-3333-ms-vs-latência-parasita)

---

## 1. Matemática do Frame Pacing 30-em-60Hz e o Bug dos Quadros Duplicados (`60 / 120`)

### 1.1 O Container HDMI 60 Hz do PlayStation 5
Mesmo quando um jogo de PS5 opera internamente com orçamento de renderização travado em **30 FPS** ($T_{\text{render}} = 33,333\text{ ms}$), o transmissor HDMI do console mantém link elétrico padrão de **60,00 Hz** ($T_{\text{HDMI}} = 16,667\text{ ms}$) quando VRR está inativo ou indisponível na placa de captura. Para preencher os 60 pulsos verticais por segundo, o *scanout* do PS5 emite cada quadro renderizado **duas vezes consecutivas** (*2:2 pulldown* digital):

$$S_{\text{HDMI}}(k) = \{A,\; A,\; B,\; B,\; C,\; C,\; D,\; D,\; \dots\}, \quad \Delta t = 16,67\text{ ms}$$

### 1.2 O Colapso de Cadência ao Capturar em `60.000 FPS` (`60 / 120`)
Quando o pino DirectShow do MPC-BE ou do OBS Studio (`FPSCommon=60`) negocia com o ASIC `MacroSilicon MS2131` uma taxa de amostragem de **60 FPS** (`AvgTimePerFrame = 166666` unidades de $100\text{ ns}$), ambos os quadros idênticos são entregues à swapchain da aplicação.

Ao aplicar o **Lossless Scaling LSFG 3.1 (`2x Fixado`)** sobre esse fluxo, o interpolador enxerga uma entrada de 60 Hz e sintetiza 1 quadro intermediário para cada par consecutivo (`60 / 120` no HUD):

1. **Par $(A_1, A_2)$:** Vetor de movimento óptico $\vec{v}(x,y) \equiv \vec{0}$. O quadro interpolado $I(A_1, A_2)$ é idêntico a $A$.
2. **Par $(A_2, B_1)$:** Vetor de movimento real $\vec{v}_{A \to B}(x,y) \neq \vec{0}$. O quadro interpolado $I(A_2, B_1) = AB_{0.5}$ contém metade do deslocamento espacial.
3. **Par $(B_1, B_2)$:** Novamente $\vec{v}(x,y) \equiv \vec{0}$, produzindo $I(B_1, B_2) = B$.

A sequência exibida a 120 FPS ($8,33\text{ ms}$ por passo) torna-se:

$$S_{60 \to 120} = \{\underbrace{A,\; A,\; A}_{25,0\text{ ms estático}},\; \underbrace{AB_{0.5}}_{8,33\text{ ms}},\; \underbrace{B,\; B,\; B}_{25,0\text{ ms estático}},\; \underbrace{BC_{0.5}}_{8,33\text{ ms}},\; \dots\}$$

**Consequências medidas:**
- **Judder severo (Assimetria 3:1):** A imagem permanece congelada por $25,0\text{ ms}$ e salta em $8,33\text{ ms}$, destruindo a fluidez visual apesar do contador marcar `120 FPS`.
- **Dobro de carga nos shaders e no barramento USB:** A GPU executa inferência óptica 120 vezes por segundo (metade delas desperdiçada comparando imagens idênticas) e trafega `248,83 MB/s` pela USB 3.0 em vez de `124,42 MB/s`.

### 1.3 A Solução Exata: Decimação Determinística na Captura (`30.000 FPS` -> `30 / 60`)
Ao configurar o formato DirectShow `VIDEOINFOHEADER` (88 bytes) para **`30.000 FPS`**:
- Offset `40` (`AvgTimePerFrame`, `INT64`): `333333` ($333\,333 \times 100\text{ ns} = 33,3333\text{ ms}$)
- Offset `32` (`dwBitRate`, `UINT32`): $1920 \times 1080 \times 16\text{ bits} \times 30 = 995\,328\,000\text{ bps}$ (`124,42 MB/s`)

O próprio hardware/driver UVC descarta a cópia redundante na origem, entregando ao player uma sequência estritamente monotônica $\{A,\; B,\; C,\; D\}$ espaçada em $33,33\text{ ms}$. O LSFG 3.1 `2x` sintetiza exatamente o ponto médio espacial e temporal:

$$S_{30 \to 60} = \{A,\; AB_{0.5},\; B,\; BC_{0.5},\; C,\; CD_{0.5},\; \dots\}, \quad \Delta t_{\text{ideal}} = 16,67\text{ ms}$$

```mermaid
sequenceDiagram
    participant PS5 as "PS5 HDMI 60 Hz (Jogo 30 FPS)"
    participant UVC as "UGREEN 15390 (DirectShow 30.000 fps)"
    participant APP as "MPC-BE / OBS (30 FPS Únicos)"
    participant LSFG as "GTX 1650 (LSFG 3.1 Fixed 2x)"
    participant PNL as "Painel Interno (144 Hz SDR)"

    PS5->>UVC: "Quadro A (0,0 ms) + Cópia A (16,7 ms)"
    UVC->>APP: "Entrega apenas A (33,3 ms ciclo limpo)"
    PS5->>UVC: "Quadro B (33,3 ms) + Cópia B (50,0 ms)"
    UVC->>APP: "Entrega apenas B"
    APP->>LSFG: "Par distinto (A, B)"
    LSFG->>PNL: "Apresenta A (t0) e Sintetiza AB_0.5 (t0 + 16,67 ms)"
```

### 1.4 Interação com Painel de `144 Hz` sem G-Sync
O painel interno do notebook opera a $144\text{ Hz}$ fixos ($T_{\text{scanout}} = \frac{1000}{144} = 6,944\text{ ms}$) sem *Variable Refresh Rate*. Como $\frac{144}{60} = 2,4$ ciclos de atualização por quadro gerado, e com `SyncMode = OFF` (apresentação imediata sem fila VSync), os quadros de $16,67\text{ ms}$ acomodam-se em cadência `2:3` de ciclos de *refresh* ($2 \times 6,944 = 13,89\text{ ms}$ e $3 \times 6,944 = 20,83\text{ ms}$). O desvio máximo de fase é limitado a meio período de *refresh* ($\pm 3,47\text{ ms}$), mantendo percepção contínua de 60 FPS sem o atraso de fila que o VSync tradicional imporia.

---

## 2. Óptica de Fluxo no LSFG 3.1 em Arquitetura sem Tensor Cores (`TU117`)

A **NVIDIA GeForce GTX 1650 Mobile** utiliza o chip **Turing `TU117`** (896 CUDA Cores, 4 GB GDDR6 a 128-bit, boost até `1785 MHz`). Diferentemente das séries RTX, o `TU117` **não possui Tensor Cores** dedicados; toda a estimação piramidal de fluxo óptico e fusão de quadros do **LSFG 3.1** ocorre nos *shaders* unificados FP16/FP32.

As escolhas de engenharia nos perfis `Settings.reference.xml` decorrem diretamente dessa microarquitetura:

| Parâmetro LSFG 3.1 | Valor Definido | Justificativa de Microarquitetura e Latência |
| :--- | :--- | :--- |
| `FrameGeneration` / `LSFG3Mode1` | `LSFG3` / `FIXED` (`2x`) | Multiplicador determinístico `2x` sobre entrada cravada em `30 FPS` evita oscilações heurísticas do modo *Adaptive*. |
| `LSFGSize` | `PERFORMANCE` | Reduz a complexidade da rede de refinamento de bordas nos CUDA Cores, mantendo o tempo de síntese em **~3–4 ms** a `1785 MHz`. No modo `BALANCED`, o custo sobe sem ganho perceptível em TV/distância normal. |
| `ScalingType` | `Off` | O fluxo de entrada (`1920x1080`) já coincide pixel a pixel com o painel (`1920x1080`). Desligar `LS1` elimina um passe inteiro de *compute shader* e erradica artefatos de *ringing*/*oversharpening* nas legendas e HUD do GTA 6. |
| `LSFGFlowScale` (MPC-BE) | `85%` | No Modo Offline, a GTX 1650 está dedicada quase exclusivamente ao LSFG. `85%` preserva excelente rastreamento de objetos rápidos (veículos/câmera) mantendo uso 3D bem abaixo de 80%. |
| `LSFGFlowScale` (OBS Studio) | `70%` | No Modo Live, a GTX 1650 compartilha largura de banda GDDR6 e SMs com composição de cena do OBS + prévia + cópia de texturas NVENC. `70%` garante *headroom* térmico e impede que o uso 3D ultrapasse **85%**, limiar onde a fila de comandos D3D11 dispara o *input lag*. |
| `QueueTarget` | `0` | **Crítico:** `QueueTarget = 1` ou `2` instrui o Lossless Scaling a reter quadros adicionais para suavizar variações de *frametime* de jogos PC instáveis. Como o PS5 já entrega 30 FPS com *pacing* de hardware constante, `QueueTarget = 0` corta **16,7 ms a 33,3 ms** de latência pura sem qualquer *stutter*. |
| `GsyncSupport` | `false` | Evita chamadas e sinalizações VRR incompatíveis com o painel eDP fixo de 144 Hz controlado pela iGPU Intel. |

---

## 3. Topologia Híbrida NVIDIA Optimus, Barramento PCIe e DWM Independent Flip

### 3.1 Anatomia do Gargalo de `~15 FPS` (`66,7 ms`) na iGPU
Em notebooks sem *MUX Switch* físico (arquitetura **NVIDIA Optimus / MSHybrid**), a topologia elétrica segue o modelo *Render-Only Display-Less dGPU*:
- **`NVIDIA GeForce GTX 1650` (`dGPU`):** Conectada à CPU (`i5-10300H`) via barramento PCIe 3.0; possui alta capacidade aritmética e 4 GB GDDR6, mas **nenhuma trilha física ligada à tela interna**.
- **`Intel UHD Graphics` (`iGPU`):** Conectada fisicamente via eDP ao painel `1920x1080 @ 144 Hz` e compartilhando RAM DDR4 do sistema (com apenas `128 MB` pré-alocados).

```mermaid
flowchart LR
    subgraph Antes["ANTES: Colapso na iGPU (~15 FPS / 66,7 ms)"]
        direction LR
        A1["OBS / Player"] -->|"WGC Cross-Adapter Copy"| A2["Intel UHD Graphics (PreferredGpuId=0)"]
        A2 -->|"LS1 + LSFG Balanced + Flow 100%"| A3["Saturação EU + DDR4 (66,7 ms/frame)"]
        A3 -->|"DWM BitBlt Legado (+8 a +16 ms)"| A4["Painel 144 Hz"]
    end

    subgraph Depois["DEPOIS: Pipeline Direto na dGPU (30 / 60 FPS | ~3-4 ms Shader)"]
        direction LR
        B1["MPC-BE EVR-CP (GTX 1650)"] -->|"DXGI Local VRAM"| B2["GTX 1650 @ 1785 MHz (PreferredGpuId=2)"]
        B2 -->|"LSFG 3.1 Perf + QueueTarget=0 (~3-4 ms)"| B3["1x Transferência PCIe Cross-Adapter"]
        B3 -->|"DWM Independent Flip (SwapEffectUpgrade=1)"| B4["Painel 144 Hz (Scanout 6,94 ms)"]
    end
```

Quando `PreferredGpuId = 0` (*Automático*) estava ativo no Lossless Scaling junto de `CaptureApi = WGC`, o aplicativo escolhia o adaptador dono da saída de vídeo (`Intel UHD Graphics`). Somado à cópia cruzada PCIe e ao `LSFGSize = BALANCED` em `FlowScale = 100%`, as unidades de execução da Intel UHD colapsavam para **~15 FPS (`~66,7 ms/frame`)** — piorando a taxa de quadros para metade da velocidade original do PS5!

Ao fixar **`PreferredGpuId = 2`** (GTX 1650), **`GpuPreference = 2;`** para ambos os binários (player + Lossless Scaling) e **`CaptureApi = DXGI`**, tanto a renderização do quadro capturado quanto a captura `IDXGIOutputDuplication` e a síntese `LSFG 3.1` ocorrem integralmente dentro da VRAM GDDR6 da GTX 1650, restando apenas **uma única transferência final via PCIe** do *backbuffer* pronto para o motor de *scanout* da Intel UHD.

### 3.2 DWM *BitBlt* vs. *Independent Flip* no Windows 11 25H2
Como o Lossless Scaling sobrepõe uma janela *borderless topmost* sobre o player (`ExclusiveFullscreen = 0`), a apresentação passa pelo **Desktop Window Manager (DWM)**:
- **Com `SwapEffectUpgradeEnable = 0` (*Otimizações para jogos em janela* desligado):** Aplicações DirectX 11 que criam swapchains no modo antigo `DXGI_SWAP_EFFECT_DISCARD` caem em apresentação **BitBlt**, exigindo cópia extra para superfície intermediária do DWM e espera pelo próximo ciclo de composição da área de trabalho (**+8 ms a +16 ms**).
- **Com `SwapEffectUpgradeEnable = 1` + `GameDVR_Enabled = 0`:** O runtime DirectX 11 promove automaticamente a swapchain para **Flip Model** (`DXGI_SWAP_EFFECT_FLIP_DISCARD`), habilitando *DirectFlip / Independent Flip* (ou *Composed: Flip* otimizado em MSHybrid) e removendo hooks de gravação em segundo plano do Xbox Game Bar (**economia combinada de 11 ms a 24 ms**).

---

## 4. Estados Dinâmicos de Energia (`P-states`) na GTX 1650 e Controle via `nvapi64.dll`

### 4.1 A Descoberta do Downclock Silencioso (`645 MHz` vs. `1785 MHz`)
Durante a telemetria real com `nvidia-smi` sob carga simultânea de captura e transmissão no OBS Studio, identificou-se uma anomalia crítica: como o pipeline de vídeo em `30 FPS` gera rajadas curtas e periódicas de *compute* (em vez de 100% de carga contínua típica de um jogo 3D nativo), a heurística padrão de energia do driver NVIDIA (*Optimal Power*) rebaixava a GTX 1650 para estados intermediários de economia, travando o clock gráfico em **`645 MHz`** (contra o boost nominal de **`1785 MHz`** em `P0`).

$$\text{Fator de penalidade de clock} = \frac{1785\text{ MHz}}{645\text{ MHz}} \approx 2,77\times$$

Na prática, um *dispatch* de *compute shader* do LSFG 3.1 que leva **~3,5 ms** a `1785 MHz` passava a consumir **~10 ms a 12 ms** a `645 MHz`, injetando **+7 ms a +9 ms de latência morta** em todo único quadro sintetizado.

### 4.2 Automação Cirúrgica no Banco Binário NVIDIA DRS
Em vez de forçar *Prefer Maximum Performance* globalmente (o que impediria a GPU do notebook de entrar em `P8` a `300–345 MHz` na bateria ou em uso de escritório), o script [`scripts/Configure-NvidiaDrsLowLatency.ps1`](../scripts/Configure-NvidiaDrsLowLatency.ps1) consome diretamente a biblioteca oficial **`nvapi64.dll`** via `nvapi_QueryInterface` e grava três diretivas por executável (`losslessscaling.exe`, `mpc-be64.exe` e `obs64.exe`):

1. **`PREFERRED_PSTATE_ID` (`0x1057EB71`) = `0x00000001` (*Prefer Maximum Performance*):** Mantém a GTX 1650 em estado `P0` (`~1785 MHz`) do primeiro ao último segundo de execução do player/interpolador, liberando `P8` (`~345 MHz`, `~45–53 °C`) imediatamente ao fechar o aplicativo.
2. **`VSYNCMODE_ID` (`0x00A879CF`) = `0x08416747` (*Force Off*):** Impede qualquer retenção de *backbuffer* pelo driver NVIDIA.
3. **`PRERENDERLIMIT_ID` (`0x007BA09E`) = `0x00000001` (*Maximum Pre-Rendered Frames = 1*):** Restringe a fila de comandos CPU->GPU a 1 único quadro em voo.

---

## 5. Engenharia de Captura USB 3.0 (`UGREEN 15390` / `MS2131`): `YUY2` vs. `MJPEG`

### 5.1 Topologia Composta do Chipset `MacroSilicon MS2131`
A placa de captura **`UGREEN 15390`** (`USB\VID_345F&PID_2131`) enumera no barramento USB 3.0 SuperSpeed (`5 Gbps`) como um dispositivo composto de múltiplas interfaces:
- **`MI_00` (`Class: Camera`):** Endpoint UVC de vídeo não-comprimido (`YUY2`) ou comprimido (`MJPEG`).
- **`MI_02` (`Class: MEDIA` / `AudioEndpoint`):** `Interface de áudio digital (UGREEN 15390)` operando via WASAPI em PCM `48 kHz` estéreo de 16 bits.
- **`MI_04` (`Class: HID`):** Canal auxiliar de controle de hardware.

### 5.2 Por Que `YUY2` na USB 3.0 é Obrigatório (e `MJPEG` Deve Ser Evitado)

| Formato UVC | Subamostragem | Banda em `1080p30` | Banda em `1080p60` | Latência de Codec | Impacto no Fluxo Óptico LSFG 3.1 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`YUY2` (Ideal)** | **4:2:2 Raw** (16 bpp) | **124,42 MB/s** (`995 Mbps`) | 248,83 MB/s (`1,99 Gbps`) | **~0 ms (Zero compressão)** | **Bordas limpas, vetores de movimento precisos.** |
| **`MJPEG`** | 4:2:0 / 4:2:2 JPEG | ~15–35 MB/s | ~25–50 MB/s | **+8 ms a +18 ms** (Encode ASIC + Decode CPU) | Macroblocos DCT $8\times 8$ e *mosquito noise* enganam o estimador óptico ao redor do HUD. |

> [!IMPORTANT]
> **Requisito Físico USB 3.0:** Uma porta USB 2.0 High-Speed possui teto teórico de `480 Mbps` (~`40 MB/s` úteis), fisicamente incapaz de transportar `995 Mbps` do `YUY2 1080p30`. Se conectada a uma porta USB 2.0 ou hub barato, a `UGREEN 15390` oculta o formato `YUY2 1080p` e força fallback silencioso para `MJPEG` (+8 a +18 ms de atraso e perda severa de nitidez).

### 5.3 Conflito de Recursos USB (`0x800705AA`) e Suspensão Seletiva
Nos logs reais do OBS Studio (`%APPDATA%\obs-studio\logs`), a presença simultânea de múltiplas fontes `dshow_input` apontando para a mesma `UGREEN 15390` dispara:
`DShow: Run failed (0x800705AA): Insufficient system resources exist to complete the requested service.`

Isso ocorre porque a primeira fonte reserva a fatia de banda do controlador host xHCI para o fluxo UVC de alta vazão; tentativas concorrentes (ou abrir `mpc-be64.exe` e `obs64.exe` ao mesmo tempo) falham ou derrubam o endpoint de áudio (`Device invalidated`). Além disso, manter a **Suspensão Seletiva USB Desabilitada (`0x0` em AC e DC)** impede o Windows de negociar estados de economia U1/U2 na raiz xHCI durante telas escuras de carregamento.

---

## 6. Análise Física do Piso Teórico Irredutível (`33,33 ms`) vs. Latência Parasita

Engenharia séria exige distinguir com transparência absoluta **latência física/algorítmica irredutível** de **latência parasita de software/configuração**.

### 6.1 Por Que Todo Interpolador `30 -> 60 FPS` Possui Piso Algorítmico de `33,33 ms`
Diferentemente de técnicas de *extrapolação/reprojeção* com acesso aos vetores de profundidade e matriz de câmera interna da engine (impossíveis sobre um sinal HDMI externo fechado), um interpolador temporal de vídeo precisa sintetizar o quadro intermediário $F_{t + 0.5}$ posicionado exatamente entre $F_t$ e $F_{t + 1}$:

$$F_{t + 0.5} = \Phi_{\text{LSFG}}\!\left(F_t,\; F_{t+1}\right)$$

Pelo **princípio da causalidade física**, o computador **não pode adivinhar o conteúdo de $F_{t+1}$ antes que o PS5 termine de enviá-lo pela porta HDMI**. Logo:
1. No instante $t = 0\text{ ms}$, chega $F_t$. Ele é retido por 1 período de quadro de entrada enquanto se aguarda $F_{t+1}$.
2. No instante $t = 33,33\text{ ms}$, chega $F_{t+1}$. Nesse exato momento, o pipeline exibe a sequência sincronizada e dispara a síntese de $F_{t+0.5}$ em `~3,5 ms` para exibição no meio do intervalo seguinte (`+16,67 ms`).

Portanto, **qualquer** geração de quadros por interpolação temporal sobre fonte externa de 30 FPS carrega um **custo algorítmico mínimo irredutível de $T_{\text{base}} = \frac{1000}{30} = 33,33\text{ ms}$** em troca de dobrar a resolução temporal percebida pelo sistema visual humano (`30 Hz -> 60 Hz`).

### 6.2 Equação Completa de Latência e Eliminação da Gordura Parasita

Podemos decompor a latência total adicionada pelo PC receptor ($L_{\text{PC}}$) em duas parcelas:

$$L_{\text{PC}} = \underbrace{\left(L_{\text{USB+UVC}} + T_{\text{hold\_30fps}} + L_{\text{shader\_P0}} + L_{\text{scanout\_144Hz}}\right)}_{L_{\text{física\_mínima}} \;\approx\; 48\text{–}55\text{ ms}} + \underbrace{\left(\Delta L_{\text{Queue}} + \Delta L_{\text{PState}} + \Delta L_{\text{DWM}} + \Delta L_{\text{GameDVR}} + \Delta L_{\text{OBS\_Scene}}\right)}_{L_{\text{parasita}}}$$

Antes da intervenção, $L_{\text{parasita}}$ somava **entre `+55 ms` e `> +95 ms` extras** (chegando ao colapso de `> 150 ms` quando caía em ~15 FPS na iGPU), tornando a mira e direção de veículos pesadas e atrasadas. Após a arquitetura de dois perfis documentada neste repositório:

- $\Delta L_{\text{Queue}}$ (`QueueTarget: 1 -> 0`): **zerado** (`-16,7 ms a -33,3 ms`)
- $\Delta L_{\text{PState}}$ (`645 MHz -> 1785 MHz` + `LS1 Off` + `Performance`): **zerado** (`-7 ms a -9 ms`, ou fim do colapso de `66,7 ms` da iGPU)
- $\Delta L_{\text{DWM}}$ (`BitBlt -> Independent Flip`): **zerado** (`-8 ms a -16 ms`)
- $\Delta L_{\text{GameDVR}}$ (`GameDVR_Enabled: 1 -> 0`): **zerado** (`-3 ms a -8 ms`)
- $\Delta L_{\text{OBS\_Scene}}$ (Bypass via `MPC-BE EVR-CP` fora de live): **zerado** (`-20 ms a -35 ms`)

O resultado aproxima assintoticamente o sistema do **piso físico teórico absoluto** permitido pelas leis de amostragem de sinais a 30 FPS em 144 Hz, entregando resposta imediata ao DualSense com fluidez visual sólida de **60 FPS**.
