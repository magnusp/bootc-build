#!/usr/bin/env bash
# Test suite for the built bootc node image.
# Run via CI with IMAGE_NAME env var pointing to the loaded image tag.
set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; ((PASS++)); }
fail() { echo "  FAIL: $*"; ((FAIL++)); }

banner() { echo; echo "── $* ──────────────────────────────────────"; }

run() { docker run --rm "$IMAGE_NAME" "$@"; }

echo "=============================================="
echo "bootc image test suite"
echo "Image: $IMAGE_NAME"
echo "=============================================="

# ── 1. bootc compatibility label ──────────────────────────────────────────────
banner "bootc label"
label=$(docker inspect --format='{{index .Config.Labels "containers.bootc"}}' "$IMAGE_NAME" 2>/dev/null || true)
if [ "$label" = "1" ]; then
    ok "containers.bootc=1 label present"
else
    fail "containers.bootc=1 label missing (got: '$label')"
fi

# ── 2. Kernel modules directory (from fedora-bootc base) ─────────────────────
banner "Kernel"
if run ls /usr/lib/modules/ > /dev/null 2>&1; then
    ok "/usr/lib/modules/ present"
else
    fail "/usr/lib/modules/ missing – kernel not found"
fi

# ── 3. Mandatory binaries ─────────────────────────────────────────────────────
banner "Required binaries"
for bin in kubelet kubeadm kubectl containerd runc helm systemctl; do
    if run which "$bin" > /dev/null 2>&1; then
        ok "$bin found"
    else
        fail "$bin not found in PATH"
    fi
done

# ── 4. CNI plugin binaries ────────────────────────────────────────────────────
banner "CNI plugins"
if run ls /opt/cni/bin/ > /dev/null 2>&1; then
    ok "/opt/cni/bin/ present with contents: $(run ls /opt/cni/bin/ | tr '\n' ' ')"
else
    fail "/opt/cni/bin/ missing – CNI plugins not installed"
fi

# ── 5. Kernel modules configuration ──────────────────────────────────────────
banner "Kernel modules config"
for mod in br_netfilter overlay nf_conntrack; do
    if run grep -q "$mod" /etc/modules-load.d/99-kubernetes.conf 2>/dev/null; then
        ok "module config: $mod"
    else
        fail "module config missing: $mod"
    fi
done

# ── 6. sysctl settings ────────────────────────────────────────────────────────
banner "sysctl settings"
for setting in "net.ipv4.ip_forward=1" "net.bridge.bridge-nf-call-iptables=1" "net.ipv6.conf.all.forwarding=1"; do
    if run grep -q "$setting" /etc/sysctl.d/99-kubernetes.conf 2>/dev/null; then
        ok "sysctl: $setting"
    else
        fail "sysctl missing: $setting"
    fi
done

# ── 7. containerd config ──────────────────────────────────────────────────────
banner "containerd config"
if run grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
    ok "SystemdCgroup = true"
else
    fail "SystemdCgroup not set in containerd config"
fi
if run grep -q "runc" /etc/containerd/config.toml 2>/dev/null; then
    ok "runc runtime configured"
else
    fail "runc not referenced in containerd config"
fi

# ── 8. kubelet cgroup driver drop-in ─────────────────────────────────────────
banner "kubelet cgroup driver"
if run grep -q "systemd" /etc/systemd/system/kubelet.service.d/10-cgroupdriver.conf 2>/dev/null; then
    ok "kubelet cgroup driver drop-in present"
else
    fail "kubelet cgroup driver drop-in missing"
fi

# ── 9. firewalld disabled ─────────────────────────────────────────────────────
banner "firewalld"
if run test -L /etc/systemd/system/multi-user.target.wants/firewalld.service 2>/dev/null; then
    fail "firewalld is still enabled (symlink exists)"
else
    ok "firewalld is not enabled"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo
echo "=============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
