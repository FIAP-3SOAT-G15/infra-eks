locals {
  name            = "selfordermanagementcluster"
  cluster_version = "1.29"

  namespace            = "selfordermanagement"
  service_account_name = "self-order-management-sa"
}

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

      capacity_type = "ON_DEMAND"
    }
  }
}

# AWS Secrets and Configuration Provider (ASCP)
# https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html#integrating_csi_driver_install

resource "helm_release" "csi-secrets-store" {
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

resource "helm_release" "secrets-provider-aws" {
  name       = "secrets-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  namespace  = "kube-system"

  depends_on = [
    module.eks,
    helm_release.csi-secrets-store
  ]
}

resource "aws_iam_role" "service_account_role" {
  name = "SelfOrderManagementServiceAccount"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" : "sts.amazonaws.com",
            "${module.eks.oidc_provider}:sub" : "system:serviceaccount:${local.namespace}:${local.service_account_name}"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "rds_secrets_read_only_for_service_account" {
  role       = aws_iam_role.service_account_role.name
  policy_arn = data.terraform_remote_state.rds.outputs.rds_secrets_read_only_policy_arn
}

resource "aws_iam_role_policy_attachment" "rds_params_read_only_for_service_account" {
  role       = aws_iam_role.service_account_role.name
  policy_arn = data.terraform_remote_state.rds.outputs.rds_params_read_only_policy_arn
}

resource "aws_iam_role_policy_attachment" "mercado_pago_secrets_read_only_for_service_account" {
  role       = aws_iam_role.service_account_role.name
  policy_arn = data.terraform_remote_state.tech-challenge.outputs.mercado_pago_secrets_read_only_policy_arn
}
