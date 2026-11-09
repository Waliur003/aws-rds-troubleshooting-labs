# Lab 12 — RDS Parameter Group Misconfiguration

## Overview

This lab demonstrates how to troubleshoot Amazon RDS PostgreSQL configuration problems caused by incorrect database parameter group settings.

We deploy a private RDS PostgreSQL database and an Amazon Linux 2023 EC2 troubleshooting client in the same VPC.

We create a custom RDS DB parameter group and associate it with the PostgreSQL database.

After verifying normal database operation, we intentionally configure the `statement_timeout` parameter to **1000 milliseconds (1 second)**.

This setting causes SQL statements running longer than one second to be cancelled.

We reproduce the application failure using a three-second PostgreSQL query, investigate the configuration using AWS CLI and PostgreSQL system views, and identify the incorrect parameter.

We then reset the parameter to its default setting, verify the change is applied, and confirm that the previously failing query executes successfully.

The lab also investigates dynamic and static parameters, PostgreSQL engine families, the `pending-reboot` status, and safe database configuration management.

Finally, we delete the custom parameter group and temporary AWS infrastructure.

**Troubleshooting workflow:**

Infrastructure Setup → Custom Parameter Group → Baseline Verification → Fault Injection → SQL Failure → Investigation → Root Cause Analysis → Remediation → Final Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-012 |
| Difficulty | Advanced |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager |
| Database Engine | PostgreSQL |
| RDS Instance | `cloud-rds-lab12-postgres` |
| Instance Class | `db.t4g.micro` |
| Storage | 20 GiB gp3 |
| Storage Encryption | Enabled |
| Database Name | `labdb` |
| Master Username | `labadmin` |
| Database Port | TCP 5432 |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| VPC | `10.202.0.0/16` |
| Public Subnet | `10.202.1.0/24` |
| Private Subnet A | `10.202.2.0/24` |
| Private Subnet B | `10.202.3.0/24` |
| Custom Parameter Group | `cloud-rds-lab12-custom-pg` |
| Fault Parameter | `statement_timeout` |
| Fault Value | `1000` milliseconds |
| Test Query | `SELECT pg_sleep(3);` |
| Expected Error | Statement timeout |
| Remediation | Reset parameter to default |
| Static Parameter Investigation | `max_connections` |
| RDS Public Access | Disabled |
| Deployment Type | Single-AZ |
| Incident Status | Resolved after successful verification |

---

## 2. Production Incident Scenario

### Incident Description

A company uses Amazon RDS PostgreSQL to support an application running on Amazon EC2.

The application performs database queries for customer reports and business operations.

Initially, the database works normally.

After a database configuration change, developers report that longer SQL queries begin failing.

The application displays an error similar to:

```text
ERROR: canceling statement due to statement timeout
```

The operations team investigates and confirms that:

- The RDS instance remains available.
- PostgreSQL authentication works.
- Security groups are correctly configured.
- The database endpoint resolves successfully.
- Short SQL queries execute normally.
- Longer SQL queries are cancelled.

The Cloud Engineer discovers that a custom RDS parameter group contains an incorrect value:

```text
statement_timeout = 1000
```

This configuration limits SQL statement execution to approximately one second.

The engineer must identify the incorrect setting and restore the expected database behavior.

### Incident Symptoms

- RDS reports `available`.
- TCP port 5432 is reachable.
- PostgreSQL connections succeed.
- Short SQL queries succeed.
- Long-running queries fail.
- The custom parameter group is associated with RDS.
- `statement_timeout` is set to 1000 milliseconds.
- PostgreSQL reports a statement timeout error.
- Resetting the parameter allows the test query to complete.

### Business Impact

- Reporting queries fail.
- Application users may receive errors.
- Database-dependent background jobs may stop.
- Long-running analytical queries may be cancelled.
- Application reliability decreases.
- Developers may incorrectly suspect database infrastructure problems.
- Unnecessary restarts or networking changes may delay recovery.

### Objective

Identify and remediate a PostgreSQL parameter group misconfiguration without introducing unnecessary infrastructure changes.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                         AWS Region
                          us-east-1
                              |
                              v
                         Amazon VPC
                       10.202.0.0/16
                              |
             ---------------------------------
             |                               |
             v                               v
        Public Subnet                  Private Subnets
       10.202.1.0/24                  10.202.2.0/24
             |                        10.202.3.0/24
             v                               |
        EC2 Client                           v
     Amazon Linux 2023                RDS PostgreSQL
             |                               |
             |                               v
             |                       Custom Parameter
             |                            Group
             |                               |
             |                               v
             |                       statement_timeout
             |                            1000 ms
             |                               |
             +-------- TCP 5432 -------------+
                                             |
                                             v
                                        SQL Query
                                             |
                                             v
                                       pg_sleep(3)
                                             |
                                             X
                                      Query Cancelled
```

### Fault Injection Flow

```text
PostgreSQL Working Normally
              |
              v
Create Custom Parameter Group
              |
              v
Associate Group with RDS
              |
              v
Set statement_timeout = 1000
              |
              v
Execute SELECT pg_sleep(3)
              |
              v
Statement Runs Beyond 1 Second
              |
              v
PostgreSQL Cancels Query
              |
              v
Application Error
```

### Recovery Flow

```text
Investigate Query Failure
              |
              v
Inspect RDS Parameter Group
              |
              v
Identify statement_timeout
              |
              v
Reset Parameter to Default
              |
              v
Verify Running PostgreSQL Setting
              |
              v
Execute SELECT pg_sleep(3)
              |
              v
Query Completes
```

### Networking Configuration

| Component | Configuration |
|---|---|
| VPC | `10.202.0.0/16` |
| Public Subnet | `10.202.1.0/24` |
| Private Subnet A | `10.202.2.0/24` |
| Private Subnet B | `10.202.3.0/24` |
| EC2 Routing | Internet Gateway |
| Database Routing | VPC local route |
| EC2 Security Group | `cloud-rds-lab12-client-sg` |
| RDS Security Group | `cloud-rds-lab12-db-sg` |
| Database Access | EC2 SG to RDS SG, TCP 5432 |
| Database Public Access | Disabled |
| EC2 Administration | AWS Systems Manager |

---

## 4. Understanding RDS Parameter Groups

### What Is a DB Parameter Group?

An Amazon RDS DB parameter group is a collection of configuration settings that control database engine behavior.

Examples include:

- Query execution timeout
- Database connection limits
- Memory allocation
- Query logging
- Buffer management
- Database performance settings

### Default Parameter Groups

AWS provides default parameter groups for each supported database engine family.

Their parameter values cannot be directly modified.

To customize settings, create a custom parameter group.

### Custom Parameter Groups

Custom parameter groups allow users to manage supported database engine parameters.

Example:

```text
cloud-rds-lab12-custom-pg
```

### PostgreSQL Parameter Group Families

Parameter groups must match the database engine family.

Examples:

```text
postgres16
postgres17
postgres18
```

The correct family depends on the PostgreSQL engine version.

Always retrieve the actual family before creating a custom parameter group.

### Dynamic Parameters

Dynamic parameters can normally take effect without rebooting the database.

Examples include:

```text
statement_timeout
log_min_duration_statement
work_mem
```

### Static Parameters

Static parameters require the database to restart before changes take effect.

Examples include:

```text
max_connections
shared_buffers
```

### statement_timeout

The PostgreSQL `statement_timeout` setting specifies the maximum time a SQL statement can run before PostgreSQL cancels it.

Example:

```text
statement_timeout = 1000
```

This means one second.

The normal default is:

```text
statement_timeout = 0
```

A value of `0` disables this particular timeout.

### pending-reboot

RDS may report the parameter group status as:

```text
pending-reboot
```

This indicates that some configuration changes have not yet been applied.

A manual reboot may be necessary.

### Important Distinction

| Operation | Reboot Required |
|---|---|
| Associate a new parameter group | Yes, for its settings to take effect |
| Modify an associated dynamic parameter with immediate apply | Normally no |
| Modify a static parameter | Yes |
| Reset an associated dynamic parameter immediately | Normally no |
| Reset a static parameter | Yes |

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Amazon RDS permissions
- Amazon EC2 permissions
- VPC permissions
- IAM permissions
- Systems Manager access
- PostgreSQL client
- Git and GitHub

### Safety Rules

- Use a disposable RDS database.
- Never intentionally misconfigure production parameter groups.
- Keep RDS private.
- Restrict PostgreSQL access to the EC2 security group.
- Do not open database ports to the internet.
- Use Systems Manager instead of SSH.
- Record the original parameter settings.
- Avoid modifying memory and connection limits.
- Do not reboot unrelated databases.
- Do not commit AWS credentials or database passwords.
- Remove all lab infrastructure after completion.

### Cost Warning

Amazon RDS, EC2, EBS storage, and public IPv4 addresses may incur charges.

This lab uses a small Single-AZ database to reduce costs.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab12"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab12-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab12-subnet-group"
export PARAM_GROUP="cloud-rds-lab12-custom-pg"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_CLASS="db.t4g.micro"

export EC2_NAME="cloud-rds-lab12-client"
export EC2_ROLE_NAME="cloud-rds-lab12-ssm-role"
export PROFILE_NAME="cloud-rds-lab12-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab12-client-sg"
export DB_SG_NAME="cloud-rds-lab12-db-sg"
```

### Step 2 — Verify AWS Credentials

```bash
aws sts get-caller-identity

aws --version
```

### Step 3 — Verify RDS Instance Class

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class "$DB_CLASS" \
  --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass,Version:EngineVersion}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Verify EC2 Availability

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose supported Availability Zones if necessary.

### Step 5 — Check Existing Resources

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='$DB_IDENTIFIER'].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" \
  --output table \
  --region "$AWS_REGION"
```

```bash
aws rds describe-db-parameter-groups \
  --query "DBParameterGroups[?DBParameterGroupName=='$PARAM_GROUP'].DBParameterGroupName" \
  --output table \
  --region "$AWS_REGION"
```

Avoid creating duplicate resources.

---

## 7. Create AWS VPC and Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.202.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab12-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --cidr-block "10.202.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab12-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.202.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab12-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.202.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab12-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab12-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab12-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Create internet route:

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

The RDS subnets remain private.

---

## 8. Create Security Groups

### Step 1 — Create EC2 Client Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab12 EC2 troubleshooting client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create Database Security Group

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab12 RDS PostgreSQL" \
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

### Step 4 — Verify Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: only the EC2 client security group can access port 5432.

---

## 9. Deploy EC2 Troubleshooting Client

### Step 1 — Create IAM Trust Policy

Create `ec2-trust-policy.json`:

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
  --db-subnet-group-description "Lab12 private RDS subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Enter Temporary Password

```bash
read -rsp "Enter disposable RDS password: " DB_PASSWORD
echo
```

Use a strong, unique password.

### Step 3 — Create Database

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
  --no-multi-az \
  --backup-retention-period 0 \
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
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Database

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the database is available and private.

### Step 6 — Retrieve Endpoint

```bash
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$DB_ENDPOINT"
```

### Step 7 — Retrieve Engine Version

```bash
export ENGINE_VERSION=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].EngineVersion' \
  --output text \
  --region "$AWS_REGION")

echo "$ENGINE_VERSION"
```

### Step 8 — Retrieve Parameter Family

```bash
export PARAM_FAMILY=$(aws rds describe-db-engine-versions \
  --engine postgres \
  --engine-version "$ENGINE_VERSION" \
  --query 'DBEngineVersions[0].DBParameterGroupFamily' \
  --output text \
  --region "$AWS_REGION")

echo "$PARAM_FAMILY"
```

The actual parameter family must match the engine version.

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

Replace the placeholder with the actual endpoint.

### Step 2 — Verify Networking

```bash
getent ahostsv4 "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful DNS and TCP connectivity.

### Step 3 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 4 — Inspect Initial Timeout

```sql
SHOW statement_timeout;
```

Normally:

```text
0
```

Inspect the parameter:

```sql
SELECT
    name,
    setting,
    unit,
    context,
    source,
    pending_restart
FROM pg_settings
WHERE name = 'statement_timeout';
```

Record the baseline.

### Step 5 — Run Three-Second Query

```sql
SELECT pg_sleep(3);
```

Expected: query succeeds when no stricter timeout applies.

### Step 6 — Verify Normal SQL

```sql
SELECT 1 + 1 AS result;
```

Expected:

```text
2
```

Exit:

```text
\q
```

### Baseline Summary

| Check | Expected Result |
|---|---|
| RDS | Available |
| DNS | Working |
| TCP 5432 | Working |
| PostgreSQL Login | Successful |
| statement_timeout | Baseline recorded |
| Three-Second Query | Successful |
| Short Query | Successful |

---

## 12. Create and Associate Custom Parameter Group

### Step 1 — Create Custom Group

From WSL:

```bash
aws rds create-db-parameter-group \
  --db-parameter-group-name "$PARAM_GROUP" \
  --db-parameter-group-family "$PARAM_FAMILY" \
  --description "Lab12 custom PostgreSQL parameter group" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Group

```bash
aws rds describe-db-parameter-groups \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query 'DBParameterGroups[0].{Name:DBParameterGroupName,Family:DBParameterGroupFamily}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Inspect Dynamic Parameter

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query "Parameters[?ParameterName=='statement_timeout'].{Name:ParameterName,Value:ParameterValue,ApplyType:ApplyType,Modifiable:IsModifiable,Allowed:AllowedValues}" \
  --output table \
  --region "$AWS_REGION"
```

Expected: `statement_timeout` is dynamic and modifiable.

### Step 4 — Inspect Static Parameter

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query "Parameters[?ParameterName=='max_connections'].{Name:ParameterName,Value:ParameterValue,ApplyType:ApplyType}" \
  --output table \
  --region "$AWS_REGION"
```

Expected: static parameter.

### Step 5 — Associate Custom Group

```bash
aws rds modify-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --db-parameter-group-name "$PARAM_GROUP" \
  --apply-immediately \
  --region "$AWS_REGION"
```

### Step 6 — Investigate Parameter Group Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBParameterGroups' \
  --output json \
  --region "$AWS_REGION"
```

The custom group may report:

```text
pending-reboot
```

### Step 7 — Reboot to Apply Association

Verify the disposable instance is available:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text \
  --region "$AWS_REGION"
```

Reboot:

```bash
aws rds reboot-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 8 — Wait for RDS

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 9 — Verify Group Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBParameterGroups' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the custom group is associated and reports `in-sync` after its settings are applied.

---

## 13. Fault Injection — Incorrect statement_timeout

### Step 1 — Modify statement_timeout

From WSL:

```bash
aws rds modify-db-parameter-group \
  --db-parameter-group-name "$PARAM_GROUP" \
  --parameters \
    "ParameterName=statement_timeout,ParameterValue=1000,ApplyMethod=immediate" \
  --region "$AWS_REGION"
```

This intentionally configures a one-second statement timeout.

### Step 2 — Verify the AWS Parameter

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query "Parameters[?ParameterName=='statement_timeout'].{Name:ParameterName,Value:ParameterValue,ApplyType:ApplyType,Source:Source}" \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
ParameterName: statement_timeout
Value: 1000
ApplyType: dynamic
Source: user
```

### Step 3 — Connect Using a Fresh PostgreSQL Session

Inside EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 4 — Verify Effective Timeout

```sql
SHOW statement_timeout;
```

Expected after propagation:

```text
1s
```

If the old value remains, wait for the configuration update and open a fresh session.

### Step 5 — Reproduce the Query Failure

```sql
SELECT pg_sleep(3);
```

Expected:

```text
ERROR: canceling statement due to statement timeout
```

### Step 6 — Verify Short Queries Work

```sql
SELECT 1 + 1 AS result;
```

Expected:

```text
2
```

### Step 7 — Verify Database Availability

```sql
SELECT current_database(), current_user;
```

Expected: successful query.

Exit:

```text
\q
```

### Fault Injection Summary

| Check | Baseline | Misconfigured |
|---|---|---|
| RDS Status | Available | Available |
| PostgreSQL Login | Successful | Successful |
| statement_timeout | Default | 1000 ms |
| Short Query | Successful | Successful |
| Three-Second Query | Successful | Cancelled |
| Root Cause | None | Incorrect timeout |

---

## 14. Troubleshooting Investigation

### Check 1 — Verify RDS Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

### Check 2 — Verify Associated Group

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBParameterGroups' \
  --output json \
  --region "$AWS_REGION"
```

### Check 3 — Find User-Modified Parameters

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --source user \
  --query 'Parameters[].{Name:ParameterName,Value:ParameterValue,ApplyType:ApplyType}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the custom timeout appears.

### Check 4 — Inspect PostgreSQL Settings

Inside a new PostgreSQL session:

```sql
SELECT
    name,
    setting,
    unit,
    context,
    source,
    pending_restart
FROM pg_settings
WHERE name = 'statement_timeout';
```

### Check 5 — Investigate Role and Database Overrides

```sql
SELECT
    COALESCE(r.rolname, 'ALL ROLES') AS role_name,
    COALESCE(d.datname, 'ALL DATABASES') AS database_name,
    s.setconfig
FROM pg_db_role_setting AS s
LEFT JOIN pg_roles AS r
    ON r.oid = s.setrole
LEFT JOIN pg_database AS d
    ON d.oid = s.setdatabase;
```

Check whether additional settings override the parameter group.

### Check 6 — Inspect Static Parameters

From WSL:

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query "Parameters[?ParameterName=='max_connections' || ParameterName=='shared_buffers'].{Name:ParameterName,ApplyType:ApplyType,Value:ParameterValue}" \
  --output table \
  --region "$AWS_REGION"
```

Do not modify these parameters in the lab.

### Investigation Matrix

| Investigation | Expected Finding |
|---|---|
| RDS Status | Available |
| Security Groups | Correct |
| PostgreSQL Login | Working |
| Short SQL | Working |
| Long SQL | Cancelled |
| Custom Parameter Group | Associated |
| statement_timeout | 1000 ms |
| Parameter Type | Dynamic |
| Root Cause | Configuration error |

---

## 15. Root Cause Analysis

### Root Cause

The custom RDS PostgreSQL DB parameter group contained the setting:

```text
statement_timeout = 1000
```

This restricted SQL statement execution to approximately one second.

When the application executed a longer SQL query, PostgreSQL cancelled it.

The database remained healthy, and network connectivity was not affected.

The incident was caused by an incorrect database configuration rather than an infrastructure outage.

### Root Cause Flow

```text
Database Configuration Changed
              |
              v
statement_timeout = 1000
              |
              v
Application Executes Query
              |
              v
SELECT pg_sleep(3)
              |
              v
Execution Exceeds 1 Second
              |
              v
PostgreSQL Cancels Statement
              |
              v
Application Error
```

### Five Whys

1. **Why did SQL execution fail?** PostgreSQL cancelled the query.
2. **Why was it cancelled?** The query exceeded the configured statement timeout.
3. **Why was the timeout so short?** It was configured to 1000 milliseconds.
4. **Why did the setting affect the application?** The custom parameter group was associated with the RDS database and applied.
5. **How can the issue be prevented?** Review parameter changes, test application behavior, monitor errors, and maintain rollback procedures.

### Root Cause Summary

| Item | Finding |
|---|---|
| Incident Type | Configuration misconfiguration |
| Affected Parameter | statement_timeout |
| Incorrect Value | 1000 ms |
| Database Availability | Healthy |
| SQL Failure | Statement cancellation |
| Required Fix | Reset timeout |
| Infrastructure Replacement | Not required |

---

## 16. Remediation — Restore Parameter Configuration

### Step 1 — Reset statement_timeout

From WSL:

```bash
aws rds reset-db-parameter-group \
  --db-parameter-group-name "$PARAM_GROUP" \
  --parameters \
    "ParameterName=statement_timeout,ApplyMethod=immediate" \
  --region "$AWS_REGION"
```

This removes the custom override and restores the inherited default value.

### Step 2 — Verify Parameter Group

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query "Parameters[?ParameterName=='statement_timeout'].{Name:ParameterName,Value:ParameterValue,Source:Source,ApplyType:ApplyType}" \
  --output table \
  --region "$AWS_REGION"
```

Verify the custom value is no longer active.

### Step 3 — Open a Fresh PostgreSQL Session

Inside EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 4 — Verify Timeout

```sql
SHOW statement_timeout;
```

Expected with the default configuration:

```text
0
```

If it differs, investigate additional role, database, and session settings.

### Step 5 — Repeat the Failed Query

```sql
SELECT pg_sleep(3);
```

Expected: the query completes successfully.

### Step 6 — Verify Normal SQL

```sql
SELECT 10 + 20 AS result;
```

Expected:

```text
30
```

### Step 7 — Inspect Effective Configuration

```sql
SELECT
    name,
    setting,
    unit,
    source,
    pending_restart
FROM pg_settings
WHERE name = 'statement_timeout';
```

Record the actual values.

Exit:

```text
\q
```

### Remediation Summary

| Check | Before Fix | After Fix |
|---|---|---|
| Timeout | 1000 ms | Default |
| Three-Second Query | Failed | Successful |
| Short Queries | Successful | Successful |
| PostgreSQL Login | Successful | Successful |
| RDS Availability | Available | Available |
| Reboot for Dynamic Reset | Normally unnecessary | Not required |

---

## 17. Static vs. Dynamic Parameters and Final Verification

### Investigate Dynamic Parameters

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query "Parameters[?ParameterName=='statement_timeout' || ParameterName=='log_min_duration_statement'].{Name:ParameterName,ApplyType:ApplyType}" \
  --output table \
  --region "$AWS_REGION"
```

### Investigate Static Parameters

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query "Parameters[?ParameterName=='max_connections' || ParameterName=='shared_buffers'].{Name:ParameterName,ApplyType:ApplyType}" \
  --output table \
  --region "$AWS_REGION"
```

### Understanding pending-reboot

A parameter group might show:

```text
pending-reboot
```

This status indicates that changes require a reboot before becoming effective.

For static parameters, a manual reboot is normally necessary.

Changing an already associated dynamic parameter with `ApplyMethod=immediate` does not normally require a reboot.

### Parameter Comparison

| Parameter | Type | Purpose |
|---|---|---|
| statement_timeout | Dynamic | SQL execution timeout |
| log_min_duration_statement | Dynamic | Slow-query logging |
| work_mem | Dynamic | Query processing memory |
| max_connections | Static | Maximum connections |
| shared_buffers | Static | Shared memory buffer cache |

### Final AWS Verification

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible,Groups:DBParameterGroups}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Public: False
Parameter Group: cloud-rds-lab12-custom-pg
Apply Status: in-sync
```

### Final PostgreSQL Verification

```sql
SHOW statement_timeout;

SELECT pg_sleep(3);

SELECT 10 + 20 AS result;
```

Expected: the timeout is restored and both queries succeed.

### Verification Matrix

| Check | Baseline | During Fault | After Fix |
|---|---|---|---|
| RDS Available | Yes | Yes | Yes |
| PostgreSQL Login | Works | Works | Works |
| statement_timeout | Default | 1000 ms | Default |
| Short Query | Works | Works | Works |
| Three-Second Query | Works | Fails | Works |
| Parameter Group | Default/Custom | Custom | Custom |
| Public Access | Disabled | Disabled | Disabled |

---

## 18. AWS Resource Cleanup

**Warning:** These commands permanently delete the disposable Lab 12 database and infrastructure.

### Step 1 — Exit PostgreSQL and EC2

Exit PostgreSQL:

```text
\q
```

Exit Systems Manager:

```bash
exit
```

### Step 2 — Verify Database Ownership

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

Verify:

```text
Project=RDS-Troubleshooting-Lab12
```

### Step 3 — Delete RDS Database

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

### Step 4 — Verify Parameter Group Ownership

```bash
export PARAM_GROUP_ARN=$(aws rds describe-db-parameter-groups \
  --db-parameter-group-name "$PARAM_GROUP" \
  --query 'DBParameterGroups[0].DBParameterGroupArn' \
  --output text \
  --region "$AWS_REGION")

aws rds list-tags-for-resource \
  --resource-name "$PARAM_GROUP_ARN" \
  --region "$AWS_REGION"
```

Confirm the lab project tag.

### Step 5 — Delete Custom Parameter Group

```bash
aws rds delete-db-parameter-group \
  --db-parameter-group-name "$PARAM_GROUP" \
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

Verify `DeleteOnTermination=true`.

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

### Step 10 — Verify Network Interface Cleanup

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until RDS and EC2 network interfaces are removed.

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

Check RDS:

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='$DB_IDENTIFIER'].DBInstanceIdentifier" \
  --output json \
  --region "$AWS_REGION"
```

Check parameter groups:

```bash
aws rds describe-db-parameter-groups \
  --query "DBParameterGroups[?DBParameterGroupName=='$PARAM_GROUP'].DBParameterGroupName" \
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

Expected:

```json
[]
```

Also verify EC2, EBS, IAM, security groups, and the DB subnet group have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| RDS PostgreSQL | Deleted |
| Custom Parameter Group | Deleted |
| DB Subnet Group | Deleted |
| EC2 Client | Terminated |
| Root EBS Volume | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Client SG | Deleted |
| Database SG | Deleted |
| Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 19. Interview Questions and Answers

### Q1. What is an RDS DB parameter group?

A collection of database engine configuration settings associated with an RDS database instance.

### Q2. Can you modify a default DB parameter group?

No. You must create a custom parameter group.

### Q3. What is the difference between static and dynamic parameters?

Dynamic parameters can normally be modified without restarting RDS. Static parameters require a reboot.

### Q4. What is statement_timeout?

A PostgreSQL parameter that controls how long a SQL statement can execute before PostgreSQL cancels it.

### Q5. What does statement_timeout = 1000 mean?

It configures a one-second SQL statement timeout.

### Q6. What does statement_timeout = 0 mean?

It disables the timeout enforced by that specific setting.

### Q7. What is pending-reboot?

It indicates that a configuration change requires a reboot before being applied.

### Q8. How do you inspect the running timeout?

```sql
SHOW statement_timeout;
```

### Q9. How do you identify modified RDS parameters?

```bash
aws rds describe-db-parameters \
  --db-parameter-group-name my-custom-group \
  --source user
```

### Q10. Why must the parameter group family match the engine version?

Database engine families have different supported settings and valid parameter values.

### Q11. How would you fix a PostgreSQL parameter misconfiguration?

Identify the affected parameter, verify its running value, compare it with the intended configuration, correct it, and validate database and application behavior.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL database and an EC2 troubleshooting client.

I created a custom DB parameter group and associated it with the PostgreSQL instance.

I investigated the difference between static and dynamic parameters.

I intentionally configured `statement_timeout` to 1000 milliseconds to reproduce SQL query cancellations.

I used AWS CLI and PostgreSQL system views to identify the misconfiguration.

After confirming the root cause, I reset the parameter to its default value.

I then verified that the previously failing three-second query completed successfully without changing database networking or replacing the RDS instance.

The exercise also helped me understand parameter group associations, reboot requirements, and safe database change management.

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
├── 10-rds-multi-az-failover/
├── 11-rds-backup-restore-failure/
│
└── 12-rds-parameter-group-misconfiguration/
    ├── README.md
    └── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete parameter group incident and troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager access |

Do not commit AWS credentials, database passwords, or sensitive configuration files.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how an Amazon RDS PostgreSQL configuration error can affect applications even when the database infrastructure remains healthy.

We created a custom parameter group and associated it with PostgreSQL.

We investigated the default configuration and reproduced an application-level timeout by setting `statement_timeout` to 1000 milliseconds.

We used AWS CLI and PostgreSQL system views to identify the effective parameter value.

We then reset the parameter and verified that the previously failing query worked again.

The lab also demonstrated the difference between dynamic and static parameters and why some parameter group operations require a reboot.

**Key Lesson:** Database reliability depends on correct configuration as well as healthy infrastructure. A Cloud Engineer must investigate database parameters before assuming that application errors are caused by networking, compute, or storage failures.

### Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Custom DB parameter groups
- Parameter group family identification
- Dynamic database parameters
- Static database parameters
- `statement_timeout`
- `max_connections` investigation
- PostgreSQL `pg_settings`
- Parameter override investigation
- `pending-reboot` troubleshooting
- RDS reboot procedures
- Configuration rollback
- PostgreSQL error investigation
- SQL query verification
- AWS Systems Manager
- Private VPC networking
- Root cause analysis
- Database change management
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-012 |
| Problem | RDS Parameter Group Misconfiguration |
| Database Engine | PostgreSQL |
| Custom Parameter Group | Created |
| Fault Parameter | statement_timeout |
| Fault Value | 1000 ms |
| SQL Failure | Statement timeout |
| RDS Availability | Maintained |
| Root Cause | Incorrect timeout configuration |
| Remediation | Reset parameter |
| Query After Fix | Successful |
| Parameter Group Status | in-sync |
| Public Accessibility | Disabled |
| Cleanup | Temporary infrastructure removed |
| Incident Status | Resolved after verification |

**Key Takeaway:** Effective RDS parameter group troubleshooting requires understanding database settings, parameter application methods, reboot requirements, SQL behavior, and configuration rollback procedures.