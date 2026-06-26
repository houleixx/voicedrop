# WeChat publish relay (Tokyo VPS)

A tiny always-on HTTP service that publishes 公众号 drafts **synchronously** from the
VPS whose IP (`66.42.45.128`) is whitelisted on the WeChat account. The Cloudflare
Function (`jianshuo.dev/files/api/wechat/...`) calls it and awaits the real result, so
the app shows success / the actual `errcode` instead of the old fire-and-forget
GitHub-Action dispatch.

- **Dumb relay:** holds no R2 / `FILES_TOKEN`. Gets `appid/secret` + the article per
  request (in memory, never logged), talks to WeChat, returns the mutated article
  (with `wechatMediaId`) + final thumb id. The Function persists to R2.
- **Reachable only via a Cloudflare Tunnel** (`wechat-pub.jianshuo.dev` →
  `127.0.0.1:8848`). No open inbound port. Every request needs
  `X-Relay-Secret: $WECHAT_RELAY_SECRET` (constant-time check).
- **Self-contained** `relay_server.py` (stdlib only) — the WeChat + cover helpers it
  once `import`ed from `mine.py` are now inlined; `mine.py` is gone. `tinyproxy` on
  this box is unrelated and stays as-is.

## First-time setup

From the dev box (repo root):

```bash
VPS_SSH=root@66.42.45.128 ./mining/deploy_relay.sh   # copies code to /opt/wechat-relay
```

Then on the VPS (one-time):

```bash
WECHAT_RELAY_SECRET=<paste the same value you set in Cloudflare Pages> \
  bash /opt/wechat-relay/provision.sh
```

`provision.sh` installs+starts the `wechat-relay` systemd unit and prints the
remaining `cloudflared` tunnel steps (install → login → create → route dns → config →
service install). The shared secret in `/opt/wechat-relay/relay.env` MUST equal the
Cloudflare Pages secret `WECHAT_RELAY_SECRET`.

## Updating the code later

```bash
VPS_SSH=root@66.42.45.128 ./mining/deploy_relay.sh   # rsync + restart + health check
```

## Health / debugging

```bash
curl https://wechat-pub.jianshuo.dev/health     # {"ok":true}
ssh root@66.42.45.128 'systemctl status wechat-relay; journalctl -u wechat-relay -n 50'
```
