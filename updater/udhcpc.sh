#!@busybox@/bin/busybox sh
# udhcpc lease script: addresses the interface; the first lease also sets the default route and DNS.

case $1 in
  bound | renew)
    # IPv4 only: SLAAC and link-local IPv6 addresses on the same interface stay.
    ip -4 addr flush dev "$interface"
    ip addr add "$ip/$mask" dev "$interface"

    if [ ! -e /run/net-up ]; then
      for r in $router; do
        ip route add default via "$r" dev "$interface"
        break
      done
      for d in $dns; do
        echo "nameserver $d"
      done >/etc/resolv.conf
      : >/run/net-up
    fi
    ;;
esac
