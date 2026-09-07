data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  eks_cluster_name = "togglemaster-dev"
  namespace        = "desafio3"

  sqs_queue_name      = "togglemaster-sqs"
  dynamodb_table_name = "ToggleMasterAnalytics"

  sqs_queue_arn = "arn:aws:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${local.sqs_queue_name}"

  dynamodb_table_arn = "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${local.dynamodb_table_name}"
}

# =========================================================
# EKS POD IDENTITY AGENT
# =========================================================

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = local.eks_cluster_name
  addon_name   = "eks-pod-identity-agent"
}

# =========================================================
# ANALYTICS SERVICE
# SQS -> consumir mensagens
# DynamoDB -> gravar eventos
# =========================================================

resource "aws_iam_role" "analytics_pod_role" {
  name = "togglemaster-analytics-pod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "pods.eks.amazonaws.com"
        }

        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Project     = "ToggleMaster"
    Environment = "dev"
    Service     = "analytics-service"
  }
}

resource "aws_iam_policy" "analytics_pod_policy" {
  name = "togglemaster-analytics-pod-policy"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "ConsumeSQS"
        Effect = "Allow"

        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:DeleteMessageBatch",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ChangeMessageVisibility",
          "sqs:ChangeMessageVisibilityBatch"
        ]

        Resource = local.sqs_queue_arn
      },
      {
        Sid    = "WriteDynamoDB"
        Effect = "Allow"

        Action = [
          "dynamodb:PutItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:DescribeTable"
        ]

        Resource = local.dynamodb_table_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "analytics_pod_policy_attachment" {
  role       = aws_iam_role.analytics_pod_role.name
  policy_arn = aws_iam_policy.analytics_pod_policy.arn
}

resource "aws_eks_pod_identity_association" "analytics" {
  cluster_name    = local.eks_cluster_name
  namespace       = local.namespace
  service_account = "analytics-service-sa"
  role_arn        = aws_iam_role.analytics_pod_role.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.analytics_pod_policy_attachment
  ]
}

# =========================================================
# EVALUATION SERVICE
# SQS -> publicar eventos
# =========================================================

resource "aws_iam_role" "evaluation_pod_role" {
  name = "togglemaster-evaluation-pod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "pods.eks.amazonaws.com"
        }

        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Project     = "ToggleMaster"
    Environment = "dev"
    Service     = "evaluation-service"
  }
}

resource "aws_iam_policy" "evaluation_pod_policy" {
  name = "togglemaster-evaluation-pod-policy"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "PublishSQS"
        Effect = "Allow"

        Action = [
          "sqs:SendMessage",
          "sqs:SendMessageBatch",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]

        Resource = local.sqs_queue_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "evaluation_pod_policy_attachment" {
  role       = aws_iam_role.evaluation_pod_role.name
  policy_arn = aws_iam_policy.evaluation_pod_policy.arn
}

resource "aws_eks_pod_identity_association" "evaluation" {
  cluster_name    = local.eks_cluster_name
  namespace       = local.namespace
  service_account = "evaluation-service-sa"
  role_arn        = aws_iam_role.evaluation_pod_role.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.evaluation_pod_policy_attachment
  ]
}
