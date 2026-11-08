# Lab 06 — RDS High Database CPU

## Overview

This lab demonstrates how to troubleshoot high CPU utilization in Amazon RDS PostgreSQL caused by expensive SQL queries and excessive database workload.

We deploy a private PostgreSQL database and an Amazon Linux 2023 EC2 troubleshooting client inside the same VPC.

The database initially operates normally with low CPU utilization and successful PostgreSQL connectivity.

We then generate a controlled CPU-intensive workload using concurrent PostgreSQL queries.

The workload repeatedly performs mathematical calculations over large datasets, increasing the CPU resources required by the database.

As the workload executes, Amazon CloudWatch may report elevated `CPUUtilization`, and database queries may take longer to complete.

We investigate the database using AWS CLI, CloudWatch metrics, PostgreSQL `pg_stat_activity`, SQL execution plans, and Linux troubleshooting tools.

After identifying the expensive SQL workload as the source of CPU pressure, we stop the workload, cancel remaining CPU-intensive queries, and verify database responsiveness.

Finally, we configure a CloudWatch high-CPU alarm and remove the temporary AWS resources.

**Troubleshooting workflow:**

Infrastructure Setup → CPU Fault Injection → Symptoms → Investigation → Root Cause Analysis → Remediation → Verification → Monitoring → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-006 |
| Difficulty | Intermediate–Advanced |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager, CloudWatch |
| Database Engine | PostgreSQL |
| RDS Instance Class | `db.t4g.micro` |
| RDS Storage | 20 GiB gp3 |
| RDS Deployment | Private, Single-AZ |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| Database Name | `labdb` |
| Database Username | `labadmin` |
| Database Port | TCP `5432` |
| VPC CIDR | `10.195.0.0/16` |
| Fault Injection | Concurrent CPU-intensive PostgreSQL queries |
| Primary Metric | `CPUUtilization` |
| Additional Metric | `CPUCreditBalance` |
| Expected Symptom | Elevated CPU and slower queries |
| Root Cause | Expensive SQL workload |
| Remediation | Stop workload and cancel unnecessary queries |
| Verification | CPU recovery, PostgreSQL connectivity, SQL queries |
| Monitoring | CloudWatch high-CPU alarm |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts its application on Amazon EC2 and stores application data in an Amazon RDS PostgreSQL database.

The application suddenly experiences slow database responses.

Users report that application pages take longer to load, and some requests may time out.

The Cloud Engineer checks the RDS database and finds that the instance remains available.

However, Amazon CloudWatch shows increased CPU utilization.

Example:

```text
RDS Instance: cloud-rds-lab06-postgres

DBInstanceStatus: available

CPUUtilization: Elevated

Application Response: Slow

Database Queries: Long-running
```

The engineer investigates PostgreSQL active sessions and discovers expensive SQL queries repeatedly performing mathematical calculations.

The queries consume a significant amount of available CPU resources.

The engineer must identify the source of CPU pressure, stop the unnecessary workload, and restore normal database responsiveness.

### Incident Symptoms

- RDS PostgreSQL remains available.
- EC2-to-RDS connectivity works.
- PostgreSQL authentication succeeds.
- CPU utilization increases during the workload.
- SQL queries may execute more slowly.
- Long-running queries appear in `pg_stat_activity`.
- CPU credits may decrease on burstable database instances.
- Application response times may increase.
- Database performance improves after the expensive queries stop.

### Business Impact

- Application requests may become slower.
- Customer-facing services may experience increased latency.
- Database queries may take longer to finish.
- Application connection pools may become saturated.
- Transactions may experience delays.
- CPU credit consumption may increase operating costs.
- Severe resource contention may cause service degradation.

### Objective

Investigate high RDS PostgreSQL CPU utilization, identify expensive SQL workloads, safely stop unnecessary database operations, verify performance recovery, and configure monitoring to prevent future incidents.

---

## 3. AWS Architecture

### Infrastructure

```text
                     Amazon VPC
                   10.195.0.0/16
                          |
          ---------------------------------
          |                               |
          v                               v
     Public Subnet                  Private Subnets
    10.195.1.0/24                  10.195.2.0/24
          |                        10.195.3.0/24
          v                               |
       EC2 Client                         v
    Amazon Linux 2023               RDS PostgreSQL
          |                               |
          v                               v
       Client SG                      Database SG
          |                               |
          +---------- TCP 5432 -----------+
                                          |
                                          v
                                     SQL Workload
                                          |
                                          v
                                     CPUUtilization
                                          |
                                          v
                                      CloudWatch
```

### Broken Architecture

```text
                  Application
                       |
                       v
               PostgreSQL Queries
                       |
                       v
                 Large Dataset
                       |
                       v
             Expensive Calculations
                       |
                       v
               Concurrent Queries
                       |
                       v
                  High CPU Usage
                       |
                       v
                Query Contention
                       |
                       v
               Slow SQL Execution
                       |
                       v
                Application Delay
```

### Recovered Architecture

```text
                High CPU Utilization
                         |
                         v
                 CloudWatch Metrics
                         |
                         v
                  SQL Investigation
                         |
                         v
                  pg_stat_activity
                         |
                         v
              Identify Expensive Queries
                         |
                         v
                 Stop CPU Workload
                         |
                         v
                 Cancel Active Queries
                         |
                         v
                   CPU Recovery
                         |
                         v
                Successful SQL Queries
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.195.0.0/16` |
| Public Subnet | `10.195.1.0/24` |
| Private Subnet A | `10.195.2.0/24` |
| Private Subnet B | `10.195.3.0/24` |
| Public Routing | Internet Gateway |
| Private Routing | VPC local route |
| Client SG | `cloud-rds-lab06-client-sg` |
| Database SG | `cloud-rds-lab06-db-sg` |
| RDS Public Access | Disabled |
| EC2 Management | Systems Manager |

---

## 4. Understanding RDS CPU Utilization

Amazon RDS uses CPU resources to execute SQL queries, process transactions, perform calculations, and manage database operations.

High CPU utilization occurs when workloads demand a large percentage of available processing capacity.

### CPUUtilization

Amazon CloudWatch provides the `CPUUtilization` metric.

It measures the percentage of CPU resources being used by the database instance.

Example:

```text
CPUUtilization: 85%
```

A high value indicates significant CPU usage but does not automatically identify the root cause.

### CPUCreditBalance

The `db.t4g.micro` instance belongs to the burstable-performance T-family.

These instances use CPU credits to support temporary increases above their baseline CPU performance.

The `CPUCreditBalance` metric shows available burst credits.

Sustained CPU-intensive workloads may reduce available credits or incur surplus-credit charges.

### PostgreSQL Active Sessions

PostgreSQL provides the `pg_stat_activity` system view.

It displays information about database sessions, including:

- Process ID
- Database username
- Application name
- Session state
- Query execution time
- Wait events
- SQL statement

### SQL Execution Plans

PostgreSQL supports `EXPLAIN` and `EXPLAIN ANALYZE`.

These commands help investigate how PostgreSQL executes queries.

For example:

```sql
EXPLAIN ANALYZE
SELECT COUNT(*)
FROM generate_series(1, 1000000);
```

`EXPLAIN ANALYZE` executes the query and reports actual execution statistics.

### Important Concepts

| Concept | Explanation |
|---|---|
| CPUUtilization | Percentage of instance CPU usage |
| CPUCreditBalance | Available burst CPU credits |
| CPUCreditUsage | Credits consumed by CPU activity |
| DatabaseConnections | Database client connection count |
| FreeableMemory | Available memory |
| pg_stat_activity | Active PostgreSQL session information |
| EXPLAIN | Estimated query execution plan |
| EXPLAIN ANALYZE | Actual query execution statistics |
| pg_cancel_backend | Cancels a PostgreSQL query |
| pg_terminate_backend | Terminates a PostgreSQL session |
| Query Optimization | Reduces unnecessary database work |
| CloudWatch Alarm | Detects sustained metric thresholds |

**Important:** High CPU utilization is a symptom. The root cause may be expensive SQL, excessive concurrency, inefficient execution plans, maintenance activity, or insufficient instance capacity.

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

- Use a disposable database.
- Never generate test CPU load against production.
- Keep RDS private.
- Do not expose PostgreSQL to `0.0.0.0/0`.
- Use Systems Manager for EC2 administration.
- Use a controlled CPU workload.
- Limit workload execution time.
- Cancel only confirmed lab queries.
- Avoid terminating AWS-managed database processes.
- Never commit database passwords.
- Remove temporary authentication files.
- Delete temporary AWS resources after completion.

### Cost Warning

RDS instances, EC2 instances, EBS storage, public IPv4 addresses, and CloudWatch alarms may incur charges.

T-family database instances may also incur CPU surplus-credit charges during sustained workloads.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab06"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab06-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab06-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab06-client"
export EC2_ROLE_NAME="cloud-rds-lab06-ssm-role"
export PROFILE_NAME="cloud-rds-lab06-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab06-client-sg"
export DB_SG_NAME="cloud-rds-lab06-db-sg"

export ALARM_NAME="cloud-rds-lab06-high-cpu"
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

Select compatible instance classes and Availability Zones when necessary.

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

Avoid creating duplicate billable resources.

---

## 7. Create the AWS VPC

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.195.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab06-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

Enable VPC DNS:

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
  --cidr-block "10.195.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab06-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.195.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab06-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.195.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab06-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab06-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab06-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Create default route:

```bash
aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

Associate public subnet:

```bash
export PUBLIC_RT_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

The private database subnets remain on the VPC main route table, which contains the VPC local route.

---

## 8. Create Security Groups

### Step 1 — Create EC2 Client SG

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab06 EC2 client" \
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
  --description "Lab06 RDS PostgreSQL" \
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

### Step 4 — Verify Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Protocol: TCP
Port: 5432
Source: Client Security Group
```

---

## 9. Deploy the EC2 Troubleshooting Client

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

### Step 7 — Verify Security Group Association

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups' \
  --output json \
  --region "$AWS_REGION"
```

### Step 8 — Connect Through Systems Manager

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Install tools:

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
  --db-subnet-group-description "Lab06 private database subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Subnet Group

```bash
aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --query 'DBSubnetGroups[0].Subnets[].{Subnet:SubnetIdentifier,AZ:SubnetAvailabilityZone.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: two database subnets in different Availability Zones.

### Step 3 — Enter Temporary Password

```bash
read -rsp "Enter temporary RDS password: " DB_PASSWORD
echo
```

Use a unique password.

The following command passes the password as an argument to AWS CLI. This can briefly expose it to local process inspection. For production, prefer RDS-managed credentials with AWS Secrets Manager.

### Step 4 — Create RDS

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

Remove password variable:

```bash
unset DB_PASSWORD
```

### Step 5 — Wait for RDS

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,Public:PubliclyAccessible,Engine:Engine}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Class: db.t4g.micro
Public: False
Engine: postgres
```

### Step 7 — Retrieve Endpoint

```bash
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$DB_ENDPOINT"
```

---

## 11. Fault Injection — High Database CPU

### Step 1 — Record Baseline CPU

From WSL:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table \
  --region "$AWS_REGION"
```

Record the baseline CPU value.

### Step 2 — Connect to EC2

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

### Step 3 — Verify Connectivity

```bash
getent ahostsv4 "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful connectivity.

### Step 4 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Run:

```sql
SELECT current_database(), current_user;
```

Enable query timing:

```sql
\timing on
```

Run a baseline calculation:

```sql
SELECT COUNT(*)
FROM generate_series(1, 10000);
```

Record the execution time.

Exit:

```text
\q
```

### Step 5 — Configure Temporary Authentication

Inside EC2:

```bash
read -rsp "Enter temporary RDS password: " LAB_DB_PASSWORD
echo
```

Create a temporary PostgreSQL password file:

```bash
export PGPASSFILE="$HOME/.pgpass-lab06"

umask 077

ESCAPED_PASSWORD=$(printf '%s' "$LAB_DB_PASSWORD" \
  | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')

printf '%s:5432:labdb:labadmin:%s\n' \
  "$DB_ENDPOINT" "$ESCAPED_PASSWORD" > "$PGPASSFILE"

chmod 600 "$PGPASSFILE"

unset LAB_DB_PASSWORD ESCAPED_PASSWORD
```

Verify authentication:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -c "SELECT 1;"
```

Expected: successful authentication without a password prompt.

Do not commit the temporary password file.

### Step 6 — Create CPU Load Script

Save as `load-cpu.sh`:

```bash
cat > load-cpu.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?Set DB_ENDPOINT first}"

echo "Starting Lab 06 CPU workload"

rm -f "$HOME/lab06-cpu.pids"

for worker in 1 2; do
  (
    end=$((SECONDS + 120))

    while ((SECONDS < end)); do
      psql \
        "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require application_name=lab06-cpu-load" \
        -v ON_ERROR_STOP=1 \
        -c "
          SELECT SUM(sqrt(g::double precision))
          FROM generate_series(1, 100000000) AS g;
        " > /dev/null 2>&1 || true
    done
  ) &

  echo "$!" >> "$HOME/lab06-cpu.pids"
done

echo "CPU workload started with 2 workers."
echo "Workers launch queries for approximately 120 seconds."
EOF

chmod +x load-cpu.sh
```

### Step 7 — Set Query Timeout

```bash
export PGOPTIONS="-c statement_timeout=30000"
```

This sets a 30-second statement timeout for the PostgreSQL client connections.

### Step 8 — Start CPU Workload

```bash
./load-cpu.sh
```

Expected:

```text
Starting Lab 06 CPU workload

CPU workload started with 2 workers.

Workers launch queries for approximately 120 seconds.
```

The script starts two background workers.

Each worker repeatedly executes an expensive PostgreSQL calculation during the controlled test.

### Step 9 — Verify Running Processes

```bash
cat "$HOME/lab06-cpu.pids"

ps aux | grep '[p]sql'
```

### Step 10 — Observe Active SQL

Connect to PostgreSQL:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require"
```

Execute:

```sql
SELECT
    pid,
    application_name,
    state,
    now() - query_start AS runtime,
    LEFT(query, 120) AS query
FROM pg_stat_activity
WHERE application_name = 'lab06-cpu-load';
```

Expected: active CPU-load sessions may appear while the workload is running.

### Fault Summary

| Check | Expected Result |
|---|---|
| RDS | Available |
| EC2 | Running |
| PostgreSQL | Connected |
| CPU Workers | Two |
| SQL Queries | CPU-intensive |
| CPUUtilization | Elevated |
| Query Runtime | Increased |
| Application Performance | Potential slowdown |
| Root Cause | Expensive concurrent SQL |

---

## 12. Troubleshooting Investigation

### Check 1 — Verify RDS Status

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: RDS remains available.

### Check 2 — Inspect CPUUtilization

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table \
  --region "$AWS_REGION"
```

Expected: CPU utilization rises during fault injection, although the exact peak depends on instance behavior and CloudWatch sampling.

### Check 3 — Inspect CPU Credit Balance

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUCreditBalance \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Average \
  --output table \
  --region "$AWS_REGION"
```

Finding: burst credits may decrease during sustained CPU-intensive activity.

### Check 4 — Inspect Database Connections

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average \
  --output table \
  --region "$AWS_REGION"
```

Finding: active database connection counts may increase during testing.

### Check 5 — Inspect Freeable Memory

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeableMemory \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average \
  --output table \
  --region "$AWS_REGION"
```

Memory pressure can contribute to slow database performance.

### Check 6 — Identify Active Queries

Inside PostgreSQL:

```sql
SELECT
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - query_start AS duration,
    LEFT(query, 150) AS query
FROM pg_stat_activity
WHERE datname = 'labdb'
ORDER BY query_start;
```

Expected: active CPU-load sessions may be visible.

### Check 7 — Identify Long-Running Queries

```sql
SELECT
    pid,
    application_name,
    now() - query_start AS runtime,
    LEFT(query, 150) AS query
FROM pg_stat_activity
WHERE state = 'active'
  AND pid <> pg_backend_pid()
ORDER BY runtime DESC;
```

### Check 8 — Count Active Connections

```sql
SELECT
    state,
    COUNT(*) AS connection_count
FROM pg_stat_activity
WHERE datname = 'labdb'
GROUP BY state;
```

### Check 9 — Analyze Query Execution Plan

Use a smaller query:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT SUM(sqrt(g::double precision))
FROM generate_series(1, 1000000) AS g;
```

This helps investigate the execution plan and query duration.

### Check 10 — Inspect PostgreSQL Query Statistics

Check whether `pg_stat_statements` is loaded:

```sql
SHOW shared_preload_libraries;
```

If available and preloaded:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Query:

```sql
SELECT
    calls,
    ROUND(total_exec_time::numeric, 2) AS total_ms,
    ROUND(mean_exec_time::numeric, 2) AS mean_ms,
    LEFT(query, 120) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

This step is optional and depends on PostgreSQL configuration.

### Investigation Summary

| Investigation | Finding |
|---|---|
| RDS Status | Available |
| Database Endpoint | Valid |
| DNS | Working |
| Security Groups | Correct |
| CPUUtilization | Elevated during workload |
| CPU Credits | May decrease |
| Database Sessions | CPU-load sessions |
| Expensive SQL | Mathematical aggregation |
| Query Execution | Resource-intensive |
| Root Cause | Concurrent expensive SQL queries |

---

## 13. Root Cause Analysis

### Root Cause

The PostgreSQL database experiences high CPU utilization because of repeated computationally expensive SQL queries.

The workload executes mathematical calculations over millions of generated values.

Two concurrent workers repeatedly request CPU-intensive operations from the database.

Because the RDS instance has limited CPU capacity, the workload can cause substantial CPU pressure and degrade database responsiveness.

### Technical Explanation

PostgreSQL requires CPU resources to execute queries.

When expensive calculations run repeatedly, they consume CPU cycles.

Multiple concurrent operations increase processing demand.

The database instance may spend a large percentage of available CPU resources executing these queries.

This reduces processing capacity available for other application requests.

### Root Cause Flow

```text
Application Workload
        |
        v
CPU-Intensive SQL
        |
        v
Repeated Mathematical Operations
        |
        v
Concurrent Database Sessions
        |
        v
High CPU Demand
        |
        v
CloudWatch CPUUtilization Spike
        |
        v
Database Query Contention
        |
        v
Slow Application Responses
```

### Five Whys

1. **Why did the database become slow?** CPU-intensive queries consumed available processing resources.
2. **Why was CPU utilization high?** Multiple expensive SQL operations ran concurrently.
3. **Why were the queries expensive?** They repeatedly processed large generated datasets.
4. **Why did this affect database performance?** The RDS instance had limited CPU resources for concurrent workloads.
5. **How can this be prevented?** Optimize SQL, control concurrency, monitor CPU, and right-size database capacity when necessary.

### Prevention

- Monitor CPU utilization.
- Review query execution plans.
- Optimize expensive SQL.
- Limit unnecessary concurrency.
- Use appropriate indexes.
- Monitor CPU credits.
- Configure CloudWatch alarms.
- Use query timeouts where appropriate.
- Review workload growth.
- Scale database capacity when justified.

---

## 14. Remediation — Stop Expensive Queries

### Step 1 — Stop CPU Load Workers

Inside EC2, return to Bash if currently inside PostgreSQL:

```text
\q
```

Stop the script workers:

```bash
if [[ -f "$HOME/lab06-cpu.pids" ]]; then
  while read -r pid; do
    kill "$pid" 2>/dev/null || true
  done < "$HOME/lab06-cpu.pids"
fi
```

The worker loop may stop while an already-running PostgreSQL query continues.

### Step 2 — Identify Active Queries

Connect:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require"
```

Execute:

```sql
SELECT
    pid,
    application_name,
    state,
    query
FROM pg_stat_activity
WHERE application_name = 'lab06-cpu-load';
```

Verify these sessions belong to the disposable lab workload.

### Step 3 — Cancel CPU-Intensive Queries

```sql
SELECT
    pid,
    pg_cancel_backend(pid)
FROM pg_stat_activity
WHERE application_name = 'lab06-cpu-load'
  AND state = 'active'
  AND pid <> pg_backend_pid();
```

This cancels the active query associated with each matching session.

### Step 4 — Verify Queries Stopped

```sql
SELECT
    pid,
    application_name,
    state
FROM pg_stat_activity
WHERE application_name = 'lab06-cpu-load'
  AND state = 'active';
```

Expected: no active Lab 06 CPU queries remain.

### Step 5 — Verify PostgreSQL Responsiveness

```sql
SELECT current_database(), current_user;
```

```sql
SELECT 1 + 1 AS result;
```

Expected:

```text
result
------
2
```

### Step 6 — Remove Temporary Credentials

Exit PostgreSQL:

```text
\q
```

Inside EC2:

```bash
rm -f "$HOME/.pgpass-lab06"

unset PGPASSFILE PGOPTIONS

rm -f "$HOME/lab06-cpu.pids"
```

### Remediation Summary

| Check | Before Fix | After Fix |
|---|---|---|
| CPU Workload | Running | Stopped |
| Expensive Queries | Active | Cancelled |
| CPUUtilization | Elevated | Decreasing |
| PostgreSQL Queries | Potentially slow | Responsive |
| Database Connectivity | Working under load | Working |
| RDS Public Access | Disabled | Disabled |

---

## 15. Final Verification

### Verify RDS Availability

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Public: False
```

### Verify CPU Recovery

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Average Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average,Maximum]' \
  --output table \
  --region "$AWS_REGION"
```

Expected: CPU utilization decreases toward baseline.

### Verify PostgreSQL Read and Write

Inside EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -W
```

Create test table:

```sql
CREATE TABLE lab06_verification (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

Insert data:

```sql
INSERT INTO lab06_verification (id, message)
VALUES (1, 'High CPU incident resolved');
```

Verify:

```sql
SELECT * FROM lab06_verification;
```

Expected:

```text
 id |            message
----+-------------------------------
  1 | High CPU incident resolved
```

### Configure CloudWatch High CPU Alarm

From WSL:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Lab06 RDS CPU above 80 percent" \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --statistic Average \
  --period 60 \
  --evaluation-periods 3 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --region "$AWS_REGION"
```

This alarm evaluates whether average CPU utilization exceeds 80% for three consecutive one-minute periods.

No SNS notification is configured.

### Verify Alarm

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Threshold:Threshold}' \
  --output table \
  --region "$AWS_REGION"
```

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| RDS Status | Available |
| CPUUtilization | Returns toward baseline |
| Expensive Queries | Stopped |
| PostgreSQL Login | Successful |
| SQL Reads | Successful |
| SQL Writes | Successful |
| CloudWatch Metric | Available |
| High CPU Alarm | Created |
| RDS Public Access | Disabled |
| Incident | Resolved |

---

## 16. Production Best Practices

### High CPU Troubleshooting Checklist

1. Identify the affected database instance.
2. Verify RDS status.
3. Review CloudWatch CPUUtilization.
4. Compare CPU with baseline performance.
5. Check CPUCreditBalance for burstable instances.
6. Examine database connections.
7. Inspect FreeableMemory.
8. Compare IOPS and CPU metrics.
9. Identify long-running queries.
10. Inspect pg_stat_activity.
11. Review query execution plans.
12. Identify unnecessary CPU-intensive workloads.
13. Cancel only verified problematic queries.
14. Optimize inefficient SQL.
15. Verify performance recovery.
16. Configure CPU monitoring alarms.

### Performance Recommendations

- Monitor CPU, memory, and I/O together.
- Optimize frequently executed SQL statements.
- Avoid unnecessary full-table scans.
- Create appropriate database indexes.
- Use connection pooling when suitable.
- Configure statement timeouts where appropriate.
- Monitor database workload concurrency.
- Investigate inefficient query execution plans.
- Review CPU credits on T-family instances.
- Consider a larger RDS instance when legitimate workload demand exceeds capacity.
- Test query performance before production deployment.
- Avoid terminating important production queries without approval.

### Key Cloud Security Lesson

Database availability is an important part of cloud security.

Excessive resource consumption can reduce application availability even when network security and authentication are correctly configured.

Cloud Engineers and Cloud Security Engineers must understand how to investigate resource exhaustion and restore service safely.

---

## 17. Cleanup

**Warning:** These commands permanently delete the disposable Lab 06 database and associated infrastructure.

### Step 1 — Stop Workload and Exit EC2

If the CPU workload is still running, stop its workers and cancel the verified lab queries before cleanup.

Exit PostgreSQL:

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
Project=RDS-Troubleshooting-Lab06
```

### Step 3 — Delete CloudWatch Alarm

```bash
aws cloudwatch delete-alarms \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

### Step 4 — Delete RDS

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

Confirm the root volume uses `DeleteOnTermination=true`.

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

Delete the database SG first because it references the client SG.

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

aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected: empty arrays.

Also confirm the EC2 instance, root EBS volume, IAM role, instance profile, DB subnet group, and CloudWatch alarm were removed.

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
| RDS SG | Deleted |
| CloudWatch Alarm | Deleted |
| Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 18. Interview Questions and Answers

### Q1. What causes high CPU utilization in Amazon RDS?

Expensive SQL queries, inefficient execution plans, excessive concurrency, and high application workload can increase CPU consumption.

### Q2. Which CloudWatch metric monitors database CPU?

The `CPUUtilization` metric.

### Q3. What is pg_stat_activity?

A PostgreSQL system view that provides information about database sessions and currently executing queries.

### Q4. How do you identify long-running PostgreSQL queries?

Use `pg_stat_activity` and compare `query_start` with the current timestamp for active sessions.

### Q5. What is EXPLAIN ANALYZE?

A PostgreSQL command that executes a query and displays actual execution statistics and its execution plan.

### Q6. What is CPUCreditBalance?

It represents available burst CPU credits for supported T-family database instances.

### Q7. What is the difference between pg_cancel_backend and pg_terminate_backend?

`pg_cancel_backend()` cancels the current query, while `pg_terminate_backend()` terminates the database session.

### Q8. Can high CPU cause application timeouts?

Yes. CPU contention can increase database query latency and delay application requests.

### Q9. Should you immediately increase RDS instance size when CPU is high?

Not necessarily. First investigate the workload, SQL queries, execution plans, and resource usage.

### Q10. How can indexes reduce CPU usage?

Appropriate indexes can reduce unnecessary row scans and improve query execution efficiency.

### Q11. How do you prevent recurring high CPU incidents?

Use SQL optimization, workload monitoring, appropriate connection limits, CloudWatch alarms, and sufficient database capacity.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL database and an EC2 troubleshooting client inside the same VPC.

I intentionally generated a CPU-intensive SQL workload using concurrent PostgreSQL queries.

I monitored CPU utilization and CPU credits through Amazon CloudWatch.

I investigated active database sessions using `pg_stat_activity` and analyzed SQL execution using `EXPLAIN ANALYZE`.

After identifying the expensive SQL workload as the source of CPU pressure, I stopped the load generator and cancelled the remaining active queries.

I then verified successful PostgreSQL connectivity and read/write operations while monitoring CPU recovery.

I also configured a CloudWatch high-CPU alarm and removed the temporary infrastructure.

This lab demonstrated how to troubleshoot database CPU pressure using AWS monitoring and PostgreSQL investigation tools.

---

## 19. Repository Structure

```text
06-rds-high-database-cpu/
├── README.md
├── ec2-trust-policy.json
└── load-cpu.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident, investigation, remediation, verification, and cleanup |
| `ec2-trust-policy.json` | EC2 IAM trust policy for Systems Manager access |
| `load-cpu.sh` | Generates controlled CPU-intensive PostgreSQL queries |

The `load-cpu.sh` script is created on EC2 during the exercise. Copy the script into the repository after reviewing it.

Do not commit database credentials, temporary password files, or AWS credentials.

---

## 20. Lessons Learned

This lab demonstrates how CPU-intensive SQL queries can affect Amazon RDS PostgreSQL performance.

The database may remain available while application requests become slower because CPU resources are heavily utilized.

We used Amazon CloudWatch to investigate CPU utilization and CPU credit consumption.

We also used PostgreSQL system views to identify expensive database sessions and examine query execution behavior.

After identifying the CPU-intensive workload, we stopped the load generator and cancelled the unnecessary queries.

We then verified that PostgreSQL remained accessible and database operations completed successfully.

The exercise demonstrates how Cloud Engineers can investigate resource pressure before deciding whether database scaling is required.

**Key Lesson:** High CPU utilization is not always an infrastructure sizing problem. Expensive SQL queries and excessive workload concurrency can cause performance degradation even when the database itself is healthy.

---

## 21. Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Amazon EC2 administration
- Amazon VPC networking
- AWS Systems Manager
- Amazon CloudWatch
- CPUUtilization monitoring
- CPUCreditBalance investigation
- Database performance troubleshooting
- PostgreSQL `pg_stat_activity`
- PostgreSQL `pg_stat_statements`
- SQL execution plan analysis
- `EXPLAIN ANALYZE`
- Query cancellation
- Database session investigation
- Bash scripting
- Controlled CPU fault injection
- Root cause analysis
- CloudWatch alarm configuration
- Private database networking
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-006 |
| Problem | High RDS Database CPU |
| Database Engine | PostgreSQL |
| Database | labdb |
| Fault Injection | Concurrent CPU-intensive SQL |
| Expected Symptom | Elevated CPUUtilization |
| Root Cause | Expensive SQL workload |
| Investigation | CloudWatch and PostgreSQL |
| Remediation | Stop and cancel unnecessary queries |
| CPU Recovery | Returns toward baseline |
| PostgreSQL Login | Successful |
| SQL Read/Write | Successful |
| RDS Public Access | Disabled |
| CloudWatch Monitoring | Configured |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Effective database performance troubleshooting requires combining AWS infrastructure monitoring with PostgreSQL-level investigation. Identifying and correcting the workload responsible for CPU pressure helps restore database responsiveness without unnecessary infrastructure changes.