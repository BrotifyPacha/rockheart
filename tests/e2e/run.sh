#!/usr/bin/env bash
# E2E: плейбук на systemd-контейнере, затем клиент без доступа в интернет ходит наружу только через туннель
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=$(awk -F'"' '/^xray_version:/ {print $2}' "$ROOT/roles/xray/defaults/main.yml")
TARGET=www.microsoft.com
PROBE_URL=https://www.cloudflare.com/cdn-cgi/trace

log() { printf '\n==> %s\n' "$*"; }

cleanup() {
  docker rm -f rh-server rh-client >/dev/null 2>&1 || true
  docker network rm rh-e2e-pub rh-e2e-int >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

log "Building images (xray $VERSION)"
docker build -q -f "$ROOT/tests/e2e/Dockerfile.server" -t rockheart-e2e-server "$ROOT" >/dev/null
docker build -q -f "$ROOT/tests/e2e/Dockerfile.client" --build-arg "XRAY_VERSION=$VERSION" -t rockheart-e2e-client "$ROOT" >/dev/null

log "Starting containers"
docker network create rh-e2e-pub >/dev/null
docker network create --internal rh-e2e-int >/dev/null
docker run -d --name rh-server --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --network rh-e2e-pub rockheart-e2e-server >/dev/null
docker network connect --alias rh-server rh-e2e-int rh-server
docker run -d --name rh-client --network rh-e2e-int rockheart-e2e-client sleep infinity >/dev/null
docker exec rh-server systemctl is-system-running --wait >/dev/null || true

# Только файлы репозитория, без локальных credentials/ и clients/ (они в .gitignore)
git -C "$ROOT" ls-files -co --exclude-standard \
  | COPYFILE_DISABLE=1 tar -C "$ROOT" --no-xattrs -cf - -T - \
  | docker exec -i rh-server sh -c 'mkdir -p /src && tar -xf - -C /src'

log "Running playbook"
docker exec -w /src rh-server ansible-playbook -i tests/e2e/inventory.yml site.yml

log "Running playbook again (idempotency)"
second=$(docker exec -w /src rh-server ansible-playbook -i tests/e2e/inventory.yml site.yml)
echo "$second" | tail -n 4
echo "$second" | grep -Eq 'e2e +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0' \
  || { echo "FAIL: second run is not idempotent"; exit 1; }

docker exec rh-server systemctl is-active xray >/dev/null || { echo "FAIL: xray is not active"; exit 1; }
docker exec rh-server test -s /src/clients/e2e/alice/xhttp.png || { echo "FAIL: QR code missing"; exit 1; }

log "Client has no direct internet"
if docker exec rh-client curl -sS -m 5 -o /dev/null "$PROBE_URL" 2>/dev/null; then
  echo "FAIL: client reaches the internet directly, test is meaningless"; exit 1
fi

for kind in xhttp vision; do
  log "Tunnel via $kind"
  link=$(docker exec rh-server cat "/src/clients/e2e/alice/$kind.txt")
  echo "$link" | sed -E 's#vless://[^@]+@#vless://***@#; s#(pbk|sid)=[^&]+#\1=***#g'
  docker exec -e LINK="$link" rh-client sh -c 'link2json.py "$LINK" > /tmp/client.json && xray run -test -c /tmp/client.json >/dev/null'
  docker exec -d rh-client sh -c 'xray run -c /tmp/client.json > /tmp/xray.log 2>&1'
  sleep 2
  if ! docker exec rh-client curl -sS -m 20 --socks5-hostname 127.0.0.1:10808 "$PROBE_URL" | grep -E '^(ip|tls|http)='; then
    docker exec rh-client cat /tmp/xray.log
    echo "FAIL: no traffic through $kind"; exit 1
  fi
  docker exec rh-client pkill xray
  sleep 1
done

log "Camouflage: unauthenticated TLS to the server gets the real $TARGET"
server_ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "rh-e2e-int").IPAddress}}' rh-server)
docker exec rh-client curl -sS -m 20 -o /dev/null --resolve "$TARGET:443:$server_ip" \
  -w 'HTTP %{http_code}, cert verify result %{ssl_verify_result}\n' "https://$TARGET/"

log "PASS"
