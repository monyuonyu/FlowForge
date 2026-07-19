extends Camera3D
class_name CameraRig
## 軌道カメラ（CAD向け）。
##   右ドラッグ=回転 / 中ドラッグ=移動 / ホイール=ズーム
##   正射投影(ortho)切替、Top/Front/Iso ビュープリセット、スケール算出。

var distance: float = 26.0
var yaw: float = -0.7
var pitch: float = 0.85
var target: Vector3 = Vector3(-1, 0, 0)
var ortho: bool = false

var _orbiting: bool = false
var _panning: bool = false

func _ready() -> void:
	current = true
	fov = 55.0
	_update()

func _update() -> void:
	var dir := Vector3(
		cos(pitch) * sin(yaw),
		sin(pitch),
		cos(pitch) * cos(yaw)
	)
	global_position = target + dir * distance
	look_at(target, Vector3.UP)
	if ortho:
		projection = PROJECTION_ORTHOGONAL
		size = max(1.0, distance * 0.9)   # ズーム＝表示範囲
	else:
		projection = PROJECTION_PERSPECTIVE

func set_ortho(on: bool) -> void:
	ortho = on
	_update()

func toggle_ortho() -> void:
	set_ortho(not ortho)

## ビュープリセット
func preset(view: String) -> void:
	match view:
		"top":
			yaw = 0.0
			pitch = 1.5607   # ほぼ真上（90°弱）
		"front":
			yaw = 0.0
			pitch = 0.02
		"side":
			yaw = 1.5707
			pitch = 0.02
		"iso":
			yaw = -0.785
			pitch = 0.62
	_update()

func focus() -> Vector3:
	return target

## 指定点へ注視点(pivot)を移す（選択へフォーカス）。radius>0 のとき対象が収まる距離へ
## ズームする。純粋なビュー操作でシミュレーションや直列化には一切触れない（決定論不変）。
func focus_on(point: Vector3, radius: float = 0.0) -> void:
	target = point
	if radius > 0.0:
		var half: float = deg_to_rad(max(1.0, fov)) * 0.5
		var d: float = radius / max(0.05, tan(half))
		distance = clamp(d + radius, 3.0, 140.0)
	_update()

## 全体(AABB)を画面に収める。中心へ寄せ、全体が入る距離へズームする（Home/Fit-all）。
func frame_aabb(aabb: AABB) -> void:
	var r: float = aabb.size.length() * 0.5
	focus_on(aabb.position + aabb.size * 0.5, max(2.0, r))

func get_distance() -> float:
	return distance

## 目安スケール：ワールド1mが画面上で何ピクセルか（注視点付近で算出）
func pixels_per_meter() -> float:
	var a := unproject_position(target)
	var b := unproject_position(target + Vector3(1, 0, 0))
	var d := a.distance_to(b)
	if d <= 0.0001:
		# X方向が視線と平行な場合はZで代替
		b = unproject_position(target + Vector3(0, 0, 1))
		d = a.distance_to(b)
	return d

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				distance = clamp(distance - 1.5, 3.0, 140.0)
				_update()
			MOUSE_BUTTON_WHEEL_DOWN:
				distance = clamp(distance + 1.5, 3.0, 140.0)
				_update()
			MOUSE_BUTTON_RIGHT:
				_orbiting = event.pressed
			MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed
	elif event is InputEventMouseMotion:
		if _orbiting:
			yaw -= event.relative.x * 0.006
			pitch = clamp(pitch + event.relative.y * 0.006, 0.02, 1.561)
			_update()
		elif _panning:
			var right: Vector3 = global_transform.basis.x
			var up: Vector3 = global_transform.basis.y
			var rel: Vector2 = event.relative
			var move: Vector3 = (-right * rel.x + up * rel.y) * 0.01 * (distance / 20.0)
			target += move
			_update()
