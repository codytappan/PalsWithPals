# PalsWithPals

Cost-optimized, **on-demand** [Palworld](https://palworld.gg/) dedicated server on AWS,
controlled from **Discord**. The EC2 instance only runs (and bills compute) while people
are playing; it automatically saves the world and shuts down when empty. The game world
lives on a **persistent EBS volume**, so restarts and instance-type upgrades never lose data.

The game server runs the
[`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker)
image.

> **Before launch:** check the upstream Palworld 1.0 known-issues tracker —
> https://github.com/thijsvanloef/palworld-server-docker/issues/834

## Architecture

```
Discord slash command
        │  POST /interactions
        ▼
API Gateway (HTTP v2) ─────► Lambda (Python 3.12)
                               • verifies Ed25519 signature (Discord public key)
                               • PING (type 1) -> PONG
                               • /palworld-start  -> ec2:StartInstances
                               • /palworld-stop   -> SSM save, then ec2:StopInstances
                               • /palworld-status -> ec2:DescribeInstances + cached count
        ┌──────────────────────────────────────────────────────────┐
        │  EC2 game VM (Ubuntu, m6i.xlarge default)                 │
        │   • Elastic IP (stable connect address)                   │
        │   • Docker + compose: palworld-server-docker:latest       │
        │   • REST API 8212 bound to localhost only                 │
        │   • persistent EBS data volume -> /palworld world save     │
        │   • cron idle-watcher (every 5 min):                      │
        │       rest-cli players -> cache (file + SSM Parameter)    │
        │       after N empty checks -> rest-cli save -> stop self  │
        └──────────────────────────────────────────────────────────┘
```

## Repository layout

| Path | Purpose |
|------|---------|
| `terraform/` | All AWS infrastructure (EC2, EBS, EIP, IAM, Lambda, API Gateway, alarms). |
| `lambda/` | Discord interactions handler + slash-command registration script. |
| `ec2/` | Cloud-init, compose file, idle-shutdown watcher, and resize helper. |

## Prerequisites

- An AWS account and [Terraform](https://developer.hashicorp.com/terraform) >= 1.5.
- AWS credentials configured locally (e.g. `aws configure`).
- A [Discord application](https://discord.com/developers/applications) (you'll need its
  **public key**, **application ID**, and a **bot token**).
- Python 3.12 to package the Lambda (PyNaCl must be bundled — see below).

## Deploy

### 1. Configure variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set ssh_ingress_cidr, discord_public_key,
# discord_application_id, server_password, admin_password
```

### 2. Package the Lambda dependencies

PyNaCl is not in the Lambda runtime, so install it into `lambda/` before applying:

```bash
pip install -r ../lambda/requirements.txt -t ../lambda
```

(Terraform zips the `lambda/` directory into the deployment package.)

### 3. Apply

```bash
terraform init
terraform apply
```

Note the outputs:

- `elastic_ip` — the address players connect to (UDP 8211).
- `instance_id` — the game server instance.
- `interactions_endpoint_url` — paste into Discord next.

### 4. Wire up Discord

1. In the Discord Developer Portal, open your app → **General Information** and set the
   **Interactions Endpoint URL** to the `interactions_endpoint_url` output. Discord sends a
   PING to validate it; the Lambda answers PONG.
2. Register the slash commands:

   ```bash
   cd lambda
   DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... python register_commands.py
   ```

3. Invite the app to your server and use `/palworld-start`, `/palworld-stop`, `/palworld-status`.

### 5. Connect in-game

In Palworld → **Join Multiplayer (Dedicated)** → connect to `ELASTIC_IP:8211` and enter the
server password.

## Cost summary

You are billed for **compute only while the instance is running** — the idle watcher stops it
after the world is empty. The always-on costs are small:

- **EBS volumes** (root + persistent data) — billed per GB-month whether running or stopped.
- **Elastic IPv4 address** — AWS now charges hourly for allocated public IPv4.
- **Lambda / API Gateway / SSM Parameter Store** — effectively free at this volume.

Because the instance spends most of its life stopped, compute is the smallest part of the bill.

## Operations

- **Start / stop / status:** use the Discord slash commands, or the AWS console/CLI.
- **Auto-shutdown:** the cron idle-watcher (`ec2/idle-shutdown.sh`) polls player count every
  5 minutes and, after `EMPTY_LIMIT` consecutive empty checks (default 6 = 30 min), runs
  `rest-cli save` then stops the instance. Tune `EMPTY_LIMIT` in `/opt/palworld/idle.env`.
- **Backups:** the container has `BACKUP_ENABLED=true` (nightly). Backups live under the
  persistent data volume at `/opt/palworld/data/palworld`. Restore by replacing the save files
  from a backup while the container is stopped, then `docker compose up -d`.
- **Manual save:** `docker exec palworld-server rest-cli save`.

The world is **always saved before the instance stops** — both in the idle watcher and in the
`/palworld-stop` command.

## Scaling / upgrade guide

The world save lives on a **persistent EBS data volume**, so upgrading is simply
**stop → change instance type → start** with **no data migration**. Use `ec2/resize.sh`:

```bash
./ec2/resize.sh <instance-id> r6i.xlarge us-east-1
```

Upgrade ladder:

| Tier | Instance | vCPU / RAM | When |
|------|----------|-----------|------|
| Start | m6i.xlarge | 4 / 16 GB | default small group |
| More RAM | r6i.xlarge | 4 / 32 GB | OOM / large world |
| More players | m6i.2xlarge | 8 / 32 GB | 10+ concurrent, tick lag |
| Heavy | m6i.4xlarge | 16 / 64 GB | large communities |

Before scaling hardware, try the container's performance tuning first —
`ENABLE_PERF_THREADING_ARGS` and `WORKER_THREADS_SERVER`. The CloudWatch alarms
(CPU > 85%, memory > 90%) signal when it's time to move up a tier.

Later cost optimizations: move to **spot instances** (pairing well with the container's nightly
`BACKUP_ENABLED` in case of interruption) and **Savings Plans** for steady baseline usage.

## Security notes

- The **REST API port (8212) is never exposed to the internet** — it's bound to localhost on
  the instance and omitted from the security group.
- SSH (22) is restricted to `ssh_ingress_cidr`; only 8211/udp and 27015/udp are public.
- Secrets are supplied via Terraform variables (marked `sensitive`) and an example tfvars file.
  **Never commit real secrets** — `terraform.tfvars` is gitignored.
