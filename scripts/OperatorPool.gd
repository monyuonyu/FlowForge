extends Node3D
class_name OperatorPool
## 作業者プール（イベント駆動・FIFO公平割当）。
## 要求は待ち行列に積み、空いた作業者を先着順に割り当てる（登録順勝ちの飢餓を防ぐ）。

var operators: Array = []
var _waiting: Array = []   # 作業者待ちの Processor（FIFO・3D 側）
## 外部待機者フック（PF ProcessFlow など、このプールを共有する外部エンジン）。
## 既定空＝ドーマント。3D 内部待ち行列(_waiting)を捌き切っても空きが残る時のみ、
## 登録順に呼び出す（MIRROR: 3D 解放 → PF 待機の起床）。乱数は一切引かない＝決定論不変。
## register が無い＝従来経路と完全一致（[cal-op] 等 既存マーカーはバイト同一）。
var _external_waiters: Array = []   # Array[Callable]
## ディスパッチ規則: "fifo"(既定=登録順の先着) / "nearest"(要求元に最も近い空き作業者)。
## 既定 fifo は従来経路と完全一致（決定論不変）。
var dispatch_rule: String = "fifo"

## デバッグ用カウンタ（ロジックには不使用＝決定論に影響しない）。
## no_leak 検証: 稼働へ送り出した回数(dispatch)と解放した回数(release)。
## 静穏化時点で outstanding = dispatch_count - release_count が 0 になり、
## available_count() == operators数 - outstanding が厳密に成立することを確認する。
var dispatch_count: int = 0
var release_count: int = 0

func _ready() -> void:
	Sim.register(self)

func set_dispatch_rule(rule: String) -> void:
	dispatch_rule = "nearest" if rule == "nearest" else "fifo"

func add_operator(op: Operator) -> void:
	if not operators.has(op):
		operators.append(op)

func reset_object() -> void:
	_waiting.clear()
	# 外部待機フックも初期化（run 跨ぎの残留 Callable を排除＝決定論の衛生）。
	# 空なら no-op でバイト同一。PF はこのプールを共有する run で必要時に再登録する。
	_external_waiters.clear()
	dispatch_count = 0
	release_count = 0

## 外部待機者コールバックを登録（重複登録はしない）。PF が rr["waiters"] に
## トークンを積む時だけ呼ぶ。3D 解放で空きが出た際に起床通知を受け取れるようにする。
func register_external_waiter(cb: Callable) -> void:
	if not _external_waiters.has(cb):
		_external_waiters.append(cb)

## 外部待機者コールバックを解除（PF の待ち行列が空になったらドーマントへ戻す）。
func unregister_external_waiter(cb: Callable) -> void:
	_external_waiters.erase(cb)

func on_sim_start() -> void:
	# シフト稼働開始境界で待ち仕事を拾い直すウェイクイベントを仕込む。
	for op in operators:
		_arm_shift(op)

## 次の稼働開始時刻にウェイクを予約（シフト遷移は Sim.schedule で表現）。
func _arm_shift(op) -> void:
	if op.shift.is_empty():
		return
	var nt: float = op.next_on_time(Sim.sim_time)
	if nt == INF or nt <= Sim.sim_time:
		return
	Sim.schedule(nt - Sim.sim_time, func():
		if op.available and op.on_shift(Sim.sim_time):
			_assign_next(op)
		_arm_shift(op))

func available_count() -> int:
	var n: int = 0
	for op in operators:
		if op.available and op.on_shift(Sim.sim_time):
			n += 1
	return n

func request(proc) -> void:
	if dispatch_rule == "nearest":
		var target: Vector3 = proc.op_stand_pos()
		var best = null
		var best_d: float = INF
		for op in operators:
			if op.available and op.on_shift(Sim.sim_time):
				var d: float = op.logical_pos.distance_to(target)
				if d < best_d:
					best_d = d
					best = op
		if best != null:
			_dispatch(best, proc)
			return
		_waiting.append(proc)
		return
	# fifo（既定・従来経路と完全一致）
	for op in operators:
		if op.available and op.on_shift(Sim.sim_time):
			_dispatch(op, proc)
			return
	_waiting.append(proc)

func _dispatch(op: Operator, proc) -> void:
	op.available = false
	dispatch_count += 1
	var target: Vector3 = proc.op_stand_pos()
	var tt: float = op.travel_time(target)   # 現在位置→目的地（go_to 前に計算）
	op.go_to(target)
	# 到着は「通知」に留め、稼働計上(start_working)は Processor が実処理を開始する時に行う。
	# 到着〜着手のデッドタイムや down 中の待機を稼働として水増ししない。
	Sim.schedule(tt, func():
		proc._on_operator_ready(op))

## 解放時はその場で即 available。ホーム強制帰投を廃止（無駄な往復デッドタイムを除去）。
## 論理位置は作業位置のまま保持し、次タスクの移動時間は現在位置基準で計算される。
func release(op: Operator) -> void:
	release_count += 1
	op.stop_working()
	op.available = true
	op.set_idle()
	_assign_next(op)

func _assign_next(op: Operator) -> void:
	# off シフト中の作業者には新規割当しない（稼働中タスクは完了まで継続済み）。
	if not op.on_shift(Sim.sim_time):
		return
	while _waiting.size() > 0:
		var proc = _waiting.pop_front()
		if is_instance_valid(proc) and proc.still_needs_operator():
			_dispatch(op, proc)
			return
	# 3D 内部待ち行列を捌き切っても op が空きのまま → 外部待機者(PF)へ通知（MIRROR wakeup）。
	# 固定順: 3D 内部が先、その後 外部/PF。外部が無ければ即 return＝ドーマント。
	_notify_external(op)

## 空きユニット op を外部待機者へ登録順に提示する。3D 内部待ち行列を捌いた後にのみ呼ぶ。
## 乱数は引かない。外部が無ければ即 return（既存マーカーはバイト同一）。
## 反復中の register/unregister に備えて複製上を走査し、op が確保されたら打ち切る（二重配車防止）。
func _notify_external(op: Operator) -> void:
	if _external_waiters.is_empty():
		return
	for cb in _external_waiters.duplicate():
		if not op.available:
			break
		if cb.is_valid():
			cb.call()
