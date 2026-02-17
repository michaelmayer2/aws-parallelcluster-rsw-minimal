#!/bin/bash

# Redirect all output to log file
exec >> /var/log/head-node.log 2>&1

set -x 

# Posit Workbench Version 
PWB_VERSION=${1//+/-}

S3_BUCKET_NAME=$2

SUBNET_ID=$3
SUBNET_ID2=$4

# Install things needed for Singularity/Apptainer integration

# create temporary directory for installs 
tempdir=$(mktemp -d)

# Install Apptainer
# (strictly only needed because we are building containers here)
APPTAINER_VERSION="1.4.5"
yum install -y epel-release 
download_url="https://github.com/apptainer/apptainer/releases/download/v$APPTAINER_VERSION/apptainer"
yum install -y $download_url-$APPTAINER_VERSION-1.x86_64.rpm $download_url-suid-$APPTAINER_VERSION-1.x86_64.rpm

# Clone singularity-rstudio repo 
pushd $tempdir
yum install -y git 
git clone https://github.com/sol-eng/singularity-rstudio.git 
popd 

# SPANK plugin for Singularity/apptainer

pushd $tempdir/singularity-rstudio/slurm-singularity-exec/ && \
    yum install cmake libstdc++-static -y 
    cmake -S . -B build -D CMAKE_INSTALL_PREFIX=/opt/slurm -DINSTALL_PLUGSTACK_CONF=ON && \
    cmake --build build --target install

    cat << EOF > /opt/slurm/etc/plugstack.conf
    include /opt/slurm/etc/plugstack.conf.d/*.conf
EOF
popd 


# Save cleanup function and variables to a shutdown script
save_cleanup_script() {
    cat << CLEANUP_EOF > /opt/rstudio/scripts/cleanup.sh
#!/bin/bash
exec >> /var/log/head-node-cleanup.log 2>&1
echo "Running cleanup at \$(date)..."

HOSTED_ZONE_ID="$HOSTED_ZONE_ID"
ALB_DNS="$ALB_DNS"
ALB_HOSTED_ZONE_ID="$ALB_HOSTED_ZONE_ID"
NLB_DNS="$NLB_DNS"
NLB_HOSTED_ZONE_ID="$NLB_HOSTED_ZONE_ID"
LISTENER_ARN="$LISTENER_ARN"
ALB_ARN="$ALB_ARN"
TG_ARN="$TG_ARN"
ALB_SG_ID="$ALB_SG_ID"

# Remove Route53 records
if [ -n "\$ALB_DNS" ] && [ -n "\$ALB_HOSTED_ZONE_ID" ]; then
    aws route53 change-resource-record-sets \
        --hosted-zone-id \$HOSTED_ZONE_ID \
        --change-batch '{
            "Changes": [{
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": "workbench.pcluster.soleng.posit.it",
                    "Type": "A",
                    "AliasTarget": {
                        "HostedZoneId": "'"\$ALB_HOSTED_ZONE_ID"'",
                        "DNSName": "'"\$ALB_DNS"'",
                        "EvaluateTargetHealth": true
                    }
                }
            }]
        }' 2>/dev/null
fi

if [ -n "\$NLB_DNS" ] && [ -n "\$NLB_HOSTED_ZONE_ID" ]; then
    aws route53 change-resource-record-sets \
        --hosted-zone-id \$HOSTED_ZONE_ID \
        --change-batch '{
            "Changes": [{
                "Action": "DELETE",
                "ResourceRecordSet": {
                    "Name": "hpclogin.pcluster.soleng.posit.it",
                    "Type": "A",
                    "AliasTarget": {
                        "HostedZoneId": "'"\$NLB_HOSTED_ZONE_ID"'",
                        "DNSName": "'"\$NLB_DNS"'",
                        "EvaluateTargetHealth": true
                    }
                }
            }]
        }' 2>/dev/null
fi

# Delete HTTPS listener
[ -n "\$LISTENER_ARN" ] && aws elbv2 delete-listener --listener-arn \$LISTENER_ARN 2>/dev/null

# Delete ALB
if [ -n "\$ALB_ARN" ]; then
    aws elbv2 delete-load-balancer --load-balancer-arn \$ALB_ARN 2>/dev/null
    aws elbv2 wait load-balancers-deleted --load-balancer-arns \$ALB_ARN 2>/dev/null
fi

# Delete target group
[ -n "\$TG_ARN" ] && aws elbv2 delete-target-group --target-group-arn \$TG_ARN 2>/dev/null

# Delete ALB security group
[ -n "\$ALB_SG_ID" ] && [ "\$ALB_SG_ID" != "None" ] && aws ec2 delete-security-group --group-id \$ALB_SG_ID 2>/dev/null

# Disable systemd timer
systemctl disable --now sync-alb-targets.timer 2>/dev/null

echo "Cleanup complete at \$(date)"
CLEANUP_EOF
    chmod +x /opt/rstudio/scripts/cleanup.sh
}

# Deploy config files

mkdir -p /opt/rstudio/scripts

aws s3 cp s3://$S3_BUCKET_NAME/alb-cron.sh /opt/rstudio/scripts 
chmod +x  /opt/rstudio/scripts/alb-cron.sh

# create systemd timer for cron job
cat << EOF > /etc/systemd/system/sync-alb-targets.service
# /etc/systemd/system/sync-alb-targets.service
[Unit]
Description=Sync ALB targets with NLB

[Service]
Type=oneshot
ExecStart=/opt/rstudio/scripts/alb-cron.sh $CLUSTER_NAME pwb-login-nodes-tg
EOF

cat << EOF > /etc/systemd/system/sync-alb-targets.timer
# /etc/systemd/system/sync-alb-targets.timer
[Unit]
Description=Run ALB sync every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload 
systemctl enable --now sync-alb-targets.timer

# Deal with Posit Workbench config files
# We deploy them in /opt/rstudio/etc/rstudio here and then have the login nodes simply copy them from here 

POSIT_CONFIG_DIR=/opt/rstudio/etc/rstudio

mkdir -p $POSIT_CONFIG_DIR

echo "Creating secure-cookie-key"
echo `uuidgen` > $POSIT_CONFIG_DIR/secure-cookie-key
chmod 0600 $POSIT_CONFIG_DIR/secure-cookie-key

echo "Create launcher keys"
openssl genpkey -algorithm RSA -out $POSIT_CONFIG_DIR/launcher.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -in $POSIT_CONFIG_DIR/launcher.pem -pubout > $POSIT_CONFIG_DIR/launcher.pub
chmod 0600 $POSIT_CONFIG_DIR/launcher.pem

echo "Create audited jobs keys"
openssl genpkey -algorithm RSA -out $POSIT_CONFIG_DIR/audited-jobs-private-key.pem
openssl rsa -pubout -in $POSIT_CONFIG_DIR/audited-jobs-private-key.pem -out $POSIT_CONFIG_DIR/audited-jobs-public-key.pem
chmod 0600 $POSIT_CONFIG_DIR/audited-jobs-private-key.pem

aws s3 cp s3://$S3_BUCKET_NAME/etc-rstudio.tgz /tmp 

tar xfz /tmp/etc-rstudio.tgz -C /opt/rstudio 

chmod 0600 $POSIT_CONFIG_DIR/database.conf
chmod 0600 $POSIT_CONFIG_DIR/audit-database.conf

# Create PWB Audit DB
yum install -y postgresql

source $POSIT_CONFIG_DIR/database.conf

PGPASSWORD=$password psql -h $host -U $username pwb -c "CREATE DATABASE pwbaudit;" 

touch /opt/rstudio/.db

# Create a DNS alias to point hpclogin.pcluster.soleng.posit.it to the NLB created by AWS PC
## Figure out cluster name

yum install -y yq 

CLUSTER_NAME=`cat  /opt/parallelcluster/shared/cluster-config.yaml | yq eval '.Tags[] | select(.Key == "parallelcluster:cluster-name") | .Value'`
LOGIN_NODES_NUMBER=`cat /opt/parallelcluster/shared/cluster-config.yaml | yq .LoginNodes.Pools[].Count`

## get NLB ARN
ELB=""
while true
do
        ELB=`for i in $(aws elbv2 describe-load-balancers | jq -r '.LoadBalancers[].LoadBalancerArn'); \
            do if ( aws elbv2 describe-tags --resource-arns "\$i" | jq --arg cluster_name "$CLUSTER_NAME" -ce '.TagDescriptions[].Tags[] \
            | select( .Key == "parallelcluster:cluster-name" and .Value==$cluster_name)' > /dev/null); then echo $i; fi; done `
        if [ ! -z $ELB ]; then break; fi
        sleep 2
done

# NLB URL 
NLB_DNS=`aws elbv2 describe-load-balancers --load-balancer-arns=$ELB | jq -r '.[] | .[] | .DNSName'`

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

# Get Target Group of NLB ARN
TARGET_ARN=`aws elbv2 describe-target-groups --load-balancer-arn=$ELB --query TargetGroups[].TargetGroupArn | jq -r '.[]'`

# EC2 IDs attached to Target Group - loop until all of them are available and healthy
EC2_IDS=""
while true
do
        EC2_IDS=`aws elbv2 describe-target-health --target-group-arn $TARGET_ARN --query 'TargetHealthDescriptions[*].Target.Id' | jq -r '.[]'`
        nr_ids=`set -- $EC2_IDS && echo $#`
        if [ $nr_ids == $LOGIN_NODES_NUMBER ]; then break; fi
        sleep 2
done

# Get the ACM certificate ARN for your domain
ACM_CERT_ARN=$(aws acm list-certificates \
    --query "CertificateSummaryList[?contains(DomainName, 'pcluster.soleng.posit.it')].CertificateArn" \
    --output text)

# Get subnets for the ALB (needs at least 2 AZs)
ALB_SUBNETS="$SUBNET_ID $SUBNET_ID2"

# VPC ID
VPC_ID=$(aws ec2 describe-subnets \
    --subnet-ids $SUBNET_ID \
    --query 'Subnets[0].VpcId' \
    --output text)

# Create security group for ALB
ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=pwb-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [ "$ALB_SG_ID" == "None" ] || [ -z "$ALB_SG_ID" ]; then
    echo "Creating ALB security group..."
    ALB_SG_ID=$(aws ec2 create-security-group \
        --group-name pwb-alb-sg \
        --description "SG for PWB ALB" \
        --vpc-id "${VPC_ID}" \
        --query 'GroupId' \
        --output text)

    # Get CIDR Range 
    CIDR_RANGE=$(aws ec2 describe-vpcs \
        --vpc-ids $VPC_ID \
        --query 'Vpcs[0].CidrBlock' \
        --output text)

    aws ec2 authorize-security-group-ingress \
        --group-id "${ALB_SG_ID}" \
        --protocol tcp \
        --port 443 \
        --cidr "${CIDR_RANGE}"
fi

# Create target group with 302 as healthy response
TG_ARN=$(aws elbv2 create-target-group \
    --name pwb-login-nodes-tg \
    --protocol HTTP \
    --port 8787 \
    --vpc-id "${VPC_ID}" \
    --health-check-protocol HTTP \
    --health-check-port 8787 \
    --health-check-path "/" \
    --matcher "HttpCode=302" \
    --target-type instance \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text  | tr -d '\n\r')

# Register EC2 instances to target group
for EC2_ID in $EC2_IDS; do
    aws elbv2 register-targets \
        --target-group-arn $TG_ARN \
        --targets Id=$EC2_ID,Port=8787
done

# Create ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name pwb-alb \
    --type application \
    --scheme internal \
    --subnets $ALB_SUBNETS \
    --security-groups $ALB_SG_ID \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)

# Wait for ALB to be active
aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN

# Modify ALB attributes for increased security
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $ALB_ARN \
  --attributes Key=routing.http.drop_invalid_header_fields.enabled,Value=true

# Get ALB DNS name and hosted zone ID
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

ALB_HOSTED_ZONE_ID=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].CanonicalHostedZoneId' \
    --output text)

# Create HTTPS listener
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTPS \
    --port 443 \
    --certificates CertificateArn=$ACM_CERT_ARN \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --query 'Listeners[0].ListenerArn' \
    --output text)

aws elbv2 modify-listener \
  --listener-arn $LISTENER_ARN \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09

# Create Route53 alias for workbench.pcluster.soleng.posit.it
aws route53 change-resource-record-sets \
    --hosted-zone-id $HOSTED_ZONE_ID \
    --change-batch '{
        "Changes": [{
            "Action": "UPSERT",
            "ResourceRecordSet": {
                "Name": "workbench.pcluster.soleng.posit.it",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "'"$ALB_HOSTED_ZONE_ID"'",
                    "DNSName": "'"$ALB_DNS"'",
                    "EvaluateTargetHealth": true
                }
            }
        }]
    }'

echo "ALB created: $ALB_DNS"
echo "Workbench available at: https://workbench.pcluster.soleng.posit.it"

# Save cleanup script with all variable values baked in
save_cleanup_script

# Create systemd service to run cleanup on shutdown
cat << EOF > /etc/systemd/system/head-node-cleanup.service
[Unit]
Description=Clean up AWS resources on head node shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/opt/rstudio/scripts/cleanup.sh
TimeoutStartSec=120

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

systemctl daemon-reload
systemctl enable head-node-cleanup.service

# Install a couple of singularity/apptainer containers

mkdir -p /opt/rstudio/container

mkdir -p /opt/rstudio/container
pushd $tempdir/singularity-rstudio/data/r-session-complete
    export SLURM_VERSION=`/opt/slurm/bin/sinfo -V | cut -d " " -f 2`
    yum install -y gettext
    envsubst < build.env > build.env.final
    for os in noble; do
        cd $os
        singularity build --build-arg-file ../build.env.final /opt/rstudio/container/$os.sif r-session-complete.sdef &
        cd ..
    done
    wait
popd

# cleanup tempdir
rm -rf $tempdir