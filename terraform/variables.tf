# Input variables for the Palworld server infrastructure.
# Secrets are marked `sensitive` and must be supplied at deploy time
# (e.g. via terraform.tfvars, which is gitignored). Never commit real values.

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for the game server. See the scaling guide in README for the upgrade ladder."
  type        = string
  default     = "m6i.xlarge"
}

variable "data_volume_size_gb" {
  description = "Size (GiB) of the persistent EBS data volume that holds the world save."
  type        = number
  default     = 20
}

variable "root_volume_size_gb" {
  description = "Size (GiB) of the EC2 root volume."
  type        = number
  default     = 30
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (port 22) into the instance. Restrict to your IP, e.g. 1.2.3.4/32."
  type        = string
}

variable "discord_public_key" {
  description = "Discord application public key, used by the Lambda to verify request signatures."
  type        = string
  sensitive   = true
}

variable "discord_application_id" {
  description = "Discord application ID."
  type        = string
  sensitive   = true
}

variable "discord_webhook_url" {
  description = "Discord webhook URL for optional server notifications."
  type        = string
  sensitive   = true
  default     = ""
}

variable "server_name" {
  description = "Name displayed in the Palworld community server list."
  type        = string
  default     = "PalsWithPals"
}

variable "server_description" {
  description = "Description displayed in the Palworld community server list."
  type        = string
  default     = ""
}

variable "server_password" {
  description = "Palworld server password (players must enter this to join)."
  type        = string
  sensitive   = true
}

variable "admin_password" {
  description = "Palworld admin/RCON password."
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Prefix used for naming/tagging resources."
  type        = string
  default     = "palworld"
}

variable "player_count_param_name" {
  description = "SSM Parameter Store name used to cache the current player count."
  type        = string
  default     = "/palworld/player_count"
}

variable "data_usage_param_name" {
  description = "SSM Parameter Store name used to cache persistent data volume usage percent."
  type        = string
  default     = "/palworld/data_usage_percent"
}

