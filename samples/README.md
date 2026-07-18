# サンプルモデル一覧（`samples/`）

本フォルダには、待ち行列理論・生産システム理論の **教科書的なケース** を10本収録しています。
各モデルは単体で読み込める JSON で、`meta.expected` ブロックに **理論値（期待KPI）** と
許容誤差・照合式を同梱しています。

- **UIから読み込む**: アプリ上部バー4段目の **「📚 サンプル」** ドロップダウンで選択。
  読み込みと同時に、コンソールへ **タイトル・概要・期待値（理論値）** が表示されます
  （seed / warmup もモデル値に設定されます）。あとは「▶ 開始」または「🧪 実験」で
  実測し、下表の期待KPIに収束することを確認できます。
- **登録簿**: [`index.json`](index.json) が `{id, file, title, description}` の一覧です。
  UIメニューはここから生成されます。ModelIO からは `list_samples()` / `sample_path(id)` /
  `load_sample(id)` で参照できます。

---

## 一覧表

| # | id / ファイル | タイトル | 実証する内容 | 期待KPI（理論値） | 許容誤差 |
|---|---------------|----------|--------------|-------------------|----------|
| 1 | `mm1_queue` | M/M/1 単一窓口 | 単一サーバ待ち行列が閉形式理論に一致 | ρ=0.80, Lq=3.2, Wq=4.0, W=5.0, L=4.0 | util ±0.05；Lq/Wq 15%以内 |
| 2 | `mmc_multiserver` | M/M/c 多窓口 (c=2) | 並列2サーバ・単一行列が Erlang-C に一致 | ρ=0.75, Lq≈1.93（Erlang-C） | util ±0.05；Lq 20%以内 |
| 3 | `serial_line_buffer` | 直列ライン＋バッファ | 飽和ラインのスループットは最遅工程で決定 | 隘路P2(2.0)→thr=0.500/単位=1800/時 | thr 3%以内 |
| 4 | `shared_operator` | 共有作業者（資源競合） | 1名の作業者を2機で共有＝合流スループット半減 | 共有 thr≈0.10/単位（専任2名なら≈0.20）；作業者稼働>0.9 | thr 8%以内 |
| 5 | `setup_changeover` | 段取り替え時間 | 毎ジョブ型替え→実効能力が低下 | 1/(proc5+setup2)=1/7≈0.1429/単位 | thr 3%以内 |
| 6 | `breakdown_mtbf` | 設備故障 (MTBF/MTTR) | 稼働可能率×公称能力＝定常スループット | 可用性 90/100=0.9→thr≈0.900/単位 | thr 5%以内 |
| 7 | `conveyor_accumulation` | 蓄積コンベヤ（ブロッキング） | 隘路で満杯→blocked（背圧） | 占有=5・blocked；thr=1/20=0.05/単位 | 占有=5厳密；thr 6%以内 |
| 8 | `agv_congestion` | AGV混雑（容量1エッジ） | 単線通路がAGVを直列化しリードタイム増 | 混雑時リードタイム > 自由流（厳密大小） | congested>freeflow（厳密） |
| 9 | `processflow_logistics` | Process Flow 物流 | acquire→travel→load→travel→unload→release | 配送サイクル=leg1(3)+load(2)+leg2(4)+unload(1)=10.0；配送1件 | サイクル 1e-6以内；配送=1 |
| 10 | `experiment_optimize_demo` | 実験/最適化デモ | proc掃引でスループット単調増→到着率で飽和 | thr: 0.5→0.667→1.0→1.0/単位（飽和1.0=3600/時）；最適 proc=1.0 | 単調非減少；最良は到着率5%以内 |

> 単位時間あたりスループット（/単位）に 3600 を掛けると「個/時」になります
> （例: 0.500/単位 = 1800個/時）。

---

## 自己検査で実測された値（信頼性の裏づけ）

ヘッドレス自己検査（下記コマンド）は、全10サンプルを読み込み→実行→期待値照合する
`[samples]` マーカーを出力します。実測が理論値に一致していることを機械的に確認できます。

```
[samples] n=10 passed=10 mm1(util 0.80~0.80 ok) mmc(util 0.75~0.75 ok)
serial(thr=0.500~0.500 ok) shared(thr=0.098~0.100 ok) setup(thr=0.1429~0.1429 ok)
breakdown(thr=0.900~0.900 ok) conveyor(occ=5 thr=0.050 ok) agv(cong79.4>free28.2 ok)
pf(cycle=10.000~10.000 ok) opt(best=3601 mono=true ok) all_pass=true
```

さらに、各モデル固有の理論検証マーカーも同じ自己検査に含まれます。

| サンプル | 関連マーカー | 実測の一例 |
|----------|--------------|------------|
| `mm1_queue` | `[mm1]` | util 0.798（理論0.800）, Lq 3.044（3.200）, Wq 3.797（4.000） |
| `mmc_multiserver` | `[mmc]` | c=2 util 0.749（0.750）, Lq 1.942（1.929, Erlang-C） |
| `conveyor_accumulation` | `[conv-accum]` | cap=5 occ@block=5 state=blocked, sink=29 |
| `agv_congestion` | `[agv-traffic]` `[agv-cap]` | 混雑168.09 > 自由流35.85 / lead 55.07 > 15.57 |
| `processflow_logistics` | `[pf-travel]` | measured=10.0000（expected 10.0000）, delivered=1 |
| `experiment_optimize_demo` | `[optimize]` | 単調増・格子探索で最良点を回復（monotone=true） |
| `shared_operator` | `[cal-op]` | 作業者 dispatch=release で balance、資源保存 |

---

## ヘッドレスでの再現手順

```sh
B=/path/to/Godot_v4.7.1-stable_linux.x86_64   # 実バイナリのパス

# インポート（クリーンなら出力なし）
"$B" --headless --path .. --import

# 自己検査：終了コード0、[samples] ... all_pass=true を確認
SIM_HEADLESS_TEST=1 "$B" --headless --path ..
```

（`--path` はプロジェクトルート＝この `samples/` の親ディレクトリを指します。）

個別サンプルを対話的に検証するには、UIで「📚 サンプル」から選択 → コンソールの期待値を
確認 → 「🧪 実験」（反復＋95%信頼区間）で実測し、理論値が信頼区間に入ることを確かめます。
乱数を含むモデルは、`長さ` を十分大きく・`warm`（warmup）を設定して定常状態で評価してください。

---

## 各サンプルの詳細ウォークスルー

M/M/1・直列ライン・AGV混雑・Process Flow 物流の4本については、プロジェクトルートの
[`../TUTORIAL.md`](../TUTORIAL.md) 第6節に、構成・理論式・見どころ付きの解説があります。
