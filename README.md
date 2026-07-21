# PalsWithPals

Cost-optimized, **on-demand** [Palworld](https://palworld.gg/) dedicated server on AWS,
controlled from **Discord**. The EC2 instance only runs while people
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
                               • /palworld-status -> ec2:DescribeInstances + public IP + cached count
                               • /palworld-health -> status + players + persistent data usage
        ┌──────────────────────────────────────────────────────────┐
        │  EC2 game VM (Ubuntu, m6i.xlarge default)                 │
        │   • public IP auto-assigned on start                      │
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
| `terraform/` | All AWS infrastructure (EC2, EBS, IAM, Lambda, API Gateway, alarms). |
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
```

Open `terraform.tfvars` and fill in each value. The table below explains where to
find each one:

| Variable | Required | Where to get it |
|---|---|---|
| `aws_region` | No | AWS region to deploy into. Default: `us-east-1` |
| `instance_type` | No | EC2 instance type. Default: `m6i.xlarge` (4 vCPU / 16 GB RAM) |
| `data_volume_size_gb` | No | Persistent world-save volume size in GB. Default: `20` |
| `root_volume_size_gb` | No | OS root volume size in GB. Default: `30` |
| `player_count_param_name` | No | SSM parameter for cached online player count. Default: `/palworld/player_count` |
| `data_usage_param_name` | No | SSM parameter for cached persistent data usage %. Default: `/palworld/data_usage_percent` |
| `ssh_ingress_cidr` | **Yes** | Your public IP as a `/32`. Run: `curl -s https://checkip.amazonaws.com \| awk '{print $1"/32"}'` |
| `ssh_public_key` | No | Paste your local OpenSSH public key (e.g. `cat ~/.ssh/id_ed25519.pub`) to enable SSH key login |
| `discord_public_key` | **Yes** | Discord Developer Portal → your app → **General Information** → *Public Key* |
| `discord_application_id` | **Yes** | Discord Developer Portal → your app → **General Information** → *Application ID* |
| `discord_webhook_url` | No | Discord server → channel settings → **Integrations** → **Webhooks** → copy URL |
| `server_password` | **Yes** | Any password — players enter this to join the game |
| `admin_password` | **Yes** | Any password — used for RCON/admin commands in-game |
| `server_name` | No | Name shown in the community server browser. Default: `PalsWithPals` |
| `server_description` | No | Description shown in the community server browser |

> **SSH CIDR note:** if your home IP is dynamic and changes, just re-run the
> `curl` command, update `ssh_ingress_cidr`, and re-run `terraform apply`.
> Terraform will update the security group rule in seconds with no server restart.

> **SSH key note:** if `ssh_public_key` is left empty, SSH key login is disabled and you should use AWS Systems Manager Session Manager shell access instead.

> **Secrets safety:** `terraform.tfvars` is gitignored — never commit it.
> All sensitive variables are marked `sensitive` in Terraform and will not appear
> in plan/apply output.

### 2. Build the Lambda package directory

The Lambda runtime dependencies are built into a dedicated directory
`build/lambda-package` (outside `lambda/`) so your source folder stays clean.

```bash
cd ..
./lambda/build.sh
cd terraform
```

Terraform zips `build/lambda-package` into the deployment artifact.
Re-run `./lambda/build.sh` whenever `lambda/requirements.txt` or
`lambda/lambda_handler.py` changes.

### 3. Apply

```bash
terraform init
terraform apply
```

Note the outputs:

- `public_ip` — the server's public IP right after `terraform apply`. After later stop/start cycles, use `/palworld-status` for the current IP.
- `instance_id` — the game server instance.
- `interactions_endpoint_url` — paste into Discord next.

### 4. Wire up Discord

1. In the Discord Developer Portal, open your app → **General Information** and set the
   **Interactions Endpoint URL** to the `interactions_endpoint_url` output. Discord sends a
   PING to validate it; the Lambda answers PONG.
2. Register the slash commands:

   ```bash
   cd lambda
   DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... python3 register_commands.py
   ```

3. Invite the app to your server and use `/palworld-start`, `/palworld-stop`, `/palworld-status`, `/palworld-health`.

### 5. Connect in-game

Look up SengasPalsWithPals server in the community server browser, or direct-connect:

In Palworld → **Join Multiplayer (Dedicated)** → run `/palworld-status` in Discord, then
connect to the reported `PUBLIC_IP:8211` and enter the server password.

## Operations

- **Start / stop / status/health:** use the Discord slash commands, or the AWS console/CLI. `/palworld-status` includes the server's current public IP when it is running, and `/palworld-health` adds persistent data usage so you can judge when to resize storage.
- **Discord notifications:** when `discord_webhook_url` is set, Discord receives server lifecycle posts (start/stop/idle stop) and CloudWatch alarm transitions (ALARM/OK for CPU/memory alarms).
- **Auto-shutdown:** the cron idle-watcher (`ec2/idle-shutdown.sh`) polls player count every
  5 minutes and, after `EMPTY_LIMIT` consecutive empty checks (default 6 = 30 min), runs
  `rest-cli save` then stops the instance. Tune `EMPTY_LIMIT` in `/opt/palworld/idle.env`.
- **Backups:** the container has `BACKUP_ENABLED=true` (nightly). Backups live under the
  persistent data volume at `/opt/palworld/data/palworld`. Restore by replacing the save files
  from a backup while the container is stopped, then `docker compose up -d`.
- **Manual save:** `docker exec palworld-server rest-cli save`.

The world is **always saved before the instance stops** — both in the idle watcher and in the
`/palworld-stop` command.

## Updating game settings

All gameplay tuning lives in the `environment:` block of `ec2/compose.yaml`.
Changes are picked up by running `terraform apply` (which rebuilds the instance
user-data), then doing a one-time container restart on the server.

### Workflow

1. Edit `ec2/compose.yaml` — adjust any environment variable values.
2. Apply infrastructure changes:

   ```bash
   cd terraform
   terraform apply
   ```

   > `terraform apply` updates the EC2 **user-data**, but user-data only runs on
   > first boot. The *currently running* container still has the old config.

3. Restart the container on the live server to pick up the new values:

   ```bash
   # Use the IP reported by /palworld-status
   ssh -i ~/.ssh/<YOUR_PRIVATE_KEY_FILE> ubuntu@<PUBLIC_IP>
   cd /opt/palworld

   # Save the world first
   docker exec palworld-server rest-cli save

   # Pull the updated compose file from the repo (or edit in place)
   # then restart
   docker compose up -d --force-recreate
   ```

   The container will reload all `environment:` values from compose and `.env`
   on start-up. The world save is on the persistent EBS volume so nothing is lost.

### Family-friendly settings reference

The settings currently in `ec2/compose.yaml` are tuned for a relaxed, kid-friendly
experience. Adjust to taste:

| Variable | Default | Current | Effect |
|---|---|---------|---|
| `DEATH_PENALTY` | `All` | `None`  | Items/equipment kept on death |
| `FALL_DAMAGE_RATE` | `1.0` | `0.5`   | Fall damage multiplier |

For the full list of supported variables see the upstream docs:
https://palworld-server-docker.loef.dev/getting-started/configuration/game-settings

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
