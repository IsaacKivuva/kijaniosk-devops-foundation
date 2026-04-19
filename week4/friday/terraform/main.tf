provider "aws" {
  region = var.region
}

locals {
  servers = {
    api      = {}
    payments = {}
    logs     = {}
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  owners = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_security_group" "app" {
  name = "jenkins-app-sg"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
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

module "app_servers" {
  source = "./modules/app_server"

  for_each = local.servers

  name              = "kk-${each.key}"
  instance_type     = var.instance_type
  ami_id            = data.aws_ami.ubuntu.id
  key_name          = var.ssh_key_name
  security_group_id = aws_security_group.app.id
}
