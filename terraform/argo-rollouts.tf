resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = "2.41.0" # controller v1.9.0
  namespace        = "argo-rollouts"
  create_namespace = true

  depends_on = [azurerm_kubernetes_cluster.this]
}
