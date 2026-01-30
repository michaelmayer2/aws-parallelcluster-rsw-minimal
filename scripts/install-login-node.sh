#!/bin/bash

PWB_VERSION=${1//+/-}

# We need tp install a version of R in order to avoid errors in Workbench
#  this R version is not going to be used anywhere else 

R_VERSION=4.5.2
dnf install -y https://cdn.posit.co/r/rhel-9/pkgs/R-${R_VERSION}-1-1.$(arch).rpm

# Let's fake jupyter as well to avoid additional trouble 

echo -e "#/bin/bash\n\n#Dummy script for jupyter\necho 4.5.3\n\nexit 0" > /usr/local/bin/jupyter 
chmod +x /usr/local/bin/jupyter

# Finally install workbench
dnf install -y https://s3.amazonaws.com/rstudio-ide-build/server/rhel9/x86_64/rstudio-workbench-rhel-$PWB_VERSION-x86_64.rpm

# After installing workbench, let's copy all the config files in place
mkdir -p /etc/rstudio

# Wait for /opt/rstudio/etc/rstudio/ to be available (mounted via EFS)
echo "Waiting for /opt/rstudio/etc/rstudio/ to be available..."
while [ ! -d /opt/rstudio/etc/rstudio/ ]; do
    sleep 5
done
echo "/opt/rstudio/etc/rstudio/ is now available... deploying config files..."

cp -dpRf /opt/rstudio/etc/rstudio/* /etc/rstudio 

rstudio-server stop
rstudio-launcher stop
rstudio-launcher start
rstudio-server start 
