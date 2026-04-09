variable "name" {
  description = "Server name"
  type        = string
}

variable "instance_type" {
  description = "Instance type"
  type        = string
}

variable "ami_id" {
  description = "AMI ID"
  type        = string
}

variable "key_name" {
  description = "SSH key name"
  type        = string
}

variable "security_group_id" {
  description = "Security group"
  type        = string
}