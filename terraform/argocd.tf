locals {
  kubeconfig_parsed = yamldecode(data.external.kubeconfig_raw.result.content)
  kube_cluster      = local.kubeconfig_parsed.clusters[0].cluster
  kube_user         = local.kubeconfig_parsed.users[0].user
}

provider "helm" {
  kubernetes = {
    host                   = local.kube_cluster.server
    cluster_ca_certificate = base64decode(local.kube_cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kube_user["client-certificate-data"])
    client_key             = base64decode(local.kube_user["client-key-data"])
  }
}

provider "kubernetes" {
  host                   = local.kube_cluster.server
  cluster_ca_certificate = base64decode(local.kube_cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kube_user["client-certificate-data"])
  client_key             = base64decode(local.kube_user["client-key-data"])
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version != "" ? var.argocd_chart_version : null
  namespace        = "argocd"
  create_namespace = true

  depends_on = [local_sensitive_file.kubeconfig]
}

data "kubernetes_secret_v1" "argocd_admin_password" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

  depends_on = [helm_release.argocd]
}

provider "kubectl" {
  host                   = local.kube_cluster.server
  cluster_ca_certificate = base64decode(local.kube_cluster["certificate-authority-data"])
  client_certificate     = base64decode(local.kube_user["client-certificate-data"])
  client_key             = base64decode(local.kube_user["client-key-data"])
  load_config_file       = false
}

resource "kubectl_manifest" "bootstrap_app" {
  yaml_body = templatefile("${path.module}/../gitops/bootstrap/app-of-apps.yaml", {
    repo_url = var.gitops_repo_url
    revision = var.gitops_repo_revision
  })

  depends_on = [helm_release.argocd]
}
