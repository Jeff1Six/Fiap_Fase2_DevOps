ToggleMaster Fase 4 - Loki + Alloy (AWS Academy)

1) Copie monitoring/applications/loki.yaml e alloy.yaml para o repositorio.
2) Em argocd/monitoring-app.yaml, substitua o valor EXISTENTE de
   spec.source.directory.include por:
     "{prometheus.yaml,dashboard-togglemaster.yaml,loki.yaml,alloy.yaml}"
   (nao crie outro bloco directory)
3) Em monitoring/prometheus/values.yaml, acrescente ao bloco grafana existente:
   additionalDataSources:
     - name: Loki
       uid: loki
       type: loki
       access: proxy
       url: http://togglemaster-loki-gateway.monitoring.svc.cluster.local
       isDefault: false
4) git add/commit/push dos quatro arquivos.
5) kubectl apply -f argocd/monitoring-app.yaml
6) kubectl get applications -n argocd; kubectl get pods -n monitoring
7) Grafana > Explore > Loki, consulta {namespace="desafio3"}

IMPORTANTE: Loki usa filesystem e persistence.enabled=false: logs desaparecem
se o pod for substituido. Adequado somente para laboratorio.

Se o Alloy receber 403 Forbidden ao ler pods/log, verifique RBAC do chart.
O gateway pode levar alguns minutos para se tornar Ready.
