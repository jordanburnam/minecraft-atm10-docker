# All the Mods 10 Docker Server

Status: RUNBOOK - ACTIVE

## Current State

- Host: `jordan-mac-mini` / `192.168.4.100`
- Repository: `/home/jordan/minecraft-atm10-docker`
- Compose service: `minecraft`
- Container: `atm10-server`
- Restart policy: `unless-stopped`
- Persistent data: `/home/jordan/minecraft-atm10-docker/data`
- Port mapping: host `25565/tcp` -> container `25565/tcp`
- Installed ATM10 version: `All the Mods 10-8.1`
- Minecraft version: `1.21.1`
- NeoForge version: `21.1.249`
- Java image: `eclipse-temurin:21.0.8_9-jre`
- Java runtime verified: Temurin `21.0.8+9-LTS`

## Server Settings

- Seed: `7827573050215200323`
- Difficulty: `hard`
- Online mode: `true`
- Whitelist enabled: `true`
- Enforce whitelist: `true`
- Operators: `jordanburnam`, `The_Hidden_Jedi`
- Whitelist: `jordanburnam`, `The_Hidden_Jedi`

## JVM Settings

Effective JVM args are stored in `data/user_jvm_args.txt`.

- Initial heap: `-Xms2G`
- Maximum heap: `-Xmx8G`
- `-XX:+AlwaysPreTouch` removed to avoid committing the full heap at startup.

## Access Control

Minecraft whitelist is enabled and contains the intended operators.

The host's `DOCKER-USER` firewall chain allows TCP `25565` from the LAN subnet
`192.168.4.0/24` and public source `216.81.126.3`, then drops other IPv4 sources.
Minecraft's player whitelist remains enabled as defense in depth.

## Modpack Updates

`MODPACK_VERSION=latest` makes the container query CurseForge on every start. The
entrypoint compares the latest server-pack file ID with
`data/.atm10-server-pack.json`; it installs changed pack files only when the IDs
differ. World data, player access files, server properties, and JVM arguments are
preserved. Pack-managed directories are replaced so removed mods do not remain.

Restart the service to check for and install the latest release:

```bash
docker compose restart minecraft
```

## Operations

Run commands from `/home/jordan/minecraft-atm10-docker`.

Start:

```bash
docker compose up -d
```

Stop:

```bash
docker compose stop
```

Restart:

```bash
docker compose restart minecraft
```

Status:

```bash
docker compose ps
docker inspect atm10-server --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}}'
```

Logs:

```bash
docker compose logs -f --tail=120 minecraft
```

Backup:

```bash
docker compose stop minecraft
tar -C /home/jordan/minecraft-atm10-docker -czf atm10-backup-$(date +%Y%m%d-%H%M%S).tar.gz data
docker compose up -d
```

Restore:

```bash
docker compose stop minecraft
mv data data.restore-backup-$(date +%Y%m%d-%H%M%S)
tar -C /home/jordan/minecraft-atm10-docker -xzf /path/to/atm10-backup.tar.gz
docker compose up -d
```

## Verification Snapshot

- Docker container reached the Minecraft ready message: `Done (...)! For help, type "help"`
- Docker health status: `healthy`
- Automatic update check found 8.1 current on a second restart and skipped downloading it again.
- Java version inside container: Temurin `21.0.8+9-LTS`
- Host port `25565/tcp` listening on IPv4 and IPv6.
- LAN TCP connection to `192.168.4.100:25565` succeeded from `192.168.4.51`.
- `server.properties` contains the selected seed, hard difficulty, online mode, and whitelist settings.
- `ops.json` contains `jordanburnam` and `The_Hidden_Jedi`.
- `whitelist.json` contains `jordanburnam` and `The_Hidden_Jedi`.
- Persistent world files exist under `data/world`.
- Existing unrelated Docker containers remained running; `gluetun-expressvpn` and `jellyfin` reported healthy.

## Secrets

The CurseForge API key is stored only in `.env`, which is gitignored and has mode `600`. Do not print or commit it.
