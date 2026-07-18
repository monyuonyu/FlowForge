extends Node3D
class_name TransportPool
## 搬送者プール（イベント駆動・FIFO ディスパッチ）。
## 要求（発生元・アイテム・送り先）を待ち行列に積み、空いた搬送者を先着順に割り当てる。

var transporters: Array = []
var _waiting: Array = []   # 搬送待ちの要求 {origin,item,dest,priority,seq}（3D 側）
## 外部待機者フック（PF ProcessFlow など、このプールを共有する外部エンジン）。
## 既定空＝ドーマント。3D 内部待ち行列(_waiting)を捌き切っても空きが残る時のみ、
## 登録順に呼び出す（MIRROR: 3D 解放 → PF 待機の起床）。乱数は一切引かない＝決定論不変。
var _external_waiters: Array = []   # Array[Callable]
var _wseq: int = 0         # 要求登録順（決定的タイブレーク用）
## ディスパッチ規則: "fifo"(既定=登録順の先着) / "nearest"(発生元に最も近い空き搬送者)。
## 既定 fifo は従来経路と完全一致（決定論不変）。
var dispatch_rule: String = "fifo"

## AGV 搬送ネットワーク（既定 null＝従来の直行）。ModelIO が model["network"] から構築する。
## 非 null のとき Transporter は発生元→目的地を制御点グラフ上の最短経路で走行する。
var network: TransportNetwork = null

# ネットワーク辺の簡易可視化ノード（visuals_enabled 時のみ生成）。
var _net_viz: Node3D = null

## サービス順の記録（テスト/検証用）。ディスパッチしたバッチ毎に priority 配列を追記。
var service_log: Array = []

func _ready() -> void:
	Sim.register(self)

func set_dispatch_rule(rule: String) -> void:
	dispatch_rule = "nearest" if rule == "nearest" else "fifo"

## 搬送ネットワークを設定（null で従来の直行に戻す）。visuals_enabled 時は辺を線で表示。
func set_network(net: TransportNetwork) -> void:
	network = net
	if Sim.visuals_enabled:
		_build_network_visual()

# ネットワークの辺を細い箱で結ぶ軽量表示（純データ検証には影響しない）。
func _build_network_visual() -> void:
	if _net_viz != null and is_instance_valid(_net_viz):
		_net_viz.queue_free()
		_net_viz = null
	if network == null or network.is_empty():
		return
	_net_viz = Node3D.new()
	add_child(_net_viz)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.75, 0.55, 0.7)
	mat.flags_transparent = true
	for e in network.edges:
		var a: Vector3 = network.nodes.get(str(e[0]), Vector3.ZERO)
		var b: Vector3 = network.nodes.get(str(e[1]), Vector3.ZERO)
		var seg := MeshInstance3D.new()
		var bm := BoxMesh.new()
		var len_ab: float = max(0.05, a.distance_to(b))
		bm.size = Vector3(0.08, 0.02, len_ab)
		seg.mesh = bm
		seg.material_override = mat
		seg.position = (a + b) * 0.5 + Vector3(0, 0.02, 0)
		var dir: Vector3 = (b - a)
		if abs(dir.normalized().dot(Vector3.UP)) < 0.99:
			seg.look_at_from_position(seg.position, b + Vector3(0, 0.02, 0), Vector3.UP)
		_net_viz.add_child(seg)

func add_transporter(t: Transporter) -> void:
	if not transporters.has(t):
		transporters.append(t)
		t.pool = self

func has_transporters() -> bool:
	return transporters.size() > 0

func reset_object() -> void:
	_waiting.clear()
	# 外部待機フックも初期化（run 跨ぎの残留 Callable を排除＝決定論の衛生）。空なら no-op。
	_external_waiters.clear()
	_wseq = 0
	service_log.clear()
	# stage2: ネットワークの占有・待機・方向ロックを初期化（reset_sim 間の決定論確保）。
	# 全辺 INF（既定）なら占有は元々0で待機も無いため、この初期化は no-op でバイト一致。
	if network != null:
		network.reset_occupancy()

func on_sim_start() -> void:
	pass

func available_count() -> int:
	var n: int = 0
	for t in transporters:
		if t.available:
			n += 1
	return n

func busy_count() -> int:
	return transporters.size() - available_count()

## 搬送者群の平均稼働率（UI/KPI 参照用）。台数0なら0。
func avg_utilization() -> float:
	if transporters.is_empty():
		return 0.0
	var s: float = 0.0
	for t in transporters:
		s += t.utilization()
	return s / transporters.size()

## 搬送を要求。origin から item を dest へ運ぶ。priority は待ち行列の優先度（既定0）。
func request(origin, item: FlowItem, dest, priority: int = 0) -> void:
	var req: Dictionary = {"origin": origin, "item": item, "dest": dest,
		"priority": priority, "seq": _wseq}
	_wseq += 1
	if dispatch_rule == "nearest":
		var pickup: Vector3 = origin.transport_pickup_pos()
		var best = null
		var best_d: float = INF
		for t in transporters:
			if t.available:
				var d: float = t.logical_pos.distance_to(pickup)
				if d < best_d:
					best_d = d
					best = t
		if best != null:
			_record_service([req])
			best.assign(origin, item, dest)
			return
		_waiting.append(req)
		return
	# fifo（既定・従来経路と完全一致）
	for t in transporters:
		if t.available:
			_record_service([req])
			t.assign(origin, item, dest)
			return
	_waiting.append(req)

# サービス記録（ディスパッチしたバッチの priority 配列を追記）。
func _record_service(batch: Array) -> void:
	var pr: Array = []
	for r in batch:
		pr.append(int(r.get("priority", 0)))
	service_log.append(pr)

# 待ち行列で最も優先すべき要求の index。priority 降順 → seq 昇順。
func _pick_index() -> int:
	var best: int = -1
	for i in range(_waiting.size()):
		if best < 0:
			best = i
			continue
		var a: Dictionary = _waiting[i]
		var b: Dictionary = _waiting[best]
		var pa: int = int(a.get("priority", 0))
		var pb: int = int(b.get("priority", 0))
		if pa > pb or (pa == pb and int(a.get("seq", 0)) < int(b.get("seq", 0))):
			best = i
	return best

func _req_valid(req: Dictionary) -> bool:
	var origin = req.get("origin", null)
	var item = req.get("item", null)
	var dest = req.get("dest", null)
	return is_instance_valid(origin) and is_instance_valid(dest) \
			and is_instance_valid(item) and origin.still_needs_transport(item)

func _assign_next(t: Transporter) -> void:
	while _waiting.size() > 0:
		var idx: int = _pick_index()
		if idx < 0:
			return
		var req: Dictionary = _waiting[idx]
		_waiting.remove_at(idx)
		if not _req_valid(req):
			continue
		# バッチ構築: 同一 dest の待ち要求を capacity 件までまとめる（優先度順）。
		var batch: Array = [req]
		var dest0 = req.get("dest", null)
		var cap: int = max(1, int(t.capacity))
		while batch.size() < cap:
			var j: int = _pick_index_dest(dest0)
			if j < 0:
				break
			var r2: Dictionary = _waiting[j]
			_waiting.remove_at(j)
			if not _req_valid(r2):
				continue
			batch.append(r2)
		_record_service(batch)
		t.assign_batch(batch)
		return
	# 3D 内部待ち行列を捌き切っても t が空きのまま → 外部待機者(PF)へ通知（MIRROR wakeup）。
	# 固定順: 3D 内部が先、その後 外部/PF。外部が無ければ即 return＝ドーマント。
	_notify_external(t)

# 指定 dest に一致する待ち要求のうち最優先の index（優先度降順→seq昇順）。無ければ -1。
func _pick_index_dest(dest0) -> int:
	var best: int = -1
	for i in range(_waiting.size()):
		var r: Dictionary = _waiting[i]
		if r.get("dest", null) != dest0:
			continue
		if best < 0:
			best = i
			continue
		var b: Dictionary = _waiting[best]
		var pa: int = int(r.get("priority", 0))
		var pb: int = int(b.get("priority", 0))
		if pa > pb or (pa == pb and int(r.get("seq", 0)) < int(b.get("seq", 0))):
			best = i
	return best

## 外部待機者コールバックを登録（重複登録はしない）。PF が rr["waiters"] に
## トークンを積む時だけ呼ぶ。3D 解放で空きが出た際に起床通知を受け取れるようにする。
func register_external_waiter(cb: Callable) -> void:
	if not _external_waiters.has(cb):
		_external_waiters.append(cb)

## 外部待機者コールバックを解除（PF の待ち行列が空になったらドーマントへ戻す）。
func unregister_external_waiter(cb: Callable) -> void:
	_external_waiters.erase(cb)

## 空き搬送者 t を外部待機者へ登録順に提示する。3D 内部待ち行列を捌いた後にのみ呼ぶ。
## 乱数は引かない。外部が無ければ即 return（既存マーカーはバイト同一）。
## 反復中の register/unregister に備えて複製上を走査し、t が確保されたら打ち切る（二重配車防止）。
func _notify_external(t: Transporter) -> void:
	if _external_waiters.is_empty():
		return
	for cb in _external_waiters.duplicate():
		if not t.available:
			break
		if cb.is_valid():
			cb.call()
