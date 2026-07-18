extends CanvasLayer
## 統計ダッシュボード・実行コントロール・編集インスペクタ・スクリプトエディタ・コンソール。

var editor: Editor
var io: ModelIO
var camera: CameraRig
var grid: GridRuler

const PANEL_BG := Color(0.10, 0.11, 0.15, 0.94)
const ADD_TYPES := ["Source", "Queue", "Rack", "Processor", "Conveyor", "Sink", "Combiner", "Separator"]
const SNAP_SIZES := [0.25, 0.5, 1.0, 2.0, 5.0]

# CAD ツールバー
var _measure_btn: Button
# インスペクタ変形
var _x_edit: LineEdit
var _z_edit: LineEdit
var _rot_edit: LineEdit
var _scale_edit: LineEdit
# HUD
var _hud_panel: PanelContainer
var _hud_lbl: Label
var _bar_rect: ColorRect
var _bar_lbl: Label

var _play_btn: Button
var _edit_btn: Button
var _clock_lbl: Label
var _speed_lbl: Label
# 左カラム（上部バー→CADツールバー→編集ツールバー）を縦に積み、
# 上部バーの折返し行数が変わっても衝突しないよう実サイズで再配置する。
var _top_bar_panel: PanelContainer
var _cad_panel: PanelContainer

var _stats_vb: VBoxContainer
var _stats_panel: PanelContainer
var _chart: Chart
var _chart_panel: PanelContainer
var _hist: LeadHistogram
var _hist_panel: PanelContainer
var _gantt: GanttChart
var _rows: Array = []
var _op_rows: Array = []
var _kpi_lbl: Label

# 右クリック文脈メニュー
var _context_menu: PopupMenu
var _wire_btn: Button
var _ctx_obj = null

# インスペクタ
var _insp_panel: PanelContainer
var _edit_toolbar: PanelContainer
var _name_edit: LineEdit
var _type_lbl: Label
var _params_edit: TextEdit
var _script_edit: TextEdit
var _model_lbl: Label
var _conn_opt: OptionButton
var _outputs_lbl: Label
# Processor 簡易オプション（インスペクタ内・Processor選択時のみ表示）
var _proc_opt_row: HBoxContainer
var _transport_out_chk: CheckBox
var _mtbf_basis_opt: OptionButton
# 資源設定（編集ツールバー内）
var _shift_on_edit: LineEdit
var _shift_off_edit: LineEdit
var _shift_period_edit: LineEdit
var _dispatch_btn: Button

var _console: RichTextLabel
var _model_dialog: FileDialog
var _json_dialog: FileDialog
var _csv_dialog: FileDialog
var _json_save_mode: bool = false
var _script_dialog: ConfirmationDialog
var _pending_load_path: String = ""

# 実験 / 再現性
var _seed_edit: LineEdit
var _warm_edit: LineEdit
var _reps_edit: LineEdit
var _runlen_edit: LineEdit
var _sweep_param_edit: LineEdit
var _sweep_vals_edit: LineEdit
# 非同期(フレーム分割)実験の進捗表示・中断
var _exp_cancel_btn: Button
var _exp_prog_lbl: Label
# チャート用（区間スループット）
var _last_sample_t: float = -1.0
var _last_total: int = 0

func _ready() -> void:
	_build_top_bar()
	_build_cad_toolbar()
	_build_edit_toolbar()
	_build_inspector()
	_build_stats_panel()
	_build_console()
	_build_chart()
	_build_histogram()
	_build_hud()
	_build_dialogs()
	_build_context_menu()

	# 上部バーが3段に伸びたため、CAD/編集ツールバーを実サイズで直下へ積み直す。
	_layout_left_column()
	call_deferred("_layout_left_column")

	var timer := Timer.new()
	timer.wait_time = 0.1
	timer.autostart = true
	add_child(timer)
	timer.timeout.connect(_refresh)

	Scripts.log_emitted.connect(_on_log)
	editor.selection_changed.connect(_on_selection)
	editor.model_rebuilt.connect(_on_model_rebuilt)
	editor.transform_changed.connect(_on_transform_changed)
	editor.context_requested.connect(_on_context_requested)
	Sim.sim_reset.connect(_on_sim_reset)
	Sim.experiment_progress.connect(_on_experiment_progress)

	_rebuild_stats_rows()
	_on_selection(null)
	_set_edit_visible(false)

# ---------------------------------------------------------------
func _mk_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	sb.border_color = Color(0.3, 0.33, 0.4, 0.85)
	sb.set_border_width_all(1)
	p.add_theme_stylebox_override("panel", sb)
	return p

## パネルを画面端アンカーへ配置する（stretch=canvas_items・基準1600x900 前提）。
## 固定座標に代えて「対応する端からのマージン」で位置決めすることで、ウィンドウ／
## アスペクト比が変化しても各パネルが右／下／中央の端へ張り付き、大崩れしない。
## content サイズは grow 方向へ伸長し、reset_size() も grow を尊重するため両立する。
## anchor: "tr"=右上 / "br"=右下 / "bl"=左下 / "bc"=下中央。mx/my は端からの余白(px)。
func _place_panel(p: Control, anchor: String, mx: float, my: float) -> void:
	match anchor:
		"tr":   # 右上（左・下方向へ伸長）
			p.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			p.grow_vertical = Control.GROW_DIRECTION_END
			p.offset_left = -mx; p.offset_right = -mx
			p.offset_top = my; p.offset_bottom = my
		"br":   # 右下（左・上方向へ伸長）
			p.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			p.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			p.grow_vertical = Control.GROW_DIRECTION_BEGIN
			p.offset_left = -mx; p.offset_right = -mx
			p.offset_top = -my; p.offset_bottom = -my
		"bl":   # 左下（右・上方向へ伸長）
			p.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			p.grow_horizontal = Control.GROW_DIRECTION_END
			p.grow_vertical = Control.GROW_DIRECTION_BEGIN
			p.offset_left = mx; p.offset_right = mx
			p.offset_top = -my; p.offset_bottom = -my
		"bc":   # 下中央（左右・上方向へ伸長）
			p.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
			p.grow_horizontal = Control.GROW_DIRECTION_BOTH
			p.grow_vertical = Control.GROW_DIRECTION_BEGIN
			p.offset_top = -my; p.offset_bottom = -my

## 左カラム（上部バー→CAD→編集ツールバー）を実サイズで縦に積み直す。
## 上部バーの段数（画面幅により変動）に追従し、下段ツールバーが重ならない。
func _layout_left_column() -> void:
	if _top_bar_panel == null or _cad_panel == null:
		return
	var x: float = _top_bar_panel.position.x
	var y: float = _top_bar_panel.position.y + _top_bar_panel.size.y + 8.0
	_cad_panel.position = Vector2(x, y)
	y += _cad_panel.size.y + 8.0
	if _edit_toolbar != null:
		_edit_toolbar.position = Vector2(x, y)

func _btn(text: String, cb: Callable, minw: int = 0) -> Button:
	var b := Button.new()
	b.text = text
	if minw > 0:
		b.custom_minimum_size = Vector2(minw, 32)
	else:
		b.custom_minimum_size = Vector2(0, 32)
	b.pressed.connect(cb)
	return b

# ---------------------------------------------------------------
func _build_top_bar() -> void:
	var panel := _mk_panel()
	panel.position = Vector2(12, 12)
	add_child(panel)
	_top_bar_panel = panel
	# 単一行だと制御群が画面右端を超えて切れ、右上の統計パネルとも重なる。
	# 3段に分けて各行を左カラム幅内（右パネルへ届かない）に収める。
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	panel.add_child(vb)

	# 1段目: 実行制御・速度・時刻・編集・ファイル
	var r1 := HBoxContainer.new(); r1.add_theme_constant_override("separation", 10); vb.add_child(r1)
	_play_btn = _btn("▶ 開始", _on_play, 96)
	r1.add_child(_play_btn)
	r1.add_child(_btn("⟲ リセット", _on_reset, 96))
	r1.add_child(VSeparator.new())
	var sp := Label.new(); sp.text = "速度"; r1.add_child(sp)
	var slider := HSlider.new()
	slider.min_value = 0.25; slider.max_value = 30.0; slider.step = 0.25; slider.value = 2.0
	slider.custom_minimum_size = Vector2(150, 24)
	slider.value_changed.connect(_on_speed)
	r1.add_child(slider)
	_speed_lbl = Label.new(); _speed_lbl.text = "x2.00"; _speed_lbl.custom_minimum_size = Vector2(56, 0)
	r1.add_child(_speed_lbl)
	Sim.set_speed(2.0)
	r1.add_child(VSeparator.new())
	_clock_lbl = Label.new(); _clock_lbl.text = "T = 0.0 s"; _clock_lbl.custom_minimum_size = Vector2(120, 0)
	r1.add_child(_clock_lbl)
	r1.add_child(VSeparator.new())
	_edit_btn = Button.new()
	_edit_btn.text = "🔧 編集モード"
	_edit_btn.toggle_mode = true
	_edit_btn.custom_minimum_size = Vector2(120, 32)
	_edit_btn.toggled.connect(_on_edit_toggled)
	r1.add_child(_edit_btn)
	r1.add_child(VSeparator.new())
	r1.add_child(_btn("💾 保存", _on_save_quick, 80))
	r1.add_child(_btn("📂 読込", _on_load_quick, 80))
	r1.add_child(_btn("JSON…", _on_json_dialog_open, 72))

	# 2段目: 取込・undo・再現性・実験
	var r2 := HBoxContainer.new(); r2.add_theme_constant_override("separation", 10); vb.add_child(r2)
	r2.add_child(_btn("CSV到着表", _on_csv_import, 96))
	r2.add_child(VSeparator.new())
	r2.add_child(_btn("↶", func(): editor.undo(), 40))
	r2.add_child(_btn("↷", func(): editor.redo(), 40))
	r2.add_child(VSeparator.new())
	r2.add_child(_mini_label("種"))
	_seed_edit = _mini_edit(64); _seed_edit.text = str(Sim.seed)
	_seed_edit.text_submitted.connect(func(_t): Sim.seed = int(_to_f(_seed_edit.text, 12345)))
	r2.add_child(_seed_edit)
	r2.add_child(_mini_label("warm"))
	_warm_edit = _mini_edit(52); _warm_edit.text = str(Sim.warmup)
	_warm_edit.text_submitted.connect(func(_t): _on_warm_submit())
	r2.add_child(_warm_edit)
	r2.add_child(_mini_label("反復"))
	_reps_edit = _mini_edit(40); _reps_edit.text = "5"; r2.add_child(_reps_edit)
	r2.add_child(_mini_label("長さ"))
	_runlen_edit = _mini_edit(56); _runlen_edit.text = "3600"; r2.add_child(_runlen_edit)
	r2.add_child(_btn("🧪 実験", _on_experiment, 72))
	r2.add_child(_btn("🅰🅱 シナリオ実験(A/B)", _on_scenario_experiment, 148))
	r2.add_child(_btn("📄 レポート出力", _on_report, 116))

	# 3段目: シナリオ掃引（任意パラメータ×任意値）・最適化・実験進捗/中断
	# 選択オブジェクトの対象パラメータを値リスト(カンマ区切り)で掃引し run_scenarios する。
	var r3 := HBoxContainer.new(); r3.add_theme_constant_override("separation", 10); vb.add_child(r3)
	r3.add_child(_mini_label("掃引P"))
	_sweep_param_edit = _mini_edit(96); _sweep_param_edit.text = "process_time.a"
	_sweep_param_edit.tooltip_text = "選択obj の対象パラメータ名（例 process_time.a / interarrival.a / capacity）"
	r3.add_child(_sweep_param_edit)
	r3.add_child(_mini_label("値"))
	_sweep_vals_edit = _mini_edit(96); _sweep_vals_edit.text = "2,3,4,5"
	_sweep_vals_edit.tooltip_text = "カンマ区切りの値リスト（各値が1シナリオ）"
	r3.add_child(_sweep_vals_edit)
	r3.add_child(_btn("🧭 シナリオ掃引", _on_scenario_sweep, 120))
	# 最適化：選択obj の掃引Pを [値] リストの最小〜最大格子で grid 探索し、
	# スループット最大の値を探す（CRN・結果をコンソール＋user://optimize.csv）。
	r3.add_child(_btn("🎯 最適化", _on_optimize, 96))
	# 実験系は全てフレーム分割(非同期)で実行。進捗表示と「中断」ボタンを添える。
	r3.add_child(VSeparator.new())
	_exp_cancel_btn = _btn("⏹ 中断", func(): Sim.cancel_experiment(), 72)
	_exp_cancel_btn.disabled = true
	r3.add_child(_exp_cancel_btn)
	_exp_prog_lbl = _mini_label("")
	r3.add_child(_exp_prog_lbl)
	panel.reset_size()

func _build_cad_toolbar() -> void:
	var panel := _mk_panel()
	panel.position = Vector2(12, 60)   # 実サイズ確定後 _layout_left_column で上部バー直下へ再配置
	add_child(panel)
	_cad_panel = panel
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	panel.add_child(hb)

	# スナップ
	var snap_chk := CheckButton.new()
	snap_chk.text = "スナップ"
	snap_chk.button_pressed = editor.snap_enabled
	snap_chk.toggled.connect(func(p): editor.set_snap(p))
	hb.add_child(snap_chk)
	var snap_opt := OptionButton.new()
	for s in SNAP_SIZES:
		snap_opt.add_item(_fmt_g(s) + " m")
	snap_opt.select(2)  # 1.0m
	snap_opt.item_selected.connect(func(i): editor.snap_size = SNAP_SIZES[i])
	hb.add_child(snap_opt)
	hb.add_child(VSeparator.new())

	# メジャー
	_measure_btn = Button.new()
	_measure_btn.text = "📏 メジャー"
	_measure_btn.toggle_mode = true
	_measure_btn.toggled.connect(_on_measure_toggled)
	hb.add_child(_measure_btn)
	hb.add_child(_btn("線を確定", func(): editor.measure.finish_line(), 0))
	hb.add_child(_btn("計測クリア", func(): editor.measure.clear(), 0))
	hb.add_child(VSeparator.new())

	# ビュー
	var ortho_chk := CheckButton.new()
	ortho_chk.text = "平行投影"
	ortho_chk.toggled.connect(func(p): camera.set_ortho(p))
	hb.add_child(ortho_chk)
	hb.add_child(_btn("Top", func(): camera.preset("top"), 0))
	hb.add_child(_btn("Front", func(): camera.preset("front"), 0))
	hb.add_child(_btn("Side", func(): camera.preset("side"), 0))
	hb.add_child(_btn("Iso", func(): camera.preset("iso"), 0))
	panel.reset_size()

func _on_measure_toggled(pressed: bool) -> void:
	editor.set_measure_mode(pressed)

func _build_edit_toolbar() -> void:
	_edit_toolbar = _mk_panel()
	_edit_toolbar.position = Vector2(12, 108)
	add_child(_edit_toolbar)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	_edit_toolbar.add_child(outer)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	outer.add_child(hb)
	var lbl := Label.new(); lbl.text = "追加:"; hb.add_child(lbl)
	for t in ADD_TYPES:
		hb.add_child(_btn(t, _on_add.bind(t), 0))
	hb.add_child(VSeparator.new())
	hb.add_child(_btn("🗑 削除", _on_delete, 72))
	_wire_btn = Button.new()
	_wire_btn.text = "🔗 配線"
	_wire_btn.toggle_mode = true
	_wire_btn.toggled.connect(func(p): editor.set_wiring_mode(p))
	hb.add_child(_wire_btn)
	hb.add_child(VSeparator.new())
	hb.add_child(_mini_label("作業者"))
	hb.add_child(_btn("＋", func(): editor.add_operator(), 34))
	hb.add_child(_btn("－", func(): editor.remove_operator(), 34))
	hb.add_child(VSeparator.new())
	hb.add_child(_mini_label("搬送者"))
	hb.add_child(_btn("＋", func(): editor.add_transporter(), 34))
	hb.add_child(_btn("－", func(): editor.remove_transporter(), 34))

	# 資源設定（2段目）：全作業者共通シフト ＋ ディスパッチ規則
	var hb2 := HBoxContainer.new()
	hb2.add_theme_constant_override("separation", 6)
	outer.add_child(hb2)
	hb2.add_child(_mini_label("シフト on"))
	_shift_on_edit = _mini_edit(52); _shift_on_edit.text = "0"; hb2.add_child(_shift_on_edit)
	hb2.add_child(_mini_label("off"))
	_shift_off_edit = _mini_edit(52); _shift_off_edit.text = "0"; hb2.add_child(_shift_off_edit)
	hb2.add_child(_mini_label("周期"))
	_shift_period_edit = _mini_edit(60); _shift_period_edit.text = "0"; hb2.add_child(_shift_period_edit)
	hb2.add_child(_btn("シフト適用", _on_apply_shift, 0))
	hb2.add_child(VSeparator.new())
	hb2.add_child(_mini_label("割当"))
	_dispatch_btn = Button.new()
	_dispatch_btn.text = "FIFO"
	_dispatch_btn.toggle_mode = true
	_dispatch_btn.custom_minimum_size = Vector2(76, 0)
	_dispatch_btn.toggled.connect(_on_dispatch_toggled)
	hb2.add_child(_dispatch_btn)
	_edit_toolbar.reset_size()

func _on_apply_shift() -> void:
	editor.set_operator_shift(
		_to_f(_shift_on_edit.text, 0.0),
		_to_f(_shift_off_edit.text, 0.0),
		_to_f(_shift_period_edit.text, 0.0))

func _on_dispatch_toggled(pressed: bool) -> void:
	_dispatch_btn.text = "最近傍" if pressed else "FIFO"
	editor.set_dispatch_rule("nearest" if pressed else "fifo")

# ---------------------------------------------------------------
# 右クリック文脈メニュー
# ---------------------------------------------------------------
# 各項目 id は _on_context_menu_id の match と対応。
const _CTX_DUPLICATE := 0
const _CTX_DELETE := 1
const _CTX_RENAME := 2
const _CTX_WIRE := 3
const _CTX_SCRIPT := 4

func _build_context_menu() -> void:
	_context_menu = PopupMenu.new()
	_context_menu.add_item("⧉ 複製", _CTX_DUPLICATE)
	_context_menu.add_item("🗑 削除", _CTX_DELETE)
	_context_menu.add_separator()
	_context_menu.add_item("✎ リネーム", _CTX_RENAME)
	_context_menu.add_item("🔗 配線元に設定", _CTX_WIRE)
	_context_menu.add_item("</> スクリプト編集", _CTX_SCRIPT)
	_context_menu.id_pressed.connect(_on_context_menu_id)
	add_child(_context_menu)

## Editor から右クリック（オブジェクト上）を受けてメニューを開く。
## 対象は既に Editor 側で選択済み。screen_pos はビューポート座標
## （埋め込みサブウィンドウ既定のため埋め込み Popup の position と一致）。
func _on_context_requested(obj, screen_pos) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	_ctx_obj = obj
	_context_menu.reset_size()
	_context_menu.position = Vector2i(screen_pos)
	_context_menu.popup()

func _on_context_menu_id(id: int) -> void:
	if _ctx_obj == null or not is_instance_valid(_ctx_obj):
		return
	editor.select(_ctx_obj)   # 対象を確実に選択状態へ（各アクションは selected を操作）
	match id:
		_CTX_DUPLICATE:
			editor.duplicate_selected()
		_CTX_DELETE:
			editor.delete_selected()
		_CTX_RENAME:
			_begin_rename()
		_CTX_WIRE:
			# 配線モードのトグル表示を同期させつつ、対象を配線元に据える
			if _wire_btn != null:
				_wire_btn.set_pressed_no_signal(true)
			editor.begin_wire_from(_ctx_obj)
		_CTX_SCRIPT:
			_focus_script_editor()

## インスペクタの名前欄へフォーカスして全選択（リネーム開始）。
func _begin_rename() -> void:
	if editor.selected == null:
		return
	_insp_panel.visible = true
	_insp_panel.move_to_front()
	_name_edit.grab_focus()
	_name_edit.select_all()

## インスペクタのスクリプト欄へフォーカス（スクリプト編集開始）。
func _focus_script_editor() -> void:
	if editor.selected == null:
		return
	_insp_panel.visible = true
	_insp_panel.move_to_front()
	_script_edit.grab_focus()

func _build_inspector() -> void:
	_insp_panel = _mk_panel()
	_insp_panel.custom_minimum_size = Vector2(388, 0)
	# インスペクタは選択オブジェクトの唯一の編集面。背景を不透明にし、
	# アクセント枠を強めて「常に最前面で完全に読める」ことを保証する。
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0.10, 0.11, 0.15, 1.0)   # 完全不透明（背後の3D/パネルを透かさない）
	isb.set_corner_radius_all(8)
	isb.set_content_margin_all(10)
	isb.border_color = Color(0.42, 0.62, 0.95, 0.95)
	isb.set_border_width_all(2)
	_insp_panel.add_theme_stylebox_override("panel", isb)
	add_child(_insp_panel)
	# 編集モードでは実行専用の統計パネルを隠すので、その右上域をインスペクタが占有する。
	# 上部バー(1段)の直下へアンカー。左側は追加/CADツールバー＋HUDが占有できる。
	_place_panel(_insp_panel, "tr", 16, 64)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	_insp_panel.add_child(vb)

	var title := Label.new(); title.text = "── インスペクタ ──"
	title.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	vb.add_child(title)

	var hn := HBoxContainer.new()
	var nl := Label.new(); nl.text = "名前"; nl.custom_minimum_size = Vector2(60, 0); hn.add_child(nl)
	_name_edit = LineEdit.new(); _name_edit.custom_minimum_size = Vector2(300, 0)
	_name_edit.text_submitted.connect(_on_name_submit)
	hn.add_child(_name_edit); vb.add_child(hn)

	_type_lbl = Label.new(); _type_lbl.text = "型: -"; vb.add_child(_type_lbl)
	_model_lbl = Label.new(); _model_lbl.text = "モデル: -"
	_model_lbl.add_theme_font_size_override("font_size", 12); vb.add_child(_model_lbl)
	vb.add_child(_btn("🧩 3Dモデルを割り当て…", _on_assign_model, 0))

	# 変形（CAD）
	vb.add_child(_sep_label("変形（座標 m / 回転° / 縮尺）"))
	var hp := HBoxContainer.new()
	hp.add_child(_mini_label("X"))
	_x_edit = _mini_edit(70); _x_edit.text_submitted.connect(_on_pos_submit); hp.add_child(_x_edit)
	hp.add_child(_mini_label("Z"))
	_z_edit = _mini_edit(70); _z_edit.text_submitted.connect(_on_pos_submit); hp.add_child(_z_edit)
	vb.add_child(hp)
	var hr := HBoxContainer.new()
	hr.add_child(_mini_label("回転"))
	_rot_edit = _mini_edit(60); _rot_edit.text_submitted.connect(_on_rot_submit); hr.add_child(_rot_edit)
	hr.add_child(_btn("⟲-15", func(): editor.rotate_selected(-15.0), 0))
	hr.add_child(_btn("+15⟳", func(): editor.rotate_selected(15.0), 0))
	hr.add_child(_mini_label("縮尺"))
	_scale_edit = _mini_edit(56); _scale_edit.text_submitted.connect(_on_scale_submit); hr.add_child(_scale_edit)
	vb.add_child(hr)

	# Processor 簡易オプション（Processor選択時のみ表示）
	_proc_opt_row = HBoxContainer.new()
	_transport_out_chk = CheckBox.new()
	_transport_out_chk.text = "搬送で送出"
	_transport_out_chk.toggled.connect(_on_transport_out_toggled)
	_proc_opt_row.add_child(_transport_out_chk)
	_proc_opt_row.add_child(VSeparator.new())
	_proc_opt_row.add_child(_mini_label("故障基準"))
	_mtbf_basis_opt = OptionButton.new()
	_mtbf_basis_opt.add_item("operating")
	_mtbf_basis_opt.add_item("calendar")
	_mtbf_basis_opt.item_selected.connect(_on_mtbf_basis_selected)
	_proc_opt_row.add_child(_mtbf_basis_opt)
	vb.add_child(_proc_opt_row)

	vb.add_child(_sep_label("パラメータ (JSON)"))
	_params_edit = TextEdit.new()
	_params_edit.custom_minimum_size = Vector2(360, 60)
	vb.add_child(_params_edit)
	vb.add_child(_btn("パラメータ適用", _on_apply_params, 0))

	vb.add_child(_sep_label("スクリプト (GDScript / extends LogicBase)"))
	_script_edit = TextEdit.new()
	_script_edit.custom_minimum_size = Vector2(360, 120)
	_script_edit.add_theme_font_size_override("font_size", 12)
	vb.add_child(_script_edit)
	vb.add_child(_btn("▶ スクリプト適用（ホットリロード）", _on_apply_script, 0))

	vb.add_child(_sep_label("接続"))
	var hc := HBoxContainer.new()
	_conn_opt = OptionButton.new(); _conn_opt.custom_minimum_size = Vector2(200, 0)
	hc.add_child(_conn_opt)
	hc.add_child(_btn("→ 接続", _on_connect, 0))
	hc.add_child(_btn("解除", _on_clear_conn, 0))
	vb.add_child(hc)
	_outputs_lbl = Label.new(); _outputs_lbl.text = "出力先: -"
	_outputs_lbl.add_theme_font_size_override("font_size", 12); vb.add_child(_outputs_lbl)
	_insp_panel.reset_size()

func _sep_label(t: String) -> Label:
	var l := Label.new(); l.text = "── %s ──" % t
	l.add_theme_color_override("font_color", Color(0.65, 0.7, 0.8))
	l.add_theme_font_size_override("font_size", 12)
	return l

func _mini_label(t: String) -> Label:
	var l := Label.new(); l.text = t
	l.add_theme_font_size_override("font_size", 12)
	return l

func _mini_edit(w: int) -> LineEdit:
	var e := LineEdit.new()
	e.custom_minimum_size = Vector2(w, 0)
	return e

func _on_pos_submit(_t: String = "") -> void:
	if editor.selected == null:
		return
	editor.set_obj_position(_to_f(_x_edit.text), _to_f(_z_edit.text))

func _on_rot_submit(_t: String = "") -> void:
	editor.set_rotation_deg(_to_f(_rot_edit.text))

func _on_scale_submit(_t: String = "") -> void:
	editor.set_obj_scale(_to_f(_scale_edit.text, 1.0))

func _to_f(s: String, default_val: float = 0.0) -> float:
	var t := s.strip_edges()
	if t.is_valid_float():
		return t.to_float()
	return default_val

func _build_stats_panel() -> void:
	var panel := _mk_panel()
	panel.custom_minimum_size = Vector2(388, 0)
	add_child(panel)
	_place_panel(panel, "tr", 16, 12)   # 右上アンカー（右カラム上段＝ライブ状態）
	_stats_panel = panel
	var outer := VBoxContainer.new(); outer.add_theme_constant_override("separation", 6)
	panel.add_child(outer)
	_kpi_lbl = Label.new(); _kpi_lbl.text = "KPI 集計待ち…"
	_kpi_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_kpi_lbl.add_theme_font_size_override("font_size", 12)   # サマリ行。行高を抑え右カラム縦を節約
	_kpi_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # 右端で折返し（KPI欄の切れ防止）
	_kpi_lbl.custom_minimum_size = Vector2(372, 0)
	outer.add_child(_kpi_lbl)
	outer.add_child(HSeparator.new())
	# 設備/作業者ステータス＋ガントは行数がモデル依存で伸びるため、上限高のスクロール領域に
	# まとめて収める。これで統計パネル高が画面高(900)内で固定され、直下の滞留ヒストグラムと
	# 縦衝突しない。既定モデルでは設備(8)＋作業者(2)が全て同時表示され、ガントは直下
	# （必要ならスクロール）に置かれる。
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(372, 636)
	outer.add_child(scroll)
	# スクロールの唯一の子。_stats_vb（毎回再構築）とガントを兄弟として保持する。
	var inner := VBoxContainer.new(); inner.add_theme_constant_override("separation", 6)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner)
	_stats_vb = VBoxContainer.new(); _stats_vb.add_theme_constant_override("separation", 5)
	_stats_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(_stats_vb)
	# 状態ガントチャート（分析パネル内・レイアウト非破壊で追加）。
	# _stats_vb は再構築で子を全消去するため、ガントは inner 直下（_stats_vb の外）に置く。
	inner.add_child(HSeparator.new())
	var gt := Label.new(); gt.text = "── 状態ガント（設備別タイムライン）──"
	gt.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	gt.add_theme_font_size_override("font_size", 12)
	inner.add_child(gt)
	_gantt = GanttChart.new()
	_gantt.custom_minimum_size = Vector2(360, 104)
	inner.add_child(_gantt)

func _build_histogram() -> void:
	var panel := _mk_panel()
	# 右下アンカーの top-level パネルは offset だけでは高さ0に潰れるため、高さを明示固定する
	# （統計パネル=右上・全高固定 の直下に収まる高さ）。これで縦衝突しない。
	panel.custom_minimum_size = Vector2(388, 150)
	add_child(panel)
	_place_panel(panel, "br", 16, 14)
	_hist_panel = panel
	var vb := VBoxContainer.new(); panel.add_child(vb)
	var t := Label.new(); t.text = "── 滞留時間ヒストグラム ──"
	t.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0)); vb.add_child(t)
	_hist = LeadHistogram.new()
	_hist.custom_minimum_size = Vector2(366, 108)
	_hist.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_hist)
	panel.reset_size()

func _build_console() -> void:
	var panel := _mk_panel()
	panel.custom_minimum_size = Vector2(776, 250)
	add_child(panel)
	_place_panel(panel, "bc", 0, 14)   # 下中央アンカー（従来 pos(408,636) 相当）
	var vb := VBoxContainer.new(); panel.add_child(vb)
	var t := Label.new(); t.text = "── コンソール / ログ ──"
	t.add_theme_color_override("font_color", Color(0.8, 0.8, 0.6)); vb.add_child(t)
	_console = RichTextLabel.new()
	_console.scroll_following = true
	_console.custom_minimum_size = Vector2(756, 204)
	_console.add_theme_font_size_override("normal_font_size", 13)
	vb.add_child(_console)
	panel.reset_size()

func _build_chart() -> void:
	var panel := _mk_panel()
	panel.custom_minimum_size = Vector2(384, 250)
	add_child(panel)
	_place_panel(panel, "bl", 12, 14)   # 左下アンカー（従来 pos(12,636) 相当）
	_chart_panel = panel
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var t := Label.new(); t.text = "── 時系列（スループット / WIP）──"
	t.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0)); vb.add_child(t)
	_chart = Chart.new()
	_chart.custom_minimum_size = Vector2(362, 200)
	vb.add_child(_chart)
	panel.reset_size()

func _build_hud() -> void:
	_hud_panel = _mk_panel()
	add_child(_hud_panel)
	_place_panel(_hud_panel, "bc", 0, 300)   # 下中央（下段パネルの上・従来 pos(548,556) 相当）
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 2)
	_hud_panel.add_child(vb)
	_hud_lbl = Label.new()
	_hud_lbl.text = "カーソル -"
	_hud_lbl.add_theme_font_size_override("font_size", 13)
	vb.add_child(_hud_lbl)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	var sb := Label.new(); sb.text = "縮尺"; sb.add_theme_font_size_override("font_size", 12); hb.add_child(sb)
	_bar_rect = ColorRect.new()
	_bar_rect.color = Color(0.9, 0.92, 1.0)
	_bar_rect.custom_minimum_size = Vector2(100, 6)
	var mc := CenterContainer.new(); mc.add_child(_bar_rect); hb.add_child(mc)
	_bar_lbl = Label.new(); _bar_lbl.text = "5 m"; _bar_lbl.add_theme_font_size_override("font_size", 12)
	hb.add_child(_bar_lbl)
	vb.add_child(hb)
	_hud_panel.reset_size()

func _build_dialogs() -> void:
	_model_dialog = FileDialog.new()
	_model_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_model_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_model_dialog.filters = PackedStringArray(["*.glb, *.gltf, *.obj ; 3Dモデル"])
	_model_dialog.file_selected.connect(_on_model_file_selected)
	add_child(_model_dialog)

	_json_dialog = FileDialog.new()
	_json_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_json_dialog.filters = PackedStringArray(["*.json ; モデルJSON"])
	_json_dialog.file_selected.connect(_on_json_file_selected)
	add_child(_json_dialog)

	_csv_dialog = FileDialog.new()
	_csv_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_csv_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_csv_dialog.filters = PackedStringArray(["*.csv ; CSV(到着表)"])
	_csv_dialog.file_selected.connect(_on_csv_file_selected)
	add_child(_csv_dialog)

	_script_dialog = ConfirmationDialog.new()
	_script_dialog.title = "セキュリティ確認"
	_script_dialog.dialog_text = "このモデルはスクリプト(GDScript)を含みます。\n実行を許可しますか？\n（「無効化して読込」ならコードは実行されません）"
	_script_dialog.ok_button_text = "実行を許可"
	_script_dialog.get_cancel_button().text = "無効化して読込"
	_script_dialog.confirmed.connect(func(): editor.load_model(_pending_load_path, true))
	_script_dialog.canceled.connect(func(): editor.load_model(_pending_load_path, false))
	add_child(_script_dialog)

# ---------------------------------------------------------------
# 実行コントロール
# ---------------------------------------------------------------
func _on_play() -> void:
	Sim.toggle()
	# 実行開始時に状態タイムライン記録をON（ガントチャート用）。既定オフを実行時のみ有効化。
	# 記録は乱数/イベント順に無影響で、実験(visuals_enabled=false)では記録されない。
	Sim.set_timeline_recording(Sim.running)
	_play_btn.text = "⏸ 一時停止" if Sim.running else "▶ 開始"

func _on_reset() -> void:
	Sim.reset_sim()
	_play_btn.text = "▶ 開始"

func _on_speed(v: float) -> void:
	Sim.set_speed(v)
	_speed_lbl.text = "x%.2f" % v

func _on_edit_toggled(pressed: bool) -> void:
	editor.set_edit_mode(pressed)
	_set_edit_visible(pressed)
	if pressed:
		_play_btn.text = "▶ 開始"

func _set_edit_visible(on: bool) -> void:
	_edit_toolbar.visible = on
	# 実行専用パネル（設備稼働率/状態・作業者稼働率・滞留ヒスト・時系列）は
	# 編集モードでは空でスペースを食い重なるだけなので隠し、離脱時に復帰させる。
	# コンソール・HUD・上部/CAD/編集ツールバーは編集モードでも残す。
	if _stats_panel != null:
		_stats_panel.visible = not on
	if _hist_panel != null:
		_hist_panel.visible = not on
	if _chart_panel != null:
		_chart_panel.visible = not on
	_insp_panel.visible = on and editor.selected != null
	if _insp_panel.visible:
		_insp_panel.move_to_front()   # 常に最前面で完全に読める状態を保証

# ---------------------------------------------------------------
# 編集操作
# ---------------------------------------------------------------
func _on_add(type_str: String) -> void:
	# クリックで設置：配置モードへ入り、次の地面クリックで設置する。
	editor.begin_place(type_str)

func _on_delete() -> void:
	editor.delete_selected()

func _on_name_submit(txt: String) -> void:
	if editor.selected != null:
		editor.rename_selected(txt)   # push_undo 込みで名称変更

func _on_assign_model() -> void:
	if editor.selected == null:
		return
	_model_dialog.popup_centered(Vector2i(900, 600))

func _on_model_file_selected(path: String) -> void:
	editor.assign_model_to_selected(path)
	_on_selection(editor.selected)

func _on_apply_params() -> void:
	if editor.selected == null:
		return
	var parsed = JSON.parse_string(_params_edit.text)
	if typeof(parsed) == TYPE_DICTIONARY:
		editor.apply_params(parsed)
		Scripts.log_msg("パラメータ適用: %s" % editor.selected.obj_name)
	else:
		Scripts.log_msg("⚠ パラメータJSONが不正です")

func _on_apply_script() -> void:
	if editor.selected == null:
		return
	var res: Dictionary = editor.apply_script_to_selected(_script_edit.text)
	if not bool(res.get("ok", false)):
		var el: int = int(res.get("error_line", -1))
		if el > 0:
			Scripts.log_msg("✖ 適用に失敗しました。推定 %d行目付近。コンソール上部の行番号つき本文を確認してください。" % el)
		else:
			Scripts.log_msg("✖ 適用に失敗しました。コンソールの行番号つき本文と標準出力のエラーを確認してください。")

func _on_transport_out_toggled(pressed: bool) -> void:
	if editor.selected is Processor:
		editor.apply_params({"transport_out": pressed})
		_params_edit.text = JSON.stringify(editor.selected.get_params(), "\t")

func _on_mtbf_basis_selected(idx: int) -> void:
	if editor.selected is Processor:
		var basis: String = "calendar" if idx == 1 else "operating"
		editor.apply_params({"mtbf_basis": basis})
		_params_edit.text = JSON.stringify(editor.selected.get_params(), "\t")

func _on_connect() -> void:
	if _conn_opt.selected < 0:
		return
	var target_id = _conn_opt.get_item_metadata(_conn_opt.selected)
	editor.connect_selected_to(str(target_id))
	_on_selection(editor.selected)

func _on_clear_conn() -> void:
	editor.clear_selected_outputs()
	_on_selection(editor.selected)

# ---------------------------------------------------------------
# 保存/読込
# ---------------------------------------------------------------
func _on_save_quick() -> void:
	editor.save_model("user://model.json")

func _on_load_quick() -> void:
	_load_with_check("user://model.json")

func _load_with_check(path: String) -> void:
	if _model_has_scripts(path):
		_pending_load_path = path
		_script_dialog.popup_centered(Vector2i(460, 180))
	else:
		editor.load_model(path, true)

func _model_has_scripts(path: String) -> bool:
	var m := io.load_json(path)
	for od in m.get("objects", []):
		if str(od.get("script", "")) != "":
			return true
	return false

func _on_json_dialog_open() -> void:
	_json_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_json_dialog.popup_centered(Vector2i(900, 600))

func _on_json_file_selected(path: String) -> void:
	_load_with_check(path)

# ---------------------------------------------------------------
# CSV 取込（到着スケジュール）
# ---------------------------------------------------------------
func _on_csv_import() -> void:
	_csv_dialog.popup_centered(Vector2i(900, 600))

func _on_csv_file_selected(path: String) -> void:
	# 対象 Source：選択中が Source ならそれ、無ければ先頭 Source。
	var src = editor.selected if editor.selected is Source else _primary_source()
	if src == null:
		Scripts.log_msg("⚠ CSV到着表: 対象 Source が見つかりません")
		return
	if not FileAccess.file_exists(path):
		Scripts.log_msg("⚠ CSV読込失敗: %s" % path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		Scripts.log_msg("⚠ CSV読込失敗: %s" % path)
		return
	var txt := f.get_as_text()
	f.close()
	var sched: Array = io.csv_to_arrival_schedule(txt)
	if sched.is_empty():
		Scripts.log_msg("⚠ CSV到着表: 有効な行がありません")
		return
	src.arrival_schedule = sched
	Sim.reset_sim()
	Scripts.log_msg("📥 到着表を取込: %d区間 → %s" % [sched.size(), src.obj_name])

# ---------------------------------------------------------------
# 実験（Nレプリケーション・瞬時実行）
# ---------------------------------------------------------------
func _primary_sink():
	for o in editor.ctx.get("flow_objects", []):
		if o is Sink:
			return o
	return null

func _primary_source():
	for o in editor.ctx.get("flow_objects", []):
		if o is Source:
			return o
	return null

## 非同期実験の進捗シグナル受信。中断ボタン横のラベルに %表示を出す。
func _on_experiment_progress(frac: float, info: Dictionary) -> void:
	if _exp_prog_lbl == null:
		return
	var stage: String = str(info.get("stage", ""))
	_exp_prog_lbl.text = "%s %d%% (%d/%d)" % [stage, int(round(frac * 100.0)), int(info.get("i", 0)), int(info.get("n", 0))]

## 実験の実行中/終了時の UI 状態切替（中断ボタン活性・進捗ラベル・多重起動抑止表示）。
func _set_exp_running(on: bool) -> void:
	if _exp_cancel_btn != null:
		_exp_cancel_btn.disabled = not on
	if not on and _exp_prog_lbl != null:
		_exp_prog_lbl.text = ""

func _on_experiment() -> void:
	if Sim.exp_busy:
		Scripts.log_msg("⚠ 実験実行中です（⏹ 中断で停止できます）")
		return
	var seed_v: int = int(_to_f(_seed_edit.text, 12345))
	var warm: float = _to_f(_warm_edit.text, 0.0)
	var reps: int = max(1, int(_to_f(_reps_edit.text, 5)))
	var rl: float = max(1.0, _to_f(_runlen_edit.text, 3600.0))
	Scripts.log_msg("🧪 実験開始: reps=%d 長さ=%.0f warmup=%.0f seed=%d …（フレーム分割・中断可）" % [reps, rl, warm, seed_v])
	Sim.visuals_enabled = false
	_set_exp_running(true)
	# フレーム分割ランナー：UI を固めず進捗表示・中断可能。同期版と結果ビット一致。
	var res: Dictionary = await Sim.run_replications_async(reps, rl, warm, seed_v)
	_set_exp_running(false)
	Sim.visuals_enabled = true
	if res.get("cancelled", false):
		Scripts.log_msg("⏹ 実験を中断しました（%d/%d レプリケーション完了）" % [int(res.reps), reps])
	else:
		Scripts.log_msg("🧪 結果: スループット %.1f ± %.1f 個/時 ｜ 滞留 %.1f ± %.1f 秒（95%%CI, n=%d）" % [
			res.thr_mean, res.thr_ci, res.lt_mean, res.lt_ci, res.reps])
		_write_csv(res)
	# 対話状態を復元
	Sim.seed = seed_v
	Sim.warmup = warm
	Sim.reset_sim()
	_on_model_rebuilt()

## 現在モデルでHTML+CSVレポートを生成し、コンソールへパスを出す。
func _on_report() -> void:
	var seed_v: int = int(_to_f(_seed_edit.text, 12345))
	var warm: float = _to_f(_warm_edit.text, 0.0)
	var reps: int = max(2, int(_to_f(_reps_edit.text, 5)))
	var rl: float = max(1.0, _to_f(_runlen_edit.text, 3600.0))
	Scripts.log_msg("📄 レポート生成: reps=%d 長さ=%.0f warmup=%.0f base_seed=%d …" % [reps, rl, warm, seed_v])
	Sim.visuals_enabled = false
	var out: Dictionary = Sim.generate_report(reps, rl, warm, seed_v)
	Sim.visuals_enabled = true
	Scripts.log_msg("📄 HTML: %s" % ProjectSettings.globalize_path(out.html))
	Scripts.log_msg("📄 CSV : %s" % ProjectSettings.globalize_path(out.csv))
	# 対話状態を復元
	Sim.seed = seed_v
	Sim.warmup = warm
	Sim.reset_sim()
	_on_model_rebuilt()

func _write_csv(res: Dictionary) -> void:
	var f := FileAccess.open("user://experiment.csv", FileAccess.WRITE)
	if f == null:
		Scripts.log_msg("⚠ CSV書き出し失敗")
		return
	f.store_line("rep,throughput_per_hour,leadtime_s,wip")
	for i in range(res.throughput.size()):
		var wv = res.wip[i] if i < res.wip.size() else 0
		f.store_line("%d,%.3f,%.3f,%d" % [i + 1, res.throughput[i], res.leadtime[i], wv])
	f.store_line("mean,%.3f,%.3f," % [res.thr_mean, res.lt_mean])
	f.store_line("ci95,%.3f,%.3f," % [res.thr_ci, res.lt_ci])
	f.close()
	Scripts.log_msg("💾 user://experiment.csv に書き出しました")

## シナリオ実験(A/B)：既定モデル Source.interarrival を a=3.5 と a=2.5 の
## 2シナリオで比較（CRN）。結果をコンソールへ出力し user://scenarios.csv へ書き出す。
func _on_scenario_experiment() -> void:
	if Sim.exp_busy:
		Scripts.log_msg("⚠ 実験実行中です（⏹ 中断で停止できます）")
		return
	var seed_v: int = int(_to_f(_seed_edit.text, 12345))
	var warm: float = _to_f(_warm_edit.text, 0.0)
	var reps: int = max(2, int(_to_f(_reps_edit.text, 5)))
	var rl: float = max(1.0, _to_f(_runlen_edit.text, 3600.0))
	var src_id: String = editor.ctx.source.id if editor.ctx.get("source", null) != null else "src"
	var scenarios := [
		{"name": "A(ia=3.5)", "overrides": {src_id: {"interarrival": {"type": "exp", "a": 3.5}}}},
		{"name": "B(ia=2.5)", "overrides": {src_id: {"interarrival": {"type": "exp", "a": 2.5}}}},
	]
	Scripts.log_msg("🅰🅱 シナリオ実験開始: reps=%d 長さ=%.0f warmup=%.0f base_seed=%d …（フレーム分割・中断可）" % [reps, rl, warm, seed_v])
	Sim.visuals_enabled = false
	_set_exp_running(true)
	var res: Dictionary = await Sim.run_scenarios_async(scenarios, reps, rl, warm, seed_v)
	_set_exp_running(false)
	Sim.visuals_enabled = true
	if res.get("cancelled", false):
		Scripts.log_msg("⏹ シナリオ実験を中断しました（%d/%d シナリオ完了）" % [res.scenarios.size(), scenarios.size()])
	for sc in res.scenarios:
		Scripts.log_msg("  %s: スループット %.1f ± %.1f 個/時 ｜ 滞留 %.1f ± %.1f 秒" % [
			sc.name, sc.thr_mean, sc.thr_ci, sc.lt_mean, sc.lt_ci])
	if res.has("compare"):
		var cmp: Dictionary = res.compare
		Scripts.log_msg("  対比較(%s-%s, CRN): Δスループット %.2f ± %.2f 個/時 ｜ Δ滞留 %.2f ± %.2f 秒" % [
			cmp.a, cmp.b, cmp.thr_d_mean, cmp.thr_d_ci, cmp.lt_d_mean, cmp.lt_d_ci])
	_write_scenarios_csv(res)
	# 対話状態を復元
	Sim.seed = seed_v
	Sim.warmup = warm
	Sim.reset_sim()
	_on_model_rebuilt()

func _write_scenarios_csv(res: Dictionary) -> void:
	var f := FileAccess.open("user://scenarios.csv", FileAccess.WRITE)
	if f == null:
		Scripts.log_msg("⚠ CSV書き出し失敗")
		return
	f.store_line("scenario,rep,seed,throughput_per_hour,leadtime_s")
	for sc in res.scenarios:
		for i in range(sc.throughput.size()):
			var sd = res.seeds[i] if i < res.seeds.size() else 0
			f.store_line("%s,%d,%d,%.3f,%.3f" % [sc.name, i + 1, sd, sc.throughput[i], sc.leadtime[i]])
	for sc in res.scenarios:
		f.store_line("%s,mean,,%.3f,%.3f" % [sc.name, sc.thr_mean, sc.lt_mean])
		f.store_line("%s,ci95,,%.3f,%.3f" % [sc.name, sc.thr_ci, sc.lt_ci])
	if res.has("compare"):
		var cmp: Dictionary = res.compare
		f.store_line("compare(%s-%s),d_mean,,%.3f,%.3f" % [cmp.a, cmp.b, cmp.thr_d_mean, cmp.lt_d_mean])
		f.store_line("compare(%s-%s),d_ci95,,%.3f,%.3f" % [cmp.a, cmp.b, cmp.thr_d_ci, cmp.lt_d_ci])
	f.close()
	Scripts.log_msg("💾 user://scenarios.csv に書き出しました")

## シナリオ掃引：選択オブジェクトの対象パラメータを値リストで掃引する。
## 各値を1シナリオとして run_scenarios し、全シナリオの平均±95%CIを
## コンソール出力＋user://scenarios.csv へ書き出す（CRN・実行後にパラメータ復元）。
func _on_scenario_sweep() -> void:
	if Sim.exp_busy:
		Scripts.log_msg("⚠ 実験実行中です（⏹ 中断で停止できます）")
		return
	if editor.selected == null or not (editor.selected is FlowObject):
		Scripts.log_msg("⚠ シナリオ掃引: 対象オブジェクトを選択してください")
		return
	var obj = editor.selected
	var param_path: String = _sweep_param_edit.text.strip_edges()
	if param_path == "":
		Scripts.log_msg("⚠ シナリオ掃引: 対象パラメータ名を入力してください")
		return
	var values: Array = _parse_num_list(_sweep_vals_edit.text)
	if values.is_empty():
		Scripts.log_msg("⚠ シナリオ掃引: 値リスト(カンマ区切り)を入力してください")
		return
	var seed_v: int = int(_to_f(_seed_edit.text, 12345))
	var warm: float = _to_f(_warm_edit.text, 0.0)
	var reps: int = max(1, int(_to_f(_reps_edit.text, 5)))
	var rl: float = max(1.0, _to_f(_runlen_edit.text, 3600.0))
	var scenarios: Array = Sim.build_sweep_scenarios(obj.id, param_path, values, obj.get_params())
	if scenarios.is_empty():
		Scripts.log_msg("⚠ シナリオ掃引: シナリオ生成に失敗しました（パラメータ名を確認）")
		return
	Scripts.log_msg("🧭 シナリオ掃引: %s の %s を %s で掃引（reps=%d 長さ=%.0f warmup=%.0f base_seed=%d）…（フレーム分割・中断可）" % [
		obj.obj_name, param_path, str(values), reps, rl, warm, seed_v])
	Sim.visuals_enabled = false
	_set_exp_running(true)
	var res: Dictionary = await Sim.run_scenarios_async(scenarios, reps, rl, warm, seed_v)
	_set_exp_running(false)
	Sim.visuals_enabled = true
	if res.get("cancelled", false):
		Scripts.log_msg("⏹ シナリオ掃引を中断しました（%d/%d シナリオ完了）" % [res.scenarios.size(), scenarios.size()])
	for sc in res.scenarios:
		Scripts.log_msg("  %s: スループット %.1f ± %.1f 個/時 ｜ 滞留 %.1f ± %.1f 秒" % [
			sc.name, sc.thr_mean, sc.thr_ci, sc.lt_mean, sc.lt_ci])
	if res.has("compare"):
		var cmp: Dictionary = res.compare
		Scripts.log_msg("  対比較(%s-%s, CRN): Δスループット %.2f ± %.2f 個/時" % [
			cmp.a, cmp.b, cmp.thr_d_mean, cmp.thr_d_ci])
	_write_scenarios_csv(res)
	# 対話状態を復元
	Sim.seed = seed_v
	Sim.warmup = warm
	Sim.reset_sim()
	_on_model_rebuilt()

## 最適化：選択オブジェクトの掃引Pパラメータを、値リストの最小〜最大を刻み幅とする
## 離散格子で grid 探索し、スループット最大化の最適値を求める（CRN・実行後に復元）。
## 結果をコンソール＋user://optimize.csv に出力する。
func _on_optimize() -> void:
	if Sim.exp_busy:
		Scripts.log_msg("⚠ 実験実行中です（⏹ 中断で停止できます）")
		return
	if editor.selected == null or not (editor.selected is FlowObject):
		Scripts.log_msg("⚠ 最適化: 対象オブジェクトを選択してください")
		return
	var obj = editor.selected
	var param_path: String = _sweep_param_edit.text.strip_edges()
	if param_path == "":
		Scripts.log_msg("⚠ 最適化: 対象パラメータ名（掃引P）を入力してください")
		return
	var values: Array = _parse_num_list(_sweep_vals_edit.text)
	if values.is_empty():
		Scripts.log_msg("⚠ 最適化: 値リスト（値）から格子範囲を決定できません")
		return
	# 値リストの最小/最大/最小刻みから離散格子を構成（掃引欄を再利用）。
	var lo: float = values[0]
	var hi: float = values[0]
	for v in values:
		lo = min(lo, float(v))
		hi = max(hi, float(v))
	var step: float = (hi - lo)
	if values.size() >= 2 and step > 0.0:
		step = step / float(values.size() - 1)
	if step <= 0.0:
		step = 1.0
	var seed_v: int = int(_to_f(_seed_edit.text, 12345))
	var warm: float = _to_f(_warm_edit.text, 0.0)
	var reps: int = max(1, int(_to_f(_reps_edit.text, 5)))
	var rl: float = max(1.0, _to_f(_runlen_edit.text, 3600.0))
	var dvars := [{"obj_id": obj.id, "param": param_path, "min": lo, "max": hi, "step": step}]
	var objective := {"metric": "throughput", "sense": "max"}
	Scripts.log_msg("🎯 最適化開始: %s の %s を [%.3f..%.3f step %.3f] で grid 探索（reps=%d 長さ=%.0f warmup=%.0f base_seed=%d）…（フレーム分割・中断可）" % [
		obj.obj_name, param_path, lo, hi, step, reps, rl, warm, seed_v])
	Sim.visuals_enabled = false
	_set_exp_running(true)
	var res: Dictionary = await Sim.optimize_async(dvars, objective, "grid", 256, reps, rl, warm, seed_v)
	_set_exp_running(false)
	Sim.visuals_enabled = true
	if res.get("cancelled", false):
		Scripts.log_msg("⏹ 最適化を中断しました（評価%d点まで）" % int(res.evaluated))
	for h in res.history:
		Scripts.log_msg("  %s → スループット %.1f 個/時" % [str(h.assign), float(h.obj)])
	Scripts.log_msg("  ★ 最適: %s → スループット %.1f 個/時（評価%d点）" % [
		str(res.best), float(res.best_obj), int(res.evaluated)])
	_write_optimize_csv(res)
	# 対話状態を復元
	Sim.seed = seed_v
	Sim.warmup = warm
	Sim.reset_sim()
	_on_model_rebuilt()

## 最適化の探索履歴と最適解を user://optimize.csv に書き出す。
func _write_optimize_csv(res: Dictionary) -> void:
	var f := FileAccess.open("user://optimize.csv", FileAccess.WRITE)
	if f == null:
		Scripts.log_msg("⚠ CSV書き出し失敗")
		return
	var keys: Array = []
	if res.history.size() > 0:
		keys = (res.history[0].assign as Dictionary).keys()
	elif res.has("best"):
		keys = (res.best as Dictionary).keys()
	var header: String = "eval"
	for k in keys:
		header += "," + str(k)
	header += ",objective"
	f.store_line(header)
	for i in range(res.history.size()):
		var h: Dictionary = res.history[i]
		var row: String = str(i + 1)
		for k in keys:
			row += "," + str(float(h.assign.get(k, 0.0)))
		row += ",%.4f" % float(h.obj)
		f.store_line(row)
	var best_row: String = "best"
	for k in keys:
		best_row += "," + str(float(res.best.get(k, 0.0)))
	best_row += ",%.4f" % float(res.best_obj)
	f.store_line(best_row)
	f.close()
	Scripts.log_msg("💾 user://optimize.csv に書き出しました")

## カンマ区切り文字列を数値配列に変換（空要素は無視）。
func _parse_num_list(s: String) -> Array:
	var out: Array = []
	for tok in s.split(",", false):
		var t: String = tok.strip_edges()
		if t == "":
			continue
		out.append(_to_f(t, 0.0))
	return out

# ---------------------------------------------------------------
# 選択・再構築
# ---------------------------------------------------------------
func _on_selection(obj) -> void:
	_insp_panel.visible = editor.edit_mode and obj != null
	if _insp_panel.visible:
		_insp_panel.move_to_front()   # 選択のたびに最前面へ（他パネルに隠れない）
	if obj == null:
		return
	_name_edit.text = obj.obj_name
	_type_lbl.text = "型: %s   id: %s" % [obj.type_name(), obj.id]
	_model_lbl.text = "モデル: %s" % (obj.model_path if obj.model_path != "" else "(既定)")
	_fill_transform(obj)
	_params_edit.text = JSON.stringify(obj.get_params(), "\t")
	_script_edit.text = obj.script_source if obj.script_source != "" else Scripts.DEFAULT_TEMPLATE
	_refresh_conn_options(obj)
	# Processor 簡易オプションの表示/現在値反映（信号を出さずに設定）
	var is_proc: bool = obj is Processor
	_proc_opt_row.visible = is_proc
	if is_proc:
		var p: Dictionary = obj.get_params()
		_transport_out_chk.set_pressed_no_signal(bool(p.get("transport_out", false)))
		_mtbf_basis_opt.select(1 if str(p.get("mtbf_basis", "operating")) == "calendar" else 0)

func _fill_transform(obj) -> void:
	_x_edit.text = "%.2f" % obj.position.x
	_z_edit.text = "%.2f" % obj.position.z
	_rot_edit.text = "%.0f" % rad_to_deg(obj.rotation.y)
	_scale_edit.text = "%.2f" % obj.model_scale

func _on_transform_changed(obj) -> void:
	if obj != null and obj == editor.selected:
		_fill_transform(obj)

func _refresh_conn_options(obj) -> void:
	_conn_opt.clear()
	for o in editor.ctx.flow_objects:
		if o != obj:
			var i := _conn_opt.item_count
			_conn_opt.add_item("%s (%s)" % [o.obj_name, o.id])
			_conn_opt.set_item_metadata(i, o.id)
	var names: Array = []
	for t in obj.outputs:
		names.append(t.obj_name)
	_outputs_lbl.text = "出力先: %s" % (", ".join(names) if names.size() > 0 else "-")

func _on_model_rebuilt() -> void:
	_rebuild_stats_rows()
	if _chart != null:
		_chart.reset()
	_last_sample_t = -1.0
	_last_total = 0
	if editor.selected != null:
		_on_selection(editor.selected)

## warmup 入力の確定。実行中の変更は時刻逆行（負WIP面積等）を招くため拒否し、
## 一時停止を促す。表示は現在値へ戻す。
func _on_warm_submit() -> void:
	if Sim.running:
		_warm_edit.text = str(Sim.warmup)
		Scripts.log_msg("⚠ 実行中は warmup を変更できません（⏸ 一時停止してから変更してください）")
		return
	Sim.warmup = _to_f(_warm_edit.text, 0.0)

func _on_sim_reset() -> void:
	if _chart != null:
		_chart.reset()
	_last_sample_t = -1.0
	_last_total = 0
	if _seed_edit != null:
		_seed_edit.text = str(Sim.seed)
	if _warm_edit != null:
		_warm_edit.text = str(Sim.warmup)

func _rebuild_stats_rows() -> void:
	for c in _stats_vb.get_children():
		c.queue_free()
	_rows.clear()
	_op_rows.clear()
	var t := Label.new(); t.text = "設備ステータス / 稼働率"
	t.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0)); _stats_vb.add_child(t)
	for obj in editor.ctx.get("flow_objects", []):
		var row := _mk_row(obj.obj_name, true)
		row.st.obj = obj
		_stats_vb.add_child(row.c)
		_rows.append({"obj": obj, "name": row.name, "bar": row.bar, "io": row.io, "st": row.st})
	var ot := Label.new(); ot.text = "作業者 稼働率"
	ot.add_theme_color_override("font_color", Color(1.0, 0.8, 0.5)); _stats_vb.add_child(ot)
	for op in editor.ctx.get("operators", []):
		var row := _mk_row(op.op_name, false)
		_stats_vb.add_child(row.c)
		_op_rows.append({"op": op, "name": row.name, "bar": row.bar})
	if _gantt != null:
		_gantt.objects = editor.ctx.get("flow_objects", [])
	if _stats_panel != null:
		_stats_panel.reset_size()

func _mk_row(nm: String, with_state: bool) -> Dictionary:
	# 行はやや詰めて（バーを細く、作業者は空のio行を省く）右カラム縦方向の予算内に収める。
	var c := VBoxContainer.new(); c.add_theme_constant_override("separation", 1)
	var name_lbl := Label.new(); name_lbl.text = nm
	name_lbl.add_theme_font_size_override("font_size", 14); c.add_child(name_lbl)
	var bar := ProgressBar.new()
	bar.min_value = 0; bar.max_value = 100; bar.value = 0; bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 10); c.add_child(bar)
	var st: StateBar = null
	var io_lbl: Label = null
	# StateBar・io行（in/out・Lq/Wq）は設備のみ。作業者は空行になるため生成せず縦を節約する。
	if with_state:
		st = StateBar.new()
		st.custom_minimum_size = Vector2(0, 9)
		c.add_child(st)
		io_lbl = Label.new(); io_lbl.text = ""
		io_lbl.add_theme_font_size_override("font_size", 11)
		io_lbl.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
		c.add_child(io_lbl)
	return {"c": c, "name": name_lbl, "bar": bar, "io": io_lbl, "st": st}

# ---------------------------------------------------------------
func _on_log(line: String) -> void:
	if _console != null:
		_console.add_text(line + "\n")

func _refresh() -> void:
	_clock_lbl.text = "T = %.1f s" % Sim.sim_time
	for r in _rows:
		var obj = r.obj
		if not is_instance_valid(obj):
			continue
		var util: float = obj.utilization() * 100.0
		r.name.text = "%s  [%s]" % [obj.obj_name, obj.state]
		r.bar.value = util
		_color_bar(r.bar, util)
		r.io.text = "in %d / out %d   稼働 %.0f%%" % [obj.input_count, obj.output_count, util]
		if obj is Queue:
			r.io.text += "   Lq=%.1f Wq=%.1fs" % [obj.avg_length(), obj.avg_wait()]
		if r.st != null:
			r.st.queue_redraw()
	for r in _op_rows:
		var op = r.op
		if not is_instance_valid(op):
			continue
		var util2: float = op.utilization() * 100.0
		r.name.text = "%s  [%s]" % [op.op_name, ("在席" if op.available else "作業中")]
		r.bar.value = util2
		_color_bar(r.bar, util2)

	# 複数 Source/Sink を集計
	var out_total := 0
	var lead_sum := 0.0
	for o in editor.ctx.get("flow_objects", []):
		if o is Sink:
			out_total += o.total
			lead_sum += o.sum_time_in_system
	var thr: float = float(out_total) / Sim.stats_elapsed() * 3600.0
	var avg: float = (lead_sum / out_total) if out_total > 0 else 0.0
	var wip: int = Sim.wip   # ライブWIPカウンタ（created-sunk 差分は warmup 跨ぎでずれる）
	var pool = editor.ctx.get("pool", null)
	var freeop := 0
	if pool != null and is_instance_valid(pool):
		freeop = pool.available_count()
	_kpi_lbl.text = "産出 %d 個   スループット %.1f 個/時\n平均滞留 %.1f 秒   仕掛(現在 %d / 時間平均 %.1f)   空き作業者 %d" % [
		out_total, thr, avg, wip, Sim.avg_wip(), freeop]
	if _hist != null:
		var psink = _primary_sink()
		if psink != null and is_instance_valid(psink):
			_hist.data = psink.leadtimes
		_hist.queue_redraw()
	if _gantt != null:
		_gantt.queue_redraw()

	# 区間スループット（累積平均ではなく直近の実測レート）を時系列に
	if _chart != null:
		if _last_sample_t < 0.0:
			_last_sample_t = Sim.sim_time
			_last_total = out_total
		var dt: float = Sim.sim_time - _last_sample_t
		if Sim.running and dt > 0.0:
			var rate: float = float(out_total - _last_total) / dt * 3600.0
			_chart.push_sample(rate, float(wip))
			_last_sample_t = Sim.sim_time
			_last_total = out_total
	_update_hud()

func _update_hud() -> void:
	if camera == null or _hud_lbl == null:
		return
	var minor: float = grid.minor if grid != null else 1.0
	var ppm: float = camera.pixels_per_meter()
	var mouse := get_viewport().get_mouse_position()
	var w := _ground_from_screen(mouse)
	var coord := "-" if w == Vector3.INF else "(%.2f, %.2f) m" % [w.x, w.z]
	if editor.is_placing():
		# 配置モード中はカーソル文言を設置ガイドへ切替
		_hud_lbl.text = "配置: %s — クリックで設置 / Escで取消 ｜ %s" % [editor.placing_type(), coord]
	else:
		_hud_lbl.text = "カーソル %s ｜ 1マス=%.2fm ｜ %s ｜ スナップ %s(%sm)" % [
			coord, minor, ("正射" if camera.ortho else "透視"),
			("ON" if editor.snap_enabled else "OFF"), _fmt_g(editor.snap_size)]
	var meters: float = minor * 5.0
	var px: float = clamp(meters * ppm, 20.0, 320.0)
	_bar_rect.custom_minimum_size = Vector2(px, 6)
	_bar_lbl.text = "%s m" % _fmtnum(meters)
	_hud_panel.reset_size()

func _fmtnum(v: float) -> String:
	if abs(v - round(v)) < 0.001:
		return "%d" % int(round(v))
	return "%.1f" % v

func _fmt_g(v: float) -> String:
	var s := "%.2f" % v
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s

func _ground_from_screen(sp: Vector2) -> Vector3:
	if camera == null:
		return Vector3.INF
	var from := camera.project_ray_origin(sp)
	var dir := camera.project_ray_normal(sp)
	if abs(dir.y) < 1e-5:
		return Vector3.INF
	var t := -from.y / dir.y
	if t < 0:
		return Vector3.INF
	return from + dir * t

var _bar_sb: Array = []

func _mk_bar_sb(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(3)
	return sb

func _color_bar(bar: ProgressBar, util: float) -> void:
	# 3段階の共有スタイルボックスを使い回す（毎フレーム生成を避ける）
	if _bar_sb.is_empty():
		_bar_sb = [
			_mk_bar_sb(Color(0.35, 0.55, 0.9)),
			_mk_bar_sb(Color(0.35, 0.8, 0.45)),
			_mk_bar_sb(Color(0.9, 0.75, 0.3)),
		]
	var idx: int = 0 if util < 40.0 else (1 if util < 80.0 else 2)
	if bar.get_theme_stylebox("fill") != _bar_sb[idx]:
		bar.add_theme_stylebox_override("fill", _bar_sb[idx])
