#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_RAM=2048
readonly DEFAULT_VCPUS=2
readonly DEFAULT_STORAGE=80
readonly DEFAULT_BRIDGE=virbr0
readonly DEFAULT_SSH_PORT=30122
readonly DEFAULT_WAIT_INTERVAL=2
readonly DEFAULT_OSINFO=centos-stream10

# -----------------------------------------------------------------------------
# LOGS
# -----------------------------------------------------------------------------

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------

run_virsh() {
    if ((EUID == 0)); then
        virsh "$@"
    else
        command -v sudo >/dev/null 2>&1 ||
            die "sudo is required when not running as root"

        sudo virsh "$@"
    fi
}

run_virt_install() {
    if ((EUID == 0)); then
        virt-install "$@"
    else
        command -v sudo >/dev/null 2>&1 ||
            die "sudo is required when not running as root"

        sudo virt-install "$@"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

validate_uint() {
    local value=$1 name=$2
    [[ $value =~ ^[0-9]+$ ]] ||
        die "$name must be a non-negative integer, got '$value'"
}

validate_positive_int() {
    local value=$1 name=$2
    validate_uint "$value" "$name"
    ((value > 0)) ||
        die "$name must be greater than zero, got '$value'"
}

validate_vm_name() {
    local value=$1
    [[ -n $value ]] || die "VM name is required"
    [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
        die "Invalid VM name '$value'; allowed characters: letters, digits, '.', '_', '-'"
}

validate_ipv4() {
    local ip=$1 octet value
    local IFS=.
    local -a octets=()

    read -r -a octets <<<"$ip"

    ((${#octets[@]} == 4)) || return 1

    for octet in "${octets[@]}"; do
        [[ $octet =~ ^[0-9]+$ ]] || return 1
        value=$((10#$octet))
        ((value >= 0 && value <= 255)) || return 1
    done
}

vm_exists() {
    run_virsh dominfo "$1" >/dev/null 2>&1
}

vm_is_running() {
    [[ $(run_virsh domstate "$1" 2>/dev/null | head -n1) == running ]]
}

generate_mac() {
    local hex
    hex=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')
    printf '52:54:00:%s:%s:%s\n' "${hex:0:2}" "${hex:2:2}" "${hex:4:2}"
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

usage() {
    cat <<'EOF_USAGE'
Usage:
  vmctl -m v -c [create-vm options]
  vmctl -m v -d [delete-vm options]
  vmctl -m v -i [get-ip options] VM_NAME
  vmctl -m c -c [create-cluster options]
  vmctl -m c -d [delete-cluster options]

Main options:
  -h            Show this help
  -m MODE       Mode: v = single VM, c = cluster
  -c            Create
  -d            Delete
  -i            Get VM IP (valid only with -m v)

Important:
  The main action flag terminates main-option parsing. Options after it belong
  to the selected operation. This resolves collisions such as '-c' meaning
  both "create" at the top level and "vCPU count" in create-vm.

Examples:
  vmctl -m v -c -n test-1 -d /srv/vms -i /images/centos.qcow2 \
      -k ~/.ssh/id_ed25519.pub -a 192.168.122.10
  vmctl -m v -d -n test-1 -p /srv/vms
  vmctl -m v -i -w 30 -i 2 test-1
  vmctl -m c -c --prj-path /srv/k8s --iso /images/centos.qcow2 \
      --ssh_key ~/.ssh/id_ed25519.pub --control 1 --worker 3
EOF_USAGE
}

get_ip_usage() {
    cat <<'EOF_USAGE'
Usage:
  vmctl -m v -i [-w SECONDS] [-i SECONDS] VM_NAME

Options:
  -h            Show this help
  -w SECONDS    Maximum total time to wait for an IP; default: 0
  -i SECONDS    Poll interval; default: 2
EOF_USAGE
}

create_vm_usage() {
    cat <<EOF_USAGE
Usage:
  vmctl -m v -c -n NAME -d PROJECT_DIR -i BASE_IMAGE -k SSH_PUBLIC_KEY \\
      -a IPV4 [-r MB] [-c VCPUS] [-s GB] [-b BRIDGE] [-m MAC] [-v]

Options:
  -h            Show this help
  -n NAME       VM hostname/name (required)
  -d DIR        Project/work directory (required)
  -i IMAGE      Base cloud disk image, e.g. qcow2 (required)
  -k KEY        SSH public key file (required)
  -r MB         RAM in MiB; default: ${DEFAULT_RAM}
  -c VCPUS      vCPU count; default: ${DEFAULT_VCPUS}
  -s GB         Disk size in GiB; default: ${DEFAULT_STORAGE}
  -b BRIDGE     Host bridge interface; default: ${DEFAULT_BRIDGE}
  -a IPV4       Static IPv4 address (required; /24 is assumed)
  -m MAC        MAC address; default: generated locally
  -v            Verbose shell tracing

Note:
  Despite the historical '-i/--iso' name, this workflow uses qemu-img backing
  files and virt-install --import. IMAGE must therefore be a bootable cloud
  disk image, not an installer ISO.
EOF_USAGE
}

delete_vm_usage() {
    cat <<'EOF_USAGE'
Usage:
  vmctl -m v -d -n VM_NAME -p PROJECT_DIR

Options:
  -h            Show this help
  -n VM_NAME    VM name (required)
  -p DIR        Project/work directory containing images/ and init/ (required)
EOF_USAGE
}

cluster_create_usage() {
    cat <<'EOF_USAGE'
Usage:
  vmctl -m c -c --prj-path PATH --iso BASE_IMAGE --ssh_key SSH_PUBLIC_KEY
                  [--control NUM] [--worker NUM]

Options:
  -h, --help          Show this help
  --ssh_key PATH      SSH public key (required)
  --iso PATH          Base cloud disk image (required; historical option name)
  --prj-path PATH     Project directory (required)
  --control NUM       Number of control nodes; default: 1
  --worker NUM        Number of worker nodes; default: 1
EOF_USAGE
}

cluster_delete_usage() {
    cat <<'EOF_USAGE'
Usage:
  vmctl -m c -d --prj-path PATH [--control NUM] [--worker NUM]

Options:
  -h, --help          Show this help
  --ssh_key PATH      Accepted for CLI compatibility; not used for deletion
  --prj-path PATH     Project directory (required)
  --control NUM       Number of control nodes; default: 1
  --worker NUM        Number of worker nodes; default: 1
EOF_USAGE
}

# -----------------------------------------------------------------------------
# Get IP
# -----------------------------------------------------------------------------

get_vm_mac() {
    local vm=$1
    run_virsh domiflist "$vm" 2>/dev/null |
        awk 'NR > 2 && $5 ~ /^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$/ { print tolower($5); exit }'
}

get_vm_ip_once() {
    local vm=$1 ip='' mac=''

    vm_exists "$vm" || return 1
    vm_is_running "$vm" || return 1

    # Best source when qemu-guest-agent is available.
    ip=$(run_virsh domifaddr "$vm" --source agent 2>/dev/null |
        awk 'NR > 2 && $4 ~ /^[0-9]+\./ { sub(/\/.*/, "", $4); print $4; exit }')

    # Libvirt/DHCP lease source.
    if [[ -z $ip ]]; then
        ip=$(run_virsh domifaddr "$vm" --source lease 2>/dev/null |
            awk 'NR > 2 && $4 ~ /^[0-9]+\./ { sub(/\/.*/, "", $4); print $4; exit }')
    fi

    # Host neighbor table fallback.
    if [[ -z $ip ]]; then
        mac=$(get_vm_mac "$vm")
        if [[ -n $mac ]]; then
            ip=$(ip neigh show 2>/dev/null |
                awk -v mac="$mac" 'tolower($0) ~ mac && $1 ~ /^[0-9]+\./ { print $1; exit }')
        fi
    fi

    [[ -n $ip ]] || return 1
    printf '%s\n' "$ip"
}

get_vm_ip_cli() {
    local wait_seconds=0 interval=$DEFAULT_WAIT_INTERVAL
    local OPTIND=1 opt

    while getopts ':hw:i:' opt; do
        case "$opt" in
        h)
            get_ip_usage
            return 0
            ;;
        w) wait_seconds=$OPTARG ;;
        i) interval=$OPTARG ;;
        :) die "Option -$OPTARG requires an argument" ;;
        \?) die "Unknown get-IP option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))

    local vm=${1:-}
    [[ $# -eq 1 ]] || {
        get_ip_usage >&2
        die "Exactly one VM name is required"
    }
    validate_vm_name "$vm"
    validate_uint "$wait_seconds" "wait time"
    validate_positive_int "$interval" "wait interval"

    require_command virsh
    require_command ip

    local start=$SECONDS result
    while :; do
        if result=$(get_vm_ip_once "$vm"); then
            printf '%s\n' "$result"
            return 0
        fi

        ((wait_seconds > 0)) || break
        ((SECONDS - start < wait_seconds)) || break
        sleep "$interval"
    done

    die "Could not obtain an IP address for VM '$vm' within ${wait_seconds}s"
}

# -----------------------------------------------------------------------------
# Create VM
# -----------------------------------------------------------------------------

write_cloud_init() {
    local vm=$1 init_dir=$2 ssh_key=$3 ip_addr=$4 mac=$5
    local gateway="${ip_addr%.*}.1"
    local password_hash=$(printf "%s" "admin" | mkpasswd --method=SHA-512 --rounds=500000 --stdin)

    cat >"$init_dir/meta-data" <<EOF_META
instance-id: ${vm}
local-hostname: ${vm}
EOF_META

    cat >"$init_dir/user-data" <<EOF_USER
#cloud-config

users:
  - name: admin
    gecos: Administrator
    primary_group: admin
    groups: [wheel]
    lock_passwd: false
    passwd: '${password_hash}'
    homedir: /home/admin
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_key}

ssh_pwauth: false

bootcmd:
  - [/usr/sbin/setenforce, "0"]
  - sed -ri 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
  - [systemctl, mask, --now, firewalld.service]

package_update: true

packages:
  - qemu-guest-agent
  - python3

write_files:
  - path: /etc/ssh/sshd_config.d/00-vmctl.conf
    permissions: '0644'
    content: |
      Port ${DEFAULT_SSH_PORT}
      PermitRootLogin no
      PubkeyAuthentication yes
      PasswordAuthentication no
      PermitEmptyPasswords no

runcmd:
  - [/usr/sbin/sshd, -t]
  - [systemctl, restart, sshd]
  - [systemctl, enable, --now, qemu-guest-agent]
EOF_USER

    cat >"$init_dir/network-config" <<EOF_NET
version: 2
renderer: NetworkManager
ethernets:
  vmnic:
    match:
      macaddress: "${mac}"
    set-name: eth0
    dhcp4: false
    dhcp6: false
    addresses:
      - ${ip_addr}/24
    nameservers:
      addresses: [${gateway}]
    routes:
    - to: 0.0.0.0/0
      via: ${gateway}
      metric: 100
EOF_NET
}

create_vm_impl() {
    local vm=$1 project_dir=$2 base_image=$3 ssh_key_file=$4 ip_addr=$5
    local ram=$6 vcpus=$7 storage=$8 bridge=$9 mac=${10} verbose=${11}

    require_command virsh
    require_command virt-install
    require_command qemu-img
    require_command genisoimage
    require_command realpath

    validate_vm_name "$vm"
    validate_positive_int "$ram" RAM
    validate_positive_int "$vcpus" vCPU
    validate_positive_int "$storage" storage
    validate_ipv4 "$ip_addr" || die "Invalid IPv4 address: $ip_addr"

    [[ $mac =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] ||
        die "Invalid MAC address: $mac"

    [[ -f $base_image ]] || die "Base image not found: $base_image"
    [[ -r $base_image ]] || die "Base image is not readable: $base_image"
    [[ -f $ssh_key_file ]] || die "SSH public key not found: $ssh_key_file"
    [[ -r $ssh_key_file ]] || die "SSH public key is not readable: $ssh_key_file"
    [[ -d /sys/class/net/$bridge ]] || die "Bridge interface not found: $bridge"

    base_image=$(realpath -e "$base_image")
    ssh_key_file=$(realpath -e "$ssh_key_file")

    mkdir -p "$project_dir"

    project_dir=$(realpath "$project_dir")

    vm_exists "$vm" && die "VM '$vm' already exists in libvirt"

    local images_dir="$project_dir/images"
    local init_dir="$project_dir/init/$vm"
    local disk="$images_dir/$vm.qcow2"
    local cidata="$images_dir/$vm-cidata.iso"
    local base_format ssh_key

    mkdir -p "$images_dir" "$init_dir"
    [[ ! -e $disk ]] || die "VM disk already exists: $disk"
    [[ ! -e $cidata ]] || die "cloud-init ISO already exists: $cidata"

    base_format=$(qemu-img info "$base_image" | awk -F': ' '$1 == "file format" { print $2; exit }')
    [[ -n $base_format ]] ||
        die "Unable to determine base image format: $base_image"

    ssh_key=$(<"$ssh_key_file")
    [[ $ssh_key == ssh-* ]] ||
        warn "SSH key does not look like a standard OpenSSH public key"

    if ((verbose)); then
        set -x
    fi

    log "Creating disk: $disk"
    qemu-img create -f qcow2 -F "$base_format" -b "$base_image" "$disk" "${storage}G"

    write_cloud_init "$vm" "$init_dir" "$ssh_key" "$ip_addr" "$mac"

    log "Creating cloud-init ISO: $cidata"
    if ! (
        cd "$init_dir"
        genisoimage -quiet -output "$cidata" -volid cidata -rational-rock -joliet \
            user-data meta-data network-config
    ); then
        rm -f -- "$disk" "$cidata"
        rm -rf -- "$init_dir"
        die "Failed to create cloud-init ISO for '$vm'"
    fi

    log "Defining and starting VM '$vm'"
    if ! run_virt_install \
        --connect qemu:///system \
        --name "$vm" \
        --cpu host-model \
        --vcpus "$vcpus" \
        --memory "$ram" \
        --osinfo "${VM_OSINFO:-$DEFAULT_OSINFO}" \
        --import \
        --disk "path=$disk,format=qcow2,bus=virtio" \
        --disk "path=$cidata,format=raw,device=cdrom" \
        --network "network=default,model=virtio,mac=$mac" \
        --graphics none \
        --noautoconsole; then
        warn "virt-install failed; rolling back '$vm'"
        if vm_exists "$vm"; then
            vm_is_running "$vm" && run_virsh destroy "$vm" >/dev/null 2>&1 || true
            run_virsh undefine "$vm" --nvram >/dev/null 2>&1 ||
                run_virsh undefine "$vm" >/dev/null 2>&1 || true
        fi
        rm -f -- "$disk" "$cidata"
        rm -rf -- "$init_dir"
        return 1
    fi

    if ((verbose)); then
        set +x
    fi

    log "VM '$vm' created with static IP $ip_addr and MAC $mac"
}

create_vm_cli() {
    local vm='' project_dir='' base_image='' ssh_key_file='' ip_addr='' mac=''
    local ram=$DEFAULT_RAM vcpus=$DEFAULT_VCPUS storage=$DEFAULT_STORAGE bridge=$DEFAULT_BRIDGE
    local verbose=0 OPTIND=1 opt

    while getopts ':hn:d:i:k:r:c:s:b:a:m:v' opt; do
        case "$opt" in
        h)
            create_vm_usage
            return 0
            ;;
        n) vm=$OPTARG ;;
        d) project_dir=$OPTARG ;;
        i) base_image=$OPTARG ;;
        k) ssh_key_file=$OPTARG ;;
        r) ram=$OPTARG ;;
        c) vcpus=$OPTARG ;;
        s) storage=$OPTARG ;;
        b) bridge=$OPTARG ;;
        a) ip_addr=$OPTARG ;;
        m) mac=$OPTARG ;;
        v) verbose=1 ;;
        :) die "Option -$OPTARG requires an argument" ;;
        \?) die "Unknown create-VM option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    [[ $# -eq 0 ]] || die "Unexpected create-VM argument: $1"

    [[ -n $vm ]] || {
        create_vm_usage >&2
        die "-n NAME is required"
    }
    [[ -n $project_dir ]] || die "-d PROJECT_DIR is required"
    [[ -n $base_image ]] || die "-i BASE_IMAGE is required"
    [[ -n $ssh_key_file ]] || die "-k SSH_PUBLIC_KEY is required"
    [[ -n $ip_addr ]] || die "-a IPV4 is required"
    [[ -n $mac ]] || mac=$(generate_mac)

    create_vm_impl "$vm" "$project_dir" "$base_image" "$ssh_key_file" "$ip_addr" \
        "$ram" "$vcpus" "$storage" "$bridge" "$mac" "$verbose"
}

# -----------------------------------------------------------------------------
# Delete VM
# -----------------------------------------------------------------------------

delete_vm_impl() {
    local vm=$1 project_dir=$2
    validate_vm_name "$vm"

    require_command virsh
    require_command realpath

    [[ -d $project_dir ]] || warn "Project directory does not exist: $project_dir"

    if vm_exists "$vm"; then
        if vm_is_running "$vm"; then
            log "Destroying running VM '$vm'"
            run_virsh destroy "$vm" >/dev/null
        fi

        log "Undefining VM '$vm'"
        if ! run_virsh undefine "$vm" --nvram >/dev/null 2>&1; then
            run_virsh undefine "$vm" >/dev/null
        fi
    else
        warn "VM '$vm' is not defined in libvirt"
    fi

    # Delete only files this tool owns; do not use virsh --remove-all-storage.
    if [[ -d $project_dir ]]; then
        project_dir=$(realpath "$project_dir")
        local disk_qcow2="$project_dir/images/$vm.qcow2"
        local legacy_disk="$project_dir/images/$vm.img"
        local cidata="$project_dir/images/$vm-cidata.iso"
        local legacy_cidata="$project_dir/images/$vm-cidata.img"
        local init_dir="$project_dir/init/$vm"

        rm -f -- "$disk_qcow2" "$legacy_disk" "$cidata" "$legacy_cidata"
        rm -rf -- "$init_dir"
    fi

    log "VM '$vm' deleted"
}

delete_vm_cli() {
    local vm='' project_dir='' OPTIND=1 opt

    while getopts ':hn:p:' opt; do
        case "$opt" in
        h)
            delete_vm_usage
            return 0
            ;;
        n) vm=$OPTARG ;;
        p) project_dir=$OPTARG ;;
        :) die "Option -$OPTARG requires an argument" ;;
        \?) die "Unknown delete-VM option: -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    [[ $# -eq 0 ]] || die "Unexpected delete-VM argument: $1"

    [[ -n $vm ]] || {
        delete_vm_usage >&2
        die "-n VM_NAME is required"
    }
    [[ -n $project_dir ]] || die "-p PROJECT_DIR is required"

    delete_vm_impl "$vm" "$project_dir"
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------

wait_for_tcp() {
    local host=$1 port=$2 timeout_seconds=$3 interval=$4
    local start=$SECONDS

    require_command nc
    require_command timeout

    while ((SECONDS - start < timeout_seconds)); do
        if timeout 2 nc -z "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$interval"
    done
    return 1
}

write_ansible_inventory() {
    local project_dir=$1 control_count=$2 worker_count=$3
    local inventory="$project_dir/hosts.yaml" n ip suffix

    {
        echo 'kube_control_plane:'
        echo '  hosts:'
        for ((n = 1; n <= control_count; n++)); do
            suffix=$((9 + n))
            ip="192.168.122.$suffix"
            printf '    k8s-control-%d.cluster.local:\n' "$n"
            printf '      ansible_host: %s\n' "$ip"
            printf '      ansible_port: %d\n' "$DEFAULT_SSH_PORT"
            echo '      ansible_user: admin'
        done

        echo 'kube_node:'
        echo '  hosts:'
        for ((n = 1; n <= worker_count; n++)); do
            suffix=$((9 + control_count + n))
            ip="192.168.122.$suffix"
            printf '    k8s-worker-%d.cluster.local:\n' "$n"
            printf '      ansible_host: %s\n' "$ip"
            printf '      ansible_port: %d\n' "$DEFAULT_SSH_PORT"
            echo '      ansible_user: admin'
        done

        cat <<'EOF_INV'
etcd:
  children:
    kube_control_plane:
k8s_cluster:
  children:
    kube_control_plane:
    kube_node:
EOF_INV
    } >"$inventory"

    log "Ansible inventory written to $inventory"
}

create_cluster_cli() {
    local project_dir='' base_image='' ssh_key_file=''
    local control=1 worker=1

    while (($# > 0)); do
        case "$1" in
        -h | --help)
            cluster_create_usage
            return 0
            ;;
        --ssh_key)
            (($# >= 2)) || die "--ssh_key requires a value"
            ssh_key_file=$2
            shift 2
            ;;
        --iso)
            (($# >= 2)) || die "--iso requires a value"
            base_image=$2
            shift 2
            ;;
        --prj-path)
            (($# >= 2)) || die "--prj-path requires a value"
            project_dir=$2
            shift 2
            ;;
        --control)
            (($# >= 2)) || die "--control requires a value"
            control=$2
            shift 2
            ;;
        --worker)
            (($# >= 2)) || die "--worker requires a value"
            worker=$2
            shift 2
            ;;
        *) die "Unknown create-cluster option: $1" ;;
        esac
    done

    [[ -n $project_dir ]] || {
        cluster_create_usage >&2
        die "--prj-path is required"
    }

    [[ -n $base_image ]] || die "--iso BASE_IMAGE is required"
    [[ -n $ssh_key_file ]] || die "--ssh_key SSH_PUBLIC_KEY is required"

    validate_positive_int "$control" control
    validate_uint "$worker" worker

    ((control + worker <= 245)) ||
        die "Cluster is too large for 192.168.122.0/24 address allocation"

    mkdir -p "$project_dir"

    local n suffix ip
    for ((n = 1; n <= control; n++)); do
        suffix=$((9 + n))
        ip="192.168.122.$suffix"

        log "Creating k8s-control-$n ($ip)"

        create_vm_impl "k8s-control-$n" "$project_dir" "$base_image" "$ssh_key_file" "$ip" \
            4096 2 20 "$DEFAULT_BRIDGE" "$(generate_mac)" 0
    done

    for ((n = 1; n <= worker; n++)); do
        suffix=$((9 + control + n))
        ip="192.168.122.$suffix"

        log "Creating k8s-worker-$n ($ip)"

        create_vm_impl "k8s-worker-$n" "$project_dir" "$base_image" "$ssh_key_file" "$ip" \
            8192 6 20 "$DEFAULT_BRIDGE" "$(generate_mac)" 0
    done

    local ready_timeout=${CLUSTER_READY_TIMEOUT:-300}
    local ready_interval=${CLUSTER_READY_INTERVAL:-5}

    validate_positive_int "$ready_timeout" CLUSTER_READY_TIMEOUT
    validate_positive_int "$ready_interval" CLUSTER_READY_INTERVAL

    for ((n = 1; n <= control; n++)); do
        ip="192.168.122.$((9 + n))"

        log "Waiting for k8s-control-$n SSH at $ip:$DEFAULT_SSH_PORT"

        wait_for_tcp "$ip" "$DEFAULT_SSH_PORT" "$ready_timeout" "$ready_interval" ||
            die "Timed out waiting for k8s-control-$n at $ip:$DEFAULT_SSH_PORT"
    done

    for ((n = 1; n <= worker; n++)); do
        ip="192.168.122.$((9 + control + n))"

        log "Waiting for k8s-worker-$n SSH at $ip:$DEFAULT_SSH_PORT"

        wait_for_tcp "$ip" "$DEFAULT_SSH_PORT" "$ready_timeout" "$ready_interval" ||
            die "Timed out waiting for k8s-worker-$n at $ip:$DEFAULT_SSH_PORT"
    done

    write_ansible_inventory "$project_dir" "$control" "$worker"
    log "Cluster creation completed successfully"
}

delete_cluster_cli() {
    local project_dir='' control=1 worker=1

    while (($# > 0)); do
        case "$1" in
        -h | --help)
            cluster_delete_usage
            return 0
            ;;
        --ssh_key)
            (($# >= 2)) || die "--ssh_key requires a value"
            shift 2
            ;; # accepted but intentionally unused
        --prj-path)
            (($# >= 2)) || die "--prj-path requires a value"
            project_dir=$2
            shift 2
            ;;
        --control)
            (($# >= 2)) || die "--control requires a value"
            control=$2
            shift 2
            ;;
        --worker)
            (($# >= 2)) || die "--worker requires a value"
            worker=$2
            shift 2
            ;;
        *) die "Unknown delete-cluster option: $1" ;;
        esac
    done

    [[ -n $project_dir ]] || {
        cluster_delete_usage >&2
        die "--prj-path is required"
    }
    validate_positive_int "$control" control
    validate_uint "$worker" worker

    local n
    for ((n = 1; n <= control; n++)); do
        delete_vm_impl "k8s-control-$n" "$project_dir"
    done
    for ((n = 1; n <= worker; n++)); do
        delete_vm_impl "k8s-worker-$n" "$project_dir"
    done

    log "Cluster deletion completed successfully"
}

# -----------------------------------------------------------------------------
# Main interface
# -----------------------------------------------------------------------------

main() {
    local mode='' action=''

    (($# > 0)) || {
        usage
        return 1
    }

    # Parse only main-level options. Once an action is selected, everything
    # remaining belongs to that action's own parser.
    while (($# > 0)); do
        case "$1" in
        -h | --help)
            usage
            return 0
            ;;
        -m)
            (($# >= 2)) || die "-m requires MODE (v or c)"
            mode=$2
            shift 2
            ;;
        -c)
            action=create
            shift
            break
            ;;
        -d)
            action=delete
            shift
            break
            ;;
        -i)
            action=ip
            shift
            break
            ;;
        *)
            die "Unknown main option before action: $1"
            ;;
        esac
    done

    [[ $mode == v || $mode == c ]] || die "-m MODE is required and must be 'v' or 'c'"
    [[ -n $action ]] || die "One action is required: -c, -d, or -i"

    case "$mode:$action" in
    v:create) create_vm_cli "$@" ;;
    v:delete) delete_vm_cli "$@" ;;
    v:ip) get_vm_ip_cli "$@" ;;
    c:create) create_cluster_cli "$@" ;;
    c:delete) delete_cluster_cli "$@" ;;
    c:ip) die "IP lookup is only valid for single-VM mode (-m v)" ;;
    *) die "Unsupported mode/action combination: $mode/$action" ;;
    esac
}

main "$@"
