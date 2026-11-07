# AWS RDS Troubleshooting Labs

## Overview

This repository contains 12 hands-on troubleshooting labs focused on Amazon Relational Database Service (Amazon RDS).

The purpose of this project is to practice diagnosing, investigating, and resolving common RDS problems using AWS CLI, Linux, SQL, Amazon CloudWatch, and AWS networking tools.

The labs simulate real-world cloud engineering and cloud security incidents involving database connectivity, authentication, access control, storage, performance, replication, availability, backups, and configuration.

Each lab follows a structured incident response and troubleshooting methodology.

**Troubleshooting workflow:**

Environment Setup → Fault Injection → Symptoms → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

## Objectives

- Understand Amazon RDS infrastructure and operations.
- Troubleshoot database connection and authentication failures.
- Investigate VPC and security group configurations.
- Understand public and private database connectivity.
- Diagnose database storage and performance problems.
- Analyze database connection limits.
- Investigate DNS and endpoint issues.
- Understand read replica lag and replication behavior.
- Practice RDS Multi-AZ failover investigation.
- Troubleshoot backups and database restoration.
- Investigate DB parameter group misconfigurations.
- Apply secure database administration principles.
- Build practical cloud engineering troubleshooting experience.

## Technologies Used

| Technology | Purpose |
|---|---|
| Amazon RDS | Managed relational databases |
| PostgreSQL | Database engine |
| Amazon EC2 | Database client and troubleshooting host |
| Amazon VPC | Network isolation and connectivity |
| Security Groups | Stateful network access control |
| AWS CLI v2 | Infrastructure administration |
| Linux | Network and database troubleshooting |
| Bash | Automation and command execution |
| `psql` | PostgreSQL client |
| `pg_stat_activity` | Database session investigation |
| `dig` / `getent` | DNS troubleshooting |
| `nc` | TCP connectivity testing |
| Amazon CloudWatch | Database metrics and monitoring |
| AWS Systems Manager | Secure EC2 management |
| AWS IAM | Authorization and access management |
| RDS Snapshots | Backup and restoration |
| RDS Read Replicas | Read scaling and replication investigation |
| RDS Multi-AZ | Database high availability |

## Repository Structure

```text
aws-rds-troubleshooting-labs/
│
├── README.md
│
├── 01-rds-connection-timeout/
│   └── README.md
│
├── 02-database-authentication-failure/
│   └── README.md
│
├── 03-rds-security-group-misconfiguration/
│   └── README.md
│
├── 04-rds-public-private-connectivity/
│   └── README.md
│
├── 05-rds-storage-full/
│   └── README.md
│
├── 06-high-database-cpu/
│   └── README.md
│
├── 07-too-many-database-connections/
│   └── README.md
│
├── 08-rds-dns-endpoint-investigation/
│   └── README.md
│
├── 09-rds-read-replica-lag/
│   └── README.md
│
├── 10-rds-multi-az-failover/
│   └── README.md
│
├── 11-database-backup-restore-failure/
│   └── README.md
│
└── 12-rds-parameter-group-misconfiguration/
    └── README.md
```

Additional Bash, SQL, and policy files will be included when required.

## Troubleshooting Labs

### Lab 01 — RDS Connection Timeout

Investigate a PostgreSQL connection that times out.

Topics include:

- RDS endpoint and port verification
- TCP connectivity
- Security group rules
- VPC and subnet configuration
- DNS resolution
- PostgreSQL client troubleshooting

### Lab 02 — Database Authentication Failure

Investigate failed PostgreSQL login attempts.

Topics include:

- Database usernames and passwords
- PostgreSQL authentication errors
- SQL role permissions
- Database connection parameters
- Secure credential management

### Lab 03 — RDS Security Group Misconfiguration

Investigate database connectivity failures caused by incorrect security group settings.

Topics include:

- Inbound and outbound rules
- Security group references
- PostgreSQL port 5432
- Least-privilege network access
- Rule verification

### Lab 04 — RDS Public vs. Private Connectivity

Understand how RDS networking affects database reachability.

Topics include:

- Public accessibility
- Private subnets
- Route tables
- Internet gateways
- Database subnet groups
- Private EC2 database clients

### Lab 05 — RDS Storage Full

Investigate database storage exhaustion and insufficient free storage.

Topics include:

- Allocated storage
- FreeStorageSpace
- CloudWatch monitoring
- PostgreSQL disk usage
- Storage expansion
- Storage autoscaling

### Lab 06 — High Database CPU

Investigate high CPU usage on an RDS database.

Topics include:

- CPUUtilization
- Expensive SQL queries
- PostgreSQL query investigation
- Database resource pressure
- Performance optimization

### Lab 07 — Too Many Database Connections

Troubleshoot PostgreSQL database connection exhaustion.

Topics include:

- `max_connections`
- `pg_stat_activity`
- Client connection management
- Connection cleanup
- Connection pooling concepts

### Lab 08 — RDS DNS Endpoint Investigation

Diagnose database connectivity problems involving DNS resolution and endpoint configuration.

Topics include:

- RDS endpoint DNS
- `dig`
- `getent hosts`
- `nslookup`
- DNS caching
- Endpoint changes during failover

### Lab 09 — RDS Read Replica Lag

Investigate delayed replication between a primary RDS instance and a read replica.

Topics include:

- PostgreSQL replication
- ReplicaLag
- Read replica endpoints
- Replication workload
- Monitoring and recovery

### Lab 10 — RDS Multi-AZ Failover

Investigate database availability during an RDS failover.

Topics include:

- Multi-AZ deployments
- Primary and standby instances
- Failover events
- DNS endpoint behavior
- Database reconnection
- High availability verification

### Lab 11 — Database Backup and Restore Failure

Troubleshoot database restoration issues using RDS snapshots.

Topics include:

- Automated backups
- Manual snapshots
- Snapshot status
- Database instance restoration
- Restore configuration
- Data integrity verification

### Lab 12 — RDS Parameter Group Misconfiguration

Investigate database behavior caused by incorrect configuration parameters.

Topics include:

- DB parameter groups
- Static and dynamic parameters
- PostgreSQL configuration
- Parameter validation
- Pending reboot changes
- Configuration rollback

## Standard Lab Methodology

Each troubleshooting lab contains the following sections.

### 1. Incident Scenario

Describe a realistic production problem and its impact on application availability, performance, or security.

### 2. Architecture

Explain the AWS resources and database components involved.

### 3. Environment Setup

Provision the resources needed for the exercise.

### 4. Fault Injection

Intentionally introduce a controlled configuration or workload problem.

### 5. Symptoms

Capture error messages, failed commands, and observable AWS resource states.

### 6. Investigation

Use AWS CLI, Linux, SQL, and monitoring tools to identify the problem.

### 7. Root Cause Analysis

Explain the technical reason for the failure and distinguish it from similar symptoms.

### 8. Remediation

Apply a targeted fix while following security and availability best practices.

### 9. Verification

Verify that the database or service operates correctly after remediation.

### 10. Cleanup

Delete temporary AWS resources and verify that they have been removed.

### 11. Interview Questions

Review practical troubleshooting questions related to the incident.

## Example AWS CLI Commands

### List RDS Instances

```bash
aws rds describe-db-instances \
  --region us-east-1
```

### Check Database Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier example-postgres-db \
  --query 'DBInstances[0].DBInstanceStatus'
```

### Retrieve the Database Endpoint

```bash
aws rds describe-db-instances \
  --db-instance-identifier example-postgres-db \
  --query 'DBInstances[0].Endpoint'
```

### View DB Security Groups

```bash
aws rds describe-db-instances \
  --db-instance-identifier example-postgres-db \
  --query 'DBInstances[0].VpcSecurityGroups'
```

### Describe DB Snapshots

```bash
aws rds describe-db-snapshots \
  --region us-east-1
```

## Example Linux Troubleshooting Commands

### DNS Resolution

```bash
getent hosts your-rds-endpoint
```

### Test PostgreSQL Port

```bash
nc -vz your-rds-endpoint 5432
```

### Connect to PostgreSQL

```bash
psql \
  "host=your-rds-endpoint port=5432 dbname=postgres user=your-db-user sslmode=require"
```

Use a secure credential source or interactive password prompt rather than placing passwords in shell commands.

### Check PostgreSQL Sessions

```sql
SELECT pid, usename, state, application_name
FROM pg_stat_activity;
```

### Check Database Information

```sql
SELECT current_database(), current_user, version();
```

## AWS Security Best Practices

- Prefer private RDS deployment configurations.
- Avoid opening database ports to the entire internet.
- Restrict security group ingress to authorized clients.
- Use encryption in transit and at rest where appropriate.
- Use secure credential management.
- Apply least-privilege permissions.
- Enable appropriate database backups.
- Monitor database health and security events.
- Do not store credentials in GitHub.
- Avoid using production databases for fault injection.
- Clean up temporary resources after completing exercises.

## Cost Management

RDS database instances and allocated storage can incur charges while running. Multi-AZ configurations, read replicas, backup storage, and additional EC2 resources may increase costs.

These labs use small, disposable environments where supported.

Before running a lab:

1. Review the instance class and deployment configuration.
2. Understand possible storage and backup charges.
3. Avoid unnecessary Multi-AZ deployments or read replicas.
4. Set an AWS Budget for the lab account.
5. Delete temporary resources after completion.
6. Verify backups, snapshots, and database instances are removed when no longer needed.

## Target Skills

This repository develops skills relevant to:

- Junior Cloud Engineer
- Cloud Operations Engineer
- Cloud Engineer
- Cloud Security Engineer
- DevOps Engineer
- Infrastructure Engineer
- Platform Engineer

## Learning Outcomes

After completing the 12 labs, the goal is to be able to:

- Investigate RDS connectivity failures.
- Distinguish network errors from authentication errors.
- Diagnose database storage and CPU pressure.
- Investigate excessive database connections.
- Understand database endpoint and DNS behavior.
- Analyze replication lag.
- Troubleshoot failover and availability incidents.
- Investigate snapshot and database restore failures.
- Diagnose configuration problems.
- Apply secure and practical database remediation procedures.

## Disclaimer

This repository is intended for learning and controlled testing.

The commands should be executed only in authorized environments. Resource identifiers, configurations, costs, and observed results may vary.

Avoid performing fault injection on production infrastructure.

---

**Project Focus:** Practical AWS Cloud Engineering and Cloud Security Troubleshooting

**Primary Tools:** AWS CLI · Linux · Bash · PostgreSQL · CloudWatch · Systems Manager
