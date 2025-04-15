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

# IAM policy for EC2 instance
resource "aws_iam_policy" "ec2_policy" {
  name = "quizspark-backend-ec2-policy"

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

# Attach policy to role
resource "aws_iam_role_policy_attachment" "ec2_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
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
              # Update system and install required packages in parallel
              apt-get update && apt-get install -y \
                curl \
                git \
                nginx \
                nodejs \
                npm

              # Install PM2 globally
              npm install -g pm2

              # Create application directory
              mkdir -p /var/www/quizspark
              cd /var/www/quizspark

              # Clone the repository
              git clone https://github.com/yourusername/quizspark.git .

              # Install dependencies
              npm install

              # Create .env file
              cat > .env << EOL
              SUPABASE_URL="${var.supabase_url}"
              SUPABASE_KEY="${var.supabase_key}"
              JWT_SECRET="${var.jwt_secret}"
              NODE_ENV="production"
              PORT="3000"
              CORS_ORIGIN="http://13.200.253.50:80,https://${var.s3_bucket}.s3-website.${var.aws_region}.amazonaws.com"
              EOL

              # Start the application with PM2
              pm2 start npm --name "quizspark" -- start
              pm2 save
              pm2 startup

              # Configure Nginx
              cat > /etc/nginx/sites-available/quizspark << EOL
              server {
                  listen 80;
                  server_name _;

                  location / {
                      proxy_pass http://localhost:3000;
                      proxy_http_version 1.1;
                      proxy_set_header Upgrade \$http_upgrade;
                      proxy_set_header Connection 'upgrade';
                      proxy_set_header Host \$host;
                      proxy_cache_bypass \$http_upgrade;
                  }
              }
              EOL

              ln -s /etc/nginx/sites-available/quizspark /etc/nginx/sites-enabled/
              rm /etc/nginx/sites-enabled/default
              systemctl restart nginx
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