#!/bin/bash

# Install Apptainer
APPTAINER_VERSION="1.4.5"
yum install -y epel-release 
download_url="https://github.com/apptainer/apptainer/releases/download/v$APPTAINER_VERSION/apptainer"
yum install -y $download_url-$APPTAINER_VERSION-1.x86_64.rpm $download_url-suid-$APPTAINER_VERSION-1.x86_64.rpm