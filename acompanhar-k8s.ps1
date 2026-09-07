param(
    [string]$Namespace = "desafio3",
    [int]$IntervaloSegundos = 5,
    [string]$AwsRegion = "us-east-1",
    [string]$ClusterName = "togglemaster-dev",
    [switch]$AtualizarKubeconfig
)

# Evita que mensagens normais do kubectl em stderr, como
# "No resources found", encerrem o script.
$ErrorActionPreference = "Continue"

if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "========================================="
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================="
}

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & kubectl @Arguments 2>$null
    $exitCode = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = @($output)
    }
}

function Show-Resource {
    param(
        [string]$Title,
        [string[]]$Arguments,
        [string]$EmptyMessage
    )

    Write-Section $Title

    $result = Invoke-Kubectl -Arguments $Arguments

    if ($result.ExitCode -ne 0) {
        Write-Host "Falha ao consultar $Title." -ForegroundColor Red
        return
    }

    # kubectl com custom-columns pode devolver apenas o cabeçalho.
    $lines = @($result.Output | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })

    if ($lines.Count -eq 0) {
        Write-Host $EmptyMessage -ForegroundColor Yellow
        return
    }

    if ($lines.Count -eq 1 -and $lines[0] -match '^(NAME|No resources found)') {
        Write-Host $EmptyMessage -ForegroundColor Yellow
        return
    }

    $lines | ForEach-Object { Write-Host $_ }
}

function Get-ServiceUrls {
    param([string]$Namespace)

    $result = Invoke-Kubectl -Arguments @("get", "svc", "-n", $Namespace, "-o", "json")

    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
        return @()
    }

    $jsonText = ($result.Output -join "`n")

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return @()
    }

    $services = $jsonText | ConvertFrom-Json
    $urls = @()

    foreach ($svc in @($services.items)) {
        $name = $svc.metadata.name
        $type = $svc.spec.type

        foreach ($port in @($svc.spec.ports)) {
            $scheme = if ($port.port -eq 443 -or $port.name -match "https") {
                "https"
            }
            else {
                "http"
            }

            $urls += [PSCustomObject]@{
                Tipo    = "Interna"
                Recurso = "Service"
                Nome    = $name
                URL     = "${scheme}://${name}.${Namespace}.svc.cluster.local:$($port.port)"
            }

            if ($type -eq "LoadBalancer" -and $svc.status.loadBalancer.ingress) {
                $lb = $svc.status.loadBalancer.ingress[0]
                $address = if ($lb.hostname) { $lb.hostname } else { $lb.ip }

                if ($address) {
                    $urls += [PSCustomObject]@{
                        Tipo    = "Externa"
                        Recurso = "LoadBalancer"
                        Nome    = $name
                        URL     = "${scheme}://${address}:$($port.port)"
                    }
                }
            }
        }
    }

    return $urls
}

function Get-IngressUrls {
    param([string]$Namespace)

    $result = Invoke-Kubectl -Arguments @("get", "ingress", "-n", $Namespace, "-o", "json")

    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
        return @()
    }

    $jsonText = ($result.Output -join "`n")

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return @()
    }

    $ingresses = $jsonText | ConvertFrom-Json
    $urls = @()

    foreach ($ing in @($ingresses.items)) {
        $name = $ing.metadata.name
        $address = $null

        if ($ing.status.loadBalancer.ingress) {
            $lb = $ing.status.loadBalancer.ingress[0]
            $address = if ($lb.hostname) { $lb.hostname } else { $lb.ip }
        }

        foreach ($rule in @($ing.spec.rules)) {
            $ingressHost = $rule.host

            if ([string]::IsNullOrWhiteSpace($ingressHost) -or $ingressHost -eq "*") {
                $ingressHost = $address
            }

            if ([string]::IsNullOrWhiteSpace($ingressHost)) {
                $urls += [PSCustomObject]@{
                    Tipo    = "Pendente"
                    Recurso = "Ingress"
                    Nome    = $name
                    URL     = "Aguardando ADDRESS do Ingress"
                }
                continue
            }

            foreach ($pathItem in @($rule.http.paths)) {
                $path = $pathItem.path
                if ([string]::IsNullOrWhiteSpace($path)) {
                    $path = "/"
                }

                $urls += [PSCustomObject]@{
                    Tipo    = "Externa"
                    Recurso = "Ingress"
                    Nome    = $name
                    URL     = "http://${ingressHost}${path}"
                }
            }
        }
    }

    return $urls
}

try {
    if ($AtualizarKubeconfig) {
        Write-Section "ATUALIZANDO KUBECONFIG"

        & aws eks update-kubeconfig `
            --region $AwsRegion `
            --name $ClusterName

        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao atualizar o kubeconfig."
        }
    }

    $contextResult = Invoke-Kubectl -Arguments @("config", "current-context")

    if ($contextResult.ExitCode -ne 0 -or $contextResult.Output.Count -eq 0) {
        throw "Não foi possível obter o contexto Kubernetes."
    }

    $Context = $contextResult.Output[0]

    $namespaceResult = Invoke-Kubectl -Arguments @("get", "namespace", $Namespace)

    if ($namespaceResult.ExitCode -ne 0) {
        throw "Namespace '$Namespace' não encontrado."
    }

    while ($true) {
        Clear-Host

        Write-Host "============================================================"
        Write-Host " KUBERNETES - MONITORAMENTO DO AMBIENTE" -ForegroundColor Green
        Write-Host "============================================================"
        Write-Host "Contexto:   $Context"
        Write-Host "Namespace:  $Namespace"
        Write-Host "Atualizado: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
        Write-Host "============================================================"

        Show-Resource `
            -Title "PODS" `
            -Arguments @(
                "get", "pods",
                "-n", $Namespace,
                "-o", "wide"
            ) `
            -EmptyMessage "Nenhum Pod encontrado no namespace."

        Show-Resource `
            -Title "REPLICAS / DEPLOYMENTS" `
            -Arguments @(
                "get", "deployments",
                "-n", $Namespace,
                "-o",
                "custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,UPDATED:.status.updatedReplicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas"
            ) `
            -EmptyMessage "Nenhum Deployment encontrado no namespace."

        Show-Resource `
            -Title "REPLICA SETS" `
            -Arguments @(
                "get", "replicasets",
                "-n", $Namespace,
                "-o", "wide"
            ) `
            -EmptyMessage "Nenhum ReplicaSet encontrado no namespace."

        Show-Resource `
            -Title "HPA / ESCALABILIDADE" `
            -Arguments @(
                "get", "hpa",
                "-n", $Namespace
            ) `
            -EmptyMessage "Nenhum HPA encontrado no namespace."

        Show-Resource `
            -Title "SERVICOS" `
            -Arguments @(
                "get", "svc",
                "-n", $Namespace,
                "-o", "wide"
            ) `
            -EmptyMessage "Nenhum Service encontrado no namespace."

        Show-Resource `
            -Title "INGRESS" `
            -Arguments @(
                "get", "ingress",
                "-n", $Namespace,
                "-o", "wide"
            ) `
            -EmptyMessage "Nenhum Ingress encontrado no namespace."

        Write-Section "URLS"

        $urls = @()
        $urls += @(Get-ServiceUrls -Namespace $Namespace)
        $urls += @(Get-IngressUrls -Namespace $Namespace)

        if ($urls.Count -gt 0) {
            $urls |
                Sort-Object Tipo, Recurso, Nome, URL -Unique |
                Format-Table -AutoSize
        }
        else {
            Write-Host "Nenhuma URL disponível porque ainda não existem Services/Ingress com endereço." -ForegroundColor Yellow
        }

        Write-Section "DIAGNOSTICO"

        $deployResult = Invoke-Kubectl -Arguments @("get", "deployments", "-n", $Namespace, "-o", "name")
        $podResult = Invoke-Kubectl -Arguments @("get", "pods", "-n", $Namespace, "-o", "name")
        $svcResult = Invoke-Kubectl -Arguments @("get", "svc", "-n", $Namespace, "-o", "name")

        $deployCount = @($deployResult.Output | Where-Object { $_ -like "deployment.apps/*" }).Count
        $podCount = @($podResult.Output | Where-Object { $_ -like "pod/*" }).Count
        $svcCount = @($svcResult.Output | Where-Object { $_ -like "service/*" }).Count

        Write-Host "Deployments: $deployCount"
        Write-Host "Pods:        $podCount"
        Write-Host "Services:    $svcCount"

        if ($deployCount -eq 0) {
            Write-Host ""
            Write-Host "ATENCAO: o namespace existe, mas os Deployments dos microservicos ainda nao foram aplicados." -ForegroundColor Yellow
            Write-Host "Enquanto nao houver Deployment, nao havera ReplicaSet, Pod ou Service da aplicacao." -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "Atualizando novamente em ${IntervaloSegundos}s | Ctrl+C para sair" -ForegroundColor DarkGray

        Start-Sleep -Seconds $IntervaloSegundos
    }
}
catch {
    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
