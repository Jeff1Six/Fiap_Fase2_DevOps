$ErrorActionPreference = 'Stop'
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go nao encontrado. Instale o Go compativel com os go.mod (auth: 1.25; evaluation: 1.24).'
}
$original = Get-Location
try {
    foreach ($service in @('auth-service', 'evaluation-service')) {
        Write-Host "`n=== $service ===" -ForegroundColor Cyan
        Set-Location (Join-Path $original $service)
        go mod tidy
        if ($LASTEXITCODE -ne 0) { throw "go mod tidy falhou em $service" }
        go build ./...
        if ($LASTEXITCODE -ne 0) { throw "go build falhou em $service" }
        Write-Host "Build OK: $service" -ForegroundColor Green
        Set-Location $original
    }
    Write-Host "`nAmbos os builds Go passaram. Sem deploy realizado." -ForegroundColor Green
}
finally {
    Set-Location $original
}
