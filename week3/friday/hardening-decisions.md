# Infrastructure Hardening & Security Decisions
**Prepared For:** Nia (Management & Stakeholder Review)
**Topic:** Friday Production-Grade Provisioning

## Executive Summary
This week, the KijaniKiosk infrastructure transitioned from a "functionally working" state to a "production-ready secure" state. Our primary goal was to ensure that if a malicious actor ever manages to compromise our Node.js application, the damage they can do to the underlying Linux server—and by extension, the rest of our business—is severely limited. We achieved this by implementing strict sandboxing around each application service using native systemd controls, tightly scoping our firewall rules, and enforcing a principle of least privilege across our file system. 

The resulting infrastructure treats our own application code with a healthy amount of suspicion. We have restricted what the applications can see, what they can modify, and who they can talk to on the network.

## System Hardening Implementations

The following table outlines the key security measures applied to the KijaniKiosk environment, specifically focusing on how we sandboxed the API, Payments, and Logging services.

| Security Directive | Plain Language Explanation | Why We Need It |
| :--- | :--- | :--- |
| **ProtectSystem=strict** | Makes the core operating system files completely read-only for the application. | If an attacker hacks the app, they cannot install persistent malware, backdoors, or alter system configurations in folders like `/usr` or `/boot`. |
| **PrivateTmp=true** | Gives the service its own invisible, isolated temporary folder instead of the shared server `/tmp` folder. | Prevents our application from accidentally leaking sensitive data to other users on the server, and stops it from reading temporary files left by other services. |
| **ProtectHome=true** | Completely blocks the application from viewing or entering user home directories on the server. | Prevents a compromised application from stealing SSH keys, bash histories, or personal files belonging to system administrators. |
| **NoNewPrivileges=true** | Stops the application process from ever gaining higher permissions than it started with. | Prevents privilege escalation attacks where a hacker uses a software bug to trick the system into making them a "root" administrator. |
| **Internal Firewall Targeting** | Configures the firewall to only allow internal server traffic (and our specific monitoring subnet) to reach port 3001. | The Payments service handles sensitive financial data. It should never be exposed to the public internet directly. It must only be reachable via our internal proxy. |
| **RestrictAddressFamilies** | Limits the application's networking capabilities to standard internet connections (IPv4/IPv6) and local Unix sockets. | Prevents the application from utilizing obscure network protocols (like AppleTalk or IPX) that hackers sometimes use to bypass standard monitoring tools. |
| **File Access Control Lists (ACLs)** | A highly specific set of rules that allows multiple different programs to write to the exact same folder securely. | Standard Linux permissions only allow one owner per file. ACLs allow our API and Payments services to share a logging folder without giving public access to everyone else. |
| **Idempotent Verification** | An automated script phase that double-checks every directory, permission, and firewall rule before reporting success. | Human error happens. This guarantees the server configuration matches our security design exactly, preventing silent deployment failures. |

## Technical Trade-offs & Rejected Security Measures

While we aimed for the highest security score possible, security must not break business functionality. During testing, we had to make intentional engineering trade-offs regarding two specific systemd hardening features:

**1. The Memory Restriction Trade-off**
We investigated enabling `MemoryDenyWriteExecute`. This is a highly recommended security setting that prevents a program from writing data to memory and then executing that data as code (a common tactic for memory-corruption malware). However, our applications run on Node.js. Node.js relies on an engine called V8, which compiles JavaScript into machine code "Just-In-Time" (JIT) while the app is running. This JIT process fundamentally requires writable and executable memory. Enabling this security rule caused our applications to instantly crash on startup. We chose to reject this rule because the minor security score benefit was not worth completely breaking our application runtime.

**2. The Network Isolation Trade-off**
We also considered using `PrivateNetwork=true`, which effectively unplugs the virtual ethernet cable from the application, leaving it with no network access at all. While highly secure, this is completely unworkable for a Payments API. Our payments service must communicate with upstream financial gateways, banking partners, and our internal API. Instead of using this blunt instrument, we chose a more surgical approach: we rejected `PrivateNetwork` and instead used `IPAddressDeny` and `IPAddressAllow` to strictly whitelist exactly which IP addresses the payments service is allowed to talk to.

## Honest Gaps & Remaining Vulnerabilities

It is vital to understand that while the server infrastructure is now highly hardened, this does not mean the system is impenetrable. We still have several distinct security gaps that require attention in future Agile iterations:

* **Secrets Management:** Currently, sensitive configuration data (like database passwords and API keys) are stored in plain text `.env` files within the `/opt/kijanikiosk/config/` directory. While file permissions protect them from unauthorized users on the server, a hacker who manages to read these files through an application vulnerability (like a Path Traversal exploit) will gain those secrets. We need to transition to a proper secrets manager like HashiCorp Vault or AWS Secrets Manager.
* **Application Supply Chain Risks:** Our script secures the operating system, but it does not secure the code the developers write. Node.js heavily relies on third-party NPM packages. If a developer accidentally imports a malicious package, that code will execute within our environment. We currently lack an automated vulnerability scanner for our software dependencies in the deployment pipeline.
* **DDoS Vulnerability:** The UFW firewall is excellent at blocking unauthorized ports, but it is not a Web Application Firewall (WAF). If an attacker floods our open public ports (80 and 443) with millions of requests, the server will still become overwhelmed and crash. We will need upstream protection, such as Cloudflare or AWS Shield, to mitigate Distributed Denial of Service attacks.
* **No Outbound Traffic Filtering:** While we locked down incoming traffic, our outbound traffic rules are relatively permissive. If our application is compromised, the attacker could potentially download further malware from the internet. Implementing an egress proxy to filter outbound requests would close this gap.

In conclusion, this week's deployment represents a massive leap forward in our security posture, successfully containing the blast radius of a potential breach. However, we must prioritize addressing the application-layer and secrets-management gaps in the coming weeks to achieve comprehensive security.