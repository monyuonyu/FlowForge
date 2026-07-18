extends RefCounted
class_name ProcessFlow
## トークン式ロジック層（FlexSim Process Flow 相当・stage 1/2）。
##
## 【位置づけ】既存の既定モデル（FlowObject 群）とは完全に独立した「オプトイン」の別系。
##   - autoload には登録しない（project.godot 不変）。Sim にも register しない。
##   - このファイルは存在するだけでは何も動かない。呼び出し側が明示的に
##     ProcessFlow.new(spec) → run() したときにのみ、共有 Sim イベントカレンダーを駆動する。
##   - 従って既定モデルの RNG 抽選順・イベント順・セルフテストの各マーカーには一切干渉しない。
##
## 【決定論（HARD INVARIANT 1/2）】
##   - 乱数は Rng.stream("pf:" + activity_id) のみを使用（Math.random 相当は使わない）。
##   - 各確率的アクティビティは、自分専用ストリームから決められた順序で抽選する（下記）。
##   - 同一 seed → バイト同一結果。ストリームキーは "pf:" 接頭辞で既存キーと衝突しない。
##
## 【RNG 抽選順（ストリーム別・固定）】
##   Source   ("pf:"+id): 1到着ごとに interarrival を1回 Dist.sample。到着（イベント）時刻順。
##   Delay    ("pf:"+id): 1トークン入場ごとに duration を1回 Dist.sample。
##   Decide   ("pf:"+id): probabilistic 時、1トークンごとに randf() を1回。条件分岐時は無抽選。
##   Assign/Batch/Unbatch/Acquire/Release/Sink: 乱数を引かない。
##   stage 2 の新アクティビティ（wait_event / acquire_resource / release_resource /
##     create_item / push_object / travel）は【一切乱数を引かない】。従って "pf:" ストリームの
##     消費位置を動かさず、これらを使わない既存モデルの抽選順・結果はバイト同一のまま。
##   Load/Unload ("pf:"+id): time が確率分布のときのみ dwell を1回 Dist.sample（1トークン入場ごと）。
##     time が数値/{"type":"const"} なら無抽選（Dist.sample は const で乱数を引かない）。
##     travel の移動時間は距離/ネットワークで決定的（無抽選）。
##   ※各アクティビティは独立ストリームなので、跨いだ抽選タイミングは互いに干渉しない。
##
## 【stage 2：実3Dモデル連携（オプトイン・既定ドーマント）】
##   トークンが実 FlowObject / 実プール（OperatorPool・TransportPool）を編成する橋渡し。
##   spec に下記の新 type を含めるか、bind_objects()/run_isolated() を呼んだ時のみ働く。
##   これらを使わない spec は従来経路のみを通り、既存マーカー値はバイト同一。
##
##   bind_objects(map): PF の参照キー(アクティビティ id / 任意名) → 実オブジェクト/プールを束縛。
##     値は Object 実体、または String（Sim.objects 内の FlowObject id）で与える。
##
##   "wait_event": 束縛オブジェクトが item_entered（既定）/item_exited（signal:"exited"）を
##     emit するまでトークンをブロック。emit 時に「そのオブジェクトで待つトークン群」を
##     FIFO（到着順）で1件だけ払い出し、発火した FlowItem を token.item に束縛して next へ。
##     実装は (オブジェクト×シグナル) 毎に1接続＋待ち行列。行列が空になった時点で
##     disconnect（クリーン切断）。乱数・イベント予約なし。
##     spec: {"type":"wait_event","object":<key>,"signal":"entered"|"exited","next":...}
##
##   "acquire_resource": 実プールから REAL 資源（Operator/Transporter）を1つ確保。
##     空きが無ければトークンを FIFO で待機。release 時に「最長待ち（行列先頭）」へ先に
##     引き渡す（追い越し無し）。確保した実体は token._res / token.labels["resource"] に束縛。
##     ディスパッチ/解放は _real_res[key] の dispatched/released で均衡（リーク検出可能）。
##     spec: {"type":"acquire_resource","pool":<key>,"next":...}
##   "release_resource": token._res の実資源をプールへ返却し、行列先頭へ再割当（追い越し無し）。
##     spec: {"type":"release_resource","pool":<key>,"next":...}
##
##   "create_item": トークン用に FlowItem を新規生成し token.item へ束縛（Sim.wip は増やさない：
##     wip はトークン単位で計上済み）。spec: {"type":"create_item","item_type":<int>,"next":...}
##   "push_object": token.item を束縛オブジェクトへ receive_item で注入（所有権を実モデルへ移譲、
##     token.item は解除）。spec: {"type":"push_object","object":<key>,"next":...}
##
##   【タスクシーケンス（確保済み REAL 資源を物理移動）】前提: 先の acquire_resource で
##     token._res に Operator/Transporter を確保済み（未確保なら push_error して素通り）。
##   "travel": 確保ユニットを目的地へ物理移動し、到着までトークンをブロック→next。
##     spec: {"type":"travel","to":<key|[x,z]|"pickup"|"dropoff">,"state":<任意>,"next":...}
##     to 解決: [x,z]→Vector3(x,0,z) / 文字列→束縛オブジェクト位置、無ければ token.labels[key] 座標。
##     Transporter は unit._travel_to(pos, state, on_arrive) を使い、有限容量辺ネットワーク上では
##       AGV 輻輳（辺容量待ち）を自動包含。Operator は travel_time→go_to→Sim.schedule。乱数なし。
##   "load": token.item をユニットへ積む dwell（時間消費のみ）→next。item が null でも有効な dwell。
##     spec: {"type":"load","time":<const or dist>,"next":...}
##   "unload": 投下 dwell を消費し、"to" があれば token.item を実オブジェクトへ
##     _push_item_or_wait（バックプレッシャー安全・item を落とさない）で引き渡す→next。
##     成功時は push_object 同様 _wip_transferred を立て item 束縛を解除。
##     spec: {"type":"unload","time":<const or dist>,"to":<bound obj key 任意>,"next":...}
##   Load/Unload の time は数値/{"type":"const"} なら無抽選、確率分布なら pf:+id から1回抽選。
##
##   Sink: token.item があれば dispose（route 指定時は束縛先へ receive_item して手放す）。
##     item は create_item 時に wip を触っていないので、dispose も wip を触らない
##     （保存則：トークン計上と item 計上の双方が閉じる。_items_created==_items_disposed）。
##
##   run_isolated(run_len, seed): stage 1 の分離（Sim.set_sources_enabled(false)）を掛けてから
##     run() し、直後に元へ復元。既定モデルの Source が並走しないため、分離中は
##     Sim.wip が PF in_flight と厳密一致する（従来は既定モデルが並走して不可能だった）。
##
## 【保存則（HARD INVARIANT 3）】
##   created == sunk + in_flight を常時満たす。created は Source が生成した「葉トークン」数。
##   Batch は葉トークンを容器トークンに束ねるだけで葉は消さない（容器は created に数えない）。
##   Sink は容器を再帰的に分解して葉単位で sunk する。従って葉の増減は Source と Sink のみ。
##
## 【統計】kpi() は時間加重の資源稼働率（Sim.avg_wip と同じ面積方式）を返す。
##
## 【spec 形式（直列化前提の Dictionary）】
##   {
##     "seed": 12345,                                  # 省略可（既定 self.seed）
##     "resources": {"machine": 2, "op": {"capacity":3}},  # 容量N。int か {"capacity":N}
##     "activities": [                                  # 挿入順を保持（統計・初期化の反復順）
##       {"id":"src","type":"source","interarrival":{"type":"exp","a":3.0},
##        "max_arrivals":100,"next":"d1"},
##       {"id":"d1","type":"delay","duration":{"type":"const","a":2.0},"next":"asg"},
##       {"id":"asg","type":"assign","assignments":{"prio":1,"x":{"op":"add","a":"$prio","b":1}},"next":"dec"},
##       {"id":"dec","type":"decide","mode":"probabilistic","weights":[0.7,0.3],"next":["a","b"]},
##       {"id":"a","type":"acquire","resource":"machine","next":"work"},
##       {"id":"work","type":"delay","duration":{"type":"exp","a":1.5},"next":"rel"},
##       {"id":"rel","type":"release","resource":"machine","next":"snk"},
##       {"id":"snk","type":"sink"}
##     ]
##   }
##   分布 Dictionary は本プロジェクトの Dist の鍵に従う（"a"/"b"/"c"）。
##     例 {"type":"const","a":2.0} / {"type":"exp","a":3.0} / {"type":"uniform","a":1,"b":2}
##        / {"type":"triangular","a":1,"b":2,"c":3}

const DEFAULT_IA: Dictionary = {"type": "exp", "a": 3.0}
const DEFAULT_DUR: Dictionary = {"type": "const", "a": 1.0}

# ---------------------------------------------------------------
# トークン（軽量 RefCounted）
# ---------------------------------------------------------------
class Token extends RefCounted:
	var id: int = 0
	var labels: Dictionary = {}         # ユーザーラベル（Assign/Decide が読み書き）
	var created_time: float = 0.0       # 生成時刻（Sink で cycle time = now - created_time）
	var _activity: String = ""          # 現在アクティビティ id
	var _members: Array = []            # Batch 容器のとき: 内包する葉/子トークン群
	var _acq_next = null                # Acquire 待ち行列中に保持する「取得後の next」
	var trace: Array = []               # 通過アクティビティ id 列（trace_enabled 時のみ追記）
	# --- stage 2：実3Dモデル連携（既定 null=未使用。使わない限りドーマント） ---
	var item = null                     # 束縛 FlowItem（create_item / wait_event / adopt で設定）
	var _res = null                     # 確保した REAL 資源（Operator/Transporter 実体）
	var _res_key: String = ""           # _res を確保した実プールの束縛キー（release 用）
	# BUG3: item の所有権を実3Dモデルへ移譲済みか。true の間は PF sink で wip_dec しない
	# （物理実体の wip は移譲先＝実 Sink 到達 or 3D 内滞留で閉じる。二重減算を防ぐ）。
	var _wip_transferred: bool = false

# ---------------------------------------------------------------
# 計数資源プール（容量N・FIFO 待ち行列・時間加重稼働率）
# ---------------------------------------------------------------
class ResourcePool extends RefCounted:
	var id: String = ""
	var capacity: int = 1
	var in_use: int = 0
	var queue: Array = []               # 容量待ちの Token（FIFO）
	var _area: float = 0.0              # ∫ in_use dt（時間加重）
	var _last_t: float = 0.0

	func reset() -> void:
		in_use = 0
		queue.clear()
		_area = 0.0
		_last_t = Sim.sim_time

	func _accum() -> void:
		# 時刻逆行に備え dt を非負ガード（Sim._wip_accum と同方針）。
		var dt: float = max(0.0, Sim.sim_time - _last_t)
		_area += float(in_use) * dt
		_last_t = max(_last_t, Sim.sim_time)

	func acquire_now() -> void:
		_accum()
		in_use += 1

	func release_now() -> void:
		_accum()
		in_use = max(0, in_use - 1)

	func utilization() -> float:
		_accum()
		var elapsed: float = Sim.stats_elapsed()
		if capacity <= 0 or elapsed <= 0.0:
			return 0.0
		return _area / (float(capacity) * elapsed)

# ---------------------------------------------------------------
# ProcessFlow 本体
# ---------------------------------------------------------------
var seed: int = 12345               # run() が Sim.seed に設定して再現性を担保
var trace_enabled: bool = false     # true でトークンごとの通過履歴を記録

var _activities: Dictionary = {}    # id(String) -> activity(Dictionary)
var _order: Array = []              # spec 挿入順の id 列（決定的反復用）
var _resources: Dictionary = {}     # id(String) -> ResourcePool
var _res_order: Array = []          # 資源 id の挿入順

# --- stage 2：実3Dモデル連携の状態（既定空＝ドーマント） ---
var _bindings: Dictionary = {}      # 参照キー(String) -> 実オブジェクト/プール
var _waits: Dictionary = {}         # "iid|sig" -> {obj, sig, cb, queue:Array[{token,next}]}
var _push_waits: Dictionary = {}    # "iid" -> {obj, cb, queue:Array[{token,next,mode}]}（BUG1 バックプレッシャー待ち）
var _real_res: Dictionary = {}      # プールキー -> {pool, kind, waiters, dispatched, released, held}
var _items_created: int = 0         # create_item で生成した FlowItem 数（item 保存則の検証用）
var _items_disposed: int = 0        # Sink で dispose した FlowItem 数
var _wait_capture_log: Array = []   # [[token.id, item.id], ...]（wait_event の FIFO 検証用）
var _res_release_log: Array = []    # release 順の token.id（追い越し無しの検証用）

# 統計
var created: int = 0
var sunk: int = 0
var _cycle_sum: float = 0.0
var _cycle_n: int = 0
var _enter_count: Dictionary = {}   # activity id -> 入場トークン数
var _tok_seq: int = 0               # トークン通番（PF 内で独立・決定的）

func _init(spec: Dictionary = {}) -> void:
	if not spec.is_empty():
		build(spec)

# ---------------------------------------------------------------
# 構築（spec Dictionary から）
# ---------------------------------------------------------------
func build(spec: Dictionary) -> void:
	_activities.clear()
	_order.clear()
	_resources.clear()
	_res_order.clear()
	if spec.has("seed"):
		seed = int(spec["seed"])
	var res = spec.get("resources", {})
	if res is Dictionary:
		for rid in res:
			var cap: int = 1
			var rv = res[rid]
			if rv is Dictionary:
				cap = int(rv.get("capacity", 1))
			else:
				cap = int(rv)
			var p := ResourcePool.new()
			p.id = str(rid)
			p.capacity = max(1, cap)
			_resources[str(rid)] = p
			_res_order.append(str(rid))
	var acts = spec.get("activities", [])
	if acts is Array:
		for a in acts:
			if not (a is Dictionary):
				continue
			var ad: Dictionary = (a as Dictionary).duplicate(true)
			var aid: String = str(ad.get("id", ""))
			if aid == "":
				continue
			ad["id"] = aid
			ad["_buffer"] = []
			ad["_created"] = 0
			_activities[aid] = ad
			_order.append(aid)

func activity_ids() -> Array:
	return _order.duplicate()

func resource_ids() -> Array:
	return _res_order.duplicate()

# ---------------------------------------------------------------
# 実行（再現可能）
# ---------------------------------------------------------------
## リセット→シード→run_until→kpi。run_seed>=0 なら seed を上書き。
func run(run_len: float, run_seed: int = -1) -> Dictionary:
	if run_seed >= 0:
		seed = run_seed
	Sim.seed = seed
	Sim.warmup = 0.0
	Sim.reset_sim()          # 共有 Sim を初期化（heap クリア・sim_time=0・Rng.reset(seed)）
	_reset_state()           # PF 側の統計/資源/バッファ初期化 → 初回到着を予約
	Sim.run_until(run_len)
	return kpi()

func _reset_state() -> void:
	created = 0
	sunk = 0
	_cycle_sum = 0.0
	_cycle_n = 0
	_tok_seq = 0
	_enter_count.clear()
	_clear_bridge_state()    # stage 2 の橋渡し状態を初期化（未使用なら実質ノーオペ）
	for aid in _order:
		var act: Dictionary = _activities[aid]
		act["_buffer"] = []
		act["_created"] = 0
		_enter_count[aid] = 0
	for rid in _res_order:
		(_resources[rid] as ResourcePool).reset()
	# 初回到着を Source ごとに予約（spec 順＝Sim.schedule の seq 順で決定的タイブレーク）。
	for aid in _order:
		if str(_activities[aid].get("type", "")) == "source":
			_source_schedule_next(aid)

# ---------------------------------------------------------------
# 統計 API
# ---------------------------------------------------------------
func kpi() -> Dictionary:
	var util: Dictionary = {}
	for rid in _res_order:
		util[rid] = (_resources[rid] as ResourcePool).utilization()
	var counts: Dictionary = {}
	for aid in _order:
		counts[aid] = int(_enter_count.get(aid, 0))
	var avg_ct: float = (_cycle_sum / float(_cycle_n)) if _cycle_n > 0 else 0.0
	return {
		"created": created,
		"sunk": sunk,
		"in_flight": created - sunk,
		"avg_cycle_time": avg_ct,
		"per_activity_counts": counts,
		"resource_utilization": util,
	}

# ---------------------------------------------------------------
# トークン供給（Source）
# ---------------------------------------------------------------
func _new_token() -> Token:
	var t := Token.new()
	_tok_seq += 1
	t.id = _tok_seq
	t.created_time = Sim.sim_time
	return t

func _source_schedule_next(act_id: String) -> void:
	var act: Dictionary = _activities[act_id]
	var mx: int = int(act.get("max_arrivals", -1))
	if mx >= 0 and int(act.get("_created", 0)) >= mx:
		return   # 上限到達：以後は抽選もイベント予約もしない
	var d: float = Dist.sample(act.get("interarrival", DEFAULT_IA), Rng.stream("pf:" + act_id))
	Sim.schedule(d, _source_gen.bind(act_id))

func _source_gen(act_id: String) -> void:
	var act: Dictionary = _activities[act_id]
	var mx: int = int(act.get("max_arrivals", -1))
	if mx >= 0 and int(act.get("_created", 0)) >= mx:
		return
	var tok := _new_token()
	act["_created"] = int(act.get("_created", 0)) + 1
	created += 1
	Sim.wip_inc()
	_bump_enter(act_id)
	_advance(tok, act.get("next", null))
	_source_schedule_next(act_id)

# ---------------------------------------------------------------
# トークン推進：瞬時アクティビティは同期実行、時間消費は Sim.schedule
# ---------------------------------------------------------------
func _bump_enter(aid: String) -> void:
	_enter_count[aid] = int(_enter_count.get(aid, 0)) + 1

func _advance(token: Token, next_id) -> void:
	if next_id == null:
		return
	var nid: String = str(next_id)
	if nid == "":
		return
	var act = _activities.get(nid, null)
	if act == null:
		push_error("ProcessFlow: 未知のアクティビティ '%s'" % nid)
		return
	token._activity = nid
	_bump_enter(nid)
	if trace_enabled:
		token.trace.append(nid)
	_dispatch(token, act)

func _dispatch(token: Token, act: Dictionary) -> void:
	match str(act.get("type", "")):
		"delay":
			_do_delay(token, act)
		"assign":
			_do_assign(token, act)
		"decide":
			_do_decide(token, act)
		"batch":
			_do_batch(token, act)
		"unbatch":
			_do_unbatch(token, act)
		"acquire":
			_do_acquire(token, act)
		"release":
			_do_release(token, act)
		"wait_event":
			_do_wait_event(token, act)
		"acquire_resource":
			_do_acquire_resource(token, act)
		"release_resource":
			_do_release_resource(token, act)
		"create_item":
			_do_create_item(token, act)
		"push_object":
			_do_push_object(token, act)
		"travel":
			_do_travel(token, act)
		"load":
			_do_load(token, act)
		"unload":
			_do_unload(token, act)
		"sink":
			_do_sink(token, act)
		"source":
			# Source ノードへ経路指定された場合は通過扱い（生成はしない）。
			_advance(token, act.get("next", null))
		_:
			push_error("ProcessFlow: 未知のアクティビティ種別 '%s'" % str(act.get("type", "")))

# --- Delay ---
func _do_delay(token: Token, act: Dictionary) -> void:
	var d: float = Dist.sample(act.get("duration", DEFAULT_DUR), Rng.stream("pf:" + str(act.get("id", ""))))
	var nid = act.get("next", null)
	Sim.schedule(d, func() -> void: _advance(token, nid))

# --- Assign（定数 or expression-lite） ---
func _do_assign(token: Token, act: Dictionary) -> void:
	var assigns = act.get("assignments", {})
	if assigns is Dictionary:
		for k in assigns:
			token.labels[str(k)] = _eval_value(assigns[k], token)
	_advance(token, act.get("next", null))

## expression-lite の評価:
##   非文字列（int/float/bool）    → 定数
##   "$name"                       → token.labels["name"] を参照
##   その他の文字列                → 文字列定数
##   {"op":"add|sub|mul|div","a":<v>,"b":<v>} → 再帰評価した数値演算
func _eval_value(spec, token: Token):
	if spec is String:
		var s: String = spec
		if s.begins_with("$"):
			return token.labels.get(s.substr(1), null)
		return s
	if spec is Dictionary and spec.has("op"):
		var a = _eval_value(spec.get("a", 0), token)
		var b = _eval_value(spec.get("b", 0), token)
		match str(spec["op"]):
			"add": return _num(a) + _num(b)
			"sub": return _num(a) - _num(b)
			"mul": return _num(a) * _num(b)
			"div": return (_num(a) / _num(b)) if _num(b) != 0.0 else 0.0
			_: return a
	return spec

# --- Decide（確率分岐 or ラベル条件・決定的タイブレーク） ---
func _do_decide(token: Token, act: Dictionary) -> void:
	var mode: String = str(act.get("mode", "probabilistic"))
	if mode == "condition":
		var conds = act.get("conditions", [])
		if conds is Array:
			for c in conds:
				if c is Dictionary and _eval_condition(c, token):
					_advance(token, c.get("goto", null))
					return
		_advance(token, act.get("else", null))
		return
	# probabilistic
	var branches = act.get("next", [])
	if branches is String:
		branches = [branches]
	if not (branches is Array) or (branches as Array).is_empty():
		return
	var weights = act.get("weights", [])
	var barr: Array = branches
	var total: float = 0.0
	for i in range(barr.size()):
		total += max(0.0, _weight_at(weights, i, barr.size()))
	var r: float = Rng.stream("pf:" + str(act.get("id", ""))).randf()
	if total <= 0.0:
		_advance(token, barr[0])
		return
	var x: float = r * total
	var acc: float = 0.0
	for i in range(barr.size()):
		acc += max(0.0, _weight_at(weights, i, barr.size()))
		if x < acc:
			_advance(token, barr[i])
			return
	# 端数の丸め等で外れた場合の決定的タイブレーク（最終ブランチ）。
	_advance(token, barr[barr.size() - 1])

func _weight_at(weights, i: int, n: int) -> float:
	# weights 未指定/不足なら等重み。
	if weights is Array and i < (weights as Array).size():
		return _num(weights[i])
	return 1.0

func _eval_condition(c: Dictionary, token: Token) -> bool:
	var lv = token.labels.get(str(c.get("label", "")), null)
	var rv = _eval_value(c.get("value", 0), token)
	match str(c.get("op", "==")):
		"==": return _equal(lv, rv)
		"!=": return not _equal(lv, rv)
		"<": return _num(lv) < _num(rv)
		"<=": return _num(lv) <= _num(rv)
		">": return _num(lv) > _num(rv)
		">=": return _num(lv) >= _num(rv)
	return false

# --- Batch / Unbatch ---
func _do_batch(token: Token, act: Dictionary) -> void:
	var buf: Array = act.get("_buffer", [])
	buf.append(token)
	act["_buffer"] = buf
	var n: int = max(1, int(act.get("size", act.get("n", 1))))
	if buf.size() >= n:
		var members: Array = buf
		act["_buffer"] = []
		var b := _new_token()   # 容器トークン：created には数えない（葉は members が保持）
		b._members = members
		b.labels["batch_count"] = members.size()
		# 容器の created_time は最古メンバに合わせる（表示・参照用。sink は葉ごとに計上）。
		var ct: float = INF
		for m in members:
			ct = min(ct, (m as Token).created_time)
		if ct == INF:
			ct = Sim.sim_time
		b.created_time = ct
		_advance(b, act.get("next", null))

func _do_unbatch(token: Token, act: Dictionary) -> void:
	var nid = act.get("next", null)
	if token._members.size() > 0:
		var members: Array = token._members
		token._members = []
		for m in members:
			_advance(m as Token, nid)   # 束の1段を葉/子トークンに戻す（決定的順）
	else:
		_advance(token, nid)

# --- Acquire / Release（FIFO・決定的） ---
func _do_acquire(token: Token, act: Dictionary) -> void:
	var pool: ResourcePool = _resources.get(str(act.get("resource", "")), null)
	if pool == null:
		push_error("ProcessFlow: 未知の資源 '%s'" % str(act.get("resource", "")))
		_advance(token, act.get("next", null))
		return
	if pool.in_use < pool.capacity:
		pool.acquire_now()
		_advance(token, act.get("next", null))
	else:
		token._acq_next = act.get("next", null)
		pool.queue.append(token)   # 容量待ち FIFO

func _do_release(token: Token, act: Dictionary) -> void:
	var pool: ResourcePool = _resources.get(str(act.get("resource", "")), null)
	if pool != null:
		pool.release_now()
		# 解放で空いた1枠は「最長待ち（FIFO 先頭）」へ先に与える（公平性・飢餓防止）。
		# 解放トークン自身の推進より先に行うことで、直後に同資源を再取得しても
		# 待ち行列を追い越さない。
		if pool.queue.size() > 0 and pool.in_use < pool.capacity:
			var head: Token = pool.queue.pop_front()
			pool.acquire_now()
			var nn = head._acq_next
			head._acq_next = null
			_advance(head, nn)
	_advance(token, act.get("next", null))

# --- Sink ---
func _do_sink(token: Token, act: Dictionary) -> void:
	# route 指定があれば、束縛 FlowItem を実オブジェクトへ手渡して所有権を移譲（dispose しない）。
	var route = act.get("route", null)
	if route != null and token.item != null:
		var obj = _resolve_bound(route)
		if obj != null and obj.has_method("receive_item"):
			# BUG1: 満杯なら item を落とさず空きを待って再試行（成功後に _sink_token）。
			# BUG3: 移譲成功時は _wip_transferred を立て、PF sink での二重 wip_dec を回避。
			_push_item_or_wait(token, obj, null, "sink")
			return
	_sink_token(token)

## 容器トークンは再帰的に葉まで分解して計上（保存則）。
func _sink_token(t: Token) -> void:
	if t._members.size() > 0:
		var members: Array = t._members
		t._members = []
		for m in members:
			_sink_token(m as Token)
	else:
		sunk += 1
		# BUG3: item の所有権を実3Dモデルへ移譲済み(_wip_transferred)なら、その物理実体の
		# wip 減算は移譲先（実 Sink 到達時に Sink.receive_item が実施 / 3D 内滞留なら未減算で
		# 正しく wip に残る）が担う。ここで減算すると同一実体を二重減算するため行わない。
		# 移譲していない通常トークン（_wip_transferred==false）は従来通り 1 減算する。
		if not t._wip_transferred:
			Sim.wip_dec()
		_cycle_sum += Sim.sim_time - t.created_time
		_cycle_n += 1
		# 束縛 FlowItem があれば dispose（wip はトークン計上で閉じているので触らない）。
		# 既存 spec は item を持たないため、この分岐はドーマント＝マーカー値バイト同一。
		if t.item != null:
			_dispose_item(t.item)
			t.item = null
			t.labels.erase("item")

# ---------------------------------------------------------------
# 小道具
# ---------------------------------------------------------------
func _num(v) -> float:
	if v is bool:
		return 1.0 if v else 0.0
	if v is int or v is float:
		return float(v)
	if v is String and (v as String).is_valid_float():
		return float(v)
	return 0.0

func _equal(a, b) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return float(a) == float(b)
	return a == b

# ===============================================================
# stage 2：実3Dモデル連携（オプトイン・既定ドーマント）
#   下記の公開 API / アクティビティを使わない限り一切呼ばれず、
#   既存の既定モデル・既存 PF マーカーの抽選順/結果に影響しない。
# ===============================================================

# ---------------------------------------------------------------
# 束縛 API
# ---------------------------------------------------------------
## PF の参照キー(アクティビティ id / 任意名) → 実オブジェクト/プールを束縛する。
##   map 値は Object 実体、または String（Sim.objects 内の FlowObject id）。
##   例: pf.bind_objects({"q1": queue_node, "ops": operator_pool, "probe": "sinkA"})
func bind_objects(map: Dictionary) -> void:
	for k in map:
		var v = map[k]
		if v is String:
			_bindings[str(k)] = _resolve_bound(v)
		else:
			_bindings[str(k)] = v

## 参照を実オブジェクトへ解決する。優先順: 束縛表 → Sim 内 FlowObject(id 一致) → 実体そのもの。
func _resolve_bound(ref):
	if ref == null:
		return null
	if _bindings.has(str(ref)):
		return _bindings[str(ref)]
	if ref is Object:
		return ref
	var o = Sim._find_object(str(ref))
	if o != null:
		return o
	return null

## 橋渡し状態を初期化（run/_reset_state ごと）。生きているシグナル接続はクリーン切断する。
## 束縛表(_bindings)は保持する（run を跨いで再利用できる）。
func _clear_bridge_state() -> void:
	for key in _waits.keys():
		_disconnect_wait(key)
	_waits.clear()
	for pkey in _push_waits.keys():
		_disconnect_push_wait(pkey)
	_push_waits.clear()
	# 共有プールへ登録した外部待機フックをクリーン解除してから資源表を破棄する
	# （run を跨いだ残留 Callable を残さない＝決定論の衛生）。
	for rk in _real_res.keys():
		_unregister_pool_waiter(_real_res[rk])
	_real_res.clear()
	_wait_capture_log.clear()
	_res_release_log.clear()
	_items_created = 0
	_items_disposed = 0

# ---------------------------------------------------------------
# wait_event：束縛オブジェクトの item_entered/exited を FIFO で待つ
# ---------------------------------------------------------------
func _do_wait_event(token: Token, act: Dictionary) -> void:
	var obj = _resolve_bound(act.get("object", act.get("target", "")))
	var which: String = str(act.get("signal", "entered"))
	var sig: String = "item_exited" if which == "exited" else "item_entered"
	if obj == null or not (obj is Object) or not obj.has_signal(sig):
		push_error("ProcessFlow: wait_event の対象が未束縛/シグナル無し")
		_advance(token, act.get("next", null))
		return
	var key: String = str(obj.get_instance_id()) + "|" + sig
	if not _waits.has(key):
		var cb := Callable(self, "_on_wait_event").bind(key)
		obj.connect(sig, cb)
		_waits[key] = {"obj": obj, "sig": sig, "cb": cb, "queue": []}
	(_waits[key]["queue"] as Array).append({"token": token, "next": act.get("next", null)})

## シグナルハンドラ。emit された item を FIFO 先頭トークンへ束縛して advance。
## bind した key は emit 引数の後に渡る（item, key）。行列が空になったら clean disconnect。
func _on_wait_event(item, key: String) -> void:
	var info = _waits.get(key, null)
	if info == null:
		return
	var q: Array = info["queue"]
	if q.is_empty():
		return   # 待ち手が無ければこの発火は無視（過剰発火に強い）
	var entry: Dictionary = q.pop_front()
	var token: Token = entry["token"]
	var nid = entry["next"]
	token.item = item
	token.labels["item"] = item
	_wait_capture_log.append([token.id, (item.id if item != null else -1)])
	# 行列が空になった時点で切断（advance が同オブジェクトへ再登録する場合は再接続される）。
	if q.is_empty():
		_disconnect_wait(key)
	_advance(token, nid)

func _disconnect_wait(key: String) -> void:
	var info = _waits.get(key, null)
	if info == null:
		return
	var obj = info["obj"]
	var sig: String = info["sig"]
	var cb: Callable = info["cb"]
	if obj != null and is_instance_valid(obj) and obj.is_connected(sig, cb):
		obj.disconnect(sig, cb)
	_waits.erase(key)

# ---------------------------------------------------------------
# acquire_resource / release_resource：実プール（Operator/Transport）
# ---------------------------------------------------------------
func _do_acquire_resource(token: Token, act: Dictionary) -> void:
	var key: String = str(act.get("pool", act.get("resource", "")))
	var rr = _real_res_get(key)
	if rr == null:
		push_error("ProcessFlow: acquire_resource 未束縛プール '%s'" % key)
		_advance(token, act.get("next", null))
		return
	var unit = _grab_unit(rr)
	if unit != null:
		_reserve_unit(rr, unit, token, key)
		_advance(token, act.get("next", null))
	else:
		(rr["waiters"] as Array).append({"token": token, "next": act.get("next", null)})
		# MIRROR: このプールを 3D 側と共有している場合、3D 解放(pool.release/_assign_next)が
		# PF 待機を起こせるよう外部待機フックを一度だけ登録する（未共有/未対応なら no-op）。
		_register_pool_waiter(rr, key)

func _do_release_resource(token: Token, act: Dictionary) -> void:
	var key: String = str(act.get("pool", act.get("resource", token._res_key)))
	var rr = _real_res_get(key)
	var unit = token._res
	if rr != null and unit != null:
		_free_unit(rr, unit)
		token._res = null
		token._res_key = ""
		token.labels.erase("resource")
		_res_release_log.append(token.id)
		# 解放で空いた枠は「最長待ち（行列先頭）」へ先に与える（追い越し無し）。
		# 解放トークン自身の advance より先に行うことで、直後の再取得でも行列を追い越さない。
		var q: Array = rr["waiters"]
		if q.size() > 0:
			var nu = _grab_unit(rr)
			if nu != null:
				var entry: Dictionary = q.pop_front()
				var htok: Token = entry["token"]
				_reserve_unit(rr, nu, htok, key)
				_advance(htok, entry["next"])
		# 待ち行列が空になったら外部待機フックを解除（ドーマントへ戻す）。
		if q.is_empty():
			_unregister_pool_waiter(rr)
		# BUG2: PF 待ち行列を先に捌いた後、この unit をまだ PF が握り直していない（＝空き）なら、
		# 共有プールの「3D 側」待ち行列（OperatorPool/TransportPool._waiting）を起こす。
		# PF 内待機を優先し、その後 3D 側という固定順で決定的。unit を再確保済みなら二重配車を
		# 防ぐため何もしない。PF 専用プール（_waiting 空）では no-op でマーカー値バイト同一。
		var pool = rr["pool"]
		if unit.available and pool != null and pool.has_method("_assign_next"):
			pool._assign_next(unit)
	_advance(token, act.get("next", null))

# ---------------------------------------------------------------
# MIRROR wakeup（3D 側解放 → PF 待機の起床）
#   PF が rr["waiters"] にトークンを積むと共有プールへ外部待機フックを登録する。
#   3D 側の pool.release()/_assign_next() が 3D 内部行列(_waiting)を捌き切っても
#   ユニットが余った時に本フックが呼ばれ、PF は FIFO 先頭（最長待ち）へ 1 枠を与える。
#   固定優先度: プールの 3D 待機が先、その後 PF FIFO（追い越し無し・決定的）。
#   フックは乱数を引かず、外部待機者が居なければ何もしない（既存マーカーはバイト同一）。
# ---------------------------------------------------------------

## PF 待機を共有プールへ一度だけ登録（rr["ext_registered"] で重複防止）。
## プールが register_external_waiter を持たない（PF 専用プール等）なら no-op＝ドーマント。
func _register_pool_waiter(rr: Dictionary, key: String) -> void:
	if rr.get("ext_registered", false):
		return
	var pool = rr["pool"]
	if pool != null and is_instance_valid(pool) and pool.has_method("register_external_waiter"):
		var cb := Callable(self, "_on_pool_unit_freed").bind(key)
		pool.register_external_waiter(cb)
		rr["ext_cb"] = cb
		rr["ext_registered"] = true

## 外部待機フックを解除（待ち行列が空になった時／橋渡し状態クリア時）。
func _unregister_pool_waiter(rr: Dictionary) -> void:
	if not rr.get("ext_registered", false):
		return
	var pool = rr["pool"]
	var cb = rr.get("ext_cb", null)
	if pool != null and is_instance_valid(pool) and cb != null \
			and pool.has_method("unregister_external_waiter"):
		pool.unregister_external_waiter(cb)
	rr["ext_registered"] = false
	rr["ext_cb"] = null

## 共有プールが 3D 内部行列を捌いた後に空き枠を通知してくる（MIRROR wakeup）。
## FIFO 先頭トークンへ空きユニットを 1 つ与えて前進させる（追い越し無し）。
## 二重配車防止: _grab_unit は available のみ返し、_reserve_unit で available=false にする。
## プールは空きユニット 1 個ごとに 1 回通知するので、ここでは 1 枠だけ捌けば足りる
## （PF 解放側 _do_release_resource と対称）。行列が空になったらフックを解除する。
func _on_pool_unit_freed(key: String) -> void:
	var rr = _real_res.get(key, null)
	if rr == null:
		return
	var q: Array = rr["waiters"]
	if q.size() > 0:
		var unit = _grab_unit(rr)
		if unit != null:
			var entry: Dictionary = q.pop_front()
			var htok: Token = entry["token"]
			_reserve_unit(rr, unit, htok, key)
			_advance(htok, entry["next"])
	if (rr["waiters"] as Array).is_empty():
		_unregister_pool_waiter(rr)

## プールキー→実資源管理レコードを取得（初回に遅延生成）。プール以外を束縛していたら null。
func _real_res_get(key: String):
	if _real_res.has(key):
		return _real_res[key]
	var obj = _resolve_bound(key)
	var kind: String = ""
	if obj is OperatorPool:
		kind = "operator"
	elif obj is TransportPool:
		kind = "transporter"
	else:
		return null
	var rr: Dictionary = {"pool": obj, "kind": kind, "waiters": [],
		"dispatched": 0, "released": 0, "held": []}
	_real_res[key] = rr
	return rr

## 空き実資源を1つ返す（登録順の先着＝決定的）。作業者はシフト稼働中のみ対象。無ければ null。
func _grab_unit(rr: Dictionary):
	var pool = rr["pool"]
	if rr["kind"] == "operator":
		for op in pool.operators:
			if op.available and op.on_shift(Sim.sim_time):
				return op
	else:
		for t in pool.transporters:
			if t.available:
				return t
	return null

func _reserve_unit(rr: Dictionary, unit, token: Token, key: String) -> void:
	unit.available = false
	if rr["kind"] == "operator":
		unit.start_working()   # 稼働計上（乱数・イベントに触れない）
	rr["dispatched"] = int(rr["dispatched"]) + 1
	(rr["held"] as Array).append(unit)
	token._res = unit
	token._res_key = key
	token.labels["resource"] = unit

func _free_unit(rr: Dictionary, unit) -> void:
	if rr["kind"] == "operator":
		unit.stop_working()
		unit.set_idle()
	unit.available = true
	rr["released"] = int(rr["released"]) + 1
	(rr["held"] as Array).erase(unit)

## 実プールの均衡（dispatched==released かつ held 空）を検査（no-leak 検証用）。
func real_res_balanced(key: String) -> bool:
	var rr = _real_res.get(key, null)
	if rr == null:
		return true
	return int(rr["dispatched"]) == int(rr["released"]) and (rr["held"] as Array).is_empty()

func real_res_stats(key: String) -> Dictionary:
	var rr = _real_res.get(key, null)
	if rr == null:
		return {"dispatched": 0, "released": 0, "outstanding": 0, "waiting": 0}
	return {
		"dispatched": int(rr["dispatched"]),
		"released": int(rr["released"]),
		"outstanding": (rr["held"] as Array).size(),
		"waiting": (rr["waiters"] as Array).size(),
	}

# ---------------------------------------------------------------
# Token<->FlowItem 束縛ヘルパ
# ---------------------------------------------------------------
## トークン用に FlowItem を生成し束縛する（Sim.wip は増やさない：wip はトークン単位）。
func pf_create_item(token: Token, item_type: int = 0) -> FlowItem:
	var it := FlowItem.new()
	it.setup(item_type, Color(0.6, 0.7, 0.9), Sim.visuals_enabled)
	it.id = Sim.next_item_id()
	it.created_time = Sim.sim_time
	token.item = it
	token.labels["item"] = it
	_items_created += 1
	return it

## wait_event 等で捕捉した既存 FlowItem をトークンへ採用（束縛）する。
func pf_adopt_item(token: Token, it) -> void:
	token.item = it
	token.labels["item"] = it

func _do_create_item(token: Token, act: Dictionary) -> void:
	pf_create_item(token, int(act.get("item_type", 0)))
	_advance(token, act.get("next", null))

func _do_push_object(token: Token, act: Dictionary) -> void:
	var obj = _resolve_bound(act.get("object", act.get("target", "")))
	if obj != null and obj.has_method("receive_item") and token.item != null:
		# BUG1: 満杯なら item を落とさず空きを待って再試行（成功後に next へ）。
		# BUG3: 移譲成功時は _wip_transferred を立て、PF sink での二重 wip_dec を回避。
		_push_item_or_wait(token, obj, act.get("next", null), "push")
	else:
		_advance(token, act.get("next", null))

## token.item を obj へ receive_item で渡す（所有権移譲）。
##   成功: _wip_transferred を立て item 束縛を解除。mode=="sink" なら _sink_token、それ以外は next へ。
##   満杯(false): item を落とさず obj.item_exited を FIFO で待ち、空きが出た時点で再試行する
##     （バックプレッシャー：1 出庫＝1 入庫）。乱数・イベント予約は一切行わない。
func _push_item_or_wait(token: Token, obj, next_id, mode: String) -> void:
	if obj.receive_item(token.item):
		_on_transfer_ok(token, next_id, mode)
		return
	# --- 満杯：バックプレッシャー待ち ---
	if not (obj is Object) or not obj.has_signal("item_exited"):
		# 空き通知機構が無い対象：最低限アイテムを失わない（保持したままブロック＝エラー通知）。
		push_error("ProcessFlow: push 先が満杯で item_exited が無い。item を保持しブロックします。")
		return
	var key: String = str(obj.get_instance_id())
	if not _push_waits.has(key):
		var cb := Callable(self, "_on_push_space").bind(key)
		obj.connect("item_exited", cb)
		_push_waits[key] = {"obj": obj, "cb": cb, "queue": []}
	(_push_waits[key]["queue"] as Array).append({"token": token, "next": next_id, "mode": mode})

## 移譲成功時の共通処理（wip 移譲フラグ・item 束縛解除・後続推進）。
func _on_transfer_ok(token: Token, next_id, mode: String) -> void:
	token._wip_transferred = true
	token.item = null
	token.labels.erase("item")
	if mode == "sink":
		_sink_token(token)
	else:
		_advance(token, next_id)

## obj が下流へ 1 件送出（item_exited）＝空きが 1 枠出た。FIFO 先頭の待機トークンを 1 件だけ再試行。
## bind した key は emit 引数(item)の後に渡る（item, key）。行列が空になったら clean disconnect。
func _on_push_space(_item, key: String) -> void:
	var info = _push_waits.get(key, null)
	if info == null:
		return
	var q: Array = info["queue"]
	if q.is_empty():
		return
	var obj = info["obj"]
	if obj == null or not is_instance_valid(obj) or not obj.has_method("receive_item"):
		_disconnect_push_wait(key)
		return
	# 先頭を pop してから再試行（receive_item の同期連鎖で本ハンドラへ再入しても、取り出し済みの
	# 先頭は行列に無いため二重注入しない）。失敗（別経路が枠を奪取）なら先頭へ戻して次の空きを待つ。
	var entry: Dictionary = q.pop_front()
	var token: Token = entry["token"]
	if obj.receive_item(token.item):
		if q.is_empty():
			_disconnect_push_wait(key)
		_on_transfer_ok(token, entry.get("next", null), str(entry.get("mode", "push")))
	else:
		q.push_front(entry)

func _disconnect_push_wait(key: String) -> void:
	var info = _push_waits.get(key, null)
	if info == null:
		return
	var obj = info["obj"]
	var cb: Callable = info["cb"]
	if obj != null and is_instance_valid(obj) and obj.is_connected("item_exited", cb):
		obj.disconnect("item_exited", cb)
	_push_waits.erase(key)

func _dispose_item(it) -> void:
	if it != null and it.has_method("dispose"):
		it.dispose()
	_items_disposed += 1

# ===============================================================
# タスクシーケンス（確保した REAL 資源を物理移動させ、item を積載/投下）
#   前提: トークンは既に acquire_resource で REAL 資源（Operator/Transporter）を
#   token._res に握っている。未確保なら push_error して素通り（next へ）。
#   これらは【travel/load/unload】で構成され、logistics 例:
#     acquire_resource(T) → travel(to pickup) → load → travel(to dropoff)
#       → unload(to 実 Queue/Sink) → release_resource
#   Transporter 経路は _travel_to を用いるため、有限容量辺ネットワーク上では
#   AGV 同士の輻輳（辺容量待ち）と自動的に合成される。
# ---------------------------------------------------------------

## travel: 確保ユニット token._res を目的地へ物理移動し、到着までトークンをブロック→next。
##   目的地 "to" の解決:
##     Array [x,z]           → Vector3(x, 0, z)
##     Vector3               → そのまま
##     文字列キー            → 束縛オブジェクトの位置（transport_pickup_pos/global_position）
##       束縛が無ければ token.labels[キー] の座標（Vector3 or [x,z]）＝"pickup"/"dropoff" 等
##   Transporter は unit._travel_to(pos, state, on_arrive) を使い、輻輳（辺容量待ち）を自動包含。
##     state は spec "state" 指定、無指定なら token.item を積んでいれば "carrying" 否なら "to_pickup"。
##   Operator は t=travel_time(pos)（go_to 前に算出）→ go_to(pos) → Sim.schedule(t, advance)。
##   乱数は引かない（移動時間は距離/ネットワークで決定的）。
func _do_travel(token: Token, act: Dictionary) -> void:
	var nid = act.get("next", null)
	var unit = token._res
	if unit == null:
		push_error("ProcessFlow: travel はユニット未確保のトークンには使えない（先に acquire_resource）")
		_advance(token, nid)
		return
	var target = _resolve_travel_target(act.get("to", act.get("target", null)), token)
	if target == null:
		push_error("ProcessFlow: travel の目的地 '%s' を解決できない" % str(act.get("to", act.get("target", null))))
		_advance(token, nid)
		return
	if unit is Transporter:
		# 輻輳を含む区間逐次走行。on_arrive がトークンを next へ（二重スケジュールしない）。
		var st: String = str(act.get("state", "carrying" if token.item != null else "to_pickup"))
		(unit as Transporter)._travel_to(target, st, func() -> void: _advance(token, nid))
	else:
		# Operator（非輻輳）: travel_time は go_to より前に、更新前 logical_pos で算出する。
		var t: float = unit.travel_time(target)
		unit.go_to(target)
		Sim.schedule(t, func() -> void: _advance(token, nid))

## load: token.item をユニットへ積載する dwell（時間消費のみ）→ next。
##   time が数値/{"type":"const"} なら乱数を引かない定数、確率分布なら pf:+id から1回抽選。
##   token.item が null でも有効な dwell（純粋な滞留時間）。
func _do_load(token: Token, act: Dictionary) -> void:
	var d: float = _dwell_sample(act)
	var nid = act.get("next", null)
	Sim.schedule(d, func() -> void: _advance(token, nid))

## unload: 投下 dwell を消費し、"to" があれば token.item を実オブジェクトへ引き渡す→ next。
##   引き渡しは _push_item_or_wait（バックプレッシャー安全）で行い、item を落とさない。
##   満杯なら item_exited を FIFO で待ち、空きが出た時点で受け渡す（1出庫=1入庫）。成功時は
##   push_object と同様に _wip_transferred を立て、token.item 束縛を解除する。
##   "to" 無指定なら item はトークンに留めたまま dwell 後 next（後段で push_object/sink 可能）。
##   time の抽選規則は load と同一。
func _do_unload(token: Token, act: Dictionary) -> void:
	var d: float = _dwell_sample(act)
	var nid = act.get("next", null)
	var to = act.get("to", null)
	Sim.schedule(d, func() -> void: _finish_unload(token, to, nid))

## unload dwell 完了後の投下処理。"to" が実オブジェクト(receive_item 有)かつ item 有りなら
## バックプレッシャー安全に引き渡す。それ以外は素通り（item 保持のまま next）。
func _finish_unload(token: Token, to, nid) -> void:
	if to != null and token.item != null:
		var obj = _resolve_bound(to)
		if obj != null and obj.has_method("receive_item"):
			_push_item_or_wait(token, obj, nid, "push")
			return
	_advance(token, nid)

## load/unload の時間抽選。数値/{"type":"const"} は乱数を引かない定数、確率分布のみ
## Dist.sample(pf:+id) で1回抽選（const は Dist.sample 内でも無抽選）。非負クランプ。
func _dwell_sample(act: Dictionary) -> float:
	var tv = act.get("time", act.get("duration", 0.0))
	if tv is Dictionary:
		return Dist.sample(tv, Rng.stream("pf:" + str(act.get("id", ""))))
	return max(0.0, _num(tv))

## travel の目的地座標を解決する（乱数なし）。
##   Array[>=2] → Vector3(a0,0,a1) / Vector3 → そのまま / 文字列 → 束縛オブジェクト位置、
##   無ければ token.labels[キー] の座標（Vector3 または [x,z]）。解決不能なら null。
func _resolve_travel_target(ref, token: Token):
	if ref == null:
		return null
	if ref is Vector3:
		return ref
	if ref is Array:
		var arr: Array = ref
		if arr.size() >= 2:
			return Vector3(_num(arr[0]), 0.0, _num(arr[1]))
		return null
	var key: String = str(ref)
	# 束縛オブジェクト（Sim 内 FlowObject 含む）が最優先。
	var obj = _resolve_bound(key)
	if obj != null and not (obj is ResourcePool):
		return _object_position(obj)
	# 束縛が無ければトークンのラベル座標（"pickup"/"dropoff" 等）。
	if token.labels.has(key):
		var lv = token.labels[key]
		if lv is Vector3:
			return lv
		if lv is Array and (lv as Array).size() >= 2:
			return Vector3(_num(lv[0]), 0.0, _num(lv[1]))
	return null

## 実オブジェクトの移動目標座標。FlowObject は transport_pickup_pos()、Node3D は global_position、
## logical_pos を持つもの（Operator/Transporter）はそれを使う。
func _object_position(obj) -> Vector3:
	if obj == null:
		return Vector3.ZERO
	if obj.has_method("transport_pickup_pos"):
		return obj.transport_pickup_pos()
	if obj is Node3D:
		return (obj as Node3D).global_position
	if obj is Object and "logical_pos" in obj:
		return obj.logical_pos
	return Vector3.ZERO

# ---------------------------------------------------------------
# 分離実行（stage 1 の Sim.sources_enabled を掛けて PF だけを走らせる）
# ---------------------------------------------------------------
## 既定モデルの Source 自走を止めてから run() し、直後に元の状態へ復元する。
## 分離中は Sim.wip を触るのが PF のトークン生成/消滅のみになるため、
## 実行後に Sim.wip == kpi.in_flight が厳密成立する（従来は既定モデル並走で不可能）。
func run_isolated(run_len: float, run_seed: int = -1) -> Dictionary:
	var prev: bool = Sim.sources_enabled
	Sim.set_sources_enabled(false)
	var k: Dictionary = run(run_len, run_seed)
	Sim.set_sources_enabled(prev)
	return k

## item 保存則の検査（生成==破棄+（in-flight トークンが保持中）+（route で手放した数））。
## 完全ドレインかつ route 未使用なら _items_created == _items_disposed。
func item_stats() -> Dictionary:
	return {"created": _items_created, "disposed": _items_disposed}

# ===============================================================
# lint：spec の静的検証（純粋・副作用なし・rng/スケジュール/イベント一切なし）
#   実行時 push_error に頼らず、呼び出し側が「実行前に」実行可能な診断を得るための
#   純粋な静的解析。これは新規の static API であり、既存の実行経路（build/run/kpi/…）
#   からは一切呼ばれない＝完全ドーマント。従って 81 マーカーはバイト同一のまま。
#
#   使い方: var diags := ProcessFlow.lint(spec) もしくは ProcessFlow.lint(spec, bindings)
#     bindings は bind_objects に渡すのと同じ参照キー表（値は不問。lint はキーの有無しか見ない）。
#   返り値: 診断 Array。各要素は {severity:"error"|"warning", code, activity_id, message}。
#     clean な spec は空配列 [] を返す。spec/bindings は一切変更しない（read-only）。
#
#   実装する診断コード（本 static 群は乱数もスケジュールも触らない＝純粋）:
#     error   unknown_next          next/goto/else 参照先が存在しないアクティビティ id
#     error   unknown_type          未知のアクティビティ種別
#     error   unknown_resource      acquire/release の計数資源が resources に未宣言
#     error   unbound_pool          acquire_resource/release_resource の実プールが未束縛
#     error   unbound_object        wait_event/push_object の対象、unload の to が未束縛
#     error   unbound_travel_target travel の to が座標でも束縛でもラベルでもない
#     error   zero_arrival_interval source の到着間隔が常に 0 以下で無制限（同時刻無限ループ）
#     error   spin_cycle            時間消費もバリアも無い同期閉路（イベントカレンダー空転）
#     warning zero_arrival_interval  同上だが max_arrivals 有限（同時刻有限）
#     warning unreachable_activity  どの source からも到達不能
#     warning missing_sink          source のグラフが sink に到達しない
#     warning decide_empty_branches decide の分岐（next/conditions/else）が空
#     warning decide_weights        decide 重みが不整合（数不一致/負値/合計0以下）
#     warning duplicate_id          アクティビティ id 重複（後勝ちで上書き）
#     warning no_source             source が1つも無い（トークンが生成されない）
# ===============================================================

## 時間を消費する（未来イベントを予約して同期連鎖を断ち切る）種別。
const LINT_TIME_TYPES: Dictionary = {
	"delay": true, "travel": true, "load": true, "unload": true, "process": true,
}
## PF が解釈できるアクティビティ種別（"process" は将来の時間消費種別として受理）。
const LINT_KNOWN_TYPES: Dictionary = {
	"source": true, "delay": true, "assign": true, "decide": true, "batch": true,
	"unbatch": true, "acquire": true, "release": true, "wait_event": true,
	"acquire_resource": true, "release_resource": true, "create_item": true,
	"push_object": true, "travel": true, "load": true, "unload": true,
	"sink": true, "process": true,
}

static func lint(spec: Dictionary, bindings: Dictionary = {}) -> Array:
	var diags: Array = []

	# --- activities を順序付きで抽出（build の Array 形式に加え Dictionary 形式にも耐える） ---
	var order: Array = []
	var acts: Dictionary = {}
	var raw_acts = spec.get("activities", [])
	if raw_acts is Array:
		for a in raw_acts:
			if not (a is Dictionary):
				continue
			var aid: String = str((a as Dictionary).get("id", ""))
			if aid == "":
				continue
			if acts.has(aid):
				diags.append(_lint_diag("warning", "duplicate_id", aid,
					"アクティビティ id '%s' が重複（後勝ちで上書きされる）" % aid))
			else:
				order.append(aid)
			acts[aid] = a
	elif raw_acts is Dictionary:
		for k in raw_acts:
			var a = raw_acts[k]
			if not (a is Dictionary):
				continue
			var aid: String = str((a as Dictionary).get("id", k))
			if aid == "":
				aid = str(k)
			if acts.has(aid):
				diags.append(_lint_diag("warning", "duplicate_id", aid,
					"アクティビティ id '%s' が重複" % aid))
			else:
				order.append(aid)
			acts[aid] = a

	# --- resources（計数資源）の宣言集合 ---
	var res_ids: Dictionary = {}
	var raw_res = spec.get("resources", {})
	if raw_res is Dictionary:
		for rid in raw_res:
			res_ids[str(rid)] = true

	# --- assign が書き込むラベル名を収集（travel の to がラベル座標の場合の誤検出回避用） ---
	var known_labels: Dictionary = {"item": true, "resource": true}
	for aid in order:
		var a: Dictionary = acts[aid]
		if str(a.get("type", "")) == "assign":
			var asg = a.get("assignments", {})
			if asg is Dictionary:
				for lk in asg:
					known_labels[str(lk)] = true

	# --- アクティビティ単位の検査（挿入順で決定的） ---
	for aid in order:
		var a: Dictionary = acts[aid]
		var t: String = str(a.get("type", ""))
		if not LINT_KNOWN_TYPES.has(t):
			diags.append(_lint_diag("error", "unknown_type", aid,
				"未知のアクティビティ種別 '%s'" % t))
		# next 参照（unknown_next）: 種別が不明でも参照だけは検査する。
		for ref in _lint_targets(a):
			if ref == "":
				continue
			if not acts.has(ref):
				diags.append(_lint_diag("error", "unknown_next", aid,
					"next 参照先 '%s' が存在しない" % ref))
		# 種別ごとの束縛/資源/構造検査
		match t:
			"acquire", "release":
				var res_key: String = str(a.get("resource", ""))
				if res_key == "":
					diags.append(_lint_diag("error", "unknown_resource", aid,
						"%s に resource 指定が無い" % t))
				elif not res_ids.has(res_key):
					diags.append(_lint_diag("error", "unknown_resource", aid,
						"計数資源 '%s' が resources に未宣言" % res_key))
			"acquire_resource":
				var pool_key: String = str(a.get("pool", a.get("resource", "")))
				if pool_key == "":
					diags.append(_lint_diag("error", "unbound_pool", aid,
						"acquire_resource に pool 指定が無い"))
				elif not _lint_is_bound(pool_key, bindings, acts):
					diags.append(_lint_diag("error", "unbound_pool", aid,
						"実プール '%s' が未束縛（bindings にもアクティビティにも無い）" % pool_key))
			"release_resource":
				# pool は省略可（token._res_key を使う）。明示された時のみ検査。
				var pool_key2 = a.get("pool", a.get("resource", null))
				if pool_key2 != null and str(pool_key2) != "" \
						and not _lint_is_bound(str(pool_key2), bindings, acts):
					diags.append(_lint_diag("error", "unbound_pool", aid,
						"実プール '%s' が未束縛" % str(pool_key2)))
			"wait_event":
				var wobj: String = str(a.get("object", a.get("target", "")))
				if wobj == "":
					diags.append(_lint_diag("error", "unbound_object", aid,
						"wait_event に object 指定が無い"))
				elif not _lint_is_bound(wobj, bindings, acts):
					diags.append(_lint_diag("error", "unbound_object", aid,
						"対象オブジェクト '%s' が未束縛" % wobj))
			"push_object":
				var pobj: String = str(a.get("object", a.get("target", "")))
				if pobj == "":
					diags.append(_lint_diag("error", "unbound_object", aid,
						"push_object に object 指定が無い"))
				elif not _lint_is_bound(pobj, bindings, acts):
					diags.append(_lint_diag("error", "unbound_object", aid,
						"対象オブジェクト '%s' が未束縛" % pobj))
			"unload":
				var unl_to = a.get("to", null)
				if unl_to != null and (unl_to is String) and str(unl_to) != "" \
						and not _lint_is_bound(str(unl_to), bindings, acts):
					diags.append(_lint_diag("error", "unbound_object", aid,
						"unload の受け渡し先 '%s' が未束縛" % str(unl_to)))
			"travel":
				_lint_check_travel(a, aid, bindings, acts, known_labels, diags)
			"decide":
				_lint_check_decide(a, aid, diags)
			"source":
				_lint_check_source(a, aid, diags)
			_:
				pass

	# --- 到達可能性 / sink 到達（source が根） ---
	var sources: Array = []
	for aid in order:
		if str(acts[aid].get("type", "")) == "source":
			sources.append(aid)
	if sources.is_empty():
		if not order.is_empty():
			diags.append(_lint_diag("warning", "no_source", "",
				"source アクティビティが1つも無い（トークンが生成されない）"))
	else:
		var reach_all: Dictionary = _lint_reach(sources, acts)
		for aid in order:
			if reach_all.has(aid):
				continue
			if str(acts[aid].get("type", "")) == "source":
				continue   # source は根なので必ず可達扱い（自明）
			diags.append(_lint_diag("warning", "unreachable_activity", aid,
				"どの source からも到達不能"))
		for s in sources:
			var r: Dictionary = _lint_reach([s], acts)
			var has_sink: bool = false
			for rid in r:
				if str(acts[rid].get("type", "")) == "sink":
					has_sink = true
					break
			if not has_sink:
				diags.append(_lint_diag("warning", "missing_sink", s,
					"source '%s' のグラフが sink に到達しない" % s))

	# --- spin cycle（時間消費もバリアも無い同期閉路＝イベントカレンダー空転） ---
	for cyc in _lint_spin_cycles(order, acts):
		var rep: String = str(cyc[0])
		var best: int = 1 << 30
		for m in cyc:
			var idx: int = order.find(m)
			if idx >= 0 and idx < best:
				best = idx
				rep = str(m)
		diags.append(_lint_diag("error", "spin_cycle", rep,
			"時間消費アクティビティを含まない閉路（イベントカレンダーが空転する）: %s"
				% _lint_join(cyc, " -> ")))

	return diags

# ---------------------------------------------------------------
# lint ヘルパ（すべて static・純粋。spec/bindings を変更しない）
# ---------------------------------------------------------------
static func _lint_diag(sev: String, code: String, aid: String, msg: String) -> Dictionary:
	return {"severity": sev, "code": code, "activity_id": aid, "message": msg}

## アクティビティの後続参照（next/goto/else）を String 配列で返す。実行時 _dispatch と同じ
## 経路選択に従う（sink は後続なし。condition decide は conditions.goto + else）。
static func _lint_targets(act: Dictionary) -> Array:
	var out: Array = []
	var t: String = str(act.get("type", ""))
	if t == "sink":
		return out
	if t == "decide" and str(act.get("mode", "probabilistic")) == "condition":
		var conds = act.get("conditions", [])
		if conds is Array:
			for c in conds:
				if c is Dictionary and c.get("goto", null) != null:
					_lint_append_ref(out, c.get("goto"))
		if act.get("else", null) != null:
			_lint_append_ref(out, act.get("else"))
		return out
	_lint_append_ref(out, act.get("next", null))
	return out

static func _lint_append_ref(out: Array, ref) -> void:
	if ref == null:
		return
	if ref is Array:
		for r in ref:
			if r != null:
				out.append(str(r))
	else:
		out.append(str(ref))

## 参照キーが束縛済みか。bindings 表にあるか、または同名アクティビティが存在すれば真。
static func _lint_is_bound(key: String, bindings: Dictionary, acts: Dictionary) -> bool:
	if bindings.has(key):
		return true
	if acts.has(key):
		return true
	return false

static func _lint_check_travel(a: Dictionary, aid: String, bindings: Dictionary,
		acts: Dictionary, known_labels: Dictionary, diags: Array) -> void:
	var to = a.get("to", a.get("target", null))
	if to == null:
		diags.append(_lint_diag("error", "unbound_travel_target", aid,
			"travel に目的地(to)が無い"))
		return
	if to is Array or to is Vector3:
		return   # 座標指定は常に有効
	var key: String = str(to)
	if key == "":
		diags.append(_lint_diag("error", "unbound_travel_target", aid,
			"travel の目的地(to)が空"))
		return
	if _lint_is_bound(key, bindings, acts):
		return
	if known_labels.has(key):
		return   # assign 等が書き込むラベル座標（実行時に解決される）
	diags.append(_lint_diag("error", "unbound_travel_target", aid,
		"travel の目的地 '%s' が未束縛かつラベル未定義" % key))

static func _lint_check_decide(a: Dictionary, aid: String, diags: Array) -> void:
	var mode: String = str(a.get("mode", "probabilistic"))
	if mode == "condition":
		var conds = a.get("conditions", [])
		var has_cond: bool = conds is Array and not (conds as Array).is_empty()
		var has_else: bool = a.get("else", null) != null
		if not has_cond and not has_else:
			diags.append(_lint_diag("warning", "decide_empty_branches", aid,
				"condition decide に conditions も else も無い（トークンが行き場を失う）"))
		return
	# probabilistic
	var branches: Array = []
	_lint_append_ref(branches, a.get("next", null))
	if branches.is_empty():
		diags.append(_lint_diag("warning", "decide_empty_branches", aid,
			"probabilistic decide の分岐(next)が空"))
		return
	var weights = a.get("weights", null)
	if weights is Array:
		var warr: Array = weights
		var issues: Array = []
		if warr.size() != branches.size():
			issues.append("weights 数(%d)が分岐数(%d)と不一致" % [warr.size(), branches.size()])
		var total: float = 0.0
		var has_neg: bool = false
		for w in warr:
			var wv: float = _lint_numf(w, 0.0)
			if wv < 0.0:
				has_neg = true
			total += max(0.0, wv)
		if has_neg:
			issues.append("負の重みがある")
		if total <= 0.0:
			issues.append("重みの合計が 0 以下（先頭分岐へ縮退する）")
		if not issues.is_empty():
			diags.append(_lint_diag("warning", "decide_weights", aid,
				"decide 重みの問題: " + _lint_join(issues, "; ")))

static func _lint_check_source(a: Dictionary, aid: String, diags: Array) -> void:
	if not a.has("interarrival"):
		return   # 既定 exp（有効）
	if not _lint_dist_nonpositive(a.get("interarrival")):
		return
	var mx: int = int(a.get("max_arrivals", -1))
	if mx < 0:
		diags.append(_lint_diag("error", "zero_arrival_interval", aid,
			"source の到着間隔が常に 0 以下で max_arrivals 無制限（同時刻無限ループになる）"))
	else:
		diags.append(_lint_diag("warning", "zero_arrival_interval", aid,
			"source の到着間隔が常に 0 以下（全到着が同時刻。max_arrivals=%d なので有限）" % mx))

## 分布 spec が「常に 0 以下」を返すか（Dist.sample の非負クランプ/退化パラメタ挙動に基づく）。
static func _lint_dist_nonpositive(spec) -> bool:
	if spec is int or spec is float:
		return float(spec) <= 0.0
	if not (spec is Dictionary):
		return false
	var d: Dictionary = spec
	match str(d.get("type", "const")):
		"const":
			return _lint_numf(d.get("a"), 1.0) <= 0.0
		"exp":
			return _lint_numf(d.get("a"), 1.0) <= 0.0
		"uniform":
			return _lint_numf(d.get("a"), 0.0) <= 0.0 and _lint_numf(d.get("b"), 1.0) <= 0.0
		"normal":
			return _lint_numf(d.get("a"), 1.0) <= 0.0 and _lint_numf(d.get("b"), 0.1) <= 0.0
		"triangular":
			return _lint_numf(d.get("c"), 2.0) <= 0.0
		"lognormal":
			return _lint_numf(d.get("a"), 1.0) <= 0.0
		"weibull":
			return _lint_numf(d.get("a"), 1.0) <= 0.0 or _lint_numf(d.get("b"), 1.0) <= 0.0
		"gamma":
			return _lint_numf(d.get("a"), 1.0) <= 0.0 or _lint_numf(d.get("b"), 1.0) <= 0.0
		"empirical", "empirical_cont":
			var vals = d.get("a", [])
			if not (vals is Array) or (vals as Array).is_empty():
				return true   # 空 → sample は 0 を返す
			var mx: float = -INF
			for v in vals:
				mx = max(mx, _lint_numf(v, 0.0))
			return mx <= 0.0
		_:
			return _lint_numf(d.get("a"), 1.0) <= 0.0

static func _lint_numf(v, def: float) -> float:
	if v is bool:
		return 1.0 if v else 0.0
	if v is int or v is float:
		return float(v)
	if v is String and (v as String).is_valid_float():
		return float(v)
	return def

## roots から next 辺を辿って到達できるアクティビティ id 集合を返す（純粋・反復 DFS）。
static func _lint_reach(roots: Array, acts: Dictionary) -> Dictionary:
	var seen: Dictionary = {}
	var stack: Array = []
	for r in roots:
		var rk: String = str(r)
		if acts.has(rk) and not seen.has(rk):
			seen[rk] = true
			stack.append(rk)
	while not stack.is_empty():
		var u = stack.pop_back()
		for ref in _lint_targets(acts[u]):
			if ref != "" and acts.has(ref) and not seen.has(ref):
				seen[ref] = true
				stack.append(ref)
	return seen

## 時間消費もバリアも無い「同期ノード」だけの部分グラフを作り、その中の閉路を返す。
## 閉路が在れば、その閉路のトークン遷移は同時刻で無限連鎖しうる＝空転リスク。
## バリア（wait_event / size>=2 の batch）は単一トークンを同期前進させないので閉路を断つ。
static func _lint_spin_cycles(order: Array, acts: Dictionary) -> Array:
	var sync: Dictionary = {}
	for aid in order:
		var a: Dictionary = acts[aid]
		var t: String = str(a.get("type", ""))
		if LINT_TIME_TYPES.has(t):
			continue
		if _lint_is_barrier(a):
			continue
		sync[aid] = true
	var adj: Dictionary = {}
	for aid in sync:
		var outs: Array = []
		for ref in _lint_targets(acts[aid]):
			if sync.has(ref):
				outs.append(ref)
		adj[aid] = outs
	var state: Dictionary = {"color": {}, "stack": [], "cycles": [], "seen": {}}
	for aid in sync:
		if int((state["color"] as Dictionary).get(aid, 0)) == 0:
			_lint_dfs_cycle(aid, adj, state)
	return state["cycles"]

static func _lint_dfs_cycle(u, adj: Dictionary, state: Dictionary) -> void:
	(state["color"] as Dictionary)[u] = 1        # gray（再帰スタック上）
	(state["stack"] as Array).append(u)
	for w in adj.get(u, []):
		var c: int = int((state["color"] as Dictionary).get(w, 0))
		if c == 0:
			_lint_dfs_cycle(w, adj, state)
		elif c == 1:
			# back edge: スタック上の w..u が閉路。member 集合で dedupe して 1 件記録。
			var st: Array = state["stack"]
			var idx: int = -1
			for i in range(st.size() - 1, -1, -1):
				if st[i] == w:
					idx = i
					break
			if idx >= 0:
				var cyc: Array = st.slice(idx)
				var keyparts: Array = cyc.duplicate()
				keyparts.sort()
				var key: String = _lint_join(keyparts, ",")
				if not (state["seen"] as Dictionary).has(key):
					(state["seen"] as Dictionary)[key] = true
					(state["cycles"] as Array).append(cyc)
	(state["stack"] as Array).pop_back()
	(state["color"] as Dictionary)[u] = 2        # black（探索完了）

## 単一トークンを同期前進させない「バリア」種別か（閉路を断つ）。
##   wait_event: 外部シグナルまでブロック。 batch(size>=2): N 個溜まるまで前進しない。
##   batch(size==1) は即前進するのでバリアにならない（＝閉路に含まれれば空転しうる）。
static func _lint_is_barrier(a: Dictionary) -> bool:
	var t: String = str(a.get("type", ""))
	if t == "wait_event":
		return true
	if t == "batch":
		var sz: int = max(1, int(a.get("size", a.get("n", 1))))
		return sz >= 2
	return false

static func _lint_join(arr: Array, sep: String) -> String:
	var s: String = ""
	for i in range(arr.size()):
		if i > 0:
			s += sep
		s += str(arr[i])
	return s
