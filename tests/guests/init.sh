#!@tools@/bin/sh
# Test init: the stub image's own init, plus a background job that does what a real agent does:
# loopback forwarder to the host proxy at vsock 2:3128 and an HTTP request via http_proxy. Its output
# reaches the console, so the recorded log shows the answer.
export PATH=/bin

(
  ip link set lo up
  socat TCP-LISTEN:3128,bind=127.0.0.1,fork,reuseaddr VSOCK-CONNECT:2:3128 &
  sleep 1

  export http_proxy=http://127.0.0.1:3128

  wget -q -O - http://ok.test/via-guest 2>&1

  echo "guest requests done"
) &

exec @stub@
