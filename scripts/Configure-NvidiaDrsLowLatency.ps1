<#
.SYNOPSIS
    Audita ou configura perfis de baixa latência no NVIDIA Driver Settings (DRS) via nvapi64.dll oficial
    para LosslessScaling.exe, mpc-be64.exe e obs64.exe.

.DESCRIPTION
    Em notebooks híbridos NVIDIA Optimus (ex.: GTX 1650 Turing TU117), cargas moderadas de compute/captura
    fazem o gerenciamento de energia padrão do driver reduzir o clock da GPU para ~645 MHz (2,77x abaixo
    do boost máximo de 1785 MHz), elevando o tempo de síntese do LSFG 3.1 de ~3-4 ms para ~10-12 ms
    (+7 ms a +9 ms de latência morta por quadro).

    Este script utiliza P/Invoke C# sobre a API nativa oficial `nvapi64.dll` (`nvapi_QueryInterface`)
    para inspecionar ou aplicar os seguintes parâmetros por aplicativo no banco binário DRS do driver:

      - 0x1057EB71 (PREFERRED_PSTATE_ID)  = 0x00000001 (Prefer Maximum Performance -> trava P0 ~1785 MHz)
      - 0x00A879CF (VSYNCMODE_ID)         = 0x08416747 (Vertical Sync -> Force Off)
      - 0x007BA09E (PRERENDERLIMIT_ID)    = 0x00000001 (Maximum Pre-Rendered Frames -> 1)

    VANTAGEM ARQUITETURAL:
      Como a política é vinculada apenas aos executáveis do pipeline (`losslessscaling.exe`, `mpc-be64.exe`,
      `obs64.exe`), a GPU mantém boost máximo (~1785 MHz) durante o jogo/live e retorna automaticamente ao
      estado ocioso `P8` (~345 MHz, baixa temperatura) assim que os aplicativos são fechados.

.PARAMETER CheckOnly
    Executa apenas leitura/auditoria dos perfis atuais no banco NVIDIA DRS (não exige Administrador).

.PARAMETER Targets
    Lista de executáveis a auditar/configurar. Padrão: losslessscaling.exe, mpc-be64.exe, obs64.exe.

.EXAMPLE
    .\scripts\Configure-NvidiaDrsLowLatency.ps1 -CheckOnly
    Audita via nvapi64.dll os valores ativos de Power Management, VSync e Pre-Rendered Frames.

.EXAMPLE
    .\scripts\Configure-NvidiaDrsLowLatency.ps1
    Aplica e salva no banco NVIDIA DRS (exige PowerShell executado como Administrador).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$CheckOnly,

    [string[]]$Targets = @(
        'losslessscaling.exe',
        'mpc-be64.exe',
        'obs64.exe'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Este script requer PowerShell 64-bit para carregar nvapi64.dll.'
}

$nvApiSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class NvidiaDrsEntryResult {
    public string Executable { get; set; }
    public string ProfileName { get; set; }
    public bool ProfileFound { get; set; }
    public bool CreatedProfile { get; set; }
    public int StatusCode { get; set; }
    public uint? PreferredPState { get; set; }
    public uint? VSyncMode { get; set; }
    public uint? PreRenderLimit { get; set; }
}

public static class NvidiaDrsInterop {
    // IDs oficiais nvapi_QueryInterface (NVAPI SDK R535+)
    private const uint ID_NvAPI_Initialize                  = 0x0150E828u;
    private const uint ID_NvAPI_DRS_CreateSession           = 0x0694D52Eu;
    private const uint ID_NvAPI_DRS_DestroySession          = 0xDAD9CFF8u;
    private const uint ID_NvAPI_DRS_LoadSettings            = 0x375DBD6Bu;
    private const uint ID_NvAPI_DRS_SaveSettings            = 0xFCBC7E14u;
    private const uint ID_NvAPI_DRS_CreateProfile           = 0xCC176068u;
    private const uint ID_NvAPI_DRS_FindProfileByName       = 0x7E4A9A0Bu;
    private const uint ID_NvAPI_DRS_CreateApplication       = 0x4347A9DEu;
    private const uint ID_NvAPI_DRS_FindApplicationByName   = 0xEEE566B2u;
    private const uint ID_NvAPI_DRS_SetSetting              = 0x577DD202u;
    private const uint ID_NvAPI_DRS_GetSetting              = 0x73BF8338u;

    // IDs e constantes oficiais NvApiDriverSettings.h
    public const uint PREFERRED_PSTATE_ID   = 0x1057EB71u;
    public const uint PSTATE_PREFER_MAX     = 0x00000001u;

    public const uint VSYNCMODE_ID          = 0x00A879CFu;
    public const uint VSYNCMODE_FORCEOFF    = 0x08416747u;

    public const uint PRERENDERLIMIT_ID     = 0x007BA09Eu;
    public const uint PRERENDERLIMIT_ONE    = 0x00000001u;

    private const int NVAPI_OK                     = 0;
    private const int NVAPI_SETTING_NOT_FOUND      = -191;

    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr QueryInterface(uint interfaceId);

    // Layouts nativos NVDRS V1 verificados (Prof=4116B, App=12296B, Setting=12320B)
    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NVDRS_PROFILE_V1 {
        public uint version;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2048)]
        public ushort[] profileName;
        public uint gpuSupport;
        public uint isPredefined;
        public uint numOfApps;
        public uint numOfSettings;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NVDRS_APPLICATION_V1 {
        public uint version;
        public uint isPredefined;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2048)]
        public ushort[] appName;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2048)]
        public ushort[] userFriendlyName;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2048)]
        public ushort[] launcher;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    private struct NVDRS_SETTING_V1 {
        public uint version;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 2048)]
        public ushort[] settingName;
        public uint settingId;
        public uint settingType;      // 0 = NVDRS_DWORD_TYPE
        public uint settingLocation;  // 0 = NVDRS_CURRENT_PROFILE_LOCATION
        public uint isCurrentPredefined;
        public uint isPredefinedValid;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100)]
        public byte[] predefinedUnion;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4100)]
        public byte[] currentUnion;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int InitDel();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int CreateSessionDel(out IntPtr hSession);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int DestroySessionDel(IntPtr hSession);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int LoadSettingsDel(IntPtr hSession);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int SaveSettingsDel(IntPtr hSession);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int CreateProfileDel(IntPtr hSession, ref NVDRS_PROFILE_V1 profileInfo, out IntPtr hProfile);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int FindProfileDel(IntPtr hSession, [MarshalAs(UnmanagedType.LPArray, SizeConst = 2048)] ushort[] profileName, out IntPtr hProfile);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int CreateAppDel(IntPtr hSession, IntPtr hProfile, ref NVDRS_APPLICATION_V1 app);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int FindAppDel(IntPtr hSession, [MarshalAs(UnmanagedType.LPArray, SizeConst = 2048)] ushort[] appName, out IntPtr hProfile, ref NVDRS_APPLICATION_V1 app);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int SetSettingDel(IntPtr hSession, IntPtr hProfile, ref NVDRS_SETTING_V1 setting);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int GetSettingDel(IntPtr hSession, IntPtr hProfile, uint settingId, ref NVDRS_SETTING_V1 setting);

    private static T Bind<T>(uint id) where T : class {
        IntPtr ptr = QueryInterface(id);
        if (ptr == IntPtr.Zero) {
            throw new InvalidOperationException(string.Format("Funcao NVAPI 0x{0:X8} indisponivel neste driver.", id));
        }
        return Marshal.GetDelegateForFunctionPointer(ptr, typeof(T)) as T;
    }

    private static uint MakeVersion(Type t, uint ver) {
        return (uint)Marshal.SizeOf(t) | (ver << 16);
    }

    private static ushort[] ToNvString(string text) {
        var buf = new ushort[2048];
        if (!string.IsNullOrEmpty(text)) {
            int max = Math.Min(text.Length, 2047);
            for (int i = 0; i < max; i++) buf[i] = text[i];
        }
        return buf;
    }

    private static uint? ReadDwordSetting(GetSettingDel getSetting, IntPtr hSession, IntPtr hProfile, uint settingId) {
        var st = new NVDRS_SETTING_V1();
        st.version = MakeVersion(typeof(NVDRS_SETTING_V1), 1);
        int rc = getSetting(hSession, hProfile, settingId, ref st);
        if (rc == NVAPI_OK && st.currentUnion != null && st.currentUnion.Length >= 4) {
            return BitConverter.ToUInt32(st.currentUnion, 0);
        }
        return null;
    }

    private static void WriteDwordSetting(SetSettingDel setSetting, IntPtr hSession, IntPtr hProfile, uint settingId, uint value) {
        var st = new NVDRS_SETTING_V1();
        st.version         = MakeVersion(typeof(NVDRS_SETTING_V1), 1);
        st.settingName     = new ushort[2048];
        st.settingId       = settingId;
        st.settingType     = 0u; // NVDRS_DWORD_TYPE
        st.settingLocation = 0u; // NVDRS_CURRENT_PROFILE_LOCATION
        st.predefinedUnion = new byte[4100];
        st.currentUnion    = new byte[4100];
        byte[] bytes       = BitConverter.GetBytes(value);
        Array.Copy(bytes, 0, st.currentUnion, 0, 4);

        int rc = setSetting(hSession, hProfile, ref st);
        if (rc != NVAPI_OK) {
            throw new InvalidOperationException(string.Format("Falha em NvAPI_DRS_SetSetting(0x{0:X8}): codigo {1}", settingId, rc));
        }
    }

    public static List<NvidiaDrsEntryResult> ProcessTargets(string[] executables, bool applyChanges) {
        var init           = Bind<InitDel>(ID_NvAPI_Initialize);
        var createSession  = Bind<CreateSessionDel>(ID_NvAPI_DRS_CreateSession);
        var destroySession = Bind<DestroySessionDel>(ID_NvAPI_DRS_DestroySession);
        var loadSettings   = Bind<LoadSettingsDel>(ID_NvAPI_DRS_LoadSettings);
        var saveSettings   = Bind<SaveSettingsDel>(ID_NvAPI_DRS_SaveSettings);
        var createProfile  = Bind<CreateProfileDel>(ID_NvAPI_DRS_CreateProfile);
        var findProfile    = Bind<FindProfileDel>(ID_NvAPI_DRS_FindProfileByName);
        var createApp      = Bind<CreateAppDel>(ID_NvAPI_DRS_CreateApplication);
        var findApp        = Bind<FindAppDel>(ID_NvAPI_DRS_FindApplicationByName);
        var setSetting     = Bind<SetSettingDel>(ID_NvAPI_DRS_SetSetting);
        var getSetting     = Bind<GetSettingDel>(ID_NvAPI_DRS_GetSetting);

        int rcInit = init();
        if (rcInit != NVAPI_OK) {
            throw new InvalidOperationException("NvAPI_Initialize falhou com codigo: " + rcInit);
        }

        IntPtr hSession;
        int rcSess = createSession(out hSession);
        if (rcSess != NVAPI_OK) {
            throw new InvalidOperationException("NvAPI_DRS_CreateSession falhou com codigo: " + rcSess);
        }

        var results = new List<NvidiaDrsEntryResult>();
        try {
            int rcLoad = loadSettings(hSession);
            if (rcLoad != NVAPI_OK) {
                throw new InvalidOperationException("NvAPI_DRS_LoadSettings falhou com codigo: " + rcLoad);
            }

            foreach (string rawExe in executables) {
                string exe = rawExe.Trim().ToLowerInvariant();
                var item = new NvidiaDrsEntryResult { Executable = exe };

                var appInfo = new NVDRS_APPLICATION_V1();
                appInfo.version = MakeVersion(typeof(NVDRS_APPLICATION_V1), 1);

                IntPtr hProfile;
                int rcFind = findApp(hSession, ToNvString(exe), out hProfile, ref appInfo);
                if (rcFind == NVAPI_OK && hProfile != IntPtr.Zero) {
                    item.ProfileFound = true;
                    item.ProfileName  = "(Perfil Associado Existente)";
                } else if (applyChanges) {
                    string customTitle = "LowLatency - " + exe;
                    int rcProf = findProfile(hSession, ToNvString(customTitle), out hProfile);
                    if (rcProf != NVAPI_OK || hProfile == IntPtr.Zero) {
                        var newProf = new NVDRS_PROFILE_V1();
                        newProf.version     = MakeVersion(typeof(NVDRS_PROFILE_V1), 1);
                        newProf.profileName = ToNvString(customTitle);
                        newProf.gpuSupport  = 1u; // GeForce bit
                        int rcCreateP = createProfile(hSession, ref newProf, out hProfile);
                        if (rcCreateP != NVAPI_OK) {
                            throw new InvalidOperationException("NvAPI_DRS_CreateProfile falhou para " + exe + ": codigo " + rcCreateP);
                        }
                        item.CreatedProfile = true;
                    }

                    var newApp = new NVDRS_APPLICATION_V1();
                    newApp.version          = MakeVersion(typeof(NVDRS_APPLICATION_V1), 1);
                    newApp.appName          = ToNvString(exe);
                    newApp.userFriendlyName = ToNvString(exe);
                    newApp.launcher         = new ushort[2048];
                    int rcCreateA = createApp(hSession, hProfile, ref newApp);
                    if (rcCreateA != NVAPI_OK) {
                        throw new InvalidOperationException("NvAPI_DRS_CreateApplication falhou para " + exe + ": codigo " + rcCreateA);
                    }

                    item.ProfileFound = true;
                    item.ProfileName  = customTitle;
                } else {
                    item.ProfileFound = false;
                    item.ProfileName  = "<Sem perfil DRS>";
                    item.StatusCode   = rcFind;
                    results.Add(item);
                    continue;
                }

                if (applyChanges) {
                    WriteDwordSetting(setSetting, hSession, hProfile, PREFERRED_PSTATE_ID, PSTATE_PREFER_MAX);
                    WriteDwordSetting(setSetting, hSession, hProfile, VSYNCMODE_ID, VSYNCMODE_FORCEOFF);
                    WriteDwordSetting(setSetting, hSession, hProfile, PRERENDERLIMIT_ID, PRERENDERLIMIT_ONE);
                }

                item.PreferredPState = ReadDwordSetting(getSetting, hSession, hProfile, PREFERRED_PSTATE_ID);
                item.VSyncMode       = ReadDwordSetting(getSetting, hSession, hProfile, VSYNCMODE_ID);
                item.PreRenderLimit  = ReadDwordSetting(getSetting, hSession, hProfile, PRERENDERLIMIT_ID);
                results.Add(item);
            }

            if (applyChanges) {
                int rcSave = saveSettings(hSession);
                if (rcSave != NVAPI_OK) {
                    throw new InvalidOperationException("NvAPI_DRS_SaveSettings falhou (codigo " + rcSave + "). Execute o PowerShell como Administrador.");
                }
            }
        } finally {
            destroySession(hSession);
        }

        return results;
    }
}
'@

if (-not ('NvidiaDrsInterop' -as [type])) {
    Add-Type -TypeDefinition $nvApiSource -Language CSharp
}

function Format-HexOrDefault {
    param([Nullable[uint32]]$Val, [uint32]$Expected, [string]$ExpectedLabel)
    if ($null -eq $Val) { return '<padrao global>' }
    $hex = ('0x{0:X8}' -f $Val)
    if ($Val -eq $Expected) { return "$hex ($ExpectedLabel)" }
    return $hex
}

$shouldApply = (-not $CheckOnly)
if ($shouldApply) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin -and -not $WhatIfPreference) {
        throw 'Para gravar perfis no banco NVIDIA DRS (NvAPI_DRS_SaveSettings), abra o PowerShell como Administrador ou use -CheckOnly para auditoria.'
    }
}

$doWrite = $false
if ($shouldApply) {
    if ($PSCmdlet.ShouldProcess(($Targets -join ', '), 'Aplicar Prefer Maximum Performance (0x1), VSync Force Off (0x08416747) e PreRenderLimit=1 via nvapi64.dll')) {
        $doWrite = $true
    }
}

$entries = [NvidiaDrsInterop]::ProcessTargets($Targets, $doWrite)

$table = foreach ($e in $entries) {
    $ok = $e.ProfileFound `
        -and ($e.PreferredPState -eq [NvidiaDrsInterop]::PSTATE_PREFER_MAX) `
        -and ($e.VSyncMode       -eq [NvidiaDrsInterop]::VSYNCMODE_FORCEOFF) `
        -and ($e.PreRenderLimit  -eq [NvidiaDrsInterop]::PRERENDERLIMIT_ONE)

    [PSCustomObject]@{
        Executavel        = $e.Executable
        PowerManagement   = Format-HexOrDefault -Val $e.PreferredPState -Expected ([NvidiaDrsInterop]::PSTATE_PREFER_MAX) -ExpectedLabel 'Max Perf'
        VerticalSync      = Format-HexOrDefault -Val $e.VSyncMode -Expected ([NvidiaDrsInterop]::VSYNCMODE_FORCEOFF) -ExpectedLabel 'Force Off'
        MaxPreRendered    = $(if ($null -eq $e.PreRenderLimit) { '<padrao global>' } else { "$($e.PreRenderLimit)" })
        Status            = $(if ($ok) { 'OK' } else { 'PENDENTE' })
    }
}

Write-Host "`n=== Auditoria / Configuracao NVIDIA DRS (nvapi64.dll Oficial) ===" -ForegroundColor Cyan
$table | Format-Table -AutoSize

$notOk = @($table | Where-Object { $_.Status -ne 'OK' }).Count
if ($doWrite -and $notOk -eq 0) {
    Write-Host "[OK] Perfis NVIDIA DRS gravados com sucesso! A GTX 1650 mantera boost maximo (~1785 MHz) quando qualquer alvo estiver ativo." -ForegroundColor Green
} elseif ($CheckOnly -and $notOk -eq 0) {
    Write-Host "[OK] Todos os executaveis alvo ja estao otimizados no banco NVIDIA DRS." -ForegroundColor Green
} elseif ($notOk -gt 0) {
    Write-Host "[AVISO] $notOk executavel(is) fora do perfil ideal. Execute como Administrador sem -CheckOnly para aplicar." -ForegroundColor Yellow
}
