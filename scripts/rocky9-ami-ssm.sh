INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $ROCKY9_AMI \
    --instance-type t3.medium \
    --subnet-id $POSIT_SUBNET_ID \
    --security-group-ids $PWB_LOGIN_SG_ID \
    --iam-instance-profile Name=AmazonSSMRoleForInstancesQuickSetup \
    --user-data '#!/bin/bash
# Install SSM agent for Rocky/RHEL
dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=rocky9-prep},{Key=rs:project,Value=solutions},{Key=rs:environment,Value=development},{Key=rs:owner,Value=michael.mayer@posit.co}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance ID: $INSTANCE_ID"
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

echo "Waiting for instance status checks..."
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID

echo "Creating AMI..."
AMI_ID=$(aws ec2 create-image \
    --instance-id $INSTANCE_ID \
    --name "rocky9-pcluster-base-$(date +%Y%m%d)" \
    --description "Rocky 9 with SSM agent for ParallelCluster" \
    --query 'ImageId' \
    --output text)

echo "AMI ID: $AMI_ID"
echo "Waiting for AMI to be available..."
aws ec2 wait image-available --image-ids $AMI_ID

echo "Terminating instance $INSTANCE_ID..."
aws ec2 terminate-instances --instance-ids $INSTANCE_ID

echo "Done! AMI $AMI_ID is ready and can be used as an entry point for"
echo "AWS ParallelCluster AMI generation."