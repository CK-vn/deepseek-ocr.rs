# DeepSeek OCR outputs
output "deepseek_ocr_alb_dns" {
  value       = aws_lb.deepseek_ocr.dns_name
  description = "DeepSeek OCR ALB DNS name (persistent)"
}

output "deepseek_ocr_api_endpoint" {
  value       = "http://${aws_lb.deepseek_ocr.dns_name}:8000"
  description = "DeepSeek OCR API endpoint via ALB"
}

output "deepseek_ocr_instance_id" {
  value       = aws_instance.deepseek_ocr.id
  description = "DeepSeek OCR EC2 instance ID"
}

output "deepseek_ocr_schedule" {
  value       = "Starts at 9 AM UTC+7 (2 AM UTC), Stops at 7 PM UTC+7 (12 PM UTC)"
  description = "DeepSeek OCR scheduled start/stop times"
}

# Open WebUI outputs
output "open_webui_alb_dns" {
  value       = aws_lb.open_webui.dns_name
  description = "Open WebUI ALB DNS name (persistent)"
}

output "open_webui_url" {
  value       = "http://${aws_lb.open_webui.dns_name}:3000"
  description = "Open WebUI access URL via ALB"
}

output "open_webui_instance_id" {
  value       = aws_instance.open_webui.id
  description = "Open WebUI EC2 instance ID"
}

output "open_webui_schedule" {
  value       = "Starts at 9 AM UTC+7 (2 AM UTC), Stops at 7 PM UTC+7 (12 PM UTC)"
  description = "Open WebUI scheduled start/stop times"
}

# General outputs
output "ssh_key_file" {
  value       = "${path.module}/deepseek-ocr-key.pem"
  description = "SSH private key file location"
}

output "list_instances_command" {
  value       = "aws ec2 describe-instances --filters 'Name=tag:Environment,Values=demo' --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' --output table --region ${var.aws_region}"
  description = "Command to list all instances in the deployment"
}

# Scheduler outputs
output "lambda_scheduler_function" {
  value       = aws_lambda_function.ec2_scheduler.function_name
  description = "Lambda function name for EC2 scheduling"
}

output "manual_stop_command" {
  value       = "aws lambda invoke --function-name ${aws_lambda_function.ec2_scheduler.function_name} --payload '{\"action\":\"stop\"}' /tmp/response.json --region ${var.aws_region}"
  description = "Command to manually stop instances"
}

output "manual_start_command" {
  value       = "aws lambda invoke --function-name ${aws_lambda_function.ec2_scheduler.function_name} --payload '{\"action\":\"start\"}' /tmp/response.json --region ${var.aws_region}"
  description = "Command to manually start instances"
}
