# Data source to fetch the default VPC
data "aws_vpc" "default" {
  default = true
}

# Data source to fetch all availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source to fetch default subnets
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# IAM role for EC2 instance to use SSM
resource "aws_iam_role" "deepseek_ocr_ssm" {
  name = "deepseek-ocr-ssm-role"

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

  tags = {
    Name        = "deepseek-ocr-ssm-role"
    Environment = "demo"
    Purpose     = "DeepSeek OCR SSM Access"
  }
}

# Attach AWS managed policy for SSM
resource "aws_iam_role_policy_attachment" "deepseek_ocr_ssm" {
  role       = aws_iam_role.deepseek_ocr_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile for the EC2 instance
resource "aws_iam_instance_profile" "deepseek_ocr_ssm" {
  name = "deepseek-ocr-ssm-profile"
  role = aws_iam_role.deepseek_ocr_ssm.name

  tags = {
    Name        = "deepseek-ocr-ssm-profile"
    Environment = "demo"
    Purpose     = "DeepSeek OCR SSM Instance Profile"
  }
}

# Security group for deepseek-ocr ALB
resource "aws_security_group" "deepseek_ocr_alb" {
  name        = "deepseek-ocr-alb-sg"
  description = "Security group for DeepSeek OCR ALB"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule for HTTP API (port 8000)
  ingress {
    description = "HTTP API access"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress rule for all traffic
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "deepseek-ocr-alb-sg"
    Environment = "demo"
    Purpose     = "DeepSeek OCR ALB Security Group"
  }
}

# Security group for deepseek-ocr-server instances
resource "aws_security_group" "deepseek_ocr" {
  name        = "deepseek-ocr-server-sg"
  description = "Security group for DeepSeek OCR server instances"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule for SSH (port 22)
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Ingress rule for HTTP API from ALB (port 8000)
  ingress {
    description     = "HTTP API access from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.deepseek_ocr_alb.id]
  }

  # Egress rule for all traffic
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "deepseek-ocr-server-sg"
    Environment = "demo"
    Purpose     = "DeepSeek OCR Server Security Group"
  }
}

# Generate RSA private key for SSH access
resource "tls_private_key" "deepseek_ocr" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS key pair using the generated public key
resource "aws_key_pair" "deepseek_ocr" {
  key_name   = "deepseek-ocr-key"
  public_key = tls_private_key.deepseek_ocr.public_key_openssh

  tags = {
    Name        = "deepseek-ocr-key"
    Environment = "demo"
    Purpose     = "DeepSeek OCR Server SSH Key"
  }
}

# Save private key to local file
resource "local_file" "private_key" {
  content         = tls_private_key.deepseek_ocr.private_key_pem
  filename        = "${path.module}/deepseek-ocr-key.pem"
  file_permission = "0600"
}

# Data source to find latest Ubuntu 22.04 GPU AMI
data "aws_ami" "ubuntu_gpu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Launch template for deepseek-ocr-server
resource "aws_launch_template" "deepseek_ocr" {
  name_prefix   = "deepseek-ocr-"
  image_id      = data.aws_ami.ubuntu_gpu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.deepseek_ocr.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.deepseek_ocr_ssm.name
  }

  vpc_security_group_ids = [aws_security_group.deepseek_ocr.id]

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {}))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "deepseek-ocr-server"
      Environment = "demo"
      Purpose     = "DeepSeek OCR Server with GPU acceleration"
    }
  }

  depends_on = [
    aws_security_group.deepseek_ocr,
    aws_key_pair.deepseek_ocr,
    aws_iam_instance_profile.deepseek_ocr_ssm
  ]
}

# Target group for deepseek-ocr ALB
resource "aws_lb_target_group" "deepseek_ocr" {
  name     = "deepseek-ocr-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/v1/models"
    matcher             = "200"
  }

  tags = {
    Name        = "deepseek-ocr-tg"
    Environment = "demo"
    Purpose     = "DeepSeek OCR Target Group"
  }
}

# Application Load Balancer for deepseek-ocr
resource "aws_lb" "deepseek_ocr" {
  name               = "deepseek-ocr-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.deepseek_ocr_alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name        = "deepseek-ocr-alb"
    Environment = "demo"
    Purpose     = "DeepSeek OCR Application Load Balancer"
  }
}

# ALB listener for deepseek-ocr
resource "aws_lb_listener" "deepseek_ocr" {
  load_balancer_arn = aws_lb.deepseek_ocr.arn
  port              = 8000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.deepseek_ocr.arn
  }
}

# Auto Scaling Group for deepseek-ocr
resource "aws_autoscaling_group" "deepseek_ocr" {
  name                      = "deepseek-ocr-asg"
  vpc_zone_identifier       = data.aws_subnets.default.ids
  target_group_arns         = [aws_lb_target_group.deepseek_ocr.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 900
  min_size                  = 0
  max_size                  = 1
  desired_capacity          = 1

  launch_template {
    id      = aws_launch_template.deepseek_ocr.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "deepseek-ocr-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "demo"
    propagate_at_launch = true
  }

  tag {
    key                 = "Purpose"
    value               = "DeepSeek OCR ASG Instance"
    propagate_at_launch = true
  }
}

# Scheduled action to start instances at 9 AM UTC+7 (2 AM UTC)
resource "aws_autoscaling_schedule" "deepseek_ocr_start" {
  scheduled_action_name  = "deepseek-ocr-start"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 1
  recurrence             = "0 2 * * *"
  autoscaling_group_name = aws_autoscaling_group.deepseek_ocr.name
}

# Scheduled action to stop instances at 7 PM UTC+7 (12 PM UTC)
resource "aws_autoscaling_schedule" "deepseek_ocr_stop" {
  scheduled_action_name  = "deepseek-ocr-stop"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 0
  recurrence             = "0 12 * * *"
  autoscaling_group_name = aws_autoscaling_group.deepseek_ocr.name
}

# Security group for Open WebUI ALB
resource "aws_security_group" "open_webui_alb" {
  name        = "open-webui-alb-sg"
  description = "Security group for Open WebUI ALB"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule for Open WebUI (port 3000)
  ingress {
    description = "Open WebUI HTTP access"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress rule for all traffic
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "open-webui-alb-sg"
    Environment = "demo"
    Purpose     = "Open WebUI ALB Security Group"
  }
}

# Security group for Open WebUI instances
resource "aws_security_group" "open_webui" {
  name        = "open-webui-sg"
  description = "Security group for Open WebUI instances"
  vpc_id      = data.aws_vpc.default.id

  # Ingress rule for SSH (port 22)
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Ingress rule for Open WebUI from ALB (port 3000)
  ingress {
    description     = "Open WebUI HTTP access from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.open_webui_alb.id]
  }

  # Egress rule for all traffic
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "open-webui-sg"
    Environment = "demo"
    Purpose     = "Open WebUI Security Group"
  }
}

# Launch template for Open WebUI
resource "aws_launch_template" "open_webui" {
  name_prefix   = "open-webui-"
  image_id      = data.aws_ami.ubuntu_gpu.id
  instance_type = var.open_webui_instance_type
  key_name      = aws_key_pair.deepseek_ocr.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.deepseek_ocr_ssm.name
  }

  vpc_security_group_ids = [aws_security_group.open_webui.id]

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/open-webui-user-data.sh", {
    deepseek_ocr_endpoint = "http://${aws_lb.deepseek_ocr.dns_name}:8000"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "open-webui-server"
      Environment = "demo"
      Purpose     = "Open WebUI for testing DeepSeek OCR"
    }
  }

  depends_on = [
    aws_security_group.open_webui,
    aws_key_pair.deepseek_ocr,
    aws_iam_instance_profile.deepseek_ocr_ssm,
    aws_lb.deepseek_ocr
  ]
}

# Target group for Open WebUI ALB
resource "aws_lb_target_group" "open_webui" {
  name     = "open-webui-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/"
    matcher             = "200"
  }

  tags = {
    Name        = "open-webui-tg"
    Environment = "demo"
    Purpose     = "Open WebUI Target Group"
  }
}

# Application Load Balancer for Open WebUI
resource "aws_lb" "open_webui" {
  name               = "open-webui-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.open_webui_alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name        = "open-webui-alb"
    Environment = "demo"
    Purpose     = "Open WebUI Application Load Balancer"
  }
}

# ALB listener for Open WebUI
resource "aws_lb_listener" "open_webui" {
  load_balancer_arn = aws_lb.open_webui.arn
  port              = 3000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.open_webui.arn
  }
}

# Auto Scaling Group for Open WebUI
resource "aws_autoscaling_group" "open_webui" {
  name                      = "open-webui-asg"
  vpc_zone_identifier       = data.aws_subnets.default.ids
  target_group_arns         = [aws_lb_target_group.open_webui.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  min_size                  = 0
  max_size                  = 1
  desired_capacity          = 1

  launch_template {
    id      = aws_launch_template.open_webui.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "open-webui-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = "demo"
    propagate_at_launch = true
  }

  tag {
    key                 = "Purpose"
    value               = "Open WebUI ASG Instance"
    propagate_at_launch = true
  }
}

# Scheduled action to start instances at 9 AM UTC+7 (2 AM UTC)
resource "aws_autoscaling_schedule" "open_webui_start" {
  scheduled_action_name  = "open-webui-start"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 1
  recurrence             = "0 2 * * *"
  autoscaling_group_name = aws_autoscaling_group.open_webui.name
}

# Scheduled action to stop instances at 7 PM UTC+7 (12 PM UTC)
resource "aws_autoscaling_schedule" "open_webui_stop" {
  scheduled_action_name  = "open-webui-stop"
  min_size               = 0
  max_size               = 1
  desired_capacity       = 0
  recurrence             = "0 12 * * *"
  autoscaling_group_name = aws_autoscaling_group.open_webui.name
}
