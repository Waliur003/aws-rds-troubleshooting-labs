# Lab 01 — Amazon RDS Connection Timeout

## Overview

This lab demonstrates how to troubleshoot a connection timeout between an Amazon EC2 instance and a private Amazon RDS PostgreSQL database.

We deploy an EC2 troubleshooting client in a public subnet and an RDS PostgreSQL database in private subnets within the same VPC.

We intentionally configure the RDS security group without an inbound rule for PostgreSQL port `5432`.

When the EC2 client attempts to connect to the database, the connection times out.

We investigate the issue using AWS CLI, Linux networking commands, security group configurations, DNS resolution, VPC routing, and database endpoint information.

After identifying the root cause, we authorize TCP port `5432` from the EC2 client's security group.

Finally, we verify that the database connection succeeds, execute SQL queries using `psql`, and clean up the temporary AWS infrastructure.

**Troubleshooting methodology:**

Environment Setup → Fault Injection → Symptoms → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-001 |
| Difficulty | Beginner–Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager |
| Database Engine | PostgreSQL |
| RDS Instance Class | `db.t4g.micro` |
| RDS Storage | 20 GiB gp3 |
| RDS Deployment | Single-AZ |
| RDS Accessibility | Private |
| EC2 Instance Type | `t3.micro` |
| EC2 Operating System | Amazon Linux 2023 |
| Database Name | `labdb` |
| Database Username | `labadmin` |
| Database Port | TCP `5432` |
| Client Tool | `psql` |
| Network Tools | `nc`, `dig`, `getent` |
| Fault Injection | Remove/omit inbound PostgreSQL access |
| Expected Error | Connection timed out |
| Root Cause | Missing RDS security group ingress rule |
| Remediation | Allow TCP 5432 from EC2 client security group |
| Verification | Successful TCP connection and SQL query |

---

## 2. Production Incident Scenario

### Incident Description

A company runs an application on an Amazon EC2 instance.

The application connects to an Amazon RDS PostgreSQL database to store and retrieve business information.

The database is deployed privately within an Amazon VPC.

After a networking configuration change, the application can no longer connect to the database.

Users begin reporting that the application is not responding correctly.

The cloud engineering team investigates and finds that the database connection is timing out.

A PostgreSQL connection attempt returns an error similar to:

```text
connection to server at "database-endpoint", port 5432 failed:
Connection timed out
```

However, the RDS instance still reports the status `available`.

The engineer must determine whether the issue comes from DNS resolution, security groups, route tables, network ACLs, or database availability.

### Incident Symptoms

- EC2 instance is running.
- RDS PostgreSQL instance is available.
- Both resources are inside the same VPC.
- The RDS endpoint resolves successfully.
- TCP connections to port `5432` time out.
- PostgreSQL login cannot begin.
- The RDS security group has no inbound PostgreSQL rule.
- The database itself has not failed.

### Business Impact

- Application cannot connect to the database.
- Users may be unable to log in or access data.
- Database-dependent application features may fail.
- Application requests may time out.
- Business transactions may be interrupted.
- Application availability may decrease.

### Objective

Identify the networking configuration responsible for the RDS connection timeout and restore database connectivity without making the database publicly accessible or allowing unrestricted network access.

---

## 3. AWS Architecture

### Network Architecture

```text
                         AWS VPC
                      10.190.0.0/16
                              |
             --------------------------------
             |                              |
             v                              v
       Public Subnet                  Private Subnets
       10.190.1.0/24                  10.190.2.0/24
             |                              |
             v                              v
        Amazon EC2                    Amazon RDS
       Amazon Linux                   PostgreSQL
             |                              |
             v                              v
       Client Security               Database Security
            Group                         Group
             |                              |
             |     TCP Port 5432            |
             +----------------------------->|
                                            |
                                            v
                                         Database
                                           labdb
```

### Broken Architecture

```text
                  EC2 Client
                      |
                      |
                PostgreSQL Request
                   TCP 5432
                      |
                      v
               RDS Security Group
                      |
                      X
            No Inbound Rule for 5432
                      |
                      v
               Packet Not Allowed
                      |
                      v
               Connection Timeout
```

### Recovered Architecture

```text
                  EC2 Client
                      |
                      v
              Client Security Group
                      |
                      | TCP 5432
                      v
               RDS Security Group
                      |
                      v
          Allow Source: EC2 Client SG
                      |
                      v
               RDS PostgreSQL
                      |
                      v
              Successful Connection
                      |
                      v
                 SQL Queries
```

### Infrastructure Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.190.0.0/16` |
| Public Subnet | `10.190.1.0/24` |
| Private Subnet A | `10.190.2.0/24` |
| Private Subnet B | `10.190.3.0/24` |
| Public Routing | Internet Gateway |
| Private Routing | VPC local route |
| DB Subnet Group | Two private subnets in separate AZs |
| EC2 Security Group | No inbound rules |
| RDS Security Group | Initially no inbound rules |
| EC2 Access | AWS Systems Manager |
| Database Connectivity | Private VPC networking |

---

## 4. Understanding RDS Connection Timeouts

A connection timeout occurs when a client cannot establish the required network connection before its configured timeout expires.

A TCP connection timeout is different from a database authentication failure.

### Common RDS Connection Errors

| Error | Possible Cause |
|---|---|
| Connection timed out | Security group, NACL, routing, or network path |
| Connection refused | Incorrect port or unreachable database listener |
| Name or service not known | DNS resolution problem |
| Password authentication failed | Incorrect database credentials |
| Database does not exist | Incorrect database name |
| Too many connections | Database connection limit reached |
| SSL-related error | Client/server TLS configuration mismatch |

### How Security Groups Work

AWS security groups are stateful virtual firewalls.

They control allowed inbound and outbound traffic for associated network interfaces.

For this lab:

- EC2 has an outbound rule allowing traffic.
- RDS initially has no inbound rules.
- The EC2 client sends TCP traffic to port `5432`.
- RDS security group does not permit the connection.
- The client experiences a timeout.

### Important Concepts

**RDS status `available`:** The database instance is ready for normal operations, but this does not guarantee connectivity from every client.

**Private RDS:** The database is not publicly accessible from the internet. Authorized clients within the VPC can still access it.

**Security group reference:** Instead of authorizing an entire IP range, we can allow PostgreSQL traffic from resources associated with the EC2 client security group.

**VPC local route:** Resources within the same VPC can communicate through the VPC local route, provided that security policies and other network controls permit the traffic.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- Amazon EC2 permissions
- Amazon RDS permissions
- Amazon VPC permissions
- IAM permissions
- Systems Manager Session Manager support
- PostgreSQL client
- Git and GitHub

### Safety Rules

- Use only a disposable lab database.
- Never run fault injection against production databases.
- Keep RDS privately accessible.
- Do not authorize PostgreSQL from `0.0.0.0/0`.
- Use a separate security group for EC2 and RDS.
- Do not store database passwords in GitHub.
- Use secure database connection methods.
- Verify AWS resource identifiers before deletion.
- Remove temporary RDS resources after the lab.

### Cost Considerations

RDS is a billable AWS service.

Charges may apply for:

- RDS database instance hours
- RDS allocated storage
- EC2 instance hours
- EC2 root EBS storage
- Public IPv4 addresses
- Backup storage or snapshots beyond applicable allowances

This lab uses a small Single-AZ instance and does not provision a NAT gateway or read replica.

---

## 6. Prepare the Environment

### Step 1 — Configure Environment Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab01"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab01-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab01-subnet-group"

export DB_USERNAME="labadmin"
export DB_NAME="labdb"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab01-client"
export EC2_ROLE_NAME="cloud-rds-lab01-ssm-role"
export PROFILE_NAME="cloud-rds-lab01-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab01-client-sg"
export DB_SG_NAME="cloud-rds-lab01-db-sg"
```

### Step 2 — Verify AWS Identity

```bash
aws sts get-caller-identity

aws --version
```

### Step 3 — Check Instance Availability

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Verify RDS instance class availability:

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass,Version:EngineVersion}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Verify Existing Resources

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

Avoid duplicate resources.

---

## 7. Create AWS VPC Infrastructure

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.190.0.0/16 \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab01-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --cidr-block 10.190.1.0/24 \
  --availability-zone "$AZ_A" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.190.2.0/24 \
  --availability-zone "$AZ_A" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.190.3.0/24 \
  --availability-zone "$AZ_B" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

These two private subnets provide the required Availability Zone coverage for the DB subnet group.

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

### Step 6 — Create Public Route Table

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"

export PUBLIC_RT_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION"
```

The private database subnets remain on the VPC local routing configuration.

### Step 7 — Create Client Security Group

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab01 EC2 database client" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 8 — Create Database Security Group

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab01 PostgreSQL database" \
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

### Step 9 — Verify Database Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Do not add inbound PostgreSQL access yet.

This missing rule is the fault we intend to reproduce.

---

## 8. Create the EC2 Troubleshooting Client

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

### Step 2 — Create SSM IAM Role

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

### Step 8 — Install PostgreSQL and Networking Tools

Inside EC2:

```bash
sudo dnf install -y postgresql15 nmap-ncat bind-utils
```

Verify:

```bash
psql --version

nc -h

dig -v
```

Exit the SSM session:

```bash
exit
```

---

## 9. Create the Private RDS Database

### Step 1 — Create DB Subnet Group

From WSL2:

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab01 private database subnet group" \
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

Expected: subnets in two different Availability Zones.

### Step 3 — Configure a Temporary Database Password

```bash
read -rsp "Enter a strong temporary RDS password: " DB_PASSWORD
echo
```

Do not commit or print database passwords.

The following disposable-lab creation command passes the password as an AWS CLI argument, which can briefly expose it to local process inspection. Production deployments should use a stronger secret-management workflow, such as RDS-managed master credentials.

### Step 4 — Create RDS PostgreSQL

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

Remove the password from the shell:

```bash
unset DB_PASSWORD
```

### Step 5 — Wait for RDS Availability

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 6 — Verify RDS

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Public:PubliclyAccessible,Engine:Engine,MultiAZ:MultiAZ}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
Public: False
Engine: postgres
MultiAZ: False
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

### Step 8 — Verify Endpoint Port

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Port' \
  --output text \
  --region "$AWS_REGION"
```

Expected: `5432`.

---

## 10. Fault Injection — RDS Connection Timeout

### Step 1 — Connect to EC2

From WSL2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Configure Endpoint on EC2

Inside EC2:

```bash
export DB_ENDPOINT="YOUR_ACTUAL_RDS_ENDPOINT"
export DB_PORT="5432"
```

Replace the placeholder with the real RDS endpoint.

### Step 3 — Verify DNS Resolution

```bash
getent hosts "$DB_ENDPOINT"
```

Also:

```bash
dig +short "$DB_ENDPOINT"
```

Expected: the endpoint resolves to the RDS database's private IP address.

### Step 4 — Test TCP Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" "$DB_PORT"
```

Expected error:

```text
Ncat: Connection timed out.
```

The exact message may vary.

### Step 5 — Test PostgreSQL Connection

```bash
PGCONNECT_TIMEOUT=5 psql \
  "host=$DB_ENDPOINT port=$DB_PORT dbname=labdb user=labadmin connect_timeout=5 sslmode=require"
```

Expected error:

```text
connection to server at "database-endpoint", port 5432 failed:
Connection timed out
```

### Step 6 — Verify RDS Status

From WSL2:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: RDS reports `available`.

### Fault Summary

| Check | Expected Finding |
|---|---|
| EC2 Instance | Running |
| RDS Instance | Available |
| RDS Endpoint | Valid |
| DNS Resolution | Successful |
| TCP 5432 | Timed out |
| PostgreSQL Login | Cannot connect |
| RDS Security Group | No inbound rule |
| Root Cause | Network access blocked |

---

## 11. Troubleshooting Investigation

### Check 1 — Inspect RDS Security Group

From WSL2:

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].{Group:GroupId,Ingress:IpPermissions}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
{
  "Ingress": []
}
```

**Finding:** The database security group has no inbound rule for PostgreSQL.

### Check 2 — Inspect EC2 Outbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json \
  --region "$AWS_REGION"
```

Expected: default outbound traffic is permitted.

### Check 3 — Verify VPC Membership

Check EC2:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text \
  --region "$AWS_REGION"
```

Check RDS:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBSubnetGroup.VpcId' \
  --output text \
  --region "$AWS_REGION"
```

Both should return the same VPC ID.

### Check 4 — Inspect Route Tables

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Verify that the VPC local route is present.

### Check 5 — Inspect Network ACLs

```bash
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Entries:Entries,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: default NACL rules allow the traffic.

### Check 6 — Verify RDS Endpoint and Port

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint' \
  --output json \
  --region "$AWS_REGION"
```

Expected port: `5432`.

### Check 7 — Compare DNS and TCP Results

Inside EC2:

```bash
getent ahostsv4 "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected:

| Test | Result |
|---|---|
| DNS | Resolves |
| TCP | Times out |

### Investigation Summary

| Investigation | Finding |
|---|---|
| RDS Status | Available |
| EC2 Status | Running |
| Endpoint | Correct |
| DNS | Working |
| VPC | Same |
| Local Routing | Present |
| Network ACL | Not blocking |
| EC2 Outbound | Allowed |
| RDS Inbound | Missing |
| Root Cause | RDS security group restriction |

---

## 12. Root Cause Analysis

### Root Cause

The Amazon RDS security group did not allow inbound PostgreSQL traffic from the EC2 troubleshooting client.

Even though the database was healthy and the endpoint resolved successfully, the TCP connection was blocked by the database security group's ingress configuration.

As a result, the client could not establish a connection and reported a timeout.

### Technical Explanation

The EC2 client attempts to establish a TCP connection to the RDS endpoint on port `5432`.

The packet reaches the RDS network access controls, but the RDS security group has no rule allowing the client.

Security groups deny inbound traffic that does not match an allowed rule.

The connection therefore cannot be established.

### Root Cause Flow

```text
EC2 PostgreSQL Client
          |
          v
      TCP Port 5432
          |
          v
    RDS Security Group
          |
          X
    Missing Inbound Rule
          |
          v
    Connection Timeout
```

### Five Whys

1. **Why did the application fail to connect?** The TCP connection timed out.
2. **Why did the connection time out?** The RDS security group blocked the traffic.
3. **Why was it blocked?** No inbound rule permitted TCP port `5432` from the client.
4. **Why did RDS still show available?** RDS availability does not guarantee client network access.
5. **How can the issue be prevented?** Maintain correctly scoped security group rules and verify client-to-database connectivity after networking changes.

### Prevention

- Use dedicated security groups for application and database tiers.
- Reference application security groups in database ingress rules.
- Avoid broad CIDR ranges.
- Validate connectivity after infrastructure changes.
- Monitor failed database connections.
- Include endpoint and port checks in troubleshooting procedures.
- Keep the database private unless public access is explicitly required.

---

## 13. Remediation — Correct the RDS Security Group

### Step 1 — Authorize PostgreSQL Traffic

From WSL2:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

This permits TCP port `5432` from EC2 network interfaces associated with the client security group.

### Step 2 — Verify the New Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Protocol: tcp
Port: 5432
Source: EC2 Client Security Group
```

### Step 3 — Retest Connectivity

Inside the EC2 SSM session:

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected:

```text
Connection to RDS endpoint port 5432 succeeded.
```

### Step 4 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin connect_timeout=5 sslmode=require"
```

Enter the temporary database password when prompted.

Expected PostgreSQL prompt:

```text
labdb=>
```

### Step 5 — Verify Database Identity

Inside PostgreSQL:

```sql
SELECT current_database(), current_user;
```

Expected database: `labdb`.

### Step 6 — Verify PostgreSQL Version

```sql
SELECT version();
```

### Step 7 — Verify Server Address and Port

```sql
SELECT inet_server_addr(), inet_server_port();
```

Expected server port: `5432`.

### Step 8 — Create a Test Table

```sql
CREATE TABLE lab01_connection_test (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

### Step 9 — Insert Test Data

```sql
INSERT INTO lab01_connection_test (id, message)
VALUES (1, 'RDS connectivity restored');
```

### Step 10 — Verify SQL Query

```sql
SELECT * FROM lab01_connection_test;
```

Expected:

```text
 id |          message
----+----------------------------
  1 | RDS connectivity restored
```

Exit PostgreSQL:

```text
\q
```

### Remediation Summary

| Check | Before Fix | After Fix |
|---|---|---|
| RDS Status | Available | Available |
| DNS Resolution | Working | Working |
| TCP 5432 | Timeout | Successful |
| PostgreSQL Connection | Failed | Successful |
| SQL Query | Unavailable | Successful |
| RDS Security Group | No inbound PostgreSQL rule | EC2 security group allowed |
| RDS Public Access | False | False |
| Root Cause | Missing ingress rule | Resolved |

---

## 14. Final Verification

### Verify RDS Status

From WSL2:

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

### Verify Network Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: PostgreSQL inbound rule allows the EC2 client security group.

### Verify TCP Connectivity

Inside EC2:

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: connection succeeds.

### Verify Database Query

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require"
```

Then:

```sql
SELECT * FROM lab01_connection_test;
```

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| EC2 Client | Running |
| RDS PostgreSQL | Available |
| DB Endpoint | Resolves |
| TCP 5432 | Reachable |
| PostgreSQL Authentication | Successful |
| Test Table | Exists |
| SQL Query | Successful |
| RDS Publicly Accessible | False |
| RDS SG Source | EC2 client SG |
| Database Integrity | Preserved |
| Incident | Resolved |

---

## 15. Production Best Practices

### RDS Connectivity Troubleshooting Checklist

1. Verify database status.
2. Identify the correct RDS endpoint.
3. Verify the destination port.
4. Check DNS resolution.
5. Test TCP connectivity using `nc`.
6. Verify the EC2 client's security group.
7. Inspect RDS security group ingress.
8. Confirm VPC membership.
9. Inspect route tables.
10. Inspect network ACLs.
11. Verify public/private connectivity requirements.
12. Test PostgreSQL authentication.
13. Execute a SQL query.
14. Verify application connectivity.
15. Document the root cause and remediation.

### Security Recommendations

- Prefer private RDS instances.
- Avoid opening port 5432 to `0.0.0.0/0`.
- Authorize only necessary application clients.
- Use security group references where appropriate.
- Use TLS for PostgreSQL connections.
- Use secure database credential management.
- Review database security group changes.
- Monitor database availability and connection failures.
- Maintain backups for important databases.

### Cloud Security Lesson

A database can be operational while still being inaccessible due to network configuration.

Cloud engineers must understand the difference between a service health problem and a network authorization problem.

---

## 16. Cleanup

**Warning:** These operations permanently delete the disposable RDS database and the AWS infrastructure created for this lab.

### Step 1 — Verify RDS Ownership

From WSL2:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,ARN:DBInstanceArn}' \
  --output json \
  --region "$AWS_REGION"
```

Retrieve its ARN and verify the project tag:

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

Confirm `Project=RDS-Troubleshooting-Lab01`.

### Step 2 — Delete RDS

This lab uses disposable data, so we skip creating a final snapshot.

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

Wait for deletion:

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 3 — Delete DB Subnet Group

```bash
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION"
```

### Step 4 — Verify EC2 Root Volume Settings

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `DeleteOnTermination=true` for the root EBS volume.

### Step 5 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Delete IAM Resources

Verify the lab IAM role and instance profile:

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Remove:

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

### Step 7 — Check Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until AWS removes the EC2 and RDS network interfaces.

### Step 8 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete Public Routing

```bash
aws ec2 disassociate-route-table \
  --association-id "$PUBLIC_RT_ASSOC" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Subnets

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

### Step 11 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Verify Cleanup

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

Expected: empty arrays after deletion completes.

Also verify the EC2 instance, root EBS volume, IAM role, and instance profile are removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| RDS PostgreSQL | Deleted |
| DB Subnet Group | Deleted |
| EC2 Client | Terminated |
| EC2 Root EBS | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| RDS Security Group | Deleted |
| EC2 Security Group | Deleted |
| Public Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnet A | Deleted |
| Private Subnet B | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 17. Interview Questions and Answers

### Q1. What causes an RDS connection timeout?

Common causes include security group restrictions, network ACLs, routing problems, incorrect endpoints, and network reachability failures.

### Q2. What is the default PostgreSQL port?

TCP port `5432`.

### Q3. Can RDS be available but unreachable?

Yes. RDS can report `available` even when security groups or networking configurations prevent a client from connecting.

### Q4. What is an RDS DB subnet group?

A collection of VPC subnets that RDS can use when deploying database resources.

### Q5. Why do we create private database subnets in two AZs?

An ordinary RDS DB subnet group generally requires subnet coverage in at least two Availability Zones.

### Q6. What does `PubliclyAccessible=false` mean?

The database is not configured for direct public internet access. Authorized clients inside its VPC can still connect.

### Q7. What does `nc -vz` test?

It attempts a TCP connection to the destination host and port.

### Q8. What is the difference between `nc` and `psql`?

`nc` checks TCP connectivity, while `psql` establishes a PostgreSQL session and allows SQL commands.

### Q9. Why use a source security group instead of `0.0.0.0/0`?

A source security group restricts access to designated client resources rather than allowing unrestricted network origins.

### Q10. Does private RDS need a NAT gateway to communicate with EC2 in the same VPC?

No. EC2 and RDS can communicate using the VPC local route when network security rules permit it.

### Q11. Should you reset the database password when a TCP connection times out?

Not initially. A network timeout occurs before database authentication, so network connectivity should be investigated first.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL database and an EC2 troubleshooting client inside the same VPC.

I intentionally configured the RDS security group without inbound PostgreSQL access, causing connection timeouts on port 5432.

I investigated the issue using AWS CLI, Linux networking commands, DNS resolution, security groups, route tables, and network ACLs.

I confirmed the database was available and its endpoint resolved correctly, but TCP traffic was blocked.

After identifying the missing security group ingress rule as the root cause, I authorized port 5432 only from the EC2 client's security group.

I then verified connectivity using `nc`, successfully connected using `psql`, and executed SQL queries.

The RDS database remained private throughout the exercise.

---

## 18. Repository Structure

```text
01-rds-connection-timeout/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete RDS connection timeout troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager access |

Do not commit passwords, credentials, access keys, or database connection secrets.

---

## 19. Lessons Learned

This lab demonstrates how an RDS database can be healthy but unreachable from an application.

The database was running correctly, and its endpoint resolved successfully.

However, the RDS security group did not allow TCP traffic from the EC2 client.

We investigated the issue using AWS CLI and Linux networking tools, including `nc`, `dig`, and `getent`.

We also verified the VPC configuration, subnet group, security groups, route tables, and network ACLs.

After adding a narrowly scoped inbound security group rule, the database became reachable.

We successfully connected to PostgreSQL and executed SQL queries to verify recovery.

**Key Lesson:** An RDS connection timeout is not automatically a database failure. Always investigate DNS, TCP connectivity, VPC routing, network ACLs, and security groups before changing database credentials or configuration.

---

## 20. Skills Demonstrated

- Amazon RDS PostgreSQL administration
- AWS CLI v2
- Amazon VPC networking
- Public and private subnet configuration
- RDS DB subnet groups
- EC2 troubleshooting clients
- AWS Systems Manager
- Security group troubleshooting
- TCP port 5432 investigation
- Linux networking commands
- DNS resolution
- PostgreSQL `psql`
- SQL verification
- IAM instance profiles
- Root cause analysis
- Least-privilege network remediation
- Secure database connectivity
- AWS infrastructure cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-001 |
| Problem | RDS connection timeout |
| Database Engine | PostgreSQL |
| Deployment | Private Single-AZ RDS |
| Source | EC2 client |
| Destination | RDS PostgreSQL |
| Port | 5432 |
| Fault | Missing inbound SG rule |
| Root Cause | RDS security group blocks TCP |
| Remediation | Authorize EC2 client SG |
| TCP Connectivity | Restored |
| PostgreSQL Login | Successful |
| SQL Query | Successful |
| RDS Public Access | Disabled |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Effective RDS troubleshooting requires isolating database health, network reachability, and authentication. Fixing the specific security group restriction restores connectivity without exposing the database to the public internet.
