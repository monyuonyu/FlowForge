extends RefCounted
class_name ModelIO
## モデルの構築・直列化・保存/読込。
## モデルは Dictionary（→JSON）で表現する。schema は README 参照。

# ---------------------------------------------------------------
# schema バージョン管理
# 現行 schema バージョン。to_dict はこの値を書き出す。
# 破壊的変更を行う際はここを上げ、migrate() に旧版→新版の変換を追記する。
const CURRENT_VERSION := 1

# 旧い params キー別名 → 正規キー。旧モデルの読込時に正規化する。
# 既存モデルは正規キーのみ使用するため、この正規化は既存動作に影響しない。
const PARAM_ALIASES := {
	"cap": "capacity",
	"proc_time": "process_time",
	"processing_time": "process_time",
	"inter_arrival": "interarrival",
	"interarrival_time": "interarrival",
	"arrival": "interarrival",
	"travel": "travel_time",
	"num_types": "type_count",
	"types": "type_count",
	"batch": "batch_size",
	"split": "split_qty",
}

# ---------------------------------------------------------------
# migrate: 任意（旧版・欠落キーあり）のモデル辞書を現行 schema へ正規化する。
# - version 欠落 → 1 を補完
# - seed / warmup / operators / transporters / objects / connections 欠落 → 既定補完
# - 各 object の params 内の旧別名キー → 正規キーへ変換
# - 将来の破壊的変更に備え、version 別の段階変換をここに追加していく。
# 冪等（再適用しても結果不変）に保つこと。
func migrate(model: Dictionary) -> Dictionary:
	var m: Dictionary = model.duplicate(true)
	# version 欠落補完
	if not m.has("version"):
		m["version"] = 1
	var v: int = int(m.get("version", 1))

	# --- 段階的マイグレーション枠組み（例: v0/未知 → v1）---
	# 現状は v1 のみ。将来 v2 追加時は下記のように積み上げる:
	#   if v < 2: m = _migrate_1_to_2(m); v = 2
	if v < 1:
		v = 1
	m["version"] = CURRENT_VERSION

	# トップレベル欠落キーの既定補完
	if not m.has("seed"):
		m["seed"] = 12345
	if not m.has("warmup"):
		m["warmup"] = 0.0
	if not (m.get("operators") is Array):
		m["operators"] = []
	if not (m.get("transporters") is Array):
		m["transporters"] = []
	if not (m.get("objects") is Array):
		m["objects"] = []
	if not (m.get("connections") is Array):
		m["connections"] = []

	# params の旧別名キー正規化
	for od in m["objects"]:
		if od is Dictionary and od.get("params") is Dictionary:
			od["params"] = _normalize_params(od["params"])
	return m

func _normalize_params(p: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in p.keys():
		var nk: String = PARAM_ALIASES.get(k, k)
		# 正規キーが既に存在する場合は既存を優先（別名は破棄）
		if nk != k and out.has(nk):
			continue
		out[nk] = p[k]
	return out

# ---------------------------------------------------------------
# 構築： model(Dictionary) から実ノードを生成し parent に追加。
# 戻り値 ctx = {registry, flow_objects, operators, pool, source, sink}
# ---------------------------------------------------------------
func build(model_in: Dictionary, parent: Node, allow_scripts: bool = true) -> Dictionary:
	var model: Dictionary = migrate(model_in)   # version 差・欠落キーを吸収
	var ctx := {
		"registry": {}, "flow_objects": [], "operators": [], "transporters": [],
		"pool": null, "transport_pool": null, "source": null, "sink": null,
	}
	Scripts.clear_objects()
	Sim.seed = int(model.get("seed", 12345))
	Sim.warmup = float(model.get("warmup", 0.0))

	# 作業者プール
	var pool := OperatorPool.new()
	parent.add_child(pool)
	ctx.pool = pool
	for od in model.get("operators", []):
		var op := Operator.new()
		parent.add_child(op)
		op.setup(str(od.get("name", "Op")), _v3(od.get("home", [0, 0, 0])))
		if od.has("shift"):
			op.shift = od.shift
		if od.has("shift_period"):
			op.shift_period = float(od.shift_period)
		if od.has("model") and str(od.model) != "":
			op.apply_model(str(od.model))
		pool.add_operator(op)
		ctx.operators.append(op)

	# 搬送者プール（既定は空）
	var tpool := TransportPool.new()
	parent.add_child(tpool)
	ctx.transport_pool = tpool
	for td in model.get("transporters", []):
		var tr := Transporter.new()
		parent.add_child(tr)
		tr.setup(str(td.get("name", "T")), _v3(td.get("home", [0, 0, 0])))
		if td.has("capacity"): tr.capacity = int(td["capacity"])
		if td.has("load_time"): tr.load_time = float(td["load_time"])
		if td.has("unload_time"): tr.unload_time = float(td["unload_time"])
		if td.has("waypoints"):
			var wps: Array = []
			for w in td["waypoints"]:
				wps.append(_v3(w))
			tr.waypoints = wps
		if td.has("model") and str(td.model) != "":
			tr.apply_model(str(td.model))
		tpool.add_transporter(tr)
		ctx.transporters.append(tr)

	# 搬送ネットワーク（既定なし＝従来の直行）。model["network"]={nodes,edges} から構築。
	var net_def = model.get("network", null)
	if net_def is Dictionary and (net_def.get("nodes") is Dictionary) \
			and not (net_def.get("nodes") as Dictionary).is_empty():
		var net := TransportNetwork.new(net_def.get("nodes", {}), net_def.get("edges", []))
		# 辺／ノード容量（任意）。既定は未設定＝INF（無制限）で従来どおりドーマント。
		# edge_capacities: [[a, b, cap], ...] / node_capacities: [[id, cap], ...]
		for ec in net_def.get("edge_capacities", []):
			if ec is Array and ec.size() >= 3:
				net.set_edge_capacity(str(ec[0]), str(ec[1]), float(ec[2]))
		for nc in net_def.get("node_capacities", []):
			if nc is Array and nc.size() >= 2:
				net.set_node_capacity(str(nc[0]), float(nc[1]))
		tpool.set_network(net)

	# 設備
	for od in model.get("objects", []):
		var o: FlowObject = _make(str(od.get("type", "Queue")))
		if o == null:
			continue
		o.id = str(od.get("id", ""))
		o.obj_name = str(od.get("name", od.get("type", "Object")))
		o.position = _v3(od.get("pos", [0, 0, 0]))
		if od.has("rot"):
			o.rotation.y = deg_to_rad(float(od.rot))
		if od.has("model"):
			o.model_path = str(od.model)
		if od.has("scale"):
			o.model_scale = float(od.scale)
		parent.add_child(o)   # _ready でモデル込みの見た目を構築
		if od.has("params"):
			o.set_params(od.params)
		ctx.registry[o.id] = o
		ctx.flow_objects.append(o)
		Scripts.register_object(o.id, o)

		# すべての Processor にプールを渡す（needs_operator/transport_out を後から有効化しても機能する）
		if o is Processor:
			o.operator_pool = pool
			o.transport_pool = tpool
		if o is Source:
			ctx.source = o
		if o is Sink:
			ctx.sink = o
		if o is Conveyor:
			var pr: Dictionary = od.get("params", {})
			if pr.has("start"):
				o.start_point = _v3(pr.start)
			if pr.has("end"):
				o.end_point = _v3(pr.end)
			o.build_belt()

		if od.has("script") and str(od.script) != "":
			if allow_scripts:
				o.set_logic(str(od.script))
			else:
				o.script_source = str(od.script)   # 保持のみ（実行しない）

	# 接続
	for c in model.get("connections", []):
		if c.size() < 2:
			continue
		var a = ctx.registry.get(str(c[0]), null)
		var b = ctx.registry.get(str(c[1]), null)
		if a != null and b != null:
			a.connect_to(b)

	return ctx

# ---------------------------------------------------------------
# 直列化： 現在の ctx を Dictionary に。
# ---------------------------------------------------------------
func to_dict(ctx: Dictionary) -> Dictionary:
	var objs: Array = []
	for o in ctx.flow_objects:
		var params: Dictionary = o.get_params().duplicate(true)
		if o is Conveyor:
			params["start"] = _arr(o.start_point)
			params["end"] = _arr(o.end_point)
		objs.append({
			"id": o.id, "type": o.type_name(), "name": o.obj_name,
			"pos": _arr(o.position), "rot": rad_to_deg(o.rotation.y),
			"model": o.model_path, "scale": o.model_scale,
			"params": params, "script": o.script_source,
		})
	var conns: Array = []
	for o in ctx.flow_objects:
		for t in o.outputs:
			conns.append([o.id, t.id])
	var ops: Array = []
	for op in ctx.operators:
		var opd := {"name": op.op_name, "home": _arr(op.home), "model": op.model_path}
		if not op.shift.is_empty():
			opd["shift"] = op.shift
			opd["shift_period"] = op.shift_period
		ops.append(opd)
	var trs: Array = []
	for tr in ctx.get("transporters", []):
		var trd := {"name": tr.t_name, "home": _arr(tr.home), "model": tr.model_path}
		if int(tr.capacity) != 1: trd["capacity"] = int(tr.capacity)
		if float(tr.load_time) != 0.0: trd["load_time"] = float(tr.load_time)
		if float(tr.unload_time) != 0.0: trd["unload_time"] = float(tr.unload_time)
		if not tr.waypoints.is_empty():
			var wps: Array = []
			for w in tr.waypoints:
				wps.append(_arr(w))
			trd["waypoints"] = wps
		trs.append(trd)
	var out := {
		"version": CURRENT_VERSION, "seed": Sim.seed, "warmup": Sim.warmup,
		"objects": objs, "connections": conns, "operators": ops, "transporters": trs,
	}
	# 搬送ネットワーク（あれば）。既定 null のときはキー自体を出さない（既存モデル不変）。
	var tp = ctx.get("transport_pool", null)
	if tp != null and tp.network != null and not tp.network.is_empty():
		var nnodes: Dictionary = {}
		for nid in tp.network.nodes.keys():
			nnodes[str(nid)] = _arr(tp.network.nodes[nid])
		var nedges: Array = []
		for e in tp.network.edges:
			nedges.append([str(e[0]), str(e[1])])
		var netd: Dictionary = {"nodes": nnodes, "edges": nedges}
		# 有限容量を設定した辺のみ書き出す（無ければキー自体を出さない＝既存モデル不変）。
		var ncaps: Array = []
		for e in tp.network.edges:
			var cap: float = tp.network.edge_capacity(e[0], e[1])
			if not is_inf(cap):
				ncaps.append([str(e[0]), str(e[1]), cap])
		if not ncaps.is_empty():
			netd["edge_capacities"] = ncaps
		out["network"] = netd
	return out

# ---------------------------------------------------------------
# JSON 保存/読込
# ---------------------------------------------------------------
func save_json(path: String, model: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		Scripts.log_msg("⚠ 保存失敗: %s" % path)
		return false
	f.store_string(JSON.stringify(model, "\t"))
	f.close()
	Scripts.log_msg("💾 モデルを保存: %s" % path)
	return true

func load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		Scripts.log_msg("⚠ JSON解析失敗: %s" % path)
		return {}
	return migrate(parsed)   # 旧版・欠落キーを現行 schema へ正規化

# ---------------------------------------------------------------
## モデルの objects いずれかに非空の script が含まれるか。
func model_has_scripts(model: Dictionary) -> bool:
	for od in model.get("objects", []):
		if str(od.get("script", "")).strip_edges() != "":
			return true
	return false

# ---------------------------------------------------------------
# CSV 取込（入力モデリング）
# ---------------------------------------------------------------
## CSVテキストを行配列（各行=セル文字列配列）へパースする。
## 空行は無視、各セルの前後空白は除去、CR も除去。
func parse_csv(text: String) -> Array:
	var rows: Array = []
	for raw_line in text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line == "":
			continue
		var cells: Array = []
		for c in line.split(","):
			cells.append(c.strip_edges())
		rows.append(cells)
	return rows

## 2列(time, interarrival_mean)のCSV → Source.arrival_schedule 形式:
## [{"from":time, "interarrival":{"type":"exp","a":mean}}, ...]
## 数値でない先頭セルの行（ヘッダ等）は自動でスキップする。
func csv_to_arrival_schedule(text: String) -> Array:
	var sched: Array = []
	for cells in parse_csv(text):
		if cells.size() < 2:
			continue
		if not _is_number(cells[0]) or not _is_number(cells[1]):
			continue
		sched.append({
			"from": float(cells[0]),
			"interarrival": {"type": "exp", "a": float(cells[1])},
		})
	return sched

## 1列の数値CSV → 数値配列（empirical / empirical_cont の a 配列用）。
## 数値でないセル（ヘッダ等）はスキップする。
func csv_to_values(text: String) -> Array:
	var vals: Array = []
	for cells in parse_csv(text):
		if cells.is_empty():
			continue
		if not _is_number(cells[0]):
			continue
		vals.append(float(cells[0]))
	return vals

func _is_number(s: String) -> bool:
	return s.is_valid_float() or s.is_valid_int()

func _make(type_str: String) -> FlowObject:
	match type_str:
		"Source": return Source.new()
		"Queue": return Queue.new()
		"Rack": return Rack.new()
		"Processor": return Processor.new()
		"Conveyor": return Conveyor.new()
		"Sink": return Sink.new()
		"Combiner": return Combiner.new()
		"Separator": return FlowSeparator.new()
		_:
			push_error("未知の設備タイプ: %s" % type_str)
			return null

func _v3(a) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO

func _arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

# ---------------------------------------------------------------
# 既定モデル（サンプル工場 + スクリプト例）
# ---------------------------------------------------------------
func default_model() -> Dictionary:
	return {
		"version": 1,
		"seed": 12345,
		"warmup": 0.0,
		"operators": [
			{"name": "Op1", "home": [-6, 0, 8], "model": "res://models/operator.glb"},
			{"name": "Op2", "home": [8, 0, 9], "model": "res://models/operator.glb"},
		],
		"objects": [
			{
				"id": "src", "type": "Source", "name": "Source", "pos": [-16, 0, 0],
				"model": "res://models/source.glb",
				"params": {"interarrival": {"type": "exp", "a": 3.5}, "type_count": 3},
				"script": "extends LogicBase\n\n# 生成時に優先度ラベルを付与\nfunc on_create(item):\n\titem.set_label(\"priority\", sim.rand_int(1, 3))\n",
			},
			{
				"id": "q1", "type": "Queue", "name": "Queue 1", "pos": [-11, 0, 0],
				"model": "res://models/buffer.glb", "params": {"capacity": 12},
			},
			{
				"id": "mA", "type": "Processor", "name": "Machine A", "pos": [-6, 0, 0],
				"model": "res://models/machine.glb",
				"params": {"process_time": {"type": "normal", "a": 5.0, "b": 1.2}, "needs_operator": true,
					"mtbf": {"type": "exp", "a": 45.0}, "mttr": {"type": "const", "a": 8.0}},
				"script": "extends LogicBase\n\n# 処理時間をスクリプトで決める\nfunc process_time():\n\treturn sim.normal(5.0, 1.0)\n\nfunc on_process_finish(item):\n\tsim.log(\"A 完了 item=%d age=%.1fs\" % [item.id, item.age()])\n",
			},
			{
				"id": "conv", "type": "Conveyor", "name": "Conveyor", "pos": [-1, 0, 0],
				"params": {"travel_time": 5.0, "start": [-4, 0, 0], "end": [2, 0, 0]},
			},
			{
				"id": "q2", "type": "Queue", "name": "Queue 2", "pos": [4, 0, 0],
				"model": "res://models/buffer.glb", "params": {"capacity": 12},
				"script": "extends LogicBase\n\n# 型番で送り先ポートを振り分け（0→B1, それ以外→B2）\nfunc select_output(item):\n\treturn 0 if item.item_type == 0 else 1\n",
			},
			{
				"id": "mB1", "type": "Processor", "name": "Machine B1", "pos": [8, 0, -3],
				"model": "res://models/machine.glb",
				"params": {"process_time": {"type": "normal", "a": 8.0, "b": 2.0}, "needs_operator": true,
					"setup_time": {"type": "const", "a": 4.0}},
			},
			{
				"id": "mB2", "type": "Processor", "name": "Machine B2", "pos": [8, 0, 3],
				"model": "res://models/robot_arm.glb",
				"params": {"process_time": {"type": "normal", "a": 8.0, "b": 2.0}, "needs_operator": true,
					"setup_time": {"type": "const", "a": 4.0}},
			},
			{
				"id": "sink", "type": "Sink", "name": "Sink", "pos": [13, 0, 0],
				"model": "res://models/sink.glb",
			},
		],
		"connections": [
			["src", "q1"], ["q1", "mA"], ["mA", "conv"], ["conv", "q2"],
			["q2", "mB1"], ["q2", "mB2"], ["mB1", "sink"], ["mB2", "sink"],
		],
	}
