#!/usr/bin/env bash
# Test suite for validated configurations inside built bootc images
set -euo pipefail

echo "=============================================="
echo "Running bootc image tests..."
echo "=============================================="

# 1. Verify bootc labels
echo "Testing bootc configuration labels..."
bootc_compat=$(docker inspect --format='{{index .Config.Labels "containers.bootc"}}' "$IMAGE_NAME")
if [ "$bootc_compat" != "1" ]; then
    echo "FAIL: bootc compatibility label 'containers.bootc=1' not found!"
    exit 1
fi
echo "PASS: bootc compatibility label is valid."

# 2. Check kernel config and modules directory
echo "Verifying kernel presence..."
if ! docker run --rm "$IMAGE_NAME" ls -d /usr/lib/modules/ > /dev/null 2>&1; then
    echo "FAIL: /usr/lib/modules not found! Kernel is missing."
    exit 1
fi
echo "PASS: Kernel modules directory is present."

# 3. Check for mandatory binaries
mandatory_binaries=("kubelet" "kubeadm" "kubectl" "containerd" "runc" "systemctl")
for bin in "${mandatory_binaries[@]}"; do
    echo "Checking binary: $bin..."
    if ! docker run --rm "$IMAGE_NAME" which "$bin" > /dev/null 2>&1; then
        echo "FAIL: Required binary '$bin' is not installed."
        exit 1
    fi
done
echo "PASS: All mandatory binaries are present."

# 4. Check for kernel modules load configurations
echo "Verifying kernel modules configurations..."
required_modules=("br_netfilter" "overlay" "nf_conntrack")
for mod in "${required_modules[@]}"; do
    if ! docker run --rm "$IMAGE_NAME" grep -q "$mod" /etc/modules-load.d/99-kubernetes.conf; then
        echo "FAIL: Module '$mod' configuration not found in /etc/modules-load.d/99-kubernetes.conf."
        exit 1
    fi
done
echo "PASS: Kernel modules configurations verified."

# 5. Check for sysctl network tuning options
echo "Verifying sysctl settings..."
required_sysctl=("net.ipv4.ip_forward=1" "net.bridge.bridge-nf-call-iptables=1")
for sys in "${required_sysctl[@]}"; do
    if ! docker run --rm "$IMAGE_NAME" grep -q "${sys// /}" /etc/sysctl.d/99-kubernetes.conf; then
        echo "FAIL: Sysctl setting '$sys' not found in /etc/sysctl.d/99-kubernetes.conf."
        exit 1
    fi
done
echo "PASS: Sysctl configurations verified."

# 6. Verify containerd config.toml systemd-cgroup setting
echo "Verifying containerd cgroup configuration..."
if ! docker run --rm "$IMAGE_NAME" grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
    echo "FAIL: Containerd config does not have SystemdCgroup enabled."
    exit 1
fi
echo "PASS: Containerd configuration verified."

echo "=============================================="
echo "ALL TESTS PASSED SUCCESSFULLY!"
echo "=============================================="
