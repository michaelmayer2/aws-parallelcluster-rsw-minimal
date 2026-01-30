#!/bin/bash

# This script keeps the nodes in the ALB TG in sync with the NLB TG for a given cluster. 

# Configuration
CLUSTER_NAME=$1
ALB_TG_NAME=$2

# Get NLB ARN for the cluster
NLB_ARN=$(for i in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[?Type==`network`].LoadBalancerArn' --output text); do
    if aws elbv2 describe-tags --resource-arns "$i" | jq --arg cluster_name "$CLUSTER_NAME" -ce '.TagDescriptions[].Tags[] | select(.Key == "parallelcluster:cluster-name" and .Value==$cluster_name)' > /dev/null 2>&1; then
        echo $i
    fi
done)

# Get NLB target group ARN
NLB_TG_ARN=$(aws elbv2 describe-target-groups --load-balancer-arn $NLB_ARN --query 'TargetGroups[0].TargetGroupArn' --output text)

# Get ALB target group ARN
ALB_TG_ARN=$(aws elbv2 describe-target-groups --names $ALB_TG_NAME --query 'TargetGroups[0].TargetGroupArn' --output text)

# Get current targets in NLB (source of truth)
NLB_TARGETS=$(aws elbv2 describe-target-health --target-group-arn $NLB_TG_ARN --query 'TargetHealthDescriptions[*].Target.Id' --output text | tr '\t' '\n' | sort)

# Get current targets in ALB
ALB_TARGETS=$(aws elbv2 describe-target-health --target-group-arn $ALB_TG_ARN --query 'TargetHealthDescriptions[*].Target.Id' --output text | tr '\t' '\n' | sort)

# Find targets to add (in NLB but not in ALB)
TARGETS_TO_ADD=$(comm -23 <(echo "$NLB_TARGETS") <(echo "$ALB_TARGETS"))

# Find targets to remove (in ALB but not in NLB)
TARGETS_TO_REMOVE=$(comm -13 <(echo "$NLB_TARGETS") <(echo "$ALB_TARGETS"))

# Add new targets
if [ -n "$TARGETS_TO_ADD" ]; then
    echo "Adding targets: $TARGETS_TO_ADD"
    for EC2_ID in $TARGETS_TO_ADD; do
        aws elbv2 register-targets \
            --target-group-arn $ALB_TG_ARN \
            --targets Id=$EC2_ID,Port=8787
    done
fi

# Remove old targets
if [ -n "$TARGETS_TO_REMOVE" ]; then
    echo "Removing targets: $TARGETS_TO_REMOVE"
    for EC2_ID in $TARGETS_TO_REMOVE; do
        aws elbv2 deregister-targets \
            --target-group-arn $ALB_TG_ARN \
            --targets Id=$EC2_ID
    done
fi

echo "Sync complete. NLB targets: $(echo $NLB_TARGETS | wc -w), ALB targets: $(echo $NLB_TARGETS | wc -w)"
