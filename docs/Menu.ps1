#Requires -Version 5.1
# MeuBoost - otimizador básico pessoal (Windows 10/11)
# Cada ajuste guarda o valor original em C:\ProgramData\MeuBoost\backup.json
# e pode ser revertido individualmente pela interface.

# ---------------- Auto-elevação (admin) ----------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$BackupDir  = Join-Path $env:ProgramData 'MeuBoost'
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
        $raw = Get-Content $BackupFile -Raw | ConvertFrom-Json
        return @{ reg = (ConvertTo-Hash $raw.reg); services = (ConvertTo-Hash $raw.services); power = $raw.power }
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
    powercfg /setactive $script:Backup.power.Target | Out-Null
}

function Disable-Services {
    foreach ($svc in 'DiagTrack', 'SysMain') {
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

function Clear-Temp {
    foreach ($d in @($env:TEMP, "$env:windir\Temp")) {
        Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------- Catálogo de ajustes ----------------
$SP = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$Tweaks = @(
    [pscustomobject]@{ Id = 'power'; Name = 'Plano de energia: Desempenho Máximo'; Apply = { Enable-PowerPlan } }
    [pscustomobject]@{ Id = 'gamedvr'; Name = 'Desativar Game DVR (gravação em segundo plano)'; Apply = {
        Set-Tweak 'gamedvr' 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        Set-Tweak 'gamedvr' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 } }
    [pscustomobject]@{ Id = 'gamemode'; Name = 'Ativar Modo de Jogo do Windows'; Apply = {
        Set-Tweak 'gamemode' 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 } }
    [pscustomobject]@{ Id = 'hags'; Name = 'Agendamento de GPU por hardware (HAGS) [reiniciar]'; Apply = {
        Set-Tweak 'hags' 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchGpuMode' 2 } }
    [pscustomobject]@{ Id = 'mmcss'; Name = 'Prioridade de CPU/GPU para jogos (MMCSS)'; Apply = {
        Set-Tweak 'mmcss' $SP 'SystemResponsiveness' 10
        Set-Tweak 'mmcss' $SP 'NetworkThrottlingIndex' (-1)   # 0xFFFFFFFF
        Set-Tweak 'mmcss' "$SP\Tasks\Games" 'GPU Priority' 8
        Set-Tweak 'mmcss' "$SP\Tasks\Games" 'Priority' 6
        Set-Tweak 'mmcss' "$SP\Tasks\Games" 'Scheduling Category' 'High' 'String'
        Set-Tweak 'mmcss' "$SP\Tasks\Games" 'SFIO Priority' 'High' 'String' } }
    [pscustomobject]@{ Id = 'priosep'; Name = 'Priorizar o app em primeiro plano (Win32PrioritySeparation)'; Apply = {
        Set-Tweak 'priosep' 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38 } }
    [pscustomobject]@{ Id = 'mouse'; Name = 'Desativar aceleração do mouse [relogar]'; Apply = {
        Set-Tweak 'mouse' 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
        Set-Tweak 'mouse' 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
        Set-Tweak 'mouse' 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String' } }
    [pscustomobject]@{ Id = 'nagle'; Name = 'Desativar Nagle / ACK atrasado (TCP) [reiniciar]'; Apply = { Disable-Nagle } }
    [pscustomobject]@{ Id = 'services'; Name = 'Desativar telemetria (DiagTrack) e SysMain'; Apply = { Disable-Services } }
    [pscustomobject]@{ Id = 'visual'; Name = 'Efeitos visuais: melhor desempenho + sem transparência'; Apply = {
        Set-Tweak 'visual' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
        Set-Tweak 'visual' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0 } }
    [pscustomobject]@{ Id = 'temp'; Name = 'Limpar arquivos temporários (NÃO reversível)'; Apply = { Clear-Temp } }
)

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

function Test-Applied([string]$Id) {
    if ($Id -eq 'power') { return $null -ne $script:Backup.power }
    if (@($script:Backup.services.Values | Where-Object { $_.Tweak -eq $Id }).Count) { return $true }
    return [bool](@($script:Backup.reg.Values | Where-Object { $_.Tweak -eq $Id }).Count)
}

# ---------------- Interface ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'MeuBoost'
$form.Size = New-Object System.Drawing.Size(600, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$list = New-Object System.Windows.Forms.CheckedListBox
$list.Location = New-Object System.Drawing.Point(12, 12)
$list.Size = New-Object System.Drawing.Size(560, 280)
$list.CheckOnClick = $true
$form.Controls.Add($list)

$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(12, 345)
$log.Size = New-Object System.Drawing.Size(560, 160)
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$form.Controls.Add($log)

function Write-Log([string]$msg) { $log.AppendText("$msg`r`n"); [System.Windows.Forms.Application]::DoEvents() }

function Update-List {
    $list.Items.Clear()
    foreach ($t in $Tweaks) {
        $prefix = if (Test-Applied $t.Id) { '[ATIVO] ' } else { '' }
        [void]$list.Items.Add("$prefix$($t.Name)")
    }
}

function New-Button([string]$text, [int]$x) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 302)
    $b.Size = New-Object System.Drawing.Size(180, 32)
    $form.Controls.Add($b)
    return $b
}

$btnApply  = New-Button 'Aplicar selecionados' 12
$btnUndo   = New-Button 'Reverter selecionados' 202
$btnUndoAll = New-Button 'Reverter tudo' 392

$btnApply.Add_Click({
    $sel = @($list.CheckedIndices | ForEach-Object { $Tweaks[$_] })
    if ($sel.Count -eq 0) { Write-Log 'Nada selecionado.'; return }
    Write-Log 'Criando ponto de restauração (pode demorar)...'
    try {
        Checkpoint-Computer -Description 'MeuBoost' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Ponto de restauração OK.'
    } catch { Write-Log "Aviso: ponto de restauração não criado ($($_.Exception.Message))" }
    foreach ($t in $sel) {
        try { & $t.Apply; Write-Log "OK    $($t.Name)" }
        catch { Write-Log "ERRO  $($t.Name): $($_.Exception.Message)" }
    }
    Save-Backup; Update-List
    Write-Log 'Concluído. Ajustes marcados com [reiniciar]/[relogar] precisam disso para valer.'
})

$btnUndo.Add_Click({
    $ids = @($list.CheckedIndices | ForEach-Object { $Tweaks[$_].Id })
    if ($ids.Count -eq 0) { Write-Log 'Nada selecionado.'; return }
    Undo-Tweaks $ids; Update-List
    Write-Log "Revertido: $($ids -join ', ')"
})

$btnUndoAll.Add_Click({
    Undo-Tweaks @($Tweaks | ForEach-Object { $_.Id }); Update-List
    Write-Log 'Tudo revertido para os valores originais.'
})

Update-List
Write-Log "Backup em: $BackupFile"
[void]$form.ShowDialog()