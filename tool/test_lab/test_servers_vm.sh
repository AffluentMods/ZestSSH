#!/usr/bin/env bash
# A small Google Compute Engine VM that carries ONLY the remote screen test servers
# (tool/remote_screens_test_servers.sh: the test sshd on 2240, Xvnc on 15931/15932 and its socket,
# xrdp on 13389, the test account "alex"), so that Firebase Test Lab devices can run the device
# tests that need a server (integration_test/screen_run_test.dart). WSL on a developer's PC is
# unreachable from Test Lab; this VM stands in for it during a run and is stopped after.
#
#   bash tool/test_lab/test_servers_vm.sh network   [--go]   once: its own VPC, subnet, firewall
#   bash tool/test_lab/test_servers_vm.sh create    [--go]   once: the VM (no service account)
#   bash tool/test_lab/test_servers_vm.sh ranges    [--go]   when Google changes Test Lab's IP blocks
#   bash tool/test_lab/test_servers_vm.sh up        [--go]   each run: start, new password, servers up
#   bash tool/test_lab/test_servers_vm.sh settings  [--go]   each run: the dart-defines file for the run
#   bash tool/test_lab/test_servers_vm.sh down      [--go]   each run: account purged, VM stopped
#   bash tool/test_lab/test_servers_vm.sh delete    [--go]   the end: VM, firewall, subnet, VPC gone
#
# Without --go every step PRINTS its gcloud commands and changes nothing. With --go it creates or
# changes billed Google Cloud resources: a person's call, never an automated one.
#
# Safety, by design:
#  - its own VPC (zs-testlab) with no default rules, so the default network's "allow SSH from
#    anywhere" rule never applies to it;
#  - only the test sshd's port (2240) is open, and only to Test Lab's published IPv4 blocks for
#    physical devices (firebase.google.com/docs/test-lab/overview, "IP blocks"; the list changes
#    about once a year: compare with `gcloud beta firebase test ip-blocks list` and run `ranges`
#    after editing TEST_LAB_IPV4 below); those blocks are
#    shared by every Test Lab customer, so this narrows who can reach it, it does not make it private;
#  - admin SSH (port 22) only through Identity-Aware Proxy (35.235.240.0/20), never the internet;
#  - no service account and no API scopes on the VM: it can reach nothing in the project;
#  - test account only, with a NEW random password each `up` (purge then start), purged again at
#    `down`; nothing of the developer's (keys, hosts, data) is ever put on it;
#  - running only for a run: `down` stops it (a stopped VM costs only its disk).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROJECT="${TEST_LAB_PROJECT:-}"
REGION="${TEST_LAB_VM_REGION:-us-central1}"
ZONE="${TEST_LAB_VM_ZONE:-us-central1-a}"
NETWORK=zs-testlab
SUBNET=zs-testlab-subnet
SUBNET_RANGE=10.90.0.0/24
VM=zs-testlab-servers
TAG=zs-testlab-servers
# xrdp with an Xfce desktop wants more than e2-small's 2 GB.
MACHINE=e2-medium
DISK_GB=20

# Test Lab, physical devices (and Arm virtual devices), IPv4, as published 2026-11-11 (blocks that
# sit inside a larger one listed here are left out: 70.32.128.48/28, 70.32.150.192/27, 108.177.6.0/27).
TEST_LAB_IPV4=(
  70.32.128.0/19
  108.177.6.0/23
  108.177.18.192/26
  108.177.24.160/27
  108.177.25.128/27
  108.177.26.128/26
  108.177.29.0/27
  108.177.29.64/27
  108.177.29.192/26
  108.177.31.160/27
  172.217.120.64/26
  172.217.120.128/26
  199.36.156.8/29
  199.36.156.16/28
  209.85.131.0/27
)
IAP_RANGE=35.235.240.0/20
# Only the test sshd: screen_run_test reaches the VNC socket through SSH, as the app does by
# default. Add tcp:15932 (VeNCrypt, TLS) or tcp:13389 (RDP, TLS) only for a device test that
# connects directly; never 15931 (plain VncAuth).
TEST_PORTS=tcp:2240

go=no
args=()
for a in "$@"; do
  if [ "$a" = "--go" ]; then go=yes; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

die() { echo "test_servers_vm.sh: $*" >&2; exit 2; }
[ -n "$PROJECT" ] || die "set TEST_LAB_PROJECT to the project id"

g() {
  if [ "$go" = yes ]; then
    gcloud --project="$PROJECT" "$@"
  else
    printf '  gcloud --project=%q' "$PROJECT"
    printf ' %q' "$@"
    printf '\n'
  fi
}

on_vm() { g compute ssh "$VM" --zone="$ZONE" --tunnel-through-iap --command="$1"; }

[ "$go" = yes ] || echo "Printed only (add --go to run them; they change billed resources):"

case "${1:-}" in
  network)
    g compute networks create "$NETWORK" --subnet-mode=custom
    g compute networks subnets create "$SUBNET" --network="$NETWORK" --region="$REGION" \
      --range="$SUBNET_RANGE"
    (IFS=,; g compute firewall-rules create zs-testlab-from-test-lab --network="$NETWORK" \
      --direction=INGRESS --action=ALLOW --rules="$TEST_PORTS" \
      --source-ranges="${TEST_LAB_IPV4[*]}" --target-tags="$TAG" \
      --description="ZestSSH test servers: Firebase Test Lab physical devices only")
    g compute firewall-rules create zs-testlab-iap-ssh --network="$NETWORK" \
      --direction=INGRESS --action=ALLOW --rules=tcp:22 \
      --source-ranges="$IAP_RANGE" --target-tags="$TAG" \
      --description="Admin SSH through Identity-Aware Proxy only"
    ;;

  ranges)
    (IFS=,; g compute firewall-rules update zs-testlab-from-test-lab       --source-ranges="${TEST_LAB_IPV4[*]}")
    ;;

  create)
    g compute instances create "$VM" --zone="$ZONE" --machine-type="$MACHINE" \
      --network-interface="subnet=$SUBNET,stack-type=IPV4_ONLY" \
      --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
      --boot-disk-size="${DISK_GB}GB" --boot-disk-type=pd-balanced \
      --no-service-account --no-scopes \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
      --tags="$TAG" --labels=purpose=zestssh-test-lab \
      --metadata=enable-oslogin=TRUE
    # The server script, as in the repo (it installs its packages on its first start).
    g compute scp "$ROOT/tool/remote_screens_test_servers.sh" "$VM":~/remote_screens_test_servers.sh \
      --zone="$ZONE" --tunnel-through-iap
    g compute instances stop "$VM" --zone="$ZONE"
    ;;

  up)
    g compute instances start "$VM" --zone="$ZONE"
    # A new account and password every run: purge drops the last one, start makes a new one.
    on_vm 'sudo bash ~/remote_screens_test_servers.sh purge >/dev/null 2>&1 || true; sudo bash ~/remote_screens_test_servers.sh start vencrypt && sudo bash ~/remote_screens_test_servers.sh status'
    ;;

  settings)
    # The run's dart-defines (ZS_HOST, ZS_SSH_PORT, ZS_USER, ZS_PASSWORD, ZS_VNC_PASSWORD,
    # ZS_SOCKET, ZS_RUN) for `run.sh build-instr integration_test/screen_run_test.dart <file>`.
    # Written to a private folder, never printed; delete it after the build (`down` does).
    out="${TEST_LAB_SETTINGS:-$HOME/.zestssh-test-lab/screen_run.json}"
    if [ "$go" != yes ]; then
      echo "  (reads the VM's external address and /etc/zestscreens/env over IAP SSH into $out, mode 0600)"
      exit 0
    fi
    mkdir -p "$(dirname "$out")"
    chmod 700 "$(dirname "$out")"
    ip="$(gcloud --project="$PROJECT" compute instances describe "$VM" --zone="$ZONE" \
      --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
    [ -n "$ip" ] || die "the VM has no external address: is it up?"
    umask 077
    gcloud --project="$PROJECT" compute ssh "$VM" --zone="$ZONE" --tunnel-through-iap \
      --command='sudo cat /etc/zestscreens/env' 2> /dev/null |
      python -I -c '
import json, sys
host = sys.argv[1]
env = dict(l.strip().split("=", 1) for l in sys.stdin if "=" in l)
print(json.dumps({"ZS_HOST": host, "ZS_SSH_PORT": "2240", "ZS_USER": env["ZS_USER"],
                  "ZS_PASSWORD": env["ZS_PASSWORD"], "ZS_VNC_PASSWORD": env["ZS_VNC_PASSWORD"],
                  "ZS_SOCKET": "/run/zestscreens/vnc.sock", "ZS_RUN": "test-lab"}))
' "$ip" > "$out"
    echo "settings written to $out (not shown)"
    ;;

  down)
    on_vm 'sudo bash ~/remote_screens_test_servers.sh purge'
    g compute instances stop "$VM" --zone="$ZONE"
    if [ "$go" = yes ]; then
      rm -f "${TEST_LAB_SETTINGS:-$HOME/.zestssh-test-lab/screen_run.json}"
    fi
    ;;

  delete)
    g compute instances delete "$VM" --zone="$ZONE" --quiet
    g compute firewall-rules delete zs-testlab-from-test-lab zs-testlab-iap-ssh --quiet
    g compute networks subnets delete "$SUBNET" --region="$REGION" --quiet
    g compute networks delete "$NETWORK" --quiet
    ;;

  *)
    sed -n '2,16p' "${BASH_SOURCE[0]}"
    exit 2
    ;;
esac
