#!/usr/bin/env bash
# Push the relay code to the Tokyo VPS and restart it.
#   VPS_SSH=root@66.42.45.128 ./mining/deploy_relay.sh
# (Run mining/vps/provision.sh once on the box first — see mining/vps/README.md.)
set -euo pipefail
VPS_SSH="${VPS_SSH:-root@66.42.45.128}"
DEST="/opt/wechat-relay"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "→ ensure $DEST on $VPS_SSH"
ssh "$VPS_SSH" "mkdir -p $DEST"
echo "→ rsync relay files"
rsync -avz \
  "$HERE/mine.py" \
  "$HERE/relay_server.py" \
  "$HERE/vps/wechat-relay.service" \
  "$HERE/vps/provision.sh" \
  "$VPS_SSH:$DEST/"
echo "→ restart + health check"
ssh "$VPS_SSH" 'if systemctl list-unit-files | grep -q "^wechat-relay.service"; then
    systemctl restart wechat-relay && sleep 1 && systemctl is-active wechat-relay && curl -fsS http://127.0.0.1:8848/health && echo;
  else
    echo "wechat-relay not installed yet — first run: WECHAT_RELAY_SECRET=<secret> bash /opt/wechat-relay/provision.sh";
  fi'
echo "✓ files synced"
