# Useful outputs after apply.

output "elastic_ip" {
  description = "Stable public IP to connect to in-game (port 8211)."
  value       = aws_eip.palworld.public_ip
}

output "instance_id" {
  description = "EC2 instance ID of the Palworld server."
  value       = aws_instance.palworld.id
}

output "interactions_endpoint_url" {
  description = "Paste this into the Discord app's Interactions Endpoint URL."
  value       = "${aws_apigatewayv2_api.http.api_endpoint}/interactions"
}
