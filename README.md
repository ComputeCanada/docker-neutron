# `docker-neutron`

Atmosphere's neutron image (`registry.atmosphere.dev/library/neutron`) with
downstream patches applied. It is deployed only where a patch is needed,
through `atmosphere_image_overrides`; everything else keeps using Atmosphere's
image unchanged.

## Patches

`patches/` is a quilt series of upstream neutron commits, exactly as
`git format-patch` emits them, applied in order with `--fuzz=0`. A patch that
no longer applies fails the build rather than half-applying.

| patch | upstream | why |
|---|---|---|
| `haproxy-nbthread-2.patch` | [`0a044ce384`](https://opendev.org/openstack/neutron/commit/0a044ce38407d9ac196bc3fabdc16acf8fbb29fa), [LP#2120668](https://bugs.launchpad.net/neutron/+bug/2120668), neutron 2025.2+ | see below |

### `haproxy-nbthread-2.patch`

The OVN metadata agent runs one haproxy per network with a VM on the host.
haproxy 2.4 defaults to one thread per CPU, capped at 64, and every thread
counts against the kubelet `podPidsLimit` (5000, from `kubelet_pod_pids_limit`
in ubernetes). Our persistent nodes are oversubscribed 10:1 and carry ~80
networks each, so 78 haproxies x 64 threads hit the limit. Provisioning a new
network then fails with `BlockingIOError: [Errno 11] Resource temporarily
unavailable`, its `ovnmeta-` namespace gets no haproxy, and VMs on it never
receive metadata, so no SSH key.

Upstream hit the same thing as `Too many open files` and pinned `nbthread 2`.
With it, a node with 80 networks uses ~160 PIDs instead of ~5000.

## How the image is built

The base image ships neither `patch` nor `quilt`, so a Debian stage on the
*build* platform copies the installed `neutron` package out of the base,
applies the series, and keeps only the files under `neutron/` that the patches
touched. The final stage is the base image plus one `COPY` of those files: no
`RUN`, no package changes, a layer of a few KB.

Because neutron is pure Python and nothing executes target-arch code, the
arm64 variant builds without emulation. It is built at all because kalpa-prod
has an arm64 node (`k8s-a1402`) running the OVN metadata agent: an amd64-only
override would break that pod.

## `ci/smoke-test.sh`

```sh
podman build --platform linux/amd64 -t localhost/neutron:test .
./ci/smoke-test.sh --platform linux/amd64 localhost/neutron:test
```

Every check goes through `import neutron` rather than a file path, so a patch
copied to the wrong `site-packages` (say, after a base bump changes the Python
version) fails instead of silently doing nothing. It checks that neutron
imports, that the imported `METADATA_HAPROXY_GLOBAL` contains `nbthread 2`
exactly once, and that haproxy accepts the config neutron renders and reports
`Nbthread: 2` over its stats socket.

The thread count comes from haproxy, not from `/proc/<pid>/task`: under
qemu-user emulation (GitLab's arm64 path) qemu adds a thread of its own to
every process, which would read as 3.

Run against the unpatched base it fails on the template check, as it should.

## CI

Same arrangement as `docker-openvswitch`: `git.computecanada.ca` is
authoritative and push-mirrors to `github.com/ComputeCanada/docker-neutron`.

- **GitLab** (`.gitlab-ci.yml`) builds both arches with buildah, smoke-tests
  each, then pushes a manifest list to the project registry as the ref slug and
  `$CI_COMMIT_SHORT_SHA`. The arm64 smoke test needs qemu binfmt handlers on
  the runner host (see `docker-openvswitch`'s README).
- **GitHub** (`.github/workflows/ci.yaml`) builds each arch on a native runner,
  smoke-tests it, and publishes `ghcr.io/computecanada/docker-neutron` as the
  branch name, `sha-<short sha>`, and the release tag plus `latest` on a
  published release.

**The ghcr.io package is private until you change it.** After the first
successful run, make it public once:

```
https://github.com/orgs/ComputeCanada/packages/container/docker-neutron/settings
```

## Deploying with Atmosphere

### 1. Allow the image in the Kyverno exception

The kalpa clusters enforce the Pod Security `restricted` level through Kyverno,
and the metadata agent (privileged, root init containers, `CHOWN`) only runs
because of a `PolicyException` whose controls are scoped by image. Without our
image in it, the first replacement pod is rejected and the rollout stalls with
that node's agent gone:

```
admission webhook "validate.kyverno.svc-fail" denied the request: ...
  violates PodSecurity "restricted:" ... runAsNonRoot != true ... privileged ...
```

In `ubernetes-applications`, add `ghcr.io/computecanada/docker-neutron:*`
after **every** `registry.atmosphere.dev/library/neutron:*` line in
`environments/metal/kalpa/default/addons/kyverno/policies/exceptions/openstack/neutron/neutron-ovn-metadata-agent-default-exception.yaml`
(nine of them: Seccomp x2, Capabilities, Privileged Containers, Privilege
Escalation x2, Running as Non-root x2, Running as Non-root user). Missing one
control fails the same way. The file is shared by kalpa-dev and kalpa-prod;
merge it and let Argo CD sync before deploying the image.

If a rollout did stall, it resumes on its own once the exception syncs, but the
DaemonSet controller backs off failed creates for up to ~16 minutes. Touching
the DaemonSet's metadata retries immediately without changing the pod template:

```sh
kubectl -n openstack annotate ds neutron-ovn-metadata-agent-default retry-trigger="$(date +%s)" --overwrite
kubectl -n openstack annotate ds neutron-ovn-metadata-agent-default retry-trigger-
```

### 2. Override the image in atmo-config

The key is **`neutron_metadata`**, not `neutron_ovn_metadata`. Atmosphere
defines both, but the chart's `daemonset-ovn-metadata-agent.yaml` renders all
three of its neutron containers from `images.tags.neutron_metadata`; nothing
reads `neutron_ovn_metadata`, so overriding it produces a new Helm revision
and no pod changes. (`neutron_metadata` is also used by the OVS
`daemonset-metadata-agent.yaml`, which is disabled on OVN clouds.)

Add it to the existing `atmosphere_image_overrides` in
`common/cloud-config/inventory/group_vars/all/all.yml`, pinned by digest. Do
not define `atmosphere_image_overrides` again under an environment's
group_vars: Ansible replaces dicts rather than merging them, so it would drop
every other override for that environment.

```yaml
atmosphere_image_overrides:
  # ...existing overrides...
  neutron_metadata: ghcr.io/computecanada/docker-neutron:sha-<short>@sha256:<index digest>
```

To roll it to one environment first, deploy only that environment from the
branch carrying the change:

```sh
cd atmo-config/kalpa-dev/cloud-config
ansible-playbook -D -u root -i inventory/hosts.ini vexxhost.atmosphere.openstack -t neutron
```

The playbook re-renders the whole neutron release from the collection's image
pins, so run it with the same `vexxhost.atmosphere` version that last deployed
the environment; otherwise neutron-server and the other agents move too. In
the `-D` output the only image change should be `neutron_metadata`.

### 3. Roll out

The `ovn_metadata_agent` DaemonSet rolls 10% at a time (`max_unavailable` in
atmo-config's `neutron_helm_values`). For a one-off faster rollout, patch the
live DaemonSet; the next neutron deploy resets it:

```sh
kubectl -n openstack patch ds neutron-ovn-metadata-agent-default --type merge \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"maxUnavailable":4}}}}'
```

Restarting an agent kills its haproxies, and VMs on that node lose metadata for
a few seconds while it resyncs; the resync also provisions any network that
failed earlier. VMs that already booted without metadata still need a reboot
(or rebuild) for cloud-init to fetch their SSH keys.

### 4. Verify

There is one haproxy per network with a VM on the node, each in an
`ovnmeta-<network id>` namespace. Every generated config should have
`nbthread 2` and every haproxy should run 2 threads:

```sh
pod=$(kubectl -n openstack get pods -o wide --no-headers \
  | awk '/neutron-ovn-metadata-agent/ && $7 ~ /p0122/ {print $1}')
kubectl -n openstack exec $pod -- sh -c \
  'grep -h nbthread /var/lib/neutron/ovn-metadata-proxy/*.conf | sort | uniq -c
   for p in $(pgrep -x haproxy); do ls /proc/$p/task | wc -l; done | sort | uniq -c'
```

On kalpa-dev (2026-10-07) a node with 5 networks went from 5 x 64 haproxy
threads and 334 pod PIDs to 5 x 2 threads and 25 PIDs.

End to end, boot a VM with a key pair and SSH in. The agent on its node logs
the fetch, including `GET /latest/meta-data/public-keys/0/openssh-key ...
status: 200`.

## Keeping `FROM` in step with Atmosphere

`FROM` must be the image Atmosphere deploys for `neutron_metadata`, by
digest. Do not track the moving `2024.2` tag: it is rebuilt between Atmosphere
releases and would put the metadata agent on a different neutron than the rest
of the deployment.

On every Atmosphere upgrade:

1. Read the new digest from the running DaemonSet *before* the override is
   reapplied, or from Atmosphere's `roles/defaults/vars/main.yml`:
   ```sh
   kubectl -n openstack get ds neutron-ovn-metadata-agent-default \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```
2. Update `FROM`, let CI build, and update the override's digest.
3. If a patch no longer applies because the base already contains it, drop it
   from `patches/series`. Once the series is empty, remove the override from
   atmo-config instead of shipping an unmodified image.

For `haproxy-nbthread-2.patch` that happens when Atmosphere moves to neutron
2025.2 (Flamingo); it was not backported to 2025.1 or 2024.2.
