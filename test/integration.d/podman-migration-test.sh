#!/bin/bash

# Real legacy Docker fixtures in a disposable ISO guest. Never run this script
# directly on a development desktop: the harness owns the guest and its disk.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
base_image_ready || { echo "Run this through ./test/integration" >&2; exit 1; }
start_vm_from_base
wait_for_ssh "$BOOT_TIMEOUT"
ssh_sudo "printf '%s\n' '$GUEST_USER ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/90-container-test; chmod 440 /etc/sudoers.d/90-container-test"

# Reproduce both legacy ufw-docker blocks from the recorded installed system.
# Installing Docker alone on a fresh Podman ISO does not recreate this state.
python3 - "$ROOT/manifests/fresh-4.json" <<'PY' | ssh_guest 'cat >/tmp/legacy-firewall.json'
import json
import sys

with open(sys.argv[1]) as source:
    files = json.load(source)['files']['system_config']
json.dump({path: files[path]['text'] for path in ('/etc/ufw/after.rules', '/etc/ufw/after6.rules')}, sys.stdout)
PY

ssh_guest 'cat >/tmp/podman-migration-fixture.sh' <<'GUEST'
#!/bin/bash
set -euo pipefail
[[ $(hostname) == "omarchy-test" ]] || exit 1
export OMARCHY_PATH=/usr/share/omarchy
export XDG_RUNTIME_DIR=/run/user/$(id -u)
unset DOCKER_HOST
# Fresh offline installs intentionally omit synchronized repository databases.
# Refresh only this disposable fixture's indexes; keep the built runtime pinned.
sudo pacman -Sy --noconfirm
omarchy-pkg-drop podman-docker
omarchy-pkg-add docker
# ONCE must block migration even when it has not created any containers yet.
omarchy-pkg-add once-bin
if bash -euo pipefail "$OMARCHY_PATH/migrations/1788886195.sh" >/tmp/once-preflight.log 2>&1; then
  echo 'ONCE incorrectly passed Podman migration' >&2; exit 1
fi
grep -q 'ONCE is installed' /tmp/once-preflight.log
[[ $(pacman -Qq docker) == "docker" ]]
pacman -Q once-bin
omarchy-pkg-drop once-bin

# Retain transaction coverage with a harmless CLI-dependent package instead
# of claiming that the ONCE application's Docker API works through the shim.
dependency_fixture=$(mktemp -d)
cat >"$dependency_fixture/.PKGINFO" <<'PKGINFO'
pkgname = omarchy-test-docker-client
pkgver = 1-1
pkgdesc = Disposable Docker CLI dependency fixture
arch = any
depend = docker
PKGINFO
bsdtar -czf "$dependency_fixture/client.pkg.tar.gz" -C "$dependency_fixture" .PKGINFO
sudo pacman -U --noconfirm "$dependency_fixture/client.pkg.tar.gz"
rm -r "$dependency_fixture"
if sudo pacman -Rns --noconfirm docker >/tmp/docker-dependency.log 2>&1; then
  echo 'Docker removal unexpectedly ignored the CLI dependency' >&2; exit 1
fi
grep -q 'required by omarchy-test-docker-client' /tmp/docker-dependency.log
sudo python3 - <<'PY'
import json
from pathlib import Path

for path, contents in json.loads(Path('/tmp/legacy-firewall.json').read_text()).items():
    Path(path).write_text(contents)
PY
sudo ufw reload
# Consume the complete dump: grep -q closes early and makes ip6tables-save
# fail with SIGPIPE under pipefail when the rules exceed the pipe buffer.
sudo ip6tables-save | grep DOCKER-USER >/dev/null
sudo systemctl start docker.socket
sudo docker run -d --name redis --restart unless-stopped \
  -p 127.0.0.1:6379:6379 \
  --health-cmd 'redis-cli ping' --health-interval 1s --health-timeout 1s --health-retries 5 \
  docker.io/library/redis:7
sudo docker run -d --name postgres16 --restart unless-stopped \
  -p 127.0.0.1:5432:5432 \
  -e POSTGRES_PASSWORD=fixture-only docker.io/library/postgres:16
for attempt in {1..60}; do
  sudo docker exec postgres16 pg_isready -U postgres && break
  sleep 1
done
sudo docker exec postgres16 psql -U postgres -c "CREATE TABLE migration_proof (value text); INSERT INTO migration_proof VALUES ('preserved');"
sudo docker exec redis redis-cli SET migration-proof preserved
sudo docker exec redis sh -c 'echo writable-layer >/migration-proof'
sudo docker stop postgres16

# Stock installers rely on the image's anonymous VOLUME.
volume_name=$(sudo docker inspect postgres16 --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')
volume=$(sudo docker volume inspect "$volume_name" --format '{{.Mountpoint}}')
sudo python3 - "$volume" <<'PY'
from pathlib import Path
import os,sys
p=Path(sys.argv[1]);p.chmod(0o775)
f=p/'metadata-proof';f.write_bytes(b'preserved metadata\n');f.chmod(0o640)
os.chown(f,1000,1000);os.setxattr(f,'user.migration',b'preserved')
os.link(f,p/'hardlink-proof');(p/'symlink-proof').symlink_to('metadata-proof')
os.utime(f,ns=(1720000000123456789,1720000000123456789))
PY
sudo setfacl -m u:1234:r "$volume/metadata-proof"
sudo python3 - "$volume/metadata-proof" <<'PY'
import json, os, stat, sys
from pathlib import Path
path = Path(sys.argv[1])
Path('/tmp/source-volume-metadata.json').write_text(json.dumps({
    'mode': stat.S_IMODE(path.stat().st_mode),
    'acl': os.getxattr(path, 'system.posix_acl_access').hex(),
}))
PY

# A custom image/name, private named volume, non-root application user and
# explicit resource/confinement settings should migrate without gaining access.
sudo docker volume create --label fixture=secure-migration project-state
sudo docker run --rm -v project-state:/data docker.io/library/alpine:3 \
  sh -c 'chown 1000:1000 /data; chmod 0750 /data'
sudo docker run -d --name project-worker --restart unless-stopped \
  --user 1000:1000 --cap-drop NET_RAW --security-opt no-new-privileges \
  --cpus 0.5 --memory 128m --memory-swap 256m --pids-limit 64 --shm-size 128m \
  -e WORKER_MESSAGE=retained -v project-state:/data docker.io/library/alpine:3 \
  sh -c 'echo preserved >/data/proof; trap "exit 0" TERM; while :; do sleep 1 & wait $!; done'
sudo docker exec project-worker sh -c 'grep -Eq "^CapEff:[[:space:]]+0+$" /proc/1/status'
sudo docker inspect project-worker --format '{{json .HostConfig}}' >/tmp/source-worker-limits.json

# Review-required records are never started, even in this disposable fixture.
# Both must be reported while all ordinary source workloads stay running.
sudo docker create --name review-required --privileged docker.io/library/alpine:3 sleep infinity
sudo docker create --name device-required --device /dev/null docker.io/library/alpine:3 sleep infinity
if bash -euo pipefail "$OMARCHY_PATH/migrations/1788886195.sh" >/tmp/preflight.log 2>&1; then
  echo 'Unsupported container incorrectly passed migration' >&2; exit 1
fi
cat /tmp/preflight.log
grep -q review-required /tmp/preflight.log
grep -q device-required /tmp/preflight.log
[[ $(sudo docker inspect redis --format '{{.State.Running}}') == "true" ]]
[[ $(sudo docker inspect project-worker --format '{{.State.Running}}') == "true" ]]
! podman container exists redis
! podman container exists project-worker
sudo docker rm review-required device-required

# Complete one transfer while Docker is still needed by the remaining batch.
# Its old always policy must not revive a stale source after a daemon restart.
# Uppercase and repeated dots are valid container names, but not image paths.
sudo docker run -d --name Always..Worker --restart always docker.io/library/alpine:3 \
  sh -c 'echo original >/retry-proof; trap "exit 0" TERM; while :; do sleep 1 & wait $!; done'
retry_source=$(sudo docker inspect Always..Worker --format '{{.Id}}')
python3 "$OMARCHY_PATH/default/podman/migrate-databases.py" Always..Worker
[[ $(sudo docker inspect Always..Worker --format '{{.HostConfig.RestartPolicy.Name}}') == "no" ]]
[[ $(podman inspect Always..Worker --format '{{.HostConfig.RestartPolicy.Name}}') == "always" ]]
sudo systemctl restart docker
[[ $(sudo docker inspect Always..Worker --format '{{.State.Running}}') == "false" ]]
python3 "$OMARCHY_PATH/default/podman/migrate-databases.py" Always..Worker

# Explicitly resuming the recovery copy invalidates its receipt, even when it
# is stopped again. Never silently choose the stale target after new writes.
sudo docker start Always..Worker
sudo docker exec Always..Worker sh -c 'echo changed >/retry-proof'
for source_state in running stopped; do
  if [[ $source_state == "stopped" ]]; then sudo docker stop Always..Worker; fi
  if python3 "$OMARCHY_PATH/default/podman/migrate-databases.py" Always..Worker >/tmp/retry.log 2>&1; then
    echo 'Restarted Docker source incorrectly reused its old receipt' >&2; exit 1
  fi
  grep -q 'no completed transfer' /tmp/retry.log
  [[ $(podman exec Always..Worker cat /retry-proof) == "original" ]]
done
# These conflicting copies are disposable test data; production leaves both
# for review. Remove this fixture so the ordinary batch can proceed below.
sudo docker rm Always..Worker
podman rm -f Always..Worker
rm "$HOME/.local/state/omarchy/podman-migration/$retry_source"
printf 'INTERRUPTED BATCH AND SOURCE RESTART SAFEGUARDS VERIFIED\n'

# Match sudo-run upgrades, which do not pass the graphical session variables.
sudo -u "$USER" -H env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS \
  OMARCHY_PATH="$OMARCHY_PATH" PATH="$PATH" CONTAINER_HOST=unix:///tmp/do-not-contact-podman.sock \
  bash -euo pipefail "$OMARCHY_PATH/migrations/1788886195.sh"
[[ $(pacman -Qq docker) == "podman-docker" ]]
pacman -Q omarchy-test-docker-client
[[ -z $(pacman -T docker) ]]
sudo python3 - <<'PY'
import json
from pathlib import Path

for path, original in json.loads(Path('/tmp/legacy-firewall.json').read_text()).items():
    assert '# BEGIN UFW AND DOCKER' not in Path(path).read_text()
    assert Path(path + '.before-podman').read_text() == original
PY
[[ $(podman exec redis redis-cli GET migration-proof) == "preserved" ]]
[[ $(podman exec redis cat /migration-proof) == "writable-layer" ]]
[[ $(podman inspect postgres16 --format '{{.State.Running}}') == "false" ]]
[[ $(podman inspect redis --format '{{.HostConfig.PidsLimit}}') == "-1" ]]
for attempt in {1..30}; do
  [[ $(podman inspect redis --format '{{.State.Health.Status}}') == "healthy" ]] && break
  sleep 1
done
[[ $(podman inspect redis --format '{{.State.Health.Status}}') == "healthy" ]]
[[ $(podman exec project-worker cat /data/proof) == "preserved" ]]
[[ $(podman exec project-worker printenv WORKER_MESSAGE) == "retained" ]]
[[ $(podman exec project-worker id -u) == "1000" ]]
podman exec project-worker sh -ec 'grep -Eq "^NoNewPrivs:[[:space:]]+1$" /proc/1/status; grep -Eq "^Seccomp:[[:space:]]+2$" /proc/1/status; for field in CapBnd CapEff CapAmb; do grep -Eq "^$field:[[:space:]]+0+$" /proc/1/status; done'
[[ $(podman inspect project-worker --format '{{.HostConfig.Privileged}}') == "false" ]]
podman inspect project-worker >/tmp/target-worker-inspect.json
python3 - <<'PY'
import json, math
from pathlib import Path
source = json.loads(Path('/tmp/source-worker-limits.json').read_text())
target = json.loads(Path('/tmp/target-worker-inspect.json').read_text())[0]['HostConfig']
for key in ('Memory', 'MemorySwap', 'PidsLimit', 'ShmSize'):
    assert target[key] == source[key], (key, source[key], target[key])
def cpus(config):
    if config.get('NanoCpus', 0):
        return config['NanoCpus'] / 1_000_000_000
    return config['CpuQuota'] / config['CpuPeriod']
assert math.isclose(cpus(target), cpus(source)), (source, target)
PY
[[ $(podman volume inspect project-state --format '{{index .Labels "fixture"}}') == "secure-migration" ]]
worker_volume=$(podman volume inspect project-state --format '{{.Mountpoint}}')
[[ $(podman unshare stat -c '%u:%g:%a' "$worker_volume") == "1000:1000:750" ]]
[[ -z $(sudo podman ps -aq) ]]
printf 'CUSTOM ROOTLESS CONFINEMENT VERIFIED\n'
target=$(podman volume inspect "omarchy-migrated-$volume_name" --format '{{.Mountpoint}}')
podman unshare python3 - "$target" <<'PY'
import json, os, stat, sys
from pathlib import Path
p=Path(sys.argv[1]);f=p/'metadata-proof';s=f.stat()
source = json.loads(Path('/tmp/source-volume-metadata.json').read_text())
assert stat.S_IMODE(s.st_mode) == source['mode'] == 0o640
assert os.getxattr(f, 'system.posix_acl_access').hex() == source['acl']
assert p.stat().st_mode & 0o777==0o775
assert s.st_uid==1000 and s.st_gid==1000
assert s.st_mtime_ns==1720000000123456789
assert os.getxattr(f,'user.migration')==b'preserved'
assert s.st_ino==(p/'hardlink-proof').stat().st_ino
assert (p/'symlink-proof').readlink()==Path('metadata-proof')
PY
podman start postgres16
for attempt in {1..60}; do
  podman exec postgres16 pg_isready -U postgres && break
  sleep 1
done
[[ $(podman exec postgres16 psql -U postgres -Atc 'SELECT value FROM migration_proof') == "preserved" ]]
podman stop postgres16
# Retrying after Docker removal must preserve both destinations and their data.
bash -euo pipefail "$OMARCHY_PATH/migrations/1788886195.sh"
sudo test -d /var/lib/docker
printf 'LIVE MIGRATION VERIFIED\n'
GUEST
ssh_guest 'bash /tmp/podman-migration-fixture.sh' >"$RUN_DIR/migration.log" 2>&1 || {
  cat "$RUN_DIR/migration.log"; capture_console failure-podman-migration; exit 1;
}
capture_console success-podman-migration
old_boot=$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')
ssh_sudo 'systemctl reboot' || true
sleep 10
wait_for_ssh "$BOOT_TIMEOUT"
check "guest rebooted" ssh_guest "test \"\$(cat /proc/sys/kernel/random/boot_id)\" != '$old_boot'"
# SSH login starts the user manager; its container restart service and Redis
# readiness can finish later. Wait for the actual data response, with a bound.
check "running Redis resumed with data" ssh_guest 'for attempt in {1..30}; do [[ $(podman exec redis redis-cli GET migration-proof 2>/dev/null) == preserved ]] && exit 0; sleep 1; done; exit 1'
check "deliberately stopped PostgreSQL remains stopped" ssh_guest "test \"\$(podman inspect postgres16 --format '{{.State.Running}}')\" = false"
check "custom worker resumes as its original non-root user" ssh_guest "test \"\$(podman exec project-worker id -u)\" = 1000"
check "Docker bridge and IPv4/IPv6 firewall chains are gone" ssh_sudo '! ip link show docker0 2>/dev/null && ! iptables-save | grep -q DOCKER && ! ip6tables-save | grep -q DOCKER'
check "rootless API responds after reboot" ssh_guest 'curl -fsS --max-time 10 --unix-socket "$XDG_RUNTIME_DIR/podman/podman.sock" http://localhost/_ping'
capture_console success-podman-migration-reboot
finish
