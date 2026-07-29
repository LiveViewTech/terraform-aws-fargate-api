## Context

Minimal consumer example: external ECS cluster, ACS info module outputs, nginx hello-world image, CodeDeploy test listener on 8443. Uses `source = "../../"` for local module testing.

## Tech

- Terraform `>=1.0.0`, AWS provider `>= 3`
- Provider region/profile: `us-west-2` / `default` (`examples/basic/main.tf`)
- External module: `bitbucket.org/liveviewtech/terraform-aws-acs-info.git?ref=v1`
- Container image: `nginxdemos/hello:latest` on port 80

## Architecture

`aws_ecs_cluster.example` + `module.acs` → `module.example` (this repo’s root module) → DNS name via `module.example.dns_record.fqdn` output.

## Patterns

- DO: create/pass an ECS cluster name; the root module does not create one (`examples/basic/main.tf` `ecs_cluster_name`).
- DO: supply `codedeploy_config` with `codedeploy_service_role_arn` from ACS (`module.acs.powerbuilder_role.arn`).
- DO: set `deployment_config_filename` when you want the module to emit deploy JSON next to the example.
- DON'T: assume README Bitbucket `terraform-aws-fargate` source matches this checkout — local path is `../../`; published source is unsettled across docs.

## Key Files

- `examples/basic/main.tf` — full wiring
- `examples/basic/.gitignore` — local Terraform state/lock ignores
- `../../main.tf` — module implementation under test
- `../../variables.tf` — required inputs (`name`, `container_port`, VPC/DNS/IAM, etc.)
