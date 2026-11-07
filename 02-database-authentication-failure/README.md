# Lab 02 — RDS Database Authentication Failure

## Overview

This lab demonstrates how to investigate and resolve a PostgreSQL authentication failure on Amazon Relational Database Service (Amazon RDS).

We deploy a private RDS PostgreSQL database and an Amazon Linux 2023 EC2 troubleshooting client inside the same VPC.

First, we verify that the database is reachable over TCP port `5432`. Next, we create a dedicated PostgreSQL application role named `appuser` and grant it limited database permissions.

We intentionally attempt to connect with an incorrect password, reproducing the following error:

```text
FATAL: password authentication failed for user "appuser"
```

We investigate the database endpoint, network connectivity, PostgreSQL role, login permissions, and database privileges.

After identifying the incorrect password as the root cause, we securely reset the application user's password and verify successful authentication.

The exercise demonstrates the difference between **network connectivity, database authentication, and database authorization**.

**Troubleshooting workflow:**

Infrastructure Setup → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-002 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager |
| Database Engine | PostgreSQL |
| RDS Instance Class | `db.t4g.micro` |
| RDS Storage | 20 GiB gp3 |
| Deployment | Private, Single-AZ |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| Database | `labdb` |
| Master Username | `labadmin` |
| Application Username | `appuser` |
| Database Port | TCP `5432` |
| Fault Injection | Enter incorrect application-user password |
| Expected Error | `password authentication failed` |
| Root Cause | Incorrect PostgreSQL credentials |
| Remediation | Reset application-role password |
| Verification | Successful login and SQL query |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts an application that connects to Amazon RDS PostgreSQL.

The application previously worked correctly, but users begin experiencing database-related errors after an application credential change.

The cloud engineering team confirms that the RDS instance is running and that the EC2 application server can reach the database endpoint.

However, the application cannot successfully authenticate.

The PostgreSQL client displays:

```text
psql: error: connection to server failed:
FATAL: password authentication failed for user "appuser"
```

The engineer must determine whether the issue involves the network, the database endpoint, the username, the password, or database permissions.

### Incident Symptoms

- RDS status is `available`.
- Database endpoint resolves successfully.
- TCP port `5432` is reachable.
- The master database user can authenticate.
- The application user exists.
- The application user has the `LOGIN` attribute.
- Authentication fails when an incorrect password is supplied.
- Database access works after the password is corrected.

### Business Impact

- Application database connections fail.
- Users cannot access database-dependent features.
- Application requests may return errors.
- Scheduled database operations may fail.
- Application availability decreases.
- Credential changes may cause service disruption if not coordinated.

### Objective

Identify and resolve the PostgreSQL credential mismatch without modifying working network configurations or granting unnecessary database privileges.

---

## 3. AWS Architecture

### Infrastructure

```text
                      AWS VPC
                   10.191.0.0/16
                           |
               -------------------------
               |                       |
               v                       v
          Public Subnet           Private Subnets
         10.191.1.0/24           10.191.2.0/24
               |                 10.191.3.0/24
               v                       |
          Amazon EC2                   v
         Amazon Linux             Amazon RDS
               |                  PostgreSQL
               |                       |
               v                       v
          Client SG                Database SG
               |                       |
               +------ TCP 5432 ------>+
                                       |
                                       v
                                Database: labdb
                                       |
                                       v
                                 Role: appuser
```

### Authentication Failure

```text
                  EC2 Client
                      |
                      v
                RDS DNS Endpoint
                      |
                      v
               TCP 5432 Connected
                      |
                      v
              PostgreSQL Authentication
                      |
                      v
                User: appuser
                Wrong Password
                      |
                      X
             Authentication Rejected
                      |
                      v
        FATAL: password authentication failed
```

### Recovered Architecture

```text
               PostgreSQL Admin
                      |
                      v
              Verify appuser Role
                      |
                      v
              Reset Role Password
                      |
                      v
               EC2 psql Client
                      |
                      v
             Correct New Password
                      |
                      v
             Authentication Success
                      |
                      v
              Authorized SQL Query
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.191.0.0/16` |
| Public Subnet | `10.191.1.0/24` |
| Private Subnet A | `10.191.2.0/24` |
| Private Subnet B | `10.191.3.0/24` |
| EC2 Security Group | No inbound rules required |
| RDS Security Group | TCP 5432 from EC2 client SG |
| RDS Public Access | Disabled |
| EC2 Management | AWS Systems Manager |
| Database TLS | Required by `psql` connection string |

---

## 4. Understanding Database Authentication

Database authentication verifies that a user has supplied valid credentials.

Database authorization determines which resources and operations that authenticated user may access.

Network connectivity must work before PostgreSQL authentication can take place.

### Connection Stages

```text
Stage 1: DNS Resolution
         |
         v
Stage 2: TCP Connection
         |
         v
Stage 3: PostgreSQL Authentication
         |
         v
Stage 4: Database Authorization
         |
         v
Stage 5: SQL Query Execution
```

### Authentication vs. Authorization

| Feature | Authentication | Authorization |
|---|---|---|
| Main Question | Who are you? | What can you do? |
| PostgreSQL Example | Username and password | SELECT, INSERT, CREATE |
| Common Failure | Password authentication failed | Permission denied |
| Typical Remediation | Correct credentials | Review role grants |

### Common PostgreSQL Errors

| Error | Possible Cause |
|---|---|
| Connection timed out | Network or security group issue |
| Connection refused | Port or service connectivity issue |
| Could not resolve hostname | DNS problem |
| Password authentication failed | Incorrect credentials or login configuration |
| Database does not exist | Incorrect database name |
| Permission denied for table | Missing object privileges |
| Too many connections | Connection limit reached |

**Important:** A password authentication failure demonstrates that the database server was reached. It should not be treated as a security group timeout.

---

## 5. Prerequisites

### Tools

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Amazon Linux 2023
- PostgreSQL `psql`
- `nc`
- `dig`
- AWS Systems Manager
- Git and GitHub

### Security Requirements

- Use a disposable lab database.
- Keep RDS private.
- Allow database traffic only from the client security group.
- Do not expose PostgreSQL to `0.0.0.0/0`.
- Use unique database passwords.
- Do not place passwords in GitHub.
- Use encrypted database connections.
- Do not use the RDS master account as an application account.
- Verify resources before deleting them.

### Cost Warning

RDS, EC2, EBS storage, and public IPv4 addresses may incur AWS charges.

Delete the dedicated resources after completing the lab.

---

## 6. Prepare the AWS Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab02"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab02-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab02-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export APP_USERNAME="appuser"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab02-client"
export EC2_ROLE_NAME="cloud-rds-lab02-ssm-role"
export PROFILE_NAME="cloud-rds-lab02-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab02-client-sg"
export DB_SG_NAME="cloud-rds-lab02-db-sg"
```

### Step 2 — Verify AWS Access

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

Check RDS PostgreSQL compatibility:

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass,Version:EngineVersion}' \
  --output table \
  --region "$AWS_REGION"
```

If the requested class or Availability Zone is unavailable, select a supported option before creating resources.

---

## 7. Create AWS Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "10.191.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab02-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

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
  --cidr-block "10.191.1.0/24" \
  --availability-zone "$AZ_A" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.191.2.0/24" \
  --availability-zone "$AZ_A" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.191.3.0/24" \
  --availability-zone "$AZ_B" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
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
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"

export PUBLIC_RT_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION"
```

### Step 7 — Create EC2 Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab02 PostgreSQL client" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 8 — Create RDS Security Group

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab02 PostgreSQL database" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Tag both:

```bash
aws ec2 create-tags \
  --resources "$CLIENT_SG_ID" "$DB_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 9 — Allow PostgreSQL Traffic

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: TCP port `5432` allowed only from the EC2 client security group.

---

## 8. Deploy the EC2 Client

### Step 1 — Create EC2 Trust Policy

Save `ec2-trust-policy.json`:

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

Wait:

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Install PostgreSQL Tools

Connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo dnf install -y postgresql15 nmap-ncat bind-utils

psql --version
command -v nc
command -v dig
```

Exit:

```bash
exit
```

---

## 9. Create Private RDS PostgreSQL

### Step 1 — Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab02 private PostgreSQL subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Enter Temporary Master Password

```bash
read -rsp "Enter a temporary RDS master password: " DB_PASSWORD
echo
```

Use a strong, unique lab password. Do not commit it.

For production, prefer RDS-managed master credentials or approved AWS Secrets Manager workflows.

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
  --port "$DB_PORT" \
  --no-publicly-accessible \
  --no-multi-az \
  --backup-retention-period 0 \
  --no-deletion-protection \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

Note: The example above supplies the password as a CLI argument, which can briefly expose it to local process inspection. Use only in the disposable lab.

Remove the local variable:

```bash
unset DB_PASSWORD
```

### Step 4 — Wait for Availability

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Database State

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

## 10. Establish the Healthy Baseline

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
export DB_ENDPOINT="YOUR_ACTUAL_RDS_ENDPOINT"
export DB_PORT="5432"
```

Replace the placeholder with the real RDS hostname.

### Step 2 — Verify DNS

```bash
getent hosts "$DB_ENDPOINT"
dig +short "$DB_ENDPOINT"
```

Expected: private RDS IP address resolves.

### Step 3 — Verify TCP Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: TCP connection succeeds.

### Step 4 — Connect as Master User

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Enter the correct master password interactively.

### Step 5 — Verify Database Identity

```sql
SELECT current_database(), current_user;
```

Expected database: `labdb`.

Expected user: `labadmin`.

---

## 11. Create the Application Role

### Step 1 — Create appuser

Inside the administrator `psql` session:

```sql
CREATE ROLE appuser WITH LOGIN;
```

### Step 2 — Set Initial Application Password

Run this `psql` meta-command:

```text
\password appuser
```

Enter a new application password twice.

Do not enter passwords in committed SQL scripts.

### Step 3 — Grant Database Connection

```sql
GRANT CONNECT ON DATABASE labdb TO appuser;
```

### Step 4 — Grant Schema Access

```sql
GRANT USAGE ON SCHEMA public TO appuser;
```

### Step 5 — Create Sample Table

```sql
CREATE TABLE IF NOT EXISTS public.lab02_application_data (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

Insert the test record:

```sql
INSERT INTO public.lab02_application_data (id, message)
VALUES (1, 'RDS Authentication Lab 02');
```

### Step 6 — Grant Read-Only Table Access

```sql
GRANT SELECT ON public.lab02_application_data TO appuser;
```

### Step 7 — Inspect the Application Role

```sql
SELECT rolname, rolcanlogin, rolsuper
FROM pg_roles
WHERE rolname = 'appuser';
```

Expected:

```text
appuser | t | f
```

Exit:

```text
\q
```

### Step 8 — Test Valid Credentials

From EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=appuser sslmode=require connect_timeout=5" \
  -W
```

Enter the correct initial application password.

Inside `psql`:

```sql
SELECT current_user;

SELECT * FROM public.lab02_application_data;
```

Expected: successful login and test row returned.

Exit with `\q`.

**Healthy baseline:** DNS, TCP connectivity, authentication, and authorized table reads are working.

---

## 12. Fault Injection — Incorrect Password

### Step 1 — Attempt Login With Wrong Credentials

Inside EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=appuser sslmode=require connect_timeout=5" \
  -W
```

When prompted, intentionally enter an incorrect password.

### Expected Error

```text
FATAL: password authentication failed for user "appuser"
```

The exact full error message may vary.

### Step 2 — Verify TCP Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: connection succeeds.

### Step 3 — Compare Symptoms

| Check | Expected Result |
|---|---|
| DNS | Working |
| TCP 5432 | Reachable |
| RDS Status | Available |
| PostgreSQL Server | Responding |
| Application Login | Failed |
| Error Type | Authentication |
| Known Cause | Incorrect password |

**Important:** The connection reached PostgreSQL. Therefore, changing network security groups is not the appropriate remediation for this incident.

---

## 13. Troubleshooting Investigation

### Check 1 — Inspect the Error

```text
FATAL: password authentication failed for user "appuser"
```

This indicates that PostgreSQL rejected the credentials.

### Check 2 — Verify Database Endpoint

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint' \
  --output json \
  --region "$AWS_REGION"
```

Compare with the client endpoint.

### Check 3 — Verify RDS Availability

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `available`, public access disabled.

### Check 4 — Verify Security Group Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: inbound TCP `5432` from the client security group.

### Check 5 — Verify Master Authentication

Inside EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Enter the valid master password.

Expected: successful login.

### Check 6 — Inspect the Application Role

Inside administrator `psql`:

```sql
SELECT rolname, rolcanlogin, rolsuper
FROM pg_roles
WHERE rolname = 'appuser';
```

Expected: `appuser` exists, can log in, and is not a superuser.

### Check 7 — Verify Database Privileges

```sql
SELECT has_database_privilege(
    'appuser',
    'labdb',
    'CONNECT'
);
```

Expected: `true`.

### Check 8 — Verify Table Permissions

```sql
SELECT has_table_privilege(
    'appuser',
    'public.lab02_application_data',
    'SELECT'
);
```

Expected: `true`.

### Check 9 — Inspect Password Expiration

```sql
SELECT rolname, rolcanlogin, rolvaliduntil
FROM pg_roles
WHERE rolname = 'appuser';
```

Expected: login enabled; password expiration is not responsible for the controlled failure.

### Investigation Summary

| Component | Finding |
|---|---|
| RDS Database | Healthy |
| DNS | Working |
| TCP 5432 | Reachable |
| Security Group | Correct |
| Master User | Authenticates |
| Application Role | Exists |
| LOGIN Attribute | Enabled |
| CONNECT Privilege | Present |
| SELECT Privilege | Present |
| Supplied Password | Incorrect |
| Root Cause | Credential mismatch |

---

## 14. Root Cause Analysis

### Root Cause

The PostgreSQL application user attempted to authenticate using a password that did not match the role's configured credential.

PostgreSQL rejected the login.

The issue was not caused by the network, VPC, RDS security group, database availability, or table permissions.

### Technical Explanation

PostgreSQL validates authentication information before establishing an authenticated database session.

If the supplied password is incorrect, the server rejects the login and returns an authentication error.

The user cannot execute SQL queries until authentication succeeds.

### Root Cause Flow

```text
EC2 Database Client
        |
        v
RDS Endpoint Resolved
        |
        v
TCP 5432 Connected
        |
        v
PostgreSQL Authentication
        |
        v
Incorrect appuser Password
        |
        X
Authentication Rejected
```

### Five Whys

1. **Why did the application fail?** PostgreSQL rejected authentication.
2. **Why did PostgreSQL reject authentication?** The supplied password was incorrect.
3. **Why did network troubleshooting not fix it?** Network connectivity was already working.
4. **Why did the master user succeed?** Valid credentials were supplied for that user.
5. **How can the problem be prevented?** Manage credentials securely and coordinate secret updates with application deployment.

### Prevention

- Use AWS Secrets Manager or an approved secret-management system.
- Keep application credentials synchronized.
- Validate secrets after rotation.
- Use dedicated application database roles.
- Avoid master credentials in application configurations.
- Monitor authentication failures.
- Do not expose passwords in logs or source code.

---

## 15. Remediation — Reset appuser Password

### Step 1 — Connect as Administrator

Inside EC2:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Enter the correct master password.

### Step 2 — Reset Application Password

Inside `psql`:

```text
\password appuser
```

Enter the new password twice.

This changes the password without modifying the role's existing privileges.

### Step 3 — Verify the Role

```sql
SELECT rolname, rolcanlogin, rolsuper
FROM pg_roles
WHERE rolname = 'appuser';
```

Expected:

```text
appuser | t | f
```

Exit using `\q`.

### Step 4 — Retry Application Login

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=appuser sslmode=require connect_timeout=5" \
  -W
```

Enter the newly configured password.

Expected: successful connection.

### Step 5 — Verify Authenticated User

```sql
SELECT current_database(), current_user;
```

Expected:

```text
labdb | appuser
```

### Step 6 — Verify Table Read

```sql
SELECT * FROM public.lab02_application_data;
```

Expected:

```text
 id |             message
----+--------------------------------
  1 | RDS Authentication Lab 02
```

### Step 7 — Verify Least Privilege

As `appuser`, test an operation outside the granted permissions:

```sql
CREATE TABLE public.unauthorized_test (
    id INTEGER
);
```

Expected for the lab's default schema permissions:

```text
ERROR: permission denied for schema public
```

If the command succeeds, review existing schema grants and role memberships instead of assuming authorization is restricted.

### Remediation Summary

| Check | Before | After |
|---|---|---|
| DNS | Working | Working |
| TCP | Reachable | Reachable |
| PostgreSQL Authentication | Failed | Successful |
| appuser Password | Incorrect | Reset |
| appuser LOGIN | Enabled | Enabled |
| Database Access | Blocked by authentication | Restored |
| SELECT Query | Cannot run | Successful |
| Role Privileges | Restricted | Restricted |
| RDS Public Access | Disabled | Disabled |

---

## 16. Final Verification

### AWS Verification

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible,Endpoint:Endpoint}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Public: False
Port: 5432
```

### Linux Network Verification

Inside EC2:

```bash
getent hosts "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: DNS and TCP tests succeed.

### PostgreSQL Verification

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=appuser sslmode=require" \
  -W
```

Then:

```sql
SELECT current_user;

SELECT * FROM public.lab02_application_data;
```

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| RDS Status | Available |
| Database Public Access | Disabled |
| DNS | Resolves |
| TCP 5432 | Successful |
| Application Role | Exists |
| Application Password | Updated |
| Authentication | Successful |
| Database CONNECT | Allowed |
| Table SELECT | Allowed |
| Superuser Privilege | Not granted |
| Incident | Resolved |

---

## 17. Production Best Practices

### Authentication Troubleshooting Checklist

1. Verify the database endpoint.
2. Check RDS availability.
3. Test DNS resolution.
4. Test TCP port connectivity.
5. Inspect the PostgreSQL error.
6. Verify the intended database username.
7. Check whether the role exists.
8. Check whether the role has LOGIN enabled.
9. Inspect password expiration.
10. Verify database CONNECT permissions.
11. Verify object permissions.
12. Confirm the application's approved secret source.
13. Reset or rotate credentials only when necessary.
14. Update application secrets securely.
15. Test a new database connection.
16. Confirm the application has only required permissions.

### Security Recommendations

- Keep RDS private.
- Require TLS for connections where appropriate.
- Use dedicated application roles.
- Follow least-privilege database access.
- Store passwords in AWS Secrets Manager or an approved secret store.
- Never hardcode credentials.
- Avoid putting credentials in CLI history, application logs, or GitHub.
- Rotate credentials using an operationally safe process.
- Monitor failed authentication attempts.
- Review database access regularly.

### Cloud Security Lesson

A successful network connection does not guarantee successful database authentication.

Likewise, successful authentication does not guarantee permission to access a database object.

Cloud engineers must troubleshoot each layer independently.

---

## 18. Cleanup

**Warning:** These commands permanently delete the disposable database, sample data, and lab infrastructure.

### Step 1 — Exit PostgreSQL and EC2

From PostgreSQL:

```text
\q
```

Exit the SSM session:

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

aws rds list-tags-for-resource \
  --resource-name "$DB_ARN" \
  --region "$AWS_REGION"
```

Confirm the `Project` tag is `RDS-Troubleshooting-Lab02`.

### Step 3 — Delete RDS

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

### Step 4 — Delete DB Subnet Group

```bash
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION"
```

### Step 5 — Verify EC2 Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root volume is set to `DeleteOnTermination=true`.

### Step 6 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete IAM Resources

Verify the IAM role is dedicated to Lab 02:

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

### Step 8 — Verify AWS ENI Cleanup

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait for EC2 and RDS network interfaces to disappear.

### Step 9 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Public Routing

```bash
aws ec2 disassociate-route-table \
  --association-id "$PUBLIC_RT_ASSOC" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete Subnets

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

### Step 12 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Verify Cleanup

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='$DB_IDENTIFIER'].DBInstanceIdentifier" \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-vpcs \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected: empty arrays after successful deletion.

Also confirm that the EC2 instance, root EBS volume, IAM role, and instance profile are gone.

---

## 19. Interview Questions and Answers

### Q1. What does PostgreSQL password authentication failed mean?

PostgreSQL rejected the supplied login credentials.

### Q2. What is the difference between a connection timeout and authentication failure?

A connection timeout occurs when the client cannot establish the network connection. An authentication failure occurs after PostgreSQL is reached but rejects the credentials.

### Q3. How can you test RDS network connectivity?

Use `nc -vz` with the RDS endpoint and port `5432`.

### Q4. What is the default PostgreSQL port?

TCP `5432`.

### Q5. How do you list PostgreSQL roles?

Use `\du` inside `psql` or query the `pg_roles` system view.

### Q6. What does rolcanlogin mean?

It indicates whether a PostgreSQL role is permitted to log in.

### Q7. How can you securely reset a PostgreSQL role password?

Use `\password username` inside an authorized `psql` session.

### Q8. Why shouldn't an application use the master database user?

The master account has elevated permissions. Applications should use dedicated roles with limited privileges.

### Q9. Can PostgreSQL authentication succeed but SQL operations still fail?

Yes. Successful authentication does not automatically grant permission to read or modify tables.

### Q10. What does GRANT CONNECT do?

It authorizes a role to connect to a database but does not grant unrestricted access to database objects.

### Q11. How should production RDS credentials be stored?

Use approved secret management, such as AWS Secrets Manager, with appropriate IAM access controls and rotation.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL instance and an EC2 client inside the same VPC.

I configured the security groups correctly and verified TCP connectivity to the database on port 5432.

I created a dedicated PostgreSQL application user with restricted database access.

I intentionally attempted a login using an incorrect password and reproduced the PostgreSQL authentication failure.

I investigated the database endpoint, network connectivity, user role, LOGIN attribute, database privileges, and application credentials.

After identifying the incorrect password as the root cause, I securely reset the application user's password and verified successful authentication and SQL queries.

I completed the recovery without modifying working network security rules or granting unnecessary database privileges.

---

## 20. Repository Structure

```text
02-database-authentication-failure/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete RDS authentication troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for the EC2 Systems Manager role |

Do not commit passwords, AWS access keys, secret files, or database credentials.

---

## 21. Lessons Learned

This lab demonstrates that database authentication failures must be investigated separately from network connectivity problems.

The RDS instance was running correctly, and the EC2 client could reach PostgreSQL on TCP port 5432.

However, the application login failed because the supplied password was incorrect.

We used `psql`, AWS CLI, SQL role queries, and Linux networking tools to identify the problem.

We also practiced managing a dedicated application database role and verifying its permissions.

After resetting the password, the application user authenticated successfully and accessed the authorized test table.

**Key Lesson:** When PostgreSQL returns `password authentication failed`, first verify network connectivity and the intended database identity, then investigate credentials and role configuration. Do not weaken network or database security to fix a credential mismatch.

---

## 22. Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Linux troubleshooting
- PostgreSQL `psql`
- PostgreSQL roles
- Database authentication
- Database authorization
- SQL GRANT permissions
- PostgreSQL password resets
- Secure credential handling
- VPC networking
- Security group verification
- DNS troubleshooting
- TCP connectivity testing
- AWS Systems Manager
- Least-privilege database access
- Root cause analysis
- Safe AWS cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-002 |
| Problem | Database authentication failure |
| RDS Engine | PostgreSQL |
| Database | labdb |
| Application User | appuser |
| Network Connectivity | Working |
| Fault Injection | Incorrect password |
| Root Cause | Credential mismatch |
| Remediation | Reset appuser password |
| Database Login | Restored |
| Authorized SQL Query | Successful |
| Application Role | Non-superuser |
| RDS Public Access | Disabled |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Reliable cloud database troubleshooting requires understanding the difference between network connectivity, authentication, and authorization. Solve the specific failing layer while preserving least-privilege security.
