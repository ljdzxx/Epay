#!/bin/sh
set -eu

# Optional project root is useful for staging directories and offline tests.
if [ "$#" -gt 1 ]; then
    echo 'Usage: epay-fix-plugin-permissions [project-root]' >&2
    exit 1
fi
project_root=${1:-/opt/epay}
case "$project_root" in
    /*) ;;
    *) echo 'Project root must be an absolute path.' >&2; exit 1 ;;
esac
plugins_dir=${project_root%/}/plugins

if [ "$(id -u)" -ne 0 ]; then
    echo 'Plugin permission setup requires root; use docker exec --user root.' >&2
    exit 1
fi
if [ ! -d "$plugins_dir" ] || [ -L "$plugins_dir" ]; then
    echo "Expected a real plugins directory in the project mount: $plugins_dir" >&2
    exit 1
fi
php_group=$(id -g www-data)
cd "$plugins_dir"

# Use the container's group ID, not a same-named account on the host.
# find defaults to not following symlinks. Only directories and regular files
# inside the plugin tree are handled; source files do not need write access.
find . \( -type d -o -type f \) -exec chgrp "$php_group" {} +
find . -type d -exec chmod g+rx {} +
find . -type f -exec chmod g+r {} +

# Cover every plugin, including nested layouts such as jdpay/inc/cert, and
# every merchant beneath it. No merchant IDs or certificate extensions are
# hardcoded: PEM, CRT, KEY, P12 and PFX files all need to be readable.
# Relative paths keep a "cert" component in the project root from matching
# unrelated source files. find's -path wildcard also covers nested merchants.
find . -type d \( -name cert -o -path '*/cert/*' \) -exec chmod 2770 {} +
find . -type f -path '*/cert/*' ! -name cert.pem -exec chmod 0640 {} +
# WeChat Pay and Douyin SDKs refresh this downloaded platform certificate.
find . -type f -path '*/cert/*' -name cert.pem -exec chmod 0660 {} +

echo "Plugin and merchant certificate permissions prepared: $plugins_dir"
