locals {
  name                 = "tech-challenge"
  cluster_version      = "1.29"
  namespace            = "tech-challenge"
  service_account_name = "tech-challenge-service-account"
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "tech-challenge" {
  backend = "s3"

  config = {
    bucket = "fiap-3soat-g15-infra-tech-challenge-state"
    key    = "live/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "rds" {
  backend = "s3"

  config = {
    bucket = "fiap-3soat-g15-infra-db-state"
    key    = "live/terraform.tfstate"
    region = var.region
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.3"

  cluster_name                    = local.name
  cluster_version                 = local.cluster_version
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  access_entries = {
    root_admin = {
      kubernetes_groups = []
      principal_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  enable_cluster_creator_admin_permissions = true

  vpc_id     = data.terraform_remote_state.tech-challenge.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.tech-challenge.outputs.private_subnets

  eks_managed_node_group_defaults = {
    disk_size      = 20
    instance_types = ["t3.small"]
  }

  eks_managed_node_groups = {
    default_node_group = {
      use_custom_launch_template = false

      desired_size = 2
      min_size     = 1
      max_size     = 5

      capacity_type = "SPOT"
    }
  }
}

# Creating as Terraform resource (instead of Kubernetes manifest)
# for removing Kubernetes services (like load balancers) when destroying it
resource "kubernetes_namespace" "namespace" {
  metadata {
    name = local.namespace

    annotations = {
      name = local.namespace
    }
  }
}

# Install AWS Secrets and Configuration Provider (ASCP)
# https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html
resource "helm_release" "csi_secrets_store" {
  name       = "csi-secrets-store"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }

  set {
    name  = "enableSecretRotation"
    value = "true"
  }

  depends_on = [
    module.eks
  ]
}

resource "helm_release" "secrets_provider_aws" {
  name       = "secrets-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  namespace  = "kube-system"

  depends_on = [
    module.eks,
    helm_release.csi_secrets_store
  ]
}

# Install AWS Load Balancer Controller
# https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html
# https://github.com/aws/eks-charts/tree/master/stable/aws-load-balancer-controller
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = data.terraform_remote_state.tech-challenge.outputs.vpc_id
  }

  set {
    name  = "clusterName"
    value = local.name
  }

  set {
    name  = "serviceAccount.create"
    value = false
  }

  set {
    name  = "serviceAccount.name"
    value = local.service_account_name
  }

  depends_on = [
    module.eks,
    kubernetes_namespace.namespace
  ]
}

module "eks_service_account_role" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "TechChallengeEKSServiceAccount"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "${local.namespace}:${local.service_account_name}",
        "kube-system:${local.service_account_name}",
      ]
    }
  }

  role_policy_arns = {
    RDSSecretsReadOnlyPolicy = data.terraform_remote_state.rds.outputs.rds_secrets_read_only_policy_arn
    RDSParamsReadOnlyPolicy  = data.terraform_remote_state.rds.outputs.rds_params_read_only_policy_arn
    MPSecretsReadOnlyPolicy  = data.terraform_remote_state.tech-challenge.outputs.mercado_pago_secrets_read_only_policy_arn
  }

  depends_on = [
    module.eks,
    kubernetes_namespace.namespace
  ]

  tags = var.tags
}

resource "kubernetes_service_account" "kube_system_service_account" {
  metadata {
    name      = local.service_account_name
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = module.eks_service_account_role.iam_role_arn
    }
  }

  depends_on = [
    module.eks,
    module.eks_service_account_role
  ]
}

resource "kubernetes_service_account" "namespace_service_account" {
  metadata {
    name      = local.service_account_name
    namespace = local.namespace

    annotations = {
      "eks.amazonaws.com/role-arn" = module.eks_service_account_role.iam_role_arn
    }
  }

  depends_on = [
    module.eks,
    module.eks_service_account_role
  ]
}
