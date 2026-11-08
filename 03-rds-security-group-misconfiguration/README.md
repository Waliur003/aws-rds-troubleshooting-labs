# Lab 03 — RDS Security Group Misconfiguration

## Overview

This lab demonstrates how to troubleshoot an Amazon RDS PostgreSQL connection failure caused by an incorrect security group reference.

We deploy a private PostgreSQL database and an Amazon Linux 2023 EC2 troubleshooting client inside the same VPC.

The database security group has an inbound rule allowing TCP port `5432`. However, the rule references an unused security group instead of the security group actually attached to the EC2 client.

As a result, the EC2 instance cannot establish a connection to PostgreSQL, even though the RDS database is available and the expected inbound port appears in the security group configuration.

We investigate the EC2 security group associations, RDS inbound rules, DNS resolution, TCP connectivity, route tables, and network ACLs using AWS CLI and Linux.

After identifying the incorrect source security group as the root cause, we replace it with the correct reference and verify successful PostgreSQL connectivity.

**Troubleshooting workflow:**

Infrastructure Setup → Fault Injection → Symptoms → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-003 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | RDS, EC2, VPC, IAM, Systems Manager |
| Database Engine | PostgreSQL |
| RDS Instance Class | `db.t4g.micro` |
| RDS Storage | 20 GiB gp3 |
| RDS Deployment | Private, Single-AZ |
| EC2 Instance | `t3.micro` |
| Operating System | Amazon Linux 2023 |
| Database Name | `labdb` |
| Database Username | `labadmin` |
| Database Port | TCP `5432` |
| VPC CIDR | `10.192.0.0/16` |
| Fault Injection | Reference incorrect source security group |
| Expected Error | Connection timed out |
| Root Cause | RDS SG does not authorize the actual EC2 client SG |
| Remediation | Replace incorrect SG reference |
| Verification | TCP connection, PostgreSQL login, SQL query |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts its application on an Amazon EC2 instance and stores application data in an Amazon RDS PostgreSQL database.

The application suddenly stops connecting to PostgreSQL following a networking configuration change.

The operations engineer checks the RDS instance and finds that it is running normally.

The RDS security group also appears to contain an inbound rule for PostgreSQL port `5432`.

However, the application continues to experience connection timeouts.

Example:

```text
connection to server at "database-endpoint",
port 5432 failed:

Connection timed out
```

After inspecting the complete security group configuration, the engineer discovers that the inbound rule references a security group that is not attached to the application EC2 instance.

The engineer must identify the incorrect security group reference, update the rule, and verify connectivity without exposing the database to the internet.

### Incident Symptoms

- EC2 instance is running.
- RDS PostgreSQL instance is available.
- Both resources exist in the same VPC.
- Database endpoint resolves successfully.
- RDS security group contains a TCP 5432 ingress rule.
- The rule references an unused security group.
- EC2 uses a different security group.
- TCP connection attempts time out.
- Database authentication cannot begin.

### Business Impact

- Application cannot connect to its database.
- Users may experience failed requests.
- Application features may become unavailable.
- Database-dependent transactions may fail.
- Service availability and reliability may decrease.
- Incorrect remediation could accidentally expose sensitive database services.

### Objective

Investigate and correct an RDS security group source-reference mismatch while preserving private database connectivity and least-privilege network access.

---

## 3. AWS Architecture

### Infrastructure

```text
                    Amazon VPC
                  10.192.0.0/16
                         |
          --------------------------------
          |                              |
          v                              v
     Public Subnet                 Private Subnets
    10.192.1.0/24                 10.192.2.0/24
          |                       10.192.3.0/24
          v                              |
       EC2 Client                        v
    Amazon Linux 2023               RDS PostgreSQL
          |                              |
          v                              v
     Client SG                       Database SG
          |                              |
          +---------- TCP 5432 ---------+
```

### Broken Architecture

```text
                  EC2 Client
                      |
                      v
              Actual Client SG
                  sg-client
                      |
                      v
                TCP Port 5432
                      |
                      v
             RDS Security Group
                      |
                      v
             Allowed Source Group
                  sg-wrong
                      |
                      X
             Source Does Not Match
                      |
                      v
               Connection Timeout
```

### Recovered Architecture

```text
                  EC2 Client
                      |
                      v
                Client SG
                      |
                      v
                 TCP 5432
                      |
                      v
               RDS Security Group
                      |
                      v
           Allowed Source: Client SG
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

### Networking Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.192.0.0/16` |
| Public Subnet | `10.192.1.0/24` |
| Private Subnet A | `10.192.2.0/24` |
| Private Subnet B | `10.192.3.0/24` |
| Public Routing | Internet Gateway |
| Private Routing | VPC local route |
| Client SG | `cloud-rds-lab03-client-sg` |
| Incorrect SG | `cloud-rds-lab03-wrong-sg` |
| Database SG | `cloud-rds-lab03-db-sg` |
| RDS Public Access | Disabled |
| EC2 Management | Systems Manager |

---

## 4. Understanding Security Group References

An AWS security group acts as a stateful virtual firewall.

Its rules control traffic based on protocol, port, and source or destination.

For inbound rules, the source may be an IP CIDR range or another security group.

### Example: Correct Inbound Rule

```text
Type: PostgreSQL
Protocol: TCP
Port: 5432
Source: EC2 Client Security Group
```

This permits matching traffic originating from network interfaces associated with the referenced client security group.

### Example: Incorrect Inbound Rule

```text
Type: PostgreSQL
Protocol: TCP
Port: 5432
Source: Unused Security Group
```

The port is correct, but the actual EC2 client is not a member of the authorized source group.

Therefore, its traffic remains unauthorized.

### Important Concepts

| Concept | Explanation |
|---|---|
| Security Group | Stateful virtual firewall |
| Ingress Rule | Controls permitted inbound traffic |
| Egress Rule | Controls permitted outbound traffic |
| Source Security Group | Identifies which client network interfaces are authorized |
| TCP 5432 | Default PostgreSQL port |
| Implicit Deny | Traffic without a matching security group rule is blocked |
| Private RDS | Database is not directly accessible from the public internet |
| Network ACL | Stateless subnet-level network filtering |
| VPC Local Route | Allows routing between destinations inside the VPC CIDR |

**Important:** A rule allowing port `5432` is not sufficient by itself. The source of the traffic must also match the rule.

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
- Git and GitHub

### Security Guidelines

- Use a disposable database.
- Keep the RDS database private.
- Do not expose TCP 5432 to `0.0.0.0/0`.
- Use separate client and database security groups.
- Use Systems Manager instead of exposing SSH.
- Avoid storing database credentials in GitHub.
- Test connectivity from the actual client instance.
- Verify security group references before modifying rules.
- Delete temporary resources when finished.

### Cost Warning

RDS instances, EC2 instances, EBS storage, and public IPv4 addresses may incur charges.

The lab avoids Multi-AZ RDS, read replicas, and NAT gateways to limit costs.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab03"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab03-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab03-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab03-client"
export EC2_ROLE_NAME="cloud-rds-lab03-ssm-role"
export PROFILE_NAME="cloud-rds-lab03-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab03-client-sg"
export WRONG_SG_NAME="cloud-rds-lab03-wrong-sg"
export DB_SG_NAME="cloud-rds-lab03-db-sg"
```

### Step 2 — Verify AWS Access

```bash
aws sts get-caller-identity

aws --version
```

### Step 3 — Verify EC2 Instance Availability

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Check RDS Instance Class Availability

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
  --cidr-block "10.192.0.0/16" \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab03-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --cidr-block "10.192.1.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab03-public},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Private Subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.192.2.0/24" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab03-private-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Private Subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "10.192.3.0/24" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab03-private-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab03-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab03-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --region "$AWS_REGION")
```

The private database subnets remain on the VPC main route table, which contains the VPC local route.

---

## 8. Create the Security Groups

### Step 1 — Create the EC2 Client SG

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab03 EC2 client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Create the Incorrect Source SG

```bash
export WRONG_SG_ID=$(aws ec2 create-security-group \
  --group-name "$WRONG_SG_NAME" \
  --description "Lab03 incorrect source SG" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$WRONG_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create the RDS SG

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab03 RDS PostgreSQL" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Verify SG IDs

```bash
echo "Client SG: $CLIENT_SG_ID"
echo "Wrong SG:  $WRONG_SG_ID"
echo "RDS SG:    $DB_SG_ID"
```

### Step 5 — Configure the Intentional Misconfiguration

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$WRONG_SG_ID" \
  --region "$AWS_REGION"
```

This is the intentional fault.

The RDS security group allows PostgreSQL traffic, but only from the wrong security group.

### Step 6 — Verify the Rule

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
Source SG: Wrong SG
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

### Step 2 — Create the IAM Role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 3 — Create the Instance Profile

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

Attach only the client security group.

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

### Step 7 — Verify EC2 Security Group Association

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the instance uses `$CLIENT_SG_ID`, not `$WRONG_SG_ID`.

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
  --db-subnet-group-description "Lab03 private database subnets" \
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

### Step 3 — Enter a Temporary Database Password

```bash
read -rsp "Enter temporary RDS password: " DB_PASSWORD
echo
```

Use a strong, unique password for the disposable database.

The simple CLI command below passes the password as a process argument. This can briefly expose it to local process inspection. For production, prefer RDS-managed credentials in AWS Secrets Manager.

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

Remove the password variable:

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

## 11. Fault Injection — RDS Connection Timeout

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

Replace the placeholder with your real RDS endpoint. WSL environment variables do not automatically transfer into an SSM session.

### Step 2 — Verify DNS Resolution

```bash
getent ahostsv4 "$DB_ENDPOINT"

dig +short "$DB_ENDPOINT"
```

Expected: the RDS hostname resolves successfully.

### Step 3 — Test TCP Connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" "$DB_PORT"
```

Expected:

```text
Ncat: Connection timed out.
```

This is the intentional error.

### Step 4 — Attempt PostgreSQL Connection

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Expected error:

```text
connection to server at "...", port 5432 failed:
Connection timed out
```

### Step 5 — Verify RDS Status

From a separate WSL terminal:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: RDS remains available and private.

### Fault Summary

| Check | Expected Result |
|---|---|
| RDS | Available |
| EC2 | Running |
| DNS | Working |
| TCP 5432 | Timeout |
| PostgreSQL Login | Cannot begin |
| Inbound Rule | Present |
| Authorized SG | Wrong SG |
| Actual EC2 SG | Client SG |
| Root Cause | Source SG mismatch |

---

## 12. Troubleshooting Investigation

### Check 1 — Identify EC2 Security Group

From WSL:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the EC2 instance belongs to the client security group.

### Check 2 — Identify RDS Security Group

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].VpcSecurityGroups' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the database uses the dedicated RDS security group.

### Check 3 — Inspect RDS Ingress Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected structure:

```json
[
  {
    "IpProtocol": "tcp",
    "FromPort": 5432,
    "ToPort": 5432,
    "UserIdGroupPairs": [
      {
        "GroupId": "sg-WRONG_GROUP_ID"
      }
    ]
  }
]
```

The GroupId shown above is illustrative.

### Check 4 — Compare Security Group IDs

```bash
echo "Actual client SG: $CLIENT_SG_ID"
echo "RDS allowed SG:  $WRONG_SG_ID"
```

Expected: the IDs differ.

Read the authorized source directly:

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[].GroupId' \
  --output text \
  --region "$AWS_REGION"
```

Expected: `$WRONG_SG_ID`.

### Check 5 — Verify the Wrong SG Is Unused

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$WRONG_SG_ID" \
  --query 'NetworkInterfaces[].{ENI:NetworkInterfaceId,Status:Status,Instance:Attachment.InstanceId}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: no network interfaces associated with the wrong group.

### Check 6 — Verify EC2 Outbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$CLIENT_SG_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json \
  --region "$AWS_REGION"
```

Expected: client outbound traffic is permitted.

### Check 7 — Verify VPC Membership

EC2:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' \
  --output text \
  --region "$AWS_REGION"
```

RDS:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].DBSubnetGroup.VpcId' \
  --output text \
  --region "$AWS_REGION"
```

Expected: same VPC.

### Check 8 — Verify Route Tables

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: VPC local routing exists.

### Check 9 — Inspect Network ACLs

```bash
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Entries:Entries}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: default NACL configuration permits traffic.

### Investigation Summary

| Investigation | Finding |
|---|---|
| RDS Instance | Healthy |
| Database Endpoint | Valid |
| DNS | Working |
| EC2 VPC | Correct |
| RDS VPC | Correct |
| Route Tables | Local route present |
| Network ACL | Not blocking |
| EC2 Outbound | Allowed |
| RDS Inbound Port | 5432 |
| RDS Inbound Source | Incorrect security group |
| Root Cause | SG reference mismatch |

---

## 13. Root Cause Analysis

### Root Cause

The Amazon RDS security group allowed incoming PostgreSQL traffic only from an unused security group.

The EC2 application instance used a different security group.

Because the source group did not match, the database security group did not authorize the connection.

The connection attempt therefore timed out.

### Technical Explanation

An AWS inbound security group rule does not grant access merely because its protocol and port match the requested connection.

Its source condition must also match the client.

In this lab, the client was associated with `cloud-rds-lab03-client-sg`, but the RDS rule referenced `cloud-rds-lab03-wrong-sg`.

The mismatch caused the network authorization failure.

### Root Cause Flow

```text
EC2 Client
    |
    v
Attached SG: Client SG
    |
    v
TCP Connection to RDS:5432
    |
    v
RDS Inbound Rule
    |
    v
Allowed Source: Wrong SG
    |
    X
No Matching Source Rule
    |
    v
Connection Timeout
```

### Five Whys

1. **Why did PostgreSQL time out?** The database security group did not authorize the client.
2. **Why was the connection unauthorized?** The inbound rule referenced the wrong source security group.
3. **Why didn't the existing port 5432 rule work?** Its source did not match the actual EC2 client.
4. **Why did RDS remain available?** The issue was network authorization, not database health.
5. **How can this be prevented?** Validate security group references and test connectivity from the actual application instance.

### Prevention

- Use clear security group naming.
- Validate the security groups attached to application network interfaces.
- Check both protocol/port and source when reviewing rules.
- Use infrastructure as code to manage security groups consistently.
- Monitor unauthorized or unexpected security group changes.
- Keep RDS private.
- Test application connectivity following network changes.

---

## 14. Remediation — Correct the Security Group Reference

### Step 1 — Add the Correct Source SG

From WSL:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Remove the Wrong Source SG

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --source-group "$WRONG_SG_ID" \
  --region "$AWS_REGION"
```

The final configuration should have only the intended client security group as the authorized source for PostgreSQL.

### Step 3 — Verify the Rule

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

### Step 4 — Test TCP Connectivity

Inside EC2:

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected:

```text
Connection to RDS endpoint port 5432 succeeded.
```

### Step 5 — Connect to PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Enter the correct database password.

Expected: successful PostgreSQL login.

### Step 6 — Verify Database Identity

```sql
SELECT current_database(), current_user;
```

### Step 7 — Check Server Address and Port

```sql
SELECT inet_server_addr(), inet_server_port();
```

Expected port: `5432`.

### Step 8 — Create Test Table

```sql
CREATE TABLE lab03_connectivity_test (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

### Step 9 — Insert Test Data

```sql
INSERT INTO lab03_connectivity_test (id, message)
VALUES (1, 'RDS security group fixed');
```

### Step 10 — Verify SQL Query

```sql
SELECT * FROM lab03_connectivity_test;
```

Expected:

```text
 id |           message
----+------------------------------
  1 | RDS security group fixed
```

Exit PostgreSQL:

```text
\q
```

### Remediation Summary

| Check | Before Fix | After Fix |
|---|---|---|
| RDS Status | Available | Available |
| DNS | Working | Working |
| TCP 5432 | Timeout | Successful |
| Inbound Port | 5432 | 5432 |
| Authorized Source | Wrong SG | Client SG |
| PostgreSQL Authentication | Unreachable | Successful with valid credentials |
| SQL Query | Cannot execute | Successful |
| RDS Public Access | False | False |

---

## 15. Final Verification

### Verify RDS Availability

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

### Verify Inbound Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the actual client security group is the authorized source.

### Verify Client SG Association

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the EC2 instance is associated with the authorized client security group.

### Verify Network and Database Connectivity

Inside EC2:

```bash
getent hosts "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Connect to PostgreSQL:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require" \
  -W
```

Execute:

```sql
SELECT * FROM lab03_connectivity_test;
```

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| EC2 Instance | Running |
| RDS PostgreSQL | Available |
| DNS Resolution | Successful |
| TCP 5432 | Reachable |
| Source SG Reference | Correct |
| Wrong SG Reference | Removed |
| PostgreSQL Login | Successful |
| SQL Query | Successful |
| RDS Public Access | Disabled |
| Incident | Resolved |

---

## 16. Production Best Practices

### Security Group Troubleshooting Checklist

1. Identify the EC2 client.
2. Identify the target RDS database.
3. Verify the database endpoint.
4. Check TCP port 5432.
5. Confirm the security groups attached to EC2.
6. Confirm the security groups attached to RDS.
7. Inspect the RDS security group inbound rules.
8. Verify the source security group IDs.
9. Check EC2 outbound traffic.
10. Verify the VPC and route tables.
11. Check network ACLs if necessary.
12. Correct the specific security group reference.
13. Test TCP connectivity.
14. Verify PostgreSQL authentication.
15. Execute a SQL query.
16. Confirm the database remains private.

### Security Recommendations

- Use private RDS instances by default.
- Authorize only required client resources.
- Avoid PostgreSQL access from `0.0.0.0/0`.
- Use dedicated application and database security groups.
- Prefer security group references when appropriate.
- Use Systems Manager rather than opening SSH unnecessarily.
- Use TLS for PostgreSQL connections.
- Protect database credentials.
- Review network access changes.
- Use infrastructure as code and peer review for production changes.

### Key Cloud Security Lesson

A database security group rule can appear correct because the port is open, while the source reference makes it ineffective for the intended client.

Always validate the complete rule and the actual source network interface association.

---

## 17. Cleanup

**Warning:** These commands delete the disposable Lab 03 database and associated infrastructure.

### Step 1 — Exit PostgreSQL and EC2

If still inside PostgreSQL:

```text
\q
```

Exit the Systems Manager session:

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

Confirm the database belongs to `RDS-Troubleshooting-Lab03`.

### Step 3 — Delete RDS

This lab contains disposable data, so a final snapshot is not required.

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

### Step 5 — Verify EC2 Root Volume Settings

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root volume uses `DeleteOnTermination=true`.

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

Verify the IAM role belongs to this lab:

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

### Step 8 — Verify Network Interface Cleanup

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the AWS-managed network interfaces are removed.

### Step 9 — Delete Security Groups

Delete the database security group first because it references the client SG.

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$WRONG_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

If AWS reports a dependency violation, investigate remaining network interfaces or security group references before retrying.

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

aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected: empty arrays after cleanup completes.

Also verify the EC2 instance, root EBS volume, IAM role, instance profile, and database subnet group were removed.

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
| Wrong SG | Deleted |
| RDS SG | Deleted |
| Route Table | Deleted |
| Public Subnet | Deleted |
| Private Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 18. Interview Questions and Answers

### Q1. Why can RDS time out even when port 5432 is allowed?

The inbound rule may reference the wrong source security group or an incorrect IP range.

### Q2. What is a source security group reference?

It identifies the security group whose associated network interfaces are permitted to send matching traffic.

### Q3. How do you inspect EC2 security group associations?

Use `aws ec2 describe-instances` and examine `SecurityGroups`.

### Q4. How do you inspect RDS security group rules?

Use `aws ec2 describe-security-groups` with the database security group ID.

### Q5. Why did DNS work but TCP fail?

DNS resolution was functioning, but the security group blocked the network connection.

### Q6. What is the difference between Lab 01 and Lab 03?

Lab 01 had no inbound PostgreSQL rule. Lab 03 had an inbound rule, but its source security group was incorrect.

### Q7. Should PostgreSQL be opened to `0.0.0.0/0` during troubleshooting?

No. Database access should be restricted to authorized clients.

### Q8. Are security groups stateful?

Yes. Return traffic associated with an allowed connection is automatically permitted.

### Q9. What do network ACLs do?

They provide stateless filtering at the subnet level.

### Q10. Can private RDS communicate with an EC2 instance in the same VPC?

Yes, when routing and network security controls permit it.

### Q11. What should you verify after correcting the security group?

Test DNS, TCP connectivity, PostgreSQL login, SQL execution, and database public accessibility.

### Q12. How would you explain this lab in an interview?

I deployed a private Amazon RDS PostgreSQL database and an EC2 client inside the same VPC.

I intentionally configured the database security group to allow TCP 5432 from an unused security group rather than the EC2 client's actual security group.

Although the RDS database was available and its security group included a PostgreSQL inbound rule, connection attempts timed out.

I investigated the EC2 security group associations, RDS inbound rules, source group IDs, DNS resolution, VPC routing, and network ACLs.

After identifying the incorrect source security group as the root cause, I replaced it with the correct client security group.

I verified successful TCP connectivity with Netcat, established a PostgreSQL session using `psql`, and executed SQL queries.

The database remained private throughout the exercise.

---

## 19. Repository Structure

```text
03-rds-security-group-misconfiguration/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident, investigation, remediation, and cleanup |
| `ec2-trust-policy.json` | EC2 trust policy for Systems Manager access |

No database passwords or AWS credentials should be committed.

---

## 20. Lessons Learned

This lab demonstrates that an RDS connectivity failure can occur even when its security group includes an inbound rule for the correct port.

The problem was not the database engine, DNS resolution, or subnet routing.

The inbound PostgreSQL rule referenced a security group that was not attached to the actual EC2 client.

We used AWS CLI to compare the client and database security group configurations and identify the incorrect source reference.

We then replaced the rule and verified successful PostgreSQL connectivity and SQL execution.

**Key Lesson:** When investigating an RDS connection timeout, inspect both the destination port and the source security group or CIDR. An apparently correct port rule can still deny the intended application.

---

## 21. Skills Demonstrated

- Amazon RDS PostgreSQL
- AWS CLI v2
- Amazon EC2 administration
- Amazon VPC networking
- Security group source references
- Security group troubleshooting
- TCP connectivity testing
- DNS investigation
- Route table inspection
- Network ACL investigation
- Linux networking tools
- PostgreSQL `psql`
- SQL verification
- AWS Systems Manager
- Private database networking
- Least-privilege network remediation
- Root cause analysis
- Safe AWS cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-003 |
| Problem | RDS security group misconfiguration |
| RDS Engine | PostgreSQL |
| Database | labdb |
| Fault | Wrong security group reference |
| Expected Error | Connection timed out |
| Root Cause | Actual EC2 SG not authorized |
| Remediation | Correct client SG reference |
| DNS | Working |
| TCP Connectivity | Restored |
| PostgreSQL Login | Successful |
| SQL Query | Successful |
| RDS Public Access | Disabled |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Reliable cloud troubleshooting requires inspecting the complete network access rule—not just the port. Correct source security group references restore database connectivity while maintaining private, least-privilege access.
