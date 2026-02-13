#!/bin/bash

# Posit Workbench Version 
PWB_VERSION=${1//+/-}

S3_BUCKET_NAME=$2

SUBNET_ID=$3
SUBNET_ID2=$4

# Install things needed for Singularity/Apptainer integration

# create temporary directory for installs 
tempdir=$(mktemp -d)

# make RHEL Image compatible with RockyLinux 
# pushd $tempdir 
#     rpm -e --nodeps redhat-release 
#     rm -rf /usr/share/redhat-release
#     yum install -y curl 
#     rocky_dir="https://dl.rockylinux.org/vault/rocky/9.6/BaseOS/x86_64/os/Packages/r/"
#     for i in rocky-release-9.6-1.3.el9.noarch.rpm \
#         rocky-repos-9.6-1.3.el9.noarch.rpm \
#         rocky-gpg-keys-9.6-1.3.el9.noarch.rpm; do \
#         curl -LO $rocky_dir/$i; \
#     done 
#     rpm -Uhv rocky-* --force 
#     rm -rf rocky* 
#     rpm -e libdnf-plugin-subscription-manager python3-subscription-manager-rhsm subscription-manager rhc insights-client redhat-cloud-client-configuration
# popd

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

# Install a couple of singularity/apptainer containers

mkdir -p /opt/rstudio/container
pushd $tempdir/singularity-rstudio/data/r-session-complete
    export SLURM_VERSION=`/opt/slurm/bin/sinfo -V | cut -d " " -f 2`
    yum install -y gettext
    envsubst < build.env > build.env.final
    for os in noble; do
        pushd $os
        singularity build --build-arg-file ../build.env.final /opt/rstudio/container/$os.sif r-session-complete.sdef & 
        popd
    done
    wait 

popd

# cleanup tempdir
rm -rf $tempdir



# Redirect all output to log file
exec > >(tee -a /var/log/head-node.log) 2>&1

set -x 

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

echo `uuidgen` > $POSIT_CONFIG_DIR/secure-cookie-key
chmod 0600 $POSIT_CONFIG_DIR/secure-cookie-key
openssl genpkey -algorithm RSA -out $POSIT_CONFIG_DIR/launcher.pem -pkeyopt rsa_keygen_bits:2048
openssl rsa -in $POSIT_CONFIG_DIR/launcher.pem -pubout > $POSIT_CONFIG_DIR/launcher.pub
chmod 0600 $POSIT_CONFIG_DIR/launcher.pem

aws s3 cp s3://$S3_BUCKET_NAME/etc-rstudio.tgz /tmp 

tar xfz /tmp/etc-rstudio.tgz -C /opt/rstudio 

chmod 0600 $POSIT_CONFIG_DIR/database.conf
chmod 0600 $POSIT_CONFIG_DIR/audit-database.conf


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

# Create security group for ALB
ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=pwb-alb-sg" "Name=vpc-id,Values=${POSIT_VPC}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

if [ "$ALB_SG_ID" == "None" ] || [ -z "$ALB_SG_ID" ]; then
    echo "Creating ALB security group..."
    ALB_SG_ID=$(aws ec2 create-security-group \
        --group-name pwb-alb-sg \
        --description "SG for PWB ALB" \
        --vpc-id "${POSIT_VPC}" \
        --query 'GroupId' \
        --output text)

    # Get the VPC ID 
    SUBNET_ID=$(cat /opt/parallelcluster/shared/cluster-config.yaml | yq '.HeadNode.Networking.SubnetId')
    POSIT_VPC=$(aws ec2 describe-subnets \
    --subnet-ids $SUBNET_ID \
    --query 'Subnets[0].VpcId' \
    --output text)

    # Get CIDR Range 
    CIDR_RANGE=$(aws ec2 describe-vpcs \
        --vpc-ids $POSIT_VPC \
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
    --vpc-id "${POSIT_VPC}" \
    --health-check-protocol HTTP \
    --health-check-port 8787 \
    --health-check-path "/" \
    --matcher "HttpCode=302" \
    --target-type instance \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

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




