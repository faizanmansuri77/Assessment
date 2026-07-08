locals {
  name_prefix = "${var.project}-${var.environment}"
  port        = var.engine == "postgres" ? 5432 : 3306
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db-subnet-group"
  })
}

resource "aws_db_instance" "this" {
  identifier     = "${local.name_prefix}-db"
  engine         = var.engine == "postgres" ? "postgres" : "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  storage_type           = "gp3"
  storage_encrypted      = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = local.port

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_security_group_id]

  # RDS is intentionally private: no public IP, only reachable from ECS via
  # the security group rule defined in the network module.
  publicly_accessible = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_period
  backup_window            = "03:00-04:00"
  maintenance_window        = "sun:04:30-sun:05:30"

  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name_prefix}-final-snapshot"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-db"
  })
}
