#!/bin/bash
#
#
# Parameters
# DOCKEREE_DOWNLOAD_URL : Base location of the Docker EE packages
# UCP_PUBLIC_FQDN : UCP Public URL
# UCP_ADMIN_USERID : The UCP Admin user ID (also the ID of the Linux Administrator)
# UCP_ADMIN_PASSWORD : Password of the UCP administrator
# DTR_PUBLIC_FQDN : DTR Public URL

echo $(date) " linux-install-dockereeucp - Starting Script"


AZURE_STORAGE_ACCOUNT_NAME=$1
AZURE_STORAGE_ACCOUNT_KEY=$2
UCP_PUBLIC_FQDN=$3
DOCKER_SUBSCRIPTION="$4"
CLUSTER_SAN=$5
DTR_PUBLIC_FQDN=$6
UCP_ADMIN_USERID=$7
UCP_ADMIN_PASSWORD=$8
DOCKEREE_DOWNLOAD_URL=$9
AZURE_CLIENT_ID=${10}
AZURE_TENANT_ID=${11}
AZURE_SUBSCRIPTION_ID=${12}
AZURE_CLIENT_SECRET="${13}"
LOCATION=${14}
RGNAME=${15}

eval HOST_IP_ADDRESS=$(ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')

echo "HOST_IP_ADDRESS=$HOST_IP_ADDRESS"

install_docker()
{

# UBUNTU

sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL ${DOCKEREE_DOWNLOAD_URL}/ubuntu/gpg | sudo apt-key add -
sudo apt-key fingerprint 6D085F96
sudo add-apt-repository "deb [arch=amd64] ${DOCKEREE_DOWNLOAD_URL}/ubuntu $(lsb_release -cs) stable-18.09"
sudo apt-get update -y
sudo apt-get install -y docker-ee=5:18.09.0~3-0~ubuntu-xenial


# Post Installation configuration (all Linux distros)

groupadd docker
usermod -aG docker $USER
usermod -aG docker $UCP_ADMIN_USERID

systemctl enable docker
systemctl start docker
}

install_docker;

# Set the Kubernetes version as found in the UCP Dashboard or API
k8sversion=v1.11.2
# Get the kubectl binary.
curl -LO https://storage.googleapis.com/kubernetes-release/release/$k8sversion/bin/linux/amd64/kubectl
# Make the kubectl binary executable.
chmod +x ./kubectl
# Move the kubectl executable to /usr/local/bin.
sudo mv ./kubectl /usr/local/bin/kubectl


docker swarm init

# Create the docker_subscription.lic
touch /home/$UCP_ADMIN_USERID/docker_subscription.lic
echo $DOCKER_SUBSCRIPTION > /home/$UCP_ADMIN_USERID/docker_subscription.lic

chmod 777 /home/$UCP_ADMIN_USERID/docker_subscription.lic

# Install Azure Container Networking

PLUGIN_VERSION=v1.0.13
CNI_VERSION=0.3.1
CNI_BIN_DIR=/opt/cni/bin
CNI_NETCONF_DIR=/etc/cni/net.d

function usage
{
    printf "Installs azure-vnet CNI plugins.\n"
    printf "Usage: install-cni-plugin version [cniVersion]\n"
}

if [ "$PLUGIN_VERSION" = "" ]; then
    usage
    exit 1
fi

if [ "$CNI_VERSION" = "" ]; then
    CNI_VERSION=v0.4.0
fi

# Create CNI directories.
printf "Creating CNI directories.\n"
mkdir -p $CNI_BIN_DIR
mkdir -p $CNI_NETCONF_DIR

# Install ebtables.
if [ ! -e /sbin/ebtables ]
then
    printf "Installing ebtables package..."
    apt-get update
    apt-get install -y ebtables
    printf "done.\n"
else
    echo "Package ebtables is already installed."
fi
/sbin/ebtables --list > /dev/null

# Install azure-vnet CNI plugins.
printf "Installing azure-vnet CNI plugin version $PLUGIN_VERSION to $CNI_BIN_DIR..."
/usr/bin/curl -sSL https://github.com/Azure/azure-container-networking/releases/download/$PLUGIN_VERSION/azure-vnet-cni-linux-amd64-$PLUGIN_VERSION.tgz > $CNI_BIN_DIR/azure-vnet.tgz
tar -xzf $CNI_BIN_DIR/azure-vnet.tgz -C $CNI_BIN_DIR
printf "done.\n"

# Install azure-vnet CNI network configuration file.
printf "Installing azure-vnet CNI network configuration file to $CNI_NETCONF_DIR..."
mv $CNI_BIN_DIR/*.conflist $CNI_NETCONF_DIR
printf "done.\n"

# Install loopback plugin.
printf "Installing loopback CNI plugin version $CNI_VERSION to $CNI_BIN_DIR..."
/usr/bin/curl -sSL https://github.com/containernetworking/cni/releases/download/$CNI_VERSION/cni-amd64-$CNI_VERSION.tgz > $CNI_BIN_DIR/cni.tgz
tar -xzf $CNI_BIN_DIR/cni.tgz -C $CNI_BIN_DIR ./loopback
printf "done.\n"

# Cleanup.
rm $CNI_BIN_DIR/*.tgz
chown root:root $CNI_BIN_DIR/*

printf "azure-vnet CNI plugin is successfully installed.\n"



# Azure - GET PODCIDR & Set up Route Table
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
sudo apt-key --keyring /etc/apt/trusted.gpg.d/Microsoft.gpg adv --keyserver packages.microsoft.com --recv-keys BC528686B50D79E339D3721CEB3E94ADBE1229CF
sudo apt-get update
sudo apt-get install azure-cli

az login --service-principal -u $AZURE_CLIENT_ID -p $AZURE_CLIENT_SECRET --tenant $AZURE_TENANT_ID
az resource tag --tags pod-cidr=10.200.4.0/24 -g $RGNAME -n linuxWorker1 --resource-type "Microsoft.Compute/virtualMachines"
az resource tag --tags pod-cidr=10.200.5.0/24 -g $RGNAME -n linuxWorker2 --resource-type "Microsoft.Compute/virtualMachines"
az resource tag --tags pod-cidr=10.200.6.0/24 -g $RGNAME -n linuxWorker3 --resource-type "Microsoft.Compute/virtualMachines"

PRIVATE_IP_ADDRESS=$(az vm show -d -g $RGNAME -n linuxWorker1 --query "privateIps" -otsv)
POD_CIDR=$(az vm show -g $RGNAME --name linuxWorker1 --query "tags" -o tsv)
echo $PRIVATE_IP_ADDRESS $POD_CIDR

az network route-table create -g $RGNAME -n kubernetes-routes
az network vnet subnet update -g $RGNAME -n docker --vnet-name clusterVirtualNetwork --route-table kubernetes-routes
az network route-table route create -g $RGNAME -n kubernetes-route-10-200-1-0-24 --route-table-name kubernetes-routes --address-prefix 10.200.4.0/24 --next-hop-ip-address $PRIVATE_IP_ADDRESS --next-hop-type VirtualAppliance


# Create the /etc/kubernetes/azure.json
sudo mkdir /etc/kubernetes
touch /home/$UCP_ADMIN_USERID/azure.json
echo { > /home/$UCP_ADMIN_USERID/azure.json
echo "cloud": "AzurePublicCloud", >> /home/$UCP_ADMIN_USERID/azure.json
echo "tenantId": "$AZURE_TENANT_ID", >> /home/$UCP_ADMIN_USERID/azure.json
echo "subscriptionId": "$AZURE_SUBSCRIPTION_ID", >> /home/$UCP_ADMIN_USERID/azure.json
echo "aadClientId": "$AZURE_CLIENT_ID", >> /home/$UCP_ADMIN_USERID/azure.json
echo "aadClientSecret": "$AZURE_CLIENT_SECRET", >> /home/$UCP_ADMIN_USERID/azure.json
echo "resourceGroup": "$RGNAME", >> /home/$UCP_ADMIN_USERID/azure.json
echo "location": "$LOCATION", >> /home/$UCP_ADMIN_USERID/azure.json
echo "subnetName": "docker", >> /home/$UCP_ADMIN_USERID/azure.json
echo "securityGroupName": "ucpManager-nsg", >> /home/$UCP_ADMIN_USERID/azure.json
echo "vnetName": "clusterVirtualNetwork", >> /home/$UCP_ADMIN_USERID/azure.json
echo "routeTableName": "kubernetes-route-10-200-1-0-24", >> /home/$UCP_ADMIN_USERID/azure.json
echo "primaryAvailabilitySetName": "ucpAvailabilitySet", >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderBackoff": false >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderBackoffRetries": 0, >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderBackoffExponent": 0, >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderBackoffDuration": 0, >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderBackoffJitter": 0, >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderRatelimit": false, >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderRateLimitQPS": 0, >> /home/$UCP_ADMIN_USERID/azure.json
echo "cloudProviderRateLimitBucket": 0, >> /home/$UCP_ADMIN_USERID/azure.json
echo "useManagedIdentityExtension": false, >> /home/$UCP_ADMIN_USERID/azure.json
echo "useInstanceMetadata": false >> /home/$UCP_ADMIN_USERID/azure.json
echo } >> /home/$UCP_ADMIN_USERID/azure.json

sudo mv /home/$UCP_ADMIN_USERID/azure.json /etc/kubernetes/

#Firewalling
sudo ufw allow 179/tcp
sudo ufw allow 443/tcp
sudo ufw allow 2376/tcp
sudo ufw allow 2377/tcp
sudo ufw allow 4789/udp
sudo ufw allow 6443/tcp
sudo ufw allow 6444/tcp
sudo ufw allow 7946/udp
sudo ufw allow 7946/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 12376/tcp
sudo ufw allow 12378/tcp
sudo ufw allow 12379/tcp
sudo ufw allow 12380/tcp
sudo ufw allow 12381/tcp
sudo ufw allow 12382/tcp
sudo ufw allow 12383/tcp
sudo ufw allow 12384/tcp
sudo ufw allow 12385/tcp
sudo ufw allow 12386/tcp
sudo ufw allow 12387/tcp
sudo ufw allow 12388/tcp



# Split the UCP FQDN et get the SAN and the port

UCP_SAN=${UCP_PUBLIC_FQDN%%:*}
UCP_PORT=${UCP_PUBLIC_FQDN##*:}

if [ "$UCP_PORT" = "$UCP_PUBLIC_FQDN" ]
   then
     UCP_PORT="443"
fi

echo "UCP_SAN=$UCP_SAN"
echo "UCP_PORT=$UCP_PORT"

# Install UCP

docker run --rm -i --name ucp \
    -v /var/run/docker.sock:/var/run/docker.sock \
    docker/ucp:3.1.0 install \
    --controller-port $UCP_PORT \
    --san $CLUSTER_SAN \
    --san $UCP_SAN \
    --admin-username $UCP_ADMIN_USERID \
    --admin-password $UCP_ADMIN_PASSWORD \
    --swarm-port 3376 \
    --unmanaged-cni true \
    --pod-cidr $POD_CIDR \
    --cloud-provider azure \
    --license "$(cat /home/$UCP_ADMIN_USERID/docker_subscription.lic)" \
    --debug

# Add the Azure Storage Volume Driver

docker plugin install --alias cloudstor:azure \
  --grant-all-permissions docker4x/cloudstor:18.06.1-ce-azure1  \
  CLOUD_PLATFORM=AZURE \
  AZURE_STORAGE_ACCOUNT_KEY=$AZURE_STORAGE_ACCOUNT_KEY \
  AZURE_STORAGE_ACCOUNT=$AZURE_STORAGE_ACCOUNT_NAME \
  AZURE_STORAGE_ENDPOINT="core.windows.net" \
  DEBUG=1

echo $(date) " linux-install-ucp - End of Script"
