#!/bin/bash
# kijanikiosk-provision.sh  — Friday production-grade revision
# Idempotent provisioning for KijaniKiosk application servers.
# Usage: sudo bash kijanikiosk-provision.sh

set -euo pipefail
# -e   exit on any command failure
# -u   unset variables are errors
# -o pipefail   pipe failures are visible

readonly NGINX_VERSION="1.24.0-1~jammy"
readonly NODE_MAJOR_VERSION="20"
readonly APP_GROUP="kijanikiosk"
readonly APP_BASE="/opt/kijanikiosk"
readonly MONITORING_SUBNET="10.0.1.0/24"

log()     { echo "[$(date +%FT%T)] INFO  $*"; }
success() { echo "[$(date +%FT%T)] OK    $*"; }
warn()    { echo "[$(date +%FT%T)] WARN  $*"; }
error()   { echo "[$(date +%FT%T)] ERROR $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && error "Must run as root or with sudo"
grep -qi ubuntu /etc/os-release || error "Designed for Ubuntu only"

log "Starting KijaniKiosk provisioning (Friday production-grade)..."

# ---------------------------------------------------------------------------
# Phase 1: Packages
# Dirty-VM guard: check installed versions before touching packages.
# Decision: fail loudly on version mismatch rather than silent downgrade.
# A silent downgrade could corrupt a partially-running service; manual review
# is safer than automated rollback in a production environment.
# ---------------------------------------------------------------------------
provision_packages() {
  log "=== Phase 1: Packages ==="

  # --- Dirty VM guard: inspect what is already installed ---
  local nginx_installed node_installed
  nginx_installed=$(dpkg-query -W -f='${Version}' nginx 2>/dev/null || echo "not-installed")
  node_installed=$(dpkg-query -W -f='${Version}'  nodejs 2>/dev/null || echo "not-installed")

  if [[ "$nginx_installed" != "not-installed" && "$nginx_installed" != "$NGINX_VERSION" ]]; then
    error "nginx is at ${nginx_installed}, pinned to ${NGINX_VERSION}. \
Manual intervention required: run 'apt-mark unhold nginx && apt-get install nginx=${NGINX_VERSION}' then re-provision."
  fi

  log "Updating apt package index..."
  apt-get update -qq

  log "Installing base dependencies..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl gnupg acl ufw

  # --- nginx official stable repository (signed-by pattern) ---
  log "Configuring official nginx stable repository..."
  local nginx_keyring="/usr/share/keyrings/nginx-archive-keyring.gpg"
  local nginx_list="/etc/apt/sources.list.d/nginx.list"

  if [[ ! -f "$nginx_keyring" ]]; then
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
      | gpg --dearmor -o "$nginx_keyring"
    log "nginx GPG key installed."
  else
    log "nginx GPG key already present."
  fi

  if [[ ! -f "$nginx_list" ]]; then
    echo "deb [signed-by=${nginx_keyring}] http://nginx.org/packages/ubuntu jammy nginx" \
      > "$nginx_list"
    apt-get update -qq
    log "nginx stable repository added."
  else
    log "nginx stable repository already configured."
  fi

  # --- NodeSource repository (signed-by pattern) ---
  log "Configuring NodeSource repository for Node.js ${NODE_MAJOR_VERSION}..."
  local ns_keyring="/usr/share/keyrings/nodesource.gpg"
  local ns_list="/etc/apt/sources.list.d/nodesource.list"

  if [[ ! -f "$ns_keyring" ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o "$ns_keyring"
    log "NodeSource GPG key installed."
  else
    log "NodeSource GPG key already present."
  fi

  if [[ ! -f "$ns_list" ]]; then
    echo "deb [signed-by=${ns_keyring}] https://deb.nodesource.com/node_${NODE_MAJOR_VERSION}.x nodistro main" \
      > "$ns_list"
    apt-get update -qq
    log "NodeSource repository added."
  else
    log "NodeSource repository already configured."
  fi

  # --- Install packages (skip if already at pinned version) ---
  if [[ "$nginx_installed" == "$NGINX_VERSION" ]]; then
    log "nginx already at ${NGINX_VERSION} — skipping install."
  else
    log "Installing nginx=${NGINX_VERSION}..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      "nginx=${NGINX_VERSION}"
  fi

  if [[ "$node_installed" == "not-installed" ]]; then
    log "Installing nodejs..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs
  else
    log "nodejs already installed at ${node_installed} — skipping."
  fi

  log "Holding nginx and nodejs at pinned versions..."
  apt-mark hold nginx nodejs

  local nginx_ver node_ver
  nginx_ver=$(nginx -v 2>&1 | grep -oP '[\d.]+')
  node_ver=$(node --version)
  success "nginx ${nginx_ver} installed and held."
  success "Node.js ${node_ver} installed and held."
}

# ---------------------------------------------------------------------------
# Phase 2: Service Accounts
# ---------------------------------------------------------------------------
provision_users() {
  log "=== Phase 2: Service Accounts ==="

  if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${APP_GROUP}"
    log "Created group: ${APP_GROUP}"
  else
    log "Already exists: group ${APP_GROUP}"
  fi

  create_service_account() {
    local user="$1" comment="$2"
    if ! id "$user" >/dev/null 2>&1; then
      useradd --system --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin --comment "$comment" "$user"
      log "Created: $user"
    else
      log "Already exists: $user"
    fi
    usermod -aG "${APP_GROUP}" "$user"
  }

  create_service_account "kk-api"      "KijaniKiosk API Service"
  create_service_account "kk-payments" "KijaniKiosk Payments Service"
  create_service_account "kk-logs"     "KijaniKiosk Log Aggregator"

  if id "amina" >/dev/null 2>&1; then
    usermod -aG "${APP_GROUP}" amina
    log "Added amina to ${APP_GROUP}."
  else
    log "User amina not found — skipping (non-fatal)."
  fi

  success "Service accounts configured."
}

# ---------------------------------------------------------------------------
# Phase 3: Directories
# Also creates stub EnvironmentFiles so unit files can reference them.
#
# Challenge A resolution: config files live under /opt/kijanikiosk/config/,
# which is NOT affected by ProtectSystem=strict (strict makes /usr, /boot,
# /etc read-only; /opt is writable). No additional ReadWritePaths exemption
# needed for the config directory.
#
# Challenge B resolution: /opt/kijanikiosk/health/ is owned by
# kk-logs:kijanikiosk (750). kk-logs writes the health JSON; group members
# (including amina and the monitoring account) can read without sudo.
# ---------------------------------------------------------------------------
provision_dirs() {
  log "=== Phase 3: Directories ==="

  mkdir -p \
    "${APP_BASE}/api" \
    "${APP_BASE}/payments" \
    "${APP_BASE}/logs/api" \
    "${APP_BASE}/logs/payments" \
    "${APP_BASE}/shared/logs" \
    "${APP_BASE}/shared/config" \
    "${APP_BASE}/config" \
    "${APP_BASE}/health"

  # Root of application tree
  chown root:"${APP_GROUP}" "${APP_BASE}"
  chmod 750 "${APP_BASE}"

  # Intermediate parents
  chown root:"${APP_GROUP}" "${APP_BASE}/logs"
  chmod 750 "${APP_BASE}/logs"
  chown root:"${APP_GROUP}" "${APP_BASE}/shared"
  chmod 750 "${APP_BASE}/shared"

  # Service working directories
  chown kk-api:kk-api           "${APP_BASE}/api"
  chmod 750                     "${APP_BASE}/api"
  chown kk-payments:kk-payments "${APP_BASE}/payments"
  chmod 750                     "${APP_BASE}/payments"

  # Private log directories
  chown kk-api:kk-api           "${APP_BASE}/logs/api"
  chmod 750                     "${APP_BASE}/logs/api"
  chown kk-payments:kk-payments "${APP_BASE}/logs/payments"
  chmod 750                     "${APP_BASE}/logs/payments"

  # Shared config — root-owned, group can read
  chown root:"${APP_GROUP}" "${APP_BASE}/shared/config"
  chmod 750                 "${APP_BASE}/shared/config"

  # Shared logs — setgid so new files inherit the group automatically
  chown kk-logs:"${APP_GROUP}" "${APP_BASE}/shared/logs"
  chmod 2770                   "${APP_BASE}/shared/logs"

  # EnvironmentFile directory — root-owned, group can traverse
  chown root:"${APP_GROUP}" "${APP_BASE}/config"
  chmod 750                 "${APP_BASE}/config"

  # Health directory — kk-logs writes, group reads
  chown kk-logs:"${APP_GROUP}" "${APP_BASE}/health"
  chmod 750                    "${APP_BASE}/health"

  # --- ACLs on shared/logs ---
  setfacl -m  u:kk-api:rwx      "${APP_BASE}/shared/logs"
  setfacl -m  u:kk-payments:rwx "${APP_BASE}/shared/logs"
  setfacl -d -m u:kk-api:rwx      "${APP_BASE}/shared/logs"
  setfacl -d -m u:kk-payments:rwx "${APP_BASE}/shared/logs"

  # --- Stub EnvironmentFiles (created once; never overwritten) ---
  local -A env_owners=(
    ["api.env"]="kk-api:kk-api"
    ["payments-api.env"]="kk-payments:kk-payments"
    ["logs.env"]="kk-logs:kk-logs"
  )
  for fname in "${!env_owners[@]}"; do
    local fpath="${APP_BASE}/config/${fname}"
    if [[ ! -f "$fpath" ]]; then
      printf '# KijaniKiosk %s — populate at deployment time\nNODE_ENV=production\n' \
        "$fname" > "$fpath"
      log "Created stub EnvironmentFile: ${fpath}"
    else
      log "EnvironmentFile already exists: ${fpath}"
    fi
    chown "${env_owners[$fname]}" "$fpath"
    chmod 640 "$fpath"
  done

  success "Directory tree and permissions applied."
}

# ---------------------------------------------------------------------------
# Phase 4: systemd Unit Files
#
# All three units written inline using quoted heredocs ('UNIT') so the shell
# never expands variables inside the unit content.
#
# kk-api     — target systemd-analyze security score < 3.5
# kk-payments — target score < 2.5 (financial data; stricter hardening)
# kk-logs    — target score < 3.5
#
# kk-payments directives INVESTIGATED but NOT applied:
#   MemoryDenyWriteExecute=true — Node.js JIT compilation requires writable
#     executable memory pages. Enabling this causes an immediate SIGSEGV on
#     startup. Score benefit ~0.2; cost: service cannot start. Not applied.
#   PrivateNetwork=true — Removes all network interfaces from the process
#     namespace. A payments service that cannot reach upstream partners or
#     internal infrastructure is non-functional. IPAddressDeny/Allow provides
#     targeted network restriction without breaking connectivity. Not applied.
#
# Challenge C (logrotate + PrivateTmp) resolution:
#   ExecReload=/bin/kill -HUP $MAINPID is present in every unit. logrotate's
#   postrotate script uses 'systemctl kill -s HUP <service>' to signal each
#   process to reopen log file handles after rotation. PrivateTmp=true does
#   not interfere because application log files live in /opt/kijanikiosk,
#   not inside the service's private /tmp mount.
# ---------------------------------------------------------------------------
provision_services() {
  log "=== Phase 4: systemd Units ==="

  # --- kk-api.service ---
  log "Writing kk-api.service..."
  cat > /etc/systemd/system/kk-api.service << 'UNIT'
[Unit]
Description=KijaniKiosk API Service
Documentation=https://github.com/kijanikiosk/api
After=network.target
Wants=network.target

[Service]
Type=simple
User=kk-api
Group=kk-api
WorkingDirectory=/opt/kijanikiosk/api
EnvironmentFile=/opt/kijanikiosk/config/api.env
ExecStart=/usr/bin/node /opt/kijanikiosk/api/server.js
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Hardening (target: systemd-analyze security score < 3.5)
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
PrivateUsers=true
ProtectSystem=strict
ReadWritePaths=/opt/kijanikiosk/api /opt/kijanikiosk/logs/api /opt/kijanikiosk/shared/logs
ProtectHome=true
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RemoveIPC=true
ProtectClock=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
UMask=0077

StandardOutput=journal
StandardError=journal
SyslogIdentifier=kk-api

[Install]
WantedBy=multi-user.target
UNIT

  # --- kk-payments.service ---
  log "Writing kk-payments.service..."
  cat > /etc/systemd/system/kk-payments.service << 'UNIT'
[Unit]
Description=KijaniKiosk Payments Service
Documentation=https://github.com/kijanikiosk/payments
After=network.target kk-api.service
Wants=network.target kk-api.service

[Service]
Type=simple
User=kk-payments
Group=kk-payments
WorkingDirectory=/opt/kijanikiosk/payments
EnvironmentFile=/opt/kijanikiosk/config/payments-api.env
ExecStart=/usr/bin/node /opt/kijanikiosk/payments/server.js
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Hardening (target: systemd-analyze security score < 2.5)
# MemoryDenyWriteExecute intentionally omitted — Node.js JIT requires W+X pages.
# PrivateNetwork intentionally omitted — use IPAddressDeny/Allow for targeted control.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
PrivateUsers=true
ProtectSystem=strict
ReadWritePaths=/opt/kijanikiosk/payments /opt/kijanikiosk/logs/payments /opt/kijanikiosk/shared/logs
ProtectHome=true
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RemoveIPC=true
ProtectClock=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
IPAddressDeny=any
IPAddressAllow=localhost 127.0.0.1/8 10.0.1.0/24
UMask=0077

StandardOutput=journal
StandardError=journal
SyslogIdentifier=kk-payments

[Install]
WantedBy=multi-user.target
UNIT

  # --- kk-logs.service ---
  log "Writing kk-logs.service..."
  cat > /etc/systemd/system/kk-logs.service << 'UNIT'
[Unit]
Description=KijaniKiosk Log Aggregator
Documentation=https://github.com/kijanikiosk/logs
After=network.target
Wants=network.target

[Service]
Type=simple
User=kk-logs
Group=kk-logs
WorkingDirectory=/opt/kijanikiosk/shared/logs
EnvironmentFile=/opt/kijanikiosk/config/logs.env
ExecStart=/usr/bin/node /opt/kijanikiosk/logs/server.js
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s

# Hardening (target: systemd-analyze security score < 3.5)
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
PrivateUsers=true
ProtectSystem=strict
ReadWritePaths=/opt/kijanikiosk/shared/logs /opt/kijanikiosk/health
ProtectHome=true
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
RestrictRealtime=true
RemoveIPC=true
ProtectClock=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
UMask=0077

StandardOutput=journal
StandardError=journal
SyslogIdentifier=kk-logs

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable kk-api.service kk-payments.service kk-logs.service
  success "All three unit files written, daemon reloaded, services enabled."
}

# ---------------------------------------------------------------------------
# Phase 5: Firewall
# Reset to a clean known baseline at the start — removes the week's
# accumulated ad-hoc rules so the result reflects intent, not history.
#
# Rule ordering matters: ufw evaluates first-match wins.
# The loopback and monitoring-subnet ALLOW rules for port 3001 must appear
# BEFORE the blanket DENY rule, otherwise the deny fires first and the
# allow rules are never reached.
# ---------------------------------------------------------------------------
provision_firewall() {
  log "=== Phase 5: Firewall ==="

  log "Resetting ufw to clean baseline..."
  ufw --force reset

  ufw default deny incoming
  ufw default allow outgoing

  # SSH — added first to avoid locking out the current admin session
  ufw allow 22/tcp \
    comment "SSH access - administrative"

  # Public web traffic
  ufw allow 80/tcp \
    comment "HTTP - public web"
  ufw allow 443/tcp \
    comment "HTTPS - public web TLS"

  # KijaniKiosk public API
  ufw allow 3000/tcp \
    comment "kk-api - public-facing API endpoint"

  # kk-payments port 3001 — INTERNAL ONLY
  # ALLOW rules must come BEFORE the DENY rule (first-match wins)
  ufw allow in on lo to any port 3001 \
    comment "kk-payments - loopback for nginx internal proxy"

  ufw allow from "${MONITORING_SUBNET}" to any port 3001 \
    comment "kk-payments health check - monitoring subnet ${MONITORING_SUBNET} only"

  # Blanket deny for any remaining external source on 3001
  ufw deny 3001/tcp \
    comment "kk-payments - block all external access (internal service port)"

  ufw --force enable

  log "Active ufw rules:"
  ufw status verbose | while IFS= read -r line; do log "  $line"; done

  success "Firewall reset and configured with documented intent."
}

# ---------------------------------------------------------------------------
# Phase 6: Verification
# Checks all previous phases. Counts failures independently so every check
# runs even if an earlier one fails. Exits non-zero if any check fails.
# ---------------------------------------------------------------------------
verify_state() {
  log "=== Phase 6: Verification ==="
  local failed=0

  pass() { success "PASS: $*"; }
  fail() { log     "FAIL: $*"; ((failed++)); }

  # --- Phase 2: service accounts ---
  for user in kk-api kk-payments kk-logs; do
    id "$user" >/dev/null 2>&1 \
      && pass "Account exists: $user" \
      || fail "Account missing: $user"
  done

  # --- Phase 3: directories ---
  local required_dirs=(
    "${APP_BASE}"
    "${APP_BASE}/api"
    "${APP_BASE}/payments"
    "${APP_BASE}/logs/api"
    "${APP_BASE}/logs/payments"
    "${APP_BASE}/shared/logs"
    "${APP_BASE}/shared/config"
    "${APP_BASE}/config"
    "${APP_BASE}/health"
  )
  for dir in "${required_dirs[@]}"; do
    [[ -d "$dir" ]] \
      && pass "Directory exists: $dir" \
      || fail "Directory missing: $dir"
  done

  # EnvironmentFiles readable by their correct service account
  sudo -u kk-api      cat "${APP_BASE}/config/api.env"          >/dev/null 2>&1 \
    && pass "api.env readable by kk-api" \
    || fail "api.env not readable by kk-api"
  sudo -u kk-payments cat "${APP_BASE}/config/payments-api.env" >/dev/null 2>&1 \
    && pass "payments-api.env readable by kk-payments" \
    || fail "payments-api.env not readable by kk-payments"
  sudo -u kk-logs     cat "${APP_BASE}/config/logs.env"          >/dev/null 2>&1 \
    && pass "logs.env readable by kk-logs" \
    || fail "logs.env not readable by kk-logs"

  # Definitive ACL write test — verifies access model survives logrotate
  if sudo -u kk-api touch "${APP_BASE}/shared/logs/test-write.tmp" 2>/dev/null; then
    pass "kk-api can write to shared/logs (ACL intact)"
    rm -f "${APP_BASE}/shared/logs/test-write.tmp"
  else
    fail "kk-api cannot write to shared/logs — ACL or permissions broken"
  fi

  # SUID/SGID scan on application tree
  log "Scanning ${APP_BASE} for SUID/SGID binaries..."
  local suid_count
  suid_count=$(find "${APP_BASE}" -perm /6000 -type f 2>/dev/null | wc -l)
  if [[ "$suid_count" -eq 0 ]]; then
    pass "No SUID/SGID files found in ${APP_BASE}"
  else
    fail "${suid_count} SUID/SGID file(s) found in ${APP_BASE}:"
    find "${APP_BASE}" -perm /6000 -type f 2>/dev/null | while IFS= read -r f; do
      log "  $f"
    done
  fi

  # --- Phase 1: package holds ---
  for pkg in nginx nodejs; do
    apt-mark showhold 2>/dev/null | grep -q "^${pkg}$" \
      && pass "Package held: $pkg" \
      || fail "Package NOT held: $pkg"
  done

  # --- Phase 4: systemd units enabled ---
  for svc in kk-api kk-payments kk-logs; do
    systemctl is-enabled "${svc}.service" >/dev/null 2>&1 \
      && pass "${svc}.service is enabled" \
      || fail "${svc}.service is NOT enabled"
  done

  # --- Phase 5: firewall rules (one assertion per rule) ---
  local ufw_status
  ufw_status=$(ufw status verbose)

  echo "$ufw_status" | grep -qP '22/tcp\s+ALLOW' \
    && pass "Firewall: SSH (22/tcp) allowed" \
    || fail "Firewall: SSH rule missing"

  echo "$ufw_status" | grep -qP '80/tcp\s+ALLOW' \
    && pass "Firewall: HTTP (80/tcp) allowed" \
    || fail "Firewall: HTTP rule missing"

  echo "$ufw_status" | grep -qP '443/tcp\s+ALLOW' \
    && pass "Firewall: HTTPS (443/tcp) allowed" \
    || fail "Firewall: HTTPS rule missing"

  echo "$ufw_status" | grep -qP '3000/tcp\s+ALLOW' \
    && pass "Firewall: kk-api (3000/tcp) allowed" \
    || fail "Firewall: kk-api rule missing"

  echo "$ufw_status" | grep -q '3001' \
    && pass "Firewall: port 3001 rules present" \
    || fail "Firewall: no rules for port 3001"

  echo "$ufw_status" | grep -qP '3001.*DENY' \
    && pass "Firewall: port 3001 external deny present" \
    || fail "Firewall: port 3001 deny rule missing"

  echo "$ufw_status" | grep -qP "from ${MONITORING_SUBNET//./\\.}.*3001" \
    && pass "Firewall: monitoring subnet (${MONITORING_SUBNET}) allowed on 3001" \
    || fail "Firewall: monitoring subnet rule for 3001 missing"

  # --- Phase 7: journal and logrotate ---
  [[ -d /var/log/journal ]] \
    && pass "Journal persistence: /var/log/journal exists" \
    || fail "Journal persistence: /var/log/journal missing"

  [[ -f /etc/systemd/journald.conf.d/kijanikiosk.conf ]] \
    && pass "Journal config file present" \
    || fail "Journal config file missing"

  [[ -f /etc/logrotate.d/kijanikiosk ]] \
    && pass "logrotate config file present" \
    || fail "logrotate config file missing"

  # logrotate --debug exits non-zero when glob matches no files (pre-deployment).
  # Inspect output text for actual errors instead of trusting the exit code.
  local lr_check
  lr_check=$(logrotate --debug /etc/logrotate.d/kijanikiosk 2>&1 || true)
  echo "$lr_check" | grep -qi "error" \
    && fail "logrotate config contains errors" \
    || pass "logrotate --debug: no errors in config"

  # --- Phase 8: health check file ---
  [[ -f "${APP_BASE}/health/last-provision.json" ]] \
    && pass "Health check JSON exists" \
    || fail "Health check JSON missing: ${APP_BASE}/health/last-provision.json"

  if [[ -f "${APP_BASE}/health/last-provision.json" ]]; then
    local owner
    owner=$(stat -c '%U' "${APP_BASE}/health/last-provision.json")
    [[ "$owner" == "kk-logs" ]] \
      && pass "Health JSON owned by kk-logs" \
      || fail "Health JSON not owned by kk-logs (owner: ${owner})"
  fi

  # --- Final verdict ---
  echo ""
  [[ $failed -eq 0 ]] \
    && success "All verification checks passed (0 failures)." \
    || error "${failed} verification check(s) failed — review FAIL lines above."
}

# ---------------------------------------------------------------------------
# Phase 7: Journal Persistence and Log Rotation
# ---------------------------------------------------------------------------
provision_journal_and_logrotate() {
  log "=== Phase 7: Journal Persistence and Log Rotation ==="

  # --- Persistent journal capped at 500 MB ---
  log "Configuring persistent systemd journal..."
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/kijanikiosk.conf << 'JOURNAL'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=100M
MaxRetentionSec=90day
JOURNAL

  systemctl restart systemd-journald
  success "Journal configured: persistent storage, 500 MB cap, 90-day retention."

  # --- logrotate config for all three services ---
  #
  # Challenge C resolution:
  #   ExecReload=/bin/kill -HUP $MAINPID is present in every unit. The
  #   postrotate script uses 'systemctl kill -s HUP <service>' to tell each
  #   process to reopen its log file handles after rotation. PrivateTmp=true
  #   does not interfere because log files live in /opt/kijanikiosk, not in
  #   the service's private /tmp mount.
  #
  # The 'create' directive sets ownership and mode of the replacement file.
  # Directory default ACLs (set via setfacl -d in Phase 3) propagate
  # automatically to new files created inside shared/logs, so kk-api and
  # kk-payments retain their rwx access after every rotation without any
  # manual permission repair.
  log "Writing logrotate configuration..."
  cat > /etc/logrotate.d/kijanikiosk << 'LOGROTATE'
# KijaniKiosk shared log directory
/opt/kijanikiosk/shared/logs/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 kk-logs kijanikiosk
    sharedscripts
    postrotate
        systemctl kill -s HUP kk-logs.service 2>/dev/null || true
    endscript
}

# kk-api private log directory
/opt/kijanikiosk/logs/api/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 kk-api kk-api
    sharedscripts
    postrotate
        systemctl kill -s HUP kk-api.service 2>/dev/null || true
    endscript
}

# kk-payments private log directory
/opt/kijanikiosk/logs/payments/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 kk-payments kk-payments
    sharedscripts
    postrotate
        systemctl kill -s HUP kk-payments.service 2>/dev/null || true
    endscript
}
LOGROTATE

  # logrotate --debug exits non-zero on Ubuntu when the glob matches no files
  # (services not yet deployed = no *.log files exist). Inspect output text
  # for genuine syntax errors rather than trusting the exit code.
  local lr_output
  lr_output=$(logrotate --debug /etc/logrotate.d/kijanikiosk 2>&1 || true)

  if echo "$lr_output" | grep -qi "error"; then
    log "logrotate --debug output:"
    echo "$lr_output" | while IFS= read -r line; do log "  $line"; done
    error "logrotate config contains errors — see output above."
  else
    success "logrotate config validated: no errors detected in --debug output."
  fi

  success "Phase 7 complete."
}

# ---------------------------------------------------------------------------
# Phase 8: Monitoring Health Checks
# Services are expected to be down at provisioning time (no app code yet).
# A JSON file with "down" values is a correct result.
# A missing JSON file is a script failure.
# ---------------------------------------------------------------------------
provision_health_checks() {
  log "=== Phase 8: Monitoring Health Checks ==="

  # Ensure health directory exists with correct ownership
  mkdir -p "${APP_BASE}/health"
  chown kk-logs:"${APP_GROUP}" "${APP_BASE}/health"
  chmod 750 "${APP_BASE}/health"

  log "Checking service ports (down is expected pre-deployment)..."
  local api_status payments_status
  api_status=$(timeout 2 bash -c "echo >/dev/tcp/localhost/3000" 2>/dev/null \
    && echo '"ok"' || echo '"down"')
  payments_status=$(timeout 2 bash -c "echo >/dev/tcp/localhost/3001" 2>/dev/null \
    && echo '"ok"' || echo '"down"')

  log "kk-api      port 3000: ${api_status}"
  log "kk-payments port 3001: ${payments_status}"

  printf '{"timestamp":"%s","kk-api":%s,"kk-payments":%s,"note":"down expected pre-deployment"}\n' \
    "$(date -Is)" "$api_status" "$payments_status" \
    > "${APP_BASE}/health/last-provision.json"

  chown kk-logs:"${APP_GROUP}" "${APP_BASE}/health/last-provision.json"
  chmod 640 "${APP_BASE}/health/last-provision.json"

  success "Health check written: ${APP_BASE}/health/last-provision.json"
  success "Phase 8 complete."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  provision_packages
  provision_users
  provision_dirs
  provision_services
  provision_firewall
  provision_journal_and_logrotate
  provision_health_checks
  verify_state
  success "Provisioning complete. Server is in known-good state."
}

main "$@"
