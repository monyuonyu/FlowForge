extends Node3D
class_name Transporter
## 搬送者（イベント駆動の運搬資源）。Operator 類似だが「アイテムを1個運ぶ」。
## 発生元へ移動→積載→送り先へ移動→投下。送り先が満杯なら空くまでアイテムを持って待機
## （バックプレッシャー整合）。移動時間は現在の論理位置基準（決定的）。
## 見た目は目標位置へ補間し、搬送中アイテムは搬送者に追従する。

var t_name: String = "T"
var move_speed: float = 5.0
var home: Vector3 = Vector3.ZERO
var available: bool = true
var logical_pos: Vector3 = Vector3.ZERO
var model_path: String = ""

# --- 一般化パラメータ（既定は現状同等） ---
var capacity: int = 1          # 1トリップで運べる最大個数（既定1）
var load_time: float = 0.0     # 1個の積載に要する時間（既定0）
var unload_time: float = 0.0   # 1個の投下に要する時間（既定0）
var waypoints: Array = []      # Vector3 の経由点配列（既定空=直行）

var pool = null

# 搬送状態
var _origin = null           # 現在ピックアップ中の発生元 FlowObject
var _dest = null             # 送り先 FlowObject（バッチ共通の投下先）
var _item: FlowItem = null   # 見た目追従用の代表アイテム
var _batch: Array = []       # 現トリップの要求 [{origin,item,dest,...}]（全て同一 dest）
var _carry_idx: int = 0      # ピックアップ/投下の進行インデックス
var _state: String = "idle"  # idle / to_pickup / loading / carrying / unloading / waiting
var _blocked_on: Array = []  # 送り先が満杯で登録している下流（空き通知用）

# --- stage2: 辺容量を尊重する区間逐次走行（有限容量辺が在るときだけ有効） ---
# 1レグ（現在地→pickup など）を「接近→各辺の横断→離脱」の区間列に分解し、辺へ進入する
# 直前に network.request_edge で予約を試みる。満杯なら移動せず FIFO 待機し、他者の解放で
# 起床して横断する。移動時間は常に自由流（辺長/速度）で、輻輳効果は「ノードでの待ち」から
# 生じる（＝fable5 が求めた一次近似モデル）。無制限辺のみのモデルでは _congestion_active が
# false になり、この経路は一切通らず従来の単一スケジュール走行のままバイト一致。
var _cong_segs: Array = []              # 区間列 [{to:Vector3, edge:[a,b]|null, from:String}]
var _cong_idx: int = 0                  # 現在処理中の区間インデックス
var _cong_target = null                 # 本レグの最終目的座標
var _cong_on_arrive: Callable = Callable()  # レグ完了時に呼ぶ本来の到着ハンドラ
var _cong_state: String = ""            # レグ中の表示ステート

var _target_pos = null
var _model_holder: Node3D
var _label: Label3D

# 稼働（運搬）統計：割当(assign)〜投下(_on_delivered) の占有時間を計上。
var _busy_time: float = 0.0
var _busy_start: float = 0.0

func _ready() -> void:
	Sim.register(self)
	_build_visual()

func setup(nm: String, home_pos: Vector3) -> void:
	t_name = nm
	home = home_pos
	logical_pos = home_pos
	global_position = home_pos

func apply_model(path: String) -> void:
	model_path = path
	if _model_holder == null:
		return
	for c in _model_holder.get_children():
		c.queue_free()
	if path != "":
		var m: Node3D = Assets.load_model(path)
		if m != null:
			_model_holder.add_child(m)
			return
	_build_default_body()

func reset_object() -> void:
	available = true
	_state = "idle"
	_origin = null
	_dest = null
	_item = null
	_batch.clear()
	_carry_idx = 0
	_blocked_on.clear()
	_target_pos = null
	logical_pos = home
	global_position = home
	_busy_time = 0.0
	# stage2: 輻輳走行状態もクリア（reset_sim 間の決定論確保）。
	_cong_segs.clear()
	_cong_idx = 0
	_cong_target = null
	_cong_on_arrive = Callable()
	_cong_state = ""

func reset_stats() -> void:
	_busy_time = 0.0
	# 運搬中（未 available）なら計上起点を現在時刻へ。
	if not available:
		_busy_start = Sim.sim_time

## 稼働率（運搬占有時間 / 統計経過時間）。
func utilization() -> float:
	var busy: float = _busy_time
	if not available:
		busy += max(0.0, Sim.sim_time - _busy_start)
	return clamp(busy / Sim.stats_elapsed(), 0.0, 1.0)

func on_sim_start() -> void:
	pass

# --- 移動時間（現在位置基準＝決定的） ---
## 経路（中間点列）を辿った 現在位置→…→target の総距離/speed。
## pool.network がある時はネットワーク最短経路のポリライン、無ければ waypoints 場を使う。
## いずれも空なら直行（現状同等）。
func travel_time(target: Vector3) -> float:
	var path: Array = _leg_path(target)
	if path.is_empty():
		return max(0.05, logical_pos.distance_to(target) / move_speed)
	var d: float = 0.0
	var cur: Vector3 = logical_pos
	for wp in path:
		d += cur.distance_to(wp)
		cur = wp
	d += cur.distance_to(target)
	return max(0.05, d / move_speed)

## 現在位置→target の中間経由点列。ネットワーク優先、無ければ固定 waypoints。
func _leg_path(target: Vector3) -> Array:
	if pool != null and pool.network != null:
		return pool.network.route_points(logical_pos, target)
	return waypoints

func go_to(pos: Vector3, st: String) -> void:
	_target_pos = pos
	_state = st
	logical_pos = pos

# ---------------------------------------------------------------
# stage2: 辺容量を尊重するレグ走行
# ---------------------------------------------------------------
## 有限容量辺を持つネットワークがあるときだけ輻輳エンジンを起動する条件判定。
## false のときは従来通り（バイト一致）。
func _congestion_active() -> bool:
	return pool != null and pool.network != null \
		and pool.network.has_finite_edge_capacity()

## 現在地→target への1レグ移動。輻輳が非活性なら従来の単一スケジュール（＝バイト一致）、
## 活性なら区間逐次走行（辺予約つき）。on_arrive はレグ完了時に呼ぶ本来のハンドラ。
func _travel_to(target: Vector3, st: String, on_arrive: Callable) -> void:
	if _congestion_active():
		_begin_congested_leg(target, st, on_arrive)
	else:
		var tt: float = travel_time(target)
		go_to(target, st)
		Sim.schedule(tt, on_arrive)

## レグを「接近→各辺の横断→離脱」の区間列に分解して逐次走行を開始する。
func _begin_congested_leg(target: Vector3, st: String, on_arrive: Callable) -> void:
	_cong_target = target
	_cong_on_arrive = on_arrive
	_cong_state = st
	_state = st
	var net = pool.network
	var na: String = net.nearest_node(logical_pos)
	var nb: String = net.nearest_node(target)
	var sp: Dictionary = net.shortest_path(na, nb)
	var route: Array = sp.get("nodes", [])
	_cong_segs = []
	if route.is_empty():
		# ネットワーク到達不能：直行フォールバック（保存則を最優先）。
		_cong_segs.append({"to": target, "edge": null, "from": ""})
	else:
		# 接近区間: 現在地 → 最初の制御点（辺予約なし）。
		_cong_segs.append({"to": net.nodes[route[0]], "edge": null, "from": ""})
		# 各辺の横断区間（進入前に予約する）。
		for i in range(route.size() - 1):
			var a: String = String(route[i])
			var b: String = String(route[i + 1])
			_cong_segs.append({"to": net.nodes[b], "edge": [a, b], "from": a})
		# 離脱区間: 最後の制御点 → target（辺予約なし）。
		_cong_segs.append({"to": target, "edge": null, "from": ""})
	_cong_idx = 0
	_run_cong_segment()

## 現在の区間を実行。辺区間なら予約を試み、可なら横断開始／不可なら FIFO 待機。
func _run_cong_segment() -> void:
	if _cong_idx >= _cong_segs.size():
		# レグ完了：本来の到着ハンドラへ委譲。
		logical_pos = _cong_target
		var cb: Callable = _cong_on_arrive
		_cong_segs = []
		if cb.is_valid():
			cb.call()
		return
	var seg: Dictionary = _cong_segs[_cong_idx]
	if seg["edge"] == null:
		_move_cong_free(seg["to"])
	else:
		var e: Array = seg["edge"]
		# 辺へ進入する直前に予約を試みる。可なら即横断、不可なら待機列へ入る。
		var admitted: bool = pool.network.request_edge(
			e[0], e[1], self, String(seg["from"]), _on_edge_granted)
		if admitted:
			_enter_cong_edge()
		# else: 待機。他者が finish_edge した時に network が _on_edge_granted を呼ぶ。

## 辺予約なしの自由区間（接近／離脱）を移動する。ゼロ距離なら 0 遅延イベントを避けて同期前進。
func _move_cong_free(dest_pos: Vector3) -> void:
	var d: float = logical_pos.distance_to(dest_pos)
	go_to(dest_pos, _cong_state)
	if d <= 0.0001:
		_cong_idx += 1
		_run_cong_segment()
	else:
		Sim.schedule(d / move_speed, _on_cong_free_done)

## 予約済みの辺を実際に横断する（自由流：辺長/速度）。予約は済んでいる前提。
func _enter_cong_edge() -> void:
	var seg: Dictionary = _cong_segs[_cong_idx]
	var dest_pos: Vector3 = seg["to"]
	var d: float = logical_pos.distance_to(dest_pos)
	go_to(dest_pos, _cong_state)
	Sim.schedule(max(d / move_speed, 0.0001), _on_cong_edge_crossed)

## 待機していた辺が空いてネットワークに予約確定された時のコールバック（横断開始）。
func _on_edge_granted() -> void:
	_enter_cong_edge()

## 辺の横断完了：占有を解放して次の待機者を起床させ、次区間へ進む。
func _on_cong_edge_crossed() -> void:
	var seg: Dictionary = _cong_segs[_cong_idx]
	var e: Array = seg["edge"]
	pool.network.finish_edge(e[0], e[1], self, String(seg["from"]))
	_cong_idx += 1
	_run_cong_segment()

## 自由区間の到着：次区間へ進む。
func _on_cong_free_done() -> void:
	_cong_idx += 1
	_run_cong_segment()

# ---------------------------------------------------------------
# 搬送フロー（すべて Sim.schedule で表現）
# ---------------------------------------------------------------
## 単一要求の割当（capacity=1 の従来経路＝バッチ長1に委譲）。
func assign(origin, item: FlowItem, dest) -> void:
	assign_batch([{"origin": origin, "item": item, "dest": dest}])

## バッチ割当。reqs は全て同一 dest の要求 [{origin,item,dest,...}]。
func assign_batch(reqs: Array) -> void:
	available = false
	_busy_start = Sim.sim_time
	_batch = reqs
	_dest = reqs[0].get("dest", null)
	_carry_idx = 0
	_begin_pickup()

# 現在の _carry_idx の発生元へ移動して積載を開始。
func _begin_pickup() -> void:
	_origin = _batch[_carry_idx].get("origin", null)
	_item = _batch[_carry_idx].get("item", null)
	var pickup: Vector3 = _origin.transport_pickup_pos()
	_travel_to(pickup, "to_pickup", _on_arrive_pickup)

func _on_arrive_pickup() -> void:
	# 積載時間>0 なら Sim.schedule で計上（稼働時間に含める）。0 なら即時。
	if load_time > 0.0:
		_state = "loading"
		Sim.schedule(load_time, _finish_load)
	else:
		_finish_load()

func _finish_load() -> void:
	# 積載：発生元のスロットを解放（→上流再開）してから次工程へ
	if _origin != null and _origin.has_method("_on_transport_pickup"):
		_origin._on_transport_pickup()
	_carry_idx += 1
	if _carry_idx < _batch.size():
		# まだ積み残しがある：次の発生元へ
		_begin_pickup()
	else:
		# 全て積載完了：送り先へ移動
		_carry_idx = 0
		var drop: Vector3 = _dest.transport_pickup_pos()
		_travel_to(drop, "carrying", _on_arrive_dest)

func _on_arrive_dest() -> void:
	# 投下時間>0 なら Sim.schedule で計上。0 なら即時に投下を試みる。
	if unload_time > 0.0:
		_state = "unloading"
		Sim.schedule(unload_time, _try_deliver)
	else:
		_try_deliver()

func _try_deliver() -> void:
	# バッチ内の未投下アイテムを順に受け渡す。満杯なら残りを保持して待機。
	while _carry_idx < _batch.size():
		var it: FlowItem = _batch[_carry_idx].get("item", null)
		_item = it
		if _dest.receive_item(it):
			_carry_idx += 1
		else:
			# 送り先が満杯：空き通知を受けるまでアイテムを持って待機
			if not _dest._blocked_upstreams.has(self):
				_dest._blocked_upstreams.append(self)
			if not _blocked_on.has(_dest):
				_blocked_on.append(_dest)
			_state = "waiting"
			return
	_on_delivered()

## 送り先に空きが出た時に呼ばれる（FlowObject._notify_space 経由）。
func _retry_push() -> void:
	_try_deliver()

func _on_delivered() -> void:
	_busy_time += max(0.0, Sim.sim_time - _busy_start)
	_item = null
	_origin = null
	_dest = null
	_batch.clear()
	_carry_idx = 0
	_blocked_on.clear()
	available = true
	_state = "idle"
	if pool != null:
		pool._assign_next(self)

# ---------------------------------------------------------------
# 見た目
# ---------------------------------------------------------------
func _build_visual() -> void:
	_model_holder = Node3D.new()
	add_child(_model_holder)
	_build_default_body()
	_label = Label3D.new()
	_label.text = t_name
	_label.position = Vector3(0, 1.6, 0)
	_label.font_size = 24
	_label.outline_size = 5
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.fixed_size = true
	_label.pixel_size = 0.0010
	add_child(_label)

func _build_default_body() -> void:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.9, 0.4, 0.7)
	body.mesh = box
	body.position = Vector3(0, 0.25, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.55, 0.90)
	mat.roughness = 0.5
	body.material_override = mat
	_model_holder.add_child(body)

var _last_lbl_state: String = "?"

func _process(delta: float) -> void:
	if _target_pos != null:
		global_position = global_position.move_toward(_target_pos, delta * move_speed * max(1.0, Sim.speed))
		if global_position.distance_to(_target_pos) < 0.03:
			_target_pos = null
	# 搬送中アイテムは搬送者に追従
	if _item != null and Sim.visuals_enabled and is_instance_valid(_item):
		_item.set_pos_now(global_position + Vector3(0, 0.7, 0))
	if _label != null and _state != _last_lbl_state:
		_last_lbl_state = _state
		_label.text = "%s\n[%s]" % [t_name, _state]
