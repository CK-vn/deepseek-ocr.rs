# Enhanced DeepSeek OCR outputs
output "enhanced_deepseek_ocr_alb_dns" {
  value       = aws_lb.enhanced_deepseek_ocr.dns_name
  description = "Enhanced DeepSeek OCR ALB DNS name (persistent)"
}

output "enhanced_deepseek_ocr_api_endpoint" {
  value       = "http://${aws_lb.enhanced_deepseek_ocr.dns_name}:8000"
  description = "Enhanced DeepSeek OCR API endpoint via ALB"
}

output "enhanced_deepseek_ocr_instance_id" {
  value       = aws_instance.enhanced_deepseek_ocr.id
  description = "Enhanced DeepSeek OCR EC2 instance ID"
}

output "enhanced_deepseek_ocr_schedule" {
  value       = "Starts at 9 AM UTC+7 (2 AM UTC), Stops at 7 PM UTC+7 (12 PM UTC)"
  description = "Enhanced DeepSeek OCR scheduled start/stop times"
}

# Enhanced Open WebUI outputs
output "enhanced_open_webui_alb_dns" {
  value       = aws_lb.enhanced_open_webui.dns_name
  description = "Enhanced Open WebUI ALB DNS name (persistent)"
}

output "enhanced_open_webui_url" {
  value       = "http://${aws_lb.enhanced_open_webui.dns_name}:3000"
  description = "Enhanced Open WebUI access URL via ALB"
}

output "enhanced_open_webui_instance_id" {
  value       = aws_instance.enhanced_open_webui.id
  description = "Enhanced Open WebUI EC2 instance ID"
}

output "enhanced_open_webui_schedule" {
  value       = "Starts at 9 AM UTC+7 (2 AM UTC), Stops at 7 PM UTC+7 (12 PM UTC)"
  description = "Enhanced Open WebUI scheduled start/stop times"
}

# General outputs
output "enhanced_ssh_key_file" {
  value       = "${path.module}/enhanced-deepseek-ocr-key.pem"
  description = "Enhanced deployment SSH private key file location"
}

output "enhanced_list_instances_command" {
  value       = "aws ec2 describe-instances --filters 'Name=tag:Deployment,Values=enhanced' --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' --output table --region ${var.aws_region}"
  description = "Command to list all instances in the enhanced deployment"
}

# Scheduler outputs
output "enhanced_lambda_scheduler_function" {
  value       = aws_lambda_function.enhanced_ec2_scheduler.function_name
  description = "Enhanced Lambda function name for EC2 scheduling"
}

output "enhanced_manual_stop_command" {
  value       = "aws lambda invoke --function-name ${aws_lambda_function.enhanced_ec2_scheduler.function_name} --payload '{\"action\":\"stop\"}' /tmp/response.json --region ${var.aws_region}"
  description = "Command to manually stop enhanced instances"
}

output "enhanced_manual_start_command" {
  value       = "aws lambda invoke --function-name ${aws_lambda_function.enhanced_ec2_scheduler.function_name} --payload '{\"action\":\"start\"}' /tmp/response.json --region ${var.aws_region}"
  description = "Command to manually start enhanced instances"
}
