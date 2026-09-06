$ErrorActionPreference = "Stop"

# Vai para a raiz do repositório
$RepoRoot = git rev-parse --show-toplevel
Set-Location $RepoRoot

Write-Host "========================================="
Write-Host "1 - Executando Terraform"
Write-Host "========================================="

terraform -chdir=terraform apply -auto-approve

if ($LASTEXITCODE -ne 0) {
    Write-Error "Terraform falhou. O commit não será realizado."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================="
Write-Host "2 - Terraform concluído com sucesso"
Write-Host "========================================="

# Atualiza arquivo usado apenas para disparar os workflows
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Set-Content -Path "terraform/deploy-trigger.txt" -Value "Último deploy: $Timestamp"

Write-Host ""
Write-Host "========================================="
Write-Host "3 - Preparando commit"
Write-Host "========================================="

git config user.name "Terraform Automation"
git config user.email "terraform@bot.local"

git add terraform/deploy-trigger.txt

if (Test-Path "k8s/01-configmap.generated.yaml") {
    git add k8s/01-configmap.generated.yaml
}

git status --short

# Verifica se realmente há alterações para commitar
git diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Host "Nenhuma alteração detectada para commitar. Processo finalizado." -ForegroundColor Yellow
    exit 0
}

git commit -m "chore: trigger microservices deployment"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao criar commit."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================="
Write-Host "4 - Enviando para o GitHub"
Write-Host "========================================="

git push origin main

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao realizar push."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================="
Write-Host "Deploy disparado com sucesso!"
Write-Host "=========================================" -ForegroundColor Green
