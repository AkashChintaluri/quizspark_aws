terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "quizspark-terraform-state"
    key    = "terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = "ap-south-1"
}

# Get default VPC
data "aws_vpc" "default" {
  default = true
}

# Get default subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group for EC2 instance
resource "aws_security_group" "quizspark_backend" {
  name        = "quizspark-backend-sg"
  description = "Security group for QuizSpark backend"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "quizspark-backend-sg"
  }
}

# S3 Bucket for Frontend
data "aws_s3_bucket" "frontend" {
  bucket = "quizspark-frontend"
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = data.aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = data.aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = data.aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${data.aws_s3_bucket.frontend.arn}/*"
      }
    ]
  })
}

# IAM role for EC2 instance
resource "aws_iam_role" "ec2_role" {
  name = "quizspark-backend-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for ECR access
resource "aws_iam_policy" "ecr_policy" {
  name = "quizspark-backend-ecr-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach policy to role
resource "aws_iam_role_policy_attachment" "ecr_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ecr_policy.arn
}

# IAM policy for SSM access
resource "aws_iam_policy" "ssm_policy" {
  name = "quizspark-backend-ssm-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ssm:DescribeAssociation",
          "ssm:GetDeployablePatchSnapshotForInstance",
          "ssm:GetDocument",
          "ssm:DescribeDocument",
          "ssm:GetManifest",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:ListAssociations",
          "ssm:ListInstanceAssociations",
          "ssm:PutInventory",
          "ssm:PutComplianceItems",
          "ssm:PutConfigurePackageResult",
          "ssm:UpdateAssociationStatus",
          "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach SSM policy to role
resource "aws_iam_role_policy_attachment" "ssm_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ssm_policy.arn
}

# IAM instance profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "quizspark-backend-profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 instance
resource "aws_instance" "quizspark_backend" {
  ami                    = "ami-0f5ee92e2d63afc18" # Ubuntu 22.04 LTS
  instance_type          = "t2.micro"
  key_name               = "quizspark"
  vpc_security_group_ids = [aws_security_group.quizspark_backend.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  subnet_id              = data.aws_subnets.default.ids[0]

  user_data = <<-EOF
              #!/bin/bash
              # Install Docker
              apt-get update
              apt-get install -y docker.io
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ubuntu

              # Login to ECR
              aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${var.ecr_registry}

              # Pull and run the container
              docker pull ${var.ecr_registry}/${var.ecr_repository}:latest
              docker stop ${var.ecr_repository} || true
              docker rm ${var.ecr_repository} || true
              docker run -d --name ${var.ecr_repository} -p 80:3000 \
                -e SUPABASE_URL="${var.supabase_url}" \
                -e SUPABASE_KEY="${var.supabase_key}" \
                -e JWT_SECRET="${var.jwt_secret}" \
                -e NODE_ENV="production" \
                -e PORT="3000" \
                -e CORS_ORIGIN="https://${var.s3_bucket}.s3-website.${var.aws_region}.amazonaws.com" \
                ${var.ecr_registry}/${var.ecr_repository}:latest
              EOF

  tags = {
    Name = "quizspark-backend"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp2"
  }
}

# Output the instance public IP
output "instance_public_ip" {
  value = aws_instance.quizspark_backend.public_ip
}

# Outputs
output "frontend_url" {
  value = aws_s3_bucket_website_configuration.frontend.website_endpoint
}

# Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "s3_bucket" {
  description = "S3 bucket name for frontend"
  type        = string
  default     = "quizspark-frontend"
}

variable "ecr_repository" {
  description = "ECR repository name"
  type        = string
  default     = "quizspark-backend"
}

variable "ecr_registry" {
  description = "ECR registry URL"
  type        = string
}

variable "supabase_url" {
  description = "Supabase URL"
  type        = string
}

variable "supabase_key" {
  description = "Supabase key"
  type        = string
}

variable "jwt_secret" {
  description = "JWT secret"
  type        = string
} 