# Core infrastructure: networking lookups, security group, EC2 instance,
# persistent EBS data volume, and CloudWatch alarms.

data "aws_vpc" "default" {
  default = true
}

# Subnet is pinned to us-west-1b to match the persistent EBS data volume.
# Changing this would strand the world save on a volume in the wrong AZ.
data "aws_subnet" "selected" {
  id = "subnet-a05345c7"
}

# Latest Ubuntu 24.04 LTS AMI via the Canonical SSM public parameter.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# Render the cloud-init user data, injecting deploy-time values.
locals {
  user_data = templatefile("${path.module}/../ec2/cloud-init.yaml", {
    aws_region              = var.aws_region
    server_password         = var.server_password
    admin_password          = var.admin_password
    discord_webhook_url     = var.discord_webhook_url
    server_name             = var.server_name
    server_description      = var.server_description
    player_count_param_name = var.player_count_param_name
    data_usage_param_name   = var.data_usage_param_name
    compose_yaml_b64        = base64encode(file("${path.module}/../ec2/compose.yaml"))
    idle_shutdown_sh_b64    = base64encode(file("${path.module}/../ec2/idle-shutdown.sh"))
    start_palworld_sh_b64   = base64encode(file("${path.module}/../ec2/start-palworld.sh"))
  })
}

resource "aws_security_group" "palworld" {
  name        = "${var.project_name}-sg"
  description = "Palworld server access"
  vpc_id      = data.aws_vpc.default.id

  # Palworld game traffic.
  ingress {
    description = "Palworld game port"
    from_port   = 8211
    to_port     = 8211
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Steam query port.
  ingress {
    description = "Steam query"
    from_port   = 27015
    to_port     = 27015
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH restricted to the operator's IP. NOTE: 8212 (REST API) is intentionally
  # NOT exposed here; it stays bound to localhost on the instance.
  ingress {
    description = "SSH (restricted)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

# Optional key pair for SSH access. Leave ssh_public_key empty to rely on SSM only.
resource "aws_key_pair" "operator" {
  count      = trimspace(var.ssh_public_key) == "" ? 0 : 1
  key_name   = "${var.project_name}-operator"
  public_key = trimspace(var.ssh_public_key)
}

resource "aws_instance" "palworld" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.selected.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.palworld.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data                   = local.user_data
  user_data_replace_on_change = true
  key_name                    = trimspace(var.ssh_public_key) == "" ? null : aws_key_pair.operator[0].key_name

  # Use spot pricing (~44% cheaper). World save is on persistent EBS so
  # interruptions are safe — players get kicked and can reconnect after restart.
  instance_market_options {
    market_type = "spot"

    spot_options {
      spot_instance_type             = "persistent"
      instance_interruption_behavior = "stop"
    }
  }

  # Enforce IMDSv2.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-server" }
}

# Persistent data volume for the world save; survives instance stop/start and
# instance-type changes so upgrades need no data migration.
# AZ is pinned to us-west-1b — must match the subnet above.
resource "aws_ebs_volume" "data" {
  availability_zone = "us-west-1b"
  size              = var.data_volume_size_gb
  type              = "gp3"
  tags              = { Name = "${var.project_name}-data" }

  lifecycle {
    # Prevent accidental destruction of the world save volume.
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.palworld.id
}

resource "aws_sns_topic" "alarm_notifications" {
  name = "${var.project_name}-alarm-notifications"
}


# CPU alarm: sustained high CPU is a signal to scale up.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "Sustained CPU >85% - consider scaling up (see README scaling guide)."
  dimensions          = { InstanceId = aws_instance.palworld.id }
  alarm_actions       = [aws_sns_topic.alarm_notifications.arn]
}

# Memory alarm relies on the CloudWatch agent publishing mem_used_percent
# to the CWAgent namespace (installed via cloud-init).
resource "aws_cloudwatch_metric_alarm" "mem_high" {
  alarm_name          = "${var.project_name}-mem-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "mem_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 90
  alarm_description   = "Sustained memory >90% - consider a higher-RAM instance (see README scaling guide)."
  dimensions          = { InstanceId = aws_instance.palworld.id }
  alarm_actions       = [aws_sns_topic.alarm_notifications.arn]
}
