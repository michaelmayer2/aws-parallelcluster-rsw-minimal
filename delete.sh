#!/bin/bash

# WARNING: This script will permanently delete all AWS resources created by pre.sh.
# This includes the RDS database, S3 bucket contents, security groups, and IAM policies.
# All data will be lost. Use with extreme caution!

# source .env file
[ -f .env ] && set -a && source .env && set +a

echo "========================================"
echo "  DELETING ALL AWS RESOURCES"
echo "  This action is irreversible!"
echo "========================================"
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi


#### Delete RDS instance
echo "Deleting RDS instance aws-pc-pwb-postgres-db..."
aws rds delete-db-instance \
    --db-instance-identifier aws-pc-pwb-postgres-db \
    --skip-final-snapshot \
    --delete-automated-backups 2>/dev/null

if [ $? -eq 0 ]; then
    echo "Waiting for RDS instance to be deleted..."
    aws rds wait db-instance-deleted --db-instance-identifier aws-pc-pwb-postgres-db
fi


#### Delete DB subnet group (must wait for RDS to be deleted first)
echo "Deleting DB subnet group aws-pc-pwb-db-subnet-group..."
aws rds delete-db-subnet-group \
    --db-subnet-group-name aws-pc-pwb-db-subnet-group 2>/dev/null


#### Delete security groups
echo "Deleting security group aws-pc-pwb-db-access..."
PWB_DB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=aws-pc-pwb-db-access" "Name=vpc-id,Values=${POSIT_VPC}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [ "$PWB_DB_SG_ID" != "None" ] && [ -n "$PWB_DB_SG_ID" ]; then
    aws ec2 delete-security-group --group-id "$PWB_DB_SG_ID"
fi

echo "Deleting security group aws-pc-pwb-login-access..."
PWB_LOGIN_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=aws-pc-pwb-login-access" "Name=vpc-id,Values=${POSIT_VPC}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [ "$PWB_LOGIN_SG_ID" != "None" ] && [ -n "$PWB_LOGIN_SG_ID" ]; then
    aws ec2 delete-security-group --group-id "$PWB_LOGIN_SG_ID"
fi


#### Delete S3 bucket (must empty first)
echo "Deleting S3 bucket aws-pc-scripts-$USER..."
aws s3 rm s3://aws-pc-scripts-$USER --recursive 2>/dev/null
aws s3 rb s3://aws-pc-scripts-$USER 2>/dev/null


#### Delete IAM policies
echo "Deleting IAM policy aws-pc-pwb-s3-access-$USER..."
S3_IAM_POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='aws-pc-pwb-s3-access-$USER'].Arn" \
    --output text)
if [ -n "$S3_IAM_POLICY_ARN" ]; then
    aws iam delete-policy --policy-arn "$S3_IAM_POLICY_ARN"
fi

echo "Deleting IAM policy aws-pc-pwb-ec2-runinstances-$USER..."
EC2_RUNINSTANCES_IAM_POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='aws-pc-pwb-ec2-runinstances-$USER'].Arn" \
    --output text)
if [ -n "$EC2_RUNINSTANCES_IAM_POLICY_ARN" ]; then
    aws iam delete-policy --policy-arn "$EC2_RUNINSTANCES_IAM_POLICY_ARN"
fi

echo "Deleting IAM policy aws-pc-pwb-elb-$USER..."
ELB_IAM_POLICY_ARN=$(aws iam list-policies \
    --query "Policies[?PolicyName=='aws-pc-pwb-elb-$USER'].Arn" \
    --output text)
if [ -n "$ELB_IAM_POLICY_ARN" ]; then
    aws iam delete-policy --policy-arn "$ELB_IAM_POLICY_ARN"
fi


echo "========================================"
echo "  All resources deleted successfully"
echo "========================================"
