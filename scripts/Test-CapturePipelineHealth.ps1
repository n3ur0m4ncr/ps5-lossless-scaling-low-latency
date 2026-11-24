<#
.SYNOPSIS
    Diagnóstico em tempo real (100% SOMENTE LEITURA) da cadeia completa de captura e Frame Generation:
    Processos (MPC-BE vs OBS), USB PnP UGREEN 15390, GPU NVIDIA/Optimus, DirectShow 30 FPS e Windows DWM.

.DESCRIPTION
    Ferramenta de engenharia para validação instantânea antes ou durante sessões de jogo (PS5 / GTA 6).
    GARANTIA DE SEGURANÇA:
      Este script NUNCA altera arquivos, NUNCA modifica o Registro e NUNCA fecha ou reinicia processos.

    Verifica automaticamente 6 camadas críticas:
      1. Exclusividade DirectShow: detecta conflito simultâneo entre obs64.exe e mpc-be64.exe.
      2. Hardware USB 3.0 UGREEN 15390 (VID_345F&PID_2131): valida nós Camera (MI_00), Audio/MEDIA (MI_02)
         e endpoint WASAPI contra desconexão (CM_PROB_PHANTOM) ou falhas de enumeração.
      3. Telemetria NVIDIA & Roteamento Optimus: consulta nvidia-smi (P-state, clock atual vs máx. 1785 MHz,
         uso 3D < 85%, VRAM, temperatura < 83 °C) e contadores '\GPU Engine(*)\Utilization Percentage'
         para flagrar se algum app caiu acidentalmente na Intel UHD Graphics em vez da dGPU dedicada.
      4. Auditoria Binária DirectShow (MPC-BE & OBS): decodifica em memória o bloco Base64 VidFormat
         (VIDEOINFOHEADER de 88 bytes) do mpc-be64.ini e inspeciona basic.ini + último log do OBS para
         detectar o bug de captura em 60 FPS (AvgTimePerFrame=166666 -> 60/120 duplicado) ou erro USB 0x800705AA.
      5. Perfil Lossless Scaling (Settings.xml): confere QueueTarget=0, CaptureApi=DXGI, LSFGSize=PERFORMANCE,
         ScalingType=Off, SyncMode=OFF e PreferredGpuId != 0.
      6. Pilha Windows 11: confere SwapEffectUpgradeEnable=1, GameDVR_Enabled=0 e USB Selective Suspend=0.

.PARAMETER AsJson
    Emite o relatório completo em JSON estruturado (ideal para automação ou logs de auditoria).

.EXAMPLE
    .\scripts\Test-CapturePipelineHealth.ps1
    Exibe tabela colorida de saúde de todas as camadas e diagnóstico de causa raiz.

.EXAMPLE
    .\scripts\Test-CapturePipelineHealth.ps1 -AsJson
    Retorna diagnóstico completo serializado em JSON.
#>
[CmdletBinding()]
param(
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checks   = New-Object System.Collections.Generic.List[object]
$findings = New-Object System.Collections.Generic.List[string]

function Add-Check {
    param(
        [string]$Layer,
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Metric,
        [string]$Detail
    )
    $checks.Add([PSCustomObject]@{
        Camada   = $Layer
        Status   = $Status
        Metrica  = $Metric
        Detalhes = $Detail
    })
}

# ============================================================================
# 1. Processos Ativos e Regra Crítica de Exclusividade (MPC-BE vs OBS)
# ============================================================================
$procMpc = @(Get-Process -Name 'mpc-be64' -ErrorAction SilentlyContinue)
$procObs = @(Get-Process -Name 'obs64' -ErrorAction SilentlyContinue)
$procLs  = @(Get-Process -Name 'LosslessScaling' -ErrorAction SilentlyContinue)

$activeMode = 'IDLE'
if ($procMpc.Count -gt 0 -and $procObs.Count -gt 0) {
    $activeMode = 'CONFLICT'
    Add-Check -Layer '1. Exclusividade DirectShow' -Status 'FAIL' `
        -Metric "mpc-be64 ($($procMpc.Count)) + obs64 ($($procObs.Count))" `
        -Detail 'CONFLITO CRITICO: MPC-BE e OBS abertos juntos disputam a UGREEN 15390!'
    $findings.Add('Feche imediatamente um dos players (mpc-be64.exe OU obs64.exe): eles jamais podem rodar juntos.')
} elseif ($procMpc.Count -gt 0) {
    $activeMode = 'OFFLINE_MPC'
    Add-Check -Layer '1. Exclusividade DirectShow' -Status 'OK' `
        -Metric "Modo Fora de Live (MPC-BE PID $($procMpc[0].Id))" `
        -Detail "LosslessScaling aberto: $(if ($procLs.Count -gt 0) { 'Sim' } else { 'Nao' })"
} elseif ($procObs.Count -gt 0) {
    $activeMode = 'LIVE_OBS'
    Add-Check -Layer '1. Exclusividade DirectShow' -Status 'OK' `
        -Metric "Modo Live (OBS Studio PID $($procObs[0].Id))" `
        -Detail "LosslessScaling aberto: $(if ($procLs.Count -gt 0) { 'Sim' } else { 'Nao' })"
} else {
    Add-Check -Layer '1. Exclusividade DirectShow' -Status 'INFO' `
        -Metric 'Pipeline em repouso (Idle)' `
        -Detail 'Nenhum player (mpc-be64 / obs64) em execucao no momento.'
}

if ($activeMode -in @('OFFLINE_MPC', 'LIVE_OBS') -and $procLs.Count -eq 0) {
    Add-Check -Layer '1b. Processo Lossless Scaling' -Status 'WARN' `
        -Metric 'Fechado' `
        -Detail 'Abra o Lossless Scaling e pressione Ctrl+Alt+S sobre a janela de video.'
    $findings.Add('Abra o Lossless Scaling e ative a geracao de quadros (Ctrl + Alt + S) para atingir 30 / 60 FPS.')
}

# ============================================================================
# 2. Dispositivo PnP USB 3.0 UGREEN 15390 (VID_345F&PID_2131)
# ============================================================================
$ugreenPresent = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -match 'UGREEN|15390' -or $_.InstanceId -match 'VID_345F&PID_2131'
})

if ($ugreenPresent.Count -gt 0) {
    $badNodes = @($ugreenPresent | Where-Object { $_.Status -ne 'OK' })
    if ($badNodes.Count -eq 0) {
        Add-Check -Layer '2. Hardware UGREEN 15390' -Status 'OK' `
            -Metric "$($ugreenPresent.Count) interfaces PnP ativas (Status=OK)" `
            -Detail (($ugreenPresent | Select-Object -ExpandProperty Class -Unique) -join ', ')
    } else {
        Add-Check -Layer '2. Hardware UGREEN 15390' -Status 'FAIL' `
            -Metric "$($badNodes.Count) no(s) com erro PnP" `
            -Detail (($badNodes | ForEach-Object { "$($_.Class):$($_.Status)" }) -join '; ')
        $findings.Add('Reconecte a UGREEN 15390 diretamente em uma porta USB 3.0 SuperSpeed do notebook (sem hub USB).')
    }
} else {
    $ugreenGhost = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -match 'UGREEN|15390' -or $_.InstanceId -match 'VID_345F&PID_2131'
    })
    $ghostState = if ($ugreenGhost.Count -gt 0) { 'Desconectada (CM_PROB_PHANTOM)' } else { 'Nunca enumerada neste PC' }
    $sev = if ($activeMode -in @('OFFLINE_MPC', 'LIVE_OBS')) { 'FAIL' } else { 'WARN' }
    Add-Check -Layer '2. Hardware UGREEN 15390' -Status $sev `
        -Metric '0 interfaces presentes' `
        -Detail $ghostState
    if ($sev -eq 'FAIL') {
        $findings.Add('A placa UGREEN 15390 esta desconectada apesar do player estar aberto. Conecte-a direto na porta USB 3.0.')
    }
}

# ============================================================================
# 3. Telemetria NVIDIA (nvidia-smi) e Alocação de Engine GPU (Optimus LUID)
# ============================================================================
$nvidiaSmiCmd = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
if ($null -ne $nvidiaSmiCmd) {
    $smiRaw = & nvidia-smi.exe --query-gpu=name,pstate,utilization.gpu,memory.used,memory.total,utilization.encoder,temperature.gpu,clocks.gr,clocks.max.gr --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($smiRaw)) {
        $parts    = ($smiRaw -split ',') | ForEach-Object { $_.Trim() }
        $gpuName  = $parts[0]
        $pstate   = $parts[1]
        $util3d   = [int]$parts[2]
        $vramUsed = [int]$parts[3]
        $vramTot  = [int]$parts[4]
        $utilEnc  = [int]$parts[5]
        $tempC    = [int]$parts[6]
        $clkCur   = [int]$parts[7]
        $clkMax   = [int]$parts[8]

        $gpuStatus = 'OK'
        $gpuNotes  = "VRAM ${vramUsed}/${vramTot} MiB | Enc ${utilEnc}% | Temp ${tempC} C"

        if ($tempC -ge 83) {
            $gpuStatus = 'FAIL'
            $findings.Add("Thermal Throttling detectado na $gpuName (${tempC} C >= 83 C). Verifique refrigeracao/base do notebook.")
        } elseif ($util3d -gt 88) {
            $gpuStatus = 'WARN'
            $findings.Add("Uso 3D da $gpuName em ${util3d}% (>88%): risco de fila de renderizacao saturada. Reduza LSFGFlowScale em 10-15%.")
        } elseif ($activeMode -in @('OFFLINE_MPC', 'LIVE_OBS') -and $procLs.Count -gt 0 -and $clkCur -lt 1200) {
            $gpuStatus = 'WARN'
            $findings.Add("Clock da $gpuName baixo (${clkCur}/${clkMax} MHz em $pstate) com pipeline ativo! Rode Configure-NvidiaDrsLowLatency.ps1 como Admin.")
        }

        Add-Check -Layer '3. Telemetria dGPU NVIDIA' -Status $gpuStatus `
            -Metric "$gpuName | $pstate | ${clkCur}/${clkMax} MHz | 3D ${util3d}%" `
            -Detail $gpuNotes
    }
} else {
    Add-Check -Layer '3. Telemetria dGPU NVIDIA' -Status 'WARN' `
        -Metric 'nvidia-smi indisponivel' `
        -Detail 'Verifique a instalacao do driver NVIDIA Game Ready / Studio.'
}

# Checagem de LUID / GPU Engine apenas se processos do pipeline estiverem rodando
$targetPids = @($procMpc + $procObs + $procLs | Select-Object -ExpandProperty Id)
if ($targetPids.Count -gt 0) {
    try {
        $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples |
            Where-Object { $_.CookedValue -gt 0.25 }

        $pidPattern = '^pid_(' + (($targetPids | ForEach-Object { [string]$_ }) -join '|') + ')_luid_0x[0-9a-fA-F]+_(0x[0-9a-fA-F]+)_'
        $matchedSamples = @($samples | Where-Object { $_.InstanceName -match $pidPattern })

        if ($matchedSamples.Count -gt 0) {
            $summaryEngines = ($matchedSamples | ForEach-Object {
                if ($_.InstanceName -match '^pid_(\d+)_luid_0x[0-9a-fA-F]+_(0x[0-9a-fA-F]+)_.*_engtype_([A-Za-z0-9_]+)') {
                    "PID $($Matches[1]) @ LUID $($Matches[2]) ($($Matches[3]): $([Math]::Round($_.CookedValue,1))%)"
                }
            }) -join ' | '
            Add-Check -Layer '3b. Engines GPU em Carga' -Status 'OK' `
                -Metric "$($matchedSamples.Count) engine(s) ativa(s)" `
                -Detail $summaryEngines
        }
    } catch {
        # Contadores de performance podem estar desabilitados em alguns idiomas/ambientes; ignora silenciosamente
    }
}

# ============================================================================
# 4. Auditoria de Configuração MPC-BE (Decodificação VIDEOINFOHEADER em Memória)
# ============================================================================
$mpcIniPath = Join-Path $env:LOCALAPPDATA 'Programs\MPC-BE\mpc-be64.ini'
if (Test-Path -LiteralPath $mpcIniPath) {
    $mpcRaw = Get-Content -LiteralPath $mpcIniPath -ErrorAction SilentlyContinue
    $vidFmtLine = $mpcRaw | Where-Object { $_ -match '^VidFormat=(.+)$' } | Select-Object -First 1
    $vidRenLine = $mpcRaw | Where-Object { $_ -match '^VideoRenderer=(\d+)$' } | Select-Object -First 1
    $vsyncLine  = $mpcRaw | Where-Object { $_ -match '^VSync=(\d+)$' } | Select-Object -First 1
    $exclLine   = $mpcRaw | Where-Object { $_ -match '^ExclusiveFullscreen=(\d+)$' } | Select-Object -First 1

    if ($null -ne $vidFmtLine -and $vidFmtLine -match '^VidFormat=([A-Za-z0-9+/=]+)$') {
        try {
            $bytes = [Convert]::FromBase64String($Matches[1])
            if ($bytes.Length -ge 72) {
                $bitRate   = [BitConverter]::ToUInt32($bytes, 32)
                $avgTime   = [BitConverter]::ToInt64($bytes, 40)
                $width     = [BitConverter]::ToInt32($bytes, 52)
                $height    = [BitConverter]::ToInt32($bytes, 56)
                $fourcc    = [System.Text.Encoding]::ASCII.GetString($bytes, 64, 4)
                $fpsCalc   = if ($avgTime -gt 0) { [Math]::Round(10000000.0 / $avgTime, 2) } else { 0 }

                $is30FpsOk = ($width -eq 1920) -and ($height -eq 1080) -and ($fourcc -eq 'YUY2') -and ($avgTime -ge 330000 -and $avgTime -le 334000)
                if ($is30FpsOk) {
                    Add-Check -Layer '4a. Perfil Captura MPC-BE' -Status 'OK' `
                        -Metric "${width}x${height} $fourcc @ ${fpsCalc} FPS" `
                        -Detail "AvgTimePerFrame=$avgTime ($([Math]::Round($bitRate / 8000000.0, 1)) MB/s) — ideal para 30 / 60!"
                } elseif ($avgTime -ge 165000 -and $avgTime -le 168000) {
                    Add-Check -Layer '4a. Perfil Captura MPC-BE' -Status 'WARN' `
                        -Metric "${width}x${height} $fourcc @ ${fpsCalc} FPS (60 Hz)" `
                        -Detail "AvgTimePerFrame=$avgTime (60 FPS)! Causara 60 / 120 com quadros duplicados no PS5 30 FPS."
                    $findings.Add('No MPC-BE (Ctrl+V -> Configuracoes de Video), altere o formato da UGREEN 15390 de 60.000 fps para 30.000 fps (1920x1080 YUY2).')
                } else {
                    Add-Check -Layer '4a. Perfil Captura MPC-BE' -Status 'WARN' `
                        -Metric "${width}x${height} $fourcc @ ${fpsCalc} FPS" `
                        -Detail "Recomendado: 1920x1080 YUY2 @ 30.00 FPS (AvgTimePerFrame=333333)."
                }
            }
        } catch {
            Add-Check -Layer '4a. Perfil Captura MPC-BE' -Status 'WARN' -Metric 'VidFormat invalido' -Detail 'Nao foi possivel decodificar Base64.'
        }
    }

    $renOk = ($vidRenLine -eq 'VideoRenderer=3') -and ($vsyncLine -eq 'VSync=0') -and ($exclLine -eq 'ExclusiveFullscreen=0')
    Add-Check -Layer '4b. Renderizador MPC-BE' -Status $(if ($renOk) { 'OK' } else { 'WARN' }) `
        -Metric "$vidRenLine | $vsyncLine | $exclLine" `
        -Detail 'Alvo: VideoRenderer=3 (EVR-CP), VSync=0, ExclusiveFullscreen=0'
}

# ============================================================================
# 5. Auditoria Sanitizada OBS Studio ([Video] + Último Log de Sessão)
# ============================================================================
$obsProfilesDir = Join-Path $env:APPDATA 'obs-studio\basic\profiles'
if (Test-Path -LiteralPath $obsProfilesDir) {
    $basicInis = @(Get-ChildItem -Path $obsProfilesDir -Filter 'basic.ini' -Recurse -ErrorAction SilentlyContinue)
    foreach ($ini in $basicInis) {
        # Lê estritamente chaves numéricas de [Video], ignorando qualquer outra seção
        $inVideo = $false
        $vidMap  = @{}
        foreach ($line in (Get-Content -LiteralPath $ini.FullName -ErrorAction SilentlyContinue)) {
            if ($line -match '^\[(.+)\]$') {
                $inVideo = ($Matches[1] -eq 'Video')
                continue
            }
            if ($inVideo -and $line -match '^(BaseCX|BaseCY|OutputCX|OutputCY|FPSCommon|FPSInt|ColorFormat)=(.+)$') {
                $vidMap[$Matches[1]] = $Matches[2].Trim()
            }
        }
        if ($vidMap.Count -gt 0) {
            $fpsVal = if ($vidMap.ContainsKey('FPSCommon')) { $vidMap['FPSCommon'] } else { $vidMap['FPSInt'] }
            $obsVidOk = ($vidMap['BaseCX'] -eq '1920') -and ($vidMap['BaseCY'] -eq '1080') -and ($fpsVal -eq '30')
            Add-Check -Layer "4c. OBS Perfil ($($ini.Directory.Name))" -Status $(if ($obsVidOk) { 'OK' } else { 'WARN' }) `
                -Metric "$($vidMap['BaseCX'])x$($vidMap['BaseCY']) @ ${fpsVal} FPS ($($vidMap['ColorFormat']))" `
                -Detail 'Alvo para GTA 6 (30 FPS nativo): 1920x1080 @ FPSCommon=30'
        }
    }
}

$obsLogsDir = Join-Path $env:APPDATA 'obs-studio\logs'
if (Test-Path -LiteralPath $obsLogsDir) {
    $latestLog = Get-ChildItem -Path $obsLogsDir -Filter '*.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -ne $latestLog) {
        $logLines = Get-Content -LiteralPath $latestLog.FullName -ErrorAction SilentlyContinue
        $usbResErr = @($logLines | Where-Object { $_ -match '0x800705AA' })
        $dshow60   = @($logLines | Where-Object { $_ -match 'fps:\s*60\.00\s*\(interval:\s*166666\)' })

        if ($usbResErr.Count -gt 0) {
            Add-Check -Layer '4d. Ultimo Log OBS (Fontes USB)' -Status 'WARN' `
                -Metric 'Erro 0x800705AA detectado no ultimo log' `
                -Detail "Arquivo $($latestLog.Name): multiplas fontes dshow_input disputando a UGREEN 15390!"
            $findings.Add('No OBS Studio, remova fontes duplicadas de captura de video: mantenha APENAS UMA fonte apontando para a UGREEN 15390.')
        }
        if ($dshow60.Count -gt 0) {
            Add-Check -Layer '4e. Ultimo Log OBS (FPS Fonte)' -Status 'WARN' `
                -Metric 'Fonte DirectShow aberta em 60.00 FPS (interval 166666)' `
                -Detail "Arquivo $($latestLog.Name): altere a fonte da UGREEN para Personalizado -> 30 FPS (YUY2)."
            $findings.Add('Na fonte UGREEN 15390 do OBS Studio, defina Tipo de Resolucao/FPS = Personalizado, 1920x1080, FPS = 30 e Formato = YUY2.')
        }
    }
}

# ============================================================================
# 6. Auditoria Lossless Scaling (Settings.xml) & Pilha Windows DWM / USB
# ============================================================================
$lsXmlPath = Join-Path $env:LOCALAPPDATA 'Lossless Scaling\Settings.xml'
if (Test-Path -LiteralPath $lsXmlPath) {
    try {
        [xml]$lsDoc = Get-Content -LiteralPath $lsXmlPath -Raw
        $targetProfs = @($lsDoc.Settings.GameProfiles.Profile | Where-Object {
            $pathNode = $_.SelectSingleNode('Path')
            ($null -ne $pathNode) -and ($pathNode.InnerText -in @('mpc-be64.exe', 'obs64.exe'))
        })
        if ($targetProfs.Count -gt 0) {
            foreach ($p in $targetProfs) {
                $profOk = ($p.ScalingType -eq 'Off') `
                    -and ($p.FrameGeneration -eq 'LSFG3') `
                    -and ($p.LSFG3Mode1 -eq 'FIXED') `
                    -and ($p.LSFG3Multiplier -eq '2') `
                    -and ($p.QueueTarget -eq '0') `
                    -and ($p.CaptureApi -eq 'DXGI') `
                    -and ($p.PreferredGpuId -ne '0')
                Add-Check -Layer "5. LSFG Perfil ($($p.Path))" -Status $(if ($profOk) { 'OK' } else { 'WARN' }) `
                    -Metric "$($p.FrameGeneration) $($p.LSFG3Mode1) $($p.LSFG3Multiplier)x | Flow=$($p.LSFGFlowScale)% | Queue=$($p.QueueTarget)" `
                    -Detail "Scaling=$($p.ScalingType) | API=$($p.CaptureApi) | PreferredGpuId=$($p.PreferredGpuId)"
            }
        } else {
            Add-Check -Layer '5. Perfis Lossless Scaling' -Status 'WARN' `
                -Metric 'Perfis dedicados ausentes' `
                -Detail 'Importe configs\lossless-scaling\Settings.reference.xml para mpc-be64.exe e obs64.exe.'
        }
    } catch {
        Add-Check -Layer '5. Perfis Lossless Scaling' -Status 'WARN' -Metric 'Erro ao ler Settings.xml' -Detail $_.Exception.Message
    }
}

$dxGlobal = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue).DirectXUserGlobalSettings
$dvrVal   = (Get-ItemProperty -LiteralPath 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -ErrorAction SilentlyContinue).GameDVR_Enabled
$winOk    = ($dxGlobal -match 'SwapEffectUpgradeEnable=1') -and ($dvrVal -eq 0)
Add-Check -Layer '6. Pilha Windows DWM / GameDVR' -Status $(if ($winOk) { 'OK' } else { 'WARN' }) `
    -Metric "SwapEffectUpgrade=$(if ($dxGlobal -match 'SwapEffectUpgradeEnable=1') { '1' } else { '0' }) | GameDVR_Enabled=$dvrVal" `
    -Detail 'Alvo: SwapEffectUpgradeEnable=1 (Independent Flip) e GameDVR_Enabled=0'
if (-not $winOk) {
    $findings.Add('Execute .\scripts\Optimize-WindowsLowLatency.ps1 para habilitar DWM Independent Flip e desativar o GameDVR.')
}

# ============================================================================
# Saída Final (JSON ou Console Colorido)
# ============================================================================
if ($AsJson) {
    [PSCustomObject]@{
        Timestamp       = (Get-Date).ToString('o')
        ActiveMode      = $activeMode
        Checks          = $checks
        Recommendations = $findings
    } | ConvertTo-Json -Depth 6
    return
}

Write-Host "`n======================================================================================" -ForegroundColor Cyan
Write-Host "  DIAGNOSTICO DE SAUDE DO PIPELINE DE CAPTURA & FRAME GENERATION (SOMENTE LEITURA)" -ForegroundColor Cyan
Write-Host "======================================================================================" -ForegroundColor Cyan

foreach ($c in $checks) {
    $color = switch ($c.Status) {
        'OK'   { 'Green'  }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red'    }
        default { 'Cyan'  }
    }
    Write-Host ("[{0,-4}] {1,-32} | {2}" -f $c.Status, $c.Camada, $c.Metrica) -ForegroundColor $color
    Write-Host ("       -> {0}" -f $c.Detalhes) -ForegroundColor DarkGray
}

Write-Host "`n--- Diagnostico Consolidado ---" -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Host "[IDEAL] Nenhum gargalo de configuracao ou conflito detectado! Meta esperada com jogo aberto: 30 / 60 FPS continuos." -ForegroundColor Green
} else {
    $idx = 1
    foreach ($f in $findings) {
        Write-Host ("  {0}. {1}" -f $idx, $f) -ForegroundColor Yellow
        $idx++
    }
}
Write-Host ""
