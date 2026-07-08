# Flight/Hotel Reservation - Terraform + Database Reliability

Solution for the **DevOps Assessment: Terraform + Database Reliability** brief.
No AWS deployment is required or performed - Terraform is validated locally
via `fmt` / `init` / `validate` / `plan`, and the database tasks run fully
locally via Docker Compose.

## Repository layout

```
infra/
  modules/
    network/   # VPC, public/private subnets, NAT, ALB/ECS/RDS security groups
    ecs/       # ALB, ECS cluster, Fargate task definition + service, IAM roles
    rds/       # RDS instance (Postgres), subnet group
  envs/
    dev/       # dev.tfvars: small instance, short backup retention, deletion_protection=false
    prod/      # prod.tfvars: larger instance, long backup retention, deletion_protection=true
migrations/
  001_create_tables.sql   # hotel_bookings, booking_events
  002_indexes.sql         # covering index for the target query
seed/
  003_seed_data.sql       # 150 bookings across 5 cities / 6 orgs / 5 statuses + events
scripts/
  backup.sh                # timestamped pg_dump backup
  restore.sh                # restore into a fresh database + verification
.github/workflows/
  terraform.yml            # fmt + init + validate + plan on PRs, posts plan as PR comment + artifact
docker-compose.yml
```

## Part 1 & 2 - Terraform infrastructure

Traffic flow: **Internet → ALB (public subnets) → ECS/Fargate (private subnets) → RDS (private subnets)**.

- `network` module builds a VPC with 2 public + 2 private subnets across 2
  AZs, an Internet Gateway, a NAT Gateway (so private-subnet tasks can still
  pull images / talk to AWS APIs), and three security groups chained by
  reference (not CIDR): ALB accepts 80/443 from the internet, ECS only
  accepts the container port *from the ALB's security group*, and RDS only
  accepts its DB port *from the ECS security group*. RDS therefore has no
  route to the internet and no security group rule that could ever expose
  it publicly - `publicly_accessible = false` reinforces this at the RDS level.
- `rds` module provisions a Postgres RDS instance in the private subnets,
  with backup retention, `deletion_protection`, and `multi_az` all exposed as
  variables so each environment can set them independently.
- `ecs` module provisions the ALB + target group + listener, an ECS cluster,
  a Fargate task definition (placeholder Nginx image by default, swappable
  via `container_image`), the service (in private subnets, `assign_public_ip
  = false`), and least-privilege IAM execution/task roles.
- `envs/dev` and `envs/prod` each call all three modules with their own
  `variables.tf`, `*.tfvars`, and `backend.tf` (separate S3 bucket/key/
  DynamoDB lock table per environment, so state can never cross environments):

  | Setting | dev | prod |
  |---|---|---|
  | RDS instance class | `db.t3.micro` | `db.r6g.large` |
  | Backup retention | 3 days | 30 days |
  | Deletion protection | `false` | `true` |
  | Multi-AZ | `false` | `true` |
  | Fargate task size | 256 CPU / 512 MB | 1024 CPU / 2048 MB |
  | Desired task count | 1 | 3 |

### Validating the Terraform locally

```bash
cd infra/envs/dev     # or infra/envs/prod
terraform fmt -check -recursive
terraform init -backend=false          # no AWS creds/backend needed to validate
terraform validate
terraform plan -var-file="dev.tfvars" -var="db_password=local-plan-only" -refresh=false
```

No real AWS credentials, S3 bucket, or DynamoDB table are needed for the
commands above - `init -backend=false` skips the remote backend entirely, and
`-refresh=false` means `plan` never needs to reach AWS to read real
resource state. This mirrors exactly what the CI workflow does (see Part 3).

## Part 3 - Terraform Plan in GitHub Actions (optional, implemented)

`.github/workflows/terraform.yml` runs on every PR that touches `infra/**`,
as a matrix over `dev` and `prod`. For each environment it runs `terraform
fmt -check`, `init -backend=false`, `validate`, and `plan -refresh=false`,
then:

- uploads the full plan as a **workflow artifact** (`tfplan-dev` / `tfplan-prod`), and
- posts the plan as a **PR comment** (collapsed in a `<details>` block, truncated if very large).

`db_password` is supplied via a `TF_DB_PASSWORD` repo secret if configured,
falling back to a placeholder value so the plan job never fails on a missing
secret - this is a plan-only job, nothing is ever applied.

## Part 4, 5 & 6 - Local database

### Setup

```bash
docker compose up -d
```

On first start, Postgres automatically runs (in order) `migrations/001_create_tables.sql`,
`migrations/002_indexes.sql`, and `seed/003_seed_data.sql` via the official
image's `docker-entrypoint-initdb.d` mechanism (each file is mounted
individually and numbered, since that mechanism only picks up files placed
directly in that directory, not subfolders).

Connection details: `localhost:5432`, db `flightreservation`, user
`app_user` / password `app_password` (local dev only - see `docker-compose.yml`).

### Schema

`hotel_bookings` and `booking_events` exactly as specified in the brief,
plus: `gen_random_uuid()` defaults for both PKs (via `pgcrypto`), a
`CHECK` constraint that `checkout_date > checkin_date`, an `ON DELETE
CASCADE` foreign key from `booking_events.booking_id`, and a supporting
index on that foreign key.

### Seed data

`seed/003_seed_data.sql` generates **150 hotel_bookings** rows spread across
**5 cities** (delhi, mumbai, bangalore, pune, chennai), **6 organizations**,
and **5 statuses** (confirmed, cancelled, pending, completed, refunded),
with `created_at` spread over the last 60 days so roughly half the rows fall
inside the "last 30 days" window the target query filters on. Booking events
(`created` → `payment_received` → optionally `cancelled`) are generated for
~40% of bookings.

*(Implementation note: the org assignment originally used a correlated-looking
subquery against a lookup table, `(SELECT org_id FROM tmp_orgs OFFSET
random()*6 LIMIT 1)`. That's a bug: Postgres evaluates an **uncorrelated**
scalar subquery in a target list once per statement, not once per row - even
with a volatile function like `random()` inside it - so every row silently
got the same org. Fixed by picking from a literal array with `(ARRAY[...])[floor(random()*N)+1]`,
the same pattern already used for `city` and `status`, which does evaluate `random()` per row.)*

### Query optimization

Target query:

```sql
SELECT org_id, status, COUNT(*), SUM(amount)
FROM hotel_bookings
WHERE city = 'delhi'
  AND created_at >= NOW() - INTERVAL '30 days'
GROUP BY org_id, status;
```

**Index added** (`migrations/002_indexes.sql`):

```sql
CREATE INDEX idx_hotel_bookings_city_created_at
    ON hotel_bookings (city, created_at)
    INCLUDE (org_id, status, amount);
```

Why this shape:

- `city` leads the index because it's an **equality** predicate - it lets
  Postgres seek directly to the matching rows instead of scanning everything.
- `created_at` is second because, once `city` is pinned to a single value, a
  btree can efficiently **range-scan** the last-30-days window within that city.
- `org_id`, `status`, and `amount` are in `INCLUDE` rather than as extra key
  columns: they're only ever *read* by this query (via `GROUP BY` /
  aggregates), never filtered on, so they don't need to participate in
  index ordering - but including them means Postgres can satisfy the whole
  query from the index alone (an **index-only scan**), without visiting the
  heap for every matching row at all.

**Verified with `EXPLAIN ANALYZE`** against the actual seeded data:

Before the index (sequential scan):

```
HashAggregate  (cost=6.15..6.28 rows=10 width=65) (actual time=0.045..0.049 rows=13 loops=1)
  Group Key: org_id, status
  ->  Seq Scan on hotel_bookings  (cost=0.00..6.00 rows=15 width=33) (actual time=0.007..0.027 rows=15 loops=1)
        Filter: (((city)::text = 'delhi'::text) AND (created_at >= (now() - '30 days'::interval)))
        Rows Removed by Filter: 135
Planning Time: 0.300 ms
Execution Time: 0.090 ms
```

After the index (index-only scan, `Heap Fetches: 0`):

```
HashAggregate  (cost=4.73..4.85 rows=10 width=65) (actual time=0.060..0.064 rows=13 loops=1)
  Group Key: org_id, status
  ->  Index Only Scan using idx_hotel_bookings_city_created_at on hotel_bookings  (cost=0.28..4.58 rows=15 width=33) (actual time=0.042..0.044 rows=15 loops=1)
        Index Cond: ((city = 'delhi'::text) AND (created_at >= (now() - '30 days'::interval)))
        Heap Fetches: 0
Planning Time: 0.184 ms
Execution Time: 0.116 ms
```

Note: at only 150 seed rows, the whole table fits on a single page, so
Postgres's planner correctly *prefers* a sequential scan by default (that's
the right call at this scale - an index lookup has fixed overhead a seq scan
of one page doesn't). The "after" plan above was captured with
`SET enable_seqscan = off` to prove the index-only scan plan itself is
correct and produces identical results (13 groups) with zero heap fetches.
At realistic production data volumes (thousands-millions of rows), the
planner will choose this index automatically without any override, and the
gap between `Seq Scan` and `Index Only Scan` becomes dramatic rather than
sub-millisecond.

### Backup and restore

```bash
./scripts/backup.sh
```

Creates a timestamped, compressed custom-format dump at
`backups/flightreservation_YYYYMMDD_HHMMSS.dump` (custom format is used
over plain SQL specifically because it's restorable with `pg_restore`,
including selective/parallel restore).

```bash
./scripts/restore.sh                                    # restores the most recent backup
./scripts/restore.sh backups/flightreservation_...dump   # or a specific file
```

`restore.sh` restores into a **fresh** database (`flightreservation_restore`
by default - dropped and recreated every run) rather than layering on top of
whatever's already there, so a restore is always proven against a genuinely
clean target. It then automatically verifies success by querying row counts
from `hotel_bookings` and `booking_events` in the restored database and
exits non-zero if `hotel_bookings` comes back empty.

**To verify manually:**

```bash
docker exec -it flightreservation-db psql -U app_user -d flightreservation_restore \
  -c "SELECT count(*) FROM hotel_bookings;" \
  -c "SELECT count(*) FROM booking_events;" \
  -c "SELECT org_id, status, COUNT(*), SUM(amount) FROM hotel_bookings WHERE city='delhi' AND created_at >= NOW() - INTERVAL '30 days' GROUP BY org_id, status;"
```

Row counts should match the source database (150 bookings / ~246 events),
and the target query should return the same result set as on the original database.

## Submission checklist

- [x] Terraform infrastructure code (`infra/modules/*`)
- [x] dev and prod Terraform environment examples (`infra/envs/dev`, `infra/envs/prod`)
- [x] Docker Compose database setup (`docker-compose.yml`)
- [x] SQL migration files (`migrations/*.sql`)
- [x] Seed data script (`seed/003_seed_data.sql`)
- [x] Database backup script (`scripts/backup.sh`)
- [x] Database restore script (`scripts/restore.sh`)
- [x] README.md with setup, verification, and index rationale (this file)
- [x] GitHub Actions Terraform PR workflow (optional Part 3, implemented)
