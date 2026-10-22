#Requires -Version 5.1
# BLK Boost - otimizador pessoal para jogos (Windows 10/11 64 bits)
# Interface WPF. Cada ajuste guarda o valor original em C:\ProgramData\BlkBoost\backup.json
# e pode ser revertido individualmente.

# ---------------- Auto-elevação (admin) ----------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# Esconde a janela do console (fica só a interface)
Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
'@
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)
# ID próprio para a barra de tarefas mostrar o ícone do BLK Boost, e não o do PowerShell
[void][Native.Win]::SetCurrentProcessExplicitAppUserModelID('BLK.BlkBoost')

# Taxa de atualização atual e máxima do monitor principal (na resolução atual)
Add-Type -Namespace Native -Name Display -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;
    public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency;
    public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
    public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
}
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
public static int[] Refresh() {
    DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref d)) return null;
    int max = d.dmDisplayFrequency;
    DEVMODE m = new DEVMODE(); m.dmSize = d.dmSize;
    for (int i = 0; EnumDisplaySettings(null, i, ref m); i++)
        if (m.dmPelsWidth == d.dmPelsWidth && m.dmPelsHeight == d.dmPelsHeight && m.dmDisplayFrequency > max) max = m.dmDisplayFrequency;
    return new int[] { d.dmDisplayFrequency, max, d.dmPelsWidth, d.dmPelsHeight };
}
'@

# Pausar/retomar processos inteiros (Modo Jogo)
Add-Type -Namespace Native -Name Proc -MemberDefinition @'
[DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
[DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
[DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
const int PROCESS_SUSPEND_RESUME = 0x0800;
public static bool Suspend(int pid) {
    IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
    if (h == IntPtr.Zero) return false;
    int r = NtSuspendProcess(h); CloseHandle(h); return r == 0;
}
public static bool Resume(int pid) {
    IntPtr h = OpenProcess(PROCESS_SUSPEND_RESUME, false, pid);
    if (h == IntPtr.Zero) return false;
    int r = NtResumeProcess(h); CloseHandle(h); return r == 0;
}
'@

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$BackupDir  = Join-Path $env:ProgramData 'BlkBoost'
$BackupFile = Join-Path $BackupDir 'backup.json'
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$GuidRx = '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

# ---------------- Backup ----------------
function ConvertTo-Hash($obj) {
    $h = @{}
    if ($null -ne $obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

function Import-Backup {
    if (Test-Path $BackupFile) {
        try {
            $raw = Get-Content $BackupFile -Raw | ConvertFrom-Json
            return @{ reg = (ConvertTo-Hash $raw.reg); services = (ConvertTo-Hash $raw.services); power = $raw.power }
        } catch { }
    }
    return @{ reg = @{}; services = @{}; power = $null }
}

function Save-Backup { $script:Backup | ConvertTo-Json -Depth 6 | Set-Content $BackupFile -Encoding UTF8 }

$script:Backup = Import-Backup

# ---------------- Registro ----------------
function Get-RegValue([string]$Path, [string]$Name) {
    if (-not (Test-Path $Path)) { return @{ Exists = $false } }
    $key = Get-Item $Path
    $val = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    if ($null -eq $val) { return @{ Exists = $false } }
    return @{ Exists = $true; Value = $val; Kind = $key.GetValueKind($Name).ToString() }
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
}

# Confere se o valor atual no registro é o esperado
function Test-Reg([string]$Path, [string]$Name, $Value) {
    $r = Get-RegValue $Path $Name
    return $r.Exists -and "$($r.Value)" -eq "$Value"
}

# Salva o valor original (só na 1ª vez) e aplica o novo
function Set-Tweak([string]$Tweak, [string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord') {
    $id = "$Path|$Name"
    if (-not $script:Backup.reg.ContainsKey($id)) {
        $orig = Get-RegValue $Path $Name
        $orig.Tweak = $Tweak
        $script:Backup.reg[$id] = $orig
    }
    Set-RegValue $Path $Name $Value $Kind
}

# ---------------- Ajustes especiais ----------------
function Get-ActiveScheme {
    $out = (powercfg /getactivescheme) | Out-String
    if ($out -match $GuidRx) { return $Matches[0] }
}

function Enable-PowerPlan {
    if ($null -eq $script:Backup.power) {
        $orig = Get-ActiveScheme
        $created = $null
        $out = (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1) | Out-String
        if ($out -match $GuidRx) { $target = $Matches[0]; $created = $target }
        else { $target = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }  # fallback: Alto Desempenho
        $script:Backup.power = @{ Original = $orig; Created = $created; Target = $target; Tweak = 'power' }
    }
    $out = (powercfg /setactive $script:Backup.power.Target 2>&1) | Out-String
    if ($LASTEXITCODE -ne 0) { throw "powercfg falhou: $($out.Trim())" }
}

function Test-PowerPlan {
    $out = (powercfg /getactivescheme) | Out-String
    if ($script:Backup.power -and $out -match [regex]::Escape($script:Backup.power.Target)) { return $true }
    return $out -match 'e9a42b02-d5df-448d-aa00-03f14749eb61|8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c|Ultimate|M.ximo'
}

$Services = 'DiagTrack', 'SysMain'

function Disable-Services {
    foreach ($svc in $Services) {
        $s = Get-CimInstance Win32_Service -Filter "Name='$svc'"
        if (-not $s) { continue }
        if (-not $script:Backup.services.ContainsKey($svc)) {
            $script:Backup.services[$svc] = @{ StartMode = $s.StartMode; Tweak = 'services' }
        }
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service $svc -StartupType Disabled
    }
}

function Disable-Nagle {
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' | ForEach-Object {
        $dhcp   = $_.GetValue('DhcpIPAddress')
        $static = @($_.GetValue('IPAddress'))
        $hasIp  = ($dhcp -and $dhcp -ne '0.0.0.0') -or ($static[0] -and $static[0] -ne '0.0.0.0')
        if ($hasIp) {
            $p = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($_.PSChildName)"
            Set-Tweak 'nagle' $p 'TcpAckFrequency' 1
            Set-Tweak 'nagle' $p 'TCPNoDelay' 1
        }
    }
}

function Test-Nagle {
    foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces') {
        if ($k.GetValue('TCPNoDelay') -eq 1) { return $true }
    }
    return $false
}

# Otimizações para jogos em janela (Win11): troca o modelo de apresentação DX10/11 para flip,
# reduzindo latência e liberando VRR em modo janela/sem borda. Mantém as outras opções da string.
$DxPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
function Enable-WindowedOpt {
    $cur = Get-RegValue $DxPath 'DirectXUserGlobalSettings'
    $s = if ($cur.Exists) { [string]$cur.Value } else { '' }
    $s = $s -replace 'SwapEffectUpgradeEnable=\d;?', ''
    Set-Tweak 'windowed' $DxPath 'DirectXUserGlobalSettings' ($s + 'SwapEffectUpgradeEnable=1;') 'String'
}

$HvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
function Test-VbsOff {
    $r = Get-RegValue $HvciPath 'Enabled'
    if ($r.Exists) { return $r.Value -eq 0 }
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    return -not ($dg -and @($dg.SecurityServicesRunning) -contains 2)
}

function Clear-Temp {
    $before = 0
    foreach ($d in @($env:TEMP, "$env:windir\Temp")) {
        $before += (Get-ChildItem $d -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $after = 0
    foreach ($d in @($env:TEMP, "$env:windir\Temp")) {
        $after += (Get-ChildItem $d -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    }
    return ('{0:N0} MB liberados' -f (($before - $after) / 1MB))
}

# ---------------- Catálogo de ajustes ----------------
# Impact: real | situacional | placebo   Flags: reiniciar | relogar | seguranca
# Test lê o estado real do sistema, então o toggle mostra o que está valendo agora
$SP = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$Tweaks = @(
    [pscustomobject]@{ Id = 'power'; Cat = 'Energia e CPU'; Glyph = 0xE945; Impact = 'real'; Flags = @(); Rec = $true
        Name = 'Plano Desempenho Máximo'
        Desc = 'Mantém a CPU em clock alto, sem estacionar núcleos. Ganho maior em notebooks e em mínimos de FPS (1% low).'
        Apply = { Enable-PowerPlan }
        Test  = { Test-PowerPlan } }
    [pscustomobject]@{ Id = 'throttle'; Cat = 'Energia e CPU'; Glyph = 0xE9D9; Impact = 'situacional'; Flags = @('reiniciar'); Rec = $true
        Name = 'Desativar Power Throttling'
        Desc = 'Impede o Windows de jogar processos para núcleos de economia (E-cores) ou clock baixo. Ajuda em Intel 12ª geração+ e notebooks.'
        Apply = { Set-Tweak 'throttle' 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 }
        Test  = { Test-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 } }
    [pscustomobject]@{ Id = 'priosep'; Cat = 'Energia e CPU'; Glyph = 0xE9D9; Impact = 'placebo'; Flags = @(); Rec = $false
        Name = 'Priorizar app em primeiro plano'
        Desc = 'Win32PrioritySeparation = 38 (quantum curto, variável, boost 3x). O padrão do Windows já é parecido.'
        Apply = { Set-Tweak 'priosep' 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 }
        Test  = { Test-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 } }
    [pscustomobject]@{ Id = 'mmcss'; Cat = 'Energia e CPU'; Glyph = 0xE7FC; Impact = 'placebo'; Flags = @(); Rec = $false
        Name = 'Prioridade MMCSS para jogos'
        Desc = 'SystemResponsiveness 10, sem throttling de rede e prioridade alta na tarefa "Games". Só afeta apps que usam MMCSS.'
        Apply = {
            Set-Tweak 'mmcss' $SP 'SystemResponsiveness' 10
            Set-Tweak 'mmcss' $SP 'NetworkThrottlingIndex' (-1)   # 0xFFFFFFFF
            Set-Tweak 'mmcss' "$SP\Tasks\Games" 'GPU Priority' 8
            Set-Tweak 'mmcss' "$SP\Tasks\Games" 'Priority' 6
            Set-Tweak 'mmcss' "$SP\Tasks\Games" 'Scheduling Category' 'High' 'String'
            Set-Tweak 'mmcss' "$SP\Tasks\Games" 'SFIO Priority' 'High' 'String' }
        Test  = { (Test-Reg $SP 'SystemResponsiveness' 10) -and (Test-Reg "$SP\Tasks\Games" 'GPU Priority' 8) } }

    [pscustomobject]@{ Id = 'vbs'; Cat = 'Jogos e GPU'; Glyph = 0xE72E; Impact = 'real'; Flags = @('reiniciar', 'seguranca'); Rec = $false
        Name = 'Desativar VBS / Integridade de memória'
        Desc = 'A própria Microsoft indica desligar para jogos: 5 a 15% de FPS em vários títulos. Reduz a proteção contra drivers maliciosos. Não funciona se a VBS estiver travada na UEFI.'
        Apply = {
            Set-Tweak 'vbs' $HvciPath 'Enabled' 0
            Set-Tweak 'vbs' 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0 }
        Test  = { Test-VbsOff } }
    [pscustomobject]@{ Id = 'windowed'; Cat = 'Jogos e GPU'; Glyph = 0xE737; Impact = 'real'; Flags = @(); Rec = $true
        Name = 'Otimizações para jogos em janela'
        Desc = 'Windows 11. Jogos DX10/DX11 em janela ou sem borda passam a usar flip model: menos latência e suporte a G-Sync/FreeSync.'
        Apply = { Enable-WindowedOpt }
        Test  = { (Get-RegValue $DxPath 'DirectXUserGlobalSettings').Value -match 'SwapEffectUpgradeEnable=1' } }
    [pscustomobject]@{ Id = 'gamedvr'; Cat = 'Jogos e GPU'; Glyph = 0xE714; Impact = 'real'; Flags = @(); Rec = $true
        Name = 'Desativar Game DVR'
        Desc = 'Desliga a gravação em segundo plano da Xbox Game Bar, que consome GPU e encoder durante o jogo.'
        Apply = {
            Set-Tweak 'gamedvr' 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
            Set-Tweak 'gamedvr' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 }
        Test  = { (Test-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0) -and
                  (Test-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0) } }
    [pscustomobject]@{ Id = 'gamemode'; Cat = 'Jogos e GPU'; Glyph = 0xE7FC; Impact = 'real'; Flags = @(); Rec = $true
        Name = 'Ativar Modo de Jogo'
        Desc = 'Prioriza o jogo e segura atualizações do Windows Update enquanto você joga. Já vem ligado por padrão no Windows.'
        Apply = { Set-Tweak 'gamemode' 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 }
        # Sem o valor no registro, o Windows considera ligado
        Test  = { -not (Test-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0) } }
    [pscustomobject]@{ Id = 'hags'; Cat = 'Jogos e GPU'; Glyph = 0xE7F4; Impact = 'situacional'; Flags = @('reiniciar'); Rec = $false
        Name = 'Agendamento de GPU por hardware'
        Desc = 'HAGS. Necessário para DLSS Frame Generation; em outros casos o efeito varia de GPU para GPU.'
        Apply = { Set-Tweak 'hags' 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchGpuMode' 2 }
        Test  = { Test-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchGpuMode' 2 } }
    [pscustomobject]@{ Id = 'fse'; Cat = 'Jogos e GPU'; Glyph = 0xE740; Impact = 'situacional'; Flags = @(); Rec = $false
        Name = 'Desativar otimizações de tela cheia'
        Desc = 'Força tela cheia exclusiva de verdade em jogos antigos (DX9/DX11). Pode reduzir input lag ou piorar alt+tab; teste no seu jogo.'
        Apply = {
            Set-Tweak 'fse' 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2
            Set-Tweak 'fse' 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2
            Set-Tweak 'fse' 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1
            Set-Tweak 'fse' 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1 }
        Test  = { Test-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2 } }

    [pscustomobject]@{ Id = 'mouse'; Cat = 'Entrada e rede'; Glyph = 0xE962; Impact = 'real'; Flags = @('relogar'); Rec = $true
        Name = 'Desativar aceleração do mouse'
        Desc = 'Movimento 1:1, mira mais consistente. Não muda FPS, muda a sensação.'
        Apply = {
            Set-Tweak 'mouse' 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
            Set-Tweak 'mouse' 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
            Set-Tweak 'mouse' 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String' }
        Test  = { Test-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' } }
    [pscustomobject]@{ Id = 'nagle'; Cat = 'Entrada e rede'; Glyph = 0xE839; Impact = 'placebo'; Flags = @('reiniciar'); Rec = $false
        Name = 'Desativar Nagle (TCP)'
        Desc = 'TcpAckFrequency e TCPNoDelay nas interfaces com IP. A maioria dos jogos usa UDP, então quase não muda nada.'
        Apply = { Disable-Nagle }
        Test  = { Test-Nagle } }

    [pscustomobject]@{ Id = 'bgapps'; Cat = 'Sistema'; Glyph = 0xE71D; Impact = 'situacional'; Flags = @(); Rec = $true
        Name = 'Bloquear apps em segundo plano'
        Desc = 'Apps da Microsoft Store (Fotos, Clima, Notícias...) param de rodar escondidos. Menos uso de CPU e RAM em PCs modestos.'
        Apply = {
            Set-Tweak 'bgapps' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
            Set-Tweak 'bgapps' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0 }
        Test  = { Test-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1 } }
    [pscustomobject]@{ Id = 'services'; Cat = 'Sistema'; Glyph = 0xE713; Impact = 'situacional'; Flags = @(); Rec = $false
        Name = 'Desativar DiagTrack e SysMain'
        Desc = 'Telemetria e pré-carregamento de apps. Ajuda em PCs com HD; em SSD a diferença é mínima.'
        Apply = { Disable-Services }
        Test  = {
            $s = @(Get-Service $Services -ErrorAction SilentlyContinue)
            $s.Count -gt 0 -and -not @($s | Where-Object { $_.StartType -ne 'Disabled' }).Count } }
    [pscustomobject]@{ Id = 'visual'; Cat = 'Sistema'; Glyph = 0xE790; Impact = 'situacional'; Flags = @(); Rec = $false
        Name = 'Efeitos visuais leves'
        Desc = 'Melhor desempenho e sem transparência. Deixa a área de trabalho mais leve em PCs fracos; no jogo quase não muda.'
        Apply = {
            Set-Tweak 'visual' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
            Set-Tweak 'visual' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 }
        Test  = { Test-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 } }
)

# ---------------- Ajustes do Windows (privacidade, anúncios, IA, interface) ----------------
# Só registro: cada entrada é @(caminho, nome, valor[, tipo]). Não mexem em FPS, limpam o Windows.
$ADV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$EP  = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$WAI = 'Software\Policies\Microsoft\Windows\WindowsAI'
$WinTweaks = @(
    @{ Id = 'w_copilot'; Grp = 'IA'; Name = 'Desativar Copilot'; Desc = 'Política que desliga o Copilot do Windows.'
       Regs = @(@('HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1),
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot', 'TurnOffWindowsCopilot', 1)) }
    @{ Id = 'w_copilotbtn'; Grp = 'IA'; Name = 'Ocultar botão do Copilot'; Desc = 'Remove o botão do Copilot da barra de tarefas.'; Flags = @('explorer')
       Regs = @(, @($ADV, 'ShowCopilotButton', 0)) }
    @{ Id = 'w_recall'; Grp = 'IA'; Name = 'Desativar Recall'; Desc = 'Impede o Windows de tirar capturas da tela para a busca do Recall.'
       Regs = @(@("HKCU:\$WAI", 'DisableAIDataAnalysis', 1), @("HKLM:\$WAI", 'DisableAIDataAnalysis', 1)) }
    @{ Id = 'w_clicktodo'; Grp = 'IA'; Name = 'Desativar Click to Do'; Desc = 'Desliga as ações de IA sobre o que está na tela.'
       Regs = @(@("HKCU:\$WAI", 'DisableClickToDo', 1), @("HKLM:\$WAI", 'DisableClickToDo', 1)) }
    @{ Id = 'w_notepadai'; Grp = 'IA'; Name = 'Desativar IA do Bloco de Notas'; Desc = 'Remove reescrever/resumir com IA no Bloco de Notas.'
       Regs = @(, @('HKLM:\SOFTWARE\Policies\WindowsNotepad', 'DisableAIFeatures', 1)) }
    @{ Id = 'w_paintai'; Grp = 'IA'; Name = 'Desativar IA do Paint'; Desc = 'Desliga Cocreator, preenchimento generativo e criador de imagens no Paint.'
       Regs = @(@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint', 'DisableCocreator', 1),
                @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint', 'DisableGenerativeFill', 1),
                @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint', 'DisableImageCreator', 1)) }

    @{ Id = 'w_startsugg'; Grp = 'Anúncios'; Name = 'Sem sugestões no Iniciar'; Desc = 'Tira apps sugeridos (propaganda) do menu Iniciar.'
       Regs = @(@($CDM, 'SubscribedContent-338388Enabled', 0), @($CDM, 'SystemPaneSuggestionsEnabled', 0)) }
    @{ Id = 'w_startrec'; Grp = 'Anúncios'; Name = 'Sem recomendações no Iniciar'; Desc = 'Remove dicas e apps em destaque da área Recomendados.'; Flags = @('explorer')
       Regs = @(, @($ADV, 'Start_IrisRecommendations', 0)) }
    @{ Id = 'w_silentapps'; Grp = 'Anúncios'; Name = 'Bloquear apps instalados sozinhos'; Desc = 'Impede o Windows de instalar jogos e apps promocionais sem pedir.'
       Regs = @(@($CDM, 'SilentInstalledAppsEnabled', 0), @($CDM, 'PreInstalledAppsEnabled', 0), @($CDM, 'OemPreInstalledAppsEnabled', 0)) }
    @{ Id = 'w_tips'; Grp = 'Anúncios'; Name = 'Sem dicas e truques'; Desc = 'Desliga notificações de dicas e sugestões do Windows.'
       Regs = @(@($CDM, 'SubscribedContent-338389Enabled', 0), @($CDM, 'SoftLandingEnabled', 0)) }
    @{ Id = 'w_lockads'; Grp = 'Anúncios'; Name = 'Sem anúncios na tela de bloqueio'; Desc = 'Remove curiosidades e propagandas da tela de bloqueio.'
       Regs = @(@($CDM, 'RotatingLockScreenOverlayEnabled', 0), @($CDM, 'SubscribedContent-338387Enabled', 0)) }
    @{ Id = 'w_settingsads'; Grp = 'Anúncios'; Name = 'Sem sugestões em Configurações'; Desc = 'Tira conteúdo sugerido do app Configurações.'
       Regs = @(@($CDM, 'SubscribedContent-338393Enabled', 0), @($CDM, 'SubscribedContent-353694Enabled', 0), @($CDM, 'SubscribedContent-353696Enabled', 0)) }
    @{ Id = 'w_adid'; Grp = 'Anúncios'; Name = 'Desativar ID de anúncio'; Desc = 'Apps deixam de usar um identificador para anúncios personalizados.'
       Regs = @(, @('HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled', 0)) }
    @{ Id = 'w_tailored'; Grp = 'Anúncios'; Name = 'Sem experiências personalizadas'; Desc = 'A Microsoft não usa seus dados de diagnóstico para dicas e ofertas.'
       Regs = @(, @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy', 'TailoredExperiencesWithDiagnosticDataEnabled', 0)) }
    @{ Id = 'w_scoobe'; Grp = 'Anúncios'; Name = 'Sem "Concluir configuração"'; Desc = 'Para a tela que insiste em conta Microsoft, OneDrive e Game Pass.'
       Regs = @(, @('HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', 'ScoobeSystemSettingEnabled', 0)) }
    @{ Id = 'w_explorerads'; Grp = 'Anúncios'; Name = 'Sem anúncios no Explorador'; Desc = 'Remove as propagandas de OneDrive/Microsoft 365 no Explorador de Arquivos.'; Flags = @('explorer')
       Regs = @(, @($ADV, 'ShowSyncProviderNotifications', 0)) }

    @{ Id = 'w_telemetry'; Grp = 'Privacidade'; Name = 'Telemetria no mínimo'; Desc = 'Envia só os dados de diagnóstico obrigatórios.'
       Regs = @(, @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection', 'AllowTelemetry', 0)) }
    @{ Id = 'w_activity'; Grp = 'Privacidade'; Name = 'Desativar histórico de atividades'; Desc = 'O Windows para de registrar e enviar o que você abre.'
       Regs = @(@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'EnableActivityFeed', 0),
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'PublishUserActivities', 0),
                @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System', 'UploadUserActivities', 0)) }
    @{ Id = 'w_trackprogs'; Grp = 'Privacidade'; Name = 'Não rastrear apps abertos'; Desc = 'O Iniciar deixa de montar lista de apps mais usados.'
       Regs = @(, @($ADV, 'Start_TrackProgs', 0)) }
    @{ Id = 'w_feedback'; Grp = 'Privacidade'; Name = 'Sem pedidos de feedback'; Desc = 'Para as perguntas "como está o Windows?".'
       Regs = @(, @('HKCU:\Software\Microsoft\Siuf\Rules', 'NumberOfSIUFInPeriod', 0)) }
    @{ Id = 'w_wer'; Grp = 'Privacidade'; Name = 'Desativar relatório de erros'; Desc = 'Não envia relatórios de travamento para a Microsoft.'
       Regs = @(, @('HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting', 'Disabled', 1)) }
    @{ Id = 'w_inking'; Grp = 'Privacidade'; Name = 'Não coletar digitação e escrita'; Desc = 'O Windows para de aprender com o que você digita ou escreve.'
       Regs = @(@('HKCU:\Software\Microsoft\InputPersonalization', 'RestrictImplicitTextCollection', 1),
                @('HKCU:\Software\Microsoft\InputPersonalization', 'RestrictImplicitInkCollection', 1)) }

    @{ Id = 'w_websearch'; Grp = 'Pesquisa'; Name = 'Sem resultados da web'; Desc = 'A pesquisa do Iniciar procura só no PC, sem Bing.'; Flags = @('explorer')
       Regs = @(@('HKCU:\Software\Policies\Microsoft\Windows\Explorer', 'DisableSearchBoxSuggestions', 1),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0)) }
    @{ Id = 'w_highlights'; Grp = 'Pesquisa'; Name = 'Sem destaques da pesquisa'; Desc = 'Remove as ilustrações e notícias da caixa de pesquisa.'
       Regs = @(, @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDynamicSearchBoxEnabled', 0)) }

    @{ Id = 'w_edgebg'; Grp = 'Edge'; Name = 'Edge fora do segundo plano'; Desc = 'O Edge fecha de verdade e não pré-carrega com o Windows. Libera RAM. O Edge mostra "gerenciado pela organização".'
       Regs = @(@($EP, 'BackgroundModeEnabled', 0), @($EP, 'StartupBoostEnabled', 0)) }
    @{ Id = 'w_edgesidebar'; Grp = 'Edge'; Name = 'Sem barra lateral e Copilot no Edge'; Desc = 'Remove a barra lateral do Edge, incluindo o Copilot.'
       Regs = @(, @($EP, 'HubsSidebarEnabled', 0)) }
    @{ Id = 'w_edgenews'; Grp = 'Edge'; Name = 'Sem notícias na nova guia'; Desc = 'Nova guia sem feed de notícias e sem recomendações.'
       Regs = @(@($EP, 'NewTabPageContentEnabled', 0), @($EP, 'ShowRecommendationsEnabled', 0)) }
    @{ Id = 'w_edgeshop'; Grp = 'Edge'; Name = 'Sem compras e cupons no Edge'; Desc = 'Desliga o assistente de compras do Edge.'
       Regs = @(, @($EP, 'EdgeShoppingAssistantEnabled', 0)) }

    @{ Id = 'w_widgets'; Grp = 'Barra de tarefas'; Name = 'Desativar Widgets'; Desc = 'Remove o painel de notícias/clima, que fica rodando em segundo plano.'; Flags = @('explorer')
       Regs = @(, @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh', 'AllowNewsAndInterests', 0)) }
    @{ Id = 'w_taskview'; Grp = 'Barra de tarefas'; Name = 'Ocultar Visão de Tarefas'; Desc = 'Tira o botão de áreas de trabalho da barra.'; Flags = @('explorer')
       Regs = @(, @($ADV, 'ShowTaskViewButton', 0)) }
    @{ Id = 'w_searchicon'; Grp = 'Barra de tarefas'; Name = 'Pesquisa só como ícone'; Desc = 'Troca a caixa de pesquisa grande por um ícone.'; Flags = @('explorer')
       Regs = @(, @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'SearchboxTaskbarMode', 1)) }
    @{ Id = 'w_taskleft'; Grp = 'Barra de tarefas'; Name = 'Ícones à esquerda'; Desc = 'Alinha o Iniciar e os ícones à esquerda, como no Windows 10.'; Flags = @('explorer')
       Regs = @(, @($ADV, 'TaskbarAl', 0)) }

    @{ Id = 'w_ext'; Grp = 'Explorador'; Name = 'Mostrar extensões de arquivo'; Desc = 'Mostra .exe, .zip etc. Ajuda a perceber arquivos falsos.'; Flags = @('explorer')
       Regs = @(, @($ADV, 'HideFileExt', 0)) }
    @{ Id = 'w_hidden'; Grp = 'Explorador'; Name = 'Mostrar arquivos ocultos'; Desc = 'Exibe pastas como AppData no Explorador.'; Flags = @('explorer')
       Regs = @(, @($ADV, 'Hidden', 1)) }
    @{ Id = 'w_thispc'; Grp = 'Explorador'; Name = 'Abrir em "Este Computador"'; Desc = 'O Explorador abre mostrando os discos em vez de Início.'
       Regs = @(, @($ADV, 'LaunchTo', 1)) }
    @{ Id = 'w_dark'; Grp = 'Explorador'; Name = 'Modo escuro'; Desc = 'Tema escuro para o Windows e os apps.'
       Regs = @(@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'AppsUseLightTheme', 0),
                @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'SystemUsesLightTheme', 0)) }

    @{ Id = 'w_sticky'; Grp = 'Jogos'; Name = 'Sem popup de Teclas de Aderência'; Desc = 'Apertar Shift 5 vezes no jogo não abre mais o aviso que minimiza o jogo.'
       Regs = @(@('HKCU:\Control Panel\Accessibility\StickyKeys', 'Flags', '506', 'String'),
                @('HKCU:\Control Panel\Accessibility\ToggleKeys', 'Flags', '58', 'String'),
                @('HKCU:\Control Panel\Accessibility\Keyboard Response', 'Flags', '122', 'String')) }
    @{ Id = 'w_fastboot'; Grp = 'Jogos'; Name = 'Desativar inicialização rápida'; Desc = 'Desligar passa a ser desligar de verdade: evita drivers travados e bugs que só somem reiniciando.'
       Regs = @(, @('HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power', 'HiberbootEnabled', 0)) }
)
foreach ($w in $WinTweaks) {
    $Tweaks += [pscustomobject]@{ Id = $w.Id; Page = 'win'; Cat = $w.Grp; Name = $w.Name; Desc = $w.Desc; Regs = $w.Regs
                                   Flags = @($w.Flags | Where-Object { $_ }); Rec = $false; Impact = 'placebo'; Glyph = 0 }
}

function Invoke-Tweak($t) {
    if (-not $t.Regs) { return & $t.Apply }
    foreach ($r in $t.Regs) {
        $kind = if ($r.Count -gt 3) { $r[3] } else { 'DWord' }
        Set-Tweak $t.Id $r[0] $r[1] $r[2] $kind
    }
}

# Mudanças na barra de tarefas/Explorador só aparecem depois de reabrir o Explorer (o Windows reabre sozinho)
function Restart-Explorer { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue }

# ---------------- Reverter ----------------
function Undo-Tweaks([string[]]$Ids) {
    foreach ($id in @($script:Backup.reg.Keys)) {
        $e = $script:Backup.reg[$id]
        if ($Ids -notcontains $e.Tweak) { continue }
        $path, $name = $id -split '\|', 2
        if ($e.Exists) { Set-RegValue $path $name $e.Value $e.Kind }
        else { Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue }
        $script:Backup.reg.Remove($id)
    }
    foreach ($svc in @($script:Backup.services.Keys)) {
        $e = $script:Backup.services[$svc]
        if ($Ids -notcontains $e.Tweak) { continue }
        $mode = switch ($e.StartMode) { 'Auto' { 'Automatic' } 'Disabled' { 'Disabled' } default { 'Manual' } }
        Set-Service $svc -StartupType $mode
        if ($mode -eq 'Automatic') { Start-Service $svc -ErrorAction SilentlyContinue }
        $script:Backup.services.Remove($svc)
    }
    if ($script:Backup.power -and $Ids -contains 'power') {
        if ($script:Backup.power.Original) { powercfg /setactive $script:Backup.power.Original | Out-Null }
        if ($script:Backup.power.Created)  { powercfg /delete $script:Backup.power.Created | Out-Null }
        $script:Backup.power = $null
    }
    Save-Backup
}

function Test-HasBackup([string]$Id) {
    if ($Id -eq 'power') { return $null -ne $script:Backup.power }
    if (@($script:Backup.services.Values | Where-Object { $_.Tweak -eq $Id }).Count) { return $true }
    return [bool](@($script:Backup.reg.Values | Where-Object { $_.Tweak -eq $Id }).Count)
}

function Test-Applied($t) {
    if ($t.Regs) {
        foreach ($r in $t.Regs) { if (-not (Test-Reg $r[0] $r[1] $r[2])) { return $false } }
        return $true
    }
    try { return [bool](& $t.Test) } catch { return Test-HasBackup $t.Id }
}

# ---------------- Diagnóstico ----------------
# Coisas que pesam muito mais no FPS do que qualquer ajuste de registro
function Invoke-Diagnostics {
    Clear-Findings
    Write-Log 'Analisando o PC...'

    $hz = [Native.Display]::Refresh()
    if ($hz) {
        if ($hz[1] -gt $hz[0]) {
            Add-Finding "Monitor em $($hz[0]) Hz, mas suporta $($hz[1]) Hz em $($hz[2])x$($hz[3]). Mude em Tela > Configurações avançadas de vídeo." 'warn'
        } else { Add-Finding "Monitor na taxa máxima: $($hz[0]) Hz ($($hz[2])x$($hz[3]))." 'ok' }
    }

    $mem = @(Get-CimInstance Win32_PhysicalMemory)
    if ($mem.Count) {
        $clk  = ($mem | Measure-Object ConfiguredClockSpeed -Minimum).Minimum
        $type = $mem[0].SMBIOSMemoryType
        $gen  = switch ($type) { 26 { 'DDR4' } 34 { 'DDR5' } default { 'RAM' } }
        $slow = ($type -eq 26 -and $clk -lt 3000) -or ($type -eq 34 -and $clk -le 4800)
        if ($slow) { Add-Finding "$gen rodando a $clk MT/s. Se o seu kit é mais rápido, ative XMP/EXPO na BIOS: ganho real de FPS, principalmente em Ryzen." 'warn' }
        else { Add-Finding "$gen rodando a $clk MT/s." 'ok' }
        if ($mem.Count -eq 1) { Add-Finding 'Só 1 pente de RAM (single channel). Um segundo pente igual pode render 10 a 30% em jogos que dependem de CPU.' 'warn' }
    }

    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    if ($dg -and $dg.VirtualizationBasedSecurityStatus -eq 2) {
        Add-Finding 'VBS/Integridade de memória está rodando. Desligar costuma dar 5 a 15% de FPS (ajuste em Otimizar).' 'warn'
    }

    if (-not (Test-PerfCounters)) {
        Add-Finding 'Contadores de desempenho do Windows corrompidos (afeta o Gerenciador de Tarefas). Use Ferramentas > Reparar contadores.' 'warn'
    }

    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bat -and $bat.BatteryStatus -ne 2) { Add-Finding 'Notebook na bateria: a CPU e a GPU ficam limitadas. Jogue na tomada.' 'warn' }

    foreach ($v in Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' }) {
        $age = ((Get-Date) - $v.DriverDate).Days
        if ($age -gt 180) { Add-Finding "Driver de vídeo ($($v.Name)) tem $age dias. Atualize pelo site da NVIDIA/AMD/Intel." 'warn' }
        else { Add-Finding "Driver de vídeo ($($v.Name)) atualizado ($age dias)." 'ok' }
    }

    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    if ($c -and $c.Size) {
        $pct = [math]::Round(100 * $c.FreeSpace / $c.Size)
        if ($pct -lt 10) { Add-Finding "Disco do sistema com só $pct% livre. Pouco espaço causa travadas (stutter)." 'warn' }
    }

    $hogs = Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
    } | Where-Object { $_.MB -ge 500 -and $_.Name -notmatch '^(Memory Compression|System|dwm|MsMpEng|explorer|svchost|vmmem.*|powershell)$' } |
        Sort-Object MB -Descending | Select-Object -First 5
    if ($hogs) {
        Add-Finding ('Feche antes de jogar: ' + (($hogs | ForEach-Object { "$($_.Name) ($($_.MB) MB)" }) -join ', ')) 'warn'
    }
    if ($script:WarnTotal) { Write-Log "Análise concluída: $script:WarnTotal ponto(s) de atenção. Veja a aba Análise." 'warn' }
    else { Write-Log 'Análise concluída: nada a corrigir.' 'ok' }
}

# ---------------- Info do sistema ----------------
function Get-SysInfo {
    $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s+', ' '
    $gpu = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' } |
            Select-Object -First 1).Name
    $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $os  = (Get-CimInstance Win32_OperatingSystem).Caption -replace 'Microsoft ', ''
    return @{ Cpu = "$cpu".Trim(); Gpu = $(if ($gpu) { $gpu } else { 'Não detectada' }); Ram = "$ram GB"; Os = $os }
}

# Dados para os cards do Painel (nomes curtos e marca)
function Get-HwInfo {
    $p = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpuName  = ($p.Name -replace '\(R\)|\(TM\)|\d+-Core Processor|Processor|CPU @.*|with Radeon.*', '' -replace '^\s*(AMD|Intel)\s+', '' -replace '\s+', ' ').Trim()
    $cpuBrand = if ($p.Name -match 'AMD') { 'AMD' } elseif ($p.Name -match 'Intel') { 'INTEL' } else { '' }

    $v = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' } | Select-Object -First 1
    $gpuBrand = switch -Regex ("$($v.Name)") { 'NVIDIA|GeForce' { 'NVIDIA' } 'AMD|Radeon' { 'AMD' } 'Intel|Arc' { 'INTEL' } default { '' } }
    $gpuName  = ("$($v.Name)" -replace 'NVIDIA|GeForce|AMD|Radeon\(TM\)|Intel\(R\)', '' -replace '\s+', ' ').Trim()
    $hasNv    = [bool](Get-Command nvidia-smi -ErrorAction SilentlyContinue)
    $driver   = if ($hasNv) { "$(& nvidia-smi --query-gpu=driver_version --format=csv,noheader | Select-Object -First 1)".Trim() } else { $v.DriverVersion }

    $mem = @(Get-CimInstance Win32_PhysicalMemory)
    $pn  = "$($mem[0].PartNumber)".Trim()
    $mf  = "$($mem[0].Manufacturer)".Trim()
    $memBrand = switch -Regex ($pn) {
        '^CM'              { 'CORSAIR' }
        '^F[345]-'         { 'G.SKILL' }
        '^(KF|KHX|KVR)'    { 'KINGSTON' }
        '^(BL|CT)'         { 'CRUCIAL' }
        '^(TF|TED|FF)'     { 'TEAMGROUP' }
        '^(M3|M4)'         { 'SAMSUNG' }
        '^HM'              { 'SK HYNIX' }
        '^PV'              { 'PATRIOT' }
        '^AX'              { 'XPG' }
        default            { if ($mf -and $mf -notmatch 'Unknown|^0') { $mf.ToUpper() } else { '' } }
    }

    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    return @{
        CpuName = $cpuName; CpuBrand = $cpuBrand; Cores = $p.NumberOfCores; Threads = $p.NumberOfLogicalProcessors; MaxMhz = $p.MaxClockSpeed
        GpuName = $(if ($gpuName) { $gpuName } else { 'Não detectada' }); GpuBrand = $gpuBrand; Driver = $driver; HasNv = $hasNv
        MemGb   = [math]::Round(($mem | Measure-Object Capacity -Sum).Sum / 1GB)
        MemType = switch ($mem[0].SMBIOSMemoryType) { 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { 'RAM' } }
        MemMts  = ($mem | Measure-Object ConfiguredClockSpeed -Minimum).Minimum; MemCount = $mem.Count; MemBrand = $memBrand
        OsName  = ((Get-CimInstance Win32_OperatingSystem).Caption -replace 'Microsoft Windows', 'Win').Trim()
        Build   = "$($cv.CurrentBuild).$($cv.UBR)"; OsVer = $cv.DisplayVersion
    }
}

function Test-PerfCounters {
    try { Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop | Out-Null; return $true }
    catch { return $false }
}

function Repair-PerfCounters {
    Write-Log 'Reconstruindo contadores de desempenho (lodctr /R)...'
    $out = (& "$env:windir\System32\lodctr.exe" /R 2>&1) | Out-String
    if (Test-Path "$env:windir\SysWOW64\lodctr.exe") { & "$env:windir\SysWOW64\lodctr.exe" /R 2>&1 | Out-Null }
    & "$env:windir\System32\wbem\winmgmt.exe" /resyncperf 2>&1 | Out-Null
    Write-Log $out.Trim()
    if (Test-PerfCounters) { Write-Log 'Contadores reparados.' 'ok' }
    else { Write-Log 'Feito. Se ainda não funcionar, reinicie o PC.' 'warn' }
}

# ---------------- Interface (XAML) ----------------
# Visual flat: tons de cinza escuro, uma única cor de destaque, sem gradientes.
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BLK Boost" Width="1080" Height="720" MinWidth="880" MinHeight="580"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#0E0F11" FontFamily="Segoe UI" UseLayoutRounding="True">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="40" ResizeBorderThickness="5" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"        Color="#0E0F11"/>
    <SolidColorBrush x:Key="Rail"      Color="#09090B"/>
    <SolidColorBrush x:Key="Surface"   Color="#16181B"/>
    <SolidColorBrush x:Key="SurfaceHi" Color="#1C1F23"/>
    <SolidColorBrush x:Key="Line"      Color="#24272C"/>
    <SolidColorBrush x:Key="Text"      Color="#ECEDEE"/>
    <SolidColorBrush x:Key="Muted"     Color="#8A8F98"/>
    <SolidColorBrush x:Key="Dim"       Color="#5C616B"/>
    <SolidColorBrush x:Key="Accent"    Color="#F2542D"/>
    <SolidColorBrush x:Key="AccentHi"  Color="#FF6A45"/>

    <!-- Toggle -->
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="38" Height="20" CornerRadius="10" Background="#2A2D33">
              <Ellipse x:Name="Thumb" Width="14" Height="14" Fill="#8A8F98" HorizontalAlignment="Left" Margin="3,0,0,0">
                <Ellipse.RenderTransform><TranslateTransform x:Name="Tx" X="0"/></Ellipse.RenderTransform>
              </Ellipse>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Thumb" Property="Fill" Value="White"/>
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard>
                    <DoubleAnimation Storyboard.TargetName="Tx" Storyboard.TargetProperty="X" To="18" Duration="0:0:0.12"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard>
                    <DoubleAnimation Storyboard.TargetName="Tx" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.12"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Botões -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="#1F2226"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="4">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#272A2F"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="#2E3238"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Padding" Value="22,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource AccentHi}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="#E5534B"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
    </Style>
    <Style x:Key="BtnChrome" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#1C1F23"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnClose" TargetType="Button" BasedOn="{StaticResource BtnChrome}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#C42B1C"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Menu lateral -->
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="Height" Value="56"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="Nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid x:Name="G" Background="Transparent">
              <Border x:Name="Bar" Width="3" HorizontalAlignment="Left" Background="{StaticResource Accent}" Visibility="Collapsed"/>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{StaticResource Muted}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter TargetName="G" Property="Background" Value="#131518"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Linha de lista -->
    <Style x:Key="Row" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Surface}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Surface}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="14,12"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{StaticResource SurfaceHi}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="22"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Margin" Value="0,3,0,0"/>
    </Style>
    <Style x:Key="Caps" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    </Style>

    <!-- Filtro em pílula -->
    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="B" Background="#1F2226" CornerRadius="14" Padding="12,5">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#272A2F"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Text}"/>
                <Setter Property="Foreground" Value="#0E0F11"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Campo de texto -->
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="B" Background="#0A0B0C" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="4">
              <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Margin="10,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Dim}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="IsHitTestVisible" Value="False"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="13,0,0,0"/>
    </Style>
    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Surface}"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="12"/>
    </Style>

    <!-- Scrollbar fina -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="#2A2D33" CornerRadius="3"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="40"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="28"/>
      </Grid.RowDefinitions>

      <!-- Barra de título -->
      <Grid Background="{StaticResource Rail}">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
          <Border Width="22" Height="22" CornerRadius="3" Background="{StaticResource Accent}">
            <TextBlock Text="B" FontWeight="Black" FontSize="13" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="BLK BOOST" Foreground="{StaticResource Text}" FontSize="12" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnMin"   Style="{StaticResource BtnChrome}" Content="&#xE921;"/>
          <Button x:Name="BtnMax"   Style="{StaticResource BtnChrome}" Content="&#xE922;"/>
          <Button x:Name="BtnClose" Style="{StaticResource BtnClose}"  Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="76"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Menu -->
        <Border Background="{StaticResource Rail}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
          <DockPanel LastChildFill="False" Margin="0,8,0,8">
            <StackPanel DockPanel.Dock="Top">
              <RadioButton x:Name="NavHome" Style="{StaticResource Nav}" Tag="PageHome" IsChecked="True">
                <StackPanel>
                  <TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                  <TextBlock Text="Painel" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavOpt" Style="{StaticResource Nav}" Tag="PageOpt">
                <StackPanel>
                  <TextBlock Text="&#xE945;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                  <TextBlock Text="Otimizar" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavWin" Style="{StaticResource Nav}" Tag="PageWin">
                <StackPanel>
                  <TextBlock Text="&#xE770;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                  <TextBlock Text="Windows" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavGame" Style="{StaticResource Nav}" Tag="PageGame">
                <StackPanel>
                  <TextBlock Text="&#xE7FC;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                  <TextBlock Text="Modo Jogo" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavBench" Style="{StaticResource Nav}" Tag="PageBench">
                <StackPanel>
                  <TextBlock Text="&#xE916;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                  <TextBlock Text="Benchmark" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavDiag" Style="{StaticResource Nav}" Tag="PageDiag">
                <Grid>
                  <StackPanel>
                    <TextBlock Text="&#xE9D9;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                    <TextBlock Text="Análise" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                  </StackPanel>
                  <Border x:Name="WarnBadge" Visibility="Collapsed" Background="{StaticResource Accent}" CornerRadius="7"
                          MinWidth="14" Height="14" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-5,-8,0">
                    <TextBlock x:Name="WarnCount" FontSize="9" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="4,0"/>
                  </Border>
                </Grid>
              </RadioButton>
              <RadioButton x:Name="NavTools" Style="{StaticResource Nav}" Tag="PageTools">
                <StackPanel>
                  <TextBlock Text="&#xE90F;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                  <TextBlock Text="Ferramentas" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavLog" Style="{StaticResource Nav}" Tag="PageLog">
                <StackPanel>
                  <TextBlock Text="&#xE81C;" FontFamily="Segoe MDL2 Assets" FontSize="18" HorizontalAlignment="Center"/>
                  <TextBlock Text="Atividade" FontSize="10" Margin="0,5,0,0" HorizontalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
            </StackPanel>
          </DockPanel>
        </Border>

        <!-- Página: Painel -->
        <ScrollViewer x:Name="PageHome" Grid.Column="1" VerticalScrollBarVisibility="Auto" Padding="28,22,18,16">
          <StackPanel>
            <StackPanel Margin="0,0,10,14">
              <TextBlock Text="Painel" Style="{StaticResource H1}"/>
              <TextBlock Text="Seu hardware." Style="{StaticResource Sub}"/>
            </StackPanel>
            <TextBlock Text="SISTEMA" Style="{StaticResource Caps}" Margin="2,0,0,8"/>
            <UniformGrid x:Name="SysCards" Columns="2"/>
          </StackPanel>
        </ScrollViewer>

        <!-- Página: Otimizar -->
        <Grid x:Name="PageOpt" Grid.Column="1" Visibility="Collapsed" Margin="0,0,0,64">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Margin="28,22,28,14">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
              <StackPanel VerticalAlignment="Center" Margin="0,0,22,0">
                <DockPanel>
                  <TextBlock Text="ATIVOS" Style="{StaticResource Caps}" VerticalAlignment="Bottom" Margin="0,0,10,2"/>
                  <TextBlock x:Name="ActiveTotal" Text="/ 0" DockPanel.Dock="Right" FontSize="12" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="4,0,0,2"/>
                  <TextBlock x:Name="ActiveCount" Text="0" FontSize="20" FontWeight="SemiBold" Foreground="{StaticResource Text}" HorizontalAlignment="Right"/>
                </DockPanel>
                <Grid Width="150" Height="3" Margin="0,6,0,0">
                  <Border Background="{StaticResource Line}"/>
                  <Border x:Name="Meter" Background="{StaticResource Accent}" HorizontalAlignment="Left" Width="0"/>
                </Grid>
              </StackPanel>
              <Button x:Name="BtnRec" Style="{StaticResource Btn}" Content="Ligar recomendados"/>
            </StackPanel>
            <StackPanel>
              <TextBlock Text="Otimizações" Style="{StaticResource H1}"/>
              <TextBlock Text="Ligado = ativo no PC agora. Mude o que quiser e clique em Aplicar." Style="{StaticResource Sub}"/>
            </StackPanel>
          </DockPanel>

          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="28,0,16,4">
            <StackPanel x:Name="Sections"/>
          </ScrollViewer>
        </Grid>

        <!-- Página: Windows -->
        <Grid x:Name="PageWin" Grid.Column="1" Visibility="Collapsed" Margin="0,0,0,64">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Margin="28,18,28,12">
            <Grid DockPanel.Dock="Right" Width="68" Height="68">
              <Ellipse Stroke="{StaticResource Line}" StrokeThickness="4"/>
              <Path x:Name="WinArc" Stroke="{StaticResource Accent}" StrokeThickness="4" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
              <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <TextBlock x:Name="WinCount" Text="0" FontFamily="Bahnschrift" FontStretch="Condensed" FontWeight="SemiBold" FontSize="24" Foreground="{StaticResource Text}" HorizontalAlignment="Center"/>
                <TextBlock x:Name="WinTotal" Text="/ 0" FontSize="9" Foreground="{StaticResource Dim}" HorizontalAlignment="Center" Margin="0,-3,0,0"/>
              </StackPanel>
            </Grid>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="Windows" Style="{StaticResource H1}"/>
              <TextBlock Text="Privacidade, anúncios, IA e interface. Não aumenta FPS, deixa o Windows mais limpo." Style="{StaticResource Sub}"/>
            </StackPanel>
          </DockPanel>
          <StackPanel Grid.Row="1" Margin="28,0,28,8">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="BtnWinAllOn" Style="{StaticResource Btn}" Content="Ligar todos" Margin="8,0,0,0"/>
                <Button x:Name="BtnWinAllOff" Style="{StaticResource Btn}" Content="Desligar todos" Margin="8,0,0,0"/>
              </StackPanel>
              <Grid>
                <TextBox x:Name="WinSearch" Style="{StaticResource Input}"/>
                <TextBlock x:Name="WinSearchHint" Text="Buscar ajustes..." Style="{StaticResource Hint}"/>
              </Grid>
            </DockPanel>
            <WrapPanel x:Name="WinChips" Margin="0,10,0,0"/>
          </StackPanel>
          <ScrollViewer x:Name="WinScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="28,0,18,8">
            <WrapPanel x:Name="WinCards"/>
          </ScrollViewer>
        </Grid>

        <!-- Página: Modo Jogo -->
        <Grid x:Name="PageGame" Grid.Column="1" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Margin="28,22,28,14">
            <Button x:Name="BtnGame" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Iniciar Modo Jogo" VerticalAlignment="Center"/>
            <StackPanel>
              <TextBlock Text="Modo Jogo" Style="{StaticResource H1}"/>
              <TextBlock x:Name="GameSub" Text="Marque o que fechar (F) ou pausar (P) enquanto joga. Ao parar, os pausados voltam." Style="{StaticResource Sub}"/>
            </StackPanel>
          </DockPanel>
          <Grid Grid.Row="1" Margin="28,0,28,20">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="2*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Style="{StaticResource Panel}">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
                  <Button x:Name="BtnProcRefresh" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Atualizar" Margin="8,0,0,0"/>
                  <Grid>
                    <TextBox x:Name="ProcSearch" Style="{StaticResource Input}"/>
                    <TextBlock x:Name="ProcSearchHint" Text="Buscar processos..." Style="{StaticResource Hint}"/>
                  </Grid>
                </DockPanel>
                <TextBlock x:Name="ProcHeader" DockPanel.Dock="Top" Text="PROCESSOS" Style="{StaticResource Caps}" Margin="2,0,0,6"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="ProcList"/>
                </ScrollViewer>
              </DockPanel>
            </Border>
            <Border Grid.Column="2" Style="{StaticResource Panel}">
              <DockPanel>
                <TextBlock x:Name="KillHeader" DockPanel.Dock="Top" Text="FECHAR" Style="{StaticResource Caps}" Margin="2,0,0,0"/>
                <TextBlock DockPanel.Dock="Top" Text="Encerrados ao iniciar" FontSize="11" Foreground="{StaticResource Dim}" Margin="2,2,0,10"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="KillList"/>
                </ScrollViewer>
              </DockPanel>
            </Border>
            <Border Grid.Column="4" Style="{StaticResource Panel}">
              <DockPanel>
                <TextBlock x:Name="SuspHeader" DockPanel.Dock="Top" Text="PAUSAR" Style="{StaticResource Caps}" Margin="2,0,0,0"/>
                <TextBlock DockPanel.Dock="Top" Text="Congelados ao iniciar, voltam ao parar" FontSize="11" Foreground="{StaticResource Dim}" Margin="2,2,0,10"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="SuspList"/>
                </ScrollViewer>
              </DockPanel>
            </Border>
          </Grid>
        </Grid>

        <!-- Página: Benchmark -->
        <Grid x:Name="PageBench" Grid.Column="1" Visibility="Collapsed">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="240"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Background="#121417" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
            <DockPanel Margin="14,22,10,14">
              <TextBlock DockPanel.Dock="Top" Text="CAPTURAS" Style="{StaticResource Caps}" Margin="2,0,0,10"/>
              <TextBlock x:Name="CapEmpty" DockPanel.Dock="Top" Text="Nenhuma captura ainda." FontSize="12" Foreground="{StaticResource Dim}" Margin="2,0,0,0"/>
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="CapList"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
          <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" Padding="24,22,20,20">
            <StackPanel>
              <TextBlock Text="Benchmark" Style="{StaticResource H1}"/>
              <TextBlock Text="Grava o FPS real do jogo com o PresentMon. Capture antes e depois de um ajuste para ver se ele ajudou." Style="{StaticResource Sub}" TextWrapping="Wrap"/>
              <Border Style="{StaticResource Panel}" Margin="0,16,0,0" Padding="16">
                <Grid>
                  <StackPanel x:Name="CapSetup">
                    <DockPanel>
                      <Button x:Name="BtnGamesRefresh" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Atualizar" Height="28" Padding="12,0"/>
                      <TextBlock Text="JOGO" Style="{StaticResource Caps}" VerticalAlignment="Center"/>
                    </DockPanel>
                    <WrapPanel x:Name="GameChips" Margin="0,8,0,0"/>
                    <TextBlock x:Name="GameChipsEmpty" Text="Abra o jogo e clique em Atualizar." FontSize="12" Foreground="{StaticResource Dim}" Margin="2,4,0,0"/>
                    <TextBlock Text="DURAÇÃO" Style="{StaticResource Caps}" Margin="0,12,0,8"/>
                    <WrapPanel x:Name="DurChips"/>
                    <TextBlock Text="NOME DA CAPTURA" Style="{StaticResource Caps}" Margin="0,12,0,8"/>
                    <DockPanel>
                      <Button x:Name="BtnCapture" DockPanel.Dock="Right" Style="{StaticResource BtnPrimary}" Content="Gravar" Margin="10,0,0,0"/>
                      <Grid>
                        <TextBox x:Name="CapName" Style="{StaticResource Input}"/>
                        <TextBlock x:Name="CapNameHint" Text="ex.: CS2 antes dos ajustes" Style="{StaticResource Hint}"/>
                      </Grid>
                    </DockPanel>
                    <TextBlock Text="Depois de clicar em Gravar, volte para o jogo e jogue normalmente até o tempo acabar." FontSize="11" Foreground="{StaticResource Dim}" Margin="2,10,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                  <StackPanel x:Name="CapRunning" Visibility="Collapsed" HorizontalAlignment="Center">
                    <TextBlock x:Name="CapRunTitle" Text="GRAVANDO" Style="{StaticResource Caps}" HorizontalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                      <TextBlock x:Name="CapLeft" Text="60" FontFamily="Bahnschrift" FontStretch="Condensed" FontWeight="SemiBold" FontSize="80" Foreground="{StaticResource Text}"/>
                      <TextBlock Text="s" FontFamily="Bahnschrift" FontStretch="Condensed" FontSize="30" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="4,0,0,18"/>
                    </StackPanel>
                    <Grid Width="320" Height="3">
                      <Border Background="{StaticResource Line}"/>
                      <Border x:Name="CapProg" Background="{StaticResource Accent}" HorizontalAlignment="Left" Width="0"/>
                    </Grid>
                    <Button x:Name="BtnCapCancel" Style="{StaticResource Btn}" Content="Cancelar" Margin="0,18,0,0" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Grid>
              </Border>
              <DockPanel Margin="2,22,0,10">
                <StackPanel x:Name="Legend" DockPanel.Dock="Right" Orientation="Horizontal"/>
                <TextBlock Text="COMPARAÇÃO (FPS)" Style="{StaticResource Caps}" VerticalAlignment="Center"/>
              </DockPanel>
              <StackPanel x:Name="Chart"/>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <!-- Página: Análise -->
        <Grid x:Name="PageDiag" Grid.Column="1" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Margin="28,22,28,14">
            <Button x:Name="BtnScan" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Analisar de novo" VerticalAlignment="Center"/>
            <StackPanel>
              <TextBlock Text="Análise do PC" Style="{StaticResource H1}"/>
              <TextBlock Text="O que mais pesa no FPS além dos ajustes do Windows." Style="{StaticResource Sub}"/>
            </StackPanel>
          </DockPanel>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="28,0,22,16">
            <StackPanel>
              <TextBlock Text="SEU PC" Style="{StaticResource Caps}" Margin="0,4,0,8"/>
              <Border Style="{StaticResource Row}" Padding="16,10">
                <StackPanel x:Name="SysPanel"/>
              </Border>
              <TextBlock Text="RESULTADO" Style="{StaticResource Caps}" Margin="0,16,0,8"/>
              <StackPanel x:Name="Findings"/>
            </StackPanel>
          </ScrollViewer>
        </Grid>

        <!-- Página: Ferramentas -->
        <Grid x:Name="PageTools" Grid.Column="1" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Margin="28,22,28,14">
            <TextBlock Text="Ferramentas" Style="{StaticResource H1}"/>
            <TextBlock Text="Ações rápidas e atalhos para configurações do Windows." Style="{StaticResource Sub}"/>
          </StackPanel>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="28,0,22,16">
            <StackPanel x:Name="Tools"/>
          </ScrollViewer>
        </Grid>

        <!-- Página: Atividade -->
        <Grid x:Name="PageLog" Grid.Column="1" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <DockPanel Margin="28,22,28,14">
            <Button x:Name="BtnBackup" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Abrir pasta de backup" VerticalAlignment="Center"/>
            <StackPanel>
              <TextBlock Text="Atividade" Style="{StaticResource H1}"/>
              <TextBlock Text="Tudo o que foi feito nesta sessão." Style="{StaticResource Sub}"/>
            </StackPanel>
          </DockPanel>
          <Border Grid.Row="1" Background="{StaticResource Surface}" CornerRadius="6" Margin="28,0,28,20" Padding="14,10,6,10">
            <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="LogPanel"/>
            </ScrollViewer>
          </Border>
        </Grid>

        <!-- Barra de aplicar (Otimizar e Windows) -->
        <Border x:Name="ActionBar" Grid.Column="1" VerticalAlignment="Bottom" Height="64" Visibility="Collapsed"
                Background="#121417" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="28,12">
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="BtnUndoAll" Style="{StaticResource BtnDanger}" Content="Reverter tudo" Margin="0,0,8,0"/>
              <Button x:Name="BtnDiscard" Style="{StaticResource Btn}" Content="Descartar" Margin="0,0,8,0"/>
              <Button x:Name="BtnApply" Style="{StaticResource BtnPrimary}" Content="Aplicar alterações"/>
            </StackPanel>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="SelInfo" Text="Nenhuma alteração pendente" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Text}"/>
              <TextBlock Text="Backup e ponto de restauração são criados antes de aplicar." FontSize="11" Foreground="{StaticResource Dim}" Margin="0,2,0,0"/>
            </StackPanel>
          </DockPanel>
        </Border>
      </Grid>

      <!-- Barra de status -->
      <Border Grid.Row="2" Background="{StaticResource Rail}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
        <DockPanel Margin="14,0">
          <TextBlock x:Name="StatusRight" DockPanel.Dock="Right" FontSize="11" Foreground="{StaticResource Dim}" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="StatusDot" Width="6" Height="6" Fill="#3BD671" Margin="0,0,8,0"/>
            <TextBlock x:Name="StatusText" FontSize="11" Foreground="{StaticResource Muted}" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
# Ícone: ao lado do script quando aberto pelo .exe, em assets\ quando aberto pelo .bat
foreach ($ico in (Join-Path $PSScriptRoot 'BlkBoost.ico'), (Join-Path $PSScriptRoot 'assets\BlkBoost.ico')) {
    if (Test-Path $ico) { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$ico); break }
}
$ui = @{}
foreach ($n in 'Root', 'BtnMin', 'BtnMax', 'BtnClose', 'NavHome', 'PageHome', 'SysCards', 'NavOpt', 'NavDiag', 'NavTools', 'NavLog', 'WarnBadge', 'WarnCount',
               'PageOpt', 'PageDiag', 'PageTools', 'PageLog', 'ActiveCount', 'ActiveTotal', 'Meter', 'BtnRec', 'Sections',
               'BtnUndoAll', 'BtnDiscard', 'BtnApply', 'SelInfo', 'BtnScan', 'SysPanel', 'Findings', 'Tools',
               'BtnBackup', 'LogScroll', 'LogPanel', 'StatusRight', 'StatusDot', 'StatusText', 'ActionBar',
               'NavWin', 'PageWin', 'WinArc', 'WinCount', 'WinTotal', 'BtnWinAllOn', 'BtnWinAllOff', 'WinSearch', 'WinSearchHint',
               'WinChips', 'WinScroll', 'WinCards',
               'NavGame', 'PageGame', 'BtnGame', 'GameSub', 'BtnProcRefresh', 'ProcSearch', 'ProcSearchHint', 'ProcHeader',
               'ProcList', 'KillHeader', 'KillList', 'SuspHeader', 'SuspList',
               'NavBench', 'PageBench', 'CapEmpty', 'CapList', 'CapSetup', 'BtnGamesRefresh', 'GameChips', 'GameChipsEmpty',
               'DurChips', 'BtnCapture', 'CapName', 'CapNameHint', 'CapRunning', 'CapRunTitle', 'CapLeft', 'CapProg',
               'BtnCapCancel', 'Legend', 'Chart') {
    $ui[$n] = $window.FindName($n)
}

$bc = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$hex) { return $bc.ConvertFromString($hex) }
$Color       = @{ ok = '#3BD671'; warn = '#E6B450'; err = '#E5534B'; info = '#8A8F98'; accent = '#F2542D' }
$ImpactColor = @{ real = '#3BD671'; situacional = '#E6B450'; placebo = '#7D828C' }
$ImpactLabel = @{ real = 'COMPROVADO'; situacional = 'SITUACIONAL'; placebo = 'PLACEBO' }
$FlagLabel   = @{ reiniciar = 'REINICIAR'; relogar = 'RELOGAR'; seguranca = 'REDUZ SEGURANÇA'; explorer = 'REABRE EXPLORER' }
$Inv         = [Globalization.CultureInfo]::InvariantCulture

# ---------------- Log ----------------
function Update-Ui { $window.Dispatcher.Invoke([action] {}, [Windows.Threading.DispatcherPriority]::Background) }

function Write-Log([string]$msg, [string]$kind = 'info') {
    $tag = switch ($kind) { 'ok' { 'OK   ' } 'err' { 'ERRO ' } 'warn' { 'AVISO' } default { '·    ' } }
    $tb = New-Object Windows.Controls.TextBlock
    $tb.FontFamily = 'Cascadia Mono, Consolas'
    $tb.FontSize = 12
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = '0,2,0,2'
    $time = New-Object Windows.Documents.Run ((Get-Date -Format 'HH:mm:ss') + '  ')
    $time.Foreground = Get-Brush '#5C616B'
    $t = New-Object Windows.Documents.Run ("$tag  ")
    $t.Foreground = Get-Brush $Color[$kind]
    $t.FontWeight = 'Bold'
    $m = New-Object Windows.Documents.Run $msg
    $m.Foreground = Get-Brush '#C5C8CD'
    $tb.Inlines.Add($time); $tb.Inlines.Add($t); $tb.Inlines.Add($m)
    [void]$ui.LogPanel.Children.Add($tb)
    $ui.LogScroll.ScrollToEnd()
    $ui.StatusDot.Fill = Get-Brush $Color[$kind]
    $ui.StatusText.Text = $msg
    Update-Ui
}

# ---------------- Componentes ----------------
function New-Text([string]$text, [double]$size = 12, [string]$color = '#8A8F98', [string]$weight = 'Normal') {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.FontWeight = $weight
    $tb.Foreground = Get-Brush $color
    return $tb
}

function New-Tag([string]$text, [string]$fg, [string]$bg) {
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = 3
    $b.Padding = '6,1'
    $b.Margin = '8,0,0,0'
    $b.VerticalAlignment = 'Center'
    $b.Background = Get-Brush $bg
    $b.Child = New-Text $text 9.5 $fg 'Bold'
    return $b
}

function New-IconBox([int]$glyph) {
    $box = New-Object Windows.Controls.Border
    $box.Width = 36; $box.Height = 36; $box.CornerRadius = 4
    $box.Background = Get-Brush '#1F2226'
    $box.VerticalAlignment = 'Center'
    $box.Margin = '0,0,14,0'
    $icon = New-Text ([string][char]$glyph) 16 '#8A8F98'
    $icon.FontFamily = 'Segoe MDL2 Assets'
    $icon.HorizontalAlignment = 'Center'; $icon.VerticalAlignment = 'Center'
    $box.Child = $icon
    return $box
}

function New-RowGrid([string[]]$cols) {
    $grid = New-Object Windows.Controls.Grid
    foreach ($w in $cols) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($w)
        $grid.ColumnDefinitions.Add($cd)
    }
    return $grid
}

# ---------------- Linhas de ajuste ----------------
$script:Cards = @{}
$script:CatCount = @{}

function New-Card($t) {
    $card = New-Object Windows.Controls.Border
    $card.Style = $window.FindResource('Row')
    $card.Padding = '16'
    $card.Margin = '0,0,10,10'
    $card.Cursor = 'Hand'

    $sp = New-Object Windows.Controls.StackPanel

    # Topo: ícone à esquerda, toggle à direita
    $top = New-Object Windows.Controls.DockPanel
    $top.Margin = '0,0,0,12'
    $tg = New-Object Windows.Controls.CheckBox
    $tg.Style = $window.FindResource('Toggle')
    $tg.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($tg, 'Right')
    $tg.Add_Checked({ Update-Selection })
    $tg.Add_Unchecked({ Update-Selection })
    $top.Children.Add($tg) | Out-Null
    $iconBox = New-IconBox $t.Glyph
    $iconBox.HorizontalAlignment = 'Left'
    $top.Children.Add($iconBox) | Out-Null
    $sp.Children.Add($top) | Out-Null

    $name = New-Text $t.Name 14 '#ECEDEE' 'SemiBold'
    $name.TextWrapping = 'Wrap'
    $sp.Children.Add($name) | Out-Null

    $tags = New-Object Windows.Controls.WrapPanel
    $tags.Margin = '0,6,0,0'
    $ic = $ImpactColor[$t.Impact]
    $list = @(New-Tag $ImpactLabel[$t.Impact] $ic ($ic -replace '#', '#1F'))
    foreach ($f in $t.Flags) {
        if ($f -eq 'seguranca') { $list += New-Tag $FlagLabel[$f] '#E5534B' '#2A1A1A' }
        else { $list += New-Tag $FlagLabel[$f] '#8A8F98' '#1F2226' }
    }
    $pending = New-Tag '' '#FFFFFF' '#F2542D'
    $pending.Visibility = 'Collapsed'
    $list += $pending
    foreach ($tag in $list) { $tag.Margin = '0,0,6,4'; $tags.Children.Add($tag) | Out-Null }
    $sp.Children.Add($tags) | Out-Null

    $desc = New-Text $t.Desc 12 '#8A8F98'
    $desc.TextWrapping = 'Wrap'
    $desc.Margin = '0,4,0,0'
    $sp.Children.Add($desc) | Out-Null

    $card.Child = $sp
    $card.Tag = $tg
    # Clicar em qualquer lugar do card alterna o toggle
    $card.Add_MouseLeftButtonUp({ param($s, $e)
        if ($e.OriginalSource -isnot [Windows.Controls.CheckBox] -and $s.Tag.IsEnabled) { $s.Tag.IsChecked = -not $s.Tag.IsChecked }
    })

    $script:Cards[$t.Id] = @{ Toggle = $tg; Icon = $iconBox.Child; Pending = $pending; Card = $card }
    return $card
}

$OptTweaks = @($Tweaks | Where-Object { $_.Page -ne 'win' })
$WinList   = @($Tweaks | Where-Object { $_.Page -eq 'win' })

foreach ($cat in ($OptTweaks | ForEach-Object { $_.Cat } | Select-Object -Unique)) {
    $hdr = New-Object Windows.Controls.DockPanel
    $hdr.Margin = '2,14,12,8'
    $cnt = New-Text '' 11 '#5C616B'
    [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
    $hdr.Children.Add($cnt) | Out-Null
    $name = New-Text $cat.ToUpper() 11 '#5C616B' 'SemiBold'
    $hdr.Children.Add($name) | Out-Null
    $ui.Sections.Children.Add($hdr) | Out-Null
    $script:CatCount[$cat] = $cnt

    $ug = New-Object Windows.Controls.Primitives.UniformGrid
    $ug.Columns = 2
    foreach ($t in ($Tweaks | Where-Object { $_.Cat -eq $cat })) { $ug.Children.Add((New-Card $t)) | Out-Null }
    $ui.Sections.Children.Add($ug) | Out-Null
}
$ui.Sections.Children[0].Margin = '2,0,12,8'

# ---------------- Estado ----------------
# Applied = estado real lido do sistema; o toggle = estado desejado. A diferença é o que será aplicado/revertido.
$script:Applied = @{}

function Get-Pending { @($Tweaks | Where-Object { [bool]$script:Cards[$_.Id].Toggle.IsChecked -ne [bool]$script:Applied[$_.Id] }) }

function Update-Selection {
    $on = 0; $off = 0
    foreach ($t in $Tweaks) {
        $c    = $script:Cards[$t.Id]
        $want = [bool]$c.Toggle.IsChecked
        $has  = [bool]$script:Applied[$t.Id]
        if ($c.Icon) { $c.Icon.Foreground = Get-Brush $(if ($has) { $Color.accent } else { '#8A8F98' }) }
        if ($want -ne $has) {
            $c.Pending.Child.Text = if ($want) { 'VAI APLICAR' } else { 'VAI REVERTER' }
            $c.Pending.Visibility = 'Visible'
            $c.Card.BorderBrush = Get-Brush $Color.accent
            if ($want) { $on++ } else { $off++ }
        } else {
            $c.Pending.Visibility = 'Collapsed'
            $c.Card.ClearValue([Windows.Controls.Border]::BorderBrushProperty)
        }
    }
    $parts = @()
    if ($on)  { $parts += "$on para aplicar" }
    if ($off) { $parts += "$off para reverter" }
    $ui.SelInfo.Text = if ($parts) { $parts -join '  ·  ' } else { 'Nenhuma alteração pendente' }
}

# Relê o estado real e alinha os toggles com ele
function Update-State {
    foreach ($t in $Tweaks) { $script:Applied[$t.Id] = Test-Applied $t }
    foreach ($t in $Tweaks) { $script:Cards[$t.Id].Toggle.IsChecked = $script:Applied[$t.Id] }
    foreach ($cat in $script:CatCount.Keys) {
        $all = @($OptTweaks | Where-Object { $_.Cat -eq $cat })
        $act = @($all | Where-Object { $script:Applied[$_.Id] }).Count
        $script:CatCount[$cat].Text = "$act de $($all.Count) ativos"
    }
    $count = @($OptTweaks | Where-Object { $script:Applied[$_.Id] }).Count
    $ui.ActiveCount.Text = "$count"
    $ui.ActiveTotal.Text = "/ $($OptTweaks.Count)"
    $ui.Meter.Width = [math]::Round(150 * $count / [math]::Max(1, $OptTweaks.Count))
    Update-WinSummary
    Update-Selection
}

$script:ToolButtons = @()

function Set-Busy([bool]$busy) {
    foreach ($b in 'BtnApply', 'BtnRec', 'BtnDiscard', 'BtnUndoAll', 'BtnScan', 'BtnWinAllOn', 'BtnWinAllOff',
                   'BtnProcRefresh', 'BtnGamesRefresh') { $ui[$b].IsEnabled = -not $busy }
    # Durante uma gravação o botão Gravar vira "ocupado" por conta própria; o Modo Jogo segue o mesmo
    if (-not $script:Capturing) { $ui.BtnCapture.IsEnabled = -not $busy; $ui.BtnGame.IsEnabled = -not $busy }
    foreach ($b in $script:ToolButtons) { $b.IsEnabled = -not $busy }
    foreach ($c in $script:Cards.Values) { $c.Toggle.IsEnabled = -not $busy }
    $window.Cursor = if ($busy) { [Windows.Input.Cursors]::Wait } else { $null }
}

# ---------------- Análise ----------------
$script:WarnTotal = 0

function Clear-Findings {
    $ui.Findings.Children.Clear()
    $script:WarnTotal = 0
    $ui.WarnBadge.Visibility = 'Collapsed'
}

function Add-Finding([string]$msg, [string]$kind = 'ok') {
    $row = New-Object Windows.Controls.Border
    $row.Style = $window.FindResource('Row')
    $grid = New-RowGrid 'Auto', '*'
    $glyph = if ($kind -eq 'ok') { 0xE73E } else { 0xE7BA }
    $icon = New-Text ([string][char]$glyph) 14 $Color[$kind]
    $icon.FontFamily = 'Segoe MDL2 Assets'
    $icon.VerticalAlignment = 'Center'
    $icon.Margin = '2,0,14,0'
    $grid.Children.Add($icon) | Out-Null
    $tx = New-Text $msg 13 '#ECEDEE'
    $tx.TextWrapping = 'Wrap'
    $tx.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($tx, 1)
    $grid.Children.Add($tx) | Out-Null
    $row.Child = $grid
    if ($kind -eq 'ok') { [void]$ui.Findings.Children.Add($row) }
    else {
        # Avisos primeiro
        $ui.Findings.Children.Insert($script:WarnTotal, $row)
        $script:WarnTotal++
        $ui.WarnCount.Text = "$script:WarnTotal"
        $ui.WarnBadge.Visibility = 'Visible'
    }
    Update-Ui
}

function Start-Scan {
    Set-Busy $true
    try { Invoke-Diagnostics } catch { Write-Log $_.Exception.Message 'err' }
    finally { Set-Busy $false }
}

# ---------------- Ações ----------------
function New-RestorePoint {
    Write-Log 'Criando ponto de restauração (pode levar até 1 minuto)...'
    $job = Start-Job { Checkpoint-Computer -Description 'BLK Boost' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction Stop }
    while ($job.State -eq 'Running') { Update-Ui; Start-Sleep -Milliseconds 100 }
    try { Receive-Job $job -ErrorAction Stop -WarningAction Stop | Out-Null; Write-Log 'Ponto de restauração criado.' 'ok' }
    catch { Write-Log "Ponto de restauração não criado: $($_.Exception.Message)" 'warn' }
    finally { Remove-Job $job -Force }
}

$ui.BtnApply.Add_Click({
    $pend = Get-Pending
    if ($pend.Count -eq 0) { Write-Log 'Nenhuma alteração. Ligue ou desligue os ajustes e clique em Aplicar.' 'warn'; return }
    $toApply = @($pend | Where-Object { $script:Cards[$_.Id].Toggle.IsChecked })
    $toUndo  = @($pend | Where-Object { -not $script:Cards[$_.Id].Toggle.IsChecked })
    Set-Busy $true
    try {
        if ($toApply.Count) { New-RestorePoint }
        $needs = @{}
        foreach ($t in $toApply) {
            try {
                Invoke-Tweak $t | Out-Null
                Write-Log "Aplicado: $($t.Name)" 'ok'
                foreach ($f in $t.Flags) { $needs[$f] = $true }
            } catch { Write-Log "$($t.Name): $($_.Exception.Message)" 'err' }
            Save-Backup
        }
        foreach ($t in $toUndo) {
            if (-not (Test-HasBackup $t.Id)) {
                Write-Log "$($t.Name): já estava ativo antes do BLK Boost, não há valor original para voltar." 'warn'
                continue
            }
            try {
                Undo-Tweaks @($t.Id)
                Write-Log "Revertido: $($t.Name)" 'ok'
                foreach ($f in $t.Flags) { $needs[$f] = $true }
            } catch { Write-Log "$($t.Name): $($_.Exception.Message)" 'err' }
        }
        if ($needs.explorer) { Write-Log 'Reabrindo o Explorer para aplicar mudanças na barra de tarefas...'; Restart-Explorer }
        if ($needs.reiniciar) { Write-Log 'Reinicie o PC para os ajustes marcados com REINICIAR valerem.' 'warn' }
        elseif ($needs.relogar) { Write-Log 'Saia e entre de novo na conta para os ajustes marcados com RELOGAR valerem.' 'warn' }
        else { Write-Log 'Alterações aplicadas.' 'ok' }
    } finally { Update-State; Set-Busy $false }
})

$ui.BtnRec.Add_Click({
    foreach ($t in $Tweaks | Where-Object { $_.Rec }) { $script:Cards[$t.Id].Toggle.IsChecked = $true }
    if (-not @(Get-Pending).Count) { Write-Log 'Todos os recomendados já estão ativos.' 'ok' }
    else { Write-Log 'Recomendados ligados. Clique em Aplicar alterações para confirmar.' }
})

$ui.BtnDiscard.Add_Click({ Update-State })

$ui.BtnUndoAll.Add_Click({
    Set-Busy $true
    try {
        $explorer = @($Tweaks | Where-Object { $_.Flags -contains 'explorer' -and (Test-HasBackup $_.Id) }).Count
        Undo-Tweaks @($Tweaks | ForEach-Object { $_.Id })
        if ($explorer) { Restart-Explorer }
        Write-Log 'Tudo revertido para os valores originais.' 'ok'
    } catch { Write-Log $_.Exception.Message 'err' }
    finally { Update-State; Set-Busy $false }
})

$ui.BtnScan.Add_Click({ Start-Scan })

# ---------------- Ferramentas ----------------
function Add-Tool([string]$Text, [string]$Desc, [int]$Glyph, [string]$BtnText, [scriptblock]$Action) {
    $row = New-Object Windows.Controls.Border
    $row.Style = $window.FindResource('Row')
    $grid = New-RowGrid 'Auto', '*', 'Auto'
    $grid.Children.Add((New-IconBox $Glyph)) | Out-Null

    $sp = New-Object Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    $sp.Children.Add((New-Text $Text 14 '#ECEDEE' 'SemiBold')) | Out-Null
    $d = New-Text $Desc 12 '#8A8F98'
    $d.TextWrapping = 'Wrap'
    $d.Margin = '0,3,0,0'
    $sp.Children.Add($d) | Out-Null
    $grid.Children.Add($sp) | Out-Null

    $b = New-Object Windows.Controls.Button
    $b.Style = $window.FindResource('Btn')
    $b.Content = $BtnText
    $b.MinWidth = 96
    $b.Margin = '16,0,0,0'
    $b.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($b, 2)
    $b.Tag = $Action
    $b.Add_Click({ param($s)
        Set-Busy $true
        try { & $s.Tag } catch { Write-Log $_.Exception.Message 'err' }
        finally { Set-Busy $false }
    })
    $grid.Children.Add($b) | Out-Null
    $script:ToolButtons += $b

    $row.Child = $grid
    $ui.Tools.Children.Add($row) | Out-Null
}

Add-Tool 'Limpar arquivos temporários' 'Apaga %TEMP% e C:\Windows\Temp. Libera espaço em disco; não aumenta FPS.' 0xE74D 'Limpar' {
    Write-Log "Temporários: $(Clear-Temp)" 'ok' }
Add-Tool 'GPU por jogo' 'Escolha cada jogo e marque Alto desempenho. Em notebook, garante a placa de vídeo dedicada.' 0xE7F4 'Abrir' {
    Start-Process 'ms-settings:display-advancedgraphics'; Write-Log 'Configurações de gráficos abertas.' }
Add-Tool 'Apps na inicialização' 'Desligue o que não precisa abrir junto com o Windows.' 0xE7E8 'Abrir' {
    Start-Process 'ms-settings:startupapps'; Write-Log 'Apps de inicialização abertos.' }
Add-Tool 'Taxa de atualização do monitor' 'Confira se o monitor está na maior taxa disponível (144 Hz, 240 Hz...).' 0xE7F8 'Abrir' {
    Start-Process 'ms-settings:display-advanced'; Write-Log 'Configurações avançadas de vídeo abertas.' }

Add-Tool 'Reparar contadores de desempenho' 'Reconstrói os contadores do Windows (lodctr /R). Corrige Gerenciador de Tarefas sem dados de CPU e o clock no Painel.' 0xE90F 'Reparar' {
    Repair-PerfCounters }

# ---------------- Painel ----------------
$Cond = [Windows.FontStretches]::Condensed

function New-BigText([string]$text, [double]$size, [string]$color = '#ECEDEE') {
    $tb = New-Text $text $size $color 'SemiBold'
    $tb.FontFamily = 'Bahnschrift'
    $tb.FontStretch = $Cond
    return $tb
}

function New-SysCard([string]$label, [string]$main, [string]$sub, [string]$brand) {
    $card = New-Object Windows.Controls.Border
    $card.Style = $window.FindResource('Row')
    $card.Padding = '16,14'
    $card.Margin = '0,0,10,10'
    $dp = New-Object Windows.Controls.DockPanel
    $b = New-BigText $brand.ToUpper() 30
    $b.VerticalAlignment = 'Center'
    $b.Margin = '12,0,0,0'
    [Windows.Controls.DockPanel]::SetDock($b, 'Right')
    $dp.Children.Add($b) | Out-Null
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Children.Add((New-Text $label.ToUpper() 10 '#5C616B' 'SemiBold')) | Out-Null
    $m = New-Text $main.ToUpper() 13 '#ECEDEE' 'SemiBold'
    $m.Margin = '0,5,0,0'; $m.TextTrimming = 'CharacterEllipsis'; $m.ToolTip = $main
    $sp.Children.Add($m) | Out-Null
    $s = New-Text $sub 11 '#8A8F98'
    $s.Margin = '0,2,0,0'
    $sp.Children.Add($s) | Out-Null
    $dp.Children.Add($sp) | Out-Null
    $card.Child = $dp
    $ui.SysCards.Children.Add($card) | Out-Null
}

$hw = Get-HwInfo
New-SysCard 'CPU' $hw.CpuName "$($hw.Cores) núcleos · $($hw.Threads) threads" $hw.CpuBrand
New-SysCard 'GPU' $hw.GpuName "Driver $($hw.Driver)" $hw.GpuBrand
New-SysCard 'Memória' "$($hw.MemType) $($hw.MemGb) GB" "$($hw.MemMts) MT/s · $($hw.MemCount) pente(s)" $hw.MemBrand
New-SysCard 'Sistema' $hw.OsName "Build $($hw.Build)" $hw.OsVer

$window.Add_Closed({
    if ($script:GameOn -or $script:GameCfg.Paused.Count) { [void](Resume-Paused) }
})

# ---------------- Página Windows ----------------
$script:WinFilter = 'Todos'
$script:WinChipRefs = @{}

function New-WinCard($t) {
    $card = New-Object Windows.Controls.Border
    $card.Style = $window.FindResource('Row')
    $card.Padding = '14,12'
    $card.Margin = '0,0,10,10'
    $card.Cursor = 'Hand'
    $card.ToolTip = $t.Desc

    $sp = New-Object Windows.Controls.StackPanel
    $top = New-Object Windows.Controls.DockPanel
    $tg = New-Object Windows.Controls.CheckBox
    $tg.Style = $window.FindResource('Toggle')
    $tg.VerticalAlignment = 'Top'
    [Windows.Controls.DockPanel]::SetDock($tg, 'Right')
    $tg.Add_Checked({ Update-Selection })
    $tg.Add_Unchecked({ Update-Selection })
    $top.Children.Add($tg) | Out-Null
    $name = New-Text $t.Name 13 '#ECEDEE' 'SemiBold'
    $name.TextWrapping = 'Wrap'
    $name.Margin = '0,1,10,0'
    $top.Children.Add($name) | Out-Null
    $sp.Children.Add($top) | Out-Null

    $tags = New-Object Windows.Controls.WrapPanel
    $tags.Margin = '0,8,0,0'
    $list = @(New-Tag $t.Cat.ToUpper() '#8A8F98' '#1F2226')
    foreach ($f in $t.Flags) { $list += New-Tag $FlagLabel[$f] '#8A8F98' '#1F2226' }
    $pending = New-Tag '' '#FFFFFF' '#F2542D'
    $pending.Visibility = 'Collapsed'
    $list += $pending
    foreach ($tag in $list) { $tag.Margin = '0,0,6,0'; $tags.Children.Add($tag) | Out-Null }
    $sp.Children.Add($tags) | Out-Null

    $card.Child = $sp
    $card.Tag = $tg
    $card.Add_MouseLeftButtonUp({ param($s, $e)
        if ($e.OriginalSource -isnot [Windows.Controls.CheckBox] -and $s.Tag.IsEnabled) { $s.Tag.IsChecked = -not $s.Tag.IsChecked }
    })
    $script:Cards[$t.Id] = @{ Toggle = $tg; Icon = $null; Pending = $pending; Card = $card }
    $ui.WinCards.Children.Add($card) | Out-Null
}

function Update-WinFilter {
    $q = $ui.WinSearch.Text.Trim()
    foreach ($t in $WinList) {
        $show = ($script:WinFilter -eq 'Todos' -or $t.Cat -eq $script:WinFilter) -and
                (-not $q -or $t.Name -like "*$q*" -or $t.Desc -like "*$q*" -or $t.Cat -like "*$q*")
        $script:Cards[$t.Id].Card.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    }
    $ui.WinSearchHint.Visibility = if ($ui.WinSearch.Text) { 'Collapsed' } else { 'Visible' }
}

# Arco do anel de progresso (0 a 1), desenhado a partir do topo no sentido horário
function Set-Arc($path, [double]$frac, [double]$size = 68, [double]$stroke = 4) {
    if ($frac -le 0) { $path.Data = $null; return }
    $frac = [math]::Min($frac, 0.9999)
    $r = ($size - $stroke) / 2; $c = $size / 2
    $a = 2 * [math]::PI * $frac
    $geo = [string]::Format($Inv, 'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}', $c, ($c - $r), $r,
        $(if ($frac -gt 0.5) { 1 } else { 0 }), ($c + $r * [math]::Sin($a)), ($c - $r * [math]::Cos($a)))
    $path.Data = [Windows.Media.Geometry]::Parse($geo)
}

function Update-WinSummary {
    $act = @($WinList | Where-Object { $script:Applied[$_.Id] }).Count
    $ui.WinCount.Text = "$act"
    $ui.WinTotal.Text = "/ $($WinList.Count)"
    Set-Arc $ui.WinArc ($act / [math]::Max(1, $WinList.Count))
    foreach ($g in $script:WinChipRefs.Keys) {
        $items = if ($g -eq 'Todos') { $WinList } else { @($WinList | Where-Object { $_.Cat -eq $g }) }
        $on = @($items | Where-Object { $script:Applied[$_.Id] }).Count
        $script:WinChipRefs[$g].Content = "$g   $on/$(@($items).Count)"
    }
}

foreach ($g in @('Todos') + @($WinList | ForEach-Object { $_.Cat } | Select-Object -Unique)) {
    $chip = New-Object Windows.Controls.RadioButton
    $chip.Style = $window.FindResource('Chip')
    $chip.GroupName = 'WinFilter'
    $chip.Tag = $g
    $chip.IsChecked = ($g -eq 'Todos')
    $chip.Add_Checked({ param($s) $script:WinFilter = $s.Tag; Update-WinFilter })
    $ui.WinChips.Children.Add($chip) | Out-Null
    $script:WinChipRefs[$g] = $chip
}
foreach ($t in $WinList) { New-WinCard $t }

# Grade de 3 colunas que acompanha a largura da janela
$ui.WinScroll.Add_SizeChanged({
    # 46 = padding do ScrollViewer, 24 = barra de rolagem e folga de arredondamento
    $w = [math]::Floor(($ui.WinScroll.ActualWidth - 46 - 24) / 3)
    foreach ($c in $ui.WinCards.Children) { $c.Width = [math]::Max(180, $w - 10) }
})
$ui.WinSearch.Add_TextChanged({ Update-WinFilter })
$ui.BtnWinAllOn.Add_Click({
    foreach ($t in $WinList) { $c = $script:Cards[$t.Id]; if ($c.Card.Visibility -eq 'Visible') { $c.Toggle.IsChecked = $true } }
})
$ui.BtnWinAllOff.Add_Click({
    foreach ($t in $WinList) { $c = $script:Cards[$t.Id]; if ($c.Card.Visibility -eq 'Visible') { $c.Toggle.IsChecked = $false } }
})

# ---------------- Modo Jogo ----------------
$GameFile = Join-Path $BackupDir 'modojogo.json'
# Processos do sistema/shell que nunca aparecem na lista
$Protected = 'System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost', 'dwm',
             'explorer', 'fontdrvhost', 'sihost', 'ctfmon', 'conhost', 'powershell', 'pwsh', 'RuntimeBroker', 'dllhost',
             'StartMenuExperienceHost', 'ShellExperienceHost', 'SearchHost', 'TextInputHost', 'taskhostw', 'audiodg',
             'SecurityHealthSystray', 'smartscreen', 'LockApp', 'ApplicationFrameHost', 'MsMpEng', 'NisSrv', 'PresentMon',
             'Widgets', 'WidgetService', 'UserOOBEBroker', 'ShellHost', 'ProcessLasso', 'ProcessGovernor', 'bitsumsessionagent'

function Import-GameCfg {
    $cfg = @{ Kill = @(); Suspend = @(); Paused = @() }
    if (Test-Path $GameFile) {
        try {
            $raw = Get-Content $GameFile -Raw | ConvertFrom-Json
            $cfg.Kill = @($raw.Kill | Where-Object { $_ }); $cfg.Suspend = @($raw.Suspend | Where-Object { $_ })
            $cfg.Paused = @($raw.Paused | Where-Object { $_ })
        } catch { }
    }
    return $cfg
}
function Save-GameCfg { $script:GameCfg | ConvertTo-Json | Set-Content $GameFile -Encoding UTF8 }
$script:GameCfg = Import-GameCfg
$script:GameOn = $false
$MySession = [Diagnostics.Process]::GetCurrentProcess().SessionId

function Get-ProcGroups {
    Get-Process | Where-Object { $_.SessionId -eq $MySession -and $_.Id -ne $PID -and $Protected -notcontains $_.ProcessName } |
        Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Count = $_.Count; MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) }
        } | Sort-Object MB -Descending
}

function New-MiniBtn([string]$text, [bool]$on, [string]$onColor, [string]$list, [string]$name, [string]$tip) {
    $b = New-Object Windows.Controls.Border
    $b.Width = 22; $b.Height = 20; $b.CornerRadius = 3
    $b.Margin = '0,0,4,0'
    $b.Cursor = 'Hand'
    $b.ToolTip = $tip
    $b.Background = Get-Brush $(if ($on) { $onColor } else { '#1F2226' })
    $t = New-Text $text 10 $(if ($on) { '#0E0F11' } else { '#8A8F98' }) 'Bold'
    $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Child = $t
    $b.Tag = @{ List = $list; Name = $name }
    $b.Add_MouseLeftButtonUp({ param($s) Switch-GameList $s.Tag.List $s.Tag.Name })
    return $b
}

function Update-ProcList {
    $script:ProcGroups = @(Get-ProcGroups)
    Show-ProcList
}

function Show-ProcList {
    $ui.ProcList.Children.Clear()
    $q = $ui.ProcSearch.Text.Trim()
    $ui.ProcSearchHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }
    $ui.ProcHeader.Text = "PROCESSOS ($($script:ProcGroups.Count))"
    foreach ($g in $script:ProcGroups | Where-Object { -not $q -or $_.Name -like "*$q*" }) {
        $row = New-Object Windows.Controls.Border
        $row.Padding = '6,4'
        $row.CornerRadius = 4
        $row.Background = Get-Brush '#00000000'
        $row.Add_MouseEnter({ param($s) $s.Background = Get-Brush '#1C1F23' })
        $row.Add_MouseLeave({ param($s) $s.Background = Get-Brush '#00000000' })
        $dp = New-Object Windows.Controls.DockPanel
        $mb = New-Text "$($g.MB) MB" 11 '#5C616B'
        $mb.VerticalAlignment = 'Center'
        [Windows.Controls.DockPanel]::SetDock($mb, 'Right')
        $dp.Children.Add($mb) | Out-Null
        $k = New-MiniBtn 'F' ($script:GameCfg.Kill -contains $g.Name) $Color.err 'Kill' $g.Name 'Fechar ao iniciar o Modo Jogo'
        $p = New-MiniBtn 'P' ($script:GameCfg.Suspend -contains $g.Name) $Color.warn 'Suspend' $g.Name 'Pausar enquanto o Modo Jogo estiver ativo'
        [Windows.Controls.DockPanel]::SetDock($k, 'Left'); [Windows.Controls.DockPanel]::SetDock($p, 'Left')
        $dp.Children.Add($k) | Out-Null; $dp.Children.Add($p) | Out-Null
        $nm = New-Object Windows.Controls.TextBlock
        $nm.VerticalAlignment = 'Center'
        $nm.Margin = '6,0,8,0'
        $nm.TextTrimming = 'CharacterEllipsis'
        $r1 = New-Object Windows.Documents.Run "$($g.Name).exe"
        $r1.Foreground = Get-Brush '#ECEDEE'; $r1.FontWeight = 'SemiBold'
        $r2 = New-Object Windows.Documents.Run $(if ($g.Count -gt 1) { "  ($($g.Count))" } else { '' })
        $r2.Foreground = Get-Brush '#5C616B'
        $nm.Inlines.Add($r1); $nm.Inlines.Add($r2)
        $nm.FontSize = 12
        $dp.Children.Add($nm) | Out-Null
        $row.Child = $dp
        $ui.ProcList.Children.Add($row) | Out-Null
    }
    Show-GameLists
}

function Show-GameLists {
    foreach ($pair in @(@('Kill', $ui.KillList, $ui.KillHeader, 'FECHAR'), @('Suspend', $ui.SuspList, $ui.SuspHeader, 'PAUSAR'))) {
        $items = @($script:GameCfg[$pair[0]])
        $pair[1].Children.Clear()
        $pair[2].Text = "$($pair[3]) ($($items.Count))"
        foreach ($n in $items) {
            $dp = New-Object Windows.Controls.DockPanel
            $dp.Margin = '2,3,0,3'
            $x = New-Text ([string][char]0xE711) 10 '#5C616B'
            $x.FontFamily = 'Segoe MDL2 Assets'
            $x.Cursor = 'Hand'
            $x.ToolTip = 'Remover'
            $x.VerticalAlignment = 'Center'
            $x.Tag = @{ List = $pair[0]; Name = $n }
            $x.Add_MouseLeftButtonUp({ param($s) Switch-GameList $s.Tag.List $s.Tag.Name })
            [Windows.Controls.DockPanel]::SetDock($x, 'Right')
            $dp.Children.Add($x) | Out-Null
            $t = New-Text "$n.exe" 12 '#ECEDEE'
            $t.FontFamily = 'Cascadia Mono, Consolas'
            $t.TextTrimming = 'CharacterEllipsis'
            $dp.Children.Add($t) | Out-Null
            $pair[1].Children.Add($dp) | Out-Null
        }
    }
}

# Marca/desmarca um processo numa lista; um processo não pode estar nas duas
function Switch-GameList([string]$list, [string]$name) {
    $other = if ($list -eq 'Kill') { 'Suspend' } else { 'Kill' }
    if ($script:GameCfg[$list] -contains $name) {
        $script:GameCfg[$list] = @($script:GameCfg[$list] | Where-Object { $_ -ne $name })
    } else {
        $script:GameCfg[$list] = @($script:GameCfg[$list]) + $name
        $script:GameCfg[$other] = @($script:GameCfg[$other] | Where-Object { $_ -ne $name })
    }
    Save-GameCfg
    Show-ProcList
}

function Resume-Paused {
    $n = 0
    foreach ($id in $script:GameCfg.Paused) { if ([Native.Proc]::Resume([int]$id)) { $n++ } }
    $script:GameCfg.Paused = @()
    Save-GameCfg
    return $n
}

function Start-GameMode {
    if (-not ($script:GameCfg.Kill.Count + $script:GameCfg.Suspend.Count)) {
        Write-Log 'Marque ao menos um processo com F (fechar) ou P (pausar).' 'warn'; return
    }
    $killed = 0
    foreach ($n in $script:GameCfg.Kill) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $MySession })) {
            try { $p.Kill(); $killed++ } catch { }
        }
    }
    $paused = @()
    foreach ($n in $script:GameCfg.Suspend) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $MySession })) {
            if ([Native.Proc]::Suspend($p.Id)) { $paused += $p.Id }
        }
    }
    # Os PIDs ficam salvos: se o BLK Boost fechar de forma inesperada, eles são retomados ao abrir de novo
    $script:GameCfg.Paused = $paused
    Save-GameCfg
    $script:GameOn = $true
    $ui.BtnGame.Content = 'Parar Modo Jogo'
    $ui.GameSub.Text = "Ativo: $killed processo(s) fechado(s), $($paused.Count) pausado(s). Pare antes de usar os apps pausados."
    $ui.GameSub.Foreground = Get-Brush $Color.ok
    Write-Log "Modo Jogo ligado: $killed fechado(s), $($paused.Count) pausado(s)." 'ok'
    Update-ProcList
}

function Stop-GameMode {
    $n = Resume-Paused
    $script:GameOn = $false
    $ui.BtnGame.Content = 'Iniciar Modo Jogo'
    $ui.GameSub.Text = 'Marque o que fechar (F) ou pausar (P) enquanto joga. Ao parar, os pausados voltam.'
    $ui.GameSub.Foreground = $window.FindResource('Muted')
    Write-Log "Modo Jogo desligado: $n processo(s) retomado(s)." 'ok'
}

$ui.BtnGame.Add_Click({ if ($script:GameOn) { Stop-GameMode } else { Start-GameMode } })
$ui.BtnProcRefresh.Add_Click({ Update-ProcList })
$ui.ProcSearch.Add_TextChanged({ Show-ProcList })

# ---------------- Benchmark (PresentMon) ----------------
$PmExe  = Join-Path $BackupDir 'PresentMon.exe'
$CapDir = Join-Path $BackupDir 'capturas'
New-Item -ItemType Directory -Path $CapDir -Force | Out-Null
# Paleta categórica validada (contraste e daltonismo) sobre o fundo dos cards
$Series = @(
    @{ Key = 'Avg'; Name = 'Média';    Color = '#3987e5' }
    @{ Key = 'P1';  Name = '1% low';   Color = '#d95926' }
    @{ Key = 'P01'; Name = '0,1% low'; Color = '#199e70' }
)
$NotGames = 'explorer', 'ApplicationFrameHost', 'SystemSettings', 'TextInputHost', 'powershell', 'pwsh', 'WindowsTerminal',
            'Code', 'chrome', 'msedge', 'firefox', 'opera', 'brave', 'Discord', 'steamwebhelper', 'steam', 'EpicGamesLauncher',
            'Spotify', 'Taskmgr', 'SearchHost', 'StartMenuExperienceHost', 'ShellExperienceHost', 'LockApp', 'WhatsApp',
            'Telegram', 'obs64', 'Notepad', 'notepad', 'mspaint', 'Photos', 'CalculatorApp', 'NVIDIA app', 'NVIDIA Overlay'
$script:CapGame = $null
$script:CapSecs = 60
$script:Capturing = $false

function Get-PresentMon {
    if (Test-Path $PmExe) { return $true }
    Write-Log 'Baixando o PresentMon (Intel, ~1 MB)...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod 'https://api.github.com/repos/GameTechDev/PresentMon/releases/latest' -Headers @{ 'User-Agent' = 'BlkBoost' }
        $a = $r.assets | Where-Object { $_.name -match '^PresentMon-[\d.]+-x64\.exe$' } | Select-Object -First 1
        if (-not $a) { throw 'arquivo do PresentMon não encontrado no release.' }
        $tmp = "$PmExe.download"
        Invoke-WebRequest $a.browser_download_url -OutFile $tmp -UseBasicParsing
        # Só aceita o executável assinado pela Intel
        $sig = Get-AuthenticodeSignature $tmp
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Intel Corporation') {
            Remove-Item $tmp -Force
            throw 'a assinatura digital do arquivo não é da Intel.'
        }
        Move-Item $tmp $PmExe -Force
        Write-Log "PresentMon $($r.tag_name) baixado e verificado (assinado pela Intel)." 'ok'
        return $true
    } catch {
        Write-Log "Não foi possível baixar o PresentMon: $($_.Exception.Message)" 'err'
        return $false
    }
}

function Update-GameChips {
    $ui.GameChips.Children.Clear()
    $names = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.Id -ne $PID -and $NotGames -notcontains $_.ProcessName } |
               Sort-Object WorkingSet64 -Descending | ForEach-Object { $_.ProcessName } | Select-Object -Unique -First 12)
    foreach ($n in $names) {
        $chip = New-Object Windows.Controls.RadioButton
        $chip.Style = $window.FindResource('Chip')
        $chip.GroupName = 'CapGame'
        $chip.Content = "$n.exe"
        $chip.Tag = $n
        $chip.Add_Checked({ param($s) $script:CapGame = $s.Tag })
        $ui.GameChips.Children.Add($chip) | Out-Null
    }
    if ($names -contains $script:CapGame) {
        ($ui.GameChips.Children | Where-Object { $_.Tag -eq $script:CapGame }).IsChecked = $true
    } else { $script:CapGame = $null }
    $ui.GameChipsEmpty.Visibility = if ($names.Count) { 'Collapsed' } else { 'Visible' }
}

# FPS médio e lows a partir dos tempos de frame (ms) gravados pelo PresentMon
function Measure-Capture([string]$csv) {
    if (-not (Test-Path $csv)) { return $null }
    $rows = @(Import-Csv $csv)
    if (-not $rows.Count) { return $null }
    $cols = $rows[0].PSObject.Properties.Name
    $col = @('MsBetweenPresents', 'FrameTime', 'MsBetweenDisplayChange') | Where-Object { $cols -contains $_ } | Select-Object -First 1
    if (-not $col) { return $null }
    $ft = New-Object 'System.Collections.Generic.List[double]'
    foreach ($r in $rows) {
        $v = 0.0
        if ([double]::TryParse($r.$col, [Globalization.NumberStyles]::Float, $Inv, [ref]$v) -and $v -gt 0) { $ft.Add($v) }
    }
    if ($ft.Count -lt 30) { return $null }
    $arr = $ft.ToArray()
    $sum = 0.0; foreach ($v in $arr) { $sum += $v }
    [Array]::Sort($arr)
    $pct = { param($p) $arr[[math]::Min($arr.Length - 1, [int][math]::Floor($p * ($arr.Length - 1)))] }
    $median = & $pct 0.5
    return @{
        Avg = [math]::Round(1000 / ($sum / $arr.Length), 1)
        P1  = [math]::Round(1000 / (& $pct 0.99), 1)
        P01 = [math]::Round(1000 / (& $pct 0.999), 1)
        Stutters = @($arr | Where-Object { $_ -gt 2.5 * $median }).Count
        Frames = $arr.Length
    }
}

function Start-Capture {
    if (-not $script:CapGame) { Write-Log 'Abra o jogo, clique em Atualizar e escolha ele na lista.' 'warn'; return }
    if (-not (Get-PresentMon)) { return }
    $game  = $script:CapGame
    $secs  = $script:CapSecs
    $label = if ($ui.CapName.Text.Trim()) { $ui.CapName.Text.Trim() } else { $game }
    $stamp = Get-Date
    $csv   = Join-Path $CapDir ('{0:yyyyMMdd-HHmmss}.csv' -f $stamp)
    $pmArgs = "--process_name `"$game.exe`" --output_file `"$csv`" --timed $secs --terminate_after_timed " +
              '--stop_existing_session --no_console_stats --v1_metrics --session_name BlkBoost'

    $script:Capturing = $true
    $script:CapCancel = $false
    Set-Busy $true
    $ui.BtnCapture.IsEnabled = $false
    $ui.CapSetup.Visibility = 'Collapsed'
    $ui.CapRunning.Visibility = 'Visible'
    $ui.CapRunTitle.Text = "GRAVANDO $($game.ToUpper()).EXE"
    Write-Log "Gravando $game.exe por $secs s. Volte para o jogo."
    $cancelled = $false
    try {
        $p = Start-Process $PmExe -ArgumentList $pmArgs -PassThru -WindowStyle Hidden
        $t0 = Get-Date
        while (-not $p.HasExited) {
            $el = ((Get-Date) - $t0).TotalSeconds
            $ui.CapLeft.Text = [math]::Max(0, [math]::Ceiling($secs - $el))
            $ui.CapProg.Width = 320 * [math]::Min(1, $el / $secs)
            if ($script:CapCancel -or $el -gt $secs + 20) { try { $p.Kill() } catch { }; $cancelled = $script:CapCancel; break }
            Update-Ui
            Start-Sleep -Milliseconds 100
        }
    } finally {
        $script:Capturing = $false
        $ui.CapRunning.Visibility = 'Collapsed'
        $ui.CapSetup.Visibility = 'Visible'
        Set-Busy $false
    }

    if ($cancelled) { Remove-Item $csv -Force -ErrorAction SilentlyContinue; Write-Log 'Captura cancelada.' 'warn'; return }
    Write-Log 'Calculando resultados...'
    $res = Measure-Capture $csv
    Remove-Item $csv -Force -ErrorAction SilentlyContinue
    if (-not $res) {
        Write-Log "Nenhum frame de $game.exe foi gravado (código $($p.ExitCode)). O jogo precisa estar aberto e renderizando, não minimizado." 'err'
        return
    }
    [pscustomobject]@{ Name = $label; Game = $game; Date = $stamp.ToString('o'); Secs = $secs
                       Avg = $res.Avg; P1 = $res.P1; P01 = $res.P01; Stutters = $res.Stutters; Frames = $res.Frames } |
        ConvertTo-Json | Set-Content (Join-Path $CapDir ('{0:yyyyMMdd-HHmmss}.json' -f $stamp)) -Encoding UTF8
    $ui.CapName.Text = ''
    Write-Log ([string]::Format('Captura "{0}": média {1:0.0} FPS, 1% low {2:0.0}, 0,1% low {3:0.0}, {4} travadas.',
        $label, $res.Avg, $res.P1, $res.P01, $res.Stutters)) 'ok'
    Update-Captures
}

function New-Bar([double]$value, [double]$max, [string]$color, [string]$tip) {
    $g = New-Object Windows.Controls.Grid
    $g.Margin = '0,0,0,2'
    $g.ToolTip = $tip
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $c1.Width = New-Object Windows.GridLength ([math]::Max(0.001, $value)), 'Star'
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c2.Width = New-Object Windows.GridLength ([math]::Max(0.001, $max - $value)), 'Star'
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $bar = New-Object Windows.Controls.Border
    $bar.Height = 12
    $bar.CornerRadius = '0,4,4,0'
    $bar.Background = Get-Brush $color
    $g.Children.Add($bar) | Out-Null
    $lbl = New-Text ('{0:0.0}' -f $value) 11 '#ECEDEE' 'SemiBold'
    $lbl.Margin = '6,0,0,0'
    $lbl.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($lbl, 1)
    $g.Children.Add($lbl) | Out-Null
    return $g
}

function Update-Captures {
    $caps = @(Get-ChildItem $CapDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
        try { $o = Get-Content $_.FullName -Raw | ConvertFrom-Json; $o | Add-Member File $_.FullName -PassThru } catch { }
    })
    $ui.CapList.Children.Clear()
    $ui.Chart.Children.Clear()
    $ui.CapEmpty.Visibility = if ($caps.Count) { 'Collapsed' } else { 'Visible' }

    foreach ($c in $caps) {
        $row = New-Object Windows.Controls.Border
        $row.Style = $window.FindResource('Row')
        $row.Padding = '10,8'
        $dp = New-Object Windows.Controls.DockPanel
        $del = New-Text ([string][char]0xE74D) 12 '#5C616B'
        $del.FontFamily = 'Segoe MDL2 Assets'
        $del.Cursor = 'Hand'
        $del.ToolTip = 'Apagar captura'
        $del.VerticalAlignment = 'Top'
        $del.Tag = $c.File
        $del.Add_MouseLeftButtonUp({ param($s) Remove-Item $s.Tag -Force; Update-Captures })
        [Windows.Controls.DockPanel]::SetDock($del, 'Right')
        $dp.Children.Add($del) | Out-Null
        $sp = New-Object Windows.Controls.StackPanel
        $n = New-Text $c.Name 12 '#ECEDEE' 'SemiBold'
        $n.TextTrimming = 'CharacterEllipsis'; $n.ToolTip = $c.Name
        $sp.Children.Add($n) | Out-Null
        $sp.Children.Add((New-Text ('{0:dd/MM HH:mm} · {1}.exe · {2} s' -f [datetime]$c.Date, $c.Game, $c.Secs) 10 '#5C616B')) | Out-Null
        $st = New-Text ('{0:0.0} FPS · {1} travada(s)' -f $c.Avg, $c.Stutters) 11 '#8A8F98'
        $st.Margin = '0,3,0,0'
        $sp.Children.Add($st) | Out-Null
        $dp.Children.Add($sp) | Out-Null
        $row.Child = $dp
        $ui.CapList.Children.Add($row) | Out-Null
    }

    if (-not $caps.Count) {
        $empty = New-Text 'Grave pelo menos uma captura para ver o gráfico. Dica: grave antes e depois de aplicar ajustes, no mesmo trecho do jogo.' 12 '#5C616B'
        $empty.TextWrapping = 'Wrap'
        $empty.Margin = '2,0,0,0'
        $ui.Chart.Children.Add($empty) | Out-Null
        return
    }
    # Espaço extra à direita para o número não ser cortado
    $max = (($caps | ForEach-Object { $_.Avg }) | Measure-Object -Maximum).Maximum * 1.15
    $panel = New-Object Windows.Controls.Border
    $panel.Style = $window.FindResource('Panel')
    $panel.Padding = '16,14'
    $stack = New-Object Windows.Controls.StackPanel
    foreach ($c in $caps) {
        $g = New-RowGrid '170', '*'
        $g.Margin = '0,6,0,8'
        $lab = New-Object Windows.Controls.StackPanel
        $lab.VerticalAlignment = 'Center'
        $ln = New-Text $c.Name 12 '#ECEDEE' 'SemiBold'
        $ln.TextTrimming = 'CharacterEllipsis'; $ln.Margin = '0,0,12,0'
        $lab.Children.Add($ln) | Out-Null
        $lab.Children.Add((New-Text ('{0:dd/MM HH:mm}' -f [datetime]$c.Date) 10 '#5C616B')) | Out-Null
        $g.Children.Add($lab) | Out-Null
        $bars = New-Object Windows.Controls.StackPanel
        foreach ($s in $Series) {
            $v = [double]$c.($s.Key)
            $bars.Children.Add((New-Bar $v $max $s.Color ('{0}: {1:0.0} FPS' -f $s.Name, $v))) | Out-Null
        }
        [Windows.Controls.Grid]::SetColumn($bars, 1)
        $g.Children.Add($bars) | Out-Null
        $stack.Children.Add($g) | Out-Null
    }
    $panel.Child = $stack
    $ui.Chart.Children.Add($panel) | Out-Null
}

foreach ($s in $Series) {
    $sw = New-Object Windows.Controls.Border
    $sw.Width = 10; $sw.Height = 10; $sw.CornerRadius = 2
    $sw.Background = Get-Brush $s.Color
    $sw.Margin = '14,0,6,0'
    $sw.VerticalAlignment = 'Center'
    $ui.Legend.Children.Add($sw) | Out-Null
    $lt = New-Text $s.Name 11 '#8A8F98'
    $lt.VerticalAlignment = 'Center'
    $ui.Legend.Children.Add($lt) | Out-Null
}
foreach ($d in 30, 60, 120) {
    $chip = New-Object Windows.Controls.RadioButton
    $chip.Style = $window.FindResource('Chip')
    $chip.GroupName = 'CapDur'
    $chip.Content = "$d s"
    $chip.Tag = $d
    $chip.IsChecked = ($d -eq 60)
    $chip.Add_Checked({ param($s) $script:CapSecs = [int]$s.Tag })
    $ui.DurChips.Children.Add($chip) | Out-Null
}
$ui.BtnCapture.Add_Click({ Start-Capture })
$ui.BtnCapCancel.Add_Click({ $script:CapCancel = $true })
$ui.BtnGamesRefresh.Add_Click({ Update-GameChips })
$ui.CapName.Add_TextChanged({ $ui.CapNameHint.Visibility = if ($ui.CapName.Text) { 'Collapsed' } else { 'Visible' } })
Update-Captures

# ---------------- Janela ----------------
foreach ($nav in 'NavHome', 'NavOpt', 'NavWin', 'NavGame', 'NavBench', 'NavDiag', 'NavTools', 'NavLog') {
    $ui[$nav].Add_Checked({ param($s)
        foreach ($p in 'PageHome', 'PageOpt', 'PageWin', 'PageGame', 'PageBench', 'PageDiag', 'PageTools', 'PageLog') {
            $ui[$p].Visibility = if ($p -eq $s.Tag) { 'Visible' } else { 'Collapsed' }
        }
        $ui.ActionBar.Visibility = if ($s.Tag -in 'PageOpt', 'PageWin') { 'Visible' } else { 'Collapsed' }
        if ($s.Tag -eq 'PageGame' -and -not $ui.ProcList.Children.Count) { Update-ProcList }
        if ($s.Tag -eq 'PageBench' -and -not $ui.GameChips.Children.Count) { Update-GameChips }
    })
}

$ui.BtnBackup.Add_Click({ Start-Process explorer.exe $BackupDir })
$ui.BtnMin.Add_Click({ $window.WindowState = 'Minimized' })
$ui.BtnMax.Add_Click({ $window.WindowState = if ($window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$ui.BtnClose.Add_Click({ $window.Close() })
# Maximizada sem borda, a janela passa um pouco da tela; a margem compensa
$window.Add_StateChanged({
    $max = $window.WindowState -eq 'Maximized'
    $ui.Root.Margin = if ($max) { '7' } else { '0' }
    $ui.BtnMax.Content = [string][char]$(if ($max) { 0xE923 } else { 0xE922 })
})

# ---------------- Início ----------------
$info = Get-SysInfo
foreach ($row in @(@('Processador', $info.Cpu), @('Placa de vídeo', $info.Gpu), @('Memória', $info.Ram), @('Sistema', $info.Os))) {
    $g = New-Object Windows.Controls.DockPanel
    $g.Margin = '0,4,0,4'
    $k = New-Text $row[0] 12 '#8A8F98'
    $k.Width = 120
    $v = New-Text $row[1] 12 '#ECEDEE' 'SemiBold'
    $v.TextTrimming = 'CharacterEllipsis'; $v.ToolTip = $row[1]
    $g.Children.Add($k) | Out-Null; $g.Children.Add($v) | Out-Null
    $ui.SysPanel.Children.Add($g) | Out-Null
}
$ui.StatusRight.Text = "Backup: $BackupFile"

Update-State
$window.Add_ContentRendered({
    Write-Log 'Pronto.'
    if ($script:GameCfg.Paused.Count) {
        $n = Resume-Paused
        Write-Log "O Modo Jogo não foi desligado da última vez: $n processo(s) pausado(s) foram retomados." 'warn'
    }
    Start-Scan
})
[void]$window.ShowDialog()
