# LocalCanvas ユーザーガイド

[English](user-guide.md) · [Русский](user-guide.ru.md) · **日本語**

**アプリの表示言語は英語とロシア語だけです。** 日本語のロケールはありません。この
ガイドは日本語ですが、画面に出る文言は英語（またはロシア語）のままなので、以下では
画面の項目を英語表記のまま引用し、意味を添えます。

空のフォルダーからスマートフォンに画像が出るまでに必要なことを、すべて書いてあり
ます。まだなら [README.ja.md](../README.ja.md) を先にお読みください。LocalCanvas が
何であり、何をあえてしないかが書いてあります。このガイドの正文は英語版です:
[user-guide.md](user-guide.md)。

以下の PowerShell の行は、いずれもリポジトリのルートで入力する形で書いてあります。

---

## 1. 始める前に

生成を行う PC に必要なもの:

| 必要なもの | 理由 |
|---|---|
| **Windows 10 または 11** | 実行用スクリプトは PowerShell で書かれており、v0.1 では PC 側は Windows 専用です。 |
| **PowerShell 7 以降** (`pwsh`) | Windows PowerShell 5.1 はサポートしません。`winget install --id Microsoft.PowerShell`、または <https://aka.ms/powershell>。 |
| **git** | 最初の一歩がこのリポジトリのクローンで、任意の ComfyUI ブートストラップもクローンします。ComfyUI のポータブル版を使っている人は入れていないことも多いはずです: `winget install --id Git.Git`、または <https://git-scm.com/download/win>。 |
| **Python 3.10 – 3.13** | ゲートウェイが宣言している範囲は `>=3.10,<3.14` で、<https://www.python.org/downloads/> から入れます。LocalCanvas は自前の `.venv/` を作り、ComfyUI の Python には何もインストールしません。PC にサポート対象の Python がなければ、setup は何も作らずに止まり、インストールするよう案内します。 |
| **ComfyUI**（動作するもの）と GPU | LocalCanvas は*あなたの*ワークフローを走らせます。ComfyUI の代わりではありません。 |
| **Google Chrome または Microsoft Edge** | ComfyUI の **Save** で保存したワークフローを変換するときだけ必要です。**Export (API)** で書き出したワークフローには不要です。 |
| **Flutter**（stable）と **Android SDK** | Android アプリを自分でビルドするときだけ必要です。ここで最も時間のかかるインストールです。Flutter 自身の Windows 向け手順 <https://docs.flutter.dev/get-started/install> に従ってください（Android SDK もそこで扱われます）。そのあと `flutter doctor --android-licenses`。第 5 節。 |
| 同じ Wi-Fi にある **Android スマートフォン** | 実際に使うもの。**Android 7.0（API 24）**以降 —— リリースビルドが宣言している下限です。 |

Python が複数入っているマシンでも、自分で選ぶ必要はありません。`setup.ps1` が
サポート範囲内のインタプリタを選び、どれを選んでどのバージョンだったかを表示します。

**何が確かめられているか。** 公開 CI（GitHub Actions、`windows-latest`、本物の
ComfyUI なし）は、`main` への push とすべての pull request で、Python 3.10 と
3.13 でのゲートウェイのテスト、アプリの `flutter analyze` と `flutter test`、
PowerShell スクリプトのテストを実行します。手作業では、メンテナーが折りたたみ
スマートフォン 1 台で、Wi-Fi 経由で本物の ComfyUI を相手に、ペアリングと生成を
確認しています。この経路を自動で確かめるものはありません。画像や動画の
アップロードは、スマートフォンから動くことがまだ確認できていません。プロンプトの
翻訳、mDNS による探索がスマートフォンに届くこと、doctor の管理者権限での
ファイアウォール確認は、模擬環境でしか試していません。ComfyUI ブートストラップの
プロファイルで検証済みなのは Minimal だけです（第 2 節）。

## 2. ComfyUI を用意する

### すでにある場合 — こちらが普通です

することはありません。LocalCanvas は、自分がインストールしたのではない ComfyUI に
書き込むことも、その Python にパッケージを足すことも、その設定を書き換えることも
ありません。両者をつなぐのは HTTP だけです。

### ない場合 — 任意のブートストラップ

```powershell
pwsh .\comfy\setup.ps1 -Profile Minimal -DryRun
pwsh .\comfy\setup.ps1 -Profile Minimal
```

ドライランは行う予定の操作をすべて表示し、フォルダー 1 つさえ作らず、まったく何も
書きません。本番の実行は ComfyUI を固定リビジョンでクローンし（転送量はおよそ
7 MiB、ディスク上でおよそ 31 MiB）、その `user/default/workflows` フォルダーを
作ります。二度実行すると、二度目はすべて完了済みだと言って何も変えません。

**どこに入るか。** `-ComfyRoot` を付けなければルートは
`%LOCALAPPDATA%\LocalCanvas\comfyui`、典型的なマシンでは
`C:\Users\<you>\AppData\Local\LocalCanvas\comfyui` です。その中身:

| 何 | どこ |
|---|---|
| ComfyUI のチェックアウト — 第 3 節が尋ねてくる ComfyUI がこれです | `<root>\ComfyUI` |
| あなたのワークフローフォルダー。第 3 節が自分で見つけます | `<root>\ComfyUI\user\default\workflows` |
| 何をインストールしたかの記録 | `<root>\localcanvas-bootstrap.json` |

別の場所に置くには `-ComfyRoot "D:\somewhere"` を渡します。これらのパスを打ち
直す必要はありません。第 3 節の `pwsh .\scripts\setup.ps1` が、*あなたの ComfyUI
はどこか*への答えとしてこの場所を既定で示すので、Enter を押すだけです。先に読んで
おきたければ、ドライランが完全な形で表示します —— 先頭の `Root:` の行、続いて操作
ごとの `[PLAN]` の行、そして**チェックアウトとインストール記録**を繰り返す末尾の
ブロックです。ワークフローフォルダーは上の計画のほうに出てきて、この末尾の
ブロックには入りません。

`user/default/workflows` フォルダーはブートストラップが終わった時点で存在するので、
まだ 1 つもワークフローを保存していなくても第 4 節のインポーターは読むものがあります。

**しないことを、はっきり書きます。** モデルはダウンロードせず、Python 環境も作り
ません。その ComfyUI が起動する前に、サポートされている Python を自分で入れ、
ComfyUI 自身の `requirements.txt` を入れ（数ギガバイトあり、GPU に合う CUDA ビルドを
選ぶのはあなたの判断です）、ワークフローが必要とするモデルを用意し、ComfyUI を
起動する必要があります。

v0.1 でサポートするのは **Minimal** プロファイルだけです。マニフェストの形式は
Recommended と Video のプロファイルも表現できますが、これらは実験的で、このリリース
では検証しておらず、どのプロファイルでも LocalCanvas はモデルを配布しません。

ある ComfyUI —— あなたのものでも、ブートストラップで入れたものでも —— が
LocalCanvas で使えるかを尋ねるには:

```powershell
pwsh .\comfy\doctor.ps1
```

読み取り専用で、どの答えも動いている ComfyUI への実際のリクエストから得ています。
終了コードは **0**（COMPATIBLE）、**2**（UNKNOWN — 失敗はないが、少なくとも 1 つの
点検が行えなかった）、**3**（NOT COMPATIBLE）です。行えなかった点検が合格として
報告されることは決してないので、動いていない ComfyUI は「異常なし」ではなく UNKNOWN
になります。

## 3. LocalCanvas を入れて起動する

```powershell
pwsh .\scripts\setup.ps1
pwsh .\scripts\start.ps1
```

この 2 つで初回は終わりです。テンプレートをコピーすることも、YAML を開くことも
なく、手で編集する設定ファイルの数は**ゼロ**です。setup の間は ComfyUI が
動いていなくても構いませんが、`start.ps1` には必要です（そう選んだ場合は、
それが自分で ComfyUI を起動します）。

### 初回の実行がすること

`setup.ps1` はサポート範囲内の Python を選んでどれをどのバージョンで使ったかを
表示します。（見つからなければ、何も作らずに止まり、Python 3.10 – 3.13 を
<https://www.python.org/downloads/> から入れるか、`-PythonExe` でインタプリタを
指定するよう案内します。）そしてリポジトリのルートに `.venv/` を作り、そこへゲートウェイをインストール
します。インストールは必ず `.venv\Scripts\python.exe -m pip` として走るので、
ComfyUI の Python に書き込むことはできません。さらに、読み込めるゲートウェイが
どこかに残った別のコピーではなく*この*チェックアウトのものであることを確認します。
そのうえで質問をし、設定を書き、その設定を `start.ps1` が読むのと同じやり方で
読み直し、状態の表を表示し、次に実行するコマンドを示します。

### 2 つの質問

1. **「ComfyUI はご自分で起動しますか、それとも LocalCanvas が起動しますか？」**
   これを最初に尋ねるのは、答えによってあとで必要になるものが決まるからです。
   選択肢は `1  I start ComfyUI myself` と `2  LocalCanvas starts ComfyUI for me`
   で、Enter を押すと **1** になります。
   * **1 — 外部モード**（`-Mode External`）。LocalCanvas は ComfyUI を起動すること
     も停止することもありません。ゲートウェイを起動する前にアドレスが応答すること
     を確かめるだけです。起動コマンドを割り出す必要がまったくないので、このモード
     があなたに求めるものが一番少なくて済みます。
   * **2 — 管理モード**（`-Mode Managed`）。LocalCanvas が ComfyUI を起動でき、
     すでに動いていれば 2 つめを起動せずそれを再利用し、自分で起動したものだけを
     停止します。起動には、あなたの ComfyUI の隣にすでにある Python を使います ——
     ポータブル版なら `python_embeded\python.exe`、クローンなら
     `venv\Scripts\python.exe` または `.venv\Scripts\python.exe` —— これを setup が
     インストールから読み取り、`comfy.launcher` に書き込みます。そのインタプリタに
     は何もインストールしません。見つからなければ setup は推測せずに**拒否**します:
     *"There is no Python beside ... to start ComfyUI with ... LocalCanvas will
     not guess at an interpreter it has not found. Nothing has been written to
     config."* そして進む道として `-Mode External` を示します。
2. **「あなたの ComfyUI はどこにありますか？」** `main.py` の入っているフォルダー、
   またはポータブル版なら*その*フォルダーを含むフォルダーです。どちらのレイアウト
   も認識し、入力された内容は検証されます。これだけは推定できません。LocalCanvas は
   ドライブを走査せず、ディレクトリツリーをたどらず、レジストリも読まないからです。
   第 2 節のブートストラップで入れた場合は、その場所が既定として示されるので Enter
   を押すだけです。

**3 つめ**の質問は、指定されたフォルダーの中に `user\default\workflows` ——
ComfyUI 自身がワークフローを置く場所 —— が無いときにだけ行われます。そこにあれば
自動的に見つかり、何も尋ねられません。

ほかに尋ねることはありません。尋ねる必要がないからです。表示名はコンピューター名
から、ComfyUI のアドレスは ComfyUI 自身の既定 `127.0.0.1:8188` から、ゲートウェイ
のアドレスは `0.0.0.0:7801`、起動コマンドは指定された ComfyUI から読み取り、
レジストリは `config/local/workflows`。`startup`、`media`、`prompt_translation`
の各節は、そこに入る値がどれもゲートウェイ自身の既定と同じなので、そもそも
書かれません。

**このとき ComfyUI が動いている必要はありません。** setup は推定したアドレスへ
期限つきのリクエストを 1 回送るだけで、応答が無ければ

    [INFO] ComfyUI did not answer at http://127.0.0.1:8188.
           That is expected if it is not running yet. If it IS running, the
           address is wrong: check comfy.host and comfy.port in <あなたの設定>.

と表示し、そのまま終了コード 0 で最後まで進みます。応答が無かったことが
セットアップの失敗として扱われることはありません。「まだ起動していない」と
「アドレスが違う」を区別できないので、両方を述べます。

書かれるファイルは 2 つで、どちらも gitignore された `config/local/` の中です。
あなたのパスがコミットに入ることはありません:

| ファイル | 中身 |
|---|---|
| `config/local/runtime.yaml` | モード、あなたの ComfyUI、アドレス、レジストリ、この PC の表示名。 |
| `config/local/workflow-sources.yaml` | LocalCanvas がワークフローを読む、ただ 1 つのフォルダー。 |

[`config/examples/runtime.example.yaml`](../config/examples/runtime.example.yaml)
は、これらのファイルに書けるものすべての参照先です —— 存在する設定、その意味、
書かなかったときに何が起きるか。setup が書いた内容を変えたくなったら読んでくだ
さい。手で編集する前に知っておくとよい値が 2 つあります:

- **`comfy.root`** は絶対パスでなければなりません。LocalCanvas がこれを推測する
  ことはありません。
- **`comfy.launcher.executable`** と **`comfy.launcher.script`** は
  **`comfy.root` からの相対パス**です。ポータブル版なら
  `python_embeded/python.exe` と `ComfyUI/main.py`、普通のクローンなら
  `venv/Scripts/python.exe` と `main.py`。絶対パスはそのまま使われますが、
  `python` のような裸の名前は絶対パス**ではなく**、`<root>\python` と解釈される
  ので動きません。どちらの値も setup が指定された ComfyUI から読み取ります。
  だから手で正しく書く必要がないのです。

### 先に答えておく

どの質問にもパラメーターがあるので、無人の実行が待たされることはありません。何が
足りないかを告げ、それを与えるパラメーターを示して終了します。

```powershell
pwsh .\scripts\setup.ps1 -Mode External -ComfyRoot "C:\path\to\ComfyUI"
```

| パラメーター | 何に答えるか |
|---|---|
| `-Mode External` / `-Mode Managed` | 質問 1。`External` だけで最後まで通ります。 |
| `-ComfyRoot "C:\path\to\ComfyUI"` | 質問 2。 |
| `-WorkflowSource "C:\path\to\workflows"` | 質問 3。 |
| `-ComfyHost`、`-ComfyPort` | ComfyUI の待ち受け先が `127.0.0.1:8188` でないとき。 |
| `-PythonExe`、`-VenvPath`、`-Recreate`、`-Dev` | どのインタプリタか、環境をどこに作るか、作り直すか、テスト用の追加を入れるか。 |

### setup をもう一度実行する

冪等です。健全な状態で二度目を実行すると、同じ状態の表と `Nothing to change.` が
出ます。何も尋ねません。`.venv/` のゲートウェイをローカルで確認し、問題がなければ
何もインストールせず（`Gateway already installed from this checkout - nothing to install`
と表示します）、そのためオフラインでも動きます。確認で問題が見つかったときだけ
ゲートウェイを入れ直し、その理由を示します。**すでにある設定ファイルはそのままに
します** —— あなたのファイルはあなたのもので、中身が何であれ書き換えません。
ワークフローには触れず、モデルもダウンロードせず、ComfyUI の中には何も書きません。

再実行では直らないものが 1 つあります。サポート範囲外のインタプリタで作られた環境
です。これは `-Recreate` を示して拒否されます。直せるのは作り直しだけだからです。

ワークフローの場所を setup が判断できなかった場合、状態の表に
`Workflow sources   not configured` と出て、仕上げるためのコマンドが表示されます
—— `pwsh .\scripts\setup.ps1 -WorkflowSource '<your workflow folder>'`。この実行は
ソース一覧を書くだけで、ほかは何も変えません。

### そして起動する

```powershell
pwsh .\scripts\start.ps1
```

設定を読み込み、ComfyUI が本当に準備できていることを確かめ（固定時間の待機ではなく、
実際に HTTP を繰り返し叩いて確認します）、第 4 節のとおりワークフローフォルダーを
調べ、ゲートウェイを起動して、接続先と QR コードをターミナルに表示します。
スマートフォンを使っている間は、**そのウィンドウを開いたままにしてください**。
閉じるとゲートウェイも止まります。

**setup とは違い、こちらは ComfyUI が動いている必要があります。** 外部モード ——
既定である答え 1 —— では LocalCanvas が代わりに起動することはないので、応答しない
ComfyUI は `ComfyUI is not reachable` と終了コード 4 で実行を終わらせ、ゲートウェイ
は起動しません。管理モードなら、LocalCanvas 自身が ComfyUI を起動して待ちます。

**setup はワークフローを 1 つも取り込みません。** ワークフローが入ってくるのは
最初の `start.ps1` で、フォルダーの中身をすべて新規として見つけ、取り込むかを
尋ねます（第 4 節）。

マシンの状態はいつでも —— 前でも後でも —— 見られます。`pwsh .\scripts\doctor.ps1`
は読み取り専用で、まとめて診断します（第 13 節）。

## 4. あなたのワークフロー

`config/local/workflow-sources.yaml` は setup がすでに書いていて、あなたの ComfyUI
ワークフローフォルダーもそこに書かれています —— 既定のインストールなら ComfyUI
フォルダー内の `user/default/workflows` です。このファイルの中身は 2 つの約束が
すべてです。**そこに挙げられたフォルダーだけが、LocalCanvas が読むフォルダーの
すべてです。** そして**あなたのワークフローファイルは読むだけです** —— 名前を
変えることも、移動も、削除も、書き換えもしません。

### Save でも Export (API) でも使えます

ComfyUI はワークフローを 2 つの形のどちらかで書きます。LocalCanvas はどちらも
受け付けます:

| ComfyUI で使ったもの | LocalCanvas の扱い |
|---|---|
| **Save**（ふつうの保存） | 取り込むときに、あなたの動いている ComfyUI を通し、PC にすでにある Chrome または Edge の中で変換します。 |
| **Workflow → Export (API)**（古い ComfyUI では *Save (API Format)*） | そのまま取り込みます。ブラウザーは要りません。 |

つまり **Save** で保存したワークフローに必要なのは、**取り込みの時点で ComfyUI が
動いていて、Chrome か Edge が入っていること**だけです。ブラウザーは画面を持たず、
使い捨ての専用プロファイルで動くので、画面には何も現れません。

### ワークフローを追加・変更する

1. ComfyUI でワークフローを作るか編集し、ワークフローフォルダーに保存します。
2. LocalCanvas が動いていれば止めます —— `pwsh .\scripts\stop.ps1` を実行するか、
   起動したウィンドウを閉じます。ゲートウェイはカタログを起動時に一度だけ読むので、
   動いたままのゲートウェイには変更が見えません。
3. ComfyUI を起動した状態で（LocalCanvas に起動を任せた場合を除く）
   `pwsh .\scripts\start.ps1` を実行します。
4. ワークフローが見つかり、こう尋ねられます:

       [WARN] Workflows: 1 new
              Sync workflows now? [Y/n]

   Enter（はい）を押します。取り込みが走り、そのあと LocalCanvas が起動します。
5. アプリをすでに開いていて、そのワークフローが一覧にない場合は、
   **Choose a workflow**（ワークフローを選ぶ）画面の上にある
   **Refresh the list**（一覧を更新、↻）をタップします。

バックグラウンドでフォルダーを見張るものはありません。変更が取り込まれるのは、
`start.ps1` を実行したとき、または手で取り込んだとき（下記）だけで、勝手に
取り込まれることはありません。

### 起動のたびに調べること

`start.ps1` はゲートウェイを起動する前にフォルダーを調べます。各ファイルを読み、
前回取り込んだものと**内容**を比べるので、中身を変えずに保存し直しただけの
ワークフローは変更なしと数えます。何も変換せず、何も書かず、ComfyUI には何も
尋ねません。

ただではありません。フォルダーが大きいなら数字を知っておく価値があります。
実測で **250 個あたりおよそ 4〜5.5 秒**、1 個あたり**およそ 14〜19 ms** で線形に
増えるので、500 個ならおよそ 8〜10 秒です。幅があるのは、同じコードを別のマシンと
別のフォルダーで丁寧に測った 2 つの結果が、4 分の 1 ほど食い違ったからです。

| 確認で見つかったもの | 何が起きるか |
|---|---|
| 新規も変更もない | `Workflows: unchanged - nothing new and nothing edited` と表示して LocalCanvas が起動します。同期も変換も質問もありません。 |
| 新規または変更があり、ターミナルにいる | `Workflows: 1 new, 2 changed` のような 1 行の要約に続けて `Sync workflows now? [Y/n]`。**Enter は「はい」です。** |
| 新規または変更があり、尋ねる相手がいない | 質問も待機もしません。何が変わったかを告げ、`pwsh .\scripts\sync-workflows.ps1` を示し、すでにあるカタログで起動します。 |

**はい**と答えると、下の「手で取り込む」と同じインポーターが走り、そのあと起動が
続きます。それ以外の答えは拒否で、何も書かれず、LocalCanvas はすでにあるカタログ
で起動します。

「尋ねる相手がいない」セッションとは、タスクスケジューラ、CI のステップ、
パイプ、`-NonInteractive` のシェルのことです。そうしたセッションで LocalCanvas が
勝手に同期することはありません。ComfyUI での保存は実験や作りかけのグラフである
ことが多く、スマートフォンに突然それが出てくるべきではないからです。

答えがもうわかっているときのためのスイッチが 2 つあります:

```powershell
pwsh .\scripts\start.ps1 -SyncWorkflows      # 変わったものを、尋ねずに同期する
pwsh .\scripts\start.ps1 -SkipWorkflowCheck  # フォルダーをまったく見ない
```

`-SyncWorkflows` でも最初に軽い確認は走るので、誰も触っていないフォルダーなら
スイッチなしと同じ時間しかかかりません。`-SkipWorkflowCheck` は、遅いディスク上の
とても大きなフォルダーや、何も変わっていないとわかっている起動のためのものです。
2 つは矛盾するので、両方を渡すと拒否され、何も起動しません。

### 取り込めなかったワークフロー

**Save** で保存したワークフローが変換できなかった場合は、*理由*によって扱いが
変わります:

- **次回もう一度提案されます。** 変換を試みることすらできなかったとき —— Chrome
  も Edge もない、あるいは ComfyUI の準備ができていなかったとき —— は、次の起動で
  `N not converted last time` として、同じ `Sync workflows now? [Y/n]` の質問と
  ともにもう一度提案されます。原因を直して（ComfyUI を起動する、ブラウザーを
  入れる）「はい」と答えてください。
- **確認が必要です。** ComfyUI がそのグラフを拒否したとき、または変換後のグラフを
  LocalCanvas が確信をもって読めなかったときは、ファイルが変わるまで起動のたびに
  `N workflow file(s) need a look` と表示されます。
  `pwsh .\scripts\sync-workflows.ps1 -DryRun` でどのワークフローがなぜそうなった
  のかを確かめ、ComfyUI で直して保存し直してください —— 変わったファイルは、
  ほかのものと同じようにまた提案されます。

取り込み済みのワークフローは、変わらないかぎり繰り返し報告されることはありません。

**ComfyUI のフォルダーから削除したワークフロー**は、起動のたびに
`no longer in your folder` と報告されます。**カタログから自動で削除されるものは
ありません。** この報告は `config/local/workflow-inventory.json`（見つかったものの
記録）から来ているので、報告を止めるのはそこからそのワークフローの項目を消すこと
です —— `config/local/workflows` の定義を消すとスマートフォンからは見えなくなり
ますが、報告は残ります。`config/local/workflow-sources.yaml` で
`detect_removed: false` にすると、この報告は完全に止まります。いつもつないでいる
とはかぎらないドライブにフォルダーがあるときのための設定です。

### 手で取り込む

```powershell
pwsh .\scripts\sync-workflows.ps1 -DryRun
pwsh .\scripts\sync-workflows.ps1
```

**先に ComfyUI を起動してください** —— `-DryRun` でも同じです。ドライランは何も
書きませんが、何が取り込まれるかを言うために、**Save** で保存したワークフローの
変換を ComfyUI に実際に頼みます。応答がないと、そうしたファイルをあきらめるまでに
最大 4 分かかることがあります。`-NoConvert` は ComfyUI に何も尋ねない速い報告で、
そうしたファイルはすべて `NEEDS_API_EXPORT` と表示されます。

ドライランは、取り込むもの、確認のために保留するもの、変換できなかったものを
すべて理由とともに挙げます。スマートフォンにワークフローが出てこないときに読む
べきなのはこの報告です。`Converted by ComfyUI` の行は、変換したもの、前回の
結果を再利用したもの、拒否されたもの、試さなかったものを数えます。本番の実行が
書くのは次のものです:

| 何を | どこに |
|---|---|
| 読んで編集できる定義 | `config/local/workflows` |
| API 形式グラフの自前のコピー | `config/local/imported-workflows` |
| 今回見つかったもの | `config/local/workflow-inventory.json` |

生成された定義は自由に編集できます。後の実行がそれを書き直すのは、元の
ワークフローが変わったときだけで、名前、表示設定、翻訳の設定、あなたが書いた
ラベルと説明文はすべて残します。生成されたものに戻したいときは
`-RegenerateLabels` を付けます。`-DryRun` と一緒なら、何を置き換えるかを正確に
挙げ、何も書きません。

**確信をもって読めないワークフローは、推測せずに保留します。** 何が決められな
かったか —— グラフならそのノードと入力 —— を名指しする一文とともに
`NEEDS_REVIEW` と報告され、定義は書かれません。ほかのワークフローはすべて
取り込まれ、それでも取り込ませるスイッチはありません。抜け道は 2 つで、どちらが
よいかはその一文しだいです:

1. **問題が消えるようにワークフローを変える。** 多くは、インポーターが入力として
   読めない使われ方をしているノードです —— ComfyUI でつなぎ直すか置き換え、
   保存して、もう一度同期します。
2. **その定義を 1 つだけ自分で書く。** 定義は、生成されたものと並べて
   `config/local/workflows` に置く小さな YAML ファイルです。形式は
   [`workflow-schema.md`](workflow-schema.md) にあり、
   [`../workflows/examples/`](../workflows/examples/) には完全な作例が 3 つ
   —— プロンプトだけ、画像入力、動画入力 —— あるので、写して使えます。
   あなたが書いた定義に、インポーターは手を出しません。

どちらの場合も、ゲートウェイを起動し直す前にフォルダーを確かめてください ——
ComfyUI も GPU もネットワークも要りません:

```powershell
.\.venv\Scripts\python.exe -m localcanvas_gateway.workflows config\local\workflows
```

    [ OK ] my-portrait (11 fields) - config\local\workflows\my-portrait.yaml
    2 workflows loaded, 0 rejected, from config\local\workflows

拒否された定義は、ファイル、ワークフロー、問題とともに示され、残りはそのまま
読み込まれます。

### 同期そのものがうまくいかないとき

失敗したインポーターの実行も、そもそも走れなかった確認も、同じように扱われます:
**すでにある定義はそのまま残り**、LocalCanvas はそれがいくつあるかを告げます。
ターミナルでは続けて `Start LocalCanvas anyway? [Y/n]` と尋ね、既定は「はい」
です。尋ねる相手がいなければ、報告して続行します。止まるのは、戻れるカタログが
1 つも無いとき（起動しても、アプリはつながった先で生成に使えるものを何も見つけ
られないからです）か、その質問に「いいえ」と答えたときだけで、その場合は終了
コード **6** で、ゲートウェイは起動しません。

### ゲートウェイはカタログを起動時に一度だけ読みます

だから、起動時に受け入れた同期はゲートウェイの起動前に反映されていて、ゲートウェイ
が動いている*最中*に実行した同期は反映されません。反映させるには:

```powershell
pwsh .\scripts\stop.ps1
pwsh .\scripts\start.ps1
```

`setup.ps1` ができる前に `config/local/runtime.yaml` を手で書いていたなら、
`workflows.registry` も確かめてください。インポーターが書き込むフォルダー、
`config/local/workflows` を指している必要があります。setup が書いた設定なら、
すでにそうなっています。

## 5. アプリを入れる

リポジトリそのものに APK は入っていません。リポジトリがリリースを公開していれば、
いちばん簡単なのはその **Releases** ページです。APK をダウンロードし、下のとおり
インストールしてください。そうでなければ、自分でビルドします。

### 自分でビルドする

`app/` から:

```powershell
flutter pub get
flutter build apk --release --split-per-abi
```

Flutter がまだ入っていなければ、**Flutter 自身の Windows 向け手順**
<https://docs.flutter.dev/get-started/install> から始めてください。SDK を入れ、
Android 側の準備も案内してくれます（Android Studio が Android SDK を一緒に
持ってきます）。このガイドで最も長い手順であり、1 つのプログラムではなくツール
チェーン一式を入れる唯一の手順です。

そのあと `flutter doctor` が足りないものを挙げ、
`flutter doctor --android-licenses` が Android SDK のライセンスに同意する一度きりの
手順です。同意はあなたと Google の間の取り決めなので、ここにあるスクリプトが代わりに
行うことはありません。`flutter doctor` が Android のツールチェーンについて問題なしと
言えば、上の 2 つのコマンドが通ります。

APK は `app/build/app/outputs/flutter-apk/` に、ABI ごとに 1 つずつ、
`LocalCanvas-<version>-<abi>.apk` という名前でできます。たいていのスマートフォンに
必要なのは `arm64-v8a` です。`flutter install`、
`adb install`、あるいはファイルをスマートフォンへコピーしてインストールして
ください。コピーした場合、Android はそのアプリからのインストールを許可するか
尋ねます。ストアからではなく手動で入れているからです。

### CI のビルド

リポジトリの **APK** ワークフロー（`.github/workflows/apk.yml`）が、`main` への
push のたびに、また手動でも、同じビルドを実行します。その実行が見られる場合は、
実行ページ下部の成果物 **`LocalCanvas-apk-debug-signed`** が APK 3 つの入った
zip です。成果物の保存期間は **14 日**なので、ブックマークしないでください。

### ここにある APK はすべてデバッグ鍵で署名されています

**リリース署名は設定していない**ので、リリースのビルドタイプにはデバッグの署名
設定が入っており、自分のビルドも CI のビルドも、すべて Android のデバッグ鍵で
署名されます。これは
サイドロード用のビルドです。検証されたリリース成果物でも配布用でもなく、
プロジェクトが署名したものでもなく、自分でビルドしたものより信頼できるわけでも
ありません。

そこから、入れる前に知っておくべき帰結が 1 つあります。**デバッグ鍵はマシンごとに
生成され、次の実行でも同じものにはなりません** —— CI のランナーとあなたの PC では
違い、次の実行とも違います —— そして Android は別の鍵で署名された更新を
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`（*signatures do not match*）で拒否します。
ですから新しい APK を古いものへ上書きインストールすると失敗することがあり、進む道
はいったん LocalCanvas をアンインストールすることです。
アプリに保存された設定もそのとき消えるので、気になるなら先にプロファイルを
書き出しておいてください（第 12 節）。

署名を自分で確かめるには `apksigner verify --print-certs` を使ってください。
これらの APK には v1（JAR）署名がまったく無いので（アプリの最小 SDK は 24）、
`keytool -printcert -jarfile` は *Not a signed jar file* と答えるだけで、何も
教えてくれません。

## 6. Wi-Fi でつなぐ

PC を動かしたままアプリを開きます。入り口は 4 つあり、どれが上ということはなく、
どれもアドレスが受け入れられる前に同じハンドシェイクで終わります。

1. **記憶したサーバー** — 最後に成功したアドレスを起動時に試します。
2. **「On this network（このネットワーク上）」** — ゲートウェイが mDNS で自分を
   知らせ、アプリは見つかったものを並べます。マルチキャストを通さないルーターや
   VPN もあります。それは異常ではなく、アプリは残り 3 つを出すだけです。
3. **「Scan pairing code（ペアリングコードを読み取る）」** — `start.ps1` が表示した
   QR コードです。完全にローカルで、QR サービスも短縮 URL も使わず、コードの中に
   秘密は入っていません。
4. **「Enter address（アドレスを入力）」** — つねに選べます。`192.0.2.42`、
   `192.0.2.42:7801`、`http://192.0.2.42:7801` のどれでも動きます（あなたの PC の
   アドレスで）。既定のポートは 7801 です。

何かが応答したのにそれが LocalCanvas でない場合や、API のバージョンが違う場合は、
アプリがどちらなのかと何をすればよいかを伝えます。

**いちばんありがちな障害物は Windows ファイアウォールです。** ゲートウェイは
ポートで待ち受ける新しいプログラムで、Windows は誰かが許可するまでネットワーク
からの接続を遮ります。初めて `start.ps1` を実行したときに *Windows Defender
ファイアウォール*のダイアログが出るはずなので、**プライベートネットワーク**に
チェックを入れてください。パブリックではありません —— ゲートウェイに認証は無く、
自分の LAN の中だけにいるべきものだからです。ダイアログが出なかったり閉じて
しまったりすると、PC 側は何もかも正しく見えるのにスマートフォンは届きません。
QR コードは読み取れ、アドレスも合っているのに、接続がタイムアウトします。

`pwsh .\scripts\doctor.ps1` はゲートウェイのポートと、そこで何かが待ち受けて
いるかを報告します。ファイアウォールの規則そのものは管理者として実行したときだけ
読みます —— 昇格せずに実行した場合、そしてそれが文書化された実行方法ですが、
推測せず *not measured, needs Administrator* と報告します。既存の規則を手で確認
したり直したりするのは Windows の**セキュリティが強化された Windows Defender
ファイアウォール**で、[`privacy-security.md`](privacy-security.md) には、さらに
踏み込んだ、元に戻せる任意の `scripts\strict-lan.ps1` の説明があります。

## 7. 何かを作る

ワークフローを選ぶと、そのワークフローが宣言したフォームをアプリが描きます。
プロンプトを書き、ほかに求められているものを埋めて、
**「Generate（生成）」**を押します。

実行中は正直な状態が見えます —— アップロード中、待機中、生成中 —— で、バックエンド
が進捗を報告する場面では実測の進捗を、報告しない場面では不確定のインジケーターを
出します。作り物のパーセントは出しません。ワークフローが対応していれば
**「Cancel（中止）」**があります。

結果は大きく開きます。ほぼ全画面で見て、ギャラリーに**「Save（保存）」**し、Android
標準の共有シートで**「Share（共有）」**し、**「Generate Again（もう一度生成）」**を
押せます。

**「Generate Again」とシード。** 役割がシードである項目のシードをすべて振り直し、
新しい数値を項目に書き戻します。ですから画面に見えているシードは、つねに送られた
シードです。フォームのほかの部分は変わりません。「Advanced（詳細設定）」には
**「Freeze seed（シードを固定）」**のスイッチがあり、既定はオフで、オンにすると
「Generate Again」が同じシードをそのまま使います。

このセッションの結果をさかのぼるのは、メモリー上の小さな状態です。個数に上限のある
リストで、バイト列は保持せず、何も書き残さず、アプリを閉じれば何も残りません。
ギャラリーもデータベースの履歴もありません —— そう決めたからです。

## 8. 画像や動画から作る

定義が画像入力や動画入力を持つワークフローでは、ファイルの選択画面が出ます。写真や
動画を選び、プレビューを見て、差し替えたり外したりでき、アップロード中は実バイト数
の進捗が見えます。

**HEIC の写真はこちらで処理します。** 最近の Samsung や iPhone のカメラは既定で
HEIC で保存します。LocalCanvas はファイル名ではなく*バイト列*を見て、HEIC や HEIF の
写真を**スマートフォン上で** JPEG に変換してからアップロードします。ほかのファイルは
バイト単位でそのまま通ります —— PNG は透過を保ち、JPEG は再エンコードされません。
スマートフォンに HEIF のデコーダーがない場合やデコードに失敗した場合は元のファイルが
アップロードされ、ゲートウェイが形式を名指しするメッセージとともに拒否します
（トラブルシューティングを参照）。

**動画の結果**にはローカルのプレビューと再生がつき、「Save」と「Share」も使えます。
大きな動画ほどアップロードに時間がかかります。`media.max_video_megabytes`
（`config/local/runtime.yaml` の中）がゲートウェイの課す上限で、拒否のメッセージは
その値を示します。

アップロードされたファイルは PC 上の一時領域に、それ自身の寿命
（`media.ttl_seconds`、既定で 1 時間）とともに置かれます。すでに期限切れのファイルを
参照する生成は、不可解に失敗するのではなく、そう伝えてもう一度そのファイルを求めます。

## 9. Main と Advanced

どのワークフローも、重要な少数の項目を先に見せ、残りは**「Advanced（詳細設定）」**の
中にしまいます。どちらに入るかはワークフローの定義が決めることで、アプリの推測では
ありません。アプリが理解するのは項目の*型*と*見せ方*であって、モデルやチェックポイント
やノードグラフのことは何も知りません。グループ分けも設定の一部です —— 見出しの名前は
あなたの定義から来ますし、知らないグループはそれ自身の見出しとして描かれます。
ワークフローのカードの上にあるフィルターで、一覧を 1 つのグループに絞ったり、
**「All（すべて）」**に戻したりできます。

## 10. 自分の言語でプロンプトを書く

任意機能で、既定はオフ、動くのはあなたの PC の上です。`prompt_translation`
（`config/local/runtime.yaml` の中）をオンにすると、`sources` に挙げた言語で
書かれたプロンプトが、
生成が組み立てられる前に `target` へ翻訳されます。判定は文字の種類によります。
キリル文字も仮名も含まないプロンプトは、書いたとおりそのまま残ります。
`"二重引用符"` の中にあるものは翻訳器に渡されないので、看板の文字や固有名詞は
書いたままになります。

これにはおよそ 1 ギガバイトの追加インストール —— 入るのは LocalCanvas 自前の
`.venv/` で、ComfyUI のそばではありません —— と、書く言語ごとに 1 つの言語ペアが
必要です。`--editable` が大事です。setup が入れたときと同じく、ゲートウェイを
このチェックアウトから入れたままにします。

```powershell
.\.venv\Scripts\python.exe -m pip install --editable ".\gateway[translation]"
.\.venv\Scripts\argospm.exe update
.\.venv\Scripts\argospm.exe install translate-ru_en
```

生成中に何かがダウンロードされることはありません。ダウンロードはこのインストール
だけで、しかもあなたが頼んだから起こります。同じコマンドは
`config/examples/runtime.example.yaml` の `prompt_translation` ブロックのそばの
コメントにもあり、そこには残りの設定の説明もあります。インストールせずに有効に
しても黙って失敗することはありません。何が足りないかを「Generate」を押す前に
アプリが伝え、翻訳が必要なプロンプトは、どのインストールが無いのかをそのまま
報告します。どの言語ペアが入っているかはゲートウェイの起動時に読まれ、その出力に
表示されます（`Translation: ru->en`）。動いている間に入れたペアは、次に起動した
ときに拾われます。

アプリが表示するのも、下書きが保存するのも、「Generate Again」が送り直すのも、
つねにあなたの原文です。翻訳があなたの言葉を置き換えることはありません。

## 11. My defaults、下書き、保存したセットアップ

あえて別物にしてある 3 つです:

- **My defaults（自分の既定値）** — *いつもこうしたい、は何か。*
  **「Save settings as my defaults（設定を自分の既定値として保存）」**がそのワーク
  フローの現在の値を記録し、**「Reset settings to my defaults（設定を自分の既定値に
  戻す）」**がそれを呼び戻します。**「Reset settings to workflow defaults（設定を
  ワークフローの既定値に戻す）」**は定義を書いた人が宣言した値に戻します。
- **下書き** — *途中まで何をしていたか。* ワークフローごとに 1 つ、自動で保存され、
  上書きされます。文章と設定は戻ってきますが、メディアの項目はあえて空で戻ります。
  下書きを読み直す頃にはアップロード済みファイルの id はたいてい期限切れなので、
  フォームはもう一度画像を求めます。
- **Setups（セットアップ）** — 残しておくと決めた、名前つきの組み合わせです。設定
  だけ、またはプロンプトと設定の両方を保存し、名前を付け、変え、忘れさせられます。

## 12. 別のスマートフォンへ移る

**Your profile（あなたのプロファイル）**は、保存した設定とセットアップを 1 つの
ファイルにしたものです。書き出して、好きな方法でファイルを移し、もう一方の
スマートフォンで読み込みます。中にサーバーのことも、生成したものも入っていません。
読み込みは既にあるものを消しません —— 読み込んだ内容を適用するには**「Reset settings
to my defaults」**を使ってください。外観とアプリの言語は端末に属するもので、あえて
プロファイルには入れていません。より新しい LocalCanvas が書いたプロファイルは、
中途半端に読まれるのではなく、そうと名指しして拒否されます。

## 13. うまくいかないとき

**スクリプトが起動を拒否する: 「cannot be run because it contained a `#requires`
statement」。** Windows PowerShell 5.1 で実行しています。LocalCanvas はこのシェル
をサポートしておらず、ここにあるスクリプトはすべて PowerShell 7 以降が必要です。何も
読まれず、書かれず、起動されていません。このメッセージは Windows 自身が出すもので、
システムの言語で表示され、ウィンドウ幅で折り返されます（中のバージョン番号が 2 行に
分かれることがあります）。また要件を「Windows PowerShell 7.0」と呼びますが、そのような
製品はありません。必要なのは PowerShell 7 で、コマンドは `pwsh` です。
<https://aka.ms/powershell> から、または `winget install --id Microsoft.PowerShell`
で入れて、このガイドのコマンドは `pwsh` のウィンドウで実行してください。今どちらにいる
かを見るには:

```powershell
$PSVersionTable.PSVersion
```

自分のスクリプトからこれらのスクリプトを呼ぶ場合にもう一点: この拒否は終了コードでは
なくエラーなので、`$?` を調べてください。`$LASTEXITCODE` ではありません。

**まず doctor を走らせてください。**

```powershell
pwsh .\scripts\doctor.ps1
```

何も起動せず、ファイルも書かず、何も変えません。終了コードは次のとおりです:

| 終了コード | 意味 |
|---|---|
| **0** | 行えた点検はすべて問題なしでした。 |
| **2** | 失敗はないが、少なくとも 1 つの点検が行えなかったか、対処する価値のある警告が出ました。設定ファイルが無い・読めない場合も 2 です。 |
| **3** | 何かが失敗しました。 |

最後まで走った実行では、末尾の要約がすべての点検を数え上げ、終了コードはその要約
から導かれたものです。**そこまで行けずに終わり、要約をまったく出さない失敗が
2 つあります**: `.venv/` がまだ無い場合と、設定を読めなかった場合です。どちらも
対処法つきの `[FAIL]` の行を 1 本出してそこで止まります。その先は診断できないから
です。環境が無い場合は終了コード 3、設定が読めない場合は 2 で、これはここにある
どのスクリプトも設定を読めないときに返すコードと同じです。

ファイアウォールのポートフィルターを読むには管理者権限が必要です。昇格せずに走らせた
場合 —— そしてそれが文書化された走らせ方です —— その点検だけは *not measured, needs
Administrator* と報告され、問題のない実行を 2 に変えることはありません。

**setup が、サポート対象の Python がないと言う。** Python 3.10 – 3.13 を
<https://www.python.org/downloads/> から入れて `pwsh .\scripts\setup.ps1` をもう
一度実行するか、`-PythonExe` でインタプリタを指定してください。何も作られては
いません。

**setup がパラメーターを挙げて止まる。** 質問に答える人のいない場所で実行された
ので、先に答えておくためのパラメーター —— `-Mode`、`-ComfyRoot`、
`-WorkflowSource`（第 3 節）—— を挙げ、何も書かずに止まりました。

**`start.ps1` が `ComfyUI is not reachable` と出して 4 で終わる。** ComfyUI が
動いていないか、`config/local/runtime.yaml` の `comfy.host`/`comfy.port` が
間違っています。外部モードでは LocalCanvas が ComfyUI を代わりに起動することは
ありません。起動してから、もう一度 `start.ps1` を実行してください。

**「That photo is in HEIC format, which LocalCanvas cannot use yet.（その写真は HEIC
形式で、LocalCanvas はまだ扱えません。）」** スマートフォン側で HEIC をデコードできず、
元のファイルがゲートウェイに届いて拒否されました。JPEG か PNG を選ぶか、カメラの設定
で高効率（HEIC）写真をオフにしてください。

**アプリにワークフローが出てこない、または 1 つもない。** ComfyUI を起動した
状態で `pwsh .\scripts\sync-workflows.ps1 -DryRun` を走らせ、報告を読んで
ください。`NEEDS_REVIEW` と出ているワークフローは、確信をもって判断できないことが
あったため保留されていて、その行に何がだめだったかが書かれています。
`NEEDS_API_EXPORT` と出ているワークフローは **Save** で保存されたもので、変換
できる ComfyUI（または Chrome か Edge）がありませんでした —— それを直して同期し
直してください。ゲートウェイが動いている間に同期した場合は、停止して起動し直して
ください。カタログは起動時に一度だけ読まれます。そのあと、アプリで
**Refresh the list**（一覧を更新）をタップします。

**起動のたびに `N workflow file(s) need a look` と出る。** ComfyUI がそれらの
ファイルの変換を拒否したか、LocalCanvas が確信をもって読めなかったか、そもそも
ワークフローではないファイルです。`pwsh .\scripts\sync-workflows.ps1 -DryRun` が
1 つずつ理由とともに挙げます。ComfyUI で直して保存し直せば、次の起動で提案され
ます（第 4 節）。

**起動のたびに `N not converted last time` と出る。** それらは **Save** で保存
されたワークフローで、前回の取り込みで変換できませんでした —— Chrome も Edge も
なかったか、ComfyUI の準備ができていなかったためです。原因を直し、
`Sync workflows now? [Y/n]` に「はい」と答えてください。

**起動のたびにワークフローが `no longer in your folder` と出る。** ComfyUI から
それを削除したということです。LocalCanvas が自分から定義を消すことはありません。
この報告は `config/local/workflow-inventory.json` の項目から出ているので、終わらせる
にはその項目を消します。`config/local/workflows` の定義を消しても終わりません
（実測）。あるいは `config/local/workflow-sources.yaml` で
`detect_removed: false` にすれば、報告そのものが止まります。

**`start.ps1` が 6 で終わる。** ワークフローの層を用意できず、しかも起動に使える
カタログが無かったか、`Start LocalCanvas anyway? [Y/n]` に「いいえ」と答えたので、
ゲートウェイは起動していません。何が起きたかは、その上のメッセージに書かれて
います。そこで名指しされたものを直してから
`pwsh .\scripts\sync-workflows.ps1` を実行してください。

**`start.ps1` が `Workflows: no folder is configured yet` と出す、または
`sync-workflows.ps1` が `No workflow folder is configured yet` で止まる（終了
コード 2、ファイルは何も書かれない）。** setup がワークフローの場所を判断
できなかったので、まだ `config/local/workflow-sources.yaml` がありません。
フォルダーを一度だけ指定してください:

```powershell
pwsh .\scripts\setup.ps1 -WorkflowSource '<your workflow folder>'
```

この実行はソース一覧を書くだけで、ほかは何も変えません。

**スマートフォンが PC を見つけられない。** 家庭用ネットワークでは mDNS が通らない
ことがよくあります。QR コードを使うか、アドレスを入力してください。どちらも mDNS に
依存しません。それでも届かないならファイアウォールです。ゲートウェイのポートが
Windows ファイアウォールの**プライベート**ネットワークで許可されているかを確かめて
ください（第 6 節）。

**「Connected, but ComfyUI isn't running.（接続できましたが、ComfyUI が動いていま
せん。）」** ゲートウェイは応答し、ComfyUI は応答しませんでした。PC で ComfyUI を
起動するか、`comfy.host` と `comfy.port`（`config/local/runtime.yaml` の中）を
確かめてください。

**生成の途中で接続が切れた。** アプリは自動で再接続し —— 1 回から 10 回、既定は
3 回で、端末ごとに設定できます —— そのあとゲートウェイにジョブが生き残ったかを
尋ねます。判断できないときは、推測せずにそう伝えます。

**いま何が動いているのか。**

```powershell
pwsh .\scripts\status.ps1
```

読み取り専用です。何が上がっていて、どれが LocalCanvas のもので、接続先はどこかを
示します。

## 14. 止める

```powershell
pwsh .\scripts\stop.ps1
```

止めるのは LocalCanvas 自身が起動したプロセスだけです。すでに動いていた ComfyUI を
再利用した場合や、外部モードの場合は、それに触れずにその旨を伝えます。
`start.ps1` を実行したウィンドウを閉じても、ゲートウェイは止まります。

1 つだけ、あなたが片づけるものがあります。入力ファイルをローダーノードに渡すには
ComfyUI 自身のアップロード用エンドポイントに渡すしかなく、ComfyUI はそれを保持し
ます。LocalCanvas はそれらをすべて ComfyUI の入力ディレクトリの中の 1 つの
`localcanvas/` サブフォルダーにまとめるので、一度の操作で空にできます —— 自分で
削除することはできません。

---

## さらに読む

以下のドキュメントは英語のみです。

- [SECURITY.md](../SECURITY.md) — セキュリティモデルと問題の報告方法。
- [`privacy-security.md`](privacy-security.md) — プライバシーに関する主張の全文。
  任意の、マシン単位の厳格 LAN モードを含みます。
- [`workflow-schema.md`](workflow-schema.md) — 定義の形式。インポーターが書いたもの
  を手直ししたい場合や、手で書きたい場合に。
- [`../workflows/examples/README.md`](../workflows/examples/README.md) — 完成した
  例が 3 つ: プロンプトのみ、画像入力、動画入力。
- [`connection.md`](connection.md)、[`recovery.md`](recovery.md) — ペアリング、
  再接続、ジョブの復帰の詳細。
