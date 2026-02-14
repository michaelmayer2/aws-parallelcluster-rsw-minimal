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


# ...existing code...
#### IAM Policies
for POLICY_NAME in "aws-pc-pwb-s3-access-$USER" "aws-pc-pwb-ec2-runinstances-$USER" "aws-pc-pwb-elb-$USER"; do
    POLICY_ARN=$(aws iam list-policies \
        --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" \
        --output text 2>/dev/null)
    
    if [ -n "$POLICY_ARN" ] && [ "$POLICY_ARN" != "None" ]; then
        echo "Deleting IAM policy ${POLICY_NAME}..."
        
        # Delete all non-default policy versions first
        for VERSION_ID in $(aws iam list-policy-versions \
            --policy-arn $POLICY_ARN \
            --query "Versions[?IsDefaultVersion==\`false\`].VersionId" \
            --output text 2>/dev/null); do
            aws iam delete-policy-version \
                --policy-arn $POLICY_ARN \
                --version-id $VERSION_ID 2>/dev/null
        done
        
        # Detach policy from all roles
        for ROLE_NAME in $(aws iam list-entities-for-policy \
            --policy-arn $POLICY_ARN \
            --query "PolicyRoles[*].RoleName" \
            --output text 2>/dev/null); do
            aws iam detach-role-policy \
                --role-name $ROLE_NAME \
                --policy-arn $POLICY_ARN 2>/dev/null
        done

        aws iam delete-policy --policy-arn $POLICY_ARN 2>/dev/null
    fi
done

echo "========================================"
echo "  All resources deleted successfully"
echo "========================================"
