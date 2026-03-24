# Cloud Service Model

This system utilizes a hybrid approach, combining **PaaS (Platform as a Service)** and **IaaS (Infrastructure as a Service)** to optimize both developer velocity and backend control.

* **PaaS:** We leverage a managed platform to host our frontend("NextJs") and serverless API("tRPC") routes. This allows the cloud provider to handle underlying OS patching, autoscaling, and edge caching automatically, enabling our developers to focus entirely on application logic and user experience.
* **IaaS / Managed Services:** For our data layer, we utilize a managed relational database service (like AWS RDS or Google Cloud SQL) rather than raw virtual machines. This gives our Prisma ORM a reliable, persistent connection while the cloud provider manages backups, automated failover, and hardware maintenance.