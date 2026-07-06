# DevOps Assessment: Terraform + Database Reliability

AWS infrastructure design in Terraform (VPC → ALB → ECS/Fargate → RDS), plus a
locally runnable PostgreSQL setup demonstrating schema design, seed data,
query optimization, and backup/restore.

Actual AWS deployment is not required or expected. Terraform is
validated with `fmt` / `init` / `validate` / `plan`. The database tasks run
entirely locally via Docker Compose.

## Repository structure

```
.
├── infra/
│   ├── modules/
│   │   ├── network/   # VPC, subnets, NAT, routing, security groups
│   │   ├── ecs/        # ALB, ECS cluster, Fargate task + service, IAM
│   │   └── rds/         # RDS instance, subnet group
│   └── envs/
│       ├── dev/         # smaller / cheaper, deletion protection off
│       └── prod/        # larger, multi-AZ, deletion protection on
├── .github/workflows/terraform.yml   # fmt/init/validate/plan on PRs (optional Part 3)
├── db/
│   ├── migrations/       # 001-003: schema + the optimization index
│   └── seed/seed.sql     # 300 seeded bookings + events
├── scripts/
│   ├── backup.sh
│   └── restore.sh
├── docker-compose.yml
└── backups/              # created by backup.sh, gitignored
```

## Prerequisites

- Docker + Docker Compose
- `psql` client (optional, only needed if you want to run ad-hoc queries
  from your host instead of through `docker exec`)
- Terraform >= 1.5 (only needed if you want to run `fmt`/`init`/`validate`/`plan`
  yourself instead of relying on the GitHub Actions workflow)

---

## Part 1 & 2: Terraform infrastructure + environments

The topology is `Internet → ALB → ECS/Fargate → RDS`, built from three
reusable modules under `infra/modules/`, and instantiated per-environment
under `infra/envs/`:

- **`modules/network`** — VPC, 2 public + 2 private subnets across 2 AZs,
  Internet Gateway, single NAT Gateway (private subnets route outbound
  through it), and three security groups that only trust the tier in
  front of them:
  `alb-sg` (0.0.0.0/0 → 80/443) → `ecs-sg` (only from alb-sg) → `rds-sg`
  (only from ecs-sg). RDS is never reachable from the internet or directly
  from the ALB.
- **`modules/ecs`** — Application Load Balancer + target group + listener,
  an ECS cluster, a Fargate task definition (placeholder `nginx` image,
  swap `container_image` for a real service image), the service itself
  (deployed into the private subnets, no public IP), the ECS task
  execution/task IAM roles, and a CloudWatch log group.
- **`modules/rds`** — a single RDS instance (Postgres by default, MySQL
  supported via `db_engine`) in a private DB subnet group, encrypted
  storage, and a master password that AWS generates and rotates in
  Secrets Manager (`manage_master_user_password = true`) rather than a
  plaintext Terraform variable.

`infra/envs/dev` and `infra/envs/prod` each have their own
`terraform.tfvars`, `backend.tf` (separate S3 key + DynamoDB lock table per
env), and variable sizing:

| | dev | prod |
|---|---|---|
| DB instance class | `db.t3.micro` | `db.t3.medium` |
| DB backup retention | 1 day | 30 days |
| DB deletion protection | `false` | `true` |
| DB Multi-AZ | `false` | `true` |
| Fargate task size | 256 CPU / 512 MB | 512 CPU / 1024 MB |
| Desired task count | 1 | 2 |

### Validating the Terraform

The S3 bucket / DynamoDB table in `backend.tf` are placeholders (they don't
need to exist to review the code) — use `-backend=false` to validate/plan
against local state only, exactly like the CI workflow does:

```bash
cd infra/envs/dev      # or infra/envs/prod
terraform fmt -check -recursive ../../..
terraform init -backend=false
terraform validate
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
AWS_SKIP_CREDENTIALS_VALIDATION=true AWS_SKIP_REQUESTING_ACCOUNT_ID=true AWS_SKIP_METADATA_API_CHECK=true \
terraform plan -refresh=false
```

The dummy `AWS_*` values and `SKIP_*` flags let the AWS provider initialize
and produce a full plan without any real AWS credentials — no account is
required to review this code.

## Part 3: GitHub Actions Terraform workflow (optional — implemented)

`.github/workflows/terraform.yml` runs on every PR that touches `infra/**`:

1. `terraform fmt -check -recursive`
2. For each environment (`dev`, `prod`), in parallel: `terraform init -backend=false`, `terraform validate`, `terraform plan -refresh=false`
3. The plan output is both **posted as a PR comment** (collapsed in a
   `<details>` block) and **uploaded as a workflow artifact**, so it's
   visible either way.

It uses the same dummy-credential / skip-validation approach described
above, so it runs on any fork with no secrets configured.

---

## Part 4 & 5: Local database, schema, seed data, and query optimization

### Quick start

```bash
docker compose up -d
docker compose ps        # wait for hotel_db to be "healthy"
```

On first startup, Postgres automatically runs everything in
`db/migrations/` and `db/seed/seed.sql` (mounted into
`docker-entrypoint-initdb.d`, which executes `*.sql` files in order):
creates `hotel_bookings` and `booking_events`, adds the optimization index,
and seeds 300 bookings across 6 cities / 5 orgs / 5 statuses, with
booking_events for ~60% of them.

> Note: `docker-entrypoint-initdb.d` only runs on a **fresh** volume. If
> you've already started the stack once and want to re-seed from scratch:
> `docker compose down -v && docker compose up -d`.

Verify the data loaded:

```bash
docker exec hotel_db psql -U hotel_app -d hotel_bookings_db -c "SELECT COUNT(*) FROM hotel_bookings;"
docker exec hotel_db psql -U hotel_app -d hotel_bookings_db -c "SELECT COUNT(*) FROM booking_events;"
docker exec hotel_db psql -U hotel_app -d hotel_bookings_db -c "SELECT city, COUNT(*) FROM hotel_bookings GROUP BY city;"
```

### Schema

`hotel_bookings` and `booking_events` follow the schema given in the
assessment exactly, with two additions: `gen_random_uuid()` as the default
for `id` (via the `pgcrypto` extension), and a foreign key from
`booking_events.booking_id` to `hotel_bookings.id`.

### Query optimization (Part 5)

Target query:

```sql
SELECT org_id, status, COUNT(*), SUM(amount)
FROM hotel_bookings
WHERE city = 'delhi'
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY org_id, status;
```

Without an index this is a full sequential scan of `hotel_bookings`.
`db/migrations/003_indexes.sql` adds:

```sql
CREATE INDEX idx_hotel_bookings_city_created_at
    ON hotel_bookings (city, created_at)
    INCLUDE (org_id, status, amount);
```

**Why this shape:**
- **`city` first, `created_at` second** — `city` is an equality filter and
  `created_at` is a range filter. B-tree indexes work best when equality
  columns come before range columns: Postgres can jump straight to the
  `delhi` slice of the index, then binary-search within that slice for the
  last-30-days boundary, instead of scanning every `delhi` row regardless
  of date.
- **`INCLUDE (org_id, status, amount)`** — these columns aren't filtered or
  ordered on, so they don't belong in the index *key*, but they are exactly
  what the `SELECT`/`GROUP BY` needs. Adding them as included (non-key)
  columns means Postgres can potentially answer the whole query from the
  index alone (an **index-only scan**), skipping a heap fetch for every
  matching row — as long as the table has been `VACUUM`ed recently enough
  for the visibility map to be up to date.

To see the effect yourself:

```bash
docker exec hotel_db psql -U hotel_app -d hotel_bookings_db -c "
EXPLAIN ANALYZE
SELECT org_id, status, COUNT(*), SUM(amount)
FROM hotel_bookings
WHERE city = 'delhi' AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY org_id, status;"
```

With 300 seeded rows the planner may still choose a sequential scan (the
table is small enough that it's genuinely cheaper) — the index pays off as
the table grows into the thousands/millions of rows this schema is designed
for. You can force the comparison at this scale with
`SET enable_seqscan = off;` before running the same `EXPLAIN ANALYZE`, then
`SET enable_seqscan = on;` afterwards to restore normal planning.

---

## Part 6: Backup and restore

```bash
./scripts/backup.sh
# ==> Backup completed: backups/backup_20260706_120000.sql.gz

./scripts/restore.sh
# restores the most recent backup into a fresh `hotel_bookings_restore`
# database inside the same container, then verifies it
```

`backup.sh` runs `pg_dump` inside the `hotel_db` container and writes a
timestamped, gzip-compressed dump to `backups/`.

`restore.sh` takes an optional path to a specific backup file (defaults to
the most recent one in `backups/`), drops and recreates a **fresh**
database (`hotel_bookings_restore` by default — the live `hotel_bookings_db`
is never touched), loads the dump into it, and automatically checks that
`hotel_bookings` has rows after restore, failing loudly if not.

### How to verify a restore worked

The script's built-in check (row count > 0) catches a broken restore. To
verify more thoroughly by hand, compare the original and restored
databases directly:

```bash
# Row counts should match
docker exec hotel_db psql -U hotel_app -d hotel_bookings_db     -t -c "SELECT COUNT(*) FROM hotel_bookings;"
docker exec hotel_db psql -U hotel_app -d hotel_bookings_restore -t -c "SELECT COUNT(*) FROM hotel_bookings;"

# Spot-check a specific row is identical
docker exec hotel_db psql -U hotel_app -d hotel_bookings_db \
  -c "SELECT * FROM hotel_bookings ORDER BY created_at LIMIT 1;"
docker exec hotel_db psql -U hotel_app -d hotel_bookings_restore \
  -c "SELECT * FROM hotel_bookings ORDER BY created_at LIMIT 1;"

# The optimization index should exist in the restored DB too
docker exec hotel_db psql -U hotel_app -d hotel_bookings_restore \
  -c "\d hotel_bookings"
```

---

## Assumptions & design decisions

- **Postgres over MySQL** for the local database: the given schema uses
  `UUID` and `JSONB`, both native Postgres types, and the index uses
  Postgres's `INCLUDE` clause. Terraform's RDS module still supports either
  engine via `db_engine`, but the local Docker Compose/SQL scripts are
  Postgres-specific — adapting them to MySQL would mean `CHAR(36)` for IDs,
  a `JSON` column instead of `JSONB`, and dropping the `INCLUDE` clause in
  favor of a plain composite index.
- **RDS master password** is managed by AWS in Secrets Manager
  (`manage_master_user_password = true`) instead of a Terraform variable,
  so no credential is ever stored in state or `tfvars`.
- **Single NAT Gateway** shared across both private subnets, for cost —
  a stricter HA setup would use one NAT Gateway per AZ.
- **CI runs plan-only**, with dummy AWS credentials and `AWS_SKIP_*` env
  vars, so the workflow (and this whole review) needs no real AWS account.
- **Default region** is `us-east-1` and default AZs are `us-east-1a`/`b` —
  change `aws_region` and `azs` in each env's `tfvars` for other regions.
- **Container image** is a placeholder (`nginx`) per the assessment's
  instructions — swap `container_image` in `tfvars` for a real application
  image.
