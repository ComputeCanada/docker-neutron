# Atmosphere's neutron image with downstream patches from patches/ applied.
#
# FROM must be the image Atmosphere deploys for neutron_ovn_metadata (see
# README, "Keeping FROM in step with Atmosphere"). It is a multi-arch index, so
# each --platform picks the matching variant.
ARG FROM=registry.atmosphere.dev/library/neutron:2024.2@sha256:e380efa91bab16ad959b9898f90936e099b31dcb1a3bf726e82b34bb77364252
ARG SITE_PACKAGES=/var/lib/openstack/lib/python3.10/site-packages

FROM ${FROM} AS base

# The base image has neither patch nor quilt, and installing them would change
# its package set. Patching happens here instead, on the build platform: neutron
# is pure Python, so nothing in this stage depends on the target arch and an
# arm64 build needs no emulation.
FROM --platform=$BUILDPLATFORM debian:13.5@sha256:d07d1b51c39f51188e60be9b64e6bf769fa94e187f092bc32b91305cfa34ba5a AS patcher
RUN apt-get update && \
    apt-get install --no-install-recommends -y quilt && \
    rm -rf /var/lib/apt/lists/*
ARG SITE_PACKAGES
WORKDIR /src
COPY --from=base ${SITE_PACKAGES}/neutron /src/neutron
COPY patches /patches
# Patches are upstream commits exactly as git format-patch emits them, so paths
# are neutron/... at -p1. Files outside neutron/ (release notes, tests) are not
# in the installed package; quilt creates them here and they are dropped below.
RUN --network=none \
    QUILT_PATCHES=/patches \
    QUILT_PC=/src/.pc \
    QUILT_PATCH_OPTS="--unified -p1" \
    quilt push -a --fuzz=0 --leave-rejects
# Carry over only the files the patches touched, so the final stage adds a few
# KB on top of the unchanged base rather than a second copy of neutron.
RUN --network=none \
    mkdir /out && \
    QUILT_PATCHES=/patches QUILT_PC=/src/.pc quilt files -a \
        | grep '^neutron/' \
        | xargs -r cp --parents -t /out

# No RUN in this stage, so it never executes target-arch code either. The
# copied files are newer than their __pycache__ entries, which Python detects
# and ignores.
FROM ${FROM}
ARG SITE_PACKAGES
COPY --from=patcher /out/ ${SITE_PACKAGES}/
