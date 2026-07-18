extends Node
## 外部3Dファイルの実行時ローダ（autoload "Assets"）。
## 対応: .glb / .gltf（マテリアル込み） と .obj（頂点/面, 簡易パーサ）。
## 読み込んだモデルはキャッシュし、複製(duplicate)して各設備へ渡す。

var _cache: Dictionary = {}   # path -> プロトタイプ Node3D（オーファン）

## パスからモデルの複製を返す。失敗時 null。
func load_model(path: String) -> Node3D:
	if path == "":
		return null
	var proto: Node3D = _cache.get(path, null)
	if proto == null:
		proto = _load_uncached(path)
		if proto != null:
			_cache[path] = proto
	if proto == null:
		return null
	return proto.duplicate()

func clear_cache() -> void:
	for k in _cache:
		var n = _cache[k]
		if is_instance_valid(n):
			n.queue_free()
	_cache.clear()

func _load_uncached(path: String) -> Node3D:
	var ext: String = path.get_extension().to_lower()
	match ext:
		"glb", "gltf":
			return _load_gltf(path)
		"obj":
			return _load_obj(path)
		_:
			push_error("未対応の3D形式: %s" % ext)
			return null

# ---------------------------------------------------------------
func _load_gltf(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err: int = doc.append_from_file(path, state)
	if err != OK:
		push_error("glTF読込失敗: %s (err=%d)" % [path, err])
		return null
	var scene: Node = doc.generate_scene(state)
	if scene == null:
		return null
	var root := Node3D.new()
	root.name = "Model"
	root.add_child(scene)
	return root

# ---------------------------------------------------------------
# 最小限の OBJ パーサ（v / vn / f）。マテリアルは無地グレー。
func _load_obj(path: String) -> Node3D:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("OBJを開けません: %s" % path)
		return null
	var positions: Array = []   # Vector3
	var normals: Array = []     # Vector3
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var have_normals := false

	while not f.eof_reached():
		var line: String = f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var parts: PackedStringArray = line.split(" ", false)
		if parts.size() == 0:
			continue
		match parts[0]:
			"v":
				if parts.size() >= 4:
					positions.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
			"vn":
				if parts.size() >= 4:
					normals.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
			"f":
				var idx: Array = []
				for i in range(1, parts.size()):
					idx.append(parts[i])
				# 多角形は三角形ファンに分割
				for t in range(1, idx.size() - 1):
					_obj_tri(st, positions, normals, idx[0])
					_obj_tri(st, positions, normals, idx[t])
					_obj_tri(st, positions, normals, idx[t + 1])
					have_normals = have_normals or normals.size() > 0
	f.close()

	if positions.is_empty():
		push_error("OBJに頂点がありません: %s" % path)
		return null
	if not have_normals:
		st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.72, 0.76)
	mat.roughness = 0.7
	st.set_material(mat)
	var mesh: ArrayMesh = st.commit()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var root := Node3D.new()
	root.name = "Model"
	root.add_child(mi)
	return root

func _obj_tri(st: SurfaceTool, positions: Array, normals: Array, token: String) -> void:
	# token: "v", "v/vt", "v//vn", "v/vt/vn"（1始まり、負数=末尾相対）
	var comps: PackedStringArray = token.split("/")
	var vi: int = int(comps[0])
	if vi < 0:
		vi = positions.size() + vi
	else:
		vi -= 1
	if comps.size() >= 3 and comps[2] != "":
		var ni: int = int(comps[2])
		if ni < 0:
			ni = normals.size() + ni
		else:
			ni -= 1
		if ni >= 0 and ni < normals.size():
			st.set_normal(normals[ni])
	if vi >= 0 and vi < positions.size():
		st.add_vertex(positions[vi])
