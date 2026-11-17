#requires -Version 5.1
<#
.SYNOPSIS
  ToggleMaster / FIAP Fase 4 - demonstracao automatizada e evidencias.
.DESCRIPTION
  Por padrao executa apenas verificacoes de leitura.
  Para testes que provocam falhas no EKS, informe explicitamente -RunFaults.
  Nao altera os 5 Deployments da aplicacao, exceto exclusao de UM pod do flag-service
  no cenario de self-healing. O incidente utiliza um Deployment temporario isolado.
.EXAMPLE
  .\ToggleMaster-Demo-Fase4.ps1 -Scenario All
.EXAMPLE
  .\ToggleMaster-Demo-Fase4.ps1 -Scenario All -RunFaults -EvidencePauseSec 45
.EXAMPLE
  .\ToggleMaster-Demo-Fase4.ps1 -Scenario Incident -RunFaults
#>
[CmdletBinding()]
param(
    [ValidateSet('All','Overview','SelfHealing','Incident')]
    [string]$Scenario = 'All',
    [switch]$RunFaults,
    [int]$FiringTimeoutSec = 60,
    [int]$EvidencePauseSec = 45,
    [string]$Namespace = 'desafio3',
    [string]$MonitoringNamespace = 'monitoring',
    [string]$ArgoNamespace = 'argocd',
    [string]$TestImage = 'nginx:1.27-alpine',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$script:TempDeployment = 'togglemaster-alert-test'
$script:PortForward = $null
$script:OwnPortForward = $false
$script:Port = 19090
$script:TranscriptStarted = $false
$script:IncidentCreated = $false
$script:Results = New-Object System.Collections.ArrayList

if ($FiringTimeoutSec -lt 60) { throw 'Use FiringTimeoutSec de pelo menos 50 (a regra possui for: 1m).' }
if ($EvidencePauseSec -lt 0) { throw 'EvidencePauseSec nao pode ser negativo.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Get-Location).Path ('evidencias-fase4-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path

function Banner([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Title) -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}
function Info([string]$Message) { Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message) -ForegroundColor White }
function Good([string]$Message) { Write-Host ('[OK] ' + $Message) -ForegroundColor Green }
function Warn([string]$Message) { Write-Host ('[AVISO] ' + $Message) -ForegroundColor Yellow }
function Fail([string]$Message) { Write-Host ('[ERRO] ' + $Message) -ForegroundColor Red }
function Record([string]$Step, [string]$Status, [string]$Detail) {
    [void]$script:Results.Add([pscustomobject]@{Cenario=$Step; Resultado=$Status; Detalhe=$Detail; Horario=(Get-Date).ToString('o')})
}
function Cmd([string[]]$Arguments) {
    & kubectl @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('kubectl falhou (exit=' + $LASTEXITCODE + '): ' + ($Arguments -join ' ')) }
}
function Save-Cmd([string]$Filename, [string[]]$Arguments) {
    $target = Join-Path $OutputDirectory $Filename
    $result = & kubectl @Arguments 2>&1
    $result | Out-File -FilePath $target -Encoding utf8
    if ($LASTEXITCODE -ne 0) { Warn ('Nao foi possivel coletar ' + $Filename) }
    return $result
}
function Verify-Prerequisites {
    Banner '00 | PRE-CHECK: ferramentas e cluster'
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { throw 'kubectl nao encontrado no PATH.' }
    Cmd @('cluster-info')
    $context = (& kubectl config current-context)
    Info ('Contexto kubectl: ' + $context)
    if (-not ($context -match 'togglemaster-dev')) {
        Warn 'O contexto atual nao contem togglemaster-dev. Revise antes de executar falhas.'
        if ($RunFaults) { throw 'Por seguranca, RunFaults exige contexto contendo togglemaster-dev.' }
    }
    Cmd @('get','namespace',$Namespace)
    Cmd @('get','namespace',$MonitoringNamespace)
    $expected = @('auth-service','evaluation-service','flag-service','targeting-service','analytics-service')
    foreach ($d in $expected) {
        $deploymentJson = & kubectl get deployment $d -n $Namespace -o json
        if ($LASTEXITCODE -ne 0 -or -not $deploymentJson) { throw ('Falha ao consultar Deployment: ' + $d) }
        $deployment = $deploymentJson | ConvertFrom-Json
        $desired = [int]$deployment.spec.replicas
        $ready = [int]$deployment.status.readyReplicas
        $available = [int]$deployment.status.availableReplicas
        Info ($d + ': desejadas=' + $desired + ' | prontas=' + $ready + ' | disponiveis=' + $available)
        if ($desired -lt 1 -or $ready -lt $desired -or $available -lt $desired) {
            throw ('Deployment nao pronto: ' + $d + ' (desejadas=' + $desired + ', prontas=' + $ready + ', disponiveis=' + $available + ')')
        }
    }
    Good 'Cinco microsservicos prontos.'
    Record '00 - Pre-check' 'OK' 'Contexto e deployments validados'
}
function Overview {
    Banner '01 | EKS, Terraform/GitOps e microsservicos'
    Save-Cmd '01-nodes.txt' @('get','nodes','-o','wide') | Out-Host
    Save-Cmd '01-deployments.txt' @('get','deployments','-n',$Namespace,'-o','wide') | Out-Host
    Save-Cmd '01-pods.txt' @('get','pods','-n',$Namespace,'-o','wide') | Out-Host
    Save-Cmd '01-services.txt' @('get','services','-n',$Namespace) | Out-Host
    Save-Cmd '01-argocd.txt' @('get','applications','-n',$ArgoNamespace) | Out-Host
    Save-Cmd '01-images.txt' @('get','deployments','-n',$Namespace,'-o','custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image') | Out-Host
    if (Get-Command git -ErrorAction SilentlyContinue) {
        (& git rev-parse --show-toplevel 2>$null) | Out-File (Join-Path $OutputDirectory '01-git-root.txt') -Encoding utf8
        (& git log -1 --format='%h %s' 2>$null) | Out-File (Join-Path $OutputDirectory '01-git-commit.txt') -Encoding utf8
    }
    Record '01 - Infra/GitOps' 'OK' 'Inventario de nos, deployments, imagens e ArgoCD'

    Banner '02 | Observabilidade: Prometheus, Grafana, Loki, Alloy, OTel, New Relic'
    Save-Cmd '02-monitoring-pods.txt' @('get','pods','-n',$MonitoringNamespace) | Out-Host
    Save-Cmd '02-monitoring-services.txt' @('get','services','-n',$MonitoringNamespace) | Out-Host
    Save-Cmd '02-alert-rules.txt' @('get','prometheusrules','-n',$MonitoringNamespace) | Out-Host
    Save-Cmd '02-alert-routing.txt' @('get','alertmanagerconfigs','-n',$MonitoringNamespace) | Out-Host
    Save-Cmd '02-alertmanager.txt' @('get','alertmanager','-n',$MonitoringNamespace) | Out-Host
    Save-Cmd '02-otel-deployments.txt' @('get','deployments','-n',$MonitoringNamespace) | Out-Host
    Info 'Evidencia manual: abra Grafana dashboard, Explore Loki e New Relic Service Map + Trace.'
    Info 'Nao cole tokens, Integration Keys ou Webhooks nas capturas.'
    Record '02 - Observabilidade' 'OK' 'Inventario da stack; evidencias visuais do APM dependem do navegador'
}
function Start-PrometheusProxy {
    Banner '03 | Acessando a API do Prometheus'
    $uri = 'http://127.0.0.1:' + $script:Port + '/api/v1/status/buildinfo'
    try {
        Invoke-RestMethod -Uri $uri -TimeoutSec 3 | Out-Null
        Good ('Prometheus ja acessivel na porta ' + $script:Port)
        return
    } catch { }
    $kubectl = (Get-Command kubectl).Source
    $stdout = Join-Path $OutputDirectory '03-portforward-stdout.txt'
    $stderr = Join-Path $OutputDirectory '03-portforward-stderr.txt'
    $args = @('port-forward','-n',$MonitoringNamespace,'svc/togglemaster-monitoring-prometheus',($script:Port.ToString() + ':9090'),'--address','127.0.0.1')
    $script:PortForward = Start-Process -FilePath $kubectl -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $script:OwnPortForward = $true
    for ($i=0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri $uri -TimeoutSec 2 | Out-Null
            Good ('Prometheus disponivel em http://127.0.0.1:' + $script:Port)
            return
        } catch { }
    }
    throw 'Nao foi possivel abrir port-forward. Consulte 03-portforward-stderr.txt.'
}
function Alert-State {
    $uri = 'http://127.0.0.1:' + $script:Port + '/api/v1/alerts'
    $response = Invoke-RestMethod -Uri $uri -TimeoutSec 10
    if ($response.status -ne 'success') { throw 'API do Prometheus retornou erro.' }
    $matching = @($response.data.alerts | Where-Object {
        $_.labels.alertname -eq 'ToggleMasterDeploymentUnavailable' -and
        $_.labels.deployment -eq $script:TempDeployment
    })
    if ($matching.Count -eq 0) { return 'inactive' }
    return [string]$matching[0].state
}
function SelfHealing {
    Banner '04 | SELF-HEALING: exclusao controlada de UM pod flag-service'
    if (-not $RunFaults) { Warn 'Cenario ignorado: acrescente -RunFaults para permitir alteracoes.'; Record '04 - Pod self-healing' 'PULADO' 'Sem -RunFaults'; return }
    $old = (& kubectl get pods -n $Namespace -l 'app=flag-service' -o 'jsonpath={.items[0].metadata.name}' 2>$null)
    if (-not $old) {
        $old = (& kubectl get pods -n $Namespace -o 'jsonpath={.items[*].metadata.name}').Split(' ') | Where-Object { $_ -like 'flag-service-*' } | Select-Object -First 1
    }
    if (-not $old) { throw 'Pod flag-service nao encontrado.' }
    Info ('Pod original: ' + $old)
    Cmd @('delete','pod',$old,'-n',$Namespace,'--wait=false')
    Info 'Kubernetes/ReplicaSet esta criando um novo pod...'
    $newPods = @()
    for ($i = 0; $i -lt 30; $i++) {
        $allPodNames = (& kubectl get pods -n $Namespace -o 'jsonpath={.items[*].metadata.name}')
        $newPods = @($allPodNames.Split(' ') | Where-Object { $_ -like 'flag-service-*' -and $_ -ne $old })
        if ($newPods.Count -gt 0) { break }
        Start-Sleep -Seconds 2
    }
    if ($newPods.Count -lt 1) { throw 'Nao foi identificado um novo pod flag-service.' }
    Cmd @('wait','--for=condition=Ready',('pod/' + $newPods[0]),'-n',$Namespace,'--timeout=180s')
    Cmd @('rollout','status','deployment/flag-service','-n',$Namespace,'--timeout=180s')
    Good ('Self-healing comprovado: ' + $old + ' -> ' + $newPods[0])
    Save-Cmd '04-selfhealing-pods.txt' @('get','pods','-n',$Namespace,'-o','wide') | Out-Host
    Save-Cmd '04-selfhealing-deployment.txt' @('get','deployment','flag-service','-n',$Namespace) | Out-Host
    Record '04 - Pod self-healing' 'OK' ($old + ' -> ' + $newPods[0])
}
function Incident {
    Banner '05 | INCIDENTE: Prometheus FIRING -> Runbook -> RESOLVED'
    if (-not $RunFaults) { Warn 'Cenario ignorado: acrescente -RunFaults para permitir alteracoes.'; Record '05 - Incidente+Runbook' 'PULADO' 'Sem -RunFaults'; return }
    Start-PrometheusProxy
    $existing = & kubectl get deployment $script:TempDeployment -n $Namespace --ignore-not-found -o name
    if ($existing) { throw ('Ja existe ' + $script:TempDeployment + '. Remova-o manualmente apos verificar sua origem; o script nao sobrescreve deployments existentes.') }
    Info 'Criando Deployment descartavel com imagem inexistente (nenhum microsservico sera alterado).'
    Cmd @('create','deployment',$script:TempDeployment,'-n',$Namespace,'--image=invalid.local/togglemaster-demonstracao-imagem-inexistente:fiap')
    $script:IncidentCreated = $true
    Save-Cmd '05-deployment-falha.txt' @('get','deployment',$script:TempDeployment,'-n',$Namespace) | Out-Host
    Save-Cmd '05-pod-falha.txt' @('get','pods','-n',$Namespace) | Out-Host
    Info 'Regra monitorada: ToggleMasterDeploymentUnavailable (for: 5m).'
    Info ('Prometheus para navegador: http://127.0.0.1:' + $script:Port + '/alerts (port-forward interno do script).')
    $deadline = (Get-Date).AddSeconds($FiringTimeoutSec)
    $lastState = ''
    $fired = $false
    while ((Get-Date) -lt $deadline) {
        try { $state = Alert-State } catch { $state = 'api-unavailable'; Warn $_.Exception.Message }
        if ($state -ne $lastState) { Info ('Estado Prometheus: ' + $lastState + ' -> ' + $state); $lastState = $state }
        $remaining = [math]::Max(0, [math]::Round(($deadline - (Get-Date)).TotalSeconds))
        Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] Esperando FIRING | estado=' + $state + ' | timeout restante=' + $remaining + 's') -ForegroundColor Yellow
        if ($state -eq 'firing') { $fired = $true; break }
        Start-Sleep -Seconds 15
    }
    if (-not $fired) {
        Record '05 - Incidente+Runbook' 'FALHOU' 'FIRING nao observado no prazo; falha limpa automaticamente'
        throw 'Prometheus nao entrou em FIRING no prazo. Verifique regra, kube-state-metrics e scrape.'
    }
    Good 'Prometheus entrou em FIRING para o Deployment descartavel!'
    Record '05 - Prometheus FIRING' 'OK' ('Deployment ' + $script:TempDeployment)
    Info 'Slack: abra #togglemaster-alertas e registre a notificacao FIRING.'
    Info 'PagerDuty: abra https://app.pagerduty.com/incidents e registre o incidente.'
    Info ('Pausa automatica de ' + $EvidencePauseSec + 's para exibicao/gravar evidencias.')
    if ($EvidencePauseSec -gt 0) { Start-Sleep -Seconds $EvidencePauseSec }

    Banner '06 | RUNBOOK AUTOMATICO: evento FIRING aciona acao corretiva'
    Info 'Acao automatizada: substituir imagem invalida por imagem funcional no Deployment temporario.'
    $imageAssignment = '*=' + $TestImage
    Cmd @('set','image',('deployment/' + $script:TempDeployment),$imageAssignment,'-n',$Namespace)
    Info ('Imagem restaurada automaticamente para ' + $TestImage)
    try {
        Cmd @('rollout','status',('deployment/' + $script:TempDeployment),'-n',$Namespace,'--timeout=180s')
        Good 'RUNBOOK: deployment recuperado automaticamente apos alerta FIRING.'
        Record '06 - Runbook automatico' 'OK' ('FIRING -> kubectl set image ' + $TestImage)
    } catch {
        Warn ('Imagem de recuperacao nao ficou pronta: ' + $_.Exception.Message)
        Record '06 - Runbook automatico' 'FALHOU' 'Falha no rollout da imagem de recuperacao'
        throw
    }
    Save-Cmd '06-deployment-recuperado.txt' @('get','deployment',$script:TempDeployment,'-n',$Namespace) | Out-Host
    Save-Cmd '06-pods-recuperados.txt' @('get','pods','-n',$Namespace) | Out-Host

    Banner '07 | AGUARDANDO resolucao do alerta'
    $deadlineResolved = (Get-Date).AddSeconds(150)
    $resolved = $false
    while ((Get-Date) -lt $deadlineResolved) {
        try { $state = Alert-State } catch { $state = 'api-unavailable' }
        Info ('Alerta apos runbook: ' + $state)
        if ($state -eq 'inactive') { $resolved = $true; break }
        Start-Sleep -Seconds 10
    }
    if ($resolved) {
        Good 'RESOLVED: condicao nao esta mais ativa no Prometheus.'
        Record '07 - Resolucao Prometheus' 'OK' 'Alerta ausente da API ativa'
    } else {
        Warn 'Alerta ainda ativo ou API indisponivel; verificar manualmente.'
        Record '07 - Resolucao Prometheus' 'PENDENTE' 'Nao foi possivel confirmar o fim do alerta'
    }
    Info 'Verifique Slack RESOLVED e PagerDuty Resolved through integration API.'
}
function Cleanup {
    Banner '08 | LIMPEZA E SAUDE FINAL'
    if ($script:IncidentCreated) {
        Info ('Excluindo somente o Deployment temporario: ' + $script:TempDeployment)
        & kubectl delete deployment $script:TempDeployment -n $Namespace --ignore-not-found
        $script:IncidentCreated = $false
    }
    Save-Cmd '08-deployments-final.txt' @('get','deployments','-n',$Namespace) | Out-Host
    Save-Cmd '08-pods-final.txt' @('get','pods','-n',$Namespace) | Out-Host
    Save-Cmd '08-argocd-final.txt' @('get','applications','-n',$ArgoNamespace) | Out-Host
    if ($script:OwnPortForward -and $script:PortForward) {
        try { Stop-Process -Id $script:PortForward.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
}

try {
    Start-Transcript -Path (Join-Path $OutputDirectory '00-execucao-completa.txt') | Out-Null
    $script:TranscriptStarted = $true
    Banner 'TOGGLEMASTER | TECH CHALLENGE FASE 4 | DEMO AUTOMATIZADA'
    Info ('Saida das evidencias: ' + $OutputDirectory)
    Info ('Cenario=' + $Scenario + ' | Falhas habilitadas=' + $RunFaults)
    Verify-Prerequisites
    if ($Scenario -eq 'All' -or $Scenario -eq 'Overview') { Overview }
    if ($Scenario -eq 'All' -or $Scenario -eq 'SelfHealing') { SelfHealing }
    if ($Scenario -eq 'All' -or $Scenario -eq 'Incident') { Incident }
    Good 'Execucao principal concluida.'
} catch {
    Fail $_.Exception.Message
    Record 'Execucao' 'ERRO' $_.Exception.Message
} finally {
    try { Cleanup } catch { Warn ('Falha parcial durante limpeza: ' + $_.Exception.Message) }
    $csv = Join-Path $OutputDirectory '00-resumo-cenarios.csv'
    $script:Results | Export-Csv -Path $csv -Encoding UTF8 -NoTypeInformation -Delimiter ';'
    Banner 'RESUMO DOS CENARIOS'
    $script:Results | Format-Table -AutoSize | Out-Host
    Info ('Logs e evidencias TXT/CSV: ' + $OutputDirectory)
    if ($script:TranscriptStarted) { Stop-Transcript | Out-Null }
}
