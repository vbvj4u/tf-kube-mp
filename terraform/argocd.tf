provider "helm" {
  kubernetes = {
    config_path = local_file.kubeconfig.filename
  }
}

provider "kubernetes" {
  config_path = local_file.kubeconfig.filename
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version != "" ? var.argocd_chart_version : null
  namespace        = "argocd"
  create_namespace = true

  depends_on = [local_file.kubeconfig]
}

data "kubernetes_secret_v1" "argocd_admin_password" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

  depends_on = [helm_release.argocd]
}

provider "kubectl" {
  config_path = local_file.kubeconfig.filename
}

resource "kubectl_manifest" "bootstrap_app" {
  yaml_body = templatefile("${path.module}/../gitops/bootstrap/app-of-apps.yaml", {
    repo_url = var.gitops_repo_url
    revision = var.gitops_repo_revision
  })

  depends_on = [helm_release.argocd]
}
