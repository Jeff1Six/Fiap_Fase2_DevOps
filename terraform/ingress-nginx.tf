resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"

  namespace        = "ingress-nginx"
  create_namespace = true

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
        }
      }
    })
  ]
}
