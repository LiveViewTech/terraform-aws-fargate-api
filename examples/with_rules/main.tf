terraform {
  required_version = ">=1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = "default"
}

module "acs" {
  source  = "bitbucket.org/liveviewtech/terraform-aws-acs-info.git?ref=v2"
  profile = "default"
}

resource "aws_ecs_cluster" "example" {
  name = "hello-world"
}

module "example" {
  # source = "bitbucket.org/liveviewtech/terraform-aws-fargate-api.git?ref=v0.2.0"
  source = "../../" # for local testing

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

  # This will set two different rules both forwarding to the active target group (green/blue)
  https_listener_rules = [
    {
      conditions = [
        {
          path_patterns = ["/test/1234/*", "/test2/5678/*"]
        },
        {
          http_headers = [{
            http_header_name = "X-Forwarded-For"
            values           = ["192.168.1.*"]
          }]
        },
        {
          http_request_methods = [
            "GET", "PUT"
          ]
        },

      ]
    },
    {
      conditions = [
        {
          path_patterns = ["/test/*", "/test2/*"]
        },
        {
          query_strings = [
            {
              key   = "test",
              value = "this-is-the-value"
            }
          ]
        },
        {
          source_ips = [
            "192.168.1.1", "192.168.2.1"
          ]
        }
      ]
    },
  ]

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
