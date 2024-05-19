locals {
  name               = "tech-challenge"
  cluster_version    = "1.29"
  orders_namespace   = "orders"
  payments_namespace = "payments"
  stock_namespace    = "stock"
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "tech-challenge" {
  backend = "s3"

  config = {
    bucket = "fiap-3soat-g15-iac-tech-challenge"
    key    = "live/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "stock-api" {
  backend = "s3"

  config = {
    bucket = "fiap-3soat-g15-iac-stock-api"
    key    = "live/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "payments-api" {
  backend = "s3"

  config = {
    bucket = "fiap-3soat-g15-iac-payments-api"
    key    = "live/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "orders-api" {
  backend = "s3"

  config = {
    bucket = "fiap-3soat-g15-iac-orders-api"
    key    = "live/terraform.tfstate"
    region = var.region
  }
}

# CLUSTER

// https://github.com/terraform-aws-modules/terraform-aws-eks
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
  
  cluster_addons = {
    // Service Discovery
    coredns = {
      most_recent = true
    }
  }
}

# NAMESPACES

# Creating as Terraform resource (instead of Kubernetes manifest)
# for removing Kubernetes services (like load balancers) when destroying it
resource "kubernetes_namespace" "orders-namespace" {
  metadata {
    name = "orders"
    annotations = {
      name = "orders"
    }
  }
}

resource "kubernetes_namespace" "payments-namespace" {
  metadata {
    name = "payments"
    annotations = {
      name = "payments"
    }
  }
}

resource "kubernetes_namespace" "stock-namespace" {
  metadata {
    name = "stock"
    annotations = {
      name = "stock"
    }
  }
}

# ADD-ONS

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
    value = "kube-system-service-account"
  }
}

# ROLES ATTACHED TO SERVICE ACCOUNTS

module "kube_system_service_account_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  role_name = "TechChallengeKubeSystemServiceAccount"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "kube-system:kube-system-service-account",
      ]
    }
  }

  attach_load_balancer_controller_policy = true

  tags = var.tags
}

module "orders_service_account_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  role_name = "TechChallengeOrdersServiceAccount"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "${local.orders_namespace}:${local.orders_namespace}-service-account",
      ]
    }
  }

  role_policy_arns = {
    OrdersRDSSecretsReadOnlyPolicy = data.terraform_remote_state.orders-api.outputs.rds_secrets_read_only_policy_arn
    OrdersRDSParamsReadOnlyPolicy  = data.terraform_remote_state.orders-api.outputs.rds_params_read_only_policy_arn
  }

  tags = var.tags
}

module "payments_service_account_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  role_name = "TechChallengePaymentsServiceAccount"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "${local.payments_namespace}:${local.payments_namespace}-service-account",
      ]
    }
  }

  role_policy_arns = {
    PaymentsDynamoDBTablePolicy = data.terraform_remote_state.payments-api.outputs.payments_dynamodb_table_policy_arn
    MercadoPagoSecretsReadOnlyPolicy = data.terraform_remote_state.payments-api.outputs.mercado_pago_secrets_read_only_policy_arn
  }

  tags = var.tags
}

module "stock_service_account_role" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  role_name = "TechChallengeStockServiceAccount"

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "${local.stock_namespace}:${local.stock_namespace}-service-account",
      ]
    }
  }

  role_policy_arns = {
    StockRDSSecretsReadOnlyPolicy = data.terraform_remote_state.stock-api.outputs.rds_secrets_read_only_policy_arn
    StockRDSParamsReadOnlyPolicy  = data.terraform_remote_state.stock-api.outputs.rds_params_read_only_policy_arn
  }

  tags = var.tags
}

# SERVICE ACCOUNTS

resource "kubernetes_service_account" "kube_system_service_account" {
  metadata {
    name      = "kube-system-service-account"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = module.kube_system_service_account_role.iam_role_arn
    }
  }
}

resource "kubernetes_service_account" "orders_service_account" {
  metadata {
    name      = "${local.orders_namespace}-service-account"
    namespace = local.orders_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = module.orders_service_account_role.iam_role_arn
    }
  }
}

resource "kubernetes_service_account" "payments_service_account" {
  metadata {
    name      = "${local.payments_namespace}-service-account"
    namespace = local.payments_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = module.payments_service_account_role.iam_role_arn
    }
  }
}

resource "kubernetes_service_account" "stock_service_account" {
  metadata {
    name      = "${local.stock_namespace}-service-account"
    namespace = local.stock_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = module.stock_service_account_role.iam_role_arn
    }
  }
}
