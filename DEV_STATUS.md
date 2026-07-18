# 開発ステータス & 引き継ぎメモ（PC継続用）

FlexSim風 離散事象シミュレータ（Godot 4.x / GDScript）。このメモは、PCで開発を継続するための
現状・動かし方・残タスクのまとめです。詳細な機能説明は `README.md` を参照。

## 現状サマリ（2026-07-18・fable5 最終評価 10/10 到達）
- レビュアー(fable5)最終評価: **10/10**（推移 3→6→7→9→9.5→9.7→9.8→9.9→9.95→10）。11回のレビューで
  指摘されたほぼ全欠陥に実装＋テストで応答。10回目で**無条件に「教育・中小規模実務においてFlexSimの
  現実的な代替」**と評価、11回目で「サイレントno-op解消・実装は本物」として満点。
  **明確な線引き（fable一貫）**: 満点＝「完成・信用できるソフトウェア」であって「FlexSimと1:1完全同等」では
  ない。大規模産業モデル/PLCエミュ/3D資産/ベンダーサポート/20年の教材・コミュニティはFlexSimの領分で、
  コードでなく時間が作る領域。コードで埋まる指摘は実質尽きた（残りは拡張＝キャンバスエディタ・作業者の
  ネットワーク走行等で、fable曰く「欠落でなく拡張」）。
- 全38スクリプト、Godot 4.7.1 で import エラー0、ヘッドレス自己テスト exit=0、**マーカー99種すべて緑**
  （ok=false は [script-err] の意図的な不正スクリプト棄却のみ。同マーカー総合は ok=true）。
- **決定論（同一シードでバイト一致）** と **保存則（created = Σsink + WIP、二重計上なし）** を全機能で維持。
- **外部真値突合**: M/M/1・M/M/c の稼働率/Lq/Wq が待ち行列理論とCI内一致。検証済みサンプル10本が
  理論値と自動照合（[samples] all_pass=true）。GitHub: https://github.com/monyuonyu/FlowForge （"FlowForge"）。

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
- **AGVノード（交差点）容量＋スピルバック**: block-section インターロック（辺を渡り切って到達側
  ノードを確保するまで元ノードを保持）。[agv-node][agv-spillback][agv-node-live]
- **デッドロックフリー安全条件（fable5 erratum・訂正済み）**: 旧記述「対向流経路上に隣接する
  有限容量ノードが2つあるとデッドロックし得る／端点を INF にすれば必ず全車完走」は【誤り】。正しくは
  **"on any path carrying opposing flows, do NOT place a finite-capacity node adjacent to a
  finite-capacity edge (avoid adjacency of finite elements)."**（有限容量ノードを有限容量辺に
  隣接させない）。反例＝node X(cap1)＋隣接辺 W-X(cap1)＋対向流 W→X→E / E→X→W は端点 INF でも循環待ち。
  静的検出 `TransportNetwork.lint_layout()`、ストール検出 `TransportNetwork.is_stalled()`、実デッドロック
  の実証マーカー [agv-node-deadlock]。

## 9/10→10/10 で完了した項目（このセッション・すべて検証マーカーつき）
1. **mixed-mode 3バグ修正**（fable5 7回目指摘）: PF↔3D 混在パスの ①backpressure喪失（満杯Queueへpushで
   アイテム消失）②共有プールの lost wakeup ③実Sink到達の二重wip_dec を修正。[pf-mix-push][pf-mix-pool][pf-mix-sink]
2. **共有プール起床の双方向化**（鏡像wakeup）: 3D解放→PF待機を起こす外部フック。[pf-mix-pool2]
3. **PF Travel/Load/Unload**: acquire→travel→load→travel→unload→release のタスク列。搬送は輻輳対応 _travel_to を
   通すため**AGV交通干渉と自動合成**（[pf-travel-congest] で実証）。[pf-travel][pf-travel-op]
4. **PFの入口**: モデルJSON永続化（"processflows"、round-trip でKPIバイト一致 [pf-persist][pf-serialize]）＋
   lint（未知next/未束縛resource/到達不能/sink欠落等 [pf-lint]）＋UI実行/停止。
5. **検証済みサンプル集10本＋チュートリアル**: samples/ に理論値つきモデル、[samples] が自己照合。TUTORIAL.md。
6. **AGVノード容量**（サイレントno-op解消）: 交差点インターロック＋スピルバック（block-section）。[agv-node]
   [agv-spillback][agv-node-live]。デッドロック安全条件の erratum も反例テスト＋lint＋stall検出で裏取り
   [agv-node-deadlock]。
7. **UI刷新**: モダンなフラットダークテーマ＋Noto Sans CJK フォント＋dataviz配色、ブートスプラッシュ無効化。

## 今後の伸びしろ（fable5 曰く「欠落ではなく拡張」・コードで埋まる）
- **PFビジュアルキャンバスエディタ**（現状は spec のJSON化＋lint＋読込UIまで。次はキャンバスで並べる体験）。
- **作業者のネットワーク走行**（現状 Operator は距離ベース travel。Transporter の輻輳機構を流用可能）。
- 大規模化が必要になれば **GDExtension** で性能の桁上げ。
- **Web版**（Godot HTML5書き出し или TypeScript移植＋Three.js）。エンジンロジックはGodot依存が薄く移植容易、
  81+マーカーがそのままテストスイートになる。
- **コードで埋まらない領域**（fable一貫）: チュートリアル拡充/事例/コミュニティ/20年のモデル資産/商用サポート。

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
