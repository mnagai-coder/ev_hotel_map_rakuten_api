# EV Hotel Map (Rakuten API)

EV充電器付きホテルを地図上で検索・閲覧するFlutterアプリです。  
CSVデータをベースに、楽天トラベルAPIの補足情報（画像/価格/レビュー）を表示します。

## セットアップ

1. `lib/main.dart` の以下を設定してください。
- `googleMapsApiKey`
- `rakutenAppId`
- `myProxyUrl`（Cloudflare Workers URL。末尾 `/` なし）

2. Web利用時は `web/index.html` の以下を設定してください。
- `YOUR_GOOGLE_MAPS_WEB_API_KEY`

3. 依存関係を取得して起動します。

```bash
flutter pub get
flutter run
```

## 公開前チェック

- APIキーやIDをソースに直書きしたまま公開しない
- `myProxyUrl` 未設定だと外部API連携は動作しない
- GitHub Pagesで公開する場合は `flutter build web --output docs` で成果物を作成できる

## 要件定義

- `REQUIREMENTS.md`（必要に応じて作成）
