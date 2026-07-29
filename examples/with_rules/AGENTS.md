## Context

Same baseline as `examples/basic`, plus `https_listener_rules` demonstrating path, header, method, query-string, and source-IP conditions. Unmatched HTTPS traffic is forbidden by the module default action.

## Tech

- Terraform `>=1.0.0`, AWS provider `>= 3`
- Provider region/profile: `us-west-2` / `default` (`examples/with_rules/main.tf`)
- External module: `bitbucket.org/liveviewtech/terraform-aws-acs-info.git?ref=v2` (note: basic example pins `ref=v1`)
- Listener rules configured on `module.example` via `https_listener_rules`

## Architecture

Cluster + ACS → root module with rule list → HTTPS listener default 403 when rules present → `aws_lb_listener_rule.this` forwards matches to the blue target group (`../../main.tf`). CodeDeploy may later retarget rule actions; Terraform ignores those ARN drift fields.

## Patterns

- DO: model each rule as `{ conditions = [ ... ] }` maps; priority defaults by index unless set (`examples/with_rules/main.tf`, `../../main.tf` `aws_lb_listener_rule.this`).
- DO: combine condition types in one rule (path + header + method, or path + query + source IP) as in this example.
- DON'T: edit live `https_listener_rules` while the active listener target group is not blue — can drop traffic (`README.md`).
- DON'T: expect Terraform to “fix” listener/rule target groups back to blue after CodeDeploy shifts traffic (`ignore_changes` on those ARNs in `../../main.tf`).

## Key Files

- `examples/with_rules/main.tf` — rules example
- `examples/basic/main.tf` — simpler baseline without rules
- `../../main.tf` — listener default 403 vs forward, and rule condition blocks
- `../../README.md` — https_listener_rules warning and condition docs
