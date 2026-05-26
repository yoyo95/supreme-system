#Requires -Version 5.1
<#
.SYNOPSIS
    NinjaOne Speedtest Script v2.1 — Ookla Speedtest CLI 1.2.0
.DESCRIPTION
    Version corrigée v2.1 :
      • Capture stdout/stderr via fichiers (System.Diagnostics.Process)
        → fiable en contexte NT AUTHORITY\SYSTEM (NinjaOne agent)
      • Récupère le vrai exit code de speedtest.exe
      • Logs bruts sauvegardés pour debug en cas d'échec
      • Pré-acceptation EULA SYSTEM profile

.NOTES
    Auteur     : Joseph
    Version    : 2.1
    Fix vs 2.0 : capture I/O native + diagnostic enrichi
#>

# ─────────────────────────────────────────────────────────────────────────────
# 1. CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

$SpeedtestVersion = "1.2.0"
$SpeedtestURL     = "https://install.speedtest.net/app/cli/ookla-speedtest-$SpeedtestVersion-win64.zip"
$SpeedtestSHA256  = "13E3D888B845D301A556419E31F14AB9BFF57E3F06089EF2FD3BDC9BA6841EFA"

# Seuils VPN-ready (FortiGate SSL VPN vpn.lfcc.fr)
$Threshold_DownloadMinMbps  = 10
$Threshold_UploadMinMbps    = 3
$Threshold_PingMaxMs        = 80
$Threshold_JitterMaxMs      = 20
$Threshold_PacketLossMaxPct = 2

$CF = @{
    Download   = "speedtestDownloadMbps"
    Upload     = "speedtestUploadMbps"
    Ping       = "speedtestPingMs"
    Jitter     = "speedtestJitterMs"
    PacketLoss = "speedtestPacketLossPct"
    ISP        = "speedtestISP"
    Server     = "speedtestServeur"
    ResultURL  = "speedtestResultURL"
    LastRun    = "speedtestDernierTest"
    Status     = "speedtestStatut"
}

$WorkDir   = Join-Path $env:ProgramData "NinjaRMM\speedtest"
$ExePath   = Join-Path $WorkDir "speedtest.exe"
$LockFile  = Join-Path $WorkDir ".lock"
$StdoutLog = Join-Path $WorkDir "_last_stdout.log"
$StderrLog = Join-Path $WorkDir "_last_stderr.log"
$LockMaxAgeMinutes = 10

# ─────────────────────────────────────────────────────────────────────────────
# 2. PRÉPARATION
# ─────────────────────────────────────────────────────────────────────────────

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

# Pré-création du dossier de config Speedtest pour le profil SYSTEM (fix EULA)
$SystemProfileOoklaDir = "C:\Windows\System32\config\systemprofile\AppData\Roaming\Ookla\Speedtest CLI"
if (-not (Test-Path $SystemProfileOoklaDir)) {
    try {
        New-Item -ItemType Directory -Path $SystemProfileOoklaDir -Force | Out-Null
    } catch { }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. FONCTIONS UTILITAIRES
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')][string]$Level = 'INFO')
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$ts][$Level] $Message"
}

function Set-NinjaField {
    param([string]$Name, $Value)
    try {
        if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
            Ninja-Property-Set $Name $Value | Out-Null
        }
    } catch {
        Write-Log "CF '$Name' non écrit : $($_.Exception.Message)" 'WARN'
    }
}

function Test-LockFile {
    if (Test-Path $LockFile) {
        $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
        if ($age.TotalMinutes -lt $LockMaxAgeMinutes) {
            Write-Log "Test déjà en cours (lock < $LockMaxAgeMinutes min)" 'WARN'
            return $false
        }
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
    Set-Content -Path $LockFile -Value $PID -Force
    return $true
}

function Remove-LockFile {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}

function Get-FileSHA256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpper()
}

function Test-SpeedtestBinary {
    if (-not (Test-Path $ExePath)) { return $false }
    try {
        $verOutput = & $ExePath --version 2>&1 | Select-Object -First 1
        if ($verOutput -match $SpeedtestVersion) { return $true }
        Write-Log "Version inattendue : '$verOutput'" 'WARN'
    } catch {
        Write-Log "Binaire invalide : $($_.Exception.Message)" 'WARN'
    }
    return $false
}

function Install-SpeedtestCLI {
    $zipPath = Join-Path $WorkDir "speedtest-$SpeedtestVersion.zip"
    $tmpPath = "$zipPath.tmp"

    Write-Log "Téléchargement Speedtest CLI $SpeedtestVersion..."
    try {
        $wc = New-Object Net.WebClient
        $wc.Proxy = [Net.WebRequest]::GetSystemWebProxy()
        $wc.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
        $wc.Headers.Add("User-Agent", "NinjaOne-Speedtest-Script/2.1")

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $wc.DownloadFile($SpeedtestURL, $tmpPath)
        $sw.Stop()

        $sizeKB = [math]::Round((Get-Item $tmpPath).Length / 1KB, 1)
        Write-Log "Téléchargé : $sizeKB KB en $($sw.Elapsed.TotalSeconds.ToString('F1'))s" 'OK'
    }
    catch {
        Write-Log "Échec téléchargement : $($_.Exception.Message)" 'ERROR'
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    finally {
        if ($wc) { $wc.Dispose() }
    }

    Write-Log "Vérification SHA256..."
    $actualHash = Get-FileSHA256 -Path $tmpPath
    if ($actualHash -ne $SpeedtestSHA256) {
        Write-Log "ÉCHEC SHA256 : attendu $SpeedtestSHA256 / reçu $actualHash" 'ERROR'
        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Log "SHA256 valide" 'OK'

    Move-Item -Path $tmpPath -Destination $zipPath -Force

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $extractDir = Join-Path $WorkDir "_extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)

        $found = Get-ChildItem -Path $extractDir -Filter "speedtest.exe" -Recurse | Select-Object -First 1
        if (-not $found) {
            Write-Log "speedtest.exe introuvable dans l'archive" 'ERROR'
            return $false
        }

        Move-Item -Path $found.FullName -Destination $ExePath -Force
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        Write-Log "speedtest.exe installé : $ExePath" 'OK'
        return $true
    }
    catch {
        Write-Log "Erreur extraction : $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Invoke-Speedtest {
    <#
    .SYNOPSIS Lance le test via System.Diagnostics.Process (capture I/O fiable).
    #>
    param([int]$MaxAttempts = 2)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "Test Speedtest en cours (tentative $attempt/$MaxAttempts)..."

        # Nettoyage logs précédents
        Remove-Item $StdoutLog, $StderrLog -Force -ErrorAction SilentlyContinue

        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            # ── Approche bulletproof : System.Diagnostics.Process ───────────
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $ExePath
            $psi.Arguments              = "--accept-license --accept-gdpr -f json --progress=no"
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            # Force UTF-8 pour la sortie (speedtest.exe sort en UTF-8)
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

            $proc = [System.Diagnostics.Process]::Start($psi)
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $exitCode = $proc.ExitCode
            $sw.Stop()

            # Sauvegarde des logs bruts pour diagnostic
            $stdout | Out-File -FilePath $StdoutLog -Encoding UTF8 -Force
            $stderr | Out-File -FilePath $StderrLog -Encoding UTF8 -Force

            Write-Log "speedtest.exe terminé en $($sw.Elapsed.TotalSeconds.ToString('F1'))s (exit=$exitCode)"

            # ── Vérification exit code ─────────────────────────────────────
            if ($exitCode -ne 0) {
                $errMsg = if ($stderr) { $stderr.Trim() } else { "Aucune sortie d'erreur" }
                Write-Log "Échec speedtest.exe (code $exitCode) : $errMsg" 'WARN'
                Write-Log "Logs bruts : $StdoutLog / $StderrLog" 'DEBUG'
                if ($attempt -lt $MaxAttempts) {
                    Write-Log "Nouvelle tentative dans 5s..."
                    Start-Sleep -Seconds 5
                }
                continue
            }

            # ── Parsing JSON ───────────────────────────────────────────────
            if ([string]::IsNullOrWhiteSpace($stdout)) {
                Write-Log "stdout vide alors que exit=0 (cas inattendu)" 'WARN'
                if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 5 }
                continue
            }

            try {
                $result = $stdout | ConvertFrom-Json -ErrorAction Stop
                Write-Log "Parsing JSON réussi" 'OK'
                return $result
            } catch {
                $preview = $stdout.Substring(0, [Math]::Min(300, $stdout.Length))
                Write-Log "Parsing JSON échoué : $($_.Exception.Message)" 'WARN'
                Write-Log "stdout (300 1ers car.) : $preview" 'DEBUG'
                if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 5 }
            }
        }
        catch {
            Write-Log "Exception : $($_.Exception.Message)" 'WARN'
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 5 }
        }
    }
    return $null
}

function To-Mbps { param([double]$BytesPerSec) [math]::Round($BytesPerSec / 125000, 2) }

# ─────────────────────────────────────────────────────────────────────────────
# 4. FLUX PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────

$globalSw = [Diagnostics.Stopwatch]::StartNew()
Write-Log "=== NinjaOne Speedtest Script v2.1 ==="
Write-Log "Machine : $env:COMPUTERNAME | Contexte : $env:USERNAME"

if (-not (Test-LockFile)) { exit 0 }

try {
    if (-not (Test-SpeedtestBinary)) {
        if (-not (Install-SpeedtestCLI)) {
            Set-NinjaField $CF.Status "ERREUR - CLI indisponible"
            Set-NinjaField $CF.LastRun (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            exit 2
        }
    } else {
        Write-Log "CLI déjà installé (v$SpeedtestVersion vérifiée)" 'OK'
    }

    $data = Invoke-Speedtest -MaxAttempts 2
    if (-not $data) {
        Set-NinjaField $CF.Status "ERREUR - Test échoué (voir $StdoutLog)"
        Set-NinjaField $CF.LastRun (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Write-Log "Diagnostic : consulter $StdoutLog et $StderrLog" 'ERROR'
        exit 2
    }

    $download   = To-Mbps $data.download.bandwidth
    $upload     = To-Mbps $data.upload.bandwidth
    $ping       = [math]::Round($data.ping.latency, 2)
    $jitter     = [math]::Round($data.ping.jitter, 2)
    $packetLoss = if ($null -ne $data.packetLoss) { [math]::Round($data.packetLoss, 2) } else { 0 }
    $isp        = $data.isp
    $serverInfo = "{0} - {1} ({2})" -f $data.server.name, $data.server.location, $data.server.country
    $resultURL  = $data.result.url
    $timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Write-Log "──────────────────────────────────────────"
    Write-Log "  Download    : $download Mbps"
    Write-Log "  Upload      : $upload Mbps"
    Write-Log "  Ping        : $ping ms"
    Write-Log "  Jitter      : $jitter ms"
    Write-Log "  Packet Loss : $packetLoss %"
    Write-Log "  FAI         : $isp"
    Write-Log "  Serveur     : $serverInfo"
    Write-Log "  Résultat    : $resultURL"
    Write-Log "──────────────────────────────────────────"

    Set-NinjaField $CF.Download   $download
    Set-NinjaField $CF.Upload     $upload
    Set-NinjaField $CF.Ping       $ping
    Set-NinjaField $CF.Jitter     $jitter
    Set-NinjaField $CF.PacketLoss $packetLoss
    Set-NinjaField $CF.ISP        $isp
    Set-NinjaField $CF.Server     $serverInfo
    Set-NinjaField $CF.ResultURL  $resultURL
    Set-NinjaField $CF.LastRun    $timestamp

    $alerts = @()
    if ($Threshold_DownloadMinMbps  -gt 0 -and $download   -lt $Threshold_DownloadMinMbps)  { $alerts += "Download $download<$Threshold_DownloadMinMbps Mbps" }
    if ($Threshold_UploadMinMbps    -gt 0 -and $upload     -lt $Threshold_UploadMinMbps)    { $alerts += "Upload $upload<$Threshold_UploadMinMbps Mbps" }
    if ($Threshold_PingMaxMs        -gt 0 -and $ping       -gt $Threshold_PingMaxMs)        { $alerts += "Ping $ping>$Threshold_PingMaxMs ms" }
    if ($Threshold_JitterMaxMs      -gt 0 -and $jitter     -gt $Threshold_JitterMaxMs)      { $alerts += "Jitter $jitter>$Threshold_JitterMaxMs ms" }
    if ($Threshold_PacketLossMaxPct -gt 0 -and $packetLoss -gt $Threshold_PacketLossMaxPct) { $alerts += "PacketLoss $packetLoss>$Threshold_PacketLossMaxPct%" }

    $globalSw.Stop()
    if ($alerts.Count -eq 0) {
        Set-NinjaField $CF.Status "OK"
        Write-Log "Réseau VPN-ready ✅ (durée totale : $($globalSw.Elapsed.TotalSeconds.ToString('F1'))s)" 'OK'
        exit 0
    } else {
        $summary = "ALERTE: " + ($alerts -join " | ")
        Set-NinjaField $CF.Status $summary
        Write-Log $summary 'WARN'
        Write-Log "Durée totale : $($globalSw.Elapsed.TotalSeconds.ToString('F1'))s"
        exit 1
    }
}
finally {
    Remove-LockFile
}
