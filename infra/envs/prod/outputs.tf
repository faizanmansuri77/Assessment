output "alb_dns_name" {
  value = module.ecs.alb_dns_name
}

output "db_endpoint" {
  value     = module.rds.db_instance_endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.network.vpc_id
}
