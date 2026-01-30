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
