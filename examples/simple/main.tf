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
}

module "acs" {
  source  = "bitbucket.org/liveviewtech/terraform-aws-acs-info.git?ref=v1"
}

module "app" {
  source = "bitbucket.org/liveviewtech/terraform-aws-fargate-api.git?ref=v0.1.0"

  app_name       = local.project.id
  container_port = 8080

  primary_container_definition = {
    name  = "os-update-service"
    image = "nginx:latest"
    ports = [8080]
    environment_variables = {
      S3_BUCKET = aws_s3_bucket.main.bucket
    }
    secrets = {
      IMAGE_UUID = aws_ssm_parameter.image_uuid.name
    }
    efs_volume_mounts = null
  }

  autoscaling_config = null

  appspec_filename = "${path.module}/../appspec.json"
  codedeploy_config = {
    codedeploy_test_listener_port    = 8080
    codedeploy_service_role_arn      = module.acs.powerbuilder_role.arn
    codedeploy_termination_wait_time = 0
    codedeploy_lifecycle_hooks = {
      BeforeInstall         = null
      AfterInstall          = null
      AfterAllowTestTraffic = null
      BeforeAllowTraffic    = null
      AfterAllowTraffic     = null
    }
  }

  health_check_matcher = "200,202,301,302"

  task_policies   = []
  security_groups = [module.acs.odo_security_group.id]

  task_cpu = 1024
  task_memory = 2048

  alb_internal_flag             = true
  hosted_zone                   = module.acs.route53_zone
  https_certificate_arn         = module.acs.certificate.arn
  public_subnet_ids             = module.acs.private_subnet_ids
  private_subnet_ids            = module.acs.private_subnet_ids
  vpc_id                        = module.acs.vpc.id
  role_permissions_boundary_arn = module.acs.role_permissions_boundary.arn
}
