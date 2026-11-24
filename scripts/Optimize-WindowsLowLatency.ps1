<#
.SYNOPSIS
    Audita, aplica (com backup JSON automático) ou reverte otimizações de baixa latência
    da pilha gráfica Windows 11 (DWM Independent Flip, DXGI dGPU Binding, GameDVR, Game Mode e USB 3.0).

.DESCRIPTION
    Projetado para pipelines de captura de console em tempo real (PS5 -> UGREEN 15390 USB 3.0 ->
    MPC-BE / OBS Studio -> Lossless Scaling LSFG 3.1) em notebooks híbridos NVIDIA Optimus.

    Camadas otimizadas por este script:
      1. DWM Windowed Game Optimizations (SwapEffectUpgradeEnable=1 em DirectXUserGlobalSettings):
         Promove janelas DX10/DX11 legadas (blt-model) sem bordas para Flip Model / Independent Flip
         (ganho estimado condicional de -8 ms a -16 ms onde swapchains D3D10/11 blt-model estariam ativas).
      2. Afinidade explícita de GPU de Alto Desempenho (GpuPreference=2; no registro DirectX):
         Garante que LosslessScaling.exe, mpc-be64.exe e obs64.exe iniciem na dGPU dedicada (GTX 1650),
         prevenindo o colapso medido de ~15 FPS (~66,7 ms) na Intel UHD Graphics (128 MB VRAM).
      3. Desativação de Xbox GameDVR, Captura em Fundo e Interceptação FSE (GameDVR_Enabled=0,
         AppCaptureEnabled=0 e GameDVR_FSEBehaviorMode=2 em HKCU:\System\GameConfigStore):
         Remove hooks de gravação contínua e wrappers de Fullscreen Optimizations/GameBar na swapchain
         (redução estimada de -3 ms a -8 ms; reversível via -RestoreFromBackup).
      4. Ativação do Windows Game Mode (AutoGameModeEnabled=1 e AllowAutoGameMode=1):
         Prioriza agendamento de threads gráficas e suprime picos de tarefas de fundo.
      5. Desativação da Suspensão Seletiva USB (AC=0 e DC=0 no plano de energia ativo):
         Impede transições de economia de energia U1/U2/U3 no controlador xHCI USB 3.0 que causam
         micro-stutter ou invalidação do endpoint WASAPI da UGREEN 15390 (MS2131).

    SEGURANÇA:
      - Não encerra processos do usuário nem altera chaves fora do escopo documentado.
      - Suporta -CheckOnly (100% somente leitura), -WhatIf e backup JSON automático antes de gravar.

.PARAMETER CheckOnly
    Executa apenas auditoria somente-leitura das chaves de registro e energia, sem alterar o sistema.

.PARAMETER BackupPath
    Caminho opcional do arquivo JSON onde os valores anteriores serão salvos antes da aplicação.

.PARAMETER RestoreFromBackup
    Caminho de um arquivo JSON gerado anteriormente por este script para restaurar o estado original.

.PARAMETER CustomAppPaths
    Caminhos completos adicionais de executáveis para vincular a GpuPreference=2; (Alto Desempenho).

.EXAMPLE
    .\scripts\Optimize-WindowsLowLatency.ps1 -CheckOnly
    Audita todas as configurações atuais do Windows sem modificar nada.

.EXAMPLE
    .\scripts\Optimize-WindowsLowLatency.ps1
    Salva backup JSON automático em .\backups\ e aplica todas as otimizações de baixa latência.

.EXAMPLE
    .\scripts\Optimize-WindowsLowLatency.ps1 -RestoreFromBackup .\backups\windows-latency-backup-20261123-210000.json
    Restaura exatamente os valores anteriores salvos no backup.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Check', Mandatory = $true)]
    [switch]$CheckOnly,

    [Parameter(ParameterSetName = 'Apply')]
    [string]$BackupPath,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [string]$RestoreFromBackup,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Check')]
    [string[]]$CustomAppPaths = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# GUIDs oficiais do Windows PowerCfg para Suspensão Seletiva USB
$UsbSubgroupGuid = '2a737441-1930-4402-8d77-b2bebba308a3'
$UsbSuspendGuid  = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'

function Resolve-PipelineExecutables {
    param([string[]]$ExtraPaths)

    $candidates = New-Object System.Collections.Generic.List[string]
    $seen       = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # Caminhos padrão conhecidos (sem nomes de usuário fixos)
    $standardLocations = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\MPC-BE\mpc-be64.exe'),
        (Join-Path $env:ProgramFiles 'MPC-BE x64\mpc-be64.exe'),
        (Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\Lossless Scaling\LosslessScaling.exe'),
        (Join-Path $env:ProgramFiles 'Steam\steamapps\common\Lossless Scaling\LosslessScaling.exe')
    )

    # Descoberta dinâmica de bibliotecas Steam via registro HKCU
    $steamReg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction SilentlyContinue
    if ($null -ne $steamReg -and -not [string]::IsNullOrWhiteSpace($steamReg.SteamPath)) {
        $steamRoot = $steamReg.SteamPath -replace '/', '\'
        $standardLocations += (Join-Path $steamRoot 'steamapps\common\Lossless Scaling\LosslessScaling.exe')

        $vdfPath = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdfPath) {
            $vdfLines = Get-Content -LiteralPath $vdfPath -ErrorAction SilentlyContinue
            foreach ($line in $vdfLines) {
                if ($line -match '"path"\s+"([^"]+)"') {
                    $libPath = $Matches[1] -replace '\\\\', '\'
                    $standardLocations += (Join-Path $libPath 'steamapps\common\Lossless Scaling\LosslessScaling.exe')
                }
            }
        }
    }

    foreach ($p in ($standardLocations + $ExtraPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) {
            $full = (Get-Item -LiteralPath $p).FullName
            if ($seen.Add($full)) {
                $candidates.Add($full)
            }
        }
    }

    return $candidates.ToArray()
}

function Get-RegistryValueOrNull {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $prop = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $prop) { return $null }
    return $prop.$Name
}

function Get-UsbSelectiveSuspendState {
    $raw = & powercfg.exe /query SCHEME_CURRENT $UsbSubgroupGuid $UsbSuspendGuid 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ Supported = $false; AC = $null; DC = $null }
    }
    $hexMatches = @($raw | Select-String -Pattern '0x([0-9a-fA-F]{8})' | ForEach-Object {
        [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16)
    })
    if ($hexMatches.Count -ge 2) {
        return [PSCustomObject]@{
            Supported = $true
            AC        = $hexMatches[$hexMatches.Count - 2]
            DC        = $hexMatches[$hexMatches.Count - 1]
        }
    }
    return [PSCustomObject]@{ Supported = $false; AC = $null; DC = $null }
}

function Merge-DirectXGlobalSettings {
    param([AllowNull()][string]$CurrentValue)
    $tokens = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        foreach ($part in ($CurrentValue -split ';')) {
            $trimmed = $part.Trim()
            if ($trimmed -match '^([A-Za-z0-9_]+)=(.+)$') {
                $tokens[$Matches[1]] = $Matches[2]
            }
        }
    }
    $tokens['SwapEffectUpgradeEnable'] = '1'
    $rebuilt = ($tokens.Keys | ForEach-Object { "$_=$($tokens[$_]);" }) -join ''
    return $rebuilt
}

# 1. Modo Restauração via Backup JSON
if ($PSCmdlet.ParameterSetName -eq 'Restore') {
    if (-not (Test-Path -LiteralPath $RestoreFromBackup)) {
        throw "Arquivo de backup não encontrado: $RestoreFromBackup"
    }
    $backup = Get-Content -LiteralPath $RestoreFromBackup -Raw | ConvertFrom-Json
    Write-Host "`n[RESTORE] Restaurando estado salvo em $($backup.Timestamp)..." -ForegroundColor Cyan

    foreach ($entry in $backup.RegistryEntries) {
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            if ($null -ne $entry.Value) {
                New-Item -Path $entry.Path -Force | Out-Null
            } else {
                continue
            }
        }
        if ($null -eq $entry.Value) {
            if ($PSCmdlet.ShouldProcess("$($entry.Path)\$($entry.Name)", 'Remover valor criado posteriormente')) {
                Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
            }
        } else {
            if ($PSCmdlet.ShouldProcess("$($entry.Path)\$($entry.Name)", "Restaurar para '$($entry.Value)'")) {
                Set-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -Type $entry.ValueKind
            }
        }
    }

    if ($backup.UsbSelectiveSuspend.Supported -and $null -ne $backup.UsbSelectiveSuspend.AC -and $null -ne $backup.UsbSelectiveSuspend.DC) {
        if ($PSCmdlet.ShouldProcess('SCHEME_CURRENT USB Selective Suspend', "Restaurar AC=$($backup.UsbSelectiveSuspend.AC), DC=$($backup.UsbSelectiveSuspend.DC)")) {
            & powercfg.exe /setacvalueindex SCHEME_CURRENT $UsbSubgroupGuid $UsbSuspendGuid $backup.UsbSelectiveSuspend.AC | Out-Null
            & powercfg.exe /setdcvalueindex SCHEME_CURRENT $UsbSubgroupGuid $UsbSuspendGuid $backup.UsbSelectiveSuspend.DC | Out-Null
            & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
        }
    }

    Write-Host "[OK] Estado anterior restaurado com sucesso." -ForegroundColor Green
    return
}

# 2. Coleta de estado atual (Somente Leitura)
$dxPath          = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$gameConfigPath  = 'HKCU:\System\GameConfigStore'
$gameDvrPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
$gameBarPath     = 'HKCU:\Software\Microsoft\GameBar'

$discoveredApps  = @(Resolve-PipelineExecutables -ExtraPaths $CustomAppPaths)
$dxGlobalCurrent = [string](Get-RegistryValueOrNull -Path $dxPath -Name 'DirectXUserGlobalSettings')
$gameDvrEnabled  = Get-RegistryValueOrNull -Path $gameConfigPath -Name 'GameDVR_Enabled'
$fseBehaviorMode = Get-RegistryValueOrNull -Path $gameConfigPath -Name 'GameDVR_FSEBehaviorMode'
$appCapture      = Get-RegistryValueOrNull -Path $gameDvrPath -Name 'AppCaptureEnabled'
$autoGameMode    = Get-RegistryValueOrNull -Path $gameBarPath -Name 'AutoGameModeEnabled'
$allowGameMode   = Get-RegistryValueOrNull -Path $gameBarPath -Name 'AllowAutoGameMode'
$usbState        = Get-UsbSelectiveSuspendState

$auditRows = New-Object System.Collections.Generic.List[object]

$swapOk = $dxGlobalCurrent -match '(^|;)SwapEffectUpgradeEnable=1(;|$)'
$auditRows.Add([PSCustomObject]@{
    Camada   = 'DWM Independent Flip (Windowed SwapEffect)'
    Atual    = $(if ([string]::IsNullOrWhiteSpace($dxGlobalCurrent)) { '<ausente>' } else { $dxGlobalCurrent })
    Alvo     = 'SwapEffectUpgradeEnable=1;'
    Status   = $(if ($swapOk) { 'OK' } else { 'SUB-OTIMO' })
    Impacto  = '-8 ms a -16 ms (evita BitBlt legado)'
})

foreach ($app in $discoveredApps) {
    $appVal = [string](Get-RegistryValueOrNull -Path $dxPath -Name $app)
    # Verifica se está exatamente limpo em GpuPreference=2; (sem lixo binário residual)
    $appOk  = ($appVal -eq 'GpuPreference=2;')
    $auditRows.Add([PSCustomObject]@{
        Camada   = "DXGI GPU Binding ($([System.IO.Path]::GetFileName($app)))"
        Atual    = $(if ([string]::IsNullOrWhiteSpace($appVal)) { '<ausente>' } else { $appVal })
        Alvo     = 'GpuPreference=2;'
        Status   = $(if ($appOk) { 'OK' } else { 'SUB-OTIMO' })
        Impacto  = 'Forca dGPU dedicada (evita ~15 FPS na iGPU)'
    })
}

$dvrOk = ($gameDvrEnabled -eq 0) -and ($appCapture -eq 0) -and ($fseBehaviorMode -eq 2)
$auditRows.Add([PSCustomObject]@{
    Camada   = 'Xbox GameDVR / FSE Behavior'
    Atual    = "GameDVR=$gameDvrEnabled, AppCap=$appCapture, FSEMode=$fseBehaviorMode"
    Alvo     = 'GameDVR=0, AppCap=0, FSEMode=2'
    Status   = $(if ($dvrOk) { 'OK' } else { 'SUB-OTIMO' })
    Impacto  = '-3 ms a -8 ms est. (sem hooks GameDVR/FSE)'
})

$gmOk = ($autoGameMode -eq 1) -and ($allowGameMode -eq 1)
$auditRows.Add([PSCustomObject]@{
    Camada   = 'Windows Game Mode'
    Atual    = "AutoGameMode=$autoGameMode, AllowAuto=$allowGameMode"
    Alvo     = 'AutoGameMode=1, AllowAuto=1'
    Status   = $(if ($gmOk) { 'OK' } else { 'SUB-OTIMO' })
    Impacto  = 'Prioridade de escalonamento CPU/GPU'
})

$usbOk = $usbState.Supported -and ($usbState.AC -eq 0) -and ($usbState.DC -eq 0)
$auditRows.Add([PSCustomObject]@{
    Camada   = 'USB Selective Suspend (Plano Ativo)'
    Atual    = $(if ($usbState.Supported) { "AC=$($usbState.AC), DC=$($usbState.DC)" } else { 'Nao suportado/indisponivel' })
    Alvo     = 'AC=0, DC=0 (Desabilitado)'
    Status   = $(if ($usbOk) { 'OK' } else { 'SUB-OTIMO' })
    Impacto  = 'Estabilidade isocrona/bulk USB 3.0 UGREEN 15390'
})

Write-Host "`n=== Auditoria de Baixa Latencia Windows 11 (DWM / DXGI / GameDVR / USB) ===" -ForegroundColor Cyan
$auditRows | Format-Table -AutoSize

if ($CheckOnly) {
    $pending = @($auditRows | Where-Object { $_.Status -ne 'OK' }).Count
    if ($pending -eq 0) {
        Write-Host "[OK] Todas as camadas auditadas estao em estado ideal de baixa latencia." -ForegroundColor Green
    } else {
        Write-Host "[AVISO] $pending camada(s) fora do perfil ideal. Execute sem -CheckOnly para aplicar." -ForegroundColor Yellow
    }
    return
}

# 3. Backup JSON automático antes da aplicação
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $repoRoot  = Split-Path -Parent $PSScriptRoot
    $backupDir = Join-Path $repoRoot 'backups'
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $BackupPath = Join-Path $backupDir "windows-latency-backup-$stamp.json"
}

$regSnapshot = New-Object System.Collections.Generic.List[object]
$regTargets = @(
    @{ Path = $dxPath;         Name = 'DirectXUserGlobalSettings'; Kind = 'String' },
    @{ Path = $gameConfigPath; Name = 'GameDVR_Enabled';           Kind = 'DWord'  },
    @{ Path = $gameConfigPath; Name = 'GameDVR_FSEBehaviorMode';   Kind = 'DWord'  },
    @{ Path = $gameDvrPath;    Name = 'AppCaptureEnabled';         Kind = 'DWord'  },
    @{ Path = $gameBarPath;    Name = 'AutoGameModeEnabled';       Kind = 'DWord'  },
    @{ Path = $gameBarPath;    Name = 'AllowAutoGameMode';         Kind = 'DWord'  }
)
foreach ($app in $discoveredApps) {
    $regTargets += @{ Path = $dxPath; Name = $app; Kind = 'String' }
}

foreach ($t in $regTargets) {
    $regSnapshot.Add([PSCustomObject]@{
        Path      = $t.Path
        Name      = $t.Name
        ValueKind = $t.Kind
        Value     = (Get-RegistryValueOrNull -Path $t.Path -Name $t.Name)
    })
}

$backupPayload = [PSCustomObject]@{
    Timestamp           = (Get-Date).ToString('o')
    RegistryEntries     = $regSnapshot
    UsbSelectiveSuspend = $usbState
}

if ($PSCmdlet.ShouldProcess($BackupPath, 'Salvar snapshot de seguranca (JSON)')) {
    $parentDir = Split-Path -Parent $BackupPath
    if (-not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    $backupPayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    Write-Host "[BACKUP] Estado anterior salvo em: $BackupPath" -ForegroundColor DarkGray
}

# 4. Aplicação segura e idempotente
foreach ($path in @($dxPath, $gameConfigPath, $gameDvrPath, $gameBarPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        if ($PSCmdlet.ShouldProcess($path, 'Criar chave de registro')) {
            New-Item -Path $path -Force | Out-Null
        }
    }
}

$mergedGlobal = Merge-DirectXGlobalSettings -CurrentValue $dxGlobalCurrent
if ($PSCmdlet.ShouldProcess("$dxPath\DirectXUserGlobalSettings", "Definir '$mergedGlobal'")) {
    Set-ItemProperty -LiteralPath $dxPath -Name 'DirectXUserGlobalSettings' -Value $mergedGlobal -Type String
}

foreach ($app in $discoveredApps) {
    if ($PSCmdlet.ShouldProcess("$dxPath\$app", "Definir 'GpuPreference=2;'")) {
        Set-ItemProperty -LiteralPath $dxPath -Name $app -Value 'GpuPreference=2;' -Type String
    }
}

if ($PSCmdlet.ShouldProcess($gameConfigPath, 'Desabilitar GameDVR_Enabled=0 e definir GameDVR_FSEBehaviorMode=2')) {
    Set-ItemProperty -LiteralPath $gameConfigPath -Name 'GameDVR_Enabled' -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $gameConfigPath -Name 'GameDVR_FSEBehaviorMode' -Value 2 -Type DWord
}

if ($PSCmdlet.ShouldProcess($gameDvrPath, 'Desabilitar AppCaptureEnabled=0')) {
    Set-ItemProperty -LiteralPath $gameDvrPath -Name 'AppCaptureEnabled' -Value 0 -Type DWord
}

if ($PSCmdlet.ShouldProcess($gameBarPath, 'Habilitar AutoGameModeEnabled=1 e AllowAutoGameMode=1')) {
    Set-ItemProperty -LiteralPath $gameBarPath -Name 'AutoGameModeEnabled' -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $gameBarPath -Name 'AllowAutoGameMode' -Value 1 -Type DWord
}

if ($usbState.Supported) {
    if ($PSCmdlet.ShouldProcess('SCHEME_CURRENT USB Selective Suspend', 'Definir AC=0 e DC=0 (Desabilitado)')) {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT $UsbSubgroupGuid $UsbSuspendGuid 0 | Out-Null
        & powercfg.exe /setdcvalueindex SCHEME_CURRENT $UsbSubgroupGuid $UsbSuspendGuid 0 | Out-Null
        & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
    }
}

Write-Host "[OK] Otimizacoes de baixa latencia aplicadas com sucesso no Windows." -ForegroundColor Green
Write-Host "     Nota: reinicie mpc-be64.exe / obs64.exe / LosslessScaling.exe se estiverem abertos para absorverem o novo SwapEffect." -ForegroundColor Gray
