# Firewalld Zone Sync from DNS Hosts

## Overview

`fw-zone-sync` is a Bash script designed to automatically synchronize **Firewalld zone sources** with the **current IPs of DNS hostnames**.

This is ideal for environments with **dynamic IP addresses (DDNS)**, where you need to allow access to services from a changing set of hosts.

Key features:

* Supports **single-zone CLI mode** and **multi-zone config file** mode.
* **Dry-run** mode for auditing changes without applying them.
* Fully **JSON-structured logging**, including **added and removed IPs per zone**.
* Works with **IPv4 and IPv6**.
* Supports **systemd timer** for periodic updates.
* Logs are rotated automatically via **logrotate**.

---

## Table of Contents

1. [Installation](#installation)
2. [Configuration](#configuration)
3. [Usage](#usage)
4. [Systemd Integration](#systemd-integration)
5. [Dry-Run Mode](#dry-run-mode)
6. [JSON Logging](#json-logging)
7. [Log Rotation](#log-rotation)
8. [Example Config](#example-config)
9. [License](#license)

---

## Installation

1. Copy the script to `/usr/local/bin`:
```
wget -O /usr/local/bin/fw-zone-sync.sh \
https://github.com/ninpucho/fw-zone-source-sync-from-urls/blob/main/fw-zone-sync.sh
```

2. Create a directory for multi-zone config:

```bash
sudo mkdir -p /etc/fw-zone-sync
```

3. Create your zone configuration file (INI-style):

```bash
sudo nano /etc/fw-zone-sync/zones.ini
```

---

## Configuration

The config file supports **multiple zones**, each with a list of hostnames:

```ini
[public]
host1.example.com
host2.example.com

[dmz]
service1.example.com
service2.example.com
```

* Section names are the **Firewalld zones**.
* Lines under each section are **hostnames** to resolve via DNS.
* Supports both **IPv4 and IPv6** addresses.

---

## Usage

### Single-zone CLI mode:

```bash
sudo /usr/local/bin/fw-zone-sync.sh public host1.example.com host2.example.com
```

### Multi-zone config file:

```bash
sudo /usr/local/bin/fw-zone-sync.sh -f /etc/fw-zone-sync/zones.ini
```

### Dry-run mode (audit changes without applying):

```bash
sudo /usr/local/bin/fw-zone-sync.sh --dry-run -f /etc/fw-zone-sync/zones.ini
```

---

## Systemd Integration

### Service Install

```
wget -O /etc/systemd/system/fw-zone-sync.service \
https://github.com/ninpucho/fw-zone-source-sync-from-urls/blob/main/fw-zone-sync.service
```

### Timer Install

```
wget -O /etc/systemd/system/fw-zone-sync.timer \
https://github.com/ninpucho/fw-zone-source-sync-from-urls/blob/main/fw-zone-sync.timer
```

Enable and start the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fw-zone-sync.timer
```

Check timer status:

```bash
systemctl list-timers fw-zone-sync.timer
```

---

## Dry-Run Mode

* Use `--dry-run` to **simulate changes** without modifying Firewalld.
* JSON logs will include **added and removed IPs** that *would* be applied.
* Example:

```bash
sudo /usr/local/bin/fw-zone-sync.sh --dry-run public host1.example.com
```

---

## JSON Logging

Logs are written to:

```text
/var/log/fw-zone-sync.jsonl
```

Each entry is **newline-delimited JSON**, including:

* `timestamp` – UTC timestamp
* `level` – `INFO`, `WARN`, or `ERROR`
* `zone` – Firewalld zone
* `message` – Description of event
* `added_ips` / `removed_ips` – Arrays of IPs added or removed

Example:

```json
{
  "timestamp": "2025-10-05T23:15:01Z",
  "level": "INFO",
  "zone": "public",
  "message": "Added IPs to zone",
  "added_ips": [
    "192.0.2.1/32",
    "198.51.100.5/32"
  ]
}
```

Pretty-print logs:

```bash
jq . /var/log/fw-zone-sync.jsonl | less
```

Filter for errors:

```bash
jq 'select(.level=="ERROR")' /var/log/fw-zone-sync.jsonl
```

---

## Log Rotation

A `logrotate` config ensures logs don’t grow indefinitely:

File: `/etc/logrotate.d/fw-zone-sync-json`

Install
```
wget -O /etc/systemd/system/fw-zone-sync-json \
https://github.com/ninpucho/fw-zone-source-sync-from-urls/blob/main/fw-zone-sync-json
```

```conf
/var/log/fw-zone-sync.jsonl {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 root root
    copytruncate
}
```

* Rotates daily
* Keeps **7 days** of compressed logs
* `copytruncate` ensures the script continues logging to the same file

---

## Example Config File

```ini
[public]
host1.example.com
host2.example.com

[dmz]
service1.example.com
service2.example.com
```

---

## License

MIT License — free to use and modify.

---

This README fully documents your **multi-zone, JSON-logging, dry-run Firewalld sync script** with **systemd + logrotate integration**.

---

I can also create a **diagram showing how DNS, Firewalld, systemd, and logging interact**, which is helpful for documentation or handoff.

Do you want me to make that diagram?
