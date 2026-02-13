NLB_DNS=$(pcluster describe-cluster --cluster-name ${AWS_PC_CLUSTER} | jq -r '.loginNodes[0].address')

# Get the hosted zone ID for your domain
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "pcluster.soleng.posit.it" \
    --query "HostedZones[0].Id" \
    --output text)

# Get the NLB hosted zone ID (needed for alias records)
NLB_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(DNSName, '${NLB_DNS}')].CanonicalHostedZoneId" \
    --output text)

# Create the alias record
aws route53 change-resource-record-sets \
    --hosted-zone-id $HOSTED_ZONE_ID \
    --change-batch '{
        "Changes": [{
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "hpclogin.pcluster.soleng.posit.it",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "'"$NLB_HOSTED_ZONE_ID"'",
                    "DNSName": "'"$NLB_DNS"'",
                    "EvaluateTargetHealth": true
                }
            }
        }]
    }'


#### EFS Backup Configuration (daily, 3-day retention)

# Get the EFS file system ID from the cluster
EFS_ID=$(pcluster describe-cluster --cluster-name ${AWS_PC_CLUSTER} | jq -r '.sharedStorage[] | select(.mountDir=="/opt/rstudio") | .efsSettings.fileSystemId // .storageId' 2>/dev/null)

# Create backup vault (if not exists)
aws backup create-backup-vault \
    --backup-vault-name efs-daily-vault 2>/dev/null || true

# Create backup plan with daily backups, 3-day retention
BACKUP_PLAN_ID=$(aws backup create-backup-plan \
    --backup-plan '{
        "BackupPlanName": "efs-daily-3day-retention",
        "Rules": [{
            "RuleName": "daily-backup",
            "TargetBackupVaultName": "efs-daily-vault",
            "ScheduleExpression": "cron(0 5 ? * * *)",
            "StartWindowMinutes": 60,
            "CompletionWindowMinutes": 180,
            "Lifecycle": {
                "DeleteAfterDays": 3
            }
        }]
    }' \
    --query 'BackupPlanId' \
    --output text 2>/dev/null)

if [ -z "$BACKUP_PLAN_ID" ]; then
    BACKUP_PLAN_ID=$(aws backup list-backup-plans \
        --query "BackupPlansList[?BackupPlanName=='efs-daily-3day-retention'].BackupPlanId" \
        --output text)
fi

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

# Get EFS ARN
EFS_ARN="arn:aws:elasticfilesystem:eu-west-1:${ACCOUNT_ID}:file-system/${EFS_ID}"

# Assign the EFS to the backup plan
aws backup create-backup-selection \
    --backup-plan-id $BACKUP_PLAN_ID \
    --backup-selection '{
        "SelectionName": "efs-selection",
        "IamRoleArn": "arn:aws:iam::'"$ACCOUNT_ID"':role/aws-service-role/backup.amazonaws.com/AWSServiceRoleForBackup",
        "Resources": ["'"$EFS_ARN"'"]
    }'

echo "EFS backup configured: daily at 05:00 UTC, 3-day retention"
