# Cloudflare Worker Proxy

楽天APIをWebから呼ぶためのCORS対応プロキシです。

## 使い方（最短）
1. CloudflareのWorkersに `worker.js` をデプロイ
2. デプロイURLを `CLOUDFLARE_PROXY_URL` に設定

## 例
```
https://your-worker-name.your-account.workers.dev
```

## 注意
- `url` クエリは `https://app.rakuten.co.jp` のみ許可しています。
- それ以外は `403 Forbidden` を返します。
