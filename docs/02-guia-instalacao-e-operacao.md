# 02 — Guia Passo a Passo de Instalação, Operação Dual-Profile e Troubleshooting

Este guia descreve a implantação completa do ambiente de baixa latência no Windows 11 e o fluxo operacional diário para jogar no **Modo 1 (Fora de Live — Menor Input Lag via MPC-BE)** ou transmitir no **Modo 2 (Em Live — OBS Studio + NVENC)** mantendo **`30 / 60 FPS`** cravados.

---

## Sumário

1. [Checklist Físico: PS5 + Cabo HDMI + Porta USB 3.0](#1-checklist-físico-ps5--cabo-hdmi--porta-usb-30)
2. [Implantação Inicial (Scripts Windows, NVIDIA DRS e Perfis)](#2-implantação-inicial-scripts-windows-nvidia-drs-e-perfis)
3. [Modo 1: Operação Fora de Live (MPC-BE x64 + LSFG 3.1)](#3-modo-1-operação-fora-de-live-mpc-be-x64--lsfg-31)
4. [Modo 2: Operação Em Live / Gravação (OBS Studio x64 + LSFG 3.1)](#4-modo-2-operação-em-live--gravação-obs-studio-x64--lsfg-31)
5. [Auditoria Automática em Tempo Real (`Test-CapturePipelineHealth.ps1`)](#5-auditoria-automática-em-tempo-real-test-capturepipelinehealthps1)
6. [Matriz Completa de Troubleshooting (Sintoma -> Causa -> Solução)](#6-matriz-completa-de-troubleshooting-sintoma---causa---solução)

---

## 1. Checklist Físico: PS5 + Cabo HDMI + Porta USB 3.0

1. **Ajustes de Tela e Vídeo no PlayStation 5:**
   - **Resolução:** `1080p` (evita downscale extra dentro da placa de captura).
   - **HDR:** `Desativado` (a `UGREEN 15390` `MS2131` opera em pipeline SDR 8-bit `YUY2`; manter HDR desligado evita lavagem de cores / *tone mapping* incorreto).
   - **VRR / Saída de 120 Hz:** `Desativado`.
   - **Intervalo RGB:** `Limitado` (alinhado ao `YUY2` Rec. 709 Parcial `16–235`, preservando detalhes de sombra sem *black crush*).
   - **HDCP:** Se a imagem ficar preta na captura, desative em *Configurações -> Sistema -> HDMI -> Habilitar HDCP* (necessário para captura direta via USB).
2. **Conexão Direta USB 3.0 SuperSpeed:**
   - Conecte a **`UGREEN 15390`** (`VID_345F&PID_2131`) **diretamente** em uma porta **USB 3.0 / 3.1 / 3.2 (azul ou SS)** da placa-mãe do notebook.
   - **Jamais utilize hubs USB passivos ou portas USB 2.0:** sem banda SuperSpeed (`5 Gbps`), o modo `YUY2 1920x1080 @ 30 fps` (`124,4 MB/s`) desaparece ou falha.
3. **Painel Interno do Notebook em `144 Hz`:**
   - Em *Configurações do Windows -> Sistema -> Tela -> Exibição avançada*, confirme que a taxa de atualização está em **`144 Hz`**.

---

## 2. Implantação Inicial (Scripts Windows, NVIDIA DRS e Perfis)

Abra um terminal **PowerShell como Administrador** na raiz deste repositório e execute na ordem abaixo:

### Passo 2.1 — Otimizar Pilha Gráfica Windows 11 (DWM Flip, GameDVR, Game Mode e USB)
```powershell
# 1. Auditar estado atual (somente leitura)
.\scripts\Optimize-WindowsLowLatency.ps1 -CheckOnly

# 2. Aplicar otimizações (cria backup JSON automático em .\backups\)
.\scripts\Optimize-WindowsLowLatency.ps1
```

### Passo 2.2 — Configurar Clocks `P0` (`~1785 MHz`) e Fila Mínima via `nvapi64.dll`
```powershell
# 1. Auditar banco NVIDIA DRS atual
.\scripts\Configure-NvidiaDrsLowLatency.ps1 -CheckOnly

# 2. Gravar perfis para losslessscaling.exe, mpc-be64.exe e obs64.exe (requer Admin)
.\scripts\Configure-NvidiaDrsLowLatency.ps1
```

### Passo 2.3 — Importar Perfis de Referência do Lossless Scaling
1. Feche o **Lossless Scaling** caso esteja aberto.
2. Faça um backup do seu arquivo atual `%LOCALAPPDATA%\Lossless Scaling\Settings.xml` (se existir).
3. Copie [`configs/lossless-scaling/Settings.reference.xml`](../configs/lossless-scaling/Settings.reference.xml) para:
   ```text
   %LOCALAPPDATA%\Lossless Scaling\Settings.xml
   ```
4. Abra o Lossless Scaling e verifique na seção **GPU & Display** dos perfis `MPC-BE - GTA 6 (60 FPS)` e `OBS - GTA 6 (60 FPS)` se **GPU Preferida** está apontando para **`NVIDIA GeForce GTX 1650`** (`PreferredGpuId = 2` na maioria dos notebooks Optimus; ajuste no menu caso o índice da sua dGPU seja `1`).

---

## 3. Modo 1: Operação Fora de Live (`MPC-BE x64` + `LSFG 3.1`)

> [!TIP]
> **Use sempre este modo quando NÃO estiver transmitindo ou gravando!** Ele acessa a `UGREEN 15390` diretamente via grafo DirectShow enxuto (`EVR-CP` + `WASAPI`), eliminando de **20 ms a 35 ms** de latência da cena/compositor do OBS Studio.

### 3.1 Configuração Única no MPC-BE 1.9.3+ (x64)
Você pode usar [`configs/mpc-be/mpc-be64.reference.ini`](../configs/mpc-be/mpc-be64.reference.ini) como base ou confirmar pela interface (`Exibir -> Opções` / tecla `O`):
1. **Vídeo (`Vídeo`):**
   - **Renderizador de vídeo:** `Enhanced Video Renderer (custom presenter)` (`VideoRenderer=3`).
   - **Buffers EVR:** `4` (`EVRBuffers=4`).
   - Desmarque **Tela cheia exclusiva (D3D Fullscreen)** (`ExclusiveFullscreen=0`) — obrigatório para o DWM Independent Flip e para o overlay do Lossless Scaling funcionar!
   - Em *Sincronização*, deixe **VSync** e **VSync Interno** **desmarcados** (`VSync=0`, `VSyncInternal=0`).
2. **Áudio (`Áudio`):**
   - **Renderizador de áudio:** `MPC Audio Renderer` (opera via WASAPI com baixa latência e zero filtros extras).
3. **Formato de Captura (`Reprodução -> Captura` e `Arquivo -> Abrir Dispositivo` / `Ctrl + V`):**
   - Selecione **Vídeo:** `UGREEN 15390` e **Áudio:** `Interface de áudio digital (UGREEN 15390)`.
   - Ao abrir o dispositivo (`Ctrl + V`), acesse as propriedades do filtro/pino de captura (`Exibir -> Opções` ou menu de filtros -> `UGREEN 15390` -> *Pin/Capture Format*) e selecione **exatamente**:
     - **Espaço de Cor / Compressão:** `YUY2`
     - **Dimensão de Saída:** `1920 x 1080`
     - **Taxa de Quadros:** **`30.000`** (`AvgTimePerFrame = 333333`) — **NÃO deixe em `60.000`!**

### 3.2 Rotina Rápida Antes de Jogar (Modo Offline)
1. Certifique-se de que o **OBS Studio (`obs64.exe`) está completamente fechado** (inclusive na bandeja do relógio).
2. Abra o **Lossless Scaling** (ele já deve iniciar como Administrador com os perfis carregados).
3. Abra o **MPC-BE x64**, pressione **`Ctrl + V`** para abrir o sinal do PS5 e coloque em tela cheia (**`Alt + Enter`** ou duplo clique).
4. Com o foco na janela em tela cheia do MPC-BE, pressione **`Ctrl + Alt + S`**.
5. **Validação imediata no canto da tela:** o contador de FPS do Lossless Scaling deve cravar em **`30 / 60`**.

---

## 4. Modo 2: Operação Em Live / Gravação (`OBS Studio x64` + `LSFG 3.1`)

> [!WARNING]
> **Regra de Exclusividade DirectShow:** Antes de abrir o OBS Studio, **feche totalmente o MPC-BE (`mpc-be64.exe`)**. Dois processos nunca podem abrir o endpoint UVC da `UGREEN 15390` ao mesmo tempo.

### 4.1 Configuração Limpa no OBS Studio (Referência: `basic.video-reference.ini`)
Consulte [`configs/obs-studio/basic.video-reference.ini`](../configs/obs-studio/basic.video-reference.ini) e confira no OBS Studio:
1. **Executar sempre como Administrador:** Clique com o botão direito no atalho do `obs64.exe` -> *Propriedades -> Compatibilidade -> Executar este programa como administrador* (garante prioridade de agendamento GPU no Windows).
2. **Configurações -> Vídeo:**
   - **Resolução de Base (Tela):** `1920x1080`
   - **Resolução de Saída (Escalada):** `1920x1080`
   - **Valores Comuns de FPS:** **`30`** (essencial para jogos nativos de 30 FPS como GTA 6!).
3. **Limpeza de Fontes de Cena (Prevenção do Erro `0x800705AA`):**
   - Verifique **todas as cenas** da sua Coleção de Cenas e **exclua fontes antigas/duplicadas** de Dispositivo de Captura de Vídeo. Deve existir **apenas UMA** fonte apontando para a `UGREEN 15390` (se precisar dela em outra cena, use *Adicionar Existente / Referência*, jamais crie uma segunda instância!).
4. **Propriedades da Fonte `UGREEN 15390`:**
   - **Dispositivo:** `UGREEN 15390`
   - **Tipo de Resolução/FPS:** `Personalizado`
   - **Resolução:** `1920x1080`
   - **FPS:** **`30`**
   - **Formato de Vídeo:** **`YUY2`**
   - **Espaço de Cor:** `Rec. 709` | **Faixa de Cores:** `Parcial`
   - **Buffering:** **`Desativado`** (reduz de 16 ms a 33 ms de latência na prévia!).
   - **Modo de Saída de Áudio:** `Capturar apenas áudio` -> marque *Usar dispositivo de áudio personalizado* -> selecione `Interface de áudio digital (UGREEN 15390)`.
   - Clique na engrenagem do Mixer de Áudio -> **Propriedades de Áudio Avançadas** -> na fonte da UGREEN, mude *Monitoramento de Áudio* para **`Monitorar e enviar saída`**.

### 4.2 Rotina Rápida para Transmitir e Jogar a 60 FPS (Modo Live)
1. Confirme que `mpc-be64.exe` está fechado e abra o **OBS Studio** e o **Lossless Scaling**.
2. No OBS Studio, clique com o botão direito sobre a prévia do jogo -> **Projetor em Tela Cheia (Prévia)** -> selecione o monitor interno (`1920x1080 @ 144 Hz`).
3. Clique uma vez sobre a janela do **Projetor em Tela Cheia** para dar foco a ela e pressione **`Ctrl + Alt + S`**.
4. **Validação imediata:** o contador do Lossless Scaling deve exibir **`30 / 60`** (você joga a 60 FPS fluidos na tela de 144 Hz enquanto os espectadores assistem à transmissão NVENC limpa em 1080p30 sem artefatos!).

---

## 5. Auditoria Automática em Tempo Real (`Test-CapturePipelineHealth.ps1`)

Sempre que quiser validar se todas as camadas estão saudáveis (com o jogo aberto ou antes de iniciar), execute em qualquer janela PowerShell (não exige Administrador e é **100% somente leitura**):

```powershell
.\scripts\Test-CapturePipelineHealth.ps1
```

O script verifica instantaneamente:
- Se há conflito simultâneo entre `obs64.exe` e `mpc-be64.exe`;
- Se a `UGREEN 15390` está enumerada com `Status = OK` ou desconectada (`CM_PROB_PHANTOM`);
- Clock real da GTX 1650 (`~1785 MHz` em carga vs. alerta se cair abaixo de `1200 MHz`), uso 3D (`< 85%`), VRAM e temperatura (`< 83 °C`);
- Decodificação binária do `VidFormat` do MPC-BE e inspeção do último log do OBS contra os bugs `60 FPS (interval 166666)` e `0x800705AA`.

---

## 6. Matriz Completa de Troubleshooting (Sintoma -> Causa -> Solução)

| Sintoma Observado | Causa Raiz Técnica | Solução Direta |
| :--- | :--- | :--- |
| Contador do Lossless Scaling mostra **`60 / 120`** e a imagem engasga (*judder*) | A captura no MPC-BE ou na fonte do OBS está em **`60 FPS`** (`AvgTimePerFrame=166666`), recebendo quadros duplicados `A, A, B, B` do container HDMI 60 Hz do PS5. | Altere o pino de captura da `UGREEN 15390` para **`30.000 fps`** (`1920x1080 YUY2`) no MPC-BE ou na fonte do OBS (`FPS = 30`). O contador passará para **`30 / 60`**. |
| FPS despenca para **`~15 FPS`** e o controle responde com meio segundo de atraso | O Lossless Scaling ou o player iniciou na **`Intel UHD Graphics`** (`PreferredGpuId=0`) em vez da **`GTX 1650`**. | Em `Settings.xml` / UI do Lossless Scaling, selecione explicitamente **`NVIDIA GeForce GTX 1650`** (`PreferredGpuId=2`) e rode `.\scripts\Optimize-WindowsLowLatency.ps1`. |
| Tela preta no MPC-BE ou erro `0x800705AA` no log do OBS | 1) MPC-BE e OBS abertos juntos; 2) Múltiplas fontes `dshow_input` no OBS; ou 3) HDCP ativo no PS5. | 1) Feche totalmente um dos dois apps; 2) Deixe **apenas 1** fonte `UGREEN 15390` em toda a coleção de cenas do OBS; 3) Desative *Habilitar HDCP* no PS5. |
| `UGREEN 15390` não aparece ou `Test-CapturePipelineHealth.ps1` acusa `CM_PROB_PHANTOM` | Cabo desconectado, mau contato ou porta/hub sem alimentação suficiente. | Conecte a `UGREEN 15390` diretamente em uma porta **USB 3.0** física do notebook, aguarde 3 segundos e rode novamente `.\scripts\Test-CapturePipelineHealth.ps1`. |
| Formato `YUY2` só oferece `720p` ou `10 fps` (só aparece `1080p` em `MJPEG`) | A placa foi negociada em protocolo **USB 2.0** (`480 Mbps`) por porta errada, adaptador USB-C simples ou encaixe lento/parcial. | Troque para uma porta USB 3.0 azul/SuperSpeed e encaixe o conector de forma firme e rápida até o fim. |
| Latência sobe sutilmente após alguns minutos no OBS (`nvidia-smi` mostra `~645 MHz`) | Perfil NVIDIA DRS ausente ou sobrescrito após instalação limpa (*Clean Install*) de driver NVIDIA. | Reexecute `.\scripts\Configure-NvidiaDrsLowLatency.ps1` como Administrador para restaurar `Prefer Maximum Performance (0x1)` nos 3 executáveis. |
| Sem som do PS5 no Modo Live (OBS) | Monitoramento de áudio desligado por padrão na fonte do OBS. | Em *Propriedades de Áudio Avançadas* do OBS, mude a fonte da `UGREEN 15390` para **`Monitorar e enviar saída`**. |
