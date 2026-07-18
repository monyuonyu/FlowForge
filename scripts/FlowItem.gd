extends RefCounted
class_name FlowItem
## 流れるアイテム。純データ本体(RefCounted)＋任意の視覚ノード _visual(Node3D)。
## ロジックはイベント駆動。実験時(visuals_enabled=false)は _visual を作らず Node を
## 一切生成しない（純データ化）。real-time(visuals_enabled=true)は従来同等の見た目で、
## _visual を Sim.items_root に add_child し、目標位置へ補間する。

var item_type: int = 0
var created_time: float = 0.0
var id: int = 0
var data: Dictionary = {}
var enqueue_time: float = 0.0   # Queue が待ち時間集計に使う専用フィールド（data 辞書を汚さない）
var _visual: FlowItemVisual = null

## 任意の視覚ノード。目標位置へ move_toward で補間（描画とロジックを分離）。
## visuals_enabled=true のときのみ生成され、items_root に属する。
class FlowItemVisual extends Node3D:
	var _mat: StandardMaterial3D
	var _target = null
	func _process(delta: float) -> void:
		if _target != null:
			global_position = global_position.move_toward(_target, delta * 10.0)
			if global_position.distance_to(_target) < 0.02:
				_target = null

func setup(type_index: int, color: Color, make_visual: bool = true, sz: Vector3 = Vector3(0.5, 0.5, 0.5)) -> void:
	item_type = type_index
	if not make_visual:
		return   # 純データ本体のみ。Node は一切生成しない。
	_visual = FlowItemVisual.new()
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = sz
	mesh.mesh = box
	_visual._mat = StandardMaterial3D.new()
	_visual._mat.albedo_color = color
	_visual._mat.metallic = 0.1
	_visual._mat.roughness = 0.5
	mesh.material_override = _visual._mat
	_visual.add_child(mesh)
	if Sim.items_root != null:
		Sim.items_root.add_child(_visual)

func set_color(c: Color) -> void:
	if _visual != null and _visual._mat != null:
		_visual._mat.albedo_color = c

func set_label(key: String, value) -> void:
	data[key] = value

func get_label(key: String, default_value = null):
	return data.get(key, default_value)

func has_label(key: String) -> bool:
	return data.has(key)

func age() -> float:
	return Sim.sim_time - created_time

func move_to(target_pos: Vector3, _dur: float = 0.2) -> void:
	if _visual != null:
		_visual._target = target_pos

func set_pos_now(p: Vector3) -> void:
	if _visual != null:
		_visual.global_position = p
		_visual._target = null

## 破棄。_visual があれば queue_free、本体は参照喪失で解放される。queue_free の代替。
func dispose() -> void:
	if _visual != null and is_instance_valid(_visual):
		_visual.queue_free()
	_visual = null
