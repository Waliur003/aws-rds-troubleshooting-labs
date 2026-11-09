# Lab 09 — RDS Read Replica Lag

## Overview

This lab demonstrates how to investigate replication lag in Amazon RDS PostgreSQL using AWS CLI, Amazon CloudWatch, PostgreSQL replication statistics, and Linux troubleshooting tools.

We deploy a private PostgreSQL primary database and create an actual Amazon RDS read replica.

The primary database handles application read and write operations, while the read replica handles read-only queries.

We generate a controlled workload that inserts thousands of synthetic records into the primary database.

These operations produce PostgreSQL Write-Ahead Log (WAL) records that must be transferred and replayed on the replica.

Because RDS PostgreSQL read replicas use asynchronous replication, the replica may temporarily contain older data than the primary.

We investigate replication status, WAL positions, CloudWatch `ReplicaLag`, database resource utilization, and data consistency.

After the workload finishes, we verify that the replica has applied the primary database's committed changes.

Finally, we configure CloudWatch monitoring, review production remediation techniques, and delete the temporary infrastructure.

**Troubleshooting workflow:**

Infrastructure Setup → Primary Deployment → Replica Creation → Baseline Verification → Write Workload → Replication Investigation → Root Cause Analysis → Recovery → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-009 |
| Difficulty | Advanced |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager, CloudWatch |
| Database Engine | PostgreSQL |
| Primary Instance | `cloud-rds-lab09-primary` |
| Read Replica | `cloud-rds-lab09-replica` |
| Instance Class | `db.t4g.micro` |
| Primary Storage | 20 GiB gp3 |
| Replica Storage | Inherited from source |
| Primary Backup Retention | 1 day |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| Database Name | `labdb` |
| Database Username | `labadmin` |
| Database Port | TCP `5432` |
| VPC | `10.199.0.0/16` |
| Public Subnet | `10.199.1.0/24` |
| Private Subnet A | `10.199.2.0/24` |
| Private Subnet B | `10.199.3.0/24` |
| Primary Public Access | Disabled |
| Replica Public Access | Disabled |
| Replication Type | Asynchronous |
| Fault Simulation | Controlled write burst |
| Expected Symptom | Temporary replica data lag |
| Main Metric | `ReplicaLag` |
| Additional Metrics | `WriteIOPS`, `CPUUtilization`, `OldestReplicationSlotLag` |
| Investigation | PostgreSQL WAL and replication views |
| Remediation | Stop unnecessary workload and investigate replica capacity |
| Verification | Primary and replica data consistency |

---

## 2. Production Incident Scenario

### Incident Description

A company operates an online application using Amazon RDS PostgreSQL.

The application stores customer transactions on the primary database.

To reduce the primary database's reporting workload, the company creates a PostgreSQL read replica.

The primary database processes inserts, updates, and deletes.

The read replica serves read-only reporting requests.

One day, customers report that their recent transactions are not immediately visible in the reporting dashboard.

The operations team investigates and discovers that new records exist on the primary database but are not yet visible on the replica.

The RDS instances remain available, and PostgreSQL connections are successful.

However, the replica has fallen behind the primary database.

### Incident Symptoms

- Primary RDS instance is available.
- Read replica is available.
- Database connections succeed.
- Primary accepts writes.
- Replica rejects writes.
- New records appear on the primary first.
- Replica may temporarily return older data.
- CloudWatch `ReplicaLag` may increase.
- WAL replay can lag behind WAL generation.
- Application reporting may show outdated records.

### Business Impact

- Reporting dashboards may show stale data.
- Recent transactions may not appear immediately.
- Analytics applications may use outdated information.
- Users may question data accuracy.
- Read-after-write application workflows may behave incorrectly.
- Prolonged lag can increase WAL retention and storage pressure.
- Incident investigation may require database and infrastructure monitoring.

### Objective

Investigate PostgreSQL read replica lag, identify possible replication bottlenecks, verify replication progress, and confirm that the replica eventually contains the primary database's committed records.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                      AWS Region
                       us-east-1
                           |
                           v
                      Amazon VPC
                    10.199.0.0/16
                           |
             -------------------------------
             |                             |
             v                             v
        Public Subnet                Private Subnets
       10.199.1.0/24                10.199.2.0/24
             |                      10.199.3.0/24
             v                             |
         EC2 Client                        |
      Amazon Linux 2023                    |
             |                             |
             v                             v
       PostgreSQL Client           --------------------
                                   |                  |
                                   v                  v
                               Primary RDS        Read Replica
                               READ/WRITE          READ ONLY
                                   |                  ^
                                   |                  |
                                   +------- WAL ------+
                                      Asynchronous
                                       Replication
```

### PostgreSQL Replication Flow

```text
Application Write
        |
        v
Primary PostgreSQL
        |
        v
Transaction Commit
        |
        v
Write-Ahead Log (WAL)
        |
        v
WAL Streaming
        |
        v
Read Replica Receives WAL
        |
        v
Read Replica Replays WAL
        |
        v
Latest Data Becomes Visible
```

### Potential Replication Lag

```text
Primary Database
        |
        v
Heavy Write Activity
        |
        v
Increased WAL Generation
        |
        v
Replica Receives WAL
        |
        v
Replica Replay Falls Behind
        |
        v
ReplicaLag Increases
        |
        v
Reporting Queries May Show Stale Data
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.199.0.0/16` |
| Public Subnet | `10.199.1.0/24` |
| Private Subnet A | `10.199.2.0/24` |
| Private Subnet B | `10.199.3.0/24` |
| Public Routing | Internet Gateway |
| Private Routing | VPC local route |
| EC2 Security Group | `cloud-rds-lab09-client-sg` |
| Database Security Group | `cloud-rds-lab09-db-sg` |
| PostgreSQL Access | EC2 SG to RDS SG, TCP 5432 |
| Primary Accessibility | Private |
| Replica Accessibility | Private |
| EC2 Administration | Systems Manager |

---

## 4. Understanding PostgreSQL Read Replication

### What Is an RDS Read Replica?

An Amazon RDS read replica is a separate database instance that asynchronously receives changes from a source database.

Read replicas are useful for workloads such as:

- Reporting
- Analytics
- Read-heavy applications
- Business dashboards
- Read query distribution

### Primary Database

The primary database accepts read and write operations.

Example:

```sql
INSERT INTO replication_test (batch_no, payload)
VALUES (1, decode('AA', 'hex'));
```

### Read Replica

The read replica normally accepts read-only operations.

Example:

```sql
SELECT COUNT(*) FROM replication_test;
```

Attempting a normal application write on the read replica results in a read-only transaction error.

### Asynchronous Replication

PostgreSQL read replicas use asynchronous replication.

A transaction can commit on the primary before its changes become visible on the replica.

This means the replica can temporarily show stale data.

### Write-Ahead Logging

PostgreSQL records database changes using Write-Ahead Logging, commonly called WAL.

WAL supports crash recovery and physical replication.

### Replication Lag

Replication lag describes how far the replica is behind the primary database.

Amazon CloudWatch provides the `ReplicaLag` metric.

For PostgreSQL, the reported time is based on the timestamp of the last replayed transaction.

### WAL Log Sequence Number

A Log Sequence Number, or LSN, identifies a position in PostgreSQL's WAL stream.

Useful PostgreSQL functions include:

```sql
SELECT pg_current_wal_lsn();
```

```sql
SELECT pg_last_wal_receive_lsn();
```

```sql
SELECT pg_last_wal_replay_lsn();
```

### Important Replication Views

| View or Function | Purpose |
|---|---|
| `pg_stat_replication` | Replication connection status on the primary |
| `pg_replication_slots` | Replication slot information |
| `pg_is_in_recovery()` | Identifies whether the database is a standby |
| `pg_current_wal_lsn()` | Current WAL position on primary |
| `pg_last_wal_receive_lsn()` | WAL received by replica |
| `pg_last_wal_replay_lsn()` | WAL replayed by replica |
| `pg_last_xact_replay_timestamp()` | Last replayed transaction timestamp |
| `pg_wal_lsn_diff()` | Difference between WAL positions |

**Important:** PostgreSQL's reported time-based replication lag can increase while the primary is idle, even when committed changes are fully replayed. Always compare multiple indicators.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Amazon RDS permissions
- Amazon EC2 permissions
- VPC administration permissions
- IAM permissions
- CloudWatch permissions
- Systems Manager access
- PostgreSQL client
- Git and GitHub

### Safety Guidelines

- Use only disposable RDS instances.
- Do not generate write workloads on production databases.
- Keep the primary and replica private.
- Do not expose PostgreSQL to `0.0.0.0/0`.
- Use Systems Manager instead of SSH.
- Generate synthetic records.
- Limit the write workload.
- Monitor database storage and resource utilization.
- Do not force replication failure by deleting required WAL files.
- Do not promote the read replica unnecessarily.
- Do not terminate AWS-managed PostgreSQL processes.
- Remove temporary database passwords.
- Delete all resources afterward.

### Cost Warning

This lab creates **two billable RDS instances** and one EC2 instance.

Additional charges may include database storage, backups, EBS storage, public IPv4 addresses, and CloudWatch alarms.

Keep both databases only as long as needed for the exercise.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab09"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export PRIMARY_DB="cloud-rds-lab09-primary"
export REPLICA_DB="cloud-rds-lab09-replica"

export DB_SUBNET_GROUP="cloud-rds-lab09-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"

export EC2_ROLE_NAME="cloud-rds-lab09-ssm-role"
export PROFILE_NAME="cloud-rds-lab09-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab09-client-sg"
export DB_SG_NAME="cloud-rds-lab09-db-sg"

export ALARM_NAME="cloud-rds-lab09-replica-lag"
```

### Step 2 — Verify AWS Credentials

```bash
aws sts get-caller-identity

aws --version
```

### Step 3 — Verify Instance Availability

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass,Version:EngineVersion}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Check Existing Resources

```bash
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, 'cloud-rds-lab09')].[DBInstanceIdentifier,DBInstanceStatus]" \
  --output table \
  --region "$AWS_REGION"
```

Avoid creating duplicate resources.

---

## 7. Create AWS Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.199.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab09-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

Enable DNS:

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

### Step 2 — Create Public Subnet

```bash
export PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.199.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab09-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.199.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab09-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.199.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab09-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab09-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Create Public Route Table

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab09-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

```bash
aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

Associate the public subnet:

```bash
export PUBLIC_RT_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Both database subnets remain private.

---

## 8. Create Security Groups

### Step 1 — Create EC2 Client SG

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab09 EC2 troubleshooting client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Database SG

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab09 primary and replica PostgreSQL" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Authorize PostgreSQL Traffic

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify SG Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: port `5432` is permitted from the EC2 client security group only.

---

## 9. Deploy EC2 Troubleshooting Client

### Step 1 — Create Trust Policy

Save as `ec2-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Step 2 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 3 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

Allow IAM changes to propagate before launching EC2.

### Step 4 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$PUBLIC_SUBNET_ID,Groups=$CLIENT_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=cloud-rds-lab09-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$INSTANCE_ID"
```

### Step 6 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Connect Through Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo dnf install -y postgresql15 nmap-ncat bind-utils
```

Verify:

```bash
psql --version
command -v nc
command -v dig
```

Exit:

```bash
exit
```

---

## 10. Create Primary RDS PostgreSQL

### Step 1 — Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab09 primary and read replica subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Enter Temporary Password

```bash
read -rsp "Enter disposable RDS password: " DB_PASSWORD
echo
```

Use a unique, strong password.

For this disposable exercise, the password is passed as a CLI argument. In production, use RDS-managed credentials in AWS Secrets Manager.

### Step 3 — Create Primary Database

The source must have automated backups enabled.

```bash
aws rds create-db-instance \
  --db-instance-identifier "$PRIMARY_DB" \
  --engine postgres \
  --db-instance-class db.t4g.micro \
  --allocated-storage 20 \
  --storage-type gp3 \
  --storage-encrypted \
  --master-username "$DB_USERNAME" \
  --master-user-password "$DB_PASSWORD" \
  --db-name "$DB_NAME" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --port 5432 \
  --no-publicly-accessible \
  --no-multi-az \
  --backup-retention-period 1 \
  --no-deletion-protection \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

Remove the password variable:

```bash
unset DB_PASSWORD
```

### Step 4 — Wait for Primary

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$PRIMARY_DB" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Primary

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$PRIMARY_DB" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,BackupRetention:BackupRetentionPeriod,Public:PubliclyAccessible,Class:DBInstanceClass}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
BackupRetention: 1
Public: False
Class: db.t4g.micro
```

### Step 6 — Retrieve Primary Endpoint

```bash
export PRIMARY_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$PRIMARY_DB" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$PRIMARY_ENDPOINT"
```

---

## 11. Create RDS Read Replica

### Step 1 — Create Replica

```bash
aws rds create-db-instance-read-replica \
  --db-instance-identifier "$REPLICA_DB" \
  --source-db-instance-identifier "$PRIMARY_DB" \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --no-publicly-accessible \
  --no-multi-az \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

The read replica is a separate billable RDS database instance.

### Step 2 — Wait for Replica

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$REPLICA_DB" \
  --region "$AWS_REGION"
```

### Step 3 — Verify Replication Source

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$REPLICA_DB" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Source:ReadReplicaSourceDBInstanceIdentifier,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Source: cloud-rds-lab09-primary
Public: False
```

### Step 4 — Verify Replica on Primary

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$PRIMARY_DB" \
  --query 'DBInstances[0].ReadReplicaDBInstanceIdentifiers' \
  --output json \
  --region "$AWS_REGION"
```

Expected: `cloud-rds-lab09-replica`.

### Step 5 — Retrieve Replica Endpoint

```bash
export REPLICA_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$REPLICA_DB" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$REPLICA_ENDPOINT"
```

### Step 6 — Verify Both Instances

```bash
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, 'cloud-rds-lab09')].{Name:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address,Source:ReadReplicaSourceDBInstanceIdentifier}" \
  --output table \
  --region "$AWS_REGION"
```

---

## 12. Baseline Replication Verification

### Step 1 — Connect to EC2

From WSL:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export PRIMARY_ENDPOINT="YOUR_PRIMARY_RDS_ENDPOINT"
export REPLICA_ENDPOINT="YOUR_REPLICA_RDS_ENDPOINT"
```

Replace the placeholders with the actual RDS endpoints.

### Step 2 — Verify DNS and TCP

```bash
getent ahostsv4 "$PRIMARY_ENDPOINT"
getent ahostsv4 "$REPLICA_ENDPOINT"
```

```bash
nc -vz -w 5 "$PRIMARY_ENDPOINT" 5432

nc -vz -w 5 "$REPLICA_ENDPOINT" 5432
```

Expected: successful connectivity.

### Step 3 — Connect to Primary

```bash
psql \
  "host=$PRIMARY_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Verify:

```sql
SELECT pg_is_in_recovery();
```

Expected: `false`.

### Step 4 — Create Test Table

```sql
CREATE TABLE replication_test (
    id BIGSERIAL PRIMARY KEY,
    batch_no INTEGER NOT NULL,
    payload BYTEA NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

Enable `pgcrypto`:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

Insert a baseline record:

```sql
INSERT INTO replication_test (batch_no, payload)
VALUES (0, gen_random_bytes(128));
```

Verify:

```sql
SELECT COUNT(*) FROM replication_test;
```

Expected: 1.

### Step 5 — Inspect Primary Replication Status

```sql
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
```

Expected: a streaming replication connection when the replica is connected.

### Step 6 — Inspect Replication Slots

```sql
SELECT
    slot_name,
    slot_type,
    active,
    restart_lsn,
    wal_status
FROM pg_replication_slots;
```

The exact result depends on PostgreSQL and RDS configuration.

Exit:

```text
\q
```

### Step 7 — Connect to Read Replica

```bash
psql \
  "host=$REPLICA_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Verify standby status:

```sql
SELECT pg_is_in_recovery();
```

Expected: `true`.

### Step 8 — Verify Replicated Data

```sql
SELECT COUNT(*) FROM replication_test;
```

Expected: 1 after replication catches up.

### Step 9 — Verify Read-Only Behavior

```sql
INSERT INTO replication_test (batch_no, payload)
VALUES (999, decode('AA', 'hex'));
```

Expected: read-only transaction error.

This is correct behavior.

### Step 10 — Inspect WAL Replay

```sql
SELECT
    pg_last_wal_receive_lsn(),
    pg_last_wal_replay_lsn(),
    pg_last_xact_replay_timestamp();
```

Exit:

```text
\q
```

### Step 11 — Record Baseline ReplicaLag

From WSL:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table \
  --region "$AWS_REGION"
```

Record the actual results.

---

## 13. Fault Injection — Generate Replication Workload

### Step 1 — Configure Temporary Authentication

Inside EC2:

```bash
read -rsp "Enter labadmin database password: " DB_PASSWORD
echo
```

Create a password file for both endpoints:

```bash
export PGPASSFILE="$HOME/.pgpass-lab09"

umask 077

ESCAPED_PASSWORD=$(printf '%s' "$DB_PASSWORD" \
  | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')

printf '%s:5432:labdb:labadmin:%s\n' \
  "$PRIMARY_ENDPOINT" "$ESCAPED_PASSWORD" \
  > "$PGPASSFILE"

printf '%s:5432:labdb:labadmin:%s\n' \
  "$REPLICA_ENDPOINT" "$ESCAPED_PASSWORD" \
  >> "$PGPASSFILE"

chmod 600 "$PGPASSFILE"

unset DB_PASSWORD ESCAPED_PASSWORD
```

### Step 2 — Verify Authentication

```bash
psql \
  "host=$PRIMARY_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "SELECT 1;"
```

```bash
psql \
  "host=$REPLICA_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "SELECT 1;"
```

### Step 3 — Create Write Workload Script

Save as `generate-replication-load.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${PRIMARY_ENDPOINT:?PRIMARY_ENDPOINT is required}"
: "${PGPASSFILE:?PGPASSFILE is required}"

for batch in $(seq 1 8); do

    echo "Inserting batch $batch"

    psql \
      "host=$PRIMARY_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require application_name=lab09-write-load" \
      -v ON_ERROR_STOP=1 \
      -c "
      INSERT INTO replication_test (batch_no, payload)
      SELECT
          $batch,
          gen_random_bytes(1024)
      FROM generate_series(1, 10000);
      "

    echo "Committed batch $batch"
done

echo "Replication workload finished."
```

Make the script executable:

```bash
chmod +x generate-replication-load.sh
```

### Step 4 — Start Write Workload

```bash
./generate-replication-load.sh
```

Expected:

```text
Inserting batch 1
Committed batch 1
...
Inserting batch 8
Committed batch 8
Replication workload finished.
```

### Step 5 — Verify Primary Records

```bash
psql \
  "host=$PRIMARY_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "
  SELECT
      COUNT(*) AS total_rows,
      MAX(batch_no) AS latest_batch
  FROM replication_test;
  "
```

Expected after all batches:

```text
total_rows: 80001
latest_batch: 8
```

### Step 6 — Verify Replica Records

```bash
psql \
  "host=$REPLICA_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "
  SELECT
      COUNT(*) AS total_rows,
      MAX(batch_no) AS latest_batch
  FROM replication_test;
  "
```

The read replica may temporarily contain fewer records.

A healthy replica may also catch up quickly enough that both results match immediately.

### Step 7 — Investigate CloudWatch ReplicaLag

From WSL:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" \
  --start-time "$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table \
  --region "$AWS_REGION"
```

### Step 8 — Inspect Primary WriteIOPS

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name WriteIOPS \
  --dimensions Name=DBInstanceIdentifier,Value="$PRIMARY_DB" \
  --start-time "$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --output table \
  --region "$AWS_REGION"
```

### Step 9 — Inspect Replica CPU

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" \
  --start-time "$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --output table \
  --region "$AWS_REGION"
```

### Fault Injection Summary

| Check | Expected Result |
|---|---|
| Primary | Available |
| Read Replica | Available |
| Primary Writes | Successful |
| Replica Writes | Rejected |
| Synthetic Records | 80,001 |
| WAL Generation | Increased |
| ReplicaLag | Monitored; may increase |
| Replica Data | May temporarily lag |
| Replication | Continues asynchronously |

---

## 14. Troubleshooting Investigation

### Check 1 — Verify Replica Relationship

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$REPLICA_DB" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Source:ReadReplicaSourceDBInstanceIdentifier,Class:DBInstanceClass}' \
  --output table \
  --region "$AWS_REGION"
```

### Check 2 — Inspect Primary Replication

Inside EC2:

```bash
psql \
  "host=$PRIMARY_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require"
```

Execute:

```sql
SELECT
    application_name,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
```

Look for the streaming state.

### Check 3 — Compare WAL Positions

```sql
SELECT
    application_name,
    pg_wal_lsn_diff(sent_lsn, replay_lsn)
        AS bytes_sent_not_replayed
FROM pg_stat_replication
WHERE replay_lsn IS NOT NULL;
```

This value represents a WAL difference in bytes rather than seconds.

### Check 4 — Examine Replication Slots

```sql
SELECT
    slot_name,
    active,
    restart_lsn,
    wal_status
FROM pg_replication_slots;
```

Inspect whether the replication slot is active and retaining WAL.

Exit the primary:

```text
\q
```

### Check 5 — Inspect Replica Replay

Connect to the replica:

```bash
psql \
  "host=$REPLICA_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require"
```

Execute:

```sql
SELECT
    pg_last_wal_receive_lsn() AS received_lsn,
    pg_last_wal_replay_lsn() AS replayed_lsn;
```

### Check 6 — Compare Received and Replayed WAL

```sql
SELECT
    pg_wal_lsn_diff(
        pg_last_wal_receive_lsn(),
        pg_last_wal_replay_lsn()
    ) AS received_not_replayed_bytes;
```

A positive result indicates WAL has been received but not yet fully replayed.

A zero result alone does not prove every primary change has arrived.

### Check 7 — Inspect Last Transaction Replay

```sql
SELECT pg_last_xact_replay_timestamp();
```

Calculate elapsed time:

```sql
SELECT
    EXTRACT(
        EPOCH FROM now() - pg_last_xact_replay_timestamp()
    ) AS replay_age_seconds;
```

This value may increase during source inactivity, even when replication is otherwise healthy.

### Check 8 — Compare Application Data

On the primary:

```sql
SELECT
    COUNT(*) AS total_rows,
    MAX(batch_no) AS latest_batch
FROM replication_test;
```

Run the same statement on the replica and compare the results.

### Check 9 — Investigate ReplicaLag

From WSL:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Average Maximum \
  --output table \
  --region "$AWS_REGION"
```

### Check 10 — Examine Replication Slot Lag

When supported, inspect the `OldestReplicationSlotLag` metric on the primary:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name OldestReplicationSlotLag \
  --dimensions Name=DBInstanceIdentifier,Value="$PRIMARY_DB" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Maximum \
  --output table \
  --region "$AWS_REGION"
```

This metric concerns WAL lag in bytes, not replication delay in seconds.

### Investigation Summary

| Investigation | Expected Finding |
|---|---|
| Primary Status | Available |
| Replica Status | Available |
| Primary Writes | Successful |
| Replica Read-Only | True |
| Primary Replication Connection | Streaming |
| WriteIOPS | Increases during writes |
| WAL Generation | Increased |
| ReplicaLag | Monitored |
| WAL Replay | Progressing |
| Record Counts | Eventually equal |
| Root Cause if Lag Occurs | Replication replay behind write activity |

---

## 15. Root Cause Analysis

### Simulated Root Cause

The primary database generates WAL records as it processes the synthetic write workload.

These WAL records must be transferred to the read replica and replayed asynchronously.

If the primary generates changes faster than the read replica can process them, the replica may temporarily fall behind.

This creates a delay before new records become visible through replica queries.

### Technical Explanation

The primary processes write operations and commits transactions.

PostgreSQL writes corresponding WAL records.

The read replica receives these records and replays the changes.

Replication lag occurs when receiving or replaying the necessary WAL takes longer than the rate at which new WAL is generated.

In production, sustained lag can also result from resource constraints, long-running queries, or replication connectivity problems.

### Root Cause Flow

```text
Application Writes
        |
        v
Primary PostgreSQL
        |
        v
Large Number of Transactions
        |
        v
Increased WAL Generation
        |
        v
WAL Streaming to Replica
        |
        v
Replica Replay Delay
        |
        v
ReplicaLag May Increase
        |
        v
Reporting Queries May Show Stale Data
```

### Five Whys

1. **Why might the reporting application show outdated data?** The replica has not replayed the most recent committed changes.
2. **Why has replay fallen behind?** The replica may not keep pace with primary WAL generation.
3. **Why does the primary generate so much WAL?** It is processing repeated write operations.
4. **Why does this affect application reporting?** The reporting application reads asynchronously replicated data instead of the primary.
5. **How can the problem be prevented?** Monitor replication, optimize workloads, ensure sufficient replica capacity, and use the primary for consistency-sensitive reads.

### Important Investigation Note

A temporary lag spike does not necessarily indicate a broken replication system.

If primary and replica records match and replication is streaming normally, document that observation.

Do not claim that a replica outage or measurable lag occurred unless the actual monitoring data supports it.

---

## 16. Remediation — Restore Replication Freshness

### Step 1 — Stop Additional Write Workload

Stop launching new synthetic write batches.

If the workload is still running, use `Ctrl+C` in its terminal.

### Step 2 — Verify Primary Data

Inside EC2:

```bash
psql \
  "host=$PRIMARY_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "
  SELECT
      COUNT(*) AS total_rows,
      MAX(batch_no) AS latest_batch
  FROM replication_test;
  "
```

### Step 3 — Verify Replica Data

```bash
psql \
  "host=$REPLICA_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "
  SELECT
      COUNT(*) AS total_rows,
      MAX(batch_no) AS latest_batch
  FROM replication_test;
  "
```

Compare the results.

### Step 4 — Check Replication Status

On the primary:

```sql
SELECT
    application_name,
    state,
    sync_state
FROM pg_stat_replication;
```

Expected: replication remains active.

### Step 5 — Create Verification Marker

On the primary:

```sql
CREATE TABLE IF NOT EXISTS lab09_markers (
    marker_id INTEGER PRIMARY KEY,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

```sql
INSERT INTO lab09_markers (marker_id, message)
VALUES (1, 'Read replica recovery verified');
```

### Step 6 — Verify Marker on Replica

On the replica:

```sql
SELECT * FROM lab09_markers;
```

Expected: the marker becomes visible after replication catches up.

### Step 7 — Verify CloudWatch Recovery

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table \
  --region "$AWS_REGION"
```

Expected during catch-up: lag decreases toward normal values.

### Remediation Summary

| Check | During Workload | After Recovery |
|---|---|---|
| Primary Writes | Heavy test activity | Stopped |
| WAL Generation | Increased | Reduced |
| ReplicaLag | May increase | Recovers during active replication |
| Primary Data | Latest | Latest |
| Replica Data | May lag | Matches primary |
| Replication Connection | Streaming | Streaming |
| Verification Marker | Primary first | Visible on replica |

---

## 17. Monitoring and Production Best Practices

### Configure CloudWatch Alarm

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Lab09 RDS replica lag above 120 seconds" \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 120 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --region "$AWS_REGION"
```

Verify:

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold}' \
  --output table \
  --region "$AWS_REGION"
```

This is a demonstration threshold without SNS notifications.

Because reported lag can increase during periods of inactivity, production alarms should correlate the metric with replication health and recent write activity.

### Production Troubleshooting Checklist

1. Verify primary and replica status.
2. Confirm the replication relationship.
3. Investigate `ReplicaLag`.
4. Inspect primary write activity.
5. Check primary and replica CPU usage.
6. Check storage I/O and available memory.
7. Review `pg_stat_replication`.
8. Investigate replication slots.
9. Compare WAL receive and replay positions.
10. Look for long-running database transactions.
11. Compare recent committed data.
12. Determine whether lag is temporary or sustained.
13. Reduce unnecessary workload pressure.
14. Increase replica capacity when justified.
15. Verify data freshness after remediation.
16. Configure appropriate monitoring.

### Read Replica vs. Multi-AZ

| Feature | Read Replica | Traditional Multi-AZ DB Instance |
|---|---|---|
| Primary Purpose | Read scaling | High availability |
| Replication | Asynchronous | Synchronous |
| Read Queries on Secondary | Supported | Not supported on standby |
| Replica Endpoint | Separate | Not applicable |
| Writes | Primary | Primary |
| Automatic HA Failover | Not the primary purpose | Supported |
| Potential Stale Reads | Yes | Standby not used for application reads |

### Production Recommendations

- Use read replicas for workloads that tolerate some replication delay.
- Send read-after-write operations requiring immediate consistency to the primary.
- Monitor WAL retention and storage.
- Avoid unnecessary long-running replica queries.
- Evaluate replica CPU and storage performance.
- Avoid relying on `ReplicaLag` alone.
- Use actual data-freshness checks when diagnosing application reports.
- Keep databases private and use TLS connections.
- Do not promote replicas without an operational reason.

---

## 18. AWS Resource Cleanup

**Warning:** These commands permanently delete both disposable RDS databases and the supporting AWS infrastructure.

### Step 1 — Remove Temporary Authentication

Inside EC2:

```bash
rm -f "$HOME/.pgpass-lab09"

unset PGPASSFILE
```

Exit Systems Manager:

```bash
exit
```

### Step 2 — Verify Ownership

From WSL:

```bash
for DB in "$REPLICA_DB" "$PRIMARY_DB"; do
  ARN=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB" \
    --query 'DBInstances[0].DBInstanceArn' \
    --output text \
    --region "$AWS_REGION")

  aws rds list-tags-for-resource \
    --resource-name "$ARN" \
    --region "$AWS_REGION"
done
```

Confirm both instances belong to `RDS-Troubleshooting-Lab09`.

### Step 3 — Delete CloudWatch Alarm

```bash
aws cloudwatch delete-alarms \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Read Replica First

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$REPLICA_DB" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

Wait:

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$REPLICA_DB" \
  --region "$AWS_REGION"
```

### Step 5 — Delete Primary

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$PRIMARY_DB" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

Wait:

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$PRIMARY_DB" \
  --region "$AWS_REGION"
```

### Step 6 — Delete DB Subnet Group

```bash
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION"
```

### Step 7 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `DeleteOnTermination=true`.

### Step 8 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete IAM Resources

Verify the role tag:

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Delete:

```bash
aws iam detach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$EC2_ROLE_NAME"
```

### Step 10 — Verify ENI Cleanup

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the EC2 and RDS network interfaces are gone.

### Step 11 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Public Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$PUBLIC_RT_ASSOC" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$DB_SUBNET_A" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$DB_SUBNET_B" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Verify Cleanup

```bash
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, 'cloud-rds-lab09')].DBInstanceIdentifier" \
  --output json \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Also confirm that EC2, EBS, IAM, security groups, and the DB subnet group were removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Primary RDS | Deleted |
| Read Replica | Deleted |
| DB Subnet Group | Deleted |
| EC2 Client | Terminated |
| Root EBS Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Client SG | Deleted |
| Database SG | Deleted |
| CloudWatch Alarm | Deleted |
| Public Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is an Amazon RDS read replica?

A separate database instance that asynchronously receives data changes from a source database and is typically used to serve read requests.

### Q2. What causes replication lag?

High write volume, insufficient replica resources, storage bottlenecks, network problems, or replay delays can cause replication lag.

### Q3. What is ReplicaLag?

A CloudWatch metric reporting the replica's estimated replication delay relative to the source database.

### Q4. What is PostgreSQL WAL?

Write-Ahead Logging records database changes for durability, recovery, and replication.

### Q5. What is pg_stat_replication?

A PostgreSQL system view that displays information about replication connections from the primary database.

### Q6. What is a replication slot?

A PostgreSQL mechanism used to track replication consumption and retain WAL needed by replication consumers.

### Q7. Why are RDS read replicas read-only?

A normal read replica replays changes received from its source and does not accept ordinary application writes.

### Q8. What is the difference between synchronous and asynchronous replication?

Synchronous replication coordinates transaction durability with a standby before acknowledging commits, while asynchronous replication allows primary commits before the replica confirms receipt or replay.

### Q9. Can a read replica contain stale data?

Yes. Asynchronous replication can temporarily delay visibility of committed changes.

### Q10. Does high ReplicaLag always indicate a real data-freshness problem?

No. PostgreSQL's time-based metric can increase while the primary is idle. Confirm with WAL information and application data.

### Q11. How can a Cloud Engineer reduce persistent replica lag?

Investigate the source write workload, replica CPU, memory, I/O, replication connectivity, long-running transactions, and capacity requirements.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL primary database and created a read replica using AWS CLI.

I verified the replication relationship and confirmed that the primary accepted writes while the replica was read-only.

I generated a controlled synthetic write workload to produce PostgreSQL WAL activity.

I investigated the replication process using Amazon CloudWatch `ReplicaLag`, PostgreSQL `pg_stat_replication`, replication slots, and WAL receive and replay positions.

I compared primary and replica record counts to determine whether the replica contained the latest committed data.

After the workload completed, I verified the replica caught up and confirmed that a new transaction marker appeared on both databases.

I also configured a CloudWatch alarm and reviewed strategies for preventing sustained replication lag.

---

## 20. Repository Structure

```text
aws-rds-troubleshooting-labs/
│
├── README.md
│
├── 01-rds-connection-timeout/
├── 02-database-authentication-failure/
├── 03-rds-security-group-misconfiguration/
├── 04-rds-public-private-connectivity/
├── 05-rds-storage-full/
├── 06-rds-high-database-cpu/
├── 07-rds-too-many-database-connections/
├── 08-rds-dns-endpoint-investigation/
│
└── 09-rds-read-replica-lag/
    ├── README.md
    ├── ec2-trust-policy.json
    └── generate-replication-load.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete replication incident, investigation, remediation, and cleanup |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager |
| `generate-replication-load.sh` | Generates a controlled PostgreSQL write workload |

Do not commit AWS credentials, PostgreSQL passwords, or temporary `.pgpass` files.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how Amazon RDS PostgreSQL read replicas work and why asynchronous replication can produce temporary differences between the primary and replica.

We created a real read replica and investigated its relationship with the primary database.

We generated a controlled workload that produced PostgreSQL WAL records and examined replication progress.

We used CloudWatch and PostgreSQL system views to investigate replica lag, WAL positions, and database performance.

We also verified application-level consistency by comparing committed records and checking a final transaction marker.

The exercise demonstrates why Cloud Engineers must distinguish database availability from data freshness.

**Key Lesson:** An available read replica is not necessarily fully synchronized with its primary. Always investigate replication status and verify application data before declaring a replication incident resolved.

### Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Read replica provisioning
- Primary-replica architecture
- Asynchronous replication
- PostgreSQL WAL
- `pg_stat_replication`
- `pg_replication_slots`
- WAL LSN investigation
- `pg_last_wal_receive_lsn()`
- `pg_last_wal_replay_lsn()`
- `pg_last_xact_replay_timestamp()`
- CloudWatch `ReplicaLag`
- `OldestReplicationSlotLag`
- Database consistency verification
- Replication performance monitoring
- Bash scripting
- AWS Systems Manager
- Private VPC networking
- Root cause analysis
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-009 |
| Problem | RDS Read Replica Lag |
| Primary | Available |
| Read Replica | Available |
| Replication | Asynchronous |
| Workload | Controlled synthetic writes |
| Primary Writes | Successful |
| Replica Writes | Rejected |
| ReplicaLag | Investigated |
| WAL Positions | Investigated |
| Replica Catch-Up | Verified |
| Data Consistency | Latest records match |
| Monitoring | CloudWatch alarm configured |
| RDS Public Access | Disabled |
| Cleanup | Temporary infrastructure removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Successful RDS replica troubleshooting requires understanding PostgreSQL WAL, replication lag metrics, primary and replica resource utilization, and application-level data consistency. Monitoring actual replication progress helps prevent stale-read problems and unnecessary infrastructure changes.