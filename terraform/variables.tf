variable "aws_region" {
  description = "Região AWS utilizada pelo projeto"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome utilizado nos recursos do projeto"
  type        = string
  default     = "togglemaster"
}

variable "environment" {
  description = "Ambiente da aplicação"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "microservices" {
  description = "Microsserviços do ToggleMaster"
  type        = set(string)
  default     = ["auth", "flag", "targeting", "evaluation", "analytics"]
}

variable "eks_cluster_role_arn" {
  description = "ARN da IAM Role utilizada pelo cluster EKS"
  type        = string
}

variable "eks_node_role_arn" {
  description = "ARN da IAM Role utilizada pelos Worker Nodes"
  type        = string
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes utilizada pelo EKS"
  type        = string
  default     = "1.35"
}

variable "databases" {
  description = "Configuração dos bancos de dados RDS"
  type = map(object({
    allocated_storage = number
    storage_type      = string
    username          = string
    password          = string
    engine            = string
    instance_class    = string
  }))
  sensitive = true
}