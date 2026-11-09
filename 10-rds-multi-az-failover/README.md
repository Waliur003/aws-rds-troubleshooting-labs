# Lab 10 — RDS Multi-AZ Failover

## Overview

This lab demonstrates how to investigate and troubleshoot an Amazon RDS PostgreSQL Multi-AZ failover using AWS CLI, Linux, PostgreSQL, Amazon CloudWatch, and AWS Systems Manager.

We deploy a private Amazon RDS PostgreSQL database configured with Multi-AZ high availability and an EC2 troubleshooting instance in the same VPC.

Amazon RDS automatically maintains a synchronously replicated standby database in another Availability Zone.

We first verify normal database connectivity, record the original primary Availability Zone, and insert test records.

Next, we create a Bash monitoring script that continuously checks PostgreSQL connectivity and records DNS resolution, successful connections, and connection failures.

We intentionally trigger a Multi-AZ failover using the AWS CLI command `reboot-db-instance --force-failover`.

During the failover, existing database connections may be interrupted while RDS promotes the standby and updates the DNS mapping of the database endpoint.

We investigate the failover using RDS events, Availability Zone information, DNS records, PostgreSQL queries, and CloudWatch metrics.

After recovery, we verify that committed records remain available and the new primary accepts database writes.

Finally, we review production best practices for high availability, DNS caching, application reconnection, and resource cleanup.

**Troubleshooting workflow:**

Infrastructure Setup → Multi-AZ Deployment → Baseline Verification → Connection Monitoring → Forced Failover → Investigation → Root Cause Analysis → Recovery → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-010 |
| Difficulty | Advanced |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager, CloudWatch |
| Database Engine | PostgreSQL |
| DB Identifier | `cloud-rds-lab10-postgres` |
| RDS Class | `db.t4g.micro`, if Multi-AZ capable |
| Deployment | Traditional Multi-AZ DB instance |
| Storage | 20 GiB gp3 |
| Storage Encryption | Enabled |
| Automated Backups | 1 day |
| Database Name | `labdb` |
| Master Username | `labadmin` |
| Database Port | TCP `5432` |
| EC2 Instance | `t3.micro` |
| EC2 OS | Amazon Linux 2023 |
| VPC CIDR | `10.200.0.0/16` |
| Public Subnet | `10.200.1.0/24` |
| Private Subnet A | `10.200.2.0/24` |
| Private Subnet B | `10.200.3.0/24` |
| RDS Public Access | Disabled |
| Fault Injection | Forced Multi-AZ failover |
| Expected Error | Temporary connection interruption |
| Investigation | RDS events, DNS, primary AZ, client monitoring |
| Remediation | Automatic standby promotion and client reconnection |
| Verification | Committed data and new writes |
| Incident Status | Record after completing the lab |

---

## 2. Production Incident Scenario

### Incident Description

A company operates a customer-facing application using Amazon EC2 and Amazon RDS PostgreSQL.

The application stores customer records and transactions in a private PostgreSQL database.

To improve database availability, the company enables Multi-AZ deployment.

Amazon RDS maintains a primary database and a synchronously replicated standby in another Availability Zone.

One day, the application's database connections suddenly fail.

Customers experience temporary application errors, and some database queries cannot complete.

The Cloud Engineer investigates and discovers that the database has experienced a Multi-AZ failover.

During the failover, the original primary stops handling application connections.

Amazon RDS promotes the standby database and updates the DNS record behind the existing RDS endpoint.

Previously established PostgreSQL connections cannot continue automatically.

The application must establish new connections to the promoted primary.

### Incident Symptoms

- RDS enters a transitional state such as `rebooting`.
- Existing PostgreSQL sessions are interrupted.
- New connections may temporarily fail.
- Application queries may return errors or time out.
- RDS failover events appear.
- The active primary Availability Zone changes.
- The RDS endpoint hostname remains unchanged.
- DNS may resolve to a different database IP address.
- PostgreSQL connectivity returns after failover.
- Previously committed records remain available.

### Business Impact

- Temporary application unavailability.
- Failed database connections.
- Interrupted customer requests.
- Failed or uncertain application transactions.
- Increased application error rates.
- Reconnection delays caused by DNS caching.
- Temporary disruption to background jobs.

### Objective

Reproduce a controlled Multi-AZ failover, investigate application connection interruption, verify standby promotion, and confirm that PostgreSQL connectivity and committed data are restored.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                         AWS Region
                          us-east-1
                              |
                              v
                         Amazon VPC
                       10.200.0.0/16
                              |
            -----------------------------------
            |                                 |
            v                                 v
       Public Subnet                    Private Subnets
      10.200.1.0/24                    10.200.2.0/24
            |                          10.200.3.0/24
            v                                 |
       EC2 Client                            |
    Amazon Linux 2023                        |
            |                                 |
            v                                 v
       PostgreSQL                      RDS Endpoint
       Monitoring                            |
            |                                 v
            |                       -------------------
            |                       |                 |
            |                       v                 v
            |                  Primary RDS       Standby RDS
            |                   READ/WRITE       Not readable
            |                       |                 ^
            |                       |                 |
            +----- TCP 5432 --------+---- Synchronous +
                                          Replication
```

### Normal Operation

```text
Application
     |
     v
RDS DNS Endpoint
     |
     v
Primary Database — AZ A
     |
     v
Synchronous Replication
     |
     v
Standby Database — AZ B
```

### During Failover

```text
Forced Failover
      |
      v
Original Primary Interrupted
      |
      v
Existing Connections Lost
      |
      v
Standby Promoted to Primary
      |
      v
RDS Endpoint DNS Updated
      |
      v
New Connections Established
      |
      v
Application Recovery
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.200.0.0/16` |
| Public Subnet | `10.200.1.0/24` |
| Private Subnet A | `10.200.2.0/24` |
| Private Subnet B | `10.200.3.0/24` |
| EC2 Routing | Internet Gateway |
| Database Routing | VPC local route |
| EC2 Security Group | `cloud-rds-lab10-client-sg` |
| RDS Security Group | `cloud-rds-lab10-db-sg` |
| PostgreSQL Access | EC2 SG, TCP 5432 |
| RDS Public Access | Disabled |
| EC2 Access | Systems Manager |

---

## 4. Understanding Amazon RDS Multi-AZ

### What Is Multi-AZ?

Amazon RDS Multi-AZ is a high-availability deployment option.

For a traditional Multi-AZ DB instance, Amazon RDS maintains:

- One primary database.
- One standby database in a different Availability Zone.
- Synchronous replication between primary and standby.
- Automatic failover when supported failure conditions occur.

### Primary Database

The primary accepts application reads and writes.

Example:

```sql
SELECT * FROM failover_test;
```

```sql
INSERT INTO failover_test (id, message)
VALUES (3, 'Post-failover write');
```

### Standby Database

In a traditional Multi-AZ DB instance deployment, the standby is not available for application read queries.

It exists primarily to support high availability.

### Synchronous Replication

The primary and standby coordinate database changes so that the standby maintains a consistent copy of committed data.

This helps protect committed transactions during failover.

### Automatic Failover

Amazon RDS can initiate failover when supported infrastructure or database failure conditions occur.

It promotes the standby and redirects future application connections through the existing database endpoint.

### Forced Failover

A Cloud Engineer can intentionally test failover by running:

```bash
aws rds reboot-db-instance \
  --db-instance-identifier cloud-rds-lab10-postgres \
  --force-failover \
  --region us-east-1
```

This operation causes a temporary database interruption.

### DNS Behavior

During failover:

- The RDS endpoint hostname normally stays the same.
- AWS updates its DNS mapping to the promoted database host.
- Existing TCP sessions must reconnect.
- DNS caching can delay application recovery.

### Multi-AZ vs. Read Replica

| Feature | Multi-AZ DB Instance | Read Replica |
|---|---|---|
| Main Purpose | High availability | Read scaling |
| Replication | Synchronous | Asynchronous |
| Standby/Replica Readable | No | Yes |
| Automatic Failover | Yes | Not as standard read-scaling behavior |
| Application Writes | Primary | Source primary |
| Separate Reader Endpoint | No | Yes |
| Temporary Connection Interruption | Possible during failover | Depends on source/replica events |

**Important:** This lab uses a traditional Multi-AZ DB instance, not a Multi-AZ DB cluster.

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
- CloudWatch permissions
- PostgreSQL client
- Git and GitHub

### Safety Rules

- Use a disposable database.
- Do not trigger failover on production systems.
- Stop application write activity before planned forced failover.
- Keep RDS private.
- Use Systems Manager instead of public SSH.
- Do not expose PostgreSQL to the internet.
- Avoid hardcoded RDS private IP addresses.
- Do not commit database passwords.
- Use an encrypted RDS instance.
- Preserve baseline records for verification.
- Record actual failover measurements.
- Delete temporary resources.

### Cost Warning

Traditional Multi-AZ RDS deployments have additional standby-related charges compared with Single-AZ databases.

Charges may also apply for EC2, EBS, storage, public IPv4 addresses, and monitoring.

Check AWS pricing and remove the infrastructure after the experiment.

---

## 6. Prepare the Environment

### Step 1 — Configure Environment Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab10"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab10-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab10-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_CLASS="db.t4g.micro"

export EC2_NAME="cloud-rds-lab10-client"
export EC2_ROLE_NAME="cloud-rds-lab10-ssm-role"
export PROFILE_NAME="cloud-rds-lab10-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab10-client-sg"
export DB_SG_NAME="cloud-rds-lab10-db-sg"

export ALARM_NAME="cloud-rds-lab10-low-connections"
```

### Step 2 — Verify AWS Credentials

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Verify Multi-AZ Instance Class Support

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class "$DB_CLASS" \
  --query 'OrderableDBInstanceOptions[].{Version:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZCapable}' \
  --output table \
  --region "$AWS_REGION"
```

Use an engine version and instance class that support traditional Multi-AZ deployment.

### Step 4 — Verify EC2 Availability

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 5 — Check Existing Resources

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='$DB_IDENTIFIER'].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" \
  --output table \
  --region "$AWS_REGION"
```

Avoid duplicate resources.

---

## 7. Create AWS VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.200.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab10-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --cidr-block "10.200.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab10-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.200.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab10-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.200.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab10-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab10-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab10-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

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

The two RDS subnets remain private.

---

## 8. Create Security Groups

### Step 1 — Create Client SG

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab10 EC2 troubleshooting client" \
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
  --description "Lab10 Multi-AZ PostgreSQL" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Allow PostgreSQL Traffic

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Security Group Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: PostgreSQL TCP 5432 allowed from the EC2 client security group only.

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
sudo dnf install -y postgresql15 bind-utils nmap-ncat
```

Verify:

```bash
psql --version
command -v dig
command -v nc
```

Exit:

```bash
exit
```

---

## 10. Deploy Multi-AZ RDS PostgreSQL

### Step 1 — Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab10 Multi-AZ private subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Subnets

```bash
aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --query 'DBSubnetGroups[0].Subnets[].{Subnet:SubnetIdentifier,AZ:SubnetAvailabilityZone.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: two different Availability Zones.

### Step 3 — Enter Temporary Password

```bash
read -rsp "Enter disposable RDS password: " DB_PASSWORD
echo
```

Use a strong, unique password.

The following disposable-lab CLI command passes the password as an argument. In production, prefer RDS-managed credentials through Secrets Manager.

### Step 4 — Create Multi-AZ Database

```bash
aws rds create-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
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
  --multi-az \
  --backup-retention-period 1 \
  --no-deletion-protection \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

Remove the password variable:

```bash
unset DB_PASSWORD
```

### Step 5 — Wait for Database

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Multi-AZ Configuration

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,PrimaryAZ:AvailabilityZone,Public:PubliclyAccessible,Class:DBInstanceClass}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
MultiAZ: True
Public: False
```

### Step 7 — Record Original Primary AZ

```bash
export ORIGINAL_AZ=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].AvailabilityZone' \
  --output text \
  --region "$AWS_REGION")

echo "$ORIGINAL_AZ"
```

### Step 8 — Retrieve Endpoint

```bash
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$DB_ENDPOINT"
```

The hostname is generated by AWS.

---

## 11. Baseline PostgreSQL Verification

### Step 1 — Connect to EC2

From WSL:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export DB_ENDPOINT="YOUR_ACTUAL_RDS_ENDPOINT"
```

Replace the placeholder with the actual RDS endpoint.

### Step 2 — Verify DNS

```bash
dig +short "$DB_ENDPOINT"

getent ahostsv4 "$DB_ENDPOINT"
```

Record the initial resolved address:

```bash
export ORIGINAL_DB_IP=$(dig +short A "$DB_ENDPOINT" \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | tail -n 1)

echo "$ORIGINAL_DB_IP"
```

### Step 3 — Verify TCP

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful connection.

### Step 4 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 5 — Verify Primary Status

```sql
SELECT pg_is_in_recovery();
```

Expected:

```text
f
```

### Step 6 — Create Test Table

```sql
CREATE TABLE failover_test (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

### Step 7 — Insert Test Records

```sql
INSERT INTO failover_test (id, message)
VALUES
(1, 'Before Multi-AZ failover'),
(2, 'Committed baseline record');
```

Verify:

```sql
SELECT * FROM failover_test ORDER BY id;
```

Expected: two committed records.

### Step 8 — Record PostgreSQL Information

```sql
SELECT
    inet_server_addr() AS server_ip,
    inet_server_port() AS server_port,
    pg_postmaster_start_time() AS postgres_start_time;
```

Record the values.

Exit:

```text
\q
```

### Baseline Verification

| Check | Expected Result |
|---|---|
| RDS Status | Available |
| Multi-AZ | True |
| Primary AZ | Recorded |
| Endpoint | Valid |
| DNS | Working |
| TCP 5432 | Working |
| PostgreSQL Login | Successful |
| PostgreSQL Writable | Yes |
| Committed Records | 2 |
| Public Accessibility | False |

---

## 12. Fault Injection — Forced Multi-AZ Failover

### Step 1 — Configure Temporary Authentication

Inside EC2:

```bash
read -rsp "Enter temporary RDS password: " DB_PASSWORD
echo
```

Create a temporary PostgreSQL password file:

```bash
export PGPASSFILE="$HOME/.pgpass-lab10"

umask 077

ESCAPED_PASSWORD=$(printf '%s' "$DB_PASSWORD" \
  | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')

printf '%s:5432:labdb:labadmin:%s\n' \
  "$DB_ENDPOINT" "$ESCAPED_PASSWORD" > "$PGPASSFILE"

chmod 600 "$PGPASSFILE"

unset DB_PASSWORD ESCAPED_PASSWORD
```

Test:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "SELECT 1;"
```

### Step 2 — Create Connection Monitoring Script

Save as `monitor-failover.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?DB_ENDPOINT is required}"
: "${PGPASSFILE:?PGPASSFILE is required}"

LOG_FILE="${1:-$HOME/lab10-failover.log}"
MAX_SECONDS=600

echo "timestamp,status,resolved_ip,details" > "$LOG_FILE"

echo "Starting RDS failover monitoring"
echo "Endpoint: $DB_ENDPOINT"
echo "Log file: $LOG_FILE"

end=$((SECONDS + MAX_SECONDS))

while ((SECONDS < end)); do
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    resolved_ip=$(getent ahostsv4 "$DB_ENDPOINT" \
      | awk 'NR==1 {print $1}')

    resolved_ip="${resolved_ip:-unresolved}"

    if output=$(psql \
      "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=3 application_name=lab10-failover-monitor" \
      -X -A -t -v ON_ERROR_STOP=1 \
      -c "SELECT 1;" 2>&1); then

        status="SUCCESS"
        details="query_ok"
    else
        status="FAILURE"
        details=$(printf '%s' "$output" \
          | tr '\n,' '  ' \
          | cut -c 1-100)
    fi

    printf '%s,%s,%s,%s\n' \
      "$timestamp" \
      "$status" \
      "$resolved_ip" \
      "$details" >> "$LOG_FILE"

    echo "$timestamp | $status | $resolved_ip"

    sleep 3
done

echo "Monitoring finished."
```

Make the script executable:

```bash
chmod +x monitor-failover.sh
```

### Step 3 — Start Monitoring

Inside EC2:

```bash
nohup env \
  DB_ENDPOINT="$DB_ENDPOINT" \
  PGPASSFILE="$PGPASSFILE" \
  "$PWD/monitor-failover.sh" \
  "$HOME/lab10-failover.log" \
  > "$HOME/lab10-monitor-console.log" 2>&1 \
  < /dev/null &

echo $! > "$HOME/lab10-monitor.pid"
```

Verify:

```bash
tail -n 10 "$HOME/lab10-monitor-console.log"
```

Expected: repeated `SUCCESS` entries before failover.

### Step 4 — Verify RDS Before Failover

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone}' \
  --output table \
  --region "$AWS_REGION"
```

Only continue if RDS reports `available` and `MultiAZ=true`.

### Step 5 — Record Start Time

```bash
export FAILOVER_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "$FAILOVER_START"
```

### Step 6 — Trigger Forced Failover

```bash
aws rds reboot-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --force-failover \
  --region "$AWS_REGION"
```

This intentionally triggers a Multi-AZ failover.

### Step 7 — Check RDS Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,AZ:AvailabilityZone,MultiAZ:MultiAZ}' \
  --output table \
  --region "$AWS_REGION"
```

During the operation, RDS may show `rebooting`.

### Step 8 — Observe Connection Failures

Inside EC2:

```bash
tail -n 25 "$HOME/lab10-monitor-console.log"
```

Expected pattern:

```text
SUCCESS
SUCCESS
FAILURE
FAILURE
SUCCESS
SUCCESS
```

The exact results depend on failover timing and probe intervals.

### Step 9 — Wait for Recovery

From WSL:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 10 — Record End Time

```bash
export FAILOVER_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

START_EPOCH=$(date -ud "$FAILOVER_START" +%s)
END_EPOCH=$(date -ud "$FAILOVER_END" +%s)

echo "RDS wait measurement: $((END_EPOCH - START_EPOCH)) seconds"
```

This is a control-plane wait measurement, not necessarily the exact application outage duration.

---

Append the following sections to the same `README.md`, immediately after Section 12.

<WritingBlock id="10487" variant="document">## 13. Troubleshooting Investigation

### Check 1 — Verify the New Primary Availability Zone

From WSL:

```bash
export NEW_PRIMARY_AZ=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].AvailabilityZone' \
  --output text \
  --region "$AWS_REGION")

echo "Original AZ: $ORIGINAL_AZ"
echo "Current AZ: $NEW_PRIMARY_AZ"
```

Expected: the primary Availability Zone changes following a successful failover.

RDS control-plane reporting may take additional time to reflect the updated placement.

### Check 2 — Investigate RDS Events

```bash
aws rds describe-events \
  --source-type db-instance \
  --source-identifier "$DB_IDENTIFIER" \
  --duration 120 \
  --query 'Events[].{Time:Date,Message:Message}' \
  --output table \
  --region "$AWS_REGION"
```

Look for events indicating failover initiation and completion.

Typical messages include:

```text
Multi-AZ instance failover started
Multi-AZ failover to standby complete
```

Actual wording may vary.

### Check 3 — Verify Endpoint Stability

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION"
```

Expected: the endpoint hostname remains unchanged.

### Check 4 — Compare DNS Addresses

Inside EC2:

```bash
dig +short "$DB_ENDPOINT"

getent ahostsv4 "$DB_ENDPOINT"
```

Compare the resolved address with the value recorded before failover.

The new primary may have a different private IP address.

### Check 5 — Inspect Connection Monitoring Logs

```bash
cat "$HOME/lab10-failover.log"
```

Example output format:

```text
timestamp,status,resolved_ip,details
2026-11-08T19:00:00Z,SUCCESS,10.200.2.15,query_ok
2026-11-08T19:01:00Z,FAILURE,10.200.2.15,connection_error
2026-11-08T19:03:00Z,SUCCESS,10.200.3.21,query_ok
```

These are illustrative values, not measured results.

### Check 6 — Count Successful and Failed Probes

```bash
awk -F, '
NR > 1 {
    count[$2]++
}
END {
    print "Successful probes:", count["SUCCESS"] + 0
    print "Failed probes:", count["FAILURE"] + 0
}
' "$HOME/lab10-failover.log"
```

### Check 7 — Identify Failure and Recovery Timestamps

```bash
awk -F, '
NR == 1 { next }

$2 == "FAILURE" && first_failure == "" {
    first_failure = $1
}

first_failure != "" && $2 == "SUCCESS" && recovery == "" {
    recovery = $1
}

END {
    print "First failure:", first_failure
    print "First recovery:", recovery
}
' "$HOME/lab10-failover.log"
```

Record both timestamps.

### Check 8 — Investigate CloudWatch Connections

From WSL:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table \
  --region "$AWS_REGION"
```

### Check 9 — Investigate CPU Utilization

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --output table \
  --region "$AWS_REGION"
```

CloudWatch metrics may be delayed or temporarily missing during failover.

### Investigation Summary

| Investigation | Expected Finding |
|---|---|
| Multi-AZ | Enabled |
| Original Primary AZ | Recorded |
| New Primary AZ | Updated |
| RDS Events | Failover recorded |
| RDS Endpoint Hostname | Unchanged |
| DNS Mapping | Updated |
| Existing Connections | Interrupted |
| Connection Monitor | May capture failures |
| RDS Status | Returns to available |
| PostgreSQL Connectivity | Restored |

---

## 14. Root Cause Analysis

### Root Cause

The temporary PostgreSQL connectivity interruption was caused by an intentionally triggered Multi-AZ failover.

The RDS reboot operation interrupted the original primary database.

Amazon RDS automatically promoted the standby in another Availability Zone.

During the transition, existing PostgreSQL sessions became invalid and some new connection attempts could not complete.

After the standby was promoted and the database endpoint's DNS record was updated, clients could establish new connections to the active primary.

### Technical Explanation

A traditional Multi-AZ RDS deployment maintains a synchronously replicated standby database.

During failover, the standby takes over as the primary.

However, existing TCP sessions cannot automatically move between database hosts.

Applications must reconnect through the RDS endpoint.

An application that caches the previous IP address too long may experience additional recovery delays.

### Root Cause Flow

```text
Forced Failover Initiated
          |
          v
Original Primary Interrupted
          |
          v
Existing PostgreSQL Sessions Lost
          |
          v
Standby Promotion
          |
          v
RDS DNS Record Updated
          |
          v
Application Reconnection
          |
          v
New Primary Available
          |
          v
Application Recovery
```

### Five Whys

1. **Why did PostgreSQL connections fail?** The database was undergoing Multi-AZ failover.
2. **Why did failover occur?** The Cloud Engineer initiated a controlled reboot with forced failover.
3. **Why were existing sessions interrupted?** The active database host changed.
4. **Why did applications need to reconnect?** TCP connections cannot automatically transfer to the promoted standby.
5. **How can the impact be reduced?** Configure DNS caching, connection retries, monitoring, and transaction-safe recovery.

### Root Cause Summary

| Component | Finding |
|---|---|
| Database Engine | PostgreSQL |
| Multi-AZ | Enabled |
| Trigger | Forced failover |
| Immediate Cause | Primary role transition |
| Application Symptom | Connection interruption |
| DNS Change | Endpoint mapping updated |
| Recovery | Reconnect to promoted primary |
| Prevention | Application resilience and failover readiness |

---

## 15. Remediation and Recovery

### Step 1 — Verify RDS Availability

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
MultiAZ: True
```

### Step 2 — Verify DNS Resolution

Inside EC2:

```bash
getent ahostsv4 "$DB_ENDPOINT"
```

```bash
dig +short "$DB_ENDPOINT"
```

Expected: the endpoint resolves successfully.

### Step 3 — Verify TCP Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: TCP connection succeeds.

### Step 4 — Verify PostgreSQL Login

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -c "SELECT pg_is_in_recovery();"
```

Expected:

```text
f
```

### Step 5 — Verify Committed Data

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "SELECT * FROM failover_test ORDER BY id;"
```

Expected: the two original records remain available.

### Step 6 — Verify New Writes

Connect to PostgreSQL:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require"
```

Execute:

```sql
INSERT INTO failover_test (id, message)
VALUES (3, 'After Multi-AZ failover');
```

Verify:

```sql
SELECT id, message
FROM failover_test
ORDER BY id;
```

Expected:

```text
1 | Before Multi-AZ failover
2 | Committed baseline record
3 | After Multi-AZ failover
```

### Step 7 — Inspect New Database Session

```sql
SELECT
    inet_server_addr(),
    inet_server_port(),
    pg_postmaster_start_time();
```

Compare with the original database session.

Exit:

```text
\q
```

### Step 8 — Stop Monitoring

```bash
if [[ -f "$HOME/lab10-monitor.pid" ]]; then
    kill "$(cat "$HOME/lab10-monitor.pid")" 2>/dev/null || true
fi
```

Review:

```bash
tail -n 15 "$HOME/lab10-failover.log"
```

Expected: successful connection probes after recovery.

### Remediation Summary

| Check | During Failover | After Recovery |
|---|---|---|
| RDS Status | Transitional | Available |
| Primary Database | Interrupted | Standby promoted |
| Existing Connections | Interrupted | Re-established |
| Endpoint Hostname | Same | Same |
| DNS Target | Changing | New primary |
| PostgreSQL Login | May fail | Successful |
| Committed Data | Temporarily unavailable | Preserved |
| New Writes | May fail | Successful |

---

## 16. Final Verification and Outage Measurement

### Verify Active Primary

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone,Endpoint:Endpoint.Address,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

### Verify PostgreSQL Query

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "SELECT id, message FROM failover_test ORDER BY id;"
```

### Measure Client-Visible Interruption

Use the connection monitor's first failure and first subsequent success timestamps.

The approximate interruption can be calculated as:

```text
Estimated client interruption =
First successful probe after failure
-
First failed probe
```

Because probes occur at intervals, the measurement is approximate.

### Lab Results Template

Record actual results after performing the lab:

| Measurement | Actual Result |
|---|---|
| Original Primary AZ | To be recorded |
| New Primary AZ | To be recorded |
| RDS Endpoint Changed? | To be verified |
| Original Resolved IP | To be recorded |
| New Resolved IP | To be recorded |
| Failover Start Time | To be recorded |
| First Failed Probe | To be recorded |
| First Successful Probe After Failure | To be recorded |
| Client Interruption | To be calculated |
| RDS Failover Event | To be recorded |
| Original Records Preserved | To be verified |
| New SQL Write | To be verified |

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| RDS Status | Available |
| Multi-AZ | True |
| Endpoint Hostname | Unchanged |
| Active Primary AZ | Updated |
| DNS Resolution | Successful |
| TCP 5432 | Reachable |
| PostgreSQL Login | Successful |
| `pg_is_in_recovery()` | False |
| Original Records | Present |
| Post-Failover Record | Present |
| Connection Monitor | Successful recovery probes |
| RDS Public Access | Disabled |

---

## 17. CloudWatch Monitoring and Production Best Practices

### Step 1 — Create CloudWatch Connection Alarm

From WSL:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Lab10 RDS connections below 1" \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator LessThanThreshold \
  --treat-missing-data missing \
  --region "$AWS_REGION"
```

This is an illustrative alarm and is not a reliable standalone failover detector.

A database can legitimately have very few connections during idle periods.

For production, combine RDS events with application-level availability monitoring.

### Step 2 — Verify Alarm

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold}' \
  --output table \
  --region "$AWS_REGION"
```

### Production Best Practices

1. Use Multi-AZ for databases requiring high availability.
2. Keep the RDS database in private subnets.
3. Use the AWS-managed RDS endpoint hostname.
4. Avoid hardcoded database IP addresses.
5. Configure DNS caching appropriately.
6. Implement bounded connection retries.
7. Use exponential backoff with jitter.
8. Verify transaction outcomes before retrying writes.
9. Use connection pooling where appropriate.
10. Monitor RDS failover events.
11. Monitor application database connectivity.
12. Test failover during approved maintenance windows.
13. Keep application transactions short where practical.
14. Verify committed data after failover.
15. Record observed recovery times.
16. Review application behavior during failover.

### Important Security Lesson

Multi-AZ high availability improves database resilience but does not eliminate the need for secure application design.

The application must handle connection interruptions and safely recover without duplicating transactions or exposing the database.

---

## 18. AWS Resource Cleanup

**Warning:** These commands permanently delete the disposable Lab 10 database and AWS infrastructure.

### Step 1 — Stop Monitoring and Remove Temporary Files

Inside EC2:

```bash
if [[ -f "$HOME/lab10-monitor.pid" ]]; then
    kill "$(cat "$HOME/lab10-monitor.pid")" 2>/dev/null || true
fi
```

Remove temporary credentials:

```bash
rm -f "$HOME/.pgpass-lab10"
unset PGPASSFILE
```

After saving any monitoring evidence you need:

```bash
rm -f "$HOME/lab10-failover.log"
rm -f "$HOME/lab10-monitor-console.log"
rm -f "$HOME/lab10-monitor.pid"
```

Exit Systems Manager:

```bash
exit
```

### Step 2 — Verify Resource Ownership

From WSL:

```bash
export DB_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBInstanceArn' \
  --output text \
  --region "$AWS_REGION")

aws rds list-tags-for-resource \
  --resource-name "$DB_ARN" \
  --region "$AWS_REGION"
```

Confirm the project tag is `RDS-Troubleshooting-Lab10`.

### Step 3 — Delete CloudWatch Alarm

```bash
aws cloudwatch delete-alarms \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Multi-AZ Database

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

This deletes the disposable Multi-AZ DB instance deployment and its managed standby.

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

Confirm that the root volume uses `DeleteOnTermination=true`.

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

Verify role ownership:

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

Wait until the RDS and EC2 network interfaces are removed.

### Step 10 — Delete Security Groups

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

Expected: empty arrays.

Also verify EC2, EBS, IAM, DB subnet group, security group, and CloudWatch alarm removal.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Multi-AZ RDS Database | Deleted |
| Managed Standby | Deleted |
| DB Subnet Group | Deleted |
| EC2 Client | Terminated |
| Root EBS Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Client SG | Deleted |
| RDS SG | Deleted |
| CloudWatch Alarm | Deleted |
| Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is Amazon RDS Multi-AZ?

A high-availability deployment where Amazon RDS maintains a primary database and a synchronously replicated standby in another Availability Zone.

### Q2. What happens during failover?

RDS promotes the standby database, updates the endpoint's DNS mapping, and allows new client connections to the promoted primary.

### Q3. Can a traditional Multi-AZ standby serve read traffic?

No. Its primary purpose is high availability.

### Q4. How do you trigger forced Multi-AZ failover?

```bash
aws rds reboot-db-instance \
  --db-instance-identifier mydb \
  --force-failover
```

### Q5. Does the endpoint hostname change?

Normally, the hostname remains unchanged, but its DNS record is updated to point to the active primary.

### Q6. What happens to existing connections?

They are interrupted and need to be re-established.

### Q7. How do you verify failover?

Inspect RDS events, Availability Zone changes, endpoint DNS resolution, and PostgreSQL reconnection.

### Q8. How long does Multi-AZ failover take?

AWS reports a typical duration of 60–120 seconds, but actual recovery depends on database activity, crash recovery, and other conditions.

### Q9. What is the difference between Multi-AZ and a read replica?

Traditional Multi-AZ provides a synchronous standby for high availability. Read replicas use asynchronous replication for read scaling.

### Q10. Does Multi-AZ eliminate downtime?

No. It reduces the impact of failures but generally involves a temporary interruption during failover.

### Q11. How should an application handle failover?

Use the RDS hostname, refresh DNS appropriately, reconnect, apply bounded retries, and verify transaction outcomes before retrying writes.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL Multi-AZ database and an EC2 troubleshooting client inside the same VPC.

I verified the database configuration, recorded the original primary Availability Zone, and inserted test records.

I created a Bash script to monitor PostgreSQL connectivity and DNS resolution.

I intentionally triggered a Multi-AZ failover using the AWS CLI.

During the operation, I investigated connection failures, RDS events, database status, DNS changes, and primary Availability Zone information.

After the standby was promoted, I verified that PostgreSQL connections succeeded, existing committed records remained available, and new writes worked.

I also reviewed application connection retries, DNS caching, and high-availability monitoring practices.

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
├── 09-rds-read-replica-lag/
│
└── 10-rds-multi-az-failover/
    ├── README.md
    ├── ec2-trust-policy.json
    └── monitor-failover.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Full troubleshooting incident and remediation documentation |
| `ec2-trust-policy.json` | EC2 IAM trust policy for Systems Manager |
| `monitor-failover.sh` | Continuously monitors PostgreSQL connections and DNS during failover |

Do not commit AWS credentials, PostgreSQL passwords, temporary password files, or sensitive monitoring data.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how Amazon RDS Multi-AZ improves database availability by maintaining a synchronously replicated standby in another Availability Zone.

We investigated how a failover changes the active database host and interrupts existing PostgreSQL connections.

We learned that the RDS endpoint hostname normally remains the same while AWS updates its DNS mapping.

We used Bash monitoring to investigate client-visible connection failures and AWS CLI to inspect database status, Availability Zone changes, and RDS events.

After failover, we verified that previously committed records were preserved and the new primary accepted write operations.

The exercise demonstrates why high availability requires both infrastructure redundancy and application-level resilience.

**Key Lesson:** Multi-AZ protects database availability, but applications must be designed to reconnect safely after failover. DNS refresh, connection retries, transaction handling, and monitoring are essential for recovery.

### Skills Demonstrated

- Amazon RDS PostgreSQL
- Traditional Multi-AZ deployments
- Synchronous replication
- AWS CLI
- RDS forced failover
- `reboot-db-instance --force-failover`
- RDS event investigation
- Availability Zone verification
- RDS DNS endpoint troubleshooting
- PostgreSQL connectivity
- Linux `dig` and `getent`
- Bash monitoring scripts
- Database outage analysis
- Application reconnection concepts
- CloudWatch monitoring
- Data preservation verification
- High availability concepts
- Disaster recovery fundamentals
- VPC networking
- AWS Systems Manager
- Root cause analysis
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-010 |
| Problem | RDS Multi-AZ Failover |
| Database Engine | PostgreSQL |
| Deployment | Multi-AZ |
| Fault Injection | Forced failover |
| Original Connections | Interrupted |
| New Primary | Standby promoted |
| Endpoint Hostname | Unchanged |
| DNS Mapping | Updated |
| RDS Events | Recorded |
| PostgreSQL Connectivity | Restored |
| Previously Committed Data | Preserved |
| New Database Writes | Successful |
| Monitoring | Bash and CloudWatch |
| RDS Public Access | Disabled |
| Cleanup | Temporary infrastructure removed |
| Incident Status | Set to resolved after verification |

**Key Takeaway:** Reliable RDS high availability requires Multi-AZ infrastructure, DNS-aware applications, resilient database connections, accurate failover monitoring, and verification of committed data after recovery.