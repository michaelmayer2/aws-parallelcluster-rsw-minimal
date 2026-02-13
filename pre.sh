#!/bin/bash

# source .env file
[ -f .env ] && set -a && source .env && set +a

# For RDS --tags (JSON array)
export POSIT_TAGS_JSON='[{"Key":"rs:project","Value":"solutions"},{"Key":"rs:environment","Value":"development"},{"Key":"rs:owner","Value":"michael.mayer@posit.co"}]'

# For EC2 --tag-specifications (shorthand)
export POSIT_TAGS_EC2="ResourceType=security-group,Tags=[{Key=rs:project,Value=solutions},{Key=rs:environment,Value=development},{Key=rs:owner,Value=michael.mayer@posit.co}]"

export POSIT_TAGS_S3='{"TagSet":[{"Key":"rs:project","Value":"solutions"},{"Key":"rs:environment","Value":"development"},{"Key":"rs:owner","Value":"michael.mayer@posit.co"}]}'

# Extract CIDR Range
export CIDR_RANGE=$(aws ec2 describe-vpcs \
    --vpc-ids $POSIT_VPC \
    --query 'Vpcs[0].CidrBlock' \
    --output text)

# Check if security group already exists
export PWB_LOGIN_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=aws-pc-pwb-login-access" "Name=vpc-id,Values=${POSIT_VPC}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [ "$PWB_LOGIN_SG_ID" == "None" ] || [ -z "$PWB_LOGIN_SG_ID" ]; then
    echo "Creating security group aws-pc-pwb-login-access..."
    export PWB_LOGIN_SG_ID=$(aws ec2 create-security-group \
        --group-name aws-pc-pwb-login-access \
        --description "SG for Workbench access (Launcher and Server)" \
        --tag-specifications "${POSIT_TAGS_EC2}" \
        --vpc-id "${POSIT_VPC}" | jq -r '.GroupId')

    aws ec2 authorize-security-group-ingress \
        --group-id "${PWB_LOGIN_SG_ID}" \
        --protocol tcp \
        --port 8787 \
        --cidr "${CIDR_RANGE}"
    aws ec2 authorize-security-group-ingress \
        --group-id "${PWB_LOGIN_SG_ID}" \
        --protocol tcp \
        --port 5559 \
        --cidr "${CIDR_RANGE}"
else
    echo "Security group aws-pc-pwb-db-access already exists: $PWB_LOGIN_SG_ID"
fi

export PWB_BB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=aws-pc-pwb-db-access" "Name=vpc-id,Values=${POSIT_VPC}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [ "$PWB_DB_SG_ID" == "None" ] || [ -z "$PWB_DB_SG_ID" ]; then
    echo "Creating security group aws-pc-pwb-db-access..."
    PWB_DB_SG_ID=$(aws ec2 create-security-group \
        --group-name aws-pc-pwb-db-access \
        --description "SG for PostgreSQL pwb-db access" \
        --tag-specifications "${POSIT_TAGS_EC2}" \
        --vpc-id "${POSIT_VPC}" | jq -r '.GroupId')

    aws ec2 authorize-security-group-ingress \
        --group-id "${PWB_DB_SG_ID}" \
        --protocol tcp \
        --port 5432 \
        --cidr "${CIDR_RANGE}"
else
    echo "Security group aws-pc-pwb-db-access already exists: $PWB_DB_SG_ID"
fi

# Check if DB subnet group already exists
SUBNET_GROUP_EXISTS=$(aws rds describe-db-subnet-groups \
    --db-subnet-group-name aws-pc-pwb-db-subnet-group \
    --query 'DBSubnetGroups[0].DBSubnetGroupName' \
    --output text 2>/dev/null)

if [ "$SUBNET_GROUP_EXISTS" == "None" ] || [ -z "$SUBNET_GROUP_EXISTS" ]; then
    echo "Creating DB subnet group aws-pc-pwb-db-subnet-group..."
    aws rds create-db-subnet-group \
        --db-subnet-group-name aws-pc-pwb-db-subnet-group \
        --db-subnet-group-description "Subnet group for PWB PostgreSQL" \
        --subnet-ids "$POSIT_SUBNET_ID" "$POSIT_SUBNET_ID2" \
        --tags "${POSIT_TAGS_JSON}"
else
    echo "DB subnet group aws-pc-pwb-db-subnet-group already exists"
fi

# Check if RDS instance already exists
DB_INSTANCE_EXISTS=$(aws rds describe-db-instances \
    --db-instance-identifier aws-pc-pwb-postgres-db \
    --query 'DBInstances[0].DBInstanceIdentifier' \
    --output text 2>/dev/null)

if [ "$DB_INSTANCE_EXISTS" == "None" ] || [ -z "$DB_INSTANCE_EXISTS" ]; then
    echo "Creating RDS instance aws-pc-pwb-postgres-db..."
    aws rds create-db-instance \
    --db-instance-identifier aws-pc-pwb-postgres-db \
    --db-instance-class db.t3.micro \
    --db-name pwb \
    --db-subnet-group-name aws-pc-pwb-db-subnet-group \
    --engine postgres \
    --master-username $PWB_DB_USER \
    --master-user-password $PWB_DB_PASSWORD \
    --allocated-storage 20 \
    --storage-encrypted \
    --vpc-security-group-ids $PWB_DB_SG_ID \
    --tags "${POSIT_TAGS_JSON}"

    aws rds wait db-instance-available --db-instance-identifier aws-pc-pwb-postgres-db
else
    echo "RDS instance pwb-postgres-db already exists"
fi

export PWB_DB_HOST=`aws rds describe-db-instances \
    --db-instance-identifier aws-pc-pwb-postgres-db \
    --query 'DBInstances[0].Endpoint.Address' \
    --output text`

envsubst < etc/rstudio/database.conf.tmpl > etc/rstudio/database.conf
envsubst < etc/rstudio/audit-database.conf.tmpl > etc/rstudio/audit-database.conf

# Tar up the etc/rstudio.files 

cd scripts 
tar cfz etc-rstudio.tgz  etc/rstudio
cd .. 

### S3 bucket

export S3_BUCKET_NAME=aws-pc-scripts-$USER

aws s3 mb s3://aws-pc-scripts-$USER --region eu-west-1
aws s3api put-bucket-tagging \
    --bucket  aws-pc-scripts-$USER \
    --tagging "${POSIT_TAGS_S3}"

echo "Copying install scripts to S3 bucket" 
for ins_script in scripts/etc-rstudio.tgz scripts/install-* scripts/alb-*; do aws s3 cp $ins_script s3://aws-pc-scripts-$USER; done

#### IAM Policy for S3 access 
# Check if IAM policy already exists
S3_IAM_POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='aws-pc-pwb-s3-access-$USER'].Arn" \
    --output text)

if [ -z "$S3_IAM_POLICY_ARN" ]; then
    echo "Creating IAM policy aws-pc-pwb-s3-access-$USER..."
    export S3_IAM_POLICY_ARN=$(aws iam create-policy \
        --policy-name aws-pc-pwb-s3-access-$USER \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": [
                        "s3:GetObject",
                        "s3:PutObject",
                        "s3:DeleteObject",
                        "s3:ListBucket"
                    ],
                    "Resource": [
                        "arn:aws:s3:::aws-pc-scripts-'"$USER"'",
                        "arn:aws:s3:::aws-pc-scripts-'"$USER"'/*"
                    ]
                }
            ]
        }' \
        --tags "${POSIT_TAGS_JSON}"  \
        --query 'Policy.Arn' \
        --output text)
else
    echo "IAM policy aws-pc-pwb-s3-access-$USER already exists: $S3_IAM_POLICY_ARN"
fi


#### IAM Policy for ec2:RunInstances 
# Check if IAM policy already exists
export EC2_RUNINSTANCES_IAM_POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='aws-pc-pwb-ec2-runinstances-$USER'].Arn" \
    --output text)

if [ -z "$EC2_RUNINSTANCES_IAM_POLICY_ARN" ]; then
    echo "Creating IAM policy aws-pc-pwb-ec2-runinstances-$USER..."
    export EC2_RUNINSTANCES_IAM_POLICY_ARN=$(aws iam create-policy \
        --policy-name aws-pc-pwb-ec2-runinstances-$USER \
        --policy-document '{
        "Statement": [
                {
                        "Action": [
                                "ec2:RunInstances"
                        ],
                        "Effect": "Allow",
                        "Resource": "*"
                }
        ],
        "Version": "2012-10-17"
}' \
        --tags "${POSIT_TAGS_JSON}"  \
        --query 'Policy.Arn' \
        --output text)
else
    echo "IAM policy aws-pc-pwb-ec2-runinstances-$USER  already exists: $EC2_RUNINSTANCES_IAM_POLICY_ARN"
fi

#### IAM Policy for ELB tweaks
# Check if IAM policy already exists
export ELB_IAM_POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='aws-pc-pwb-elb-$USER'].Arn" \
    --output text)

if [ -z "$ELB_IAM_POLICY_ARN" ]; then
    echo "Creating IAM policy aws-pc-pwb-elb-$USER..."
    export ELB_IAM_POLICY_ARN=$(aws iam create-policy \
        --policy-name aws-pc-pwb-elb-$USER \
        --policy-document '{
        "Statement": [
                {
                        "Action": [
                                "elasticloadbalancing:DescribeTags",
                                "elasticloadbalancing:DescribeTargetGroups",
                                "elasticloadbalancing:DescribeLoadBalancers",
                                "elasticloadbalancing:DescribeTargetHealth",
                                "elasticloadbalancing:RegisterTargets"
                        ],
                        "Effect": "Allow",
                        "Resource": "*"
                },
                {
                        "Action": [
                                "ec2:DescribeNetworkInterfaces",
                                "ec2:DescribeSubnets"
                        ],
                        "Effect": "Allow",
                        "Resource": "*"
                }
        ],
        "Version": "2012-10-17"
}' \
        --tags "${POSIT_TAGS_JSON}"  \
        --query 'Policy.Arn' \
        --output text)
else
    echo "IAM policy aws-pc-pwb-elb-$USER  already exists: $ELB_IAM_POLICY_ARN"
fi
