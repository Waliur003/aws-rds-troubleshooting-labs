# Lab 08 — RDS DNS Endpoint Investigation

## Overview

This lab demonstrates how to investigate and troubleshoot Amazon RDS PostgreSQL connectivity failures caused by incorrect DNS endpoints and client-side hostname resolution problems.

We deploy a private Amazon RDS PostgreSQL database and an Amazon Linux 2023 EC2 troubleshooting instance inside the same VPC.

The database initially operates normally. We verify the RDS endpoint using Linux DNS tools, establish TCP connectivity, and execute PostgreSQL queries.

We then reproduce two common production incidents:

1. **Incorrect RDS endpoint:** The application uses an invalid database hostname, resulting in a DNS resolution failure.
2. **Incorrect local hostname override:** The EC2 client's `/etc/hosts` file maps the correct RDS hostname to `127.0.0.1`, causing applications to connect to the wrong address.

We investigate these failures using `dig`, `nslookup`, `getent`, `nc`, AWS CLI, VPC DNS attributes, and DHCP options.

After identifying the root causes, we correct the endpoint, restore the original hostname configuration, and verify successful PostgreSQL connectivity.

Finally, we review DNS TTL, RDS endpoint behavior during failover, production best practices, and AWS resource cleanup.

**Troubleshooting workflow:**

Infrastructure Setup → Baseline Verification → DNS Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-008 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager, Route 53 Resolver |
| Database Engine | PostgreSQL |
| RDS Instance | `db.t4g.micro` |
| RDS Storage | 20 GiB gp3 |
| RDS Deployment | Private, Single-AZ |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| Database Name | `labdb` |
| Database Username | `labadmin` |
| Database Port | TCP `5432` |
| VPC CIDR | `10.198.0.0/16` |
| EC2 Public Subnet | `10.198.1.0/24` |
| RDS Private Subnet A | `10.198.2.0/24` |
| RDS Private Subnet B | `10.198.3.0/24` |
| RDS Public Access | Disabled |
| Fault Injection 1 | Incorrect RDS hostname |
| Fault Injection 2 | Incorrect `/etc/hosts` mapping |
| Primary Tools | `dig`, `nslookup`, `getent`, `nc`, `psql` |
| Root Causes | Endpoint configuration and hostname override |
| Remediation | Correct endpoint and restore `/etc/hosts` |
| Verification | DNS, TCP, and PostgreSQL connectivity |

---

## 2. Production Incident Scenario

### Incident Description

A company runs an application on Amazon EC2 and stores customer information in Amazon RDS PostgreSQL.

The database is deployed in private subnets and is accessible only from the application security group.

The application initially works normally.

After a configuration change, application requests begin failing because the PostgreSQL client cannot resolve the database hostname.

Example error:

```text
could not translate host name
to address: Name or service not known
```

The operations team investigates the database and confirms that RDS remains available.

The database security group permits the required traffic, and the VPC routing configuration is correct.

However, the application is using an incorrect RDS endpoint.

In a second incident scenario, the endpoint is correct, but a local hostname override causes the operating system to resolve the database hostname to `127.0.0.1`.

Consequently, the application attempts to connect to the local EC2 instance rather than the RDS database.

The Cloud Engineer must identify whether the problem is caused by DNS, local hostname configuration, networking, or PostgreSQL authentication.

### Incident Symptoms

- RDS remains `available`.
- Database security groups are correctly configured.
- Application requests fail to connect to PostgreSQL.
- An incorrect endpoint may produce an `NXDOMAIN` DNS response.
- `getent` may return an incorrect address.
- `dig` may return a different address from `getent`.
- TCP connectivity fails when the client uses the incorrect hostname or IP address.
- PostgreSQL login succeeds after correcting hostname resolution.

### Business Impact

- Application requests may fail.
- Customer-facing services may become unavailable.
- Database-dependent background jobs may stop.
- Application connection attempts may time out or fail.
- Monitoring may report database connection errors.
- Incorrect DNS caching may delay recovery after failover.
- Incident resolution may be delayed if DNS and network problems are confused.

### Objective

Investigate RDS endpoint resolution, reproduce hostname-related failures, identify client-side DNS misconfigurations, and restore secure PostgreSQL connectivity without exposing the database or modifying unrelated AWS infrastructure.

---

## 3. AWS Architecture

### Infrastructure Architecture

```text
                       AWS Region
                        us-east-1
                            |
                            v
                       Amazon VPC
                     10.198.0.0/16
                            |
           -----------------------------------
           |                                 |
           v                                 v
      Public Subnet                    Private Subnets
     10.198.1.0/24                    10.198.2.0/24
           |                          10.198.3.0/24
           v                                 |
      EC2 Client                             v
   Amazon Linux 2023                   RDS PostgreSQL
           |                                 |
           v                                 |
      DNS Resolution                         |
           |                                 |
           v                                 |
     Route 53 Resolver                       |
      169.254.169.253                        |
           |                                 |
           v                                 |
      RDS DNS Endpoint                       |
           |                                 |
           v                                 |
     Private IP Address                      |
           |                                 |
           +----------- TCP 5432 ------------+
                                             |
                                             v
                                         PostgreSQL
```

### Fault 1 — Incorrect Endpoint

```text
                    EC2 Application
                           |
                           v
                  Incorrect RDS Hostname
                           |
                           v
                       DNS Query
                           |
                           v
                         NXDOMAIN
                           |
                           X
                   No IP Resolution
                           |
                           v
                   PostgreSQL Failure
```

### Fault 2 — Incorrect `/etc/hosts`

```text
                   Correct RDS Hostname
                           |
                           v
                     EC2 /etc/hosts
                           |
                           v
                      127.0.0.1
                           |
                           v
                   Local EC2 Loopback
                           |
                           X
                   PostgreSQL Failure

Meanwhile:

RDS Hostname → Amazon DNS → Correct Private IP
```

### Recovered Architecture

```text
                   EC2 Application
                          |
                          v
                  Correct RDS Endpoint
                          |
                          v
                 Correct Name Resolution
                          |
                          v
                    Private RDS IP
                          |
                          v
                       TCP 5432
                          |
                          v
                    PostgreSQL Login
                          |
                          v
                   Successful SQL Query
```

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.198.0.0/16` |
| Public Subnet | `10.198.1.0/24` |
| Private Subnet A | `10.198.2.0/24` |
| Private Subnet B | `10.198.3.0/24` |
| EC2 Routing | Internet Gateway |
| RDS Routing | VPC local route |
| EC2 Security Group | `cloud-rds-lab08-client-sg` |
| RDS Security Group | `cloud-rds-lab08-db-sg` |
| PostgreSQL Access | EC2 SG to RDS SG, TCP 5432 |
| DNS | AmazonProvidedDNS |
| RDS Public Access | Disabled |
| EC2 Administration | Systems Manager |

---

## 4. Understanding RDS DNS Resolution

### What Is an RDS Endpoint?

An RDS endpoint is an AWS-managed DNS hostname used by database clients to connect to an RDS database.

Example endpoint format:

```text
cloud-rds-lab08-postgres.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com
```

The exact endpoint is created by AWS and retrieved using the RDS API.

Applications should use this endpoint instead of hardcoding the database's current IP address.

### How DNS Resolution Works

```text
Application
    |
    v
RDS Endpoint Hostname
    |
    v
Operating System Resolver
    |
    v
DNS Resolver
    |
    v
RDS Private IP
    |
    v
TCP Connection
    |
    v
PostgreSQL
```

### AmazonProvidedDNS

Amazon VPC provides an integrated DNS resolver called Amazon Route 53 Resolver.

For this lab, it is available at:

```text
169.254.169.253
```

It can also be accessed at:

```text
10.198.0.2
```

The second address is derived from the VPC's primary IPv4 CIDR block.

### enableDnsSupport

The `enableDnsSupport` VPC attribute controls DNS resolution through the Amazon-provided DNS server.

This attribute should be enabled for the lab.

### enableDnsHostnames

The `enableDnsHostnames` attribute controls whether eligible EC2 instances can receive public DNS hostnames.

It does not directly define the RDS endpoint, but correct VPC DNS configuration is important for AWS networking.

### DNS TTL

Time to Live, or TTL, determines how long DNS information may be cached.

RDS underlying IP addresses can change during maintenance or failover.

Applications should respect DNS TTL values and establish new connections using the correct endpoint.

### Linux DNS Investigation Tools

| Tool | Purpose |
|---|---|
| `dig` | Queries DNS records |
| `nslookup` | Performs DNS lookups |
| `getent` | Uses system hostname lookup configuration |
| `cat /etc/resolv.conf` | Shows configured DNS resolvers |
| `cat /etc/hosts` | Shows local hostname overrides |
| `nc` | Tests TCP connectivity |
| `psql` | Tests PostgreSQL connectivity |
| AWS CLI | Retrieves actual RDS and VPC configuration |

**Important:** DNS resolution, TCP connectivity, and database authentication are separate troubleshooting layers.

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
- AWS Systems Manager
- PostgreSQL client
- Linux networking tools
- Git and GitHub

### Security Guidelines

- Use a disposable database.
- Keep RDS private.
- Do not allow PostgreSQL access from `0.0.0.0/0`.
- Manage EC2 through Systems Manager.
- Use synthetic database records.
- Do not modify WSL DNS settings.
- Do not disable VPC DNS support.
- Modify `/etc/hosts` only on the disposable EC2 instance.
- Back up `/etc/hosts` before changing it.
- Restore the original file after fault injection.
- Do not hardcode RDS private IP addresses.
- Never commit database passwords.
- Delete temporary resources after completing the lab.

### Cost Warning

Amazon RDS, EC2, EBS storage, public IPv4 addresses, and related resources may incur charges.

The lab uses a small Single-AZ RDS instance and no NAT gateway to reduce costs.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab08"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab08-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab08-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab08-client"
export EC2_ROLE_NAME="cloud-rds-lab08-ssm-role"
export PROFILE_NAME="cloud-rds-lab08-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab08-client-sg"
export DB_SG_NAME="cloud-rds-lab08-db-sg"
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

Choose supported Availability Zones if necessary.

### Step 5 — Check Existing Resources

```bash
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='$DB_IDENTIFIER'].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" \
  --output table \
  --region "$AWS_REGION"
```

```bash
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
  --cidr-block "10.198.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab08-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

### Step 2 — Enable VPC DNS

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"
```

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

Expected: both attributes are enabled.

### Step 3 — Create Public Subnet

```bash
export PUBLIC_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.198.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab08-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.198.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab08-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.198.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab08-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab08-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Create Public Route Table

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab08-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
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

The RDS subnets remain private and inherit the main route table's local route.

---

## 8. Create Security Groups

### Step 1 — Create EC2 Client SG

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab08 EC2 troubleshooting client" \
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
  --description "Lab08 RDS PostgreSQL" \
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

### Step 4 — Verify Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: port 5432 is accessible from the EC2 client security group only.

---

## 9. Deploy EC2 Troubleshooting Client

### Step 1 — Create Trust Policy

Save the following as `ec2-trust-policy.json`:

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
```

```bash
aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 3 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"
```

```bash
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
command -v nslookup
command -v nc
```

Exit:

```bash
exit
```

---

## 10. Deploy RDS PostgreSQL

### Step 1 — Create DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab08 private RDS subnets" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 2 — Enter Temporary Password

```bash
read -rsp "Enter temporary RDS password: " DB_PASSWORD
echo
```

Use a unique, strong password.

For this disposable lab, the next CLI command passes the password as an argument. Production environments should use RDS-managed credentials stored in Secrets Manager.

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

### Step 5 — Verify RDS

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible,Engine:Engine,Port:Endpoint.Port}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Public: False
Engine: postgres
Port: 5432
```

### Step 6 — Retrieve the Endpoint

```bash
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$DB_ENDPOINT"
```

The actual hostname is generated by AWS.

---

## 11. Baseline DNS and PostgreSQL Verification

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

Replace the placeholder with your actual endpoint.

### Step 2 — Inspect DNS Resolver

```bash
cat /etc/resolv.conf
```

Check the Amazon resolver:

```bash
dig @169.254.169.253 amazon.com +short
```

Expected: successful DNS response.

### Step 3 — Resolve RDS Endpoint

```bash
dig "$DB_ENDPOINT"
```

```bash
dig +short A "$DB_ENDPOINT"
```

Expected: a private RDS IP address.

### Step 4 — Compare DNS Tools

```bash
nslookup "$DB_ENDPOINT"
```

```bash
getent ahostsv4 "$DB_ENDPOINT"
```

```bash
dig @169.254.169.253 "$DB_ENDPOINT" A +short
```

Expected: successful resolution.

### Step 5 — Test TCP Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful TCP connection.

### Step 6 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Verify:

```sql
SELECT current_database(), current_user;
```

```sql
SELECT inet_server_addr(), inet_server_port();
```

### Step 7 — Create Test Data

```sql
CREATE TABLE lab08_dns_test (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

```sql
INSERT INTO lab08_dns_test (id, message)
VALUES (1, 'RDS DNS endpoint working');
```

Verify:

```sql
SELECT * FROM lab08_dns_test;
```

Expected:

```text
1 | RDS DNS endpoint working
```

Exit:

```text
\q
```

### Baseline Verification

| Check | Expected Result |
|---|---|
| RDS | Available |
| DNS Support | Enabled |
| RDS Endpoint | Correct |
| dig | Successful |
| nslookup | Successful |
| getent | Successful |
| TCP 5432 | Reachable |
| PostgreSQL Login | Successful |
| SQL Query | Successful |

---

## 12. Fault Injection 1 — Incorrect RDS Endpoint

### Step 1 — Preserve Correct Endpoint

Inside EC2:

```bash
export CORRECT_DB_ENDPOINT="$DB_ENDPOINT"
```

### Step 2 — Inject Incorrect Hostname

```bash
export DB_ENDPOINT="${CORRECT_DB_ENDPOINT}.invalid"
```

Verify:

```bash
echo "$DB_ENDPOINT"
```

### Step 3 — Investigate DNS

```bash
dig "$DB_ENDPOINT"
```

Expected: DNS resolution fails, typically with `NXDOMAIN`.

Verify using the system resolver:

```bash
getent ahostsv4 "$DB_ENDPOINT"
```

Expected: no address returned.

### Step 4 — Test TCP

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Possible error:

```text
Name or service not known
```

### Step 5 — Test PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Expected:

```text
could not translate host name
to address: Name or service not known
```

### Step 6 — Investigate Correct AWS Endpoint

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION"
```

Compare this result with the incorrect application hostname.

### Step 7 — Remediate

Inside EC2:

```bash
export DB_ENDPOINT="$CORRECT_DB_ENDPOINT"
```

Verify:

```bash
dig +short "$DB_ENDPOINT"
```

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

### Step 8 — Verify PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Execute:

```sql
SELECT * FROM lab08_dns_test;
```

Exit:

```text
\q
```

### Fault 1 Summary

| Check | Before Fix | After Fix |
|---|---|---|
| RDS Status | Available | Available |
| Endpoint Configuration | Incorrect | Correct |
| DNS Resolution | Failed | Successful |
| TCP Connection | Failed | Successful |
| PostgreSQL Login | Failed | Successful |
| SQL Query | Unavailable | Successful |

---

## 13. Fault Injection 2 — Incorrect Local Hostname Override

### Step 1 — Back Up `/etc/hosts`

Inside EC2:

```bash
sudo cp -p /etc/hosts /etc/hosts.lab08-backup
```

Verify:

```bash
ls -l /etc/hosts*
```

### Step 2 — Add Incorrect Mapping

```bash
printf '127.0.0.1 %s # lab08-test\n' "$DB_ENDPOINT" \
  | sudo tee -a /etc/hosts
```

Verify:

```bash
tail -n 5 /etc/hosts
```

Expected: the RDS hostname is incorrectly mapped to `127.0.0.1`.

### Step 3 — Investigate System Resolution

```bash
getent ahostsv4 "$DB_ENDPOINT"
```

Expected:

```text
127.0.0.1
```

### Step 4 — Compare DNS Resolution

```bash
dig +short "$DB_ENDPOINT"
```

```bash
dig @169.254.169.253 "$DB_ENDPOINT" A +short
```

Expected: the actual RDS private IP address.

This demonstrates that the DNS server can return the correct answer while the client uses an incorrect local mapping.

### Step 5 — Test Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: connection failure, commonly connection refused because the hostname resolves to loopback.

### Step 6 — Test PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Expected: connection failure.

### Step 7 — Restore `/etc/hosts`

```bash
sudo cp -p /etc/hosts.lab08-backup /etc/hosts
```

Verify the override is absent:

```bash
grep -n 'lab08-test' /etc/hosts \
  || echo "Lab 08 override removed"
```

Delete the backup:

```bash
sudo rm -f /etc/hosts.lab08-backup
```

### Step 8 — Verify DNS Recovery

```bash
getent ahostsv4 "$DB_ENDPOINT"
```

```bash
dig +short "$DB_ENDPOINT"
```

Expected: correct database address.

### Step 9 — Verify TCP and PostgreSQL

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Run:

```sql
SELECT * FROM lab08_dns_test;
```

Exit:

```text
\q
```

### Fault 2 Summary

| Check | During Fault | After Fix |
|---|---|---|
| RDS Status | Available | Available |
| RDS Endpoint | Correct | Correct |
| Amazon DNS | Working | Working |
| `/etc/hosts` | Incorrect | Restored |
| dig | Correct Private IP | Correct Private IP |
| getent | 127.0.0.1 | Correct Private IP |
| TCP 5432 | Failed | Successful |
| PostgreSQL | Failed | Successful |

---

## 14. Troubleshooting Investigation

### Check 1 — Verify VPC DNS Support

From WSL:

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"
```

Expected: `true`.

### Check 2 — Verify VPC DNS Hostnames

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

Expected: `true`.

### Check 3 — Inspect DHCP Options

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].{VpcId:VpcId,DhcpOptionsId:DhcpOptionsId}' \
  --output table \
  --region "$AWS_REGION"
```

Retrieve DHCP options ID:

```bash
export DHCP_OPTIONS_ID=$(aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].DhcpOptionsId' \
  --output text \
  --region "$AWS_REGION")
```

Inspect configuration:

```bash
aws ec2 describe-dhcp-options \
  --dhcp-options-ids "$DHCP_OPTIONS_ID" \
  --output json \
  --region "$AWS_REGION"
```

Look for `AmazonProvidedDNS`.

### Check 4 — Verify EC2 Networking

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Vpc:VpcId,Subnet:SubnetId,PrivateIP:PrivateIpAddress,SecurityGroups:SecurityGroups}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 5 — Verify RDS Networking

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Endpoint:Endpoint.Address,Public:PubliclyAccessible,VPC:DBSubnetGroup.VpcId,Subnets:DBSubnetGroup.Subnets[].SubnetIdentifier}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 6 — Examine DNS TTL

Inside EC2:

```bash
dig "$DB_ENDPOINT"
```

Inspect the DNS answer section.

DNS TTL affects how long records can remain cached.

### Check 7 — Verify the System Resolver

```bash
cat /etc/resolv.conf
```

```bash
getent ahostsv4 "$DB_ENDPOINT"
```

```bash
dig @169.254.169.253 "$DB_ENDPOINT" A +short
```

### Investigation Summary

| Investigation | Finding |
|---|---|
| RDS Instance | Available |
| Endpoint | Valid |
| EC2 VPC | Correct |
| RDS VPC | Correct |
| VPC DNS Support | Enabled |
| DNS Hostnames | Enabled |
| DHCP DNS | AmazonProvidedDNS |
| Amazon Resolver | Working |
| Security Groups | Correct |
| Client Hostname Override | Removed |
| TCP Connectivity | Restored |
| PostgreSQL | Working |

---

## 15. Root Cause Analysis

### Root Cause 1 — Incorrect RDS Hostname

The application was configured with a hostname that did not match the endpoint assigned to the RDS instance.

The DNS resolver could not locate the invalid hostname.

Because no IP address was returned, the application could not begin a TCP connection.

#### Five Whys

1. **Why couldn't the application connect?** The database hostname could not be resolved.
2. **Why did DNS resolution fail?** The application used an invalid hostname.
3. **Why was the hostname incorrect?** The application configuration contained an incorrect endpoint.
4. **Why wasn't the error detected earlier?** The configured hostname was not validated against the RDS endpoint.
5. **How can this be prevented?** Retrieve endpoints from AWS infrastructure outputs and validate application configuration.

### Root Cause 2 — Incorrect `/etc/hosts` Mapping

The EC2 instance contained a local hostname override that mapped the valid RDS hostname to `127.0.0.1`.

The operating system used this local mapping instead of the correct address from DNS.

The application therefore attempted to connect to the local machine rather than RDS.

#### Five Whys

1. **Why did PostgreSQL connectivity fail?** The client connected to the wrong address.
2. **Why was the address incorrect?** System hostname resolution returned `127.0.0.1`.
3. **Why did it return loopback?** An incorrect entry existed in `/etc/hosts`.
4. **Why did dig show the correct address?** It queried DNS rather than using the local hosts-file mapping.
5. **How can this be prevented?** Avoid unnecessary static mappings and validate operating system resolution.

### Root Cause Flow

```text
Application Connection Failure
              |
              v
        Check RDS Status
              |
              v
          RDS Available
              |
              v
        Check DNS Endpoint
              |
        ------------------
        |                |
        v                v
    NXDOMAIN       DNS Resolves
        |                |
        v                v
   Wrong Hostname   Check getent
        |                |
        v                v
  Correct Endpoint   Wrong Local IP
                         |
                         v
                   Inspect /etc/hosts
                         |
                         v
                    Remove Override
                         |
                         v
                  Verify Connectivity
```

### Root Cause Summary

| Incident | Root Cause | Remediation |
|---|---|---|
| Incorrect Endpoint | Invalid application hostname | Use actual RDS endpoint |
| Local Host Override | Wrong `/etc/hosts` mapping | Restore hostname configuration |
| DNS Caching Risk | Cached outdated address | Honor DNS TTL and reconnect |

---

## 16. Final Verification

### Step 1 — Verify RDS

From WSL:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: available and private.

### Step 2 — Verify Local Mapping Was Removed

Inside EC2:

```bash
grep -n 'lab08-test' /etc/hosts \
  || echo "No Lab 08 override"
```

### Step 3 — Verify DNS Resolution

```bash
getent ahostsv4 "$DB_ENDPOINT"
```

```bash
dig @169.254.169.253 "$DB_ENDPOINT" A +short
```

Expected: the correct private RDS address.

### Step 4 — Verify TCP Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: successful connection.

### Step 5 — Verify PostgreSQL Login

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

### Step 6 — Verify Database Read

```sql
SELECT * FROM lab08_dns_test;
```

### Step 7 — Verify Database Write

```sql
INSERT INTO lab08_dns_test (id, message)
VALUES (2, 'DNS troubleshooting completed');
```

Verify:

```sql
SELECT * FROM lab08_dns_test ORDER BY id;
```

Expected: both records are returned.

### Final Verification Matrix

| Check | Baseline | Fault 1 | Fault 2 | Final |
|---|---|---|---|---|
| RDS Available | Yes | Yes | Yes | Yes |
| Valid Endpoint | Yes | No | Yes | Yes |
| DNS Server | Working | Working | Working | Working |
| Local Hosts Mapping | Correct | Correct | Wrong | Correct |
| System Resolution | Correct | Failed | Loopback | Correct |
| TCP 5432 | Working | Failed | Failed | Working |
| PostgreSQL | Working | Failed | Failed | Working |
| RDS Private | Yes | Yes | Yes | Yes |

---

## 17. Production Best Practices

### DNS Troubleshooting Checklist

1. Verify the RDS instance is available.
2. Retrieve the endpoint using AWS CLI.
3. Confirm the application uses the correct hostname.
4. Inspect `/etc/resolv.conf`.
5. Inspect `/etc/hosts`.
6. Test `dig`.
7. Test `nslookup`.
8. Compare results using `getent`.
9. Query AmazonProvidedDNS directly.
10. Check `enableDnsSupport`.
11. Check `enableDnsHostnames`.
12. Inspect VPC DHCP options.
13. Verify EC2 and RDS VPC configuration.
14. Test TCP connectivity.
15. Test PostgreSQL authentication.
16. Verify DNS behavior after remediation.

### Production Recommendations

- Always connect using the RDS endpoint hostname.
- Do not hardcode the current RDS private IP.
- Retrieve endpoints from infrastructure outputs.
- Keep DNS support enabled.
- Configure DNS forwarding correctly.
- Avoid unnecessary static hosts-file mappings.
- Respect DNS TTL values.
- Review application DNS caching.
- Ensure connection pools reconnect appropriately after failover.
- Use private RDS connectivity.
- Use TLS for PostgreSQL connections.
- Monitor database connection errors.
- Document DNS troubleshooting procedures.
- Validate configuration during deployments.

### DNS Failover Consideration

For a Multi-AZ RDS DB instance, AWS can update the endpoint's DNS record to point to the new primary after failover.

Applications that cache an outdated address for too long may fail to reconnect promptly.

This lab does not perform a real RDS failover. It demonstrates the DNS troubleshooting skills needed to investigate similar connectivity problems.

### Key Cloud Security Lesson

DNS configuration affects service availability.

Even when the database is healthy and security groups are correctly configured, an incorrect hostname or client-side DNS mapping can interrupt application access.

Reliable cloud infrastructure requires correct DNS configuration, secure networking, and effective troubleshooting procedures.

---

## 18. Cleanup

**Warning:** The following commands permanently delete the disposable Lab 08 database and AWS infrastructure.

### Step 1 — Restore EC2 Host Configuration

Inside EC2:

```bash
grep -n 'lab08-test' /etc/hosts \
  || echo "No Lab 08 override"
```

If the override remains and the backup exists:

```bash
sudo cp -p /etc/hosts.lab08-backup /etc/hosts
```

Verify restoration and remove the backup:

```bash
sudo rm -f /etc/hosts.lab08-backup
```

Exit PostgreSQL if connected:

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

```bash
aws rds list-tags-for-resource \
  --resource-name "$DB_ARN" \
  --region "$AWS_REGION"
```

Confirm the tag:

```text
Project=RDS-Troubleshooting-Lab08
```

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

Confirm the root volume is configured with `DeleteOnTermination=true`.

### Step 6 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

```bash
aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete IAM Resources

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

### Step 8 — Verify Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until RDS and EC2 network interfaces are removed.

### Step 9 — Delete Security Groups

Delete the database security group first:

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Public Route Table

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

Also verify EC2, EBS, IAM, security group, and DB subnet group removal.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| RDS PostgreSQL | Deleted |
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

### Q1. What is an RDS endpoint?

An AWS-managed DNS hostname used by applications to connect to an RDS database.

### Q2. Why should applications use the RDS hostname instead of an IP?

AWS may change the database's underlying IP address during maintenance, replacement, or failover.

### Q3. What does enableDnsSupport do?

It controls DNS resolution through the Amazon-provided DNS server within a VPC.

### Q4. What is AmazonProvidedDNS?

The AWS-managed Route 53 Resolver available inside a VPC, including at `169.254.169.253`.

### Q5. What is the difference between dig and getent?

`dig` performs DNS queries, while `getent` follows the operating system's name-service lookup configuration, potentially including `/etc/hosts`.

### Q6. What is NXDOMAIN?

A DNS response indicating that the queried domain name does not exist.

### Q7. What is DNS TTL?

Time to Live determines how long a DNS record may be cached before it should be refreshed.

### Q8. Can DNS resolution succeed while TCP connectivity fails?

Yes. DNS resolution only identifies an address; TCP connectivity can still be blocked by security groups, routes, firewalls, or an unavailable service.

### Q9. Can `/etc/hosts` override a valid RDS DNS endpoint?

Yes. A local hostname mapping may cause applications to use an incorrect address.

### Q10. What happens to the RDS endpoint during Multi-AZ failover?

For an RDS Multi-AZ DB instance, AWS changes the DNS mapping to the new primary. Applications need to reconnect and recognize the updated address.

### Q11. How would you troubleshoot an RDS DNS failure?

Verify the RDS endpoint, inspect system DNS configuration, compare `dig` and `getent`, review `/etc/hosts`, check VPC DNS attributes, test TCP connectivity, and verify PostgreSQL authentication.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL database and an EC2 troubleshooting client inside the same VPC.

I verified that the database endpoint resolved correctly and that PostgreSQL connectivity was successful.

I intentionally configured an incorrect RDS hostname to reproduce a DNS resolution failure.

Next, I created a temporary `/etc/hosts` override that mapped the database hostname to `127.0.0.1`.

I investigated both scenarios using Linux tools including `dig`, `nslookup`, `getent`, and `nc`, along with AWS CLI.

I identified the difference between DNS server responses and client-side hostname resolution.

After correcting the endpoint and restoring `/etc/hosts`, I verified successful DNS resolution, TCP connectivity, and PostgreSQL queries.

I also reviewed VPC DNS configuration, DHCP options, DNS TTL, and RDS endpoint behavior during failover.

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
│
└── 08-rds-dns-endpoint-investigation/
    ├── README.md
    └── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete lab documentation, investigation, remediation, and cleanup |
| `ec2-trust-policy.json` | IAM trust policy used by the EC2 Systems Manager role |

No AWS credentials or database passwords should be committed.

---

## 21. Lessons Learned and Skills Demonstrated

### Lessons Learned

This lab demonstrates how DNS misconfiguration can cause database connection failures even when the Amazon RDS instance is healthy.

We reproduced two different hostname-related incidents.

In the first scenario, an incorrect database endpoint caused DNS resolution to fail.

In the second scenario, the RDS endpoint was correct, but the EC2 client's `/etc/hosts` file returned an incorrect IP address.

We used AWS CLI and Linux networking tools to distinguish between these problems.

After correcting the client configurations, PostgreSQL connectivity was restored without modifying RDS security groups or database settings.

The exercise also demonstrated why applications should connect using AWS-managed RDS endpoints instead of hardcoded IP addresses.

**Key Lesson:** When an RDS connection fails, investigate DNS resolution, system hostname configuration, TCP connectivity, and database authentication separately. A correct diagnosis prevents unnecessary infrastructure changes.

### Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Amazon EC2
- Amazon VPC
- AWS Systems Manager
- Route 53 Resolver concepts
- AmazonProvidedDNS
- RDS endpoint troubleshooting
- DNS resolution investigation
- DNS TTL analysis
- VPC DNS attributes
- DHCP options inspection
- Linux `dig`
- Linux `nslookup`
- Linux `getent`
- Linux `/etc/hosts`
- Netcat TCP testing
- PostgreSQL connectivity
- Client-side fault injection
- Root cause analysis
- Secure private database networking
- AWS resource cleanup

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-008 |
| Problem | RDS DNS Endpoint Investigation |
| Database Engine | PostgreSQL |
| Database | labdb |
| Fault 1 | Incorrect database hostname |
| Fault 2 | Incorrect `/etc/hosts` mapping |
| Expected Errors | NXDOMAIN, hostname resolution failure, connection failure |
| Root Causes | Client DNS and hostname configuration |
| Amazon DNS Resolver | Working |
| Remediation | Correct endpoint and restore `/etc/hosts` |
| DNS Resolution | Restored |
| TCP Connectivity | Successful |
| PostgreSQL Login | Successful |
| SQL Queries | Successful |
| RDS Public Access | Disabled |
| Cleanup | Temporary AWS resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Effective RDS DNS troubleshooting requires understanding the difference between DNS server responses, operating system hostname resolution, network connectivity, and database authentication. Correct endpoint configuration and proper DNS caching are important for cloud database availability.