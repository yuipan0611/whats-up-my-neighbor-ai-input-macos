<p align="center">
  <a href="https://nekonode.cloud">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/media/brand/app-icon.svg">
      <img src="docs/media/brand/neko-round-face.svg" alt="What's up my neighbor 黒猫ロゴ" width="150">
    </picture>
  </a>
</p>

<h1 align="center">What's up my neighbor</h1>

<p align="center">
  <b>思いついたら、声に出すだけ。</b><br>
  Mac のメニューバーに住む黒猫の音声入力。ショートカットを押して話せば、入力中の場所に文字が戻ります。
</p>

<p align="center">
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml"><img src="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest"><img src="https://img.shields.io/github/v/release/yuipan0611/whats-up-my-neighbor-ai-input-macos" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-101114?logo=apple" alt="macOS 13+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
  <a href="https://nekonode.cloud"><img src="https://img.shields.io/badge/website-nekonode.cloud-101114" alt="公式サイト nekonode.cloud"></a>
</p>

<p align="center">
  <a href="https://nekonode.cloud"><b>公式サイト</b></a> ·
  <a href="https://nekonode.cloud/#download">ダウンロード</a> ·
  <a href="https://nekonode.cloud/guide">使い方</a> ·
  <a href="docs/GUIDE.md">詳細ガイド</a> ·
  <a href="https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-windows">Windows 版</a>
</p>

<p align="center">
  言語：
  <a href="README.md"><kbd>繁體中文</kbd></a>
  <a href="README.en.md"><kbd>English</kbd></a>
  <a href="README.ja.md"><kbd>日本語 ✓</kbd></a>
</p>

---

> [!NOTE]
> アプリの画面、公式サイト、詳細ガイドは現在 **繁体字中国語のみ** です。以下に出てくる中国語のファイル名は原文のまま示し、括弧内に日本語訳を添えています。

What's up my neighbor は、軽量なネイティブ macOS メニューバー音声入力アプリです。任意のテキスト欄で `⌥↑` を押すと録音が始まり、もう一度押すと止まります。音声は Groq `whisper-large-v3` で文字起こしされ、元のカーソル位置に自動で貼り付けられます。録音中は小さな黒猫が画面に現れ、話を聞いてくれます。

<p align="center">
  <img src="docs/media/screenshots/recording-hud-card.png" alt="録音中の黒猫オーバーレイ：両耳の間の音量バーが声に合わせて動き、左目の×でキャンセル、右目の✓で完了" width="420">
</p>

## 特長

- **ワンキーで録音、元の場所へ**：初期ショートカットは `⌥↑`（変更可能）。認識後、録音を始めた入力欄に自動で貼り付けます。
- **黒猫の録音オーバーレイ**：音量バーが声に合わせて動きます。左目（×）でキャンセル、右目（✓）で完了。入力欄のフォーカスは奪いません。
- **3 つの出力モード**：逐語（初期設定）、標準、簡潔。すべてローカルの固定ルールで処理し、書き換えモデルは使いません。法律用語や条文番号は変更されません。
- **言語ガード**：繁体字中国語、英語、日本語、韓国語、タイ語、ベトナム語、スペイン語、フランス語、ドイツ語から、メイン言語 1 つと混在を許す言語を最大 2 つ選べます。許可していない言語の文字が出た場合は貼り付けずに保留し、1 回だけ自動で再試行します。
- **クリップボード履歴**：直近 10 件を `⌃⌥V` で呼び出せます。Enter は貼り付けるだけで、メッセージを送信しません。
- **デスクトップの黒猫**：散歩、毛づくろい、あくび、昼寝をします。クリックすると「ゴロゴロ」の吹き出しが出て、押したままドラッグすると持ち上げられます。
- **プライバシー優先**：API キーは macOS キーチェーンにのみ保存。分析、広告、独自サーバーはありません。
- **更新はあなたが決める**：Sparkle が毎日新しいバージョンを確認し、インストールするかどうかを尋ねます。個人設定は上書きされません。

### QA テスト機能（正式版には未収録）

- **Command＋V で履歴を選択**：通常の `⌘V` はそのまま貼り付けます。`⌘V` を押したまま `↑`／`↓` を押すと履歴を表示し、Enter で確定、Esc で閉じます。`⌃⌥V` とメニューからも開けます。
- **9 種類の毛色をすぐに切り替え**：メニューバーの「選擇貓咪花色」（毛色を選択）から選ぶと、デスクトップの猫に即時反映され、非表示の場合は表示されます。再起動は不要です。初期設定は元の黒猫で、最後の選択を記憶します。
- **カスタム猫パック**：左右の目、鼻、首輪、リボンを設定し、`.nekocat` で読み込み・書き出しできます。初回インストール時に指定の猫を設定する配布パッケージも作れます。[形式・配布・QA の説明（繁体字中国語）](docs/CAT-PACKS.md)。

正式版 1.4.5 にはこれらの機能は含まれません。QA 版のメニューには「QA 測試版」とソースの識別番号を表示します。[インストールとデスクトップ QA の手順（繁体字中国語）](docs/QA_CLIPBOARD_CAT.md)。

## スクリーンショット

<p align="center">
  <img src="docs/media/screenshots/greeting-card.gif" alt="黒猫に what's up と話しかけると、吹き出しで what's up! と返事をする" width="400">
  &nbsp;&nbsp;
  <img src="docs/media/screenshots/desktop-pet-walking-card.gif" alt="デスクトップの黒猫が歩くアニメーション" width="250"><br>
  <sub><code>what's up</code> とだけ言うと黒猫が返事をします（このフレーズは入力欄には入りません）。デスクトップに出すと、画面の端を散歩したり休んだりします。</sub>
</p>

<p align="center">
  <img src="docs/media/screenshots/desktop-pet-poses.png" alt="黒猫の 7 つのポーズ：座る、立ち上がる、歩く、首をかしげる、前足をなめる、あくび、寝そべる" width="820"><br>
  <sub>約 12 秒操作がないと自分でポーズを変えます。録音中、フルスクリーン、ロック中は止まります</sub>
</p>

<p align="center">
  <img src="docs/media/screenshots/desktop-pet-interaction.png" alt="左：クリックすると目を閉じてゴロゴロ。右：ドラッグすると持ち上げられる" width="820"><br>
  <sub>クリックで「ゴロゴロ」、押したままドラッグで持ち上げ、離すと座り直します</sub>
</p>

## インストール

**動作環境**：macOS 13 Ventura 以降、ご自身の Groq API キー、インターネット接続、「マイク」と「アクセシビリティ」の許可。

### ZIP をダウンロード

1. [Releases](https://github.com/yuipan0611/whats-up-my-neighbor-ai-input-macos/releases/latest) から `Groq-AI-Voice-Input-macOS-v<バージョン>.zip` をダウンロードして展開します。同じページの `Neighbor-macOS-<バージョン>.zip` はアプリ内アップデート用なので不要です。
2. 無料版は Apple の公証を受けていないため、初回は `安裝.command` を右クリックして「開く」を選びます。それでもブロックされる場合は「システム設定 → プライバシーとセキュリティ」で「このまま開く」を押します。
3. 初回起動画面に従ってご自身の Groq API キーを貼り付け、「マイク」と「アクセシビリティ」を許可します。
4. 任意のテキスト欄で `⌥↑` を押して録音を始め、もう一度押して止めます。

現行の正式リリースには、1 行インストール用のスクリプトはまだ含まれていません。上記の ZIP 手順を使用してください。今後のリリースにスクリプトが含まれた場合は、[詳細ガイド](docs/GUIDE.md#一行指令安裝熟悉終端機)を参照してください。

インストール済みの場合、インストーラーは既存の場所と設定をそのまま使います。アプリが見つからないときやインストール結果を確認したいときは、[インストール場所・名称対照・確認](docs/GUIDE.md#安裝位置名稱對照與驗證)（繁体字中国語）を参照してください。

Claude Code や Codex などの AI にインストールを任せることもできます。[AI に任せる](docs/GUIDE.md#直接交給-ai-安裝)（繁体字中国語）のプロンプトを丸ごと貼り付けてください。

### Groq API キー

[Groq Console](https://console.groq.com/keys) で `gsk_` から始まるキーを作成し、アプリ専用の入力ウィンドウにだけ貼り付けてください。他人のキーは使わないでください。普段の音声入力で Groq 無料プランの上限に達することはまずありません。上限の詳細は[こちら（英語）](docs/GUIDE.md#english)。

## プライバシー

- 音声は文字起こしのためだけに Groq Speech-to-Text API へ送られます。アプリに分析、広告、独自サーバーはありません。
- Groq API キーはこの Mac のキーチェーンにのみ保存され、設定ファイル、リポジトリ、ログには書き込まれません。
- クリップボード履歴はこの Mac にのみ保存され、いつでも一時停止・削除できます。録音ファイルの履歴は残しません。

詳細（中国語）：[PRIVACY.md](PRIVACY.md)

## ドキュメント

ほとんどのドキュメントは繁体字中国語で書かれています。

| 目的 | 参照先 |
|---|---|
| すべての機能と設定を知る | [詳細ガイド](docs/GUIDE.md)、[公式サイトの使い方](https://nekonode.cloud/guide) |
| 黒猫の画像やあいさつを変える | [CAT-CONFIG.md](CAT-CONFIG.md) |
| カスタム猫パックの作成・共有・配布 | [docs/CAT-PACKS.md](docs/CAT-PACKS.md) |
| バージョンごとの変更点 | [CHANGELOG.md](CHANGELOG.md)、[公式サイトの更新履歴](https://nekonode.cloud/changelog) |
| アーキテクチャを理解する | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| ソースからビルド・テストする | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)、[docs/TESTING.md](docs/TESTING.md) |
| リリースと更新の流れ | [docs/UPDATES.md](docs/UPDATES.md) |
| 開発に参加する・問題を報告する | [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) |

連携する iPhone アプリは現在開発中で、まだ公開されていません。

## ライセンス

[MIT License](LICENSE)
