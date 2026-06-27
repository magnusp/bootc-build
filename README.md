# Guide: Deploying and Running the Bootc-based Kubernetes Cluster
This document provides step-by-step instructions for booting the nodes on Proxmox, configuring the 3-node HA Kubernetes Control Plane & Worker cluster, and setting up Cilium and Democratic CSI.

## Architecture Overview
*   **Operating System**: openSUSE Tumbleweed Bootc (`registry.opensuse.org/opensuse/tumbleweed:latest`)
*   **Nodes**: 3 physical/VM nodes, all acting as unified nodes (both control plane and worker nodes)
*   **Container Runtime**: `containerd` with systemd cgroups and `runc` OCI runtime
*   **Networking / CNI**: `Cilium` (eBPF-based, no kube-proxy required if preferred)
*   **Storage / CSI**: `democratic-csi` (using `local-hostpath` pointing to ZFS datasets on VMs or connecting via iSCSI)

---

## 1. Creating VM Disk Images via `bootc-image-builder`
First, build the unified container image using `podman` or `docker`:
```bash
podman build -t local/k8s-node:latest .
```

To convert the container image into a `.qcow2` virtual disk image for Proxmox, use the `bootc-image-builder` utility:
```bash
# Generate QCOW2 image
podman run --rm -it --privileged \
  -v ./output:/output \
  -v /var/lib/containers:/var/lib/containers \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  local/k8s-node:latest
```
Copy the resulting `.qcow2` file to your Proxmox VE hypervisor and import it using `qm importdisk`.

---

## 2. Proxmox Storage Passthrough to VMs
To enable the high-performance local ZFS pool on your Proxmox host for the Kubernetes VMs, you can choose between two main methods.

### Method A: VirtIO SCSI Block Passthrough (Recommended)
This approach passes a ZFS Volume (zvol) block device directly into the VM. VirtIO SCSI single ensures isolated threads per disk, offering the best performance.

1. **Create a zvol on your Proxmox host ZFS pool**:
   ```bash
   # Create a 100G volume on pool 'rpool'
   zfs create -V 100G rpool/k8s-vm1-data
   ```
2. **Pass through the block device to the VM** (assuming VM ID is `101` and SCSI Controller is set to `VirtIO SCSI Single`):
   ```bash
   # Attach the raw zvol block device to VM 101 as SCSI device scsi1
   qm set 101 -scsi1 /dev/zvol/rpool/k8s-vm1-data,discard=on,iothread=1,ssd=1
   ```
   *Note:* Using `discard=on` enables TRIM support which allows the VM to release unused blocks back to the host ZFS pool. `iothread=1` isolates I/O processing onto a dedicated CPU thread.

3. **Partition & Format inside VM**:
   Once booted, the disk appears as `/dev/sdb`. You can format it and mount it under `/var/lib/democratic-csi` for storage.

---

## 3. Bootstrapping the 3-Node Kubernetes Control Plane
We will run a 3-node HA control plane. kubeadm supports standard stacked control planes using an external or embedded `etcd` cluster.

### Step 3.1: Initialize the First Node (e.g., node-1)
Create a `kubeadm-config.yaml` file to define the initialization parameters, including a virtual IP or load-balancer DNS name for the API Server (recommended for HA):
```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "192.168.1.10" # IP of node-1
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "1.31.0"
controlPlaneEndpoint: "k8s-api.homelab.local:6443" # DNS of Load Balancer (or Virtual IP)
etcd:
  local:
    dataDir: /var/lib/etcd
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

Run the initialization on **node-1**:
```bash
sudo kubeadm init --config kubeadm-config.yaml --upload-certs
```
Save the `kubeadm join` commands printed at the end of the output (one for control-plane join, one for workers).

### Step 3.2: Join the Remaining Nodes (node-2 and node-3)
Join the next two nodes as **control planes** using the control-plane join token:
```bash
sudo kubeadm join k8s-api.homelab.local:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane --certificate-key <key>
```
*Note: Since all 3 nodes run both workloads and control plane, you must untaint the nodes to allow scheduler deployment on them:*
```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

---

## 4. Deploying Cilium CNI
Install Cilium via Helm on the master node:
```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=k8s-api.homelab.local \
  --set k8sServicePort=6443
```
Using `kubeProxyReplacement=true` allows Cilium to fully replace `kube-proxy` via eBPF, maximizing performance and compatibility.

---

## 5. Configuring Democratic CSI with Proxmox ZFS
If you are running the VMs on ZFS backed storage, you can expose a ZFS dataset to each VM (e.g. `/var/lib/democratic-csi`) or provision dynamic datasets on Proxmox over SSH/API.

### Dynamic Provisioning on Proxmox host
Install `democratic-csi` on the cluster pointing to the hostpath directory or setup ZFS API communication using:
```bash
helm repo add democratic-csi https://democratic-csi.github.io/charts/
helm repo update

helm install democratic-csi democratic-csi/democratic-csi \
  --namespace democratic-csi \
  --create-namespace \
  -f democratic-csi-values.yaml
```
Your Kubernetes workloads can now request PVCs that map dynamically to local persistent volumes, matching perfectly with node-local paths backed by Proxmox's fast ZFS arrays.
