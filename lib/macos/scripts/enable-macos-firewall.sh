#!/bin/sh

#Script to turn on the Firewall
#Created by Jason Miller

# Configure, then enable the application layer firewall
/usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on
/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
/usr/libexec/ApplicationFirewall/socketfilterfw --setloggingmode on

exit 0