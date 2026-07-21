resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v26.3.2"
  namespace        = "gpu-operator"
  create_namespace = true

  # Unlike EKS (driver baked into the accelerated AMI), AKS GPU nodes are created with
  # gpu_driver = "None" and the Operator installs the driver itself — Ubuntu is a
  # supported OS for the Operator's driver container.
  set {
    name  = "driver.enabled"
    value = "true"
  }

  # Tolerate the custom GPU taint so the Operator's DaemonSets land on the GPU node.
  set {
    name  = "daemonsets.tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "daemonsets.tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "daemonsets.tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [azurerm_kubernetes_cluster_node_pool.gpu]
}
