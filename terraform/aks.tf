resource "azurerm_resource_group" "this" {
  name     = "rg-${var.cluster_name}"
  location = var.location

  tags = {
    project = var.cluster_name
  }
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free" # control plane costs $0 (no uptime SLA — fine for a demo)

  identity {
    type = "SystemAssigned"
  }

  # Required system pool — CPU only; runs CoreDNS, GPU Operator + Argo Rollouts controllers.
  default_node_pool {
    name       = "system"
    vm_size    = var.system_vm_size
    node_count = 1
  }

  tags = {
    project = var.cluster_name
  }
}

# GPU pool: 1x T4 shared by stable + canary pods via GPU Operator time-slicing.
# gpu_driver = "None" skips AKS's own NVIDIA driver install so the GPU Operator
# owns the full stack (driver + device plugin + time-slicing) without conflicts.
resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  name                  = "gpu"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.gpu_vm_size
  node_count            = 1
  gpu_driver            = "None"

  node_labels = {
    workload = "gpu"
  }

  node_taints = ["nvidia.com/gpu=present:NoSchedule"]

  tags = {
    project = var.cluster_name
  }
}
