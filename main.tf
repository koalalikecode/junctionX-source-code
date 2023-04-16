terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "ap-southeast-1"
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "croptech-vpc"
  }
}

# Create public and private subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.0.0/20"
  availability_zone = "ap-southeast-1a"

  tags = {
    Name = "Public Subnet 1"
  }
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.16.0/20"
  availability_zone = "ap-southeast-1b"

  tags = {
    Name = "Public Subnet 2"
  }
}

resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.128.0/20"
  availability_zone = "ap-southeast-1a"

  tags = {
    Name = "Private Subnet 1"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.144.0/20"
  availability_zone = "ap-southeast-1b"

  tags = {
    Name = "Private Subnet 2"
  }
}

# Create internet gateway
resource "aws_internet_gateway" "main_ig" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Internet Gateway"
  }
}

# Create a route table for a public subnet
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_ig.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.main_ig.id
  }

  tags = {
    Name = "Public Route Table"
  }
}

resource "aws_route_table_association" "public_1_rt_a" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_2_rt_a" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# create security groups for EC2
resource "aws_security_group" "ec2-sg" {
  name   = "HTTP and SSH"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create ec2 linux instance in private subnet 2
resource "aws_instance" "input_handle_server" {
  ami                         = "ami-063e1495af50e6fd5"
  instance_type               = "m5.xlarge"
  subnet_id                   = aws_subnet.private_subnet_2.id
  vpc_security_group_ids      = [aws_security_group.ec2-sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "Input_handle_server"
  }
}

# Create ec2 linux instance in public subnet 1
resource "aws_instance" "web_server" {
  ami                         = "ami-063e1495af50e6fd5"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.public_subnet_2.id
  vpc_security_group_ids      = [aws_security_group.ec2-sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "web_server"
  }
}

# Create s3 bucket for data storage
resource "aws_s3_bucket" "croptech-s3" {
  bucket = "croptech-s3"
}

resource "aws_s3_bucket_ownership_controls" "croptech-s3-ownership" {
  bucket = aws_s3_bucket.croptech-s3.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "croptech-s3-acl" {
  depends_on = [aws_s3_bucket_ownership_controls.croptech-s3-ownership]

  bucket = aws_s3_bucket.croptech-s3.id
  acl    = "private"
}

# Create an IoT policy
resource "aws_iot_policy" "devices-policy" {
  name = "devices-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iot:Connect"
        ]
        Resource = [
          "*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iot:Publish",
          "iot:Receive"
        ]
        Resource = [
          "*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iot:GetThingShadow",
          "iot:UpdateThingShadow",
          "iot:DeleteThingShadow"
        ]
        Resource = [
          "*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iot:Subscribe"
        ]
        Resource = [
          "*"
        ]
      }
    ]
  })
}

# Create an IoT certificate
resource "aws_iot_certificate" "devices-certificate" {
  active = true
}

# Attach the certificate to a thing
resource "aws_iot_thing" "devices-things" {
  name = "devices-things"
}

resource "aws_iot_policy_attachment" "iot-policy-att" {
  policy = aws_iot_policy.devices-policy.name
  target = aws_iot_certificate.devices-certificate.arn
}

# Create an IoT rule
resource "aws_iot_topic_rule" "service-iot-rule" {
  name        = "service_iot_rule"
  enabled     = true
  sql         = "SELECT * FROM 'data'"
  sql_version = "2016-03-23"

  # Transform incoming data using a Lambda function
  lambda {
    function_arn = aws_lambda_function.data_processing_lambda_function.arn
  }


  # Store transformed data in an S3 bucket
  s3 {
    bucket_name = aws_s3_bucket.croptech-s3.id
    key         = "agriculture-data"
    role_arn    = aws_iam_role.IoT_rule_acess_S3.arn
  }
}

# Create an IAM role for the IoT rule to access the S3 bucket
resource "aws_iam_role" "IoT_rule_acess_S3" {
  name = "IoT_rule_acess_S3_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "iot.amazonaws.com"
        }
      }
    ]
  })
}

# Create an IAM policy to allow the IoT rule to access the S3 bucket
resource "aws_iam_policy" "IoT_rule_acess_S3_policy" {
  name = "IoT_rule_acess_S3_policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = aws_s3_bucket.croptech-s3.arn
      }
    ]
  })
}

# Attach the IAM policy to the IAM role
resource "aws_iam_role_policy_attachment" "example" {
  policy_arn = aws_iam_policy.IoT_rule_acess_S3_policy.arn
  role       = aws_iam_role.IoT_rule_acess_S3.name
}

# Create an IoT endpoint
data "aws_iot_endpoint" "devices-endpoint" {}

# Output the IoT endpoint
output "iot_endpoint" {
  value = data.aws_iot_endpoint.devices-endpoint.endpoint_address
}

resource "aws_db_instance" "rds_instance" {
  identifier              = "croptech-db"
  engine                  = "mysql"
  engine_version          = "5.7"
  instance_class          = "db.t2.micro"
  allocated_storage       = 20
  db_name                 = "croptechdb"
  username                = "db_user"
  password                = "db_password"
  parameter_group_name    = "default.mysql5.7"
  backup_retention_period = 7
  vpc_security_group_ids  = [aws_security_group.rds_security_group.id]
  db_subnet_group_name    = aws_db_subnet_group.rds_subnet_group.name

  tags = {
    Name = "agriculture-db"
  }
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name        = "agriculture-db-subnet-group"
  description = "Subnet group for agriculture RDS instance"

  subnet_ids = [
    aws_subnet.private_subnet_1.id,
    aws_subnet.private_subnet_2.id,
  ]
}

resource "aws_security_group" "rds_security_group" {
  name_prefix = "rds-security-group"

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.private_subnet_1.cidr_block, aws_subnet.private_subnet_2.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-security-group"
  }
}

# Archive lambda function
data "archive_file" "main" {
  type        = "zip"
  source_dir  = "function"
  output_path = "${path.module}/.terraform/archive_files/function.zip"

  depends_on = [null_resource.main]
}

# Provisioner to install dependencies in lambda package before upload it.
resource "null_resource" "main" {

  triggers = {
    updated_at = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOF
    yarn
    EOF

    working_dir = "${path.module}/function"
  }
}

# setting up AWS Lambda function
resource "aws_lambda_function" "data_processing_lambda_function" {
  filename      = "${path.module}/.terraform/archive_files/function.zip"
  function_name = "data_processing_lambda_function"
  handler       = "index.handler"
  role          = aws_iam_role.lambda.arn
  runtime       = "nodejs14.x"
  memory_size   = 256
  timeout       = 300

  source_code_hash = data.archive_file.main.output_base64sha256
}

# Create an IAM role for the Lambda function
resource "aws_iam_role" "lambda" {
  name = "lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Attach an IAM policy to the Lambda role to allow it to write to S3
resource "aws_iam_role_policy_attachment" "lambda" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.lambda.name
}

# Create a SageMaker Notebook Instance
resource "aws_sagemaker_notebook_instance" "sagemaker_instance" {
  name          = "sagemaker-notebook-instance"
  instance_type = "ml.t2.medium"

  # Attach an IAM role with appropriate permissions
  role_arn = aws_iam_role.sagemaker.arn
}

# Create an IAM role for SageMaker with appropriate permissions
resource "aws_iam_role" "sagemaker" {
  name = "sagemaker-role"

  # Attach policies with the necessary permissions
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
      }
    ]
  })
}
