extends FlowObject
class_name Processor
## 加工機（イベント駆動・明示フェーズ機械）。処理・段取り・故障・修理をすべてイベントで予約する。
## 作業者は完了時に解放（ブロック中は拘束しない → 稼働率の水増しを防ぐ）。
##
## 明示フェーズ（_phase）で「今どの段階か」を一元管理し、各段階の予約イベントを
## ハンドル変数（_setup_ev / _seg_ev / _cal_ev）に保持する。calendar 故障が来たら
## 「現在フェーズに対応する予約」だけを Sim.cancel して残時間/残作業を保存し down へ、
## 修理後は保存フェーズを正しく再開する（機能の直積で起きる二重予約・作業者リークを排除）。
##   phase: "idle" / "wait_op" / "setup" / "process" / "blocked" / "wait_transport"
##          （down は _cal_down フラグで表現し、_phase には「中断前の段階」を保持したまま）

var process_time: Dictionary = {"type": "normal", "a": 6.0, "b": 1.5}
var needs_operator: bool = false
var operator_pool = null                       # 常に設定される（needs_operator時のみ使用）
var mtbf: Dictionary = {"type": "exp", "a": 0.0}
## 故障の時間基準: "operating"(既定=稼働時間ベース) / "calendar"(経過時間ベース)。
## calendar は処理有無に関わらずカレンダー時刻で故障が来る。
var mtbf_basis: String = "operating"
var mttr: Dictionary = {"type": "const", "a": 20.0}
var setup_time: Dictionary = {"type": "const", "a": 0.0}
var transport_out: bool = false                # 送出を搬送者に運ばせる（既定 off）
var transport_priority: int = 0                # 搬送要求の優先度（既定0＝従来同等）
var transport_pool = null                      # 常に設定される（transport_out時のみ使用）

var _current: FlowItem = null
var _finished: FlowItem = null
var _transport_item: FlowItem = null           # 搬送者の積載待ちで保持中のアイテム
var _remaining: float = 0.0
var _ttf: float = INF
var _last_type: int = -1
var _operator = null
# --- 明示フェーズ機械の状態 ---
var _phase: String = "idle"   # 論理フェーズ（down中も中断前の段階を保持）
# --- setup セグメント（calendar preempt用） ---
var _setup_ev = null          # 予約中の段取り完了イベント
var _setup_end: float = 0.0   # 段取り完了の絶対時刻
var _setup_remaining: float = 0.0  # 中断時に保存した残段取り時間
# --- 処理セグメント（calendar preempt用） ---
var _seg_ev = null            # 現在の処理セグメント完了イベント
var _seg_end: float = 0.0     # 現セグメント完了の絶対時刻
# --- calendar 故障用の状態 ---
var _cal_ev = null            # 予約中のカレンダー故障イベント
var _cal_down: bool = false   # calendar故障で停止中
var _proc_active: bool = false  # 処理セグメント進行中（= _phase=="process"）
var _pending_begin: bool = false  # down中に受入れ、未着手のアイテムあり
var _op_arrived: bool = false     # down中に作業者が到着済み（修理後に着手）

func _init() -> void:
	obj_name = "Processor"
	body_color = Color(0.30, 0.45, 0.35)

func type_name() -> String:
	return "Processor"

func get_params() -> Dictionary:
	return {
		"process_time": process_time, "needs_operator": needs_operator,
		"mtbf": mtbf, "mtbf_basis": mtbf_basis, "mttr": mttr, "setup_time": setup_time,
		"transport_out": transport_out, "transport_priority": transport_priority,
	}

func set_params(d: Dictionary) -> void:
	if d.has("process_time"): process_time = d["process_time"]
	if d.has("needs_operator"): needs_operator = bool(d["needs_operator"])
	if d.has("mtbf"): mtbf = d["mtbf"]
	if d.has("mtbf_basis"): mtbf_basis = str(d["mtbf_basis"])
	if d.has("mttr"): mttr = d["mttr"]
	if d.has("setup_time"): setup_time = d["setup_time"]
	if d.has("transport_out"): transport_out = bool(d["transport_out"])
	if d.has("transport_priority"): transport_priority = int(d["transport_priority"])

func reset_object() -> void:
	super.reset_object()
	_current = null
	_finished = null
	_transport_item = null
	_remaining = 0.0
	_last_type = -1
	_operator = null
	_phase = "idle"
	_setup_ev = null
	_setup_end = 0.0
	_setup_remaining = 0.0
	_seg_ev = null
	_seg_end = 0.0
	_cal_ev = null
	_cal_down = false
	_proc_active = false
	_pending_begin = false
	_op_arrived = false
	_arm_failure()
	set_state("idle")

## calendar 基準の初回故障は絶対時刻イベントで仕込む（処理有無に依存しない）。
func on_sim_start() -> void:
	if _calendar_basis():
		_schedule_cal_failure()

func still_needs_operator() -> bool:
	# wait_op フェーズ（down中も含む）で、まだ作業者が割当・到着していない間は true。
	# down 中も true を返すことで作業者要求が待ち行列から失われず／二重要求も防ぐ。
	return _current != null and _phase == "wait_op" and _operator == null and not _op_arrived

func still_needs_transport(item: FlowItem) -> bool:
	return _transport_item != null and _transport_item == item

func op_stand_pos() -> Vector3:
	return global_position + Vector3(0.0, 0.0, 1.2)

func _transport_enabled() -> bool:
	return transport_out and transport_pool != null and transport_pool.has_transporters()

func _failure_enabled() -> bool:
	return float(mtbf.get("a", 0.0)) > 0.0

func _operating_basis() -> bool:
	return mtbf_basis != "calendar"

func _calendar_basis() -> bool:
	return _failure_enabled() and mtbf_basis == "calendar"

func _setup_enabled() -> bool:
	return float(setup_time.get("a", 0.0)) > 0.0

func _arm_failure() -> void:
	# 稼働時間ベースの time-to-failure（calendar 基準では未使用＝INF）。
	_ttf = Dist.sample(mtbf, rng("fail")) if (_failure_enabled() and _operating_basis()) else INF

func _schedule_cal_failure() -> void:
	_cal_ev = Sim.schedule(Dist.sample(mtbf, rng("fail")), _on_calendar_failure)

# ---------------------------------------------------------------
func receive_item(item: FlowItem) -> bool:
	if _current != null or _finished != null or _transport_item != null:
		return false
	_current = item
	input_count += 1
	_fire("on_entry", item)
	if Sim.visuals_enabled:
		item.move_to(global_position + Vector3(0, 1.0, 0))
	_begin()
	return true

func _begin() -> void:
	if _cal_down:
		# calendar故障で停止中は着手を保留（復帰時に開始）。
		_pending_begin = true
		return
	if needs_operator and operator_pool != null:
		_phase = "wait_op"
		set_state("waiting")
		operator_pool.request(self)   # 要求は高々1つ（wait_op復帰では再要求しない）
	else:
		_start_processing()

func _on_operator_ready(op) -> void:
	_operator = op
	if _cal_down:
		# down中に到着したら着手せず「到着済み」を記録（修理後に開始）。作業者は拘束保持。
		_op_arrived = true
		return
	_start_processing()

func _start_processing() -> void:
	# 作業者は「実処理(段取り/加工)が実際に始まる」この時点から稼働計上する
	# （到着〜着手のデッドタイムや down 中の待機は計上しない）。冪等なので
	# 段取り→加工の連続でも計上起点は一度だけ立つ。
	if _operator != null:
		_operator.start_working()
	if _setup_enabled() and _last_type != -1 and _current.item_type != _last_type:
		_phase = "setup"
		set_state("setup")
		var st: float = Dist.sample(setup_time, rng("setup"))
		_setup_remaining = st
		_setup_end = Sim.sim_time + st
		_setup_ev = Sim.schedule(st, _after_setup)
	else:
		_enter_processing()

func _after_setup() -> void:
	_setup_ev = null
	if _cal_down:
		return  # down中は進めない（通常は故障時にcancel済み。多重安全ガード）
	_enter_processing()

func _enter_processing() -> void:
	if _cal_down:
		return  # down中は進めない（多重安全ガード）
	_remaining = _override_num("process_time", Dist.sample(process_time, rng("proc")))
	_last_type = _current.item_type
	_phase = "process"
	_proc_active = true
	_fire("on_process_start", _current)
	set_state("busy")
	_schedule_segment()

func _schedule_segment() -> void:
	if _operating_basis() and _failure_enabled() and _ttf < _remaining:
		Sim.schedule(_ttf, _on_failure)
	elif _calendar_basis():
		# 完了イベント handle を保持（calendar故障が来たら preempt する）。
		_seg_end = Sim.sim_time + _remaining
		_seg_ev = Sim.schedule(_remaining, _on_complete)
	else:
		Sim.schedule(_remaining, _on_complete)

func _on_failure() -> void:
	_remaining -= _ttf
	# down 突入: 作業者は処理を止めるので稼働計上も止める。
	if _operator != null:
		_operator.stop_working()
	set_state("down")
	Sim.schedule(Dist.sample(mttr, rng("repair")), _on_repair)

func _on_repair() -> void:
	_arm_failure()
	# 修理完了で処理再開: 作業者の稼働計上を再開する。
	if _operator != null:
		_operator.start_working()
	set_state("busy")
	_schedule_segment()

# --- calendar 基準の故障（経過時間で来る。アイドルでも発生） ---
## 現在フェーズに応じて対応する予約をキャンセルし残時間/残作業を保存して down へ。
func _on_calendar_failure() -> void:
	_cal_ev = null
	_cal_down = true
	# down 突入: 処理(setup/process)が進行中なら作業者の稼働計上を止める。
	# working でなければ stop_working は no-op（wait_op で未着手 等）。
	if _operator != null:
		_operator.stop_working()
	if _phase == "process":
		# 処理中：完了イベントを取消し、残処理時間を保存して preempt。
		if _seg_ev != null:
			Sim.cancel(_seg_ev)
			_seg_ev = null
		_remaining = max(0.0, _seg_end - Sim.sim_time)
	elif _phase == "setup":
		# 段取り中：段取り完了イベントを取消し、残段取り時間を保存して preempt。
		if _setup_ev != null:
			Sim.cancel(_setup_ev)
			_setup_ev = null
		_setup_remaining = max(0.0, _setup_end - Sim.sim_time)
	# wait_op / wait_transport / idle / blocked は取消すべき自前イベントが無い
	# （作業者・搬送者は外部プールが管理、blockedは下流待ち）。フェーズを保持して down。
	set_state("down")
	Sim.schedule(Dist.sample(mttr, rng("repair")), _on_calendar_repair)

## 保存したフェーズを正しく再開する。
func _on_calendar_repair() -> void:
	_cal_down = false
	_schedule_cal_failure()   # 次のカレンダー故障を絶対時刻で再仕込み
	if _phase == "process":
		# 中断した処理を残時間から再開。作業者は稼働計上を再開。
		if _operator != null:
			_operator.start_working()
		set_state("busy")
		_schedule_segment()
	elif _phase == "setup":
		# 中断した段取りを残時間から再開。作業者は稼働計上を再開。
		if _operator != null:
			_operator.start_working()
		set_state("setup")
		_setup_end = Sim.sim_time + _setup_remaining
		_setup_ev = Sim.schedule(_setup_remaining, _after_setup)
	elif _phase == "blocked":
		# (a) down前は完成品を保持したままブロック中だった。フェーズ不変条件を保ち、
		# idle 化しない。下流に空きがあれば送出して idle へ、無ければ blocked を継続。
		if _finished != null and try_push(_finished):
			_finished = null
			_phase = "idle"
			set_state("idle")
			_notify_space()
		else:
			set_state("blocked")
	elif _phase == "wait_op":
		if _op_arrived:
			# down中に作業者が到着済み → ここで着手（二重要求なし・作業者は保持済み）。
			_op_arrived = false
			_start_processing()
		else:
			# まだ作業者待ち（要求は既発行のまま／到着イベントを待つ）。再要求しない。
			set_state("waiting")
	elif _phase == "wait_transport":
		# 搬送者の積載を待つ状態へ戻す（搬送は外部プールが独立に完了させる）。
		set_state("waiting")
	elif _pending_begin:
		# down中に受入れて未着手だったアイテムをここで開始。
		_pending_begin = false
		set_state("idle")
		_begin()
	elif _current != null:
		set_state("idle")
		_begin()
	else:
		_phase = "idle"
		set_state("idle")
		_notify_space()

func _on_complete() -> void:
	if _operating_basis() and _failure_enabled():
		_ttf -= _remaining
	_seg_ev = null
	_proc_active = false
	var done: FlowItem = _current
	_current = null
	_fire("on_process_finish", done)
	_release_operator()
	if _transport_enabled():
		_dispatch_transport(done)
	elif try_push(done):
		_phase = "idle"
		set_state("idle")
		_notify_space()
	else:
		_phase = "blocked"
		_finished = done
		set_state("blocked")

# --- 搬送送出 ---
func _pick_dest(item: FlowItem):
	var idx: int = _override_output(item)
	if idx >= 0 and idx < outputs.size():
		return outputs[idx]
	if outputs.size() > 0:
		return outputs[0]
	return null

func _dispatch_transport(item: FlowItem) -> void:
	var dest = _pick_dest(item)
	if dest == null:
		# 送り先が無ければ従来ルーティングにフォールバック（保存則維持）
		if try_push(item):
			_phase = "idle"
			set_state("idle")
			_notify_space()
		else:
			_phase = "blocked"
			_finished = item
			set_state("blocked")
		return
	# アイテムはスロットに保持したまま搬送者の到着を待つ（受入不可＝上流ブロック維持）
	_transport_item = item
	_phase = "wait_transport"
	set_state("waiting")
	transport_pool.request(self, item, dest, transport_priority)

## 搬送者が発生元に到着して積載した時に呼ばれる。スロットを解放し上流を再開させる。
func _on_transport_pickup() -> void:
	_transport_item = null
	_phase = "idle"
	if _cal_down:
		# ⑤ down中はidleに誤計上しない（down状態を尊重）。スロットのみ解放し上流再開。
		# 修理後は _on_calendar_repair の idle 経路で正しく idle へ戻る。
		_notify_space()
		return
	set_state("idle")
	_notify_space()

func _retry_push() -> void:
	# (b) down 中は再送しない（idle へ誤遷移させない）。修理後に _on_calendar_repair の
	# blocked 経路で送出を試みる。⑤(_on_transport_pickup)の down ガードと対称。
	if _cal_down:
		return
	if _finished != null and try_push(_finished):
		_finished = null
		_phase = "idle"
		set_state("idle")
		_notify_space()

func _release_operator() -> void:
	if _operator != null and operator_pool != null:
		operator_pool.release(_operator)
	_operator = null
