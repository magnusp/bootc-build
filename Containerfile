# Unified Containerfile for Kubernetes Nodes using openSUSE Tumbleweed-based Bootc images
FROM registry.opensuse.org/opensuse/tumbleweed:latest

# Define bootc compatibility labels
LABEL containers.bootc=1

# 1. Install bootc system packages, kernel, systemd, containerd, runc, and tools
RUN zypper --non-interactive install --no-recommends \
    kernel-default \
    dracut \
    systemd \
    bootc \
    containerd \
    runc \
    iptables \
    iproute2 \
    socat \
    conntrack-tools \
    ethtool \
    util-linux \
    nfs-client \
    cryptsetup \
    lvm2 \
    tar \
    curl \
    jq \
    && zypper clean -a

# 2. Add Kubernetes Repository and Install kubelet, kubeadm, kubectl
RUN mkdir -p /etc/zypp/repos.d/ && cat <<EOF | tee /etc/zypp/repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
type=rpm-md
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
EOF

RUN zypper --gpg-auto-import-keys --non-interactive install --no-recommends \
    kubelet \
    kubeadm \
    kubectl \
    cri-tools \
    kubernetes-cni \
    && zypper clean -a

# 3. Install Helm client to easily bootstrap Cilium, Democratic-CSI and other Helm packages
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && \
    chmod 700 get_helm.sh && \
    ./get_helm.sh && \
    rm get_helm.sh

# 4. Configure Containerd and OCI Runtime (runc)
COPY containerd-config.toml /etc/containerd/config.toml
RUN systemctl enable containerd.service

# 5. Copy kernel/network tuning files
COPY k8s-sysctl.conf /etc/sysctl.d/99-kubernetes.conf
COPY k8s-modules.conf /etc/modules-load.d/99-kubernetes.conf

# 6. Enable kubelet service (it will start on boot and wait for kubeadm configuration)
RUN systemctl enable kubelet.service

# 7. Configure storage dirs to be persistent/mutable on host
RUN mkdir -p /var/lib/kubelet /var/lib/containerd /var/lib/cni /etc/cni/net.d /etc/kubernetes

# 8. Run bootc container lint to ensure the image meets specifications
RUN bootc container lint
