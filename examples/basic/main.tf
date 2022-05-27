terraform {
  required_version = ">=1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = "default"
}

module "acs" {
  source  = "bitbucket.org/liveviewtech/terraform-aws-acs-info.git?ref=v1"
  profile = "default"
}

resource "aws_ecs_cluster" "example" {
  name = "hello-world"
}

module "example" {
  # source = "bitbucket.org/liveviewtech/terraform-aws-fargate-api.git?ref=v0.2.0"
  source = "../../"

  name = "hello-world"

  container_port   = 80
  ecs_cluster_name = aws_ecs_cluster.example.name
  primary_container_definition = {
    name                  = "hello-world"
    image                 = "nginxdemos/hello:latest"
    ports                 = [80]
    environment_variables = null
    secrets               = null
  }

  codedeploy_config = {
    codedeploy_test_listener_port    = 8443
    codedeploy_service_role_arn      = module.acs.powerbuilder_role.arn
    codedeploy_termination_wait_time = 0
  }

  deployment_config_filename = "${path.module}/deployment-config.json"

  hosted_zone                   = module.acs.route53_zone
  https_certificate_arn         = module.acs.certificate.arn
  public_subnet_ids             = module.acs.public_subnet_ids
  private_subnet_ids            = module.acs.private_subnet_ids
  vpc_id                        = module.acs.vpc.id
  role_permissions_boundary_arn = module.acs.role_permissions_boundary.arn
}

output "host" {
  value = module.example.dns_record.fqdn
}
