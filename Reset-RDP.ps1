# Reset-RDP.ps1
# Réinitialise les paramètres Bureau à distance enregistrés puis relance MSTSC
# Bug avec la taille du rdp qui a une taille anormale.

Write-Host "Fermeture des connexions Bureau à distance en cours..." -ForegroundColor Yellow

# Ferme les sessions MSTSC ouvertes
Get-Process mstsc -ErrorAction SilentlyContinue | Stop-Process -Force

Start-Sleep -Seconds 1

# Chemin du fichier Default.rdp
$DefaultRdpPath = Join-Path $env:USERPROFILE "Documents\Default.rdp"

Write-Host "Suppression du fichier de configuration RDP par défaut..." -ForegroundColor Yellow

# Supprime Default.rdp si présent
if (Test-Path $DefaultRdpPath) {
    Remove-Item $DefaultRdpPath -Force -ErrorAction SilentlyContinue
    Write-Host "Fichier supprimé : $DefaultRdpPath" -ForegroundColor Green
}
else {
    Write-Host "Aucun fichier Default.rdp trouvé." -ForegroundColor Cyan
}

# Relance Bureau à distance
Write-Host "Relance de Bureau à distance..." -ForegroundColor Yellow
Start-Process mstsc.exe

Write-Host "Terminé. Reconnecte-toi normalement." -ForegroundColor Green