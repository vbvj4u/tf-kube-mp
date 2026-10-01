variable "masters" {
  type        = number
  default     = 1
  description = "Number of control-plane (k3s server) nodes. Only 1 is currently supported."

  validation {
    condition     = var.masters == 1
    error_message = "Multi-master is not yet implemented; masters must be 1."
  }
}

variable "workers" {
  type        = number
  default     = 2
  description = "Number of worker (k3s agent) nodes."

  validation {
    condition     = var.workers >= 1
    error_message = "At least 1 worker is required."
  }
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Number of vCPUs per VM."
}

variable "memory" {
  type        = string
  default     = "2GiB"
  description = "Memory per VM (Multipass size string, e.g. 2GiB)."
}

variable "disk" {
  type        = string
  default     = "10GiB"
  description = "Disk size per VM (Multipass size string, e.g. 10GiB)."
}

variable "k3s_channel" {
  type        = string
  default     = "stable"
  description = "k3s release channel (see https://update.k3s.io/v1-release/channels)."
}

variable "argocd_chart_version" {
  type        = string
  default     = ""
  description = "Pin the argo-cd Helm chart version. Empty string resolves to the latest chart version at apply time."
}

variable "gitops_repo_url" {
  type        = string
  default     = "https://github.com/vbvj4u/tf-kube-mp.git"
  description = "Git repository ArgoCD's bootstrap Application watches."
}

variable "gitops_repo_revision" {
  type        = string
  default     = "main"
  description = "Git revision (branch/tag) ArgoCD's bootstrap Application tracks."
}
