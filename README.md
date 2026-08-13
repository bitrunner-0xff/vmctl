# Examples

Create one VM

```sh
./vmctl.sh -m v -c \
    -n test-1 \
    -d /srv/vms \
    -i /var/lib/libvirt/images/centos-stream.qcow2 \
    -k ~/.ssh/id_ed25519.pub \
    -a 192.168.122.10 \
    -r 4096 \
    -c 4 \
    -s 40 \
    -b virbr0
```

Get its IP, wait up to 30 seconds, poll every 2 seconds

```sh
./vmctl.sh -m v -i -w 30 -i 2 test-1
```

Delete it

```sh
./vmctl.sh -m v -d \
    -n test-1 \
    -p /srv/vms
```

Create cluster

```sh
./vmctl.sh -m c -c \
    --prj-path ~/projects/personal/kube/lab-1 \
    --iso /var/lib/libvirt/images/centos-stream.qcow2 \
    --ssh_key ~/.ssh/kubernetes_lab_vm_key.pub \
    --control 1 \
    --worker 3
```

Delete cluster

```sh
./vmctl.sh -m c -d \
    --prj-path ~/projects/personal/kube/lab-1 \
    --control 3 \
    --worker 3
```
