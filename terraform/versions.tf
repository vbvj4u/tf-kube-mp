terraform {
  required_version = ">= 1.9"

  required_providers {
    multipass = {
      source  = "larstobi/multipass"
      version = "1.4.3"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.19.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.9.1"
    }
    external = {
      source  = "hashicorp/external"
      version = "2.4.2"
    }
  }
}
