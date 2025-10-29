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
resource "aws_iam_role" "enhanced_deepseek_ocr_ssm" {
  name = "enhanced-deepseek-ocr-ssm-role"

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
    Name        = "enhanced-deepseek-ocr-ssm-role"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR SSM Access"
    Deployment  = "enhanced"
  }
}

# Attach AWS managed policy for SSM
resource "aws_iam_role_policy_attachment" "enhanced_deepseek_ocr_ssm" {
  role       = aws_iam_role.enhanced_deepseek_ocr_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile for the EC2 instance
resource "aws_iam_instance_profile" "enhanced_deepseek_ocr_ssm" {
  name = "enhanced-deepseek-ocr-ssm-profile"
  role = aws_iam_role.enhanced_deepseek_ocr_ssm.name

  tags = {
    Name        = "enhanced-deepseek-ocr-ssm-profile"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR SSM Instance Profile"
    Deployment  = "enhanced"
  }
}

# Security group for enhanced deepseek-ocr ALB
resource "aws_security_group" "enhanced_deepseek_ocr_alb" {
  name        = "enhanced-deepseek-ocr-alb-sg"
  description = "Security group for Enhanced DeepSeek OCR ALB"
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
    Name        = "enhanced-deepseek-ocr-alb-sg"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR ALB Security Group"
    Deployment  = "enhanced"
  }
}

# Security group for enhanced deepseek-ocr-server instances
resource "aws_security_group" "enhanced_deepseek_ocr" {
  name        = "enhanced-deepseek-ocr-server-sg"
  description = "Security group for Enhanced DeepSeek OCR server instances"
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
    security_groups = [aws_security_group.enhanced_deepseek_ocr_alb.id]
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
    Name        = "enhanced-deepseek-ocr-server-sg"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR Server Security Group"
    Deployment  = "enhanced"
  }
}

# Generate RSA private key for SSH access
resource "tls_private_key" "enhanced_deepseek_ocr" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS key pair using the generated public key
resource "aws_key_pair" "enhanced_deepseek_ocr" {
  key_name   = "enhanced-deepseek-ocr-key"
  public_key = tls_private_key.enhanced_deepseek_ocr.public_key_openssh

  tags = {
    Name        = "enhanced-deepseek-ocr-key"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR Server SSH Key"
    Deployment  = "enhanced"
  }
}

# Save private key to local file
resource "local_file" "enhanced_private_key" {
  content         = tls_private_key.enhanced_deepseek_ocr.private_key_pem
  filename        = "${path.module}/enhanced-deepseek-ocr-key.pem"
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

# EC2 instance for enhanced deepseek-ocr-server
resource "aws_instance" "enhanced_deepseek_ocr" {
  ami                    = data.aws_ami.ubuntu_gpu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.enhanced_deepseek_ocr.key_name
  iam_instance_profile   = aws_iam_instance_profile.enhanced_deepseek_ocr_ssm.name
  vpc_security_group_ids = [aws_security_group.enhanced_deepseek_ocr.id]
  user_data              = templatefile("${path.module}/user-data.sh", {})

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = false
  }

  tags = {
    Name        = "enhanced-deepseek-ocr-server"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR Server with GPU acceleration and multimodal support"
    AutoStop    = "true"
    Deployment  = "enhanced"
  }

  depends_on = [
    aws_security_group.enhanced_deepseek_ocr,
    aws_key_pair.enhanced_deepseek_ocr,
    aws_iam_instance_profile.enhanced_deepseek_ocr_ssm
  ]
}

# Target group for enhanced deepseek-ocr ALB
resource "aws_lb_target_group" "enhanced_deepseek_ocr" {
  name     = "enhanced-deepseek-ocr-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 10
    interval            = 30
    path                = "/v1/health"
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name        = "enhanced-deepseek-ocr-tg"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR Target Group"
    Deployment  = "enhanced"
  }
}

# Attach enhanced deepseek-ocr instance to target group
resource "aws_lb_target_group_attachment" "enhanced_deepseek_ocr" {
  target_group_arn = aws_lb_target_group.enhanced_deepseek_ocr.arn
  target_id        = aws_instance.enhanced_deepseek_ocr.id
  port             = 8000
}

# Application Load Balancer for enhanced deepseek-ocr
resource "aws_lb" "enhanced_deepseek_ocr" {
  name               = "enhanced-deepseek-ocr-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.enhanced_deepseek_ocr_alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name        = "enhanced-deepseek-ocr-alb"
    Environment = "demo"
    Purpose     = "Enhanced DeepSeek OCR Application Load Balancer"
    Deployment  = "enhanced"
  }
}

# ALB listener for enhanced deepseek-ocr
resource "aws_lb_listener" "enhanced_deepseek_ocr" {
  load_balancer_arn = aws_lb.enhanced_deepseek_ocr.arn
  port              = 8000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.enhanced_deepseek_ocr.arn
  }
}



# Security group for Enhanced Open WebUI ALB
resource "aws_security_group" "enhanced_open_webui_alb" {
  name        = "enhanced-open-webui-alb-sg"
  description = "Security group for Enhanced Open WebUI ALB"
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
    Name        = "enhanced-open-webui-alb-sg"
    Environment = "demo"
    Purpose     = "Enhanced Open WebUI ALB Security Group"
    Deployment  = "enhanced"
  }
}

# Security group for Enhanced Open WebUI instances
resource "aws_security_group" "enhanced_open_webui" {
  name        = "enhanced-open-webui-sg"
  description = "Security group for Enhanced Open WebUI instances"
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
    security_groups = [aws_security_group.enhanced_open_webui_alb.id]
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
    Name        = "enhanced-open-webui-sg"
    Environment = "demo"
    Purpose     = "Enhanced Open WebUI Security Group"
    Deployment  = "enhanced"
  }
}

# EC2 instance for Enhanced Open WebUI
resource "aws_instance" "enhanced_open_webui" {
  ami                    = data.aws_ami.ubuntu_gpu.id
  instance_type          = var.open_webui_instance_type
  key_name               = aws_key_pair.enhanced_deepseek_ocr.key_name
  iam_instance_profile   = aws_iam_instance_profile.enhanced_deepseek_ocr_ssm.name
  vpc_security_group_ids = [aws_security_group.enhanced_open_webui.id]
  user_data = templatefile("${path.module}/open-webui-user-data.sh", {
    deepseek_ocr_endpoint = "http://${aws_lb.enhanced_deepseek_ocr.dns_name}:8000"
  })

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = false
  }

  tags = {
    Name        = "enhanced-open-webui-server"
    Environment = "demo"
    Purpose     = "Enhanced Open WebUI for testing DeepSeek OCR with multimodal support"
    AutoStop    = "true"
    Deployment  = "enhanced"
  }

  depends_on = [
    aws_security_group.enhanced_open_webui,
    aws_key_pair.enhanced_deepseek_ocr,
    aws_iam_instance_profile.enhanced_deepseek_ocr_ssm,
    aws_lb.enhanced_deepseek_ocr
  ]
}

# Target group for Enhanced Open WebUI ALB
resource "aws_lb_target_group" "enhanced_open_webui" {
  name     = "enhanced-open-webui-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 10
    timeout             = 10
    interval            = 30
    path                = "/"
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name        = "enhanced-open-webui-tg"
    Environment = "demo"
    Purpose     = "Enhanced Open WebUI Target Group"
    Deployment  = "enhanced"
  }
}

# Attach enhanced open-webui instance to target group
resource "aws_lb_target_group_attachment" "enhanced_open_webui" {
  target_group_arn = aws_lb_target_group.enhanced_open_webui.arn
  target_id        = aws_instance.enhanced_open_webui.id
  port             = 3000
}

# Application Load Balancer for Enhanced Open WebUI
resource "aws_lb" "enhanced_open_webui" {
  name               = "enhanced-open-webui-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.enhanced_open_webui_alb.id]
  subnets            = data.aws_subnets.default.ids

  tags = {
    Name        = "enhanced-open-webui-alb"
    Environment = "demo"
    Purpose     = "Enhanced Open WebUI Application Load Balancer"
    Deployment  = "enhanced"
  }
}

# ALB listener for Enhanced Open WebUI
resource "aws_lb_listener" "enhanced_open_webui" {
  load_balancer_arn = aws_lb.enhanced_open_webui.arn
  port              = 3000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.enhanced_open_webui.arn
  }
}



# IAM role for Lambda function
resource "aws_iam_role" "enhanced_lambda_scheduler" {
  name = "enhanced-ec2-scheduler-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "enhanced-ec2-scheduler-lambda-role"
    Environment = "demo"
    Purpose     = "Enhanced Lambda role for EC2 instance scheduling"
    Deployment  = "enhanced"
  }
}

# IAM policy for Lambda to manage EC2 instances
resource "aws_iam_role_policy" "enhanced_lambda_scheduler" {
  name = "enhanced-ec2-scheduler-policy"
  role = aws_iam_role.enhanced_lambda_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StopInstances",
          "ec2:StartInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Archive Lambda function code
data "archive_file" "enhanced_lambda_scheduler" {
  type        = "zip"
  source_file = "${path.module}/lambda_scheduler.py"
  output_path = "${path.module}/lambda_scheduler.zip"
}

# Lambda function for EC2 scheduling
resource "aws_lambda_function" "enhanced_ec2_scheduler" {
  filename         = data.archive_file.enhanced_lambda_scheduler.output_path
  function_name    = "enhanced-ec2-instance-scheduler"
  role             = aws_iam_role.enhanced_lambda_scheduler.arn
  handler          = "lambda_scheduler.lambda_handler"
  source_code_hash = data.archive_file.enhanced_lambda_scheduler.output_base64sha256
  runtime          = "python3.11"
  timeout          = 60

  environment {
    variables = {
      TAG_KEY   = "AutoStop"
      TAG_VALUE = "true"
    }
  }

  tags = {
    Name        = "enhanced-ec2-instance-scheduler"
    Environment = "demo"
    Purpose     = "Enhanced scheduled EC2 instance stop/start"
    Deployment  = "enhanced"
  }
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "enhanced_lambda_scheduler" {
  name              = "/aws/lambda/${aws_lambda_function.enhanced_ec2_scheduler.function_name}"
  retention_in_days = 7

  tags = {
    Name        = "enhanced-ec2-scheduler-logs"
    Environment = "demo"
    Deployment  = "enhanced"
  }
}

# EventBridge rule to stop instances at 7 PM UTC+7 (12 PM UTC)
resource "aws_cloudwatch_event_rule" "enhanced_stop_instances" {
  name                = "enhanced-stop-instances-7pm-utc7"
  description         = "Stop Enhanced EC2 instances at 7 PM UTC+7 (12 PM UTC)"
  schedule_expression = "cron(0 12 * * ? *)"

  tags = {
    Name        = "enhanced-stop-instances-schedule"
    Environment = "demo"
    Deployment  = "enhanced"
  }
}

# EventBridge target for stop rule
resource "aws_cloudwatch_event_target" "enhanced_stop_instances" {
  rule      = aws_cloudwatch_event_rule.enhanced_stop_instances.name
  target_id = "StopEnhancedEC2Instances"
  arn       = aws_lambda_function.enhanced_ec2_scheduler.arn

  input = jsonencode({
    action = "stop"
  })
}

# Lambda permission for stop rule
resource "aws_lambda_permission" "enhanced_allow_eventbridge_stop" {
  statement_id  = "AllowExecutionFromEventBridgeStop"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.enhanced_ec2_scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.enhanced_stop_instances.arn
}

# EventBridge rule to start instances at 9 AM UTC+7 (2 AM UTC)
resource "aws_cloudwatch_event_rule" "enhanced_start_instances" {
  name                = "enhanced-start-instances-9am-utc7"
  description         = "Start Enhanced EC2 instances at 9 AM UTC+7 (2 AM UTC)"
  schedule_expression = "cron(0 2 * * ? *)"

  tags = {
    Name        = "enhanced-start-instances-schedule"
    Environment = "demo"
    Deployment  = "enhanced"
  }
}

# EventBridge target for start rule
resource "aws_cloudwatch_event_target" "enhanced_start_instances" {
  rule      = aws_cloudwatch_event_rule.enhanced_start_instances.name
  target_id = "StartEnhancedEC2Instances"
  arn       = aws_lambda_function.enhanced_ec2_scheduler.arn

  input = jsonencode({
    action = "start"
  })
}

# Lambda permission for start rule
resource "aws_lambda_permission" "enhanced_allow_eventbridge_start" {
  statement_id  = "AllowExecutionFromEventBridgeStart"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.enhanced_ec2_scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.enhanced_start_instances.arn
}
