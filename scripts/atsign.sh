#!/bin/bash
echo "Adding new Linux user atsign"
sudo adduser -uid 1024 --disabled-password --disabled-login atsign
echo "Creating some base directories for atsign"
sudo -u atsign mkdir -p ~atsign/dess ~atsign/atsign/var ~atsign/atsign/etc ~atsign/atsign/logs
echo "Copying over the base config files"
sudo -u atsign cp dess/.env ~atsign/dess/
sudo -u atsign cp dess/docker-compose.yaml ~atsign/dess/
echo "Allowing atsign to run docker containers"
sudo usermod -aG docker atsign
echo "Checking if atsign can run a docker container"
sleep 5
echo "OK let's try"
sudo -u atsign docker run hello-world
echo "."
sleep 1
echo "."
sleep 1
echo "If your saw hello-world run you are ready for the next step"
echo "editing the config files for your secondary"
echo "start by switching user to atsign, with the following command"
echo "sudo -s -u atsign"
echo "The change directory to dess and edit .env"
echo "cd dess"
echo "nano .env"
echo "Once that is complete get some certificates with"
echo "docker-compose up cert"

