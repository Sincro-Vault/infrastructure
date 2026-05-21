data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ECR Repository Data Source
data "aws_ecr_repository" "vault_server" {
  name = var.ecr_repository_name
}

# IAM Role for App Instance to pull from ECR
resource "aws_iam_role" "app_role" {
  name = "vault-app-ecr-role"

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

resource "aws_iam_role_policy_attachment" "app_ecr_policy" {
  role       = aws_iam_role.app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "app_cw_policy" {
  role       = aws_iam_role.app_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "vault-app-profile"
  role = aws_iam_role.app_role.name
}

resource "aws_cloudwatch_log_group" "vault_app_logs" {
  name              = "vault-app-logs"
  retention_in_days = 7
}

# Security Groups
resource "aws_security_group" "sql_server_sg" {
  name        = "sql-server-sg"
  description = "Security group for SQL Server"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow SQL Server port from App SG"
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app_sg" {
  name        = "app-server-sg"
  description = "Security group for App Server"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow REST API"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow GRPC"
    from_port   = 50051
    to_port     = 50051
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Key Pair (optional, but good for debugging)
# We won't strictly attach a key pair unless it exists, but usually users have one or use session manager. 
# We will omit key_name to allow EC2 Instance Connect or Session Manager if user sets it up.

# SQL Server Instance
resource "aws_instance" "sql_server" {
  ami                  = data.aws_ami.amazon_linux.id
  instance_type        = "t3.small" # Minimum practical size for SQL Server (needs >= 2GB RAM)
  subnet_id            = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.sql_server_sg.id]
  iam_instance_profile = aws_iam_instance_profile.app_profile.name

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y docker
    systemctl start docker
    systemctl enable docker

    # Run SQL Server Express with CloudWatch logging
    docker run -e 'ACCEPT_EULA=Y' -e 'MSSQL_SA_PASSWORD=SincroVault2026!' -p 1433:1433 --name sqlserver \
      --log-driver=awslogs \
      --log-opt awslogs-group=${aws_cloudwatch_log_group.vault_app_logs.name} \
      --log-opt awslogs-stream=sql-server \
      --log-opt awslogs-region=${var.aws_region} \
      -d mcr.microsoft.com/mssql/server:2022-latest
    
    # Wait for SQL Server to be ready
    sleep 30
    
    # Create the database
    docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'SincroVault2026!' -C -Q "CREATE DATABASE secretsdb"
  EOF

  tags = {
    Name = "SQL-Server-Vault"
  }
}

# Network Load Balancer (for TCP/GRPC support without HTTPS certs)
resource "aws_lb" "app_alb" {
  name               = "vault-app-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name = "vault-app-nlb"
  }
}

# Target Groups
resource "aws_lb_target_group" "app_rest_tg" {
  name     = "vault-app-rest-tg"
  port     = 9000
  protocol = "TCP"
  vpc_id   = data.aws_vpc.default.id
}

resource "aws_lb_target_group" "app_grpc_tg" {
  name     = "vault-app-grpc-tg"
  port     = 50051
  protocol = "TCP"
  vpc_id   = data.aws_vpc.default.id
}

# Listeners
resource "aws_lb_listener" "rest_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "9000"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_rest_tg.arn
  }
}

resource "aws_lb_listener" "grpc_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "50051"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_grpc_tg.arn
  }
}

# App Server Launch Template
resource "aws_launch_template" "app_lt" {
  name_prefix   = "vault-app-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.app_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app_sg.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y docker
    systemctl start docker
    systemctl enable docker

    # Authenticate to ECR
    aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_ecr_repository.vault_server.repository_url}
    
    # Pull the image (assuming the image is pushed as 'latest')
    docker pull ${data.aws_ecr_repository.vault_server.repository_url}:latest

    # Setup data dir for ledger
    mkdir -p /app/data
    chmod 777 /app/data

    # Run the application container with CloudWatch logging
    docker run -d --name vault-app \
      --log-driver=awslogs \
      --log-opt awslogs-group=${aws_cloudwatch_log_group.vault_app_logs.name} \
      --log-opt awslogs-stream=app-server \
      --log-opt awslogs-region=${var.aws_region} \
      -p 9000:9000 \
      -p 50051:50051 \
      -e REST_HOST=0.0.0.0 \
      -e REST_PORT=9000 \
      -e GRPC_HOST=0.0.0.0 \
      -e GRPC_PORT=50051 \
      -e DATABASE_URL="mssql+pyodbc://sa:SincroVault2026!@${aws_instance.sql_server.private_ip}:1433/secretsdb?driver=ODBC+Driver+18+for+SQL+Server&TrustServerCertificate=yes" \
      -e BLOCKCHAIN_LEDGER_PATH=/app/data/ledger.json \
      -v /app/data:/app/data \
      --restart unless-stopped \
      ${data.aws_ecr_repository.vault_server.repository_url}:latest
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "App-Server-Vault"
    }
  }

  depends_on = [
    aws_instance.sql_server,
    aws_iam_role_policy_attachment.app_ecr_policy
  ]
}

# Auto Scaling Group
resource "aws_autoscaling_group" "app_asg" {
  name_prefix         = "vault-app-asg-"
  desired_capacity    = 1
  max_size            = 3
  min_size            = 1
  target_group_arns   = [
    aws_lb_target_group.app_rest_tg.arn,
    aws_lb_target_group.app_grpc_tg.arn
  ]
  vpc_zone_identifier = data.aws_subnets.default.ids

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "App-Server-Vault"
    propagate_at_launch = true
  }
}

output "sql_server_private_ip" {
  value = aws_instance.sql_server.private_ip
}

output "alb_dns_name" {
  value       = aws_lb.app_alb.dns_name
  description = "The domain name of the load balancer"
}
