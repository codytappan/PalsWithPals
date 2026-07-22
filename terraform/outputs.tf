# Useful outputs after apply.

output "public_ip" {
  description = "Stable Elastic IP for the game server (persists across instance stop/start)."
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
