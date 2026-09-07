param(
    [string]$Namespace = "desafio3",
    [string]$IngressName = "toggle-master-ingress",
    [string]$AwsRegion = "us-east-1",
    [string]$ClusterName = "togglemaster-dev",
    [switch]$AtualizarKubeconfig,
    [switch]$FluxoCompleto,
    [string]$MasterKey = "admin-secreto-123",
    [string]$FlagName = "enable-new-dashboard",
    [string]$TestUserId = "user-123"
)

$ErrorActionPreference = "Stop"

if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "============================================================"
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[AVISO] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "[ERRO] $Text" -ForegroundColor Red
}

function Invoke-KubectlJson {
    param([string[]]$Arguments)

    $output = & kubectl @Arguments 2>$null

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $text = ($output -join "`n")

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return ($text | ConvertFrom-Json)
}

function Get-IngressInfo {
    param(
        [string]$Namespace,
        [string]$IngressName
    )

    $ingress = Invoke-KubectlJson -Arguments @(
        "get", "ingress", $IngressName,
        "-n", $Namespace,
        "-o", "json"
    )

    if (-not $ingress) {
        throw "Ingress '$IngressName' não encontrado no namespace '$Namespace'."
    }

    $address = $null

    if ($ingress.status.loadBalancer.ingress) {
        $lb = $ingress.status.loadBalancer.ingress[0]

        if ($lb.hostname) {
            $address = $lb.hostname
        }
        elseif ($lb.ip) {
            $address = $lb.ip
        }
    }

    if ([string]::IsNullOrWhiteSpace($address)) {
        throw "O Ingress existe, mas ainda não possui ADDRESS público na AWS."
    }

    $tlsHosts = @()

    foreach ($tls in @($ingress.spec.tls)) {
        foreach ($tlsHost in @($tls.hosts)) {
            if ($tlsHost) {
                $tlsHosts += $tlsHost
            }
        }
    }

    $routes = @()

    foreach ($rule in @($ingress.spec.rules)) {
        $ruleHost = $rule.host

        foreach ($pathItem in @($rule.http.paths)) {
            $serviceName = $pathItem.backend.service.name
            $path = $pathItem.path

            if ([string]::IsNullOrWhiteSpace($path)) {
                $path = "/"
            }

            $hostForUrl = $ruleHost

            if ([string]::IsNullOrWhiteSpace($hostForUrl) -or $hostForUrl -eq "*") {
                $hostForUrl = $address
            }

            $scheme = "http"

            if ($tlsHosts -contains $ruleHost) {
                $scheme = "https"
            }

            $routes += [PSCustomObject]@{
                Service = $serviceName
                Path    = $path
                Host    = $hostForUrl
                Scheme  = $scheme
                BaseUrl = "${scheme}://${hostForUrl}"
            }
        }
    }

    return [PSCustomObject]@{
        Address = $address
        Routes  = $routes
    }
}

function Get-ServiceRoute {
    param(
        [object[]]$Routes,
        [string]$ServiceName
    )

    return @(
        $Routes | Where-Object {
            $_.Service -eq $ServiceName -or
            $_.Service -like "$ServiceName*" -or
            $ServiceName -like "$($_.Service)*"
        }
    ) | Select-Object -First 1
}

function Join-ExternalUrl {
    param(
        [string]$BaseUrl,
        [string]$IngressPath,
        [string]$Endpoint
    )

    if ([string]::IsNullOrWhiteSpace($IngressPath)) {
        $IngressPath = "/"
    }

    $prefix = $IngressPath

    # Remove regex/wildcard comum em Ingress NGINX, ex.: /auth(/|$)(.*)
    $prefix = $prefix -replace '\(\.\*\).*$', ''
    $prefix = $prefix -replace '\(/\|\$\).*$', ''
    $prefix = $prefix -replace '\(\.\*\)', ''
    $prefix = $prefix.TrimEnd('/')

    if ($prefix -eq "") {
        $prefix = ""
    }

    if (-not $Endpoint.StartsWith("/")) {
        $Endpoint = "/$Endpoint"
    }

    return "$BaseUrl$prefix$Endpoint"
}

function Invoke-Endpoint {
    param(
        [string]$Name,
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [int[]]$ExpectedStatus = @(200)
    )

    Write-Host ""
    Write-Host "[$Method] $Name"
    Write-Host "URL: $Url" -ForegroundColor DarkGray

    try {
        $params = @{
            Uri         = $Url
            Method      = $Method
            Headers     = $Headers
            TimeoutSec  = 20
            ErrorAction = "Stop"
        }

        if ($null -ne $Body) {
            $params["ContentType"] = "application/json"
            $params["Body"] = ($Body | ConvertTo-Json -Depth 10 -Compress)
        }

        $response = Invoke-WebRequest @params

        if ($ExpectedStatus -contains [int]$response.StatusCode) {
            Write-Ok "HTTP $($response.StatusCode)"
        }
        else {
            Write-Warn "HTTP $($response.StatusCode) - esperado: $($ExpectedStatus -join ', ')"
        }

        if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
            Write-Host $response.Content
        }

        return [PSCustomObject]@{
            Success    = $ExpectedStatus -contains [int]$response.StatusCode
            StatusCode = [int]$response.StatusCode
            Content    = $response.Content
        }
    }
    catch {
        $statusCode = $null
        $content = ""

        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = $null
            }
        }

        if ($statusCode -and ($ExpectedStatus -contains $statusCode)) {
            Write-Ok "HTTP $statusCode"
            return [PSCustomObject]@{
                Success    = $true
                StatusCode = $statusCode
                Content    = $content
            }
        }

        if ($statusCode) {
            Write-Fail "HTTP $statusCode"
        }
        else {
            Write-Fail $_.Exception.Message
        }

        return [PSCustomObject]@{
            Success    = $false
            StatusCode = $statusCode
            Content    = $content
        }
    }
}

try {
    if ($AtualizarKubeconfig) {
        Write-Section "ATUALIZANDO KUBECONFIG"

        & aws eks update-kubeconfig `
            --region $AwsRegion `
            --name $ClusterName

        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao atualizar kubeconfig."
        }

        Write-Ok "Kubeconfig atualizado."
    }

    Write-Section "DESCOBRINDO ENDPOINTS AWS"

    $ingressInfo = Get-IngressInfo `
        -Namespace $Namespace `
        -IngressName $IngressName

    Write-Host "Ingress:  $IngressName"
    Write-Host "Address:  $($ingressInfo.Address)"
    Write-Host ""

    if ($ingressInfo.Routes.Count -eq 0) {
        throw "O Ingress não possui rotas configuradas."
    }

    $ingressInfo.Routes |
        Select-Object Service, Path, Scheme, Host |
        Format-Table -AutoSize

    $serviceNames = @{
        Auth       = "auth-service"
        Flag       = "flag-service"
        Targeting  = "targeting-service"
        Evaluation = "evaluation-service"
        Analytics  = "analytics-service"
    }

    $routes = @{}

    foreach ($key in $serviceNames.Keys) {
        $route = Get-ServiceRoute `
            -Routes $ingressInfo.Routes `
            -ServiceName $serviceNames[$key]

        if ($route) {
            $routes[$key] = $route
        }
        else {
            Write-Warn "Não encontrei rota do Ingress para $($serviceNames[$key])."
        }
    }

    Write-Section "HEALTH CHECK DOS MICROSSERVICOS"

    $healthResults = @()

    foreach ($key in @("Auth", "Flag", "Targeting", "Evaluation", "Analytics")) {
        if (-not $routes.ContainsKey($key)) {
            continue
        }

        $route = $routes[$key]

        $healthUrl = Join-ExternalUrl `
            -BaseUrl $route.BaseUrl `
            -IngressPath $route.Path `
            -Endpoint "/health"

        $result = Invoke-Endpoint `
            -Name "$key Service - Health" `
            -Method "GET" `
            -Url $healthUrl `
            -ExpectedStatus @(200)

        $healthResults += [PSCustomObject]@{
            Servico = $key
            URL     = $healthUrl
            Status  = if ($result.Success) { "OK" } else { "FALHOU" }
            HTTP    = $result.StatusCode
        }
    }

    Write-Section "RESUMO HEALTH CHECK"

    $healthResults | Format-Table -AutoSize

    if (-not $FluxoCompleto) {
        Write-Host ""
        Write-Host "Somente health checks executados." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Para testar o fluxo funcional completo:"
        Write-Host '.\testar-endpoints-aws.ps1 -FluxoCompleto -MasterKey "SUA_MASTER_KEY"'
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($MasterKey)) {
        throw "Para usar -FluxoCompleto informe também -MasterKey."
    }

    if (
        -not $routes.ContainsKey("Auth") -or
        -not $routes.ContainsKey("Flag") -or
        -not $routes.ContainsKey("Targeting") -or
        -not $routes.ContainsKey("Evaluation")
    ) {
        throw "O fluxo completo precisa das rotas de Auth, Flag, Targeting e Evaluation."
    }

    Write-Section "1 - CRIANDO CHAVE DE API"

    $authRoute = $routes["Auth"]

    $createKeyUrl = Join-ExternalUrl `
        -BaseUrl $authRoute.BaseUrl `
        -IngressPath $authRoute.Path `
        -Endpoint "/admin/keys"

    $keyResult = Invoke-Endpoint `
        -Name "Auth - Criar API Key" `
        -Method "POST" `
        -Url $createKeyUrl `
        -Headers @{
            Authorization = "Bearer $MasterKey"
        } `
        -Body @{
            name = "aws-endpoint-test"
        } `
        -ExpectedStatus @(200, 201)

    if (-not $keyResult.Success -or [string]::IsNullOrWhiteSpace($keyResult.Content)) {
        throw "Não foi possível criar a API Key."
    }

    $keyJson = $keyResult.Content | ConvertFrom-Json
    $ApiKey = $keyJson.key

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "O auth-service respondeu, mas não retornou o campo 'key'."
    }

    Write-Ok "API Key criada."

    Write-Section "2 - VALIDANDO CHAVE"

    $validateUrl = Join-ExternalUrl `
        -BaseUrl $authRoute.BaseUrl `
        -IngressPath $authRoute.Path `
        -Endpoint "/validate"

    Invoke-Endpoint `
        -Name "Auth - Validar API Key" `
        -Method "GET" `
        -Url $validateUrl `
        -Headers @{
            Authorization = "Bearer $ApiKey"
        } `
        -ExpectedStatus @(200) | Out-Null

    Write-Section "3 - CRIANDO FLAG"

    $flagRoute = $routes["Flag"]

    $flagsUrl = Join-ExternalUrl `
        -BaseUrl $flagRoute.BaseUrl `
        -IngressPath $flagRoute.Path `
        -Endpoint "/flags"

    Invoke-Endpoint `
        -Name "Flag - Criar flag" `
        -Method "POST" `
        -Url $flagsUrl `
        -Headers @{
            Authorization = "Bearer $ApiKey"
        } `
        -Body @{
            name        = $FlagName
            description = "Flag criada pelo teste automatizado AWS"
            is_enabled  = $true
        } `
        -ExpectedStatus @(200, 201, 409) | Out-Null

    Invoke-Endpoint `
        -Name "Flag - Listar flags" `
        -Method "GET" `
        -Url $flagsUrl `
        -Headers @{
            Authorization = "Bearer $ApiKey"
        } `
        -ExpectedStatus @(200) | Out-Null

    Write-Section "4 - CRIANDO REGRA DE TARGETING"

    $targetingRoute = $routes["Targeting"]

    $rulesUrl = Join-ExternalUrl `
        -BaseUrl $targetingRoute.BaseUrl `
        -IngressPath $targetingRoute.Path `
        -Endpoint "/rules"

    Invoke-Endpoint `
        -Name "Targeting - Criar regra" `
        -Method "POST" `
        -Url $rulesUrl `
        -Headers @{
            Authorization = "Bearer $ApiKey"
        } `
        -Body @{
            flag_name  = $FlagName
            is_enabled = $true
            rules      = @{
                type  = "PERCENTAGE"
                value = 50
            }
        } `
        -ExpectedStatus @(200, 201, 409) | Out-Null

    $getRuleUrl = Join-ExternalUrl `
        -BaseUrl $targetingRoute.BaseUrl `
        -IngressPath $targetingRoute.Path `
        -Endpoint "/rules/$FlagName"

    Invoke-Endpoint `
        -Name "Targeting - Consultar regra" `
        -Method "GET" `
        -Url $getRuleUrl `
        -Headers @{
            Authorization = "Bearer $ApiKey"
        } `
        -ExpectedStatus @(200) | Out-Null

    Write-Section "5 - TESTANDO EVALUATION"

    # Usa exatamente a API Key criada no passo 1.
    # Ela é salva em um Secret runtime separado, que não fica no Git.
    Write-Host "Configurando API Key runtime do evaluation-service..." -ForegroundColor Yellow

    $runtimeSecretName = "evaluation-api-key"

    $secretYaml = & kubectl create secret generic $runtimeSecretName `
        -n $Namespace `
        --from-literal="SERVICE_API_KEY=$ApiKey" `
        --dry-run=client `
        -o yaml

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($secretYaml -join "`n"))) {
        throw "Não foi possível gerar o Secret runtime '$runtimeSecretName'."
    }

    $secretYaml | & kubectl apply -f - | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível criar/atualizar o Secret runtime '$runtimeSecretName'."
    }

    # O Deployment lê SERVICE_API_KEY do Secret evaluation-api-key.
    # Reinicia somente o evaluation-service para carregar a chave nova.
    & kubectl rollout restart `
        deployment/evaluation-service `
        -n $Namespace | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível reiniciar o evaluation-service."
    }

    Write-Host "Aguardando rollout do evaluation-service..." -ForegroundColor Yellow

    & kubectl rollout status `
        deployment/evaluation-service `
        -n $Namespace `
        --timeout=120s | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "O evaluation-service não ficou Ready dentro do tempo esperado."
    }

    # Confirma, sem imprimir a chave, que o Pod recebeu a mesma chave criada no teste.
    $podApiKey = & kubectl exec `
        -n $Namespace `
        deployment/evaluation-service `
        -- printenv SERVICE_API_KEY 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($podApiKey)) {
        throw "SERVICE_API_KEY não foi encontrada no Pod do evaluation-service."
    }

    if (($podApiKey -join "`n").Trim() -ne $ApiKey.Trim()) {
        throw "O evaluation-service não recebeu a API Key criada neste teste."
    }

    Write-Ok "Evaluation configurado com a API Key criada neste teste."

    Write-Host "Aguardando endpoint do evaluation-service ficar disponível..." -ForegroundColor Yellow

    $endpointReady = $false

    for ($attempt = 1; $attempt -le 15; $attempt++) {
        $ready = & kubectl get endpointslice `
            -n $Namespace `
            -l kubernetes.io/service-name=evaluation-service-svc `
            -o jsonpath='{.items[0].endpoints[0].conditions.ready}' `
            2>$null

        if ($LASTEXITCODE -eq 0 -and "$ready".Trim() -eq "true") {
            $endpointReady = $true
            break
        }

        Start-Sleep -Seconds 2
    }

    if (-not $endpointReady) {
        throw "O endpoint do evaluation-service não ficou disponível no Kubernetes."
    }

    Start-Sleep -Seconds 3

    $evaluationRoute = $routes["Evaluation"]

    $evaluateUrl = Join-ExternalUrl `
        -BaseUrl $evaluationRoute.BaseUrl `
        -IngressPath $evaluationRoute.Path `
        -Endpoint "/evaluate?user_id=$TestUserId&flag_name=$FlagName"

    $evaluationResult = $null

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $evaluationResult = Invoke-Endpoint `
            -Name "Evaluation - Avaliar flag" `
            -Method "GET" `
            -Url $evaluateUrl `
            -ExpectedStatus @(200)

        if ($evaluationResult.Success) {
            break
        }

        if ($evaluationResult.StatusCode -in @(502, 503)) {
            Write-Warn "Evaluation retornou HTTP $($evaluationResult.StatusCode). Tentativa $attempt de 5."
            Start-Sleep -Seconds 3
            continue
        }

        break
    }

    if (-not $evaluationResult.Success) {
        throw "Falha ao avaliar flag no evaluation-service. HTTP $($evaluationResult.StatusCode)."
    }

    Write-Section "6 - TESTANDO REDIS"

    $redisHost = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.REDIS_HOST}'

    $redisPort = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.REDIS_PORT}'

    if (
        [string]::IsNullOrWhiteSpace($redisHost) -or
        [string]::IsNullOrWhiteSpace($redisPort)
    ) {
        throw "REDIS_HOST ou REDIS_PORT não encontrados no ConfigMap app-configmap."
    }

    $redisTestPod = "redis-test-" + (Get-Random -Minimum 1000 -Maximum 9999)

    try {
        Write-Host "Testando conexão com Redis..." -ForegroundColor Yellow

        & kubectl run $redisTestPod `
            -n $Namespace `
            --restart=Never `
            --image=redis:7-alpine `
            --command `
            -- redis-cli `
                -h $redisHost `
                -p $redisPort `
                ping | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Não foi possível criar o Pod temporário para testar o Redis."
        }

        $redisFinished = $false

        for ($attempt = 1; $attempt -le 45; $attempt++) {
            $phase = & kubectl get pod $redisTestPod `
                -n $Namespace `
                -o jsonpath='{.status.phase}' `
                2>$null

            if ("$phase".Trim() -eq "Succeeded") {
                $redisFinished = $true
                break
            }

            if ("$phase".Trim() -eq "Failed") {
                break
            }

            Start-Sleep -Seconds 2
        }

        $redisOutput = & kubectl logs $redisTestPod `
            -n $Namespace `
            2>$null

        if (-not $redisFinished -or (($redisOutput -join "`n").Trim() -ne "PONG")) {
            throw "Redis não respondeu PONG."
        }

        Write-Ok "Redis respondeu PONG."

        Write-Host "Validando cache do evaluation-service..." -ForegroundColor Yellow

        $cacheResult = Invoke-Endpoint `
            -Name "Evaluation - Segunda avaliação para validar cache" `
            -Method "GET" `
            -Url $evaluateUrl `
            -ExpectedStatus @(200)

        if (-not $cacheResult.Success) {
            throw "Falha ao executar segunda avaliação para validar o Redis."
        }

        Start-Sleep -Seconds 1

        $evaluationLogs = & kubectl logs `
            -n $Namespace `
            deployment/evaluation-service `
            --since=30s `
            2>$null

        if (($evaluationLogs -join "`n") -match "Cache HIT") {
            Write-Ok "Cache HIT identificado no evaluation-service."
        }
        else {
            Write-Warn "Redis respondeu PONG, mas não encontrei 'Cache HIT' nos logs recentes."
        }
    }
    finally {
        & kubectl delete pod $redisTestPod `
            -n $Namespace `
            --ignore-not-found=true `
            --wait=false `
            2>$null | Out-Null
    }

    Write-Section "7 - TESTANDO SQS"

    $sqsUrl = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.AWS_SQS_URL}'

    if ([string]::IsNullOrWhiteSpace($sqsUrl)) {
        throw "AWS_SQS_URL não encontrada no ConfigMap app-configmap."
    }

    Write-Host "Validando fila SQS..." -ForegroundColor Yellow

    $sqsAttributesJson = & aws sqs get-queue-attributes `
        --queue-url $sqsUrl `
        --attribute-names `
            ApproximateNumberOfMessages `
            ApproximateNumberOfMessagesNotVisible `
            ApproximateNumberOfMessagesDelayed `
        --region $AwsRegion `
        --output json `
        2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($sqsAttributesJson -join "`n"))) {
        throw "Não foi possível consultar a fila SQS."
    }

    $sqsAttributes = ($sqsAttributesJson -join "`n") | ConvertFrom-Json

    Write-Ok "Fila SQS acessível."
    Write-Host "Mensagens disponíveis: $($sqsAttributes.Attributes.ApproximateNumberOfMessages)"
    Write-Host "Mensagens em processamento: $($sqsAttributes.Attributes.ApproximateNumberOfMessagesNotVisible)"
    Write-Host "Mensagens atrasadas: $($sqsAttributes.Attributes.ApproximateNumberOfMessagesDelayed)"

    $sqsTestUser = "sqs-test-" + (Get-Date -Format "yyyyMMddHHmmss")

    $sqsEvaluateUrl = Join-ExternalUrl `
        -BaseUrl $evaluationRoute.BaseUrl `
        -IngressPath $evaluationRoute.Path `
        -Endpoint "/evaluate?user_id=$sqsTestUser&flag_name=$FlagName"

    $sqsEvaluationResult = Invoke-Endpoint `
        -Name "Evaluation - Gerar evento para SQS" `
        -Method "GET" `
        -Url $sqsEvaluateUrl `
        -ExpectedStatus @(200)

    if (-not $sqsEvaluationResult.Success) {
        throw "Não foi possível gerar o evento de teste para a SQS."
    }

    Write-Ok "Evento de avaliação gerado para o fluxo SQS."

    Write-Section "8 - TESTANDO ANALYTICS E DYNAMODB"

    if (-not $routes.ContainsKey("Analytics")) {
        throw "Não encontrei a rota do analytics-service."
    }

    $analyticsRoute = $routes["Analytics"]

    $analyticsHealth = Join-ExternalUrl `
        -BaseUrl $analyticsRoute.BaseUrl `
        -IngressPath $analyticsRoute.Path `
        -Endpoint "/health"

    $analyticsHealthResult = Invoke-Endpoint `
        -Name "Analytics - Health" `
        -Method "GET" `
        -Url $analyticsHealth `
        -ExpectedStatus @(200)

    if (-not $analyticsHealthResult.Success) {
        throw "Analytics health check falhou."
    }

    $dynamoTable = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.AWS_DYNAMODB_TABLE}'

    if ([string]::IsNullOrWhiteSpace($dynamoTable)) {
        throw "AWS_DYNAMODB_TABLE não encontrada no ConfigMap app-configmap."
    }

    Write-Host "Validando tabela DynamoDB..." -ForegroundColor Yellow

    $tableJson = & aws dynamodb describe-table `
        --table-name $dynamoTable `
        --region $AwsRegion `
        --output json `
        2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($tableJson -join "`n"))) {
        throw "Não foi possível consultar a tabela DynamoDB '$dynamoTable'."
    }

    $tableInfo = ($tableJson -join "`n") | ConvertFrom-Json

    if ($tableInfo.Table.TableStatus -ne "ACTIVE") {
        throw "Tabela DynamoDB '$dynamoTable' não está ACTIVE."
    }

    Write-Ok "DynamoDB $dynamoTable está ACTIVE."

    $beforeCountJson = & aws dynamodb scan `
        --table-name $dynamoTable `
        --region $AwsRegion `
        --select COUNT `
        --output json `
        2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível contar os registros atuais do DynamoDB."
    }

    $beforeCount = [int](($beforeCountJson -join "`n") | ConvertFrom-Json).Count

    Write-Host "Registros antes do teste: $beforeCount"

    $dynamoTestUser = "dynamo-test-" + (Get-Date -Format "yyyyMMddHHmmss")

    $dynamoEvaluateUrl = Join-ExternalUrl `
        -BaseUrl $evaluationRoute.BaseUrl `
        -IngressPath $evaluationRoute.Path `
        -Endpoint "/evaluate?user_id=$dynamoTestUser&flag_name=$FlagName"

    $dynamoEvaluationResult = Invoke-Endpoint `
        -Name "Evaluation - Gerar evento para DynamoDB" `
        -Method "GET" `
        -Url $dynamoEvaluateUrl `
        -ExpectedStatus @(200)

    if (-not $dynamoEvaluationResult.Success) {
        throw "Não foi possível gerar o evento para testar Analytics/DynamoDB."
    }

    Write-Host "Aguardando Analytics consumir SQS e persistir no DynamoDB..." -ForegroundColor Yellow

    $dynamoPersisted = $false
    $afterCount = $beforeCount

    for ($attempt = 1; $attempt -le 8; $attempt++) {
        Start-Sleep -Seconds 5

        $afterCountJson = & aws dynamodb scan `
            --table-name $dynamoTable `
            --region $AwsRegion `
            --select COUNT `
            --output json `
            2>$null

        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $afterCount = [int](($afterCountJson -join "`n") | ConvertFrom-Json).Count

        if ($afterCount -gt $beforeCount) {
            $dynamoPersisted = $true
            break
        }
    }

    $analyticsLogs = & kubectl logs `
        -n $Namespace `
        deployment/analytics-service `
        --since=90s `
        2>$null

    $relevantAnalyticsLogs = @(
        $analyticsLogs |
            Select-String -Pattern "Recebidas|Processando|DynamoDB|salvo"
    )

    if ($relevantAnalyticsLogs.Count -gt 0) {
        Write-Host ""
        Write-Host "Logs recentes do Analytics:" -ForegroundColor DarkGray

        foreach ($logLine in $relevantAnalyticsLogs) {
            Write-Host $logLine.Line -ForegroundColor DarkGray
        }
    }

    if (-not $dynamoPersisted) {
        throw "O DynamoDB não recebeu novo registro dentro do tempo esperado."
    }

    Write-Ok "Analytics consumiu o fluxo e o DynamoDB recebeu novo registro."
    Write-Host "Registros antes:  $beforeCount"
    Write-Host "Registros depois: $afterCount"

    Write-Section "TESTE FINALIZADO"

    Write-Ok "Fluxo de endpoints e infraestrutura AWS concluído."
    Write-Host ""
    Write-Host "Flag utilizada: $FlagName"
    Write-Host "Usuário teste:  $TestUserId"
    Write-Host ""
    Write-Host "Infraestrutura validada:"
    Write-Host "  Redis    -> PONG / Cache"
    Write-Host "  SQS      -> fila acessível / evento gerado"
    Write-Host "  Analytics -> worker saudável"
    Write-Host "  DynamoDB -> tabela ACTIVE / novo registro persistido"
}
catch {
    Write-Host ""
    Write-Fail $_.Exception.Message
    exit 1
}
