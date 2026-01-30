from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2, EC2Instances
from diagrams.aws.database import RDS
from diagrams.aws.storage import S3, EFS, FSx
from diagrams.aws.network import ALB, NLB, Route53
from diagrams.aws.security import IAM, ACM
from diagrams.aws.general import Users

graph_attr = {
    "fontsize": "14",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "ortho",
}

with Diagram(
    "AWS ParallelCluster with Posit Workbench",
    show=False,
    filename="aws-architecture",
    direction="TB",
    graph_attr=graph_attr,
):

    user = Users("Users")

    with Cluster("Route 53"):
        dns_wb = Route53("workbench.pcluster\n.soleng.posit.it")
        dns_ssh = Route53("hpclogin.pcluster\n.soleng.posit.it")

    with Cluster("AWS Services"):
        s3 = S3("aws-pc-scripts-*")
        acm = ACM("SSL Certificate")
        iam = IAM("IAM Policies")

    with Cluster("Load Balancers"):
        alb = ALB("ALB (internal)\nSSL Termination\nPort 443")
        nlb = NLB("NLB\nTCP Passthrough")

    with Cluster("VPC (10.13.0.0/16)"):

        with Cluster("AWS ParallelCluster"):

            with Cluster("Head Node (t3.xlarge)"):
                head = EC2("Slurm Controller\nALB Sync Cron")

            with Cluster("Login Nodes (x2, t3.xlarge)"):
                login1 = EC2("Login Node 1\nSSH :22\nrstudio-server :8787\nrstudio-launcher :5559")
                login2 = EC2("Login Node 2\nSSH :22\nrstudio-server :8787\nrstudio-launcher :5559")

            with Cluster("Slurm Queues"):
                q_interactive = EC2Instances("interactive\nt3.xlarge\nmin:1 max:5")
                q_all = EC2Instances("all\nt3.xlarge\nmin:0 max:10")
                q_gpu = EC2Instances("gpu\ng4dn.xlarge\nmin:0 max:1")

        with Cluster("Shared Storage"):
            fsx = FSx("FSx Lustre (1.2TB)\n/home")
            efs = EFS("EFS\n/opt/rstudio")

        with Cluster("Data Services"):
            rds = RDS("PostgreSQL\ndb.t3.micro\nPort 5432")

    # User connections
    user >> dns_wb
    user >> dns_ssh

    # DNS to Load Balancers
    dns_wb >> alb
    dns_ssh >> nlb

    # SSL Certificate
    acm >> Edge(style="dashed") >> alb

    # Load Balancers to Login Nodes
    alb >> Edge(label="HTTP:8787") >> login1
    alb >> Edge(label="HTTP:8787") >> login2
    nlb >> Edge(label="SSH:22") >> login1
    nlb >> Edge(label="SSH:22") >> login2

    # Login Nodes to Head Node (Slurm)
    login1 >> Edge(label="Slurm Jobs") >> head
    login2 >> Edge(label="Slurm Jobs") >> head

    # Head Node to Queues
    head >> q_interactive
    head >> q_all
    head >> q_gpu

    # Storage connections
    head >> fsx
    head >> efs
    login1 >> fsx
    login1 >> efs
    login2 >> fsx
    login2 >> efs

    # Database connections
    login1 >> Edge(label="Session State") >> rds
    login2 >> rds

    # S3 and IAM to Head Node
    s3 >> Edge(style="dashed", label="Bootstrap") >> head
    iam >> Edge(style="dashed", label="Permissions") >> head
