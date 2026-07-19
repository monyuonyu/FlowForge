extends Node3D
class_name ConnectionViz
## 接続（ルーティング）を矢印で3D表示。設備を動かすと追従する。
## 各矢印の始点側にポート番号（outputs 配列の添字＝ select_output の送出順）を
## Label3D で併記し、インスペクタの出力リストと論理ポート順が視覚的に一致する。

var editor
var _mi: MeshInstance3D
var _im: ImmediateMesh
# ポート番号ラベル(Label3D)のプール。エッジ本数に応じて増やし、余りは隠して再利用する
# （毎フレームの生成/破棄を避けて GC 負荷と点滅を防ぐ）。
var _labels: Array = []

const COL := Color(0.45, 0.85, 0.6, 0.9)
const COL_LABEL := Color(0.62, 0.96, 0.76)   # ポート番号（矢印と同系の明るい緑）

func _ready() -> void:
	_mi = MeshInstance3D.new()
	_im = ImmediateMesh.new()
	_mi.mesh = _im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mi.material_override = mat
	add_child(_mi)

func setup(ed) -> void:
	editor = ed

func _process(_delta: float) -> void:
	if editor == null:
		return
	_im.clear_surfaces()
	var objs: Array = editor.ctx.get("flow_objects", [])
	var total_conn: int = 0
	for o in objs:
		if is_instance_valid(o):
			total_conn += o.outputs.size()
	var used: int = 0
	if total_conn > 0:
		_im.surface_begin(Mesh.PRIMITIVE_LINES)
		for o in objs:
			if not is_instance_valid(o):
				continue
			# ポート番号＝ outputs 配列の添字。select_output はこの番号で送出先を選ぶため、
			# 添字をそのままラベルにすると論理ポート順と一致する。
			for idx in range(o.outputs.size()):
				var t = o.outputs[idx]
				if not is_instance_valid(t):
					continue
				var a: Vector3 = o.global_position + Vector3(0, 1.0, 0)
				var b: Vector3 = t.global_position + Vector3(0, 1.0, 0)
				_arrow(a, b)
				_place_port_label(used, idx, a, b)
				used += 1
		_im.surface_end()
	# 使わなかったラベルは隠す（プールは保持して次フレームで再利用）。
	for i in range(used, _labels.size()):
		_labels[i].visible = false

## slot 番目のラベルを再利用（無ければ生成）し、始点 a 寄りにポート番号を置く。
func _place_port_label(slot: int, port: int, a: Vector3, b: Vector3) -> void:
	var lbl: Label3D = _get_label(slot)
	lbl.text = str(port)
	var dir: Vector3 = b - a
	var pos: Vector3 = a
	if dir.length() > 0.01:
		pos = a + dir.normalized() * 1.4   # 始点からわずかに矢印方向へ寄せる
	pos.y += 0.3
	lbl.position = pos   # ConnectionViz は原点なので local==global
	lbl.visible = true

func _get_label(slot: int) -> Label3D:
	while slot >= _labels.size():
		var l := Label3D.new()
		l.font_size = 22
		l.outline_size = 6
		l.modulate = COL_LABEL
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.pixel_size = 0.0012
		l.no_depth_test = true
		add_child(l)
		_labels.append(l)
	return _labels[slot]

func _arrow(a: Vector3, b: Vector3) -> void:
	_line(a, b)
	var dir: Vector3 = (b - a)
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var up := Vector3.UP
	var side: Vector3 = dir.cross(up).normalized()
	if side.length() < 0.01:
		side = Vector3.RIGHT
	var tip: Vector3 = b - dir * 0.2
	var head: float = 0.35
	_line(b, tip + side * head)
	_line(b, tip - side * head)

func _line(a: Vector3, b: Vector3) -> void:
	_im.surface_set_color(COL)
	_im.surface_add_vertex(a)
	_im.surface_set_color(COL)
	_im.surface_add_vertex(b)
