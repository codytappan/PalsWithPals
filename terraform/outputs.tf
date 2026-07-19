# Useful outputs after apply.

output "public_ip" {
  description = "Public IP after apply. After later stop/start cycles, use /palworld-status for the current IP."
  value       = aws_instance.palworld.public_ip
}

output "instance_id" {
  description = "EC2 instance ID of the Palworld server."
  value       = aws_instance.palworld.id
}

output "interactions_endpoint_url" {
  description = "Paste this into the Discord app's Interactions Endpoint URL."
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/interactions"
}
