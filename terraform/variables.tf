variable "location" {
  description = "Azure region. Must have approved NCASv3_T4 (T4 GPU) quota."
  type        = string
  default     = "australiacentral"
}

variable "cluster_name" {
  description = "AKS cluster name (also used for the resource group: rg-<name>)."
  type        = string
  default     = "llm-argo-canary"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. null = let AKS pick its default (run `az aks get-versions --location <loc> -o table` to see options)."
  type        = string
  default     = null
}

variable "system_vm_size" {
  description = "CPU system node pool VM size (CoreDNS, GPU Operator + Argo Rollouts controllers). DSv3 family — subscription has quota for it in australiacentral (DASv5/DSv5 are 0)."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "gpu_vm_size" {
  description = "GPU node pool VM size. Standard_NC4as_T4_v3 = 1x NVIDIA T4 16GB (cheapest Azure GPU)."
  type        = string
  default     = "Standard_NC4as_T4_v3"
}
