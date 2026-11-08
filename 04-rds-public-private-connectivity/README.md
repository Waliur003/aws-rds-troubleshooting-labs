# Lab 04 — RDS Public vs. Private Connectivity

## Overview

This lab demonstrates how to investigate and troubleshoot Amazon RDS PostgreSQL connectivity from inside an AWS VPC and from an external Linux workstation. We deploy a disposable PostgreSQL database and an Amazon Linux 2023 EC2 troubleshooting client. EC2 can reach the database privately, while an Ubuntu WSL client outside the VPC cannot.

We isolate **three independent requirements** for direct public database connections: RDS public accessibility, Internet Gateway routing for the DB subnet group, and an inbound security group rule permitting the external source address. We temporarily enable public accessibility and a narrowly scoped `/32` inbound rule to prove the behavior. We then **remove the external access, disable public accessibility, and return the database subnets to private routing**.

The database remains dedicated to this disposable learning environment. Public connectivity is enabled only for a short, controlled test, never for ordinary production administration.

**Troubleshooting workflow:**

Infrastructure Setup → Private Connectivity Test → External Failure → Public Access Test → Security Group Investigation → Scoped External Test → Restore Private Networking → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-RDS-004 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | Amazon RDS, EC2, VPC, IAM, Systems Manager |
| Database Engine | PostgreSQL |
| RDS Instance Class | `db.t4g.micro` |
| RDS Storage | 20 GiB gp3, encrypted |
| RDS Deployment | Single-AZ, disposable |
| EC2 Client | `t3.micro`, Amazon Linux 2023 |
| Database | `labdb` |
| Username | `labadmin` |
| Database Port | TCP `5432` |
| VPC CIDR | `10.193.0.0/16` |
| Internal Test | EC2 → RDS |
| External Test | Ubuntu WSL → RDS |
| Initial RDS State | `PubliclyAccessible=false` |
| Temporary RDS State | `PubliclyAccessible=true` |
| Temporary External SG Source | Verified public IPv4 `/32` only |
| Initial External Error | Timeout or network unreachable |
| Root Cause | Private RDS is not directly reachable from an external internet client |
| Final Remediation | Restore private RDS and remove external ingress |
| Verification | `dig`, `nc`, `psql`, SQL queries and AWS CLI |

---

## 2. Production Incident Scenario

### Incident Description

An application on EC2 successfully connects to an Amazon RDS PostgreSQL database. A developer working from a personal workstation tries the same database endpoint and receives a connection error. RDS is healthy; the problem is **network reachability**, not necessarily PostgreSQL itself.

```text
connection to server at "database-endpoint", port 5432 failed:
Connection timed out
```

The engineer discovers `PubliclyAccessible=false`. Changing that single setting is not enough: public DB subnet routing and security group authorization are separate requirements. The team must determine which network boundary causes the failure and avoid leaving a sensitive database unnecessarily exposed.

### Incident Symptoms

- EC2 and RDS are running and in the same VPC.
- PostgreSQL accepts authenticated queries from EC2.
- An external Ubuntu WSL client cannot establish a TCP connection.
- Initially, RDS public accessibility is disabled.
- The database security group allows only the EC2 client security group.
- Setting public accessibility to true still does not authorize the external workstation.
- A short-lived `/32` rule for the workstation permits controlled verification.

### Business Impact

- Remote administration and development access are unavailable.
- Misdiagnosis could lead to unsafe broad database exposure.
- Unnecessary public access enlarges the attack surface.
- Poor network change management can interrupt legitimate application traffic.

### Objective

Distinguish private and public RDS networking, prove the role of DNS, IGW routes and security groups, restore a private-only design, and validate application connectivity after remediation.

---

## 3. AWS Architecture

### Lab Topology

```text
                     Amazon VPC 10.193.0.0/16
                              |
             +----------------+------------------+
             |                |                  |
       Client subnet      DB subnet A        DB subnet B
       10.193.1.0/24      10.193.2.0/24      10.193.3.0/24
             |                |                  |
       EC2 / Client SG       +---------+---------+
             |                        |
             +------ TCP 5432 ------> RDS PostgreSQL
                                      / DB SG

       External Ubuntu WSL
             |
         Internet
             |
       Internet Gateway
             |
       RDS public endpoint (only during temporary test)
```

### Broken External Connection

```text
Ubuntu WSL → Internet → RDS endpoint
                           |
               PubliclyAccessible=false
                           X
                  No direct public path
```

Even after `PubliclyAccessible=true`, the external connection is still denied while the DB security group allows only the EC2 security group.

### Temporarily Working External Connection

```text
Ubuntu WSL (verified public IPv4)
           |
       Internet Gateway
           |
    Public DB subnet routing
           |
    RDS public accessibility = true
           |
    DB SG permits client IPv4 /32
           |
        TCP 5432 → PostgreSQL → SQL query
```

### Final Recovered Configuration

```text
Ubuntu WSL → X  no direct external RDS access

EC2 Client SG → VPC local route → DB SG → Private RDS
                                            |
                                         SQL query
```

### Network Design

| Resource | Configuration |
|---|---|
| VPC | `10.193.0.0/16` |
| Client subnet | `10.193.1.0/24` |
| DB subnet A | `10.193.2.0/24` |
| DB subnet B | `10.193.3.0/24` |
| Client subnet routing | Default route to Internet Gateway |
| DB subnet routing during test | Default route to Internet Gateway |
| DB subnet routing after remediation | VPC local route only |
| Client SG | `cloud-rds-lab04-client-sg` |
| DB SG | `cloud-rds-lab04-db-sg` |
| Internal authorized source | Client SG |
| Temporary external source | Verified IPv4 `/32` |
| EC2 management | AWS Systems Manager Session Manager |

**Design note:** The DB subnets are deliberately routed publicly during the experiment, although RDS initially has no public accessibility. The end state removes those routes so the DB subnets become private in the network-routing sense.

---

## 4. Understanding Public and Private RDS Connectivity

A **private RDS** database is accessible over approved private network paths, including same-VPC EC2 communication. Its endpoint is not directly reachable through the public internet. A **publicly accessible RDS** database can obtain public addressing, but it is only reachable by external clients when the subnet routes, security rules and upstream network also permit traffic.

| Concept | Meaning |
|---|---|
| `PubliclyAccessible=false` | No direct public IP reachability for RDS |
| `PubliclyAccessible=true` | Enables public addressing; does **not** bypass firewalls |
| DB subnet group | Defines database subnet placement across Availability Zones |
| Internet Gateway route | Provides an internet route for public subnet use |
| Security group | Stateful network permission control |
| Source SG reference | Authorizes clients attached to a referenced SG |
| IPv4 `/32` | One specific public IPv4 source address |
| DNS endpoint | RDS-managed hostname; resolved addresses may change |
| VPC local route | Allows traffic among addresses in the VPC CIDR |
| Network ACL | Stateless subnet traffic filtering |
| TLS (`sslmode=require`) | Encrypts the PostgreSQL session; does not itself validate the server identity |

**Key concept:** `PubliclyAccessible=true` alone does not mean `0.0.0.0/0` can connect. The DB security group must authorize the source, and all relevant DB subnet-group subnets must support public routing. For stronger identity verification in real deployments, use `sslmode=verify-full` with the appropriate RDS CA certificate.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account with disposable lab permissions for VPC, EC2, RDS, IAM, and Systems Manager.
- AWS CLI v2 configured in Ubuntu WSL2.
- Bash, Git, and a GitHub repository.
- Local `psql`, `nc`, `dig`, and `curl` tools (installed below).
- AWS Session Manager plugin installed **locally** for `aws ssm start-session`.
- No corporate VPN or private route into the test VPC during the *external internet* connection test.

### Security Rules

- Use a disposable database with **synthetic data only**.
- **Never** use `0.0.0.0/0` for PostgreSQL ingress.
- Temporarily authorize only the current, verified public IPv4 `/32`.
- Remove the external SG rule as soon as the connectivity test is complete.
- Disable RDS public accessibility afterward.
- Restore private DB subnet routing before ending the lab.
- Keep credentials out of Git, screenshots, shell history and command logs.
- Use Systems Manager instead of opening port 22.
- Verify ownership tags before deleting resources.

### Cost Warning

RDS, EC2, storage and public IPv4 resources may generate charges. This lab avoids NAT gateways, Multi-AZ deployment, and replicas. **Perform the complete cleanup** when testing is finished.

### Documentation Convention

All commands run in **Ubuntu WSL2** unless explicitly labeled **inside EC2** or **inside `psql`**. Values marked `YOUR_ACTUAL_...` must be replaced with real lab values. Tables describe **expected** outcomes, not results already observed.

---

## 6. Prepare the Environment

### Create the Lab Directory

```bash
cd "/mnt/d/AWS Cloud/Troubleshooting Labs/RDS/aws-rds-troubleshooting-labs"
mkdir -p 04-rds-public-private-connectivity
cd 04-rds-public-private-connectivity
```

The path above comes from the supplied lab procedure; adjust it if your local repository lives elsewhere.

### Step 1 — Configure environment variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="RDS-Troubleshooting-Lab04"

export AZ_A="us-east-1a"
export AZ_B="us-east-1b"

export DB_IDENTIFIER="cloud-rds-lab04-postgres"
export DB_SUBNET_GROUP="cloud-rds-lab04-subnet-group"

export DB_NAME="labdb"
export DB_USERNAME="labadmin"
export DB_PORT="5432"

export EC2_NAME="cloud-rds-lab04-client"
export EC2_ROLE_NAME="cloud-rds-lab04-ssm-role"
export PROFILE_NAME="cloud-rds-lab04-ssm-profile"

export CLIENT_SG_NAME="cloud-rds-lab04-client-sg"
export DB_SG_NAME="cloud-rds-lab04-db-sg"
```

### Step 2 — Verify AWS credentials

```bash
aws sts get-caller-identity
aws --version
```

Check EC2 instance support:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Check the RDS class:

```bash
aws rds describe-orderable-db-instance-options \
  --engine postgres \
  --db-instance-class db.t4g.micro \
  --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass,Version:EngineVersion}' \
  --output table \
  --region "$AWS_REGION"
```

Choose compatible Availability Zones if needed.

### Step 3 — Check for existing Lab 04 resources

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

Do not create duplicates if the lab already exists.

---

## 7. Create the AWS VPC

Build a dedicated test VPC. The EC2 subnet and both database subnets temporarily receive IGW routing so the public-access requirement can be investigated separately from the RDS public flag.

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.193.0.0/16 \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-rds-lab04-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 2 — Create EC2 client subnet

```bash
export CLIENT_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.193.1.0/24 \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab04-client},{Key=Project,Value=$PROJECT_TAG}]" \
  --query Subnet.SubnetId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create DB subnet A

```bash
export DB_SUBNET_A=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.193.2.0/24 \
  --availability-zone "$AZ_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab04-db-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query Subnet.SubnetId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create DB subnet B

```bash
export DB_SUBNET_B=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block 10.193.3.0/24 \
  --availability-zone "$AZ_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-rds-lab04-db-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query Subnet.SubnetId \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-rds-lab04-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query InternetGateway.InternetGatewayId \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Create public route table

```bash
export PUBLIC_RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-rds-lab04-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query RouteTable.RouteTableId \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$PUBLIC_RT_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Associate all three subnets

For the temporary public RDS test, both database subnets require internet-gateway routing. AWS specifies that all subnets in a publicly accessible DB subnet group must be public.

Associate the client subnet:

```bash
export CLIENT_RT_ASSOC=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$CLIENT_SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Associate database subnet A:

```bash
export DB_RT_ASSOC_A=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$DB_SUBNET_A" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Associate database subnet B:

```bash
export DB_RT_ASSOC_B=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --subnet-id "$DB_SUBNET_B" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$PUBLIC_RT_ID" \
  --query 'RouteTables[0].{Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: all three subnets are associated with the route table containing `0.0.0.0/0 → Internet Gateway`.

---

## 8. Create Security Groups

Use a dedicated EC2 client security group and a dedicated RDS security group. Initially, only traffic associated with the EC2 SG can reach PostgreSQL.

### Step 1 — Create security groups

EC2 client security group:

```bash
export CLIENT_SG_ID=$(aws ec2 create-security-group \
  --group-name "$CLIENT_SG_NAME" \
  --description "Lab04 EC2 database client" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$CLIENT_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

RDS security group:

```bash
export DB_SG_ID=$(aws ec2 create-security-group \
  --group-name "$DB_SG_NAME" \
  --description "Lab04 RDS PostgreSQL" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$DB_SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Permit private EC2-to-RDS access

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port "$DB_PORT" \
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

Expected: TCP `5432` from the EC2 client security group, with no public CIDR rule.

---

## 9. Deploy the EC2 Troubleshooting Client

Use Amazon Linux 2023 with an IAM instance profile and Systems Manager Session Manager. No inbound SSH permission is required.

### Step 1 — Create EC2 trust policy

Save this in the Lab 04 folder:

```bash
cat > ec2-trust-policy.json <<'EOF'
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
EOF
```

### Step 2 — Create SSM IAM role

```bash
aws iam create-role \
  --role-name "$EC2_ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$EC2_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

Create the instance profile:

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$EC2_ROLE_NAME"
```

Allow IAM propagation before launching EC2.

### Step 3 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$CLIENT_SUBNET_ID,Groups=$CLIENT_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$EC2_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")

echo "$INSTANCE_ID"
```

Wait for the instance:

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Install PostgreSQL tools

Connect using SSM:

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

Exit EC2:

```text
exit
```

---

## 10. Create RDS PostgreSQL

The RDS instance starts in private mode, even though the test DB subnets currently have IGW routes. This allows us to isolate the public-access flag. Use temporary lab credentials and store them securely for later authentication tests.

### Step 1 — Create DB subnet group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --db-subnet-group-description "Lab04 database subnet group for public private testing" \
  --subnet-ids "$DB_SUBNET_A" "$DB_SUBNET_B" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --region "$AWS_REGION"
```

Verify two Availability Zones:

```bash
aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --query 'DBSubnetGroups[0].Subnets[].{ID:SubnetIdentifier,AZ:SubnetAvailabilityZone.Name}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 2 — Create a disposable database password

```bash
read -rsp "Enter a strong temporary RDS password: " DB_PASSWORD
echo
```

Keep it securely available for the later PostgreSQL tests.

The following command supplies a password argument to the local AWS CLI process, which can briefly expose the value to process inspection. This is for a disposable lab only; for production prefer RDS-managed credentials with AWS Secrets Manager.

### Step 3 — Create RDS in private mode

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

Remove the shell variable:

```bash
unset DB_PASSWORD
```

Wait for availability:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 4 — Verify RDS is not public

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,PubliclyAccessible:PubliclyAccessible,MultiAZ:MultiAZ}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Status: available
PubliclyAccessible: False
MultiAZ: False
```

### Step 5 — Retrieve the endpoint

```bash
export DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION")

echo "$DB_ENDPOINT"
```

The same RDS endpoint DNS name will be used for both private and public tests. The IP address it resolves to can differ depending on the database's public-access configuration and the DNS query location.

---

## 11. Fault Injection — External RDS Connection Failure

### Baseline: Verify Private EC2-to-RDS Connectivity

Before investigating the external failure, prove that the database itself works. From EC2, verify private DNS resolution, TCP port `5432`, authentication, and a SQL query.

### Step 1 — Connect to EC2

From WSL:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2, copy the real endpoint obtained in Section 10:

```bash
export DB_ENDPOINT="YOUR_ACTUAL_RDS_ENDPOINT"
export DB_PORT="5432"
```

### Step 2 — Verify internal DNS resolution

```bash
getent ahostsv4 "$DB_ENDPOINT"

dig +short "$DB_ENDPOINT"
```

Expected: a private IP address in the VPC.

### Step 3 — Test TCP 5432

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: connection succeeds.

This verifies that the EC2 client can reach the RDS database privately.

### Step 4 — Connect with PostgreSQL

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Enter the correct database password.

Expected: successful login.

Run:

```sql
SELECT current_database(), current_user;
```

Then:

```sql
SELECT inet_server_addr(), inet_server_port();
```

Create a test table:

```sql
CREATE TABLE lab04_connectivity_test (
    id INTEGER PRIMARY KEY,
    message TEXT NOT NULL
);
```

Insert a record:

```sql
INSERT INTO lab04_connectivity_test (id, message)
VALUES (1, 'Private RDS connectivity working');
```

Verify:

```sql
SELECT * FROM lab04_connectivity_test;
```

Exit PostgreSQL:

```text
\q
```

Then exit EC2:

```text
exit
```

### Test 1 findings

| Check                | Expected result |
| -------------------- | --------------- |
| RDS state            | Available       |
| Public accessibility | False           |
| EC2 DNS              | Resolves        |
| EC2 TCP 5432         | Successful      |
| PostgreSQL login     | Successful      |
| SQL query            | Successful      |

Conclusion: A database does not need to be publicly accessible for an EC2 instance in the same VPC to connect.

### External Failure from Ubuntu WSL

Test directly from the **local WSL workstation**, not through the EC2 SSM session. The expected failed connection is the incident symptom.

### Step 1 — Install local troubleshooting tools

In WSL:

```bash
sudo apt-get update

sudo apt-get install -y \
  postgresql-client \
  netcat-openbsd \
  dnsutils \
  curl
```

Verify:

```bash
psql --version
nc -h
dig -v
```

### Step 2 — Check the RDS endpoint from WSL

```bash
echo "$DB_ENDPOINT"

dig +short "$DB_ENDPOINT"
```

When RDS is private, the endpoint normally resolves to private IP addressing.

Do not assume every public DNS resolver will return identical results.

### Step 3 — Test external TCP connectivity

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: a timeout, network-unreachable result, or another failed TCP connection.

The database isn't publicly reachable.

If your computer is connected to a corporate VPN or private AWS network, your results may differ. For this test, use an ordinary internet connection without a private route into the lab VPC.

### Step 4 — Test with `psql`

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Expected: connection failure before successful authentication.

### Test 2 findings

| Check                          | Expected result          |
| ------------------------------ | ------------------------ |
| Internal EC2 access            | Working                  |
| External WSL access            | Blocked                  |
| PubliclyAccessible             | False                    |
| RDS security group             | Allows EC2 SG only       |
| Database availability          | Healthy                  |
| Root cause of external failure | No public network access |

This is the intended and recommended configuration for many production databases.

### Fault Summary

| Check | Expected Result |
|---|---|
| RDS instance | Available |
| EC2 → RDS TCP 5432 | Successful |
| EC2 → RDS SQL | Successful |
| External WSL → RDS TCP 5432 | Failed |
| RDS public flag | False |
| Database SG | Allows EC2 SG only |
| Meaning | External failure is network-related, not proof of an unhealthy database |

---

## 12. Troubleshooting Investigation

Work from the inside out: confirm the database is healthy, compare internal and external network behavior, inspect public addressing, then inspect the security group source.

### Check 1 — Confirm RDS and EC2 Status

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible,Endpoint:Endpoint.Address}' \
  --output table --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{State:State.Name,VPC:VpcId,SGs:SecurityGroups}' \
  --output json --region "$AWS_REGION"
```

### Check 2 — Compare Actual Network Sources

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].VpcSecurityGroups' \
  --output json --region "$AWS_REGION"

aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json --region "$AWS_REGION"
```

Expected initially: the inbound TCP 5432 rule references the EC2 SG, not an external public IPv4 CIDR.

### Check 3 — Inspect Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json --region "$AWS_REGION"
```

Confirm the client subnet and both database subnets are associated with the intended public route table **during the test**.

### Check 4 — Inspect Network ACLs

```bash
aws ec2 describe-network-acls \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkAcls[].{ID:NetworkAclId,Entries:Entries,Associations:Associations}' \
  --output json --region "$AWS_REGION"
```

The default NACL is expected to allow the test. Custom NACLs may block TCP 5432 or return ephemeral ports.

### Check 5 — Compare DNS and TCP Results

From **WSL**:

```bash
dig +short "$DB_ENDPOINT"
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Inside **EC2**, run the same commands with the endpoint defined in that shell. DNS can resolve to different addresses depending on where the query runs and whether public accessibility is enabled. DNS success does not prove TCP reachability.

### Investigation Summary

| Investigation | Initial Finding |
|---|---|
| RDS health | Available |
| EC2 private connection | Works |
| External connection | Fails |
| RDS public accessibility | Disabled |
| DB subnet routing | Temporarily includes IGW route |
| RDS inbound authorization | EC2 SG only |
| Root cause of initial external failure | No authorized public network path |

### Isolate Public Accessibility from the SG

Enable RDS public accessibility while leaving the DB SG unchanged. The expected result is **still no external TCP connection**. This proves that receiving public addressing is not equivalent to authorization.

### Step 1 — Modify the database

From WSL:

```bash
aws rds modify-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --publicly-accessible \
  --apply-immediately \
  --region "$AWS_REGION"
```

Public accessibility changes are applied immediately by RDS rather than waiting for a maintenance window, although reaching a usable state may still require time for networking and DNS changes.

### Step 2 — Verify the setting

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

Check:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,PubliclyAccessible:PubliclyAccessible,Endpoint:Endpoint}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
PubliclyAccessible: true
```

### Step 3 — Check DNS from outside AWS

In WSL:

```bash
dig +short "$DB_ENDPOINT"
```

For a publicly accessible database, its endpoint should resolve to a public IP address when queried from outside the VPC, once DNS updates propagate.

Do not hardcode that address. Always use the endpoint hostname.

### Step 4 — Test TCP connectivity without changing the SG

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: connection still fails.

Why?

The RDS security group currently allows only traffic from the EC2 client security group. Your external WSL host does not belong to it.

### Test 3 findings

| Setting                  | Expected         |
| ------------------------ | ---------------- |
| RDS public accessibility | True             |
| DB subnet routing        | Internet Gateway |
| RDS public DNS           | Public address   |
| RDS SG                   | EC2 SG only      |
| External TCP 5432        | Blocked          |

Lesson: A public IP does not bypass the RDS security group.

---

## 13. Root Cause Analysis

### Root Cause

The developer attempted to connect from outside AWS to an RDS instance configured for private access. The internal EC2 application could connect because the VPC local route and DB security group allowed it. External access was unavailable by design.

After enabling the RDS public flag, connectivity remained blocked because the DB security group still authorized **only** the internal EC2 client SG. External access needs a valid public network path **and** a matching inbound rule.

### Technical Explanation

```text
External WSL client
       |
       v
RDS PubliclyAccessible=false
       X  no direct public endpoint

After setting PubliclyAccessible=true:
       |
       v
IGW routing and public RDS addressing
       |
       v
DB SG source = EC2 client SG only
       X  WSL public IP is not authorized
```

### Five Whys

1. **Why did the remote developer time out?** Direct internet connectivity to the RDS endpoint was unavailable.
2. **Why was direct connectivity unavailable initially?** Public accessibility was disabled.
3. **Why was enabling public accessibility alone insufficient?** The database SG still excluded the developer's source IP.
4. **Why did the application on EC2 work?** EC2 used authorized private VPC networking.
5. **What is the long-term solution?** Keep RDS private and provide administrative access through an approved private connection path.

### Prevention

- Define database exposure requirements before deployment.
- Use infrastructure as code and review RDS public-access changes.
- Monitor public exposure and unexpected SG rule changes.
- Prefer approved private management paths instead of changing a database to public for convenience.
- Test from the actual source network and preserve least-privilege rules.

---

## 14. Remediation — Controlled Test and Restore Private Networking

**Warning:** This section temporarily creates public reachability for a **disposable** database. Revoke the `/32` rule immediately after Test 4, then restore private RDS configuration.

### Temporarily Authorize the Exact External Source

### Step 1 — Retrieve your public IPv4 address

In WSL:

```bash
export MY_PUBLIC_IP=$(curl -4 -fsS https://checkip.amazonaws.com | tr -d '\r\n')

echo "$MY_PUBLIC_IP"
```

Check that the output is a valid public IPv4 address. Do not proceed if the command fails or prints an unexpected value.

Set the CIDR:

```bash
export MY_PUBLIC_CIDR="${MY_PUBLIC_IP}/32"

echo "$MY_PUBLIC_CIDR"
```

Example only:

```text
198.51.100.25/32
```

The example address above is not your actual IP.

Important: If you're behind a corporate firewall, VPN, carrier-grade NAT, or changing home IP, the address or outbound port policy may prevent the test from succeeding. Do not broaden the ingress rule to compensate.

### Step 2 — Add the temporary external rule

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --cidr "$MY_PUBLIC_CIDR" \
  --region "$AWS_REGION"
```

This authorizes only connections originating from your selected public IPv4 address.

### Step 3 — Verify the security group

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected two authorized sources for TCP 5432:

- The EC2 client security group.
- Your temporary public IPv4 `/32`.

There should be no `0.0.0.0/0` rule.

### Step 4 — Test external TCP connectivity

From WSL:

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: TCP connection succeeds.

If it still fails, verify the public IP has not changed, the endpoint resolves publicly, both DB subnets use the internet gateway route, and the RDS instance has reached its available state.

### Step 5 — Test external PostgreSQL access

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Enter the correct disposable database password.

Expected: a successful PostgreSQL session.

Run:

```sql
SELECT current_database(), current_user;
```

Then:

```sql
SELECT * FROM lab04_connectivity_test;
```

Expected: the record created earlier from EC2 is returned.

Exit PostgreSQL:

```text
\q
```

### Test 4 findings

| Setting                   | Expected result      |
| ------------------------- | -------------------- |
| PubliclyAccessible        | True                 |
| DB subnet routing         | Public               |
| SG source                 | Your public IP `/32` |
| External TCP 5432         | Successful           |
| External PostgreSQL login | Successful           |
| Query existing data       | Successful           |

We have now demonstrated all three components required for external RDS connectivity.

### Restore Secure Private Access

### Step 1 — Revoke external PostgreSQL access

Run this immediately after Test 4:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$DB_SG_ID" \
  --protocol tcp \
  --port 5432 \
  --cidr "$MY_PUBLIC_CIDR" \
  --region "$AWS_REGION"
```

Verify that only the EC2 security group remains:

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

### Step 2 — Disable public accessibility

```bash
aws rds modify-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --no-publicly-accessible \
  --apply-immediately \
  --region "$AWS_REGION"
```

Wait for RDS availability:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,PubliclyAccessible:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
PubliclyAccessible: False
```

### Step 3 — Return the DB subnets to private routing

Now that public accessibility is disabled, remove the two database subnet associations from the public route table.

```bash
aws ec2 disassociate-route-table \
  --association-id "$DB_RT_ASSOC_A" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$DB_RT_ASSOC_B" \
  --region "$AWS_REGION"
```

Both DB subnets now inherit the VPC main route table, which contains only the VPC local route.

Confirm the main route table:

```bash
aws ec2 describe-route-tables \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=association.main,Values=true" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: local VPC routing and no `0.0.0.0/0` route to an internet gateway.

Your EC2 subnet keeps its internet gateway route so Systems Manager connectivity remains available.

### Remediation Summary

| Setting | Initially | Controlled Public Test | Restored |
|---|---|---|---|
| RDS public flag | False | True | False |
| DB subnet IGW routes | Present for test | Present | Removed |
| RDS SG public `/32` | None | Temporary workstation IP | Removed |
| EC2 → RDS | Works | Works | Works |
| External WSL → RDS | Blocked | Allowed during `/32` test | Blocked |
| PostgreSQL data | Available internally | Available with valid login | Available internally |

---

## 15. Final Verification

Verify that the private application path remains functional and that external direct access is again blocked.

### Step 1 — Verify private connectivity still works

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2, set the endpoint if needed:

```bash
export DB_ENDPOINT="YOUR_ACTUAL_RDS_ENDPOINT"
```

Test:

```bash
getent ahostsv4 "$DB_ENDPOINT"

nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: the database is still reachable privately.

Connect:

```bash
psql \
  "host=$DB_ENDPOINT port=5432 dbname=labdb user=labadmin sslmode=require connect_timeout=5" \
  -W
```

Then:

```sql
SELECT * FROM lab04_connectivity_test;
```

Expected: the original record remains accessible.

Exit `psql` and SSM.

### Step 2 — Verify external access is blocked again

From WSL:

```bash
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

Expected: external connection fails.

Confirm the RDS setting:

```bash
aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Public:PubliclyAccessible}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Public: False
```

### Final investigation matrix

| Test                     | Initial private     | Temporary public         | Final private |
| ------------------------ | ------------------- | ------------------------ | ------------- |
| RDS public flag          | False               | True                     | False         |
| DB subnet internet route | Present for testing | Present                  | Removed       |
| EC2-to-RDS               | Works               | Works                    | Works         |
| WSL-to-RDS               | Blocked             | Works with `/32` SG rule | Blocked       |
| External SG rule         | None                | Your IP only             | Removed       |
| PostgreSQL data          | Accessible          | Accessible               | Accessible    |

### Verify Only the EC2 SG Is Authorized

```bash
aws ec2 describe-security-groups \
  --group-ids "$DB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json --region "$AWS_REGION"
```

Expected: the PostgreSQL rule references the EC2 client SG. No remaining public IPv4 `/32` rule and no `0.0.0.0/0` rule.

### Final Verification Matrix

| Check | Expected Result |
|---|---|
| EC2 | Running |
| RDS PostgreSQL | Available |
| `PubliclyAccessible` | False |
| DB subnets | VPC-local-only routes |
| Internal DNS | Resolves |
| EC2 → RDS TCP 5432 | Successful |
| PostgreSQL login from EC2 | Successful |
| SQL `SELECT` from EC2 | Successful |
| External WSL → RDS TCP 5432 | Blocked |
| Temporary external SG rule | Removed |
| Incident status | Secure private connectivity restored |

---

## 16. Production Best Practices

### RDS Connectivity Troubleshooting Checklist

1. Confirm the RDS instance is available.
2. Validate the endpoint hostname and database port.
3. Test the endpoint from the actual failing source.
4. Compare DNS answers inside and outside the VPC.
5. Check `PubliclyAccessible` without assuming it proves reachability.
6. Verify DB subnet-group subnets and their route tables.
7. Verify Internet Gateway routing when public access is explicitly required.
8. Inspect inbound DB SG protocol, port, and source.
9. Confirm client egress rules, NACLs, and upstream firewalls.
10. Distinguish network timeouts from authentication errors.
11. Prove functionality with a PostgreSQL query.
12. Remove all temporary public-access changes.
13. Confirm normal EC2-to-RDS connectivity afterward.

### Security Recommendations

- Keep production databases private unless public access is a reviewed requirement.
- Use Session Manager, VPN, Direct Connect, or an approved private client to administer databases.
- Restrict access to application SGs or narrow approved CIDRs.
- Never open PostgreSQL to `0.0.0.0/0` as a troubleshooting shortcut.
- Require TLS and validate server certificates for production clients.
- Prefer managed secret storage and credential rotation.
- Monitor changes using CloudTrail and applicable AWS security controls.
- Manage network infrastructure through reviewed IaC.

### Common Symptom Comparison

| Symptom | Investigate |
|---|---|
| EC2 works, laptop fails | Public flag, endpoint DNS, routes, SG source, laptop firewall |
| Endpoint resolves to private IP outside VPC | RDS public-access setting and DNS behavior |
| Public IP resolves, TCP times out | SG, NACL, route, outbound firewall |
| TCP connects, authentication fails | Username, password, PostgreSQL database and auth configuration |
| Internal EC2 cannot connect | VPC routing, SGs, NACLs, endpoint, RDS state |
| Connectivity changes after failover | DNS cache and client reconnect behavior |

**Key lesson:** Public addressing, subnet reachability, and database authorization are related but separate controls.

---

## 17. Cleanup

**Warning:** The commands below permanently delete the disposable database and all Lab 04 AWS resources. Confirm the project tag and verify no useful data remains before proceeding.

Exit PostgreSQL with `\q`, then exit the SSM session with `exit`, if applicable.

### Step 1 — Verify the RDS project tag

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

Confirm `Project=RDS-Troubleshooting-Lab04`.

### Step 2 — Delete the RDS instance

```bash
aws rds delete-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --skip-final-snapshot \
  --delete-automated-backups \
  --region "$AWS_REGION"
```

The final snapshot is intentionally skipped because the database is disposable.

Wait for deletion:

```bash
aws rds wait db-instance-deleted \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION"
```

### Step 3 — Delete the DB subnet group

```bash
aws rds delete-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --region "$AWS_REGION"
```

### Step 4 — Verify EC2 root volume settings

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

### Step 6 — Delete the EC2 IAM role

Verify ownership:

```bash
aws iam list-role-tags \
  --role-name "$EC2_ROLE_NAME"
```

Then:

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

### Step 7 — Verify network interfaces are removed

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until EC2 and RDS network interfaces have disappeared.

### Step 8 — Delete both security groups

```bash
aws ec2 delete-security-group \
  --group-id "$DB_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$CLIENT_SG_ID" \
  --region "$AWS_REGION"
```

Delete the database SG first because it references the client SG.

### Step 9 — Remove remaining route-table associations

If you completed Step 43, the DB subnet associations have already been removed. If you skipped it, disassociate those two before deleting the route table.

Disassociate the EC2 subnet:

```bash
aws ec2 disassociate-route-table \
  --association-id "$CLIENT_RT_ASSOC" \
  --region "$AWS_REGION"
```

Delete the route table:

```bash
aws ec2 delete-route-table \
  --route-table-id "$PUBLIC_RT_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete the subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$CLIENT_SUBNET_ID" \
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

### Step 13 — Verify cleanup

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

Expected: empty arrays.

Also confirm the EC2 instance, root EBS volume, IAM role, and instance profile are removed.

### Cleanup Verification Matrix

| Resource | Expected Result |
|---|---|
| RDS instance | Deleted |
| DB subnet group | Deleted |
| EC2 instance | Terminated |
| EC2 root EBS volume | Deleted when `DeleteOnTermination=true` |
| IAM role | Deleted |
| Instance profile | Deleted |
| Client SG | Deleted |
| DB SG | Deleted |
| Public route table | Deleted |
| Three lab subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC / other projects | Unchanged |

**If cleanup reports a dependency violation**, inspect remaining ENIs, route table associations, and SG references; do not delete unrelated resources.

---

## 18. Interview Questions and Answers

### Q1. What is the difference between public and private RDS?

A publicly accessible RDS instance can have an internet-reachable public IP address, subject to subnet routing and security rules. A private RDS instance doesn't provide direct public internet access.

### Q2. Does `PubliclyAccessible=true` automatically allow all clients?

No. The security group must also authorize the client's traffic, and the DB subnet-group network must support public access.

### Q3. Can an EC2 instance connect to private RDS?

Yes, using private VPC routing and appropriate security group rules.

### Q4. Does RDS need a NAT gateway for same-VPC connections?

No. Same-VPC communication uses the local VPC route.

### Q5. Why does RDS use a DNS endpoint instead of a fixed IP?

RDS manages the underlying infrastructure, and IP addresses can change during operations such as failover.

### Q6. What happens to DNS when public accessibility changes?

The RDS endpoint may resolve to a public address externally when public access is enabled, while resolving privately within the VPC.

### Q7. What is a `/32` security group rule?

It permits traffic from one specific IPv4 address.

### Q8. Why use a security group reference for EC2 clients?

It authorizes traffic from resources associated with the designated SG without depending on individual EC2 private IPs.

### Q9. Can an internet gateway route make a private RDS instance public by itself?

No. RDS public accessibility and security group permissions also matter.

### Q10. How can you test TCP access to PostgreSQL?

```
nc -vz -w 5 "$DB_ENDPOINT" 5432
```

### Q11. What is a safer alternative to public RDS access?

A private EC2 client accessed through Systems Manager, a properly configured VPN, or another approved private network path.

### Q12. How would you explain this lab in an interview?

> I deployed a PostgreSQL RDS database and an EC2 client inside the same VPC. I first verified that EC2 could connect privately while direct external access failed. Then I temporarily enabled RDS public accessibility and confirmed that the external connection was still blocked by the security group. After allowing only my verified public IPv4 address, I established a PostgreSQL connection from outside the VPC. Finally, I removed the external rule, disabled public accessibility, restored private subnet routing, and verified EC2-to-RDS connectivity remained operational. This helped me understand how RDS public accessibility, VPC routing, DNS, and security groups work together.

---

## 19. Repository Structure

```text
04-rds-public-private-connectivity/
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Incident scenario, architecture, investigation, remediation, tests and cleanup |
| `ec2-trust-policy.json` | EC2 IAM trust policy for Systems Manager |

The trust policy is created in the lab procedure. No AWS keys, database passwords, connection secrets or private personal IP information should be committed.

### Git Commands (Run After Completing the Practical Lab)

From the repository root:

```bash
git add 04-rds-public-private-connectivity/README.md \
        04-rds-public-private-connectivity/ec2-trust-policy.json

git commit -m "docs: add RDS public vs private connectivity lab 04"
git push origin HEAD
```

Confirm you are on the intended Git branch before pushing.

---

## 20. Lessons Learned

This lab shows why a healthy RDS PostgreSQL database can work from an EC2 instance while remaining unreachable from an external workstation. The failure is a consequence of intentionally private network design, not necessarily a database outage.

First, EC2-to-RDS connectivity succeeded using VPC local routing and a source-SG reference. Next, WSL-to-RDS failed while `PubliclyAccessible=false`. Enabling public accessibility demonstrated that **public IP availability does not override security groups**. A temporary `/32` ingress rule then allowed a controlled external PostgreSQL connection, after which the public access was removed.

The final configuration keeps RDS private, removes external inbound access, and retains application connectivity from EC2.

**Key Lesson:** Troubleshoot RDS connectivity as a combination of endpoint DNS, RDS accessibility, subnet routing, security group authorization, and client-side reachability. Do not weaken production database security just to make an external diagnostic test succeed.

---

## 21. Skills Demonstrated and Final Outcome

### Skills Demonstrated

- Amazon RDS PostgreSQL administration
- AWS CLI v2 and Ubuntu WSL2
- VPC and subnet design
- Internet Gateway routing and route tables
- Public vs private RDS connectivity
- Database security group troubleshooting
- Source security group references and `/32` CIDRs
- Amazon EC2 and Systems Manager
- IAM roles and instance profiles
- Linux DNS and TCP diagnosis (`dig`, `nc`)
- PostgreSQL client (`psql`) and SQL verification
- Controlled network fault isolation
- Root cause analysis and Five Whys
- Least-privilege remediation
- Validation after security changes
- Safe infrastructure teardown

### Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-RDS-004 |
| Problem | External client cannot reach private RDS |
| Database Engine | PostgreSQL |
| Database | `labdb` |
| Initial RDS Flag | `PubliclyAccessible=false` |
| Controlled Test Flag | `PubliclyAccessible=true` |
| Initial External Connection | Blocked |
| External Connection With `/32` Rule | Successful |
| Root Cause | Public access and/or matching source authorization absent |
| Final RDS Configuration | Private |
| Final DB Subnet Routing | VPC local route only |
| Final External Rule | Removed |
| EC2 Private Connection | Successful |
| SQL Query | Successful |
| Cleanup | All temporary resources removed (verify after running) |
| Expected Incident Status | Resolved with secure private access |

**Key Takeaway:** Secure cloud networking is not just about opening a port. Public accessibility, subnet routing, DNS, security groups, and verified client origin must align. The right long-term solution for most applications is to preserve private database connectivity and use approved private access paths.
