variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region for deployment"
}

variable "instance_type" {
  type        = string
  default     = "g6.xlarge"
  description = "EC2 instance type"
}

variable "root_volume_size" {
  type        = number
  default     = 50
  description = "Root volume size in GB"
}

variable "allowed_ssh_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR block allowed to SSH"
}

variable "open_webui_instance_type" {
  type        = string
  default     = "t3.medium"
  description = "EC2 instance type for Open WebUI"
}
