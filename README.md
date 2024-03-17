# FIAP 3SOAT Tech Challenge - G15 - EKS

IaC provisionada de EKS cluster na AWS com Terraform.

Repositório principal: [tech-challenge](https://github.com/FIAP-3SOAT-G15/tech-challenge)

## Recursos criados

Cluster do Elastic Kubernetes Service (EKS), com adição de [AWS Secrets and Configuration Provider (ASCP)](https://docs.aws.amazon.com/secretsmanager/latest/userguide/integrating_csi_driver.html) para utilização de secrets do Secrets Manager e parâmetros do SSM Parameter Store como um volume montado nos pods (conforme configuração de secret provider em manifesto do Kubernetes), e uma [IAM role para service account](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) com permissão de leitura das secrets necessárias.

## Dependências

- Secrets (username e password) e parâmetros (endpoint e nome do BD) do RDS
- Secrets da integração com o Mercado Pago

Essas dependências são criadas nos outros repositórios de infraestrutura da organização e são utilizadas neste repositório através [remote state como data source](https://developer.hashicorp.com/terraform/language/state/remote-state-data).

## Estrutura

```text
.
├── .github/
│   └── workflows/
│       ├── manifest.yml      # deployment dos manifestos do Kubernetes
│       └── provisioning.yml  # provisionamento de IaC com Terraform
├── manifests/                # manifestos do Kubernetes
└── terraform/                # IaC com Terraform
```

## Desenvolvimento

Para usar o kubectl, atualize o kubeconfig:

```bash
aws eks update-kubeconfig --name fiap-3soat-g15 --region us-east-1 --profile my-profile
```

Considerando o profile definido em `~/.aws/credentials`:

```text
[my-profile]
aws_access_key_id     = **************
aws_secret_access_key = **************
region                = us-east-1
```

É necessário que este usuário IAM esteja configurado como [IAM access entry](https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html) no cluster, com a access policy `AmazonEKSClusterAdminPolicy`.

Teste de acesso:

```
kubectl auth can-i "*" "*"
```
