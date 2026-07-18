extends RefCounted
class_name TransportNetwork
## AGV 搬送ネットワーク（制御点グラフ＋最短経路ルーティング）。
## 制御点(nodes: id→Vector3)と辺(edges: [a,b] 双方向, 重み=ユークリッド距離)を保持し、
## 隣接リストを構築する。Dijkstra で 2 ノード間の最短経路（ノード列＋総距離）を返す。
## 乱数不使用・決定的（距離同値のタイブレークは id 昇順）。

var nodes: Dictionary = {}   # id(String) -> Vector3
var edges: Array = []        # [[a_id, b_id], ...]（正規化済み）
var _adj: Dictionary = {}    # id -> Array of {"to": id, "w": float}

# --- 容量／占有ブックキーピング（既定は無制限＝ドーマント） ---
# 既定容量は INF（無制限）なので、有限容量を明示設定したモデルでのみ輻輳が働く。
# 既存モデルの挙動・自己テストマーカーは一切変わらない（誰も予約しなければ占有は0のまま）。
# 乱数不使用・純データ・決定的。辺は無向として扱い、正規化キーで双方向を1本に束ねる。
var _edge_cap: Dictionary = {}      # ekey -> float 容量（未設定は INF）
var _edge_occ: Dictionary = {}      # ekey -> int  現在占有数
var _edge_waiters: Dictionary = {}  # ekey -> Array of {"who":.., "cb": Callable}（FIFO）
# --- stage2: 単一レーン方向ロック＆占有ピーク（有限容量辺でのみ意味を持つ） ---
# _edge_dir[k]: 現在この辺を占有している搬送者の「進入元ノード」。占有0のとき "" にリセット。
#   有限容量辺は「単一レーン」とみなし、占有中は同一方向（同一 from ノード）の進入のみ許可する。
#   これにより対向（逆方向）は辺が空くまで待たされ、正面衝突デッドロックを構造的に防ぐ。
# _edge_occ_peak[k]: 実行中に観測した最大同時占有（占有不変条件の検証ウィットネス）。
var _edge_dir: Dictionary = {}      # ekey -> String 現方向（進入元ノード id）／空=未占有
var _edge_occ_peak: Dictionary = {} # ekey -> int  観測最大同時占有
var _node_cap: Dictionary = {}      # id   -> float 容量（未設定は INF）
var _node_occ: Dictionary = {}      # id   -> int  現在占有数
var _node_waiters: Dictionary = {}  # id   -> Array of {"who":.., "cb": Callable}（FIFO）
var _node_occ_peak: Dictionary = {} # id   -> int  観測最大同時占有（占有不変条件の検証ウィットネス）

func _init(nodes_in: Dictionary = {}, edges_in: Array = []) -> void:
	build(nodes_in, edges_in)

## nodes(id→座標) と edges([a,b]) からグラフを再構築する。
func build(nodes_in: Dictionary, edges_in: Array) -> void:
	nodes = {}
	for k in nodes_in.keys():
		nodes[str(k)] = _to_v3(nodes_in[k])
	edges = []
	_adj = {}
	# グラフ再構築時は容量・占有・待ち行列も初期化（新しいグラフに対する live 状態）。
	# 容量はモデルが build 後に set_edge_capacity/set_node_capacity で設定する。
	_edge_cap = {}
	_edge_occ = {}
	_edge_waiters = {}
	_edge_dir = {}
	_edge_occ_peak = {}
	_node_cap = {}
	_node_occ = {}
	_node_waiters = {}
	_node_occ_peak = {}
	for id in nodes.keys():
		_adj[id] = []
	for e in edges_in:
		if not (e is Array) or e.size() < 2:
			continue
		var a: String = str(e[0])
		var b: String = str(e[1])
		if a == b or not nodes.has(a) or not nodes.has(b):
			continue
		var w: float = nodes[a].distance_to(nodes[b])
		edges.append([a, b])
		_adj[a].append({"to": b, "w": w})
		_adj[b].append({"to": a, "w": w})

func node_count() -> int:
	return nodes.size()

func is_empty() -> bool:
	return nodes.is_empty()

## 任意座標 pos を最寄り制御点 id に対応づける。距離同値は id 昇順で決定的。空なら ""。
func nearest_node(pos: Vector3) -> String:
	var best: String = ""
	var bd: float = INF
	for id in nodes.keys():
		var d: float = nodes[id].distance_to(pos)
		if d < bd or (d == bd and (best == "" or String(id) < best)):
			bd = d
			best = id
	return best

## 2 ノード間の最短経路。{"nodes": [id...], "dist": float}。到達不能/未知は {[], INF}。
## Dijkstra。未訪問最小距離ノードの選択は距離昇順→id 昇順の決定的タイブレーク。
func shortest_path(a_id_in, b_id_in) -> Dictionary:
	var a_id: String = str(a_id_in)
	var b_id: String = str(b_id_in)
	if not nodes.has(a_id) or not nodes.has(b_id):
		return {"nodes": [], "dist": INF}
	if a_id == b_id:
		return {"nodes": [a_id], "dist": 0.0}
	var dist: Dictionary = {}
	var prev: Dictionary = {}
	var visited: Dictionary = {}
	for id in nodes.keys():
		dist[id] = INF
	dist[a_id] = 0.0
	while true:
		# 未訪問で最小距離のノードを選ぶ（距離同値は id 昇順）。
		var u: String = ""
		var best: float = INF
		for id in nodes.keys():
			if visited.has(id):
				continue
			var d: float = dist[id]
			if d < best or (d == best and (u == "" or String(id) < u)):
				best = d
				u = id
		if u == "" or best == INF:
			break
		if u == b_id:
			break
		visited[u] = true
		for e in _adj[u]:
			var v: String = e["to"]
			if visited.has(v):
				continue
			var nd: float = dist[u] + float(e["w"])
			if nd < dist[v]:
				dist[v] = nd
				prev[v] = u
	if dist[b_id] == INF:
		return {"nodes": [], "dist": INF}
	# 経路復元
	var path: Array = []
	var cur: String = b_id
	while cur != a_id:
		path.push_front(cur)
		if not prev.has(cur):
			return {"nodes": [], "dist": INF}
		cur = prev[cur]
	path.push_front(a_id)
	return {"nodes": path, "dist": dist[b_id]}

## from_pos → target をネットワーク経由で走行する際の中間制御点座標列を返す。
## nearest_node(from_pos) から nearest_node(target) までの最短経路上のノード座標列。
## ネットワークが空/到達不能なら空配列（＝直行）。
func route_points(from_pos: Vector3, target: Vector3) -> Array:
	if nodes.is_empty():
		return []
	var na: String = nearest_node(from_pos)
	var nb: String = nearest_node(target)
	if na == "" or nb == "":
		return []
	var sp: Dictionary = shortest_path(na, nb)
	var pts: Array = []
	for id in sp["nodes"]:
		pts.append(nodes[id])
	return pts

# ===============================================================
# 容量・占有・待ち行列プリミティブ（純データ／決定的／乱数不使用）
# ---------------------------------------------------------------
# 既定容量は INF（無制限）。try_reserve_* は既定では常に成功するため、
# 容量を明示設定しないモデルでは占有カウントが増えても上限に当たらず、
# 既存挙動・自己テストの全マーカー値はバイト一致のまま（＝ドーマント）。
# 実際にカレンダー上で「待つ」イベント化は stage2（Transporter）で行う。
# ここでは占有が容量を超えない保証と、決定的な FIFO 起床のみを提供する。

## 無向辺の正規化キー（a,b の順序に依らず同一辺を1本として扱う）。
## 区切りに ASCII Unit Separator(0x1F) を用いノード id との衝突を避ける。
func _ekey(a: String, b: String) -> String:
	if a <= b:
		return a + "" + b
	return b + "" + a

# --- 辺（無向）---
## 辺 a-b の容量を設定。cap=INF で無制限（既定に戻す）。有限値でのみ輻輳が働く。
func set_edge_capacity(a, b, cap: float) -> void:
	_edge_cap[_ekey(str(a), str(b))] = cap

## 辺 a-b の容量（未設定は INF＝無制限）。
func edge_capacity(a, b) -> float:
	return float(_edge_cap.get(_ekey(str(a), str(b)), INF))

## 辺 a-b の現在占有数（未使用は 0）。
func edge_occupancy(a, b) -> int:
	return int(_edge_occ.get(_ekey(str(a), str(b)), 0))

## 辺 a-b を who のために予約。空きがあれば占有を +1 して true、満杯なら false。
## 占有が容量を超えないことをこの API レベルで保証する。
func try_reserve_edge(a, b, who) -> bool:
	var k: String = _ekey(str(a), str(b))
	var cap: float = float(_edge_cap.get(k, INF))
	var occ: int = int(_edge_occ.get(k, 0))
	if occ < cap:
		_edge_occ[k] = occ + 1
		return true
	return false

## 辺 a-b の予約を解放（占有を -1、下限 0 でクランプ）。
func release_edge(a, b, who) -> void:
	var k: String = _ekey(str(a), str(b))
	var occ: int = int(_edge_occ.get(k, 0))
	if occ > 0:
		_edge_occ[k] = occ - 1

## 辺 a-b の待ち行列に who を FIFO 登録（cb は空き通知コールバック）。
## 同一 who の二重登録は無視（1 who は同一辺で高々1スロットを待つ）。
func enqueue_edge_waiter(a, b, who, cb: Callable) -> void:
	var k: String = _ekey(str(a), str(b))
	var q: Array = _edge_waiters.get(k, [])
	for w in q:
		if w["who"] == who:
			return
	q.append({"who": who, "cb": cb})
	_edge_waiters[k] = q

## 辺 a-b の待ち行列で最長待ち（先頭）を1件取り出しコールバックを呼ぶ。
## 起床対象がいれば true。予約は行わない（cb 側で try_reserve_edge を再試行する契約）。
func _wake_next_edge_waiter(a, b) -> bool:
	var k: String = _ekey(str(a), str(b))
	var q: Array = _edge_waiters.get(k, [])
	if q.is_empty():
		return false
	var w: Dictionary = q.pop_front()
	_edge_waiters[k] = q
	var cb: Callable = w.get("cb", Callable())
	if cb.is_valid():
		cb.call()
	return true

## 辺 a-b の待ち人数（検証・introspection 用）。
func edge_waiter_count(a, b) -> int:
	var q = _edge_waiters.get(_ekey(str(a), str(b)), [])
	return q.size()

# ===============================================================
# stage2: カレンダー統合用「予約 or FIFO待機」API（Transporter が使う）
# ---------------------------------------------------------------
# request_edge / finish_edge は「占有」「単一レーン方向ロック」「FIFO 起床」を
# ネットワーク側で原子的に扱う。占有加算は _edge_can_admit が真のときのみ行うため、
# いかなる瞬間も占有が容量を超えない（占有不変条件）。無制限(INF)辺は方向ロックも
# 待機も一切発生しないため、有限容量を設定しないモデルでは完全にドーマント。

## いずれかの辺に有限容量が設定されていれば true（＝輻輳エンジンを起動する条件）。
## 全辺 INF（既定）なら false → Transporter は従来の直行スケジュールを使う（バイト一致）。
func has_finite_edge_capacity() -> bool:
	for k in _edge_cap.keys():
		if not is_inf(float(_edge_cap[k])):
			return true
	return false

## 辺 k へ from_node 方向で進入できるか。
## - 占有>=容量 → 不可（占有不変条件）。
## - INF 辺 → 常に可（単一レーン扱いしない＝方向ロック無し）。
## - 有限辺で占有0 → 可（この搬送者が方向を決める）。
## - 有限辺で占有>0 → 現方向（_edge_dir）と同一方向のときのみ可（対向は待機）。
func _edge_can_admit(k: String, from_node: String) -> bool:
	var cap: float = float(_edge_cap.get(k, INF))
	var occ: int = int(_edge_occ.get(k, 0))
	if occ >= cap:
		return false
	if is_inf(cap):
		return true
	if occ == 0:
		return true
	return String(_edge_dir.get(k, "")) == from_node

## 辺 k を from_node 方向で占有（占有 +1、方向確定、ピーク更新）。事前に _edge_can_admit 前提。
func _admit_edge(k: String, from_node: String) -> void:
	var occ: int = int(_edge_occ.get(k, 0))
	if occ == 0:
		_edge_dir[k] = from_node
	occ += 1
	_edge_occ[k] = occ
	if occ > int(_edge_occ_peak.get(k, 0)):
		_edge_occ_peak[k] = occ

## 搬送者 who が辺 a-b へ from_node 方向で進入を要求する。
## - 待機列が空 かつ 進入可 → 直ちに占有して true（呼び出し側は即横断）。
## - それ以外 → FIFO 待機列末尾へ登録して false（追い越し禁止）。空きが出たら
##   ネットワークが占有を確定した上で cb を呼ぶ（cb 側は再予約不要で横断開始）。
func request_edge(a, b, who, from_node, cb: Callable) -> bool:
	var k: String = _ekey(str(a), str(b))
	var fn: String = str(from_node)
	var q: Array = _edge_waiters.get(k, [])
	if q.is_empty() and _edge_can_admit(k, fn):
		_admit_edge(k, fn)
		return true
	for w in q:
		if w["who"] == who:
			return false
	q.append({"who": who, "from": fn, "cb": cb})
	_edge_waiters[k] = q
	return false

## 搬送者 who が辺 a-b（from_node 方向）の横断を完了して占有を解放する。
## 占有 -1、占有0で方向ロック解除、その後 FIFO 待機列を可能な限り起床させる。
func finish_edge(a, b, who, from_node) -> void:
	var k: String = _ekey(str(a), str(b))
	var occ: int = int(_edge_occ.get(k, 0))
	if occ > 0:
		occ -= 1
		_edge_occ[k] = occ
	if occ == 0:
		_edge_dir[k] = ""
	_wake_edge_fifo(k)

## 辺 k の FIFO 待機列を先頭から、進入可能な限り起床させる（占有を確定して cb を呼ぶ）。
## 先頭が進入不可（容量満杯／対向方向）になった時点で停止（追い越し禁止＝決定的）。
func _wake_edge_fifo(k: String) -> void:
	var q: Array = _edge_waiters.get(k, [])
	while not q.is_empty():
		var front: Dictionary = q[0]
		var fn: String = str(front.get("from", ""))
		if not _edge_can_admit(k, fn):
			break
		q.pop_front()
		_admit_edge(k, fn)
		var cb: Callable = front.get("cb", Callable())
		if cb.is_valid():
			cb.call()
	_edge_waiters[k] = q

## 辺 a-b の現方向（進入元ノード id）。未占有は ""（introspection／検証用）。
func edge_direction(a, b) -> String:
	return String(_edge_dir.get(_ekey(str(a), str(b)), ""))

## 辺 a-b の観測最大同時占有（占有不変条件の検証ウィットネス）。
func edge_occupancy_peak(a, b) -> int:
	return int(_edge_occ_peak.get(_ekey(str(a), str(b)), 0))

## 全辺で「占有ピーク <= 容量」が成り立つか（占有不変条件の全域チェック）。
func occupancy_within_capacity() -> bool:
	for k in _edge_occ_peak.keys():
		if float(_edge_occ_peak[k]) > float(_edge_cap.get(k, INF)):
			return false
	return true

# --- ノード ---
## ノード id の容量を設定。cap=INF で無制限（既定）。有限値でのみ輻輳が働く。
func set_node_capacity(id, cap: float) -> void:
	_node_cap[str(id)] = cap

## ノード id の容量（未設定は INF＝無制限）。
func node_capacity(id) -> float:
	return float(_node_cap.get(str(id), INF))

## ノード id の現在占有数（未使用は 0）。
func node_occupancy(id) -> int:
	return int(_node_occ.get(str(id), 0))

## ノード id を who のために予約。空きがあれば占有を +1 して true、満杯なら false。
func try_reserve_node(id, who) -> bool:
	var k: String = str(id)
	var cap: float = float(_node_cap.get(k, INF))
	var occ: int = int(_node_occ.get(k, 0))
	if occ < cap:
		_node_occ[k] = occ + 1
		return true
	return false

## ノード id の予約を解放（占有を -1、下限 0 でクランプ）。
func release_node(id, who) -> void:
	var k: String = str(id)
	var occ: int = int(_node_occ.get(k, 0))
	if occ > 0:
		_node_occ[k] = occ - 1

## ノード id の待ち行列に who を FIFO 登録（同一 who の二重登録は無視）。
func enqueue_node_waiter(id, who, cb: Callable) -> void:
	var k: String = str(id)
	var q: Array = _node_waiters.get(k, [])
	for w in q:
		if w["who"] == who:
			return
	q.append({"who": who, "cb": cb})
	_node_waiters[k] = q

## ノード id の待ち行列で最長待ち（先頭）を1件取り出しコールバックを呼ぶ。起床すれば true。
func _wake_next_node_waiter(id) -> bool:
	var k: String = str(id)
	var q: Array = _node_waiters.get(k, [])
	if q.is_empty():
		return false
	var w: Dictionary = q.pop_front()
	_node_waiters[k] = q
	var cb: Callable = w.get("cb", Callable())
	if cb.is_valid():
		cb.call()
	return true

## ノード id の待ち人数（検証・introspection 用）。
func node_waiter_count(id) -> int:
	var q = _node_waiters.get(str(id), [])
	return q.size()

# ===============================================================
# stage3: ノード（交差点）インターロック用「予約 or FIFO待機」API（Transporter が使う）
# ---------------------------------------------------------------
# request_node / finish_node は edge 版（request_edge/finish_edge）と対称で、ノード占有・
# FIFO 起床をネットワーク側で原子的に扱う。占有加算は容量に空きがあるときのみ行うため、
# いかなる瞬間もノード占有が容量を超えない（占有不変条件）。未設定ノードは INF なので
# request_node は常に即成功（待機ゼロ・占有は増えても上限に当たらない）。よって有限ノード
# 容量を1つも設定しないモデルでは Transporter 側ガード（has_finite_node_capacity）が false に
# なり、この経路は一切踏まれず既存挙動・全マーカーがバイト一致（＝完全ドーマント）。

## いずれかのノードに有限容量が設定されていれば true（＝ノードインターロックを起動する条件）。
## 全ノード INF（既定）なら false → Transporter はノード予約を一切行わない（バイト一致）。
func has_finite_node_capacity() -> bool:
	for k in _node_cap.keys():
		if not is_inf(float(_node_cap[k])):
			return true
	return false

## ノード占有ピークを更新（占有不変条件の検証ウィットネス）。占有を +1 した直後に呼ぶ。
func _bump_node_peak(k: String) -> void:
	var occ: int = int(_node_occ.get(k, 0))
	if occ > int(_node_occ_peak.get(k, 0)):
		_node_occ_peak[k] = occ

## 搬送者 who がノード id への進入（占有）を要求する。
## - 待機列が空 かつ 空きがある → 直ちに占有(+1)して true（呼び出し側は即進入）。
## - それ以外 → FIFO 待機列末尾へ登録して false（追い越し禁止＝決定的）。空きが出たら
##   ネットワークが占有を確定した上で cb を呼ぶ（cb 側は再予約不要で進入）。
## INF ノードは常に即成功（占有は増えるが上限に当たらず、待機も方向制約も無い）。
func request_node(id, who, cb: Callable) -> bool:
	var k: String = str(id)
	var q: Array = _node_waiters.get(k, [])
	if q.is_empty() and try_reserve_node(k, who):
		_bump_node_peak(k)
		return true
	enqueue_node_waiter(k, who, cb)
	return false

## 搬送者 who がノード id の占有を解放する（下流へ通過完了）。
## 占有 -1 の後、FIFO 待機列を空きがある限り起床させる（占有を確定して cb を呼ぶ）。
func finish_node(id, who) -> void:
	release_node(id, who)
	_wake_node_fifo(str(id))

## ノード k の FIFO 待機列を先頭から、空きがある限り起床させる（占有を確定して cb を呼ぶ）。
## 先頭が満杯で進入不可になった時点で停止（追い越し禁止＝決定的）。
func _wake_node_fifo(k: String) -> void:
	var q: Array = _node_waiters.get(k, [])
	while not q.is_empty():
		var occ: int = int(_node_occ.get(k, 0))
		var cap: float = float(_node_cap.get(k, INF))
		if occ >= cap:
			break
		var front: Dictionary = q.pop_front()
		_node_occ[k] = occ + 1
		_bump_node_peak(k)
		var cb: Callable = front.get("cb", Callable())
		if cb.is_valid():
			cb.call()
	_node_waiters[k] = q

## ノード id の観測最大同時占有（占有不変条件の検証ウィットネス）。
func node_occupancy_peak(id) -> int:
	return int(_node_occ_peak.get(str(id), 0))

## 全ノードで「占有ピーク <= 容量」が成り立つか（占有不変条件の全域チェック）。
func node_occupancy_within_capacity() -> bool:
	for k in _node_occ_peak.keys():
		if float(_node_occ_peak[k]) > float(_node_cap.get(k, INF)):
			return false
	return true

# ===============================================================
# ストール（デッドロック）ウォッチドッグ & 静的レイアウト診断
# ---------------------------------------------------------------
# いずれも純データ・乱数不使用・決定的で、既存の走行経路からは一切呼ばれない（テストハーネス／
# 診断からのみ呼ぶ opt-in ヘルパ）。よってコアイベントループにも占有・rng にも影響せず、既存の
# 98 マーカーはバイト一致のまま。fable5 erratum の安全条件検証に用いる。

## 現在いずれかの辺・ノードの FIFO 待機列に積まれている搬送者の総数（introspection・純データ）。
## 0＝誰も容量待ちしていない。>0＝容量が空くまで進めない搬送者がいる（ストールの必要条件）。
func waiting_count() -> int:
	var n: int = 0
	for k in _edge_waiters.keys():
		n += (_edge_waiters[k] as Array).size()
	for k in _node_waiters.keys():
		n += (_node_waiters[k] as Array).size()
	return n

## ストール（デッドロック）ウォッチドッグの一次判定: 容量待ちの搬送者が1人でも居るか。
## これ単体は「今この瞬間ブロックされている搬送者が居る」ことを示すに過ぎない（後で辺／ノードが
## 空いて起床する一時的な待ちも true になり得る）。恒久デッドロックの確証は「有界ランを回し切った
## 後（＝カレンダーに搬送を前進させるイベントがもう無い＝進捗ゼロ）でも本値が true」で得る。
## 使い方（テストハーネス）: Sim.run_until(T) で有界に回す → is_stalled() が true かつ 追加の
## Sim.run_until(2T) でシンク到達数が一切増えない（進捗ゼロ）なら、待機中の搬送者を起こすイベントが
## 存在しない＝デッドロック確定。ハングしない（run_until は時刻上限で必ず返る）。
func is_stalled() -> bool:
	return waiting_count() > 0

## 静的レイアウト診断（純データ・乱数不使用・決定的）。fable5 erratum のデッドロック十分条件
## 「対向流を運ぶ経路上で有限容量ノードが有限容量辺に隣接する（有限要素どうしの隣接）」に該当する
## 箇所を警告として列挙する。無向辺は本質的に対向流を許すため、有限辺の端点に有限ノードが在る配置は
## そのまま循環待ちの温床になる。返り値: 警告文字列の配列（辺キー昇順→端点 a,b 順で決定的）。空なら
## 危険な隣接なし。走行前に呼び出し側が実行可能性を静的に確かめるための診断（実行時挙動は変えない）。
func lint_layout() -> Array:
	var warns: Array = []
	# 辺を (a,b) 昇順キーでソートして決定的順序で走査する。
	var ekeys: Array = []
	var by_key: Dictionary = {}
	for e in edges:
		var a0: String = String(e[0])
		var b0: String = String(e[1])
		var k: String = _ekey(a0, b0)
		if not by_key.has(k):
			by_key[k] = [a0, b0]
			ekeys.append(k)
	ekeys.sort()
	for k in ekeys:
		var ab: Array = by_key[k]
		var a: String = String(ab[0])
		var b: String = String(ab[1])
		if is_inf(edge_capacity(a, b)):
			continue   # INF 辺は単一レーン扱いされず対向でも待たないので安全
		# 有限辺。端点に有限容量ノードが隣接していれば危険（有限要素の隣接）。
		if not is_inf(node_capacity(a)):
			warns.append("finite-capacity edge %s-%s is adjacent to finite-capacity node %s on an opposing-flow-capable path (deadlock risk: avoid adjacency of finite elements)" % [a, b, a])
		if not is_inf(node_capacity(b)):
			warns.append("finite-capacity edge %s-%s is adjacent to finite-capacity node %s on an opposing-flow-capable path (deadlock risk: avoid adjacency of finite elements)" % [a, b, b])
	return warns

## 占有・待ち行列のみ初期化（容量設定は保持）。reset_sim 間の決定論確保用（stage2）。
func reset_occupancy() -> void:
	_edge_occ = {}
	_edge_waiters = {}
	_edge_dir = {}
	_edge_occ_peak = {}
	_node_occ = {}
	_node_waiters = {}
	_node_occ_peak = {}

func _to_v3(a) -> Vector3:
	if a is Vector3:
		return a
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO
