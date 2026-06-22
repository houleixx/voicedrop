#!/usr/bin/env python3
"""On-demand WeChat draft push for ONE already-mined article document.

Dispatched by the app when the user taps 发布微信公众号草稿 (Cloudflare route
POST /files/api/wechat/<articleKey> → publish-wechat.yml). Unlike the miner, this
never transcribes or calls the LLM — it just (re)pushes the WeChat draft(s) for an
existing articles/<stem>.json, routed through the whitelisted Tokyo proxy. An
article already carrying a wechatMediaId is updated in place; a fresh one is
created. Idempotent: tap twice and the same drafts are simply updated again.

Env:
  FILES_TOKEN    admin token for jianshuo.dev/files
  WECHAT_PROXY   http://user:pass@66.42.45.128:8888 (whitelisted egress)
  ARTICLE_KEY    full R2 key, users/<sub>/articles/<stem>.json
"""
import os, json, urllib.parse, sys
import mine


def main():
    article_key = os.environ.get("ARTICLE_KEY", "").strip()
    if "/articles/" not in article_key or not article_key.endswith(".json"):
        sys.exit(f"bad ARTICLE_KEY: {article_key!r}")
    mine.log(f"publish-wechat: {article_key}")

    # Manual publish ignores the 自动推草稿 toggle — the user asked for it explicitly.
    cfg = mine.fetch_wechat_config(article_key, require_enabled=False)
    if not cfg:
        sys.exit("WeChat not configured (missing appid/secret) for this user")

    raw = mine._req("GET", f"{mine.BASE}/download/{urllib.parse.quote(article_key)}",
                    headers={"Authorization": f"Bearer {mine.TOKEN}"})
    art = json.loads(raw)
    if not art.get("articles"):
        # v1 fallback: a single title/body doc.
        if art.get("body"):
            art["articles"] = [{"title": art.get("title") or "(无题)", "body": art["body"]}]
        else:
            sys.exit("no articles in doc")

    wx_token = mine.wechat_access_token(cfg["appid"], cfg["secret"])
    thumb_id = mine.ensure_wechat_thumb(wx_token, cfg, article_key)
    created, updated = mine.sync_wechat_drafts(wx_token, art, thumb_id)

    # Persist the (possibly new) wechatMediaIds so a re-tap updates, not dupes.
    mine.api_put(article_key, json.dumps(art, ensure_ascii=False).encode(),
                 "application/json")
    mine.log(f"DONE publish-wechat: {created} created · {updated} updated")


if __name__ == "__main__":
    main()
