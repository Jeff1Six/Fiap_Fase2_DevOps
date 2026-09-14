param(
    [string]$Namespace = "desafio3",
    [string]$IngressName = "toggle-master-ingress",
    [string]$AwsRegion = "us-east-1",
    [string]$ClusterName = "togglemaster-dev",
    [string]$MasterKey = "admin-secreto-123",
    [string]$FlagName = "enable-new-dashboard",
    [string]$TestUserId = "user-123",
    [switch]$AtualizarKubeconfig,
    [switch]$SemPausa,
    [int]$HpaLoadPods = 5,
    [int]$HpaMaxWaitSeconds = 180
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Resultados = @()
$script:ApiKey = $null
$script:Routes = @{}
$script:IngressAddress = $null
$script:EvaluationUrl = $null
$script:InicioTeste = Get-Date

function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Magenta
    Write-Host "            TOGGLE MASTER - FIAP - PARTE 3" -ForegroundColor Magenta
    Write-Host "          CENARIOS DE TESTE PARA GRAVACAO" -ForegroundColor Magenta
    Write-Host "==============================================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Cluster:    $ClusterName"
    Write-Host "Namespace:  $Namespace"
    Write-Host "Regiao AWS: $AwsRegion"
    Write-Host "Flag:       $FlagName"
    Write-Host "Usuario:    $TestUserId"
    Write-Host ""
}

function Write-Scenario {
    param(
        [int]$Numero,
        [string]$Titulo,
        [string]$Objetivo
    )

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ("CENARIO {0} - {1}" -f $Numero, $Titulo) -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "Objetivo: $Objetivo" -ForegroundColor DarkGray
    Write-Host ""
}

function Write-Ok {
    param([string]$Texto)
    Write-Host "[OK] $Texto" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Texto)
    Write-Host "[AVISO] $Texto" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Texto)
    Write-Host "[ERRO] $Texto" -ForegroundColor Red
}

function Wait-Video {
    param([string]$Proximo)

    if ($SemPausa) {
        return
    }

    Write-Host ""
    Read-Host "Pressione ENTER para $Proximo" | Out-Null
}

function Add-Resultado {
    param(
        [string]$Cenario,
        [bool]$Sucesso,
        [string]$Detalhe
    )

    $script:Resultados += [PSCustomObject]@{
        Cenario = $Cenario
        Status  = if ($Sucesso) { "APROVADO" } else { "FALHOU" }
        Detalhe = $Detalhe
    }
}

function Invoke-NativeJson {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    $output = & $Command @Arguments 2>$null

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $text = ($output -join "`n").Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return $text | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-IngressRoutes {
    $ingress = Invoke-NativeJson `
        -Command "kubectl" `
        -Arguments @("get", "ingress", $IngressName, "-n", $Namespace, "-o", "json")

    if (-not $ingress) {
        throw "Ingress '$IngressName' nao encontrado no namespace '$Namespace'."
    }

    $address = $null

    if ($ingress.status.loadBalancer.ingress) {
        $lb = $ingress.status.loadBalancer.ingress[0]

        if ($lb.hostname) {
            $address = [string]$lb.hostname
        }
        elseif ($lb.ip) {
            $address = [string]$lb.ip
        }
    }

    if ([string]::IsNullOrWhiteSpace($address)) {
        throw "O Ingress existe, mas ainda nao possui ADDRESS publico."
    }

    $script:IngressAddress = $address
    $routes = @{}

    foreach ($rule in @($ingress.spec.rules)) {
        $hostName = [string]$rule.host

        if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName -eq "*") {
            $hostName = $address
        }

        # O Ingress atual esta publicado apenas em HTTP/porta 80.
        # Quando rule.host e spec.tls sao nulos, o PowerShell pode considerar
        # "$null -contains $null" como verdadeiro e selecionar HTTPS por engano.
        # Portanto, so usamos HTTPS quando existir configuracao TLS real.
        $scheme = "http"

        $tlsEntries = @(
            $ingress.spec.tls | Where-Object {
                $null -ne $_ -and (
                    -not [string]::IsNullOrWhiteSpace([string]$_.secretName) -or
                    @($_.hosts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0
                )
            }
        )

        if ($tlsEntries.Count -gt 0) {
            $scheme = "https"
        }

        foreach ($pathItem in @($rule.http.paths)) {
            $service = [string]$pathItem.backend.service.name
            $path = [string]$pathItem.path

            $prefix = $path
            $prefix = $prefix -replace '\(\.\*\).*$', ''
            $prefix = $prefix -replace '\(/\|\$\).*$', ''
            $prefix = $prefix -replace '\(\.\*\)', ''
            $prefix = $prefix.TrimEnd('/')

            $routes[$service] = [PSCustomObject]@{
                Service = $service
                Prefix  = $prefix
                BaseUrl = "${scheme}://${hostName}"
                Path    = $path
            }
        }
    }

    return $routes
}

function Get-RouteByService {
    param([string]$ServiceName)

    if ($script:Routes.ContainsKey($ServiceName)) {
        return $script:Routes[$ServiceName]
    }

    $match = $script:Routes.Keys |
        Where-Object { $_ -like "$ServiceName*" } |
        Select-Object -First 1

    if ($match) {
        return $script:Routes[$match]
    }

    throw "Rota do servico '$ServiceName' nao encontrada no Ingress."
}

function Join-Url {
    param(
        [object]$Route,
        [string]$Endpoint
    )

    if (-not $Endpoint.StartsWith("/")) {
        $Endpoint = "/$Endpoint"
    }

    return "$($Route.BaseUrl)$($Route.Prefix)$Endpoint"
}

function Invoke-Api {
    param(
        [string]$Nome,
        [ValidateSet("GET", "POST", "PUT", "DELETE", "PATCH")]
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers = @{},
        [object]$Body = $null,
        [int[]]$ExpectedStatus = @(200),
        [switch]$OcultarResposta
    )

    Write-Host "[$Method] $Nome" -ForegroundColor White
    Write-Host "      $Url" -ForegroundColor DarkGray

    $params = @{
        Uri         = $Url
        Method      = $Method
        Headers     = $Headers
        TimeoutSec      = 30
        ErrorAction     = "Stop"
        UseBasicParsing = $true
    }

    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }

    try {
        $response = Invoke-WebRequest @params
        $statusCode = [int]$response.StatusCode
        $content = [string]$response.Content

        if ($ExpectedStatus -notcontains $statusCode) {
            throw "HTTP $statusCode. Esperado: $($ExpectedStatus -join ', ')."
        }

        Write-Ok "HTTP $statusCode"

        if (-not $OcultarResposta -and -not [string]::IsNullOrWhiteSpace($content)) {
            try {
                $json = $content | ConvertFrom-Json
                $json | ConvertTo-Json -Depth 10 | Write-Host
            }
            catch {
                Write-Host $content
            }
        }

        return [PSCustomObject]@{
            Success    = $true
            StatusCode = $statusCode
            Content    = $content
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

        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $content = [string]$_.ErrorDetails.Message
        }

        if ($statusCode -and ($ExpectedStatus -contains $statusCode)) {
            Write-Ok "HTTP $statusCode"

            if (-not $OcultarResposta -and -not [string]::IsNullOrWhiteSpace($content)) {
                Write-Host $content
            }

            return [PSCustomObject]@{
                Success    = $true
                StatusCode = $statusCode
                Content    = $content
            }
        }

        if ($statusCode) {
            throw "${Nome}: HTTP $statusCode. $content"
        }

        throw "${Nome}: $($_.Exception.Message)"
    }
}

function Get-PlainTextFromSecureString {
    param([Security.SecureString]$SecureString)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Ensure-MasterKey {
    if (-not [string]::IsNullOrWhiteSpace($script:MasterKey)) {
        return
    }

    $secure = Read-Host "Informe a Master Key do auth-service" -AsSecureString
    $script:MasterKey = Get-PlainTextFromSecureString -SecureString $secure

    if ([string]::IsNullOrWhiteSpace($script:MasterKey)) {
        throw "Master Key nao informada."
    }
}

function Test-DeploymentsReady {
    $expected = @(
        "auth-service",
        "flag-service",
        "targeting-service",
        "evaluation-service",
        "analytics-service"
    )

    $deployments = Invoke-NativeJson `
        -Command "kubectl" `
        -Arguments @("get", "deployments", "-n", $Namespace, "-o", "json")

    if (-not $deployments) {
        throw "Nao foi possivel consultar os deployments."
    }

    foreach ($name in $expected) {
        $deployment = @($deployments.items | Where-Object { $_.metadata.name -eq $name }) | Select-Object -First 1

        if (-not $deployment) {
            throw "Deployment '$name' nao encontrado."
        }

        $available = [int]($deployment.status.availableReplicas | ForEach-Object { if ($_){$_}else{0} })

        if ($available -lt 1) {
            throw "Deployment '$name' nao possui replicas disponiveis."
        }
    }
}

function Set-EvaluationApiKey {
    param([string]$ApiKey)

    $secretName = "evaluation-api-key"

    $secretYaml = & kubectl create secret generic $secretName `
        -n $Namespace `
        --from-literal="SERVICE_API_KEY=$ApiKey" `
        --dry-run=client `
        -o yaml

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($secretYaml -join "`n"))) {
        throw "Nao foi possivel gerar o Secret runtime '$secretName'."
    }

    $secretYaml | & kubectl apply -f - | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Nao foi possivel aplicar o Secret runtime '$secretName'."
    }

    & kubectl rollout restart deployment/evaluation-service -n $Namespace | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao reiniciar evaluation-service."
    }

    Write-Host "Aguardando rollout do evaluation-service..." -ForegroundColor Yellow

    & kubectl rollout status deployment/evaluation-service `
        -n $Namespace `
        --timeout=120s | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "evaluation-service nao ficou Ready dentro do tempo esperado."
    }

    Start-Sleep -Seconds 2
}

function Test-RedisPing {
    $redisHost = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.REDIS_HOST}'

    $redisPort = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.REDIS_PORT}'

    if ([string]::IsNullOrWhiteSpace($redisHost) -or [string]::IsNullOrWhiteSpace($redisPort)) {
        throw "REDIS_HOST ou REDIS_PORT nao encontrados no ConfigMap app-configmap."
    }

    $podName = "redis-video-" + (Get-Random -Minimum 1000 -Maximum 9999)

    try {
        & kubectl run $podName `
            -n $Namespace `
            --restart=Never `
            --image=redis:7-alpine `
            --command `
            -- redis-cli -h $redisHost -p $redisPort ping | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Nao foi possivel criar o Pod temporario de teste do Redis."
        }

        $finished = $false

        for ($i = 1; $i -le 45; $i++) {
            $phase = & kubectl get pod $podName `
                -n $Namespace `
                -o jsonpath='{.status.phase}' `
                2>$null

            if ("$phase".Trim() -eq "Succeeded") {
                $finished = $true
                break
            }

            if ("$phase".Trim() -eq "Failed") {
                break
            }

            Start-Sleep -Seconds 2
        }

        $logs = & kubectl logs $podName -n $Namespace 2>$null
        $result = ($logs -join "`n").Trim()

        if (-not $finished -or $result -ne "PONG") {
            throw "Redis nao respondeu PONG. Retorno: $result"
        }

        Write-Ok "Redis respondeu PONG"
    }
    finally {
        & kubectl delete pod $podName `
            -n $Namespace `
            --ignore-not-found=true `
            --wait=false `
            2>$null | Out-Null
    }
}

# ==============================================================
# INICIO
# ==============================================================

Write-Banner

try {
    if ($AtualizarKubeconfig) {
        Write-Host "Atualizando kubeconfig do EKS..." -ForegroundColor Yellow
        & aws eks update-kubeconfig --region $AwsRegion --name $ClusterName | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao atualizar kubeconfig."
        }

        Write-Ok "Kubeconfig atualizado"
    }

    $script:Routes = Get-IngressRoutes
    Write-Ok "Ingress encontrado: $script:IngressAddress"

    $firstRoute = $script:Routes.Values | Select-Object -First 1
    if ($firstRoute) {
        $protocol = (($firstRoute.BaseUrl -split ':')[0]).ToUpper()
        Write-Ok "Protocolo externo detectado: $protocol"
    }
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}

# ==============================================================
# CENARIO 1 - KUBERNETES / EKS
# ==============================================================

Wait-Video "executar o CENARIO 1 - Kubernetes / EKS"
Write-Scenario `
    -Numero 1 `
    -Titulo "KUBERNETES / EKS" `
    -Objetivo "Comprovar que os cinco microsservicos estao implantados e disponiveis."

try {
    & kubectl get pods `
        -n $Namespace `
        -l 'app in (analytics-service,auth-service,evaluation-service,flag-service,targeting-service)' `
        -o wide
    Write-Host ""
    & kubectl get svc -n $Namespace
    Write-Host ""
    & kubectl get ingress $IngressName -n $Namespace

    Test-DeploymentsReady

    Write-Ok "Auth, Flag, Targeting, Evaluation e Analytics estao disponiveis no EKS."
    Add-Resultado "1 - Kubernetes / EKS" $true "5 microsservicos disponiveis"
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "1 - Kubernetes / EKS" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 2 - HEALTH CHECK
# ==============================================================

Wait-Video "executar o CENARIO 2 - Health Check"
Write-Scenario `
    -Numero 2 `
    -Titulo "HEALTH CHECK DOS MICROSSERVICOS" `
    -Objetivo "Validar o acesso externo via Ingress e o endpoint /health de todos os servicos."

try {
    $serviceMap = [ordered]@{
        "Auth"       = "auth-service"
        "Flag"       = "flag-service"
        "Targeting"  = "targeting-service"
        "Evaluation" = "evaluation-service"
        "Analytics"  = "analytics-service"
    }

    foreach ($item in $serviceMap.GetEnumerator()) {
        $route = Get-RouteByService -ServiceName $item.Value
        $url = Join-Url -Route $route -Endpoint "/health"

        Invoke-Api `
            -Nome "$($item.Key) - Health" `
            -Method GET `
            -Url $url `
            -ExpectedStatus @(200) | Out-Null

        Write-Host ""
    }

    Write-Ok "Os cinco health checks retornaram HTTP 200."
    Add-Resultado "2 - Health Check" $true "5/5 endpoints HTTP 200"
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "2 - Health Check" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 3 - AUTH SERVICE
# ==============================================================

Wait-Video "executar o CENARIO 3 - Auth Service"
Write-Scenario `
    -Numero 3 `
    -Titulo "AUTH SERVICE" `
    -Objetivo "Criar uma API Key e validar a autenticacao utilizada pelos demais microsservicos."

try {
    Ensure-MasterKey

    $authRoute = Get-RouteByService -ServiceName "auth-service"
    $createKeyUrl = Join-Url -Route $authRoute -Endpoint "/admin/keys"
    $validateUrl = Join-Url -Route $authRoute -Endpoint "/validate"
    $keyName = "video-parte3-" + (Get-Date -Format "yyyyMMdd-HHmmss")

    $keyResult = Invoke-Api `
        -Nome "Criar API Key" `
        -Method POST `
        -Url $createKeyUrl `
        -Headers @{ Authorization = "Bearer $script:MasterKey" } `
        -Body @{ name = $keyName } `
        -ExpectedStatus @(200, 201) `
        -OcultarResposta

    $keyJson = $keyResult.Content | ConvertFrom-Json
    $script:ApiKey = [string]$keyJson.key

    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        throw "O Auth respondeu sem o campo 'key'."
    }

    $maskedKey = if ($script:ApiKey.Length -ge 8) {
        $script:ApiKey.Substring(0, 4) + "..." + $script:ApiKey.Substring($script:ApiKey.Length - 4)
    }
    else {
        "********"
    }

    Write-Ok "API Key criada: $maskedKey"
    Write-Host ""

    Invoke-Api `
        -Nome "Validar API Key" `
        -Method GET `
        -Url $validateUrl `
        -Headers @{ Authorization = "Bearer $script:ApiKey" } `
        -ExpectedStatus @(200) | Out-Null

    Write-Ok "Autenticacao validada com sucesso."
    Add-Resultado "3 - Auth Service" $true "API Key criada e validada"
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "3 - Auth Service" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 4 - FLAG SERVICE
# ==============================================================

Wait-Video "executar o CENARIO 4 - Flag Service"
Write-Scenario `
    -Numero 4 `
    -Titulo "FLAG SERVICE" `
    -Objetivo "Cadastrar e consultar a feature flag usada na demonstracao."

try {
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        throw "API Key nao disponivel. Execute o Cenario 3 com sucesso."
    }

    $flagRoute = Get-RouteByService -ServiceName "flag-service"
    $flagsUrl = Join-Url -Route $flagRoute -Endpoint "/flags"

    $createFlag = Invoke-Api `
        -Nome "Criar feature flag '$FlagName'" `
        -Method POST `
        -Url $flagsUrl `
        -Headers @{ Authorization = "Bearer $script:ApiKey" } `
        -Body @{
            name        = $FlagName
            description = "Flag utilizada na gravacao da Parte 3"
            is_enabled  = $true
        } `
        -ExpectedStatus @(200, 201, 409)

    if ($createFlag.StatusCode -eq 409) {
        Write-Warn "A flag ja existia. O teste continuara usando o cadastro atual."
    }

    Write-Host ""

    Invoke-Api `
        -Nome "Listar feature flags" `
        -Method GET `
        -Url $flagsUrl `
        -Headers @{ Authorization = "Bearer $script:ApiKey" } `
        -ExpectedStatus @(200) | Out-Null

    Write-Ok "Flag '$FlagName' disponivel para uso."
    Add-Resultado "4 - Flag Service" $true "Flag criada/existente e listagem HTTP 200"
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "4 - Flag Service" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 5 - TARGETING SERVICE
# ==============================================================

Wait-Video "executar o CENARIO 5 - Targeting Service"
Write-Scenario `
    -Numero 5 `
    -Titulo "TARGETING SERVICE" `
    -Objetivo "Criar uma regra percentual de 50% e comprovar sua consulta por nome da flag."

try {
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        throw "API Key nao disponivel. Execute o Cenario 3 com sucesso."
    }

    $targetRoute = Get-RouteByService -ServiceName "targeting-service"
    $rulesUrl = Join-Url -Route $targetRoute -Endpoint "/rules"
    $getRuleUrl = Join-Url -Route $targetRoute -Endpoint "/rules/$FlagName"

    $createRule = Invoke-Api `
        -Nome "Criar regra de targeting 50%" `
        -Method POST `
        -Url $rulesUrl `
        -Headers @{ Authorization = "Bearer $script:ApiKey" } `
        -Body @{
            flag_name  = $FlagName
            is_enabled = $true
            rules      = @{
                type  = "PERCENTAGE"
                value = 50
            }
        } `
        -ExpectedStatus @(200, 201, 409)

    if ($createRule.StatusCode -eq 409) {
        Write-Warn "A regra da flag ja existia. O teste seguira consultando a regra atual."
    }

    Write-Host ""

    Invoke-Api `
        -Nome "Consultar regra '$FlagName'" `
        -Method GET `
        -Url $getRuleUrl `
        -Headers @{ Authorization = "Bearer $script:ApiKey" } `
        -ExpectedStatus @(200) | Out-Null

    Write-Ok "Regra percentual de targeting disponivel."
    Add-Resultado "5 - Targeting Service" $true "Regra PERCENTAGE 50% consultada"
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "5 - Targeting Service" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 6 - EVALUATION + REDIS
# ==============================================================

Wait-Video "executar o CENARIO 6 - Evaluation e Redis"
Write-Scenario `
    -Numero 6 `
    -Titulo "EVALUATION SERVICE + REDIS" `
    -Objetivo "Avaliar a flag, testar conectividade com o Redis e demonstrar o cache da avaliacao."

try {
    if ([string]::IsNullOrWhiteSpace($script:ApiKey)) {
        throw "API Key nao disponivel. Execute o Cenario 3 com sucesso."
    }

    Write-Host "Configurando a API Key runtime do Evaluation..." -ForegroundColor Yellow
    Set-EvaluationApiKey -ApiKey $script:ApiKey
    Write-Ok "Secret runtime aplicado sem exibir a chave."
    Write-Host ""

    $evaluationRoute = Get-RouteByService -ServiceName "evaluation-service"
    $script:EvaluationUrl = Join-Url `
        -Route $evaluationRoute `
        -Endpoint "/evaluate?user_id=$TestUserId&flag_name=$FlagName"

    $evaluationResult = Invoke-Api `
        -Nome "Avaliar feature flag" `
        -Method GET `
        -Url $script:EvaluationUrl `
        -ExpectedStatus @(200)

    $evaluationJson = $evaluationResult.Content | ConvertFrom-Json

    if ($null -eq $evaluationJson.result) {
        throw "Evaluation respondeu HTTP 200, mas nao retornou o campo 'result'."
    }

    Write-Host "Resultado da avaliacao: $($evaluationJson.result)" -ForegroundColor Cyan
    Write-Host ""

    Test-RedisPing
    Write-Host ""

    Invoke-Api `
        -Nome "Repetir avaliacao para validar cache" `
        -Method GET `
        -Url $script:EvaluationUrl `
        -ExpectedStatus @(200) | Out-Null

    Start-Sleep -Seconds 1

    $evaluationLogs = & kubectl logs `
        -n $Namespace `
        deployment/evaluation-service `
        --since=45s `
        2>$null

    if (($evaluationLogs -join "`n") -match "Cache HIT") {
        Write-Ok "Cache HIT identificado nos logs do Evaluation."
        Add-Resultado "6 - Evaluation + Redis" $true "Evaluation HTTP 200, Redis PONG e Cache HIT"
    }
    else {
        Write-Warn "Redis respondeu PONG, mas 'Cache HIT' nao apareceu nos logs recentes."
        Add-Resultado "6 - Evaluation + Redis" $true "Evaluation HTTP 200 e Redis PONG; Cache HIT nao localizado"
    }
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "6 - Evaluation + Redis" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 7 - SQS
# ==============================================================

Wait-Video "executar o CENARIO 7 - Amazon SQS"
Write-Scenario `
    -Numero 7 `
    -Titulo "AMAZON SQS" `
    -Objetivo "Gerar uma nova avaliacao e comprovar o envio/consumo do evento assincrono."

try {
    $evaluationRoute = Get-RouteByService -ServiceName "evaluation-service"
    $analyticsRoute = Get-RouteByService -ServiceName "analytics-service"

    $sqsUrl = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.AWS_SQS_URL}'

    if ([string]::IsNullOrWhiteSpace($sqsUrl)) {
        throw "AWS_SQS_URL nao encontrada no ConfigMap app-configmap."
    }

    Write-Host "Fila configurada no ambiente: OK" -ForegroundColor Green

    $queueAttributes = & aws sqs get-queue-attributes `
        --queue-url $sqsUrl `
        --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible `
        --region $AwsRegion `
        --output json `
        2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($queueAttributes -join "`n"))) {
        $queueJson = ($queueAttributes -join "`n") | ConvertFrom-Json
        Write-Host "Mensagens disponiveis:     $($queueJson.Attributes.ApproximateNumberOfMessages)"
        Write-Host "Mensagens em processamento: $($queueJson.Attributes.ApproximateNumberOfMessagesNotVisible)"
    }
    else {
        Write-Warn "AWS CLI local nao consultou os atributos; a validacao continuara pelos workloads."
    }

    $sqsUser = "video-sqs-" + (Get-Date -Format "yyyyMMddHHmmss")
    $sqsEvaluationUrl = Join-Url `
        -Route $evaluationRoute `
        -Endpoint "/evaluate?user_id=$sqsUser&flag_name=$FlagName"

    $since = (Get-Date).ToUniversalTime().AddSeconds(-2).ToString("yyyy-MM-ddTHH:mm:ssZ")

    Invoke-Api `
        -Nome "Gerar evento de avaliacao para SQS" `
        -Method GET `
        -Url $sqsEvaluationUrl `
        -ExpectedStatus @(200) | Out-Null

    Write-Host "Aguardando processamento assincrono..." -ForegroundColor Yellow
    Start-Sleep -Seconds 6

    $evaluationLogs = & kubectl logs `
        -n $Namespace `
        deployment/evaluation-service `
        "--since-time=$since" `
        2>$null

    $evaluationText = ($evaluationLogs -join "`n")

    if ($evaluationText -match "Erro ao enviar mensagem para SQS|AccessDenied|NoCredentialProviders|ExpiredToken|RequestExpired") {
        throw "O Evaluation registrou erro ao enviar o evento para a SQS."
    }

    Write-Ok "Evaluation executou sem erro de SendMessage para SQS."

    $analyticsLogs = & kubectl logs `
        -n $Namespace `
        deployment/analytics-service `
        "--since-time=$since" `
        2>$null

    $analyticsText = ($analyticsLogs -join "`n")

    if ($analyticsText -match "Recebidas|Processando mensagem") {
        Write-Ok "Analytics registrou consumo/processamento da mensagem."
        Add-Resultado "7 - Amazon SQS" $true "Evento enviado e consumo identificado no Analytics"
    }
    else {
        Write-Warn "O consumo nao apareceu no trecho de log; o Cenario 8 validara a persistencia ponta a ponta."
        Add-Resultado "7 - Amazon SQS" $true "Evaluation sem erro de envio; consumo sera confirmado no DynamoDB"
    }
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "7 - Amazon SQS" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 8 - ANALYTICS + DYNAMODB
# ==============================================================

Wait-Video "executar o CENARIO 8 - Analytics e DynamoDB"
Write-Scenario `
    -Numero 8 `
    -Titulo "ANALYTICS SERVICE + DYNAMODB" `
    -Objetivo "Comprovar o fluxo ponta a ponta: Evaluation -> SQS -> Analytics -> DynamoDB."

try {
    $analyticsRoute = Get-RouteByService -ServiceName "analytics-service"
    $analyticsHealth = Join-Url -Route $analyticsRoute -Endpoint "/health"

    Invoke-Api `
        -Nome "Analytics - Health" `
        -Method GET `
        -Url $analyticsHealth `
        -ExpectedStatus @(200) | Out-Null

    $dynamoTable = & kubectl get configmap app-configmap `
        -n $Namespace `
        -o jsonpath='{.data.AWS_DYNAMODB_TABLE}'

    if ([string]::IsNullOrWhiteSpace($dynamoTable)) {
        throw "AWS_DYNAMODB_TABLE nao encontrada no ConfigMap app-configmap."
    }

    $tableInfoRaw = & aws dynamodb describe-table `
        --table-name $dynamoTable `
        --region $AwsRegion `
        --output json `
        2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($tableInfoRaw -join "`n"))) {
        throw "Nao foi possivel consultar a tabela DynamoDB '$dynamoTable'."
    }

    $tableInfo = ($tableInfoRaw -join "`n") | ConvertFrom-Json

    if ($tableInfo.Table.TableStatus -ne "ACTIVE") {
        throw "Tabela DynamoDB '$dynamoTable' nao esta ACTIVE."
    }

    Write-Ok "DynamoDB '$dynamoTable' esta ACTIVE."

    $beforeRaw = & aws dynamodb scan `
        --table-name $dynamoTable `
        --region $AwsRegion `
        --select COUNT `
        --output json `
        2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Nao foi possivel contar os registros atuais do DynamoDB."
    }

    $beforeCount = [int](($beforeRaw -join "`n") | ConvertFrom-Json).Count
    Write-Host "Registros antes:  $beforeCount"

    $evaluationRoute = Get-RouteByService -ServiceName "evaluation-service"
    $dynamoUser = "video-dynamo-" + (Get-Date -Format "yyyyMMddHHmmss")
    $dynamoEvaluationUrl = Join-Url `
        -Route $evaluationRoute `
        -Endpoint "/evaluate?user_id=$dynamoUser&flag_name=$FlagName"

    Invoke-Api `
        -Nome "Gerar evento ponta a ponta" `
        -Method GET `
        -Url $dynamoEvaluationUrl `
        -ExpectedStatus @(200) | Out-Null

    Write-Host "Aguardando Analytics persistir o evento no DynamoDB..." -ForegroundColor Yellow

    $persisted = $false
    $afterCount = $beforeCount

    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 4

        $afterRaw = & aws dynamodb scan `
            --table-name $dynamoTable `
            --region $AwsRegion `
            --select COUNT `
            --output json `
            2>$null

        if ($LASTEXITCODE -ne 0) {
            continue
        }

        $afterCount = [int](($afterRaw -join "`n") | ConvertFrom-Json).Count

        if ($afterCount -gt $beforeCount) {
            $persisted = $true
            break
        }
    }

    Write-Host "Registros depois: $afterCount"

    if (-not $persisted) {
        throw "Nenhum novo registro apareceu no DynamoDB dentro do tempo de validacao."
    }

    Write-Ok "Fluxo ponta a ponta confirmado: Evaluation -> SQS -> Analytics -> DynamoDB."
    Add-Resultado "8 - Analytics + DynamoDB" $true "Novo registro persistido no DynamoDB"
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "8 - Analytics + DynamoDB" $false $_.Exception.Message
}

# ==============================================================
# CENARIO 9 - HPA / AUTO SCALING
# ==============================================================

Wait-Video "executar o CENARIO 9 - HPA / Auto Scaling"
Write-Scenario `
    -Numero 9 `
    -Titulo "HPA / AUTO SCALING" `
    -Objetivo "Gerar carga no microsservico e comprovar o aumento automatico de replicas pelo Horizontal Pod Autoscaler."

$hpaLoadPodNames = @()

try {
    Write-Host "HPAs configurados no namespace:" -ForegroundColor Yellow
    & kubectl get hpa -n $Namespace
    Write-Host ""

    $hpaList = Invoke-NativeJson `
        -Command "kubectl" `
        -Arguments @("get", "hpa", "-n", $Namespace, "-o", "json")

    if (-not $hpaList -or @($hpaList.items).Count -eq 0) {
        throw "Nenhum HPA encontrado no namespace '$Namespace'."
    }

    # Para a demonstracao, prioriza o Evaluation porque o endpoint /evaluate
    # gera trabalho suficiente para demonstrar o scale-out.
    $hpa = @(
        $hpaList.items |
            Where-Object { $_.spec.scaleTargetRef.name -eq "evaluation-service" }
    ) | Select-Object -First 1

    if (-not $hpa) {
        $hpa = @($hpaList.items) | Select-Object -First 1
        Write-Warn "Nao encontrei HPA do evaluation-service. O teste usara o primeiro HPA disponivel."
    }

    $hpaName = [string]$hpa.metadata.name
    $targetDeployment = [string]$hpa.spec.scaleTargetRef.name
    $minReplicas = if ($null -ne $hpa.spec.minReplicas) { [int]$hpa.spec.minReplicas } else { 1 }
    $maxReplicas = [int]$hpa.spec.maxReplicas

    if ([string]::IsNullOrWhiteSpace($hpaName) -or [string]::IsNullOrWhiteSpace($targetDeployment)) {
        throw "Nao foi possivel identificar o HPA ou seu Deployment alvo."
    }

    Write-Host "HPA selecionado:    $hpaName"
    Write-Host "Deployment alvo:   $targetDeployment"
    Write-Host "Min replicas:      $minReplicas"
    Write-Host "Max replicas:      $maxReplicas"
    Write-Host "Pods de carga:     $HpaLoadPods"
    Write-Host "Tempo maximo:      $HpaMaxWaitSeconds segundos"
    Write-Host ""

    # Confirma se o HPA esta conseguindo calcular as metricas antes da carga.
    $hpaStatus = Invoke-NativeJson `
        -Command "kubectl" `
        -Arguments @("get", "hpa", $hpaName, "-n", $Namespace, "-o", "json")

    $scalingActiveCondition = @(
        $hpaStatus.status.conditions |
            Where-Object { $_.type -eq "ScalingActive" }
    ) | Select-Object -First 1

    if ($scalingActiveCondition -and $scalingActiveCondition.status -eq "False") {
        throw "HPA sem metricas ativas. Motivo: $($scalingActiveCondition.reason) - $($scalingActiveCondition.message)"
    }

    $deployment = Invoke-NativeJson `
        -Command "kubectl" `
        -Arguments @("get", "deployment", $targetDeployment, "-n", $Namespace, "-o", "json")

    if (-not $deployment) {
        throw "Deployment '$targetDeployment' nao encontrado."
    }

    $replicasAntes = if ($deployment.status.replicas) { [int]$deployment.status.replicas } else { 0 }
    $readyAntes = if ($deployment.status.readyReplicas) { [int]$deployment.status.readyReplicas } else { 0 }

    Write-Host "Replicas antes da carga: $replicasAntes (Ready: $readyAntes)" -ForegroundColor Cyan
    Write-Host ""

    # O endpoint interno evita depender do Ingress durante o teste de carga.
    if ($targetDeployment -eq "evaluation-service") {
        $targetUrl = "http://evaluation-service-svc:8080/evaluate?user_id=hpa-load-`$i&flag_name=$FlagName"
        $loadCommand = 'i=0; while true; do i=$((i+1)); wget -q -T 2 -O /dev/null "' + $targetUrl + '" || true; done'
    }
    else {
        $serviceName = "$targetDeployment-svc"
        $targetUrl = "http://${serviceName}:8080/health"
        $loadCommand = 'while true; do wget -q -T 2 -O /dev/null "' + $targetUrl + '" || true; done'
    }

    Write-Host "Gerando carga interna contra: $targetUrl" -ForegroundColor Yellow

    for ($i = 1; $i -le $HpaLoadPods; $i++) {
        $podName = "hpa-load-$i-" + (Get-Random -Minimum 1000 -Maximum 9999)
        $hpaLoadPodNames += $podName

        & kubectl run $podName `
            -n $Namespace `
            --restart=Never `
            --image=busybox:1.36 `
            --command `
            -- /bin/sh -c $loadCommand | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao criar o Pod gerador de carga '$podName'."
        }
    }

    Write-Ok "$HpaLoadPods Pods de carga criados."
    Write-Host "Aguardando o HPA detectar aumento de utilizacao..." -ForegroundColor Yellow
    Write-Host ""

    $scaled = $false
    $replicasDepois = $replicasAntes
    $desiredDepois = $replicasAntes
    $inicioHpa = Get-Date

    while (((Get-Date) - $inicioHpa).TotalSeconds -lt $HpaMaxWaitSeconds) {
        Start-Sleep -Seconds 10

        $currentHpa = Invoke-NativeJson `
            -Command "kubectl" `
            -Arguments @("get", "hpa", $hpaName, "-n", $Namespace, "-o", "json")

        $currentDeployment = Invoke-NativeJson `
            -Command "kubectl" `
            -Arguments @("get", "deployment", $targetDeployment, "-n", $Namespace, "-o", "json")

        if (-not $currentHpa -or -not $currentDeployment) {
            continue
        }

        $currentReplicas = if ($currentHpa.status.currentReplicas) { [int]$currentHpa.status.currentReplicas } else { 0 }
        $desiredReplicas = if ($currentHpa.status.desiredReplicas) { [int]$currentHpa.status.desiredReplicas } else { 0 }
        $readyReplicas = if ($currentDeployment.status.readyReplicas) { [int]$currentDeployment.status.readyReplicas } else { 0 }

        $metricText = ""
        if ($currentHpa.status.currentMetrics) {
            try {
                $metric = @($currentHpa.status.currentMetrics)[0]
                if ($metric.resource.current.averageUtilization) {
                    $metricText = " | CPU: $($metric.resource.current.averageUtilization)%"
                }
                elseif ($metric.resource.current.averageValue) {
                    $metricText = " | Metrica: $($metric.resource.current.averageValue)"
                }
            }
            catch {
                $metricText = ""
            }
        }

        Write-Host ("HPA -> Current: {0} | Desired: {1} | Ready: {2}{3}" -f `
            $currentReplicas, $desiredReplicas, $readyReplicas, $metricText)

        $replicasDepois = $currentReplicas
        $desiredDepois = $desiredReplicas

        if ($desiredReplicas -gt $replicasAntes -or $currentReplicas -gt $replicasAntes) {
            $scaled = $true
            break
        }
    }

    Write-Host ""

    if (-not $scaled) {
        Write-Warn "O HPA nao aumentou replicas dentro do tempo de teste."
        Write-Host "Diagnostico do HPA:" -ForegroundColor Yellow
        & kubectl describe hpa $hpaName -n $Namespace
        throw "HPA nao executou scale-out em ate $HpaMaxWaitSeconds segundos."
    }

    Write-Ok "Scale-out identificado pelo HPA."
    Write-Host "Replicas antes:   $replicasAntes"
    Write-Host "Current replicas: $replicasDepois"
    Write-Host "Desired replicas: $desiredDepois"
    Write-Host ""
    Write-Host "Estado atual do HPA:" -ForegroundColor Yellow
    & kubectl get hpa $hpaName -n $Namespace

    Add-Resultado `
        "9 - HPA / Auto Scaling" `
        $true `
        "Scale-out confirmado: $replicasAntes -> desired $desiredDepois replicas"
}
catch {
    Write-Fail $_.Exception.Message
    Add-Resultado "9 - HPA / Auto Scaling" $false $_.Exception.Message
}
finally {
    if ($hpaLoadPodNames.Count -gt 0) {
        Write-Host ""
        Write-Host "Removendo Pods geradores de carga..." -ForegroundColor Yellow

        foreach ($podName in $hpaLoadPodNames) {
            & kubectl delete pod $podName `
                -n $Namespace `
                --ignore-not-found=true `
                --wait=false `
                2>$null | Out-Null
        }

        Write-Ok "Carga removida. O HPA podera reduzir as replicas apos o periodo de estabilizacao."
    }
}

# ==============================================================
# RESUMO FINAL
# ==============================================================

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Magenta
Write-Host "                 RESUMO FINAL DOS TESTES" -ForegroundColor Magenta
Write-Host "==============================================================" -ForegroundColor Magenta
Write-Host ""

$script:Resultados | Format-Table -AutoSize

$total = $script:Resultados.Count
$aprovados = @($script:Resultados | Where-Object { $_.Status -eq "APROVADO" }).Count
$falhas = $total - $aprovados
$duracao = (Get-Date) - $script:InicioTeste

Write-Host "Total:     $total"
Write-Host "Aprovados: $aprovados" -ForegroundColor Green

if ($falhas -gt 0) {
    Write-Host "Falhas:    $falhas" -ForegroundColor Red
}
else {
    Write-Host "Falhas:    0" -ForegroundColor Green
}

Write-Host ("Duracao:   {0:mm\:ss}" -f $duracao)
Write-Host ""

if ($falhas -eq 0) {
    Write-Host "==============================================================" -ForegroundColor Green
    Write-Host "      TOGGLE MASTER PARTE 3 - TODOS OS CENARIOS APROVADOS" -ForegroundColor Green
    Write-Host "==============================================================" -ForegroundColor Green
    exit 0
}

Write-Host "==============================================================" -ForegroundColor Red
Write-Host "      TOGGLE MASTER PARTE 3 - EXISTEM CENARIOS COM FALHA" -ForegroundColor Red
Write-Host "==============================================================" -ForegroundColor Red
exit 1
