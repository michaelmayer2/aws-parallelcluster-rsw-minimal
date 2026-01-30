# Create pcluster image

export ROCKY9_AMI=$(aws ec2 describe-images \
    --owners 792107900819 \
    --filters "Name=name,Values=Rocky-9*" "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-5:].[ImageId,Name,CreationDate]' \
    --output table | grep Base | tail -1 | awk '{print $2}' | cut -d "|" -f 1)

echo "Converting marketplace AMI $ROCKY9_AMI into parallelcluster" 
source scripts/rocky9-ami-ssm.sh

echo "Create AWS ParalleCluster AMI" 

echo "Convert image_config.yaml" 
envsubst < ./yaml/image_config.yaml > image_config-final.yaml

echo "Launch actual pcluster image build"
pcluster build-image -i $AWS_PC_IMAGE -c image_config-final.yaml

echo "Waiting for image build to complete..."
ctr=1
while true; do
    STATUS=$(pcluster describe-image --image-id $AWS_PC_IMAGE --query 'imageBuildStatus' --output text 2>/dev/null)
    if [ "$STATUS" == "BUILD_COMPLETE" ]; then
        echo "Image build completed successfully!"
        break
    elif [ "$STATUS" == "BUILD_FAILED" ]; then
        echo "Image build failed!"
        exit 1
    else
        echo "Image status: $STATUS - waiting $ctr minutes..."
        ctr=$(( $ctr + 1 ))
        sleep 60
    fi
done

export AWS_PC_AMI=$(pcluster list-images --image-status AVAILABLE | \
    jq -r '.images[] | select(.imageId == "'$AWS_PC_IMAGE'") | .ec2AmiInfo.amiId') 


