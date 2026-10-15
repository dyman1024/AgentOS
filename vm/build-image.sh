#!/bin/sh
set -eu
# Development-only image builder. The shipped app uses Virtualization.framework, never Docker.
# Run inside an explicitly selected Alpine arm64 builder with only /input and /output mounted.
apk add --no-cache python3 nodejs npm gcc musl-dev make git curl bash e2fsprogs umoci runc
mkdir -p /image /output
for path in bin etc lib root sbin usr var; do cp -a "/$path" /image/; done
mkdir -p /image/dev /image/proc /image/sys /image/tmp /image/workspace /image/opt/agentos
mknod /image/dev/console c 5 1
cp /input/init /image/init
cp /input/guest.py /image/opt/agentos/guest.py
cp /input/oci.py /image/opt/agentos/oci.py
cp /input/aos /image/usr/local/bin/aos
chmod +x /image/init /image/usr/local/bin/aos
# mkfs populates the filesystem without a privileged loop mount.
truncate -s 2G /output/workbench.ext4
mkfs.ext4 -q -F -d /image /output/workbench.ext4
sha256sum /output/workbench.ext4 > /output/workbench.ext4.sha256
apk info -vv > /output/packages.txt
