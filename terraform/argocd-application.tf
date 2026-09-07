resource "kubectl_manifest" "togglemaster_application" {
  yaml_body = file(
    "${path.module}/../argocd/togglemaster-application.yaml"
  )

  depends_on = [
    helm_release.argocd
  ]
}
