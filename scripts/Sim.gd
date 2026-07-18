extends Node
## 離散事象シミュレーションエンジン（autoload "Sim"）。
## イベントカレンダー（二分ヒープ）方式。時間は「次のイベント」までジャンプする。
## - 実時間再生（speed倍）と、瞬時実行（run_until）を両立
## - warmup 期間経過で統計をリセット
## - 乱数は Rng（ストリーム別・シード管理）に委譲 → 同一シードで完全再現

signal ticked(sim_time)
signal sim_reset
signal experiment_done(results)
## 非同期(フレーム分割)実験の進捗。frac:0..1（単調増加で1.0到達）, info:{stage,i,n}。
signal experiment_progress(frac, info)

# --- 非同期(フレーム分割)実験ランナーの状態 ---
var exp_busy: bool = false      # 逐次ランナー実行中（UIの多重起動抑止に使う）
var _exp_cancel: bool = false   # 中断要求フラグ（次のフレーム境界で停止）

var sim_time: float = 0.0
var running: bool = false
var speed: float = 1.0
var seed: int = 12345
var warmup: float = 0.0
var stats_start: float = 0.0

var objects: Array = []          # 登録 FlowObject（統計/リセット用）
var items_root: Node3D = null
var visuals_enabled: bool = true # 実験(瞬時実行)中は false にして描画ノード生成を省く
var _item_id: int = 0

## Process Flow 分離モード（既定 true=従来通り、Source が自前で到着を生成）。
## false にすると登録済み Source が自前の到着生成を停止する（Source が Sim.sources_enabled
## を参照して _schedule_next/_gen をスキップする）。これにより ProcessFlow モデルを
## 走らせる際に、現在ロード中の既定3Dモデルの Source が独自の到着を注入しなくなる。
## reset_sim() はこのフラグを触らないため、分離中に reset_sim() が走っても Source は
## 再武装しない（on_sim_start→_schedule_next がガードされる）。
## 既定 true のため既存マーカー値には一切影響しない opt-in 機構。set_sources_enabled で切替。
var sources_enabled: bool = true

# 時間加重 WIP（系内在庫）
var wip: int = 0
var _wip_area: float = 0.0
var _wip_last_t: float = 0.0

var _heap: Array = []            # イベント最小ヒープ {t, seq, cb:Callable, alive:bool}
var _seq: int = 0
var _target: float = 0.0
var _warmed: bool = false

const MAX_FRAME_DT := 2.0
const SAFETY_EVENTS := 5000000

# ---------------------------------------------------------------
# 登録
# ---------------------------------------------------------------
func register(obj) -> void:
	if not objects.has(obj):
		objects.append(obj)

func unregister(obj) -> void:
	objects.erase(obj)

## 既定3Dモデルの Source 自走 ON/OFF を切り替える（分離機構）。
##   on=true  … 従来通り。Source が interarrival に従い到着を生成（既定）。
##   on=false … 分離モード。登録済み Source が自前の到着生成を停止し、
##              ProcessFlow など外部ドライバの駆動だけがフローを進める。
## この状態は reset_sim() を跨いでも保持されるため、分離中に reset_sim() が呼ばれても
## 既定 Source は再武装しない。PF 実行後は set_sources_enabled(true) で復帰する。
func set_sources_enabled(on: bool) -> void:
	sources_enabled = on

## 全 FlowObject の状態タイムライン記録を一括ON/OFF（ガントチャート用）。
## 記録は set_state で追記するだけで乱数/イベント順に無影響。既定オフ。
func set_timeline_recording(on: bool) -> void:
	for obj in objects:
		if obj is FlowObject:
			obj.record_timeline = on

func next_item_id() -> int:
	_item_id += 1
	return _item_id

# --- 時間加重WIP ---
func _wip_accum() -> void:
	# 時刻逆行（実行中の warmup 変更等）でも負面積を積まないよう dt をガード。
	var dt: float = max(0.0, sim_time - _wip_last_t)
	_wip_area += float(wip) * dt
	_wip_last_t = max(_wip_last_t, sim_time)

func wip_inc() -> void:
	_wip_accum()
	wip += 1

func wip_dec() -> void:
	_wip_accum()
	wip = max(0, wip - 1)

func avg_wip() -> float:
	_wip_accum()
	return _wip_area / stats_elapsed()

# ---------------------------------------------------------------
# イベントカレンダー
# ---------------------------------------------------------------
func schedule(delay: float, cb: Callable) -> Dictionary:
	var ev := {"t": sim_time + max(0.0, delay), "seq": _seq, "cb": cb, "alive": true}
	_seq += 1
	_heap_push(ev)
	return ev

func cancel(ev) -> void:
	if ev != null and ev is Dictionary:
		ev.alive = false

func _heap_push(ev: Dictionary) -> void:
	_heap.append(ev)
	var i: int = _heap.size() - 1
	while i > 0:
		var p: int = (i - 1) >> 1
		if _less(_heap[i], _heap[p]):
			var tmp = _heap[i]; _heap[i] = _heap[p]; _heap[p] = tmp
			i = p
		else:
			break

func _heap_pop() -> Dictionary:
	var top: Dictionary = _heap[0]
	var last: Dictionary = _heap.pop_back()
	if _heap.size() > 0:
		_heap[0] = last
		var i: int = 0
		var n: int = _heap.size()
		while true:
			var l: int = 2 * i + 1
			var r: int = 2 * i + 2
			var s: int = i
			if l < n and _less(_heap[l], _heap[s]): s = l
			if r < n and _less(_heap[r], _heap[s]): s = r
			if s == i: break
			var tmp = _heap[i]; _heap[i] = _heap[s]; _heap[s] = tmp
			i = s
	return top

func _less(a: Dictionary, b: Dictionary) -> bool:
	if a.t != b.t:
		return a.t < b.t
	return a.seq < b.seq

# ---------------------------------------------------------------
# 実行
# ---------------------------------------------------------------
func start() -> void:
	running = true

func pause() -> void:
	running = false

func toggle() -> void:
	running = not running

func set_speed(s: float) -> void:
	speed = max(0.0, s)

## 指定時刻まで一気に処理（瞬時）。warmup 経過で統計リセット。
func run_until(limit: float) -> void:
	var count: int = 0
	while _heap.size() > 0:
		var ev: Dictionary = _heap[0]
		if ev.t > limit:
			break
		# warmup 到達で一度だけ統計リセット。
		# sim_time を warmup に合わせてからリセットすることで
		# stats_start=warmup / 各obj._last_change=warmup / _wip_last_t=warmup になる。
		if not _warmed and warmup > 0.0 and ev.t >= warmup:
			# sim_time を warmup へ合わせるのは前進時のみ（時計を巻き戻さない）。
			if sim_time < warmup:
				sim_time = warmup
			_reset_stats_only()
			_warmed = true
		_heap_pop()
		if not ev.alive:
			continue
		sim_time = ev.t
		ev.cb.call()
		count += 1
		if count > SAFETY_EVENTS:
			push_error("Sim: イベント上限に到達（0遅延ループの可能性）")
			break
	# イベント枯渇/次イベントが limit 超過でも、warmup を跨ぐならここでリセットする。
	if not _warmed and warmup > 0.0 and warmup <= limit:
		if sim_time < warmup:
			sim_time = warmup
		_reset_stats_only()
		_warmed = true
	if sim_time < limit:
		sim_time = limit   # アイドルでも時計は進める

func _process(delta: float) -> void:
	if not running:
		return
	_target += min(delta * speed, MAX_FRAME_DT)
	run_until(_target)
	emit_signal("ticked", sim_time)

# ---------------------------------------------------------------
# リセット
# ---------------------------------------------------------------
func reset_sim() -> void:
	running = false
	sim_time = 0.0
	_target = 0.0
	_item_id = 0
	_heap.clear()
	_seq = 0
	_warmed = false
	stats_start = 0.0
	wip = 0
	_wip_area = 0.0
	_wip_last_t = 0.0
	Rng.reset(seed)
	if items_root != null:
		for c in items_root.get_children():
			c.queue_free()
	for obj in objects:
		if obj.has_method("reset_object"):
			obj.reset_object()
	# 初期イベント（Sourceの初回生成など）を仕込む
	for obj in objects:
		if obj.has_method("on_sim_start"):
			obj.on_sim_start()
	emit_signal("sim_reset")

func _reset_stats_only() -> void:
	# 統計開始点は warmup に明示的に合わせる（sim_time 依存にしない）。
	# 呼び出し側で sim_time=warmup にしてから呼ぶので各obj._last_change等も warmup になる。
	sim_time = max(sim_time, warmup)
	stats_start = warmup
	_wip_area = 0.0
	_wip_last_t = warmup
	for obj in objects:
		if obj.has_method("reset_stats"):
			obj.reset_stats()

func stats_elapsed() -> float:
	return max(0.0001, sim_time - stats_start)

# ---------------------------------------------------------------
# 実験（Nレプリケーションを瞬時実行）
# ---------------------------------------------------------------
## returns: {"reps":N,"throughput":[...],"leadtime":[...],"wip":[...],
##           "thr_mean","thr_ci","lt_mean","lt_ci"}
## 全 Source/Sink を集計した KPI を返す（単一 Sink 前提を排除）。
## returns: {"out","created","lead_sum","throughput","leadtime","wip"}
##
## 【注意・MIXED PF+3D モード】ここでの created は Source.created、out は Sink.total を集計する。
## PF(ProcessFlow) が push_object で 3D モデルへ注入したアイテムは Sink.total には計上されるが
## Source.created には現れないため、グローバル恒等式 created == out + wip は「定義上」成立しない。
## 混在モデルの保存則は PF 側で検査すること: PF.created == PF.sunk + PF.in_flight（＋ 3D へ手渡した数）。
## この collect_kpi の値だけで混在モデルのリーク判定をしてはならない（純 3D モデルのみで恒等式が成立）。
func collect_kpi() -> Dictionary:
	var out_total: int = 0
	var created_total: int = 0
	var lead_sum: float = 0.0
	for o in objects:
		if o is Sink:
			out_total += o.total
			lead_sum += o.sum_time_in_system
		elif o is Source:
			created_total += o.created
	var elapsed: float = stats_elapsed()
	return {
		"out": out_total,
		"created": created_total,
		"lead_sum": lead_sum,
		"throughput": float(out_total) / elapsed * 3600.0,
		"leadtime": (lead_sum / out_total) if out_total > 0 else 0.0,
		"wip": wip,
	}

## 1レプリケーションを実行して KPI を返す（同期・純粋）。同期版/非同期版で共有する
## 唯一の実行単位。await を含まないため、これを呼ぶ側の同期性は損なわない。
func _run_one_rep(i: int, run_len: float, warmup_t: float, base_seed: int) -> Dictionary:
	seed = base_seed + i
	warmup = warmup_t
	reset_sim()
	run_until(warmup_t + run_len)
	return collect_kpi()

## getter 引数は後方互換のため残すが未使用（collect_kpi で全 Source/Sink を集計する）。
func run_replications(n: int, run_len: float, warmup_t: float, base_seed: int, _sink_getter: Callable = Callable(), _source_getter: Callable = Callable()) -> Dictionary:
	var thr: Array = []
	var lts: Array = []
	var wips: Array = []
	var prev_seed: int = seed
	var prev_warm: float = warmup
	for i in range(n):
		var kpi := _run_one_rep(i, run_len, warmup_t, base_seed)
		thr.append(kpi.throughput)
		lts.append(kpi.leadtime)
		wips.append(kpi.wip)
	seed = prev_seed
	warmup = prev_warm
	var res := {
		"reps": n, "throughput": thr, "leadtime": lts, "wip": wips,
		"thr_mean": _mean(thr), "thr_ci": _ci95(thr),
		"lt_mean": _mean(lts), "lt_ci": _ci95(lts),
	}
	emit_signal("experiment_done", res)
	return res

## 実行中の非同期実験に中断を要求する（次のフレーム境界で停止する）。
func cancel_experiment() -> void:
	if exp_busy:
		_exp_cancel = true

## 進捗を emit して1フレーム譲る（フレーム分割ランナー内部専用）。
## await はイベント計算に無関係（同期版と seq/seed/実行順が完全同一）→ 決定論不変。
func _exp_yield(done: int, total: int, stage: String) -> void:
	emit_signal("experiment_progress", clampf(float(done) / float(max(1, total)), 0.0, 1.0),
		{"stage": stage, "i": done, "n": total})
	await get_tree().process_frame

## run_replications のフレーム分割版。1レプリケーションごとに await get_tree().process_frame
## でフレームを譲り、進捗(0..1)を experiment_progress で emit、cancel_experiment() で中断可能。
## 実行単位 _run_one_rep は同期版と共有＝計算入力/順序が同一 →**結果は同期版とビット一致**
## （await はイベント計算に無関係）。中断時は完了までの結果を返し cancelled=true を付す。
func run_replications_async(n: int, run_len: float, warmup_t: float, base_seed: int) -> Dictionary:
	var thr: Array = []
	var lts: Array = []
	var wips: Array = []
	var prev_seed: int = seed
	var prev_warm: float = warmup
	var cancelled: bool = false
	var done: int = 0
	exp_busy = true
	_exp_cancel = false
	for i in range(n):
		if _exp_cancel:
			cancelled = true
			break
		var kpi := _run_one_rep(i, run_len, warmup_t, base_seed)
		thr.append(kpi.throughput)
		lts.append(kpi.leadtime)
		wips.append(kpi.wip)
		done += 1
		await _exp_yield(done, n, "rep")
	seed = prev_seed
	warmup = prev_warm
	exp_busy = false
	_exp_cancel = false
	var res := {
		"reps": done, "throughput": thr, "leadtime": lts, "wip": wips,
		"thr_mean": _mean(thr), "thr_ci": _ci95(thr),
		"lt_mean": _mean(lts), "lt_ci": _ci95(lts),
		"cancelled": cancelled,
	}
	if not cancelled:
		emit_signal("experiment_done", res)
	return res

# ---------------------------------------------------------------
# シナリオ比較実験（CRN: 共通乱数による分散低減）
# ---------------------------------------------------------------
## objects 内から id 一致の FlowObject を返す（無ければ null）。
func _find_object(obj_id: String):
	for o in objects:
		if o is FlowObject and o.id == obj_id:
			return o
	return null

## 複数シナリオを同一乱数列（CRN）で比較実験する。
## scenarios = [{name, overrides:{obj_id:{param:value,...}, ...}} ...]
##   各シナリオの各レプリケーション i は同一 base_seed+i を使う（分散低減）。
##   overrides は該当 obj.set_params で適用し、実行後に元へ戻す。
## returns: {
##   "reps", "seeds":[base_seed+i ...],
##   "scenarios":[{name, throughput:[...], leadtime:[...], thr_mean, thr_ci, lt_mean, lt_ci} ...],
##   "compare": {a, b, thr_d:[...], thr_d_mean, thr_d_ci, lt_d:[...], lt_d_mean, lt_d_ci}  # 先頭2シナリオ
## }
## 1シナリオ分を実行する（同期・純粋）。override を適用→reps 回 CRN 実行→override を厳密復元し、
## {name, throughput, leadtime, thr_mean, thr_ci, lt_mean, lt_ci} を返す。
## 同期版/非同期版で共有する実行単位（await を含まない）。
func _run_one_scenario(sc: Dictionary, reps: int, run_len: float, warmup_t: float, base_seed: int) -> Dictionary:
	var overrides: Dictionary = sc.get("overrides", {})
	# overrides 適用前の元パラメータを退避（参照を保持→復元で厳密に戻す）
	var saved: Dictionary = {}
	for obj_id in overrides.keys():
		var obj = _find_object(obj_id)
		if obj == null:
			continue
		var cur: Dictionary = obj.get_params()
		var ovr: Dictionary = overrides[obj_id]
		# 元 get_params に存在するキーのみ override 対象にする。
		# 復元は保存済みの実値のみ（null 保存→set_params 型エラーを回避）。
		var old_vals: Dictionary = {}
		var applied: Dictionary = {}
		for pk in ovr.keys():
			if cur.has(pk):
				old_vals[pk] = cur[pk]
				applied[pk] = ovr[pk]
		saved[obj_id] = old_vals
		if not applied.is_empty():
			obj.set_params(applied.duplicate(true))
	var thr: Array = []
	var lts: Array = []
	for i in range(reps):
		var kpi := _run_one_rep(i, run_len, warmup_t, base_seed)  # CRN: 同一 i は同一シード
		thr.append(kpi.throughput)
		lts.append(kpi.leadtime)
	# overrides を元へ戻す
	for obj_id in saved.keys():
		var obj = _find_object(obj_id)
		if obj != null:
			obj.set_params(saved[obj_id])
	return {
		"name": sc.get("name", "?"),
		"throughput": thr, "leadtime": lts,
		"thr_mean": _mean(thr), "thr_ci": _ci95(thr),
		"lt_mean": _mean(lts), "lt_ci": _ci95(lts),
	}

## シナリオ結果配列から返り値辞書（seeds/scenarios/compare）を組み立てる。同期版/非同期版で共有。
func _finalize_scenarios(reps: int, base_seed: int, sc_results: Array) -> Dictionary:
	var seeds: Array = []
	for i in range(reps):
		seeds.append(base_seed + i)
	var res := {"reps": reps, "seeds": seeds, "scenarios": sc_results}
	# 先頭2シナリオの対比較（CRN: 同一 i の差 d_i = A_i - B_i の平均±CI）
	if sc_results.size() >= 2:
		var thr_d: Array = []
		var lt_d: Array = []
		for i in range(reps):
			thr_d.append(sc_results[0].throughput[i] - sc_results[1].throughput[i])
			lt_d.append(sc_results[0].leadtime[i] - sc_results[1].leadtime[i])
		res["compare"] = {
			"a": sc_results[0].name, "b": sc_results[1].name,
			"thr_d": thr_d, "thr_d_mean": _mean(thr_d), "thr_d_ci": _ci95(thr_d),
			"lt_d": lt_d, "lt_d_mean": _mean(lt_d), "lt_d_ci": _ci95(lt_d),
		}
	return res

func run_scenarios(scenarios: Array, reps: int, run_len: float, warmup_t: float, base_seed: int) -> Dictionary:
	var prev_seed: int = seed
	var prev_warm: float = warmup
	var sc_results: Array = []
	for sc in scenarios:
		sc_results.append(_run_one_scenario(sc, reps, run_len, warmup_t, base_seed))
	seed = prev_seed
	warmup = prev_warm
	return _finalize_scenarios(reps, base_seed, sc_results)

## run_scenarios のフレーム分割版（1シナリオごとに await でフレームを譲る）。
## 進捗を emit、cancel_experiment() で中断可能。実行単位 _run_one_scenario / 集計 _finalize_scenarios
## を同期版と共有 →**非中断時は結果が同期版とビット一致**。中断は各シナリオ境界（override 復元済み）で行う。
func run_scenarios_async(scenarios: Array, reps: int, run_len: float, warmup_t: float, base_seed: int) -> Dictionary:
	var prev_seed: int = seed
	var prev_warm: float = warmup
	var sc_results: Array = []
	var cancelled: bool = false
	var sc_done: int = 0
	exp_busy = true
	_exp_cancel = false
	for sc in scenarios:
		if _exp_cancel:
			cancelled = true
			break
		sc_results.append(_run_one_scenario(sc, reps, run_len, warmup_t, base_seed))
		sc_done += 1
		await _exp_yield(sc_done, scenarios.size(), "scenario")
	seed = prev_seed
	warmup = prev_warm
	exp_busy = false
	_exp_cancel = false
	var res := _finalize_scenarios(reps, base_seed, sc_results)
	res["cancelled"] = cancelled
	return res

## パラメータ掃引シナリオを生成する（任意対象×任意値の一般化）。
## obj_id      : 対象 FlowObject の id。
## param_path  : トップレベル名（例 "process_time","capacity"）または
##               分布内数値へのドット指定（例 "process_time.a","interarrival.a"）。
## values      : 掃引する値の配列。各値が1シナリオになる。
## cur_params  : 対象 obj の現在パラメータ（get_params()）。型判定に使う。
## 返り値は run_scenarios にそのまま渡せる scenarios 配列。
##   - "top.sub" 指定かつ cur[top] が分布dict → その分布の sub キーだけを差し替え。
##   - "top" 指定のみで cur[top] が分布dict     → {"type":"const","a":値} へ丸ごと差し替え。
##   - それ以外（素の数値パラメータ等）        → 値をそのまま設定。
func build_sweep_scenarios(obj_id: String, param_path: String, values: Array, cur_params: Dictionary) -> Array:
	var scenarios: Array = []
	var parts: PackedStringArray = param_path.split(".", false)
	if parts.is_empty():
		return scenarios
	var top: String = parts[0]
	var has_sub: bool = parts.size() >= 2
	var top_is_dist: bool = cur_params.has(top) and cur_params[top] is Dictionary
	# (f) 非分布トップレベルにサブキー（"capacity.x" 等）が付いている指定は解釈不能。
	# 従来は黙って top=v に丸めていたが、意図しない掃引を招くため警告する。
	if has_sub and not top_is_dist:
		Scripts.log_msg("⚠ 掃引: '%s' は分布でないため サブキー '%s' を無視し '%s' 全体に値を設定します" % [
			top, parts[1], top])
	for v in values:
		var ovr_val
		if has_sub and top_is_dist:
			var d: Dictionary = (cur_params[top] as Dictionary).duplicate(true)
			d[parts[1]] = v
			ovr_val = d
		elif top_is_dist:
			ovr_val = {"type": "const", "a": v}
		else:
			ovr_val = v
		scenarios.append({
			"name": "%s=%s" % [param_path, str(v)],
			"overrides": {obj_id: {top: ovr_val}},
		})
	return scenarios

# ---------------------------------------------------------------
# 最適化（OptQuest相当：決定変数の離散格子探索でKPI目的関数を最適化）
# ---------------------------------------------------------------
## 決定変数 decision_vars を離散格子で振り、目的関数 objective を最適化する。
## - decision_vars = [{obj_id, param, min, max, step} ...]
##     param はトップレベル数値名（例 "capacity"）または分布内数値へのドット指定
##     （例 "process_time.a","interarrival.a"）。値の適用/復元は run_scenarios と同一の
##     set_params override 方式（実行後に元の実値へ厳密復元）。
## - objective = {metric:"throughput"|"leadtime"|"wip"|"custom", sense:"max"|"min",
##     weights:{throughput,leadtime,wip}}（custom のときのみ weights を線形結合）。
## - method = "grid"（全格子, budget上限）/ "random"（テスト用Rngで格子から重複なく抽選）/
##     "hill"（格子中心から近傍1手改善を budget まで反復）。
## - **候補評価はすべて同一 base_seed+i の CRN**（分散低減・決定的）。
## returns {best:{"obj_id.param":値 ...}, best_obj, evaluated, method,
##          history:[{assign:{...}, obj:値} ...]}
func optimize(decision_vars: Array, objective: Dictionary, method: String = "grid",
		budget: int = 64, reps: int = 3, run_len: float = 1800.0,
		warmup_t: float = 0.0, base_seed: int = 12345) -> Dictionary:
	var sense: String = str(objective.get("sense", "max"))
	# 各決定変数の離散格子（値配列）を作る。
	var grids: Array = []
	for dv in decision_vars:
		grids.append(_grid_values(dv))
	# 空格子（不正指定）を含む場合は探索不能。
	for g in grids:
		if (g as Array).is_empty():
			return {"best": {}, "best_obj": 0.0, "evaluated": 0, "method": method, "history": []}
	var prev_seed: int = seed
	var prev_warm: float = warmup
	var history: Array = []
	var best_combo: Array = []
	var best_obj: float = 0.0
	var best_set: bool = false
	var evaluated: int = 0
	budget = max(1, budget)

	if method == "hill":
		# 格子中心を初期点にして、近傍（各変数±1格子）で最良へ移動。改善が無ければ停止。
		var idx: Array = []
		for g in grids:
			idx.append(int((g as Array).size() / 2))
		var cur_combo: Array = _combo_from_idx(grids, idx)
		var cur_obj: float = _eval_combo(decision_vars, cur_combo, objective, reps, run_len, warmup_t, base_seed)
		evaluated += 1
		history.append({"assign": _assign_labels(decision_vars, cur_combo), "obj": cur_obj})
		best_combo = cur_combo; best_obj = cur_obj; best_set = true
		while evaluated < budget:
			var moved: bool = false
			var local_best_idx: Array = idx.duplicate()
			var local_best_obj: float = cur_obj
			# 近傍列挙（各変数を ±1 動かした点）を決定的順で評価。
			for d in range(grids.size()):
				for delta in [-1, 1]:
					var ni: int = idx[d] + delta
					if ni < 0 or ni >= (grids[d] as Array).size():
						continue
					if evaluated >= budget:
						break
					var ncand: Array = idx.duplicate()
					ncand[d] = ni
					var ncombo: Array = _combo_from_idx(grids, ncand)
					var nobj: float = _eval_combo(decision_vars, ncombo, objective, reps, run_len, warmup_t, base_seed)
					evaluated += 1
					history.append({"assign": _assign_labels(decision_vars, ncombo), "obj": nobj})
					if _is_better(nobj, local_best_obj, sense):
						local_best_obj = nobj
						local_best_idx = ncand
						moved = true
			if not moved:
				break
			idx = local_best_idx
			cur_obj = local_best_obj
			if _is_better(cur_obj, best_obj, sense):
				best_obj = cur_obj
				best_combo = _combo_from_idx(grids, idx)
	else:
		# 全格子（デカルト積）を列挙。random はその中から重複なく budget 個を抽選。
		var all_combos: Array = _cartesian(grids)
		var order: Array = _opt_order(all_combos, method, budget, base_seed)
		for k in order:
			var combo: Array = all_combos[k]
			var obj_val: float = _eval_combo(decision_vars, combo, objective, reps, run_len, warmup_t, base_seed)
			evaluated += 1
			history.append({"assign": _assign_labels(decision_vars, combo), "obj": obj_val})
			if not best_set or _is_better(obj_val, best_obj, sense):
				best_set = true
				best_obj = obj_val
				best_combo = combo
	seed = prev_seed
	warmup = prev_warm
	return {
		"best": _assign_labels(decision_vars, best_combo),
		"best_obj": best_obj, "evaluated": evaluated,
		"method": method, "history": history,
	}

## grid/random の候補評価順（all_combos のインデックス列）を決定的に返す。同期版/非同期版で共有。
func _opt_order(all_combos: Array, method: String, budget: int, base_seed: int) -> Array:
	var order: Array = []
	if method == "random":
		var rng := RandomNumberGenerator.new()
		rng.seed = base_seed
		var pool: Array = []
		for k in range(all_combos.size()):
			pool.append(k)
		# Fisher-Yates（テスト用 Rng・決定的）で並べ替え、先頭 budget 個。
		for k in range(pool.size() - 1, 0, -1):
			var j: int = rng.randi_range(0, k)
			var tmp = pool[k]; pool[k] = pool[j]; pool[j] = tmp
		var take: int = min(budget, pool.size())
		for k in range(take):
			order.append(pool[k])
	else:
		# grid: 列挙順で budget 上限まで。
		var take2: int = min(budget, all_combos.size())
		for k in range(take2):
			order.append(k)
	return order

## optimize のフレーム分割版（候補評価ごとに await でフレームを譲る）。進捗を emit、
## cancel_experiment() で中断可能。列挙順(_opt_order)/評価(_eval_combo)/格子(_grid_values,
## _cartesian) を同期版と共有し、await はイベント計算に無関係 →**非中断時は結果が同期版とビット一致**。
func optimize_async(decision_vars: Array, objective: Dictionary, method: String = "grid",
		budget: int = 64, reps: int = 3, run_len: float = 1800.0,
		warmup_t: float = 0.0, base_seed: int = 12345) -> Dictionary:
	var sense: String = str(objective.get("sense", "max"))
	var grids: Array = []
	for dv in decision_vars:
		grids.append(_grid_values(dv))
	for g in grids:
		if (g as Array).is_empty():
			return {"best": {}, "best_obj": 0.0, "evaluated": 0, "method": method, "history": [], "cancelled": false}
	var prev_seed: int = seed
	var prev_warm: float = warmup
	var history: Array = []
	var best_combo: Array = []
	var best_obj: float = 0.0
	var best_set: bool = false
	var evaluated: int = 0
	var cancelled: bool = false
	budget = max(1, budget)
	exp_busy = true
	_exp_cancel = false

	if method == "hill":
		var idx: Array = []
		for g in grids:
			idx.append(int((g as Array).size() / 2))
		var cur_combo: Array = _combo_from_idx(grids, idx)
		var cur_obj: float = _eval_combo(decision_vars, cur_combo, objective, reps, run_len, warmup_t, base_seed)
		evaluated += 1
		history.append({"assign": _assign_labels(decision_vars, cur_combo), "obj": cur_obj})
		best_combo = cur_combo; best_obj = cur_obj; best_set = true
		await _exp_yield(evaluated, budget, "opt")
		while evaluated < budget and not _exp_cancel:
			var moved: bool = false
			var local_best_idx: Array = idx.duplicate()
			var local_best_obj: float = cur_obj
			for d in range(grids.size()):
				for delta in [-1, 1]:
					var ni: int = idx[d] + delta
					if ni < 0 or ni >= (grids[d] as Array).size():
						continue
					if evaluated >= budget or _exp_cancel:
						break
					var ncand: Array = idx.duplicate()
					ncand[d] = ni
					var ncombo: Array = _combo_from_idx(grids, ncand)
					var nobj: float = _eval_combo(decision_vars, ncombo, objective, reps, run_len, warmup_t, base_seed)
					evaluated += 1
					history.append({"assign": _assign_labels(decision_vars, ncombo), "obj": nobj})
					await _exp_yield(evaluated, budget, "opt")
					if _is_better(nobj, local_best_obj, sense):
						local_best_obj = nobj
						local_best_idx = ncand
						moved = true
			if not moved:
				break
			idx = local_best_idx
			cur_obj = local_best_obj
			if _is_better(cur_obj, best_obj, sense):
				best_obj = cur_obj
				best_combo = _combo_from_idx(grids, idx)
	else:
		var all_combos: Array = _cartesian(grids)
		var order: Array = _opt_order(all_combos, method, budget, base_seed)
		for k in order:
			if _exp_cancel:
				break
			var combo: Array = all_combos[k]
			var obj_val: float = _eval_combo(decision_vars, combo, objective, reps, run_len, warmup_t, base_seed)
			evaluated += 1
			history.append({"assign": _assign_labels(decision_vars, combo), "obj": obj_val})
			if not best_set or _is_better(obj_val, best_obj, sense):
				best_set = true
				best_obj = obj_val
				best_combo = combo
			await _exp_yield(evaluated, budget, "opt")
	seed = prev_seed
	warmup = prev_warm
	cancelled = _exp_cancel
	exp_busy = false
	_exp_cancel = false
	return {
		"best": _assign_labels(decision_vars, best_combo),
		"best_obj": best_obj, "evaluated": evaluated,
		"method": method, "history": history, "cancelled": cancelled,
	}

## 決定変数1つの離散格子（min..max を step 刻み）を値配列で返す。
## step<=0 は単一値[min]。浮動小数の誤差を吸収するため微小許容を加える。
func _grid_values(dv: Dictionary) -> Array:
	var lo: float = float(dv.get("min", 0.0))
	var hi: float = float(dv.get("max", 0.0))
	var st: float = float(dv.get("step", 0.0))
	var vals: Array = []
	if hi < lo:
		return vals
	if st <= 0.0:
		vals.append(lo)
		return vals
	var eps: float = st * 1e-6
	var v: float = lo
	var guard: int = 0
	while v <= hi + eps and guard < 100000:
		vals.append(v)
		v += st
		guard += 1
	return vals

## 格子インデックス配列 idx から各変数の実値配列（combo）を作る。
func _combo_from_idx(grids: Array, idx: Array) -> Array:
	var combo: Array = []
	for d in range(grids.size()):
		combo.append((grids[d] as Array)[idx[d]])
	return combo

## 全格子のデカルト積（各要素は値配列 combo）。列挙順は決定的。
func _cartesian(grids: Array) -> Array:
	var result: Array = [[]]
	for g in grids:
		var next: Array = []
		for prefix in result:
			for v in (g as Array):
				var row: Array = (prefix as Array).duplicate()
				row.append(v)
				next.append(row)
		result = next
	return result

## combo（各決定変数の値）を "obj_id.param":値 のラベル辞書へ変換（返り値用）。
func _assign_labels(decision_vars: Array, combo: Array) -> Dictionary:
	var out: Dictionary = {}
	for d in range(decision_vars.size()):
		if d >= combo.size():
			break
		var dv: Dictionary = decision_vars[d]
		var key: String = "%s.%s" % [str(dv.get("obj_id", "?")), str(dv.get("param", "?"))]
		out[key] = combo[d]
	return out

## sense に応じて a が b より良いか（max:大きいほど良い / min:小さいほど良い）。
func _is_better(a: float, b: float, sense: String) -> bool:
	if sense == "min":
		return a < b
	return a > b

## KPI平均から目的関数値を算出。custom は weights の線形結合。
func _objective_value(means: Dictionary, objective: Dictionary) -> float:
	var metric: String = str(objective.get("metric", "throughput"))
	if metric == "custom":
		var w: Dictionary = objective.get("weights", {})
		return float(w.get("throughput", 0.0)) * float(means.get("throughput", 0.0)) \
			+ float(w.get("leadtime", 0.0)) * float(means.get("leadtime", 0.0)) \
			+ float(w.get("wip", 0.0)) * float(means.get("wip", 0.0))
	return float(means.get(metric, 0.0))

## decision_vars と1つの combo から override 辞書 {obj_id:{top:val}} を構築。
## 分布サブキー（"process_time.a"）は現行分布を複製してサブキーのみ差し替え。
## 同一 obj+top に複数決定変数がある場合は複製へ累積適用する。
func _build_opt_overrides(decision_vars: Array, combo: Array) -> Dictionary:
	var by_obj: Dictionary = {}
	for d in range(decision_vars.size()):
		var dv: Dictionary = decision_vars[d]
		var oid: String = str(dv.get("obj_id", ""))
		var obj = _find_object(oid)
		if obj == null:
			continue
		var cur: Dictionary = obj.get_params()
		var parts: PackedStringArray = str(dv.get("param", "")).split(".", false)
		if parts.is_empty():
			continue
		var top: String = parts[0]
		if not cur.has(top):
			continue
		var has_sub: bool = parts.size() >= 2
		var top_is_dist: bool = cur[top] is Dictionary
		if not by_obj.has(oid):
			by_obj[oid] = {}
		var v = combo[d]
		if has_sub and top_is_dist:
			var base: Dictionary
			if (by_obj[oid] as Dictionary).has(top):
				base = by_obj[oid][top]
			else:
				base = (cur[top] as Dictionary).duplicate(true)
			base[parts[1]] = v
			by_obj[oid][top] = base
		elif top_is_dist:
			by_obj[oid][top] = {"type": "const", "a": v}
		else:
			by_obj[oid][top] = v
	return by_obj

## 1候補（combo）を CRN reps で評価し目的関数値を返す。実行後にパラメータを厳密復元。
func _eval_combo(decision_vars: Array, combo: Array, objective: Dictionary,
		reps: int, run_len: float, warmup_t: float, base_seed: int) -> float:
	var over_by_obj: Dictionary = _build_opt_overrides(decision_vars, combo)
	# override 適用前の元パラメータ（実値のみ）を退避。
	var saved: Dictionary = {}
	for oid in over_by_obj.keys():
		var obj = _find_object(oid)
		if obj == null:
			continue
		var cur: Dictionary = obj.get_params()
		var ovr: Dictionary = over_by_obj[oid]
		var old_vals: Dictionary = {}
		var applied: Dictionary = {}
		for pk in ovr.keys():
			if cur.has(pk):
				old_vals[pk] = cur[pk]
				applied[pk] = ovr[pk]
		saved[oid] = old_vals
		if not applied.is_empty():
			obj.set_params(applied.duplicate(true))
	# CRN: 全候補で同一 base_seed+i の列を使う。
	var thr: Array = []
	var lts: Array = []
	var wips: Array = []
	for i in range(reps):
		seed = base_seed + i
		warmup = warmup_t
		reset_sim()
		run_until(warmup_t + run_len)
		var kpi := collect_kpi()
		thr.append(kpi.throughput)
		lts.append(kpi.leadtime)
		wips.append(kpi.wip)
	# 元へ復元。
	for oid in saved.keys():
		var obj = _find_object(oid)
		if obj != null:
			obj.set_params(saved[oid])
	var means: Dictionary = {"throughput": _mean(thr), "leadtime": _mean(lts), "wip": _mean(wips)}
	return _objective_value(means, objective)

# ---------------------------------------------------------------
# 出力解析(1): Welch法によるwarmup(過渡期)推定
# ---------------------------------------------------------------
## 全 Sink の累計出力数を返す（区間スループット算出用）。
func _total_out() -> int:
	var t: int = 0
	for o in objects:
		if o is Sink:
			t += o.total
	return t

## Welch法: reps レプリケーション(CRN: base_seed+i)で時間バケット別のメトリクス時系列を
## 記録→レプリカ平均→移動平均(window)して、系列が定常水準へ落ち着くバケット(truncation
## point)を推定する。metric: "throughput"(区間スループット/時) or "wip"(区間平均WIP)。
## 記録は run_until をバケット境界まで小刻みに進めて sampling する（決定的）。
## returns {"warmup", "bucket_dt", "num_buckets", "series_len", "steady",
##          "trunc_bucket", "metric", "series"(平滑後系列)}
func estimate_warmup(reps: int, run_len: float, base_seed: int, metric: String = "throughput", window: int = 5, num_buckets: int = 50) -> Dictionary:
	reps = max(1, reps)
	num_buckets = max(4, num_buckets)
	window = clampi(window, 1, num_buckets)
	var bucket_dt: float = run_len / float(num_buckets)
	var prev_seed: int = seed
	var prev_warm: float = warmup
	# レプリカ横断の合計（後で reps で割って平均化）
	var sum_series: Array = []
	sum_series.resize(num_buckets)
	for b in range(num_buckets):
		sum_series[b] = 0.0
	for i in range(reps):
		seed = base_seed + i
		warmup = 0.0            # 過渡期をそのまま観測するため統計リセットしない
		reset_sim()
		var prev_out: int = 0
		var prev_area: float = 0.0
		for b in range(num_buckets):
			run_until(float(b + 1) * bucket_dt)
			var val: float = 0.0
			if metric == "wip":
				_wip_accum()
				val = (_wip_area - prev_area) / bucket_dt
				prev_area = _wip_area
			else:
				var out_now: int = _total_out()
				val = float(out_now - prev_out) / bucket_dt * 3600.0
				prev_out = out_now
			sum_series[b] += val
	seed = prev_seed
	warmup = prev_warm
	# レプリカ平均
	var mean_series: Array = []
	for b in range(num_buckets):
		mean_series.append(float(sum_series[b]) / float(reps))
	# 移動平均(trailing window)で平滑化
	var smooth: Array = []
	for b in range(num_buckets):
		var lo: int = max(0, b - window + 1)
		var s: float = 0.0
		for k in range(lo, b + 1):
			s += float(mean_series[k])
		smooth.append(s / float(b - lo + 1))
	# 定常水準 = 系列後半1/3の平滑値平均
	var tail_start: int = int(num_buckets * 2 / 3)
	var steady: float = 0.0
	var cnt: int = 0
	for b in range(tail_start, num_buckets):
		steady += float(smooth[b]); cnt += 1
	steady = steady / float(max(1, cnt))
	# truncation point: 平滑系列が定常水準の相対誤差 tol 以内へ初めて到達するバケット。
	# 過渡（充填中は低水準）→ 定常 で単調に近づくため、初回到達バケットが過渡期の終わり。
	var tol: float = 0.05
	var trunc_b: int = num_buckets - 1
	for b in range(num_buckets):
		if abs(float(smooth[b]) - steady) <= tol * abs(steady):
			trunc_b = b
			break
	var warm_time: float = float(trunc_b) * bucket_dt
	return {
		"warmup": warm_time, "bucket_dt": bucket_dt, "num_buckets": num_buckets,
		"series_len": num_buckets, "steady": steady, "trunc_bucket": trunc_b,
		"metric": metric, "series": smooth,
	}

# ---------------------------------------------------------------
# 出力解析(2): 目標精度に基づく反復数の自動決定
# ---------------------------------------------------------------
## レプリケーションを順次追加し、スループット95%CI半値幅/平均(相対半値幅)が
## target_rel_halfwidth 以下になったら停止（max_reps 上限, min_reps 下限）。決定的。
## returns {"reps", "thr_mean", "thr_ci", "rel_hw", "target", "reached", "throughput"}
func run_until_precision(run_len: float, warmup_t: float, base_seed: int, target_rel_halfwidth: float, max_reps: int, min_reps: int = 3) -> Dictionary:
	min_reps = max(2, min_reps)
	max_reps = max(min_reps, max_reps)
	var prev_seed: int = seed
	var prev_warm: float = warmup
	var thr: Array = []
	var rel: float = INF
	var reps_done: int = 0
	for i in range(max_reps):
		seed = base_seed + i
		warmup = warmup_t
		reset_sim()
		run_until(warmup_t + run_len)
		thr.append(collect_kpi().throughput)
		reps_done += 1
		if reps_done >= min_reps:
			var m: float = _mean(thr)
			var ci: float = _ci95(thr)
			rel = (ci / m) if m > 0.0 else INF
			if rel <= target_rel_halfwidth:
				break
	seed = prev_seed
	warmup = prev_warm
	return {
		"reps": reps_done, "thr_mean": _mean(thr), "thr_ci": _ci95(thr),
		"rel_hw": rel, "target": target_rel_halfwidth,
		"reached": rel <= target_rel_halfwidth, "throughput": thr,
	}

# ---------------------------------------------------------------
# 出力解析(3): レポート出力(HTML + CSV)
# ---------------------------------------------------------------
func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

## 現在登録中のモデルを実験(run_replications)し、集計KPIと各設備の稼働率・状態内訳・
## Queueの Lq/Wq を含む自己完結HTML(user://report.html)とCSV(user://report.csv)を出力。
## returns {"html", "csv", "res"(run_replications結果)}
func generate_report(reps: int, run_len: float, warmup_t: float, base_seed: int) -> Dictionary:
	var res: Dictionary = run_replications(reps, run_len, warmup_t, base_seed)
	# 代表1ラン(base_seed)で各設備の詳細統計を採取
	var prev_seed: int = seed
	var prev_warm: float = warmup
	seed = base_seed
	warmup = warmup_t
	reset_sim()
	run_until(warmup_t + run_len)
	var kpi: Dictionary = collect_kpi()
	var rows: Array = []
	var conn_count: int = 0
	for o in objects:
		if not (o is FlowObject):
			continue
		conn_count += o.outputs.size()
		var out_ids: Array = []
		for t in o.outputs:
			out_ids.append(t.id)
		var row: Dictionary = {
			"id": o.id, "name": o.obj_name, "type": o.type_name(),
			"util": o.utilization(), "states": o.state_durations(),
			"outputs": out_ids, "lq": -1.0, "wq": -1.0,
		}
		if o is Queue:
			row["lq"] = o.avg_length()
			row["wq"] = o.avg_wait()
		rows.append(row)
	seed = prev_seed
	warmup = prev_warm
	var html_path: String = "user://report.html"
	var csv_path: String = "user://report.csv"
	_write_report_html(html_path, res, kpi, rows, conn_count, reps, run_len, warmup_t, base_seed)
	_write_report_csv(csv_path, res, kpi, rows)
	return {"html": html_path, "csv": csv_path, "res": res}

func _write_report_html(path: String, res: Dictionary, kpi: Dictionary, rows: Array, conn_count: int, reps: int, run_len: float, warmup_t: float, base_seed: int) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	var h: String = ""
	h += "<!DOCTYPE html><html lang=\"ja\"><head><meta charset=\"utf-8\">"
	h += "<title>シミュレーションレポート</title><style>"
	h += "body{font-family:sans-serif;background:#f4f5f8;color:#222;margin:24px;}"
	h += "h1{font-size:20px;} h2{font-size:16px;border-bottom:2px solid #4a6;padding-bottom:4px;margin-top:24px;}"
	h += "table{border-collapse:collapse;margin:8px 0;font-size:13px;}"
	h += "th,td{border:1px solid #ccc;padding:4px 8px;text-align:right;}"
	h += "th{background:#e8ecf4;} td:first-child,th:first-child{text-align:left;}"
	h += ".muted{color:#777;}"
	h += "</style></head><body>"
	h += "<h1>シミュレーション出力レポート</h1>"
	# 実行条件（%% は書式文字列でないので単一 %）
	h += "<p class=\"muted\">reps=%d 実行長=%.0f warmup=%.0f base_seed=%d</p>" % [reps, run_len, warmup_t, base_seed]
	# モデル概要
	h += "<h2>モデル概要</h2><table>"
	h += "<tr><th>設備数</th><th>接続数</th></tr>"
	h += "<tr><td>%d</td><td>%d</td></tr></table>" % [rows.size(), conn_count]
	# KPI（この節タイトルは書式演算子を使わないので単一 %）
	h += "<h2>KPI (平均 ± 95% CI)</h2><table>"
	h += "<tr><th>指標</th><th>平均</th><th>95% CI 半値幅</th></tr>"
	h += "<tr><td>スループット (個/時)</td><td>%.2f</td><td>±%.2f</td></tr>" % [res.thr_mean, res.thr_ci]
	h += "<tr><td>滞留時間 (秒)</td><td>%.2f</td><td>±%.2f</td></tr>" % [res.lt_mean, res.lt_ci]
	h += "<tr><td>WIP (系内在庫)</td><td>%d</td><td class=\"muted\">代表ラン</td></tr>" % [int(kpi.wip)]
	h += "</table>"
	# 各設備
	h += "<h2>各設備の稼働率・状態内訳</h2><table>"
	h += "<tr><th>ID</th><th>種別</th><th>稼働率</th><th>状態内訳(秒)</th><th>Lq</th><th>Wq(秒)</th></tr>"
	for r in rows:
		var st: String = ""
		for k in r.states:
			st += "%s=%.0f " % [k, float(r.states[k])]
		var lq: String = ("%.2f" % r.lq) if r.lq >= 0.0 else "-"
		var wq: String = ("%.2f" % r.wq) if r.wq >= 0.0 else "-"
		# "%.1f%%" は書式文字列なので %% が literal %
		h += "<tr><td>%s</td><td>%s</td><td>%.1f%%</td><td>%s</td><td>%s</td><td>%s</td></tr>" % [
			_esc(str(r.id)), _esc(str(r.type)), float(r.util) * 100.0, _esc(st.strip_edges()), lq, wq]
	h += "</table>"
	h += "<p class=\"muted\">自己完結HTML (インラインCSS)。生成: FlexSimGodot Sim.generate_report</p>"
	h += "</body></html>"
	f.store_string(h)
	f.close()

func _write_report_csv(path: String, res: Dictionary, kpi: Dictionary, rows: Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("section,key,value1,value2")
	f.store_line("model,equipment_count,%d," % rows.size())
	var cc: int = 0
	for r in rows:
		cc += r.outputs.size()
	f.store_line("model,connection_count,%d," % cc)
	f.store_line("kpi,throughput_per_hour,%.3f,%.3f" % [res.thr_mean, res.thr_ci])
	f.store_line("kpi,leadtime_s,%.3f,%.3f" % [res.lt_mean, res.lt_ci])
	f.store_line("kpi,wip,%d," % int(kpi.wip))
	f.store_line("")
	f.store_line("obj_id,type,utilization,lq,wq")
	for r in rows:
		f.store_line("%s,%s,%.4f,%.4f,%.4f" % [str(r.id), str(r.type), float(r.util), float(r.lq), float(r.wq)])
	f.close()

func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s: float = 0.0
	for v in a:
		s += float(v)
	return s / a.size()

# Student の t 分布・両側95%点（t.975）。df=1..30 の正確値、df>30 は 1.96。
const T95 := {
	1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
	6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
	11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131,
	16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086,
	21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064, 25: 2.060,
	26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042,
}

func _t95(df: int) -> float:
	if df <= 0:
		return 0.0
	if df <= 30:
		return float(T95[df])
	return 1.96   # df>30 は正規近似で十分

func _ci95(a: Array) -> float:
	var n: int = a.size()
	if n < 2:
		return 0.0
	var m: float = _mean(a)
	var ss: float = 0.0
	for v in a:
		ss += pow(float(v) - m, 2.0)
	var sd: float = sqrt(ss / (n - 1))
	# 95%CI 半幅: t(df=n-1) * sd / sqrt(n)（正規1.96固定ではなく Student の t）
	return _t95(n - 1) * sd / sqrt(float(n))
