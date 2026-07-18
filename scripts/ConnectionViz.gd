extends Node3D
class_name ConnectionViz
## 接続（ルーティング）を矢印で3D表示。設備を動かすと追従する。

var editor
var _mi: MeshInstance3D
var _im: ImmediateMesh

const COL := Color(0.45, 0.85, 0.6, 0.9)

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
	if total_conn == 0:
		return
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	for o in objs:
		if not is_instance_valid(o):
			continue
		for t in o.outputs:
			if not is_instance_valid(t):
				continue
			_arrow(o.global_position + Vector3(0, 1.0, 0), t.global_position + Vector3(0, 1.0, 0))
	_im.surface_end()

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
