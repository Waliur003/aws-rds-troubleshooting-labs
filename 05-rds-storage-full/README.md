# Lab 05 — RDS Storage Full

## Overview

This lab demonstrates how to investigate and remediate storage capacity problems in Amazon RDS PostgreSQL.

We deploy a private PostgreSQL database with 20 GiB of gp3 storage and an Amazon Linux 2023 EC2 troubleshooting client inside the same VPC.

The database initially operates normally. We then generate synthetic application data to increase PostgreSQL table storage consumption.

As the database grows, the Amazon CloudWatch `FreeStorageSpace` metric decreases.

In a production environment, uncontrolled database growth can eventually exhaust allocated storage, cause PostgreSQL write failures, and result in an RDS `storage-full` state.

We investigate the database instance status, allocated storage, CloudWatch metrics, PostgreSQL database sizes, and individual table sizes using AWS CLI and SQL.

After identifying database growth as the source of storage pressure, we increase allocated storage from 20 GiB to 25 GiB, verify successful database operations, and configure monitoring to help prevent future incidents.

This lab uses controlled storage growth rather than intentionally exhausting the database completely. Therefore, a `storage-full` status or write failure is a possible production symptom, not a guaranteed observation from the exercise.

**Troubleshooting workflow:**

Infrastructure Setup → Storage Consumption → Symptoms → Investigation → Root Cause Analysis → Remediation → Verification → Monitoring → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-005 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager, CloudWatch |
| Database Engine | PostgreSQL |
| RDS Instance Class | `db.t4g.micro` |
| Initial RDS Storage | 20 GiB gp3 |
| Remediation Storage | 25 GiB gp3 |
| RDS Deployment | Private, Single-AZ |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| Database Name | `labdb` |
| Database Username | `labadmin` |
| Database Port | TCP `5432` |
| VPC CIDR | `10.194.0.0/16` |
| Fault Injection | Controlled database table growth |
| Expected Symptom | Decreasing free storage |
| Potential Production Error | No space left on device |
| CloudWatch Metric | `FreeStorageSpace` |
| Root Cause | Data growth with insufficient provisioned capacity |
| Remediation | Increase allocated database storage |
| Prevention | CloudWatch alarms and storage autoscaling |
| Verification | RDS status, CloudWatch metrics, SQL reads and writes |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts its application on Amazon EC2 and stores application data in an Amazon RDS PostgreSQL database.

The database was originally provisioned with 20 GiB of storage.

As the application grows, it continuously inserts new records into PostgreSQL.

The engineering team did not configure an appropriate storage monitoring alarm or storage autoscaling.

Over time, available database storage decreases.

Eventually, the database may run out of space and start rejecting write operations.

Example PostgreSQL error:

```text
ERROR: could not extend file:
No space left on device
```

The RDS instance may also report:

```text
DBInstanceStatus: storage-full
```

The Cloud Engineer investigates the incident and identifies the database's increasing storage consumption.

The engineer must determine whether the problem is caused by insufficient storage, database growth, or another infrastructure issue.

After confirming storage pressure, the engineer expands the allocated RDS storage and verifies database operations.

### Incident Symptoms

- RDS PostgreSQL initially operates normally.
- Application data continues to grow.
- Database table sizes increase.
- CloudWatch `FreeStorageSpace` decreases.
- RDS allocated storage remains fixed.
- Storage autoscaling is initially disabled.
- PostgreSQL writes may fail if storage becomes exhausted.
- RDS may enter `storage-full`.
- Application transactions may be affected.
- Database access may become unavailable during a severe storage incident.

### Business Impact

- Application write operations may fail.
- Customer transactions may be interrupted.
- Database-dependent services may become unavailable.
- Data ingestion pipelines may stop.
- Application errors may increase.
- Database recovery may require emergency infrastructure changes.
- Business operations may be delayed.

### Objective

Investigate RDS PostgreSQL storage consumption, identify storage pressure, increase database capacity, verify successful read/write operations, and implement monitoring to reduce future storage-related incidents.

---

## 3. AWS Architecture

### Infrastructure

```text
                      Amazon VPC
                    10.194.0.0/16
                           |
          ------------------------------------
          |                                  |
          v                                  v
     Public Subnet                     Private Subnets
    10.194.1.0/24                     10.194.2.0/24
          |                           10.194.3.0/24
          v                                  |
       EC2 Client                            v
    Amazon Linux 2023                 RDS PostgreSQL
          |                                  |
          v                                  v
       Client SG                         Database SG
          |                                  |
          +------------- TCP 5432 -----------+
                                             |
                                             v
                                      Database Storage
                                         20 GiB
                                             |
                                             v
                                         CloudWatch
                                      FreeStorageSpace
```

### Broken Architecture

```text
                Application
                    |
                    v
             PostgreSQL Writes
                    |
                    v
              Database Tables
                    |
                    v
               Data Growth
                    |
                    v
          Allocated Storage: 20 GiB
                    |
                    v
           Free Storage Decreases
                    |
                    v
             Storage Pressure
                    |
                    v
         Potential Storage Exhaustion
                    |
                    v
             PostgreSQL Errors
                    |
                    v
         Application Write Failures
```

### Recovered Architecture

```text
                RDS PostgreSQL
                       |
                       v
               Storage Pressure
                       |
                       v
              AWS CLI Investigation
                       |
                       v
                 CloudWatch
               FreeStorageSpace
                       |
                       v
             Identify Data Growth
                       |
                       v
              Increase Storage
                20 GiB → 25 GiB
                       |
                       v
                Storage Available
                       |
                       v
              PostgreSQL Writes
                       |
                       v
               Successful Queries
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.194.0.0/16` |
| Public Subnet | `10.194.1.0/24` |
| Private Subnet A | `10.194.2.0/24` |
| Private Subnet B | `10.194.3.0/24` |
| Public Routing | Internet Gateway |
| Private Routing | VPC local route |
| Client SG | `cloud-rds-lab05-client-sg` |
| Database SG | `cloud-rds-lab05-db-sg` |
| PostgreSQL Access | Client SG → Database SG |
| RDS Public Access | Disabled |
| EC2 Management | Systems Manager |

---

## 4. Understanding RDS Storage Management

Amazon RDS uses allocated storage to store database files, indexes, transaction logs, and other database-related data.

Storage availability is important because PostgreSQL needs sufficient disk space to perform database operations.

### Allocated Storage

Allocated storage represents the provisioned database storage capacity.

Example:

```text
AllocatedStorage: 20 GiB
```

This value does not represent the remaining available space.

### FreeStorageSpace

Amazon CloudWatch provides the `FreeStorageSpace` metric.

This metric represents the amount of available storage space in bytes.

For example:

```text
FreeStorageSpace = 5368709120 bytes
```

This represents approximately 5 GiB of available storage.

A declining metric may indicate increasing database storage consumption.

### Storage Full

A storage-full condition occurs when RDS no longer has sufficient available storage for necessary database operations.

Possible consequences include:

- Failed PostgreSQL inserts.
- Failed database updates.
- Transaction failures.
- Database unavailability.
- RDS instance entering `storage-full`.

### Important Storage Concepts

| Concept | Explanation |
|---|---|
| AllocatedStorage | Provisioned RDS storage capacity |
| FreeStorageSpace | Available database storage |
| gp3 | General Purpose SSD storage |
| Storage Autoscaling | Automatically increases storage when supported conditions are met |
| Storage Optimization | Background RDS storage modification process |
| PostgreSQL Table Size | Storage occupied by table data |
| PostgreSQL Index Size | Storage occupied by database indexes |
| Transaction Logs | PostgreSQL write-ahead logging data |
| CloudWatch Alarm | Monitors metric thresholds |
| Storage Expansion | Increases allocated database capacity |

**Important:** Database size and total RDS storage usage are not identical. RDS storage also includes database logs, transaction files, indexes, and other internal data.

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
- AWS Systems Manager
- PostgreSQL client
- Git and GitHub

### Security Guidelines

- Use a disposable PostgreSQL database.
- Do not run the workload against production.
- Keep the database private.
- Do not expose TCP 5432 to `0.0.0.0/0`.
- Use Systems Manager for EC2 administration.
- Use synthetic test data only.
- Avoid committing database credentials.
- Stop the data generator if storage becomes critically low.
- Monitor RDS health throughout the exercise.
- Delete temporary AWS resources after completion.

### Cost Warning

RDS instances, allocated database storage, EC2 instances, EBS volumes, public IPv4 addresses, and CloudWatch alarms may incur charges.

Increasing allocated RDS storage can increase ongoing costs.

Storage expansion is generally not reversible through a simple in-place reduction.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab05"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab05-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab05-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab05-client"
export EC2_ROLE_NAME="cloud-rds-lab05-ssm-role"
export PROFILE_NAME="cloud-rds-lab05-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab05-client-sg"
export DB_SG_NAME="cloud-rds-lab05-db-sg"

export ALARM_NAME="cloud-rds-lab05-low-storage"
```

### Step 2 — Verify AWS Access

```bash
aws sts get-caller-identity

aws --version
```

### Step 3 — Verify EC2 Availability

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Verify RDS Instance Class

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass,Version:EngineVersion}' \
  --output table \
  --region "$AWS_REGION"
```

Choose supported instance types and Availability Zones if necessary.

### Step 5 — Check Existing Resources

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='$DB_IDENTIFIER'].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" \
  --output table \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Avoid creating duplicate resources.

---

## 7. Create the AWS VPC

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.194.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab05-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
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
  --cidr-block "10.194.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab05-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.194.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab05-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.194.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab05-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab05-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Configure Public Routing

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab05-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Create the default route:

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

The database subnets remain private and inherit the VPC main route table.

---

## 8. Create Security Groups

### Step 1 — Create EC2 Client SG

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab05 EC2 client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create RDS SG

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab05 RDS PostgreSQL" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Authorize Private PostgreSQL Access

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: TCP 5432 from the EC2 client security group only.

---

## 9. Deploy EC2 Troubleshooting Client

### Step 1 — Create EC2 Trust Policy

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

Allow IAM propagation before launching EC2.

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
    "ResourceType=instance,Tags=[{Key=Name,Value=$EC2_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
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

Install PostgreSQL and networking utilities:

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

## 10. Create RDS PostgreSQL

### Step 1 — Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab05 private database subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Enter Temporary Password

```bash
read -rsp "Enter temporary RDS password: " DB_PASSWORD
echo
```

Use a strong password.

For a disposable lab, the following command uses a password argument. In production, prefer RDS-managed credentials and AWS Secrets Manager.

### Step 3 — Create RDS

```bash
aws rds create-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
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
  --backup-retention-period 0 \
  --no-deletion-protection \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

Remove the variable:

```bash
unset DB_PASSWORD
```

### Step 4 — Wait for RDS

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Initial Configuration

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Storage:AllocatedStorage,MaxStorage:MaxAllocatedStorage,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Storage: 20
Public: False
```

### Step 6 — Retrieve Endpoint

```bash
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$DB_ENDPOINT"
```

---

## 11. Fault Injection — Database Storage Growth

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export DB_ENDPOINT="YOUR_ACTUAL_RDS_ENDPOINT"
```

Replace the placeholder with the actual endpoint.

### Step 2 — Verify Connectivity

```bash
getent ahostsv4 "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful DNS resolution and TCP connectivity.

### Step 3 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 4 — Check Initial Database Size

```sql
SELECT
    pg_size_pretty(pg_database_size('labdb'))
    AS database_size;
```

### Step 5 — Create Test Table

Enable PostgreSQL cryptographic functions:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

Create the table:

```sql
CREATE TABLE lab05_storage_test (
    id BIGSERIAL PRIMARY KEY,
    payload BYTEA NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### Step 6 — Insert Initial Records

```sql
INSERT INTO lab05_storage_test (payload)
SELECT gen_random_bytes(1024)
FROM generate_series(1, 10000);
```

Verify:

```sql
SELECT COUNT(*) FROM lab05_storage_test;
```

Expected: 10,000 rows.

### Step 7 — Check Table Size

```sql
SELECT
    pg_size_pretty(
        pg_total_relation_size('lab05_storage_test')
    ) AS table_size;
```

### Step 8 — Generate Additional Storage Consumption

Exit PostgreSQL:

```text
\q
```

Create `load-storage.sh` inside EC2:

```bash
cat > load-storage.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?Set DB_ENDPOINT first}"

for batch in $(seq 1 10); do
    echo "Starting batch $batch"

    psql \
      "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
      -v ON_ERROR_STOP=1 \
      -c "
      INSERT INTO lab05_storage_test (payload)
      SELECT gen_random_bytes(1024)
      FROM generate_series(1, 100000);
      "

    echo "Completed batch $batch"
done
EOF

chmod +x load-storage.sh
```

Run:

```bash
./load-storage.sh
```

This creates approximately 1 GiB of synthetic payload data, plus database overhead.

**Safety:** Monitor free storage during testing. Do not continue generating records when remaining storage approaches the 2 GiB safety threshold.

### Step 9 — Verify Table Growth

Connect again:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -W
```

Execute:

```sql
SELECT
    COUNT(*) AS total_records,
    pg_size_pretty(
        pg_total_relation_size('lab05_storage_test')
    ) AS table_size
FROM lab05_storage_test;
```

Expected: a larger table and increased record count.

### Fault Injection Summary

| Check | Expected Result |
|---|---|
| RDS | Available during controlled testing |
| Initial Storage | 20 GiB |
| PostgreSQL Table | Growing |
| CloudWatch FreeStorageSpace | Decreasing |
| Storage Autoscaling | Disabled |
| Database Writes | Consuming storage |
| Potential Production Failure | Storage exhaustion |
| Root Cause | Uncontrolled data growth |

---

## 12. Troubleshooting Investigation

### Check 1 — Verify RDS Status

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Storage:AllocatedStorage}' \
  --output table \
  --region "$AWS_REGION"
```

Expected for the controlled test: `available`.

A fully exhausted production database may show `storage-full`.

### Check 2 — Check CloudWatch Free Storage

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Minimum \
  --output json \
  --region "$AWS_REGION"
```

Finding: free storage should decrease after the data-generation workload.

### Check 3 — Identify Large PostgreSQL Tables

Inside PostgreSQL:

```sql
SELECT
    relname AS table_name,
    pg_size_pretty(
        pg_total_relation_size(relid)
    ) AS total_size
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC;
```

Expected: `lab05_storage_test` is the largest user table.

### Check 4 — Check Database Sizes

```sql
SELECT
    datname,
    pg_size_pretty(
        pg_database_size(datname)
    ) AS database_size
FROM pg_database
WHERE datallowconn = true;
```

### Check 5 — Verify Allocated Storage

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{AllocatedStorage:AllocatedStorage,StorageType:StorageType,MaxAllocatedStorage:MaxAllocatedStorage}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 6 — Inspect RDS Events

```bash
aws rds describe-events \
  --source-type db-instance \
  --source-identifier "$DB_IDENTIFIER" \
  --duration 60 \
  --query 'Events[].{Time:Date,Message:Message}' \
  --output table \
  --region "$AWS_REGION"
```

Investigate any storage-related events.

### Check 7 — Verify EC2-to-RDS Network Connectivity

Inside EC2:

```bash
getent ahostsv4 "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

If RDS is still healthy, networking should remain functional.

### Investigation Summary

| Investigation | Finding |
|---|---|
| RDS Instance | Initially available |
| RDS Allocated Storage | 20 GiB |
| Storage Autoscaling | Disabled |
| PostgreSQL Table | Growing |
| FreeStorageSpace | Decreasing |
| Security Group | Correct |
| DNS | Working |
| VPC Routing | Correct |
| Database Connectivity | Initially working |
| Root Cause | Data growth with insufficient capacity |

---

## 13. Root Cause Analysis

### Root Cause

The PostgreSQL database consumes increasing amounts of storage because of ongoing application-data growth.

The RDS instance has a fixed allocation of 20 GiB and storage autoscaling is disabled.

Without sufficient available storage, PostgreSQL may eventually fail to write additional data.

In this controlled lab, we demonstrate the growth and resulting reduction in free storage before complete exhaustion.

### Technical Explanation

Amazon RDS requires available storage for table data, indexes, database logs, and internal operations.

When application writes continue, database files consume more allocated space.

If storage capacity is not expanded or managed, the available storage decreases.

Eventually, the database may become unable to perform write operations.

### Root Cause Flow

```text
Application Inserts
        |
        v
PostgreSQL Table Growth
        |
        v
Storage Consumption Increases
        |
        v
Allocated Storage Fixed at 20 GiB
        |
        v
FreeStorageSpace Decreases
        |
        v
Storage Pressure
        |
        v
Potential Storage Exhaustion
        |
        v
Database Write Failures
```

### Five Whys

1. **Why can PostgreSQL writes fail?** Available database storage may become exhausted.
2. **Why does available storage decrease?** Application data continues to grow.
3. **Why doesn't storage increase automatically?** Storage autoscaling was not enabled.
4. **Why wasn't the issue prevented?** Storage monitoring and capacity planning were insufficient.
5. **How can the problem be prevented?** Configure monitoring, storage autoscaling, and data-retention policies.

### Prevention

- Monitor database storage continuously.
- Configure low-storage CloudWatch alarms.
- Enable storage autoscaling where appropriate.
- Review table growth and index sizes.
- Configure data-retention policies.
- Use capacity forecasting.
- Investigate abnormal write workloads.
- Regularly review database operational health.

---

## 14. Remediation — Increase RDS Storage

### Step 1 — Stop the Workload

Stop generating additional records.

If the script is still running:

```text
Ctrl+C
```

Do not continue consuming storage during remediation.

### Step 2 — Verify Current Allocation

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Storage:AllocatedStorage}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Increase Storage

```bash
aws rds modify-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --allocated-storage 25 \
  --apply-immediately \
  --region "$AWS_REGION"
```

This increases the provisioned storage from 20 GiB to 25 GiB.

### Step 4 — Monitor Modification

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,AllocatedGiB:AllocatedStorage,Pending:PendingModifiedValues}' \
  --output json \
  --region "$AWS_REGION"
```

Possible states include:

```text
modifying
storage-optimization
available
```

Storage optimization may continue after the new capacity becomes available.

### Step 5 — Verify Storage

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,AllocatedGiB:AllocatedStorage}' \
  --output table \
  --region "$AWS_REGION"
```

Expected allocated storage:

```text
25 GiB
```

### Step 6 — Verify FreeStorageSpace

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average \
  --output json \
  --region "$AWS_REGION"
```

Expected: more available space after storage expansion completes, assuming no substantial new storage consumption.

### Step 7 — Verify PostgreSQL Connectivity

Inside EC2:

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful connection.

### Step 8 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -W
```

### Step 9 — Verify Existing Records

```sql
SELECT COUNT(*) FROM lab05_storage_test;
```

### Step 10 — Verify Database Write

```sql
INSERT INTO lab05_storage_test (payload)
VALUES (gen_random_bytes(1024));
```

Expected:

```text
INSERT 0 1
```

### Step 11 — Verify Latest Records

```sql
SELECT
    id,
    octet_length(payload) AS payload_bytes
FROM lab05_storage_test
ORDER BY id DESC
LIMIT 5;
```

### Remediation Summary

| Check | Before Fix | After Fix |
|---|---|---|
| Allocated Storage | 20 GiB | 25 GiB |
| FreeStorageSpace | Decreasing | Increased after expansion |
| Storage Capacity | Limited | Expanded |
| PostgreSQL Reads | At risk if fully exhausted | Successful |
| PostgreSQL Writes | At risk if fully exhausted | Successful |
| RDS Public Access | Disabled | Disabled |
| Monitoring | Investigation only | Alarm configured |

---

## 15. Final Verification

### Verify RDS Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Storage:AllocatedStorage,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Storage: 25
Public: False
```

A `storage-optimization` state may remain temporarily while AWS finishes background storage work.

### Verify CloudWatch Free Storage

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Average \
  --output json \
  --region "$AWS_REGION"
```

### Verify SQL Operations

Inside PostgreSQL:

```sql
SELECT COUNT(*) FROM lab05_storage_test;
```

```sql
SELECT
    pg_size_pretty(
        pg_database_size('labdb')
    ) AS database_size;
```

### Create CloudWatch Low-Storage Alarm

From WSL:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Lab05 RDS free storage below 2 GiB" \
  --namespace AWS/RDS \
  --metric-name FreeStorageSpace \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --statistic Average \
  --period 300 \
  --evaluation-periods 2 \
  --threshold 2147483648 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data missing \
  --region "$AWS_REGION"
```

This creates an alarm with a 2 GiB threshold.

No SNS notification is configured for this exercise.

### Verify Alarm

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold}' \
  --output table \
  --region "$AWS_REGION"
```

### Review Storage Autoscaling

Once the storage modification and optimization finish, optionally enable storage autoscaling:

```bash
aws rds modify-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --max-allocated-storage 50 \
  --apply-immediately \
  --region "$AWS_REGION"
```

This configures a maximum autoscaling storage threshold of 50 GiB.

Storage autoscaling does not guarantee immediate protection from extremely rapid storage consumption.

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| RDS PostgreSQL | Available |
| Allocated Storage | 25 GiB |
| FreeStorageSpace | Increased |
| EC2-to-RDS Network | Working |
| PostgreSQL Login | Successful |
| Database Reads | Successful |
| Database Writes | Successful |
| CloudWatch Metric | Available |
| Low-Storage Alarm | Created |
| RDS Public Access | Disabled |
| Incident | Storage pressure resolved |

---

## 16. Production Best Practices

### RDS Storage Troubleshooting Checklist

1. Identify the affected RDS instance.
2. Verify the current instance status.
3. Check allocated storage.
4. Review CloudWatch `FreeStorageSpace`.
5. Investigate recent storage trends.
6. Identify large PostgreSQL databases.
7. Inspect table and index sizes.
8. Review abnormal application write activity.
9. Check RDS events.
10. Determine whether storage autoscaling is enabled.
11. Stop unnecessary data-generation workloads.
12. Increase allocated storage when appropriate.
13. Monitor storage modification.
14. Verify database connectivity.
15. Test PostgreSQL reads and writes.
16. Configure CloudWatch alarms.
17. Review autoscaling and retention policies.

### Storage Recommendations

- Use proactive storage monitoring.
- Maintain appropriate free-storage headroom.
- Configure CloudWatch alarms with useful thresholds.
- Enable autoscaling where supported and appropriate.
- Forecast storage growth.
- Regularly review large tables and indexes.
- Avoid unnecessary database logging.
- Use data retention and archival policies.
- Monitor PostgreSQL write-ahead logging.
- Do not assume database size equals total RDS storage usage.
- Avoid waiting for complete storage exhaustion.
- Test storage recovery procedures using disposable environments.

### Key Cloud Security Lesson

Database availability is part of cloud security.

Even when networking, authentication, and encryption are correctly configured, insufficient storage can make a database unavailable.

Capacity monitoring and operational recovery are important parts of maintaining secure and reliable cloud infrastructure.

---

## 17. Cleanup

**Warning:** These commands permanently delete the disposable Lab 05 database and associated infrastructure.

### Step 1 — Exit PostgreSQL and EC2

If inside PostgreSQL:

```text
\q
```

Exit Systems Manager:

```bash
exit
```

### Step 2 — Verify RDS Ownership

From WSL:

```bash
export DB_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBInstanceArn' \
  --output text \
  --region "$AWS_REGION")
```

Check tags:

```bash
aws rds list-tags-for-resource \
  --resource-name "$DB_ARN" \
  --region "$AWS_REGION"
```

Confirm:

```text
Project=RDS-Troubleshooting-Lab05
```

### Step 3 — Delete CloudWatch Alarm

```bash
aws cloudwatch delete-alarms \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

### Step 4 — Delete RDS

Only delete the disposable database after confirming its identity.

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

Wait:

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 5 — Delete DB Subnet Group

```bash
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION"
```

### Step 6 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm that `DeleteOnTermination=true`.

### Step 7 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete IAM Resources

Verify IAM role ownership:

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

### Step 9 — Verify Network Interface Cleanup

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the EC2 and RDS network interfaces are removed.

### Step 10 — Delete Security Groups

Delete the database security group first:

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete Public Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$PUBLIC_RT_ASSOC" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Subnets

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

### Step 13 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Verify Cleanup

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='$DB_IDENTIFIER'].DBInstanceIdentifier" \
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

Also verify the EC2 instance, root EBS volume, IAM role, instance profile, and CloudWatch alarm were removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| RDS Database | Deleted |
| DB Subnet Group | Deleted |
| EC2 Client | Terminated |
| EC2 Root EBS | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Client SG | Deleted |
| Database SG | Deleted |
| CloudWatch Alarm | Deleted |
| Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 18. Interview Questions and Answers

### Q1. What happens when Amazon RDS runs out of storage?

Database write operations may fail, and the instance can enter the `storage-full` state. Depending on the severity and engine behavior, database availability may also be affected.

### Q2. Which CloudWatch metric monitors available RDS storage?

The `FreeStorageSpace` metric.

### Q3. How do you check allocated RDS storage?

Use `aws rds describe-db-instances` and inspect the `AllocatedStorage` property.

### Q4. What is the difference between allocated storage and free storage?

Allocated storage represents provisioned database capacity. Free storage represents the currently available space.

### Q5. Can RDS storage be increased without recreating the database?

Yes. RDS supports increasing allocated storage through the AWS Console, CLI, and API.

### Q6. Can you reduce RDS allocated storage after increasing it?

Not through a normal in-place reduction. A migration or restoration strategy may be needed.

### Q7. What is RDS storage autoscaling?

It automatically increases database storage when supported storage thresholds and scaling conditions are met.

### Q8. Does storage autoscaling guarantee prevention of storage-full incidents?

No. Extremely rapid storage consumption, scaling limits, or storage optimization restrictions can prevent timely expansion.

### Q9. How do you identify large PostgreSQL tables?

Use PostgreSQL functions such as `pg_total_relation_size()` and `pg_size_pretty()`.

### Q10. What should you investigate when FreeStorageSpace decreases?

Investigate database growth, large tables, indexes, transaction logs, write activity, and available storage capacity.

### Q11. What should you verify after increasing RDS storage?

Verify allocated storage, the `FreeStorageSpace` metric, RDS status, PostgreSQL connectivity, and successful read/write queries.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL database with 20 GiB of gp3 storage and an EC2 troubleshooting client inside the same VPC.

I generated synthetic application data to increase database storage consumption.

I investigated PostgreSQL table sizes, allocated storage, CloudWatch `FreeStorageSpace`, and RDS instance status.

After identifying database growth as the source of storage pressure, I increased allocated storage from 20 GiB to 25 GiB.

I verified successful PostgreSQL connectivity and executed read/write queries to confirm that the database continued operating normally.

I also configured a low-storage CloudWatch alarm and reviewed storage autoscaling as a preventive measure.

Finally, I removed the temporary AWS resources to avoid unnecessary charges.

---

## 19. Repository Structure

```text
05-rds-storage-full/
├── README.md
├── ec2-trust-policy.json
└── load-storage.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident investigation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | EC2 IAM trust policy for Systems Manager access |
| `load-storage.sh` | Generates controlled PostgreSQL storage consumption |

The `load-storage.sh` file is created on EC2 during the exercise. Copy it into the repository only after reviewing it and removing any environment-specific information.

No database passwords or AWS credentials should be committed.

---

## 20. Lessons Learned

This lab demonstrates how database storage consumption can affect the reliability and availability of Amazon RDS PostgreSQL.

The database initially operated normally with 20 GiB of allocated storage.

As synthetic application data was inserted, PostgreSQL table sizes increased and available storage decreased.

We used AWS CLI, CloudWatch metrics, and PostgreSQL SQL queries to investigate storage consumption.

After identifying storage pressure, we increased allocated RDS storage to 25 GiB and verified successful database read/write operations.

We also configured a CloudWatch alarm and reviewed storage autoscaling to help prevent future storage incidents.

The exercise demonstrates storage pressure and recovery planning without requiring a complete database outage.

**Key Lesson:** A healthy database can become unavailable when storage consumption is not monitored. Proactive capacity monitoring, appropriate storage allocation, and recovery procedures are essential for reliable cloud operations.

---

## 21. Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Amazon EC2 administration
- Amazon VPC networking
- AWS Systems Manager
- RDS storage management
- RDS storage expansion
- CloudWatch metrics
- `FreeStorageSpace` monitoring
- CloudWatch alarms
- RDS storage autoscaling
- PostgreSQL table-size analysis
- PostgreSQL SQL queries
- Database troubleshooting
- Linux Bash scripting
- Database capacity planning
- Root cause analysis
- Production incident investigation
- Safe infrastructure cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-005 |
| Problem | RDS storage pressure |
| Database Engine | PostgreSQL |
| Database | labdb |
| Initial Storage | 20 GiB |
| Remediation Storage | 25 GiB |
| Fault Injection | Controlled synthetic data growth |
| Expected Symptom | Decreasing FreeStorageSpace |
| Actual Storage-Full Outage | Not required |
| Root Cause | Rapid data growth with fixed capacity |
| Remediation | Increase allocated storage |
| PostgreSQL Connectivity | Successful |
| Database Reads | Successful |
| Database Writes | Successful |
| CloudWatch Monitoring | Configured |
| Storage Alarm | Created |
| RDS Public Access | Disabled |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Storage pressure resolved |

**Key Takeaway:** Effective RDS troubleshooting requires monitoring database capacity, investigating storage consumption, and expanding storage before an outage occurs. Combining CloudWatch monitoring, PostgreSQL investigation, and storage-management practices helps maintain database availability and reliability.