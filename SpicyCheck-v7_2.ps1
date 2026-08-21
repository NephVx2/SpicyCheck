#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Maintenance Windows 11 - V7.2
    Affichage systeme style fastfetch + diagnostic sante + maintenance complete.
.PARAMETER SauterNettoyage
    Ignore la phase de nettoyage.
.PARAMETER SauterReparation
    Ignore la phase de reparation (DISM / SFC).
.PARAMETER SauterOptimisation
    Ignore la phase d optimisation des disques.
.PARAMETER Silent
    Desactive tout affichage console.
.PARAMETER ExportJSON
    Exporte les resultats en JSON.
.PARAMETER SelfTest
    Execute une batterie de tests internes (non destructifs) pour verifier
    que les fonctions, cmdlets et binaires requis par le script fonctionnent
    correctement, puis quitte. Aucune modification systeme n est effectuee.
#>
[CmdletBinding()]
param(
    [switch]$SauterNettoyage,
    [switch]$SauterReparation,
    [switch]$SauterOptimisation,
    [switch]$Silent,
    [switch]$ExportJSON,
    [switch]$SelfTest
)

# ════════════════════════════════════════════════════════════════
#  INITIALISATION
# ════════════════════════════════════════════════════════════════
$ErrorActionPreference  = 'SilentlyContinue'
$Script:Version         = '7.2'
$Script:StartTime       = Get-Date
$Script:Results         = [System.Collections.Generic.List[object]]::new()
$Script:Sante           = [System.Collections.Generic.List[object]]::new()
$Script:SysInfo         = [ordered]@{}
$Script:ReportPath      = ''
$Script:TotalSteps      = 0
$Script:CurrentStep     = 0
$Script:TestResults     = [System.Collections.Generic.List[object]]::new()
$Script:TestPass        = 0
$Script:TestFail        = 0
$Script:TestTotal       = 0

$Script:Root    = Join-Path $env:USERPROFILE 'Desktop\Rapports_Maintenance'
if (-not (Test-Path $Script:Root)) { New-Item -ItemType Directory -Path $Script:Root -Force | Out-Null }
$Script:LogFile = Join-Path $Script:Root ("maintenance_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".log")
$Script:ErrFile = Join-Path $env:USERPROFILE 'Desktop\MAINTENANCE_ERREUR.txt'

$Script:W = 94  # largeur utile interieure des cadres

# ════════════════════════════════════════════════════════════════
#  UTILITAIRES DE BASE
# ════════════════════════════════════════════════════════════════

function Write-Log {
    param([string]$Msg, [string]$Lvl = 'INFO')
    try { Add-Content $Script:LogFile "[$(Get-Date -Format 'HH:mm:ss')][$Lvl] $Msg" -Encoding UTF8 -EA SilentlyContinue } catch {}
}

function Add-Result {
    param([string]$Op, [string]$St, $Data = '', [string]$Sec = '')
    $Script:Results.Add([PSCustomObject]@{ Op=$Op; St=$St; Data="$Data"; Time=Get-Date; Sec=$Sec })
}

function Add-Sante {
    param([string]$Comp, [string]$Val, [string]$St, [string]$Det = '')
    $Script:Sante.Add([PSCustomObject]@{ Comp=$Comp; Val=$Val; St=$St; Det=$Det })
}

function wc { param([string]$t,[string]$c='White',[switch]$n)
    if ($Silent) { return }
    if ($n) { Write-Host $t -ForegroundColor $c -NoNewline } else { Write-Host $t -ForegroundColor $c }
}

function New-Bar {
    param([int]$Pct, [int]$Len = 22)
    $f = [math]::Min([math]::Round($Pct * $Len / 100), $Len)
    return ('█' * $f) + ('░' * ($Len - $f))
}

function Get-TypeDisque {
    param([string]$L)

    # Patterns de detection par nom
    $patternSSD = 'NVMe|SSD|Solid.State|MTFD|M\.2|Flash|eMMC|' +
                  'Micron|Crucial|Kingston|Transcend|' +
                  'Samsung.*(860|870|980|970|850|840|830|750|PM|SM|MZ)|' +
                  'WD.*(Blue|Green|Black SN|Red SN|SN[0-9])|' +
                  'SanDisk|Plextor|Intel.*(SSDP|SSD)|Corsair Force|' +
                  'Patriot|ADATA|PNY|OWC|Sabrent|SK.Hynix'
    $patternHDD = 'HDD|Barracuda|Caviar|WD.*(Blue [0-9]TB|Green [0-9]TB|Red [0-9]TB|Purple|Gold)|' +
                  'Seagate|Toshiba [0-9]|HGST|Hitachi|IronWolf|NAS [0-9]'

    # ── Methode 1 : Get-Disk ──────────────────────────────────────
    try {
        $part = Get-Partition -DriveLetter $L -EA Stop
        $disk = Get-Disk -Number $part.DiskNumber -EA Stop

        if ($disk.BusType   -eq 'NVMe')            { return 'SSD' }
        if ($disk.MediaType -eq 'SSD')              { return 'SSD' }
        if ($disk.MediaType -eq 'HDD')              { return 'HDD' }
        if ($disk.FriendlyName -match $patternSSD)  { return 'SSD' }
        if ($disk.FriendlyName -match $patternHDD)  { return 'HDD' }
    } catch {}

    # ── Methode 2 : Get-PhysicalDisk (DeviceId en string) ────────
    try {
        $part    = Get-Partition -DriveLetter $L -EA Stop
        $diskNum = "$($part.DiskNumber)"   # convertir en string pour comparer DeviceId
        $pd      = Get-PhysicalDisk -EA Stop | Where-Object { $_.DeviceId -eq $diskNum }
        if ($pd) {
            if ($pd.MediaType   -eq 'SSD')          { return 'SSD' }
            if ($pd.MediaType   -eq 'HDD')          { return 'HDD' }
            if ($pd.SpindleSpeed -eq 0)             { return 'SSD' }  # 0 RPM = non-rotatif = SSD
            if ($pd.SpindleSpeed -gt 0)             { return 'HDD' }  # RPM connu = disque rotatif
            if ($pd.FriendlyName -match $patternSSD){ return 'SSD' }
            if ($pd.FriendlyName -match $patternHDD){ return 'HDD' }
        }
    } catch {}

    # ── Methode 3 : WMI MSFT_PhysicalDisk (namespace Storage) ───
    # MediaType : 3=HDD, 4=SSD, 5=SCM — plus fiable que Win32_DiskDrive
    try {
        $part    = Get-Partition -DriveLetter $L -EA Stop
        $diskNum = $part.DiskNumber
        $msft    = Get-CimInstance -Namespace root/Microsoft/Windows/Storage `
                       -ClassName MSFT_PhysicalDisk -EA Stop |
                   Where-Object { $_.DeviceId -match "\\\\$diskNum$" -or
                                  [int]$_.DeviceId -eq $diskNum }
        if ($msft) {
            if ($msft.MediaType -eq 4) { return 'SSD' }  # 4 = SSD dans MSFT
            if ($msft.MediaType -eq 3) { return 'HDD' }  # 3 = HDD dans MSFT
            if ($msft.SpindleSpeed -eq 0 -and $msft.MediaType -ne 3) { return 'SSD' }
        }
    } catch {}

    # ── Methode 4 : Win32_DiskDrive + nom du modele ──────────────
    try {
        $part    = Get-Partition -DriveLetter $L -EA Stop
        $wmi     = Get-CimInstance Win32_DiskDrive -EA Stop |
                   Where-Object { $_.Index -eq $part.DiskNumber }
        if ($wmi) {
            if ($wmi.Model -match $patternSSD) { return 'SSD' }
            if ($wmi.Model -match $patternHDD) { return 'HDD' }
            # MediaType WMI : 0=Unknown, 1=Unknown, 2=Removable, 3=Fixed, 4=Remote
            # Pour les SSD SATA, SerialNumber est non-vide et pas de rotation
        }
    } catch {}

    # ── Methode 5 : Optimize-Volume -Query ───────────────────────
    # Windows lui-meme indique le type d optimisation prevu
    try {
        $info = & defrag "$($L):" /Q 2>&1 | Out-String
        if ($info -match 'Solid.state|SSD|Trim')  { return 'SSD' }
        if ($info -match 'fragmented|Defragment')  { return 'HDD' }
    } catch {}

    Write-Log "Type disque ${L}: non determine apres 5 methodes" 'WARN'
    return 'Inconnu'
}

function Invoke-Etape {
    param([string]$Nom,[string]$Label,[string]$Sec='',[scriptblock]$Bloc)
    try {
        $r = & $Bloc
        if (-not $r) { $r = 'Operation terminee' }
        Write-Log "$Nom : OK - $r" 'OK'
        Add-Result $Nom 'OK' $r $Sec
        Write-EtapeLigne $Label "$r" 'OK'
    } catch {
        $e = $_.Exception.Message
        Write-Log "$Nom ERREUR : $e" 'ERROR'
        Add-Result $Nom 'ERROR' $e $Sec
        Write-EtapeLigne $Label "ERREUR : $e" 'ERROR'
    }
}

# ════════════════════════════════════════════════════════════════
#  COMPOSANTS VISUELS CONSOLE  (couleur unique : bleu)
# ════════════════════════════════════════════════════════════════

# Couleur unique pour tous les cadres
$Script:BC = 'Cyan'   # Blue Cyan - couleur des cadres

function Write-BoxTop   { wc "  ╔$('═'*$Script:W)╗" $Script:BC }
function Write-BoxBot   { wc "  ╚$('═'*$Script:W)╝" $Script:BC }
function Write-BoxSep   { wc "  ╠$('═'*$Script:W)╣" $Script:BC }
function Write-BoxThin  { wc "  ╟$('─'*$Script:W)╢" $Script:BC }
function Write-BoxEmpty { wc "  ║$(' '*$Script:W)║" $Script:BC }

# Ligne de contenu dans un cadre - alignement garanti
function Write-BoxLine {
    param([string]$Txt, [string]$c = 'White')
    # Tronquer si necessaire pour tenir dans le cadre
    $max = $Script:W - 4
    if ($Txt.Length -gt $max) { $Txt = $Txt.Substring(0, $max - 3) + '...' }
    wc "  ║  " Cyan -n
    wc "$($Txt.PadRight($Script:W - 4))" $c -n
    wc "  ║" Cyan
}

# Titre centre dans un cadre
function Write-BoxTitle {
    param([string]$Txt, [string]$c = 'White')
    $pad = [math]::Max(0, $Script:W - $Txt.Length)
    $l   = [math]::Floor($pad / 2)
    $r   = $pad - $l
    wc "  ║$(' '*$l)" Cyan -n
    wc $Txt $c -n
    wc "$(' '*$r)║" Cyan
}

# En-tete de section : cadre + titre colore + barre de progression
function Write-Section {
    param([string]$Titre, [string]$Icone = '>>')
    $Script:CurrentStep++
    $pct  = if ($Script:TotalSteps -gt 0) { [math]::Round($Script:CurrentStep / $Script:TotalSteps * 100) } else { 0 }
    $bar  = New-Bar $pct 28
    $step = "Etape $($Script:CurrentStep) / $($Script:TotalSteps)"

    wc ""
    wc "  ╔$('═' * $Script:W)╗" Cyan
    # Ligne titre : icone + texte en blanc brillant
    $titreStr = "  $Icone  $($Titre.ToUpper())"
    $rPad     = [math]::Max(0, $Script:W - $titreStr.Length)
    wc "  ║" Cyan -n
    Write-Host $titreStr -ForegroundColor White -NoNewline
    wc "$(' ' * $rPad)║" Cyan
    wc "  ╟$('─' * $Script:W)╢" Cyan
    # Ligne progression avec couleur selon avancement
    $pctColor = if ($pct -lt 40) { 'DarkCyan' } elseif ($pct -lt 80) { 'Cyan' } else { 'Green' }
    $prog     = "  $step   [$bar]"
    $pctTxt   = "  $pct%"
    $rPad2    = [math]::Max(0, $Script:W - $prog.Length - $pctTxt.Length)
    wc "  ║" Cyan -n
    wc $prog DarkGray -n
    wc $pctTxt $pctColor -n
    wc "$(' ' * $rPad2)║" Cyan
    wc "  ╚$('═' * $Script:W)╝" Cyan
}

# Ligne resultat d une etape - hors cadre, alignement simple
function Write-EtapeLigne {
    param([string]$Label, [string]$Val, [string]$St = 'INFO')
    $bgTag = switch($St){'OK'{'DarkGreen'}'WARN'{'DarkYellow'}'ERROR'{'DarkRed'}'SKIP'{'DarkGray'}default{'DarkBlue'}}
    $fc    = switch($St){'OK'{'Green'}'WARN'{'Yellow'}'ERROR'{'Red'}'SKIP'{'DarkGray'}default{'Gray'}}
    $tag   = switch($St){'OK'{' OK '}'WARN'{'WARN'}'ERROR'{'ERR '}'SKIP'{'SKIP'}default{' -- '}}
    $pfx   = switch($St){'OK'{'  '}'WARN'{'  '}'ERROR'{'  '}'SKIP'{'  '}default{'  '}}

    if ($Label.Length -gt 40) { $Label = $Label.Substring(0, 37) + '...' }
    if ($Val.Length   -gt 50) { $Val   = $Val.Substring(0, 47)   + '...' }

    $lp = $Label.PadRight(42, '.')
    wc "    $lp" DarkGray -n
    wc " " White -n
    Write-Host " $tag " -ForegroundColor White -BackgroundColor $bgTag -NoNewline
    Write-Host "  $Val" -ForegroundColor $fc
}

# Ligne dans le tableau de detail du resume - alignement garanti dans le cadre
function Write-BoxDetailLigne {
    param([string]$Op, [string]$Det, [string]$St)
    $bgTag  = switch($St){'OK'{'DarkGreen'}'WARN'{'DarkYellow'}'ERROR'{'DarkRed'}'SKIP'{'DarkGray'}default{'DarkBlue'}}
    $fc     = switch($St){'OK'{'Green'}'WARN'{'Yellow'}'ERROR'{'Red'}'SKIP'{'DarkGray'}default{'Gray'}}
    $tag    = switch($St){'OK'{' OK '}'WARN'{'WARN'}'ERROR'{'ERR '}'SKIP'{'SKIP'}default{' -- '}}

    # Layout : ║(1) + 2esp + TAG(6) + 2esp + Op(28) + 2esp + Det(?) + ║(1)
    # Fixe = 1+2+6+2+28+2+1 = 42 => Det = W - 42
    $opW   = 28
    $detW  = $Script:W - 40
    if ($detW -lt 4) { $detW = 4 }

    if ($Op.Length  -gt $opW)  { $Op  = $Op.Substring(0, $opW  - 3) + '...' }
    if ($Det.Length -gt $detW) { $Det = $Det.Substring(0, $detW - 3) + '...' }

    $opPad  = $Op.PadRight($opW)
    $detPad = $Det.PadRight($detW)

    wc "  ║  " Cyan -n
    Write-Host " $tag " -ForegroundColor White -BackgroundColor $bgTag -NoNewline
    Write-Host "  $opPad  " -ForegroundColor DarkGray -NoNewline
    Write-Host $detPad -ForegroundColor $fc -NoNewline
    Write-Host "║" -ForegroundColor Cyan
}

# Separateur de section dans le tableau de detail
function Write-BoxSectionSep {
    param([string]$Titre)
    $txt  = "  ── $Titre "
    $fill = [math]::Max(0, $Script:W - $txt.Length)
    wc "  ║" Cyan -n
    wc $txt Cyan -n
    wc "$('─' * $fill)║" Cyan
}

# ════════════════════════════════════════════════════════════════
#  BANNIERE PRINCIPALE
# ════════════════════════════════════════════════════════════════

function Write-Banner {
    try {
        $ui  = $Host.UI.RawUI
        $buf = $ui.BufferSize
        if ($buf.Width -lt 102) {
            $ui.BufferSize = New-Object System.Management.Automation.Host.Size(102, $buf.Height)
            $win = $ui.WindowSize
            $ui.WindowSize = New-Object System.Management.Automation.Host.Size([math]::Min(102,$ui.MaxWindowSize.Width), $win.Height)
        }
    } catch {}

    wc ""
    wc "  ╔$('═' * $Script:W)╗" Cyan
    wc "  ║$(' ' * $Script:W)║" Cyan
    wc "  ║         " Cyan -n
    Write-Host "███████╗██████╗ ██╗ ██████╗██╗   ██╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗" -ForegroundColor Cyan -NoNewline
    wc "         ║" Cyan
    wc "  ║         " Cyan -n
    Write-Host "██╔════╝██╔══██╗██║██╔════╝╚██╗ ██╔╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝" -ForegroundColor Cyan -NoNewline
    wc "         ║" Cyan
    wc "  ║         " Cyan -n
    Write-Host "███████╗██████╔╝██║██║      ╚████╔╝ ██║     ███████║█████╗  ██║     █████╔╝ " -ForegroundColor Cyan -NoNewline
    wc "         ║" Cyan
    wc "  ║         " Cyan -n
    Write-Host "╚════██║██╔═══╝ ██║██║       ╚██╔╝  ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗ " -ForegroundColor DarkCyan -NoNewline
    wc "         ║" Cyan
    wc "  ║         " Cyan -n
    Write-Host "███████║██║     ██║╚██████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗" -ForegroundColor DarkCyan -NoNewline
    wc "         ║" Cyan
    wc "  ║         " Cyan -n
    Write-Host "╚══════╝╚═╝     ╚═╝ ╚═════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝" -ForegroundColor DarkCyan -NoNewline
    wc "         ║" Cyan
    wc "  ║$(' ' * $Script:W)║" Cyan
    # Sous-titre colore : "by Nephren" en cyan, tirets en gris, version en blanc
    wc "  ║$(' ' * $Script:W)║" Cyan
    $subL = "  by "
    $subA = "Nephren"
    $subM = "  ──  Maintenance Windows 11  ──  "
    $subV = "v$($Script:Version)"
    $subFull = $subL + $subA + $subM + $subV
    $subPad  = [math]::Max(0, $Script:W - $subFull.Length)
    $subLp   = [math]::Floor($subPad / 2)
    $subRp   = $subPad - $subLp
    wc "  ║$(' ' * $subLp)" Cyan -n
    wc $subL DarkGray -n
    wc $subA Cyan -n
    wc $subM DarkGray -n
    wc $subV White -n
    wc "$(' ' * $subRp)║" Cyan
    wc "  ║$(' ' * $Script:W)║" Cyan
    wc "  ╠$('═' * $Script:W)╣" Cyan
    $date  = Get-Date -Format 'dd/MM/yyyy'
    $heure = Get-Date -Format 'HH:mm:ss'
    $info  = "  Demarre le $date a $heure   |   $env:USERNAME @ $env:COMPUTERNAME"
    $rInfo = [math]::Max(0, $Script:W - $info.Length)
    wc "  ║" Cyan -n
    wc "$info$(' ' * $rInfo)" DarkGray -n
    wc "║" Cyan
    wc "  ╚$('═' * $Script:W)╝" Cyan
}

# ════════════════════════════════════════════════════════════════
#  FASTFETCH - INFORMATIONS SYSTEME COMPLETES
# ════════════════════════════════════════════════════════════════

function Write-SysInfoLine {
    param([string]$ico,[string]$key,[string]$val,[string]$vc='White')
    # Largeur fixe : icone(1) + 2esp + cle(22) = 25 chars de cle
    $keyPad = $key.PadRight(22)
    # Verifier si l icone est double-largeur (emojis, certains symboles)
    # En forcant le prefix a 28 chars nets avec compensation si necessaire
    $icoLen  = $ico.Length
    $espIco  = if ($icoLen -gt 1) { " " } else { "  " }  # 1 esp si ico 2 chars, 2 si ico 1 char
    $prefix  = "  $ico$espIco$keyPad  "
    $valMax  = $Script:W - $prefix.Length  # prefix display = prefix.Length pour tous les icones actuels
    if ($val.Length -gt $valMax) { $val = $val.Substring(0, $valMax - 3) + '...' }
    $valPad  = $val.PadRight($valMax)
    wc "  ║" Cyan -n
    wc $prefix DarkGray -n
    wc $valPad $vc -n
    wc "║" Cyan
}

function Write-SysInfo {
    wc ""
    Write-BoxTop
    Write-BoxTitle "  INFORMATIONS SYSTEME  " Cyan
    Write-BoxSep

    # ── OS ───────────────────────────────────────────────────────
    try {
        $os   = Get-CimInstance Win32_OperatingSystem -EA Stop
        $cs   = Get-CimInstance Win32_ComputerSystem  -EA Stop
        $bios = Get-CimInstance Win32_BIOS            -EA Stop
        $up   = (Get-Date) - $os.LastBootUpTime
        $upStr= "$([int]$up.TotalDays)j $($up.Hours)h $($up.Minutes)m"

        wc "  ║$('  ── OS & MACHINE '.PadRight($Script:W,'─'))║" Cyan
        Write-SysInfoLine '⊞' 'OS'          "$($os.Caption)" Cyan
        Write-SysInfoLine '⊟' 'Build'       "$($os.BuildNumber) ($($os.OSArchitecture))" Gray
        Write-SysInfoLine '⊡' 'Machine'     "$($cs.Manufacturer) $($cs.Model)".Trim() Gray
        Write-SysInfoLine '⊠' 'BIOS'        "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate.ToString('dd/MM/yyyy')))" Gray
        Write-SysInfoLine '⊙' 'Uptime'      $upStr $(if($up.TotalDays -gt 30){'Yellow'}else{'Green'})
        Write-SysInfoLine '⊚' 'Utilisateur' "$env:USERNAME @ $env:COMPUTERNAME" Gray

        $Script:SysInfo['OS']      = "$($os.Caption) Build $($os.BuildNumber)"
        $Script:SysInfo['Machine'] = "$($cs.Manufacturer) $($cs.Model)"
        $Script:SysInfo['BIOS']    = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)"
        $Script:SysInfo['Uptime']  = $upStr
    } catch { Write-SysInfoLine '!' 'OS' "Lecture impossible" Red }

    # ── CPU ──────────────────────────────────────────────────────
    try {
        $cpu     = Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1
        $load    = if ($cpu.LoadPercentage) { $cpu.LoadPercentage } else { 0 }
        $freqMax = [math]::Round($cpu.MaxClockSpeed / 1000, 2)
        $cacheL3 = if ($cpu.L3CacheSize) { "$([math]::Round($cpu.L3CacheSize/1024,1)) Mo" } else { 'N/A' }
        $archMap = @{0='x86';5='ARM';6='Itanium';9='x64';12='ARM64'}
        $arch    = if ($archMap[[int]$cpu.Architecture]) { $archMap[[int]$cpu.Architecture] } else { 'N/A' }
        $virt    = if ($cpu.VirtualizationFirmwareEnabled) { 'Oui' } else { 'Non' }
        $barCpu  = New-Bar $load 14
        $stcCpu  = if($load -gt 90){'Red'}elseif($load -gt 70){'Yellow'}else{'Green'}

        wc "  ║$('  ── PROCESSEUR '.PadRight($Script:W,'─'))║" Cyan
        Write-SysInfoLine '►' 'CPU'          $cpu.Name.Trim() Cyan
        Write-SysInfoLine '◆' 'Architecture' "$arch | Socket: $($cpu.SocketDesignation)" Gray
        Write-SysInfoLine '◈' 'Coeurs'       "$($cpu.NumberOfCores) physiques / $($cpu.NumberOfLogicalProcessors) logiques" Gray
        Write-SysInfoLine '◉' 'Frequence'    "$freqMax GHz max" Gray
        Write-SysInfoLine '◎' 'Cache L3'     $cacheL3 Gray
        Write-SysInfoLine '◌' 'Virtualisation' $virt Gray
        Write-SysInfoLine '◍' 'Charge'       "$load%  [$barCpu]" $stcCpu

        $Script:SysInfo['CPU'] = "$($cpu.Name.Trim()) | $($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T | $freqMax GHz | L3: $cacheL3"
        Add-Sante 'CPU Modele'  $cpu.Name.Trim()  'BON'  "$arch | $($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T | $freqMax GHz | L3: $cacheL3"
        Add-Sante 'CPU Charge'  "$load%"           $(if($load -gt 90){'CRITIQUE'}elseif($load -gt 70){'MOYEN'}else{'BON'}) "Virt: $virt"
    } catch { Write-SysInfoLine '!' 'CPU' "Lecture impossible" Red }

    # ── GPU ──────────────────────────────────────────────────────
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -EA Stop | Where-Object { $_.Name -notmatch 'Basic|Generic|Remote' })
        if ($gpus.Count -gt 0) {
            wc "  ║$('  ── CARTE(S) GRAPHIQUE(S) '.PadRight($Script:W,'─'))║" Cyan
            foreach ($g in $gpus) {
                $vram = if ($g.AdapterRAM -gt 0) { "$([math]::Round($g.AdapterRAM/1GB,1)) Go VRAM" } else { 'VRAM N/A' }
                $res  = if ($g.CurrentHorizontalResolution) { "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution) @ $($g.CurrentRefreshRate)Hz" } else { '' }
                $drv  = if ($g.DriverVersion) { "Drv: $($g.DriverVersion)" } else { '' }
                Write-SysInfoLine '▶' 'GPU' $g.Name.Trim() Cyan
                Write-SysInfoLine '▷' 'VRAM / Res.' "$vram  $res" Gray
                Write-SysInfoLine '▸' 'Pilote' $drv Gray
                $Script:SysInfo["GPU_$($g.Name)"] = "$($g.Name) | $vram | $res"
                Add-Sante "GPU: $($g.Name)" $vram 'BON' "$res | $drv"
            }
        }
    } catch {}

    # ── RAM ──────────────────────────────────────────────────────
    try {
        $os_r    = Get-CimInstance Win32_OperatingSystem -EA Stop
        $slots   = @(Get-CimInstance Win32_PhysicalMemory -EA SilentlyContinue)
        $totGo   = [math]::Round($os_r.TotalVisibleMemorySize/1MB,1)
        $libGo   = [math]::Round($os_r.FreePhysicalMemory/1MB,1)
        $usedGo  = [math]::Round($totGo - $libGo, 1)
        $pct     = [math]::Round($usedGo/$totGo*100,1)
        $barRam  = New-Bar ([int]$pct) 14
        $stcRam  = if($pct -gt 90){'Red'}elseif($pct -gt 75){'Yellow'}else{'Green'}

        # Type DDR
        $ddrMap  = @{20='DDR';21='DDR2';24='DDR3';26='DDR4';34='DDR5';29='LPDDR3';30='LPDDR4';35='LPDDR5'}
        $typeRam = if($slots.Count -gt 0 -and $ddrMap[[int]$slots[0].SMBIOSMemoryType]){$ddrMap[[int]$slots[0].SMBIOSMemoryType]}else{'RAM'}
        $speed   = if($slots.Count -gt 0 -and $slots[0].Speed){"$($slots[0].Speed) MHz"}else{'N/A'}
        $ffMap   = @{8='DIMM';12='SO-DIMM';13='SRIMM';17='FBDIMM'}
        $forme   = if($slots.Count -gt 0 -and $ffMap[[int]$slots[0].FormFactor]){$ffMap[[int]$slots[0].FormFactor]}else{'N/A'}
        $fabRam  = if($slots.Count -gt 0 -and $slots[0].Manufacturer){$slots[0].Manufacturer.Trim()}else{'N/A'}
        $canal   = if($slots.Count -ge 4){'Quad-Channel'}elseif($slots.Count -ge 2){'Dual-Channel'}else{'Single-Channel'}
        $barSize = if($slots.Count -gt 0 -and $slots[0].Capacity){"$([math]::Round($slots[0].Capacity/1GB,0)) Go"}else{'N/A'}

        wc "  ║$('  ── MEMOIRE RAM '.PadRight($Script:W,'─'))║" Cyan
        Write-SysInfoLine '▣' 'Total'        "$totGo Go  ($typeRam $speed $forme)" Cyan
        Write-SysInfoLine '▤' 'Utilisee'     "$usedGo Go ($pct%)  [$barRam]" $stcRam
        Write-SysInfoLine '▥' 'Libre'        "$libGo Go" Gray
        Write-SysInfoLine '▦' 'Barrettes'    "$($slots.Count) x $barSize" Gray
        Write-SysInfoLine '▧' 'Fabricant'    $fabRam Gray
        Write-SysInfoLine '▨' 'Config'       $canal Gray

        $Script:SysInfo['RAM'] = "$totGo Go $typeRam $speed | $($slots.Count)x $barSize $forme | $canal"
        Add-Sante 'RAM Type'       "$typeRam $speed $forme"      'BON'  "$($slots.Count)x $barSize | Fab: $fabRam | $canal"
        Add-Sante 'RAM Utilisation' "$pct% ($usedGo/$totGo Go)"  $(if($pct -gt 90){'CRITIQUE'}elseif($pct -gt 75){'MOYEN'}else{'BON'}) "Libre: $libGo Go"
    } catch { Write-SysInfoLine '!' 'RAM' "Lecture impossible" Red }

    # ── DISQUES ──────────────────────────────────────────────────
    try {
        $vols = @(Get-Volume -EA Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 })
        if ($vols.Count -gt 0) {
            wc "  ║$('  ── STOCKAGE '.PadRight($Script:W,'─'))║" Cyan
            foreach ($v in $vols) {
                $libre   = [math]::Round($v.SizeRemaining/1GB,1)
                $total   = [math]::Round($v.Size/1GB,1)
                $occ     = [math]::Round($total-$libre,1)
                $pctOcc  = [math]::Round($occ/$total*100,1)
                $pctLib  = 100 - $pctOcc
                $barD    = New-Bar ([int]$pctOcc) 14
                $stcD    = if($pctLib -lt 10){'Red'}elseif($pctLib -lt 20){'Yellow'}else{'Green'}
                $typeD   = Get-TypeDisque $v.DriveLetter
                $optiD   = switch($typeD){'SSD'{'TRIM'} 'HDD'{'Defrag'} default{'Auto'}}
                $lbl     = if($v.FileSystemLabel){$v.FileSystemLabel}else{'Volume'}
                $fs      = if($v.FileSystem){$v.FileSystem}else{'N/A'}
                $nomD    = 'N/A'; $busD = 'N/A'; $hlthD = 'N/A'
                try {
                    $part  = Get-Partition -DriveLetter $v.DriveLetter -EA Stop
                    $disk  = Get-Disk -Number $part.DiskNumber -EA Stop
                    $nomD  = if($disk.FriendlyName){$disk.FriendlyName.Trim()}else{'N/A'}
                    $busD  = if($disk.BusType){$disk.BusType}else{'N/A'}
                    $hlthD = if($disk.HealthStatus){$disk.HealthStatus}else{'N/A'}
                } catch {}
                $stcH = if($hlthD -eq 'Healthy'){'Green'}elseif($hlthD -eq 'Warning'){'Yellow'}else{'Gray'}

                Write-SysInfoLine '◉' "$($v.DriveLetter): $lbl" "$nomD  [$typeD · $busD]" Cyan
                Write-SysInfoLine '◈' '  Espace'      "$occ Go / $total Go  [$barD]  ($pctLib% libre)" $stcD
                Write-SysInfoLine '◇' '  Sante / FS'  "$hlthD  ·  $fs  ·  Optim: $optiD" $stcH

                $Script:SysInfo["Disque_$($v.DriveLetter)"] = "$nomD | $typeD $busD | $total Go | $pctLib% libre | $hlthD"
                Add-Sante "Disque $($v.DriveLetter): $lbl" "$libre Go / $total Go ($pctLib% libre)" $(if($pctLib -lt 10){'CRITIQUE'}elseif($pctLib -lt 20){'MOYEN'}else{'BON'}) "$nomD | $typeD $busD | Sante: $hlthD | Optim: $optiD"
            }
        }
    } catch { Write-SysInfoLine '!' 'Disques' "Lecture impossible" Red }

    # ── RESEAU ───────────────────────────────────────────────────
    try {
        $nics = @(Get-NetAdapter -EA Stop | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false })
        if ($nics.Count -gt 0) {
            wc "  ║$('  ── RESEAU '.PadRight($Script:W,'─'))║" Cyan
            foreach ($n in $nics) {
                $ip = (Get-NetIPAddress -InterfaceIndex $n.InterfaceIndex -AddressFamily IPv4 -EA SilentlyContinue).IPAddress
                $spd = if ($n.LinkSpeed) { $n.LinkSpeed } else { 'N/A' }
                Write-SysInfoLine '◌' $n.Name "$($n.InterfaceDescription.Trim())  [$spd]" Cyan
                Write-SysInfoLine '◍' '  IPv4' $(if($ip){$ip}else{'N/A'}) Gray
            }
        }
    } catch {}

    # ── TEMPERATURES ─────────────────────────────────────────────
    try {
        $temps = @(Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature -EA Stop)
        if ($temps.Count -gt 0) {
            wc "  ║$('  ── TEMPERATURES '.PadRight($Script:W,'─'))║" Cyan
            $i = 1
            foreach ($t in $temps) {
                $c    = [math]::Round($t.CurrentTemperature/10 - 273.15, 1)
                $stcT = if($c -gt 90){'Red'}elseif($c -gt 75){'Yellow'}else{'Green'}
                $barT = New-Bar ([int][math]::Min($c,100)) 14
                Write-SysInfoLine '~~' "Temp $i" "$c C  [$barT]" $stcT
                Add-Sante "Temp Zone $i" "$c C" $(if($c -gt 90){'CRITIQUE'}elseif($c -gt 75){'MOYEN'}else{'BON'}) ''
                $i++
            }
        }
    } catch {}

    Write-BoxEmpty
    Write-BoxBot
}

# ════════════════════════════════════════════════════════════════
#  DIAGNOSTIC DE SANTE
# ════════════════════════════════════════════════════════════════

function Write-DiagSante {
    Write-Section 'DIAGNOSTIC DE SANTE' '+'
    Write-Log 'Debut diagnostic sante' 'INFO'

    # Fonction interne d affichage d une ligne de sante
    function Show-SanteLigne {
        param([string]$Label, [string]$Val, [string]$St, [string]$Det = '')
        $bg  = switch($St) { 'BON'{'DarkGreen'} 'MOYEN'{'DarkYellow'} 'CRITIQUE'{'DarkRed'} default{'DarkGray'} }
        $fc  = switch($St) { 'BON'{'Green'} 'MOYEN'{'Yellow'} 'CRITIQUE'{'Red'} default{'Gray'} }
        $tag = switch($St) { 'BON'{'  BON  '} 'MOYEN'{' MOYEN '} 'CRITIQUE'{'CRIT. '} default{'  ---  '} }
        if ($Label.Length -gt 30) { $Label = $Label.Substring(0,27) + '...' }
        if ($Val.Length   -gt 54) { $Val   = $Val.Substring(0,51)   + '...' }
        $lp = $Label.PadRight(32, '.')
        wc "    $lp " DarkGray -n
        Write-Host " $tag " -ForegroundColor White -BackgroundColor $bg -NoNewline
        Write-Host "  $Val" -ForegroundColor $fc
        if ($Det) { wc "           >> $Det" DarkGray }
    }

    # ── 1. CPU ────────────────────────────────────────────────────
    wc ""
    wc "    -- CPU $('-' * 68)" DarkGray
    try {
        $cpu     = Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1
        $load    = if ($cpu.LoadPercentage) { $cpu.LoadPercentage } else { 0 }
        $freqMax = $cpu.MaxClockSpeed
        $freqCur = $cpu.CurrentClockSpeed
        $pctFreq = if ($freqMax -gt 0) { [math]::Round($freqCur / $freqMax * 100) } else { 100 }
        $barCpu  = New-Bar $load 16

        $stLoad  = if ($load -gt 90) { 'CRITIQUE' } elseif ($load -gt 75) { 'MOYEN' } else { 'BON' }
        $stFreq  = if ($pctFreq -lt 40) { 'MOYEN' } else { 'BON' }

        Show-SanteLigne 'CPU Charge'    "$load%  [$barCpu]"  $stLoad
        Show-SanteLigne 'CPU Frequence' "$([math]::Round($freqCur/1000,2)) GHz / $([math]::Round($freqMax/1000,2)) GHz  ($pctFreq%)" $stFreq $(if($pctFreq -lt 40){'Possible throttling !'}else{''})

        $stRes = if ($stLoad -eq 'CRITIQUE' -or $stFreq -eq 'CRITIQUE') { 'ERROR' } elseif ($stLoad -eq 'MOYEN' -or $stFreq -eq 'MOYEN') { 'WARN' } else { 'OK' }
        Add-Result 'Sante_CPU' $stRes "Charge: $load% | Freq: $([math]::Round($freqCur/1000,2)) GHz" 'Sante'
        Add-Sante 'CPU Frequence' "$([math]::Round($freqCur/1000,2)) GHz / $([math]::Round($freqMax/1000,2)) GHz ($pctFreq%)" $stFreq $(if($pctFreq -lt 40){'Possible throttling !'}else{''})
    } catch { Show-SanteLigne 'CPU' 'Lecture impossible' 'MOYEN' }

    # Temperature CPU
    try {
        $temps = @(Get-CimInstance -Namespace root/WMI -ClassName MSAcpi_ThermalZoneTemperature -EA Stop)
        if ($temps.Count -gt 0) {
            $i = 1
            foreach ($t in $temps) {
                $c   = [math]::Round($t.CurrentTemperature / 10 - 273.15, 1)
                $stT = if ($c -gt 90) { 'CRITIQUE' } elseif ($c -gt 75) { 'MOYEN' } else { 'BON' }
                $barT = New-Bar ([int][math]::Min($c, 100)) 16
                Show-SanteLigne "CPU Temp Zone $i" "$c C  [$barT]" $stT
                $stRes2 = switch($stT) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
                Add-Result "Sante_Temp_$i" $stRes2 "$c C" 'Sante'
                $i++
            }
        }
    } catch { Show-SanteLigne 'CPU Temperature' 'Capteur non disponible' 'BON' }

    # ── 2. RAM ────────────────────────────────────────────────────
    wc ""
    wc "    -- RAM $('-' * 68)" DarkGray
    try {
        $os_r   = Get-CimInstance Win32_OperatingSystem -EA Stop
        $totGo  = [math]::Round($os_r.TotalVisibleMemorySize / 1MB, 1)
        $libGo  = [math]::Round($os_r.FreePhysicalMemory / 1MB, 1)
        $usedGo = [math]::Round($totGo - $libGo, 1)
        $pct    = [math]::Round($usedGo / $totGo * 100, 1)
        $barRam = New-Bar ([int]$pct) 16
        $stRam  = if ($pct -gt 90) { 'CRITIQUE' } elseif ($pct -gt 75) { 'MOYEN' } else { 'BON' }
        Show-SanteLigne 'RAM Utilisation' "$usedGo Go / $totGo Go  ($pct%)  [$barRam]" $stRam
        $stRes = switch($stRam) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
        Add-Result 'Sante_RAM' $stRes "$pct% ($usedGo/$totGo Go)" 'Sante'
    } catch { Show-SanteLigne 'RAM' 'Lecture impossible' 'MOYEN' }

    try {
        $pf = Get-CimInstance Win32_PageFileUsage -EA Stop | Select-Object -First 1
        if ($pf -and $pf.AllocatedBaseSize -gt 0) {
            $pfPct = [math]::Round($pf.CurrentUsage / $pf.AllocatedBaseSize * 100)
            $stPf  = if ($pfPct -gt 80) { 'CRITIQUE' } elseif ($pfPct -gt 50) { 'MOYEN' } else { 'BON' }
            Show-SanteLigne 'RAM Pagefile' "$($pf.CurrentUsage) Mo / $($pf.AllocatedBaseSize) Mo  ($pfPct%)" $stPf
            $stRes = switch($stPf) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
            Add-Result 'Sante_Pagefile' $stRes "$pfPct%" 'Sante'
            Add-Sante 'RAM Pagefile' "$($pf.CurrentUsage) Mo / $($pf.AllocatedBaseSize) Mo ($pfPct%)" $stPf ''
        }
    } catch {}

    # ── 3. DISQUES (chacun individuellement) ─────────────────────
    wc ""
    wc "    -- DISQUES $('-' * 65)" DarkGray
    try {
        $vols = @(Get-Volume -EA Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 })
        foreach ($v in $vols) {
            $libre  = [math]::Round($v.SizeRemaining / 1GB, 1)
            $total  = [math]::Round($v.Size / 1GB, 1)
            $pctLib = [math]::Round($v.SizeRemaining / $v.Size * 100, 1)
            $pctOcc = 100 - $pctLib
            $barD   = New-Bar ([int]$pctOcc) 14
            $stD    = if ($pctLib -lt 10) { 'CRITIQUE' } elseif ($pctLib -lt 20) { 'MOYEN' } else { 'BON' }
            $lbl    = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { 'Volume' }
            Show-SanteLigne "Disque $($v.DriveLetter): $lbl" "$libre Go libres / $total Go  ($pctLib%)  [$barD]" $stD
            $stRes = switch($stD) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
            $lblVol = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { 'Volume' }
            Add-Result "Disque $($v.DriveLetter): - Espace ($lblVol)" $stRes "$pctLib% libre ($libre Go / $total Go)" 'Sante'
        }
    } catch { Show-SanteLigne 'Volumes' 'Lecture impossible' 'MOYEN' }

    # SMART par disque physique
    try {
        $pds = @(Get-PhysicalDisk -EA Stop)
        foreach ($pd in $pds) {
            $hlth   = if ($pd.HealthStatus) { $pd.HealthStatus } else { 'Unknown' }
            $stHlth = if ($hlth -eq 'Healthy') { 'BON' } elseif ($hlth -eq 'Warning') { 'MOYEN' } else { 'CRITIQUE' }
            $nom    = if ($pd.FriendlyName) { $pd.FriendlyName.Trim() } else { "Disque $($pd.DeviceId)" }
            $taille = "$([math]::Round($pd.Size/1GB,0)) Go"
            Show-SanteLigne "SMART: $nom" "$hlth  |  $($pd.MediaType)  |  $taille" $stHlth
            $stRes = switch($stHlth) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
            Add-Result "Sante_SMART_$($pd.DeviceId)" $stRes $hlth 'Sante'
            Add-Sante "SMART: $nom" $hlth $stHlth "$($pd.MediaType) | $taille"
        }
    } catch { Show-SanteLigne 'SMART' 'Lecture impossible' 'BON' }

    # ── 4. GPU ────────────────────────────────────────────────────
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -EA Stop | Where-Object { $_.Name -notmatch 'Basic|Generic|Remote' })
        if ($gpus.Count -gt 0) {
            wc ""
            wc "    -- GPU $('-' * 69)" DarkGray
            foreach ($g in $gpus) {
                $vram  = if ($g.AdapterRAM -gt 0) { "$([math]::Round($g.AdapterRAM/1GB,1)) Go VRAM" } else { 'VRAM N/A' }
                $drv   = if ($g.DriverVersion) { "Drv $($g.DriverVersion)" } else { '' }
                $res   = if ($g.CurrentHorizontalResolution) { "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)@$($g.CurrentRefreshRate)Hz" } else { '' }
                Show-SanteLigne $g.Name.Trim() "$vram  |  $res" 'BON' $drv
                Add-Result "Sante_GPU_$($g.DeviceID)" 'OK' "$vram $res" 'Sante'
            }
        }
    } catch {}

    # ── 5. RESEAU ─────────────────────────────────────────────────
    wc ""
    wc "    -- RESEAU $('-' * 66)" DarkGray
    try {
        $nics = @(Get-NetAdapter -EA Stop | Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false })
        foreach ($n in $nics) {
            $ip  = (Get-NetIPAddress -InterfaceIndex $n.InterfaceIndex -AddressFamily IPv4 -EA SilentlyContinue).IPAddress
            Show-SanteLigne $n.Name "Up  |  $(if($ip){$ip}else{'IP N/A'})  |  $($n.LinkSpeed)" 'BON'
            Add-Result "Sante_Net_$($n.Name)" 'OK' "$(if($ip){$ip}else{'N/A'}) $($n.LinkSpeed)" 'Sante'
        }
    } catch {}

    try {
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        if ($gw -and $gw -ne '0.0.0.0') {
            $ping  = Test-Connection $gw -Count 1 -EA Stop
            $ms    = $ping.Latency
            $stNet = if ($ms -gt 200) { 'CRITIQUE' } elseif ($ms -gt 80) { 'MOYEN' } else { 'BON' }
            Show-SanteLigne 'Ping Gateway' "$gw  :  ${ms} ms" $stNet
            $stRes = switch($stNet) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
            Add-Result 'Sante_PingGW' $stRes "${ms}ms vers $gw" 'Sante'
            Add-Sante 'Ping Gateway' "${ms} ms" $stNet $gw
        }
    } catch { Show-SanteLigne 'Ping Gateway' 'Pas de passerelle detectee' 'MOYEN' }

    # ── 6. BATTERIE ───────────────────────────────────────────────
    try {
        $bat = Get-CimInstance Win32_Battery -EA Stop | Select-Object -First 1
        if ($bat) {
            wc ""
            wc "    -- BATTERIE $('-' * 64)" DarkGray
            $pct   = $bat.EstimatedChargeRemaining
            $stat  = switch ($bat.BatteryStatus) { 2{'En charge'} 1{'Sur batterie'} 3{'Pleine'} default{'Inconnu'} }
            $stBat = if ($pct -lt 20 -and $bat.BatteryStatus -eq 1) { 'CRITIQUE' } elseif ($pct -lt 40 -and $bat.BatteryStatus -eq 1) { 'MOYEN' } else { 'BON' }
            $barBat = New-Bar $pct 16
            Show-SanteLigne 'Batterie' "$pct%  [$barBat]  ($stat)" $stBat
            $stRes = switch($stBat) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
            Add-Result 'Sante_Batterie' $stRes "$pct% $stat" 'Sante'
            Add-Sante 'Batterie' "$pct% ($stat)" $stBat ''
        }
    } catch {}

    # ── 7. UPTIME ─────────────────────────────────────────────────
    try {
        $os  = Get-CimInstance Win32_OperatingSystem -EA Stop
        $up  = (Get-Date) - $os.LastBootUpTime
        $upStr = "$([int]$up.TotalDays)j $($up.Hours)h $($up.Minutes)m"
        $stUp  = if ($up.TotalDays -gt 60) { 'CRITIQUE' } elseif ($up.TotalDays -gt 30) { 'MOYEN' } else { 'BON' }
        wc ""
        wc "    -- SYSTEME $('-' * 65)" DarkGray
        Show-SanteLigne 'Uptime' $upStr $stUp $(if($up.TotalDays -gt 30){'Redemarrage recommande'}else{''})
        $stRes = switch($stUp) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
        Add-Result 'Sante_Uptime' $stRes $upStr 'Sante'
        Add-Sante 'Uptime' $upStr $stUp $(if($up.TotalDays -gt 30){'Redemarrage recommande'}else{''})
    } catch {}

    # ── 8. EVENT LOG ──────────────────────────────────────────────
    try {
        $depuis = (Get-Date).AddHours(-1)
        # Utiliser SilentlyContinue pour ne pas generer d erreurs Windows si le log est vide
        $evts   = @(Get-WinEvent -FilterHashtable @{ LogName='System','Application'; Level=1,2; StartTime=$depuis } -EA SilentlyContinue -MaxEvents 100)
        if ($null -eq $evts) { $evts = @() }
        $nbEvt  = $evts.Count
        $stEvt  = if ($nbEvt -gt 20) { 'CRITIQUE' } elseif ($nbEvt -gt 5) { 'MOYEN' } else { 'BON' }
        Show-SanteLigne 'EventLog (1h)' "$nbEvt erreur(s) / critique(s)" $stEvt
        $stRes = switch($stEvt) { 'BON'{'OK'} 'MOYEN'{'WARN'} 'CRITIQUE'{'ERROR'} }
        Add-Result 'Sante_EventLog' $stRes "$nbEvt evenements" 'Sante'
        Add-Sante 'EventLog (1h)' "$nbEvt evenement(s)" $stEvt ''
    } catch { Show-SanteLigne 'EventLog (1h)' 'Non disponible' 'BON' }

    # ── Score global ──────────────────────────────────────────────
    $nC = ($Script:Results | Where-Object { $_.Sec -eq 'Sante' -and $_.St -eq 'ERROR' }).Count
    $nM = ($Script:Results | Where-Object { $_.Sec -eq 'Sante' -and $_.St -eq 'WARN'  }).Count
    $nB = ($Script:Results | Where-Object { $_.Sec -eq 'Sante' -and $_.St -eq 'OK'    }).Count
    $sc = if($nC -gt 0){'CRITIQUE'}elseif($nM -gt 0){'MOYEN'}else{'BON'}
    $bg = switch($sc) { 'BON'{'DarkGreen'} 'MOYEN'{'DarkYellow'} 'CRITIQUE'{'DarkRed'} }

    wc ""
    Write-BoxTop
    Write-BoxTitle "  ETAT DE SANTE GLOBAL  " Cyan
    Write-BoxSep
    Write-BoxLine "  Composants OK       :  $nB" Green
    if ($nM -gt 0) { Write-BoxLine "  Attention           :  $nM" Yellow }
    if ($nC -gt 0) { Write-BoxLine "  Critique            :  $nC" Red }
    Write-BoxEmpty
    $pfx = "  Etat general  :  "
    $sfx = "  $sc  "
    $rp  = [math]::Max(0, $Script:W - 2 - $pfx.Length - $sfx.Length)
    wc "  ║  $pfx" White -n
    Write-Host $sfx -ForegroundColor White -BackgroundColor $bg -NoNewline
    wc "$(' ' * $rp)║" Cyan
    Write-BoxBot
    Write-Log "Score sante : $sc (BON=$nB MOYEN=$nM CRITIQUE=$nC)" 'OK'
}

# ════════════════════════════════════════════════════════════════
#  NETTOYAGE
# ════════════════════════════════════════════════════════════════

function Get-Taille { param([string]$P)
    if (-not (Test-Path $P)) { return 0 }
    $m = Get-ChildItem $P -Recurse -Force -EA SilentlyContinue | Measure-Object -Property Length -Sum -EA SilentlyContinue
    if ($m -and $m.Sum) { return $m.Sum } else { return 0 }
}

function Start-Nettoyage {
    Write-Section 'NETTOYAGE SYSTEME' '◈'
    Write-Log 'Debut nettoyage' 'INFO'

    Invoke-Etape 'TEMP_User' 'TEMP utilisateur' 'Nettoyage' {
        $a = Get-Taille $env:TEMP
        Get-ChildItem $env:TEMP -Recurse -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
        "$([math]::Round($a/1MB,1)) Mo liberes"
    }
    Invoke-Etape 'TEMP_Sys' 'TEMP systeme (Windows\Temp)' 'Nettoyage' {
        $p = 'C:\Windows\Temp'; $a = Get-Taille $p
        Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
        "$([math]::Round($a/1MB,1)) Mo liberes"
    }
    Invoke-Etape 'Prefetch' 'Prefetch (.pf uniquement)' 'Nettoyage' {
        $p = 'C:\Windows\Prefetch'
        $f = Get-ChildItem $p -Filter '*.pf' -Force -EA SilentlyContinue
        if (-not $f) { return '0 Mo liberes' }
        $a = ($f | Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
        if (-not $a) { $a = 0 }
        $f | Remove-Item -Force -EA SilentlyContinue
        "$([math]::Round($a/1MB,1)) Mo liberes"
    }
    Invoke-Etape 'WU_Cache' 'Cache Windows Update' 'Nettoyage' {
        $p = 'C:\Windows\SoftwareDistribution\Download'; $a = Get-Taille $p
        Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
        "$([math]::Round($a/1MB,1)) Mo liberes"
    }
    Invoke-Etape 'Thumbnails' 'Cache miniatures' 'Nettoyage' {
        $p = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"

        $fichiers = Get-ChildItem $p -Force -EA SilentlyContinue | Where-Object {
            $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db'
        }

        if (-not $fichiers) {
            return '0 Mo liberes'
        }

        $a = ($fichiers | Measure-Object Length -Sum).Sum
        if (-not $a) { $a = 0 }

        $fichiers | Remove-Item -Force -EA SilentlyContinue

        "$([math]::Round($a/1MB,1)) Mo liberes"
    }
    Invoke-Etape 'INetCache' 'Cache Internet (INetCache)' 'Nettoyage' {
        $p = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"; $a = Get-Taille $p
        Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
        "$([math]::Round($a/1MB,1)) Mo liberes"
    }
    Invoke-Etape 'LogsCBS' 'Logs CBS (Windows)' 'Nettoyage' {
        $p = 'C:\Windows\Logs\CBS'

        $fichiers = Get-ChildItem $p -Force -EA SilentlyContinue | Where-Object {
            $_.Extension -in '.log', '.cab'
        }

        if (-not $fichiers) {
            return '0 Mo liberes'
        }

        $a = ($fichiers | Measure-Object Length -Sum).Sum
        if (-not $a) { $a = 0 }

        $fichiers | Remove-Item -Force -EA SilentlyContinue

        "$([math]::Round($a/1MB,1)) Mo liberes"
    }
    Invoke-Etape 'DNS' 'Vider cache DNS' 'Nettoyage' {
        & ipconfig /flushdns 2>&1 | Out-Null ; 'Vide'
    }
    Invoke-Etape 'Corbeille' 'Corbeille' 'Nettoyage' {
        Clear-RecycleBin -Force -EA SilentlyContinue ; 'Videe'
    }
}

# ════════════════════════════════════════════════════════════════
#  REPARATION
# ════════════════════════════════════════════════════════════════

function ConvertTo-SortieProprete {
    <#
      Nettoie la sortie brute de dism.exe / sfc.exe avant tout matching texte.
      Ces deux binaires peuvent, selon la configuration console (codepage/UTF-8),
      etre captures avec des octets NUL intercales entre chaque caractere et des
      caracteres accentues mal decodes. Sans ce nettoyage, un regex qui matche
      parfaitement en test peut ne JAMAIS matcher sur la sortie reelle,
      masquant silencieusement des erreurs ou corruptions detectees.
    #>
    param([string]$Raw)
    $c = $Raw -replace "`0", ''
    $c -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' '
}

function Invoke-EtapeDiag {
    <#
      Variante d Invoke-Etape pour les etapes de diagnostic ou le resultat
      "reussi" n'est pas forcement "sain" (ex : DISM ScanHealth qui trouve
      une corruption reste une execution reussie, mais merite un WARN
      visuel plutot qu un OK vert).
      Le bloc doit retourner un objet @{ Msg = '...'; St = 'OK'|'WARN' }.
    #>
    param([string]$Nom,[string]$Label,[string]$Sec='',[scriptblock]$Bloc)
    try {
        $r = & $Bloc
        $msg = if ($r -and $r.Msg) { $r.Msg } else { 'Operation terminee' }
        $st  = if ($r -and $r.St)  { $r.St }  else { 'OK' }
        Write-Log "$Nom : $st - $msg" $st
        Add-Result $Nom $st $msg $Sec
        Write-EtapeLigne $Label $msg $st
    } catch {
        $e = $_.Exception.Message
        Write-Log "$Nom ERREUR : $e" 'ERROR'
        Add-Result $Nom 'ERROR' $e $Sec
        Write-EtapeLigne $Label "ERREUR : $e" 'ERROR'
    }
}

function Start-Reparation {
    Write-Section 'REPARATION SYSTEME' '◉'
    Write-Log 'Debut reparation' 'INFO'
    $Script:DismCorrompu = $false

    Invoke-EtapeDiag 'DISM_Check' 'DISM - CheckHealth' 'Reparation' {
        $o = ConvertTo-SortieProprete (& dism /Online /Cleanup-Image /CheckHealth 2>&1 | Out-String)
        Write-Log "DISM CheckHealth : $o" 'INFO'
        # Detection bilingue : la sortie DISM est localisee selon la langue de Windows
        # (ex FR : "Le magasin de composants est reparable", EN : "The component store is repairable")
        if ($o -match '(?i)repairable|r.parable') {
            $Script:DismCorrompu = $true
            return @{ Msg = 'Corruption detectee !'; St = 'WARN' }
        }
        @{ Msg = 'Aucune corruption'; St = 'OK' }
    }
    Invoke-EtapeDiag 'DISM_Scan' 'DISM - ScanHealth' 'Reparation' {
        $o = ConvertTo-SortieProprete (& dism /Online /Cleanup-Image /ScanHealth 2>&1 | Out-String)
        Write-Log "DISM ScanHealth : $o" 'INFO'
        if ($o -match '(?i)repairable|r.parable') {
            $Script:DismCorrompu = $true
            return @{ Msg = 'Corruption detectee !'; St = 'WARN' }
        }
        @{ Msg = 'Aucune corruption'; St = 'OK' }
    }

    if ($Script:DismCorrompu) {
        Invoke-EtapeDiag 'DISM_Restore' 'DISM - RestoreHealth' 'Reparation' {
            $o = ConvertTo-SortieProprete (& dism /Online /Cleanup-Image /RestoreHealth 2>&1 | Out-String)
            Write-Log "DISM RestoreHealth : $o" 'INFO'
            # Detection bilingue d un echec (source introuvable, erreur 0x8...)
            if ($o -match '(?i)source files? could not be found|fichiers? sources? .{0,10}introuvables?|0x[0-9a-f]{7,8}') {
                return @{ Msg = 'Echec : fichiers source introuvables (voir log)'; St = 'ERROR' }
            }
            @{ Msg = 'Reparation terminee'; St = 'OK' }
        }
    } else {
        Write-EtapeLigne 'DISM - RestoreHealth' 'Non necessaire (systeme sain)' 'SKIP'
        Add-Result 'DISM_Restore' 'SKIP' 'Aucune corruption detectee' 'Reparation'
        Write-Log 'RestoreHealth ignore : systeme sain' 'INFO'
    }

    Invoke-EtapeDiag 'SFC' 'SFC - scannow' 'Reparation' {
        $o = ConvertTo-SortieProprete (& sfc /scannow 2>&1 | Out-String)
        Write-Log "SFC : $o" 'INFO'
        # Detection bilingue - ordre important : le cas "non reparable" doit etre
        # teste avant le cas "repare avec succes" car les deux messages FR partagent
        # le debut "a trouve des fichiers endommages/corrompus...". Les gaps ".{0,N}"
        # tolerent les artefacts d encodage residuels (ex : apostrophe typographique
        # mal decodee) entre les mots-cles.
        if ($o -match "(?i)found corrupt files but was unable to (fix|repair)|mais.{0,10}pas.{0,15}r.ussi.{0,15}(tous|les) les? r.parer") {
            return @{ Msg = 'Fichiers corrompus NON reparables - lancer DISM /RestoreHealth ou reparation hors-ligne'; St = 'ERROR' }
        }
        if ($o -match "(?i)did not (perform|complete) the requested (repair )?operation|pas.{0,10}r.ussi.{0,15}effectuer.{0,15}op.ration demand") {
            return @{ Msg = 'Echec de l operation SFC (relancer en mode sans echec)'; St = 'ERROR' }
        }
        if ($o -match "(?i)successfully repaired|trouv. des fichiers.{0,20}(endommag|corrompu).{0,20}et les a r.par") {
            return @{ Msg = 'Fichiers corrompus reparES'; St = 'WARN' }
        }
        if ($o -match '(?i)did not find any integrity violations|aucune violation') {
            return @{ Msg = 'Aucune violation'; St = 'OK' }
        }
        @{ Msg = 'Verification terminee'; St = 'OK' }
    }
    Invoke-Etape 'BCD' 'BCD - Verification bootloader' 'Reparation' {
        $o = & bcdedit /enum 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) { return 'OK' }
        'Erreur BCD'
    }
}

# ════════════════════════════════════════════════════════════════
#  OPTIMISATION
# ════════════════════════════════════════════════════════════════

function Start-Optimisation {
    Write-Section 'OPTIMISATION DISQUES' '◇'
    Write-Log 'Debut optimisation' 'INFO'

    @(Get-Volume -EA SilentlyContinue | Where-Object { $_.DriveLetter -and $_.Size -gt 0 }) | ForEach-Object {
        $L = $_.DriveLetter
        $T = Get-TypeDisque $L
        if ($T -eq 'SSD') {
            Invoke-Etape "Disque $L - Optimisation SSD (TRIM)" "Disque $L (SSD) - TRIM" 'Optimisation' {
                Optimize-Volume -DriveLetter $L -ReTrim -Verbose:$false -EA Stop
                'TRIM effectue'
            }
        } elseif ($T -eq 'HDD') {
            Invoke-Etape "Disque $L - Optimisation HDD (Defrag)" "Disque $L (HDD) - Defragmentation" 'Optimisation' {
                Optimize-Volume -DriveLetter $L -Defrag -Verbose:$false -EA Stop
                'Defragmentation effectuee'
            }
        } else {
            Invoke-Etape "Disque $L - Optimisation (Auto)" "Disque $L (inconnu) - Auto" 'Optimisation' {
                Optimize-Volume -DriveLetter $L -Verbose:$false -EA Stop
                'Optimisation auto'
            }
        }
    }

    Invoke-Etape 'WinSxS' 'Nettoyage WinSxS (DISM)' 'Optimisation' {
        $o = & dism /Online /Cleanup-Image /StartComponentCleanup 2>&1 | Out-String
        Write-Log "DISM WinSxS : $o" 'INFO'
        'Termine'
    }
}

# ════════════════════════════════════════════════════════════════
#  RAPPORT HTML
# ════════════════════════════════════════════════════════════════

function New-RapportHTML {
    $file   = Join-Path $Script:Root ("rapport_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".html")
    $dur    = '{0:mm}m {0:ss}s' -f ((Get-Date) - $Script:StartTime)
    $ok     = ($Script:Results | Where-Object St -eq 'OK').Count
    $warn   = ($Script:Results | Where-Object St -eq 'WARN').Count
    $err    = ($Script:Results | Where-Object St -eq 'ERROR').Count
    $skip   = ($Script:Results | Where-Object St -eq 'SKIP').Count
    $nC     = ($Script:Sante | Where-Object St -eq 'CRITIQUE').Count
    $nM     = ($Script:Sante | Where-Object St -eq 'MOYEN').Count
    $nB     = ($Script:Sante | Where-Object St -eq 'BON').Count
    $score  = if($nC -gt 0){'CRITIQUE'}elseif($nM -gt 0){'MOYEN'}else{'BON'}
    $sCss   = switch($score){'BON'{'ok'}'MOYEN'{'warn'}'CRITIQUE'{'err'}}

    # Lignes sysinfo
    $siRows = foreach ($k in $Script:SysInfo.Keys) {
        $v = [System.Net.WebUtility]::HtmlEncode($Script:SysInfo[$k])
        "<tr><td class='si-key'>$([System.Net.WebUtility]::HtmlEncode($k))</td><td class='si-val'>$v</td></tr>"
    }

    # Lignes sante
    $santeRows = foreach ($s in $Script:Sante) {
        $bg  = switch($s.St){'BON'{'var(--ok-bg)'}'MOYEN'{'var(--warn-bg)'}'CRITIQUE'{'var(--err-bg)'}default{'var(--bg3)'}}
        $bdg = switch($s.St){
            'BON'      { '<span class="bx bx-ok">BON</span>' }
            'MOYEN'    { '<span class="bx bx-warn">MOYEN</span>' }
            'CRITIQUE' { '<span class="bx bx-err">CRITIQUE</span>' }
            default    { '<span class="bx bx-info">INFO</span>' }
        }
        "<tr style='background:$bg'><td class='h-comp'>$([System.Net.WebUtility]::HtmlEncode($s.Comp))</td><td class='h-val'>$([System.Net.WebUtility]::HtmlEncode($s.Val))</td><td class='h-det'>$([System.Net.WebUtility]::HtmlEncode($s.Det))</td><td>$bdg</td></tr>"
    }

    # Lignes operations
    $lastSec = ''
    $opsRows = foreach ($r in $Script:Results) {
        if ($r.Sec -ne $lastSec -and $r.Sec -ne '') {
            "<tr class='sec-row'><td colspan='4'>$([System.Net.WebUtility]::HtmlEncode($r.Sec))</td></tr>"
            $lastSec = $r.Sec
        }
        $bg  = switch($r.St){'OK'{'var(--ok-bg)'}'WARN'{'var(--warn-bg)'}'ERROR'{'var(--err-bg)'}'SKIP'{'var(--skip-bg)'}default{'var(--bg3)'}}
        $bdg = switch($r.St){
            'OK'    { '<span class="bx bx-ok">OK</span>' }
            'WARN'  { '<span class="bx bx-warn">WARN</span>' }
            'ERROR' { '<span class="bx bx-err">ERREUR</span>' }
            'SKIP'  { '<span class="bx bx-skip">IGNORE</span>' }
            default { '<span class="bx bx-info">INFO</span>' }
        }
        "<tr style='background:$bg'><td class='t-time'>$($r.Time.ToString('HH:mm:ss'))</td><td class='t-op'>$([System.Net.WebUtility]::HtmlEncode($r.Op))</td><td>$bdg</td><td class='t-det'>$([System.Net.WebUtility]::HtmlEncode($r.Data))</td></tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SpicyCheck by Nephren - $env:COMPUTERNAME - $(Get-Date -Format 'dd/MM/yyyy')</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:       #080b12;
  --bg2:      #0d1117;
  --bg3:      #111827;
  --bg4:      #1a2235;
  --bg5:      #0a0f1a;
  --border:   #1e2d45;
  --border2:  #243350;
  --accent:   #00d4ff;
  --accent2:  #0099cc;
  --accent3:  #005f80;
  --purple:   #7c6af7;
  --green:    #00c896;
  --green2:   #00a678;
  --yellow:   #ffb347;
  --yellow2:  #cc8800;
  --red:      #ff4d6d;
  --red2:     #cc2244;
  --text:     #e2e8f0;
  --text2:    #94a3b8;
  --text3:    #475569;
  --ok-bg:    #002a1f;
  --warn-bg:  #2a1a00;
  --err-bg:   #2a0012;
  --skip-bg:  #141a24;
}

body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;font-size:13px;line-height:1.6;min-height:100vh}

/* ══ HEADER ══════════════════════════════════════════════════════ */
header{
  background:linear-gradient(160deg,#060c1a 0%,#0a1628 50%,#060a14 100%);
  border-bottom:2px solid var(--accent3);
  padding:32px 48px 24px;
  position:relative;overflow:hidden
}
header::before{
  content:'';position:absolute;top:0;left:0;right:0;bottom:0;
  background:radial-gradient(ellipse at 20% 50%,rgba(0,212,255,.06) 0%,transparent 60%),
             radial-gradient(ellipse at 80% 20%,rgba(124,106,247,.05) 0%,transparent 50%);
  pointer-events:none
}
.logo{
  font-family:'Cascadia Code','Consolas','Courier New',monospace;
  font-size:10.5px;color:var(--accent);line-height:1.25;
  white-space:pre;margin:0 0 10px 0;
  text-shadow:0 0 20px rgba(0,212,255,.4)
}
.logo-sub{
  font-family:'Cascadia Code','Consolas',monospace;
  font-size:12px;color:var(--text2);letter-spacing:2px;
  margin-bottom:14px
}
.logo-sub b{color:var(--accent)}
.meta-bar{
  display:flex;flex-wrap:wrap;gap:8px 24px;
  font-size:11.5px;color:var(--text3);
  border-top:1px solid var(--border);padding-top:12px;margin-top:4px
}
.meta-bar span{display:flex;align-items:center;gap:6px}
.meta-bar b{color:var(--text2)}
.meta-dot{width:5px;height:5px;border-radius:50%;background:var(--accent);display:inline-block;box-shadow:0 0 6px var(--accent)}

/* ══ SCORE BANNER ════════════════════════════════════════════════ */
.score-bar{
  display:flex;align-items:center;gap:16px;
  padding:12px 48px;font-size:11px;font-weight:600;
  letter-spacing:1.5px;text-transform:uppercase;
  border-bottom:1px solid var(--border)
}
.score-ok   {background:linear-gradient(90deg,#001f14,var(--bg2));border-left:3px solid var(--green)}
.score-warn {background:linear-gradient(90deg,#1f1200,var(--bg2));border-left:3px solid var(--yellow)}
.score-err  {background:linear-gradient(90deg,#1f000a,var(--bg2));border-left:3px solid var(--red)}
.score-label{color:var(--text3)}
.score-pill{
  padding:3px 14px;border-radius:20px;font-size:11px;font-weight:700;
  letter-spacing:1px
}
.score-pill.ok  {background:var(--ok-bg); color:var(--green);border:1px solid var(--green2)}
.score-pill.warn{background:var(--warn-bg);color:var(--yellow);border:1px solid var(--yellow2)}
.score-pill.err {background:var(--err-bg); color:var(--red);  border:1px solid var(--red2)}
.score-counts{margin-left:auto;color:var(--text3);font-weight:400;font-size:11px;letter-spacing:.5px}
.score-counts b{color:var(--text2)}

/* ══ STAT CARDS ══════════════════════════════════════════════════ */
.cards{
  display:flex;flex-wrap:wrap;gap:12px;
  padding:20px 48px;background:var(--bg2);
  border-bottom:1px solid var(--border)
}
.card{
  background:var(--bg3);border:1px solid var(--border);
  border-radius:10px;padding:14px 20px;min-width:110px;
  text-align:center;transition:all .2s;cursor:default;position:relative;overflow:hidden
}
.card::after{
  content:'';position:absolute;top:0;left:0;right:0;height:2px;
  background:currentColor;opacity:.4;border-radius:10px 10px 0 0
}
.card:hover{border-color:var(--accent2);transform:translateY(-2px);box-shadow:0 4px 20px rgba(0,212,255,.1)}
.card .v{font-size:30px;font-weight:800;line-height:1;letter-spacing:-1px}
.card .l{font-size:9px;color:var(--text3);margin-top:6px;text-transform:uppercase;letter-spacing:2px}
.c-blue{color:var(--accent)}
.c-ok  {color:var(--green)}
.c-warn{color:var(--yellow)}
.c-err {color:var(--red)}
.c-skip{color:var(--text3)}
.c-pur {color:var(--purple)}

/* ══ LAYOUT ══════════════════════════════════════════════════════ */
main{padding:28px 48px;display:flex;flex-direction:column;gap:28px}
.row2{display:grid;grid-template-columns:1fr 1fr;gap:24px}
@media(max-width:960px){.row2{grid-template-columns:1fr}}

/* ══ PANELS ══════════════════════════════════════════════════════ */
.panel{
  background:var(--bg2);border:1px solid var(--border);
  border-radius:12px;overflow:hidden;
  box-shadow:0 2px 16px rgba(0,0,0,.3)
}
.panel-hdr{
  display:flex;align-items:center;gap:10px;
  padding:12px 18px;
  background:linear-gradient(90deg,var(--bg4) 0%,var(--bg2) 100%);
  border-bottom:1px solid var(--border)
}
.panel-hdr-icon{
  width:28px;height:28px;border-radius:6px;
  display:flex;align-items:center;justify-content:center;
  font-size:14px;flex-shrink:0
}
.panel-hdr-icon.blue{background:rgba(0,212,255,.12);color:var(--accent)}
.panel-hdr-icon.green{background:rgba(0,200,150,.12);color:var(--green)}
.panel-hdr-icon.purple{background:rgba(124,106,247,.12);color:var(--purple)}
.panel-title{font-size:11px;text-transform:uppercase;letter-spacing:2px;color:var(--text2);font-weight:600}
.panel-count{margin-left:auto;font-size:10px;color:var(--text3);background:var(--bg5);padding:2px 8px;border-radius:10px;border:1px solid var(--border)}

/* ══ SYSINFO TABLE ═══════════════════════════════════════════════ */
.si-table{width:100%;border-collapse:collapse}
.si-table tr{transition:background .15s}
.si-table tr:hover{background:rgba(0,212,255,.03)}
.si-key{
  padding:8px 16px;color:var(--text3);font-size:11px;
  width:32%;border-bottom:1px solid var(--border);
  white-space:nowrap;font-weight:500;letter-spacing:.3px
}
.si-val{
  padding:8px 16px;color:var(--text);font-size:12px;
  border-bottom:1px solid var(--border);
  font-family:'Cascadia Code','Consolas',monospace;
  word-break:break-word
}

/* ══ HEALTH TABLE ════════════════════════════════════════════════ */
.health-table{width:100%;border-collapse:collapse}
.health-table tr{transition:background .15s}
.health-table tr:hover td{background:rgba(0,212,255,.025)}
.health-table td{padding:8px 14px;font-size:12px;border-bottom:1px solid var(--border);vertical-align:middle}
.health-table .h-comp{color:var(--text2);font-size:11px;font-weight:500;white-space:nowrap}
.health-table .h-val {color:var(--text);font-family:'Cascadia Code','Consolas',monospace}
.health-table .h-det {color:var(--text3);font-size:11px}

/* ══ OPS TABLE ═══════════════════════════════════════════════════ */
.ops-table{width:100%;border-collapse:collapse}
.ops-table th{
  padding:10px 14px;text-align:left;font-size:9.5px;
  text-transform:uppercase;letter-spacing:1.5px;
  color:var(--accent2);background:var(--bg4);
  border-bottom:1px solid var(--border2);font-weight:600
}
.ops-table td{padding:8px 14px;font-size:12px;border-bottom:1px solid var(--border);vertical-align:middle}
.ops-table tr:hover td{background:rgba(255,255,255,.015)}
.ops-table .t-time{color:var(--text3);font-family:'Cascadia Code','Consolas',monospace;font-size:11px;white-space:nowrap}
.ops-table .t-op  {color:var(--text);font-weight:500}
.ops-table .t-det {color:var(--text2);font-size:11px}
.sec-row td{
  background:var(--bg5) !important;
  color:var(--accent2);font-size:9.5px;font-weight:700;
  text-transform:uppercase;letter-spacing:2.5px;
  padding:7px 14px;border-top:1px solid var(--border2)
}
.sec-row td::before{content:'// ';color:var(--accent3)}

/* ══ BADGES ══════════════════════════════════════════════════════ */
.bx{display:inline-flex;align-items:center;padding:3px 10px;border-radius:4px;font-size:10px;font-weight:700;letter-spacing:.8px;white-space:nowrap}
.bx-ok   {background:var(--ok-bg);  color:var(--green); border:1px solid var(--green2)}
.bx-warn {background:var(--warn-bg);color:var(--yellow);border:1px solid var(--yellow2)}
.bx-err  {background:var(--err-bg); color:var(--red);   border:1px solid var(--red2)}
.bx-skip {background:var(--skip-bg);color:var(--text3); border:1px solid var(--border)}
.bx-info {background:var(--bg4);    color:var(--accent);border:1px solid var(--accent3)}

/* ══ FOOTER ═════════════════════════════════════════════════════ */
footer{
  text-align:center;padding:20px 48px;
  color:var(--text3);font-size:11px;
  border-top:1px solid var(--border);
  background:var(--bg2);margin-top:12px;
  display:flex;align-items:center;justify-content:center;gap:16px
}
footer a{color:var(--accent2);text-decoration:none}
.footer-sep{color:var(--border2)}
</style>
</head>
<body>

<header>
  <div style="display:flex;align-items:flex-end;gap:0"><pre class="logo">███████╗██████╗ ██╗ ██████╗██╗   ██╗ ██████╗██╗  ██╗███████╗ ██████╗██╗  ██╗
██╔════╝██╔══██╗██║██╔════╝╚██╗ ██╔╝██╔════╝██║  ██║██╔════╝██╔════╝██║ ██╔╝
███████╗██████╔╝██║██║      ╚████╔╝ ██║     ███████║█████╗  ██║     █████╔╝ 
╚════██║██╔═══╝ ██║██║       ╚██╔╝  ██║     ██╔══██║██╔══╝  ██║     ██╔═██╗ 
███████║██║     ██║╚██████╗   ██║   ╚██████╗██║  ██║███████╗╚██████╗██║  ██╗
╚══════╝╚═╝     ╚═╝ ╚═════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝╚══════╝ ╚═════╝╚═╝  ╚═╝</pre><svg xmlns="http://www.w3.org/2000/svg" viewBox="9.39 8.477 484.197 428.149" style="width:80px;height:80px;margin-left:28px;align-self:flex-end;filter:drop-shadow(0 0 12px rgba(0,212,255,.4));flex-shrink:0"><path d="m347.015 235.334 42.877-112.525 67.515 25.727-42.877 112.524z" fill="#a8ce81"/><path d="m303.267 350.143 42.92-112.634 67.514 25.726-42.919 112.634z" fill="#fddb1d"/><path d="m263.921 207.033 42.879-112.525 67.406 25.685-42.877 112.525z" fill="#ef7066"/><path d="m220.505 320.972 42.588-111.764 67.406 25.685-42.588 111.764z" fill="#6eaed7"/><path d="m415.69 247.559c-12.962-10.418-30.606-21.623-53.002-30.158-1.455-.43-2.827-1.077-4.131-1.574l33.307-87.41c1.755.295 3.277.875 4.893 1.864 22.194 8.083 39.661 19.097 52.64 29.147zm-44.284 116.221a216.14 216.14 0 0 0 -53.045-30.048c-1.496-.321-2.91-.86-4.131-1.574l34.136-89.586c1.673.513 3.236.984 4.893 1.865 22.153 8.192 39.62 19.206 52.392 29.8zm122.181-212.166s-25.485-37.351-81.827-59.07c-56.66-21.216-98.7-15.447-98.482-15.364l-15.038 39.466c-.135-.3 27.632-5.533 68.583 3.971l-33.597 88.172c-41.045-9.913-68.776-3.795-68.693-4.013l-10.29 27.33s27.736-7.111 69.123 2.558l-34.717 91.108c-33.74-8.499-58.772-7.828-67.506-6.798l-14.5 38.052c10.873-1.087 47.89-2.17 95.075 15.809 56.467 21.392 82.284 57.873 82.408 57.547zm-241.467-32.87 14.747-38.705 41.45-2.259-14.748 38.705zm-91.514 240.162 14.748-38.704 41.45-2.259-14.5 38.052zm16.364-42.944 13.38-35.117 41.492-2.367-13.423 35.225zm60.11-157.752 13.382-35.118 41.45-2.259-13.381 35.117zm-30.034 78.821 13.381-35.116 41.45-2.26-13.381 35.117zm-15.038 39.466 13.38-35.117 41.45-2.26-13.38 35.117zm30.035-78.823 13.422-35.225 41.45-2.259-13.423 35.225zm-10.213-90.174 11.476-30.115 40.145-2.756-11.766 30.876zm-110.927-84.974 4.93-12.937 16.36-1.112-4.93 12.937zm76.852 67.881 8.99-23.592 35.117-2.306-9.03 23.7zm-28.691-20.768 6.835-17.94 28.455-1.483-6.836 17.94zm-24.068-24.734 5.469-14.351 23.495-.884-5.179 13.59zm40.932 183.057 11.476-30.115 39.855-1.995-11.475 30.115zm-110.927-84.974 4.93-12.938 16.36-1.111-5.178 13.59zm76.852 67.881 9.031-23.7 35.077-2.198-9.032 23.7zm-28.691-20.769 6.835-17.938 28.455-1.484-6.835 17.939zm-24.067-24.734 5.22-13.698 23.743-1.536-5.179 13.59zm41.222 182.297 11.475-30.115 40.145-2.757-11.475 30.116zm-110.927-84.974 5.178-13.59 16.112-.46-4.93 12.938zm77.1 67.229 8.74-22.94 35.119-2.307-8.783 23.05zm-28.691-20.769 6.587-17.287 28.454-1.483-6.587 17.286zm-24.026-24.843 5.178-13.59 23.495-.883-5.178 13.59z" fill="#000101"/><path d="m114.017 84.174 4.889-12.83 17.411-1.582-4.888 12.829zm88.133 61.472 9.529-25.006 32.364-1.612-9.28 24.353zm-34.836-17.383 7.913-20.766 29.355-1.887-7.913 20.766zm-29.271-19.247 6.049-15.873 22.733-1.173-6.007 15.764zm-50.589-48.909 4.102-10.763 12.995-.776-4.101 10.764zm11.525 63.532 4.93-12.938 17.411-1.583-4.93 12.938zm88.133 61.472 9.57-25.114 32.612-2.265-9.528 25.006zm-34.588-18.035 7.664-20.113 29.397-1.996-7.954 20.874zm-29.478-18.703 6.007-15.764 22.734-1.174-5.758 15.112zm-50.63-48.8 4.392-11.525 12.995-.775-4.392 11.524z" fill="#ef7066"/><path d="m68.115 204.635 4.93-12.937 17.122-.822-4.93 12.938zm87.844 62.234 9.57-25.114 32.653-2.374-9.57 25.114zm-34.547-18.144 7.913-20.766 29.107-1.235-7.664 20.113zm-29.229-19.355 5.717-15.004 22.733-1.173-5.717 15.003zm-50.92-48.04 4.391-11.524 12.995-.776-4.35 11.416zm11.814 62.77 4.93-12.937 17.122-.822-4.93 12.938zm88.133 61.473 9.28-24.353 32.654-2.374-9.57 25.115zm-34.836-17.383 7.913-20.765 29.397-1.996-7.955 20.874zm-29.229-19.355 5.717-15.004 23.023-1.934-6.007 15.764zm-50.631-48.801 4.102-10.763 12.995-.775-4.101 10.763z" fill="#6eaed7"/></svg></div></div>
  <div class="logo-sub">by <b>Nephren</b> &nbsp;&#8212;&nbsp; Maintenance Windows 11 &nbsp;&#8212;&nbsp; V$($Script:Version)</div>
  <div class="meta-bar">
    <span><span class="meta-dot"></span> $(Get-Date -Format 'dddd dd MMMM yyyy')</span>
    <span><b>$(Get-Date -Format 'HH:mm:ss')</b></span>
    <span>Machine : <b>$env:COMPUTERNAME</b></span>
    <span>Utilisateur : <b>$env:USERNAME</b></span>
    <span>Duree : <b>$dur</b></span>
  </div>
</header>

<div class="score-bar score-$sCss">
  <span class="score-label">Etat general</span>
  <span class="score-pill $sCss">&#9679; $score</span>
  <span class="score-counts">
    <b>$nB</b> OK &nbsp;&#183;&nbsp; <b>$nM</b> Moyen &nbsp;&#183;&nbsp; <b>$nC</b> Critique
  </span>
</div>

<div class="cards">
  <div class="card c-blue" ><div class="v c-blue" >$($Script:Results.Count)</div><div class="l">Operations</div></div>
  <div class="card c-ok"   ><div class="v c-ok"   >$ok</div><div class="l">Succes</div></div>
  <div class="card c-warn" ><div class="v c-warn"  >$warn</div><div class="l">Warnings</div></div>
  <div class="card c-err"  ><div class="v c-err"   >$err</div><div class="l">Erreurs</div></div>
  <div class="card c-skip" ><div class="v c-skip"  >$skip</div><div class="l">Ignores</div></div>
  <div class="card c-ok"   ><div class="v c-ok"   >$nB</div><div class="l">Sante OK</div></div>
  <div class="card c-warn" ><div class="v c-warn"  >$nM</div><div class="l">Sante Moyen</div></div>
  <div class="card c-err"  ><div class="v c-err"   >$nC</div><div class="l">Sante Crit.</div></div>
  <div class="card c-pur"  ><div class="v c-pur"   >$dur</div><div class="l">Duree</div></div>
</div>

<main>

  <div class="row2">
    <div class="panel">
      <div class="panel-hdr">
        <div class="panel-hdr-icon blue">&#9776;</div>
        <span class="panel-title">Informations Systeme</span>
      </div>
      <table class="si-table">$($siRows -join '')</table>
    </div>

    <div class="panel">
      <div class="panel-hdr">
        <div class="panel-hdr-icon green">&#10003;</div>
        <span class="panel-title">Diagnostic de Sante</span>
        <span class="panel-count">$($Script:Sante.Count) tests</span>
      </div>
      <table class="health-table">
        <tbody>$($santeRows -join '')</tbody>
      </table>
    </div>
  </div>

  <div class="panel">
    <div class="panel-hdr">
      <div class="panel-hdr-icon purple">&#9654;</div>
      <span class="panel-title">Detail des Operations</span>
      <span class="panel-count">$($Script:Results.Count) operations</span>
    </div>
    <table class="ops-table">
      <thead><tr><th>Heure</th><th>Operation</th><th>Statut</th><th>Detail</th></tr></thead>
      <tbody>$($opsRows -join '')</tbody>
    </table>
  </div>

</main>

<footer>
  <span>SpicyCheck <b>by Nephren</b> &mdash; V$($Script:Version)</span>
  <span class="footer-sep">|</span>
  <span>$env:COMPUTERNAME</span>
  <span class="footer-sep">|</span>
  <span>Log : <code>$($Script:LogFile)</code></span>
</footer>
</body>
</html>
"@

    $html | Out-File -FilePath $file -Encoding UTF8 -EA Stop
    return $file
}

# ════════════════════════════════════════════════════════════════
#  RESUME CONSOLE FINAL
# ════════════════════════════════════════════════════════════════

function Write-Resume {
    $dur   = '{0:mm}m {0:ss}s' -f ((Get-Date) - $Script:StartTime)
    $ok    = ($Script:Results | Where-Object St -eq 'OK').Count
    $warn  = ($Script:Results | Where-Object St -eq 'WARN').Count
    $err   = ($Script:Results | Where-Object St -eq 'ERROR').Count
    $skip  = ($Script:Results | Where-Object St -eq 'SKIP').Count
    $total = $Script:Results.Count
    $nC    = ($Script:Sante | Where-Object St -eq 'CRITIQUE').Count
    $nM    = ($Script:Sante | Where-Object St -eq 'MOYEN').Count
    $nB    = ($Script:Sante | Where-Object St -eq 'BON').Count
    $score = if($nC -gt 0){'CRITIQUE'}elseif($nM -gt 0){'MOYEN'}else{'BON'}
    $bgSc  = switch($score){'BON'{'DarkGreen'}'MOYEN'{'DarkYellow'}'CRITIQUE'{'DarkRed'}}
    $fcSc  = switch($score){'BON'{'Green'}'MOYEN'{'Yellow'}'CRITIQUE'{'Red'}}

    wc ""
    Write-BoxTop
    Write-BoxTitle "  RESUME FINAL  " Cyan
    Write-BoxSep
    Write-BoxEmpty
    Write-BoxLine "  Duree totale   :  $dur" White
    Write-BoxLine "  Operations     :  $total" White
    Write-BoxLine "  Succes  [OK]   :  $ok" Green
    if ($warn -gt 0) { Write-BoxLine "  Warnings [!!]  :  $warn" Yellow }
    if ($err  -gt 0) { Write-BoxLine "  Erreurs  [XX]  :  $err" Red }
    if ($skip -gt 0) { Write-BoxLine "  Ignores  [--]  :  $skip" DarkGray }
    Write-BoxEmpty
    Write-BoxThin
    Write-BoxEmpty
    Write-BoxLine "  ── SANTE DU PC" Cyan
    Write-BoxLine "  BON        :  $nB" Green
    if ($nM -gt 0) { Write-BoxLine "  MOYEN      :  $nM" Yellow }
    if ($nC -gt 0) { Write-BoxLine "  CRITIQUE   :  $nC" Red }
    Write-BoxEmpty
    # Ligne etat general avec badge colore - calcul rigoureux
    $prefix  = "  Etat general  :  "
    $suffix  = " $score "
    $rPad    = [math]::Max(0, $Script:W - 2 - $prefix.Length - $suffix.Length)
    wc "  ║  $prefix" White -n
    Write-Host $suffix -ForegroundColor White -BackgroundColor $bgSc -NoNewline
    wc "$(' ' * $rPad)║" Cyan
    Write-BoxEmpty
    Write-BoxBot

    # ── Tableau detail des operations ──────────────────────────────
    Write-BoxTop
    Write-BoxTitle "  DETAIL DES OPERATIONS  " Cyan
    Write-BoxSep

    $lastS = ''
    foreach ($r in $Script:Results) {
        # Separateur de section
        if ($r.Sec -ne $lastS -and $r.Sec -ne '') {
            Write-BoxSectionSep $r.Sec
            $lastS = $r.Sec
        }
        Write-BoxDetailLigne $r.Op $(if($r.Data){$r.Data}else{''}) $r.St
    }
    Write-BoxBot
}

# ════════════════════════════════════════════════════════════════
#  SELFTEST  (verification interne - aucune modification systeme)
# ════════════════════════════════════════════════════════════════

function Test-Assertion {
    param([string]$Nom, [scriptblock]$Bloc, [string]$Cat = 'General')
    $Script:TestTotal++
    try {
        $ok = & $Bloc
        if ($ok) {
            $Script:TestPass++
            $Script:TestResults.Add([PSCustomObject]@{ Nom=$Nom; Cat=$Cat; St='PASS'; Det='' })
            Write-EtapeLigne $Nom 'OK' 'OK'
            Write-Log "SelfTest OK : $Nom" 'OK'
        } else {
            $Script:TestFail++
            $Script:TestResults.Add([PSCustomObject]@{ Nom=$Nom; Cat=$Cat; St='FAIL'; Det='Condition non satisfaite' })
            Write-EtapeLigne $Nom 'Condition non satisfaite' 'ERROR'
            Write-Log "SelfTest FAIL : $Nom - condition non satisfaite" 'ERROR'
        }
    } catch {
        $Script:TestFail++
        $e = $_.Exception.Message
        $Script:TestResults.Add([PSCustomObject]@{ Nom=$Nom; Cat=$Cat; St='FAIL'; Det=$e })
        Write-EtapeLigne $Nom "Exception : $e" 'ERROR'
        Write-Log "SelfTest FAIL : $Nom - $e" 'ERROR'
    }
}

function Invoke-SelfTest {
    wc ""
    Write-BoxTop
    Write-BoxTitle "  SPICY CHECK V$($Script:Version) - SELFTEST  " Cyan
    Write-BoxSep
    Write-BoxLine "  Verification interne des fonctions, cmdlets et binaires." White
    Write-BoxLine "  Aucune modification systeme n est effectuee." White
    Write-BoxBot
    wc ""

    # ── Fonctions utilitaires ────────────────────────────────────
    wc "    -- UTILITAIRES $('-' * 63)" DarkGray
    Test-Assertion 'New-Bar : longueur correcte'      { (New-Bar 50 20).Length -eq 20 } 'Utilitaires'
    Test-Assertion 'New-Bar : 0% -> barre vide'        { (New-Bar 0 10) -eq ('░' * 10) } 'Utilitaires'
    Test-Assertion 'New-Bar : 100% -> barre pleine'    { (New-Bar 100 10) -eq ('█' * 10) } 'Utilitaires'
    Test-Assertion 'Get-Taille : chemin inexistant -> 0' { (Get-Taille 'Z:\Chemin_Inexistant_SelfTest') -eq 0 } 'Utilitaires'
    Test-Assertion 'Add-Result : ajoute une entree' {
        $avant = $Script:Results.Count
        Add-Result 'SelfTest_AddResult' 'OK' 'test' 'SelfTest'
        $Script:Results.Count -eq ($avant + 1)
    } 'Utilitaires'
    Test-Assertion 'Add-Sante : ajoute une entree' {
        $avant = $Script:Sante.Count
        Add-Sante 'SelfTest_Comp' '1' 'BON' ''
        $Script:Sante.Count -eq ($avant + 1)
    } 'Utilitaires'
    Test-Assertion 'Write-Log : ecrit dans le fichier log' {
        Write-Log 'Ligne de test SelfTest' 'INFO'
        Test-Path $Script:LogFile
    } 'Utilitaires'
    Test-Assertion 'Invoke-Etape : capture un succes (St=OK)' {
        Invoke-Etape 'SelfTest_Succes' 'Test succes' 'SelfTest' { 'Resultat simule' }
        $Script:Results[$Script:Results.Count - 1].St -eq 'OK'
    } 'Utilitaires'
    Test-Assertion 'Invoke-Etape : capture une erreur (St=ERROR)' {
        Invoke-Etape 'SelfTest_Erreur' 'Test erreur' 'SelfTest' { throw 'Erreur simulee SelfTest' }
        $Script:Results[$Script:Results.Count - 1].St -eq 'ERROR'
    } 'Utilitaires'

    # ── Detection disque ─────────────────────────────────────────
    wc ""
    wc "    -- DETECTION DISQUE $('-' * 56)" DarkGray
    Test-Assertion 'Get-TypeDisque(C) : retourne une valeur valide' {
        (Get-TypeDisque 'C') -in @('SSD', 'HDD', 'Inconnu')
    } 'Disque'

    # ── Binaires externes requis ─────────────────────────────────
    wc ""
    wc "    -- BINAIRES EXTERNES $('-' * 54)" DarkGray
    foreach ($bin in 'dism', 'sfc', 'bcdedit', 'defrag', 'ipconfig') {
        Test-Assertion "Binaire disponible : $bin" { [bool](Get-Command $bin -EA SilentlyContinue) } 'Binaires'
    }

    # ── Cmdlets PowerShell requis ────────────────────────────────
    wc ""
    wc "    -- CMDLETS POWERSHELL $('-' * 53)" DarkGray
    foreach ($cmd in 'Get-Volume', 'Get-PhysicalDisk', 'Get-Partition', 'Get-Disk',
                     'Get-NetAdapter', 'Get-NetIPAddress', 'Get-NetRoute', 'Optimize-Volume',
                     'Clear-RecycleBin', 'Get-CimInstance', 'Get-WinEvent', 'ConvertTo-Json') {
        Test-Assertion "Cmdlet disponible : $cmd" { [bool](Get-Command $cmd -EA SilentlyContinue) } 'Cmdlets'
    }

    # ── Classes CIM/WMI interrogeables ───────────────────────────
    wc ""
    wc "    -- CLASSES CIM / WMI $('-' * 55)" DarkGray
    foreach ($cls in 'Win32_Processor', 'Win32_OperatingSystem', 'Win32_PageFileUsage',
                     'Win32_VideoController', 'Win32_DiskDrive', 'Win32_Battery') {
        Test-Assertion "Classe interrogeable : $cls" {
            try { Get-CimInstance $cls -EA Stop | Out-Null; $true } catch { $false }
        } 'CIM'
    }

    # ── Systeme de fichiers ──────────────────────────────────────
    wc ""
    wc "    -- SYSTEME DE FICHIERS $('-' * 52)" DarkGray
    Test-Assertion 'Dossier rapports accessible en ecriture' {
        $tmp = Join-Path $Script:Root ("selftest_" + [guid]::NewGuid().ToString('N') + '.tmp')
        'test' | Out-File $tmp -Encoding UTF8 -EA Stop
        $existe = Test-Path $tmp
        Remove-Item $tmp -Force -EA SilentlyContinue
        $existe
    } 'FileSystem'
    Test-Assertion 'ConvertTo-Json fonctionne correctement' {
        $o = [PSCustomObject]@{ a = 1; b = 'test' }
        ($o | ConvertTo-Json) -match '"a"\s*:\s*1'
    } 'FileSystem'

    # ── Droits d execution ────────────────────────────────────────
    wc ""
    wc "    -- DROITS D EXECUTION $('-' * 53)" DarkGray
    Test-Assertion 'Session PowerShell elevee (Administrateur)' {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } 'Droits'

    # ── Resume ────────────────────────────────────────────────────
    $pct = if ($Script:TestTotal -gt 0) { [math]::Round($Script:TestPass / $Script:TestTotal * 100) } else { 0 }
    $bgSc = if ($Script:TestFail -eq 0) { 'DarkGreen' } else { 'DarkRed' }
    $fcSc = if ($Script:TestFail -eq 0) { 'Green' } else { 'Red' }

    wc ""
    Write-BoxTop
    Write-BoxTitle "  RESULTAT SELFTEST  " Cyan
    Write-BoxSep
    Write-BoxLine "  Tests executes  :  $Script:TestTotal" White
    Write-BoxLine "  Reussis  [OK]   :  $Script:TestPass" Green
    if ($Script:TestFail -gt 0) { Write-BoxLine "  Echecs   [XX]   :  $Script:TestFail" Red }
    Write-BoxEmpty
    $pfx = "  Score  :  "
    $sfx = "  $($Script:TestPass)/$($Script:TestTotal) ($pct%)  "
    $rp  = [math]::Max(0, $Script:W - 2 - $pfx.Length - $sfx.Length)
    wc "  ║  $pfx" White -n
    Write-Host $sfx -ForegroundColor White -BackgroundColor $bgSc -NoNewline
    wc "$(' ' * $rp)║" Cyan
    Write-BoxBot

    Write-Log "SelfTest termine : $($Script:TestPass)/$($Script:TestTotal) reussis" $(if($Script:TestFail -eq 0){'OK'}else{'ERROR'})
}

# ════════════════════════════════════════════════════════════════
#  EXECUTION PRINCIPALE
# ════════════════════════════════════════════════════════════════

trap {
    $msg = "ERREUR FATALE ligne $($_.InvocationInfo.ScriptLineNumber) : $($_.Exception.Message)"
    try { $msg | Out-File $Script:ErrFile -Encoding UTF8 -Append } catch {}
    try { Write-Log $msg 'ERROR' } catch {}
    Write-Host "`n  $msg" -ForegroundColor Red
    Write-Host "`n  Appuyez sur ENTREE pour fermer..." -ForegroundColor Yellow
    Read-Host
    continue
}

# ── Mode SelfTest : verification interne puis sortie ────────────
if ($SelfTest) {
    Invoke-SelfTest
    exit $(if ($Script:TestFail -gt 0) { 1 } else { 0 })
}

# Nombre d etapes
$Script:TotalSteps = 3  # SysInfo + Sante + Rapport
if (-not $SauterNettoyage)    { $Script:TotalSteps++ }
if (-not $SauterReparation)   { $Script:TotalSteps++ }
if (-not $SauterOptimisation) { $Script:TotalSteps++ }

Write-Log "=== MAINTENANCE WINDOWS 11 V$($Script:Version) ===" 'INFO'

# 1 ─ Banniere
Write-Banner

# 2 ─ Informations systeme (style fastfetch)
$Script:CurrentStep++
Write-SysInfo

# 3 ─ Diagnostic de sante
Write-DiagSante

# 4 ─ Nettoyage
if (-not $SauterNettoyage) { Start-Nettoyage }
else {
    Write-EtapeLigne 'Nettoyage' 'Ignore par parametre' 'SKIP'
    Add-Result 'Nettoyage' 'SKIP' 'SauterNettoyage active' 'Nettoyage'
}

# 5 ─ Reparation
if (-not $SauterReparation) { Start-Reparation }
else {
    Write-EtapeLigne 'Reparation' 'Ignoree par parametre' 'SKIP'
    Add-Result 'Reparation' 'SKIP' 'SauterReparation active' 'Reparation'
}

# 6 ─ Optimisation
if (-not $SauterOptimisation) { Start-Optimisation }
else {
    Write-EtapeLigne 'Optimisation' 'Ignoree par parametre' 'SKIP'
    Add-Result 'Optimisation' 'SKIP' 'SauterOptimisation active' 'Optimisation'
}

# 7 ─ Rapport HTML
Write-Section 'GENERATION DES RAPPORTS' '◈'
Write-Log 'Generation rapport HTML' 'INFO'
try {
    $Script:ReportPath = New-RapportHTML
    Write-EtapeLigne 'Rapport HTML' 'Genere avec succes' 'OK'
    Write-Log "Rapport : $($Script:ReportPath)" 'OK'
    Add-Result 'RapportHTML' 'OK' $Script:ReportPath 'Rapport'
} catch {
    $e = $_.Exception.Message
    Write-EtapeLigne 'Rapport HTML' "ERREUR : $e" 'ERROR'
    Write-Log "Rapport ERREUR : $e" 'ERROR'
    Add-Result 'RapportHTML' 'ERROR' $e 'Rapport'
}

if ($ExportJSON) {
    try {
        $jp = Join-Path $Script:Root ("rapport_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".json")
        $Script:Results | ConvertTo-Json -Depth 5 | Out-File $jp -Encoding UTF8
        Write-EtapeLigne 'Export JSON' $jp 'OK'
        Write-Log "JSON : $jp" 'OK'
    } catch {}
}

Write-Log "=== FIN $('{0:mm}m {0:ss}s' -f ((Get-Date)-$Script:StartTime)) ===" 'OK'

# 8 ─ Resume + pause
if (-not $Silent) {
    Write-Resume

    if ($Script:ReportPath -and (Test-Path $Script:ReportPath)) {
        wc "  Rapport HTML : $($Script:ReportPath)" Cyan
        wc ""
        $r = Read-Host "  Ouvrir dans le navigateur ? [O/n]"
        if ($r -eq '' -or $r -match '^[Oo]') { Start-Process $Script:ReportPath }
    }

    wc ""
    Write-BoxTop
    Write-BoxLine "  Appuyez sur ENTREE pour fermer cette fenetre..." Yellow
    Write-BoxBot
    Read-Host
}


# SIG # Begin signature block
# MIIFwgYJKoZIhvcNAQcCoIIFszCCBa8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBkJl/z2PjO0rhI
# GZiPqLNIcXSPee91sC9dD6C3yY/ymqCCAygwggMkMIICDKADAgECAhB6X4r8AlBU
# p0MV3JpMuQ6sMA0GCSqGSIb3DQEBCwUAMCoxKDAmBgNVBAMMH05lcGhyZW4gUG93
# ZXJTaGVsbCBDb2RlIFNpZ25pbmcwHhcNMjYwNzA0MDIzMzIwWhcNMzEwNzA0MDI0
# MzIwWjAqMSgwJgYDVQQDDB9OZXBocmVuIFBvd2VyU2hlbGwgQ29kZSBTaWduaW5n
# MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1JnV5AocUnAMNIG3nYF9
# 5mOQz5NzMYJqc9D6mq3pjRlmuYIgvYEuJL5dvt8eoAiUKd+XHTaY5wl+zt7LUon+
# TmEldVwfrYvROpI+5TDyBRc5BzY4uACsA4JUM4ienjX04BBKT3uH6JwHzBluWqcG
# Xrg16NqzDiae7WNzVrev+BME00mgSvBo3hKp3sHIvFQaAmjGXLyJd+llfnBpmoD9
# JnOxMKO7VFIlhAz5cEUnFu/xDLHgARdBUfXA5odScWKiDvygNZsH1vHo07Oo7pDK
# awR3bT6lcXWRXSUmawgE1mZra+b9qpeNol+5J+86zN83RccBKZBUtQQoyy+cv20x
# VQIDAQABo0YwRDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwMw
# HQYDVR0OBBYEFNxVaDYoNv8UXQWnbtEy/DTaQHjYMA0GCSqGSIb3DQEBCwUAA4IB
# AQCE4NqZbeximmbNEORyLxvIYiMQwP59B9R95blQQ/zugPSt4wab61yBbgO1E3mH
# mUdN0fCHhN/u0uB7h7ZBYw1w4hnzoiBac4UYzsXH4/D41gBjutbtDllRy6/zs3dl
# /hbbHAmwKXdjNVLG9cPkpWlkvKR1DJLMugU2uj+S6k+U7DfHo76sbAKqiu3biXtd
# mao6PP99EU7JBYZjsJ+BsnYcZ2KcnZ8TKiRuhSXoxAyPman7Z0BVo1H2O+fxd96b
# 4W8VclmpFh7T2CyRAHolwEy5coFYyueisO0PZg+nKwXr66+m1T1CBLQYwh79/SKO
# wGUJyU5RtTryD+hfLwkTQKVCMYIB8DCCAewCAQEwPjAqMSgwJgYDVQQDDB9OZXBo
# cmVuIFBvd2VyU2hlbGwgQ29kZSBTaWduaW5nAhB6X4r8AlBUp0MV3JpMuQ6sMA0G
# CWCGSAFlAwQCAQUAoIGEMBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZI
# hvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcC
# ARUwLwYJKoZIhvcNAQkEMSIEIFHCN+YGbka3GanoNXIg332juWN0gZZebynTCBqE
# 08LJMA0GCSqGSIb3DQEBAQUABIIBALt6M1QG4DUq6X2oc1eXBlETqh+V4UWcv0yw
# 84AISBg7AmlFN/mWKBKEGbHP2b9KSL5/e9tES59UBNzAO+2ICy1KUiEQ0pEGrJAB
# 4I13w/E0x6NItNxB17DRc3gKsXGQskrz1FgVZj8QR77AtxgyhpJuCr3F53RgPLT8
# cCW/GCahsyJybrtfmA7FroR03PzLbxoTUtIV4GIPsSEGjL9FMYQOhnrUdKji65vi
# heChdo4mCc6rEflYhfb2a2Wbc974ZP+5cwQLNlzxbbvxzNDv+WlD03V2BRt5WDW5
# vJ291xLa2UKVP908HOXMHQTMHsd36krordRQaGgbduM94VwSKIE=
# SIG # End signature block
