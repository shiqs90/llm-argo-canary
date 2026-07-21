terraform {
  required_version = "~> 1.15"

  # HCP Terraform (Terraform Cloud) backend, run with LOCAL execution so the local
  # `az login` session supplies Azure credentials. Create this workspace in the
  # Shikha_Projects org and set its Execution Mode to "Local" before the first apply.
  cloud {
    organization = "Shikha_Projects"

    workspaces {
      name = "llm-argo-canary"
    }
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
