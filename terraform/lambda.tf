# Lambda function + HTTP API Gateway (v2) for Discord interactions.

# Package the Lambda source from a dedicated build directory.
# Build it via ./lambda/build.sh before terraform plan/apply.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../build/lambda-package"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "interactions" {
  function_name    = "${var.project_name}-interactions"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_handler.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      DISCORD_PUBLIC_KEY      = var.discord_public_key
      DISCORD_APPLICATION_ID  = var.discord_application_id
      INSTANCE_ID             = aws_instance.palworld.id
      PLAYER_COUNT_PARAM_NAME = var.player_count_param_name
      DATA_USAGE_PARAM_NAME   = var.data_usage_param_name
      AWS_REGION_NAME         = var.aws_region
      DISCORD_WEBHOOK_URL     = var.discord_webhook_url
    }
  }
}

resource "aws_lambda_function" "alarm_notifier" {
  function_name    = "${var.project_name}-alarm-notifier"
  role             = aws_iam_role.alarm_notifier.arn
  handler          = "alarm_notifier.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      DISCORD_WEBHOOK_URL = var.discord_webhook_url
    }
  }
}

resource "aws_lambda_permission" "sns_alarm_notifier" {
  statement_id  = "AllowSNSInvokeAlarmNotifier"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alarm_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm_notifications.arn
}

resource "aws_sns_topic_subscription" "alarm_notifier_lambda" {
  topic_arn = aws_sns_topic.alarm_notifications.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.alarm_notifier.arn
}

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.interactions.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "interactions" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /interactions"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.interactions.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
