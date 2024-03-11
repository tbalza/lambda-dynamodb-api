provider "aws" {
  region = "us-west-1"
}

################################################################################
# IAM: Lambda Role
################################################################################

# Create custom IAM policy
module "iam_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 5.37.1"

  name        = "lambda-apigateway-role-policy"
  description = "Custom policy with permission to DynamoDB and CloudWatch Logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "Stmt1428341300017"
        Action = [
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:UpdateItem"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Sid      = ""
        Resource = "*"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect = "Allow"
      }
    ]
  })
}

# Create role for lambda function, attach custom IAM policy and trusted entity
module "iam_assumable_role_lambda" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.37.1"

  create_role = true
  role_name   = "lambda-apigateway-role"

  /* This could cleanly replace the custom_trust_policy data module, needs further testing
  allow_self_assume_role = true
  trusted_role_services = [
    "lambda.amazonaws.com"
  ]
  */

  create_custom_role_trust_policy = true
  custom_role_trust_policy        = data.aws_iam_policy_document.custom_trust_policy.json

  custom_role_policy_arns = [module.iam_policy.arn] # Get the ARN from the iam_policy module
}

# Create trusted entity
data "aws_iam_policy_document" "custom_trust_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Create trigger equivalent to explicitly grant permissions to the API Gateway to invoke your Lambda function
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.example.arn
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_deployment.dev.execution_arn}/*"
}

################################################################################
# Lambda
################################################################################

# Zip the lambda_function.py to enable uploading to AWS
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# Create lambda function from lambda_function.py
resource "aws_lambda_function" "example" {
  function_name = "LambdaFunctionsOverHttps"
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  filename = data.archive_file.lambda_zip.output_path

  # Associate function to previously created role
  role = module.iam_assumable_role_lambda.iam_role_arn # Get the ARN from the iam_assumable_role_lambda module

}

################################################################################
# DynamoDB
################################################################################

# Create a simple dynamodb table
module "dynamodb_table" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 4.0.1"

  name     = "lambda-apigateway"
  hash_key = "id" # primary key

  attributes = [
    {
      name = "id"
      type = "S"
    }
  ]
}

################################################################################
# API
################################################################################

# Create API
resource "aws_api_gateway_rest_api" "DynamoDBOperations" {
  name           = "DynamoDBOperations"
  description    = "API for DynamoDB Operations"
  api_key_source = "HEADER"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# Create resource
resource "aws_api_gateway_resource" "DynamoDBManager" {
  rest_api_id = aws_api_gateway_rest_api.DynamoDBOperations.id
  parent_id   = aws_api_gateway_rest_api.DynamoDBOperations.root_resource_id
  path_part   = "dynamodbmanager"
}

# Create POST method
resource "aws_api_gateway_method" "post" {
  rest_api_id      = aws_api_gateway_rest_api.DynamoDBOperations.id
  resource_id      = aws_api_gateway_resource.DynamoDBManager.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}

# Link API to Lambda function
resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.DynamoDBOperations.id
  resource_id = aws_api_gateway_resource.DynamoDBManager.id
  http_method = aws_api_gateway_method.post.http_method

  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = aws_lambda_function.example.invoke_arn
  passthrough_behavior    = "WHEN_NO_MATCH"
}

# Create response code
resource "aws_api_gateway_method_response" "response" {
  rest_api_id = aws_api_gateway_rest_api.DynamoDBOperations.id
  resource_id = aws_api_gateway_resource.DynamoDBManager.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "200"
}

# Integrate response code
resource "aws_api_gateway_integration_response" "lambda" {
  depends_on  = [aws_api_gateway_integration.lambda, aws_api_gateway_method_response.response]
  rest_api_id = aws_api_gateway_rest_api.DynamoDBOperations.id
  resource_id = aws_api_gateway_resource.DynamoDBManager.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = aws_api_gateway_method_response.response.status_code
}

# Deploy in "Dev"
resource "aws_api_gateway_deployment" "dev" {
  depends_on  = [aws_api_gateway_integration.lambda]
  rest_api_id = aws_api_gateway_rest_api.DynamoDBOperations.id
  stage_name  = "dev"
}







