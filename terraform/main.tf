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

# Check if security group exists
data "aws_security_group" "existing" {
  count = 1
  filter {
    name   = "tag:Name"
    values = ["quizspark-backend-sg"]
  }
}

# Security group for EC2 instance
resource "aws_security_group" "quizspark_backend" {
  count       = length(data.aws_security_group.existing) == 0 ? 1 : 0
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
resource "aws_s3_bucket" "frontend" {
  bucket = "quizspark-frontend"
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
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

# IAM instance profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "quizspark-backend-profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 instance
resource "aws_instance" "quizspark_backend" {
  ami                    = "ami-0f5ee92e2d63afc18" # Ubuntu 22.04 LTS
  instance_type          = "t2.micro"
  key_name               = "quizspark-key" # Make sure this key exists in your AWS account
  vpc_security_group_ids = [length(data.aws_security_group.existing) > 0 ? data.aws_security_group.existing[0].id : aws_security_group.quizspark_backend[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  subnet_id              = data.aws_subnets.default.ids[0]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ubuntu
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