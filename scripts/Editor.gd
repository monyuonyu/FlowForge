extends Node3D
class_name Editor
## 編集モード：3Dピッキング選択、地面ドラッグ配置、追加/削除、
## 外部モデル割当、スクリプト適用、モデルの保存/読込を担う。

signal selection_changed(obj)
signal model_rebuilt()
signal transform_changed(obj)
## 右クリックでオブジェクト上に文脈メニューを開く要求（UI が PopupMenu を表示）。
##   obj: 対象 FlowObject / screen_pos: ビューポート座標（メニュー表示位置）
signal context_requested(obj, screen_pos)

var io: ModelIO
var model_root: Node3D
var ctx: Dictionary = {}

var edit_mode: bool = false
var measure_mode: bool = false
var wiring_mode: bool = false
var selected: FlowObject = null
## 複数選択（FlowObject のみ）。selected を PRIMARY（単一/最後に掴んだ対象）として温存し、
## |selection|<=1 のとき単一選択コードは一切変えずに動く（selection==[selected] または []）。
## 群移動/群削除/群複製はこの配列を対象にする（ユニットは複数選択に含めない ＝ 従来どおり単一）。
var selection: Array = []
## 群移動用：押下時に各メンバーの開始位置を控える（開始位置＋デルタで動かしドリフトを防ぐ）。
## 単一選択（size<=1）では常に空で、群ロジックは一切発火しない（従来挙動はバイト同一）。
var _group_starts: Dictionary = {}
## 選択中の資源ユニット（Operator / Transporter）。FlowObject 選択(selected)とは排他:
## 片方を選ぶともう片方は必ず null になる。型付き selected に代入できない Node3D 由来の
## ユニットを扱うため並行フィールドとして持ち、移動/改名/回転は _active() で一本化する。
var selected_unit = null
var measure: MeasureViz = null

# CAD 設定
var snap_enabled: bool = true
var snap_size: float = 1.0
var rot_snap_deg: float = 15.0

var _dragging: bool = false
var _drag_offset: Vector3 = Vector3.ZERO
var _drag_start_pos: Vector3 = Vector3.ZERO
# 右クリック：カメラ回転(右ドラッグ)と文脈メニュー(右クリック)を区別するため
# 押下位置を保持し、離した位置がほぼ同じ（＝ドラッグでない）ときのみメニューを開く。
var _rmb_press_pos: Vector2 = Vector2.ZERO
var _uid: int = 0
var _obj_seq: int = 0

# Undo/Redo（スナップショット式）
var _undo: Array = []
var _redo: Array = []
var _move_snap = null

# ドラッグ配線
var _wire_from: FlowObject = null
var _wire_mi: MeshInstance3D
var _wire_im: ImmediateMesh

# ラバーバンド選択（空き地の左ドラッグで矩形選択）
var _rubber_active: bool = false
var _rubber_start: Vector2 = Vector2.ZERO
var _rubber_shift: bool = false
var _rubber_layer: CanvasLayer = null
var _rubber_panel: Panel = null

# クリックで設置（配置モード）
var _placing: bool = false
var _pending_place_type: String = ""
var _ghost: MeshInstance3D = null

func setup(io_ref: ModelIO, root: Node3D, initial_ctx: Dictionary) -> void:
	io = io_ref
	model_root = root
	ctx = initial_ctx

func set_edit_mode(on: bool) -> void:
	edit_mode = on
	if on:
		Sim.pause()
	else:
		cancel_place()
		select(null)

func set_measure_mode(on: bool) -> void:
	measure_mode = on
	if on:
		cancel_place()
		wiring_mode = false
		select(null)

func set_wiring_mode(on: bool) -> void:
	wiring_mode = on
	if on:
		cancel_place()
		measure_mode = false
		select(null)
	_wire_from = null
	_ensure_wire()
	_wire_im.clear_surfaces()

## 文脈メニュー「配線元に設定」用。配線モードへ入り obj を配線元に据える。
## 次に接続先を左クリックすると obj→接続先 が接続される（_wire_input が元を維持）。
func begin_wire_from(obj) -> void:
	if obj == null:
		return
	set_wiring_mode(true)
	_wire_from = obj
	select(obj)
	Scripts.log_msg("🔗 配線元: %s — 接続先をクリック" % obj.obj_name)

## 配線を安全に中断する。配線元参照を解除し、配線モードを抜けてプレビュー線を消す。
## 配線元オブジェクトの削除／Undo(rebuild) で dangling 参照が残るのを防ぐ。
func _cancel_wiring() -> void:
	_wire_from = null
	wiring_mode = false
	if _wire_im != null:
		_wire_im.clear_surfaces()

func set_snap(on: bool) -> void:
	snap_enabled = on

# ---------------------------------------------------------------
# Undo / Redo
# ---------------------------------------------------------------
func _snapshot() -> Dictionary:
	return io.to_dict(ctx)

func push_undo() -> void:
	_undo.append(_snapshot())
	if _undo.size() > 100:
		_undo.pop_front()
	_redo.clear()

func can_undo() -> bool:
	return _undo.size() > 0

func can_redo() -> bool:
	return _redo.size() > 0

func undo() -> void:
	if _undo.is_empty():
		return
	_redo.append(_snapshot())
	var m: Dictionary = _undo.pop_back()
	rebuild(m)
	Scripts.log_msg("↶ 元に戻す")

func redo() -> void:
	if _redo.is_empty():
		return
	_undo.append(_snapshot())
	var m: Dictionary = _redo.pop_back()
	rebuild(m)
	Scripts.log_msg("↷ やり直し")

func snap_vec(v: Vector3) -> Vector3:
	if not snap_enabled or snap_size <= 0.0:
		return v
	return Vector3(round(v.x / snap_size) * snap_size, v.y, round(v.z / snap_size) * snap_size)

# ---------------------------------------------------------------
# 入力
# ---------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	# キーボード
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event.keycode)

	# 配置モード（クリックで設置）：選択/ドラッグ/配線/計測より優先。
	# 非配置時は一切介入しないため、既存の選択・ドラッグ挙動は不変。
	if _placing:
		_place_input(event)
		return

	# 配線モード
	if wiring_mode:
		_wire_input(event)
		return

	# メジャーモード（編集/実行に関わらず計測できる）
	if measure_mode:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var gp := _ground_point(event.position)
			if gp != Vector3.INF and measure != null:
				measure.add_point(snap_vec(gp))
		return

	if not edit_mode:
		return
	# 右クリック：オブジェクト上で文脈メニュー。右ドラッグ(カメラ回転)は妨げない
	# ため、押下→離すの移動量が小さいクリックのときだけメニューを開く。配置中は
	# _placing 分岐（上流）が右クリックを取消に使うので、ここへは来ない。
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			_rmb_press_pos = event.position
		elif event.position.distance_to(_rmb_press_pos) <= 6.0:
			var cobj = _pick(event.position)
			if cobj != null:
				select_any(cobj)
				# 文脈メニュー（複製/削除/配線元）は FlowObject 専用。ユニットは選択のみ。
				if cobj is FlowObject or cobj is Operator or cobj is Transporter:
					emit_signal("context_requested", cobj, event.position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var obj = _pick(event.position)
			# 空き地（何も掴んでいない）での左押下＝ラバーバンド選択の開始。カメラ回転は
			# 右ドラッグ、パンは中ドラッグなので左ドラッグは矩形選択に専有できる。ほぼ動かさ
			# ない「クリック」は release 時に従来どおり選択解除として扱う（Shift 併用で解除しない）。
			if obj == null:
				_begin_rubber(event.position, Input.is_key_pressed(KEY_SHIFT))
				return
			# Shift+クリック：FlowObject を選択トグル（他の選択は保持）。ドラッグは開始しない。
			if Input.is_key_pressed(KEY_SHIFT) and obj is FlowObject:
				toggle_selection(obj)
				return
			# 複数選択メンバーを掴んだら選択を保ったまま群移動の主対象に据える。
			# それ以外（単一選択・非メンバー・ユニット）は従来どおり単一選択（バイト同一）。
			if obj is FlowObject and selection.size() > 1 and selection.has(obj):
				_set_primary(obj)
			else:
				select_any(obj)   # FlowObject / ユニットを型で振り分けて選択
			if obj != null:
				var g := _ground_point(event.position)
				if g == Vector3.INF:
					return   # 地面をクリックできない角度：ドラッグ開始しない
				_dragging = true
				_drag_start_pos = obj.position
				_move_snap = _snapshot()   # 移動前の状態を保持
				_drag_offset = obj.position - Vector3(g.x, 0, g.z)
				_capture_group_starts()    # 群移動用に各メンバーの開始位置を控える（単一では空）
		else:
			# ラバーバンド確定：矩形内の FlowObject をまとめて選択
			if _rubber_active:
				_end_rubber(event.position)
				return
			# 移動が確定：実際に動いていたら undo に積む（FlowObject/ユニット共通）。群移動も
			# 主対象が動いたか＝群全体が動いたかなので、1押下で undo は1件（群でも1件）。
			var a = _active()
			if _dragging and a != null and _move_snap != null:
				if a.position.distance_to(_drag_start_pos) > 0.001:
					_undo.append(_move_snap)
					_redo.clear()
			_dragging = false
			_move_snap = null
			_group_starts = {}
	elif event is InputEventMouseMotion:
		# ラバーバンド中：矩形を更新（3Dは触らない）
		if _rubber_active:
			_update_rubber(event.position)
			return
		if _dragging and _active() != null:
			var g := _ground_point(event.position)
			if g != Vector3.INF:
				var new_pos := Vector3(g.x, 0, g.z) + Vector3(_drag_offset.x, 0, _drag_offset.z)
				new_pos = snap_vec(new_pos)
				# Shift で軸拘束（直交スナップ）
				if Input.is_key_pressed(KEY_SHIFT):
					if abs(new_pos.x - _drag_start_pos.x) >= abs(new_pos.z - _drag_start_pos.z):
						new_pos.z = _drag_start_pos.z
					else:
						new_pos.x = _drag_start_pos.x
				_move_selected(new_pos)
				# 群移動：主対象と同じスナップ済みデルタで他メンバーも動かす。各メンバーは
				# 「開始位置＋デルタ」で置くのでドラッグ中の累積ドリフトが出ない（決定論）。
				if selection.size() > 1:
					var gdelta: Vector3 = new_pos - _drag_start_pos
					for m in selection:
						if m != selected and is_instance_valid(m) and _group_starts.has(m):
							_move_fo_to(m, _group_starts[m] + gdelta)
				emit_signal("transform_changed", _active())

func _wire_input(event: InputEvent) -> void:
	# 配線元が破棄済み（削除／Undo 経由）なら freed 参照へ触れる前に安全に中断する。
	if _wire_from != null and not is_instance_valid(_wire_from):
		_cancel_wiring()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# 文脈メニュー「配線元に設定」で据えた配線元は press で上書きしない。
			# 通常のドラッグ配線は release 時に _wire_from=null へ戻るため常に null 始まりで、
			# この分岐に影響しない（従来挙動は不変）。
			if _wire_from == null:
				# ユニットにもピッカーが付いたため、配線は FlowObject のみを対象にする。
				var wpick = _pick(event.position)
				if wpick is FlowObject:
					_wire_from = wpick
					select(wpick)
		else:
			var target = _pick(event.position)
			if _wire_from != null and target is FlowObject:
				# ドラッグ配線もインスペクタと同じ can_connect で検証する。自己ループ/重複/
				# 受理不能先は理由付きで拒否し、push_undo しない（空の Undo を作らない）。
				var wres: Dictionary = can_connect(_wire_from, target)
				if wres.ok:
					push_undo()
					_wire_from.connect_to(target)
					Scripts.log_msg("🔗 配線: %s → %s" % [_wire_from.obj_name, target.obj_name])
					Sim.reset_sim()
					emit_signal("model_rebuilt")
				elif target != _wire_from:
					# 同一オブジェクトのクリックは「配線の取消」なので黙って無視。
					# それ以外の拒否（重複・受理不能先）は理由を提示する。
					Scripts.log_msg("⚠ 配線不可: %s" % wres.reason)
			_wire_from = null
			_wire_im.clear_surfaces()
	elif event is InputEventMouseMotion and _wire_from != null:
		var g := _ground_point(event.position)
		if g != Vector3.INF:
			_draw_wire(_wire_from.global_position + Vector3(0, 1.0, 0), g + Vector3(0, 0.5, 0))

func _ensure_wire() -> void:
	if _wire_mi != null:
		return
	_wire_mi = MeshInstance3D.new()
	_wire_im = ImmediateMesh.new()
	_wire_mi.mesh = _wire_im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.95, 1.0)
	mat.no_depth_test = true
	_wire_mi.material_override = mat
	add_child(_wire_mi)

func _draw_wire(a: Vector3, b: Vector3) -> void:
	_ensure_wire()
	_wire_im.clear_surfaces()
	_wire_im.surface_begin(Mesh.PRIMITIVE_LINES)
	_wire_im.surface_add_vertex(a)
	_wire_im.surface_add_vertex(b)
	_wire_im.surface_end()

# ---------------------------------------------------------------
# ラバーバンド選択（空き地の左ドラッグで矩形選択）
# ---------------------------------------------------------------
## 矩形描画用の 2D オーバーレイ（半透明の塗り＋枠）を遅延生成する。UI(CanvasLayer layer=1)
## より下・3D より上（layer=0）に置き、ツールバー等を覆わない。マウスは透過させる。
func _ensure_rubber() -> void:
	if _rubber_panel != null:
		return
	_rubber_layer = CanvasLayer.new()
	_rubber_layer.layer = 0
	add_child(_rubber_layer)
	_rubber_panel = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.35, 0.75, 1.0, 0.12)
	sb.border_color = Color(0.45, 0.9, 1.0, 0.95)
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	_rubber_panel.add_theme_stylebox_override("panel", sb)
	_rubber_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rubber_panel.visible = false
	_rubber_layer.add_child(_rubber_panel)

func _begin_rubber(pos: Vector2, add: bool) -> void:
	_ensure_rubber()
	_rubber_active = true
	_rubber_start = pos
	_rubber_shift = add
	_rubber_panel.position = pos
	_rubber_panel.size = Vector2.ZERO
	_rubber_panel.visible = true

func _update_rubber(pos: Vector2) -> void:
	if _rubber_panel == null:
		return
	var r := Rect2(_rubber_start, Vector2.ZERO).expand(pos)
	_rubber_panel.position = r.position
	_rubber_panel.size = r.size

## 矩形確定。ほぼ動かさない場合はクリック扱い＝選択解除（Shift 併用なら現在選択を維持）。
## 実ドラッグなら、画面座標が矩形内に入る FlowObject を集めて選択（Shift で現在選択へ追加）。
func _end_rubber(pos: Vector2) -> void:
	_rubber_active = false
	if _rubber_panel != null:
		_rubber_panel.visible = false
	var moved: bool = _rubber_start.distance_to(pos) > 4.0
	if not moved:
		# 空き地クリック＝選択解除（従来挙動）。Shift 付きは現在選択を保つ。
		if not _rubber_shift:
			select(null)
		return
	var r := Rect2(_rubber_start, Vector2.ZERO).expand(pos)
	var cam := get_viewport().get_camera_3d()
	var hits: Array = []
	if cam != null:
		for o in ctx.get("flow_objects", []):
			if not is_instance_valid(o):
				continue
			if cam.is_position_behind(o.global_position):
				continue   # カメラ背後は unproject が不定になるため除外
			var sp: Vector2 = cam.unproject_position(o.global_position)
			if r.has_point(sp):
				hits.append(o)
	if _rubber_shift:
		_add_to_selection(hits)   # 現在選択へ追加
	else:
		_set_selection(hits)      # 置き換え（0件なら選択解除）

# ---------------------------------------------------------------
# 複数選択（FlowObject）ヘルパー
# ---------------------------------------------------------------
## 選択集合を arr（FlowObject 群）で置き換える。ユニット選択と旧ハイライトを解除し、
## 全メンバーにハイライトを付け、PRIMARY を末尾要素に据える（0件なら選択なし）。
func _set_selection(arr: Array) -> void:
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.set_selected(false)
	selected_unit = null
	for s in selection:
		if s != null and is_instance_valid(s):
			s.set_selected(false)
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	selection = []
	for o in arr:
		if o != null and is_instance_valid(o) and o is FlowObject and not selection.has(o):
			selection.append(o)
			o.set_selected(true)
	selected = selection.back() if not selection.is_empty() else null
	emit_signal("selection_changed", selected)

## arr を現在選択へ追加（重複は無視）。PRIMARY は追加後の末尾に更新（Shift+矩形で使用）。
func _add_to_selection(arr: Array) -> void:
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.set_selected(false)
	selected_unit = null
	for o in arr:
		if o != null and is_instance_valid(o) and o is FlowObject and not selection.has(o):
			selection.append(o)
			o.set_selected(true)
	if not selection.is_empty():
		selected = selection.back()
	emit_signal("selection_changed", selected)

## Shift+クリック：FlowObject を選択に足す/外す（他は保持）。PRIMARY は最後に触った対象。
func toggle_selection(obj) -> void:
	if obj == null or not is_instance_valid(obj) or not (obj is FlowObject):
		return
	# ユニット選択中なら解除（複数選択は FlowObject 対象）
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.set_selected(false)
	selected_unit = null
	if selection.has(obj):
		selection.erase(obj)
		obj.set_selected(false)
		if selected == obj:
			selected = selection.back() if not selection.is_empty() else null
	else:
		selection.append(obj)
		obj.set_selected(true)
		selected = obj
	emit_signal("selection_changed", selected)

## 群移動の主対象を obj に切り替える（ハイライトは全メンバー維持）。掴んだメンバーを主に据え、
## インスペクタに主対象を反映させるための最小操作（select() のように選択を畳まない）。
func _set_primary(obj) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	selected = obj
	emit_signal("selection_changed", selected)

## 群移動用に各メンバーの開始位置を控える（単一選択では空＝群ロジック不発）。
func _capture_group_starts() -> void:
	_group_starts = {}
	if selection.size() <= 1:
		return
	for m in selection:
		if is_instance_valid(m):
			_group_starts[m] = m.position

## FlowObject を new_pos へ移す（Conveyor は端点も同デルタで動かしてベルト再構築）。
## _move_selected の FlowObject 分岐と同じ規律を任意ノードへ適用する群移動用ヘルパー。
func _move_fo_to(o, new_pos: Vector3) -> void:
	if o == null or not is_instance_valid(o):
		return
	var delta: Vector3 = new_pos - o.position
	o.position = new_pos
	if o is Conveyor:
		o.start_point += delta
		o.end_point += delta
		o.build_belt()

# ---------------------------------------------------------------
# クリックで設置（配置モード）
# ---------------------------------------------------------------
## 配置モードへ入る。次の左クリックで地面上（スナップ後）に type_str を新規設置し、
## 配置モードを抜ける。Esc / 右クリックで取消。編集モード時のみ有効。
func begin_place(type_str: String) -> void:
	if not edit_mode:
		return
	_placing = true
	_pending_place_type = type_str
	# 他モードと排他（配置を最優先）
	wiring_mode = false
	_wire_from = null
	if _wire_im != null:
		_wire_im.clear_surfaces()
	measure_mode = false
	select(null)
	_ensure_ghost()
	_ghost.visible = true
	Scripts.log_msg("配置: %s — クリックで設置 / Escで取消" % type_str)

func cancel_place() -> void:
	_placing = false
	_pending_place_type = ""
	if _ghost != null:
		_ghost.visible = false

func is_placing() -> bool:
	return _placing

func placing_type() -> String:
	return _pending_place_type

func _place_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var g := _ground_point(event.position)
		if g != Vector3.INF and _ghost != null:
			var gp := snap_vec(Vector3(g.x, 0, g.z))
			_ghost.position = Vector3(gp.x, 0.5, gp.z)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var g := _ground_point(event.position)
			if g == Vector3.INF:
				return   # 地面をクリックできない角度：設置しない（配置モード継続）
			var pos := snap_vec(Vector3(g.x, 0, g.z))
			var t := _pending_place_type
			cancel_place()
			add_object_at(t, pos)   # push_undo + Sim.reset_sim は add_object_at 内
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			cancel_place()
			Scripts.log_msg("配置を取消")

func _ensure_ghost() -> void:
	if _ghost != null:
		return
	_ghost = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 1.0, 2.0)
	_ghost.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.4, 0.9, 1.0, 0.35)
	_ghost.material_override = mat
	_ghost.visible = false
	add_child(_ghost)

func _handle_key(kc: int) -> void:
	# テキスト入力中（LineEdit / TextEdit にフォーカス）はショートカットを奪わない。
	# 名前欄・パラメータ/スクリプト編集中の Delete / 矢印 / Ctrl+Z などは各フィールドへ委ねる。
	var foc = get_viewport().gui_get_focus_owner()
	if foc is LineEdit or foc is TextEdit:
		return
	# Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y / Ctrl+D
	if Input.is_key_pressed(KEY_CTRL):
		if kc == KEY_Z:
			if Input.is_key_pressed(KEY_SHIFT):
				redo()
			else:
				undo()
			return
		if kc == KEY_Y:
			redo()
			return
		if kc == KEY_D:
			# 選択の種別で複製先を振り分ける（ユニット優先、次に群複製、無ければ単一 FlowObject）。
			if selected_unit != null:
				duplicate_selected_unit()
			elif selection.size() > 1:
				duplicate_selection()
			else:
				duplicate_selected()
			return
	match kc:
		KEY_R:
			if _active() != null:
				rotate_selected(rot_snap_deg)
		# F: 選択にフォーカス（カメラ注視点を対象へ寄せ収める）。選択が無ければ全体をフィット。
		# ビュー専用でモデル/シミュレーションには一切触れない（undo にも積まない・決定論不変）。
		KEY_F:
			_focus_selection()
		# Home: 全オブジェクト（＋ユニット）を画面に収める（Fit-all）。ビュー専用。
		KEY_HOME:
			_frame_all()
		KEY_DELETE, KEY_BACKSPACE:
			# ユニット選択時は「その」ユニットを削除（末尾除去ではない）。次に群削除、
			# 無ければ単一 FlowObject 削除（単一経路は従来どおり・バイト同一）。
			if selected_unit != null:
				delete_selected_unit()
			elif selection.size() > 1:
				delete_selection()
			elif selected != null:
				delete_selected()
		KEY_ESCAPE:
			if _placing:
				cancel_place()
				Scripts.log_msg("配置を取消")
			elif _dragging and _active() != null:
				# ドラッグ中の Esc はドラッグを取消（開始位置へ復元）。deselect より優先。
				# これをしないと release 条件が外れ移動が undo 未記録になりスタックがずれる。
				_cancel_drag()
				Scripts.log_msg("移動を取消")
			elif measure_mode and measure != null:
				measure.finish_line()
			else:
				select(null)
		# 矢印キー：選択オブジェクト/ユニットを snap_size 刻みで X/Z にナッジ（undo記録・1押下1スナップ）
		KEY_LEFT:
			if _active() != null:
				nudge_selected(-snap_size, 0.0)
		KEY_RIGHT:
			if _active() != null:
				nudge_selected(snap_size, 0.0)
		KEY_UP:
			if _active() != null:
				nudge_selected(0.0, -snap_size)
		KEY_DOWN:
			if _active() != null:
				nudge_selected(0.0, snap_size)

func _move_selected(new_pos: Vector3) -> void:
	# 資源ユニット：見た目位置に加え、論理位置(logical_pos)とホーム(home)も同期する。
	# logical_pos は移動時間/最近傍ディスパッチの基準、home は reset/直列化(home キー)の基準。
	# 3者を一致させることで「ドラッグした場所」がそのまま round-trip し reset でも保たれる。
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.position = new_pos
		selected_unit.logical_pos = new_pos
		selected_unit.home = new_pos
		return
	if selected == null:
		return
	var delta := new_pos - selected.position
	selected.position = new_pos
	if selected is Conveyor:
		selected.start_point += delta
		selected.end_point += delta
		selected.build_belt()

## ドラッグ中の Esc：開始位置(_drag_start_pos)へ戻して状態を破棄する。正味移動ゼロなので
## release の undo 記録条件に載らず、Undo スタックが1件ずれる不整合を防ぐ（キャンセル＝復元）。
func _cancel_drag() -> void:
	var a = _active()
	if a != null and is_instance_valid(a):
		_move_selected(_drag_start_pos)
		# 群移動中の Esc：他メンバーも各々の開始位置へ戻す（群全体を復元）。
		if selection.size() > 1:
			for m in selection:
				if m != selected and is_instance_valid(m) and _group_starts.has(m):
					_move_fo_to(m, _group_starts[m])
		emit_signal("transform_changed", a)
	_dragging = false
	_move_snap = null
	_group_starts = {}

# 数値トランスフォーム（インスペクタから）
func set_obj_position(x: float, z: float) -> void:
	if _active() == null:
		return
	push_undo()
	_move_selected(Vector3(x, 0, z))
	emit_signal("transform_changed", _active())

# 矢印キーのナッジ（選択オブジェクトを (dx,0,dz) 平行移動）。undo記録込み。
# 構造変更ではなく座標のみの変更なので Sim.reset_sim は不要（既存の移動系と同様）。
func nudge_selected(dx: float, dz: float) -> void:
	var a = _active()
	if a == null:
		return
	push_undo()
	_move_selected(Vector3(a.position.x + dx, 0, a.position.z + dz))
	emit_signal("transform_changed", a)

# 名称変更（インスペクタから）。同名なら push_undo せず二重積みを避ける。
# FlowObject もユニットも obj_name を持つため _active() で一本化する。
func rename_selected(new_name: String) -> void:
	var a = _active()
	if a == null:
		return
	if a.obj_name == new_name:
		return
	push_undo()
	a.obj_name = new_name
	# ユニットは sim/ラベルが参照する op_name/t_name も同値に保つ（名前の窓口を一本化）。
	if a is Operator:
		a.op_name = new_name
	elif a is Transporter:
		a.t_name = new_name
	emit_signal("selection_changed", a)

func rotate_selected(deg: float) -> void:
	var a = _active()
	if a == null:
		return
	# 資源ユニット（作業者/搬送者）の rotation.y は論理的に無意味（見た目の向きに意味が無い）。
	# 黙って回す代わりに no-op として注意喚起し、Undo スタックも汚さない。
	if a is Operator or a is Transporter:
		Scripts.log_msg("⚠ 回転は作業者/搬送者には適用できません（向きは無意味）")
		return
	push_undo()
	# コンベヤは見た目(rotation.y)だけ回すと搬送経路(start/end)が旧線のまま残り、
	# 「回っているのにアイテムは元の線を流れる」乖離になる。端点を中心周りに回して
	# ベルトを再構築し、視覚とフロー経路を必ず一致させる（相対回転）。
	if a is Conveyor:
		_rotate_conveyor(a, deg_to_rad(deg))
	else:
		a.rotation.y += deg_to_rad(deg)
	emit_signal("transform_changed", a)

func set_rotation_deg(deg: float) -> void:
	var a = _active()
	if a == null:
		return
	if a is Operator or a is Transporter:
		Scripts.log_msg("⚠ 回転は作業者/搬送者には適用できません（向きは無意味）")
		return
	push_undo()
	# コンベヤは絶対角へ設定する場合も端点を回してベルトを再構築し、フロー経路を一致させる。
	if a is Conveyor:
		var d0: Vector3 = a.end_point - a.start_point
		var cur: float = atan2(-d0.z, d0.x)
		_rotate_conveyor(a, deg_to_rad(deg) - cur)
	else:
		a.rotation.y = deg_to_rad(deg)
	emit_signal("transform_changed", a)

## コンベヤの搬送経路(start/end)をベルト中点まわりに delta_rad 回して再構築する。
## スロット位置(_slot_pos)は start/end から計算されるため、これで「見た目」と「フロー経路」が
## 常に一致する。ノードの rotation.y は表示用にベルトの論理向きへ同期させる（build_belt が
## 子ベルトの二重回転を相殺する）。長さは回転で不変なので容量/スロット時間は変わらない。
func _rotate_conveyor(conv: Conveyor, delta_rad: float) -> void:
	var pivot: Vector3 = (conv.start_point + conv.end_point) * 0.5
	conv.start_point = _rot_y_around(conv.start_point, pivot, delta_rad)
	conv.end_point = _rot_y_around(conv.end_point, pivot, delta_rad)
	var dir: Vector3 = conv.end_point - conv.start_point
	conv.rotation.y = atan2(-dir.z, dir.x)   # 論理向き＝端点向き（インスペクタ表示と一致）
	conv.build_belt()

## 点 p を pivot を中心に Y 軸まわり a[rad] 回す（Godot の rotation.y と同じ符号・向き）。
func _rot_y_around(p: Vector3, pivot: Vector3, a: float) -> Vector3:
	var d: Vector3 = p - pivot
	var x: float = cos(a) * d.x + sin(a) * d.z
	var z: float = -sin(a) * d.x + cos(a) * d.z
	return pivot + Vector3(x, d.y, z)

func set_obj_scale(s: float) -> void:
	if selected == null:
		return
	push_undo()
	selected.apply_model(selected.model_path, max(0.05, s))
	emit_signal("transform_changed", selected)

# ---------------------------------------------------------------
# 選択
# ---------------------------------------------------------------
## FlowObject（または null）を選択する。ユニット選択は必ず解除する（相互排他）。
## selected_unit が常に null の従来経路では、追加した解除処理は no-op でバイト同一。
func select(obj) -> void:
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.set_selected(false)
	selected_unit = null
	# 複数選択の余剰メンバーのハイライトを解除（単一選択では selection==[selected] なので
	# ループは主対象をスキップして0回 ＝ set_selected 呼び出し数は従来と同じ・バイト同一）。
	for s in selection:
		if s != null and is_instance_valid(s) and s != selected:
			s.set_selected(false)
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	selected = obj
	selection = []
	if selected != null:
		selected.set_selected(true)
		selection.append(selected)
	emit_signal("selection_changed", selected)

## 資源ユニット（Operator / Transporter）を選択する。FlowObject 選択は必ず解除する。
## UI は selection_changed に載る型（is Operator / is Transporter）で編集面を切り替える。
func select_unit(unit) -> void:
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	# 複数選択の余剰メンバーのハイライトを解除（単一/未選択では0回・バイト同一）。
	for s in selection:
		if s != null and is_instance_valid(s) and s != selected:
			s.set_selected(false)
	selected = null
	selection = []
	if selected_unit != null and is_instance_valid(selected_unit):
		selected_unit.set_selected(false)
	selected_unit = unit
	if selected_unit != null:
		selected_unit.set_selected(true)
	emit_signal("selection_changed", selected_unit)

## ピック結果（FlowObject / ユニット / null）を型で振り分けて選択する。
## _pick はコリジョンの owner_obj を返すため、片方の select 系へ確実に流し込む。
func select_any(obj) -> void:
	if obj is FlowObject:
		select(obj)
	elif obj is Operator or obj is Transporter:
		select_unit(obj)
	else:
		select(null)

## 現在アクティブな選択（ユニット優先、無ければ FlowObject）。移動/改名/回転/ドラッグの
## 対象を一本化する窓口。ユニット未選択の従来経路では常に selected と等価。
func _active():
	if selected_unit != null and is_instance_valid(selected_unit):
		return selected_unit
	return selected

## UI 参照用の公開版（インスペクタが座標/回転の現在値を読むために使う）。
func selected_node():
	return _active()

# ---------------------------------------------------------------
# カメラ QoL（フォーカス / フィット）— すべてビュー専用（undo/Sim/直列化に非依存）
# ---------------------------------------------------------------
## アクティブなカメラ（CameraRig）を取得。無ければ null。
func _cam_rig():
	var cam = get_viewport().get_camera_3d()
	if cam != null and cam.has_method("focus_on"):
		return cam
	return null

## 対象を画面に収めるための概算半径。コンベヤは端点間長で、他は概ね2m四方の設備を想定。
func _node_radius(a) -> float:
	if a is Conveyor:
		return max(3.0, a.start_point.distance_to(a.end_point) * 0.6)
	return 3.0

## F キー：現在の選択（FlowObject / ユニット）へカメラ注視点を寄せてズームする。
## 選択が無ければ全体フィットにフォールバック。ビュー操作のみ（モデル不変）。
func _focus_selection() -> void:
	var cam = _cam_rig()
	if cam == null:
		return
	var a = _active()
	if a == null or not is_instance_valid(a):
		_frame_all()
		return
	cam.focus_on(a.global_position, _node_radius(a))

## Home / Fit-all：全オブジェクト（＋作業者/搬送者、コンベヤは端点も）を包む AABB を作り、
## カメラを中心へ寄せて全体が入る距離へズームする。対象が無ければ何もしない。
func _frame_all() -> void:
	var cam = _cam_rig()
	if cam == null:
		return
	var pts: Array = []
	for o in ctx.get("flow_objects", []):
		if is_instance_valid(o):
			pts.append(o.global_position)
			if o is Conveyor:
				pts.append(o.start_point)
				pts.append(o.end_point)
	for u in ctx.get("operators", []):
		if is_instance_valid(u):
			pts.append(u.global_position)
	for u in ctx.get("transporters", []):
		if is_instance_valid(u):
			pts.append(u.global_position)
	if pts.is_empty():
		return
	var aabb := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		aabb = aabb.expand(p)
	cam.frame_aabb(aabb)

func _pick(screen_pos: Vector2):
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	var col = hit.get("collider", null)
	if col != null and col.has_meta("owner_obj"):
		return col.get_meta("owner_obj")
	return null

func _ground_point(screen_pos: Vector2) -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.INF
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	if abs(dir.y) < 1e-5:
		return Vector3.INF
	var t := -from.y / dir.y
	if t < 0:
		return Vector3.INF
	return from + dir * t

# ---------------------------------------------------------------
# 追加 / 削除 / 割当 / スクリプト
# ---------------------------------------------------------------
# 既定配置位置（カメラ注視点あたり・スナップ後）。
func _default_place_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	var p := Vector3(0, 0, 0)
	if cam != null:
		var fwd := -cam.global_transform.basis.z
		p = cam.global_position + fwd * 12.0
		p.y = 0
	return snap_vec(p)

# 既定位置に追加（従来API・互換維持）。実体は add_object_at。
func add_object(type_str: String) -> FlowObject:
	return add_object_at(type_str, _default_place_pos())

# 指定位置に新規 FlowObject を設置する。undo 記録込み・構造変更として Sim.reset_sim。
func add_object_at(type_str: String, pos: Vector3) -> FlowObject:
	var o: FlowObject = io._make(type_str)
	if o == null:
		return null
	push_undo()
	o.id = _new_id(type_str)
	o.obj_name = "%s %d" % [type_str, ctx.flow_objects.size() + 1]
	var p := snap_vec(pos)
	p.y = 0
	o.position = p
	model_root.add_child(o)
	if o is Processor and ctx.pool != null:
		o.operator_pool = ctx.pool
	if o is Processor and ctx.get("transport_pool", null) != null:
		o.transport_pool = ctx.transport_pool
	if o is Conveyor:
		o.start_point = p + Vector3(-3, 0, 0)
		o.end_point = p + Vector3(3, 0, 0)
		o.build_belt()
	ctx.registry[o.id] = o
	ctx.flow_objects.append(o)
	Scripts.register_object(o.id, o)
	if o is Source:
		ctx.source = o
	if o is Sink:
		ctx.sink = o
	Scripts.log_msg("＋ 追加: %s (%s)" % [o.obj_name, o.id])
	Sim.reset_sim()   # 構造変更 → イベントカレンダーを再構築
	select(o)
	emit_signal("model_rebuilt")
	return o

func _new_id(type_str: String) -> String:
	_obj_seq += 1
	var base := "%s_%d" % [type_str.to_lower(), _obj_seq]
	while ctx.registry.has(base):
		_obj_seq += 1
		base = "%s_%d" % [type_str.to_lower(), _obj_seq]
	return base

# 選択オブジェクトを複製する。型・全パラメータ（分布含む）・回転・モデル・縮尺・スクリプトを
# ModelIO と同じ get_params/set_params 経路で丸ごとコピーし、原本から (snap_size,0,snap_size)
# ずらして配置、複製を選択する。undo記録込み・構造変更として Sim.reset_sim。
func duplicate_selected() -> FlowObject:
	if selected == null:
		return null
	var src: FlowObject = selected
	var type_str: String = src.type_name()
	var o: FlowObject = io._make(type_str)
	if o == null:
		return null
	# 原本の全状態を先に採取（select 後に selected が変わるため）
	var src_params: Dictionary = src.get_params().duplicate(true)
	var src_script: String = src.script_source
	var offset := Vector3(snap_size, 0, snap_size)
	push_undo()
	o.id = _new_id(type_str)
	o.obj_name = "%s のコピー" % src.obj_name
	var p := snap_vec(src.position + offset)
	p.y = 0
	o.position = p
	o.rotation.y = src.rotation.y
	o.model_path = src.model_path
	o.model_scale = src.model_scale
	model_root.add_child(o)   # _ready でモデル込みの見た目を構築
	if o is Processor and ctx.pool != null:
		o.operator_pool = ctx.pool
	if o is Processor and ctx.get("transport_pool", null) != null:
		o.transport_pool = ctx.transport_pool
	# 全パラメータ（分布・容量・故障設定 等）を丸ごと復元（保存/読込と同じ経路）
	o.set_params(src_params)
	if o is Conveyor and src is Conveyor:
		o.start_point = src.start_point + offset
		o.end_point = src.end_point + offset
		o.build_belt()
	ctx.registry[o.id] = o
	ctx.flow_objects.append(o)
	Scripts.register_object(o.id, o)
	# source/sink の主参照は既存を尊重（複製で上書きしない）
	if o is Source and ctx.get("source", null) == null:
		ctx.source = o
	if o is Sink and ctx.get("sink", null) == null:
		ctx.sink = o
	if src_script != "":
		o.set_logic(src_script)
	Scripts.log_msg("⧉ 複製: %s → %s (%s)" % [src.obj_name, o.obj_name, o.id])
	Sim.reset_sim()   # 構造変更 → イベントカレンダーを再構築
	select(o)
	emit_signal("model_rebuilt")
	return o

## src を offset ずらして複製する純粋ビルド（push_undo / Sim.reset_sim / select / model_rebuilt
## は行わない）。群複製が1回の undo・1回の reset で複数コピーを作れるよう副作用を切り出した版。
## duplicate_selected と同じ get_params/set_params 経路で全パラメータ・回転・モデル・縮尺・
## スクリプトをコピーする（接続エッジは単一複製と同様にコピーしない＝孤立コピー）。
func _dup_one(src: FlowObject, offset: Vector3) -> FlowObject:
	var type_str: String = src.type_name()
	var o: FlowObject = io._make(type_str)
	if o == null:
		return null
	var src_params: Dictionary = src.get_params().duplicate(true)
	var src_script: String = src.script_source
	o.id = _new_id(type_str)
	o.obj_name = "%s のコピー" % src.obj_name
	var p := snap_vec(src.position + offset)
	p.y = 0
	o.position = p
	o.rotation.y = src.rotation.y
	o.model_path = src.model_path
	o.model_scale = src.model_scale
	model_root.add_child(o)
	if o is Processor and ctx.pool != null:
		o.operator_pool = ctx.pool
	if o is Processor and ctx.get("transport_pool", null) != null:
		o.transport_pool = ctx.transport_pool
	o.set_params(src_params)
	if o is Conveyor and src is Conveyor:
		o.start_point = src.start_point + offset
		o.end_point = src.end_point + offset
		o.build_belt()
	ctx.registry[o.id] = o
	ctx.flow_objects.append(o)
	Scripts.register_object(o.id, o)
	if o is Source and ctx.get("source", null) == null:
		ctx.source = o
	if o is Sink and ctx.get("sink", null) == null:
		ctx.sink = o
	if src_script != "":
		o.set_logic(src_script)
	return o

## 群複製：選択中の全 FlowObject を1回の undo でまとめて複製し、コピー群を新しい選択にする。
## size<=1 は単一経路（duplicate_selected）へ委譲してバイト同一を保つ。offset は単一複製と同じ
## (snap,0,snap)。push_undo は1件・reset_sim は末尾で1回。
func duplicate_selection() -> void:
	if selection.size() <= 1:
		duplicate_selected()
		return
	var srcs: Array = []
	for s in selection:
		if is_instance_valid(s):
			srcs.append(s)
	if srcs.is_empty():
		return
	push_undo()
	var offset := Vector3(snap_size, 0, snap_size)
	var copies: Array = []
	for src in srcs:
		var c = _dup_one(src, offset)
		if c != null:
			copies.append(c)
	Scripts.log_msg("⧉ 群複製: %d個" % copies.size())
	Sim.reset_sim()   # 構造変更 → イベントカレンダーを再構築
	_set_selection(copies)   # コピー群を新しい選択に（PRIMARY は末尾）
	emit_signal("model_rebuilt")

func delete_selected() -> void:
	if selected == null:
		return
	push_undo()
	var o := selected
	select(null)
	# 配線中に対象を消すと _wire_from が dangling 参照になり _wire_input がクラッシュする。
	# キーボード Delete（_handle_key はモード判定より前に走る）を含め、削除時は配線を中断する。
	_cancel_wiring()
	# 上流・下流の接続を解除
	for up in ctx.flow_objects:
		up.outputs.erase(o)
	o.disconnect_all()
	ctx.flow_objects.erase(o)
	ctx.registry.erase(o.id)
	Scripts.objects_by_id.erase(o.id)
	Sim.unregister(o)
	if ctx.source == o:
		ctx.source = null
	if ctx.sink == o:
		ctx.sink = null
	Scripts.log_msg("－ 削除: %s" % o.obj_name)
	o.queue_free()
	Sim.reset_sim()   # 構造変更 → イベント/アイテムをクリアして再構築
	emit_signal("model_rebuilt")

## 群削除：選択中の全 FlowObject を1回の undo で削除する（push_undo は1件）。
## size<=1 は単一経路（delete_selected）へ委譲してバイト同一を保つ。各対象の上下流接続を外し、
## registry/Scripts/Sim から登録解除、source/sink 主参照も掃除して最後に一度だけ reset_sim。
func delete_selection() -> void:
	if selection.size() <= 1:
		delete_selected()
		return
	var victims: Array = []
	for s in selection:
		if is_instance_valid(s):
			victims.append(s)
	if victims.is_empty():
		return
	push_undo()
	select(null)          # 消す前に選択解除（dangling 参照防止・selection も空へ）
	_cancel_wiring()      # 配線元が対象なら dangling を避けて中断
	for o in victims:
		for up in ctx.flow_objects:
			up.outputs.erase(o)
		o.disconnect_all()
		ctx.flow_objects.erase(o)
		ctx.registry.erase(o.id)
		Scripts.objects_by_id.erase(o.id)
		Sim.unregister(o)
		if ctx.source == o:
			ctx.source = null
		if ctx.sink == o:
			ctx.sink = null
		o.queue_free()
	Scripts.log_msg("－ 群削除: %d個" % victims.size())
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 配線の妥当性を理由付きで判定する（実際の接続は行わない純粋クエリ）。
## 弾く条件: (1) 対象が無効/null、(2) 自己ループ(a→a)、(3) 既に張られた重複エッジ、
## (4) 入力を受理できない先（Source 等 can_receive_input()==false ＝ 永久ブロック）。
## 戻り値 {"ok":bool, "reason":String}（ok=true のとき reason は空）。
func can_connect(src, dst) -> Dictionary:
	if src == null or dst == null or not is_instance_valid(src) or not is_instance_valid(dst):
		return {"ok": false, "reason": "対象が無効です"}
	if src == dst:
		return {"ok": false, "reason": "自己ループ（同一オブジェクトへの接続）はできません"}
	if src.outputs.has(dst):
		return {"ok": false, "reason": "既に接続済みです（%s → %s）" % [src.obj_name, dst.obj_name]}
	if not dst.can_receive_input():
		return {"ok": false, "reason": "%s は入力を受け取れません（受理不能な先への配線は不可）" % dst.obj_name}
	return {"ok": true, "reason": ""}

func connect_selected_to(target_id: String) -> void:
	if selected == null:
		return
	var b = ctx.registry.get(target_id, null)
	# 無効/自己ループ/重複（＝no-op 再接続）/受理不能先は理由付きで拒否し、
	# push_undo しない（空の Undo エントリを作らない）。
	var res: Dictionary = can_connect(selected, b)
	if not res.ok:
		Scripts.log_msg("⚠ 接続不可: %s" % res.reason)
		return
	push_undo()
	selected.connect_to(b)
	Scripts.log_msg("→ 接続: %s → %s" % [selected.obj_name, b.obj_name])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 単一の出力エッジ（ポート index）を解除する。全解除の clear_selected_outputs と対に、
## リストの × ボタンから1本ずつ外すための API。push_undo＋Sim.reset_sim（構造変更）。
func remove_output(index: int) -> void:
	if selected == null:
		return
	if index < 0 or index >= selected.outputs.size():
		return
	push_undo()
	var t = selected.outputs[index]
	selected.outputs.remove_at(index)
	if t != null and is_instance_valid(t):
		t.inputs.erase(selected)   # 逆向き参照（inputs）も1件だけ解除（重複エッジは張れない）
	var tname: String = (t.obj_name if (t != null and is_instance_valid(t)) else "?")
	Scripts.log_msg("✂ 接続解除: %s → %s [port %d]" % [selected.obj_name, tname, index])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 出力エッジの並び順（＝ポート番号）を入れ替える。ポート番号は outputs 配列の添字で、
## スクリプトの select_output が参照する送出優先順。ユーザーがこの順を制御できる。
## from==to や範囲外への実質no-opでは push_undo しない（空の Undo を作らない）。
func reorder_output(from_index: int, to_index: int) -> void:
	if selected == null:
		return
	var n: int = selected.outputs.size()
	if from_index < 0 or from_index >= n:
		return
	to_index = clampi(to_index, 0, n - 1)
	if from_index == to_index:
		return
	push_undo()
	var t = selected.outputs[from_index]
	selected.outputs.remove_at(from_index)
	selected.outputs.insert(to_index, t)
	Scripts.log_msg("↕ ポート順変更: %s [%d → %d]" % [selected.obj_name, from_index, to_index])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## ポート index を1つ上へ（番号を1つ小さく）。境界では reorder_output 側で no-op。
func move_output_up(index: int) -> void:
	reorder_output(index, index - 1)

## ポート index を1つ下へ（番号を1つ大きく）。境界では reorder_output 側で no-op。
func move_output_down(index: int) -> void:
	reorder_output(index, index + 1)

func clear_selected_outputs() -> void:
	if selected == null:
		return
	push_undo()
	selected.disconnect_all()
	Scripts.log_msg("接続クリア: %s" % selected.obj_name)
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func assign_model_to_selected(path: String) -> void:
	if selected == null:
		return
	push_undo()
	var ok := selected.apply_model(path)
	Scripts.log_msg(("🧩 モデル割当: %s" % path) if ok else ("⚠ モデル割当失敗: %s" % path))

func apply_script_to_selected(src: String) -> Dictionary:
	if selected == null:
		return {"ok": false, "error": "no selection"}
	push_undo()
	return selected.set_logic(src)

func apply_params(d: Dictionary) -> void:
	if selected == null:
		return
	push_undo()
	selected.set_params(d)
	# パラメータ変更（mtbf_basis / transport_out / process_time 等）は
	# calendar 初回故障(on_sim_start)の再仕込みを要する → add/delete/connect と同様に
	# reset_sim でイベントカレンダーを作り直す（変更が確実に発火する）。
	Sim.reset_sim()
	emit_signal("model_rebuilt")

# ---------------------------------------------------------------
# モデル全体の保存/読込/再構築
# ---------------------------------------------------------------
func current_dict() -> Dictionary:
	return io.to_dict(ctx)

func save_model(path: String) -> void:
	io.save_json(path, io.to_dict(ctx))

func load_model(path: String, allow_scripts: bool = true) -> void:
	var m := io.load_json(path)
	if m.is_empty():
		Scripts.log_msg("⚠ 読込失敗または空: %s" % path)
		return
	rebuild(m, allow_scripts)
	Scripts.log_msg("📂 モデルを読込: %s%s" % [path, ("" if allow_scripts else "（スクリプトは無効化）")])

# ---------------------------------------------------------------
# 資源ユニット（作業者/搬送者）の配置ヘルパー
# ---------------------------------------------------------------
## 既存ユニットと重ならない配置セルを小グリッド探索で求める（連続追加が積み重ならない）。
## anchor から snap 格子（列 cols）で順に走査し、既存 position と近接しない最初のセルを返す。
## これにより固定座標へ N 個スタックしていた不具合を解消し、追加毎に別位置へ広がる。
func _free_unit_pos(anchor: Vector3, existing: Array) -> Vector3:
	var step: float = max(snap_size, 2.0)
	var cols: int = 5
	for i in range(256):
		var col: int = i % cols
		var row: int = i / cols
		var cand := snap_vec(anchor + Vector3(float(col) * step, 0, float(row) * step))
		var occupied := false
		for u in existing:
			if is_instance_valid(u) and u.position.distance_to(cand) < 0.5:
				occupied = true
				break
		if not occupied:
			return cand
	return snap_vec(anchor)

## ユニットの安定な一意 id を採番する（prefix_N。既存 id と衝突しない最小 N）。
func _new_unit_id(prefix: String, existing: Array) -> String:
	var used := {}
	for u in existing:
		if is_instance_valid(u):
			used[str(u.id)] = true
	var n: int = 1
	while used.has("%s_%d" % [prefix, n]):
		n += 1
	return "%s_%d" % [prefix, n]

# 作業者の追加/削除
func add_operator() -> void:
	if ctx.get("pool", null) == null:
		return
	push_undo()
	var op := Operator.new()
	model_root.add_child(op)
	var nm: String = "Op%d" % (ctx.operators.size() + 1)
	# 固定座標へのスタックを廃し、既存作業者と重ならない空きセルへ配置する。
	var pos: Vector3 = _free_unit_pos(Vector3(-6, 0, 9), ctx.get("operators", []))
	op.setup(nm, pos)
	op.id = _new_unit_id("op", ctx.get("operators", []))
	ctx.pool.add_operator(op)
	ctx.operators.append(op)
	select_unit(op)
	Scripts.log_msg("＋ 作業者追加: %s (%s)" % [op.op_name, op.id])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func remove_operator() -> void:
	# 作業者が選択中なら「その」作業者を消す（末尾除去ではなく選択対象）。
	# 例: Op1 を選んで「−」→ Op3 ではなく Op1 が消える。
	if selected_unit is Operator:
		delete_selected_unit()
		return
	if ctx.operators.size() <= 0:
		return
	push_undo()
	var op = ctx.operators.pop_back()
	if selected_unit == op:
		select(null)   # 選択中を消す前に選択解除（dangling 参照防止）
	ctx.pool.operators.erase(op)
	Sim.unregister(op)
	op.queue_free()
	Scripts.log_msg("－ 作業者削除")
	Sim.reset_sim()
	emit_signal("model_rebuilt")

# 搬送者の追加/削除（add_operator/remove_operator を踏襲）
func add_transporter() -> void:
	if ctx.get("transport_pool", null) == null:
		return
	push_undo()
	var tr := Transporter.new()
	model_root.add_child(tr)
	var nm: String = "T%d" % (ctx.get("transporters", []).size() + 1)
	# 固定座標へのスタックを廃し、既存搬送者と重ならない空きセルへ配置する。
	var pos: Vector3 = _free_unit_pos(Vector3(6, 0, 9), ctx.get("transporters", []))
	tr.setup(nm, pos)
	tr.id = _new_unit_id("t", ctx.get("transporters", []))
	ctx.transport_pool.add_transporter(tr)
	ctx.transporters.append(tr)
	select_unit(tr)
	Scripts.log_msg("＋ 搬送者追加: %s (%s)" % [tr.t_name, tr.id])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func remove_transporter() -> void:
	# 搬送者が選択中なら「その」搬送者を消す（末尾除去ではなく選択対象）。
	if selected_unit is Transporter:
		delete_selected_unit()
		return
	if ctx.get("transporters", []).size() <= 0:
		return
	push_undo()
	var tr = ctx.transporters.pop_back()
	if selected_unit == tr:
		select(null)   # 選択中を消す前に選択解除（dangling 参照防止）
	if ctx.get("transport_pool", null) != null:
		ctx.transport_pool.transporters.erase(tr)
	Sim.unregister(tr)
	tr.queue_free()
	Scripts.log_msg("－ 搬送者削除")
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 選択中のユニット（作業者/搬送者）そのものを削除する（末尾除去ではなく選択対象）。
## Delete/Backspace キーとユニット文脈メニューの「削除」、および選択中の「−」から呼ばれる。
## push_undo（削除前の状態）＋ 構造変更として Sim.reset_sim ＋ model_rebuilt。
func delete_selected_unit() -> void:
	var u = selected_unit
	if u == null or not is_instance_valid(u):
		return
	push_undo()
	select(null)   # 消す前に選択解除（dangling 参照防止）
	if u is Operator:
		ctx.operators.erase(u)
		if ctx.get("pool", null) != null:
			ctx.pool.operators.erase(u)
		Scripts.log_msg("－ 作業者削除: %s" % u.op_name)
	elif u is Transporter:
		if ctx.has("transporters"):
			ctx.transporters.erase(u)
		if ctx.get("transport_pool", null) != null:
			ctx.transport_pool.transporters.erase(u)
		Scripts.log_msg("－ 搬送者削除: %s" % u.t_name)
	Sim.unregister(u)
	u.queue_free()
	Sim.reset_sim()   # 構造変更 → イベント/アイテムをクリアして再構築
	emit_signal("model_rebuilt")

## 選択中のユニット（作業者/搬送者）を複製する。per-unit パラメータと「〜のコピー」名を
## 引き継ぎ、原本と重ならない空きセルへ置いて複製を選択する。push_undo ＋ Sim.reset_sim ＋
## model_rebuilt。Ctrl+D（ユニット選択時）とユニット文脈メニューの「複製」から呼ばれる。
func duplicate_selected_unit():
	var src = selected_unit
	if src == null or not is_instance_valid(src):
		return null
	push_undo()
	if src is Operator:
		var op := Operator.new()
		model_root.add_child(op)   # _ready で見た目/ピッカーを構築
		# 原本位置を起点に、既存作業者と重ならない空きセルへ（スタックしない）。
		var opos: Vector3 = _free_unit_pos(src.position, ctx.get("operators", []))
		op.setup("%s のコピー" % src.op_name, opos)
		op.id = _new_unit_id("op", ctx.get("operators", []))
		# per-unit パラメータをコピー（速度／シフト／モデル）。
		op.move_speed = src.move_speed
		op.shift = src.shift.duplicate(true)
		op.shift_period = src.shift_period
		if src.model_path != "":
			op.apply_model(src.model_path)
		if ctx.get("pool", null) != null:
			ctx.pool.add_operator(op)
		ctx.operators.append(op)
		select_unit(op)
		Scripts.log_msg("⧉ 複製: %s → %s (%s)" % [src.op_name, op.op_name, op.id])
		Sim.reset_sim()
		emit_signal("model_rebuilt")
		return op
	elif src is Transporter:
		var tr := Transporter.new()
		model_root.add_child(tr)
		var tpos: Vector3 = _free_unit_pos(src.position, ctx.get("transporters", []))
		tr.setup("%s のコピー" % src.t_name, tpos)
		tr.id = _new_unit_id("t", ctx.get("transporters", []))
		# per-unit パラメータをコピー（速度／容量／積載／投下／経由点／優先度／モデル）。
		tr.move_speed = src.move_speed
		tr.capacity = src.capacity
		tr.load_time = src.load_time
		tr.unload_time = src.unload_time
		tr.waypoints = src.waypoints.duplicate(true)
		tr.priority = src.priority
		if src.model_path != "":
			tr.apply_model(src.model_path)
		if ctx.get("transport_pool", null) != null:
			ctx.transport_pool.add_transporter(tr)
		if not ctx.has("transporters"):
			ctx.transporters = []
		ctx.transporters.append(tr)
		select_unit(tr)
		Scripts.log_msg("⧉ 複製: %s → %s (%s)" % [src.t_name, tr.t_name, tr.id])
		Sim.reset_sim()
		emit_signal("model_rebuilt")
		return tr
	return null

## 全作業者に共通シフトを設定（最小の一括編集）。period<=0 で常時稼働へ戻す。
func set_operator_shift(on_t: float, off_t: float, period: float) -> void:
	push_undo()
	for op in ctx.get("operators", []):
		if period <= 0.0:
			op.shift = []
			op.shift_period = 0.0
		else:
			op.shift = [{"on": on_t, "off": off_t}]
			op.shift_period = period
	Scripts.log_msg("🕑 全作業者シフト: on=%.0f off=%.0f period=%.0f" % [on_t, off_t, period])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 選択中のユニット（作業者/搬送者）の移動速度を設定。undo記録込み。速度は travel_time に
## 効くので、変更を確実に反映するよう reset_sim + model_rebuilt で再構成する
## （既存の資源パラメータ編集 set_operator_shift と同じ流儀）。過小値は安全側へクランプ。
func set_unit_speed(v: float) -> void:
	var a = _active()
	if a == null or not (a is Operator or a is Transporter):
		return
	push_undo()
	a.move_speed = max(0.01, v)
	Scripts.log_msg("⚙ %s 速度: %.2f" % [a.obj_name, a.move_speed])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 選択中の作業者1名のシフトを設定（period<=0 で常時稼働へ戻す）。undo記録込み。
## 全作業者一括の set_operator_shift とは別に、per-unit で個別設定できる窓口。
func set_selected_operator_shift(on_t: float, off_t: float, period: float) -> void:
	var a = _active()
	if not (a is Operator):
		return
	push_undo()
	if period <= 0.0:
		a.shift = []
		a.shift_period = 0.0
	else:
		a.shift = [{"on": on_t, "off": off_t}]
		a.shift_period = period
	Scripts.log_msg("🕑 %s シフト: on=%.0f off=%.0f period=%.0f" % [a.obj_name, on_t, off_t, period])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 選択中の搬送者の運搬パラメータ（容量/積載時間/投下時間/優先度）を一括設定。undo記録込み。
## 1回の適用で undo は1件（4項目まとめて）。容量<1・時間<0 は安全側へクランプする。
func set_transporter_params(cap: int, load_t: float, unload_t: float, prio: int) -> void:
	var a = _active()
	if not (a is Transporter):
		return
	push_undo()
	a.capacity = max(1, cap)
	a.load_time = max(0.0, load_t)
	a.unload_time = max(0.0, unload_t)
	a.priority = prio
	Scripts.log_msg("⚙ %s: cap=%d load=%.2f unload=%.2f prio=%d" % [
		a.obj_name, a.capacity, a.load_time, a.unload_time, a.priority])
	Sim.reset_sim()
	emit_signal("model_rebuilt")

## 資源ディスパッチ規則を全プールへ設定（"fifo"=既定 / "nearest"）。
func set_dispatch_rule(rule: String) -> void:
	push_undo()   # 変更前の規則をスナップショット（Undo で復元可能に）
	if ctx.get("pool", null) != null and ctx.pool.has_method("set_dispatch_rule"):
		ctx.pool.set_dispatch_rule(rule)
	if ctx.get("transport_pool", null) != null and ctx.transport_pool.has_method("set_dispatch_rule"):
		ctx.transport_pool.set_dispatch_rule(rule)
	Scripts.log_msg("⚙ ディスパッチ規則: %s" % rule)
	Sim.reset_sim()
	emit_signal("model_rebuilt")

func rebuild(model: Dictionary, allow_scripts: bool = true) -> void:
	# 選択を rebuild 後も維持してユーザーの見失いを防ぐ（Undo/Redo で特に重要）。
	# 破棄前に選択の id と種別を控え、再構築後に同 id がまだ存在すれば決定論的に選び直す。
	# （id は to_dict/build で往復保存されるため一意に引き当てられる。無ければ選択なしのまま。）
	var _sel_id: String = ""
	var _sel_kind: String = ""
	var _sa = _active()
	if _sa != null and is_instance_valid(_sa):
		if _sa is Operator:
			_sel_id = str(_sa.id); _sel_kind = "operator"
		elif _sa is Transporter:
			_sel_id = str(_sa.id); _sel_kind = "transporter"
		elif _sa is FlowObject:
			_sel_id = str(_sa.id); _sel_kind = "flow"
	select(null)
	# rebuild は全 flow_objects を破棄するため、配線元(_wire_from)が dangling 参照になる。
	# Undo/Redo/読込のいずれでも配線を中断してプレビュー線を消す（次入力でのクラッシュ防止）。
	_cancel_wiring()
	# 既存を破棄
	for o in ctx.get("flow_objects", []):
		Sim.unregister(o)
		o.queue_free()
	for op in ctx.get("operators", []):
		Sim.unregister(op)
		op.queue_free()
	for tr in ctx.get("transporters", []):
		Sim.unregister(tr)
		tr.queue_free()
	if ctx.get("pool", null) != null:
		ctx.pool.queue_free()
	if ctx.get("pool", null) != null:
		Sim.unregister(ctx.pool)
	if ctx.get("transport_pool", null) != null:
		Sim.unregister(ctx.transport_pool)
		ctx.transport_pool.queue_free()
	Sim.running = false
	# 再構築
	ctx = io.build(model, model_root, allow_scripts)
	Sim.reset_sim()   # イベント/アイテムをクリアして初期イベントを仕込む
	# 破棄前の選択を id で復元（存在する場合のみ）。model_rebuilt より前に選び直すことで
	# UI._on_model_rebuilt が復元済み選択を拾ってインスペクタを再表示する（見失い防止）。
	_reselect_by_id(_sel_id, _sel_kind)
	emit_signal("model_rebuilt")

## rebuild 前に控えた選択(id, 種別)を再構築後のモデルから引き当てて選び直す。
## 同 id が新モデルに無い（別モデルの読込など）ときは何もしない＝選択なしのまま（決定論）。
func _reselect_by_id(sel_id: String, sel_kind: String) -> void:
	if sel_id == "":
		return
	if sel_kind == "flow":
		var o = ctx.get("registry", {}).get(sel_id, null)
		if o != null and is_instance_valid(o):
			select(o)
	elif sel_kind == "operator":
		for u in ctx.get("operators", []):
			if is_instance_valid(u) and str(u.id) == sel_id:
				select_unit(u)
				return
	elif sel_kind == "transporter":
		for u in ctx.get("transporters", []):
			if is_instance_valid(u) and str(u.id) == sel_id:
				select_unit(u)
				return
