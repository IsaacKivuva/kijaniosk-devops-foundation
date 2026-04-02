# Hardening Log: kk-payments.service

**Initial Score:** ~ 9.5 (UNSAFE)
**Target Score:** < 2.5 (Financial data profile)

---

## Directives Applied

* **NoNewPrivileges=true**
  *(Score impact: -0.2)*

* **PrivateTmp=true, PrivateDevices=true, PrivateUsers=true**
  *(Score impact: -2.1)*

* **ProtectSystem=strict, ProtectHome=true**
  *(Score impact: -1.5)*

* **CapabilityBoundingSet=, AmbientCapabilities=**
  *(Score impact: -1.8)*

* **SystemCallArchitectures=native, SystemCallFilter=@system-service**
  *(Score impact: -1.2)*

* **RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX, RestrictNamespaces=true**
  *(Score impact: -0.8)*

* **LockPersonality=true, RestrictRealtime=true, RemoveIPC=true**
  *(Score impact: -0.6)*

* **ProtectClock=true, ProtectHostname=true, ProtectKernelTunables=true, ProtectKernelModules=true, ProtectKernelLogs=true, ProtectControlGroups=true**
  *(Score impact: -0.8)*

* **IPAddressDeny=any, IPAddressAllow=localhost 127.0.0.1/8 10.0.1.0/24**
  *(Network sandboxing)*

* **UMask=0077**
  *(Score impact: -0.1)*

---

## Directives Investigated but REJECTED

### MemoryDenyWriteExecute=true

**Justification:**
Node.js uses the V8 engine, which relies on Just-In-Time (JIT) compilation. JIT requires writable executable memory pages. Enabling this directive caused an immediate `SIGSEGV` crash on startup. The ~0.2 score benefit is not worth breaking the runtime.

---

### PrivateNetwork=true

**Justification:**
This directive entirely removes the network interfaces from the process namespace. Because this is a payments API, it must communicate with upstream payment gateways and internal systems. Instead of breaking connectivity, I used `IPAddressDeny` and `IPAddressAllow` to achieve targeted network restriction.
