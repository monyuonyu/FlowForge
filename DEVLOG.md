# FlexSim風 離散事象シミュレータ（Godot 4.x）

FlexSim のような「モノの流れ」を3Dで可視化・編集できる離散事象シミュレーション（DES）です。
Source→Queue→Processor→Conveyor→Sink とアイテムが流れ、作業者（共有資源）を奪い合いながら
加工が進みます。**外部3Dモデルの取り込み**・**マウスでの配置編集**・**組み込みスクリプト実行
エンジン（FlexScript相当）**・**モデルのJSON保存/読込**・**CAD系機能（縮尺グリッド・スナップ・
メジャー・正射投影/ビュープリセット・数値トランスフォーム）**を備えています。

Godot 4.7.1 でインポート〜実行〜スクリプト実行〜モデル往復まで動作確認済み。

> **v2（エンジン刷新）**: レビュー指摘を受け、コアを**イベント駆動DES**に書き換えました。
> 乱数はシード管理された独立ストリームで**完全再現**（同一シード＝同一結果）。warmup期間の
> 統計切り捨て、Nレプリケーションの**信頼区間つき実験**とCSV出力に対応。詳細は「⑥」参照。

## ⑦ 分析・部品・安全性の拡充（v3）

レビュー指摘の残り（統計/モデリング語彙/セキュリティ/可視化）を実装しました。

### 統計（`Sim.gd`, `Queue.gd`, `Sink.gd`）
- **時間加重WIP**：系内在庫を時間積分した平均（`仕掛(時間平均)`）。単純な瞬間値でなく定常評価。
- **待ち行列統計**：各Queueの**平均待ち行列長 Lq**（時間加重）と**平均待ち時間 Wq**を表示。
- **滞留時間ヒストグラム**：出口に到達したアイテムのリードタイム分布（画面右下、平均線つき）。
- 検証：`WIP ≈ スループット × 滞留時間`（リトルの法則）が数値的に整合（15.9 ≈ 0.09×170）。

### モデリング語彙（`Combiner.gd`, `Separator.gd`）
- **Combiner（組立）**：`batch_size` 個を集めて1個に統合（消えた分はWIP減算）。検証 100→33。
- **Separator（分割）**：1個を `split_qty` 個に分割（増えた分はWIP加算）。検証 100→200。
- 編集モードの追加ボタンから配置可能。

### スクリプトの安全性（`ScriptEngine.gd`, `UI.gd`）
- スクリプトを含むモデルを読み込む際、**実行するかの確認ダイアログ**を表示（他人のモデルを
  開いた瞬間に任意コードが走るのを防止）。「無効化して読込」でコードを実行せず構造だけ復元。

### 可視化・編集・性能（`ConnectionViz.gd` ほか）
- **接続の矢印表示**：設備間のルーティングを3Dの矢印で可視化（ドラッグに追従）。
- **作業者の追加/削除**：編集モードのツールバーから増減。
- **性能改善**：3Dラベル/状態灯・稼働率バーのスタイルを毎フレーム再生成せず変化時のみ更新。

> 残った任意課題：超大規模モデル向けの FlowItem の MultiMesh 描画（正確性には影響せず、
> 数千アイテム同時表示時の描画最適化のみ）。必要になった段階での対応で十分です。

## ⑥ シミュレーション基盤（v2：イベント駆動・再現性・実験）

### イベント駆動エンジン（`Sim.gd`）
時間ステップ式をやめ、**イベントカレンダー（二分ヒープ）**で「次のイベント時刻へジャンプ」する
本来のDES方式にしました。これにより (a) 8時間分を一瞬で回せる `run_until(t)`、(b) 結果が
フレームレート・更新順に依存しない決定的な実行、が可能になりました。見た目（アイテムの移動）は
ロジックと分離し、目標位置への補間で描画します。

### 乱数シードと再現性（`RngStreams.gd`）
全乱数はマスターシードから導出した**目的別・設備別の独立ストリーム**（`設備id:proc` 等）で生成。
上部バーの「種(seed)」で指定し、リセット時に再シードされます。**同一シードなら毎回まったく同じ
結果**（検証済み：`53/138.382` が2回とも一致）。共通乱数法によるA/B比較の土台にもなります。

### warmup（立ち上がり除外）
上部バーの「warm」で warmup 時間を指定。その時刻で統計をリセットし、空の系が埋まるまでの
過渡期を除外した定常状態の数値を評価します。

### 実験（Nレプリケーション＋信頼区間＋CSV）
「🧪 実験」ボタンで、指定した反復数・実行長・warmup・seed で**瞬時に複数回**実行し、
スループットと滞留時間の**平均±95%信頼区間**を算出、`user://experiment.csv` に出力します。
```
rep,throughput_per_hour,leadtime_s,wip
1,330.803,172.595,43
...
mean,336.260,170.809,
ci95,3.242,1.220,
```

### 修正した主なバグ（レビュー指摘）
作業者は完了時に解放し**ブロック中の稼働率水増しを解消**／作業者割当を**FIFO公平化**／
故障・段取りをイベント化／複数Source・Sinkの**KPI集計**／設備IDをアイテムIDと分離して**衝突回避**／
ドラッグ配置の地平線クリックでの**INF飛び防止**／構造編集時はイベントカレンダーを再構築して
**削除時のWIP破綻・幽霊イベントを解消**／`select_output` 範囲外は警告してフォールバック。


---

## 動かし方

1. [Godot Engine 4.x](https://godotengine.org/) をインストール（4.2〜4.7 で動作想定）。
2. Godot を起動し「インポート」から本フォルダの `project.godot` を選択。
3. F5 で実行。左上「▶ 開始」でシミュレーション開始。

### 画面と操作
- **実行バー（左上）**：開始/一時停止・リセット・速度・時計・編集モード・保存/読込
- **カメラ**：右ドラッグ=回転 / 中ドラッグ=平行移動 / ホイール=ズーム
- **右パネル**：KPI と各設備の状態・稼働率、作業者稼働率
- **下パネル**：コンソール（スクリプトの `sim.log()` 出力やエラーを表示）
- 各設備上の球（状態灯）：灰=待機/空、青=生成、黄=滞留、緑=稼働、橙=作業者待ち、赤=ブロック

---

## ① 外部3Dモデルの取り込みと配置（編集モード）

上部の「🔧 編集モード」を押すと編集モードに入り、シミュレーションは一時停止します。

- **選択**：設備をクリック（水色の枠で選択表示）
- **移動**：ドラッグで地面上を移動（コンベヤは搬送経路も一緒に移動）
- **追加**：ツールバーの `Source/Queue/Processor/Conveyor/Sink` ボタン
- **削除**：🗑 削除
- **3Dモデル割当**：インスペクタの「🧩 3Dモデルを割り当て…」でファイル選択
  （**.glb / .gltf / .obj** に対応。glTFはマテリアル込み、OBJは頂点/面を読込）
- **接続**：インスペクタ下部で接続先を選び「→ 接続」

`models/` に見本アセット（machine / conveyor / buffer / source / sink / operator / robot_arm）を
同梱しています。実行時に `GLTFDocument` で直接読み込むため、Godotのインポート要否に依存しません。

> 実装：`scripts/AssetLoader.gd`（glTF実行時ローダ＋簡易OBJパーサ、キャッシュ付き）

---

## ② 組み込みスクリプト実行エンジン（FlexScript 相当）

各設備に **GDScript** を書いて、シミュレーションのイベントで実行できます。実行時にコンパイル
され（ホットリロード）、エラーやログはコンソールに出ます。インスペクタのスクリプト欄に書いて
「▶ スクリプト適用」。

スクリプトは `extends LogicBase` で書き、使いたいイベントだけ実装します。

```gdscript
extends LogicBase
# 使えるもの: obj（この設備）, sim（API）

func on_create(item):                 # Source: アイテム生成時
    item.set_label("priority", sim.rand_int(1, 3))

func on_entry(item):                  # 受け取った時
    sim.log("%s got item %d" % [obj.obj_name, item.id])

func process_time():                  # 加工時間を上書き（負数で既定分布）
    return sim.normal(6.0, 1.0)

func on_process_finish(item):         # 加工完了時
    sim.log("done %d, age=%.1fs" % [item.id, item.age()])

func select_output(item):             # 送り先ポートを選択（-1で既定）
    return 0 if item.item_type == 0 else 1
```

### 利用できるイベント / オーバーライド
| メソッド | タイミング | 対象 |
|---|---|---|
| `on_reset()` | リセット時 | 全設備 |
| `on_create(item)` | アイテム生成 | Source |
| `on_entry(item)` | 受け取り | 全設備 |
| `on_exit(item)` | 送出 | 全設備 |
| `on_process_start/finish(item)` | 加工開始/完了 | Processor |
| `process_time()` → float | 加工時間の決定 | Processor |
| `interarrival()` → float | 発生間隔の決定 | Source |
| `select_output(item)` → int | 出力ポート選択 | 分岐のある設備 |

### `item`（アイテム）API
`item.id` / `item.item_type` / `item.age()` / `item.set_color(Color)` /
`item.set_label(key, value)` / `item.get_label(key, default)` — ラベルは FlexSim の
「ラベル」に相当する任意属性です。

### `sim`（SimAPI）
`sim.now()` / `sim.log(msg)` / `sim.rand(a,b)` / `sim.rand_int(a,b)` /
`sim.exp(mean)` / `sim.normal(mean,sd)` / `sim.uniform(a,b)` / `sim.find(id)`

> 実装：`scripts/ScriptEngine.gd`（実行時GDScriptコンパイル）, `scripts/LogicBase.gd`,
> `scripts/SimAPI.gd`。ユーザーコードは `GDScript` を実行時に `reload()` して本当に実行します。

---

## ③ モデルの保存 / 読込（JSON）

- 「💾 保存」→ `user://model.json` に現在のモデル（設備・位置・接続・パラメータ・
  割当モデル・スクリプト）を保存。
- 「📂 読込」→ `user://model.json` を読込んで再構築。
- 「JSON…」→ 任意パスのJSONを開く。
- 起動時、`user://model.json` があればそれを、無ければ同梱のサンプル工場を読み込みます。

`user://` の実体は OS により異なります（Windows: `%APPDATA%/Godot/app_userdata/...`、
macOS: `~/Library/Application Support/Godot/...`、Linux: `~/.local/share/godot/...`）。

### モデルJSONの形式（抜粋）
```json
{
  "version": 1,
  "operators": [{"name": "Op1", "home": [-6,0,8], "model": "res://models/operator.glb"}],
  "objects": [
    {"id": "src", "type": "Source", "name": "Source", "pos": [-16,0,0],
     "model": "res://models/source.glb",
     "params": {"interarrival": {"type": "exp", "a": 3.5}, "type_count": 3},
     "script": "extends LogicBase\nfunc on_create(item):\n\titem.set_label('p', 1)\n"}
  ],
  "connections": [["src", "q1"]]
}
```
分布は `{"type": "const|exp|uniform|normal", "a": .., "b": ..}`。

---

## ④ CAD系機能

1 ワールド単位 = 1 m として扱います。

### 縮尺つき適応グリッド＆定規（`scripts/GridRuler.gd`）
ズームに応じて目盛り間隔が自動で切り替わります（0.5m → 1m → 5m → 10m）。主要線に座標値
（m）ラベルを表示し、X軸=赤・Z軸=青で色分け。近づくほど細かい目盛りになり、CADのように
縮尺を見ながら配置できます。

### スナップ配置
上部CADツールバーの「スナップ」ON/OFFと刻み（0.25 / 0.5 / 1 / 2 / 5 m）。ドラッグ配置・
新規追加・数値入力すべてに効きます。

### メジャーツール（距離計測）
「📏 メジャー」を押すと計測モード。地面を左クリックして点を打つと、線分ごとの距離（m）と
3点以上で合計距離を3D表示します。スナップも効きます。「線を確定」で次の計測へ、Escでも確定、
「計測クリア」で全消去。

### 数値トランスフォーム（インスペクタ）
選択中の設備を **座標X/Z（m）・回転（°、±15°ボタン付き）・縮尺** で数値指定できます。
ドラッグ移動すると数値も追従します。

### ビュー
CADツールバーで **平行投影（正射）** に切替可能。**Top / Front / Side / Iso** のプリセット
ビューあり。画面下中央のHUDに**カーソルのワールド座標・現在の目盛り・スケールバー（px/m）**を
表示します。

### ショートカット
- `R` … 選択物を +15°回転
- `Delete` … 選択物を削除
- `Esc` … 計測の確定 / 選択解除

---

## ⑤ 高度な機能（現実性 / 分析 / 編集）

### 設備故障（MTBF/MTTR）と段取り替え（Processor）
パラメータJSONで設定します（`a<=0`で無効）。
```json
{ "mtbf": {"type":"exp","a":45}, "mttr": {"type":"const","a":8},
  "setup_time": {"type":"const","a":4} }
```
- **故障**：稼働(busy)時間が MTBF に達すると `down`（赤）になり、MTTR だけ停止して復帰。
- **段取り替え**：直前と品種(item_type)が変わると `setup`（水色）で setup_time だけ準備してから加工。
- 初期モデルでは Machine A が故障（MTBF45/MTTR8）、Machine B1/B2 が段取り4秒の例。

### 分析
- **時系列グラフ**（画面左下）：スループット(個/時)と WIP(仕掛)の推移。
- **状態内訳バー**：右パネルの各設備に、busy/waiting/blocked/down/setup… の**時間割合**を
  積み上げ表示（FlexSimのステートチャート相当）。

### アンドゥ / リドゥ
追加・削除・移動・配線・パラメータ・スクリプト・モデル割当を巻き戻せます。上部の ↶ / ↷、
または `Ctrl+Z` / `Ctrl+Shift+Z`（`Ctrl+Y`）。スナップショット式で最大100段。

### ドラッグ配線
編集モードの「🔗 配線」を押し、設備Aから設備Bへドラッグ（ラバーバンド線）で接続します。

### 直交拘束（平行/直角スナップ）
ドラッグ移動中に `Shift` を押すと、移動をX軸またはZ軸に拘束します（まっすぐ並べやすい）。

---

## サンプルモデル（初期構成）

```
Source → Queue1 → Machine A → Conveyor → Queue2 ┬→ Machine B1 → Sink
 (指数3.5s)          (作業者要)  (搬送5s)        └→ Machine B2 ↗
                                                  (並列・作業者要)
```
- 作業者2名の共有プールを3台の加工機が奪い合う（資源制約でB2が待つ様子が見える）。
- Source に `on_create`、Machine A に `process_time`+`on_process_finish`、
  Queue2 に `select_output`（型番で分岐）のサンプルスクリプトを同梱。

---

## アーキテクチャ

| ファイル | 役割 |
|---|---|
| `scripts/Sim.gd` | イベント駆動エンジン（イベントカレンダー・run_until・warmup・実験）autoload |
| `scripts/RngStreams.gd` | 乱数ストリーム管理（シード・再現性）autoload |
| `scripts/Distributions.gd` | 確率分布（rng対応・切断正規・三角）autoload |
| `scripts/AssetLoader.gd` | 外部3D(glTF/OBJ)実行時ローダ autoload（`Assets`） |
| `scripts/ScriptEngine.gd` | スクリプト実行時コンパイル/ログ autoload（`Scripts`） |
| `scripts/LogicBase.gd` / `SimAPI.gd` | ユーザースクリプトの基底 / API |
| `scripts/FlowObject.gd` | 設備の基底（接続・送出・統計・モデル・トリガー・選択コリジョン） |
| `scripts/Source/Queue/Processor/Conveyor/Sink.gd` | 各設備 |
| `scripts/Combiner.gd` / `Separator.gd` | 組立 / 分割 |
| `scripts/ConnectionViz.gd` | 接続の矢印表示 |
| `scripts/Chart.gd` / `StateBar.gd` / `LeadHistogram.gd` | 時系列 / 状態内訳 / 滞留分布 |
| `scripts/Operator.gd` / `OperatorPool.gd` | 作業者資源とプール |
| `scripts/FlowItem.gd` | アイテム（ラベル対応） |
| `scripts/ModelIO.gd` | モデルの構築/直列化/JSON入出力 |
| `scripts/Editor.gd` | 編集モード（選択・配置・追加/削除・割当・保存/読込） |
| `scripts/CameraRig.gd` | 軌道カメラ（正射投影・ビュープリセット・スケール算出） |
| `scripts/GridRuler.gd` | 縮尺つき適応グリッド＆座標ラベル |
| `scripts/MeasureViz.gd` | メジャーツール（距離計測の線＋ラベル表示） |
| `scripts/StateBar.gd` | 設備の状態内訳スタックバー（ステートチャート） |
| `scripts/Chart.gd` | スループット/WIP の時系列グラフ |
| `scripts/Main.gd` | 空間・照明・モデル構築のエントリポイント |
| `scripts/UI.gd` | ダッシュボード/実行制御/インスペクタ/スクリプトエディタ/コンソール |
| `models/*.glb` | 見本3Dアセット |

### シミュレーション方式
時間ステップ方式（毎フレーム `delta×速度` を進め、内部で0.05sサブステップに分割）。設備は
「押し出し（push）＋下流ブロック」で連結。`select_output` で送り先ポートを制御可能。

---

## 今後の拡張候補
- 故障（MTBF/MTTR）・段取り替え時間・シフト
- 稼働率の時系列グラフ / 状態ガントチャート
- ドラッグでのポート接続（線を引く）UI、アンドゥ/リドゥ
- 実行時のポート番号可視化、経路アニメの改善

---
Godot 4.x / GDScript。全スクリプトは Godot 4.7.1 でインポート・実行検証済みです。
