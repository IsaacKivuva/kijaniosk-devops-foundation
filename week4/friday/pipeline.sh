#!/bin/bash
set -e

echo "Running Terraform..."
cd terraform
terraform apply -auto-approve

API_IP=$(terraform output -raw api_server_ip)
PAYMENTS_IP=$(terraform output -raw payments_server_ip)
LOGS_IP=$(terraform output -raw logs_server_ip)

cd ../ansible

echo "Writing inventory..."

cat > inventory.ini <<EOF
[api]
api ansible_host=$API_IP

[payments]
payments ansible_host=$PAYMENTS_IP

[logs]
logs ansible_host=$LOGS_IP

[kijanikiosk:children]
api
payments
logs
EOF

echo "Running Ansible..."
ansible-playbook -i inventory.ini kijanikiosk.yml

echo "Pipeline complete"