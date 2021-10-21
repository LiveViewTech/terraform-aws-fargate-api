module "my_app" {
  source = "bitbucket.org/liveviewtech/terraform-aws-fargate.git?ref=v0.1.0"
  app_name       = "example-api"
  container_port = 8000
  primary_container_definition = {
    name  = "example"
    image = "crccheck/hello-world"
    ports = [8000]
    environment_variables = null
    secrets = null
    efs_volume_mounts = null
  }

  autoscaling_config            = null
  codedeploy_config             = null

  hosted_zone                   = module.acs.route53_zone
  https_certificate_arn         = module.acs.certificate.arn
  public_subnet_ids             = module.acs.public_subnet_ids
  private_subnet_ids            = module.acs.private_subnet_ids
  vpc_id                        = module.acs.vpc.id
  role_permissions_boundary_arn = module.acs.role_permissions_boundary_arn

  tags = {
    env              = "dev"
    data-sensitivity = "internal"
    repo             = "https://bitbucket.org/liveviewtech/terraform-aws-fargate"
  }
}