#Requires -Version 5.1
<#
    Optimiseur Windows
    - Onglet 1 : nettoyage du disque, confidentialité et réglages de performance.
    - Onglet 2 : choix des applications et programmes à désinstaller.
    - Onglet 3 : choix des programmes lancés au démarrage et des applis autorisées en arrière-plan.
    Chaque action est optionnelle et un point de restauration est créé avant.
#>

# ---------------------------------------------------------------- Élévation
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$LogFile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("OptimiseurWindows_{0:yyyy-MM-dd_HH-mm}.log" -f (Get-Date))
$Sys     = $env:SystemDrive
$WinDir  = $env:windir
$Lad     = $env:LOCALAPPDATA
$script:Busy        = $false
$script:RestoreDone = $false
$script:AppRows     = $null
$script:BgRows      = $null
$script:Provisioned = @()

# ---------------------------------------------------------------- Utilitaires
function Write-Log([string]$Message) {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
    $LogBox.AppendText($line + [Environment]::NewLine)
    Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    [System.Windows.Forms.Application]::DoEvents()
}

function Format-Size([double]$Bytes) {
    if     ($Bytes -ge 1GB) { '{0:N2} Go' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N0} Mo' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0} Ko' -f ($Bytes / 1KB) }
    else                    { "$Bytes o" }
}

function Get-FreeSpace { (New-Object System.IO.DriveInfo($Sys)).AvailableFreeSpace }

function Get-PathSize([string[]]$Paths) {
    $Paths = @($Paths | Where-Object { $_ })
    if (-not $Paths) { return 0L }
    $total = 0L
    foreach ($item in Get-Item -Path $Paths -Force -ErrorAction SilentlyContinue) {
        if ($item -is [System.IO.DirectoryInfo]) {
            $s = (Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum).Sum
        } else { $s = $item.Length }
        if ($s) { $total += $s }
    }
    $total
}

# Suppression récursive qui ne suit jamais les jonctions/liens symboliques
# et ignore les fichiers verrouillés au lieu de s'arrêter.
function Remove-Contents([System.IO.DirectoryInfo]$Dir) {
    try { $entries = $Dir.GetFileSystemInfos() } catch { return }
    foreach ($e in $entries) {
        try {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $e.Delete(); continue }
            if ($e -is [System.IO.DirectoryInfo]) { Remove-Contents $e; $e.Delete() }
            else { $e.Attributes = 'Normal'; $e.Delete() }
        } catch {}
    }
}

function Clear-Paths([string[]]$Paths) {
    $Paths = @($Paths | Where-Object { $_ })
    if (-not $Paths) { return }
    foreach ($item in Get-Item -Path $Paths -Force -ErrorAction SilentlyContinue) {
        if ($item.FullName.TrimEnd('\').Length -le 3) { continue }   # jamais une racine de disque
        if ($item -is [System.IO.DirectoryInfo]) { Remove-Contents $item }
        else { try { $item.Attributes = 'Normal'; $item.Delete() } catch {} }
    }
}

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
    } catch { Write-Log "   ! réglage ignoré : $Path\$Name" }
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Disable-Svc([string[]]$Names) {
    foreach ($n in $Names) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $s) { continue }
        Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
        try { Set-Service -Name $n -StartupType Disabled -ErrorAction Stop; Write-Log "   - service désactivé : $n" }
        catch { Write-Log "   ! service $n : $($_.Exception.Message)" }
    }
}

# Lance un programme externe et attend sa fin sans figer la fenêtre.
function Start-Waiting([string]$File, [string]$Arguments, [string]$Style = 'Hidden') {
    $params = @{ FilePath = $File; WindowStyle = $Style; PassThru = $true }
    if ($Arguments) { $params.ArgumentList = $Arguments }
    $p = Start-Process @params
    $null = $p.Handle
    while (-not $p.HasExited) { Start-Sleep -Milliseconds 250; [System.Windows.Forms.Application]::DoEvents() }
    $p.ExitCode
}

# Sépare "C:\chemin\prog.exe" /args en programme + arguments.
function Split-Command([string]$Command) {
    $c = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    if ($c -match '^"([^"]+)"\s*(.*)$')    { return $Matches[1], $Matches[2] }
    if ($c -match '^(.+?\.exe)\s*(.*)$')   { return $Matches[1], $Matches[2] }
    if ($c -match '^(\S+)\s*(.*)$')        { return $Matches[1], $Matches[2] }   # ex. "winget uninstall ..."
    return $c, ''
}

function Test-Like([string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    $false
}

# Nom lisible des applis du Store (PackageFamilyName -> nom du menu Démarrer)
function Get-StartAppNames {
    $map = @{}
    foreach ($s in Get-StartApps -ErrorAction SilentlyContinue) {
        if ($s.AppID -match '^([^!\\]+_[a-z0-9]{13})!' -and -not $map.ContainsKey($Matches[1])) { $map[$Matches[1]] = $s.Name }
    }
    $map
}

# ---------------------------------------------------------------- Onglet 1 : actions
$Tasks = New-Object System.Collections.Generic.List[object]
function Add-Task {
    param($Group, $Name, $Desc, [bool]$Default, [scriptblock]$Run, [scriptblock]$Size)
    $Tasks.Add([pscustomobject]@{
        Group = $Group; Name = $Name; Desc = $Desc; Default = $Default; Run = $Run; Size = $Size
        SizeBytes = 0L; Unavailable = $false
    })
}

# --- Nettoyage du disque
$TempPaths = @($env:TEMP, "$WinDir\Temp")
Add-Task 'clean' 'Fichiers temporaires' "Vide les dossiers TEMP de l'utilisateur et de Windows (les fichiers en cours d'utilisation sont ignorés)." $true `
    -Size { Get-PathSize $TempPaths } -Run { Clear-Paths $TempPaths }

$WUPath = "$WinDir\SoftwareDistribution\Download"
Add-Task 'clean' 'Cache de Windows Update' 'Supprime les mises à jour déjà installées et téléchargées. Windows les retélécharge si besoin.' $true `
    -Size { Get-PathSize $WUPath } -Run {
        Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        Clear-Paths $WUPath
        Start-Service bits, wuauserv -ErrorAction SilentlyContinue
    }

Add-Task 'clean' "Cache d'optimisation de la distribution" 'Fichiers de mises à jour partagés en pair-à-pair.' $true `
    -Size { Get-PathSize "$WinDir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache", "$WinDir\SoftwareDistribution\DeliveryOptimization" } `
    -Run { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue }

$WerPaths = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
              "$WinDir\Minidump", "$WinDir\MEMORY.DMP", "$Lad\CrashDumps")
Add-Task 'clean' "Rapports d'erreurs et vidages mémoire" 'Rapports de plantage et fichiers .dmp, inutiles sauf pour un diagnostic.' $true `
    -Size { Get-PathSize $WerPaths } -Run { Clear-Paths $WerPaths }

$ThumbPaths = @("$Lad\Microsoft\Windows\Explorer\thumbcache_*.db", "$Lad\Microsoft\Windows\Explorer\iconcache_*.db")
Add-Task 'clean' 'Cache des miniatures' "Aperçus d'images/vidéos, recréés automatiquement." $true `
    -Size { Get-PathSize $ThumbPaths } -Run { Clear-Paths $ThumbPaths }

$BrowserCaches = @(
    "$Lad\Microsoft\Edge\User Data\*\Cache", "$Lad\Microsoft\Edge\User Data\*\Code Cache", "$Lad\Microsoft\Edge\User Data\*\GPUCache",
    "$Lad\Google\Chrome\User Data\*\Cache", "$Lad\Google\Chrome\User Data\*\Code Cache", "$Lad\Google\Chrome\User Data\*\GPUCache",
    "$Lad\BraveSoftware\Brave-Browser\User Data\*\Cache", "$Lad\BraveSoftware\Brave-Browser\User Data\*\Code Cache",
    "$Lad\Vivaldi\User Data\*\Cache", "$Lad\Opera Software\Opera Stable\Cache", "$Lad\Opera Software\Opera GX Stable\Cache",
    "$Lad\Mozilla\Firefox\Profiles\*\cache2")
Add-Task 'clean' 'Cache des navigateurs (Edge, Chrome, Brave, Opera, Vivaldi, Firefox)' 'Fermez vos navigateurs avant. Mots de passe, favoris et connexions sont conservés.' $true `
    -Size { Get-PathSize $BrowserCaches } -Run { Clear-Paths $BrowserCaches }

$AppCaches = @(
    "$env:APPDATA\discord\Cache", "$env:APPDATA\discord\Code Cache", "$env:APPDATA\discord\GPUCache",
    "$Lad\Spotify\Data", "$Lad\Steam\htmlcache",
    "$Lad\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache",
    "$Lad\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Code Cache")
Add-Task 'clean' 'Cache des applications (Discord, Spotify, Steam, Teams)' 'Fermez ces applications avant. Les musiques téléchargées et les connexions sont conservées.' $true `
    -Size { Get-PathSize $AppCaches } -Run { Clear-Paths $AppCaches }

$ShaderCaches = @("$Lad\D3DSCache", "$Lad\NVIDIA\DXCache", "$Lad\NVIDIA\GLCache", "$Lad\AMD\DxCache", "$Lad\AMD\DxcCache", "$Lad\AMD\GLCache")
Add-Task 'clean' 'Cache des shaders (cartes graphiques)' 'Recréé automatiquement. Utile si un jeu saccade après une mise à jour du pilote ; les premiers lancements seront un peu plus lents.' $false `
    -Size { Get-PathSize $ShaderCaches } -Run { Clear-Paths $ShaderCaches }

$LogPaths = @("$WinDir\Logs\CBS\*.log", "$WinDir\Logs\CBS\*.cab", "$WinDir\Logs\DISM\*.log", "$WinDir\Logs\MeasuredBoot\*.log")
Add-Task 'clean' 'Anciens journaux de Windows' "Fichiers .log des mises à jour et réparations, qui grossissent avec le temps." $true `
    -Size { Get-PathSize $LogPaths } -Run { Clear-Paths $LogPaths }

$DriverInstallers = @("$env:ProgramData\NVIDIA Corporation\Downloader", "$Sys\AMD")
Add-Task 'clean' 'Anciens installateurs de pilotes (NVIDIA, AMD)' 'Pilotes graphiques déjà installés, gardés en double sur le disque. Les pilotes en place ne sont pas touchés.' $true `
    -Size { Get-PathSize $DriverInstallers } -Run { Clear-Paths $DriverInstallers }

Add-Task 'clean' 'Stockage réservé de Windows' "Windows garde environ 7 Go pour ses mises à jour. Les libérer donne de la place, mais une grosse mise à jour pourra demander de faire de la place à ce moment-là." $false `
    -Run {
        $code = Start-Waiting "$WinDir\System32\Dism.exe" '/Online /Set-ReservedStorageState /State:Disabled'
        Write-Log "   code de sortie DISM : $code"
    }

Add-Task 'clean' 'Vider la corbeille' 'Supprime définitivement le contenu de la corbeille.' $false `
    -Size { Get-PathSize (Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root '$Recycle.Bin' }) } `
    -Run { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }

Add-Task 'clean' 'Nettoyage des composants Windows (WinSxS)' 'Retire les anciennes versions des composants mis à jour (DISM). Souvent plusieurs Go. Dure 5 à 20 min.' $true `
    -Run {
        Write-Log '   (DISM en cours, cela peut prendre plusieurs minutes...)'
        $code = Start-Waiting "$WinDir\System32\Dism.exe" '/Online /Cleanup-Image /StartComponentCleanup /NoRestart'
        Write-Log "   code de sortie DISM : $code"
    }

Add-Task 'clean' 'Ancienne installation de Windows (Windows.old)' "Libère beaucoup de place, mais empêche de revenir à la version précédente de Windows." $false `
    -Size { if (Test-Path "$Sys\Windows.old") { Get-PathSize "$Sys\Windows.old" } else { -1 } } `
    -Run {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        foreach ($n in 'Previous Installations', 'Temporary Setup Files', 'Windows Upgrade Log Files') {
            if (Test-Path "$key\$n") { Set-Reg "$key\$n" 'StateFlags0042' 2 }
        }
        $null = Start-Waiting "$WinDir\System32\cleanmgr.exe" '/sagerun:42'
    }

Add-Task 'clean' "Activer l'Assistant de stockage" 'Windows supprimera automatiquement les fichiers temporaires chaque semaine.' $true `
    -Run {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        Set-Reg $p '01' 1; Set-Reg $p '04' 1; Set-Reg $p '2048' 7
    }

# --- Confidentialité et publicités
Add-Task 'privacy' 'Réduire la télémétrie' 'Coupe la collecte de données de diagnostic (service DiagTrack, tâches CEIP, demandes de commentaires).' $true -Run {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
    Disable-Svc 'DiagTrack', 'dmwappushservice'
    Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -ErrorAction SilentlyContinue |
        Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser*' -ErrorAction SilentlyContinue |
        Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
}

Add-Task 'privacy' 'Identifiant publicitaire' 'Empêche les applications de vous cibler avec de la publicité personnalisée.' $true -Run {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
}

Add-Task 'privacy' 'Suggestions, pubs et installations automatiques' "Retire les pubs du menu Démarrer et de l'écran de verrouillage, et empêche Windows d'installer des jeux sponsorisés." $true -Run {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in 'SilentInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'PreInstalledAppsEnabled',
                   'OemPreInstalledAppsEnabled', 'RotatingLockScreenOverlayEnabled', 'SubscribedContent-338387Enabled',
                   'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled',
                   'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') { Set-Reg $cdm $n 0 }
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-Reg $adv 'Start_IrisRecommendations' 0
    Set-Reg $adv 'Start_AccountNotifications' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
}

Add-Task 'privacy' 'Recherche Bing dans le menu Démarrer' 'La recherche Windows ne cherche plus sur Internet : plus rapide et plus privée.' $true -Run {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
}

Add-Task 'privacy' 'Widgets (actualités de la barre des tâches)' 'Désactive le panneau Widgets et son processus en arrière-plan.' $true -Run {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
}

Add-Task 'privacy' "Historique d'activités" "Windows n'enregistre plus les applications et fichiers que vous ouvrez." $true -Run {
    $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    Set-Reg $p 'EnableActivityFeed' 0; Set-Reg $p 'PublishUserActivities' 0; Set-Reg $p 'UploadUserActivities' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0
}

Add-Task 'privacy' 'Recall (captures IA de l''écran)' "Désactive l'enregistrement de captures d'écran par l'IA (PC Copilot+)." $true -Run {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
}

Add-Task 'privacy' 'Copilot, « Click to Do » et IA de Paint/Bloc-notes' 'Désactive Copilot dans Windows, retire son bouton, coupe les fonctions IA de Paint et du Bloc-notes et le service IA en arrière-plan.' $true -Run {
    foreach ($root in 'HKLM:\SOFTWARE', 'HKCU:\Software') {
        Set-Reg "$root\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1
        Set-Reg "$root\Policies\Microsoft\Windows\WindowsAI" 'DisableClickToDo' 1
    }
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 1
    $paint = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'
    Set-Reg $paint 'DisableCocreator' 1; Set-Reg $paint 'DisableGenerativeFill' 1; Set-Reg $paint 'DisableImageCreator' 1
    Disable-Svc 'WSAIFabricSvc'
}

Add-Task 'privacy' 'Désactiver la localisation' "Coupe le service de localisation et les mises à jour de cartes. La météo et Cartes ne trouveront plus votre position automatiquement." $false -Run {
    Disable-Svc 'lfsvc'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
    Set-Reg 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' 0
}

Add-Task 'privacy' 'Publicités et suivi dans Edge' "Retire les recommandations, l'assistant d'achat, Microsoft Rewards, l'actualité du nouvel onglet et l'envoi de données de diagnostic." $true -Run {
    $e = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    foreach ($n in 'ShowRecommendationsEnabled', 'EdgeShoppingAssistantEnabled', 'ShowMicrosoftRewards',
                   'PersonalizationReportingEnabled', 'NewTabPageContentEnabled', 'DiagnosticData') { Set-Reg $e $n 0 }
    Set-Reg $e 'HideFirstRunExperience' 1
}

# --- Performances
Add-Task 'perf' 'Capture de jeu en arrière-plan (Game DVR)' "Évite l'enregistrement vidéo permanent pendant les jeux (gain de FPS)." $true -Run {
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
}

Add-Task 'perf' 'Services inutiles' 'Désactive : gestionnaire de cartes, mode démo magasin, télécopie, partage Windows Media Player.' $true -Run {
    Disable-Svc 'MapsBroker', 'RetailDemo', 'Fax', 'WMPNetworkSvc'
}

Add-Task 'perf' 'Edge ne tourne plus en arrière-plan' "Coupe le « démarrage rapide » et l'exécution d'Edge une fois fermé (RAM libérée). Edge affichera « géré par votre organisation » : c'est normal." $true -Run {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
}

Add-Task 'perf' 'Ne plus partager les mises à jour avec d''autres PC' "Windows n'utilise plus votre connexion pour envoyer des mises à jour à des inconnus sur Internet." $true -Run {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
}

Add-Task 'perf' 'Démarrage sans délai des programmes' 'Windows attend normalement une dizaine de secondes avant de lancer les programmes du démarrage.' $true -Run {
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
    Set-Reg $p 'StartupDelayInMSec' 0; Set-Reg $p 'WaitForIdleState' 0
}

Add-Task 'perf' 'Pas d''installation automatique de logiciels de périphériques' "Windows n'installe plus tout seul les applis des souris, claviers, écrans (Razer, Logitech, LG...) quand on les branche." $true -Run {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
    # WPBT : logiciels que le BIOS du fabricant installe tout seul (ex. Armoury Crate, Lenovo Vantage).
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1
}

Add-Task 'perf' 'Priorité aux jeux et au réseau' "Windows donne plus de processeur et de carte graphique aux jeux et ne bride plus le réseau pendant le multimédia." $false -Run {
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    Set-Reg $mm 'SystemResponsiveness' 10
    Set-Reg $mm 'NetworkThrottlingIndex' -1   # 0xFFFFFFFF = pas de bridage
    Set-Reg "$mm\Tasks\Games" 'GPU Priority' 8
    Set-Reg "$mm\Tasks\Games" 'Priority' 6
    Set-Reg "$mm\Tasks\Games" 'Scheduling Category' 'High' 'String'
    Set-Reg "$mm\Tasks\Games" 'SFIO Priority' 'High' 'String'
}

Add-Task 'perf' "Désactiver l'indexation de la recherche" 'Moins de lectures disque en arrière-plan (utile sur disque dur ou PC modeste). La recherche de fichiers sera plus lente.' $false -Run {
    Disable-Svc 'WSearch'
}

Add-Task 'perf' 'Désactiver le démarrage rapide' "« Arrêter » éteint vraiment le PC : évite les bugs qui restent après un arrêt et les soucis de dual-boot. Le démarrage prend quelques secondes de plus." $false -Run {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
}

Add-Task 'perf' 'Menus plus réactifs' "Réduit le délai d'ouverture des menus de 400 à 100 ms." $true -Run {
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
}

Add-Task 'perf' 'Effets visuels réduits' 'Coupe animations et transparence (garde le lissage des polices). Utile sur PC modestes. Après déconnexion.' $false -Run {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
    Set-Reg 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0, 0, 0)) 'Binary'
    Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
    Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Set-Reg 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
}

Add-Task 'perf' "Mode d'alimentation Performances élevées" 'Pour PC fixe. Déconseillé sur portable (batterie).' $false -Run {
    $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    powercfg /setactive $hp | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $out = powercfg /duplicatescheme $hp | Out-String
        if ($out -match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') { powercfg /setactive $Matches[0] | Out-Null }
    }
}

Add-Task 'perf' 'Désactiver la mise en veille prolongée' 'Supprime hiberfil.sys (plusieurs Go). Désactive aussi le démarrage rapide. Déconseillé sur portable.' $false `
    -Size { $f = Get-Item "$Sys\hiberfil.sys" -Force -ErrorAction SilentlyContinue; if ($f) { $f.Length } else { -1 } } `
    -Run { powercfg /hibernate off | Out-Null }

# --- Confort
$Adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Add-Task 'comfort' 'Afficher les extensions de fichiers' 'Montre « .exe », « .pdf »... : plus pratique et évite les pièges (facture.pdf.exe).' $true -Run {
    Set-Reg $Adv 'HideFileExt' 0
}

Add-Task 'comfort' '« Fin de tâche » dans la barre des tâches' "Clic droit sur une appli bloquée dans la barre des tâches → Fin de tâche, sans ouvrir le Gestionnaire." $true -Run {
    Set-Reg "$Adv\TaskbarDeveloperSettings" 'TaskbarEndTask' 1
}

Add-Task 'comfort' 'Désactiver les touches rémanentes' "Coupe les touches rémanentes (et touches filtres / bascule) et leurs raccourcis : plus de fenêtre quand on appuie 5 fois sur Maj ou qu'on garde Maj droite enfoncée." $true -Run {
    $a = 'HKCU:\Control Panel\Accessibility'
    Set-Reg "$a\StickyKeys" 'Flags' '506' 'String'
    Set-Reg "$a\Keyboard Response" 'Flags' '122' 'String'
    Set-Reg "$a\ToggleKeys" 'Flags' '58' 'String'
    # Applique tout de suite (sans redémarrer) : SPI_SETSTICKYKEYS, raccourci et fonction désactivés.
    if (-not ('StickyKeysApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class StickyKeysApi {
    [StructLayout(LayoutKind.Sequential)] public struct STICKYKEYS { public uint cbSize; public uint dwFlags; }
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint action, uint param, ref STICKYKEYS v, uint winIni);
    public static bool Disable() {
        STICKYKEYS s = new STICKYKEYS(); s.cbSize = (uint)Marshal.SizeOf(typeof(STICKYKEYS)); s.dwFlags = 506;
        return SystemParametersInfo(0x003B, s.cbSize, ref s, 3);
    }
}
'@
    }
    [void][StickyKeysApi]::Disable()
}

Add-Task 'comfort' 'Pas de redémarrage forcé après une mise à jour' "Windows attend que vous redémarriez vous-même au lieu de fermer vos programmes pendant que vous êtes connecté." $true -Run {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
}

Add-Task 'comfort' 'Menu clic droit classique (Windows 10)' "Affiche directement toutes les options du clic droit, sans « Afficher plus d'options »." $false -Run {
    Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String'
}

Add-Task 'comfort' "Désactiver l'accélération de la souris" 'Mouvement de la souris plus précis et constant (apprécié en jeu).' $false -Run {
    $p = 'HKCU:\Control Panel\Mouse'
    Set-Reg $p 'MouseSpeed' '0' 'String'; Set-Reg $p 'MouseThreshold1' '0' 'String'; Set-Reg $p 'MouseThreshold2' '0' 'String'
}

Add-Task 'comfort' "L'Explorateur s'ouvre sur « Ce PC »" "Affiche directement vos disques au lieu de l'Accueil et des fichiers récents." $false -Run {
    Set-Reg $Adv 'LaunchTo' 1
}

Add-Task 'comfort' 'Barre des tâches épurée' 'Retire la grande zone de recherche (la touche Windows suffit pour chercher) et le bouton « Affichage des tâches ».' $false -Run {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
    Set-Reg $Adv 'ShowTaskViewButton' 0
}

Add-Task 'comfort' "Retirer « Accueil » et « Galerie » de l'Explorateur" "Panneau de gauche plus simple ; l'Explorateur s'ouvre sur « Ce PC »." $false -Run {
    foreach ($id in '{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}') {
        Set-Reg "HKCU:\Software\Classes\CLSID\$id" 'System.IsPinnedToNameSpaceTree' 0
    }
    Set-Reg $Adv 'LaunchTo' 1
}

Add-Task 'comfort' 'Pavé numérique activé au démarrage' 'Verr. Num est allumé dès l''écran de connexion.' $false -Run {
    Set-Reg 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
}

# ---------------------------------------------------------------- Onglet 2 : applications
# Préinstallées et inutiles pour la plupart des gens : cochées par défaut.
$RecommendedApps = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.Getstarted', 'Microsoft.GetHelp',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.WindowsFeedbackHub', 'Microsoft.MicrosoftOfficeHub', 'Clipchamp.Clipchamp',
    'Microsoft.WindowsMaps', 'Microsoft.People', 'Microsoft.ZuneVideo', 'Microsoft.PowerAutomateDesktop', 'Microsoft.SkypeApp',
    'Microsoft.549981C3F5F10', 'Microsoft.MSPaint', 'Microsoft.Microsoft3DViewer', 'Microsoft.MixedReality.Portal',
    'Microsoft.Windows.DevHome', '*CandyCrush*', '*BubbleWitch*', '*MarchofEmpires*', '*Disney*', '*TikTok*',
    '*Facebook*', '*Instagram*', '*Twitter*', '*LinkedIn*')
# Jamais proposés : leur retrait casse Windows, le Store ou l'affichage des médias.
$ProtectedApps = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
    'Microsoft.Services.Store.Engagement', 'Microsoft.MicrosoftEdge*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.Winget.*', 'Microsoft.VCLibs*',
    'Microsoft.UI.Xaml*', 'Microsoft.NET.*', '*Extension', '*Extensions', 'Microsoft.LanguageExperiencePack*',
    'MicrosoftWindows.Speech.*', 'MicrosoftWindows.Voice.*', 'Microsoft.ApplicationCompatibilityEnhancements',
    'Microsoft.XboxIdentityProvider')

# Paquet "d'intégration" (menu clic droit) installé par un programme classique, déjà listé avec lui.
function Test-SparsePackage($Package) {
    $m = Join-Path ([string]$Package.InstallLocation) 'AppxManifest.xml'
    (Test-Path -LiteralPath $m) -and ((Get-Content -LiteralPath $m -Raw -ErrorAction SilentlyContinue) -match '<(\w+:)?AllowExternalContent>\s*true')
}
$ProtectedPrograms = @('Microsoft Visual C++*', 'Microsoft .NET*', 'Microsoft Windows Desktop Runtime*', 'Microsoft ASP.NET*',
    'Microsoft Edge*', 'Microsoft Update Health Tools', 'Windows Software Development Kit*',
    'Microsoft Windows Application Compatibility*', '*Pilote graphique*', '*Graphics Driver*')
# Lancés au démarrage mais nécessaires (icône de Sécurité Windows)
$ProtectedStartup = @('SecurityHealth')
# Mises à jour de sécurité d'Edge, tâche interne de l'Explorateur, pilote audio Realtek : à garder actives.
$ProtectedTasks = @('MicrosoftEdgeUpdate*', 'CreateExplorerShellUnelevatedTask', 'RtkAud*')

function Import-AppRows {
    Set-Busy $true
    Write-Log 'Recherche des applications installées...'
    $names = Get-StartAppNames
    $script:Provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    $rows = New-Object System.Collections.Generic.List[object]

    $all = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    if (-not $all) { $all = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
    $pkgs = $all | Where-Object {
        -not $_.IsFramework -and -not $_.IsResourcePackage -and -not $_.NonRemovable -and
        $_.SignatureKind -ne 'System' -and -not (Test-Like $_.Name $ProtectedApps) -and -not (Test-SparsePackage $_) }
    foreach ($g in $pkgs | Group-Object Name) {
        $p = $g.Group[0]
        $reco = Test-Like $p.Name $RecommendedApps
        $rows.Add([pscustomobject]@{
            Kind = 'store'; Id = $p.Name; Checked = $false; Group = $(if ($reco) { 'reco' } else { 'store' })
            Name = $(if ($names.ContainsKey($p.PackageFamilyName)) { $names[$p.PackageFamilyName] } else { $p.Name })
            Publisher = ($p.Publisher -replace '^CN=([^,]+).*', '$1'); Packages = @($g.Group)
            Size = Get-PathSize ($g.Group | ForEach-Object { $_.InstallLocation } | Select-Object -Unique)
            Uninstall = $null; Quiet = $null
        })
        [System.Windows.Forms.Application]::DoEvents()
    }

    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $seen = @{}
    foreach ($e in Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue) {
        if (-not $e.DisplayName -or -not $e.UninstallString -or $e.SystemComponent -eq 1 -or $e.ParentKeyName -or
            $e.ReleaseType -in 'Update', 'Hotfix', 'Security Update') { continue }
        if ($seen.ContainsKey($e.DisplayName) -or (Test-Like $e.DisplayName $ProtectedPrograms)) { continue }
        $seen[$e.DisplayName] = $true
        $rows.Add([pscustomobject]@{
            Kind = 'win32'; Id = $e.PSChildName; Checked = $false; Group = 'win32'
            Name = $e.DisplayName.Trim(); Publisher = $e.Publisher; Packages = @()
            Size = $(if ($e.EstimatedSize) { [long]$e.EstimatedSize * 1KB } else { -1L })
            Uninstall = $e.UninstallString; Quiet = $e.QuietUninstallString
        })
    }

    $script:AppRows = @($rows | Sort-Object Name)
    Show-AppRows
    Write-Log "$($script:AppRows.Count) applications trouvées. Les recommandées sont déjà cochées."
    Set-Busy $false
}

function Show-AppRows {
    $filter = [System.Management.Automation.WildcardPattern]::Escape($appFilter.Text.Trim())
    $appList.BeginUpdate()
    $appList.Items.Clear()
    foreach ($r in $script:AppRows) {
        if ($filter -and $r.Name -notlike "*$filter*" -and $r.Publisher -notlike "*$filter*") { continue }
        $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
        [void]$it.SubItems.Add($(if ($r.Kind -eq 'store') { 'Microsoft Store' } else { 'Programme' }))
        [void]$it.SubItems.Add($(if ($r.Size -ge 0) { Format-Size $r.Size } else { '-' }))
        [void]$it.SubItems.Add([string]$r.Publisher)
        $it.Group = $appList.Groups[$r.Group]; $it.Tag = $r; $it.Checked = $r.Checked
        [void]$appList.Items.Add($it)
    }
    $appList.EndUpdate()
    Update-AppCount
}

function Update-AppCount {
    $sel = @($script:AppRows | Where-Object Checked)
    $size = 0L; foreach ($r in $sel) { if ($r.Size -gt 0) { $size += $r.Size } }
    $appCount.Text = "$($sel.Count) application(s) cochée(s) - environ $(Format-Size $size)"
}

function Uninstall-AppRow($Row) {
    if ($Row.Kind -eq 'store') {
        # Une erreur sur une ancienne version ne doit pas empêcher de retirer les autres : on vérifie à la fin.
        foreach ($p in $Row.Packages | Sort-Object PackageFullName -Unique) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
            catch { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction SilentlyContinue }
        }
        if (Get-AppxPackage -AllUsers -Name $Row.Id -ErrorAction SilentlyContinue) { throw "Windows a refusé de retirer $($Row.Id)" }
        # Empêche la réinstallation automatique pour les nouveaux comptes
        foreach ($p in $script:Provisioned | Where-Object DisplayName -eq $Row.Id) {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
        return
    }
    $cmd = if ($Row.Quiet) { $Row.Quiet } else { $Row.Uninstall }
    if ($cmd -match 'msiexec' -and $cmd -match '\{[0-9a-f-]{36}\}') {
        $code = Start-Waiting 'msiexec.exe' "/x $($Matches[0]) /qb /norestart" 'Normal'
    } else {
        Write-Log "   (suivez l'assistant de désinstallation qui s'ouvre)"
        $exe, $arg = Split-Command $cmd
        $code = Start-Waiting $exe $arg 'Normal'
    }
    if ($code -notin 0, 1605, 3010) { throw "le désinstalleur a renvoyé le code $code" }
}

# ---------------------------------------------------------------- Onglet 3 : démarrage et arrière-plan
# Même mécanisme que le Gestionnaire des tâches : réversible, rien n'est supprimé.
$ApprovedBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$StartupSources = @(
    @{ Kind = 'reg';    Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKCU:\$ApprovedBase\Run";           Label = 'Démarrage (utilisateur)' }
    @{ Kind = 'reg';    Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKLM:\$ApprovedBase\Run";           Label = 'Démarrage (tous les comptes)' }
    @{ Kind = 'reg';    Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$ApprovedBase\Run32";         Label = 'Démarrage (32 bits)' }
    @{ Kind = 'folder'; Path = [Environment]::GetFolderPath('Startup');                          Approved = "HKCU:\$ApprovedBase\StartupFolder"; Label = 'Dossier Démarrage' }
    @{ Kind = 'folder'; Path = [Environment]::GetFolderPath('CommonStartup');                    Approved = "HKLM:\$ApprovedBase\StartupFolder"; Label = 'Dossier Démarrage (tous)' }
)
$StoreTasksKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
$BgKey         = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
$BgPolicy      = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$BgDenyList    = 'LetAppsRunInBackground_ForceDenyTheseApps'

function Import-BgRows {
    Set-Busy $true
    Write-Log 'Recherche des programmes au démarrage et des applis en arrière-plan...'
    $names = Get-StartAppNames
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($src in $StartupSources) {
        if (-not $src.Path -or -not (Test-Path -LiteralPath $src.Path)) { continue }
        $entries = @()
        if ($src.Kind -eq 'reg') {
            $key = Get-Item -LiteralPath $src.Path
            foreach ($n in $key.GetValueNames()) { if ($n) { $entries += , @($n, [string]$key.GetValue($n)) } }
        } else {
            foreach ($f in Get-ChildItem -LiteralPath $src.Path -File -Force -ErrorAction SilentlyContinue) {
                if ($f.Name -ne 'desktop.ini') { $entries += , @($f.Name, $f.FullName) }
            }
        }
        foreach ($e in $entries) {
            if ($e[0] -in $ProtectedStartup) { continue }
            $b = Get-RegValue $src.Approved $e[0]
            $rows.Add([pscustomobject]@{
                Kind = 'startup'; Group = 'startup'; Name = ($e[0] -replace '\.lnk$', ''); Type = $src.Label; Detail = $e[1]
                ValueName = $e[0]; Approved = $src.Approved; Disabled = [bool](($b -is [byte[]]) -and ($b[0] -band 1)); Checked = $false
            })
        }
    }

    foreach ($pk in Get-ChildItem -LiteralPath $StoreTasksKey -ErrorAction SilentlyContinue) {
        foreach ($t in Get-ChildItem -LiteralPath $pk.PSPath -ErrorAction SilentlyContinue) {
            $state = $t.GetValue('State')
            if ($null -eq $state) { continue }
            $pfn = $pk.PSChildName
            $rows.Add([pscustomobject]@{
                Kind = 'storetask'; Group = 'startup'; Type = 'Démarrage (app du Store)'; Detail = $t.PSChildName
                Name = $(if ($names.ContainsKey($pfn)) { $names[$pfn] } else { $pfn -replace '_[a-z0-9]{13}$', '' })
                RegPath = $t.PSPath; Disabled = ($state -notin 2, 4); Checked = $false
            })
        }
    }

    # Tâches planifiées des autres éditeurs (programmes de mise à jour, assistants...)
    $schTasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and -not (Test-Like $_.TaskName $ProtectedTasks) }
    foreach ($t in $schTasks) {
        $exec = @($t.Actions | ForEach-Object { $_.Execute } | Where-Object { $_ }) -join ' ; '
        $rows.Add([pscustomobject]@{
            Kind = 'task'; Group = 'task'; Name = $t.TaskName; Type = 'Tâche planifiée'; Detail = $(if ($exec) { $exec } else { $t.TaskPath })
            TaskName = $t.TaskName; TaskPath = $t.TaskPath; Disabled = ($t.State -eq 'Disabled'); Checked = $false
        })
    }

    $deny   = @(Get-RegValue $BgPolicy $BgDenyList)
    $global = Get-RegValue $BgPolicy 'LetAppsRunInBackground'
    if ($global -eq 2) { Write-Log '   Note : une stratégie bloque déjà toutes les applis du Store en arrière-plan.' }
    $userApps = Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' -and $names.ContainsKey($_.PackageFamilyName) -and
                       -not (Test-Like $_.Name $ProtectedApps) } |
        Sort-Object PackageFamilyName -Unique
    foreach ($p in $userApps) {
        $pfn = $p.PackageFamilyName
        $rows.Add([pscustomobject]@{
            Kind = 'bg'; Group = 'bg'; Name = $names[$pfn]; Type = 'Arrière-plan (app du Store)'; Detail = $pfn; Pfn = $pfn
            Disabled = ((Get-RegValue "$BgKey\$pfn" 'Disabled') -eq 1) -or ($deny -contains $pfn) -or ($global -eq 2); Checked = $false
        })
    }

    $script:BgRows = @($rows | Sort-Object Name)
    Show-BgRows
    Write-Log "$(@($script:BgRows | Where-Object Group -eq 'startup').Count) programme(s) au démarrage, $(@($script:BgRows | Where-Object Group -eq 'task').Count) tâche(s) planifiée(s), $(@($script:BgRows | Where-Object Group -eq 'bg').Count) appli(s) du Store pouvant tourner en arrière-plan."
    Set-Busy $false
}

function Show-BgRows {
    $bgList.BeginUpdate()
    $bgList.Items.Clear()
    foreach ($r in $script:BgRows) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Name)
        [void]$it.SubItems.Add($(if ($r.Disabled) { 'Désactivé' } else { 'Actif' }))
        [void]$it.SubItems.Add($r.Type)
        [void]$it.SubItems.Add([string]$r.Detail)
        if ($r.Disabled) { $it.ForeColor = 'Gray' }
        $it.Group = $bgList.Groups[$r.Group]; $it.Tag = $r; $it.Checked = $r.Checked; $it.ToolTipText = [string]$r.Detail
        [void]$bgList.Items.Add($it)
    }
    $bgList.EndUpdate()
}

function Set-BgState($Row, [bool]$Disable) {
    switch ($Row.Kind) {
        'startup' {
            $b = New-Object byte[] 12
            $b[0] = $(if ($Disable) { 3 } else { 2 })
            Set-Reg $Row.Approved $Row.ValueName $b 'Binary'
        }
        'task' {
            if ($Disable) { Disable-ScheduledTask -TaskName $Row.TaskName -TaskPath $Row.TaskPath -ErrorAction Stop | Out-Null }
            else          { Enable-ScheduledTask  -TaskName $Row.TaskName -TaskPath $Row.TaskPath -ErrorAction Stop | Out-Null }
        }
        'storetask' {
            Set-ItemProperty -LiteralPath $Row.RegPath -Name 'State' -Value $(if ($Disable) { 1 } else { 2 }) -Type DWord -ErrorAction Stop
        }
        'bg' {
            Set-Reg "$BgKey\$($Row.Pfn)" 'Disabled' ([int]$Disable)
            Set-Reg "$BgKey\$($Row.Pfn)" 'DisabledByUser' ([int]$Disable)
            # Windows 11 ignore parfois la clé ci-dessus : on ajoute aussi la stratégie par application.
            $deny = @(Get-RegValue $BgPolicy $BgDenyList | Where-Object { $_ -and $_ -ne $Row.Pfn })
            if ($Disable) { $deny += $Row.Pfn }
            if ($deny) { Set-Reg $BgPolicy $BgDenyList ([string[]]$deny) 'MultiString' }
            else { Remove-ItemProperty -Path $BgPolicy -Name $BgDenyList -ErrorAction SilentlyContinue }
        }
    }
}

# ---------------------------------------------------------------- Interface
function New-Button([string]$Text, [int]$Width) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Width = $Width; $b.Height = 32; $b.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    $b
}

function New-PrimaryButton([string]$Text, [int]$Width) {
    $b = New-Button $Text $Width
    $b.BackColor = [System.Drawing.Color]::FromArgb(0, 95, 184); $b.ForeColor = 'White'
    $b.FlatStyle = 'Flat'; $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
    $b
}

function New-ListView([string[]]$Columns, [int[]]$Widths, [System.Collections.IDictionary]$Groups) {
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.ShowGroups = $true
    $lv.ShowItemToolTips = $true; $lv.HeaderStyle = 'Nonclickable'; $lv.Dock = 'Fill'
    for ($i = 0; $i -lt $Columns.Count; $i++) { [void]$lv.Columns.Add($Columns[$i], $Widths[$i]) }
    foreach ($k in $Groups.Keys) { [void]$lv.Groups.Add((New-Object System.Windows.Forms.ListViewGroup($k, $Groups[$k]))) }
    $lv
}

# Barre de boutons en bas d'un onglet (le premier bouton est à droite), avec un texte à gauche.
function New-ActionBar([System.Windows.Forms.Control[]]$Buttons, [System.Windows.Forms.Label]$Info) {
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = 52
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock = 'Fill'; $flow.FlowDirection = 'RightToLeft'; $flow.Padding = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    $flow.Controls.AddRange($Buttons)
    $bar.Controls.Add($flow)
    if ($Info) {
        $Info.Dock = 'Left'; $Info.AutoSize = $false; $Info.Width = 340; $Info.TextAlign = 'MiddleLeft'
        $Info.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
        $bar.Controls.Add($Info)
    }
    $bar
}

function New-Tab([string]$Title, [System.Windows.Forms.Control[]]$Controls) {
    $page = New-Object System.Windows.Forms.TabPage($Title)
    $page.Controls.AddRange($Controls)
    $Controls[0].BringToFront()
    $page
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Optimiseur Windows'
$form.Size = New-Object System.Drawing.Size(1100, 800)
$form.MinimumSize = New-Object System.Drawing.Size(860, 580)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 66
$header.BackColor = [System.Drawing.Color]::FromArgb(0, 95, 184)
$title = New-Object System.Windows.Forms.Label
$title.Text = 'Optimiseur Windows'; $title.ForeColor = 'White'; $title.AutoSize = $true
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16); $title.Location = '14,6'
$Summary = New-Object System.Windows.Forms.Label
$Summary.ForeColor = [System.Drawing.Color]::FromArgb(220, 235, 255); $Summary.AutoSize = $true; $Summary.Location = '17,40'
$header.Controls.AddRange(@($title, $Summary))

# --- Onglet 1
$list = New-ListView @('Action', 'Gain estimé', 'Description') @(330, 100, 600) ([ordered]@{
    clean   = 'Nettoyage du disque'
    privacy = 'Confidentialité, publicités et suggestions'
    perf    = 'Performances'
    comfort = 'Confort'
})
foreach ($t in $Tasks) {
    $it = New-Object System.Windows.Forms.ListViewItem($t.Name)
    [void]$it.SubItems.Add($(if ($t.Size) { '...' } else { '-' }))
    [void]$it.SubItems.Add($t.Desc)
    $it.Group = $list.Groups[$t.Group]
    # Rien n'est coché au départ : seuls les réglages choisis par l'utilisateur sont modifiés.
    $it.Tag = $t; $it.Checked = $false; $it.ToolTipText = $t.Desc
    [void]$list.Items.Add($it)
}
$btnRun     = New-PrimaryButton 'Optimiser maintenant' 170
$btnAnalyze = New-Button 'Analyser' 90
$btnReco    = New-Button 'Sélection recommandée' 160
$btnNone    = New-Button 'Tout décocher' 110
$tabClean = New-Tab 'Nettoyage et réglages' @($list, (New-ActionBar @($btnRun, $btnAnalyze, $btnReco, $btnNone) $null))

# --- Onglet 2
$appList = New-ListView @('Application', 'Type', 'Taille', 'Éditeur') @(380, 120, 90, 380) ([ordered]@{
    reco  = 'Recommandé de retirer (préinstallé, inutile pour la plupart des gens)'
    store = 'Applications du Microsoft Store (réinstallables depuis le Store)'
    win32 = "Programmes installés (l'assistant de désinstallation de chaque programme s'ouvrira)"
})
$filterPanel = New-Object System.Windows.Forms.Panel
$filterPanel.Dock = 'Top'; $filterPanel.Height = 38
$filterLabel = New-Object System.Windows.Forms.Label
$filterLabel.Text = 'Rechercher :'; $filterLabel.AutoSize = $true; $filterLabel.Location = '8,11'
$appFilter = New-Object System.Windows.Forms.TextBox
$appFilter.Location = '90,8'; $appFilter.Width = 320
$filterPanel.Controls.AddRange(@($filterLabel, $appFilter))
$appCount = New-Object System.Windows.Forms.Label
$btnUninstall = New-PrimaryButton 'Désinstaller la sélection' 190
$btnAppsRefresh = New-Button 'Actualiser' 90
$btnAppsReco    = New-Button 'Sélection recommandée' 160
$btnAppsNone    = New-Button 'Tout décocher' 110
$tabApps = New-Tab 'Désinstaller des applications' @($appList, (New-ActionBar @($btnUninstall, $btnAppsRefresh, $btnAppsReco, $btnAppsNone) $appCount), $filterPanel)

# --- Onglet 3
$bgList = New-ListView @('Nom', 'État', 'Type', 'Commande / identifiant') @(300, 90, 190, 420) ([ordered]@{
    startup = 'Lancés au démarrage de Windows'
    task    = 'Tâches planifiées (programmes de mise à jour, assistants...)'
    bg      ='Applications du Store autorisées à tourner en arrière-plan'
})
$bgInfo = New-Object System.Windows.Forms.Label
$bgInfo.Text = 'Cochez des lignes puis désactivez-les ou réactivez-les. Tout est réversible.'
$btnBgOff     = New-PrimaryButton 'Désactiver la sélection' 180
$btnBgOn      = New-Button 'Réactiver la sélection' 160
$btnBgRefresh = New-Button 'Actualiser' 90
$btnTaskMgr   = New-Button 'Gestionnaire des tâches' 160
$tabBg = New-Tab 'Démarrage et arrière-plan' @($bgList, (New-ActionBar @($btnBgOff, $btnBgOn, $btnBgRefresh, $btnTaskMgr) $bgInfo))

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'; $tabs.Padding = New-Object System.Drawing.Point(14, 6)
$tabs.TabPages.AddRange(@($tabClean, $tabApps, $tabBg))

# --- Bas de fenêtre commun
$chkRestore = New-Object System.Windows.Forms.CheckBox
$chkRestore.Text = 'Créer un point de restauration avant toute modification (recommandé)'; $chkRestore.Checked = $true
$chkRestore.Dock = 'Bottom'; $chkRestore.Height = 30; $chkRestore.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Dock = 'Bottom'; $progress.Height = 8

$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Multiline = $true; $LogBox.ReadOnly = $true; $LogBox.ScrollBars = 'Vertical'
$LogBox.Dock = 'Bottom'; $LogBox.Height = 150
$LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$LogBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $LogBox.ForeColor = 'Gainsboro'

$form.Controls.AddRange(@($tabs, $header, $chkRestore, $progress, $LogBox))
$tabs.BringToFront()

# ---------------------------------------------------------------- Logique commune
function Update-Summary {
    $d = New-Object System.IO.DriveInfo($Sys)
    $sel = 0L
    foreach ($i in $list.CheckedItems) { if ($i.Tag.SizeBytes -gt 0) { $sel += $i.Tag.SizeBytes } }
    $Summary.Text = "Disque $Sys : $(Format-Size $d.AvailableFreeSpace) libres sur $(Format-Size $d.TotalSize)" +
                    "      |      Nettoyage sélectionné : $(Format-Size $sel)  (+ WinSxS)"
}

function Set-Busy([bool]$On) {
    $script:Busy = $On
    $tabs.Enabled = -not $On; $chkRestore.Enabled = -not $On
    $form.Cursor = if ($On) { 'WaitCursor' } else { 'Default' }
}

function New-RestorePoint {
    Write-Log 'Création du point de restauration (peut prendre une minute)...'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
    $job = Start-Job -ScriptBlock {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Avant Optimiseur Windows' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    }
    while ($job.State -in 'NotStarted', 'Running') { Start-Sleep -Milliseconds 250; [System.Windows.Forms.Application]::DoEvents() }
    try {
        Receive-Job $job -ErrorAction Stop | Out-Null
        Write-Log 'Point de restauration créé.'
        return $true
    } catch {
        Write-Log "Échec du point de restauration : $($_.Exception.Message)"
        $r = [System.Windows.Forms.MessageBox]::Show("Le point de restauration n'a pas pu être créé.`n`nContinuer quand même ?",
                'Optimiseur Windows', 'YesNo', 'Warning')
        return ($r -eq 'Yes')
    } finally { Remove-Job $job -Force -ErrorAction SilentlyContinue }
}

# Demande confirmation, passe en mode occupé et crée le point de restauration (une fois par session).
function Confirm-Start([string]$Message) {
    $r = [System.Windows.Forms.MessageBox]::Show($Message, 'Optimiseur Windows', 'OKCancel', 'Information')
    if ($r -ne 'OK') { return $false }
    Set-Busy $true
    if ($chkRestore.Checked -and -not $script:RestoreDone) {
        if (-not (New-RestorePoint)) { Set-Busy $false; return $false }
        $script:RestoreDone = $true
    }
    $true
}

function Format-NameList($Rows) {
    $names = @($Rows | Select-Object -First 15 | ForEach-Object { " - $($_.Name)" })
    if (@($Rows).Count -gt 15) { $names += " ... et $(@($Rows).Count - 15) autre(s)" }
    $names -join "`n"
}

# ---------------------------------------------------------------- Onglet 1 : logique
function Start-Analysis {
    Set-Busy $true
    Write-Log 'Analyse de l''espace récupérable...'
    foreach ($item in $list.Items) {
        $t = $item.Tag
        if (-not $t.Size) { continue }
        $item.SubItems[1].Text = 'analyse...'
        [System.Windows.Forms.Application]::DoEvents()
        $s = 0L
        try { $s = [long](& $t.Size $t) } catch {}
        if ($s -lt 0) {
            $item.Checked = $false; $t.Unavailable = $true; $t.SizeBytes = 0L
            $item.ForeColor = 'Gray'; $item.SubItems[1].Text = 'Non présent'
        } else {
            $t.Unavailable = $false; $t.SizeBytes = $s
            $item.ForeColor = $list.ForeColor; $item.SubItems[1].Text = Format-Size $s
        }
    }
    Update-Summary
    Write-Log 'Analyse terminée. Choisissez vos actions dans chaque onglet.'
    Set-Busy $false
}

$list.Add_ItemCheck({
    param($s, $e)
    if ($list.Items[$e.Index].Tag.Unavailable -and $e.NewValue -eq 'Checked') { $e.NewValue = 'Unchecked' }
})
$list.Add_ItemChecked({ Update-Summary })
$btnAnalyze.Add_Click({ Start-Analysis })
$btnReco.Add_Click({ foreach ($i in $list.Items) { $i.Checked = $i.Tag.Default -and -not $i.Tag.Unavailable } })
$btnNone.Add_Click({ foreach ($i in $list.Items) { $i.Checked = $false } })

$btnRun.Add_Click({
    $selected = @($list.CheckedItems | ForEach-Object { $_.Tag })
    if (-not $selected) { [void][System.Windows.Forms.MessageBox]::Show('Aucune action cochée.', 'Optimiseur Windows'); return }
    $startFree = Get-FreeSpace
    if (-not (Confirm-Start "$($selected.Count) action(s) vont être appliquées.`n`nFermez vos navigateurs et enregistrez votre travail avant de continuer.")) { return }

    $progress.Maximum = $selected.Count; $progress.Value = 0
    foreach ($t in $selected) {
        Write-Log "-> $($t.Name)"
        $before = Get-FreeSpace
        try { & $t.Run $t; $gain = (Get-FreeSpace) - $before
              Write-Log ("   OK" + $(if ($gain -gt 1MB) { "  (+$(Format-Size $gain))" } else { '' })) }
        catch { Write-Log "   ERREUR : $($_.Exception.Message)" }
        $progress.Value++
    }
    $total = [math]::Max(0, (Get-FreeSpace) - $startFree)
    Write-Log "Terminé. Espace libéré : $(Format-Size $total). Journal : $LogFile"
    Set-Busy $false
    Start-Analysis

    $r = [System.Windows.Forms.MessageBox]::Show(
        "Optimisation terminée !`n`nEspace libéré : $(Format-Size $total)`n`nUn redémarrage est nécessaire pour appliquer tous les réglages. Redémarrer maintenant ?",
        'Optimiseur Windows', 'YesNo', 'Information')
    if ($r -eq 'Yes') { Restart-Computer -Force }
})

# ---------------------------------------------------------------- Onglet 2 : logique
$appFilter.Add_TextChanged({ if ($script:AppRows) { Show-AppRows } })
$appList.Add_ItemChecked({ param($s, $e) $e.Item.Tag.Checked = $e.Item.Checked; Update-AppCount })
$btnAppsRefresh.Add_Click({ Import-AppRows })
$btnAppsReco.Add_Click({
    foreach ($r in $script:AppRows) { $r.Checked = ($r.Group -eq 'reco') }
    Show-AppRows
})
$btnAppsNone.Add_Click({ foreach ($r in $script:AppRows) { $r.Checked = $false }; Show-AppRows })

$btnUninstall.Add_Click({
    $selected = @($script:AppRows | Where-Object Checked)
    if (-not $selected) { [void][System.Windows.Forms.MessageBox]::Show('Aucune application cochée.', 'Optimiseur Windows'); return }
    if (-not (Confirm-Start "Ces $($selected.Count) application(s) vont être désinstallées :`n`n$(Format-NameList $selected)")) { return }

    $progress.Maximum = $selected.Count; $progress.Value = 0
    $ok = 0
    foreach ($r in $selected) {
        Write-Log "-> Désinstallation : $($r.Name)"
        try { Uninstall-AppRow $r; $ok++; Write-Log '   OK' }
        catch { Write-Log "   ERREUR : $($_.Exception.Message)" }
        $progress.Value++
    }
    Write-Log "$ok / $($selected.Count) application(s) désinstallée(s)."
    # Beaucoup de désinstalleurs (Steam, Inno Setup, NSIS) rendent la main avant d'avoir fini.
    if ($selected | Where-Object Kind -eq 'win32') {
        [void][System.Windows.Forms.MessageBox]::Show("Terminez les fenêtres de désinstallation encore ouvertes, puis cliquez sur OK pour actualiser la liste.",
            'Optimiseur Windows', 'OK', 'Information')
    }
    Set-Busy $false
    Import-AppRows
    Update-Summary
})

# ---------------------------------------------------------------- Onglet 3 : logique
$bgList.Add_ItemChecked({ param($s, $e) $e.Item.Tag.Checked = $e.Item.Checked })
$btnBgRefresh.Add_Click({ Import-BgRows })
$btnTaskMgr.Add_Click({ Start-Process taskmgr.exe -ArgumentList '/7 /startup' })

function Invoke-BgChange([bool]$Disable) {
    $selected = @($script:BgRows | Where-Object { $_.Checked -and $_.Disabled -ne $Disable })
    if (-not $selected) {
        [void][System.Windows.Forms.MessageBox]::Show("Cochez au moins une ligne $(if ($Disable) { 'active' } else { 'désactivée' }).", 'Optimiseur Windows')
        return
    }
    $verb = if ($Disable) { 'désactivés' } else { 'réactivés' }
    if (-not (Confirm-Start "Ces $($selected.Count) élément(s) vont être $verb :`n`n$(Format-NameList $selected)")) { return }
    foreach ($r in $selected) {
        try { Set-BgState $r $Disable; Write-Log "-> $($r.Name) : $verb" }
        catch { Write-Log "-> $($r.Name) : ERREUR $($_.Exception.Message)" }
    }
    Write-Log 'Les changements prendront effet au prochain démarrage de Windows.'
    Set-Busy $false
    Import-BgRows
}
$btnBgOff.Add_Click({ Invoke-BgChange $true })
$btnBgOn.Add_Click({ Invoke-BgChange $false })

# ---------------------------------------------------------------- Démarrage
$tabs.Add_SelectedIndexChanged({
    if ($tabs.SelectedTab -eq $tabApps -and $null -eq $script:AppRows) { Import-AppRows }
    if ($tabs.SelectedTab -eq $tabBg   -and $null -eq $script:BgRows)  { Import-BgRows }
})
$form.Add_FormClosing({ param($s, $e) if ($script:Busy) { $e.Cancel = $true } })
$form.Add_Shown({ Write-Log "Journal enregistré dans : $LogFile"; Start-Analysis })

Update-Summary
[void]$form.ShowDialog()
