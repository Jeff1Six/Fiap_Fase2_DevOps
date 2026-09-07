param(
    [string]$Namespace = "desafio3",
    [int]$IntervaloSegundos = 5,
    [string]$AwsRegion = "us-east-1",
    [string]$ClusterName = "togglemaster-dev",
    [switch]$AtualizarKubeconfig
)

$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host "========================================="
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================="
}

function Get-InternalServiceUrls {
    param(
        [string]$Namespace
    )

    $servicesJson = kubectl get svc -n $Namespace -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($servicesJson)) {
        return @()
    }

    $services = $servicesJson | ConvertFrom-Json
    $result = @()

    foreach ($svc in @($services.items)) {
        $name = $svc.metadata.name
        $type = $svc.spec.type

        foreach ($port in @($svc.spec.ports)) {
            $scheme = "http"

            if ($port.name -match "https" -or $port.port -eq 443) {
                $scheme = "https"
            }

            $internalUrl = "${scheme}://${name}.${Namespace}.svc.cluster.local:$($port.port)"

            $result += [PSCustomObject]@{
                Tipo    = "Interna"
                Recurso = "Service"
                Nome    = $name
                URL     = $internalUrl
            }

            if ($type -eq "LoadBalancer") {
                $externalAddress = $null

                if ($svc.status.loadBalancer.ingress) {
                    $lb = $svc.status.loadBalancer.ingress[0]

                    if ($lb.hostname) {
                        $externalAddress = $lb.hostname
                    }
                    elseif ($lb.ip) {
                        $externalAddress = $lb.ip
                    }
                }

                if ($externalAddress) {
                    $externalUrl = "${scheme}://${externalAddress}:$($port.port)"

                    $result += [PSCustomObject]@{
                        Tipo    = "Externa"
                        Recurso = "Service/LoadBalancer"
                        Nome    = $name
                        URL     = $externalUrl
                    }
                }
            }
        }
    }

    return $result
}

function Get-IngressUrls {
    param(
        [string]$Namespace
    )

    $ingressJson = kubectl get ingress -n $Namespace -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ingressJson)) {
        return @()
    }

    $ingresses = $ingressJson | ConvertFrom-Json
    $result = @()

    foreach ($ing in @($ingresses.items)) {
        $name = $ing.metadata.name
        $externalAddress = $null

        if ($ing.status.loadBalancer.ingress) {
            $lb = $ing.status.loadBalancer.ingress[0]

            if ($lb.hostname) {
                $externalAddress = $lb.hostname
            }
            elseif ($lb.ip) {
                $externalAddress = $lb.ip
            }
        }

        $tlsHosts = @()

        foreach ($tls in @($ing.spec.tls)) {
            foreach ($tlsHost in @($tls.hosts)) {
                if (-not [string]::IsNullOrWhiteSpace($tlsHost)) {
                    $tlsHosts += $tlsHost
                }
            }
        }

        foreach ($rule in @($ing.spec.rules)) {
            # NÃO usar $Host: é uma variável automática somente leitura do PowerShell.
            $ingressHost = $rule.host

            if ([string]::IsNullOrWhiteSpace($ingressHost) -or $ingressHost -eq "*") {
                $ingressHost = $externalAddress
            }

            if ([string]::IsNullOrWhiteSpace($ingressHost)) {
                $result += [PSCustomObject]@{
                    Tipo    = "Pendente"
                    Recurso = "Ingress"
                    Nome    = $name
                    URL     = "Aguardando ADDRESS/hostname do Ingress"
                }
                continue
            }

            $scheme = "http"

            if ($tlsHosts -contains $rule.host) {
                $scheme = "https"
            }

            $paths = @($rule.http.paths)

            if ($paths.Count -eq 0) {
                $result += [PSCustomObject]@{
                    Tipo    = "Externa"
                    Recurso = "Ingress"
                    Nome    = $name
                    URL     = "${scheme}://${ingressHost}/"
                }
                continue
            }

            foreach ($pathItem in $paths) {
                $ingressPath = $pathItem.path

                if ([string]::IsNullOrWhiteSpace($ingressPath)) {
                    $ingressPath = "/"
                }

                $result += [PSCustomObject]@{
                    Tipo    = "Externa"
                    Recurso = "Ingress"
                    Nome    = $name
                    URL     = "${scheme}://${ingressHost}${ingressPath}"
                }
            }
        }
    }

    return $result
}

try {
    if ($AtualizarKubeconfig) {
        Write-Section "Atualizando kubeconfig"

        aws eks update-kubeconfig `
            --region $AwsRegion `
            --name $ClusterName

        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao atualizar o kubeconfig."
        }
    }

    Write-Section "Validando cluster"

    $Context = kubectl config current-context

    if ($LASTEXITCODE -ne 0) {
        throw "Não foi possível obter o contexto atual do Kubernetes."
    }

    kubectl get namespace $Namespace | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Namespace '$Namespace' não encontrado."
    }

    Write-Host "Contexto atual: $Context"
    Write-Host "Namespace:      $Namespace"
    Write-Host "Atualização:    a cada ${IntervaloSegundos}s"
    Write-Host ""
    Write-Host "Pressione Ctrl+C para encerrar." -ForegroundColor Yellow

    Start-Sleep -Seconds 2

    while ($true) {
        Clear-Host

        Write-Host "============================================================"
        Write-Host " KUBERNETES - MONITORAMENTO DO AMBIENTE" -ForegroundColor Green
        Write-Host "============================================================"
        Write-Host "Contexto:   $Context"
        Write-Host "Namespace:  $Namespace"
        Write-Host "Atualizado: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
        Write-Host "============================================================"

        Write-Section "PODS"

        $podsText = kubectl get pods `
            -n $Namespace `
            -o custom-columns="NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount,IP:.status.podIP,NODE:.spec.nodeName" `
            2>$null

        if ($LASTEXITCODE -eq 0 -and $podsText) {
            $podsText
        }
        else {
            Write-Host "Nenhum Pod encontrado." -ForegroundColor Yellow
        }

        Write-Section "REPLICAS / DEPLOYMENTS"

        $deploymentsText = kubectl get deployments `
            -n $Namespace `
            -o custom-columns="NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,UPDATED:.status.updatedReplicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas" `
            2>$null

        if ($LASTEXITCODE -eq 0 -and $deploymentsText) {
            $deploymentsText
        }
        else {
            Write-Host "Nenhum Deployment encontrado." -ForegroundColor Yellow
        }

        Write-Section "HPA / ESCALABILIDADE"

        $hpa = kubectl get hpa -n $Namespace 2>$null

        if ($LASTEXITCODE -eq 0 -and $hpa) {
            $hpa
        }
        else {
            Write-Host "Nenhum HPA encontrado." -ForegroundColor DarkGray
        }

        Write-Section "SERVICOS"

        $servicesText = kubectl get svc -n $Namespace -o wide 2>$null

        if ($LASTEXITCODE -eq 0 -and $servicesText) {
            $servicesText
        }
        else {
            Write-Host "Nenhum Service encontrado." -ForegroundColor Yellow
        }

        Write-Section "INGRESS"

        $ingress = kubectl get ingress -n $Namespace -o wide 2>$null

        if ($LASTEXITCODE -eq 0 -and $ingress) {
            $ingress
        }
        else {
            Write-Host "Nenhum Ingress encontrado." -ForegroundColor DarkGray
        }

        Write-Section "URLS"

        $urls = @()
        $urls += @(Get-InternalServiceUrls -Namespace $Namespace)
        $urls += @(Get-IngressUrls -Namespace $Namespace)

        if ($urls.Count -gt 0) {
            $urls |
                Sort-Object Tipo, Recurso, Nome, URL -Unique |
                Format-Table Tipo, Recurso, Nome, URL -AutoSize
        }
        else {
            Write-Host "Nenhuma URL encontrada no momento." -ForegroundColor Yellow
        }

        Write-Section "STATUS RESUMIDO"

        $podsJsonText = kubectl get pods -n $Namespace -o json 2>$null

        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($podsJsonText)) {
            $podsJson = $podsJsonText | ConvertFrom-Json
            $podItems = @($podsJson.items)

            if ($podItems.Count -gt 0) {
                $totalPods = $podItems.Count

                $runningPods = @(
                    $podItems | Where-Object {
                        $_.status.phase -eq "Running"
                    }
                ).Count

                $readyPods = @(
                    $podItems | Where-Object {
                        $statuses = @($_.status.containerStatuses)

                        $statuses.Count -gt 0 -and
                        @($statuses | Where-Object { -not $_.ready }).Count -eq 0
                    }
                ).Count

                Write-Host "Pods totais:   $totalPods"
                Write-Host "Pods Running:  $runningPods"

                if ($readyPods -eq $totalPods) {
                    Write-Host "Pods Ready:    $readyPods/$totalPods OK" -ForegroundColor Green
                }
                else {
                    Write-Host "Pods Ready:    $readyPods/$totalPods" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "Nenhum Pod encontrado." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Não foi possível consultar os Pods." -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "Próxima atualização em ${IntervaloSegundos}s | Ctrl+C para sair" -ForegroundColor DarkGray

        Start-Sleep -Seconds $IntervaloSegundos
    }
}
catch {
    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
