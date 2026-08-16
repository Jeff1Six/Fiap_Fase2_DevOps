output "vpc_id" {
  description = "ID da VPC criada"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR utilizado pela VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas"
  value       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "ecr_repository_urls" {
  description = "URLs dos repositórios ECR"

  value = {
    for service, repository in aws_ecr_repository.microservices :
    service => repository.repository_url
  }
}

output "eks_cluster_name" {
  description = "Nome do cluster EKS"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Endpoint da API Kubernetes"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_node_group_name" {
  description = "Nome do Node Group"
  value       = aws_eks_node_group.main.node_group_name
}

output "rds_connection_details" {
  description = "Detalhes de conexão de cada banco de dados"

  value = {
    for key, db in aws_db_instance.main : key => {
      host     = db.address
      port     = db.port
      endpoint = db.endpoint
    }
  }
}

output "redis_endpoint" {
  description = "Endpoint de conexão do Redis"
  value       = aws_elasticache_cluster.main.cache_nodes[0].address
}

output "redis_port" {
  description = "Porta do Redis"
  value       = aws_elasticache_cluster.main.cache_nodes[0].port
}

output "redis_connection_string" {
  description = "Endpoint completo do Redis"
  value       = "${aws_elasticache_cluster.main.cache_nodes[0].address}:${aws_elasticache_cluster.main.cache_nodes[0].port}"
}

output "sqs_url" {
  description = "URL da fila SQS"
  value       = aws_sqs_queue.main.url
}

output "aws_region" {
  description = "Região AWS utilizada"
  value       = var.aws_region
}