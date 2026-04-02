# Integration Challenges & Resolutions

## Integration Challenge A: Strict Filesystem vs. Application Configuration

**The Conflict:**
The `systemd` directive `ProtectSystem=strict` makes the entire OS hierarchy (`/usr`, `/boot`, `/etc`) read-only to the service. However, the application needs to read environment configuration files on startup.

**Options Considered:**

1. Place configs in `/etc/kijanikiosk` and add a `ReadWritePaths=/etc/kijanikiosk` exemption.
2. Store configs within the application directory (`/opt/kijanikiosk/config/`).

**Resolution & Rationale:**
I chose **Option 2**. Because `/opt` is intentionally excluded from the read-only restrictions of `ProtectSystem=strict`, placing the stub `.env` files in `/opt/kijanikiosk/config/` required zero additional systemd exemptions. This keeps the security profile tighter 🔒 and reduces configuration complexity.

---

## Integration Challenge B: Health Check Data Visibility

**The Conflict:**
The `kk-logs` service generates the `last-provision.json` health file, meaning it owns the file. However, monitoring tools and admin users (like `amina`) need to read this file without invoking `sudo` or breaking the principle of least privilege.

**Options Considered:**

1. Make the file world-readable (`0644`).
2. Use a shared group and strict permissions.

**Resolution & Rationale:**
I chose **Option 2**. The `/opt/kijanikiosk/health/` directory is owned by `kk-logs:kijanikiosk` with `750` permissions. `kk-logs` writes the JSON, while anyone in the `kijanikiosk` group (which includes admin accounts) can safely read it. This maintains proper access control while keeping things secure ✅.

---

## Integration Challenge C: Logrotate vs. PrivateTmp Sandboxing

**The Conflict:**
When `logrotate` archives a log file, the running Node.js process keeps writing to the old file descriptor. The standard fix is to signal the process to reopen logs. However, we are using `PrivateTmp=true` for security.

**Options Considered:**

1. Use `copytruncate` in logrotate (which can lose data).
2. Use `systemctl kill -s HUP <service>` in the `postrotate` block.

**Resolution & Rationale:**
I chose **Option 2**. `ExecReload=/bin/kill -HUP $MAINPID` was added to all units. `PrivateTmp=true` does not interfere with this because the application log files are explicitly routed to `/opt/kijanikiosk/logs/`, safely outside the isolated `/tmp` namespace. This avoids data loss and preserves isolation 🧩.

---

## Integration Challenge D: Internal Port Security vs. UFW Evaluation Order

**The Conflict:**
The `kk-payments` service runs on port `3001`, which must be strictly internal (loopback and monitoring subnet only). However, `ufw` evaluates rules top-down — first-match wins.

**Options Considered:**

1. Rely solely on application-level binding (e.g., binding Node to `127.0.0.1`).
2. Enforce at the firewall level with strict rule ordering.

**Resolution & Rationale:**
I chose **Option 2** for defense-in-depth 🛡️. The script specifically provisions:

* `ALLOW in on lo`
* `ALLOW from 10.0.1.0/24`

for port `3001` **before** applying the blanket `DENY 3001/tcp` rule.
If the deny rule was placed first, the service would be totally unreachable, even internally.
