# IAM roles and policies for the EC2 instance and the Lambda function.

data "aws_caller_identity" "current" {}

locals {
  instance_arn   = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.palworld.id}"
  param_arn      = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.player_count_param_name}"
  data_param_arn = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.data_usage_param_name}"
}

# ---------------------------------------------------------------------------
# EC2 instance role: allow it to stop itself and write the player-count cache.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Managed policy required for the SSM agent (SendCommand target + Session Manager).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_inline" {
  # Allow the instance to stop itself.
  statement {
    actions   = ["ec2:StopInstances"]
    resources = [local.instance_arn]
  }

  # Read/write the cached player count.
  statement {
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = [local.param_arn, local.data_param_arn]
  }
}

resource "aws_iam_role_policy" "ec2_inline" {
  name   = "${var.project_name}-ec2-inline"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_inline.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# Lambda role: start/stop the instance, describe instances, send SSM commands,
# read the cached count, and write CloudWatch Logs.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_inline" {
  statement {
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [local.instance_arn]
  }

  # DescribeInstances does not support resource-level permissions.
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # Run the save command on the instance before stopping.
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["*"]
  }

  statement {
    actions   = ["ssm:GetParameter"]
    resources = [local.param_arn, local.data_param_arn]
  }

  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  name   = "${var.project_name}-lambda-inline"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_inline.json
}

# ---------------------------------------------------------------------------
# Alarm notifier Lambda role: receive SNS alarm events and post to Discord.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "alarm_notifier_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alarm_notifier" {
  name               = "${var.project_name}-alarm-notifier-role"
  assume_role_policy = data.aws_iam_policy_document.alarm_notifier_assume.json
}

data "aws_iam_policy_document" "alarm_notifier_inline" {
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "alarm_notifier_inline" {
  name   = "${var.project_name}-alarm-notifier-inline"
  role   = aws_iam_role.alarm_notifier.id
  policy = data.aws_iam_policy_document.alarm_notifier_inline.json
}

