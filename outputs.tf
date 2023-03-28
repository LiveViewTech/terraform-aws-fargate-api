output "service_security_group" {
  value = aws_security_group.service
}

output "task_definition" {
  value = aws_ecs_task_definition.this
}

output "codedeploy_deployment_group" {
  value = var.codedeploy_config != null ? aws_codedeploy_deployment_group.this : null
}

output "appspec" {
  value = local.appspec
}

output "deployment_config" {
  value = local.deployment_config
}

output "lb" {
  value = aws_lb.this
}

output "lb_target_group" {
  value = aws_lb_target_group.this
}

output "lb_security_group" {
  value = aws_security_group.lb
}

output "lb_https_listener" {
  value = aws_lb_listener.https.arn
}

output "dns_record" {
  value = aws_route53_record.a_record
}

output "cloudwatch_log_group" {
  value = aws_cloudwatch_log_group.this
}

output "autoscaling_step_up_policy" {
  value = var.autoscaling_config != null ? aws_appautoscaling_policy.up : null
}

output "autoscaling_step_down_policy" {
  value = var.autoscaling_config != null ? aws_appautoscaling_policy.down : null
}

output "task_role" {
  value = aws_iam_role.task_role
}

output "task_execution_role" {
  value = aws_iam_role.task_execution_role
}

output "target_group_id" {
  value = random_string.target_group.result
}
