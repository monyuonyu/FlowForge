extends Node3D
class_name MeasureViz
## メジャーツールの表示。点列（ポリライン）を線で結び、各線分の距離と合計をラベル表示。

var lines: Array = []       # 確定した polyline（Array[Vector3]）の配列
var _current: Array = []    # 作成中の polyline

var _mi: MeshInstance3D
var _im: ImmediateMesh
var _labels_root: Node3D
var _markers_root: Node3D

const LINE_COLOR := Color(1.0, 0.82, 0.25)
const CUR_COLOR := Color(1.0, 0.55, 0.25)

func _ready() -> void:
	_mi = MeshInstance3D.new()
	_im = ImmediateMesh.new()
	_mi.mesh = _im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	_mi.material_override = mat
	add_child(_mi)
	_labels_root = Node3D.new(); add_child(_labels_root)
	_markers_root = Node3D.new(); add_child(_markers_root)

func add_point(p: Vector3) -> void:
	_current.append(p)
	_rebuild()

func finish_line() -> void:
	if _current.size() >= 2:
		lines.append(_current.duplicate())
	_current = []
	_rebuild()

func undo_point() -> void:
	if _current.size() > 0:
		_current.pop_back()
		_rebuild()

func clear() -> void:
	lines.clear()
	_current = []
	_rebuild()

func has_points() -> bool:
	return _current.size() > 0 or lines.size() > 0

func _rebuild() -> void:
	for c in _labels_root.get_children():
		c.queue_free()
	for c in _markers_root.get_children():
		c.queue_free()
	_im.clear_surfaces()
	# 線分が1本以上ある時だけサーフェスを作る（空だとエラーになる）
	var segs := 0
	for poly in lines:
		segs += max(0, poly.size() - 1)
	segs += max(0, _current.size() - 1)
	if segs > 0:
		_im.surface_begin(Mesh.PRIMITIVE_LINES)
		for poly in lines:
			_emit_poly(poly, LINE_COLOR)
		_emit_poly(_current, CUR_COLOR)
		_im.surface_end()

	for poly in lines:
		_label_poly(poly, LINE_COLOR)
	_label_poly(_current, CUR_COLOR)

func _emit_poly(poly: Array, col: Color) -> void:
	var y := 0.08
	for i in range(poly.size() - 1):
		var a: Vector3 = poly[i] + Vector3(0, y, 0)
		var b: Vector3 = poly[i + 1] + Vector3(0, y, 0)
		_im.surface_set_color(col)
		_im.surface_add_vertex(a)
		_im.surface_set_color(col)
		_im.surface_add_vertex(b)

func _label_poly(poly: Array, col: Color) -> void:
	# 点マーカー
	for p in poly:
		_add_marker(p, col)
	# 線分距離
	var total := 0.0
	for i in range(poly.size() - 1):
		var a: Vector3 = poly[i]
		var b: Vector3 = poly[i + 1]
		var seg: float = a.distance_to(b)
		total += seg
		var mid: Vector3 = (a + b) * 0.5 + Vector3(0, 0.3, 0)
		_add_label("%.2f m" % seg, mid, Color(1, 0.9, 0.5))
	# 合計（2点以上）
	if poly.size() >= 3:
		var endp: Vector3 = poly[poly.size() - 1] + Vector3(0, 0.7, 0)
		_add_label("合計 %.2f m" % total, endp, Color(0.6, 1.0, 0.7))

func _add_label(text: String, pos: Vector3, color: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font_size = 34
	l.outline_size = 8
	l.modulate = color
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = true
	l.pixel_size = 0.0018
	_labels_root.add_child(l)

func _add_marker(p: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.12
	s.height = 0.24
	mi.mesh = s
	mi.position = p + Vector3(0, 0.08, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.no_depth_test = true
	mi.material_override = mat
	_markers_root.add_child(mi)
