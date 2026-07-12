param(
    [string]$BaseUrl = "http://localhost",
    [string]$MasterKey = "admin-secreto-123",
    [string]$FlagName = "enable-new-dashboard"
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Title)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "[AVISO] $Message" -ForegroundColor Yellow
}

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet("GET", "POST", "PUT", "DELETE")][string]$Method = "GET",
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [int[]]$AllowedStatusCodes = @(200, 201, 204)
    )

    try {
        $params = @{
            Uri         = $Uri
            Method      = $Method
            Headers     = $Headers
            ErrorAction = "Stop"
        }

        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            $params.ContentType = "application/json; charset=utf-8"
            $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        }

        $response = Invoke-WebRequest @params

        if ($AllowedStatusCodes -notcontains [int]$response.StatusCode) {
            throw "Status inesperado: $($response.StatusCode)"
        }

        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            return $null
        }

        return $response.Content | ConvertFrom-Json
    }
    catch {
        $statusCode = $null
        $responseBody = $null

        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } catch {}

            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
            } catch {}
        }

        $details = if ($responseBody) { $responseBody } else { $_.Exception.Message }

        $exception = New-Object System.Exception("Falha em $Method $Uri | Status: $statusCode | Resposta: $details")
        $exception.Data["StatusCode"] = $statusCode
        $exception.Data["ResponseBody"] = $responseBody
        throw $exception
    }
}

Write-Step "1. VERIFICANDO OS 5 MICROSSERVICOS"

$services = @(
    @{ Name = "auth-service";       Url = "$BaseUrl`:8001/health" },
    @{ Name = "flag-service";       Url = "$BaseUrl`:8002/health" },
    @{ Name = "targeting-service";  Url = "$BaseUrl`:8003/health" },
    @{ Name = "evaluation-service"; Url = "$BaseUrl`:8004/health" },
    @{ Name = "analytics-service";  Url = "$BaseUrl`:8005/health" }
)

foreach ($service in $services) {
    $health = Invoke-JsonRequest -Uri $service.Url

    if ($health.status -ne "ok") {
        throw "$($service.Name) respondeu, mas com status inesperado."
    }

    Write-Success "$($service.Name) -> $($health.status)"
}

Write-Step "2. CRIANDO UMA CHAVE DE API NO AUTH-SERVICE"

$keyName = "video-demo-" + (Get-Date -Format "yyyyMMdd-HHmmss")

$keyResponse = Invoke-JsonRequest `
    -Uri "$BaseUrl`:8001/admin/keys" `
    -Method POST `
    -Headers @{ Authorization = "Bearer $MasterKey" } `
    -Body @{ name = $keyName }

$apiKey = $keyResponse.key

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "O auth-service nao retornou uma chave de API."
}

Write-Success "Chave criada: $($apiKey.Substring(0, [Math]::Min(18, $apiKey.Length)))..."
$authHeaders = @{ Authorization = "Bearer $apiKey" }

Write-Step "3. VALIDANDO A CHAVE NO AUTH-SERVICE"

$validation = Invoke-JsonRequest `
    -Uri "$BaseUrl`:8001/validate" `
    -Headers $authHeaders

Write-Success "Chave validada pelo auth-service"
$validation | Format-List | Out-Host

Write-Step "4. CRIANDO OU ATUALIZANDO A FEATURE FLAG"

$flagBody = @{
    name        = $FlagName
    description = "Flag utilizada na demonstracao do Tech Challenge"
    is_enabled  = $true
}

try {
    $flag = Invoke-JsonRequest `
        -Uri "$BaseUrl`:8002/flags" `
        -Method POST `
        -Headers $authHeaders `
        -Body $flagBody

    Write-Success "Flag criada com sucesso"
}
catch {
    if ($_.Exception.Data["StatusCode"] -eq 409) {
        Write-WarningMessage "A flag ja existe. Atualizando para is_enabled=true."

        $flag = Invoke-JsonRequest `
            -Uri "$BaseUrl`:8002/flags/$FlagName" `
            -Method PUT `
            -Headers $authHeaders `
            -Body @{
                description = "Flag utilizada na demonstracao do Tech Challenge"
                is_enabled  = $true
            }

        Write-Success "Flag atualizada com sucesso"
    }
    else {
        throw
    }
}

$flag = Invoke-JsonRequest `
    -Uri "$BaseUrl`:8002/flags/$FlagName" `
    -Headers $authHeaders

$flag | Format-List | Out-Host

Write-Step "5. CRIANDO OU ATUALIZANDO A REGRA DE TARGETING"

$ruleBody = @{
    flag_name  = $FlagName
    is_enabled = $true
    rules      = @{
        type  = "PERCENTAGE"
        value = 50
    }
}

try {
    $rule = Invoke-JsonRequest `
        -Uri "$BaseUrl`:8003/rules" `
        -Method POST `
        -Headers $authHeaders `
        -Body $ruleBody

    Write-Success "Regra criada com sucesso"
}
catch {
    if ($_.Exception.Data["StatusCode"] -eq 409) {
        Write-WarningMessage "A regra ja existe. Atualizando para 50%."

        $rule = Invoke-JsonRequest `
            -Uri "$BaseUrl`:8003/rules/$FlagName" `
            -Method PUT `
            -Headers $authHeaders `
            -Body @{
                is_enabled = $true
                rules      = @{
                    type  = "PERCENTAGE"
                    value = 50
                }
            }

        Write-Success "Regra atualizada com sucesso"
    }
    else {
        throw
    }
}

$rule = Invoke-JsonRequest `
    -Uri "$BaseUrl`:8003/rules/$FlagName" `
    -Headers $authHeaders

$rule | Format-List | Out-Host

Write-Step "6. TESTANDO O EVALUATION-SERVICE"

$userIds = @(
    "user-123",
    "user-abc",
    "customer-video-demo"
)

foreach ($userId in $userIds) {
    $evaluation = Invoke-JsonRequest `
        -Uri "$BaseUrl`:8004/evaluate?user_id=$userId&flag_name=$FlagName"

    $resultText = if ($evaluation.result) { "TRUE" } else { "FALSE" }

    Write-Host ("Usuario: {0,-22} Resultado: {1}" -f $evaluation.user_id, $resultText) -ForegroundColor Magenta
}

Write-Step "7. AGUARDANDO O ANALYTICS PROCESSAR OS EVENTOS"

Start-Sleep -Seconds 3
Write-Success "Eventos enviados para a fila pelo evaluation-service."

Write-Host ""
Write-Host "Para mostrar os logs do analytics no video, rode:" -ForegroundColor Yellow
Write-Host "docker compose logs --tail=50 analytics-service" -ForegroundColor White

Write-Host ""
Write-Host "Para mostrar os dados gravados no DynamoDB Local, rode:" -ForegroundColor Yellow
Write-Host "aws dynamodb scan --table-name ToggleMasterAnalytics --endpoint-url http://127.0.0.1:8000 --region us-east-1 --no-cli-pager" -ForegroundColor White

Write-Step "DEMONSTRACAO FINALIZADA"
Write-Success "Auth, Flag, Targeting, Evaluation e Analytics foram exercitados."