# LocalCanvas

[English](README.md) · [Русский](README.ru.md) · **日本語**

**アプリの表示言語は英語とロシア語だけです。** 日本語のロケールはありません。この
文書は日本語ですが、画面に出る文言は英語（またはロシア語）のままです。以下で画面の
項目を引用するときは、英語の表記をそのまま示し、意味を添えます。

セキュリティポリシー、コントリビューションの手引き、変更履歴は英語のみです:
SECURITY.md、CONTRIBUTING.md、CHANGELOG.md。

**ワークフローを組むのは ComfyUI。使うのは LocalCanvas。**

LocalCanvas は、すでにお持ちの ComfyUI ワークフローのための Android アプリです。
スマートフォンでワークフローを選び、プロンプトを書き、ワークフローが受け付けるなら
画像や動画を足して（[既知の制限](#既知の制限)を参照）、「Generate（生成）」を
押します。ノードグラフを見ることは一度もありません。

    Android アプリ
        │  あなたの Wi-Fi / LAN
        ▼
    LocalCanvas Gateway    ← ネットワーク上に出るのはこれだけ
        │  localhost
        ▼
    ComfyUI  →  GPU

- **ローカル優先。** すべてがあなたの PC と、あなた自身のネットワークの中で動きます。
- **今お使いの ComfyUI で動きます。** ComfyUI には何もインストールしません。
- **Android のフロントエンド。** 各ワークフローをシンプルなフォームとして表示します。
- **ワークフローの取り込みと同期。** ComfyUI のワークフローフォルダーから行います。
- **LocalCanvas のクラウドもアカウントもありません。**

**これは何ではないか** —— 意図してそうしており、今後も変わりません: アカウント、
ログイン、認証はありません。クラウド同期、インターネット越しのリモートアクセス、
クラウド生成もありません。プラグインのマーケットプレイスや SDK、ワークフローや
ノードグラフのエディタ、実行時にワークフローの入力を推測するゲートウェイ、AI による
プロンプト改善や組み込み LLM、データベースに残る履歴やサーバー側のメディア
ライブラリ、マルチユーザー対応、Kubernetes、iOS アプリ、Web フロントエンドも
ありません。

## スクリーンショット

| スマートフォン | 展開した状態 |
| --- | --- |
| <img src="docs/assets/screenshot-phone-generating.jpg" alt="スマートフォンでの表示。ワークフローを選び、プロンプトを書き、生成が進んでいるところ" width="260"> | <img src="docs/assets/screenshot-unfolded-result.jpg" alt="折りたたみ端末を開いた状態。左に入力フォーム、右に生成された画像" width="420"> |

<img src="docs/assets/screenshot-unfolded-ready.jpg" alt="生成を始める前の、同じ 2 ペイン表示" width="420">

## 必要なもの

- **Windows 10 または 11。**
- **PowerShell 7 以降** (`pwsh`)。Windows PowerShell 5.1 はサポートしません。
  インストール: `winget install --id Microsoft.PowerShell`。
- **インストール済みの Python 3.10 – 3.13**（<https://www.python.org/downloads/>
  から）。setup がそれを見つけ、LocalCanvas 専用の環境をそこから作ります。
- **すでに動いている ComfyUI。** まだ ComfyUI がない場合は、任意の
  [Minimal ブートストラップ](docs/user-guide.ja.md#2-comfyui-を用意する)で入れられ
  ます —— モデルはダウンロードせず、Python 環境も作りません。
- **Google Chrome または Microsoft Edge。** ComfyUI の **Save** で保存した
  ワークフローを変換するのに使います。
- 同じネットワークにある **Android スマートフォン**（Android 7.0 以降）。
- このリポジトリをクローンするための **git**。
- アプリを自分でビルドする場合のみ: Flutter と Android SDK
  （[Android アプリ](#android-アプリ)を参照）。

## クイックスタート

ComfyUI が動いている PC で、PowerShell 7 のウィンドウから:

```powershell
git clone https://github.com/shinKatana0/LocalCanvas.git LocalCanvas
cd LocalCanvas
pwsh .\scripts\setup.ps1
pwsh .\scripts\start.ps1
```

- setup は短い質問を 2 つします —— ComfyUI を自分で起動するか、そして ComfyUI の
  フォルダー（`main.py` のあるフォルダー、またはポータブル版のフォルダー）がどこに
  あるか —— そのうえで設定を書きます。YAML を編集することはありません。
  （ワークフローフォルダーが見つからないときだけ、3 つめの質問があります。）
  2 つの質問は[ユーザーガイド](docs/user-guide.ja.md#3-localcanvas-を入れて起動する)
  で説明しています。
- `start.ps1` の前に ComfyUI を起動しておいてください（LocalCanvas に起動を任せた
  場合を除く）。
- 初回の起動がワークフローを見つけ、取り込むかを尋ねます。
- 最後に、スマートフォン用の QR コードを表示します。

あと一歩: スマートフォンにアプリを入れます ——
[Android アプリ](#android-アプリ)を参照してください。

## 毎日の使い方

```powershell
pwsh .\scripts\start.ps1
```

これが毎日のコマンドです。スマートフォンを使っている間はそのウィンドウを開いた
ままにしてください。閉じると LocalCanvas も止まります。

起動のたびに、ComfyUI のワークフローフォルダーを調べます。この確認はファイルを
読むだけで、何も変換せず、何も書きません。

- **何も変わっていない** —— `Workflows: unchanged - nothing new and nothing edited`
  と表示され、LocalCanvas が起動します。
- **新しいもの、変わったものがある** —— `Sync workflows now? [Y/n]` と尋ねます。
  Enter は「はい」です。
- 勝手に同期することはありません。答える人のいないセッション（タスク
  スケジューラ、CI のステップ、パイプ、`-NonInteractive` のシェル）では尋ねも
  しません。実行すべきコマンドを示し、そのまま起動します。

`pwsh .\scripts\stop.ps1` は LocalCanvas が起動したものを止め、
`pwsh .\scripts\status.ps1` は今動いているものを表示します。

## ワークフローを追加・変更する

1. ComfyUI でワークフローを作るか編集し、**Save** で保存します（**Export (API)**
   でも構いません。どちらも使えます）。
2. LocalCanvas が動いていれば止めます: `pwsh .\scripts\stop.ps1`。
3. ComfyUI を起動した状態で（LocalCanvas に起動を任せた場合を除く）
   `pwsh .\scripts\start.ps1` を実行します。
4. `Workflows: 1 new`（または `changed`）と表示され、`Sync workflows now? [Y/n]`
   と尋ねられます。
5. アプリをすでに開いていて、そのワークフローが一覧にない場合は、
   **Choose a workflow**（ワークフローを選ぶ）画面の上にある
   **Refresh the list**（一覧を更新、↻）をタップします。

バックグラウンドでフォルダーを見張るものはありません。変更が取り込まれるのは、
`start.ps1` を実行したとき、または自分で同期したときです:

```powershell
pwsh .\scripts\sync-workflows.ps1 -DryRun    # 何が取り込まれるかを表示するだけで、何も書かない
pwsh .\scripts\sync-workflows.ps1            # 今すぐ取り込む
pwsh .\scripts\start.ps1 -SyncWorkflows      # 変わったものを尋ねずに同期して起動する
```

確信をもって読めないワークフローは、推測せずに `NEEDS_REVIEW` として保留します
—— どうすればよいかは[ユーザーガイド](docs/user-guide.ja.md#4-あなたのワークフロー)
にあります。

## Android アプリ

**APK を手に入れる。** このリポジトリがリリースを公開していれば、その
**Releases** ページから APK をダウンロードできます。または Flutter と Android SDK
を使って、`app/` で自分でビルドします:

```powershell
flutter pub get
flutter build apk --release --split-per-abi
```

たいていのスマートフォンに必要なのは `arm64-v8a` の APK です。Android は、ファイルを
開いたアプリからのインストールを許可するか尋ねます —— ストアではなく手動で入れる
（サイドロード）からです。APK はデバッグ鍵で署名された（テスト用の署名の）ビルド
なので、別の場所でビルドされたものを入れる前に LocalCanvas をアンインストールして
ください。詳しくは[ユーザーガイド](docs/user-guide.ja.md#5-アプリを入れる)を参照
してください。

**接続する。** `start.ps1` が表示した QR コードを読み取るか、アドレスを入力するか
（`192.0.2.42`、`192.0.2.42:7801`、`http://192.0.2.42:7801` —— あなたの PC の
アドレスで）、ルーターが探索を通す環境なら、アプリがネットワーク上で見つけた一覧
から PC を選びます。詳しくは
[Wi-Fi でつなぐ](docs/user-guide.ja.md#6-wi-fi-でつなぐ)を参照してください。

**Windows ファイアウォール。** `start.ps1` を初めて実行したとき、Windows が
ネットワークへのアクセスを許可するか尋ねることがあります。許可するのは
**プライベート ネットワーク**（Private networks）だけにしてください。ゲートウェイ
にはログインがないので、信頼できる家庭のネットワークだけで使ってください。
スマートフォンから PC に届かないとき、原因はたいていファイアウォールです。

## プライバシー

テレメトリ、アナリティクス、クラッシュレポート、アカウント、クラウド生成は
ありません。アプリが話す相手はあなたのゲートウェイだけで、ゲートウェイが話す
相手はあなたの ComfyUI だけです。これは LocalCanvas 自身のコードについての約束で
あり、**サードパーティの ComfyUI カスタムノードについての約束ではありません**。
カスタムノードは、作者が書いたとおりのことを何でもできます ——
[SECURITY.md](SECURITY.md) を参照してください。

## 既知の制限

- PC 側は **Windows のみ**です。
- 手作業では、メンテナーが折りたたみスマートフォン 1 台で、Wi-Fi 経由で本物の
  ComfyUI を相手に、ペアリングと生成を確認しています。この経路を自動で確かめる
  ものはありません。
- 画像や動画のアップロードは、スマートフォンから動くことがまだ確認できていません。
- プロンプトの翻訳と、mDNS による探索がスマートフォンに届くことは、模擬環境で
  しか試していません。
- `NEEDS_REVIEW` として保留されたワークフローは、何を表示するかを人が決める必要が
  あります。

何が確かめられているかの詳細は[ユーザーガイド](docs/user-guide.ja.md#1-始める前に)
にあります。うまくいかないときは `pwsh .\scripts\doctor.ps1` を実行し、
[うまくいかないとき](docs/user-guide.ja.md#13-うまくいかないとき)を参照して
ください。

## さらに読む

- [ユーザーガイド](docs/user-guide.ja.md) —— 詳しい手引き
  （[English](docs/user-guide.md)、[Русский](docs/user-guide.ru.md)）。
- [CONTRIBUTING.md](CONTRIBUTING.md) —— テストの実行方法。
- [SECURITY.md](SECURITY.md) —— セキュリティモデルと問題の報告方法。
- [CHANGELOG.md](CHANGELOG.md) —— 変更点。
- [LICENSE](LICENSE) —— MIT。
