output "api_invoke_url" {
  description = "api_invoke_url"
  value       = "${aws_api_gateway_deployment.dev.invoke_url}/${aws_api_gateway_resource.DynamoDBManager.path_part}"
}