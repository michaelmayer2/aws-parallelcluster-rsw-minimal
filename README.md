echo "prepare cluster build" 

# aws-parallelcluster-rsw-minimal

## Introduction 

This is a repository that aims at highlighting a slightly more simple integration of Posit Workbench into an AWS ParallelCluster environment. 

![AWS Architecture Diagram](img/aws-architecture.png)

The above image shows the Architecture used. More detailed information can be found in [the architecture document](architecture.md)

## Deployment steps 

### Defining environment variables 

Create a .env file in the repository folder that contains

```
CLUSTER_NAME=""
POSIT_VPC=""
POSIT_SUBNET_ID=""
POSIT_SUBNET_ID2=""
PWB_VERSION="2026.01.0+392.pro5"
AWS_PC_AMI=""
PWB_DB_USER=""
PWB_DB_PASSWORD=""
```

where

* `CLUSTER_NAME` is the name of the AWS ParallelCluster deploment
* `POSIT_VPC`, `POSIT_SUBNET` and `POSIT_SUBNET2` are the id's of a VPC and two subnets that exist in the VPC. The subnets will be used to set up the load balancers 
* `PWB_VERSION` is the desired version of Posit Workbench you would like to use
* `PWB_DB_USER` and `PWB_UB_PASSWORD` are the desired username and passqord for the PostgreSQL database (will be created as part of the setup)
* `AWS_PC_AMI` is the ID of the AWS ParallelCluster AMI you would like to use

### Starting the pre-installation steps 

You now can run 

```
source pre.sh
```

which will create all auxiliary services (e.g. PostgreSQL DB for Workbench, S3 bucket to bootstrap scripts from ParallelCluster), security groupd and IAM policies needed. 

### Dealing with the AMI 

The setup is assuming that we want to use Rocky Linux 9. Unfortunately AWS ParallelCluster does not provide any AMIs for Rocky Linux 9. So we have to build them ourselves. Upon building such an AMI it becomes apparent that the Marketplace AMIs for Rocky Linux do not have AWS SSM enabled. In order for AWS ParallelCluster to successfully create an AMI, we first need to create a temporary AMI that contains SSM. For this purpose we provide the script [scripts/rocky9-ami-ssm.sh](scripts/rocky9-ami-ssm.sh). 

For the script to run, you will need to set the environment variable `ROCKY9_AMI` to the desired Marketplace AMI ID. Unless you already ran `pre.sh` at this point, you also need to set `POSIT_SUBNET_ID` to a subnet where you can build AMIs and possibly replace `PWB_LOGIN_SG_ID` with a security group of your choice

In order to make things easy, an end-to-end script [image.sh](image.sh) is provided. This script will not only add SSM to the marketplace AMI, it will also transform the SSM'ed AMI into a parallelcluster compatible image and label it according to the value of `AWS_PC_IMAGE`. 

### starting the cluster build

Finally, we now can run 

```
envsubst < yaml/cluster-config.yaml > cluster-config-final.yaml
```

to create a parallelcluster cluster config file using the environment variables set by `pre.sh` and then run 

```
pcluster create-cluster -n $CLUSTER_NAME -c cluster-config-final.yaml  --rollback-on-failure false
``` 

### Post installation steps

Once the parallecluster env has been built successfully, you can run [post.sh](post.sh) in order to create a DNS alias `hpclogin.pcluster.soleng.posit.it` that will forward to the NLB of AWS Parallelcluster. This URL is available for SSH access. Given the fact this is an NLB, an ssh connection to this URL will be automatically distributed on one of the login nodes. 

In addition, an EFS backup policy will be created and activated for the EFS file systems used by AWS ParallelCluster in order to satisfy some local security regulations.

# Clean-up

After you tear down the cluster, you can use `delete.sh` to remove the auxiliary infrastructure such as IAM roles, security groups etc... 

Note that when you tear down the cluster, the AWS resources created by the `install-head-node.sh` script will be automatically removed. 