#!@tools@/bin/sh
# PID 1 of the guest: a stub echo server. Mounts the writable tmpfs paths, prints a banner on the
# serial console and echoes every input line back. Replace this file to run the real guest.
#
# The kernel has mounted the read-only root and devtmpfs on /dev; the console is stdin and stdout.

export PATH=/bin

# The proxy CA in the image is the whole trust store; these are the variables clients read for it.
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE=$SSL_CERT_FILE REQUESTS_CA_BUNDLE=$SSL_CERT_FILE NODE_EXTRA_CA_CERTS=$SSL_CERT_FILE

set -e

mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Everything writable lives in RAM and is gone at shutdown.
mount -t tmpfs -o nosuid,nodev,mode=1777 tmpfs /tmp
mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs /run
mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs /var
mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs /home
mount -t tmpfs -o nosuid,nodev,mode=0700 tmpfs /root

echo "a-box guest: echo server ready"

# The serial line echoes typed characters itself; the echo below is the stub's answer.
stty -echo

while IFS= read -r line; do
  printf '%s\n' "$line"
done

# reboot=k on the command line makes this a VM exit; a plain poweroff would hang.
reboot -f
