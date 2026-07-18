extends Node3D
## エントリポイント。空間・照明・カメラを用意し、モデルを構築して編集/実行UIを起動する。

const USER_MODEL := "user://model.json"

var io: ModelIO
var editor: Editor
var model_root: Node3D
var camera: CameraRig
var grid: GridRuler
var measure: MeasureViz
var ctx: Dictionary = {}
var _ui_ref = null

func _ready() -> void:
	_setup_environment()
	_setup_items_root()
	_setup_camera()

	# CAD グリッド＆定規
	grid = GridRuler.new()
	grid.cam = camera
	add_child(grid)

	# メジャーツール表示
	measure = MeasureViz.new()
	add_child(measure)

	model_root = Node3D.new()
	model_root.name = "ModelRoot"
	add_child(model_root)

	io = ModelIO.new()
	var model: Dictionary = io.load_json(USER_MODEL)
	var allow_scripts := true
	if model.is_empty():
		model = io.default_model()   # 自作の既定モデル（信頼済み）はスクリプト有効
	elif io.model_has_scripts(model):
		# 起動時の自動読込ではユーザー由来モデルのスクリプトは実行しない
		allow_scripts = false
		Scripts.log_msg("起動時はスクリプトを無効化。読込ボタンで有効化可")
	ctx = io.build(model, model_root, allow_scripts)

	Sim.reset_sim()   # 初期イベント（Source生成など）を仕込む

	editor = Editor.new()
	add_child(editor)
	editor.setup(io, model_root, ctx)
	editor.measure = measure

	var connviz := ConnectionViz.new()
	add_child(connviz)
	connviz.setup(editor)

	var ui := preload("res://scripts/UI.gd").new()
	ui.editor = editor
	ui.io = io
	ui.camera = camera
	ui.grid = grid
	add_child(ui)
	_ui_ref = ui

	Sim.pause()

	if OS.has_environment("SIM_HEADLESS_TEST"):
		_run_headless_test()
	if OS.has_environment("SIM_SHOT"):
		_run_shot()

func _run_shot() -> void:
	if OS.get_environment("SIM_SHOT") == "edit":
		if _ui_ref != null:
			_ui_ref._on_edit_toggled(true)
		# 編集インスペクタは FlowObject 専用。Sim.objects には Operator も混ざり
		# select() が型不一致で失敗するため、flow_objects から確実に部品を選ぶ。
		var _fobjs: Array = editor.ctx.get("flow_objects", [])
		if _fobjs.size() > 0:
			editor.select(_fobjs[2] if _fobjs.size() > 2 else _fobjs[0])
		await get_tree().process_frame
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img2: Image = get_viewport().get_texture().get_image()
		img2.save_png("/tmp/fsim_shot.png")
		print("[shot] saved /tmp/fsim_shot.png (edit)")
		get_tree().quit()
		return
	Sim.set_speed(4.0)
	Sim.start()
	await get_tree().create_timer(3.5).timeout
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png("/tmp/fsim_shot.png")
	print("[shot] saved /tmp/fsim_shot.png")
	get_tree().quit()

# ---------------------------------------------------------------
func _setup_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.10, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.ambient_light_energy = 0.6
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	var floor_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 50)
	floor_mi.mesh = plane
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.16, 0.17, 0.21)
	fmat.roughness = 1.0
	floor_mi.material_override = fmat
	add_child(floor_mi)

func _setup_items_root() -> void:
	var root := Node3D.new()
	root.name = "ItemsRoot"
	add_child(root)
	Sim.items_root = root

func _setup_camera() -> void:
	camera = CameraRig.new()
	add_child(camera)

# ---------------------------------------------------------------
func _run_headless_test() -> void:
	print("=== SELF TEST ===")
	# 1) アセット読込
	var m := Assets.load_model("res://models/machine.glb")
	print("[asset] machine.glb -> ", ("OK" if m != null else "FAIL"))
	# 1b) CAD 機能
	camera.set_ortho(true)
	camera.preset("top")
	print("[cad] ortho=%s proj=%d ppm=%.1f" % [str(camera.ortho), camera.projection, camera.pixels_per_meter()])
	grid._process(0.0)
	print("[cad] grid.minor=%.2f labels=%d" % [grid.minor, grid._labels_root.get_child_count()])
	print("[cad] snap(1.2,2.7)=%s" % str(editor.snap_vec(Vector3(1.2, 0, 2.7))))
	measure.add_point(Vector3(0, 0, 0))
	measure.add_point(Vector3(3, 0, 4))
	print("[cad] measure seg=%.2fm markers=%d" % [
		Vector3(0, 0, 0).distance_to(Vector3(3, 0, 4)), measure._markers_root.get_child_count()])
	measure.finish_line()
	print("[cad] measure lines=%d" % measure.lines.size())
	camera.set_ortho(false)

	# 2) 決定論：同一シードで瞬時実行を2回 → 完全一致、別シード → 変化
	Sim.visuals_enabled = false
	var r1 := _one_run(12345, 600.0)
	var r2 := _one_run(12345, 600.0)
	var r3 := _one_run(99999, 600.0)
	print("[determinism] seed12345: run1=%s run2=%s identical=%s | seed99999=%s" % [
		r1, r2, str(r1 == r2), r3])

	# 3) 状態内訳（故障down・段取りsetupがイベントで発生しているか）
	Sim.seed = 12345; Sim.warmup = 0.0
	Sim.reset_sim(); Sim.run_until(1800.0)
	var mA = editor.ctx.registry.get("mA", null)
	var mB1 = editor.ctx.registry.get("mB1", null)
	if mA != null:
		var da: Dictionary = mA.state_durations()
		print("[states] Machine A busy=%.0f down=%.0f blocked=%.0f (util=%.0f%%)" % [
			float(da.get("busy", 0)), float(da.get("down", 0)), float(da.get("blocked", 0)), mA.utilization() * 100.0])
	if mB1 != null:
		print("[states] Machine B1 setup=%.0f" % float(mB1.state_durations().get("setup", 0.0)))

	# 4) warmup 効果：warmup=300 でスループットが立ち上がり除外されるか
	var thr_nowarm := _one_run_thr(12345, 1800.0, 0.0)
	var thr_warm := _one_run_thr(12345, 1800.0, 300.0)
	print("[warmup] thr(warmup=0)=%.1f/h  thr(warmup=300)=%.1f/h" % [thr_nowarm, thr_warm])

	# 5) 実験：5レプリケーション（平均±95%CI）＋CSV
	var res := Sim.run_replications(5, 3600.0, 300.0, 20250717,
		func(): return editor.ctx.sink, func(): return editor.ctx.source)
	print("[experiment] reps=%d thr=%.1f ±%.1f /h  leadtime=%.1f ±%.1f s" % [
		res.reps, res.thr_mean, res.thr_ci, res.lt_mean, res.lt_ci])
	_write_csv(res)

	# 6) Undo（構造変更）
	Sim.visuals_enabled = true
	var n0: int = editor.ctx.flow_objects.size()
	editor.add_object("Queue")
	var n1: int = editor.ctx.flow_objects.size()
	editor.undo()
	var n2: int = editor.ctx.flow_objects.size()
	print("[undo] add %d→%d undo→%d" % [n0, n1, n2])

	# 7) スクリプト実行の確認 + 統計
	Sim.reset_sim(); Sim.run_until(600.0)
	print("[script] source.created=%d  (mA script=%s)" % [
		editor.ctx.source.created, str(editor.ctx.registry["mA"].logic != null)])
	print("[stats] avg_wip(時間平均)=%.2f  現在wip=%d" % [Sim.avg_wip(), Sim.wip])
	var q1 = editor.ctx.registry.get("q1", null)
	if q1 != null:
		print("[stats] Queue1 Lq=%.2f Wq=%.1fs  リードタイム標本=%d" % [
			q1.avg_length(), q1.avg_wait(), editor.ctx.sink.leadtimes.size()])

	# 8) Separator（1→2, WIP増）
	editor.rebuild(_mini_model("Separator", {"split_qty": 2}))
	Sim.run_until(200.0)
	print("[separator] source=%d sink=%d (期待 sink≈2×source)" % [
		editor.ctx.source.created, editor.ctx.sink.total])

	# 9) Combiner（3→1, WIP減）
	editor.rebuild(_mini_model("Combiner", {"batch_size": 3}))
	Sim.run_until(200.0)
	print("[combiner] source=%d sink=%d (期待 sink≈source/3)" % [
		editor.ctx.source.created, editor.ctx.sink.total])

	# 10) セキュリティ：allow_scripts=false でコード実行しない
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
			"params": {"interarrival": {"type": "const", "a": 5.0}},
			"script": "extends LogicBase\nfunc on_create(item):\n\tpass\n"}],
		"connections": [],
	}, false)
	print("[security] allow=false: logic_null=%s script保持=%d文字" % [
		str(editor.ctx.source.logic == null), editor.ctx.source.script_source.length()])

	# 10b) スクリプトのエラー報告（行番号つき本文＋ガイド）
	var _serr_obj = editor.ctx.source
	# (a) extends 無し → ok=false, error_line 推定あり, 行番号本文＋ガイド出力
	Scripts.clear_log()
	var r_noext: Dictionary = Scripts.compile("func on_entry(item):\n\tpass\n", _serr_obj)
	var noext_dump := false
	var noext_guide := false
	for _l in Scripts.logs:
		var _s := str(_l)
		if _s.find("1| ") != -1:
			noext_dump = true
		if _s.find("確認してください") != -1:
			noext_guide = true
	# (b) 未定義変数参照（extends あり）→ ok=false, 行番号本文出力
	Scripts.clear_log()
	var r_undef: Dictionary = Scripts.compile(
		"extends LogicBase\nfunc process_time():\n\treturn zzz_undefined_ident\n", _serr_obj)
	var undef_dump := false
	for _l2 in Scripts.logs:
		if str(_l2).find("| ") != -1:
			undef_dump = true
			break
	# (c) 正常スクリプトは従来通り成功
	var r_good: Dictionary = Scripts.compile(Scripts.DEFAULT_TEMPLATE, _serr_obj)
	var serr_ok := (not bool(r_noext.get("ok", true))) and noext_dump and noext_guide \
		and (not bool(r_undef.get("ok", true))) and undef_dump and bool(r_good.get("ok", false))
	print("[script-err] noext_ok=%s eline=%d dump=%s guide=%s | undef_ok=%s dump=%s | good_ok=%s | ok=%s" % [
		str(bool(r_noext.get("ok", true))), int(r_noext.get("error_line", -1)),
		str(noext_dump), str(noext_guide),
		str(bool(r_undef.get("ok", true))), str(undef_dump),
		str(bool(r_good.get("ok", false))), str(serr_ok)])

	# 11) 既定モデルへ戻す（保存則・warmup決定論の検証用）
	editor.rebuild(io.default_model())

	# [conserve] Σsource.created == Σsink.total + Sim.wip（warmup=0）
	Sim.seed = 12345; Sim.warmup = 0.0
	Sim.reset_sim(); Sim.run_until(1200.0)
	var ck: Dictionary = Sim.collect_kpi()
	print("[conserve] created=%d sink=%d wip=%d ok=%s" % [
		ck.created, ck.out, Sim.wip, str(ck.created == ck.out + Sim.wip)])

	# [warmup-det] warmup=300 で同一シード2回の (sink集計total/leadtime) が完全一致
	var w1 := _one_run_agg(12345, 300.0, 1800.0)
	var w2 := _one_run_agg(12345, 300.0, 1800.0)
	print("[warmup-det] warmup=300 run1=%s run2=%s identical=%s" % [w1, w2, str(w1 == w2)])

	# [sink-trigger] Sink の on_entry スクリプトが実際に発火するか
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 5.0}, "type_count": 1}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [5, 0, 0],
				"script": "extends LogicBase\nfunc on_entry(item):\n\tsim.log(\"SINK_ENTRY\")\n"},
		],
		"connections": [["s", "k"]],
	}, true)
	Scripts.clear_log()
	Sim.run_until(100.0)
	var fires := 0
	for line in Scripts.logs:
		if "SINK_ENTRY" in line:
			fires += 1
	print("[sink-trigger] on_entry発火=%d fired=%s" % [fires, str(fires > 0)])

	# [script-rng] 設備別に独立した script 乱数ストリーム（A が引いても B の系列は不変）
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "A", "type": "Source", "name": "A", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 5.0}, "type_count": 1}},
			{"id": "B", "type": "Sink", "name": "B", "pos": [5, 0, 0]},
		],
		"connections": [["A", "B"]],
	}, true)
	var oa = editor.ctx.registry["A"]
	var ob = editor.ctx.registry["B"]
	Rng.reset(999)
	Scripts.api.current_obj = ob
	var b_first: float = Scripts.api.rand(0.0, 1.0)   # B 単独の初回乱数
	Rng.reset(999)
	Scripts.api.current_obj = oa
	Scripts.api.rand(0.0, 1.0)                         # A が2回引く
	Scripts.api.rand(0.0, 1.0)
	Scripts.api.current_obj = ob
	var b_again: float = Scripts.api.rand(0.0, 1.0)    # B の初回乱数（A の消費に影響されない）
	Scripts.api.current_obj = null
	var per_obj: bool = Rng.stream("A:script") != Rng.stream("B:script")
	print("[script-rng] B_unaffected=%s per_obj_stream=%s (b1=%.6f b2=%.6f)" % [
		str(is_equal_approx(b_first, b_again)), str(per_obj), b_first, b_again])

	# [ci] 実験CIが Student の t 分布ベース（n=5→df=4→t=2.776 で正規1.96より大きい）
	var ci_arr := [1.0, 2.0, 3.0, 4.0, 5.0]
	var ci_t: float = Sim._ci95(ci_arr)
	var sd_demo: float = sqrt(2.5)                     # [1..5] の標本標準偏差
	var ci_norm: float = 1.96 * sd_demo / sqrt(5.0)
	print("[ci] n=5 ci_t=%.4f ci_norm(1.96)=%.4f t_based=%s thr_ci=%.3f" % [
		ci_t, ci_norm, str(ci_t > ci_norm), res.thr_ci])

	# [dist] 新規分布の標本平均が理論平均に近いこと（固定rng・20000標本, 相対誤差<5%）
	var drng := Rng.stream("test")
	var dN: int = 20000
	# lognormal: 実尺度平均 a を入力 → 理論平均 = a
	var d_ln := {"type": "lognormal", "a": 5.0, "b": 2.0}
	var m_ln: float = _dist_mean(d_ln, drng, dN)
	var ok_ln: bool = _rel_err(m_ln, 5.0) < 0.05
	# weibull: k=2, λ=3 → 平均 = λ*Γ(1.5) = 3*0.8862269 = 2.658681
	var d_wb := {"type": "weibull", "a": 2.0, "b": 3.0}
	var th_wb: float = 3.0 * 0.8862269254527580
	var m_wb: float = _dist_mean(d_wb, drng, dN)
	var ok_wb: bool = _rel_err(m_wb, th_wb) < 0.05
	# gamma: k=2.5, θ=2 → 平均 = kθ = 5.0
	var d_gm := {"type": "gamma", "a": 2.5, "b": 2.0}
	var m_gm: float = _dist_mean(d_gm, drng, dN)
	var ok_gm: bool = _rel_err(m_gm, 5.0) < 0.05
	# empirical(重み付き): 値[1,2,3] 重み[1,2,1] → 平均 = 8/4 = 2.0
	var d_em := {"type": "empirical", "a": [1.0, 2.0, 3.0], "b": [1.0, 2.0, 1.0]}
	var m_em: float = _dist_mean(d_em, drng, dN)
	var ok_em: bool = _rel_err(m_em, 2.0) < 0.05
	var dist_all: bool = ok_ln and ok_wb and ok_gm and ok_em
	print("[dist] all=%s lognormal=%.3f(th5.000) weibull=%.3f(th%.3f) gamma=%.3f(th5.000) empirical=%.3f(th2.000)" % [
		str(dist_all), m_ln, m_wb, th_wb, m_gm, m_em])

	# [op-nohome] 帰投廃止：移動時間が現在位置基準／解放は即available／論理位置を保持
	var op_nh := Operator.new()
	op_nh.home = Vector3(50, 0, 0)
	op_nh.logical_pos = Vector3(2, 0, 0)   # ホームから遠い作業位置に居る
	op_nh.move_speed = 5.0
	var tt_from_pos: float = op_nh.travel_time(Vector3(3, 0, 0))   # 現在位置基準 ≈ 0.2
	var tt_from_home: float = Vector3(50, 0, 0).distance_to(Vector3(3, 0, 0)) / 5.0  # 旧仕様 ≈ 9.4
	var pos_based: bool = tt_from_pos < tt_from_home and is_equal_approx(tt_from_pos, 0.2)
	var pool_nh := OperatorPool.new()
	op_nh.available = false
	op_nh._state = "working"
	op_nh._work_start = Sim.sim_time
	pool_nh.release(op_nh)                  # 帰投せず即解放されるはず
	var immediate_avail: bool = op_nh.available == true
	var stayed: bool = op_nh.logical_pos == Vector3(2, 0, 0)  # ホームに戻らずその場に留まる
	var nohome_ok: bool = pos_based and immediate_avail and stayed
	print("[op-nohome] pos_based=%s immediate_avail=%s stayed=%s tt_pos=%.2f tt_home=%.2f ok=%s" % [
		str(pos_based), str(immediate_avail), str(stayed), tt_from_pos, tt_from_home, str(nohome_ok)])
	op_nh.free()
	pool_nh.free()

	# [transport] Source→Processor(transport_out=true)→Sink（搬送者1台）。搬送移動時間が
	# リードタイムに反映され、保存則 created==sink+wip が成立することを確認。
	Sim.visuals_enabled = false
	var lt_direct: float = _transport_run(false)   # 搬送なし（基準）
	var lt_tr: float = _transport_run(true)        # 搬送あり
	var tr_sink: int = editor.ctx.sink.total
	var ck_tr: Dictionary = Sim.collect_kpi()
	var tr_conserve: bool = ck_tr.created == ck_tr.out + Sim.wip
	var tr_effect: bool = lt_tr > lt_direct        # 搬送移動時間がリードタイムに効いている
	var transport_ok: bool = tr_sink > 0 and tr_effect and tr_conserve
	print("[transport] sink=%d lead_tr=%.2f lead_direct=%.2f travel_effect=%s conserve=%s ok=%s" % [
		tr_sink, lt_tr, lt_direct, str(tr_effect), str(tr_conserve), str(transport_ok)])

	# [tr-gen] 搬送タスク一般化：capacity=2 / load_time=1 / unload_time=1 / 優先度差 / waypoint1点。
	# 4 発生元→1 送り先を 1 台（capacity=2）で運ぶ。複数積載(バッチ2)・積降時間・経路が移動時間へ
	# 反映(直行より長リード)・優先度降順サービス(バッチ内非増加)・保存則、を確認。
	var tg_feat: Dictionary = _trgen_run(true)    # 一般化フル（load/unload/waypoint 有効）
	var tg_base: Dictionary = _trgen_run(false)   # 直行・積降0（基準）
	var tg_conserve: bool = bool(tg_feat.conserve)
	var tg_sink_ok: bool = int(tg_feat.sink) > 0
	var tg_batched: bool = int(tg_feat.max_batch) == 2          # capacity=2 のバッチ積載が発生
	var tg_prio_ok: bool = bool(tg_feat.all_desc)              # 各バッチが優先度降順（=優先度順サービス）
	# 待ち行列の取り出し順を直接検証（priority 降順 → seq 昇順の決定的タイブレーク）。
	var tg_pool := TransportPool.new()
	tg_pool._waiting = [
		{"priority": 1, "seq": 0, "dest": "X"},
		{"priority": 3, "seq": 1, "dest": "X"},
		{"priority": 2, "seq": 2, "dest": "X"},
		{"priority": 3, "seq": 3, "dest": "X"},
	]
	var tg_order: Array = []
	while tg_pool._waiting.size() > 0:
		var pidx: int = tg_pool._pick_index()
		tg_order.append(int(tg_pool._waiting[pidx].get("priority", 0)))
		tg_pool._waiting.remove_at(pidx)
	tg_pool.free()
	var tg_order_ok: bool = tg_order == [3, 3, 2, 1]   # 高優先→低優先、同値は seq 昇順
	var tg_travel_ok: bool = float(tg_feat.lead) > float(tg_base.lead)  # 積降+経路で直行より長い
	var trgen_ok: bool = tg_conserve and tg_sink_ok and tg_batched and tg_prio_ok \
			and tg_order_ok and tg_travel_ok
	print("[tr-gen] sink=%d max_batch=%d prio_desc=%s prio_order=%s lead_feat=%.2f lead_base=%.2f travel_effect=%s conserve=%s ok=%s" % [
		int(tg_feat.sink), int(tg_feat.max_batch), str(tg_prio_ok), str(tg_order_ok),
		float(tg_feat.lead), float(tg_base.lead), str(tg_travel_ok), str(tg_conserve), str(trgen_ok)])

	# [schedule] Source 到着スケジュール：前半高レート/後半低レートで生成数比が期待通り。
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1,
					"arrival_schedule": [
						{"from": 0.0, "interarrival": {"type": "const", "a": 2.0}},
						{"from": 100.0, "interarrival": {"type": "const", "a": 20.0}}]}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [5, 0, 0]},
		],
		"connections": [["s", "k"]],
	}, true)
	Sim.run_until(100.0)
	var sch_front: int = editor.ctx.source.created
	Sim.run_until(200.0)
	var sch_back: int = editor.ctx.source.created - sch_front
	var sch_ok: bool = sch_front > sch_back and sch_back > 0
	print("[schedule] front(高レート)=%d back(低レート)=%d front>back=%s" % [
		sch_front, sch_back, str(sch_ok)])

	# [shift] on/off シフト作業者：off 区間で新規加工が始まらない（作業者稼働に隙間）。
	editor.rebuild({
		"seed": 1, "warmup": 0,
		"operators": [{"name": "Op", "home": [5, 0, 1.2],
			"shift": [{"on": 0.0, "off": 50.0}], "shift_period": 100.0}],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 3.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 2.0}, "needs_operator": true,
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	Sim.run_until(50.0)
	var sh_on: int = editor.ctx.sink.total          # 稼働区間 [0,50) の完成数
	Sim.run_until(99.0)
	var sh_off: int = editor.ctx.sink.total - sh_on # off区間 [50,99) の完成数（新規なし）
	var sh_ok: bool = sh_on >= 5 and sh_off <= 1
	print("[shift] on区間完成=%d off区間完成=%d 新規停止=%s" % [
		sh_on, sh_off, str(sh_ok)])

	# [calendar-down] mtbf_basis="calendar" はアイドル時間があっても down を経験する。
	# 稼働時間ベース(operating)ではアイドル中は故障が来ないため、down が大きく異なる。
	var cd_cal: Dictionary = _calendar_down_run("calendar")
	var cd_op: Dictionary = _calendar_down_run("operating")
	var cal_idle: float = float(cd_cal.get("idle", 0.0))
	var cal_down: float = float(cd_cal.get("down", 0.0))
	var op_down: float = float(cd_op.get("down", 0.0))
	var cal_ok: bool = cal_down > 0.0 and cal_idle > 0.0 and cal_down > op_down
	print("[calendar-down] calendar: down=%.0f idle=%.0f | operating: down=%.0f | calendar_experiences_down=%s" % [
		cal_down, cal_idle, op_down, str(cal_ok)])

	# [scenario] シナリオ比較実験(CRN)：interarrival a=4.0 と a=2.0 を reps=4 で比較。
	# 低interarrival(=高到着率)側のスループットが高く、対比較CIが算出され、
	# CRNで同一 i のシードが両シナリオで一致していることを確認する。
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "exp", "a": 4.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 1.0},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	var sc_defs := [
		{"name": "hi_ia", "overrides": {"s": {"interarrival": {"type": "exp", "a": 4.0}}}},
		{"name": "lo_ia", "overrides": {"s": {"interarrival": {"type": "exp", "a": 2.0}}}},
	]
	var sc_res: Dictionary = Sim.run_scenarios(sc_defs, 4, 1800.0, 0.0, 700)
	var thr_hi: float = sc_res.scenarios[0].thr_mean   # a=4.0（低到着率）
	var thr_lo: float = sc_res.scenarios[1].thr_mean   # a=2.0（高到着率）
	var thr_higher: bool = thr_lo > thr_hi             # 低interarrival側が高スループット
	var has_ci: bool = sc_res.has("compare")
	var d_mean: float = sc_res.compare.thr_d_mean if has_ci else 0.0
	var d_ci: float = sc_res.compare.thr_d_ci if has_ci else 0.0
	# CRN: 期待シードが base_seed+i で、run_scenarios が両シナリオに同じ列を使うこと
	var seeds_ok: bool = sc_res.seeds == [700, 701, 702, 703]
	# Source.interarrival が実験後に元(a=4.0)へ復元されているか
	var restored: bool = float(editor.ctx.registry["s"].get_params().interarrival.a) == 4.0
	var scenario_ok: bool = thr_higher and has_ci and seeds_ok and restored
	print("[scenario] thr(a=4.0)=%.1f thr(a=2.0)=%.1f lo_ia_higher=%s Δthr=%.2f±%.2f crn_seeds=%s restored=%s ok=%s" % [
		thr_hi, thr_lo, str(thr_higher), d_mean, d_ci, str(seeds_ok), str(restored), str(scenario_ok)])

	# [scenario-gen] シナリオ掃引の一般化（任意パラメータ×任意値）：
	# Processor P の process_time.a を [4,6,8] の3値で run_scenarios(reps=3) 実行。
	# Source を高到着率(const a=1.0)にして P をボトルネックにするので、
	# process_time 増加でスループットが単調減少する。各シナリオでCIが算出され、
	# 実行後に process_time.a が元(5.0)へ復元されることを確認する。
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 1.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 5.0},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	var sg_obj = editor.ctx.registry["p"]
	var sg_vals := [4.0, 6.0, 8.0]
	# UI と同じ生成器で掃引シナリオを構築（process_time.a のみ差し替え）
	var sg_defs: Array = Sim.build_sweep_scenarios("p", "process_time.a", sg_vals, sg_obj.get_params())
	var sg_res: Dictionary = Sim.run_scenarios(sg_defs, 3, 1800.0, 0.0, 900)
	var sg_thr: Array = []
	var sg_has_ci: bool = true
	for sc in sg_res.scenarios:
		sg_thr.append(sc.thr_mean)
		if not sc.has("thr_ci"):
			sg_has_ci = false
	var sg_n_ok: bool = sg_res.scenarios.size() == 3
	var sg_mono: bool = sg_n_ok and sg_thr[0] > sg_thr[1] and sg_thr[1] > sg_thr[2]
	# 実行後、process_time.a が元(5.0)へ復元されているか
	var sg_restored: bool = float(editor.ctx.registry["p"].get_params().process_time.a) == 5.0
	var sg_ok: bool = sg_mono and sg_has_ci and sg_n_ok and sg_restored
	print("[scenario-gen] thr(a=4)=%.1f thr(a=6)=%.1f thr(a=8)=%.1f monotone_down=%s n=%d ci_ci=[%.2f,%.2f,%.2f] restored=%s ok=%s" % [
		sg_thr[0], sg_thr[1], sg_thr[2], str(sg_mono), sg_res.scenarios.size(),
		sg_res.scenarios[0].thr_ci, sg_res.scenarios[1].thr_ci, sg_res.scenarios[2].thr_ci,
		str(sg_restored), str(sg_ok)])

	# ============================================================
	# 機能の直積（calendar故障 × setup × 作業者 × 搬送）を実際に踏む組合せテスト。
	# いずれもクラッシュせず保存則 created==Σsink+wip が成立することを確認する。
	# ============================================================

	# [cal-setup] calendar故障(mtbf=8/mttr=4) と setup(=5) を両方有効、品種2種で段取り発生。
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 6.0}, "type_count": 2}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 4.0},
					"mtbf": {"type": "const", "a": 8.0}, "mtbf_basis": "calendar",
					"mttr": {"type": "const", "a": 4.0},
					"setup_time": {"type": "const", "a": 5.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	Sim.run_until(2000.0)
	var cs_p = editor.ctx.registry.get("p", null)
	var cs_dur: Dictionary = cs_p.state_durations() if cs_p != null else {}
	var cs_sink: int = editor.ctx.sink.total
	var cs_cons: bool = _conserve_ok()
	# 恒等式: Σ状態時間==経過(=down中もbusy/idleが二重計上されない)。
	var cs_id: bool = cs_p != null and _state_identity_ok(cs_p, Sim.sim_time)
	var cs_ok: bool = cs_sink > 0 and cs_cons and cs_id and float(cs_dur.get("down", 0.0)) > 0.0 and float(cs_dur.get("setup", 0.0)) > 0.0
	print("[cal-setup] sink=%d setup=%.0f down=%.0f conserve=%s identity=%s ok=%s" % [
		cs_sink, float(cs_dur.get("setup", 0.0)), float(cs_dur.get("down", 0.0)), str(cs_cons), str(cs_id), str(cs_ok)])

	# [cal-op] calendar故障 かつ needs_operator=true（作業者1名）。作業者リークが無いこと。
	editor.rebuild({
		"seed": 1, "warmup": 0,
		"operators": [{"name": "Op", "home": [5, 0, 1.2]}],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 6.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 3.0}, "needs_operator": true,
					"mtbf": {"type": "const", "a": 8.0}, "mtbf_basis": "calendar",
					"mttr": {"type": "const", "a": 4.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	Sim.run_until(2000.0)
	var co_avail: int = editor.ctx.pool.available_count()
	var co_total: int = editor.ctx.pool.operators.size()
	var co_sink: int = editor.ctx.sink.total
	var co_cons: bool = _conserve_ok()
	var co_p = editor.ctx.registry.get("p", null)
	var co_id: bool = co_p != null and _state_identity_ok(co_p, Sim.sim_time)
	# no_leak 強化(fable5 e): デバッグカウンタで到着(dispatch)と解放(release)を厳密突合。
	# outstanding = dispatch - release は「今稼働へ出ている作業者数」。シフト無しなので
	# available_count() == total - outstanding が厳密に成立する必要がある（会計恒等式）。
	# また dispatch>=1 かつ release>=1 で「割当も解放も現に起きている」ことを担保。
	var co_disp: int = editor.ctx.pool.dispatch_count
	var co_rel: int = editor.ctx.pool.release_count
	var co_outstanding: int = co_disp - co_rel
	var co_balance: bool = co_avail == co_total - co_outstanding \
		and co_outstanding >= 0 and co_outstanding <= co_total \
		and co_disp >= 1 and co_rel >= 1
	var co_ok: bool = co_sink > 0 and co_cons and co_id and co_balance
	print("[cal-op] sink=%d avail=%d/%d dispatch=%d release=%d outstanding=%d balance=%s conserve=%s identity=%s no_leak=%s" % [
		co_sink, co_avail, co_total, co_disp, co_rel, co_outstanding, str(co_balance), str(co_cons), str(co_id), str(co_ok)])

	# [tr-cal] transport_out=true かつ calendar故障（搬送者1台）。down>0（idleに誤計上されない）。
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": [{"name": "T1", "home": [10, 0, 0]}],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 5.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "const", "a": 2.0},
					"mtbf": {"type": "const", "a": 8.0}, "mtbf_basis": "calendar",
					"mttr": {"type": "const", "a": 4.0}, "transport_out": true}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [24, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	Sim.run_until(2000.0)
	var tc_p = editor.ctx.registry.get("p", null)
	var tc_dur: Dictionary = tc_p.state_durations() if tc_p != null else {}
	var tc_down: float = float(tc_dur.get("down", 0.0))
	var tc_sink: int = editor.ctx.sink.total
	var tc_cons: bool = _conserve_ok()
	# 恒等式: down が idle/waiting へ誤計上されず Σ==経過 が成立すること。
	var tc_id: bool = tc_p != null and _state_identity_ok(tc_p, Sim.sim_time)
	var tc_ok: bool = tc_sink > 0 and tc_cons and tc_id and tc_down > 0.0
	print("[tr-cal] sink=%d down=%.0f idle=%.0f conserve=%s identity=%s ok=%s" % [
		tc_sink, tc_down, float(tc_dur.get("idle", 0.0)), str(tc_cons), str(tc_id), str(tc_ok)])

	# [intx-all] calendar故障 + setup + needs_operator + transport_out を全部同時に有効化。
	editor.rebuild({
		"seed": 1, "warmup": 0,
		"operators": [{"name": "Op", "home": [10, 0, 1.2]}],
		"transporters": [{"name": "T1", "home": [10, 0, 0]}],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 6.0}, "type_count": 2}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "const", "a": 4.0}, "needs_operator": true,
					"mtbf": {"type": "const", "a": 8.0}, "mtbf_basis": "calendar",
					"mttr": {"type": "const", "a": 4.0},
					"setup_time": {"type": "const", "a": 5.0}, "transport_out": true}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [24, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	Sim.run_until(3000.0)
	var ix_p = editor.ctx.registry.get("p", null)
	var ix_dur: Dictionary = ix_p.state_durations() if ix_p != null else {}
	var ix_sink: int = editor.ctx.sink.total
	var ix_cons: bool = _conserve_ok()
	var ix_avail: int = editor.ctx.pool.available_count()
	var ix_id: bool = ix_p != null and _state_identity_ok(ix_p, Sim.sim_time)
	# 作業者会計恒等式（シフト無し）: available == total - (dispatch - release)。
	var ix_out: int = editor.ctx.pool.dispatch_count - editor.ctx.pool.release_count
	var ix_bal: bool = ix_avail == editor.ctx.pool.operators.size() - ix_out and ix_out >= 0
	var ix_ok: bool = ix_sink > 0 and ix_cons and ix_id and ix_bal \
		and ix_avail >= 0 and ix_avail <= editor.ctx.pool.operators.size()
	print("[intx-all] sink=%d setup=%.0f down=%.0f avail=%d outstanding=%d conserve=%s identity=%s balance=%s ok=%s" % [
		ix_sink, float(ix_dur.get("setup", 0.0)), float(ix_dur.get("down", 0.0)),
		ix_avail, ix_out, str(ix_cons), str(ix_id), str(ix_bal), str(ix_ok)])

	# [tr-util] 搬送ミニモデルで Transporter.utilization()>0 を確認。
	_transport_run(true)
	var tu_util: float = 0.0
	if editor.ctx.transporters.size() > 0:
		tu_util = editor.ctx.transporters[0].utilization()
	var tu_ok: bool = tu_util > 0.0
	print("[tr-util] utilization=%.3f ok=%s" % [tu_util, str(tu_ok)])

	# [res-api] 資源編集API：搬送者±・シフト一括・ディスパッチ規則。
	# 既定(fifo)経路の determinism 不変、nearest でも保存則が成立することを確認。
	editor.rebuild({
		"seed": 1, "warmup": 0,
		"operators": [{"name": "Op1", "home": [5, 0, 1.2]}, {"name": "Op2", "home": [5, 0, -1.2]}],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 4.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 3.0}, "needs_operator": true,
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	# 搬送者 add → remove で ctx.transporters が増減
	var ra_t0: int = editor.ctx.transporters.size()
	editor.add_transporter()
	var ra_t1: int = editor.ctx.transporters.size()
	editor.remove_transporter()
	var ra_t2: int = editor.ctx.transporters.size()
	var ra_tr_ok: bool = ra_t1 == ra_t0 + 1 and ra_t2 == ra_t0
	# 全作業者へ共通シフトを一括適用 → operator.shift に反映
	editor.set_operator_shift(0.0, 40.0, 100.0)
	var ra_op = editor.ctx.operators[0] if editor.ctx.operators.size() > 0 else null
	var ra_shift_ok: bool = ra_op != null and not ra_op.shift.is_empty() \
		and float(ra_op.shift[0].get("off", 0.0)) == 40.0 and ra_op.shift_period == 100.0
	editor.set_operator_shift(0.0, 0.0, 0.0)   # 常時稼働へ戻す（以降の判定に影響させない）
	# fifo 決定論（既定・不変）：同一シードで2回完全一致
	var ra_f1: String = _one_run(2024, 500.0)
	var ra_f2: String = _one_run(2024, 500.0)
	var ra_det_ok: bool = ra_f1 == ra_f2
	# nearest 規則：走行がクラッシュせず保存則 created==Σsink+wip が成立
	editor.set_dispatch_rule("nearest")
	Sim.seed = 2024; Sim.warmup = 0.0
	Sim.reset_sim(); Sim.run_until(500.0)
	var ra_near_cons: bool = _conserve_ok()
	var ra_near_sink: int = editor.ctx.sink.total
	editor.set_dispatch_rule("fifo")
	var res_api_ok: bool = ra_tr_ok and ra_shift_ok and ra_det_ok and ra_near_cons and ra_near_sink > 0
	print("[res-api] tr:%d→%d→%d(%s) shift_set=%s fifo_det=%s nearest_sink=%d conserve=%s ok=%s" % [
		ra_t0, ra_t1, ra_t2, str(ra_tr_ok), str(ra_shift_ok), str(ra_det_ok),
		ra_near_sink, str(ra_near_cons), str(res_api_ok)])

	# ============================================================
	# [cal-blocked] calendar故障 Processor が blocked レグを実際に踏む構成（fable5 (1)）。
	# 下流を 容量1 Queue → 低速 Processor2(ボトルネック) → Sink とし、Q1 が詰まると
	# 上流 P1 が blocked を経験する。長め(2500s)に走らせ、クラッシュ無し・保存則・
	# 状態時間恒等式・down 中も blocked/idle 表示が壊れない(down>0 かつ blocked>0)を検査。
	editor.rebuild({
		"seed": 7, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P1", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 3.0},
					"mtbf": {"type": "const", "a": 8.0}, "mtbf_basis": "calendar",
					"mttr": {"type": "const", "a": 4.0}}},
			{"id": "q", "type": "Queue", "name": "Q1", "pos": [10, 0, 0],
				"params": {"capacity": 1}},
			{"id": "p2", "type": "Processor", "name": "P2", "pos": [15, 0, 0],
				"params": {"process_time": {"type": "const", "a": 6.0},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [20, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "q"], ["q", "p2"], ["p2", "k"]],
	}, true)
	Sim.run_until(2500.0)
	var cb_p = editor.ctx.registry.get("p", null)
	var cb_dur: Dictionary = cb_p.state_durations() if cb_p != null else {}
	var cb_down: float = float(cb_dur.get("down", 0.0))
	var cb_blocked: float = float(cb_dur.get("blocked", 0.0))
	var cb_sink: int = editor.ctx.sink.total
	var cb_cons: bool = _conserve_ok()
	var cb_id: bool = cb_p != null and _state_identity_ok(cb_p, Sim.sim_time)
	var cb_ok: bool = cb_sink > 0 and cb_cons and cb_id and cb_down > 0.0 and cb_blocked > 0.0
	print("[cal-blocked] sink=%d down=%.0f blocked=%.0f idle=%.0f busy=%.0f conserve=%s identity=%s ok=%s" % [
		cb_sink, cb_down, cb_blocked, float(cb_dur.get("idle", 0.0)), float(cb_dur.get("busy", 0.0)),
		str(cb_cons), str(cb_id), str(cb_ok)])

	# ============================================================
	# 外部真値突合スイート（fable5 (3): 自己参照でない理論値突合）。
	# 乱数はテスト内 Rng を用い決定的。理論式は GDScript で自前計算。
	# ============================================================

	# [mm1] M/M/1。λ=0.8, μ=1.0 → ρ=0.8。理論 Lq=ρ²/(1-ρ)=3.2, Wq=Lq/λ=4.0, util=ρ=0.8。
	# warmup 後に reps レプリケーションを実行し、Lq(Queue.avg_length)・Wq(Queue.avg_wait)・
	# util(Processor.utilization) の平均を理論値と突合（相対誤差<10% もしくは理論値がCI内）。
	var mm1_lam: float = 0.8
	var mm1_mu: float = 1.0
	_build_mm1(100000, 1.0 / mm1_lam, 1.0 / mm1_mu)
	var mm1: Dictionary = await _mm_replicate(6, 4000.0, 30000.0, 33001, "q", ["p"])
	var mm1_rho: float = mm1_lam / mm1_mu
	var mm1_lq_th: float = mm1_rho * mm1_rho / (1.0 - mm1_rho)
	var mm1_wq_th: float = mm1_lq_th / mm1_lam
	var mm1_util_th: float = mm1_rho
	var mm1_util_ok: bool = _theory_match(mm1.util_mean, mm1.util_ci, mm1_util_th, 0.10)
	var mm1_lq_ok: bool = _theory_match(mm1.lq_mean, mm1.lq_ci, mm1_lq_th, 0.10)
	var mm1_wq_ok: bool = _theory_match(mm1.wq_mean, mm1.wq_ci, mm1_wq_th, 0.10)
	var mm1_ok: bool = mm1_util_ok and mm1_lq_ok and mm1_wq_ok
	print("[mm1] util sim=%.3f th=%.3f(%s) | Lq sim=%.3f±%.3f th=%.3f(%s) | Wq sim=%.3f±%.3f th=%.3f(%s) ok=%s" % [
		mm1.util_mean, mm1_util_th, str(mm1_util_ok),
		mm1.lq_mean, mm1.lq_ci, mm1_lq_th, str(mm1_lq_ok),
		mm1.wq_mean, mm1.wq_ci, mm1_wq_th, str(mm1_wq_ok), str(mm1_ok)])

	# [mmc] M/M/c（c=2, 1 Queue→2並列 Processor）。λ=1.5, μ=1.0 → a=λ/μ=1.5, ρ=a/c=0.75。
	# util 突合を必須（sim=平均サーバ稼働率≈ρ）。Lq は Erlang-C 反復計算による理論値と突合（参考）。
	var mmc_lam: float = 1.5
	var mmc_mu: float = 1.0
	var mmc_c: int = 2
	_build_mmc(100000, 1.0 / mmc_lam, 1.0 / mmc_mu)
	var mmc: Dictionary = await _mm_replicate(6, 4000.0, 30000.0, 44001, "q", ["p1", "p2"])
	var mmc_rho: float = (mmc_lam / mmc_mu) / float(mmc_c)
	var mmc_lq_th: float = _mmc_lq(mmc_c, mmc_lam, mmc_mu)
	var mmc_util_th: float = mmc_rho
	var mmc_util_ok: bool = _theory_match(mmc.util_mean, mmc.util_ci, mmc_util_th, 0.10)
	var mmc_lq_ok: bool = _theory_match(mmc.lq_mean, mmc.lq_ci, mmc_lq_th, 0.15)
	var mmc_stable: bool = mmc.thr_mean > 0.0
	var mmc_ok: bool = mmc_util_ok and mmc_stable   # util 必須。Lq は参考(できれば)。
	print("[mmc] c=%d util sim=%.3f th=%.3f(%s) | Lq sim=%.3f±%.3f th=%.3f(erlangC,%s) stable=%s ok=%s" % [
		mmc_c, mmc.util_mean, mmc_util_th, str(mmc_util_ok),
		mmc.lq_mean, mmc.lq_ci, mmc_lq_th, str(mmc_lq_ok), str(mmc_stable), str(mmc_ok)])

	# ============================================================
	# [conv-accum] スロット式アキュムレーションコンベヤの詰まり伝播。
	# Source(高到着)→Conveyor(capacity=5)→容量1 Queue→低速Processor(=低速Sink化)→Sink。
	# 低速Processorがボトルネックとなり出口を詰まらせ、コンベヤが上限(=5)まで蓄積し、
	# state=blocked・占有恒等式(occupancy==capacity)・保存則を確認。その後長く走らせ、
	# 低速処理が進むことで下流が回復しアイテムが流れる（sink>0）ことを確認する。
	Sim.visuals_enabled = false
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 1.0}, "type_count": 1}},
			{"id": "conv", "type": "Conveyor", "name": "Conv", "pos": [5, 0, 0],
				"params": {"travel_time": 5.0, "capacity": 5,
					"start": [3, 0, 0], "end": [9, 0, 0]}},
			{"id": "q", "type": "Queue", "name": "Q", "pos": [11, 0, 0],
				"params": {"capacity": 1}},
			{"id": "p2", "type": "Processor", "name": "P2", "pos": [15, 0, 0],
				"params": {"process_time": {"type": "const", "a": 20.0},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [20, 0, 0]},
		],
		"connections": [["s", "conv"], ["conv", "q"], ["q", "p2"], ["p2", "k"]],
	}, true)
	var ca_conv = editor.ctx.registry.get("conv", null)
	var ca_cap: int = ca_conv.capacity_effective() if ca_conv != null else -1
	# 蓄積フェーズ: 出口が詰まりコンベヤが上限まで埋まる時刻まで進める。
	Sim.run_until(35.0)
	var ca_occ: int = ca_conv.occupancy() if ca_conv != null else -1
	var ca_state: String = ca_conv.state if ca_conv != null else "?"
	var ca_full: bool = ca_occ == ca_cap and ca_cap == 5           # 占有恒等式（上限=capacity）
	var ca_blocked: bool = ca_state == "blocked"                   # 蓄積中は blocked
	var ca_le_cap: bool = ca_occ <= ca_cap                         # 上限超過しない
	var ca_cons_block: bool = _conserve_ok()                       # 蓄積中も保存則
	# 回復フェーズ: 低速処理が進み下流が回復してアイテムが流れる。
	Sim.run_until(600.0)
	var ca_sink: int = editor.ctx.sink.total
	var ca_flowed: bool = ca_sink > 0
	var ca_cons_final: bool = _conserve_ok()
	var ca_occ2: int = ca_conv.occupancy() if ca_conv != null else -1
	var ca_le_cap2: bool = ca_occ2 <= ca_cap
	var conv_accum_ok: bool = ca_full and ca_blocked and ca_le_cap and ca_le_cap2 \
		and ca_cons_block and ca_flowed and ca_cons_final
	print("[conv-accum] cap=%d occ@block=%d state=%s full=%s blocked=%s conserve_block=%s | sink=%d flowed=%s conserve_final=%s ok=%s" % [
		ca_cap, ca_occ, ca_state, str(ca_full), str(ca_blocked), str(ca_cons_block),
		ca_sink, str(ca_flowed), str(ca_cons_final), str(conv_accum_ok)])

	# [scale] アイテム非Node化の効果検証：visuals_enabled=false で大規模モデル
	# （Source高レート→2段Processor→Sink, 総生成10万+）を run_until。
	# (1)タイムアウトせず完了 (2)保存則 conserve=true (3)所要イベント数/概算時間を出力。
	# さらに実験時に item Node が増え続けない（items_root.get_child_count() が生成総数まで
	# 膨らまない＝純データ化が効く）ことを true/値で確認する。
	Sim.visuals_enabled = false
	editor.rebuild({
		"seed": 12345, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 0.01}, "type_count": 1}},
			{"id": "p1", "type": "Processor", "name": "P1", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 0.005},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "p2", "type": "Processor", "name": "P2", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "const", "a": 0.005},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [15, 0, 0]},
		],
		"connections": [["s", "p1"], ["p1", "p2"], ["p2", "k"]],
	}, true)
	var sc_t0: int = Time.get_ticks_msec()
	Sim.run_until(1050.0)                      # 到着率100/時間単位 × 1050 ≈ 10.5万生成
	var sc_ms: int = Time.get_ticks_msec() - sc_t0
	var sc_created: int = editor.ctx.source.created
	var sc_sink: int = editor.ctx.sink.total
	var sc_events: int = Sim._seq             # 総スケジュールイベント数（run全体）
	var sc_conserve: bool = _conserve_ok()
	var sc_nodes: int = Sim.items_root.get_child_count() if Sim.items_root != null else -1
	# 純データ化: visuals_enabled=false では item Node を1つも生成しない
	# → items_root は生成総数まで膨らまない（<<created かつ ≤1）。
	var sc_no_node_growth: bool = sc_nodes < sc_created and sc_nodes <= 1
	var sc_big: bool = sc_created >= 100000    # 10万+アイテム相当を確かに生成
	var sc_completed: bool = sc_sink > 0       # タイムアウトせず流れ切った
	var scale_ok: bool = sc_big and sc_conserve and sc_no_node_growth and sc_completed
	print("[scale] created=%d sink=%d wip=%d events=%d time=%dms nodes=%d no_node_growth=%s conserve=%s completed=%s ok=%s" % [
		sc_created, sc_sink, Sim.wip, sc_events, sc_ms, sc_nodes,
		str(sc_no_node_growth), str(sc_conserve), str(sc_completed), str(scale_ok)])

	# ============================================================
	# 出力解析3種（Welch warmup推定 / 目標精度反復数 / レポート出力）
	# ============================================================
	Sim.visuals_enabled = false

	# [agv-net] AGV搬送ネットワーク（制御点グラフ＋最短経路）。発生元→目的地に直線より
	# 明確に遠回りな経路しか無いネットワークを与え、搬送移動時間が直線距離基準より長い
	# （経路に沿う）＋ある2ノードの Dijkstra 距離が手計算値(30)と一致＋保存則を確認。
	# 既定(network無し)の直行が不変（＝lead が短い直線基準）であることも確認する。
	var agv_nodes := {"A": [0, 0, 0], "B": [0, 0, 10], "C": [10, 0, 10], "D": [10, 0, 0]}
	var agv_edges := [["A", "B"], ["B", "C"], ["C", "D"]]   # A-D 直結なし → A→D は 30 の遠回り
	var agv_net := TransportNetwork.new(agv_nodes, agv_edges)
	var agv_sp: Dictionary = agv_net.shortest_path("A", "D")
	# 手計算: A→B(10)+B→C(10)+C→D(10)=30、直線 A→D=10。経路ノード列も一致。
	var agv_dij_ok: bool = is_equal_approx(float(agv_sp.dist), 30.0) \
		and agv_sp.nodes == ["A", "B", "C", "D"]
	# 位置→最寄り制御点の対応（決定的タイブレーク）。
	var agv_near_ok: bool = agv_net.nearest_node(Vector3(0.5, 0, 0.2)) == "A" \
		and agv_net.nearest_node(Vector3(9.6, 0, 0.3)) == "D"
	# ネットワーク有り/無しで同一モデルを走らせ、移動時間（リード）が遠回り分だけ延びる。
	var agv_net_res: Dictionary = _agvnet_run(true)
	var agv_dir_res: Dictionary = _agvnet_run(false)
	var agv_travel_ok: bool = float(agv_net_res.lead) > float(agv_dir_res.lead)
	var agv_cons: bool = bool(agv_net_res.conserve) and bool(agv_dir_res.conserve)
	var agv_sink_ok: bool = int(agv_net_res.sink) > 0 and int(agv_dir_res.sink) > 0
	var agv_ok: bool = agv_dij_ok and agv_near_ok and agv_travel_ok and agv_cons and agv_sink_ok
	print("[agv-net] dijkstra_AD=%.1f(=30 %s) nearest=%s lead_net=%.2f lead_direct=%.2f travel_effect=%s conserve=%s sink=%d/%d ok=%s" % [
		float(agv_sp.dist), str(agv_dij_ok), str(agv_near_ok),
		float(agv_net_res.lead), float(agv_dir_res.lead), str(agv_travel_ok),
		str(agv_cons), int(agv_net_res.sink), int(agv_dir_res.sink), str(agv_ok)])

	# [agv-cap] 辺容量を尊重する輻輳（stage2）。直線コリドー A-B-C の各辺に容量1を設定し、
	# 3台の搬送者が P(=A)→K(=C) を積載往路 A→C・空荷復路 C→A で往復する（＝単一レーンを
	# 双方向に使う正面遭遇状況）。容量1で待ちが発生し、自由流(容量INF)より明確にリードが伸びる
	# ことを確認する。あわせて (1)占有が容量を超えない（ピーク<=1）(2)保存則 (3)デッドロックせず
	# 流れ切る（sink が十分伸びる＝方向ロック+FIFOで正面デッドロックが解消される）(4)決定的
	# （同一入力2回でsink/lead一致）を true/値で確認する。容量未設定なら従来どおりバイト一致。
	var cap_free: Dictionary = _agvcap_run(INF)      # 自由流（ドーマント＝従来直行スケジュール）
	var cap_cong: Dictionary = _agvcap_run(1.0)      # 容量1で輻輳
	var cap_cong2: Dictionary = _agvcap_run(1.0)     # 決定論確認用の再実行
	var cap_congestion_ok: bool = float(cap_cong.lead) > float(cap_free.lead)
	var cap_cons: bool = bool(cap_free.conserve) and bool(cap_cong.conserve)
	var cap_live: bool = int(cap_cong.sink) >= 10 and int(cap_free.sink) > 0   # デッドロックせず流れる
	var cap_inv: bool = bool(cap_cong.inv_ok) \
		and int(cap_cong.peak_ab) <= 1 and int(cap_cong.peak_bc) <= 1          # 占有<=容量
	var cap_used: bool = int(cap_cong.peak_ab) == 1                            # ボトルネックが実占有
	var cap_det: bool = int(cap_cong.sink) == int(cap_cong2.sink) \
		and is_equal_approx(float(cap_cong.lead), float(cap_cong2.lead))
	var agv_cap_ok: bool = cap_congestion_ok and cap_cons and cap_live \
		and cap_inv and cap_used and cap_det
	print("[agv-cap] lead_cong=%.2f lead_free=%.2f congestion=%s peak_ab=%d peak_bc=%d occ_le_cap=%s sink_cong=%d sink_free=%d live=%s det=%s conserve=%s ok=%s" % [
		float(cap_cong.lead), float(cap_free.lead), str(cap_congestion_ok),
		int(cap_cong.peak_ab), int(cap_cong.peak_bc), str(cap_inv),
		int(cap_cong.sink), int(cap_free.sink), str(cap_live), str(cap_det),
		str(cap_cons), str(agv_cap_ok)])

	# [welch] 過渡が明確な充填系（空→定常でWIPが立ち上がる M/M/1 的モデル）で
	# Welch法の warmup 推定を実行。推定warmupが 0 より有意に大きく、全長より十分小さい
	# 妥当値になることを確認する。metric=wip。
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "exp", "a": 3.0}, "type_count": 1}},
			{"id": "q", "type": "Queue", "name": "Q", "pos": [5, 0, 0],
				"params": {"capacity": 9999}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "exp", "a": 2.5},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [15, 0, 0]},
		],
		"connections": [["s", "q"], ["q", "p"], ["p", "k"]],
	}, true)
	var w_run_len: float = 3600.0
	var w_est: Dictionary = Sim.estimate_warmup(8, w_run_len, 4000, "wip", 5, 60)
	# 同一入力での決定論（同じ warmup 推定値）
	var w_est2: Dictionary = Sim.estimate_warmup(8, w_run_len, 4000, "wip", 5, 60)
	var w_warm: float = w_est.warmup
	var w_significant: bool = w_warm >= w_est.bucket_dt        # 少なくとも1バケット分＝0より有意
	var w_small: bool = w_warm <= w_run_len * 0.5             # 全長より十分小さい
	var w_det: bool = is_equal_approx(w_warm, float(w_est2.warmup))
	var welch_ok: bool = w_significant and w_small and w_est.steady > 0.0 and w_det
	print("[welch] warmup=%.0f (bucket=%.0f, series_len=%d) steady_wip=%.2f trunc_b=%d significant=%s small=%s det=%s ok=%s" % [
		w_warm, w_est.bucket_dt, w_est.series_len, w_est.steady, w_est.trunc_bucket,
		str(w_significant), str(w_small), str(w_det), str(welch_ok)])

	# [repcount] 目標相対半値幅 0.03 で反復数を自動決定。min_reps以上・max_reps以下で停止、
	# 達成relhw<=target（または max到達）。同seedで同じreps数（決定的）。
	_build_mm1(9999, 3.0, 2.5)
	var rc_target: float = 0.03
	var rc: Dictionary = Sim.run_until_precision(3600.0, 0.0, 5000, rc_target, 40, 3)
	var rc2: Dictionary = Sim.run_until_precision(3600.0, 0.0, 5000, rc_target, 40, 3)
	var rc_bounds: bool = rc.reps >= 3 and rc.reps <= 40
	var rc_stop: bool = rc.reached or rc.reps == 40
	var rc_det: bool = rc.reps == rc2.reps
	var repcount_ok: bool = rc_bounds and rc_stop and rc_det
	print("[repcount] reps=%d rel_hw=%.4f target=%.3f thr=%.1f±%.1f reached=%s bounds=%s stop=%s det=%s ok=%s" % [
		rc.reps, rc.rel_hw, rc.target, rc.thr_mean, rc.thr_ci, str(rc.reached),
		str(rc_bounds), str(rc_stop), str(rc_det), str(repcount_ok)])

	# [report] レポート生成（HTML+CSV）。ファイルが生成され、HTMLに主要KPI文字列が
	# 含まれることを確認する。M/M/1 モデルを 4 レプリケーションで実験。
	_build_mm1(9999, 3.0, 2.5)
	var rep_out: Dictionary = Sim.generate_report(4, 1800.0, 0.0, 6000)
	var rep_html_ok: bool = FileAccess.file_exists(rep_out.html)
	var rep_csv_ok: bool = FileAccess.file_exists(rep_out.csv)
	var rep_kpi_ok: bool = false
	var rep_len: int = 0
	if rep_html_ok:
		var hf := FileAccess.open(rep_out.html, FileAccess.READ)
		var htxt: String = hf.get_as_text()
		hf.close()
		rep_len = htxt.length()
		rep_kpi_ok = htxt.find("スループット") >= 0 and htxt.find("稼働率") >= 0 \
			and htxt.find("Lq") >= 0
	var report_ok: bool = rep_html_ok and rep_csv_ok and rep_kpi_ok
	print("[report] html=%s(%dB) csv=%s kpi_str=%s thr=%.1f ok=%s" % [
		str(rep_html_ok), rep_len, str(rep_csv_ok), str(rep_kpi_ok),
		rep_out.res.thr_mean, str(report_ok)])

	# [gantt] 状態ガントチャート用タイムライン記録。record_timeline=ON でミニモデルを run し、
	# ある設備(Processor)のセグメントが time順・非重複で Σ(セグメント長)==経過(相対誤差<1%)、
	# record OFF(既定)では _state_log 空＝無影響、を true/値で確認する。
	Sim.visuals_enabled = true
	editor.rebuild(_mini_model("Processor", {"process_time": {"type": "const", "a": 2.0},
		"mtbf": {"type": "exp", "a": 0.0}}))
	# 記録OFF（既定）で run → _state_log は空のまま（無影響）
	Sim.set_timeline_recording(false)
	Sim.seed = 1; Sim.warmup = 0.0
	Sim.reset_sim(); Sim.run_until(200.0)
	var g_off = editor.ctx.registry.get("mid", null)
	var g_off_empty: bool = g_off != null and g_off._state_log.is_empty()
	# 記録ON にして同条件で run → セグメント記録
	Sim.set_timeline_recording(true)
	Sim.seed = 1; Sim.warmup = 0.0
	Sim.reset_sim(); Sim.run_until(200.0)
	var g_p = editor.ctx.registry.get("mid", null)
	var g_nonempty: bool = g_p != null and not g_p._state_log.is_empty()
	# 順序・非重複・被覆（進行中末尾を含む timeline_segments で Σ長==経過）
	var g_segs: Array = g_p.timeline_segments() if g_p != null else []
	var g_ordered: bool = true
	var g_sumlen: float = 0.0
	var g_prev_end: float = -INF
	for seg in g_segs:
		var s0: float = float(seg.start)
		var s1: float = float(seg.end)
		g_sumlen += s1 - s0
		if s1 < s0 or s0 < g_prev_end - 1e-6:   # 逆順 or 重複
			g_ordered = false
		g_prev_end = s1
	var g_elapsed: float = Sim.stats_elapsed()   # warmup=0 → = 経過時間(200)
	var g_sum_ok: bool = g_elapsed > 0.0 and abs(g_sumlen - g_elapsed) <= g_elapsed * 0.01
	var gantt_ok: bool = g_off_empty and g_nonempty and g_ordered and g_sum_ok
	Sim.set_timeline_recording(false)   # 後続へ影響させない
	print("[gantt] off_empty=%s on_segs=%d ordered=%s sumlen=%.3f elapsed=%.3f sum_match=%s ok=%s" % [
		str(g_off_empty), g_segs.size(), str(g_ordered), g_sumlen, g_elapsed, str(g_sum_ok), str(gantt_ok)])

	# [empirical-cont] 連続経験分布：昇順データ[1..5]から20000標本し、標本平均が
	# 理論平均（＝データ平均3.0：等間隔なので逆CDFが一様→[1,5]の中点）に近く、
	# 全標本が [min,max]=[1,5] の範囲内に収まることを確認。
	var ec_rng := Rng.stream("test")
	var ec_data: Array = [1.0, 2.0, 3.0, 4.0, 5.0]
	var ec_d := {"type": "empirical_cont", "a": ec_data}
	var ec_n: int = 20000
	var ec_sum: float = 0.0
	var ec_min: float = INF
	var ec_max: float = -INF
	for _i in range(ec_n):
		var ec_v: float = Dist.sample(ec_d, ec_rng)
		ec_sum += ec_v
		ec_min = min(ec_min, ec_v)
		ec_max = max(ec_max, ec_v)
	var ec_mean: float = ec_sum / float(ec_n)
	var ec_theory: float = 3.0
	var ec_mean_ok: bool = _rel_err(ec_mean, ec_theory) < 0.05
	var ec_range_ok: bool = ec_min >= 1.0 - 1e-9 and ec_max <= 5.0 + 1e-9
	var ec_ok: bool = ec_mean_ok and ec_range_ok
	print("[empirical-cont] n=%d mean=%.3f(th%.3f) min=%.3f max=%.3f range_ok=%s ok=%s" % [
		ec_n, ec_mean, ec_theory, ec_min, ec_max, str(ec_range_ok), str(ec_ok)])

	# [csv-import] CSV取込ヘルパの検証。到着表2列CSV→arrival_schedule形式、
	# 数値1列CSV→数値配列 が正しく得られることを true/値で確認。
	var csv_sched: Array = io.csv_to_arrival_schedule("0,5\n1800,3\n")
	var sched_ok: bool = csv_sched.size() == 2 \
		and float(csv_sched[0].get("from", -1)) == 0.0 \
		and str(csv_sched[0].get("interarrival", {}).get("type", "")) == "exp" \
		and float(csv_sched[0].get("interarrival", {}).get("a", -1)) == 5.0 \
		and float(csv_sched[1].get("from", -1)) == 1800.0 \
		and float(csv_sched[1].get("interarrival", {}).get("a", -1)) == 3.0
	var csv_vals: Array = io.csv_to_values("1\n2\n3\n")
	var vals_ok: bool = csv_vals.size() == 3 \
		and float(csv_vals[0]) == 1.0 and float(csv_vals[1]) == 2.0 and float(csv_vals[2]) == 3.0
	# ヘッダ付きCSVでも数値行のみ拾えること（頑健性）
	var csv_hdr: Array = io.csv_to_values("value\n10\n20\n")
	var hdr_ok: bool = csv_hdr.size() == 2 and float(csv_hdr[0]) == 10.0
	var csv_ok: bool = sched_ok and vals_ok and hdr_ok
	print("[csv-import] sched_n=%d sched_ok=%s vals=%s vals_ok=%s hdr_skip=%s ok=%s" % [
		csv_sched.size(), str(sched_ok), str(csv_vals), str(vals_ok), str(hdr_ok), str(csv_ok)])

	# [schema] version管理・後方互換: version/キー欠落の最小モデルを migrate/build
	# しクラッシュせず既定補完で動く。params 旧別名(cap→capacity)の正規化・往復整合も確認。
	var min_model := {
		# version / seed / warmup / operators / transporters 欠落
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 5.0}}},
			{"id": "q", "type": "Queue", "name": "Q", "pos": [3, 0, 0],
				"params": {"cap": 7}},   # 旧別名 cap → capacity
			{"id": "k", "type": "Sink", "name": "K", "pos": [6, 0, 0]},
		],
		"connections": [["s", "q"], ["q", "k"], ["k"]],   # 不正接続([\"k\"] は size<2)も混在
	}
	var mig: Dictionary = io.migrate(min_model)
	var sc_ver: int = int(mig.get("version", -1))
	var sc_defaults: bool = mig.has("seed") and mig.has("warmup") \
		and (mig.get("operators") is Array) and (mig.get("transporters") is Array) \
		and (mig.get("connections") is Array) and (mig.get("objects") is Array)
	var q_params: Dictionary = mig["objects"][1]["params"]
	var sc_alias: bool = q_params.has("capacity") and not q_params.has("cap") \
		and int(q_params["capacity"]) == 7
	# build がクラッシュせず動き、別名正規化後の容量が効く
	editor.rebuild(min_model)
	Sim.reset_sim(); Sim.run_until(100.0)
	var sc_q = editor.ctx.registry.get("q", null)
	var sc_built: bool = editor.ctx.source != null and editor.ctx.sink != null \
		and editor.ctx.sink.total > 0 and sc_q != null and int(sc_q.capacity) == 7
	# 往復(to_dict→build)で整合（object数・接続数・version が保存される）
	var d1: Dictionary = io.to_dict(editor.ctx)
	editor.rebuild(d1)
	var d2: Dictionary = io.to_dict(editor.ctx)
	var sc_round: bool = int(d1.get("version", -1)) == int(d2.get("version", -2)) \
		and d1["objects"].size() == d2["objects"].size() \
		and d1["connections"].size() == d2["connections"].size()
	var sc_ok: bool = sc_ver == 1 and sc_defaults and sc_alias and sc_built and sc_round
	print("[schema] version=%d defaults=%s alias(cap→capacity)=%s built=%s roundtrip=%s ok=%s" % [
		sc_ver, str(sc_defaults), str(sc_alias), str(sc_built), str(sc_round), str(sc_ok)])

	# [undo-cov] 名称変更(rename)→undo で名前が戻る（Editor API 経由でヘッドレス検証）
	editor.rebuild(io.default_model())
	var uc_obj = editor.ctx.registry.get("q1", null)
	var uc_ok := false
	var uc_orig := ""
	var uc_new := ""
	var uc_after := ""
	if uc_obj != null:
		editor.select(uc_obj)
		uc_orig = uc_obj.obj_name
		editor.rename_selected("Renamed Q1")
		uc_new = uc_obj.obj_name
		editor.undo()
		# undo 後は同一 id のオブジェクトを引き直す（rebuild で再生成される）
		var uc_obj2 = editor.ctx.registry.get("q1", null)
		uc_after = uc_obj2.obj_name if uc_obj2 != null else ""
		uc_ok = uc_new == "Renamed Q1" and uc_after == uc_orig and uc_orig != uc_new
	print("[undo-cov] orig=%s new=%s after_undo=%s restored=%s" % [
		uc_orig, uc_new, uc_after, str(uc_ok)])

	# [rack] ラック/倉庫ストレージ：bays=3,levels=2(容量6)。
	#   (A) モデル実行で「容量6頭打ち＋上流ブロック＋平均在庫>0＋保存則」を検証。
	#   (B) 直接操作で fifo/lifo の払い出し順差（item.id 系列）＋下流回復 payout を検証。
	Sim.visuals_enabled = false
	# (A) Source→Rack（下流なし）→ 容量6で頭打ち・上流ブロック
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
			{"id": "rk", "type": "Rack", "name": "RK", "pos": [5, 0, 0],
				"params": {"bays": 3, "levels": 2}},
		],
		"connections": [["s", "rk"]],
	}, true)
	Sim.seed = 1; Sim.warmup = 0.0
	Sim.reset_sim(); Sim.run_until(100.0)
	var rk_a = editor.ctx.registry.get("rk", null)
	var src_a = editor.ctx.registry.get("s", null)
	var ra_cap: int = rk_a.get_capacity() if rk_a != null else -1
	var ra_occ: int = rk_a.occupancy() if rk_a != null else -1
	var ra_full: bool = rk_a.is_full() if rk_a != null else false
	var ra_avg: float = rk_a.avg_inventory() if rk_a != null else 0.0
	var ra_blocked: bool = src_a != null and src_a._held != null and src_a.state == "blocked"
	var ra_conserve: bool = _conserve_ok()
	# (B) 直接操作で払い出し順を検証（下流 Queue の格納順＝払い出し順）
	var fifo_ids: Array = _rack_payout_order("fifo")
	var lifo_ids: Array = _rack_payout_order("lifo")
	var order_differ: bool = fifo_ids != lifo_ids
	var fifo_ok: bool = fifo_ids == [1, 2, 3, 4, 5, 6]
	var lifo_ok: bool = lifo_ids == [6, 5, 4, 3, 2, 1]
	var rack_ok: bool = ra_cap == 6 and ra_occ == 6 and ra_full and ra_avg > 0.0 \
		and ra_blocked and ra_conserve and order_differ and fifo_ok and lifo_ok
	print("[rack] cap=%d occ=%d full=%s avg_inv=%.2f up_block=%s conserve=%s | fifo=%s lifo=%s differ=%s | ok=%s" % [
		ra_cap, ra_occ, str(ra_full), ra_avg, str(ra_blocked), str(ra_conserve),
		str(fifo_ids), str(lifo_ids), str(order_differ), str(rack_ok)])

	# ============================================================
	# [optimize] 最適化（OptQuest相当のパラメータ格子探索）。
	# 単調性が既知の小モデルで grid 探索し、最適解が理論的期待と一致し、
	# CRN で決定的（同入力＝同結果）であることを検査する。
	#   Source(高到着 const a=1.0) → Processor(process_time.a=決定変数) → Sink。
	#   Source がボトルネックにならないよう到着を速くしておくと、process_time.a が
	#   小さいほどスループットが単調増加する。よって throughput 最大化の最適解は
	#   格子最小 process_time.a（=2.0）になるはず。
	Sim.visuals_enabled = false
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 1.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 5.0},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	var opt_dvars := [{"obj_id": "p", "param": "process_time.a", "min": 2.0, "max": 5.0, "step": 1.0}]
	var opt_obj := {"metric": "throughput", "sense": "max"}
	# grid: 4格子(2,3,4,5)。CRN base_seed=1300、reps=3。
	var opt_res: Dictionary = Sim.optimize(opt_dvars, opt_obj, "grid", 64, 3, 1800.0, 0.0, 1300)
	var opt_res2: Dictionary = Sim.optimize(opt_dvars, opt_obj, "grid", 64, 3, 1800.0, 0.0, 1300)
	var opt_best_a: float = float(opt_res.best.get("p.process_time.a", -1.0))
	var opt_n: int = int(opt_res.evaluated)
	# 期待: 最小 process_time.a（=2.0）が最適、格子4点を全評価。
	var opt_best_ok: bool = opt_best_a == 2.0
	var opt_n_ok: bool = opt_n == 4 and opt_res.history.size() == 4
	# 決定性: 同入力の再実行で best/best_obj/history が完全一致。
	var opt_det: bool = opt_res.best == opt_res2.best \
		and is_equal_approx(float(opt_res.best_obj), float(opt_res2.best_obj)) \
		and opt_res.history == opt_res2.history
	# 単調性: history のスループットが a昇順で単調減少（=aが小さいほど良い）。
	var opt_mono: bool = true
	for oi in range(opt_res.history.size() - 1):
		if float(opt_res.history[oi].obj) < float(opt_res.history[oi + 1].obj):
			opt_mono = false
	# best_obj は最小aの評価値と一致（=history先頭, a=2.0）。
	var opt_bestobj_ok: bool = opt_res.history.size() > 0 \
		and is_equal_approx(float(opt_res.best_obj), float(opt_res.history[0].obj))
	# param 復元確認: 探索後に process_time.a が元(5.0)へ戻っている。
	var opt_restored: bool = float(editor.ctx.registry["p"].get_params().process_time.a) == 5.0
	# hill 法も同じ最適解へ到達すること（近傍改善で最小aへ降りる）。
	var opt_hill: Dictionary = Sim.optimize(opt_dvars, opt_obj, "hill", 64, 3, 1800.0, 0.0, 1300)
	var opt_hill_ok: bool = float(opt_hill.best.get("p.process_time.a", -1.0)) == 2.0
	var optimize_ok: bool = opt_best_ok and opt_n_ok and opt_det and opt_mono \
		and opt_bestobj_ok and opt_restored and opt_hill_ok
	print("[optimize] best_a=%.1f(exp2.0 %s) evaluated=%d(%s) best_thr=%.1f det=%s monotone=%s hill_a=%.1f(%s) restored=%s ok=%s" % [
		opt_best_a, str(opt_best_ok), opt_n, str(opt_n_ok), float(opt_res.best_obj),
		str(opt_det), str(opt_mono), float(opt_hill.best.get("p.process_time.a", -1.0)),
		str(opt_hill_ok), str(opt_restored), str(optimize_ok)])
	# CSV(user://optimize.csv) 出力（UIボタンと同一形式）。
	_write_optimize_csv(opt_res)

	# [bg-exp] 実験のバックグラウンド化（フレーム分割コルーチン）。同一設定の実験を
	# (A)同期 run_replications と (B)フレーム分割 run_replications_async で実行し、
	# (1)結果(thr_mean/ci・各配列)がビット一致 (2)進捗が単調増加で1.0到達
	# (3)cancel_experiment で途中停止（reps<n・cancelled=true）を true/値で確認する。
	# await はイベント計算に無関係なので決定論は不変（同期版と完全一致）。
	Sim.visuals_enabled = false
	editor.rebuild({
		"seed": 12345, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "exp", "a": 3.0}, "type_count": 1}},
			{"id": "q", "type": "Queue", "name": "Q", "pos": [5, 0, 0],
				"params": {"capacity": 9999}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "exp", "a": 2.5},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [15, 0, 0]},
		],
		"connections": [["s", "q"], ["q", "p"], ["p", "k"]],
	}, true)
	var bg_reps: int = 5
	var bg_rl: float = 600.0
	var bg_seed: int = 777
	# (A) 同期実行
	var bg_a: Dictionary = Sim.run_replications(bg_reps, bg_rl, 0.0, bg_seed)
	# (B) フレーム分割実行（進捗を収集）
	var bg_prog: Array = []
	var bg_cb := func(frac, _info): bg_prog.append(float(frac))
	Sim.experiment_progress.connect(bg_cb)
	var bg_b: Dictionary = await Sim.run_replications_async(bg_reps, bg_rl, 0.0, bg_seed)
	Sim.experiment_progress.disconnect(bg_cb)
	# (1) 結果ビット一致（平均・CI・各レプリケーション配列・wip・reps）
	var bg_bit: bool = bg_a.thr_mean == bg_b.thr_mean and bg_a.thr_ci == bg_b.thr_ci \
		and bg_a.lt_mean == bg_b.lt_mean and bg_a.lt_ci == bg_b.lt_ci \
		and bg_a.throughput == bg_b.throughput and bg_a.leadtime == bg_b.leadtime \
		and bg_a.wip == bg_b.wip and int(bg_b.reps) == bg_reps
	# (2) 進捗が単調増加で 1.0 到達（レプリケーション数ぶんの emit）
	var bg_mono: bool = bg_prog.size() == bg_reps
	for pi in range(1, bg_prog.size()):
		if float(bg_prog[pi]) <= float(bg_prog[pi - 1]):
			bg_mono = false
	var bg_reach1: bool = bg_prog.size() > 0 and is_equal_approx(float(bg_prog[bg_prog.size() - 1]), 1.0)
	# (3) cancel: i>=2 完了時点で中断要求 → 次のフレーム境界で停止（reps<n・cancelled=true）
	var bg_ccb := func(_frac, info):
		if int(info.i) >= 2:
			Sim.cancel_experiment()
	Sim.experiment_progress.connect(bg_ccb)
	var bg_c: Dictionary = await Sim.run_replications_async(bg_reps, bg_rl, 0.0, bg_seed)
	Sim.experiment_progress.disconnect(bg_ccb)
	var bg_stopped: bool = bool(bg_c.get("cancelled", false)) \
		and int(bg_c.reps) >= 1 and int(bg_c.reps) < bg_reps
	var bg_ok: bool = bg_bit and bg_mono and bg_reach1 and bg_stopped and not Sim.exp_busy
	print("[bg-exp] bit_match=%s(thrM=%.6f/%.6f ci=%.6f/%.6f) mono=%s reach1=%s prog=%d cancel_reps=%d/%d cancelled=%s busy_clear=%s ok=%s" % [
		str(bg_bit), float(bg_a.thr_mean), float(bg_b.thr_mean), float(bg_a.thr_ci), float(bg_b.thr_ci),
		str(bg_mono), str(bg_reach1), bg_prog.size(), int(bg_c.reps), bg_reps,
		str(bg_stopped), str(not Sim.exp_busy), str(bg_ok)])

	# ============================================================
	# [procflow*] Process Flow 層（トークン式ロジック・オプトインの別系）の検証。
	# 既存の既定モデル（FlowObject 群）とは完全に独立。ProcessFlow.run() は内部で
	# Sim.reset_sim() を呼び共有 Sim を初期化して走らせるため、本ブロックは必ず全ての
	# 既存マーカーの後に置き、既存マーカー値へは一切干渉しない。乱数は "pf:" 接頭辞の
	# 独立ストリームのみを使うので既存キーとも衝突しない。実行後の後片付けは直下の
	# editor.rebuild(io.default_model()) が担当する（Sim を既定モデルへ戻す）。
	# ============================================================
	Sim.visuals_enabled = false

	# [procflow] 保存則: created == sunk + in_flight。有限到着(max_arrivals=300)＋資源1＋
	# 指数遅延(ρ=0.8)の同一モデルを2通りに走らせて検証する（Sim.wip は既定モデルが共有
	# カレンダー上で同時進行するため PF トークン数と一致しないので使わない）:
	#   (A) 途中打ち切り(t=150) → in_flight>0 の生きた状態で恒等式が成立することを表示。
	#   (B) 完全ドレイン(t=6000) → 全 300 トークンが sink され in_flight==0（＝トークンの
	#       漏れ/複製が無い）ことを確認。恒等式は導出上自明なので、リークを実際に捉える
	#       のはこの完全ドレイン検査である。
	var pf_cons_spec := {
		"seed": 4242,
		"resources": {"srv": 1},
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.0},
				"max_arrivals": 300, "next": "acq"},
			{"id": "acq", "type": "acquire", "resource": "srv", "next": "work"},
			{"id": "work", "type": "delay", "duration": {"type": "exp", "a": 0.8}, "next": "rel"},
			{"id": "rel", "type": "release", "resource": "srv", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	}
	var pf_kA: Dictionary = ProcessFlow.new(pf_cons_spec).run(150.0, 4242)   # 途中打ち切り
	var pf_created: int = int(pf_kA.created)
	var pf_sunk: int = int(pf_kA.sunk)
	var pf_inflight: int = int(pf_kA.in_flight)
	var pf_kB: Dictionary = ProcessFlow.new(pf_cons_spec).run(6000.0, 4242)  # 完全ドレイン
	var pf_identity_A: bool = pf_created == pf_sunk + pf_inflight
	var pf_live: bool = pf_inflight > 0                                       # 生きた in-flight を実際に踏む
	var pf_drained: bool = int(pf_kB.in_flight) == 0 and int(pf_kB.sunk) == int(pf_kB.created) \
		and int(pf_kB.created) == 300                                        # 全数 sink・漏れ無し
	var pf_conserve: bool = pf_identity_A and pf_live and pf_drained
	print("[procflow] created=%d sunk=%d in_flight=%d conserve=%s" % [
		pf_created, pf_sunk, pf_inflight, str(pf_conserve)])

	# [procflow-det] 同一 seed で同一 PF モデルを2回走らせ、kpi がバイト一致すること。
	var pf_det_spec := {
		"seed": 20250718,
		"resources": {"m": 2},
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 0.7},
				"max_arrivals": 2000, "next": "a1"},
			{"id": "a1", "type": "acquire", "resource": "m", "next": "d1"},
			{"id": "d1", "type": "delay", "duration": {"type": "exp", "a": 1.0}, "next": "r1"},
			{"id": "r1", "type": "release", "resource": "m", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	}
	var pf_k1: Dictionary = ProcessFlow.new(pf_det_spec).run(500.0, 20250718)
	var pf_k2: Dictionary = ProcessFlow.new(pf_det_spec).run(500.0, 20250718)
	var pf_identical: bool = str(pf_k1) == str(pf_k2)
	print("[procflow-det] identical=%s" % str(pf_identical))

	# [procflow-decide] Decide(mode=probabilistic, weights {0.7,0.3}) が大量トークンを
	# 期待比率で2分岐すること。N=20000 の即時トークンを2つの sink へ分け、
	# p_hat=count(sa)/N が 0.7 から許容誤差 0.03 未満で一致することを検証。
	var pf_dec_N: int = 20000
	var pf_dec := ProcessFlow.new({
		"seed": 13579,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "const", "a": 0.001},
				"max_arrivals": pf_dec_N, "next": "dec"},
			{"id": "dec", "type": "decide", "mode": "probabilistic",
				"weights": [0.7, 0.3], "next": ["sa", "sb"]},
			{"id": "sa", "type": "sink"},
			{"id": "sb", "type": "sink"},
		],
	})
	var pf_dec_k: Dictionary = pf_dec.run(float(pf_dec_N) * 0.001 + 10.0, 13579)
	var pf_dec_counts: Dictionary = pf_dec_k.per_activity_counts
	var pf_na: int = int(pf_dec_counts.get("sa", 0))
	var pf_nb: int = int(pf_dec_counts.get("sb", 0))
	var pf_p_hat: float = float(pf_na) / float(max(1, pf_na + pf_nb))
	var pf_dec_pass: bool = (pf_na + pf_nb == pf_dec_N) and (abs(pf_p_hat - 0.7) < 0.03)
	print("[procflow-decide] p_hat=%.4f pass=%s (sa=%d sb=%d N=%d)" % [
		pf_p_hat, str(pf_dec_pass), pf_na, pf_nb, pf_na + pf_nb])

	# [procflow-mm1] Source(exp到着,λ)→Acquire(server×1)→Delay(exp処理,μ)→Release→Sink。
	# 測定した平均系内時間 W_meas(=avg_cycle_time) を M/M/1 理論 W=1/(μ-λ) と突合。
	# ρ=λ/μ=0.65 に設定し、長時間(120000)走行で過渡を無視できるほど安定化させる。
	var pf_lambda: float = 0.65
	var pf_mu: float = 1.0
	var pf_mm1 := ProcessFlow.new({
		"seed": 24680,
		"resources": {"server": 1},
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.0 / pf_lambda},
				"next": "acq"},
			{"id": "acq", "type": "acquire", "resource": "server", "next": "svc"},
			{"id": "svc", "type": "delay", "duration": {"type": "exp", "a": 1.0 / pf_mu}, "next": "rel"},
			{"id": "rel", "type": "release", "resource": "server", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	var pf_mm1_k: Dictionary = pf_mm1.run(120000.0, 24680)
	var pf_W_meas: float = float(pf_mm1_k.avg_cycle_time)
	var pf_W_theory: float = 1.0 / (pf_mu - pf_lambda)
	var pf_mm1_relerr: float = abs(pf_W_meas - pf_W_theory) / pf_W_theory
	var pf_mm1_pass: bool = pf_mm1_relerr < 0.08
	print("[procflow-mm1] W_meas=%.4f W_theory=%.4f rel_err=%.4f pass=%s" % [
		pf_W_meas, pf_W_theory, pf_mm1_relerr, str(pf_mm1_pass)])

	# ============================================================
	# [pf-*] stage 2: トークンが実3Dモデルを編成する連携層（オプトイン・既定ドーマント）。
	# 上の既存 [procflow*] は不変（新機能を使わない）。以下は新 type/API のみを踏む。
	# ============================================================

	# [pf-item] Token<->FlowItem 束縛の保存則。source→create_item→delay→sink を完全ドレイン。
	# トークン保存(created==sunk, in_flight==0) と item 保存(_items_created==_items_disposed)
	# の双方が閉じることを確認（create_item は wip を触らない＝二重計上しない）。
	var it_pf := ProcessFlow.new({
		"seed": 909,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.0},
				"max_arrivals": 40, "next": "mk"},
			{"id": "mk", "type": "create_item", "item_type": 0, "next": "d"},
			{"id": "d", "type": "delay", "duration": {"type": "exp", "a": 0.8}, "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	var it_k: Dictionary = it_pf.run(100000.0, 909)
	var it_is: Dictionary = it_pf.item_stats()
	var it_tok_ok: bool = int(it_k.created) == 40 and int(it_k.sunk) == 40 and int(it_k.in_flight) == 0
	var it_item_ok: bool = int(it_is.created) == 40 and int(it_is.disposed) == 40
	var it_ok: bool = it_tok_ok and it_item_ok
	print("[pf-item] tok(created=%d sunk=%d inflight=%d) item(created=%d disposed=%d) both_conserve=%s" % [
		int(it_k.created), int(it_k.sunk), int(it_k.in_flight),
		int(it_is.created), int(it_is.disposed), str(it_ok)])

	# [pf-waitevent] 実 FlowObject の item_entered を FIFO で待つ。生産者トークンが item を
	# 実 Queue(feed) へ注入→下流(obs)へ転送で obs.item_entered が発火→待機トークンを到着順で
	# 払い出し。生産を t=1,2,3、消費者待機を t≈0 に置き、捕捉が [[tok,item]]=[[1,1],[2,2],[3,3]]
	# の FIFO 順であること・行列枯渇でシグナルが clean disconnect されること・item 保存を確認。
	var we_feed := Queue.new()
	we_feed.capacity = 50
	add_child(we_feed)
	var we_obs := Queue.new()
	we_obs.capacity = 50
	add_child(we_obs)
	we_feed.connect_to(we_obs)
	var we_pf := ProcessFlow.new({
		"seed": 111,
		"activities": [
			{"id": "sw", "type": "source", "interarrival": {"type": "const", "a": 0.001},
				"max_arrivals": 3, "next": "wait"},
			{"id": "wait", "type": "wait_event", "object": "obs", "signal": "entered", "next": "kw"},
			{"id": "kw", "type": "sink"},
			{"id": "sp", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 3, "next": "mk"},
			{"id": "mk", "type": "create_item", "item_type": 0, "next": "push"},
			{"id": "push", "type": "push_object", "object": "feed", "next": "kp"},
			{"id": "kp", "type": "sink"},
		],
	})
	we_pf.bind_objects({"feed": we_feed, "obs": we_obs})
	var we_k: Dictionary = we_pf.run(10.0, 111)
	var we_log: Array = we_pf._wait_capture_log
	var we_fifo_ok: bool = we_log == [[1, 1], [2, 2], [3, 3]]
	var we_disc_ok: bool = not we_obs.item_entered.is_connected(Callable(we_pf, "_on_wait_event"))
	var we_wait_empty: bool = we_pf._waits.is_empty()
	var we_is: Dictionary = we_pf.item_stats()
	var we_item_ok: bool = int(we_is.created) == 3 and int(we_is.disposed) == 3
	var we_conserve: bool = int(we_k.created) == 6 and int(we_k.sunk) == 6 and int(we_k.in_flight) == 0
	var we_ok: bool = we_fifo_ok and we_disc_ok and we_wait_empty and we_item_ok and we_conserve
	print("[pf-waitevent] capture=%s fifo=%s disconnected=%s waits_empty=%s item(c=%d d=%d) conserve=%s ok=%s" % [
		str(we_log), str(we_fifo_ok), str(we_disc_ok), str(we_wait_empty),
		int(we_is.created), int(we_is.disposed), str(we_conserve), str(we_ok)])
	we_feed.disconnect_all()
	Sim.unregister(we_feed); Sim.unregister(we_obs)
	remove_child(we_feed); we_feed.queue_free()
	remove_child(we_obs); we_obs.queue_free()

	# [pf-realres] 実 OperatorPool(作業者1名) から REAL 資源を取得/解放。3トークンが
	# acquire_resource→delay(5)→release_resource→sink。作業者1名なので直列化し、解放は
	# 常に行列先頭へ（追い越し無し）＝release 順は token 到着順 [1,2,3]。ディスパッチ/解放が
	# 均衡(dispatched==released, outstanding==0)＝リーク無しを確認。
	var rr_pool := OperatorPool.new()
	add_child(rr_pool)
	var rr_op := Operator.new()
	add_child(rr_op)                       # global_position を触る setup は in-tree 後に呼ぶ
	rr_op.setup("Op", Vector3(5, 0, 0))
	rr_pool.add_operator(rr_op)
	var rr_pf := ProcessFlow.new({
		"seed": 222,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "const", "a": 0.001},
				"max_arrivals": 3, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "ops", "next": "work"},
			{"id": "work", "type": "delay", "duration": {"type": "const", "a": 5.0}, "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "ops", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	rr_pf.bind_objects({"ops": rr_pool})
	var rr_k: Dictionary = rr_pf.run(100.0, 222)
	var rr_st: Dictionary = rr_pf.real_res_stats("ops")
	var rr_bal: bool = rr_pf.real_res_balanced("ops")
	var rr_rel_log: Array = rr_pf._res_release_log
	var rr_no_overtake: bool = rr_rel_log == [1, 2, 3]
	var rr_real: bool = rr_op is Operator and rr_pool.operators.has(rr_op) and rr_op.available == true
	var rr_conserve: bool = int(rr_k.created) == 3 and int(rr_k.sunk) == 3 and int(rr_k.in_flight) == 0
	var rr_ok: bool = rr_bal and rr_no_overtake and rr_real and rr_conserve \
		and int(rr_st.dispatched) == 3 and int(rr_st.released) == 3 and int(rr_st.outstanding) == 0
	print("[pf-realres] dispatch=%d release=%d outstanding=%d balance=%s no_overtake=%s(rel=%s) real_op=%s conserve=%s ok=%s" % [
		int(rr_st.dispatched), int(rr_st.released), int(rr_st.outstanding), str(rr_bal),
		str(rr_no_overtake), str(rr_rel_log), str(rr_real), str(rr_conserve), str(rr_ok)])
	Sim.unregister(rr_pool); Sim.unregister(rr_op)
	remove_child(rr_pool); rr_pool.queue_free()
	remove_child(rr_op); rr_op.queue_free()

	# [pf-isolation] run_isolated が stage1 分離(Sim.set_sources_enabled(false)) を掛け、
	# 実モデル Source を止める。実 Source→Queue(排出なし) を並走させた状態で:
	#   非分離 run(): 実 Source が wip を汚染 → Sim.wip > PF in_flight。
	#   run_isolated(): 実 Source 停止 → Sim.wip == PF in_flight（従来は不可能だった等式）。
	# さらに完全ドレインで Sim.wip==0==in_flight、実行後に sources_enabled が復元されること、
	# bind_objects の文字列 id 解決(実 FlowObject への束縛) を確認。
	editor.rebuild({
		"seed": 7, "warmup": 0, "operators": [],
		"objects": [
			{"id": "rs", "type": "Source", "name": "RS", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 1.0}, "type_count": 1}},
			{"id": "rq", "type": "Queue", "name": "RQ", "pos": [5, 0, 0],
				"params": {"capacity": 100000}},
		],
		"connections": [["rs", "rq"]],
	}, true)
	var iso_pf := ProcessFlow.new({
		"seed": 333,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.0},
				"max_arrivals": 300, "next": "d"},
			{"id": "d", "type": "delay", "duration": {"type": "exp", "a": 0.9}, "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	# bind_objects の文字列 id 解決: "rq" → 実 Queue へ解決できること。
	iso_pf.bind_objects({"q": "rq"})
	var iso_bind_ok: bool = iso_pf._resolve_bound("q") != null and iso_pf._resolve_bound("q") == editor.ctx.registry.get("rq", null)
	# 非分離: 実 Source が並走して wip を汚染する。
	var iso_non: Dictionary = iso_pf.run(120.0, 333)
	var wip_non: int = Sim.wip
	var inflight_non: int = int(iso_non.in_flight)
	var contaminated: bool = wip_non > inflight_non
	# 分離(部分実行): Sim.wip == in_flight が厳密成立し、in_flight は生きている(>0)。
	var iso_k: Dictionary = iso_pf.run_isolated(120.0, 333)
	var wip_iso: int = Sim.wip
	var inflight_iso: int = int(iso_k.in_flight)
	var iso_equal: bool = wip_iso == inflight_iso
	var iso_live: bool = inflight_iso > 0
	# 分離(完全ドレイン): 全消滅で wip==0==in_flight, sunk==created。
	var iso_drain: Dictionary = iso_pf.run_isolated(100000.0, 333)
	var iso_drained: bool = int(iso_drain.in_flight) == 0 and Sim.wip == 0 \
		and int(iso_drain.sunk) == int(iso_drain.created)
	# 実行後に sources_enabled が復元(true)されていること。
	var iso_restored: bool = Sim.sources_enabled == true
	var iso_ok: bool = iso_bind_ok and contaminated and iso_equal and iso_live and iso_drained and iso_restored
	print("[pf-isolation] non-iso(wip=%d>inflight=%d=%s) iso(wip=%d==inflight=%d=%s live=%s) drained=%s restored=%s bind_str=%s ok=%s" % [
		wip_non, inflight_non, str(contaminated), wip_iso, inflight_iso, str(iso_equal),
		str(iso_live), str(iso_drained), str(iso_restored), str(iso_bind_ok), str(iso_ok)])

	# ============================================================
	# [pf-3d*] stage 3: PF<->3D 統合の自己検査（オプトイン・既定ドーマント）。
	# いずれも run_isolated で既定 Source 自走を止め、実 FlowObject/実プールへ束縛して走らせる。
	# 既存マーカーの後に「追記」のみ（既存の値・順序には一切触れない）。run_isolated が
	# sources_enabled を復元し、末尾の rebuild(default) で Sim を元へ戻す（分離オフに復帰）。
	# ============================================================

	# [pf-3d] 実 FlowObject(Source/Queue/Processor/Sink)へ束縛した PF を run_isolated で実行。
	# 分離中は実 Source が止まるため Sim.wip==PF in_flight（分離の証明・in_flight>0 の実働）。
	# さらに完全ドレインで in_flight==0・Sim.wip==0（リーク無し）、保存則 created==sunk+in_flight。
	editor.rebuild({
		"seed": 5, "warmup": 0, "operators": [],
		"objects": [
			{"id": "rs", "type": "Source", "name": "RS", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 1.0}, "type_count": 1}},
			{"id": "rq", "type": "Queue", "name": "RQ", "pos": [5, 0, 0],
				"params": {"capacity": 100000}},
			{"id": "rp", "type": "Processor", "name": "RP", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "const", "a": 2.0}, "mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "rk", "type": "Sink", "name": "RK", "pos": [15, 0, 0]},
		],
		"connections": [["rs", "rq"], ["rq", "rp"], ["rp", "rk"]],
	}, true)
	var p3d_pf := ProcessFlow.new({
		"seed": 3030,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.0},
				"max_arrivals": 300, "next": "d"},
			{"id": "d", "type": "delay", "duration": {"type": "exp", "a": 2.0}, "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	# 実 FlowObject への束縛（文字列 id 解決 → 実 Queue/Processor/Sink 実体）。
	p3d_pf.bind_objects({"q": "rq", "p": "rp", "k": "rk"})
	var p3d_bound_ok: bool = p3d_pf._resolve_bound("q") == editor.ctx.registry.get("rq", null) \
		and p3d_pf._resolve_bound("p") == editor.ctx.registry.get("rp", null) \
		and p3d_pf._resolve_bound("k") == editor.ctx.registry.get("rk", null)
	# 部分実行（分離）: 実 Source 停止 → Sim.wip は PF トークンのみ → wip==in_flight(>0)。
	var p3d_kp: Dictionary = p3d_pf.run_isolated(100.0, 3030)
	var p3d_wip_eq: bool = Sim.wip == int(p3d_kp.in_flight) and int(p3d_kp.in_flight) > 0
	var p3d_conserve_p: bool = int(p3d_kp.created) == int(p3d_kp.sunk) + int(p3d_kp.in_flight)
	# 完全ドレイン（分離）: 全消滅 → in_flight==0・Sim.wip==0・sunk==created。
	var p3d_kd: Dictionary = p3d_pf.run_isolated(1000000.0, 3030)
	var p3d_drained: bool = int(p3d_kd.in_flight) == 0 and Sim.wip == 0 \
		and int(p3d_kd.sunk) == int(p3d_kd.created)
	var p3d_conserve_d: bool = int(p3d_kd.created) == int(p3d_kd.sunk) + int(p3d_kd.in_flight)
	var p3d_conserve: bool = p3d_conserve_p and p3d_conserve_d
	var p3d_restored: bool = Sim.sources_enabled == true
	var p3d_pass: bool = p3d_bound_ok and p3d_wip_eq and p3d_drained and p3d_conserve and p3d_restored
	print("[pf-3d] created=%d sunk=%d in_flight=%d wip_eq=%s conserve=%s pass=%s" % [
		int(p3d_kd.created), int(p3d_kd.sunk), int(p3d_kd.in_flight),
		str(p3d_wip_eq), str(p3d_conserve), str(p3d_pass)])

	# [pf-3d-det] 同一の分離モデルを同一シードで run_isolated 2回 → kpi がバイト同一。
	var pd_k1: Dictionary = p3d_pf.run_isolated(200.0, 3131)
	var pd_k2: Dictionary = p3d_pf.run_isolated(200.0, 3131)
	var pd_identical: bool = str(pd_k1) == str(pd_k2)
	print("[pf-3d-det] kpi1=%s kpi2=%s identical=%s" % [str(pd_k1), str(pd_k2), str(pd_identical)])

	# [pf-acquire3d] 実 OperatorPool(capacity=1) から REAL 作業者を acquire_resource→delay→
	# release_resource→sink。(A) 到着継続中の窓で時間加重稼働率 util≈負荷 ρ=λ*S を測定。
	# (B) 有限到着を完全ドレインし dispatch==release・outstanding==0（作業者リーク無し）を証明。
	var pa_pool := OperatorPool.new()
	add_child(pa_pool)
	var pa_op := Operator.new()
	add_child(pa_op)                      # global_position を触る setup は in-tree 後
	pa_op.setup("Op", Vector3(5, 0, 0))
	pa_pool.add_operator(pa_op)
	var pa_pf := ProcessFlow.new({
		"seed": 5050,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 4.0},
				"max_arrivals": 2000, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "ops", "next": "work"},
			{"id": "work", "type": "delay", "duration": {"type": "const", "a": 2.0}, "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "ops", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	pa_pf.bind_objects({"ops": pa_pool})
	# (A) 定常 util: Source 未枯渇の窓で測定。λ=1/4=0.25, S=2 → 負荷 ρ=0.5。
	pa_pf.run_isolated(4000.0, 5050)
	var pa_util: float = pa_op.utilization()
	var pa_expected: float = (1.0 / 4.0) * 2.0    # λ*S = ρ = 0.5
	var pa_util_range: bool = pa_util > 0.0 and pa_util <= 1.0
	var pa_util_match: bool = abs(pa_util - pa_expected) <= 0.06
	# (B) 完全ドレイン: 全 2000 到着を捌ききって no-leak を証明。
	var pa_kd: Dictionary = pa_pf.run_isolated(1000000.0, 5051)
	var pa_st: Dictionary = pa_pf.real_res_stats("ops")
	var pa_bal: bool = pa_pf.real_res_balanced("ops")
	var pa_disp: int = int(pa_st.dispatched)
	var pa_rel: int = int(pa_st.released)
	var pa_out: int = int(pa_st.outstanding)
	var pa_conserve: bool = int(pa_kd.created) == int(pa_kd.sunk) + int(pa_kd.in_flight) \
		and int(pa_kd.in_flight) == 0
	var pa_noleak: bool = pa_bal and pa_disp == pa_rel and pa_out == 0 and pa_disp >= 1
	var pa_pass: bool = pa_noleak and pa_util_range and pa_util_match and pa_conserve
	print("[pf-acquire3d] dispatch=%d release=%d outstanding=%d util=%.3f (exp=%.3f range=%s match=%s) conserve=%s pass=%s" % [
		pa_disp, pa_rel, pa_out, pa_util, pa_expected,
		str(pa_util_range), str(pa_util_match), str(pa_conserve), str(pa_pass)])
	Sim.unregister(pa_pool); Sim.unregister(pa_op)
	remove_child(pa_pool); pa_pool.queue_free()
	remove_child(pa_op); pa_op.queue_free()

	# [pf-wait] 束縛オブジェクトの item_entered を待つトークン。待機者(4)＞発火(3) とし、
	# 発火した3件だけが FIFO(到着=token id 昇順)で前進し、4件目はイベント未着で「前進しない」
	# （＝イベント後にのみ前進する）ことを in_flight/待ち行列で証明。run_isolated で実 Source を
	# 止め、実 Queue(feed→obs) を駆動して obs.item_entered を発火させる。
	var pw_feed := Queue.new()
	pw_feed.capacity = 50
	add_child(pw_feed)
	var pw_obs := Queue.new()
	pw_obs.capacity = 50
	add_child(pw_obs)
	pw_feed.connect_to(pw_obs)
	var pw_pf := ProcessFlow.new({
		"seed": 606,
		"activities": [
			{"id": "sw", "type": "source", "interarrival": {"type": "const", "a": 0.001},
				"max_arrivals": 4, "next": "wait"},
			{"id": "wait", "type": "wait_event", "object": "obs", "signal": "entered", "next": "kw"},
			{"id": "kw", "type": "sink"},
			{"id": "sp", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 3, "next": "mk"},
			{"id": "mk", "type": "create_item", "item_type": 0, "next": "push"},
			{"id": "push", "type": "push_object", "object": "feed", "next": "kp"},
			{"id": "kp", "type": "sink"},
		],
	})
	pw_pf.bind_objects({"feed": pw_feed, "obs": pw_obs})
	var pw_k: Dictionary = pw_pf.run_isolated(10.0, 606)
	var pw_log: Array = pw_pf._wait_capture_log
	var pw_tok_order: Array = []
	var pw_item_order: Array = []
	for pw_e in pw_log:
		pw_tok_order.append(int(pw_e[0]))
		pw_item_order.append(int(pw_e[1]))
	# 発火3件のみ、待機トークンの到着順(token id 1,2,3)で FIFO 前進。
	var pw_fifo_ok: bool = pw_tok_order == [1, 2, 3]
	# 捕捉した item は push 順(=item id 昇順)。
	var pw_items_ordered: bool = pw_item_order.size() == 3 \
		and pw_item_order[0] < pw_item_order[1] and pw_item_order[1] < pw_item_order[2]
	# 4件目の待機トークンはイベント未着 → 前進せず in_flight に残る（イベント後にのみ前進する証拠）。
	var pw_still_waiting: bool = false
	for pw_key in pw_pf._waits.keys():
		if (pw_pf._waits[pw_key]["queue"] as Array).size() == 1:
			pw_still_waiting = true
	var pw_only_after: bool = int(pw_k.in_flight) == 1 and pw_still_waiting
	# 保存則: created=4待機+3生産=7, sunk=3待機+3生産=6, in_flight=1(未発火の待機)。
	var pw_conserve: bool = int(pw_k.created) == 7 and int(pw_k.sunk) == 6 and int(pw_k.in_flight) == 1
	var pw_pass: bool = pw_fifo_ok and pw_items_ordered and pw_only_after and pw_conserve
	print("[pf-wait] fifo_token_order=%s items_ascending=%s only_after_event=%s(in_flight=%d waiting=%s) conserve=%s pass=%s" % [
		str(pw_tok_order), str(pw_items_ordered), str(pw_only_after),
		int(pw_k.in_flight), str(pw_still_waiting), str(pw_conserve), str(pw_pass)])
	# 後片付け: 未発火待機のシグナル接続をクリーン切断してからノード解放。
	for pw_key2 in pw_pf._waits.keys():
		pw_pf._disconnect_wait(pw_key2)
	pw_feed.disconnect_all()
	Sim.unregister(pw_feed); Sim.unregister(pw_obs)
	remove_child(pw_feed); pw_feed.queue_free()
	remove_child(pw_obs); pw_obs.queue_free()

	# ============================================================
	# [agv-traffic] / [agv-cap] / [agv-deadlock]: 単一レーン共有コリドーの交通干渉を
	# 明示的に実証する（Markers 3/3）。いずれも有限容量辺でのみ働く輻輳エンジンを踏み、
	# 容量INFの自由流と対比する。既存マーカーはこのブロックより前で全て出力済みなので
	# 一切影響しない。各ブロックは自前で editor.rebuild（＝Sim 初期化）してから走らせ、
	# ブロック末尾の既定モデル復帰で全辺 INF・visuals=true へ戻す（次マーカー追加時の保険）。
	# ============================================================
	Sim.visuals_enabled = false

	# [agv-traffic] 複数搬送者が容量1の共有辺で直列化する。固定個(バースト)の搬送タスクを
	# 与え、最終完了時刻 makespan(≈最大リードタイム, 全アイテムほぼ t=0 生成) を自由流(容量INF)と
	# 比較する。(a)直列化=congested>freeflow (b)FIFO (c)決定論 (d)保存則 を検査。
	# 容量INF/容量1で created(生成数)が一致することも確認（同一タスク集合の makespan 比較）。
	var tf_cong: Dictionary = _agvtraffic_run(1.0)      # 容量1で直列化（輻輳）
	var tf_cong2: Dictionary = _agvtraffic_run(1.0)     # 決定論確認用の再実行
	var tf_free: Dictionary = _agvtraffic_run(INF)      # 自由流（容量INF＝ドーマント）
	# FIFO: 同一辺・同一方向の待機列が到着順(FIFO)で起床することを純データで直接検証。
	# 先頭が即占有→後続3件は FIFO 待機→解放のたび先頭から1件ずつ起床（追い越し無し）。
	var tf_fifo_net := TransportNetwork.new({"A": [0, 0, 0], "B": [10, 0, 0]}, [["A", "B"]])
	tf_fifo_net.set_edge_capacity("A", "B", 1.0)
	var tf_order: Array = []
	var tf_adm0: bool = tf_fifo_net.request_edge("A", "B", "w0", "A", func(): tf_order.append(0))
	tf_fifo_net.request_edge("A", "B", "w1", "A", func(): tf_order.append(1))
	tf_fifo_net.request_edge("A", "B", "w2", "A", func(): tf_order.append(2))
	tf_fifo_net.request_edge("A", "B", "w3", "A", func(): tf_order.append(3))
	tf_fifo_net.finish_edge("A", "B", "w0", "A")   # w1 起床
	tf_fifo_net.finish_edge("A", "B", "w1", "A")   # w2 起床
	tf_fifo_net.finish_edge("A", "B", "w2", "A")   # w3 起床
	tf_fifo_net.finish_edge("A", "B", "w3", "A")
	var tf_fifo: bool = tf_adm0 and tf_order == [1, 2, 3]
	var tf_congested: float = float(tf_cong.makespan)
	var tf_freeflow: float = float(tf_free.makespan)
	var tf_serialized: bool = tf_congested > tf_freeflow
	var tf_det: bool = int(tf_cong.sink) == int(tf_cong2.sink) \
		and is_equal_approx(tf_congested, float(tf_cong2.makespan))
	var tf_cons: bool = bool(tf_cong.conserve) and bool(tf_free.conserve)
	var tf_sink_ok: bool = int(tf_cong.sink) > 0 and int(tf_free.sink) > 0 \
		and int(tf_cong.sink) == int(tf_free.sink)
	var agv_traffic_ok: bool = tf_serialized and tf_fifo and tf_det and tf_cons and tf_sink_ok
	print("[agv-traffic] congested_time=%.2f freeflow_time=%.2f congested>freeflow=%s fifo=%s det=%s conserve=%s sink=%d/%d pass=%s" % [
		tf_congested, tf_freeflow, str(tf_serialized), str(tf_fifo), str(tf_det),
		str(tf_cons), int(tf_cong.sink), int(tf_free.sink), str(agv_traffic_ok)])

	# [agv-cap] 実行中の辺占有をピーク計測（network が _admit_edge で逐次更新）し、容量1の辺・
	# 容量2の辺いずれも「占有<=容量」が全時刻で成立することを検査する。容量2の辺は同方向2台の
	# 同時占有(=2)まで到達し、容量1の辺は高々1に制限される（＝容量が実際に効いている証拠）。
	var cp: Dictionary = _agvcap2_run()
	var cp_cap2: int = int(cp.peak_ab)   # 容量2の辺 A-B の観測ピーク
	var cp_cap1: int = int(cp.peak_bc)   # 容量1の辺 B-C の観測ピーク
	var cp_le2: bool = cp_cap2 <= 2      # 容量2の辺: max_occ<=cap
	var cp_le1: bool = cp_cap1 <= 1      # 容量1の辺: max_occ<=cap
	var cp_inv: bool = bool(cp.inv_ok)   # 全辺で占有<=容量（全域チェック）
	var cp_reached: bool = cp_cap2 == 2 and cp_cap1 == 1   # 各容量を実際に使い切った
	var cp_cons: bool = bool(cp.conserve)
	var agv_cap_ok2: bool = cp_le2 and cp_le1 and cp_inv and cp_reached and cp_cons and int(cp.sink) > 0
	print("[agv-cap] cap2edge max_occ=%d cap=2 ok=%s | cap1edge max_occ=%d cap=1 ok=%s | occ_le_cap_all=%s reached=%s conserve=%s sink=%d pass=%s" % [
		cp_cap2, str(cp_le2), cp_cap1, str(cp_le1), str(cp_inv), str(cp_reached),
		str(cp_cons), int(cp.sink), str(agv_cap_ok2)])

	# [agv-deadlock] 単一レーン双方向辺(容量1)で2台が正面遭遇。方向ロック+FIFOで順に通過し、
	# 両者が必ず完走する（永久ブロック無し）。決定論・保存則も確認する。
	var dl1: Dictionary = _agvdeadlock_run()
	var dl2: Dictionary = _agvdeadlock_run()
	var dl_both: bool = bool(dl1.both)
	var dl_det: bool = str(dl1.key) == str(dl2.key)
	var dl_cons: bool = bool(dl1.conserve)
	var agv_deadlock_ok: bool = dl_both and dl_det and dl_cons
	print("[agv-deadlock] sinkA=%d sinkB=%d both_completed=%s det=%s conserve=%s pass=%s" % [
		int(dl1.sinkA), int(dl1.sinkB), str(dl_both), str(dl_det), str(dl_cons), str(agv_deadlock_ok)])

	# [agv-node] ノード（交差点）インターロック。既存の辺予約に加え、制御点＝ノードにも容量を
	# 設け「交差点を1車ずつ通す」ブロック区間方式のインターロックを実装した。ノードは辺 a→b を
	# 渡り切って到達側ノード b の占有を確定するまで元ノード a を保持する（＝実効的に交通を律速）。
	# 到達側ノードが満杯なら【辺を保持したまま】待機し上流をせき止める（＝スピルバック）。全ノード
	# INF（既定）ではこの経路を一切踏まないため既存マーカーはバイト一致（ドーマント）。
	#   検査: (a) 占有不変条件 node_peak<=cap かつ実際に cap まで使う (b) liveness（全車完走・保存則）
	#         (c) 輻輳効果 lead(cap1)>lead(INF) (d) 決定論 (e) FIFO 起床順 (f) スピルバック（辺保持）
	#         (g) 十字路（head-on/4-way 交差）で永久ブロック無し。
	# --- (e)(f) ノード FIFO 起床順＋スピルバックの純データ検証（決定的・乱数不使用）---
	var nd := TransportNetwork.new({"A": [0, 0, 0], "B": [10, 0, 0], "C": [20, 0, 0]},
		[["A", "B"], ["B", "C"]])
	nd.set_edge_capacity("A", "B", 5.0)   # 辺は広く（ノード B が律速）
	nd.set_node_capacity("B", 1.0)        # 交差点 B 容量1
	var norder: Array = []
	nd.request_edge("A", "B", "t0", "A", Callable())   # 辺 A-B 占有1（t0 横断中）
	nd.request_edge("A", "B", "t1", "A", Callable())   # 占有2
	nd.request_edge("A", "B", "t2", "A", Callable())   # 占有3
	var nb0: bool = nd.request_node("B", "t0", func(): norder.append(0))  # 空き→true（B占有1）
	var nb1: bool = nd.request_node("B", "t1", func(): norder.append(1))  # 満杯→false（FIFO待機）
	var nb2: bool = nd.request_node("B", "t2", func(): norder.append(2))  # 満杯→false（FIFO待機）
	var spill_before: int = nd.edge_occupancy("A", "B")   # =3（全員まだ辺上／未解放）
	nd.finish_edge("A", "B", "t0", "A")                   # t0 が辺解放（辺占有 3->2）
	var spill_hold: int = nd.edge_occupancy("A", "B")     # =2（t1,t2 は B 待ちで辺を保持）
	var woke_none: bool = norder.is_empty()               # B が t0 占有中なので誰も起床しない
	nd.finish_node("B", "t0")   # t0 が次ブロックへ前進＝B解放 → 先頭 t1 起床（B占有1）
	nd.finish_edge("A", "B", "t1", "A")
	nd.finish_node("B", "t1")   # → t2 起床
	nd.finish_edge("A", "B", "t2", "A")
	nd.finish_node("B", "t2")
	var node_fifo: bool = nb0 and not nb1 and not nb2 and norder == [1, 2]
	var node_spill: bool = spill_before == 3 and spill_hold == 2 and woke_none
	var node_peak_ok: bool = nd.node_occupancy_peak("B") == 1 and nd.node_occupancy_within_capacity()
	# --- (a)-(d) マージ・コリドー A-B-C（node B が交差点=容量1、辺は INF）で 6 ライン×8 台を律速 ---
	var nn_cong1: Dictionary = _agvnode_run(1.0)   # node B 容量1（インターロック）
	var nn_cong2: Dictionary = _agvnode_run(1.0)   # 決定論確認用の再実行
	var nn_free: Dictionary = _agvnode_run(INF)    # node INF＝ドーマント（自由流）
	var nn_live: bool = int(nn_cong1.sink) > 0 and bool(nn_cong1.conserve) and bool(nn_free.conserve)
	var nn_inv: bool = int(nn_cong1.peak_node_b) == 1 and bool(nn_cong1.node_inv)
	var nn_congest: bool = float(nn_cong1.lead) > float(nn_free.lead)
	var nn_det: bool = int(nn_cong1.sink) == int(nn_cong2.sink) \
		and is_equal_approx(float(nn_cong1.lead), float(nn_cong2.lead)) \
		and int(nn_cong1.peak_node_b) == int(nn_cong2.peak_node_b)
	# --- (g) 十字路: 中心 X(容量1) を水平(W→X→E)・垂直(S→X→N)の2フローが交差通過。共有辺は無く
	#         X だけを奪い合う。X は有限ノードだが隣接辺は全て INF（有限辺に隣接しない）ので fable5
	#         erratum の安全条件「対向流経路上で有限ノードを有限辺に隣接させない」を満たし全車完走する
	#         （※端点 INF だけでは不十分。隣接辺が有限だと循環待ち＝[agv-node-deadlock] 参照）---
	var cross: Dictionary = _agvnode_cross_run()
	var cross_live: bool = bool(cross.both) and bool(cross.conserve)
	var cross_inv: bool = int(cross.peak_node_x) == 1 and bool(cross.node_inv)
	var agv_node_ok: bool = nn_live and nn_inv and nn_congest and nn_det \
		and node_fifo and node_spill and node_peak_ok and cross_live and cross_inv
	print("[agv-node] node_peak_b=%d cap=1 inv=%s live=%s congest(%.2f>%.2f)=%s det=%s fifo=%s spill=%s peakok=%s | cross sinkH=%d sinkV=%d peakX=%d both=%s | pass=%s" % [
		int(nn_cong1.peak_node_b), str(nn_inv), str(nn_live), float(nn_cong1.lead), float(nn_free.lead),
		str(nn_congest), str(nn_det), str(node_fifo), str(node_spill), str(node_peak_ok),
		int(cross.sinkH), int(cross.sinkV), int(cross.peak_node_x), str(cross.both), str(agv_node_ok)])

	# ============================================================
	# [pf-mix-*] MIXED-MODE 自己検査（Tests stage 2/2）。PF<->3D 境界の3バグが生きていた
	# 経路を明示的に踏む。各ブロックは自前で editor.rebuild（＝Sim 初期化）してから
	# run_isolated（既定 Source 自走を止め wip 汚染を排除）で走らせる。既存マーカーは全て
	# このブロックより前で出力済みなので一切影響しない（追記のみ・値バイト同一）。末尾の
	# rebuild(default) で Sim を既定へ戻す（各ブロックは reset 済みの状態で開始・終了する）。
	# ============================================================
	Sim.visuals_enabled = false

	# [pf-mix-push] BUG1 バックプレッシャー: PF トークンが item を生成し、既に満杯の実 Queue へ
	# push_object する。満杯時に item を落とさず item_exited を待ち、下流 Processor が1件処理して
	# 空きが出た瞬間に再試行して通す。部分実行(t=4)で「待機中＝未消失・wip 計上済み」を、完全
	# ドレイン(t=1000)で「全数が下流実 Sink へ到達＝消失ゼロ・保存則・決定論」を確認する。
	editor.rebuild({
		"seed": 8, "warmup": 0, "operators": [],
		"objects": [
			{"id": "mpq", "type": "Queue", "name": "MPQ", "pos": [0, 0, 0],
				"params": {"capacity": 1}},
			{"id": "mpp", "type": "Processor", "name": "MPP", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 5.0},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "mpk", "type": "Sink", "name": "MPK", "pos": [10, 0, 0]},
		],
		"connections": [["mpq", "mpp"], ["mpp", "mpk"]],
	}, true)
	var mp_k = editor.ctx.registry.get("mpk", null)
	var mp_pf := ProcessFlow.new({
		"seed": 4040,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 3, "next": "mk"},
			{"id": "mk", "type": "create_item", "item_type": 0, "next": "push"},
			{"id": "push", "type": "push_object", "object": "mpq", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	mp_pf.bind_objects({"mpq": "mpq"})
	# 部分実行(t=4): item1→Processor(処理中), item2→Queue(満杯), item3=push が満杯で待機。
	var mp_kp: Dictionary = mp_pf.run_isolated(4.0, 4040)
	var mp_waited: bool = not mp_pf._push_waits.is_empty()   # item を落とさず空き待ち＝消失なし
	var mp_partial_sink0: bool = int(mp_k.total) == 0        # 待機 item はまだ実 Sink 未到達
	var mp_partial_wip: bool = Sim.wip == 3                  # 3 item すべて系内に計上＝消失なし
	var mp_partial_inflight: bool = int(mp_kp.in_flight) == 1
	# 完全ドレイン(t=1000): 空きが出るたび再試行し全 3 件を下流実 Sink へ通す。
	var mp_kd: Dictionary = mp_pf.run_isolated(1000.0, 4040)
	var mp_is: Dictionary = mp_pf.item_stats()
	var mp_pushed: int = int(mp_k.total)
	var mp_created: int = int(mp_is.created)
	var mp_in_system: int = Sim.wip
	var mp_lost: bool = (mp_created - mp_pushed - mp_in_system) != 0   # 期待 false（消失/重複なし）
	var mp_conserve: bool = mp_created == mp_pushed + mp_in_system \
		and int(mp_kd.created) == int(mp_kd.sunk) + int(mp_kd.in_flight) \
		and Sim.wip == 0 and mp_pushed == 3
	# 決定論: 同一シードで完全ドレインを2回 → kpi バイト同一。
	var mp_d1: Dictionary = mp_pf.run_isolated(1000.0, 4040)
	var mp_d2: Dictionary = mp_pf.run_isolated(1000.0, 4040)
	var mp_det: bool = str(mp_d1) == str(mp_d2)
	var mp_pass: bool = (not mp_lost) and mp_conserve and mp_det \
		and mp_waited and mp_partial_sink0 and mp_partial_wip and mp_partial_inflight
	print("[pf-mix-push] pushed=%d lost=%s conserve=%s det=%s pass=%s" % [
		mp_pushed, str(mp_lost), str(mp_conserve), str(mp_det), str(mp_pass)])

	# [pf-mix-pool] BUG2 ロストウェイクアップ: PF acquire_resource と実 Processor が同一
	# OperatorPool(容量1) を共有する。PF が唯一の作業者を確保→保持(delay)→解放する間、実
	# Processor は同プールで作業者待ちの行列に入る。PF 解放時に _assign_next 経由で 3D 側の
	# 待ち行列を起こし、実 Processor が作業者を得て前進(実 Sink へ出力)することを確認する。
	# 作業者リーク無し(pf_dispatch==pf_release, outstanding==0, プール均衡)・決定論も確認。
	editor.rebuild({
		"seed": 9, "warmup": 0,
		"operators": [{"name": "MO_Op", "home": [5, 0, 0]}],
		"objects": [
			{"id": "mop", "type": "Processor", "name": "MOP", "pos": [0, 0, 0],
				"params": {"process_time": {"type": "const", "a": 2.0}, "needs_operator": true,
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "mok", "type": "Sink", "name": "MOK", "pos": [10, 0, 0]},
		],
		"connections": [["mop", "mok"]],
	}, true)
	var mo_pool = editor.ctx.pool
	var mo_op = editor.ctx.operators[0]
	var mo_k = editor.ctx.registry.get("mok", null)
	var mo_pf := ProcessFlow.new({
		"seed": 6060,
		"activities": [
			{"id": "srcA", "type": "source", "interarrival": {"type": "const", "a": 0.5},
				"max_arrivals": 1, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "pool", "next": "hold"},
			{"id": "hold", "type": "delay", "duration": {"type": "const", "a": 5.0}, "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "pool", "next": "snkA"},
			{"id": "snkA", "type": "sink"},
			{"id": "srcB", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 1, "next": "mkB"},
			{"id": "mkB", "type": "create_item", "item_type": 0, "next": "feed"},
			{"id": "feed", "type": "push_object", "object": "mop", "next": "snkB"},
			{"id": "snkB", "type": "sink"},
		],
	})
	# PF acquire と実 Processor は同一 OperatorPool を共有（bind でプール実体を束縛）。
	mo_pf.bind_objects({"pool": mo_pool, "mop": "mop"})
	var mo_kd: Dictionary = mo_pf.run_isolated(100.0, 6060)
	var mo_st: Dictionary = mo_pf.real_res_stats("pool")
	var mo_bal: bool = mo_pf.real_res_balanced("pool")
	var mo_dispatch: int = int(mo_st.dispatched)
	var mo_release: int = int(mo_st.released)
	var mo_out: int = int(mo_st.outstanding)
	var mo_progressed: bool = int(mo_k.total) > 0             # 実 Processor が作業者を得て出力した
	var mo_pool_bal: bool = int(mo_pool.dispatch_count) == int(mo_pool.release_count) \
		and mo_op.available == true                          # プール側もリーク無し・作業者返却済み
	var mo_conserve: bool = int(mo_kd.created) == int(mo_kd.sunk) + int(mo_kd.in_flight) \
		and int(mo_kd.in_flight) == 0
	# 決定論: 同一シードで2回 → kpi バイト同一。
	var mo_d1: Dictionary = mo_pf.run_isolated(100.0, 6060)
	var mo_d2: Dictionary = mo_pf.run_isolated(100.0, 6060)
	var mo_det: bool = str(mo_d1) == str(mo_d2)
	var mo_pass: bool = mo_dispatch == 1 and mo_release == 1 and mo_progressed \
		and mo_out == 0 and mo_bal and mo_pool_bal and mo_conserve and mo_det
	print("[pf-mix-pool] pf_dispatch=%d pf_release=%d threed_progressed=%s outstanding=%d det=%s pass=%s" % [
		mo_dispatch, mo_release, str(mo_progressed), mo_out, str(mo_det), str(mo_pass)])

	# [pf-mix-sink] BUG3 二重 wip_dec: PF トークンが item を生成し push_object で 3D モデル
	# (Queue→実 Sink)へ手渡す。物理実体の wip 減算は実 Sink が1回だけ行い、所有権移譲済み
	# トークンが PF sink に達しても二重に減算しない(_wip_transferred)。系内に別途「保持中」の
	# トークン群(delay 滞留＝item を離さない)を混在させ、最終 Sim.wip が「系内に残る item 数」
	# と厳密一致することで、二重減算(＝保持分を食い潰す)が起きていないことを証明する。
	editor.rebuild({
		"seed": 10, "warmup": 0, "operators": [],
		"objects": [
			{"id": "msq", "type": "Queue", "name": "MSQ", "pos": [0, 0, 0],
				"params": {"capacity": 100}},
			{"id": "msk", "type": "Sink", "name": "MSK", "pos": [5, 0, 0]},
		],
		"connections": [["msq", "msk"]],
	}, true)
	var ms_k = editor.ctx.registry.get("msk", null)
	var ms_pf := ProcessFlow.new({
		"seed": 7070,
		"activities": [
			{"id": "srcH", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 3, "next": "mkH"},
			{"id": "mkH", "type": "create_item", "item_type": 0, "next": "dH"},
			{"id": "dH", "type": "delay", "duration": {"type": "const", "a": 100000.0}, "next": "snkH"},
			{"id": "snkH", "type": "sink"},
			{"id": "srcT", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 4, "next": "mkT"},
			{"id": "mkT", "type": "create_item", "item_type": 0, "next": "pushT"},
			{"id": "pushT", "type": "push_object", "object": "msq", "next": "snkT"},
			{"id": "snkT", "type": "sink"},
		],
	})
	ms_pf.bind_objects({"msq": "msq"})
	# 部分実行(t=50): 保持トラック(H)3件は delay 滞留のまま在系、移譲トラック(T)4件は実 Sink 到達。
	var ms_kd: Dictionary = ms_pf.run_isolated(50.0, 7070)
	var ms_is: Dictionary = ms_pf.item_stats()
	var ms_wip_final: int = Sim.wip
	var ms_expected_wip: int = int(ms_kd.in_flight)   # 系内に残る保持トークン＝保持中の item 数
	var ms_out: int = int(ms_k.total)
	var ms_no_double: bool = ms_wip_final == ms_expected_wip   # 二重減算なら保持分を食い潰し不一致
	var ms_conserve: bool = int(ms_is.created) == ms_out + ms_wip_final \
		and int(ms_kd.created) == int(ms_kd.sunk) + int(ms_kd.in_flight) \
		and ms_out == 4 and int(ms_is.created) == 7
	# 決定論: 同一シードで2回 → kpi バイト同一。
	var ms_d1: Dictionary = ms_pf.run_isolated(50.0, 7070)
	var ms_d2: Dictionary = ms_pf.run_isolated(50.0, 7070)
	var ms_det: bool = str(ms_d1) == str(ms_d2)
	var ms_pass: bool = ms_no_double and ms_conserve and ms_det
	print("[pf-mix-sink] wip_final=%d expected_wip=%d conserve=%s det=%s pass=%s" % [
		ms_wip_final, ms_expected_wip, str(ms_conserve), str(ms_det), str(ms_pass)])

	# [pf-mix-pool2] BUG2 の MIRROR（3D→PF ロストウェイクアップ）: PF acquire_resource と実
	# Processor が同一 OperatorPool(容量1) を共有する。今回は実 Processor が先に唯一の作業者を
	# 確保・保持し、その間に PF トークンが acquire で rr["waiters"] に積まれて待機する。3D 側が
	# 通常の pool.release/_assign_next で作業者を解放した時、外部待機フック(_notify_external →
	# _on_pool_unit_freed)経由で PF 待機が起床し、作業者を得て次アクティビティ(delay→release→
	# PF sink)へ前進することを確認する。作業者リーク無し(pf_dispatch==pf_release, outstanding==0,
	# プール dispatch_count==release_count)・決定論も確認。新経路は PF が待機トークンを積む時のみ
	# 起動し、それ以外はドーマント（既存マーカーはバイト同一）。前後で Sim を初期化して隔離する。
	Sim.visuals_enabled = false
	editor.rebuild({
		"seed": 11, "warmup": 0,
		"operators": [{"name": "M2_Op", "home": [5, 0, 0]}],
		"objects": [
			{"id": "m2p", "type": "Processor", "name": "M2P", "pos": [0, 0, 0],
				"params": {"process_time": {"type": "const", "a": 10.0}, "needs_operator": true,
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "m2k", "type": "Sink", "name": "M2K", "pos": [10, 0, 0]},
		],
		"connections": [["m2p", "m2k"]],
	}, true)
	var m2_pool = editor.ctx.pool
	var m2_op = editor.ctx.operators[0]
	var m2_k = editor.ctx.registry.get("m2k", null)
	var m2_pf := ProcessFlow.new({
		"seed": 8080,
		"activities": [
			# 3D 側フィード（先発）: t=0.5 に実 Processor へ item を渡し唯一の作業者を確保・保持させる。
			{"id": "srcB", "type": "source", "interarrival": {"type": "const", "a": 0.5},
				"max_arrivals": 1, "next": "mkB"},
			{"id": "mkB", "type": "create_item", "item_type": 0, "next": "feed"},
			{"id": "feed", "type": "push_object", "object": "m2p", "next": "snkB"},
			{"id": "snkB", "type": "sink"},
			# PF 側（後発）: t=2.0 に acquire。3D が作業者を握っている間 rr["waiters"] で待機する。
			{"id": "srcA", "type": "source", "interarrival": {"type": "const", "a": 2.0},
				"max_arrivals": 1, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "pool", "next": "hold"},
			{"id": "hold", "type": "delay", "duration": {"type": "const", "a": 3.0}, "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "pool", "next": "snkA"},
			{"id": "snkA", "type": "sink"},
		],
	})
	# PF acquire と実 Processor は同一 OperatorPool を共有（bind でプール実体を束縛）。
	m2_pf.bind_objects({"pool": m2_pool, "m2p": "m2p"})
	# 部分実行(t=4): 実 Processor が唯一の作業者を保持し、PF トークンは waiters で待機中の断面。
	#   PF 未確保(dispatched=0, waiting=1) かつ 3D 保持(pool dispatch=1, release=0, op 使用中, 出力0)。
	var m2_kp: Dictionary = m2_pf.run_isolated(4.0, 8080)
	var m2_sp: Dictionary = m2_pf.real_res_stats("pool")
	var m2_wait_before: bool = int(m2_sp.waiting) == 1 and int(m2_sp.dispatched) == 0
	var m2_threed_holds: bool = int(m2_pool.dispatch_count) == 1 and int(m2_pool.release_count) == 0 \
		and m2_op.available == false and int(m2_k.total) == 0
	# 完全実行(t=100): 3D 解放 → 外部フックで PF 起床 → 作業者確保 → delay→release→PF sink 前進。
	var m2_kd: Dictionary = m2_pf.run_isolated(100.0, 8080)
	var m2_st: Dictionary = m2_pf.real_res_stats("pool")
	var m2_bal: bool = m2_pf.real_res_balanced("pool")
	var m2_dispatch: int = int(m2_st.dispatched)
	var m2_release: int = int(m2_st.released)
	var m2_out: int = int(m2_st.outstanding)
	var m2_progressed: bool = int(m2_k.total) > 0             # 3D 側も作業者を得て実 Sink へ出力済み
	# 3D 解放が先: 部分実行で 3D 保持・PF 待機(release=0) を確認 → 完全実行で 3D 解放(release=1)
	# 後に PF が確保(dispatch=1)。唯一作業者ゆえ PF は 3D 解放より前には確保し得ない＝順序が確定。
	var m2_released_first: bool = m2_wait_before and m2_threed_holds \
		and int(m2_pool.release_count) == 1 and m2_dispatch == 1
	# PF トークンが確かに待機を経て起床した: 部分断面で待機、完全実行で確保・解放まで到達。
	var m2_woken: bool = m2_wait_before and m2_dispatch == 1 and m2_release == 1
	var m2_pool_bal: bool = int(m2_pool.dispatch_count) == int(m2_pool.release_count) \
		and m2_op.available == true                          # プール側もリーク無し・作業者返却済み
	var m2_conserve: bool = int(m2_kd.created) == int(m2_kd.sunk) + int(m2_kd.in_flight) \
		and int(m2_kd.in_flight) == 0
	# 決定論: 同一シードで2回 → kpi バイト同一。
	var m2_d1: Dictionary = m2_pf.run_isolated(100.0, 8080)
	var m2_d2: Dictionary = m2_pf.run_isolated(100.0, 8080)
	var m2_det: bool = str(m2_d1) == str(m2_d2)
	var m2_pass: bool = m2_woken and m2_released_first and m2_dispatch == 1 and m2_release == 1 \
		and m2_progressed and m2_out == 0 and m2_bal and m2_pool_bal and m2_conserve and m2_det
	print("[pf-mix-pool2] pf_woken=%s threed_released_first=%s outstanding=%d det=%s pass=%s" % [
		str(m2_woken), str(m2_released_first), m2_out, str(m2_det), str(m2_pass)])

	# ============================================================
	# [pf-travel*] PF タスクシーケンス（確保した REAL 資源の物理移動）と AGV 輻輳との合成の
	# 自己検査（Markers 2/2）。いずれも run_isolated で既定 Source 自走を止め、実プール／実
	# Sink へ束縛して走らせる。既存マーカーは全てこのブロックより前で出力済みなので一切影響
	# しない（追記のみ・値バイト同一）。末尾の rebuild(default) で Sim を既定へ戻す。
	# ============================================================
	Sim.visuals_enabled = false

	# [pf-travel] source→create_item→acquire_resource(transporter)→travel(pickup)→load(const)
	# →travel(dropoff)→unload(実 Sink)→release_resource→sink。トークン滞留時間が
	# (leg1 + load + leg2 + unload) に厳密一致する（期待値は実 transporter.travel_time でレグ毎に
	# 算出して比較）。item が実 Sink へちょうど1回配送される（消失/重複なし・保存則）・決定論も確認。
	editor.rebuild({
		"seed": 20, "warmup": 0, "operators": [],
		"transporters": [{"name": "PTT", "home": [0, 0, 0]}],
		"objects": [{"id": "ptk", "type": "Sink", "name": "PTK", "pos": [15, 0, 20]}],
		"connections": [],
	}, true)
	var pt_pool = editor.ctx.transport_pool
	var pt_tr = editor.ctx.transporters[0]
	var pt_sink = editor.ctx.registry.get("ptk", null)
	# 期待滞留時間: 実 transporter.travel_time で各レグを（更新前 logical_pos 基準で）算出。
	# ネットワーク未設定＝自由流（直行）。leg1: home→pickup, leg2: pickup→dropoff。
	var pt_pickup: Vector3 = Vector3(15, 0, 0)
	var pt_dropoff: Vector3 = Vector3(15, 0, 20)
	var pt_load: float = 2.0
	var pt_unload: float = 1.0
	pt_tr.logical_pos = Vector3(0, 0, 0)
	var pt_l1: float = pt_tr.travel_time(pt_pickup)
	pt_tr.logical_pos = pt_pickup
	var pt_l2: float = pt_tr.travel_time(pt_dropoff)
	pt_tr.logical_pos = Vector3(0, 0, 0)   # 復元（run 開始時に home へ reset される）
	var pt_expected: float = pt_l1 + pt_load + pt_l2 + pt_unload
	var pt_pf := ProcessFlow.new({
		"seed": 9100,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 1, "next": "mk"},
			{"id": "mk", "type": "create_item", "item_type": 0, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "agv", "next": "tp"},
			{"id": "tp", "type": "travel", "to": [15, 0], "state": "to_pickup", "next": "ld"},
			{"id": "ld", "type": "load", "time": {"type": "const", "a": 2.0}, "next": "td"},
			{"id": "td", "type": "travel", "to": [15, 20], "state": "carrying", "next": "ul"},
			{"id": "ul", "type": "unload", "time": {"type": "const", "a": 1.0}, "to": "k", "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "agv", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	pt_pf.bind_objects({"agv": pt_pool, "k": "ptk"})
	var pt_k: Dictionary = pt_pf.run_isolated(1000000.0, 9100)
	var pt_measured: float = float(pt_k.avg_cycle_time)
	var pt_time_ok: bool = abs(pt_measured - pt_expected) <= 1.0e-6
	# 配送はちょうど1回（実 Sink.total==1）。トークンも1件だけ sink 到達。
	var pt_delivered: bool = pt_sink != null and pt_sink.total == 1 and int(pt_k.sunk) == 1
	# 保存則: created==sunk==1・in_flight==0・Sim.wip==0（消失/重複なし）・資源リーク無し。
	var pt_conserve: bool = int(pt_k.created) == 1 and int(pt_k.sunk) == 1 \
		and int(pt_k.in_flight) == 0 and Sim.wip == 0 and pt_pf.real_res_balanced("agv")
	# 決定論: 同一シードで2回 → kpi バイト同一。
	var pt_d1: Dictionary = pt_pf.run_isolated(1000000.0, 9100)
	var pt_d2: Dictionary = pt_pf.run_isolated(1000000.0, 9100)
	var pt_det: bool = str(pt_d1) == str(pt_d2)
	var pt_pass: bool = pt_time_ok and pt_delivered and pt_conserve and pt_det
	print("[pf-travel] measured=%.4f expected=%.4f (l1=%.3f load=%.1f l2=%.3f unload=%.1f) delivered=%s conserve=%s det=%s pass=%s" % [
		pt_measured, pt_expected, pt_l1, pt_load, pt_l2, pt_unload,
		str(pt_delivered), str(pt_conserve), str(pt_det), str(pt_pass)])

	# [pf-travel-congest] 2 PF トークンが各々 transporter を確保し、容量1の共有辺 A-B を渡る。
	# 容量1では単一レーンで直列化し第2トークンが辺占有を待つため makespan(最終完了=最大リード
	# タイム) が伸びる。同一モデルで辺容量=INF（自由流・並走）と比較し congested>freeflow を実証。
	# FIFO/決定論（同一 key を2回）・保存則・ちょうど2件配送も確認。PF logistics が AGV 交通干渉と
	# 合成されることの証明。
	var pc_cong: Dictionary = _pftravel_congest_run(1.0)     # 容量1で直列化（輻輳）
	var pc_cong2: Dictionary = _pftravel_congest_run(1.0)    # 決定論確認の再実行
	var pc_free: Dictionary = _pftravel_congest_run(INF)     # 自由流（容量INF＝ドーマント）
	var pc_congested: float = float(pc_cong.makespan)
	var pc_freeflow: float = float(pc_free.makespan)
	var pc_serialized: bool = pc_congested > pc_freeflow
	var pc_det: bool = str(pc_cong.key) == str(pc_cong2.key)
	var pc_cons: bool = bool(pc_cong.conserve) and bool(pc_free.conserve) \
		and bool(pc_cong.balanced) and bool(pc_free.balanced)
	var pc_delivered_ok: bool = int(pc_cong.delivered) == 2 and int(pc_free.delivered) == 2
	var pc_pass: bool = pc_serialized and pc_det and pc_cons and pc_delivered_ok
	print("[pf-travel-congest] congested_time=%.4f freeflow_time=%.4f congested>freeflow=%s det=%s conserve=%s delivered=%d/%d pass=%s" % [
		pc_congested, pc_freeflow, str(pc_serialized), str(pc_det), str(pc_cons),
		int(pc_cong.delivered), int(pc_free.delivered), str(pc_pass)])

	# [pf-travel-op] Operator 版タスクシーケンス: acquire_resource(operator)→travel(目的地)→
	# delay(work)→release_resource→sink。作業者は非輻輳（travel_time→go_to→Sim.schedule）で、
	# 滞留時間が (travel_time + work) に一致し、travel が距離ベースで反映されることを確認する。
	# 決定論・保存則も検査。
	var pto_pool := OperatorPool.new()
	add_child(pto_pool)
	var pto_op := Operator.new()
	add_child(pto_op)                      # global_position を触る setup は in-tree 後
	pto_op.setup("PTO_Op", Vector3(0, 0, 0))
	pto_pool.add_operator(pto_op)
	pto_op.logical_pos = Vector3(0, 0, 0)
	var pto_dest: Vector3 = Vector3(20, 0, 0)
	var pto_work: float = 2.0
	var pto_exp_travel: float = pto_op.travel_time(pto_dest)   # dist/move_speed = 20/5 = 4.0
	var pto_pf := ProcessFlow.new({
		"seed": 9500,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "const", "a": 1.0},
				"max_arrivals": 1, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "ops", "next": "go"},
			{"id": "go", "type": "travel", "to": [20, 0], "next": "work"},
			{"id": "work", "type": "delay", "duration": {"type": "const", "a": 2.0}, "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "ops", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	pto_pf.bind_objects({"ops": pto_pool})
	var pto_k: Dictionary = pto_pf.run_isolated(1000000.0, 9500)
	var pto_elapsed: float = float(pto_k.avg_cycle_time)
	var pto_expected_total: float = pto_exp_travel + pto_work
	# travel が反映される: 滞留は work 単独より大きく、(travel+work) に厳密一致。
	var pto_travel_reflected: bool = pto_elapsed > pto_work + 1.0e-9 \
		and abs(pto_elapsed - pto_expected_total) <= 1.0e-6
	var pto_conserve: bool = int(pto_k.created) == 1 and int(pto_k.sunk) == 1 \
		and int(pto_k.in_flight) == 0 and Sim.wip == 0 and pto_pf.real_res_balanced("ops")
	# 決定論: 同一シードで2回 → kpi バイト同一。
	var pto_d1: Dictionary = pto_pf.run_isolated(1000000.0, 9500)
	var pto_d2: Dictionary = pto_pf.run_isolated(1000000.0, 9500)
	var pto_det: bool = str(pto_d1) == str(pto_d2)
	var pto_pass: bool = pto_travel_reflected and pto_conserve and pto_det
	print("[pf-travel-op] elapsed=%.4f expected_travel=%.4f (work=%.1f total=%.4f) travel_reflected=%s conserve=%s det=%s pass=%s" % [
		pto_elapsed, pto_exp_travel, pto_work, pto_expected_total,
		str(pto_travel_reflected), str(pto_conserve), str(pto_det), str(pto_pass)])
	# 後片付け（Sim 登録解除 → 以後の rebuild/マーカーに無影響）。
	Sim.unregister(pto_pool); Sim.unregister(pto_op)
	remove_child(pto_pool); pto_pool.queue_free()
	remove_child(pto_op); pto_op.queue_free()

	# ============================================================
	# [pf-persist] Process Flow の保存/読込（Persistence）: モデル JSON の "processflows"
	# を to_dict → save_json → load_json → build で往復し、復元した ProcessFlow の run() kpi が
	# メモリ上 spec の run() kpi とバイト同一（HARD INVARIANT 2）であることを確認する。
	# 併せて bindings（宣言 object_id）が保存され、build で実 FlowObject/プールへ解決されること、
	# 後方互換（processflows 欠落モデルが空配列へ migrate）を検証する。
	# 本ブロックは全既存マーカーの後・cleanup の前に置き、既存 81 マーカーへは干渉しない。
	# ============================================================
	var pfp_parent := Node3D.new()
	add_child(pfp_parent)
	# 参照: 単一資源の論理 PF をメモリ上 spec で直接 run（資源キーが単一＝JSON ソート不変）。
	var pfp_spec := {
		"seed": 4242,
		"resources": {"srv": 1},
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.0},
				"max_arrivals": 300, "next": "acq"},
			{"id": "acq", "type": "acquire", "resource": "srv", "next": "work"},
			{"id": "work", "type": "delay", "duration": {"type": "exp", "a": 0.8}, "next": "rel"},
			{"id": "rel", "type": "release", "resource": "srv", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	}
	var pfp_ref_k: Dictionary = ProcessFlow.new(pfp_spec.duplicate(true)).run(6000.0, 4242)
	# モデルへ埋め込み → to_dict → save → load → build（別 parent。editor.ctx は不変）。
	var pfp_model := {
		"seed": 1, "warmup": 0, "operators": [], "transporters": [],
		"objects": [{"id": "k", "type": "Sink", "name": "K", "pos": [0, 0, 0]}],
		"connections": [],
		"processflows": [{"id": "flow1", "spec": pfp_spec.duplicate(true),
			"bindings": {"probe": "k", "ops": "@operator_pool"}}],
	}
	var pfp_ctx1: Dictionary = io.build(pfp_model, pfp_parent, true)
	var pfp_d1: Dictionary = io.to_dict(pfp_ctx1)
	var pfp_path := "user://pf_persist_selftest.json"
	io.save_json(pfp_path, pfp_d1)
	var pfp_loaded: Dictionary = io.load_json(pfp_path)
	var pfp_ctx2: Dictionary = io.build(pfp_loaded, pfp_parent, true)
	var pfp_rt_k: Dictionary = io.run_processflow(pfp_ctx2, "flow1", 6000.0, 4242)
	var pfp_kpi_match: bool = str(pfp_ref_k) == str(pfp_rt_k)
	# bindings が保存され、build で実オブジェクトへ解決される。
	var pfp_e: Dictionary = (pfp_loaded.get("processflows", []) as Array)[0]
	var pfp_binds: Dictionary = pfp_e.get("bindings", {})
	var pfp_bind_saved: bool = str(pfp_e.get("id", "")) == "flow1" \
		and str(pfp_binds.get("probe", "")) == "k" \
		and str(pfp_binds.get("ops", "")) == "@operator_pool"
	var pfp_flow2 := io.get_processflow(pfp_ctx2, "flow1")
	var pfp_reg2: Dictionary = pfp_ctx2.get("registry", {})
	var pfp_bind_resolved: bool = pfp_flow2 != null \
		and pfp_flow2._resolve_bound("probe") == pfp_reg2.get("k", null) \
		and pfp_flow2._resolve_bound("ops") == pfp_ctx2.get("pool", null)
	# 後方互換: processflows 欠落モデルは空配列へ migrate（version は据え置き v1）。
	var pfp_mig: Dictionary = io.migrate({"version": 1, "seed": 1, "objects": [], "connections": []})
	var pfp_backcompat: bool = (pfp_mig.get("processflows") is Array) \
		and (pfp_mig["processflows"] as Array).is_empty() and int(pfp_mig.get("version", -1)) == 1
	# 安定直列化（不動点）: JSON パースは数値を float へ正規化するため in-memory(int)→初回保存は
	# 表現差が出る（Godot 全体の挙動で PF 固有ではない）。読込後の形を不動点として、以降の
	# save→load がバイト同一になることを確認する（宣言データの往復安定）。
	var pfp_path2 := "user://pf_persist_selftest2.json"
	io.save_json(pfp_path2, pfp_loaded)
	var pfp_reloaded: Dictionary = io.load_json(pfp_path2)
	var pfp_stable: bool = JSON.stringify(pfp_loaded, "\t") == JSON.stringify(pfp_reloaded, "\t")
	var pfp_ok: bool = pfp_kpi_match and pfp_bind_saved and pfp_bind_resolved \
		and pfp_backcompat and pfp_stable
	print("[pf-persist] kpi_match=%s bindings_saved=%s bindings_resolved=%s backcompat=%s stable=%s ok=%s" % [
		str(pfp_kpi_match), str(pfp_bind_saved), str(pfp_bind_resolved),
		str(pfp_backcompat), str(pfp_stable), str(pfp_ok)])
	remove_child(pfp_parent); pfp_parent.queue_free()

	# ============================================================
	# [pf-serialize] PF spec のモデル往復（Serialize）忠実度: travel/acquire_resource を含み
	# bindings（実 TransportPool / 実 Sink）が解決されて初めて走る PF を、to_dict → save_json →
	# load_json → build で往復させ、復元 PF の run_isolated kpi が元 kpi（=in-memory spec の実行）と
	# バイト同一（往復忠実・HARD INVARIANT 2）であることを確認する。併せて同一シード2回で
	# バイト同一（決定論）を確認する。Sim は前後で reset して中立に保つ。
	# ============================================================
	Sim.reset_sim()
	var pfs_parent := Node3D.new()
	add_child(pfs_parent)
	var pfs_spec := {
		"seed": 7373,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.5},
				"max_arrivals": 25, "next": "mk"},
			{"id": "mk", "type": "create_item", "item_type": 0, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "agv", "next": "tp"},
			{"id": "tp", "type": "travel", "to": [15, 0], "state": "to_pickup", "next": "ld"},
			{"id": "ld", "type": "load", "time": {"type": "const", "a": 2.0}, "next": "td"},
			{"id": "td", "type": "travel", "to": "k", "state": "carrying", "next": "ul"},
			{"id": "ul", "type": "unload", "time": {"type": "const", "a": 1.0}, "to": "k", "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "agv", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	}
	var pfs_model := {
		"seed": 20, "warmup": 0, "operators": [],
		"transporters": [{"name": "PFSZ_T", "home": [0, 0, 0]}],
		"objects": [{"id": "pfsz_k", "type": "Sink", "name": "PFSZ_K", "pos": [15, 0, 20]}],
		"connections": [],
		"processflows": [{"id": "flow1", "spec": pfs_spec.duplicate(true),
			"bindings": {"agv": "@transport_pool", "k": "pfsz_k"}}],
	}
	# build → run（実 TransportPool/実 Sink へ束縛済み）→ kpi A（=in-memory spec の実行）。
	var pfs_ctx1: Dictionary = io.build(pfs_model, pfs_parent, true)
	var pfs_kA: Dictionary = io.run_processflow(pfs_ctx1, "flow1", 200000.0, 7373, true)
	# to_dict → save_json → load_json → build → run → kpi B（復元 PF）。
	var pfs_d1: Dictionary = io.to_dict(pfs_ctx1)
	var pfs_path := "user://pf_serialize_selftest.json"
	io.save_json(pfs_path, pfs_d1)
	var pfs_loaded: Dictionary = io.load_json(pfs_path)
	var pfs_ctx2: Dictionary = io.build(pfs_loaded, pfs_parent, true)
	var pfs_kB: Dictionary = io.run_processflow(pfs_ctx2, "flow1", 200000.0, 7373, true)
	var pfs_round_trip_equal: bool = str(pfs_kA) == str(pfs_kB)
	# 決定論: 復元 PF を同一シードで2回 → kpi バイト同一。
	var pfs_b1: Dictionary = io.run_processflow(pfs_ctx2, "flow1", 200000.0, 7373, true)
	var pfs_b2: Dictionary = io.run_processflow(pfs_ctx2, "flow1", 200000.0, 7373, true)
	var pfs_det: bool = str(pfs_b1) == str(pfs_b2)
	# bindings が効いて実際に配送された（travel/acquire_resource が空回りしていない）ことも確認。
	var pfs_delivered: bool = int(pfs_kA.get("sunk", 0)) > 0 and int(pfs_kA.get("in_flight", -1)) == 0
	var pfs_pass: bool = pfs_round_trip_equal and pfs_det and pfs_delivered
	print("[pf-serialize] round_trip_equal=%s det=%s delivered=%s sunk=%d pass=%s" % [
		str(pfs_round_trip_equal), str(pfs_det), str(pfs_delivered),
		int(pfs_kA.get("sunk", 0)), str(pfs_pass)])
	remove_child(pfs_parent); pfs_parent.queue_free()
	Sim.reset_sim()

	# ============================================================
	# [pf-lint] 静的検査（lint）の欠陥検出: 既知欠陥（unknown_next / 未宣言 resource /
	# unreachable_activity / missing_sink）を仕込んだ spec で各コードが検出されることを確認し、
	# clean な spec では診断ゼロ（空配列）であることを確認する。lint は純粋 static（rng/イベント
	# 不使用）なので Sim 状態に一切触れない＝既存マーカーへ無影響。
	# ============================================================
	var lint_bad := {
		"resources": {},   # srv を宣言しない → acquire で unknown_resource（未束縛/未宣言 resource）
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 1.0},
				"max_arrivals": 10, "next": "acq"},
			{"id": "acq", "type": "acquire", "resource": "srv", "next": "work"},                    # unknown_resource
			{"id": "work", "type": "delay", "duration": {"type": "const", "a": 1.0}, "next": "ghost"},  # unknown_next
			{"id": "orphan", "type": "delay", "duration": {"type": "const", "a": 1.0}, "next": "src"}, # unreachable_activity
		],
		# sink アクティビティ無し → source グラフが sink に到達しない → missing_sink
	}
	var lint_diags: Array = ProcessFlow.lint(lint_bad)
	var lint_codes: Dictionary = {}
	for d in lint_diags:
		lint_codes[str((d as Dictionary).get("code", ""))] = true
	var lint_has_unknown_next: bool = lint_codes.has("unknown_next")
	var lint_has_unknown_res: bool = lint_codes.has("unknown_resource")
	var lint_has_unreachable: bool = lint_codes.has("unreachable_activity")
	var lint_has_missing_sink: bool = lint_codes.has("missing_sink")
	var lint_defects_found: bool = lint_has_unknown_next and lint_has_unknown_res \
		and lint_has_unreachable and lint_has_missing_sink
	# clean な spec（資源宣言済み・全到達・sink 到達）→ 診断ゼロ。
	var lint_clean := {
		"resources": {"srv": 1},
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "exp", "a": 2.0},
				"max_arrivals": 50, "next": "acq"},
			{"id": "acq", "type": "acquire", "resource": "srv", "next": "work"},
			{"id": "work", "type": "delay", "duration": {"type": "const", "a": 1.0}, "next": "rel"},
			{"id": "rel", "type": "release", "resource": "srv", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	}
	var lint_clean_diags: Array = ProcessFlow.lint(lint_clean)
	var lint_clean_empty: bool = lint_clean_diags.is_empty()
	var lint_pass: bool = lint_defects_found and lint_clean_empty
	print("[pf-lint] defects_found=%s n=%d codes=%s clean_empty=%s pass=%s" % [
		str(lint_defects_found), lint_diags.size(), str(lint_codes.keys()),
		str(lint_clean_empty), str(lint_pass)])

	# ============================================================
	# [samples] サンプルライブラリ自己検証。samples/index.json に登録された各サンプルを
	# ModelIO 経由で読み込み(load_sample)→構築(build)→実行し、各モデルの meta.expected に
	# 記載された理論/期待値に対して documented tolerance 内かを判定する。待ち行列系
	# (M/M/1・M/M/c) は複数レプリケーションで平均±95%CI を出し「理論値が CI 内」で合否、
	# 決定的な PF/AGV/ライン系は単一ランで相対誤差／厳密一致で合否。すべて追加のみ・
	# オプトイン：この block は既存 84 マーカーの出力後に実行され（＝それらへ無影響）、
	# 各サンプルの前後で Sim を reset する。
	# ============================================================
	Sim.visuals_enabled = false
	var smp_tokens: Array = []
	var smp_total: int = 0
	var smp_passed: int = 0

	# 掃除: 直前の [pf-serialize] は build した Process Flow モデルを Sim から unregister せずに
	# queue_free するため、それらのオブジェクト（transporter/pool 等）が tree 外のまま Sim.objects
	# に残存している。サンプル実行前に tree 外／無効な登録を外し、以後の reset で dangling 参照へ
	# 触れて落ちるのを防ぐ（現行モデルのオブジェクトは tree 内なので残る＝無影響）。
	for _orphan in Sim.objects.duplicate():
		if not is_instance_valid(_orphan):
			Sim.unregister(_orphan)
		elif _orphan is Node and not (_orphan as Node).is_inside_tree():
			Sim.unregister(_orphan)

	# --- 1) mm1_queue: M/M/1（stochastic・レプリケーション・理論値の CI 内包） ---
	Sim.reset_sim()
	var smA: Dictionary = io.load_sample("mm1_queue")
	var smA_exp: Dictionary = (smA.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smA)
	var smA_r: Dictionary = _mm_replicate_sync(5, 2000.0, 8000.0, 33001, "q", ["p"])
	var smA_ue: float = float(smA_exp.get("rho_util", 0.8))
	var smA_lqe: float = float(smA_exp.get("Lq", 3.2))
	var smA_wqe: float = float(smA_exp.get("Wq", 4.0))
	var smA_uok: bool = abs(smA_r.util_mean - smA_ue) <= 0.05 or _theory_match(smA_r.util_mean, smA_r.util_ci, smA_ue, 0.10)
	var smA_lok: bool = _theory_match(smA_r.lq_mean, smA_r.lq_ci, smA_lqe, 0.15)
	var smA_wok: bool = _theory_match(smA_r.wq_mean, smA_r.wq_ci, smA_wqe, 0.15)
	var smA_ok: bool = smA_uok and smA_lok and smA_wok
	smp_total += 1; smp_passed += (1 if smA_ok else 0)
	smp_tokens.append("mm1(util %.2f~%.2f %s)" % [smA_r.util_mean, smA_ue, ("ok" if smA_ok else "FAIL")])
	print("[sample:mm1] measured=util%.3f expected=%.3f within_tol=%s | Lq=%.3f(exp%.3f ci±%.3f) Wq=%.3f(exp%.3f ci±%.3f)" % [
		smA_r.util_mean, smA_ue, str(smA_ok),
		smA_r.lq_mean, smA_lqe, smA_r.lq_ci, smA_r.wq_mean, smA_wqe, smA_r.wq_ci])
	Sim.reset_sim()

	# --- 2) mmc_multiserver: M/M/c(c=2)（util 必須＋Lq を Erlang-C の CI 内包） ---
	var smB: Dictionary = io.load_sample("mmc_multiserver")
	var smB_exp: Dictionary = (smB.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smB)
	var smB_r: Dictionary = _mm_replicate_sync(5, 2000.0, 8000.0, 44001, "q", ["p1", "p2"])
	var smB_ue: float = float(smB_exp.get("rho_util", 0.75))
	var smB_lqe: float = float(smB_exp.get("Lq_erlangC", 1.9286))
	var smB_uok: bool = abs(smB_r.util_mean - smB_ue) <= 0.05 or _theory_match(smB_r.util_mean, smB_r.util_ci, smB_ue, 0.10)
	var smB_lok: bool = _theory_match(smB_r.lq_mean, smB_r.lq_ci, smB_lqe, 0.20)
	var smB_ok: bool = smB_uok and smB_lok
	smp_total += 1; smp_passed += (1 if smB_ok else 0)
	smp_tokens.append("mmc(util %.2f~%.2f %s)" % [smB_r.util_mean, smB_ue, ("ok" if smB_ok else "FAIL")])
	print("[sample:mmc] measured=util%.3f expected=%.3f within_tol=%s | Lq=%.3f(exp%.4f ci±%.3f)" % [
		smB_r.util_mean, smB_ue, str(smB_ok), smB_r.lq_mean, smB_lqe, smB_r.lq_ci])
	Sim.reset_sim()

	# --- 3) serial_line_buffer: ボトルネックスループット（決定的単一ラン, 3%内） ---
	var smC: Dictionary = io.load_sample("serial_line_buffer")
	var smC_exp: Dictionary = (smC.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smC)
	Sim.warmup = 200.0; Sim.reset_sim(); Sim.run_until(200.0 + 6000.0)
	var smC_thr: float = Sim.collect_kpi().throughput / 3600.0
	var smC_exp_thr: float = float(smC_exp.get("throughput_per_unit", 0.5))
	var smC_ok: bool = _rel_err(smC_thr, smC_exp_thr) < 0.03
	smp_total += 1; smp_passed += (1 if smC_ok else 0)
	smp_tokens.append("serial(thr=%.3f~%.3f %s)" % [smC_thr, smC_exp_thr, ("ok" if smC_ok else "FAIL")])
	print("[sample:serial] measured=%.4f expected=%.4f within_tol=%s (rel=%.4f)" % [
		smC_thr, smC_exp_thr, str(smC_ok), _rel_err(smC_thr, smC_exp_thr)])
	Sim.reset_sim()

	# --- 4) shared_operator: 単一作業者が共有ボトルネック（8%内＋作業者稼働率>0.9） ---
	var smD: Dictionary = io.load_sample("shared_operator")
	var smD_exp: Dictionary = (smD.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smD)
	Sim.warmup = 0.0; Sim.reset_sim(); Sim.run_until(6000.0)
	var smD_thr: float = Sim.collect_kpi().throughput / 3600.0
	var smD_util: float = editor.ctx.operators[0].utilization() if editor.ctx.operators.size() > 0 else 0.0
	var smD_exp_thr: float = float(smD_exp.get("combined_throughput_shared_per_unit", 0.1))
	var smD_ok: bool = _rel_err(smD_thr, smD_exp_thr) < 0.08 and smD_util > 0.9
	smp_total += 1; smp_passed += (1 if smD_ok else 0)
	smp_tokens.append("shared(thr=%.3f~%.3f %s)" % [smD_thr, smD_exp_thr, ("ok" if smD_ok else "FAIL")])
	print("[sample:shared] measured=%.4f expected=%.4f within_tol=%s (op_util=%.3f>0.9=%s)" % [
		smD_thr, smD_exp_thr, str(smD_ok), smD_util, str(smD_util > 0.9)])
	Sim.reset_sim()

	# --- 5) setup_changeover: 毎ジョブ段取りで実効能力=1/(proc+setup)=1/7（3%内） ---
	var smE: Dictionary = io.load_sample("setup_changeover")
	var smE_exp: Dictionary = (smE.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smE)
	Sim.warmup = 0.0; Sim.reset_sim(); Sim.run_until(7000.0)
	var smE_thr: float = Sim.collect_kpi().throughput / 3600.0
	var smE_exp_thr: float = float(smE_exp.get("effective_capacity_per_unit", 1.0 / 7.0))
	var smE_ok: bool = _rel_err(smE_thr, smE_exp_thr) < 0.03
	smp_total += 1; smp_passed += (1 if smE_ok else 0)
	smp_tokens.append("setup(thr=%.4f~%.4f %s)" % [smE_thr, smE_exp_thr, ("ok" if smE_ok else "FAIL")])
	print("[sample:setup] measured=%.5f expected=%.5f within_tol=%s (rel=%.4f)" % [
		smE_thr, smE_exp_thr, str(smE_ok), _rel_err(smE_thr, smE_exp_thr)])
	Sim.reset_sim()

	# --- 6) breakdown_mtbf: availability=MTBF/(MTBF+MTTR)=0.9 → thr≈0.9（5%内） ---
	var smF: Dictionary = io.load_sample("breakdown_mtbf")
	var smF_exp: Dictionary = (smF.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smF)
	Sim.warmup = 0.0; Sim.reset_sim(); Sim.run_until(10000.0)
	var smF_thr: float = Sim.collect_kpi().throughput / 3600.0
	var smF_exp_thr: float = float(smF_exp.get("throughput_per_unit", 0.9))
	var smF_ok: bool = _rel_err(smF_thr, smF_exp_thr) < 0.05
	smp_total += 1; smp_passed += (1 if smF_ok else 0)
	smp_tokens.append("breakdown(thr=%.3f~%.3f %s)" % [smF_thr, smF_exp_thr, ("ok" if smF_ok else "FAIL")])
	print("[sample:breakdown] measured=%.4f expected=%.4f within_tol=%s (rel=%.4f)" % [
		smF_thr, smF_exp_thr, str(smF_ok), _rel_err(smF_thr, smF_exp_thr)])
	Sim.reset_sim()

	# --- 7) conveyor_accumulation: 満杯(=5)ブロック占有 + ボトルネックスループット0.05（6%内） ---
	var smG: Dictionary = io.load_sample("conveyor_accumulation")
	var smG_exp: Dictionary = (smG.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smG)
	Sim.warmup = 0.0; Sim.reset_sim(); Sim.run_until(35.0)
	var smG_conv = editor.ctx.registry.get("conv", null)
	var smG_occ: int = smG_conv.occupancy() if smG_conv != null else -1
	var smG_state: String = smG_conv.state if smG_conv != null else "?"
	var smG_exp_occ: int = int(smG_exp.get("accumulated_occupancy", 5))
	Sim.run_until(20035.0)
	var smG_thr: float = Sim.collect_kpi().throughput / 3600.0
	var smG_exp_thr: float = float(smG_exp.get("throughput_per_unit", 0.05))
	var smG_ok: bool = smG_occ == smG_exp_occ and smG_state == "blocked" and _rel_err(smG_thr, smG_exp_thr) < 0.06
	smp_total += 1; smp_passed += (1 if smG_ok else 0)
	smp_tokens.append("conveyor(occ=%d thr=%.3f %s)" % [smG_occ, smG_thr, ("ok" if smG_ok else "FAIL")])
	print("[sample:conveyor] measured=occ%d/thr%.4f expected=occ%d/thr%.4f within_tol=%s (state=%s)" % [
		smG_occ, smG_thr, smG_exp_occ, smG_exp_thr, str(smG_ok), smG_state])
	Sim.reset_sim()

	# --- 8) agv_congestion: 容量1辺で直列化しリードタイム増（輻輳 vs 自由流, 厳密大小） ---
	var smH: Dictionary = io.load_sample("agv_congestion")
	editor.rebuild(smH)
	Sim.warmup = 0.0; Sim.reset_sim(); Sim.run_until(600.0)
	var smH_lead_cong: float = editor.ctx.sink.avg_time_in_system()
	var smH_sink_cong: int = editor.ctx.sink.total
	var smH_free: Dictionary = io.load_sample("agv_congestion")
	(smH_free["network"] as Dictionary)["edge_capacities"] = []   # 辺容量撤廃＝自由流(INF)
	editor.rebuild(smH_free)
	Sim.warmup = 0.0; Sim.reset_sim(); Sim.run_until(600.0)
	var smH_lead_free: float = editor.ctx.sink.avg_time_in_system()
	var smH_sink_free: int = editor.ctx.sink.total
	var smH_ok: bool = smH_lead_cong > smH_lead_free and smH_sink_cong > 0 and smH_sink_free > 0
	smp_total += 1; smp_passed += (1 if smH_ok else 0)
	smp_tokens.append("agv(cong%.1f>free%.1f %s)" % [smH_lead_cong, smH_lead_free, ("ok" if smH_ok else "FAIL")])
	print("[sample:agv] measured=lead_cong%.3f expected=>lead_free%.3f within_tol=%s (sink_cong=%d sink_free=%d)" % [
		smH_lead_cong, smH_lead_free, str(smH_ok), smH_sink_cong, smH_sink_free])
	Sim.reset_sim()

	# --- 9) processflow_logistics: acquire→travel→load→travel→unload→release 配送サイクル=10.0（厳密1e-6） ---
	var smI: Dictionary = io.load_sample("processflow_logistics")
	var smI_exp: Dictionary = (smI.get("meta", {}) as Dictionary).get("expected", {})
	editor.rebuild(smI)
	var smI_k: Dictionary = io.run_processflow(editor.ctx, "logistics", 1000000.0, 9100, true)
	var smI_cycle: float = float(smI_k.get("avg_cycle_time", -1.0))
	var smI_exp_cycle: float = float(smI_exp.get("delivered_cycle_time", 10.0))
	var smI_ok: bool = abs(smI_cycle - smI_exp_cycle) <= 1.0e-6 and int(smI_k.get("sunk", 0)) == 1
	smp_total += 1; smp_passed += (1 if smI_ok else 0)
	smp_tokens.append("pf(cycle=%.3f~%.3f %s)" % [smI_cycle, smI_exp_cycle, ("ok" if smI_ok else "FAIL")])
	print("[sample:pf] measured=%.6f expected=%.6f within_tol=%s (sunk=%d)" % [
		smI_cycle, smI_exp_cycle, str(smI_ok), int(smI_k.get("sunk", 0))])
	Sim.reset_sim()

	# --- 10) experiment_optimize_demo: 掃引で単調非減少・最適化が到着率(3600/h)で飽和（5%内） ---
	var smJ: Dictionary = io.load_sample("experiment_optimize_demo")
	editor.rebuild(smJ)
	var smJ_cur: Dictionary = editor.ctx.registry["p"].get_params()
	var smJ_scen: Array = Sim.build_sweep_scenarios("p", "process_time.a", [2.0, 1.5, 1.0, 0.5], smJ_cur)
	var smJ_res: Dictionary = Sim.run_scenarios(smJ_scen, 3, 3600.0, 200.0, 12345)
	var smJ_thrs: Array = []
	for smj_sc in smJ_res.scenarios:
		smJ_thrs.append(float(smj_sc.thr_mean))
	var smJ_mono: bool = true
	for smj_i in range(1, smJ_thrs.size()):
		if smJ_thrs[smj_i] < smJ_thrs[smj_i - 1] - max(5.0, smJ_thrs[smj_i - 1] * 0.01):
			smJ_mono = false
	var smJ_opt: Dictionary = Sim.optimize(
		[{"obj_id": "p", "param": "process_time.a", "min": 0.5, "max": 2.0, "step": 0.5}],
		{"metric": "throughput", "sense": "max"}, "grid", 64, 3, 3600.0, 200.0, 12345)
	var smJ_arr_h: float = 3600.0   # 到着率 1.0/unit = 3600/h（飽和スループット）
	var smJ_best_ok: bool = _rel_err(float(smJ_opt.best_obj), smJ_arr_h) < 0.05
	var smJ_ok: bool = smJ_mono and smJ_best_ok
	smp_total += 1; smp_passed += (1 if smJ_ok else 0)
	smp_tokens.append("opt(best=%.0f mono=%s %s)" % [float(smJ_opt.best_obj), str(smJ_mono), ("ok" if smJ_ok else "FAIL")])
	print("[sample:opt] measured=best_obj%.1f/h expected~%.1f/h within_tol=%s (sweep/h=[%.0f,%.0f,%.0f,%.0f] mono=%s best=%s)" % [
		float(smJ_opt.best_obj), smJ_arr_h, str(smJ_ok),
		smJ_thrs[0], smJ_thrs[1], smJ_thrs[2], smJ_thrs[3], str(smJ_mono), str(smJ_opt.best)])
	Sim.reset_sim()

	# --- 集計 [samples] ---
	var smp_all: bool = smp_passed == smp_total
	print("[samples] n=%d passed=%d %s all_pass=%s" % [
		smp_total, smp_passed, " ".join(PackedStringArray(smp_tokens)), str(smp_all)])

	# ============================================================
	# [agv-spillback] / [agv-node-live]: ノード（交差点）容量が実際に効く（no-op でない）ことの
	# 追加実証（Markers 2/2）。既存 [agv-node] が node cap の輻輳効果を示すのに続き、ここでは
	# (1) ブロッキングバック（スピルバック）: 満杯ノードで詰まった搬送者が辺を保持し上流を遅延
	# させること、かつその遅延が「下流ノード満杯」由来で「辺容量だけ」では説明できないこと、
	# (2) 素朴予約なら循環待ちでデッドロックし得る競合（4方向 head-on 交差, 中心 cap1）でも
	# 全車が必ず完走する liveness、を示す。全て有限ノード容量を明示設定したモデル内でのみ動作し、
	# 本ブロックは全既存マーカーの後に実行される（追記のみ）。末尾の既定モデル再構築で node 容量は
	# INF へ戻り、既存マーカーはバイト一致のまま（＝ドーマント）。
	# --- [agv-spillback] 純データ因果チェーン（決定的・乱数不使用）: 満杯ノードで辺が保持され上流が
	#     待つこと、その原因が「辺容量」でなく「下流ノード満杯」であることを対照実験で分離する ---
	var sbk_net := TransportNetwork.new(
		{"A": [0, 0, 0], "B": [10, 0, 0], "C": [20, 0, 0]},
		[["A", "B"], ["B", "C"]])
	sbk_net.set_edge_capacity("B", "C", 1.0)   # 辺 B-C は単一レーン（容量1）
	sbk_net.set_node_capacity("C", 1.0)        # 交差点 C 容量1
	var sbk_up_woke: Array = []
	var sbk_park: bool = sbk_net.request_node("C", "park", Callable())            # C を先客が占有（占有1）
	var sbk_down_edge: bool = sbk_net.request_edge("B", "C", "down", "B", Callable())  # down が辺を確保・横断
	# down は到達側 C へ入ろうとするが満杯 → false。以後 down は【辺 B-C を保持したまま】C を待つ
	# （＝スピルバック: 下流ノード満杯が辺を解放させない）。cb は起床時に辺を解放する block-section 前進。
	var sbk_down_node: bool = sbk_net.request_node("C", "down", func(): sbk_net.finish_edge("B", "C", "down", "B"))
	var sbk_edge_held: int = sbk_net.edge_occupancy("B", "C")                     # =1（down が辺を離さない）
	# 上流 up が同方向で辺 B-C へ進入したい → down が辺を保持中なので不可（FIFO 待機＝上流の遅延）。
	var sbk_up_edge: bool = sbk_net.request_edge("B", "C", "up", "B", func(): sbk_up_woke.append(1))
	var sbk_up_blocked: bool = (not sbk_up_edge) and sbk_up_woke.is_empty() and sbk_edge_held == 1
	# 下流ノード C を解放 → FIFO で down が C を得て cb で辺を解放 → はじめて up が辺を取得（因果連鎖）。
	sbk_net.finish_node("C", "park")
	var sbk_up_freed: bool = sbk_up_woke == [1]        # up は「下流ノード解放後」にのみ前進できた
	var sbk_inv1: bool = sbk_net.node_occupancy_within_capacity() and sbk_net.occupancy_within_capacity()
	# 対照実験: 辺容量は同じ1・ノード C だけ容量2 にすると、down は即 C を得て辺を解放でき、up は一切
	# 待たされない ⇒ 上流ブロックの原因は「辺容量」ではなく「ノード満杯」だと分離できる。
	var sbk_net2 := TransportNetwork.new(
		{"A": [0, 0, 0], "B": [10, 0, 0], "C": [20, 0, 0]},
		[["A", "B"], ["B", "C"]])
	sbk_net2.set_edge_capacity("B", "C", 1.0)
	sbk_net2.set_node_capacity("C", 2.0)
	sbk_net2.request_node("C", "park", Callable())
	sbk_net2.request_edge("B", "C", "down", "B", Callable())
	var sbk2_down_node: bool = sbk_net2.request_node("C", "down", Callable())   # 空きあり → 即 true
	if sbk2_down_node:
		sbk_net2.finish_edge("B", "C", "down", "B")                            # 即 C 確保 → 辺を即解放
	var sbk2_up: bool = sbk_net2.request_edge("B", "C", "up", "B", Callable())  # true（辺は解放済み＝上流フリー）
	var sbk_node_causes: bool = sbk_up_blocked and sbk2_down_node and sbk2_up
	# --- [agv-spillback] (wall-clock) 辺は両ランで同一(INF)・交差点 B の cap1 vs INF でメイクスパン
	#     比較。辺が同一なので差はノード起因のみ。cap1 では上流搬送者が B で直列化し完了が遅延する ---
	var spl_cong: Dictionary = _agvspill_run(1.0)
	var spl_cong2: Dictionary = _agvspill_run(1.0)
	var spl_free: Dictionary = _agvspill_run(INF)
	var spl_mkup: bool = float(spl_cong.makespan) > float(spl_free.makespan)
	var spl_det: bool = is_equal_approx(float(spl_cong.makespan), float(spl_cong2.makespan)) \
		and int(spl_cong.sink) == int(spl_cong2.sink)
	var spl_cons: bool = bool(spl_cong.conserve) and bool(spl_free.conserve)
	var spl_inv: bool = int(spl_cong.peak_node_b) == 1 and bool(spl_cong.node_inv) and sbk_inv1
	var spl_upstream_delayed: bool = sbk_node_causes and sbk_up_freed and spl_mkup
	var spl_ok: bool = spl_upstream_delayed and spl_inv and spl_det and spl_cons
	print("[agv-spillback] upstream_delayed=%s edge_held=%d node_causes(cap1_blocked=%s,cap2_free=%s)=%s freed_after_node_release=%s makespan_cong=%.2f>free=%.2f=%s peak_b=%d inv=%s det=%s conserve=%s pass=%s" % [
		str(spl_upstream_delayed), sbk_edge_held, str(sbk_up_blocked), str(sbk2_up), str(sbk_node_causes),
		str(sbk_up_freed), float(spl_cong.makespan), float(spl_free.makespan), str(spl_mkup),
		int(spl_cong.peak_node_b), str(spl_inv), str(spl_det), str(spl_cons), str(spl_ok)])

	# --- [agv-node-live] 4方向 head-on 交差（中心 X 容量1, 端点 INF, 隣接辺は全て INF）。水平 W↔E・
	#     垂直 S↔N の対向2ペア計4フローが X だけを奪い合う。素朴な「次ノードを握ってから進む」予約なら
	#     4アームが互いに X を待って循環デッドロックし得るが、X の隣接辺が全て INF（有限ノードが有限辺
	#     に隣接しない＝fable5 erratum の安全条件を満たす）ため block-section 方式で全フローが完走する
	#     （liveness）。※安全なのは「端点 INF」だからではなく「有限ノード X が有限辺に隣接しない」から。
	#     有限辺に隣接すると端点 INF でもデッドロックする（反例＝[agv-node-deadlock]）。
	#     決定論・保存則・占有不変も確認する。---
	var ndl1: Dictionary = _agvnodelive_run()
	var ndl2: Dictionary = _agvnodelive_run()
	var ndl_all: bool = bool(ndl1.all)
	var ndl_det: bool = str(ndl1.key) == str(ndl2.key)
	var ndl_cons: bool = bool(ndl1.conserve)
	var ndl_inv: bool = int(ndl1.peak_x) == 1 and bool(ndl1.node_inv)
	var ndl_ok: bool = ndl_all and ndl_det and ndl_cons and ndl_inv
	print("[agv-node-live] sinkWE=%d sinkEW=%d sinkSN=%d sinkNS=%d all_completed=%s peakX=%d cap=1 inv=%s det=%s conserve=%s pass=%s" % [
		int(ndl1.he), int(ndl1.hw), int(ndl1.vn), int(ndl1.vs), str(ndl_all),
		int(ndl1.peak_x), str(ndl_inv), str(ndl_det), str(ndl_cons), str(ndl_ok)])

	# ============================================================
	# [agv-node-deadlock] fable5 erratum の反例。安全条件「対向流経路上で有限容量ノードを有限容量辺に
	# 隣接させない」を破った実行不能レイアウト（有限ノード X(cap1)＋隣接する有限辺 W-X(cap1)＋対向流
	# W→X→E / E→X→W）を構築し、端点 W,E が INF（車庫）でも循環デッドロックすることを実証する。
	# TA(W→E) は有限辺 W-X を W 方向に横断中（＝方向ロックで X をブロック）、TB(E→W) は短い INF 辺
	# E-X で先に X を確保し辺 X-W(=W-X) を要求 → TA が横断を終えて X を要求 → TB が辺を保持したまま X を
	# 握り続ける＝循環待ち。有界ラン（run_until 上限で必ず返る＝ハングしない）＋ストールウォッチドッグ
	# is_stalled()（待機列に残る搬送者を検出）＋「フェーズ2で完了数が一切増えない（進捗ゼロ）」で
	# 恒久デッドロックを確定する。「実行不能レイアウトが確かにストールする」ことの検証なのでデッドロック
	# を検出できたら pass。あわせて静的診断 lint_layout() が危険な隣接を1件以上警告することも確認する。
	# 本ブロックは全既存マーカーの後・末尾の既定モデル再構築の前に置く（追記のみ／既存マーカー不変）。
	var ddl1: Dictionary = _agvnodedeadlock_run()
	var ddl2: Dictionary = _agvnodedeadlock_run()
	var ddl_stall: bool = bool(ddl1.stalled)                              # ウォッチドッグ確定（待機残＋進捗ゼロ）
	var ddl_watchdog: bool = bool(ddl1.watchdog)                          # is_stalled() 生値
	var ddl_incomplete: bool = int(ddl1.completed) < int(ddl1.expected)  # 全アイテムが流れ切っていない
	var ddl_det: bool = str(ddl1.key) == str(ddl2.key)                    # 決定論（2ラン一致）
	var ddl_lint: Array = ddl1.lint                                       # 静的診断の警告列
	var ddl_lint_ok: bool = ddl_lint.size() >= 1                          # 反例レイアウトを1件以上フラグ
	var ddl_ok: bool = ddl_stall and ddl_watchdog and ddl_incomplete and ddl_det and ddl_lint_ok
	print("[agv-node-deadlock] detected_stall=%s completed=%d expected=%d completed<expected=%s watchdog_fired=%s waiters=%d busy_stuck=%d lint_warns=%d det=%s pass=%s" % [
		str(ddl_stall), int(ddl1.completed), int(ddl1.expected), str(ddl_incomplete),
		str(ddl_watchdog), int(ddl1.waiters), int(ddl1.busy), ddl_lint.size(), str(ddl_det), str(ddl_ok)])

	# 既定モデルへ戻す（後片付け）
	Sim.visuals_enabled = true
	editor.rebuild(io.default_model())

	get_tree().quit()

## [rack] 補助: 容量6のラックへ id=1..6 を投入（下流なしで満杯）→ 下流 Queue を接続して
## payout させ、Queue の格納順（＝払い出し順）の item.id 配列を返す。方策 policy で順が変わる。
## 生成/破棄したノードは Sim から登録解除して以後のマーカーへ影響させない（決定的）。
func _rack_payout_order(policy: String) -> Array:
	var rk := Rack.new()
	add_child(rk)
	rk.set_params({"bays": 3, "levels": 2, "retrieve_policy": policy, "put_time": 0.0, "get_time": 0.0})
	# 下流なしで 1..6 を投入（払い出し不可 → 全数格納）
	for i in range(6):
		var it := FlowItem.new()
		it.id = i + 1
		it.setup(0, Color.WHITE, false)
		rk.receive_item(it)
	# 下流 Queue を接続して払い出し（下流回復 payout）
	var q := Queue.new()
	q.capacity = 50
	add_child(q)
	rk.connect_to(q)
	rk._retry_push()
	var ids: Array = []
	for it2 in q.items:
		ids.append(it2.id)
	# 後片付け（Sim 登録解除 → 以後のマーカーに無影響）
	rk.disconnect_all()
	Sim.unregister(rk)
	Sim.unregister(q)
	remove_child(rk); rk.queue_free()
	remove_child(q); q.queue_free()
	return ids

## 保存則 created == Σsink.total + Sim.wip が成立するか（warmup=0 前提）。
func _conserve_ok() -> bool:
	var k: Dictionary = Sim.collect_kpi()
	return k.created == k.out + Sim.wip

## 状態時間の恒等式: Σ obj.state_durations() が elapsed に一致するか（相対誤差<0.5%）。
## 状態時間は時間軸の分割（partition）なので合計は必ず経過時間になる。合計が経過を
## 超えれば「down 中に busy/idle も同時計上」等の二重計上が起きている証拠になる。
## → identity=true は「down 中に busy/idle が増えない（重複計上が無い）」ことの確認でもある。
func _state_identity_ok(obj, elapsed: float) -> bool:
	if elapsed <= 0.0:
		return false
	var d: Dictionary = obj.state_durations()
	var s: float = 0.0
	for k in d:
		s += float(d[k])
	return abs(s - elapsed) <= elapsed * 0.005

## Erlang-B 損失確率 B(c,a) を反復で計算（a=提供トラフィック λ/μ, c=サーバ数）。
func _erlang_b(c: int, a: float) -> float:
	var b: float = 1.0
	for k in range(1, c + 1):
		b = (a * b) / (float(k) + a * b)
	return b

## Erlang-C 待ち確率 C(c,a)。B から C = c·B / (c − a·(1−B)) で導出。
func _erlang_c(c: int, a: float) -> float:
	var b: float = _erlang_b(c, a)
	var denom: float = float(c) - a * (1.0 - b)
	if denom <= 0.0:
		return 1.0
	return (float(c) * b) / denom

## M/M/c の平均待ち行列長 Lq = C(c,a)·ρ/(1−ρ)（ρ=a/c, a=λ/μ）。
func _mmc_lq(c: int, lam: float, mu: float) -> float:
	var a: float = lam / mu
	var rho: float = a / float(c)
	if rho >= 1.0:
		return INF
	return _erlang_c(c, a) * rho / (1.0 - rho)

## 相対誤差<tol もしくは理論値が [mean−ci, mean+ci] に入れば true（外部真値突合の合否）。
func _theory_match(sim_mean: float, ci: float, theory: float, tol: float) -> bool:
	var rel: float = _rel_err(sim_mean, theory)
	var in_ci: bool = ci > 0.0 and theory >= sim_mean - ci and theory <= sim_mean + ci
	return rel < tol or in_ci

## calendar-down 検証用ミニモデル。到着間隔を長くしてアイドル時間を作り、
## mtbf_basis で故障基準を切り替える。Processor P の状態内訳を返す。
func _calendar_down_run(basis: String) -> Dictionary:
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 50.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [5, 0, 0],
				"params": {"process_time": {"type": "const", "a": 5.0},
					"mtbf": {"type": "const", "a": 20.0}, "mtbf_basis": basis,
					"mttr": {"type": "const", "a": 5.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	Sim.run_until(300.0)
	var p = editor.ctx.registry.get("p", null)
	if p == null:
		return {}
	var d: Dictionary = p.state_durations()
	return {"down": float(d.get("down", 0.0)), "idle": float(d.get("idle", 0.0)),
		"busy": float(d.get("busy", 0.0))}

## M/M/1 モデル構築（Source(exp)→Queue(大容量)→Processor(exp)→Sink、作業者/故障/段取り無し）。
func _build_mm1(cap: int, ia_mean: float, proc_mean: float) -> void:
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "exp", "a": ia_mean}, "type_count": 1}},
			{"id": "q", "type": "Queue", "name": "Q", "pos": [5, 0, 0],
				"params": {"capacity": cap}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "exp", "a": proc_mean},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [15, 0, 0]},
		],
		"connections": [["s", "q"], ["q", "p"], ["p", "k"]],
	}, true)

## M/M/c モデル構築（Source(exp)→Queue(大容量)→c=2並列 Processor(exp)→Sink）。
func _build_mmc(cap: int, ia_mean: float, proc_mean: float) -> void:
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "exp", "a": ia_mean}, "type_count": 1}},
			{"id": "q", "type": "Queue", "name": "Q", "pos": [5, 0, 0],
				"params": {"capacity": cap}},
			{"id": "p1", "type": "Processor", "name": "P1", "pos": [10, 0, 1.5],
				"params": {"process_time": {"type": "exp", "a": proc_mean},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "p2", "type": "Processor", "name": "P2", "pos": [10, 0, -1.5],
				"params": {"process_time": {"type": "exp", "a": proc_mean},
					"mtbf": {"type": "exp", "a": 0.0}}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [15, 0, 0]},
		],
		"connections": [["s", "q"], ["q", "p1"], ["q", "p2"], ["p1", "k"], ["p2", "k"]],
	}, true)

## 待ち行列モデルの reps レプリケーション（warmup 対応・CRN 的に seed=base+i）。
## Lq(Queue.avg_length), Wq(Queue.avg_wait), util(Processor平均稼働率), thr を平均±CIで返す。
## 各レプリケーション先頭で1フレーム待ち、前レプリケーションで queue_free 済みの
## FlowItem を実際に解放させる（同期テストはフレームを跨がないため放置すると
## items_root にアイテムが累積してメモリ・速度が悪化する）。フレームは Sim を進めない
## （テスト中 running=false）ので決定論には影響しない。
func _mm_replicate(reps: int, warmup_v: float, run_len: float, base_seed: int, q_id: String, proc_ids: Array) -> Dictionary:
	var lq: Array = []
	var wq: Array = []
	var util: Array = []
	var thr: Array = []
	for i in range(reps):
		Sim.seed = base_seed + i
		Sim.warmup = warmup_v
		Sim.reset_sim()
		await get_tree().process_frame   # 前レプリケーションの解放待ちアイテムを実解放
		Sim.run_until(warmup_v + run_len)
		var q = editor.ctx.registry.get(q_id, null)
		if q != null:
			lq.append(q.avg_length())
			wq.append(q.avg_wait())
		var u: float = 0.0
		var np: int = 0
		for pid in proc_ids:
			var p = editor.ctx.registry.get(pid, null)
			if p != null:
				u += p.utilization()
				np += 1
		util.append(u / float(max(1, np)))
		thr.append(Sim.collect_kpi().throughput)
	return {
		"lq_mean": Sim._mean(lq), "lq_ci": Sim._ci95(lq),
		"wq_mean": Sim._mean(wq), "wq_ci": Sim._ci95(wq),
		"util_mean": Sim._mean(util), "util_ci": Sim._ci95(util),
		"thr_mean": Sim._mean(thr),
	}

## [samples] 用の同期版レプリケーション（_mm_replicate と同一だが await get_tree().process_frame
## を含まない）。visuals_enabled=false ではアイテムが Node 化されない＝解放待ちが無いため
## フレーム譲りは不要。await を持たないことで、他コルーチンや deferred free とサンプル実行が
## 干渉せず、Sim.objects の dangling 参照事故を避けられる（結果は同期計算のため await 版と同値）。
func _mm_replicate_sync(reps: int, warmup_v: float, run_len: float, base_seed: int, q_id: String, proc_ids: Array) -> Dictionary:
	var lq: Array = []
	var wq: Array = []
	var util: Array = []
	var thr: Array = []
	for i in range(reps):
		Sim.seed = base_seed + i
		Sim.warmup = warmup_v
		Sim.reset_sim()
		Sim.run_until(warmup_v + run_len)
		var q = editor.ctx.registry.get(q_id, null)
		if q != null:
			lq.append(q.avg_length())
			wq.append(q.avg_wait())
		var u: float = 0.0
		var np: int = 0
		for pid in proc_ids:
			var p = editor.ctx.registry.get(pid, null)
			if p != null:
				u += p.utilization()
				np += 1
		util.append(u / float(max(1, np)))
		thr.append(Sim.collect_kpi().throughput)
	return {
		"lq_mean": Sim._mean(lq), "lq_ci": Sim._ci95(lq),
		"wq_mean": Sim._mean(wq), "wq_ci": Sim._ci95(wq),
		"util_mean": Sim._mean(util), "util_ci": Sim._ci95(util),
		"thr_mean": Sim._mean(thr),
	}

## 搬送ミニモデルを1ラン。transport=true なら Processor→Sink を搬送者に運ばせる。
## 返り値: 平均リードタイム（sink 集計）。
func _transport_run(transport: bool) -> float:
	var trs: Array = []
	if transport:
		trs = [{"name": "T1", "home": [10, 0, 0]}]
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [], "transporters": trs,
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 5.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [10, 0, 0],
				"params": {"process_time": {"type": "const", "a": 2.0},
					"mtbf": {"type": "exp", "a": 0.0}, "transport_out": transport}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [24, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}, true)
	Sim.run_until(300.0)
	return editor.ctx.sink.avg_time_in_system()

## 搬送一般化ミニモデルを1ラン。featured=true で load/unload/waypoint を有効化。
## 4 発生元(優先度差)→1 送り先を capacity=2 の1台で運ぶ。
## 返り値 {lead,sink,conserve,max_batch,all_desc,prio_defer}。
func _trgen_run(featured: bool) -> Dictionary:
	var tdict := {"name": "T1", "home": [30, 0, 0], "capacity": 2}
	if featured:
		tdict["load_time"] = 1.0
		tdict["unload_time"] = 1.0
		tdict["waypoints"] = [[10, 0, -25]]
	var prios: Array = [0, 1, 3, 2]   # p1..p4 の搬送優先度（差あり）
	var objs: Array = []
	var conns: Array = []
	for i in range(4):
		var sid: String = "s%d" % (i + 1)
		var pid: String = "p%d" % (i + 1)
		objs.append({"id": sid, "type": "Source", "name": sid.to_upper(),
			"pos": [0, 0, i * 3],
			"params": {"interarrival": {"type": "const", "a": 5.0}, "type_count": 1}})
		objs.append({"id": pid, "type": "Processor", "name": pid.to_upper(),
			"pos": [10, 0, i * 3],
			"params": {"process_time": {"type": "const", "a": 2.0},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true,
				"transport_priority": prios[i]}})
		conns.append([sid, pid])
		conns.append([pid, "k"])
	objs.append({"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 20]})
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [], "transporters": [tdict],
		"objects": objs, "connections": conns,
	}, true)
	Sim.run_until(300.0)
	# サービス記録を解析
	var log: Array = editor.ctx.transport_pool.service_log
	var max_batch: int = 0
	var all_desc: bool = true
	for bi in range(log.size()):
		var b: Array = log[bi]
		if b.size() > max_batch:
			max_batch = b.size()
		for j in range(1, b.size()):
			if int(b[j]) > int(b[j - 1]):
				all_desc = false   # バッチ内が優先度降順でない
	var ck: Dictionary = Sim.collect_kpi()
	var conserve: bool = ck.created == ck.out + Sim.wip
	return {
		"lead": editor.ctx.sink.avg_time_in_system(),
		"sink": editor.ctx.sink.total,
		"conserve": conserve, "max_batch": max_batch,
		"all_desc": all_desc,
	}

## AGV ネットワーク・ミニモデルを1ラン。use_network=true で遠回りグラフ上を最短経路走行、
## false で従来の直行（不変）。返り値 {lead,sink,conserve}。
func _agvnet_run(use_network: bool) -> Dictionary:
	var m := {
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": [{"name": "T1", "home": [0, 0, 0]}],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 8.0}, "type_count": 1}},
			{"id": "p", "type": "Processor", "name": "P", "pos": [0, 0, 0],
				"params": {"process_time": {"type": "const", "a": 2.0},
					"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "p"], ["p", "k"]],
	}
	if use_network:
		m["network"] = {
			"nodes": {"A": [0, 0, 0], "B": [0, 0, 10], "C": [10, 0, 10], "D": [10, 0, 0]},
			"edges": [["A", "B"], ["B", "C"], ["C", "D"]],   # 直線 A→D 無し（遠回り30のみ）
		}
	editor.rebuild(m, true)
	Sim.run_until(300.0)
	var ck: Dictionary = Sim.collect_kpi()
	return {
		"lead": editor.ctx.sink.avg_time_in_system(),
		"sink": editor.ctx.sink.total,
		"conserve": ck.created == ck.out + Sim.wip,
	}

## [agv-cap] 補助: 直線コリドー A-B-C（各辺長10）を共有する輻輳モデルを1ラン。
## 6本の並列ライン Source→Processor(transport_out) が全て単一の Sink K(=C) へ、共有の
## 単一レーン・コリドー越しに搬送する。8台の搬送者が積載往路 A→C・空荷復路 C→A で往復し、
## 複数台が同時にコリドーへ殺到する（＝正面遭遇＋方向待ちが恒常的に発生する）状況を作る。
## cap 有限なら両辺に容量 cap を設定（単一レーン方向ロック発動）、INF なら未設定（ドーマント）。
## 返り値に占有ピーク・占有不変条件も含める。
func _agvcap_run(cap: float) -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"A": [0, 0, 0], "B": [10, 0, 0], "C": [20, 0, 0]},
		"edges": [["A", "B"], ["B", "C"]],
	}
	if not is_inf(cap):
		net_def["edge_capacities"] = [["A", "B", cap], ["B", "C", cap]]
	var trs: Array = []
	for ti in range(8):
		trs.append({"name": "T%d" % (ti + 1), "home": [0, 0, 0]})
	var objs: Array = []
	var conns: Array = []
	for li in range(6):
		var sid: String = "s%d" % li
		var pid: String = "p%d" % li
		objs.append({"id": sid, "type": "Source", "name": sid.to_upper(),
			"pos": [-5, 0, li],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}})
		objs.append({"id": pid, "type": "Processor", "name": pid.to_upper(),
			"pos": [0, 0, li],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}})
		conns.append([sid, pid])
		conns.append([pid, "k"])
	objs.append({"id": "k", "type": "Sink", "name": "K", "pos": [20, 0, 0]})
	var m: Dictionary = {
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": trs, "objects": objs, "connections": conns,
		"network": net_def,
	}
	editor.rebuild(m, true)
	Sim.run_until(300.0)
	var ck: Dictionary = Sim.collect_kpi()
	var net = editor.ctx.transport_pool.network
	return {
		"lead": editor.ctx.sink.avg_time_in_system(),
		"sink": editor.ctx.sink.total,
		"conserve": ck.created == ck.out + Sim.wip,
		"peak_ab": net.edge_occupancy_peak("A", "B"),
		"peak_bc": net.edge_occupancy_peak("B", "C"),
		"inv_ok": net.occupancy_within_capacity(),
	}

## [agv-traffic] 補助: 単一レーン共有辺 A-B(長さ20, 容量 cap)を N ライン×バーストで共有する。
## 各ラインは Source(バースト)→Queue(大容量, Source を詰まらせない)→Processor(transport_out)
## →共有 Sink(=B)。M 台の搬送者が積載往路 A→B・空荷復路 B→A で単一レーンを双方向使用する。
## cap 有限なら辺 A-B に容量を設定（単一レーン方向ロック発動）、INF なら未設定（自由流ドーマント）。
## 全アイテムがほぼ t=0 に生成される（バースト）ので makespan=最大リードタイム=最終完了時刻。
## Source 生成は下流の輻輳から独立（Queue が大容量で詰まらない）ため created は cap に依らず一定。
## 返り値 {makespan, sink, conserve}。
func _agvtraffic_run(cap: float) -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"A": [0, 0, 0], "B": [20, 0, 0]},
		"edges": [["A", "B"]],
	}
	if not is_inf(cap):
		net_def["edge_capacities"] = [["A", "B", cap]]
	var trs: Array = []
	for ti in range(6):
		trs.append({"name": "T%d" % (ti + 1), "home": [0, 0, 0]})
	var objs: Array = []
	var conns: Array = []
	for li in range(4):
		var sid: String = "s%d" % li
		var qid: String = "q%d" % li
		var pid: String = "p%d" % li
		objs.append({"id": sid, "type": "Source", "name": sid.to_upper(),
			"pos": [0, 0, li],
			"params": {"interarrival": {"type": "const", "a": 0.001}, "type_count": 1,
				"arrival_schedule": [
					{"from": 0.0, "interarrival": {"type": "const", "a": 0.001}},
					{"from": 0.006, "interarrival": {"type": "const", "a": 1.0e9}}]}})
		objs.append({"id": qid, "type": "Queue", "name": qid.to_upper(),
			"pos": [0, 0, li], "params": {"capacity": 1000}})
		objs.append({"id": pid, "type": "Processor", "name": pid.to_upper(),
			"pos": [0, 0, li],
			"params": {"process_time": {"type": "const", "a": 0.1},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}})
		conns.append([sid, qid])
		conns.append([qid, pid])
		conns.append([pid, "k"])
	objs.append({"id": "k", "type": "Sink", "name": "K", "pos": [20, 0, 0]})
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": trs, "objects": objs, "connections": conns,
		"network": net_def,
	}, true)
	Sim.run_until(3000.0)
	var ck: Dictionary = Sim.collect_kpi()
	var sink = editor.ctx.sink
	var mk: float = 0.0
	for lt in sink.leadtimes:
		if float(lt) > mk:
			mk = float(lt)
	return {
		"makespan": mk,
		"sink": sink.total,
		"conserve": ck.created == ck.out + Sim.wip,
	}

## [agv-cap] 補助: コリドー A-B(容量2)-C(容量1)。8台の搬送者×6ラインで両辺を飽和させ、
## 実行中の占有ピークを観測する。容量2の辺 A-B は同方向2台の同時占有(=2)まで到達し、
## 容量1の辺 B-C は高々1に制限される。返り値 {peak_ab, peak_bc, inv_ok, conserve, sink}。
func _agvcap2_run() -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"A": [0, 0, 0], "B": [10, 0, 0], "C": [20, 0, 0]},
		"edges": [["A", "B"], ["B", "C"]],
		"edge_capacities": [["A", "B", 2.0], ["B", "C", 1.0]],
	}
	var trs: Array = []
	for ti in range(8):
		trs.append({"name": "T%d" % (ti + 1), "home": [0, 0, 0]})
	var objs: Array = []
	var conns: Array = []
	for li in range(6):
		var sid: String = "s%d" % li
		var pid: String = "p%d" % li
		objs.append({"id": sid, "type": "Source", "name": sid.to_upper(),
			"pos": [-5, 0, li],
			"params": {"interarrival": {"type": "const", "a": 1.5}, "type_count": 1}})
		objs.append({"id": pid, "type": "Processor", "name": pid.to_upper(),
			"pos": [0, 0, li],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}})
		conns.append([sid, pid])
		conns.append([pid, "k"])
	objs.append({"id": "k", "type": "Sink", "name": "K", "pos": [20, 0, 0]})
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": trs, "objects": objs, "connections": conns,
		"network": net_def,
	}, true)
	Sim.run_until(400.0)
	var ck: Dictionary = Sim.collect_kpi()
	var net = editor.ctx.transport_pool.network
	return {
		"peak_ab": net.edge_occupancy_peak("A", "B"),
		"peak_bc": net.edge_occupancy_peak("B", "C"),
		"inv_ok": net.occupancy_within_capacity(),
		"conserve": ck.created == ck.out + Sim.wip,
		"sink": editor.ctx.sink.total,
	}

## [agv-deadlock] 補助: 単一レーン双方向辺 A-B(容量1)で2台が正面遭遇する構成を1ラン。
## Line1: Aで加工→Bの Sink KB へ搬送(A→B)。Line2: Bで加工→Aの Sink KA へ搬送(B→A)。
## 2台の搬送者(TA=A起点, TB=B起点)が対向で同一辺を要求 → 方向ロック+FIFOで順に通過し、
## 両者が必ず完走する（永久ブロック無し）。返り値 {sinkA, sinkB, both, conserve, key}。
func _agvdeadlock_run() -> Dictionary:
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": [
			{"name": "TA", "home": [0, 0, 0]},
			{"name": "TB", "home": [20, 0, 0]},
		],
		"objects": [
			{"id": "sa", "type": "Source", "name": "SA", "pos": [0, 0, 1],
				"params": {"interarrival": {"type": "const", "a": 5.0}, "type_count": 1}},
			{"id": "pa", "type": "Processor", "name": "PA", "pos": [0, 0, 0],
				"params": {"process_time": {"type": "const", "a": 0.5},
					"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
			{"id": "kb", "type": "Sink", "name": "KB", "pos": [20, 0, 0]},
			{"id": "sb", "type": "Source", "name": "SB", "pos": [20, 0, 1],
				"params": {"interarrival": {"type": "const", "a": 5.0}, "type_count": 1}},
			{"id": "pb", "type": "Processor", "name": "PB", "pos": [20, 0, 0],
				"params": {"process_time": {"type": "const", "a": 0.5},
					"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
			{"id": "ka", "type": "Sink", "name": "KA", "pos": [0, 0, 0]},
		],
		"connections": [["sa", "pa"], ["pa", "kb"], ["sb", "pb"], ["pb", "ka"]],
		"network": {
			"nodes": {"A": [0, 0, 0], "B": [20, 0, 0]},
			"edges": [["A", "B"]],
			"edge_capacities": [["A", "B", 1.0]],
		},
	}, true)
	Sim.run_until(300.0)
	var ck: Dictionary = Sim.collect_kpi()
	var ka = editor.ctx.registry.get("ka", null)
	var kb = editor.ctx.registry.get("kb", null)
	var sinkA: int = ka.total if ka != null else 0
	var sinkB: int = kb.total if kb != null else 0
	var sumA: float = ka.sum_time_in_system if ka != null else 0.0
	var sumB: float = kb.sum_time_in_system if kb != null else 0.0
	return {
		"sinkA": sinkA, "sinkB": sinkB,
		"both": sinkA > 0 and sinkB > 0,
		"conserve": ck.created == ck.out + Sim.wip,
		"key": "%d/%d/%.3f/%.3f" % [sinkA, sinkB, sumA, sumB],
	}

## [agv-node] 補助: マージ・コリドー A(0)-B(10)-C(20)。中央の制御点 B が「交差点」で容量 node_cap、
## 辺は容量 INF（＝ノードが唯一の律速）。6 ライン Source→Processor(transport_out)→Sink K(=C) が
## 8 台の搬送者で B を共有する。搬送者は積載 A→B→C・空荷復路 C→B→A で往復し、ブロック区間方式の
## インターロックにより B を「渡り切って隣ノードに入るまで」占有するため、有限 node_cap は交通を
## 実効的に律速する。端点 A,C は INF（車庫）なので B 占有者は必ず前進でき永久ブロックは起きない。
## node_cap=INF なら node_capacities 未設定＝ドーマント（自由流）。返り値に占有ピーク・不変条件を含む。
func _agvnode_run(node_cap: float) -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"A": [0, 0, 0], "B": [10, 0, 0], "C": [20, 0, 0]},
		"edges": [["A", "B"], ["B", "C"]],
	}
	if not is_inf(node_cap):
		net_def["node_capacities"] = [["B", node_cap]]
	var trs: Array = []
	for ti in range(8):
		trs.append({"name": "T%d" % (ti + 1), "home": [0, 0, 0]})
	var objs: Array = []
	var conns: Array = []
	for li in range(6):
		var sid: String = "s%d" % li
		var pid: String = "p%d" % li
		objs.append({"id": sid, "type": "Source", "name": sid.to_upper(),
			"pos": [-5, 0, li],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}})
		objs.append({"id": pid, "type": "Processor", "name": pid.to_upper(),
			"pos": [0, 0, li],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}})
		conns.append([sid, pid])
		conns.append([pid, "k"])
	objs.append({"id": "k", "type": "Sink", "name": "K", "pos": [20, 0, 0]})
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": trs, "objects": objs, "connections": conns,
		"network": net_def,
	}, true)
	Sim.run_until(300.0)
	var ck: Dictionary = Sim.collect_kpi()
	var net = editor.ctx.transport_pool.network
	return {
		"lead": editor.ctx.sink.avg_time_in_system(),
		"sink": editor.ctx.sink.total,
		"conserve": ck.created == ck.out + Sim.wip,
		"peak_node_b": net.node_occupancy_peak("B"),
		"node_inv": net.node_occupancy_within_capacity(),
	}

## [agv-node] 補助: 十字路。中心 X(容量1) に4本のアーム W-X, X-E, S-X, X-N。水平フロー
## H(sw→pw(W)→搬送→ke(E), route W→X→E) と垂直フロー V(ss→ps(S)→搬送→kn(N), route S→X→N) が
## X で交差する。共有辺は無く X（容量1）だけを奪い合う構造。X は有限ノードだが隣接辺 W-X,X-E,S-X,X-N
## は全て INF（有限ノードが有限辺に隣接しない＝fable5 erratum の安全条件を満たす）ので循環待ちが
## 起きず必ず全車完走する（head-on / 4-way 交差の永久ブロック無しの実証）。4台の搬送者を
## 両フローで共有し、空荷復路・初期回送で各アームを双方向に使うため X には両側から進入が集中する。
func _agvnode_cross_run() -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"W": [-10, 0, 0], "X": [0, 0, 0], "E": [10, 0, 0],
			"S": [0, 0, -10], "N": [0, 0, 10]},
		"edges": [["W", "X"], ["X", "E"], ["S", "X"], ["X", "N"]],
		"node_capacities": [["X", 1.0]],
	}
	var trs: Array = []
	for ti in range(4):
		trs.append({"name": "T%d" % (ti + 1), "home": [0, 0, 0]})
	var objs: Array = [
		{"id": "sw", "type": "Source", "name": "SW", "pos": [-10, 0, 1],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
		{"id": "pw", "type": "Processor", "name": "PW", "pos": [-10, 0, 0],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
		{"id": "ke", "type": "Sink", "name": "KE", "pos": [10, 0, 0]},
		{"id": "ss", "type": "Source", "name": "SS", "pos": [1, 0, -10],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
		{"id": "ps", "type": "Processor", "name": "PS", "pos": [0, 0, -10],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
		{"id": "kn", "type": "Sink", "name": "KN", "pos": [0, 0, 10]},
	]
	var conns: Array = [["sw", "pw"], ["pw", "ke"], ["ss", "ps"], ["ps", "kn"]]
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": trs, "objects": objs, "connections": conns,
		"network": net_def,
	}, true)
	Sim.run_until(300.0)
	var ck: Dictionary = Sim.collect_kpi()
	var net = editor.ctx.transport_pool.network
	var ke = editor.ctx.registry.get("ke", null)
	var kn = editor.ctx.registry.get("kn", null)
	var sinkH: int = ke.total if ke != null else 0
	var sinkV: int = kn.total if kn != null else 0
	return {
		"sinkH": sinkH, "sinkV": sinkV,
		"both": sinkH > 0 and sinkV > 0,
		"conserve": ck.created == ck.out + Sim.wip,
		"peak_node_x": net.node_occupancy_peak("X"),
		"node_inv": net.node_occupancy_within_capacity(),
	}

## [agv-spillback] 補助: 直線コリドー A(0)-B(10)-C(20)。中央の交差点 B を容量 node_cap にし、辺は
## INF（＝ノードだけが律速）。1 ライン Source(バースト生成)→Queue(大容量)→Processor(transport_out)
## →Sink K(=C) を 3 台の搬送者が共有する。全 item がほぼ t=0 に生成されるので makespan=最大リード
## タイム=最終完了時刻。node_cap=1 では搬送者が B を1台ずつしか通れず（block-section で B を渡り切る
## まで保持）上流が直列化して makespan が伸びる。node_cap=INF は node_capacities 未設定＝ドーマント
## （自由流・並走）。辺は両ランで同一(INF)なので makespan 差はノード起因のみ。返り値に占有ピーク・
## 不変条件を含む。決定論確認のため呼び出し側が同一 node_cap で2回走らせて突合する。
func _agvspill_run(node_cap: float) -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"A": [0, 0, 0], "B": [10, 0, 0], "C": [20, 0, 0]},
		"edges": [["A", "B"], ["B", "C"]],
	}
	if not is_inf(node_cap):
		net_def["node_capacities"] = [["B", node_cap]]
	var trs: Array = []
	for ti in range(3):
		trs.append({"name": "T%d" % (ti + 1), "home": [0, 0, 0]})
	var objs: Array = [
		{"id": "s", "type": "Source", "name": "S", "pos": [-5, 0, 0],
			"params": {"interarrival": {"type": "const", "a": 0.001}, "type_count": 1,
				"arrival_schedule": [
					{"from": 0.0, "interarrival": {"type": "const", "a": 0.001}},
					{"from": 0.012, "interarrival": {"type": "const", "a": 1.0e9}}]}},
		{"id": "q", "type": "Queue", "name": "Q", "pos": [-2, 0, 0], "params": {"capacity": 1000}},
		{"id": "p", "type": "Processor", "name": "P", "pos": [0, 0, 0],
			"params": {"process_time": {"type": "const", "a": 0.1},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
		{"id": "k", "type": "Sink", "name": "K", "pos": [20, 0, 0]},
	]
	var conns: Array = [["s", "q"], ["q", "p"], ["p", "k"]]
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": trs, "objects": objs, "connections": conns, "network": net_def,
	}, true)
	Sim.run_until(3000.0)
	var ck: Dictionary = Sim.collect_kpi()
	var sink = editor.ctx.sink
	var mk: float = 0.0
	for lt in sink.leadtimes:
		if float(lt) > mk:
			mk = float(lt)
	var net = editor.ctx.transport_pool.network
	return {
		"makespan": mk,
		"sink": sink.total,
		"conserve": ck.created == ck.out + Sim.wip,
		"peak_node_b": net.node_occupancy_peak("B"),
		"node_inv": net.node_occupancy_within_capacity(),
	}

## [agv-node-live] 補助: 4方向 head-on 交差。中心 X(容量1) に4本のアーム W-X, X-E, S-X, X-N。水平
## 対向2フロー W→E(route W→X→E) / E→W(route E→X→W) と垂直対向2フロー S→N(route S→X→N) /
## N→S(route N→X→S) が中心 X だけを奪い合う（共有辺は無く、隣接辺 W-X,X-E,S-X,X-N は全て INF）。
## 素朴な「次ノードを握ってから現ノードを離す」予約なら4アームが互いに X を待って循環デッドロックし得る
## 構造だが、X（有限ノード）が有限辺に隣接しない＝fable5 erratum の安全条件を満たすため循環待ちが
## 起きず全フローが完走する（liveness）。※安全なのは端点 INF だからではなく有限ノードが有限辺に隣接
## しないから（隣接すると端点 INF でもデッドロック＝[agv-node-deadlock]）。4台の搬送者を全フローで共有し、空荷復路・回送で各アームを
## 双方向使用するため X には四方から進入が集中する。返り値に各シンク数・占有ピーク・不変条件・
## 決定論比較キーを含む。
func _agvnodelive_run() -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"W": [-10, 0, 0], "X": [0, 0, 0], "E": [10, 0, 0],
			"S": [0, 0, -10], "N": [0, 0, 10]},
		"edges": [["W", "X"], ["X", "E"], ["S", "X"], ["X", "N"]],
		"node_capacities": [["X", 1.0]],
	}
	var trs: Array = []
	for ti in range(4):
		trs.append({"name": "T%d" % (ti + 1), "home": [0, 0, 0]})
	var objs: Array = [
		# 水平対向: W→E と E→W（正面対向 head-on）
		{"id": "sw", "type": "Source", "name": "SW", "pos": [-10, 0, 1],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
		{"id": "pw", "type": "Processor", "name": "PW", "pos": [-10, 0, 0],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
		{"id": "ke", "type": "Sink", "name": "KE", "pos": [10, 0, 0]},
		{"id": "se", "type": "Source", "name": "SE", "pos": [10, 0, 1],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
		{"id": "pe", "type": "Processor", "name": "PE", "pos": [10, 0, 0],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
		{"id": "kw", "type": "Sink", "name": "KW", "pos": [-10, 0, 0]},
		# 垂直対向: S→N と N→S（正面対向 head-on）
		{"id": "ss", "type": "Source", "name": "SS", "pos": [1, 0, -10],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
		{"id": "ps", "type": "Processor", "name": "PS", "pos": [0, 0, -10],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
		{"id": "kn", "type": "Sink", "name": "KN", "pos": [0, 0, 10]},
		{"id": "sn", "type": "Source", "name": "SN", "pos": [1, 0, 10],
			"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
		{"id": "pn", "type": "Processor", "name": "PN", "pos": [0, 0, 10],
			"params": {"process_time": {"type": "const", "a": 0.5},
				"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
		{"id": "ks", "type": "Sink", "name": "KS", "pos": [0, 0, -10]},
	]
	var conns: Array = [["sw", "pw"], ["pw", "ke"], ["se", "pe"], ["pe", "kw"],
		["ss", "ps"], ["ps", "kn"], ["sn", "pn"], ["pn", "ks"]]
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": trs, "objects": objs, "connections": conns, "network": net_def,
	}, true)
	Sim.run_until(300.0)
	var ck: Dictionary = Sim.collect_kpi()
	var net = editor.ctx.transport_pool.network
	var ke = editor.ctx.registry.get("ke", null)
	var kw = editor.ctx.registry.get("kw", null)
	var kn = editor.ctx.registry.get("kn", null)
	var ks = editor.ctx.registry.get("ks", null)
	var he: int = ke.total if ke != null else 0   # W→E
	var hw: int = kw.total if kw != null else 0   # E→W
	var vn: int = kn.total if kn != null else 0   # S→N
	var vs: int = ks.total if ks != null else 0   # N→S
	var sum_he: float = ke.sum_time_in_system if ke != null else 0.0
	var sum_hw: float = kw.sum_time_in_system if kw != null else 0.0
	var sum_vn: float = kn.sum_time_in_system if kn != null else 0.0
	var sum_vs: float = ks.sum_time_in_system if ks != null else 0.0
	return {
		"he": he, "hw": hw, "vn": vn, "vs": vs,
		"all": he > 0 and hw > 0 and vn > 0 and vs > 0,
		"conserve": ck.created == ck.out + Sim.wip,
		"peak_x": net.node_occupancy_peak("X"),
		"node_inv": net.node_occupancy_within_capacity(),
		"key": "%d/%d/%d/%d/%.3f/%.3f/%.3f/%.3f" % [he, hw, vn, vs, sum_he, sum_hw, sum_vn, sum_vs],
	}

## [agv-node-deadlock] 補助: fable5 erratum の反例レイアウトを1ラン。有限ノード X(cap1) と隣接する
## 有限辺 W-X(cap1)、端点 W,E は INF。対向2フロー flow1=W→X→E（PW→搬送→KE）と flow2=E→X→W
## （PE→搬送→KW）。幾何で循環待ちを強制する: 有限辺 W-X を長く（W を X から遠く）、INF 辺 X-E を
## 短く（E を X に近く）配置し、TB(E→W) が短い X-E を渡って先に X を確保して辺 X-W を要求する一方、
## TA(W→E) は長い有限辺 W-X を横断中（＝方向ロックで X をブロック）→横断後に X を要求 → 互いに
## 「TB は辺 W-X を、TA はノード X を」待つ循環待ち（端点 INF でも起きる）。
## 検出は「有界2フェーズラン＋ストールウォッチドッグ」: run_until(60) 後 is_stalled()（待機列に残る
## 搬送者）を確認し、さらに run_until(120) で完了数が1件も増えない（＝待機者を起こす搬送イベントが
## カレンダーに無い＝進捗ゼロ）ことで恒久デッドロックを確定する。run_until は時刻上限で必ず返るので
## スイートはハングしない。走行前に lint_layout() の静的診断も採取する。返り値に検出結果・lint・
## 決定論キーを含む。
func _agvnodedeadlock_run() -> Dictionary:
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": [
			{"name": "TA", "home": [-40, 0, 0]},   # flow1 側（W 起点）
			{"name": "TB", "home": [8, 0, 0]},      # flow2 側（E 起点）
		],
		"objects": [
			# flow1: W→E（有限辺 W-X を W 方向へ横断）
			{"id": "sw", "type": "Source", "name": "SW", "pos": [-40, 0, 1],
				"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
			{"id": "pw", "type": "Processor", "name": "PW", "pos": [-40, 0, 0],
				"params": {"process_time": {"type": "const", "a": 0.5},
					"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
			{"id": "ke", "type": "Sink", "name": "KE", "pos": [8, 0, 0]},
			# flow2: E→W（短い INF 辺 X-E で先に X を確保）
			{"id": "se", "type": "Source", "name": "SE", "pos": [8, 0, 1],
				"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
			{"id": "pe", "type": "Processor", "name": "PE", "pos": [8, 0, 0],
				"params": {"process_time": {"type": "const", "a": 0.5},
					"mtbf": {"type": "exp", "a": 0.0}, "transport_out": true}},
			{"id": "kw", "type": "Sink", "name": "KW", "pos": [-40, 0, 0]},
		],
		"connections": [["sw", "pw"], ["pw", "ke"], ["se", "pe"], ["pe", "kw"]],
		"network": {
			"nodes": {"W": [-40, 0, 0], "X": [0, 0, 0], "E": [8, 0, 0]},
			"edges": [["W", "X"], ["X", "E"]],
			"edge_capacities": [["W", "X", 1.0]],   # 有限辺（X-E は INF のまま）
			"node_capacities": [["X", 1.0]],        # 有限ノード（W,E は INF のまま）
		},
	}, true)
	var net = editor.ctx.transport_pool.network
	# 走行前の静的診断（純データ・実行時挙動は変えない）。反例では辺 W-X が有限ノード X に隣接。
	var lint_warns: Array = net.lint_layout()
	# 有界フェーズ1: デッドロック形成まで回す（run_until は時刻上限で必ず返る＝ハングしない）。
	Sim.run_until(60.0)
	var wait_mid: int = net.waiting_count()
	var stalled_mid: bool = net.is_stalled()
	var sink_mid: int = int(Sim.collect_kpi().out)
	var busy_mid: int = editor.ctx.transport_pool.busy_count()
	# 有界フェーズ2: さらに時間を進め、完了数が一切増えないこと（進捗ゼロ）を確認する。
	Sim.run_until(120.0)
	var ck: Dictionary = Sim.collect_kpi()
	var sink_end: int = int(ck.out)
	var created: int = int(ck.created)
	var stalled_end: bool = net.is_stalled()
	var no_progress: bool = sink_end == sink_mid
	return {
		"lint": lint_warns,
		# ウォッチドッグ確定: 待機中の搬送者が残り、かつフェーズ2で進捗ゼロ＝恒久デッドロック。
		"stalled": stalled_mid and stalled_end and no_progress,
		"watchdog": stalled_end,          # is_stalled() 生値
		"waiters": wait_mid,              # デッドロック中の待機搬送者数（=2）
		"busy": busy_mid,                 # 恒久ブロック中の搬送者数（=2）
		"completed": sink_end,            # 完了（sink 到達）数
		"expected": created,              # 生成数（実行可能なら全完了するはず）
		"key": "%d/%d/%d/%d/%s/%d" % [sink_end, created, wait_mid, busy_mid,
			str(stalled_mid and stalled_end and no_progress), lint_warns.size()],
	}

## [pf-travel-congest] 補助: 2 PF トークンが各々 transporter を確保し、容量 cap の共有辺 A-B を
## 渡る。cap 有限なら単一レーンで直列化（第2トークンが辺占有を FIFO 待機）、INF なら congestion
## エンジンがドーマントで自由流（並走）になる。PF は create_item→acquire_resource(transporter)→
## travel(A→B)→unload(実 Sink)→release_resource→sink。run_isolated で既定 Source 自走を止め、
## 実 Sink.leadtimes（全 item はほぼ t=0 生成）から makespan=最大リードタイム=最終完了時刻を得る。
## 返り値 {makespan, delivered, conserve, key, balanced}。key は決定論比較用（total/makespan/Σlt）。
func _pftravel_congest_run(cap: float) -> Dictionary:
	var net_def: Dictionary = {
		"nodes": {"A": [0, 0, 0], "B": [30, 0, 0]},
		"edges": [["A", "B"]],
	}
	if not is_inf(cap):
		net_def["edge_capacities"] = [["A", "B", cap]]
	editor.rebuild({
		"seed": 1, "warmup": 0, "operators": [],
		"transporters": [
			{"name": "PC1", "home": [0, 0, 0]},
			{"name": "PC2", "home": [0, 0, 0]},
		],
		"objects": [
			{"id": "pck", "type": "Sink", "name": "PCK", "pos": [30, 0, 0]},
		],
		"connections": [],
		"network": net_def,
	}, true)
	var pf := ProcessFlow.new({
		"seed": 9300,
		"activities": [
			{"id": "src", "type": "source", "interarrival": {"type": "const", "a": 0.001},
				"max_arrivals": 2, "next": "mk"},
			{"id": "mk", "type": "create_item", "item_type": 0, "next": "acq"},
			{"id": "acq", "type": "acquire_resource", "pool": "agv", "next": "tp"},
			{"id": "tp", "type": "travel", "to": [30, 0], "state": "carrying", "next": "ul"},
			{"id": "ul", "type": "unload", "time": {"type": "const", "a": 0.0}, "to": "k", "next": "rel"},
			{"id": "rel", "type": "release_resource", "pool": "agv", "next": "snk"},
			{"id": "snk", "type": "sink"},
		],
	})
	pf.bind_objects({"agv": editor.ctx.transport_pool, "k": "pck"})
	var kp: Dictionary = pf.run_isolated(1000000.0, 9300)
	var sink = editor.ctx.sink
	var mk: float = 0.0
	var sumlt: float = 0.0
	for lt in sink.leadtimes:
		sumlt += float(lt)
		if float(lt) > mk:
			mk = float(lt)
	var conserve: bool = int(kp.created) == int(kp.sunk) + int(kp.in_flight) \
		and int(kp.in_flight) == 0 and Sim.wip == 0
	return {
		"makespan": mk,
		"delivered": sink.total,
		"conserve": conserve,
		"balanced": pf.real_res_balanced("agv"),
		"key": "%d/%.4f/%.4f" % [sink.total, mk, sumlt],
	}

func _dist_mean(d: Dictionary, rng: RandomNumberGenerator, n: int) -> float:
	var s: float = 0.0
	for _i in range(n):
		s += Dist.sample(d, rng)
	return s / float(n)

func _rel_err(v: float, target: float) -> float:
	if target == 0.0:
		return abs(v)
	return abs(v - target) / abs(target)

func _mini_model(mid_type: String, mid_params: Dictionary) -> Dictionary:
	return {
		"seed": 1, "warmup": 0, "operators": [],
		"objects": [
			{"id": "s", "type": "Source", "name": "S", "pos": [0, 0, 0],
				"params": {"interarrival": {"type": "const", "a": 2.0}, "type_count": 1}},
			{"id": "mid", "type": mid_type, "name": mid_type, "pos": [5, 0, 0], "params": mid_params},
			{"id": "k", "type": "Sink", "name": "K", "pos": [10, 0, 0]},
		],
		"connections": [["s", "mid"], ["mid", "k"]],
	}

func _one_run(seed_v: int, t_end: float) -> String:
	Sim.seed = seed_v
	Sim.warmup = 0.0
	Sim.reset_sim()
	Sim.run_until(t_end)
	var sink = editor.ctx.sink
	return "%d/%.3f" % [sink.total, sink.avg_time_in_system()]

func _one_run_thr(seed_v: int, t_end: float, warmup_v: float) -> float:
	Sim.seed = seed_v
	Sim.warmup = warmup_v
	Sim.reset_sim()
	Sim.run_until(warmup_v + t_end)
	return editor.ctx.sink.throughput_per_hour()

## 全 Sink 集計での 1 ラン（warmup 対応）。"total/leadtime" を返す（決定論検証用）。
func _one_run_agg(seed_v: int, warmup_v: float, run_len: float) -> String:
	Sim.seed = seed_v
	Sim.warmup = warmup_v
	Sim.reset_sim()
	Sim.run_until(warmup_v + run_len)
	var k: Dictionary = Sim.collect_kpi()
	return "%d/%.3f" % [k.out, k.leadtime]

func _write_csv(res: Dictionary) -> void:
	var f := FileAccess.open("user://experiment.csv", FileAccess.WRITE)
	if f == null:
		return
	f.store_line("rep,throughput_per_hour,leadtime_s,wip")
	for i in range(res.throughput.size()):
		f.store_line("%d,%.3f,%.3f,%d" % [i + 1, res.throughput[i], res.leadtime[i], res.wip[i] if i < res.wip.size() else 0])
	f.store_line("mean,%.3f,%.3f," % [res.thr_mean, res.lt_mean])
	f.store_line("ci95,%.3f,%.3f," % [res.thr_ci, res.lt_ci])
	f.close()
	print("[csv] user://experiment.csv 書き出し")

## 最適化の探索履歴と最適解を user://optimize.csv に書き出す（UIボタンと同一形式）。
func _write_optimize_csv(res: Dictionary) -> void:
	var f := FileAccess.open("user://optimize.csv", FileAccess.WRITE)
	if f == null:
		return
	# 決定変数ラベルの列順を history 先頭から確定（無ければ best から）。
	var keys: Array = []
	if res.history.size() > 0:
		keys = (res.history[0].assign as Dictionary).keys()
	elif res.has("best"):
		keys = (res.best as Dictionary).keys()
	var header: String = "eval"
	for k in keys:
		header += "," + str(k)
	header += ",objective"
	f.store_line(header)
	for i in range(res.history.size()):
		var h: Dictionary = res.history[i]
		var row: String = str(i + 1)
		for k in keys:
			row += "," + str(float(h.assign.get(k, 0.0)))
		row += ",%.4f" % float(h.obj)
		f.store_line(row)
	# 最適解行。
	var best_row: String = "best"
	for k in keys:
		best_row += "," + str(float(res.best.get(k, 0.0)))
	best_row += ",%.4f" % float(res.best_obj)
	f.store_line(best_row)
	f.close()
	print("[csv] user://optimize.csv 書き出し")
