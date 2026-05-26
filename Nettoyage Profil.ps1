$ProfileName = "$env:ProfileName"
$Path = "C:\Users\$ProfileName"

if ([string]::IsNullOrWhiteSpace($ProfileName)) {
    Write-Output "ERREUR : variable ProfileName vide"
    exit 1
}

if (-not (Test-Path $Path)) {
    Write-Output "Dossier introuvable : $Path"
    exit 0
}

icacls $Path /grant *S-1-5-32-544:F /T /C
cmd /c rd /s /q "\\?\$Path"

if (Test-Path $Path) {
    Write-Output "ERREUR : dossier encore présent : $Path"
    exit 1
}

Write-Output "OK : dossier supprimé : $Path"
exit 0