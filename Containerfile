# Unified Containerfile for Kubernetes Nodes using Fedora Bootc
# All 3 nodes act as both control-plane and worker.
FROM quay.io/fedora/fedora-bootc:41

# Kubernetes version – override at build time via --build-arg
ARG KUBERNETES_VERSION=v1.31

# Helm version – pinned for reproducible builds
ARG HELM_VERSION=v3.17.3

# ── 1. Kubernetes DNF repository ──────────────────────────────────────────────
RUN cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl kubernetes-cni cri-tools
EOF

# ── 2. System packages ────────────────────────────────────────────────────────
# containerd and runc come from the Fedora repos (no Docker repo needed)
# kubernetes-cni provides CNI plugin binaries to /opt/cni/bin
RUN dnf install -y --skip-unavailable \
        containerd \
        runc \
        kubelet \
        kubeadm \
        kubectl \
        kubernetes-cni \
        cri-tools \
        iptables \
        iptables-nft \
        iproute \
        socat \
        conntrack-tools \
        ethtool \
        nfs-utils \
        iscsi-initiator-utils \
        cryptsetup \
        lvm2 \
        tar \
        curl \
        jq \
        firewalld \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# ── 3. Helm (pinned, checksum-verified) ──────────────────────────────────────
RUN ARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" && \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
        -o /tmp/helm.tar.gz && \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz.sha256sum" \
        -o /tmp/helm.sha256 && \
    echo "$(cat /tmp/helm.sha256 | awk '{print $1}')  /tmp/helm.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/helm.tar.gz -C /tmp && \
    install -o root -g root -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm && \
    rm -rf /tmp/helm.tar.gz /tmp/helm.sha256 "/tmp/linux-${ARCH}"

# ── 4. containerd configuration ───────────────────────────────────────────────
COPY containerd-config.toml /etc/containerd/config.toml
RUN systemctl enable containerd.service

# ── 5. kubelet – systemd cgroup driver ───────────────────────────────────────
RUN mkdir -p /etc/systemd/system/kubelet.service.d
COPY kubelet-cgroupdriver.conf /etc/systemd/system/kubelet.service.d/10-cgroupdriver.conf
RUN systemctl enable kubelet.service

# ── 6. Kernel / network tuning ───────────────────────────────────────────────
COPY k8s-sysctl.conf    /etc/sysctl.d/99-kubernetes.conf
COPY k8s-modules.conf   /etc/modules-load.d/99-kubernetes.conf

# ── 7. Firewall: configure firewalld for Kubernetes & Cilium ports ───────────
COPY firewalld-public.xml /etc/firewalld/zones/public.xml
RUN systemctl enable firewalld.service

# ── 8. Persistent state directories via systemd-tmpfiles ────────────────────
COPY kubernetes-tmpfiles.conf /usr/lib/tmpfiles.d/kubernetes.conf
RUN mkdir -p \
        /opt/cni/bin \
        /etc/cni/net.d \
        /etc/kubernetes \
        /etc/containerd/certs.d

# ── 9. Clean up transient build artifacts in /var ────────────────────────────
RUN rm -rf \
        /var/log/* \
        /var/cache/dnf \
        /var/cache/libdnf5 \
        /var/cache/ldconfig/aux-cache \
        /var/lib/dnf \
        /var/lib/iscsi

# ── 10. Validate bootc image structure ───────────────────────────────────────
RUN bootc container lint
