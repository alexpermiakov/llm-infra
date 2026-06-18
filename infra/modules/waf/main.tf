# AWS WAF for Application Load Balancer protection
# Implements OWASP Top 10 protection, rate limiting, and geographic restrictions
# https://docs.aws.amazon.com/waf/latest/developerguide/aws-managed-rule-groups-list.html

data "aws_region" "current" {}

locals {
  resource_suffix = var.pr_number > 0 ? "${var.environment}-pr-${var.pr_number}" : var.environment
}

resource "aws_wafv2_web_acl" "main" {
  name  = "idp-waf-${local.resource_suffix}-${var.region}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Rule 1: AWS Managed Rules - Core Rule Set (OWASP Top 10)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # Exclude rules that might cause false positives in dev/staging
        dynamic "rule_action_override" {
          for_each = var.environment != "prod" ? ["SizeRestrictions_BODY"] : []
          content {
            name = rule_action_override.value
            action_to_use {
              count {}
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS Managed Rules - Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: AWS Managed Rules - SQL Injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: Rate Limiting (per IP)
  rule {
    name     = "RateLimitPerIP"
    priority = 4

    action {
      block {
        custom_response {
          response_code            = 429
          custom_response_body_key = "rate_limit_response"
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = var.environment == "prod" ? 2000 : 5000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIPMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 5: AWS Managed Rules - Anonymous IP List (blocks VPNs, proxies, Tor)
  # Only enforce in production to avoid blocking developers
  dynamic "rule" {
    for_each = var.environment == "prod" ? [1] : []
    content {
      name     = "AWSManagedRulesAnonymousIpList"
      priority = 5

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesAnonymousIpList"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "AWSManagedRulesAnonymousIpListMetric"
        sampled_requests_enabled   = true
      }
    }
  }

  # Rule 6: AWS Managed Rules - Amazon IP Reputation List
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 6

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationListMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule 7: AWS Managed Rules - Bot Control (PCI-DSS 6.6)
  # Protects against automated attacks, credential stuffing, and web scraping
  # rule {
  #   name     = "AWSManagedRulesBotControlRuleSet"
  #   priority = 7

  #   override_action {
  #     none {}
  #   }

  #   statement {
  #     managed_rule_group_statement {
  #       vendor_name = "AWS"
  #       name        = "AWSManagedRulesBotControlRuleSet"

  #       managed_rule_group_configs {
  #         aws_managed_rules_bot_control_rule_set {
  #           # COMMON: Basic bot protection (scrapers, crawlers)
  #           # TARGETED: Advanced protection (credential stuffing, account takeover)
  #           inspection_level = var.environment == "prod" ? "TARGETED" : "COMMON"
  #         }
  #       }

  #       # Allow verified bots (Googlebot, Bingbot) in all environments
  #       rule_action_override {
  #         name = "CategoryVerifiedSearchEngine"
  #         action_to_use {
  #           allow {}
  #         }
  #       }

  #       # Allow social media bots for link previews
  #       rule_action_override {
  #         name = "CategorySocialMedia"
  #         action_to_use {
  #           allow {}
  #         }
  #       }
  #     }
  #   }

  #   visibility_config {
  #     cloudwatch_metrics_enabled = true
  #     metric_name                = "AWSManagedRulesBotControlRuleSetMetric"
  #     sampled_requests_enabled   = true
  #   }
  # }

  custom_response_body {
    key = "rate_limit_response"
    content = jsonencode({
      error   = "Rate limit exceeded"
      message = "Too many requests. Please try again later."
    })
    content_type = "APPLICATION_JSON"
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "idp-waf-${var.environment}-${var.region}"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "idp-waf-${var.environment}"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "ALB protection and compliance"
  }
}

resource "aws_cloudwatch_metric_alarm" "waf_blocked_requests" {
  alarm_name          = "waf-blocked-requests-${local.resource_suffix}-${var.region}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "BlockedRequests"
  namespace           = "AWS/WAFV2"
  period              = 300
  statistic           = "Sum"
  threshold           = var.environment == "prod" ? 1000 : 5000
  alarm_description   = "Alert when WAF blocks more than threshold requests"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.main.name
    Region = var.region
    Rule   = "ALL"
  }

  tags = {
    Name        = "WAF Blocked Requests Alarm"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_metric_alarm" "waf_rate_limit_triggered" {
  alarm_name          = "waf-rate-limit-triggered-${local.resource_suffix}-${var.region}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RateLimitPerIPMetric"
  namespace           = "AWS/WAFV2"
  period              = 60
  statistic           = "Sum"
  threshold           = 100
  alarm_description   = "Alert when rate limiting is frequently triggered"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = aws_wafv2_web_acl.main.name
    Region = var.region
    Rule   = "RateLimitPerIP"
  }

  tags = {
    Name        = "WAF Rate Limit Alarm"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Exposes WAF ACL ARN to ArgoCD via External Secrets
# Used by standard-service Helm chart to attach WAF to ALB Ingress annotations
# See: helm-charts/standard-service/templates/ingress.yaml
resource "aws_ssm_parameter" "waf_acl_arn" {
  name        = "/idp/${local.resource_suffix}/waf/acl-arn"
  description = "WAF Web ACL ARN for ALB ingress attachment"
  type        = "String"
  value       = aws_wafv2_web_acl.main.arn

  tags = {
    Name        = "WAF ACL ARN"
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "Dynamic ingress WAF association"
  }
}
