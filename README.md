# EV Hotel Map (Rakuten API)

EV充電器付きホテルを地図上で検索・閲覧するFlutterアプリです。  
CSVデータをベースに、楽天トラベルAPIの補足情報（画像/価格/レビュー）を表示します。

## セットアップ

1. 依存関係を取得します。

```bash
flutter pub get
```

2. ローカル実行時は `--dart-define` でキーを渡します。

```bash
flutter run \
  --dart-define=GOOGLE_MAPS_API_KEY=YOUR_GOOGLE_API_KEY \
  --dart-define=RAKUTEN_APP_ID=YOUR_RAKUTEN_APP_ID \
  --dart-define=CLOUDFLARE_PROXY_URL=YOUR_CLOUDFLARE_URL
```

3. Webローカル確認時は `web/index.html` の `YOUR_GOOGLE_MAPS_WEB_API_KEY` を設定してください。

## GitHub Pages（Secrets + Actions）

1. GitHub Repository Secrets に以下を追加します。
- `GOOGLE_MAPS_WEB_API_KEY`
- `GOOGLE_MAPS_API_KEY`
- `RAKUTEN_APP_ID`
- `CLOUDFLARE_PROXY_URL`

2. Repository Settings > Pages で `Build and deployment` の Source を `GitHub Actions` にします。

3. `main` に push すると `.github/workflows/deploy-pages.yml` が自動でWebをビルドして公開します（`docs/` は不要です）。

## 要件定義

- `REQUIREMENTS.md`（必要に応じて作成）
