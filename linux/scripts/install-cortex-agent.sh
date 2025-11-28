#!/bin/sh

mkdir -p /etc/panw

echo "--distribution-id CHANGETHISFORYOURDEPLOYMENT" > /etc/panw/cortex.conf
echo "--distribution-server https://distributions.traps.paloaltonetworks.com/" >> /etc/panw/cortex.conf

apt-get install --assume-yes -f "$INSTALLER_PATH"
