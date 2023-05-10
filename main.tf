terraform {
  required_version = "~>1"
  required_providers {
    aws = ">= 3"
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name        = var.name_prefix != null ? "${var.name_prefix}-${var.name}" : var.name
  definitions = concat([var.primary_container_definition], var.extra_container_definitions)
  volumes = distinct(flatten([
    for def in local.definitions :
    try(def.efs_volume_mounts, null) != null ? def.efs_volume_mounts : []
  ]))
  ssm_parameters = distinct(flatten([
    for def in local.definitions :
    values(def.secrets != null ? def.secrets : {})
  ]))
  has_secrets            = length(local.ssm_parameters) > 0
  ssm_parameter_arn_base = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/"
  secrets_arns = [
    for param in local.ssm_parameters :
    "${local.ssm_parameter_arn_base}${replace(param, "/^//", "")}"
  ]

  lb_name                   = local.name
  app_domain_url            = var.site_domain != null ? var.site_domain : "${local.name}.${var.hosted_zone.name}"
  cloudwatch_log_group_name = var.name_prefix != null ? "/${var.name_prefix}/${var.name}" : "/${var.name}"
  service_name              = var.name

  excluded_container_params = ["ports", "environment_variables", "secrets"]
  container_definitions = [
    for def in local.definitions : merge({
      essential  = true
      privileged = false
      portMappings = [
        for port in def.ports :
        {
          containerPort = port
          hostPort      = port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = local.cloudwatch_log_group_name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = local.service_name
        }
      }
      environment = [
        for key in keys(def.environment_variables != null ? def.environment_variables : {}) :
        {
          name  = key
          value = lookup(def.environment_variables, key)
        }
      ]
      secrets = [
        for key in keys(def.secrets != null ? def.secrets : {}) :
        {
          name      = key
          valueFrom = "${local.ssm_parameter_arn_base}${replace(lookup(def.secrets, key), "/^//", "")}"
        }
      ]
      mountPoints = [
        for mount in(try(def.efs_volume_mounts, null) != null ? def.efs_volume_mounts : []) :
        {
          containerPath = mount.container_path
          sourceVolume  = mount.name
          readOnly      = false
        }
      ]
      # exclude values that we manage for the user (secrets, env vars, etc)
    }, { for k, v in def : k => v if !contains(local.excluded_container_params, k) })
  ]

  hooks = var.codedeploy_config != null && var.codedeploy_lifecycle_hooks != null ? setsubtract([
    for hook in keys(var.codedeploy_lifecycle_hooks) :
    zipmap([hook], [lookup(var.codedeploy_lifecycle_hooks, hook, null)])
    ], [
    {
      BeforeInstall = null
    },
    {
      AfterInstall = null
    },
    {
      AfterAllowTestTraffic = null
    },
    {
      BeforeAllowTraffic = null
    },
    {
      AfterAllowTraffic = null
    }
  ]) : null
  codedeploy_test_listener_port = var.codedeploy_config.codedeploy_test_listener_port
}

resource "aws_lb" "this" {
  name            = local.lb_name
  subnets         = var.public_subnet_ids
  security_groups = [aws_security_group.lb.id]
  internal        = var.internal

  tags = var.tags
}

resource "aws_security_group" "lb" {
  name   = "${local.name}-lb"
  vpc_id = var.vpc_id

  dynamic "ingress" {
    // allow access to the LB from anywhere for 80 and 443
    for_each = toset(var.whitelisted_cidr_blocks != null ? [80, 443] : [])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.whitelisted_cidr_blocks
    }
  }

  // allow any outgoing traffic
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${local.name}-lb"
  })
}

resource "random_string" "target_group" {
  length  = 8
  lower   = true
  numeric = true
  upper   = false
  special = false
}

resource "aws_lb_target_group" "blue" {
  name = "lvt-${random_string.target_group.result}-blue"

  port     = var.container_port
  protocol = var.target_group_protocol
  vpc_id   = var.vpc_id

  load_balancing_algorithm_type = "least_outstanding_requests"
  target_type                   = "ip"
  deregistration_delay          = var.target_group_deregistration_delay
  stickiness {
    type    = "lb_cookie"
    enabled = var.sticky_sessions
  }
  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = var.health_check_matcher
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
  }

  tags = merge(var.tags, {
    Name = "${local.name}-blue"
    Type = "blue"
  })

  depends_on = [aws_lb.this]
}

resource "aws_lb_target_group" "green" {
  name = "lvt-${random_string.target_group.result}-green"

  port     = var.container_port
  protocol = var.target_group_protocol
  vpc_id   = var.vpc_id

  load_balancing_algorithm_type = "least_outstanding_requests"
  target_type                   = "ip"
  deregistration_delay          = var.target_group_deregistration_delay
  stickiness {
    type    = "lb_cookie"
    enabled = var.sticky_sessions
  }
  health_check {
    path                = var.health_check_path
    matcher             = var.health_check_matcher
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
  }

  tags = merge(var.tags, {
    Name = "${local.name}-green"
    Type = "green"
  })

  depends_on = [aws_lb.this]
}

resource "aws_lb_target_group" "this" {
  name = "lvt-${random_string.target_group.result}"

  port     = var.container_port
  protocol = var.target_group_protocol
  vpc_id   = var.vpc_id

  load_balancing_algorithm_type = "least_outstanding_requests"
  target_type                   = "ip"
  deregistration_delay          = var.target_group_deregistration_delay
  stickiness {
    type    = "lb_cookie"
    enabled = var.sticky_sessions
  }
  health_check {
    path                = var.health_check_path
    matcher             = var.health_check_matcher
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
  }

  tags = merge(var.tags, {
    Name = local.name
    Type = "default"
  })

  depends_on = [aws_lb.this]
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.https_certificate_arn

  ssl_policy = "ELBSecurityPolicy-FS-1-2-2019-08"

  dynamic "default_action" {
    for_each = var.https_listener_rules != [] ? ["this"] : []
    content {
      type = "fixed-response"

      fixed_response {
        content_type = "text/plain"
        message_body = "Forbidden"
        status_code  = "403"
      }
    }
  }
  dynamic "default_action" {
    for_each = var.https_listener_rules == [] ? ["this"] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.blue.arn
    }
  }
  lifecycle {
    ignore_changes = [default_action[0].target_group_arn]
    replace_triggered_by = [
      aws_lb_target_group.this.arn,
      aws_lb_target_group.blue.arn,
      aws_lb_target_group.green.arn,
    ]
  }
  depends_on = [
    aws_lb_target_group.this,
    aws_lb_target_group.blue,
    aws_lb_target_group.green,
  ]
}

resource "aws_lb_listener_rule" "this" {
  count        = length(var.https_listener_rules) > 0 ? length(var.https_listener_rules) : 0
  listener_arn = aws_lb_listener.https.arn
  priority     = lookup(var.https_listener_rules[count.index], "priority", null)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  lifecycle {
    ignore_changes = [action[0].target_group_arn]
  }

  # Path Pattern condition
  dynamic "condition" {
    for_each = [
      for condition_rule in var.https_listener_rules[count.index].conditions :
      condition_rule
      if length(lookup(condition_rule, "path_patterns", [])) > 0
    ]
    content {
      path_pattern {
        values = condition.value["path_patterns"]
      }
    }
  }

  # Host header condition
  dynamic "condition" {
    for_each = [
      for condition_rule in var.https_listener_rules[count.index].conditions :
      condition_rule
      if length(lookup(condition_rule, "host_headers", [])) > 0
    ]

    content {
      host_header {
        values = condition.value["host_headers"]
      }
    }
  }

  # Http header condition
  dynamic "condition" {
    for_each = [
      for condition_rule in var.https_listener_rules[count.index].conditions :
      condition_rule
      if length(lookup(condition_rule, "http_headers", [])) > 0
    ]

    content {
      dynamic "http_header" {
        for_each = condition.value["http_headers"]

        content {
          http_header_name = http_header.value["http_header_name"]
          values           = http_header.value["values"]
        }
      }
    }
  }

  # Http request method condition
  dynamic "condition" {
    for_each = [
      for condition_rule in var.https_listener_rules[count.index].conditions :
      condition_rule
      if length(lookup(condition_rule, "http_request_methods", [])) > 0
    ]

    content {
      http_request_method {
        values = condition.value["http_request_methods"]
      }
    }
  }

  # Query string condition
  dynamic "condition" {
    for_each = [
      for condition_rule in var.https_listener_rules[count.index].conditions :
      condition_rule
      if length(lookup(condition_rule, "query_strings", [])) > 0
    ]

    content {
      dynamic "query_string" {
        for_each = condition.value["query_strings"]

        content {
          key   = lookup(query_string.value, "key", null)
          value = query_string.value["value"]
        }
      }
    }
  }

  # Source IP address condition
  dynamic "condition" {
    for_each = [
      for condition_rule in var.https_listener_rules[count.index].conditions :
      condition_rule
      if length(lookup(condition_rule, "source_ips", [])) > 0
    ]

    content {
      source_ip {
        values = condition.value["source_ips"]
      }
    }
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      status_code = "HTTP_301"
      port        = aws_lb_listener.https.port
      protocol    = aws_lb_listener.https.protocol
    }
  }
}

resource "aws_lb_listener" "test_listener" {
  load_balancer_arn = aws_lb.this.arn
  port              = local.codedeploy_test_listener_port
  protocol          = "HTTPS"
  certificate_arn   = var.https_certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }
  lifecycle {
    ignore_changes = [default_action[0].target_group_arn]
    replace_triggered_by = [
      aws_lb_target_group.this.arn,
      aws_lb_target_group.blue.arn,
      aws_lb_target_group.green.arn,
    ]
  }
  depends_on = [
    aws_lb_target_group.this,
    aws_lb_target_group.blue,
    aws_lb_target_group.green,
  ]
}

resource "aws_route53_record" "a_record" {
  name    = local.app_domain_url
  type    = "A"
  zone_id = var.hosted_zone.id
  alias {
    evaluate_target_health = true
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
  }
}

resource "aws_route53_record" "aaaa_record" {
  name    = local.app_domain_url
  type    = "AAAA"
  zone_id = var.hosted_zone.id
  alias {
    evaluate_target_health = true
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
  }
}

data "aws_iam_policy_document" "task_execution_policy" {
  version = "2012-10-17"
  statement {
    effect = "Allow"
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      identifiers = ["ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_iam_role" "task_execution_role" {
  name                 = "${local.name}_task-execution-role"
  assume_role_policy   = data.aws_iam_policy_document.task_execution_policy.json
  permissions_boundary = var.role_permissions_boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_policy_attach" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
  role       = aws_iam_role.task_execution_role.name
}

// Make sure the fargate task has access to get the parameters from the container secrets
data "aws_iam_policy_document" "secrets_access" {
  count   = local.has_secrets ? 1 : 0
  version = "2012-10-17"
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameters",
      "ssm:GetParameter",
      "ssm:GetParemetersByPath"
    ]
    resources = local.secrets_arns
  }
}

resource "aws_iam_policy" "secrets_access" {
  count  = local.has_secrets ? 1 : 0
  name   = "${local.name}_secrets-access"
  policy = data.aws_iam_policy_document.secrets_access[0].json
}

resource "aws_iam_role_policy_attachment" "secrets_policy_attach" {
  count      = local.has_secrets ? 1 : 0
  policy_arn = aws_iam_policy.secrets_access[0].arn
  role       = aws_iam_role.task_execution_role.name
}

data "aws_iam_policy_document" "task_policy" {
  version = "2012-10-17"
  statement {
    effect = "Allow"
    principals {
      identifiers = ["ecs-tasks.amazonaws.com"]
      type        = "Service"
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "task_role" {
  name                 = "${local.name}_task-role"
  assume_role_policy   = data.aws_iam_policy_document.task_policy.json
  permissions_boundary = var.role_permissions_boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "task_policy_attach" {
  count      = length(var.task_policies)
  policy_arn = element(var.task_policies, count.index)
  role       = aws_iam_role.task_role.name
}

resource "aws_iam_role_policy_attachment" "secret_task_policy_attach" {
  count      = local.has_secrets ? 1 : 0
  policy_arn = aws_iam_policy.secrets_access[0].arn
  role       = aws_iam_role.task_role.name
}

resource "aws_ecs_task_definition" "this" {
  container_definitions    = jsonencode(local.container_definitions)
  family                   = local.name
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.task_execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.arm ? "ARM64" : "X86_64"
  }

  dynamic "volume" {
    for_each = local.volumes
    content {
      name = volume.value.name
      efs_volume_configuration {
        file_system_id = volume.value.file_system_id
        root_directory = volume.value.root_directory
      }
    }
  }

  tags = var.tags
}

resource "aws_security_group" "service" {
  name   = local.name
  vpc_id = var.vpc_id

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = local.name
  })
}

resource "aws_ecs_service" "this" {
  name             = local.service_name
  task_definition  = aws_ecs_task_definition.this.arn
  cluster          = var.ecs_cluster_name
  desired_count    = var.autoscaling_config != null ? var.autoscaling_config.min_capacity : 1
  launch_type      = "FARGATE"
  platform_version = var.fargate_platform_version

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = concat([aws_security_group.service.id], var.security_groups)
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.primary_container_definition.name
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = var.health_check_grace_period

  tags = var.tags

  lifecycle {
    ignore_changes = [
      task_definition,       // ignore because new revisions will get added after code deploy's blue-green deployment
      load_balancer,         // ignore because load balancer can change after code deploy's blue-green deployment
      network_configuration, // ignore because network configuration is changed by codedeploy
      desired_count,         // ignore because we're assuming you have autoscaling to manage the container count
    ]
    replace_triggered_by = [
      aws_lb.this.arn,
      aws_security_group.service.arn,
      aws_lb_target_group.this.arn,
      aws_lb_target_group.blue.arn,
      aws_lb_target_group.green.arn,
    ]
  }

  depends_on = [
    aws_lb_listener.http_redirect,
    aws_lb_listener.https,
    aws_lb_listener.test_listener,
  ]
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.cloudwatch_log_group_name
  retention_in_days = var.log_retention_in_days
  tags              = var.tags
}

resource "aws_appautoscaling_target" "default" {
  count              = var.autoscaling_config != null ? 1 : 0
  min_capacity       = var.autoscaling_config.min_capacity
  max_capacity       = var.autoscaling_config.max_capacity
  resource_id        = "service/${var.ecs_cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "up" {
  count              = var.autoscaling_config != null ? 1 : 0
  name               = "${local.name}_autoscale-up"
  resource_id        = aws_appautoscaling_target.default[0].resource_id
  scalable_dimension = aws_appautoscaling_target.default[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.default[0].service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    metric_aggregation_type = "Average"
    cooldown                = 300

    step_adjustment {
      scaling_adjustment          = 1
      metric_interval_lower_bound = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "up" {
  count      = var.autoscaling_config != null ? 1 : 0
  alarm_name = "${local.name}_alarm-up"
  namespace  = "AWS/ECS"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = aws_ecs_service.this.name
  }
  statistic           = "Average"
  metric_name         = "CPUUtilization"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 75
  period              = 300
  evaluation_periods  = 5
  alarm_actions       = [aws_appautoscaling_policy.up[0].arn]
  tags                = var.tags
}

resource "aws_appautoscaling_policy" "down" {
  count              = var.autoscaling_config != null ? 1 : 0
  name               = "${local.name}_autoscale-down"
  resource_id        = aws_appautoscaling_target.default[0].resource_id
  scalable_dimension = aws_appautoscaling_target.default[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.default[0].service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    metric_aggregation_type = "Average"
    cooldown                = 300

    step_adjustment {
      scaling_adjustment          = -1
      metric_interval_upper_bound = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "down" {
  count      = var.autoscaling_config != null ? 1 : 0
  alarm_name = "${local.name}_alarm-down"
  namespace  = "AWS/ECS"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = aws_ecs_service.this.name
  }
  statistic           = "Average"
  metric_name         = "CPUUtilization"
  comparison_operator = "LessThanThreshold"
  threshold           = 25
  period              = 300
  evaluation_periods  = 5
  alarm_actions       = [aws_appautoscaling_policy.down[0].arn]
  tags                = var.tags
}

resource "aws_codedeploy_app" "this" {
  name             = local.name
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = local.name
  service_role_arn       = var.codedeploy_config.codedeploy_service_role_arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  ecs_service {
    cluster_name = var.ecs_cluster_name
    service_name = aws_ecs_service.this.name
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.codedeploy_config.codedeploy_termination_wait_time
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.https.arn]
      }
      test_traffic_route {
        listener_arns = local.codedeploy_test_listener_port != null ? [aws_lb_listener.test_listener.arn] : []
      }
      target_group {
        name = aws_lb_target_group.blue.name
      }
      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }
}

locals {
  appspec = {
    version = 1
    Resources = [{
      TargetService = {
        Type = "AWS::ECS::SERVICE"
        Properties = {
          TaskDefinition = aws_ecs_task_definition.this.arn
          LoadBalancerInfo = {
            ContainerName = var.primary_container_definition.name
            ContainerPort = var.container_port
          }
          PlatformVersion = var.fargate_platform_version
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = var.private_subnet_ids
              SecurityGroups = concat([aws_security_group.service.id], var.security_groups)
              AssignPublicIp = var.assign_public_ip ? "ENABLED" : "DISABLED"
            }
          }
        }
      }
    }],
    Hooks = local.hooks
  }
  deployment_config = {
    applicationName     = aws_codedeploy_app.this.name
    deploymentGroupName = aws_codedeploy_deployment_group.this.deployment_group_name
    revision = {
      revisionType = "AppSpecContent"
      appSpecContent = {
        content = jsonencode(local.appspec)
      }
    }
  }
}

resource "local_file" "appspec_json" {
  count    = var.appspec_filename == null ? 0 : 1
  filename = var.appspec_filename
  content  = jsonencode(local.appspec)
}

resource "local_file" "deployment_config" {
  count    = var.deployment_config_filename == null ? 0 : 1
  filename = var.deployment_config_filename
  content  = jsonencode(local.deployment_config)
}
