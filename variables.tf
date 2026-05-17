variable "aws_region" {
  description = "The AWS region to deploy to"
  type        = string
  default     = "us-east-1"
}

variable "ecr_repository_name" {
  description = "The name of the ECR repository"
  type        = string
  default     = "vault-server-repo"
}
