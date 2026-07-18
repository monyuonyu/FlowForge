# 開発ステータス & 引き継ぎメモ（PC継続用）

FlexSim風 離散事象シミュレータ（Godot 4.x / GDScript）。このメモは、PCで開発を継続するための
現状・動かし方・残タスクのまとめです。詳細な機能説明は `README.md` を参照。

## 現状サマリ（2026-07-18 セッション中断時点）
- レビュアー(fable5)最新評価: **9.7/10**（推移 3→6→7→9→9.5→9.7）。「検証可能性で勝り、規模と統合度で劣る、
  独立した小型DES」。10/10＝完全同等はコードでは原理的に不可（エコシステム＝文書/教材/コミュニティ/20年の
  モデル資産/ベンダーサポートを含むため）。**コードで到達できる上限は約9.8**、その後さらに9.8→9.9級の余地あり（後述）。
- 全35スクリプト、Godot 4.7.1 で import エラー0、ヘッドレス自己テスト exit=0、**マーカー74種すべて緑**
  （ok=false は [script-err] の「不正スクリプトは棄却されるべき」という意図的な下位判定のみ。同マーカー総合は ok=true）。
- **決定論（同一シードでバイト一致）** と **保存則（created = Σsink + WIP、二重計上なし）** を全機能で維持。
- **外部真値突合**: M/M/1・M/M/c の稼働率/Lq/Wq が待ち行列理論とCI内一致。

## 9/10 以降にこのセッションで追加した機能（すべて検証マーカーつき）
- **AGV経路網**（TransportNetwork.gd）: Dijkstra最短路（決定的タイブレーク）。[agv-net]
- **立体倉庫ラック**（Rack.gd）: bays×levels、fifo/lifo/by_label、時間加重在庫。[rack]
- **最適化＝OptQuest相当**（Sim.optimize）: grid/random/hill、CRN、override→厳密復元。[optimize]
- **実験のバックグラウンド化**（run_replications_async 他）: フレーム分割・中断・進捗、同期版とビット一致。[bg-exp]
- **プロセスフロー**（ProcessFlow.gd, 814行）＝FlexSim看板機能。トークン層 source/delay/assign/decide/batch/
  acquire/release/sink をイベントカレンダー上に。M/M/1理論突合・分岐比検証つき。[procflow][procflow-mm1][procflow-decide]
- **PF↔3D統合**: 隔離実行(run_isolated＝Sim.wip==in_flight実証)、Wait-for-Event(FlowObjectの受動シグナル)、
  実プールからのAcquire、Token⇔FlowItem束縛。[pf-3d][pf-isolation][pf-acquire3d][pf-wait][pf-waitevent][pf-realres]
- **AGV交通干渉**: エッジ占有セマフォ＋FIFO解放待ち＝渋滞再現、占有≤容量の不変、単線双方向の
  デッドロック回避（方向ロック＋release-before-request）。[agv-traffic][agv-cap][agv-deadlock]

## ★最優先の次タスク：mixed-mode 3バグ修正（fable5指摘・これで即9.8）
fable5 7回目レビューが PF↔3D の**混在利用パス**に実バグを3つ発見（単層テストが緑でも踏んでいなかった）。
完全な修正手順は **`/home/claude/wf_pfmix.js`（Workflowスクリプト）** に記述済み。着手途中版（未検証・814→914行）は
**`/home/claude/FlexSimGodot_INPROGRESS_ProcessFlow_bugfix.gd`** に退避（参考。on-disk は検証済み9.7へ復元済み）。
1. **backpressure喪失（重大）**: ProcessFlow.gd `_do_push_object`(~785) と `_do_sink` route(~521) が
   `obj.receive_item()` の戻り値を捨て、満杯でも token.item=null → **アイテム無言消失**（v2以来の保存則侵犯）。
   修正: 戻り値検査。失敗時は落とさず、対象の item_exited シグナル/_notify_space で空き待ち→再投入（FIFO・決定的）。
2. **lost wakeup**: PFと3D Processor が同一 OperatorPool を共有時、PFの `_free_unit`(~736) が
   `pool._assign_next(op)` を呼ばず、3D側の待ち行列が起きない。修正: PF自前待ち処理後にユニットが空きなら
   `pool._assign_next(unit)` を呼ぶ（決定的優先順）。[cal-op] no_leak を壊さないこと。
3. **二重wip_dec**: PF注入アイテムが実Sinkに到達すると Sink が wip_dec、トークンも PF sink で wip_dec ＝二重。
   修正: token._wip_transferred フラグ。receive_item成功で所有権移譲時に true、_sink_token は true のとき wip_dec を
   飛ばす（実Sinkが1回だけ減算）。4ケース（自前dispose/手放し後sink/item無し/手放し後も3D内滞留）で算術検証。
- 検証: 混在テスト3本 [pf-mix-push]（満杯Queueへpush＝無損失）[pf-mix-pool]（共有プール受け渡し）
  [pf-mix-sink]（注入アイテムが実Sink＝二重計上なし）を Main.gd に追加。既存74マーカーはバイト不変を厳守。
- 再開方法（同一セッション想定）: `Workflow({scriptPath:'/home/claude/wf_pfmix.js'})`。別環境なら wf_pfmix.js の
  各エージェント指示をそのまま手作業指針として使える。

## 9.8 以降の余地（fable5・コードで埋まる／最後の0.1はエコシステムで埋まらない）
- コードで埋まる: (i) 上記3バグ修正、(ii) ノード容量の走行統合 or 仕様から削除（現状 try_reserve_node 群は
  死にコード＝待機AGVがノードに無制限堆積、スピルバック未表現）、(iii) **PFに Travel/Load/Unload 相当**
  （現状 acquire_resource は作業者が瞬間移動で着手。FlexSim PF の核心はトークンがタスク列＝移動/積載/降ろしを
  実資源へ発行すること。seize/release はその半分）、(iv) **PFビジュアルエディタ**（現状 Dictionary 手書き。
  キャンバスにアクティビティを並べる体験こそ本丸。これは文書でなくコードで埋まるUX）。
- コードで埋まらない最後の0.1: チュートリアル/事例/コミュニティ/20年のモデル資産/ベンダーサポート。追わない判断が正しい。

## 旧・軽微メモ（保留）
- ガント記録が visuals_enabled 依存、timeline_cap=2000 のリング欠落、スクリプトエラー行番号のヒューリスティック、
  Rngキー接頭辞 obj:/pf: の理論衝突（id が偶然 "pf" の時）、Dijkstra O(V²)。

## 実装済み（検証マーカーつき）
- イベント駆動エンジン（二分ヒープのイベントカレンダー、`run_until` 瞬時実行、実時間再生）
- 乱数シード管理・設備別独立ストリーム（FNV-1a 安定ハッシュ）→ 完全再現
- warmup（立ち上がり除外）、実験(Nレプリケーション＋Student-t 95%CI＋CSV)
- 時間加重WIP、Queueの Lq/Wq、滞留ヒストグラム
- Source/Queue/Processor/Conveyor/Sink/Combiner/Separator、Operator/作業者プール
- 故障(operating基準 MTBF/MTTR ＋ calendar基準)、段取り替え(setup)
- 搬送(Transporter/TransportPool)、作業者の帰投デッドタイム除去、ディスパッチ規則(FIFO/nearest)
- 到着スケジュール、シフトカレンダー
- 分布: const/exp/uniform/normal(切断)/triangular/lognormal/weibull/gamma/empirical
- シナリオ実験(CRN共通乱数, 対比較CI)、パラメータ掃引
- CAD: 縮尺グリッド/スナップ/メジャー/正射投影/ビュープリセット/数値変形/直交拘束
- 編集: 選択・ドラッグ配置・追加/削除・ドラッグ配線・作業者±・搬送者±・シフト編集・
  transport_out/mtbf_basis の GUI切替・Undo/Redo・接続矢印・スクリプトエディタ・コンソール
- スクリプト実行エンジン(GDScript実行時コンパイル)、モデルJSON保存/読込＋読込時セキュリティ確認

## 動かし方
1. Godot 4.x（4.2〜4.7 で動作想定、検証は 4.7.1）で `project.godot` をインポート。
2. F5 で実行。左上「▶開始」。編集は「🔧編集モード」。

## ヘッドレス検証（PCでも回せる）
```
# 自己テスト（全マーカーを標準出力に）
SIM_HEADLESS_TEST=1 godot --headless --path . 
# スクリーンショット（要 xvfb 環境 or 実表示）
SIM_SHOT=1 godot --path . 
```
自己テストは `scripts/Main.gd` の `_run_headless_test()`。マーカー例:
`[determinism] identical=true` / `[conserve] ok=true` / `[cal-op] no_leak=true` /
`[intx-all] ... conserve=true`（down×setup×operator×transport 同時）/ `[scenario-gen] monotone_down=true` 等。
**新機能を足したら、対応する `[xxx]` マーカーを Main.gd に追加し、determinism と conserve が
緑のままかを必ず確認**（このプロジェクトの品質はこの自己テスト網で担保しています）。

## アーキテクチャ（scripts/）
- エンジン: `Sim.gd`(イベントカレンダー/実験), `RngStreams.gd`(乱数), `Distributions.gd`(分布)
- 基底/部品: `FlowObject.gd`, `Source/Queue/Processor/Conveyor/Sink/Combiner/Separator.gd`
- 資源: `Operator.gd`/`OperatorPool.gd`, `Transporter.gd`/`TransportPool.gd`
- スクリプト: `ScriptEngine.gd`(`Scripts`), `LogicBase.gd`, `SimAPI.gd`
- 入出力/編集: `ModelIO.gd`, `Editor.gd`, `Main.gd`(エントリ), `UI.gd`
- 可視化: `CameraRig.gd`, `GridRuler.gd`, `MeasureViz.gd`, `ConnectionViz.gd`,
  `Chart.gd`, `StateBar.gd`, `LeadHistogram.gd`, `FlowItem.gd`, `AssetLoader.gd`
- autoload: `Rng`, `Sim`, `Dist`, `Assets`, `Scripts`（`project.godot` 参照）

## 設計上の約束（継続時に守ると安全）
- 新機能は原則 **既定オフ**（既定モデルの決定論を壊さない）。専用ミニモデルで自己テスト。
- operating基準・非calendar・非transport の**既定パスの rng 抽選順・イベント順を変えない**
  （変えると determinism の値が変わる。identical 自体は保たれるが差分レビューが困難になる）。
- 構造編集（追加/削除/配線）後は `Sim.reset_sim()` でイベントカレンダーを作り直す。

## 残タスク（fable5 指摘・優先度順）
1. **コンベヤ物理の仕上げ**：Phase 4 でスロット式アキュムレーションに着手したが未完/未検証
   （`[conv-accum]` マーカー未確認）。詰まり後方伝播・実効容量=物理長・出口blockedを完成させ検証。
2. **搬送の実用化**：複数積載・積み降ろし時間・より賢いディスパッチ、搬送者の稼働率をUI/KPIへ。
3. **分析の深化**：状態ガントチャート、Welch法によるwarmup推定支援、目標精度ベースの反復数決定、
   レポート出力。
4. **コンベヤ/搬送ラインのボトルネック可視化**。
5. **スケール**：実験モードで FlowItem を Node3D から純データへ（数万アイテム/長時間対応）。
6. **スクリプトUX**：コンパイル/実行時エラーの行番号をコンソール表示（Godotの制約に注意）。
7. **非斉次ポアソン到着の厳密化**（現状は生成時点の区間レート＝近似）。

## 既知の注意点
- ヘッドレス終了時の `Leaked instance / RID allocations / ~PagedAllocator` はダミー描画サーバの
  終了ノイズで実害なし。
- `.godot/` と `*.import` はGodotが再生成するためアーカイブから除外（初回インポートで再生成）。
- **MIXED PF+3D モードの保存則**: `Sim.collect_kpi()` の `created`(=Source.created) と `out`(=Sink.total)
  だけでは混在モデルのリークを判定できない。PF が push_object で 3D へ注入したアイテムは Sink.total には
  乗るが Source.created には現れないため、グローバル恒等式 `created == out + wip` は**定義上成立しない**。
  混在モデルは必ず **PF 側で** 保存則を検査する: `PF.created == PF.sunk + PF.in_flight`（＋ 3D へ手渡した数）。
  純 3D モデルのみでグローバル恒等式が成立する（`[conserve]`/`[cal-op]` 等の既定マーカーはこの前提）。
- **共有プールの起床は双方向**: PF↔3D が同一 OperatorPool/TransportPool を共有する時、
  (a) PF 解放は `_do_release_resource` が `pool._assign_next` で 3D 待機を起こし、
  (b) 3D 解放(`pool.release`/`_assign_next`)は pool の `_notify_external`(外部待機フック)で PF 待機を起こす。
  固定優先度は「pool の 3D 内部待機が先 → その後 PF FIFO」。外部待機者が未登録なら完全ドーマント（乱数不使用・
  既存マーカーはバイト同一）。
