# Lecture variable NinjaOne
$Message = "$env:CustomField_MessageIT"

# Fallback si vide
if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = "Message par défaut du service informatique."
}

# Affichage
msg * $Message