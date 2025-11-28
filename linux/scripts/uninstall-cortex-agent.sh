package_name="cortex-agent"

# Fleet uninstalls app using product name that's extracted on upload
apt-get remove --purge --assume-yes "$package_name"
