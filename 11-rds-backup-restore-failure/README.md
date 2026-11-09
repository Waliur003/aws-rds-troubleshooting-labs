# Lab 11 — RDS Database Backup and Restore Failure

## Overview

This lab demonstrates how to troubleshoot Amazon RDS PostgreSQL backup and restoration failures using AWS CLI, Linux, PostgreSQL, and AWS Systems Manager.

We deploy a private PostgreSQL database, create synthetic customer-order records, and take a manual RDS snapshot.

Next, we simulate accidental data loss by deleting the `customer_orders` table from the source database.

During recovery, we intentionally reproduce two AWS errors:

- `DBSnapshotNotFound` — attempting to restore from a nonexistent snapshot.
- `DBInstanceAlreadyExists` — attempting to restore a snapshot using an existing database instance identifier.

We investigate the errors, identify the valid snapshot, and restore it to a new private RDS database instance.

After restoration, we verify the recovered records, confirm that the restored database accepts writes, and compare the restored database against the original source.

We also investigate automated backups, point-in-time recovery (PITR), Recovery Point Objective (RPO), and Recovery Time Objective (RTO).

Finally, we delete all disposable AWS infrastructure, including the manual snapshot.

**Troubleshooting workflow:**

Infrastructure Setup → Source Database → Test Data → Manual Snapshot → Accidental Data Loss → Restore Errors → Investigation → Successful Restore → Data Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-011 |
| Difficulty | Advanced |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager |
| Database Engine | PostgreSQL |
| Source Database | `cloud-rds-lab11-primary` |
| Restored Database | `cloud-rds-lab11-restored` |
| Snapshot | `cloud-rds-lab11-snapshot` |
| Invalid Snapshot | `cloud-rds-lab11-missing-snapshot` |
| DB Instance Class | `db.t4g.micro` |
| Storage | 20 GiB gp3 |
| Storage Encryption | Enabled |
| Automated Backup Retention | 1 day |
| Database Name | `labdb` |
| Database User | `labadmin` |
| PostgreSQL Port | TCP `5432` |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| VPC | `10.201.0.0/16` |
| Public Subnet | `10.201.1.0/24` |
| Private Subnet A | `10.201.2.0/24` |
| Private Subnet B | `10.201.3.0/24` |
| Data Loss Simulation | `DROP TABLE customer_orders` |
| Restore Failure 1 | Missing snapshot |
| Restore Failure 2 | Duplicate DB identifier |
| Recovery Method | Manual snapshot restoration |
| Additional Investigation | PITR |
| Verification | Recovered records and SQL writes |

---

## 2. Production Incident Scenario

### Incident Description

A company operates a customer-order application using Amazon RDS PostgreSQL.

The database contains order records used by the application.

During a maintenance operation, an engineer accidentally deletes the `customer_orders` table.

The RDS instance remains available, but queries that depend on the deleted table fail.

Example:

```text
ERROR: relation "customer_orders" does not exist
```

The operations team decides to recover from an existing manual RDS snapshot.

However, the first restore attempt fails because the engineer specifies an incorrect snapshot identifier.

The second attempt uses the correct snapshot but attempts to restore it using the identifier of the existing source database.

That request also fails.

The Cloud Engineer must investigate both restoration errors, choose a valid snapshot, create a new database instance, and verify the recovered records.

### Incident Symptoms

- Source RDS instance remains available.
- PostgreSQL authentication works.
- Application table is missing.
- Customer-order queries fail.
- A valid manual snapshot exists.
- An invalid snapshot identifier causes a restore error.
- An existing DB identifier causes another restore error.
- A correctly configured restore creates a new database.
- Recovered customer records become accessible.

### Business Impact

- Customer order history becomes unavailable.
- Database-dependent application features fail.
- Users may receive application errors.
- Reporting and transaction workflows are interrupted.
- Incorrect restoration procedures increase recovery time.
- Selecting the wrong recovery point can cause data loss.
- Delayed recovery may affect business operations.

### Objective

Recover deleted application data from a verified RDS manual snapshot while identifying and resolving common restoration configuration errors.

---

## 3. AWS Architecture

### Infrastructure

```text
                    AWS Region
                     us-east-1
                         |
                         v
                    Amazon VPC
                  10.201.0.0/16
                         |
             -------------------------
             |                       |
             v                       v
        Public Subnet           Private Subnets
             |                       |
             v                       v
         EC2 Client              Source RDS
         SSM + psql              PostgreSQL
             |                       |
             |                       v
             |                customer_orders
             |                       |
             |                       v
             |                 Manual Snapshot
             |                       |
             |                Accidental Deletion
             |                       |
             |                       v
             |                 Restore Request
             |                       |
             |             --------------------
             |             |                  |
             |             v                  v
             |        Invalid Restore    Valid Restore
             |             |                  |
             |             v                  v
             |          AWS Error       New RDS Instance
             |                                |
             +--------------------------------+
                                              |
                                              v
                                        Recovered Data
```

### Data Recovery Flow

```text
Source PostgreSQL
        |
        v
Create Customer Orders
        |
        v
Manual RDS Snapshot
        |
        v
Accidental DROP TABLE
        |
        v
Restore Attempt
        |
        v
Restore Error Investigation
        |
        v
Identify Correct Snapshot
        |
        v
Create New DB Instance
        |
        v
Verify Recovered Orders
        |
        v
Recovery Confirmed
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.201.0.0/16` |
| Public Subnet | `10.201.1.0/24` |
| Private Subnet A | `10.201.2.0/24` |
| Private Subnet B | `10.201.3.0/24` |
| EC2 Internet Access | Internet Gateway |
| Database Network | Private subnets |
| EC2 Security Group | `cloud-rds-lab11-client-sg` |
| Database Security Group | `cloud-rds-lab11-db-sg` |
| Database Access | TCP 5432 from EC2 security group |
| EC2 Management | Systems Manager |
| Database Public Access | Disabled |

---

## 4. Understanding RDS Backups and Restoration

### Manual Snapshots

A manual RDS snapshot captures a database instance recovery point.

Manual snapshots remain available until explicitly deleted.

Example:

```bash
aws rds create-db-snapshot \
  --db-instance-identifier cloud-rds-lab11-primary \
  --db-snapshot-identifier cloud-rds-lab11-snapshot
```

### Automated Backups

Amazon RDS can automatically back up database instances when backup retention is enabled.

Automated backups support point-in-time recovery within the available backup window.

### Snapshot Restoration

An RDS snapshot restores to a new database instance.

The restore process does not directly replace the original source database.

The restored DB receives its own identifier and endpoint.

### Point-in-Time Recovery

PITR allows restoration to a supported timestamp within the automated backup recovery window.

This can help recover data before an accidental deletion or destructive application change.

### RPO

Recovery Point Objective represents the maximum acceptable data loss measured in time.

### RTO

Recovery Time Objective represents the maximum acceptable time required to restore service.

### Backup and Restore Error Types

| Error | Meaning |
|---|---|
| `DBSnapshotNotFound` | Snapshot identifier is not found or accessible |
| `DBInstanceAlreadyExists` | Target DB identifier already exists |
| `InvalidDBSnapshotState` | Snapshot is not in a usable state |
| `InvalidParameterCombination` | Restore settings are incompatible |
| KMS access errors | Required encryption key is unavailable or access is denied |
| `DBSubnetGroupNotFoundFault` | Specified DB subnet group does not exist |
| Invalid security group | Specified network security configuration is invalid |

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Amazon RDS permissions
- EC2 permissions
- VPC permissions
- IAM permissions
- Systems Manager access
- PostgreSQL client
- Git and GitHub

### Safety Rules

- Use only disposable RDS databases.
- Never execute `DROP TABLE` against production.
- Verify the manual snapshot is available before deleting data.
- Use synthetic customer records.
- Keep RDS private.
- Restrict database access to the EC2 security group.
- Do not commit PostgreSQL credentials.
- Do not overwrite existing AWS resources.
- Verify restored data before deleting the original source.
- Delete the manual snapshot after the lab to avoid ongoing charges.

### Cost Warning

This exercise temporarily uses two billable RDS database instances, an EC2 instance, and a manual snapshot.

The optional PITR exercise creates another billable RDS instance.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in WSL Ubuntu:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab11"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export SOURCE_DB="cloud-rds-lab11-primary"
export RESTORED_DB="cloud-rds-lab11-restored"

export SNAPSHOT_ID="cloud-rds-lab11-snapshot"
export INVALID_SNAPSHOT="cloud-rds-lab11-missing-snapshot"

export DB_SUBNET_GROUP="cloud-rds-lab11-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_CLASS="db.t4g.micro"

export EC2_NAME="cloud-rds-lab11-client"
export EC2_ROLE_NAME="cloud-rds-lab11-ssm-role"
export PROFILE_NAME="cloud-rds-lab11-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab11-client-sg"
export DB_SG_NAME="cloud-rds-lab11-db-sg"
```

### Step 2 — Verify AWS Access

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Verify DB Instance Class

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class "$DB_CLASS" \
  --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass,Version:EngineVersion}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Check Existing Resources

```bash
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, 'cloud-rds-lab11')].[DBInstanceIdentifier,DBInstanceStatus]" \
  --output table \
  --region "$AWS_REGION"
```

```bash
aws rds describe-db-snapshots \
  --snapshot-type manual \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier, 'cloud-rds-lab11')].[DBSnapshotIdentifier,Status]" \
  --output table \
  --region "$AWS_REGION"
```

Do not create duplicate resources.

---

## 7. Create VPC and Subnets

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.201.0.0/16" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab11-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --cidr-block "10.201.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab11-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.201.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab11-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.201.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab11-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab11-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Create Public Routing

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab11-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
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

```bash
export PUBLIC_RT_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

The RDS subnets remain private.

---

## 8. Create Security Groups

### Step 1 — EC2 Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab11 EC2 troubleshooting client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — RDS Security Group

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab11 private RDS instances" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Authorize PostgreSQL

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: TCP port 5432 authorized only from the EC2 client security group.

---

## 9. Deploy EC2 Troubleshooting Client

### Step 1 — Create IAM Trust Policy

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

Allow IAM propagation.

### Step 4 — Retrieve AMI

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

### Step 7 — Connect with Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo dnf install -y postgresql15 bind-utils nmap-ncat
```

Verify:

```bash
psql --version
command -v nc
```

Exit EC2:

```bash
exit
```

---

## 10. Deploy the Source RDS Database

### Step 1 — Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab11 backup restore private subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Enter Temporary Password

```bash
read -rsp "Enter disposable RDS password: " DB_PASSWORD
echo
```

Use a strong unique password.

In production, prefer RDS-managed credentials through AWS Secrets Manager. The following disposable-lab command passes the password as an argument.

### Step 3 — Create Database

```bash
aws rds create-db-instance \
  --db-instance-identifier "$SOURCE_DB" \
  --engine postgres \
  --db-instance-class "$DB_CLASS" \
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

### Step 4 — Wait for RDS

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$SOURCE_DB" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Backups

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$SOURCE_DB" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Backups:BackupRetentionPeriod,Public:PubliclyAccessible,Encrypted:StorageEncrypted}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Backups: 1
Public: False
Encrypted: True
```

### Step 6 — Retrieve Endpoint

```bash
export SOURCE_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$SOURCE_DB" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$SOURCE_ENDPOINT"
```

---

## 11. Create Test Customer Data

### Step 1 — Connect to EC2

From WSL:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export SOURCE_ENDPOINT="YOUR_ACTUAL_SOURCE_RDS_ENDPOINT"
```

Replace the placeholder with the actual endpoint.

### Step 2 — Verify Connectivity

```bash
getent ahostsv4 "$SOURCE_ENDPOINT"

nc -vz -w 5 "$SOURCE_ENDPOINT" 5432
```

### Step 3 — Connect to PostgreSQL

```bash
psql \
  "host=$SOURCE_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 4 — Create Test Table

```sql
CREATE TABLE customer_orders (
    order_id INTEGER PRIMARY KEY,
    customer_name VARCHAR(100) NOT NULL,
    product VARCHAR(100) NOT NULL,
    amount NUMERIC(10,2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

### Step 5 — Insert Customer Records

```sql
INSERT INTO customer_orders
(order_id, customer_name, product, amount)
VALUES
(101, 'Customer A', 'Laptop', 899.99),
(102, 'Customer B', 'Keyboard', 79.99),
(103, 'Customer C', 'Monitor', 249.99),
(104, 'Customer D', 'Mouse', 39.99),
(105, 'Customer E', 'Headphones', 129.99);
```

### Step 6 — Verify Records

```sql
SELECT *
FROM customer_orders
ORDER BY order_id;
```

Expected: five rows.

### Step 7 — Verify Data Summary

```sql
SELECT
    COUNT(*) AS total_orders,
    SUM(amount) AS total_amount
FROM customer_orders;
```

Expected:

```text
total_orders | total_amount
-------------+-------------
5            | 1399.95
```

Record the baseline for the later restore verification.

Exit:

```text
\q
```

---

## 12. Create Manual Snapshot and Simulate Data Loss

### Step 1 — Create Snapshot

From WSL:

```bash
aws rds create-db-snapshot \
  --db-instance-identifier "$SOURCE_DB" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Check Snapshot Status

```bash
aws rds describe-db-snapshots \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --query 'DBSnapshots[0].{ID:DBSnapshotIdentifier,Status:Status,Source:DBInstanceIdentifier}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Wait for Snapshot

```bash
aws rds wait db-snapshot-available \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Snapshot

```bash
aws rds describe-db-snapshots \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --query 'DBSnapshots[0].{ID:DBSnapshotIdentifier,Status:Status,Created:SnapshotCreateTime,Encrypted:Encrypted}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Encrypted: True
```

Do not proceed with data deletion until the snapshot is available.

### Step 5 — Connect to Source DB

Inside EC2:

```bash
psql \
  "host=$SOURCE_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -W
```

Verify:

```sql
SELECT COUNT(*) FROM customer_orders;
```

Expected: 5.

### Step 6 — Simulate Accidental Deletion

**Run only against the disposable Lab 11 database.**

```sql
DROP TABLE customer_orders;
```

Expected:

```text
DROP TABLE
```

### Step 7 — Reproduce Application Error

```sql
SELECT * FROM customer_orders;
```

Expected:

```text
ERROR: relation "customer_orders" does not exist
```

Exit:

```text
\q
```

### Fault Injection Summary

| Component | Expected Result |
|---|---|
| Source RDS | Available |
| Snapshot | Available |
| PostgreSQL Login | Successful |
| Customer Table | Deleted |
| Application Query | Failed |
| Snapshot Recovery | Required |

---

## 13. Troubleshooting Restore Failure 1 — Missing Snapshot

### Step 1 — Attempt Invalid Restore

From WSL:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$RESTORED_DB" \
  --db-snapshot-identifier "$INVALID_SNAPSHOT" \
  --db-instance-class "$DB_CLASS" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --no-publicly-accessible \
  --no-multi-az \
  --region "$AWS_REGION"
```

Expected error:

```text
DBSnapshotNotFound
```

### Step 2 — Investigate Snapshot Inventory

```bash
aws rds describe-db-snapshots \
  --snapshot-type manual \
  --query 'DBSnapshots[].{ID:DBSnapshotIdentifier,Source:DBInstanceIdentifier,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Verify Valid Snapshot

```bash
aws rds describe-db-snapshots \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --query 'DBSnapshots[0].{ID:DBSnapshotIdentifier,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
ID: cloud-rds-lab11-snapshot
Status: available
```

### Root Cause

The restore command referenced a snapshot identifier that did not exist.

### Remediation

Use the correct snapshot identifier and verify the snapshot's status before requesting restoration.

---

## 14. Troubleshooting Restore Failure 2 — Duplicate Identifier

### Step 1 — Attempt Restore Over Existing Instance

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$SOURCE_DB" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --db-instance-class "$DB_CLASS" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --no-publicly-accessible \
  --no-multi-az \
  --region "$AWS_REGION"
```

Expected error:

```text
DBInstanceAlreadyExists
```

### Step 2 — Investigate DB Identifiers

```bash
aws rds describe-db-instances \
  --query 'DBInstances[].{Name:DBInstanceIdentifier,Status:DBInstanceStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm `cloud-rds-lab11-primary` already exists.

### Root Cause

RDS snapshot restoration requires a new target instance identifier that is not already in use.

### Remediation

Use a new identifier such as:

```text
cloud-rds-lab11-restored
```

### Troubleshooting Comparison

| Fault | Expected Error | Root Cause | Fix |
|---|---|---|---|
| Wrong Snapshot | DBSnapshotNotFound | Incorrect snapshot identifier | Use existing snapshot |
| Duplicate DB Identifier | DBInstanceAlreadyExists | Target DB already exists | Choose unique identifier |

---

## 15. Successful Snapshot Restoration

### Step 1 — Restore Using Correct Values

From WSL:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "$RESTORED_DB" \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --db-instance-class "$DB_CLASS" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --no-publicly-accessible \
  --no-multi-az \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Check Restore Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$RESTORED_DB" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected during provisioning:

```text
Status: creating
```

### Step 3 — Wait for Restoration

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$RESTORED_DB" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Restored Configuration

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$RESTORED_DB" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Public:PubliclyAccessible,Encrypted:StorageEncrypted,VPC:DBSubnetGroup.VpcId}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `available`, encrypted, private, and in the correct VPC.

### Step 5 — Retrieve Restored Endpoint

```bash
export RESTORED_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$RESTORED_DB" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$RESTORED_ENDPOINT"
```

### Step 6 — Verify Networking

Inside EC2:

```bash
export RESTORED_ENDPOINT="YOUR_ACTUAL_RESTORED_RDS_ENDPOINT"
```

```bash
getent ahostsv4 "$RESTORED_ENDPOINT"

nc -vz -w 5 "$RESTORED_ENDPOINT" 5432
```

### Step 7 — Connect to Restored DB

```bash
psql \
  "host=$RESTORED_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -W
```

### Step 8 — Verify Recovered Records

```sql
SELECT *
FROM customer_orders
ORDER BY order_id;
```

Expected: five original customer orders.

```sql
SELECT
    COUNT(*) AS total_orders,
    SUM(amount) AS total_amount
FROM customer_orders;
```

Expected:

```text
5 | 1399.95
```

### Step 9 — Verify New Writes

```sql
INSERT INTO customer_orders
(order_id, customer_name, product, amount)
VALUES
(106, 'Recovery Test', 'USB Hub', 24.99);
```

Verify:

```sql
SELECT COUNT(*) FROM customer_orders;
```

Expected: six rows after the additional test insert.

Exit:

```text
\q
```

### Recovery Summary

| Check | Source | Restored DB |
|---|---|---|
| Instance Available | Yes | Yes |
| Customer Table | Missing | Present |
| Original Five Orders | Missing | Recovered |
| Additional Test Row | Absent | Present |
| PostgreSQL Login | Working | Working |
| Endpoint | Original | New |
| Public Access | Disabled | Disabled |

---

## 16. Point-in-Time Recovery Investigation

### Step 1 — Verify Backup Retention

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$SOURCE_DB" \
  --query 'DBInstances[0].{Retention:BackupRetentionPeriod,LatestRestorableTime:LatestRestorableTime}' \
  --output table \
  --region "$AWS_REGION"
```

Expected backup retention: one day.

### Step 2 — Inspect Automated Backups

```bash
aws rds describe-db-instance-automated-backups \
  --db-instance-identifier "$SOURCE_DB" \
  --output json \
  --region "$AWS_REGION"
```

### Step 3 — Inspect Recovery Window

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$SOURCE_DB" \
  --query 'DBInstances[0].LatestRestorableTime' \
  --output text \
  --region "$AWS_REGION"
```

If the result is `None`, a restorable time is not yet available.

### Step 4 — Understand PITR

Point-in-time recovery can restore to a supported time within the available automated-backup recovery window.

For accidental deletion, the selected time should be before the destructive operation.

### Optional PITR Command

This creates a third billable database instance and is optional:

```bash
export PITR_DB="cloud-rds-lab11-pitr"
```

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$SOURCE_DB" \
  --target-db-instance-identifier "$PITR_DB" \
  --use-latest-restorable-time \
  --db-instance-class "$DB_CLASS" \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --no-publicly-accessible \
  --no-multi-az \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

**Important:** The latest restorable time may be after the table deletion, so this command does not guarantee that it recovers the missing table.

A production recovery would select and validate an appropriate restorable timestamp before the deletion.

### Snapshot vs. PITR

| Feature | Manual Snapshot | PITR |
|---|---|---|
| Recovery Point | Snapshot creation point | Selected supported timestamp |
| Backup Source | Manual snapshot | Automated backups and transaction logs |
| Creates New DB | Yes | Yes |
| Replaces Existing DB | No | No |
| Manual Retention | Until deleted | Not applicable |
| Backup Retention Window | Snapshot remains separately available | Required |
| Best Use | Known recovery point | Time-specific recovery |

---

## README.md — Sections 17–21

Append these final sections after Section 16 of the same README.

<WritingBlock id="11643" variant="document">## 17. Root Cause Analysis

### Primary Incident Root Cause

The `customer_orders` table was accidentally deleted from the source PostgreSQL database.

The RDS instance remained available, but application queries failed because the required relation no longer existed.

A valid manual snapshot contained the original table and its five customer-order records.

### Restore Failure 1 — Invalid Snapshot

The recovery command referenced `cloud-rds-lab11-missing-snapshot`, which did not exist.

AWS rejected the request with a snapshot-not-found error.

**Remediation:** List available snapshots and use the correct identifier.

### Restore Failure 2 — Existing Database Identifier

The recovery command attempted to create the restored DB using the existing source identifier `cloud-rds-lab11-primary`.

AWS rejected the request because an RDS instance already used that identifier.

**Remediation:** Use `cloud-rds-lab11-restored` as the new target identifier.

### Root Cause Flow

```text
Accidental DROP TABLE
          |
          v
Customer Data Missing
          |
          v
Application Query Failure
          |
          v
Restore Attempt
          |
     -----------------------
     |                     |
     v                     v
Wrong Snapshot       Duplicate DB ID
     |                     |
     v                     v
Restore Rejected      Restore Rejected
     |                     |
     +----------+----------+
                |
                v
      Inspect RDS Resources
                |
                v
      Select Valid Snapshot
                |
                v
      Choose New DB Identifier
                |
                v
      Restore RDS Instance
                |
                v
       Verify Recovered Data
```

### Five Whys

1. **Why did the application lose access to customer orders?** The table was deleted.
2. **Why couldn't PostgreSQL return the order records?** The required database relation no longer existed.
3. **Why did the first recovery attempt fail?** An incorrect snapshot identifier was specified.
4. **Why did the second attempt fail?** The restore target used an existing DB identifier.
5. **How was recovery achieved?** The engineer used a valid available snapshot and restored it to a new private RDS instance.

### Production Prevention

- Restrict permissions for destructive SQL operations.
- Use reviewed database migration procedures.
- Maintain automated backups.
- Create manual snapshots before major changes.
- Test database restoration regularly.
- Verify recovery point selection.
- Use unique restore identifiers.
- Define RPO and RTO requirements.
- Review KMS permissions for encrypted snapshot restoration.
- Validate restored data before application cutover.

---

## 18. AWS Resource Cleanup

**Warning:** These commands permanently delete the disposable Lab 11 databases, snapshot, and supporting AWS resources.

### Step 1 — Exit PostgreSQL and EC2

Exit PostgreSQL:

```text
\q
```

Exit the SSM session:

```bash
exit
```

### Step 2 — Verify Resource Ownership

From WSL:

```bash
for DB in "$SOURCE_DB" "$RESTORED_DB"; do
  ARN=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB" \
    --query 'DBInstances[0].DBInstanceArn' \
    --output text \
    --region "$AWS_REGION")

  echo "Checking $DB"

  aws rds list-tags-for-resource \
    --resource-name "$ARN" \
    --region "$AWS_REGION"
done
```

Confirm both resources have the tag:

```text
Project=RDS-Troubleshooting-Lab11
```

### Step 3 — Delete Optional PITR Instance

Only run this if the optional PITR instance was created and its ownership has been verified:

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$PITR_DB" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$PITR_DB" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Restored Database

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$RESTORED_DB" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$RESTORED_DB" \
  --region "$AWS_REGION"
```

### Step 5 — Delete Source Database

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$SOURCE_DB" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$SOURCE_DB" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Manual Snapshot Ownership

```bash
export SNAPSHOT_ARN=$(aws rds describe-db-snapshots \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --query 'DBSnapshots[0].DBSnapshotArn' \
  --output text \
  --region "$AWS_REGION")
```

```bash
aws rds list-tags-for-resource \
  --resource-name "$SNAPSHOT_ARN" \
  --region "$AWS_REGION"
```

### Step 7 — Delete Manual Snapshot

```bash
aws rds delete-db-snapshot \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --region "$AWS_REGION"
```

Manual snapshots can continue incurring storage charges until deleted.

### Step 8 — Delete DB Subnet Group

```bash
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION"
```

### Step 9 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `DeleteOnTermination=true`.

### Step 10 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete IAM Resources

Verify ownership:

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

### Step 12 — Verify Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until EC2 and RDS network interfaces have been removed.

### Step 13 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Route Table

```bash
aws ec2 disassociate-route-table \
  --association-id "$PUBLIC_RT_ASSOC" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete Subnets

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

### Step 16 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 17 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 18 — Verify Cleanup

Check RDS:

```bash
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, 'cloud-rds-lab11')].DBInstanceIdentifier" \
  --output json \
  --region "$AWS_REGION"
```

Check manual snapshots:

```bash
aws rds describe-db-snapshots \
  --snapshot-type manual \
  --query "DBSnapshots[?contains(DBSnapshotIdentifier, 'cloud-rds-lab11')].DBSnapshotIdentifier" \
  --output json \
  --region "$AWS_REGION"
```

Check VPC:

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected: empty arrays.

Also verify there are no remaining lab EC2 instances, EBS volumes, IAM roles, or DB subnet groups.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Source RDS | Deleted |
| Restored RDS | Deleted |
| Optional PITR RDS | Deleted, if created |
| Manual Snapshot | Deleted |
| DB Subnet Group | Deleted |
| EC2 Client | Terminated |
| Root EBS Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Client SG | Deleted |
| Database SG | Deleted |
| Public Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is an RDS manual snapshot?

A user-initiated backup of an RDS DB instance retained until explicitly deleted.

### Q2. What is the difference between automated backups and manual snapshots?

Automated backups have a configurable retention period and support PITR. Manual snapshots are explicitly created and retained until deletion.

### Q3. Can you restore an RDS snapshot over an existing DB instance?

No. A snapshot restore creates a new DB instance with a unique identifier.

### Q4. What causes DBSnapshotNotFound?

The specified snapshot does not exist or cannot be accessed in the requested context.

### Q5. What causes DBInstanceAlreadyExists?

A database already uses the requested restore target identifier.

### Q6. What is point-in-time recovery?

PITR restores a database to a supported timestamp within the automated backup recovery window.

### Q7. What is RPO?

Recovery Point Objective describes the maximum acceptable data loss, measured in time.

### Q8. What is RTO?

Recovery Time Objective describes the maximum acceptable time needed to restore service.

### Q9. Why should you verify data after restoration?

A restored RDS instance can be available even when the selected snapshot does not contain the required application data.

### Q10. Does restoring a snapshot automatically switch application traffic?

No. The restored database receives a new endpoint, and a recovery plan must address application connectivity or selective data recovery.

### Q11. What security checks are important after RDS restoration?

Verify subnet placement, public accessibility, security groups, encryption, database credentials, and application permissions.

### Q12. How would you explain this lab in an interview?

I deployed a private RDS PostgreSQL database and an EC2 troubleshooting client inside the same VPC.

I created five synthetic customer-order records and captured a manual RDS snapshot.

I simulated accidental data loss by deleting the customer-orders table.

I reproduced two AWS restore errors: an invalid snapshot identifier and a duplicate target database identifier.

I investigated the snapshot inventory, verified the correct snapshot, and restored the database to a new RDS instance.

After restoration, I verified that the original customer orders were recovered and confirmed the restored database accepted new writes.

I also reviewed automated backups, point-in-time recovery, RPO, RTO, and secure database restoration practices.

---

## 20. Repository Structure

```text
aws-rds-troubleshooting-labs/
│
├── README.md
├── 01-rds-connection-timeout/
├── 02-database-authentication-failure/
├── 03-rds-security-group-misconfiguration/
├── 04-rds-public-private-connectivity/
├── 05-rds-storage-full/
├── 06-rds-high-database-cpu/
├── 07-rds-too-many-database-connections/
├── 08-rds-dns-endpoint-investigation/
├── 09-rds-read-replica-lag/
├── 10-rds-multi-az-failover/
│
└── 11-rds-backup-restore-failure/
    ├── README.md
    ├── ec2-trust-policy.json
    └── create-test-data.sql
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident, troubleshooting, restore, and cleanup documentation |
| `ec2-trust-policy.json` | IAM trust policy for the EC2 Systems Manager role |
| `create-test-data.sql` | PostgreSQL schema and sample customer-order records |

Never commit database passwords, AWS credentials, or private authentication files.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how Amazon RDS PostgreSQL data can be recovered from a manual snapshot after accidental deletion.

We reproduced restoration failures caused by incorrect snapshot identifiers and existing database identifiers.

We investigated available snapshots, identified the correct recovery point, and restored a private PostgreSQL instance.

We verified that the original customer-order records were present in the restored database.

We also confirmed that a snapshot restore creates a separate RDS instance rather than directly repairing the original database.

The exercise introduced automated backups, PITR, RPO, RTO, and the importance of validating recovered data before application cutover.

**Key Lesson:** Database recovery is not complete when the restored RDS instance becomes available. A Cloud Engineer must verify that the correct data was recovered, confirm secure connectivity, and plan how the application will resume service.

### Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Manual RDS snapshots
- Automated backups
- Snapshot status investigation
- Snapshot restoration
- `DBSnapshotNotFound`
- `DBInstanceAlreadyExists`
- PostgreSQL data recovery
- SQL data validation
- Point-in-time recovery
- Recovery Point Objective
- Recovery Time Objective
- AWS KMS encryption concepts
- VPC security groups
- Private database networking
- AWS Systems Manager
- Root cause analysis
- Disaster recovery planning
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-011 |
| Problem | Database Backup and Restore Failure |
| Database Engine | PostgreSQL |
| Source Instance | Available |
| Manual Snapshot | Available before recovery |
| Data Loss | Customer-orders table deleted |
| Fault 1 | Missing snapshot |
| Fault 2 | Duplicate DB identifier |
| Correct Restore | New database instance created |
| Original Records | Five recovered |
| Post-Restore Write | Successful |
| Source Database | Remains unchanged by restoration |
| Restored Database | Private and encrypted |
| PITR | Investigated |
| Cleanup | Temporary infrastructure removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Effective RDS disaster recovery requires verified backups, correct restore configuration, secure infrastructure, measurable recovery objectives, and application-level data validation.