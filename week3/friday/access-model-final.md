
## Group & User Architecture
* **Application Group:** `kijanikiosk`
* **Service Accounts:** * `kk-api` (Member of `kijanikiosk`)
    * `kk-payments` (Member of `kijanikiosk`)
    * `kk-logs` (Member of `kijanikiosk`)
* **Administrative Accounts:**
    * `amina` (Member of `kijanikiosk` - Added for troubleshooting and log review without requiring `sudo`)

## Directory Ownership & Permissions

### 1. The Application Base
* `/opt/kijanikiosk/` -> `root:kijanikiosk` (750)
    * *Rationale:* Only root can modify the top-level structure. The application group can traverse it.

### 2. Service Working Directories
* `/opt/kijanikiosk/api/` -> `kk-api:kk-api` (750)
* `/opt/kijanikiosk/payments/` -> `kk-payments:kk-payments` (750)
    * *Rationale:* Strict isolation. The API service cannot read the Payments service code, and vice versa.

### 3. Configuration & Environment Files
* `/opt/kijanikiosk/config/` -> `root:kijanikiosk` (750)
* `/opt/kijanikiosk/config/api.env` -> `kk-api:kk-api` (640)
* `/opt/kijanikiosk/config/payments-api.env` -> `kk-payments:kk-payments` (640)
* `/opt/kijanikiosk/config/logs.env` -> `kk-logs:kk-logs` (640)
    * *Rationale:* Placed in `/opt` to avoid conflicts with `systemd`'s `ProtectSystem=strict` (which locks down `/etc`). Each `.env` file is strictly scoped to its specific service owner to protect embedded secrets.

### 4. Logging Directories
* `/opt/kijanikiosk/logs/api/` -> `kk-api:kk-api` (750)
* `/opt/kijanikiosk/logs/payments/` -> `kk-payments:kk-payments` (750)
* `/opt/kijanikiosk/shared/logs/` -> `kk-logs:kijanikiosk` (2770 - SetGID)
    * **ACLs Applied:** `u:kk-api:rwx`, `u:kk-payments:rwx`
    * **Default ACLs Applied:** `d:u:kk-api:rwx`, `d:u:kk-payments:rwx`
    * *Rationale:* The SetGID bit (2770) ensures any file created here inherits the `kijanikiosk` group. The Default ACLs ensure that when `kk-logs` rotates files, `kk-api` and `kk-payments` automatically retain write access to the directory without needing manual permission repairs.

### 5. Health Monitoring (New)
* `/opt/kijanikiosk/health/` -> `kk-logs:kijanikiosk` (750)
* `/opt/kijanikiosk/health/last-provision.json` -> `kk-logs:kijanikiosk` (640)
    * *Rationale:* `kk-logs` generates the health payload. The group read permission allows monitoring tools or admins in the `kijanikiosk` group to ingest the health status without elevated privileges.

## Logrotate Interaction Notes
The `logrotate` configuration utilizes the `create 0640 kk-logs kijanikiosk` directive for shared logs. Because we established default ACLs (`setfacl -d -m ...`) on the parent directory, newly created replacement log files automatically inherit the necessary write permissions for the respective application services. The `postrotate` script utilizes a `SIGHUP` signal (`systemctl kill -s HUP`) to cleanly instruct the Node.js processes to re-attach to the new file descriptors, bypassing any conflicts with `PrivateTmp=true`.