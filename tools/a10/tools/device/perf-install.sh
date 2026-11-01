#!/bin/sh
# perf for the device chroot, which has no network: Debian unstable's
# linux-perf installed in the Mesa sid container, copied with the libraries
# it links to /run/sid/opt/perf (perf itself to /usr/local/bin). Run it
# with LD_LIBRARY_PATH set to those directories, as mesa/hypr-bench.sh
# profile does. The kernel config has PERF_EVENTS and the CPU PMU.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../../out/perf
mkdir -p "$OUT"
podman run --rm -v "$OUT:/out" localhost/orchard-mesa-g9p:sid sh -c '
    apt-get update -qq > /dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-perf > /dev/null
    cp /usr/bin/perf /out/perf
    tar -chf /out/libs.tar $(ldd /usr/bin/perf | awk "/=>/ { print \$3 }")'
orchard push "$OUT/perf" /run/sid/usr/local/bin/perf > /dev/null
orchard push "$OUT/libs.tar" /run/sid/root/perf-libs.tar > /dev/null
orchard exec -- sh -c 'mkdir -p /run/sid/opt/perf && tar -xf /run/sid/root/perf-libs.tar -C /run/sid/opt/perf &&
    rm /run/sid/root/perf-libs.tar && chmod +x /run/sid/usr/local/bin/perf'
