#!/usr/bin/env bash
# One-time setup of the WeChat publish relay on the Tokyo VPS. Run as root ON the VPS,
# AFTER the code is in /opt/wechat-relay (use mining/deploy_relay.sh from the dev box,
# or scp relay_server.py wechat-relay.service provision.sh there).
#
#   WECHAT_RELAY_SECRET=<same-as-Cloudflare-Pages> bash /opt/wechat-relay/provision.sh
#
# Leaves tinyproxy untouched. Exposes nothing on a public port — inbound is via the
# Cloudflare Tunnel set up in the printed next-steps.
set -euo pipefail
DEST=/opt/wechat-relay
[ -f "$DEST/relay_server.py" ] || { echo "ERROR: copy relay_server.py to $DEST first"; exit 1; }

# 1. Shared secret (relay.env). Reuse if present; else take $WECHAT_RELAY_SECRET or generate.
if [ ! -f "$DEST/relay.env" ]; then
  SECRET="${WECHAT_RELAY_SECRET:-$(openssl rand -hex 32)}"
  umask 077
  printf 'WECHAT_RELAY_SECRET=%s\n' "$SECRET" > "$DEST/relay.env"
  echo "→ wrote $DEST/relay.env — set the SAME value as Cloudflare Pages secret WECHAT_RELAY_SECRET:"
  echo "    $SECRET"
fi
chmod 600 "$DEST/relay.env"

# 2. systemd service
cp "$DEST/wechat-relay.service" /etc/systemd/system/wechat-relay.service
systemctl daemon-reload
systemctl enable --now wechat-relay
sleep 1
systemctl is-active wechat-relay >/dev/null && echo "→ wechat-relay active"
curl -fsS http://127.0.0.1:8848/health && echo "  ✓ relay healthy on 127.0.0.1:8848"

cat <<'EOF'

── Next: expose it via a Cloudflare Tunnel (no open inbound port) ──────────────
On THIS box:
  # 1. install cloudflared (Debian/Ubuntu):
  curl -fsSL https://pkg.cloudflare.com/cloudflared/install.sh | sudo bash
  # 2. authenticate (opens a browser link; choose the jianshuo.dev zone):
  cloudflared tunnel login
  # 3. create the tunnel + route the hostname:
  cloudflared tunnel create wechat-pub
  cloudflared tunnel route dns wechat-pub wechat-pub.jianshuo.dev
  # 4. write /root/.cloudflared/config.yml  (fill in the UUID printed by `create`):
  #   tunnel: <TUNNEL-UUID>
  #   credentials-file: /root/.cloudflared/<TUNNEL-UUID>.json
  #   ingress:
  #     - hostname: wechat-pub.jianshuo.dev
  #       service: http://127.0.0.1:8848
  #     - service: http_status:404
  # 5. run it as a service:
  cloudflared service install
  systemctl enable --now cloudflared && systemctl restart cloudflared

Verify from anywhere:  curl https://wechat-pub.jianshuo.dev/health  → {"ok":true}
────────────────────────────────────────────────────────────────────────────────
EOF
