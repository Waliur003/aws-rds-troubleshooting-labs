# Lab 07 — Too Many Database Connections

## Overview

This lab demonstrates how to troubleshoot an Amazon RDS PostgreSQL connection failure caused by excessive database connections and an application role reaching its configured connection limit.

We deploy a private PostgreSQL database and an Amazon Linux 2023 EC2 troubleshooting client inside the same VPC.

The database initially accepts connections normally.

We create a dedicated PostgreSQL application role named `lab07_app` with a maximum of five concurrent connections.

Next, we simulate an application connection management problem by opening five PostgreSQL sessions and keeping them occupied using `pg_sleep()`.

When a sixth client attempts to connect using the same application role, PostgreSQL rejects the connection because the role has reached its permitted connection limit.

We investigate the connection failure using PostgreSQL `pg_stat_activity`, `pg_stat_database`, `max_connections`, role configuration, and Amazon CloudWatch `DatabaseConnections`.

After identifying the occupied application connection slots as the root cause, we stop the workload, terminate unnecessary sessions, and verify successful PostgreSQL reconnection.

Finally, we configure CloudWatch monitoring, review connection pooling solutions, and remove all temporary AWS resources.

This lab reproduces a real PostgreSQL role-level connection-limit error without intentionally exhausting the entire RDS instance.

**Troubleshooting workflow:**

Infrastructure Setup → Fault Injection → Symptoms → Investigation → Root Cause Analysis → Remediation → Verification → Monitoring → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-007 |
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
| Master Username | `labadmin` |
| Application Role | `lab07_app` |
| Application Connection Limit | 5 |
| Database Port | TCP `5432` |
| VPC CIDR | `10.197.0.0/16` |
| Fault Injection | Five occupied connections and a sixth connection attempt |
| Expected Error | Too many connections for role |
| Root Cause | Application role connection limit reached |
| Investigation | PostgreSQL system views and CloudWatch |
| Remediation | Release unnecessary application connections |
| Prevention | Connection pooling and application connection management |
| Verification | Successful application reconnection and SQL execution |

---

## 2. Production Incident Scenario

### Incident Description

A company runs an application on Amazon EC2 and stores customer information in Amazon RDS PostgreSQL.

The application originally connects to PostgreSQL without problems.

After an increase in application traffic, developers report that users occasionally receive database connection errors.

The application creates new PostgreSQL connections for incoming requests but does not properly reuse or close the existing connections.

Consequently, the number of active database sessions increases.

Eventually, the application reaches its permitted connection limit and PostgreSQL refuses additional connections.

Example:

```text
connection to server at "database-endpoint",
port 5432 failed:

FATAL: too many connections for role "lab07_app"
```

The operations engineer investigates and finds that the RDS database remains available.

DNS resolution and TCP connectivity are functioning correctly.

However, PostgreSQL rejects new application sessions because all five allowed connections are occupied.

The engineer must identify the connection-limit problem, release unnecessary sessions, and restore application connectivity without restarting or exposing the database.

### Incident Symptoms

- EC2 instance is running.
- RDS PostgreSQL instance is available.
- Both resources are in the same VPC.
- RDS endpoint resolves successfully.
- TCP port `5432` is reachable.
- PostgreSQL administrator can connect.
- Application role has a five-connection limit.
- Five application sessions remain connected.
- Sixth application connection is rejected.
- CloudWatch may show increased database connection counts.
- New application requests may fail until connections are released.

### Business Impact

- Application requests may fail.
- Users may receive database-related errors.
- Customer transactions may be interrupted.
- Application availability may decrease.
- Connection pools may become exhausted.
- Background jobs may fail to establish connections.
- Repeated retries may increase database connection pressure.
- Poor session management may reduce application reliability.

### Objective

Investigate PostgreSQL connection exhaustion, identify the sessions consuming application connection slots, release unnecessary connections safely, verify restored connectivity, and implement connection monitoring and prevention practices.

---

## 3. AWS Architecture

### Infrastructure

```text
                     Amazon VPC
                   10.197.0.0/16
                          |
          --------------------------------
          |                              |
          v                              v
     Public Subnet                 Private Subnets
    10.197.1.0/24                 10.197.2.0/24
          |                       10.197.3.0/24
          v                              |
       EC2 Client                        v
    Amazon Linux 2023               RDS PostgreSQL
          |                              |
          v                              v
       Client SG                      Database SG
          |                              |
          +---------- TCP 5432 ----------+
                                         |
                                         v
                                   Application Role
                                      lab07_app
                                         |
                                         v
                                  Connection Limit
                                          5
```

### Broken Architecture

```text
                  EC2 Application
                        |
                        v
                 PostgreSQL Client
                        |
                        v
                    lab07_app
                        |
                        v
                Connection Limit: 5
                        |
             -----------------------
             |                     |
             v                     v
       Connection 1           Connection 2
       Connection 3           Connection 4
             |
             v
        Connection 5
             |
             v
       All Slots Occupied
             |
             v
       Connection 6 Attempt
             |
             X
       Connection Rejected
             |
             v
       FATAL: Too Many Connections
```

### Recovered Architecture

```text
                 EC2 Application
                        |
                        v
                  PostgreSQL
                        |
                        v
               Application Role
                   lab07_app
                        |
                        v
             Inspect pg_stat_activity
                        |
                        v
             Identify Lab Sessions
                        |
                        v
             Stop Connection Workers
                        |
                        v
             Terminate Unused Sessions
                        |
                        v
              Connection Slots Free
                        |
                        v
             New Connection Accepted
                        |
                        v
                SQL Query Success
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.197.0.0/16` |
| Public Subnet | `10.197.1.0/24` |
| Private Subnet A | `10.197.2.0/24` |
| Private Subnet B | `10.197.3.0/24` |
| Public Routing | Internet Gateway |
| Private Routing | VPC local route |
| Client SG | `cloud-rds-lab07-client-sg` |
| Database SG | `cloud-rds-lab07-db-sg` |
| PostgreSQL Access | EC2 Client SG |
| RDS Public Access | Disabled |
| EC2 Management | Systems Manager |

---

## 4. Understanding PostgreSQL Connection Limits

PostgreSQL uses database sessions to manage client connections.

Each client connection consumes some database resources, including memory and process management overhead.

If too many connections remain open, PostgreSQL may reject additional clients.

### max_connections

The PostgreSQL `max_connections` parameter controls the maximum number of concurrent connections permitted by the database instance.

Example:

```sql
SHOW max_connections;
```

The value depends on the database instance configuration.

A larger number of permitted connections is not always better because each connection consumes system resources.

### Role Connection Limit

PostgreSQL also supports connection limits for individual database roles.

Example:

```sql
CREATE ROLE lab07_app
LOGIN
CONNECTION LIMIT 5;
```

This configures a maximum of five simultaneous connections for the application role, subject to PostgreSQL's role-limit enforcement rules.

In this lab, the application role is a regular non-superuser role, so its connection limit applies.

### Active Connections

An active database session is currently executing a query.

Example:

```text
State: active
Query: SELECT pg_sleep(120);
```

### Idle Connections

An idle database session is connected but not executing a query.

Example:

```text
State: idle
```

Idle connections still occupy database connection slots.

### Idle in Transaction

An `idle in transaction` session has an open transaction but is not currently executing a query.

Such sessions can cause additional problems, including holding locks and interfering with database maintenance.

### PostgreSQL System Views

| View | Purpose |
|---|---|
| `pg_stat_activity` | Displays database sessions |
| `pg_stat_database` | Displays database-level statistics |
| `pg_roles` | Displays PostgreSQL role configuration |
| `pg_settings` | Displays server parameters |

### Connection Monitoring

Amazon CloudWatch provides the `DatabaseConnections` metric for RDS instances.

This metric helps monitor connection activity but may not exactly equal the PostgreSQL session count from `pg_stat_activity`.

### Important Concepts

| Concept | Explanation |
|---|---|
| max_connections | Instance-wide connection limit |
| Role Connection Limit | Connection limit for a particular PostgreSQL role |
| Active Session | Session executing a query |
| Idle Session | Connected session not executing a query |
| Idle in Transaction | Session waiting while a transaction remains open |
| Connection Pool | Reuses database connections |
| RDS Proxy | Managed connection pooling service |
| PgBouncer | PostgreSQL connection pooler |
| pg_terminate_backend | Terminates a database session |
| DatabaseConnections | CloudWatch connection metric |
| Reserved Connections | Connection capacity reserved for privileged roles |

**Important:** This lab intentionally reaches the application role's connection limit rather than exhausting the entire instance's global `max_connections` limit.

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
- Keep the RDS instance private.
- Do not expose PostgreSQL to `0.0.0.0/0`.
- Use Systems Manager instead of exposing SSH.
- Use a dedicated application role for fault injection.
- Do not exhaust instance-wide connection capacity.
- Preserve administrator access.
- Terminate only verified test sessions.
- Avoid changing the global `max_connections` parameter.
- Do not commit passwords to GitHub.
- Remove temporary authentication files.
- Delete temporary AWS resources.

### Cost Warning

RDS instances, EC2 instances, EBS storage, public IPv4 addresses, and CloudWatch monitoring may incur charges.

The lab uses a small Single-AZ database, a small EC2 instance, and no NAT gateway to reduce costs.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab07"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab07-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab07-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export APP_USERNAME="lab07_app"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab07-client"
export EC2_ROLE_NAME="cloud-rds-lab07-ssm-role"
export PROFILE_NAME="cloud-rds-lab07-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab07-client-sg"
export DB_SG_NAME="cloud-rds-lab07-db-sg"

export ALARM_NAME="cloud-rds-lab07-connections"
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

Select compatible instance types and Availability Zones if necessary.

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

Avoid creating duplicate AWS resources.

---

## 7. Create the AWS VPC

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.197.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab07-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --cidr-block "10.197.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab07-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.197.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab07-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.197.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab07-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab07-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Configure Public Route Table

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab07-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Create the internet route:

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

The database subnets inherit the VPC main route table with local routing only.

---

## 8. Create Security Groups

### Step 1 — Create EC2 Client SG

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab07 EC2 client" \
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
  --description "Lab07 RDS PostgreSQL" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Authorize PostgreSQL Access

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

Expected:

```text
Protocol: TCP
Port: 5432
Source: Client Security Group
```

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

Allow IAM changes to propagate.

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

### Step 7 — Verify EC2 SG Association

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

## 10. Create RDS PostgreSQL

### Step 1 — Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab07 private database subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Verify DB Subnet Group

```bash
aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --query 'DBSubnetGroups[0].Subnets[].{Subnet:SubnetIdentifier,AZ:SubnetAvailabilityZone.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: two private subnets in different Availability Zones.

### Step 3 — Enter Database Password

```bash
read -rsp "Enter temporary RDS password: " DB_PASSWORD
echo
```

Use a strong, unique password.

The following disposable-lab command passes the password as a process argument. For production, prefer RDS-managed credentials in AWS Secrets Manager.

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

### Step 6 — Verify RDS Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible,Engine:Engine}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
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

## 11. Fault Injection — Too Many Database Connections

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
export APP_USERNAME="lab07_app"
```

Replace the endpoint placeholder.

### Step 2 — Verify DNS and TCP

```bash
getent ahostsv4 "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful DNS resolution and TCP connectivity.

### Step 3 — Connect as Administrator

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 4 — Check Instance Connection Limit

```sql
SHOW max_connections;
```

Record the actual value.

Inspect reserved connections:

```sql
SELECT name, setting
FROM pg_settings
WHERE name LIKE '%reserved_connections%'
ORDER BY name;
```

### Step 5 — Check Current Connections

```sql
SELECT COUNT(*) AS current_connections
FROM pg_stat_activity;
```

Inspect client sessions:

```sql
SELECT
    usename,
    state,
    COUNT(*) AS connections
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, state
ORDER BY connections DESC;
```

### Step 6 — Create Limited Application Role

```sql
CREATE ROLE lab07_app
LOGIN
CONNECTION LIMIT 5;
```

Set its password interactively:

```text
\password lab07_app
```

Grant database access:

```sql
GRANT CONNECT ON DATABASE labdb TO lab07_app;
```

```sql
GRANT USAGE ON SCHEMA public TO lab07_app;
```

### Step 7 — Verify Role Limit

```sql
SELECT
    rolname,
    rolcanlogin,
    rolconnlimit
FROM pg_roles
WHERE rolname = 'lab07_app';
```

Expected:

```text
rolname   | rolcanlogin | rolconnlimit
----------+-------------+-------------
lab07_app | true        | 5
```

Exit PostgreSQL:

```text
\q
```

### Step 8 — Configure Temporary Authentication

Inside EC2:

```bash
read -rsp "Enter lab07_app password: " APP_DB_PASSWORD
echo
```

Create a temporary password file:

```bash
export PGPASSFILE="$HOME/.pgpass-lab07"

umask 077

ESCAPED_PASSWORD=$(printf '%s' "$APP_DB_PASSWORD" \
  | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')

printf '%s:5432:labdb:lab07_app:%s\n' \
  "$DB_ENDPOINT" "$ESCAPED_PASSWORD" \
  > "$PGPASSFILE"

chmod 600 "$PGPASSFILE"

unset APP_DB_PASSWORD ESCAPED_PASSWORD
```

Verify login:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=lab07_app sslmode=require connect_timeout=5" \
  -c "SELECT current_user;"
```

Expected: `lab07_app`.

### Step 9 — Create Connection Load Script

Save as `load-connections.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${DB_ENDPOINT:?DB_ENDPOINT is required}"
: "${PGPASSFILE:?PGPASSFILE is required}"

echo "Starting five Lab 07 database sessions"

mkdir -p "$HOME/lab07-connections"

for worker in 1 2 3 4 5; do
    psql \
      "host=$DB_ENDPOINT port=5432 dbname=labdb user=lab07_app sslmode=require connect_timeout=5 application_name=lab07-worker-$worker" \
      -v ON_ERROR_STOP=1 \
      -c "SELECT pg_sleep(120);" \
      > "$HOME/lab07-connections/worker-$worker.log" \
      2>&1 &

    echo "$!" \
      > "$HOME/lab07-connections/worker-$worker.pid"

    echo "Started worker $worker"
done

echo "Five connection workers launched."
```

Inside EC2, create the script with a text editor or a heredoc and make it executable:

```bash
chmod +x load-connections.sh
```

### Step 10 — Start Connection Workload

```bash
./load-connections.sh
```

Expected:

```text
Starting five Lab 07 database sessions

Started worker 1
Started worker 2
Started worker 3
Started worker 4
Started worker 5

Five connection workers launched.
```

The workers each hold a connection while executing `pg_sleep(120)`.

### Step 11 — Verify Worker Processes

```bash
ps aux | grep '[p]sql'
```

Check worker logs:

```bash
ls -l "$HOME/lab07-connections/"
```

### Step 12 — Attempt Sixth Connection

While all five workers remain connected:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=lab07_app sslmode=require connect_timeout=5 application_name=lab07-sixth-client" \
  -c "SELECT current_user;"
```

Expected:

```text
FATAL: too many connections for role "lab07_app"
```

This is the intentional error.

If the existing sessions have already finished, rerun the load script and repeat the test before its 120-second window expires.

### Fault Injection Summary

| Check | Expected Result |
|---|---|
| RDS Status | Available |
| EC2 | Running |
| DNS | Working |
| TCP 5432 | Reachable |
| Application Role | lab07_app |
| Role Connection Limit | 5 |
| First Five Connections | Accepted |
| Sixth Connection | Rejected |
| Root Cause | Application connection limit reached |
| Administrator Access | Preserved |

---

## 12. Troubleshooting Investigation

### Check 1 — Verify RDS Status

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: RDS remains available and private.

### Check 2 — Inspect Application Role

Inside an administrator PostgreSQL session:

```sql
SELECT
    rolname,
    rolconnlimit
FROM pg_roles
WHERE rolname = 'lab07_app';
```

Expected: connection limit equals 5.

### Check 3 — Count Application Connections

```sql
SELECT
    usename,
    COUNT(*) AS total_connections
FROM pg_stat_activity
WHERE usename = 'lab07_app'
GROUP BY usename;
```

Expected during fault injection:

```text
lab07_app | 5
```

### Check 4 — Identify Session Details

```sql
SELECT
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - backend_start AS connection_age
FROM pg_stat_activity
WHERE usename = 'lab07_app'
ORDER BY backend_start;
```

Expected: five application worker sessions.

### Check 5 — Inspect Active SQL

```sql
SELECT
    pid,
    application_name,
    state,
    LEFT(query, 120) AS query
FROM pg_stat_activity
WHERE usename = 'lab07_app';
```

Expected:

```sql
SELECT pg_sleep(120);
```

### Check 6 — Compare Global Connection Limit

```sql
SHOW max_connections;
```

The global connection limit should not be exhausted by the five-connection application workload.

### Check 7 — Examine Session States

```sql
SELECT
    usename,
    state,
    COUNT(*) AS connections
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, state
ORDER BY connections DESC;
```

### Check 8 — Check Database Backend Count

```sql
SELECT
    datname,
    numbackends
FROM pg_stat_database
WHERE datname = 'labdb';
```

### Check 9 — Review CloudWatch Connections

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

Expected: connection activity increases during the workload.

The CloudWatch metric may not exactly equal the number of sessions displayed in `pg_stat_activity`.

### Check 10 — Review RDS Events

```bash
aws rds describe-events \
  --source-type db-instance \
  --source-identifier "$DB_IDENTIFIER" \
  --duration 60 \
  --query 'Events[].{Time:Date,Message:Message}' \
  --output table \
  --region "$AWS_REGION"
```

A connection-limit error may occur without producing an RDS event.

### Investigation Summary

| Investigation | Finding |
|---|---|
| RDS Status | Available |
| Database Endpoint | Valid |
| DNS | Working |
| TCP Connectivity | Working |
| Security Groups | Correct |
| Master Role | Can connect |
| Application Role | lab07_app |
| Application Role Limit | 5 |
| Occupied Connections | 5 |
| Sixth Connection | Rejected |
| Global max_connections | Not exhausted |
| Root Cause | Application role connection limit reached |

---

## 13. Root Cause Analysis

### Root Cause

The application role was configured with a maximum of five simultaneous PostgreSQL connections.

The simulated application opened five sessions and kept them occupied using long-running SQL statements.

When a sixth client attempted to connect using the same role, PostgreSQL rejected the new connection.

The failure occurred because the application had no available connection slots within its configured role limit.

### Technical Explanation

A PostgreSQL role can have a connection limit separate from the instance-wide `max_connections` parameter.

In this exercise:

```text
Application Role: lab07_app

Role Connection Limit: 5

Existing Connections: 5

Additional Connection: Rejected
```

The database itself remained healthy and available.

The failure was not related to DNS, VPC routing, security group authorization, or incorrect credentials.

### Root Cause Flow

```text
Application Requests
        |
        v
New PostgreSQL Sessions
        |
        v
Five Sessions Remain Open
        |
        v
Role Connection Limit Reached
        |
        v
Sixth Connection Attempt
        |
        X
No Available Application Slot
        |
        v
Connection Rejected
```

### Five Whys

1. **Why was the application connection rejected?** The application role reached its permitted connection limit.
2. **Why were all connection slots occupied?** Five sessions remained open.
3. **Why were connections unavailable for new requests?** The application did not release or reuse its existing connections.
4. **Why did PostgreSQL reject the sixth connection?** The role was configured with a maximum of five simultaneous connections.
5. **How can this be prevented?** Use connection pooling, proper session lifecycle management, monitoring, and realistic connection limits.

### Prevention

- Reuse application connections.
- Close unused database sessions.
- Monitor connection counts.
- Investigate idle sessions.
- Use connection pooling.
- Configure sensible application pool limits.
- Review connection timeouts.
- Avoid unnecessary connection retries.
- Monitor PostgreSQL and CloudWatch connection metrics.

---

## 14. Remediation — Release Unnecessary Connections

### Step 1 — Stop Connection Workers

Inside the original EC2 session:

```bash
for pidfile in "$HOME"/lab07-connections/*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
done
```

This stops the client processes when they are still running.

### Step 2 — Identify Remaining Sessions

Connect to PostgreSQL as administrator:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -W
```

Execute:

```sql
SELECT
    pid,
    usename,
    application_name,
    state
FROM pg_stat_activity
WHERE usename = 'lab07_app';
```

Verify the remaining sessions belong to the disposable lab.

### Step 3 — Terminate Remaining Lab Sessions

```sql
SELECT
    pid,
    pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE usename = 'lab07_app'
  AND application_name LIKE 'lab07-worker-%'
  AND pid <> pg_backend_pid();
```

This targets the lab-created application worker sessions.

In production, investigate session ownership and transaction impact before terminating database connections.

### Step 4 — Verify Connection Count

```sql
SELECT
    COUNT(*) AS remaining_connections
FROM pg_stat_activity
WHERE usename = 'lab07_app';
```

Expected: zero application connections after the workers stop and their sessions are removed.

### Step 5 — Verify Role Configuration

```sql
SELECT
    rolname,
    rolconnlimit
FROM pg_roles
WHERE rolname = 'lab07_app';
```

Expected: the limit remains 5.

No increase to the connection limit is required.

### Step 6 — Verify Application Reconnection

Exit administrator PostgreSQL:

```text
\q
```

Inside EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=lab07_app sslmode=require connect_timeout=5" \
  -c "SELECT current_user, current_database();"
```

Expected:

```text
current_user | current_database
-------------+-----------------
lab07_app    | labdb
```

### Step 7 — Verify SQL Query

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=lab07_app sslmode=require" \
  -c "SELECT 1 + 1 AS result;"
```

Expected:

```text
result
------
2
```

### Remediation Summary

| Check | Before Fix | After Fix |
|---|---|---|
| RDS Status | Available | Available |
| Role Limit | 5 | 5 |
| Worker Connections | 5 | 0 |
| New Application Connection | Rejected | Successful |
| PostgreSQL Authentication | Limited by occupied slots | Successful |
| SQL Execution | Cannot begin for sixth client | Successful |
| RDS Public Access | Disabled | Disabled |

---

## 15. Final Verification

### Verify RDS Availability

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Public: False
```

### Verify Database Connections

Inside PostgreSQL:

```sql
SELECT
    usename,
    state,
    COUNT(*) AS connections
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, state;
```

### Verify Application Role Limit

```sql
SELECT
    rolname,
    rolconnlimit
FROM pg_roles
WHERE rolname = 'lab07_app';
```

### Verify PostgreSQL Connectivity

Inside EC2:

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful TCP connectivity.

### Verify Application Query

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=lab07_app sslmode=require" \
  -c "SELECT 'Connection restored' AS status;"
```

Expected:

```text
Connection restored
```

### Configure CloudWatch Alarm

From WSL:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Lab07 RDS connections above 5" \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value="$DB_IDENTIFIER" \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --region "$AWS_REGION"
```

This is an illustrative instance-level CloudWatch alarm.

It monitors total database connections rather than the specific `lab07_app` role limit.

Administrative and other connections may also contribute to the metric.

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
| RDS Instance | Available |
| DNS Resolution | Working |
| TCP 5432 | Reachable |
| Application Role | Valid |
| Application Role Limit | 5 |
| Excessive Worker Sessions | Removed |
| New Application Connection | Successful |
| PostgreSQL SQL Query | Successful |
| CloudWatch Monitoring | Configured |
| RDS Public Access | Disabled |
| Incident | Resolved |

---

## 16. Production Best Practices

### Database Connection Troubleshooting Checklist

1. Identify the affected application.
2. Verify RDS instance status.
3. Check database endpoint and network connectivity.
4. Review the connection error.
5. Inspect `max_connections`.
6. Check application role connection limits.
7. Count active database sessions.
8. Inspect `pg_stat_activity`.
9. Identify idle and long-running connections.
10. Check CloudWatch `DatabaseConnections`.
11. Confirm whether the limit is role-level or instance-wide.
12. Identify unnecessary client sessions.
13. Release connections safely.
14. Verify new application connections.
15. Review application connection pooling.
16. Configure monitoring and prevention.

### Connection Pooling Recommendations

Connection pooling helps applications reuse existing database connections.

Without pooling:

```text
Request 1 → Connection 1
Request 2 → Connection 2
Request 3 → Connection 3
Request 4 → Connection 4
Request 5 → Connection 5
Request 6 → Rejected
```

With pooling:

```text
              Application Requests
                       |
                       v
                  Connection Pool
                       |
             ---------------------
             |         |         |
             v         v         v
           Conn 1    Conn 2    Conn 3
             |         |         |
             +---------+---------+
                       |
                       v
                  PostgreSQL
```

### Amazon RDS Proxy

Amazon RDS Proxy provides managed database connection pooling for supported database engines.

It can help applications reuse database connections and reduce connection-management overhead.

### PgBouncer

PgBouncer is a lightweight PostgreSQL connection pooler.

It supports different pooling strategies and can reduce the number of database connections required by an application.

### Production Recommendations

- Use connection pooling.
- Configure reasonable pool sizes.
- Close unused application sessions.
- Avoid idle transactions.
- Configure appropriate connection timeouts.
- Monitor application concurrency.
- Review connection leaks.
- Keep administrative access available.
- Monitor database memory.
- Avoid increasing `max_connections` without capacity analysis.
- Configure CloudWatch alerts.
- Review database connection usage regularly.

### Key Cloud Security Lesson

Database availability depends on resource management as well as networking and authentication.

An application can cause an availability incident by opening too many connections.

Connection limits, monitoring, and connection pooling help reduce the risk of resource exhaustion.

---

## 17. Cleanup

**Warning:** These commands permanently delete the disposable Lab 07 RDS database and its associated infrastructure.

### Step 1 — Stop Workers

Inside EC2:

```bash
for pidfile in "$HOME"/lab07-connections/*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
done
```

### Step 2 — Remove Temporary Authentication Files

```bash
rm -f "$HOME/.pgpass-lab07"

rm -rf "$HOME/lab07-connections"

unset PGPASSFILE
```

Exit Systems Manager:

```bash
exit
```

### Step 3 — Verify RDS Ownership

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

Confirm the database has:

```text
Project=RDS-Troubleshooting-Lab07
```

### Step 4 — Delete CloudWatch Alarm

```bash
aws cloudwatch delete-alarms \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

### Step 5 — Delete RDS

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

The disposable database and application role are removed with the RDS instance.

### Step 6 — Delete DB Subnet Group

```bash
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION"
```

### Step 7 — Verify EC2 Root Volume Settings

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

### Step 10 — Verify Network Interface Cleanup

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the EC2 and RDS network interfaces are removed.

### Step 11 — Delete Security Groups

Delete the database SG first:

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

Also verify EC2, EBS, IAM, DB subnet group, and CloudWatch alarm removal.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| RDS Database | Deleted |
| DB Subnet Group | Deleted |
| EC2 Client | Terminated |
| Root EBS Volume | Deleted |
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

### Q1. What causes too many database connections in RDS PostgreSQL?

Common causes include excessive application concurrency, connection leaks, idle sessions, missing connection pooling, and configured connection limits being reached.

### Q2. What is max_connections?

It is a PostgreSQL parameter that controls the maximum number of concurrent connections allowed by the database instance.

### Q3. How do you inspect max_connections?

```sql
SHOW max_connections;
```

### Q4. What is pg_stat_activity?

It is a PostgreSQL system view that displays database session information, including process IDs, usernames, states, queries, and client addresses.

### Q5. What is the difference between an active and idle connection?

An active connection is executing a query. An idle connection remains connected but is not currently executing a query.

### Q6. What is a role connection limit?

It restricts how many simultaneous connections a particular PostgreSQL role may establish, subject to PostgreSQL's enforcement rules.

### Q7. What is the difference between max_connections and a role connection limit?

`max_connections` controls instance-wide connection capacity, while a role connection limit restricts a specific database role.

### Q8. What is RDS Proxy?

Amazon RDS Proxy is a managed database proxy that supports connection pooling and reduces connection-management overhead.

### Q9. What is PgBouncer?

PgBouncer is a PostgreSQL connection pooler that allows applications to reuse database connections.

### Q10. Why should max_connections not be increased without investigation?

Each database connection consumes memory and processing resources. Increasing the limit without adequate capacity can cause resource pressure.

### Q11. How can you recover from connection exhaustion?

Identify unnecessary sessions, stop connection leaks, release or terminate verified idle connections, and implement appropriate connection pooling.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL database and an EC2 troubleshooting client inside the same VPC.

I created a dedicated application role with a maximum of five simultaneous connections.

I intentionally opened five PostgreSQL sessions and attempted a sixth connection, which was rejected because the role reached its connection limit.

I investigated the issue using `pg_stat_activity`, `pg_stat_database`, PostgreSQL role configuration, and Amazon CloudWatch `DatabaseConnections`.

After identifying the occupied application connection slots, I stopped the workload and terminated the unnecessary sessions.

I verified that new PostgreSQL connections succeeded and reviewed connection pooling solutions such as RDS Proxy and PgBouncer.

The database remained private throughout the exercise.

---

## 19. Repository Structure

```text
07-rds-too-many-database-connections/
├── README.md
├── ec2-trust-policy.json
└── load-connections.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete production incident, troubleshooting, remediation, and cleanup |
| `ec2-trust-policy.json` | EC2 IAM trust policy for Systems Manager |
| `load-connections.sh` | Reproduces a controlled PostgreSQL role connection-limit error |

The load script should be saved in the repository without credentials or environment-specific secrets.

No PostgreSQL passwords, AWS access keys, or temporary password files should be committed.

---

## 20. Lessons Learned

This lab demonstrates how PostgreSQL connection limits can prevent applications from accessing a database even when the RDS instance is healthy.

The database networking and security group configurations were correct.

However, the application role reached its maximum permitted connections.

We used PostgreSQL system views to identify the occupied sessions and determine why new connections were rejected.

After releasing the unnecessary application sessions, PostgreSQL accepted new connections.

We also investigated the importance of connection pooling, session lifecycle management, and CloudWatch monitoring.

**Key Lesson:** When an application reports too many database connections, investigate connection usage, role limits, and instance-wide capacity before changing network settings or increasing the database instance size.

---

## 21. Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Amazon EC2 administration
- Amazon VPC networking
- AWS Systems Manager
- PostgreSQL role management
- PostgreSQL connection limits
- `max_connections`
- `pg_stat_activity`
- `pg_stat_database`
- `pg_roles`
- Database session investigation
- PostgreSQL session termination
- CloudWatch `DatabaseConnections`
- Connection pooling concepts
- Amazon RDS Proxy concepts
- PgBouncer concepts
- Bash scripting
- Controlled connection fault injection
- Root cause analysis
- Least-privilege database administration
- Private database connectivity
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-007 |
| Problem | Too Many Database Connections |
| Database Engine | PostgreSQL |
| Database | labdb |
| Application Role | lab07_app |
| Application Connection Limit | 5 |
| Fault Injection | Five occupied database connections |
| Expected Error | Too many connections for role |
| Root Cause | Application connection slots exhausted |
| Investigation | PostgreSQL system views and CloudWatch |
| Remediation | Release unnecessary application sessions |
| New PostgreSQL Connection | Successful |
| SQL Query | Successful |
| RDS Public Access | Disabled |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Reliable database operations require effective connection management. Monitoring session usage, investigating connection limits, and implementing connection pooling help prevent application outages caused by database connection exhaustion.