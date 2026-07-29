## Purpose

Reusable Terraform module that provisions a standardized AWS Fargate HTTP API behind an ALB with Route53 DNS, optional autoscaling, and CodeDeploy blue-green deployments.

## Project Snapshot

- Type: single Terraform module (not a monorepo app)
- Language: HCL
- Runtime: Terraform `~>1`, AWS provider `>= 3` (`main.tf`)
- Examples: `examples/basic/`, `examples/with_rules/`
- Tests: none in-repo

## Commands

No `package.json` / Makefile scripts. Consumer workflow from an example dir (needs AWS credentials and access to the ACS info module):

```bash
cd examples/basic
terraform init
terraform plan
terraform apply
```

Same sequence under `examples/with_rules/`. Module source for local testing is `source = "../../"` in those examples.

## Conventions

- Treat this module as opinionated scaffolding; heavy customization may mean forking the pattern rather than stretching inputs (`README.md`).
- After first apply, do not expect `terraform apply` to update ECS `task_definition`, `load_balancer`, `network_configuration`, or `desired_count` — `aws_ecs_service.this` ignores those (`main.tf`). Ship task changes via CodeDeploy.
- When `https_listener_rules` is non-empty, unmatched HTTPS traffic gets a fixed 403; only matching rules forward (`main.tf`, `examples/with_rules/main.tf`).
- **Warning:** Before changing `https_listener_rules` on a live stack, ensure the HTTPS listener still forwards to the blue target group — otherwise traffic can drop (`README.md` https_listener_rules note).
- Optional `appspec_filename` / `deployment_config_filename` write deploy JSON via `local_file` (`main.tf`); root `.gitignore` ignores `appspec.json` and `deployment-config.json`.
- Pass SSM parameter names/paths in container `secrets`; the module expands them to ARNs and attaches IAM (`main.tf` locals + `secrets_access`).
- Target groups are named `lvt-<random>-{blue,green}` / `lvt-<random>` (`main.tf`).

## Directory Map

- `./` — root module (`main.tf`, `variables.tf`, `outputs.tf`)
- `examples/basic/` → see `examples/basic/AGENTS.md`
- `examples/with_rules/` → see `examples/with_rules/AGENTS.md`

## Architecture

Inputs (VPC, subnets, hosted zone, ACM cert, container definition, CodeDeploy role) → ALB + blue/green target groups + listeners → ECS task definition/service (`CODE_DEPLOY`) → Route53 A/AAAA → optional App Auto Scaling + CloudWatch alarms → CodeDeploy app/group → optional local appspec/deployment-config files for pipelines.

## Gotchas

- `codedeploy_config` defaults to `null` in `variables.tf` and README suggests null means “bring your own,” but `main.tf` always creates CodeDeploy resources and dereferences `var.codedeploy_config` — omit it and plan fails.
- README says the module can create an ECS cluster; root module does not — callers must supply `ecs_cluster_name` (examples create `aws_ecs_cluster.example`).
- `replace_triggered_by` on the ECS service: recreating the ALB, service SG, or target groups forces service replacement (`main.tf`).
- README input/output names drift from `variables.tf` / `outputs.tf` (e.g. `internal` vs documented `alb_internal_flag`, `access_logs` vs `lb_logging_*`). Trust the `.tf` files.
