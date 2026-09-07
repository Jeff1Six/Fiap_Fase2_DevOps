$ErrorActionPreference = "Stop"

# Vai para a raiz do repositório
$RepoRoot = git rev-parse --show-toplevel
Set-Location $RepoRoot

Write-Host ""
Write-Host "========================================="
Write-Host "0 - Sincronizando repositório"
Write-Host "========================================="

git fetch origin main

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao buscar alterações do GitHub."
    exit $LASTEXITCODE
}

git pull --rebase origin main

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao sincronizar com a branch main."
    Write-Host "Verifique se existem conflitos no Git."
    exit $LASTEXITCODE
}

Write-Host ""
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
Set-Content `
    -Path "terraform/deploy-trigger.txt" `
    -Value "Último deploy: $Timestamp"

Write-Host ""
Write-Host "========================================="
Write-Host "3 - Preparando commit"
Write-Host "========================================="

git config user.name "Terraform Automation"
git config user.email "terraform@bot.local"

# Arquivo que dispara os workflows
git add terraform/deploy-trigger.txt

# Adiciona ConfigMap gerado, caso exista
if (Test-Path "k8s/01-configmap.generated.yaml") {
    git add k8s/01-configmap.generated.yaml
}

Write-Host ""
Write-Host "Arquivos alterados:"
git status --short

# Verifica se há alterações preparadas para commit
git diff --cached --quiet

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Nenhuma alteração detectada para commitar." -ForegroundColor Yellow
    Write-Host "Processo finalizado."
    exit 0
}

git commit -m "chore: trigger microservices deployment"

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao criar commit."
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================="
Write-Host "4 - Verificando alterações remotas"
Write-Host "========================================="

# Verifica novamente porque algum commit pode ter
# sido enviado enquanto o Terraform estava executando
git fetch origin main

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao atualizar informações do GitHub."
    exit $LASTEXITCODE
}

git rebase origin/main

if ($LASTEXITCODE -ne 0) {
    Write-Error "Falha ao realizar rebase com a main remota."
    Write-Host ""
    Write-Host "Possivelmente existe um conflito."
    Write-Host "Resolva o conflito e execute:"
    Write-Host "git rebase --continue"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================="
Write-Host "5 - Enviando para o GitHub"
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
