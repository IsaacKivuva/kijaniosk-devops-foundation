# Region and Availability Zones Strategy

## Region Selection
Our infrastructure is deployed in a single primary region. This region was selected based on the availability of necessary managed services, cost-efficiency, and geographic proximity to our primary user base to ensure the lowest possible network latency for API requests.

## Multi-AZ Reliability
To guarantee High Availability (HA) and mitigate the risk of a single point of failure, our architecture is distributed across at least two Availability Zones (AZs). 
* The application load balancer automatically distributes incoming web traffic to healthy compute instances across multiple AZs.
* Our relational database is configured in a Multi-AZ deployment. There is a primary database in AZ-A and a synchronous standby replica in AZ-B. If the primary data center goes offline, the system automatically fails over to the standby replica without data loss, ensuring the application remains operational.