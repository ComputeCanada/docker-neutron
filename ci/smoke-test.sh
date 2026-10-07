#!/bin/sh
# Verify a built image before it is published.
#
# The failure this guards against is a patch that applied to the patcher
# stage's copy of neutron but never reached the module Python actually imports
# -- a wrong SITE_PACKAGES after an Atmosphere base bump would do exactly that,
# silently. So every check goes through `import neutron`, never a file path,
# and the last one runs haproxy with the config neutron generates and counts
# its threads.
#
# Usage: ci/smoke-test.sh [--platform os/arch] IMAGE
#
# Runtime is auto-detected; override with CONTAINER_RUNTIME=buildah|podman|docker.
set -eu

PLATFORM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
        --platform=*) PLATFORM="${1#*=}"; shift ;;
        *) break ;;
    esac
done

IMAGE="${1:?usage: smoke-test.sh [--platform os/arch] IMAGE}"
[ -n "$PLATFORM" ] && echo "platform: $PLATFORM"

# haproxy threads each metadata proxy should run with. Keep in step with the
# nbthread value in patches/.
EXPECT_THREADS="${EXPECT_THREADS:-2}"

# Same runtime handling as docker-openvswitch's ci/smoke-test.sh; see the
# comments there for why each fallback exists.
if [ -z "${CONTAINER_RUNTIME:-}" ]; then
    for candidate in buildah podman docker; do
        if command -v "$candidate" >/dev/null 2>&1; then
            CONTAINER_RUNTIME="$candidate"
            break
        fi
    done
fi
: "${CONTAINER_RUNTIME:?no container runtime found (buildah, podman or docker)}"
echo "runtime: $CONTAINER_RUNTIME"

if [ "$CONTAINER_RUNTIME" = "buildah" ]; then
    CTR="$(buildah from --quiet --pull=never ${PLATFORM:+--platform "$PLATFORM"} "$IMAGE" 2>/dev/null)" \
        || CTR="$(buildah from --quiet ${PLATFORM:+--platform "$PLATFORM"} "$IMAGE" 2>/dev/null)" \
        || CTR="$(buildah from --quiet --pull=never "$IMAGE" 2>/dev/null)" \
        || { echo "SMOKE TEST FAILED: cannot create a container from '$IMAGE'${PLATFORM:+ for $PLATFORM}." >&2
             exit 1; }
    trap 'buildah rm "$CTR" >/dev/null 2>&1 || true' EXIT
    NETOPT=""
    probe=""
    for opt in --net=none --net=host ""; do
        if probe="$(buildah run $opt "$CTR" -- sh -c 'uname -m' 2>&1)" && [ -n "$probe" ]; then
            NETOPT="$opt"
            break
        fi
    done
    case "$probe" in
        aarch64|x86_64) ;;
        *) echo "SMOKE TEST FAILED: cannot run commands in a container from '$IMAGE'." >&2
           echo "  last error: $probe" >&2
           exit 1 ;;
    esac
    run() { buildah run $NETOPT "$CTR" -- sh -c "$1" 2>/dev/null; }
else
    PULL="--pull=never"
    "$CONTAINER_RUNTIME" image exists "$IMAGE" 2>/dev/null || PULL=""
    run() {
        "$CONTAINER_RUNTIME" run --rm --network=none $PULL \
            ${PLATFORM:+--platform "$PLATFORM"} --entrypoint sh "$IMAGE" -c "$1"
    }
fi

fail() {
    echo "SMOKE TEST FAILED: $1" >&2
    exit 1
}

PY=/var/lib/openstack/bin/python3

if [ -n "$PLATFORM" ]; then
    want_arch="${PLATFORM#*/}"
    got_arch="$(run 'uname -m' || true)"
    case "$want_arch:$got_arch" in
        arm64:aarch64|aarch64:aarch64|amd64:x86_64|x86_64:x86_64) ;;
        *) fail "wanted $want_arch, container reports '$got_arch'" ;;
    esac
    echo "arch confirmed: $got_arch"
fi

echo "== neutron imports and reports a version =="
version="$(run "$PY -c 'import neutron.version as v; print(v.version_info.release_string())'")" \
    || fail "neutron does not import"
echo "  neutron $version"

echo "== the imported haproxy template sets nbthread $EXPECT_THREADS =="
count="$(run "$PY -c 'from neutron.common import metadata as m; print(m.METADATA_HAPROXY_GLOBAL.count(\"nbthread    $EXPECT_THREADS\"))'")" \
    || fail "cannot import neutron.common.metadata"
[ "$count" = "1" ] || fail "METADATA_HAPROXY_GLOBAL contains 'nbthread    $EXPECT_THREADS' $count times, expected once"
echo "  ok"

echo "== haproxy runs the generated config with $EXPECT_THREADS threads =="
# Rendered by neutron's own template, so this is the config the agent writes;
# the only addition is a stats socket to ask haproxy how many threads it runs.
# Counting /proc/<pid>/task instead would be wrong under qemu-user emulation
# (GitLab's arm64 path), which adds a thread of its own to every process.
# Everything stays in the container's /tmp and binds loopback only.
threads="$(run "
    set -e
    $PY - <<'EOF' > /tmp/haproxy.cfg
from neutron.common import metadata as m
cfg = m.METADATA_HAPROXY_GLOBAL % {
    'log_level': 'info', 'log_tag': 'smoke', 'user': 'neutron',
    'group': 'neutron', 'pidfile': '/tmp/haproxy.pid'}
print(cfg.replace('    daemon\n', '    daemon\n    stats socket /tmp/haproxy.sock\n', 1))
print('listen listener')
print('    bind 127.0.0.1:8775')
print('    server metadata 127.0.0.1:9')
EOF
    haproxy -q -c -f /tmp/haproxy.cfg
    haproxy -f /tmp/haproxy.cfg
    sleep 1
    $PY - <<'EOF'
import socket
s = socket.socket(socket.AF_UNIX)
s.connect('/tmp/haproxy.sock')
s.sendall(b'show info\n')
info = b''
while chunk := s.recv(65536):
    info += chunk
print(dict(l.split(': ', 1) for l in info.decode().splitlines() if ': ' in l)['Nbthread'])
EOF
")" || fail "haproxy rejected or could not start the generated config"
echo "  haproxy Nbthread: $threads"
[ "$threads" = "$EXPECT_THREADS" ] || fail "haproxy runs $threads threads, expected $EXPECT_THREADS"

echo
echo "SMOKE TEST PASSED: $IMAGE"
