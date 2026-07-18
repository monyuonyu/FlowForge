extends Node3D
class_name GridRuler
## 縮尺つき適応グリッド＆定規。
## カメラのズームに応じて目盛り間隔（minor/major）を切替え、主要線に座標値ラベルを表示する。
## 1 ワールド単位 = 1 m として扱う。

var cam: CameraRig

var _mi: MeshInstance3D
var _im: ImmediateMesh
var _labels_root: Node3D
var _last_key: String = ""
var minor: float = 1.0   # 現在の最小目盛り（m）

const AXIS_X_COLOR := Color(0.85, 0.35, 0.35, 0.9)
const AXIS_Z_COLOR := Color(0.40, 0.55, 0.95, 0.9)
const MAJOR_COLOR := Color(0.45, 0.48, 0.56, 0.75)
const MINOR_COLOR := Color(0.28, 0.30, 0.36, 0.45)

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
	_labels_root = Node3D.new()
	add_child(_labels_root)

func _process(_dt: float) -> void:
	if cam == null:
		return
	var d: float = cam.get_distance()
	var c: Vector3 = cam.focus()
	minor = _minor_for(d)
	var major: float = minor * 5.0
	var cellx: int = int(round(c.x / major))
	var cellz: int = int(round(c.z / major))
	var key: String = "%f:%d:%d" % [minor, cellx, cellz]
	if key != _last_key:
		_last_key = key
		_rebuild(Vector3(cellx * major, 0, cellz * major), minor, d)

func _minor_for(d: float) -> float:
	if d < 12.0: return 0.5
	elif d < 30.0: return 1.0
	elif d < 70.0: return 5.0
	else: return 10.0

func _rebuild(center: Vector3, m: float, d: float) -> void:
	var major: float = m * 5.0
	var radius: float = clamp(d * 1.8, 30.0, 300.0)
	var x0: float = floor((center.x - radius) / m) * m
	var x1: float = ceil((center.x + radius) / m) * m
	var z0: float = floor((center.z - radius) / m) * m
	var z1: float = ceil((center.z + radius) / m) * m
	var y: float = 0.03

	_im.clear_surfaces()
	_im.surface_begin(Mesh.PRIMITIVE_LINES)

	var x: float = x0
	while x <= x1 + 0.001:
		var col: Color = _line_color(x, major)
		_im.surface_set_color(col)
		_im.surface_add_vertex(Vector3(x, y, z0))
		_im.surface_set_color(col)
		_im.surface_add_vertex(Vector3(x, y, z1))
		x += m
	var z: float = z0
	while z <= z1 + 0.001:
		var col2: Color = _line_color(z, major)
		_im.surface_set_color(col2)
		_im.surface_add_vertex(Vector3(x0, y, z))
		_im.surface_set_color(col2)
		_im.surface_add_vertex(Vector3(x1, y, z))
		z += m
	_im.surface_end()

	_rebuild_labels(center, major, radius)

func _line_color(v: float, major: float) -> Color:
	if abs(v) < 0.001:
		return AXIS_X_COLOR
	if abs(fmod(v, major)) < 0.001 or abs(abs(fmod(v, major)) - major) < 0.001:
		return MAJOR_COLOR
	return MINOR_COLOR

func _rebuild_labels(center: Vector3, major: float, radius: float) -> void:
	for c in _labels_root.get_children():
		c.queue_free()
	# ラベル数を抑えるためのステップ
	var step: float = major
	while (2.0 * radius) / step > 26.0:
		step *= 2.0
	var lx0: float = floor((center.x - radius) / step) * step
	var lx1: float = center.x + radius
	var lz0: float = floor((center.z - radius) / step) * step
	var lz1: float = center.z + radius
	var x: float = lx0
	while x <= lx1:
		_add_label("%s" % _fmt(x), Vector3(x, 0.06, center.z))
		x += step
	var z: float = lz0
	while z <= lz1:
		if abs(z - center.z) > 0.001:   # 原点付近の二重表示を避ける
			_add_label("%s" % _fmt(z), Vector3(center.x, 0.06, z))
		z += step

func _fmt(v: float) -> String:
	if abs(v - round(v)) < 0.001:
		return "%d" % int(round(v))
	return "%.1f" % v

func _add_label(text: String, pos: Vector3) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.pixel_size = 0.008
	l.modulate = Color(0.75, 0.8, 0.9)
	l.font_size = 28
	l.outline_size = 6
	l.rotation_degrees = Vector3(-90, 0, 0)   # 地面に寝かせる
	l.no_depth_test = false
	_labels_root.add_child(l)
