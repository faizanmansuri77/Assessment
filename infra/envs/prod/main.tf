locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

module "network" {
  source = "../../modules/network"

  project              = var.project
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  container_port       = 80
  db_port              = 5432
  tags                 = local.tags
}

module "rds" {
  source = "../../modules/rds"

  project                = var.project
  environment            = var.environment
  vpc_id                 = module.network.vpc_id
  private_subnet_ids     = module.network.private_subnet_ids
  rds_security_group_id  = module.network.rds_security_group_id

  engine                  = "postgres"
  engine_version           = "16.4"
  instance_class           = "db.r6g.large"
  allocated_storage        = 100
  db_username              = var.db_username
  db_password              = var.db_password

  # --- prod sizing: bigger instance, long retention, protected ---
  backup_retention_period = 30
  deletion_protection      = true
  multi_az                 = true
  skip_final_snapshot      = false

  tags = local.tags
}

module "ecs" {
  source = "../../modules/ecs"

  project                = var.project
  environment            = var.environment
  vpc_id                 = module.network.vpc_id
  public_subnet_ids      = module.network.public_subnet_ids
  private_subnet_ids     = module.network.private_subnet_ids
  alb_security_group_id  = module.network.alb_security_group_id
  ecs_security_group_id  = module.network.ecs_security_group_id

  container_image = var.container_image
  container_port  = 80
  task_cpu        = "1024"
  task_memory     = "2048"
  desired_count   = 3

  tags = local.tags
}
