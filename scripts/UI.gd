extends CanvasLayer
## 統計ダッシュボード・実行コントロール・編集インスペクタ・スクリプトエディタ・コンソール。

var editor: Editor
var io: ModelIO
var camera: CameraRig
var grid: GridRuler

# --- モダン・フラットダーク パレット --------------------------------
# 階層化したダークグレー（base<panel<elevated）＋控えめな枠線＋1色のアクセント。
const C_BASE    := Color("#12141a")   # 最下地
const C_PANEL   := Color("#1a1d26")   # パネル面
const C_ELEV    := Color("#22262f")   # 一段上（ボタン/タイル）
const C_ELEV2   := Color("#2c313c")   # ホバー/枠線
const C_BORDER  := Color("#2c313c")   # 1px 枠線
const C_TEXT    := Color("#e6e8ec")   # 主要テキスト（オフホワイト）
const C_MUTED   := Color("#9aa0ac")   # 副次テキスト（ミュート）
const C_ACCENT  := Color("#4c8dff")   # アクセント（プライマリ/トグルON）
const C_ACCENT2 := Color("#34c6a8")   # 補助アクセント（ティール）
const PANEL_BG  := Color(0.102, 0.114, 0.149, 0.965)   # = C_PANEL に近い半透明
const ADD_TYPES := ["Source", "Queue", "Rack", "Processor", "Conveyor", "Sink", "Combiner", "Separator"]
const SNAP_SIZES := [0.25, 0.5, 1.0, 2.0, 5.0]

# テーマ・フォント（_build_theme で生成し全パネルへ付与）
var _theme: Theme
var _ui_font: FontFile
var _ui_font_bold: FontVariation

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
var _kpi_tiles: Dictionary = {}   # key -> 値ラベル（KPIタイル）

# 右クリック文脈メニュー
var _context_menu: PopupMenu
## 資源ユニット（作業者/搬送者）専用の文脈メニュー（リネーム/複製/削除）。
## FlowObject 用 _context_menu とは別に持ち、_on_context_requested が対象の型で出し分ける。
var _unit_context_menu: PopupMenu
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
var _outputs_list: VBoxContainer   # 出力エッジを1行ずつ並べる編集リスト（[port N] 名 × ▲ ▼）
# FlowObject 専用のインスペクタ区画（モデル割当/パラメータ/スクリプト/接続）。
# 資源ユニット（Operator/Transporter）選択時は丸ごと隠し、名前と変形だけを編集面に残す。
var _fo_only_box: VBoxContainer
# Processor 簡易オプション（インスペクタ内・Processor選択時のみ表示）
var _proc_opt_row: HBoxContainer
var _transport_out_chk: CheckBox
var _mtbf_basis_opt: OptionButton
# 資源ユニット（Operator/Transporter）専用のインスペクタ区画。ユニット選択時のみ表示し、
# 移動速度＋型別パラメータ（作業者=シフト / 搬送者=容量・積載/投下時間・優先度）を編集する。
var _unit_box: VBoxContainer
var _unit_op_box: VBoxContainer   # 作業者専用（シフト）
var _unit_tr_box: VBoxContainer   # 搬送者専用（容量/時間/優先度）
var _u_speed_edit: LineEdit
var _u_shift_on_edit: LineEdit
var _u_shift_off_edit: LineEdit
var _u_shift_period_edit: LineEdit
var _u_cap_edit: LineEdit
var _u_prio_edit: LineEdit
var _u_load_edit: LineEdit
var _u_unload_edit: LineEdit
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
# Process Flow（オプトイン）制御
var _pf_status_lbl: Label
var _pf_active: bool = false
# サンプル・ライブラリ（samples/index.json から生成する読込メニュー）
var _sample_opt: OptionButton
# チャート用（区間スループット）
var _last_sample_t: float = -1.0
var _last_total: int = 0

func _ready() -> void:
	_build_theme()
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
	_build_unit_context_menu()

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
# モダン・フラットダーク テーマ
# ---------------------------------------------------------------
## StyleBoxFlat 生成ヘルパ（角丸・任意枠線・内側余白）。
func _sbf(bg: Color, radius: int = 6, border_col: Color = Color(0, 0, 0, 0), border_w: int = 0, ph: int = 12, pv: int = 6) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = ph
	sb.content_margin_right = ph
	sb.content_margin_top = pv
	sb.content_margin_bottom = pv
	if border_w > 0:
		sb.border_color = border_col
		sb.set_border_width_all(border_w)
		sb.anti_aliasing = true
	return sb

## UI 全体に付与するダークテーマ（フォント＋各ウィジェットのスタイル）を構築。
## 未指定項目は Godot 既定テーマにフォールバックするため、変更したい箇所だけ上書きする。
func _build_theme() -> void:
	var th := Theme.new()
	# --- フォント（Noto Sans CJK JP）。_draw ウィジェット/3Dラベルには fallback_font 経由で波及 ---
	var f := FontFile.new()
	var fp := ProjectSettings.globalize_path("res://fonts/NotoSansCJKjp.ttc")
	if f.load_dynamic_font(fp) == OK and f.get_face_count() > 0:
		_ui_font = f
		ThemeDB.fallback_font = f
		th.default_font = f
		var fb := FontVariation.new()
		fb.set_base_font(f)
		fb.variation_embolden = 0.5
		_ui_font_bold = fb
	th.default_font_size = 14

	# --- ボタン類（Button / OptionButton / MenuButton 共通） ---
	var btn_normal := _sbf(C_ELEV, 6, C_BORDER, 1, 12, 6)
	var btn_hover := _sbf(C_ELEV2, 6, Color("#3a4150"), 1, 12, 6)
	var btn_pressed := _sbf(C_ACCENT, 6, C_ACCENT, 1, 12, 6)          # トグルON/押下＝アクセント
	var btn_disabled := _sbf(Color("#191c24"), 6, C_BORDER, 1, 12, 6)
	var btn_focus := _sbf(Color(0, 0, 0, 0), 6, C_ACCENT, 1, 12, 6)   # フォーカス＝アクセント枠のみ
	btn_focus.draw_center = false
	for t in ["Button", "OptionButton", "MenuButton"]:
		th.set_stylebox("normal", t, btn_normal)
		th.set_stylebox("hover", t, btn_hover)
		th.set_stylebox("pressed", t, btn_pressed)
		th.set_stylebox("hover_pressed", t, btn_pressed)
		th.set_stylebox("disabled", t, btn_disabled)
		th.set_stylebox("focus", t, btn_focus)
		th.set_color("font_color", t, C_TEXT)
		th.set_color("font_hover_color", t, Color.WHITE)
		th.set_color("font_pressed_color", t, Color.WHITE)
		th.set_color("font_hover_pressed_color", t, Color.WHITE)
		th.set_color("font_focus_color", t, C_TEXT)
		th.set_color("font_disabled_color", t, Color(C_MUTED.r, C_MUTED.g, C_MUTED.b, 0.45))
		th.set_font_size("font_size", t, 14)

	# --- チェック系（枠は既定のまま、文字色/ON色だけ整える） ---
	for t in ["CheckButton", "CheckBox"]:
		th.set_color("font_color", t, C_TEXT)
		th.set_color("font_hover_color", t, Color.WHITE)
		th.set_color("font_pressed_color", t, C_ACCENT)
		th.set_font_size("font_size", t, 14)

	# --- 入力欄（LineEdit / TextEdit）：暗いフィールド＋フォーカスでアクセント枠 ---
	var field_bg := Color("#14161d")
	var le_normal := _sbf(field_bg, 6, C_BORDER, 1, 8, 6)
	var le_focus := _sbf(field_bg, 6, C_ACCENT, 1, 8, 6)
	th.set_stylebox("normal", "LineEdit", le_normal)
	th.set_stylebox("focus", "LineEdit", le_focus)
	th.set_stylebox("read_only", "LineEdit", _sbf(Color("#101218"), 6, C_BORDER, 1, 8, 6))
	th.set_color("font_color", "LineEdit", C_TEXT)
	th.set_color("font_placeholder_color", "LineEdit", Color(C_MUTED.r, C_MUTED.g, C_MUTED.b, 0.7))
	th.set_color("font_uneditable_color", "LineEdit", C_MUTED)
	th.set_color("caret_color", "LineEdit", C_ACCENT)
	th.set_color("selection_color", "LineEdit", Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.35))
	th.set_font_size("font_size", "LineEdit", 14)
	th.set_stylebox("normal", "TextEdit", le_normal)
	th.set_stylebox("focus", "TextEdit", le_focus)
	th.set_color("font_color", "TextEdit", C_TEXT)
	th.set_color("caret_color", "TextEdit", C_ACCENT)
	th.set_color("selection_color", "TextEdit", Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.35))
	th.set_color("current_line_color", "TextEdit", Color(1, 1, 1, 0.03))
	th.set_font_size("font_size", "TextEdit", 13)

	# --- ラベル / リッチテキスト ---
	th.set_color("font_color", "Label", C_TEXT)
	th.set_font_size("font_size", "Label", 14)
	th.set_color("default_color", "RichTextLabel", C_TEXT)
	th.set_font_size("normal_font_size", "RichTextLabel", 13)

	# --- プログレスバー（塗りは _color_bar で個別上書き） ---
	th.set_stylebox("background", "ProgressBar", _sbf(field_bg, 5))
	th.set_stylebox("fill", "ProgressBar", _sbf(C_ACCENT, 5))
	th.set_color("font_color", "ProgressBar", C_MUTED)

	# --- スライダー（トラック＝暗色、塗り＝アクセント） ---
	th.set_stylebox("slider", "HSlider", _sbf(field_bg, 3, C_BORDER, 1, 0, 0))
	th.set_stylebox("grabber_area", "HSlider", _sbf(C_ACCENT, 3))
	th.set_stylebox("grabber_area_highlight", "HSlider", _sbf(C_ACCENT.lightened(0.12), 3))

	# --- パネル面（ポップアップ/ダイアログの既定背景） ---
	var panel_sb := _sbf(Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 0.97), 8, C_BORDER, 1, 12, 12)
	th.set_stylebox("panel", "PanelContainer", panel_sb)
	th.set_stylebox("panel", "Panel", panel_sb)

	# --- ポップアップメニュー（右クリック文脈メニュー） ---
	th.set_stylebox("panel", "PopupMenu", _sbf(C_ELEV, 8, C_BORDER, 1, 6, 6))
	th.set_stylebox("hover", "PopupMenu", _sbf(Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.22), 5, Color(0, 0, 0, 0), 0, 6, 4))
	th.set_color("font_color", "PopupMenu", C_TEXT)
	th.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	th.set_color("font_separator_color", "PopupMenu", C_MUTED)
	th.set_font_size("font_size", "PopupMenu", 14)

	# --- セパレータ（細い枠線色のライン） ---
	var vsep := StyleBoxLine.new(); vsep.color = C_BORDER; vsep.vertical = true; vsep.thickness = 1
	var hsep := StyleBoxLine.new(); hsep.color = C_BORDER; hsep.vertical = false; hsep.thickness = 1
	th.set_stylebox("separator", "VSeparator", vsep)
	th.set_stylebox("separator", "HSeparator", hsep)

	# --- スクロールバー（統計パネル等） ---
	for sbt in ["VScrollBar", "HScrollBar"]:
		th.set_stylebox("scroll", sbt, _sbf(field_bg, 4))
		th.set_stylebox("grabber", sbt, _sbf(C_ELEV2, 4))
		th.set_stylebox("grabber_highlight", sbt, _sbf(C_MUTED, 4))
		th.set_stylebox("grabber_pressed", sbt, _sbf(C_ACCENT, 4))

	_theme = th

# ---------------------------------------------------------------
func _mk_panel() -> PanelContainer:
	var p := PanelContainer.new()
	if _theme != null:
		p.theme = _theme
	var sb := _sbf(PANEL_BG, 8, C_BORDER, 1, 14, 12)
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

	# 4段目: Process Flow（オプトイン）。ctx.processflows の先頭 PF を run_isolated で
	# 実行/停止し、lint（静的検査）診断をコンソールへ出す。PF 未登録なら friendly メッセージ。
	# 既存モデル（processflows 欠落／空）では何も自動実行しない＝従来挙動を一切変えない。
	var r4 := HBoxContainer.new(); r4.add_theme_constant_override("separation", 10); vb.add_child(r4)
	# サンプル・ライブラリ（getting-started 入口）。samples/index.json から項目を生成し、
	# 選択でそのモデルを既存の読込パス（_load_with_check→editor.load_model）で読み込み、
	# タイトル＋ドキュメント期待値（理論値）をコンソールへ出す＝「期待すべき数値」が即分かる。
	# 追加のみ・オプトインで、既定モデルにも自己検査にも一切影響しない。
	r4.add_child(_mini_label("📚 サンプル"))
	_sample_opt = OptionButton.new()
	_sample_opt.custom_minimum_size = Vector2(300, 32)
	_sample_opt.tooltip_text = "サンプルモデルを選択して読込（タイトル＋理論的な期待KPIをコンソールへ表示）"
	_populate_sample_menu()
	_sample_opt.item_selected.connect(_on_sample_selected)
	r4.add_child(_sample_opt)
	r4.add_child(VSeparator.new())
	r4.add_child(_mini_label("PF"))
	var pf_run_btn := _btn("▶ PF実行", _on_pf_run, 88)
	pf_run_btn.tooltip_text = "先頭の登録 Process Flow を run_isolated で実行（種/長さ欄を使用）"
	r4.add_child(pf_run_btn)
	var pf_stop_btn := _btn("⏹ PF停止", _on_pf_stop, 88)
	pf_stop_btn.tooltip_text = "共有 Sim をリセットし PF の残状態を消して中立へ戻す"
	r4.add_child(pf_stop_btn)
	var pf_lint_btn := _btn("🔍 PF検査", _on_pf_lint, 88)
	pf_lint_btn.tooltip_text = "先頭 PF の spec を静的検査（lint）し診断をコンソールへ出す"
	r4.add_child(pf_lint_btn)
	_pf_status_lbl = _mini_label("")
	r4.add_child(_pf_status_lbl)

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
	# 空/非数値のシフト入力は現在の作業者シフト値へ戻して拒否（0.0 への silent default をしない）。
	var cur: Dictionary = _current_shift_values()
	var ok_on: bool = _validate_num(_shift_on_edit, "シフトon", cur.on, "%.0f")
	var ok_off: bool = _validate_num(_shift_off_edit, "シフトoff", cur.off, "%.0f")
	var ok_p: bool = _validate_num(_shift_period_edit, "シフト周期", cur.period, "%.0f")
	if not (ok_on and ok_off and ok_p):
		return
	editor.set_operator_shift(
		_to_f(_shift_on_edit.text, 0.0),
		_to_f(_shift_off_edit.text, 0.0),
		_to_f(_shift_period_edit.text, 0.0))

## 現在の作業者シフト設定 {on, off, period} を先頭作業者から読む（未設定なら全て 0）。
## シフト入力が無効なときに「現在値へ戻す」ための復元元。
func _current_shift_values() -> Dictionary:
	var res := {"on": 0.0, "off": 0.0, "period": 0.0}
	if editor == null or not (editor.ctx is Dictionary):
		return res
	var ops = editor.ctx.get("operators", [])
	if ops is Array and not (ops as Array).is_empty():
		var op = (ops as Array)[0]
		if op != null and is_instance_valid(op):
			res.period = float(op.shift_period)
			if op.shift is Array and not (op.shift as Array).is_empty() and (op.shift as Array)[0] is Dictionary:
				var seg: Dictionary = (op.shift as Array)[0]
				res.on = float(seg.get("on", 0.0))
				res.off = float(seg.get("off", 0.0))
	return res

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
	if _theme != null:
		_context_menu.theme = _theme
	add_child(_context_menu)

# ユニット文脈メニュー（作業者/搬送者）。各項目 id は _on_unit_context_menu_id の match と対応。
const _UCTX_RENAME := 0
const _UCTX_DUPLICATE := 1
const _UCTX_DELETE := 2

func _build_unit_context_menu() -> void:
	_unit_context_menu = PopupMenu.new()
	_unit_context_menu.add_item("✎ リネーム", _UCTX_RENAME)
	_unit_context_menu.add_item("⧉ 複製", _UCTX_DUPLICATE)
	_unit_context_menu.add_separator()
	_unit_context_menu.add_item("🗑 削除", _UCTX_DELETE)
	_unit_context_menu.id_pressed.connect(_on_unit_context_menu_id)
	if _theme != null:
		_unit_context_menu.theme = _theme
	add_child(_unit_context_menu)

## Editor から右クリック（オブジェクト上）を受けてメニューを開く。
## 対象は既に Editor 側で選択済み。screen_pos はビューポート座標
## （埋め込みサブウィンドウ既定のため埋め込み Popup の position と一致）。
## 対象がユニット（作業者/搬送者）ならユニット専用メニュー、それ以外は FlowObject 用を出す。
func _on_context_requested(obj, screen_pos) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	_ctx_obj = obj
	var menu: PopupMenu = _unit_context_menu if (obj is Operator or obj is Transporter) else _context_menu
	menu.reset_size()
	menu.position = Vector2i(screen_pos)
	menu.popup()

## ユニット文脈メニューのアクション（リネーム/複製/削除）。対象を確実に選択状態にしてから
## Editor の per-unit API を呼ぶ（各操作は selected_unit を対象に push_undo する）。
func _on_unit_context_menu_id(id: int) -> void:
	if _ctx_obj == null or not is_instance_valid(_ctx_obj):
		return
	editor.select_unit(_ctx_obj)   # 対象ユニットを確実に選択状態へ
	match id:
		_UCTX_RENAME:
			_begin_rename_unit()
		_UCTX_DUPLICATE:
			editor.duplicate_selected_unit()
		_UCTX_DELETE:
			editor.delete_selected_unit()

## ユニットのリネーム開始：インスペクタの名前欄へフォーカスして全選択。
## 名前欄の確定は editor.rename_selected（_active() 経由でユニットにも効く）へ委ねる。
func _begin_rename_unit() -> void:
	if editor.selected_unit == null:
		return
	_insp_panel.visible = true
	_insp_panel.move_to_front()
	_name_edit.grab_focus()
	_name_edit.select_all()

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
	# 完全不透明（背後の3D/パネルを透かさない）＋アクセント枠で編集面を明示。
	var isb := _sbf(Color(C_PANEL.r, C_PANEL.g, C_PANEL.b, 1.0), 8, C_ACCENT, 2, 14, 12)
	_insp_panel.add_theme_stylebox_override("panel", isb)
	add_child(_insp_panel)
	# 編集モードでは実行専用の統計パネルを隠すので、その右上域をインスペクタが占有する。
	# 上部バー(1段)の直下へアンカー。左側は追加/CADツールバー＋HUDが占有できる。
	_place_panel(_insp_panel, "tr", 16, 64)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 5)
	_insp_panel.add_child(vb)

	vb.add_child(_header("インスペクタ"))

	var hn := HBoxContainer.new()
	var nl := Label.new(); nl.text = "名前"; nl.custom_minimum_size = Vector2(60, 0); hn.add_child(nl)
	_name_edit = LineEdit.new(); _name_edit.custom_minimum_size = Vector2(300, 0)
	_name_edit.text_submitted.connect(_on_name_submit)
	hn.add_child(_name_edit); vb.add_child(hn)

	_type_lbl = Label.new(); _type_lbl.text = "型: -"; vb.add_child(_type_lbl)
	_model_lbl = Label.new(); _model_lbl.text = "モデル: -"
	_model_lbl.add_theme_font_size_override("font_size", 12); vb.add_child(_model_lbl)

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

	# 資源ユニット専用区画（Operator/Transporter 選択時のみ表示。FlowObject 選択時は
	# visible=false でレイアウトから外れ、既存の FlowObject インスペクタ配置は不変）。
	_unit_box = VBoxContainer.new()
	_unit_box.add_theme_constant_override("separation", 4)
	_unit_box.visible = false
	vb.add_child(_unit_box)
	_unit_box.add_child(_sep_label("資源パラメータ"))
	var hs := HBoxContainer.new()
	hs.add_child(_mini_label("移動速度"))
	_u_speed_edit = _mini_edit(70)
	_u_speed_edit.text_submitted.connect(_on_unit_speed_submit)
	hs.add_child(_u_speed_edit)
	hs.add_child(_btn("速度適用", func(): _on_unit_speed_submit(""), 0))
	_unit_box.add_child(hs)
	# 作業者専用: シフト（on/off 秒・周期。周期0で常時稼働）。
	_unit_op_box = VBoxContainer.new()
	_unit_op_box.add_theme_constant_override("separation", 4)
	_unit_box.add_child(_unit_op_box)
	_unit_op_box.add_child(_sep_label("シフト（on/off秒・周期0で常時）"))
	var hsh := HBoxContainer.new()
	hsh.add_child(_mini_label("on"))
	_u_shift_on_edit = _mini_edit(56); _u_shift_on_edit.text_submitted.connect(_on_unit_shift_submit)
	hsh.add_child(_u_shift_on_edit)
	hsh.add_child(_mini_label("off"))
	_u_shift_off_edit = _mini_edit(56); _u_shift_off_edit.text_submitted.connect(_on_unit_shift_submit)
	hsh.add_child(_u_shift_off_edit)
	hsh.add_child(_mini_label("周期"))
	_u_shift_period_edit = _mini_edit(56); _u_shift_period_edit.text_submitted.connect(_on_unit_shift_submit)
	hsh.add_child(_u_shift_period_edit)
	_unit_op_box.add_child(hsh)
	_unit_op_box.add_child(_btn("シフト適用", func(): _on_unit_shift_submit(""), 0))
	# 搬送者専用: 容量/積載時間/投下時間/優先度。
	_unit_tr_box = VBoxContainer.new()
	_unit_tr_box.add_theme_constant_override("separation", 4)
	_unit_box.add_child(_unit_tr_box)
	var htc := HBoxContainer.new()
	htc.add_child(_mini_label("容量"))
	_u_cap_edit = _mini_edit(56); _u_cap_edit.text_submitted.connect(_on_unit_tr_submit)
	htc.add_child(_u_cap_edit)
	htc.add_child(_mini_label("優先度"))
	_u_prio_edit = _mini_edit(56); _u_prio_edit.text_submitted.connect(_on_unit_tr_submit)
	htc.add_child(_u_prio_edit)
	_unit_tr_box.add_child(htc)
	var htt := HBoxContainer.new()
	htt.add_child(_mini_label("積載時間"))
	_u_load_edit = _mini_edit(56); _u_load_edit.text_submitted.connect(_on_unit_tr_submit)
	htt.add_child(_u_load_edit)
	htt.add_child(_mini_label("投下時間"))
	_u_unload_edit = _mini_edit(56); _u_unload_edit.text_submitted.connect(_on_unit_tr_submit)
	htt.add_child(_u_unload_edit)
	_unit_tr_box.add_child(htt)
	_unit_tr_box.add_child(_btn("搬送パラメータ適用", func(): _on_unit_tr_submit(""), 0))

	# FlowObject 専用区画（ユニット選択時は _on_selection が丸ごと非表示にする）。
	# モデル割当・パラメータ・スクリプト・接続はフロー部品にのみ意味を持つ。
	_fo_only_box = VBoxContainer.new()
	_fo_only_box.add_theme_constant_override("separation", 5)
	vb.add_child(_fo_only_box)

	_fo_only_box.add_child(_btn("🧩 3Dモデルを割り当て…", _on_assign_model, 0))

	_fo_only_box.add_child(_sep_label("パラメータ (JSON)"))
	_params_edit = TextEdit.new()
	_params_edit.custom_minimum_size = Vector2(360, 60)
	_fo_only_box.add_child(_params_edit)
	_fo_only_box.add_child(_btn("パラメータ適用", _on_apply_params, 0))

	_fo_only_box.add_child(_sep_label("スクリプト (GDScript / extends LogicBase)"))
	_script_edit = TextEdit.new()
	_script_edit.custom_minimum_size = Vector2(360, 120)
	_script_edit.add_theme_font_size_override("font_size", 12)
	_fo_only_box.add_child(_script_edit)
	_fo_only_box.add_child(_btn("▶ スクリプト適用（ホットリロード）", _on_apply_script, 0))

	_fo_only_box.add_child(_sep_label("接続（出力ポート）"))
	var hc := HBoxContainer.new()
	_conn_opt = OptionButton.new(); _conn_opt.custom_minimum_size = Vector2(200, 0)
	hc.add_child(_conn_opt)
	hc.add_child(_btn("→ 接続", _on_connect, 0))
	hc.add_child(_btn("全解除", _on_clear_conn, 0))
	_fo_only_box.add_child(hc)
	# 出力エッジの編集リスト（1行1エッジ）: [port N] <名前>  × ▲ ▼。
	# ポート番号 = outputs 配列の添字＝ select_output の送出優先順。並べ替えで順を制御。
	_outputs_list = VBoxContainer.new()
	_outputs_list.add_theme_constant_override("separation", 2)
	_fo_only_box.add_child(_outputs_list)
	_insp_panel.reset_size()

## インスペクタ内の小見出し（ダッシュ無し・ミュート色）。
func _sep_label(t: String) -> Label:
	var l := Label.new(); l.text = t
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 12)
	return l

## パネル見出し：ミュートの小ラベル＋控えめなアクセント下線（統一スタイル）。
func _header(t: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new(); l.text = t
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 12)
	box.add_child(l)
	var line := ColorRect.new()
	line.color = Color(C_ACCENT.r, C_ACCENT.g, C_ACCENT.b, 0.45)
	line.custom_minimum_size = Vector2(0, 2)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(line)
	return box

## KPIタイル（小ミュート見出し＋大きな太字の値）を1枚生成する。
func _make_kpi_tile(caption: String) -> Dictionary:
	var tile := PanelContainer.new()
	tile.add_theme_stylebox_override("panel", _sbf(C_ELEV, 6, C_BORDER, 1, 10, 6))
	tile.custom_minimum_size = Vector2(110, 0)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	tile.add_child(v)
	var cap := Label.new(); cap.text = caption
	cap.add_theme_color_override("font_color", C_MUTED)
	cap.add_theme_font_size_override("font_size", 11)
	cap.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(cap)
	var val := Label.new(); val.text = "–"
	val.add_theme_color_override("font_color", C_TEXT)
	val.add_theme_font_size_override("font_size", 16)
	if _ui_font_bold != null:
		val.add_theme_font_override("font", _ui_font_bold)
	v.add_child(val)
	return {"tile": tile, "val": val}

func _mini_label(t: String) -> Label:
	var l := Label.new(); l.text = t
	l.add_theme_color_override("font_color", C_MUTED)
	l.add_theme_font_size_override("font_size", 12)
	return l

func _mini_edit(w: int) -> LineEdit:
	var e := LineEdit.new()
	e.custom_minimum_size = Vector2(w, 0)
	return e

func _on_pos_submit(_t: String = "") -> void:
	# FlowObject もユニット（Operator/Transporter）も座標編集可。selected_node() で一本化。
	var sel = editor.selected_node()
	if sel == null:
		return
	# 空/非数値は現在座標へ戻して拒否（0.0 への silent teleport をしない）。X/Z を各々検証。
	var ok_x: bool = _validate_num(_x_edit, "X座標", sel.position.x, "%.2f")
	var ok_z: bool = _validate_num(_z_edit, "Z座標", sel.position.z, "%.2f")
	if not (ok_x and ok_z):
		return
	editor.set_obj_position(_to_f(_x_edit.text), _to_f(_z_edit.text))

func _on_rot_submit(_t: String = "") -> void:
	var sel = editor.selected_node()
	if sel == null:
		return
	if not _validate_num(_rot_edit, "回転角", rad_to_deg(sel.rotation.y), "%.0f"):
		return
	editor.set_rotation_deg(_to_f(_rot_edit.text))

func _on_scale_submit(_t: String = "") -> void:
	if editor.selected == null:
		return
	# 空/非数値は現在縮尺へ戻して拒否（1.0 への silent teleport をしない）。
	if not _validate_num(_scale_edit, "縮尺", editor.selected.model_scale, "%.2f"):
		return
	editor.set_obj_scale(_to_f(_scale_edit.text, 1.0))

func _to_f(s: String, default_val: float = 0.0) -> float:
	var t := s.strip_edges()
	if t.is_valid_float():
		return t.to_float()
	return default_val

## 数値入力フィールドを検証する。空/非数値なら false を返し、フィールドを cur（対象の
## 現在値）へ fmt 書式で復元し、friendly な警告をコンソールへ出す。有効なら true を返し、
## 呼び出し側がその値を適用する。無効入力を 0.0/1.0 へ黙って倒さず、変更を拒否＝現在値維持。
func _validate_num(edit: LineEdit, field: String, cur: float, fmt: String = "%g") -> bool:
	var raw: String = edit.text
	if raw.strip_edges().is_valid_float():
		return true
	var restored: String = fmt % cur
	edit.text = restored
	Scripts.log_msg("⚠ %s: 入力『%s』は数値として無効のため変更を取り消し、現在値 %s に戻しました" % [field, raw, restored])
	return false

func _build_stats_panel() -> void:
	var panel := _mk_panel()
	panel.custom_minimum_size = Vector2(388, 0)
	add_child(panel)
	_place_panel(panel, "tr", 16, 12)   # 右上アンカー（右カラム上段＝ライブ状態）
	_stats_panel = panel
	var outer := VBoxContainer.new(); outer.add_theme_constant_override("separation", 8)
	panel.add_child(outer)
	# KPIヘッダ：ラベル小＋値大の統計タイルを 3×2 グリッドで整列。
	var kpi_grid := GridContainer.new()
	kpi_grid.columns = 3
	kpi_grid.add_theme_constant_override("h_separation", 6)
	kpi_grid.add_theme_constant_override("v_separation", 6)
	kpi_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var kpi_defs := [
		["out", "産出 (個)"], ["thr", "スループット (個/時)"], ["lead", "平均滞留 (秒)"],
		["wip", "仕掛 (現在)"], ["awip", "仕掛 (時間平均)"], ["free", "空き作業者"]]
	for d in kpi_defs:
		var tt := _make_kpi_tile(d[1])
		_kpi_tiles[d[0]] = tt.val
		kpi_grid.add_child(tt.tile)
	outer.add_child(kpi_grid)
	outer.add_child(HSeparator.new())
	# 設備/作業者ステータス＋ガントは行数がモデル依存で伸びるため、上限高のスクロール領域に
	# まとめて収める。これで統計パネル高が画面高(900)内で固定され、直下の滞留ヒストグラムと
	# 縦衝突しない。既定モデルでは設備(8)＋作業者(2)が全て同時表示され、ガントは直下
	# （必要ならスクロール）に置かれる。
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(372, 556)   # KPIタイル分の高さを差し引き、直下ヒストと縦衝突させない
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
	inner.add_child(_header("状態ガント（設備別タイムライン）"))
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
	vb.add_child(_header("滞留時間ヒストグラム"))
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
	vb.add_child(_header("コンソール / ログ"))
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
	vb.add_child(_header("時系列（スループット / WIP）"))
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

	if _theme != null:
		for dlg in [_model_dialog, _json_dialog, _csv_dialog, _script_dialog]:
			dlg.theme = _theme

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

# ---------------------------------------------------------------
# Process Flow（オプトイン）制御。editor.ctx.processflows の先頭レコードを対象にする。
# PF 未登録（processflows 欠落／空）のモデルでは friendly メッセージのみ＝従来挙動不変。
# ---------------------------------------------------------------
## 先頭 PF レコード {id, spec, bindings, flow} を返す（無ければ null）。
func _pf_first_record():
	if editor == null or not (editor.ctx is Dictionary):
		return null
	var pfs = (editor.ctx as Dictionary).get("processflows", [])
	if pfs is Array and not (pfs as Array).is_empty() and (pfs as Array)[0] is Dictionary:
		return (pfs as Array)[0]
	return null

## 先頭 PF を run_isolated で実行し、KPI（created/sunk/in_flight/avg_cycle_time）をコンソールへ。
func _on_pf_run() -> void:
	var rec = _pf_first_record()
	if rec == null:
		Scripts.log_msg("PF: 登録された Process Flow がありません（モデルに processflows を追加してください）")
		return
	var flow = (rec as Dictionary).get("flow", null)
	if flow == null:
		Scripts.log_msg("PF: フロー '%s' が構築されていません" % str((rec as Dictionary).get("id", "")))
		return
	var run_len: float = _to_f(_runlen_edit.text, 3600.0)
	var run_seed: int = int(_to_f(_seed_edit.text, float(Sim.seed)))
	var k: Dictionary = flow.run_isolated(run_len, run_seed)
	_pf_active = true
	var pfid: String = str((rec as Dictionary).get("id", ""))
	Scripts.log_msg("▶ PF '%s' 実行 (len=%.0f seed=%d)" % [pfid, run_len, run_seed])
	Scripts.log_msg("  KPI: created=%d sunk=%d in_flight=%d avg_cycle_time=%.4f" % [
		int(k.get("created", 0)), int(k.get("sunk", 0)),
		int(k.get("in_flight", 0)), float(k.get("avg_cycle_time", 0.0))])
	if _pf_status_lbl != null:
		_pf_status_lbl.text = "PF '%s': c=%d s=%d wip=%d ct=%.2f" % [
			pfid, int(k.get("created", 0)), int(k.get("sunk", 0)),
			int(k.get("in_flight", 0)), float(k.get("avg_cycle_time", 0.0))]

## PF 停止：run_isolated は同期完結だが共有 Sim には PF の残イベント/時刻が残る。
## 「停止」で Source 自走を復帰させ Sim をリセットして中立状態へ戻す。
func _on_pf_stop() -> void:
	var rec = _pf_first_record()
	if rec == null:
		Scripts.log_msg("PF: 登録された Process Flow がありません")
		return
	Sim.set_sources_enabled(true)
	Sim.reset_sim()
	Sim.running = false
	if _play_btn != null:
		_play_btn.text = "▶ 開始"
	_pf_active = false
	Scripts.log_msg("⏹ PF '%s' 停止（Sim をリセット）" % str((rec as Dictionary).get("id", "")))
	if _pf_status_lbl != null:
		_pf_status_lbl.text = "PF 停止"

## 先頭 PF の spec を静的検査（lint）し、各診断を1行ずつコンソールへ出す。
## clean（診断なし）なら friendly な空メッセージを出す。
func _on_pf_lint() -> void:
	var rec = _pf_first_record()
	if rec == null:
		Scripts.log_msg("PF検査: 登録された Process Flow がありません")
		return
	var spec: Dictionary = (rec as Dictionary).get("spec", {})
	var bindings: Dictionary = (rec as Dictionary).get("bindings", {})
	var diags: Array = ProcessFlow.lint(spec, bindings)
	var pfid: String = str((rec as Dictionary).get("id", ""))
	if diags.is_empty():
		Scripts.log_msg("🔍 PF検査 '%s': 診断なし（clean）" % pfid)
	else:
		Scripts.log_msg("🔍 PF検査 '%s': %d 件の診断" % [pfid, diags.size()])
		for d in diags:
			Scripts.log_msg("  [%s] %s @%s: %s" % [
				str((d as Dictionary).get("severity", "")), str((d as Dictionary).get("code", "")),
				str((d as Dictionary).get("activity_id", "")), str((d as Dictionary).get("message", ""))])
	if _pf_status_lbl != null:
		_pf_status_lbl.text = "PF検査: %d件" % diags.size()

# ---------------------------------------------------------------
# サンプル・ライブラリ（getting-started 入口）
#   samples/index.json を ModelIO.list_samples() で読み、OptionButton を生成する。
#   選択で当該モデルを既存の読込パス（_load_with_check→editor.load_model）で読み込み、
#   同梱の meta.expected（理論値）をコンソールへ出す＝「期待すべき数値」が即分かる。
#   全て追加のみ・オプトインで、既定モデル/自己検査には一切影響しない。
# ---------------------------------------------------------------
## サンプル登録簿（samples/index.json）から OptionButton の項目を生成する。
## 先頭は選択不可のプレースホルダ（選択しても何も起きない）。各項目 metadata に sample id。
func _populate_sample_menu() -> void:
	if _sample_opt == null:
		return
	_sample_opt.clear()
	_sample_opt.add_item("📚 サンプルを選択…")
	_sample_opt.set_item_disabled(0, true)
	_sample_opt.set_item_metadata(0, "")
	var samples: Array = io.list_samples() if io != null else []
	for e in samples:
		if not (e is Dictionary):
			continue
		var rec: Dictionary = e
		var idx: int = _sample_opt.item_count
		_sample_opt.add_item(str(rec.get("title", rec.get("id", "sample"))))
		_sample_opt.set_item_metadata(idx, str(rec.get("id", "")))
	_sample_opt.select(0)

## サンプル選択：id からパスを解決し、既存の読込パスでモデルを読み込む。
## 読込後にタイトル＋ドキュメント期待値（理論値）をコンソールへ出す。
## 選択状態はプレースホルダへ戻し、同一サンプルの再読込を許可する（select は信号を出さない）。
func _on_sample_selected(idx: int) -> void:
	var sid: String = str(_sample_opt.get_item_metadata(idx))
	_sample_opt.select(0)
	if sid == "":
		return
	if io == null:
		Scripts.log_msg("⚠ サンプル: ModelIO が未初期化です")
		return
	var path: String = io.sample_path(sid)
	if path == "":
		Scripts.log_msg("⚠ サンプルが見つかりません: %s" % sid)
		return
	# 期待値メタは読込前に取得（migrate 済み dict は meta ブロックを保持する）。
	var m: Dictionary = io.load_sample(sid)
	var meta: Dictionary = {}
	if m.get("meta", null) is Dictionary:
		meta = m.get("meta")
	# 既存のモデル読込パスで読み込む（スクリプト含有時はセキュリティ確認ダイアログを経由）。
	_load_with_check(path)
	_log_sample_expected(sid, meta)

## サンプルのタイトル・概要・期待値（理論値）をコンソールへ整形出力する。
## 「期待すべき数値」が即座に読めるよう、meta.expected の各項目を1行ずつ出す。
func _log_sample_expected(sid: String, meta: Dictionary) -> void:
	var title: String = str(meta.get("title", sid))
	Scripts.log_msg("📚 サンプル読込: %s" % title)
	var desc: String = str(meta.get("description", ""))
	if desc != "":
		Scripts.log_msg("  概要: %s" % desc)
	var expected = meta.get("expected", null)
	if expected is Dictionary and not (expected as Dictionary).is_empty():
		Scripts.log_msg("  期待値（理論値・ドキュメント）:")
		for k in (expected as Dictionary).keys():
			Scripts.log_msg("    %s = %s" % [str(k), _fmt_expected_val((expected as Dictionary)[k])])
	else:
		Scripts.log_msg("  （このサンプルには期待値メタがありません）")
	Scripts.log_msg("  ▶ 開始で実測し、上記の理論値に一致することを確認できます（長期実行＋warmup 推奨）。")
	Scripts.log_msg("  ヘッドレス再現: TUTORIAL.md / samples/README.md を参照。")

## 期待値の値を1行表示用に整形する（辞書/配列は JSON、数値/文字列はそのまま）。
func _fmt_expected_val(v) -> String:
	if v is Dictionary or v is Array:
		return JSON.stringify(v)
	return str(v)

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
	_insp_panel.visible = on and (editor.selected != null or editor.selected_unit != null)
	if _insp_panel.visible:
		_insp_panel.move_to_front()   # 常に最前面で完全に読める状態を保証

# ---------------------------------------------------------------
# 編集操作
# ---------------------------------------------------------------
func _on_add(type_str: String) -> void:
	# クリックで設置：配置モードへ入り、次の地面クリックで設置する。
	editor.begin_place(type_str)

func _on_delete() -> void:
	# ユニット（作業者/搬送者）選択時は「その」ユニットを削除（Delete キーと同じ規律）。
	if editor.selected_unit != null:
		editor.delete_selected_unit()
	else:
		editor.delete_selected()

func _on_name_submit(txt: String) -> void:
	# FlowObject もユニット（Operator/Transporter）も rename_selected が _active() で扱う。
	if editor.selected != null or editor.selected_unit != null:
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
	var raw: String = _params_edit.text.strip_edges()
	if raw == "":
		Scripts.log_msg("⚠ パラメータ: 入力が空です（変更なし）")
		return
	# JSON をパース。パース失敗や非オブジェクトは「壊れた入力」→ 部分適用せず理由を提示する。
	var jp := JSON.new()
	var perr: int = jp.parse(raw)
	if perr != OK:
		Scripts.log_msg("⚠ パラメータJSON解析エラー（%d行目付近）: %s" % [jp.get_error_line(), jp.get_error_message()])
		return
	if typeof(jp.data) != TYPE_DICTIONARY:
		Scripts.log_msg("⚠ パラメータJSONはオブジェクト（{ \"キー\": 値, … }）である必要があります")
		return
	var input: Dictionary = jp.data
	# 適用前後の既知パラメータ集合から入力キーを「反映(applied)」「無視/不明(ignored)」に仕分ける。
	# typo キー（例 proces_time）は known に無いので ignored に出る＝黙って捨てない。
	var before: Dictionary = editor.selected.get_params()
	editor.apply_params(input)
	var after: Dictionary = editor.selected.get_params()
	var cls: Dictionary = _classify_params(before, after, input)
	var applied: Array = cls.applied
	var ignored: Array = cls.ignored
	var msg: String = "パラメータ適用: %s ｜ 反映(%d): %s" % [
		editor.selected.obj_name, applied.size(),
		(", ".join(applied) if not applied.is_empty() else "なし")]
	if not ignored.is_empty():
		msg += " ｜ 無視/不明(%d): %s" % [ignored.size(), ", ".join(ignored)]
	Scripts.log_msg(msg)

## パラメータ入力キーを「反映(applied)」と「無視/不明(ignored)」に仕分ける純関数。
## 既知キー = 適用前後の get_params キーの和集合（arrival_schedule 等の条件付きキーも拾える）。
## 未知キー（typo 等）は ignored に出し、黙って捨てないことを保証する。
func _classify_params(before: Dictionary, after: Dictionary, input: Dictionary) -> Dictionary:
	var known := {}
	for k in before.keys(): known[k] = true
	for k in after.keys(): known[k] = true
	var applied: Array = []
	var ignored: Array = []
	for k in input.keys():
		if known.has(k):
			applied.append(str(k))
		else:
			ignored.append(str(k))
	return {"applied": applied, "ignored": ignored}

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
	# 資源ユニット（Operator/Transporter）か FlowObject かで編集面を切り替える。
	# ユニットは name / 変形（座標・回転）のみ編集可。FlowObject 専用区画は隠す。
	var is_unit: bool = obj is Operator or obj is Transporter
	_name_edit.text = obj.obj_name
	_type_lbl.text = "型: %s   id: %s" % [obj.type_name(), obj.id]
	# 複数選択（FlowObject）時は主対象のインスペクタを出しつつ、選択数を簡潔に表示する。
	# 単一/未選択（selection.size()<=1）では何も付かず従来表示のまま（バイト同一）。
	if editor.selection.size() > 1:
		_type_lbl.text = "【%d個選択】 %s" % [editor.selection.size(), _type_lbl.text]
	_model_lbl.text = "モデル: %s" % (obj.model_path if obj.model_path != "" else "(既定)")
	_fill_transform(obj)
	_fo_only_box.visible = not is_unit
	_proc_opt_row.visible = (not is_unit) and (obj is Processor)
	_unit_box.visible = is_unit
	if is_unit:
		_fill_unit_params(obj)
		return
	_params_edit.text = JSON.stringify(obj.get_params(), "\t")
	_script_edit.text = obj.script_source if obj.script_source != "" else Scripts.DEFAULT_TEMPLATE
	_refresh_conn_options(obj)
	# Processor 簡易オプションの現在値反映（信号を出さずに設定）
	if obj is Processor:
		var p: Dictionary = obj.get_params()
		_transport_out_chk.set_pressed_no_signal(bool(p.get("transport_out", false)))
		_mtbf_basis_opt.select(1 if str(p.get("mtbf_basis", "operating")) == "calendar" else 0)

func _fill_transform(obj) -> void:
	_x_edit.text = "%.2f" % obj.position.x
	_z_edit.text = "%.2f" % obj.position.z
	_rot_edit.text = "%.0f" % rad_to_deg(obj.rotation.y)
	# 資源ユニットは model_scale を持たない（縮尺は既定 1.00 表示・編集は FlowObject のみ）。
	var is_unit: bool = obj is Operator or obj is Transporter
	_scale_edit.text = "%.2f" % (1.0 if is_unit else obj.model_scale)

## 資源ユニット（Operator/Transporter）の型別パラメータをインスペクタへ反映する。
## 移動速度は共通。作業者はシフト行、搬送者は容量/時間/優先度行を出し分ける。
func _fill_unit_params(obj) -> void:
	_u_speed_edit.text = "%.2f" % obj.move_speed
	var is_op: bool = obj is Operator
	_unit_op_box.visible = is_op
	_unit_tr_box.visible = obj is Transporter
	if is_op:
		if obj.shift.is_empty():
			_u_shift_on_edit.text = "0"
			_u_shift_off_edit.text = "0"
			_u_shift_period_edit.text = "0"
		else:
			_u_shift_on_edit.text = "%.0f" % float(obj.shift[0].get("on", 0.0))
			_u_shift_off_edit.text = "%.0f" % float(obj.shift[0].get("off", 0.0))
			_u_shift_period_edit.text = "%.0f" % obj.shift_period
	else:
		_u_cap_edit.text = "%d" % int(obj.capacity)
		_u_prio_edit.text = "%d" % int(obj.priority)
		_u_load_edit.text = "%.2f" % obj.load_time
		_u_unload_edit.text = "%.2f" % obj.unload_time

## 移動速度の確定。空/非数値は現在値へ復元し警告（FlowObject 座標欄と同じ規律）。
func _on_unit_speed_submit(_t: String = "") -> void:
	var sel = editor.selected_node()
	if sel == null or not (sel is Operator or sel is Transporter):
		return
	if not _validate_num(_u_speed_edit, "移動速度", sel.move_speed, "%.2f"):
		return
	editor.set_unit_speed(_to_f(_u_speed_edit.text, sel.move_speed))

## 選択中の作業者のシフト確定。on/off/周期の各欄を検証し、いずれか無効なら現在値へ復元し中止。
func _on_unit_shift_submit(_t: String = "") -> void:
	var sel = editor.selected_node()
	if not (sel is Operator):
		return
	var on_cur: float = (float(sel.shift[0].get("on", 0.0)) if not sel.shift.is_empty() else 0.0)
	var off_cur: float = (float(sel.shift[0].get("off", 0.0)) if not sel.shift.is_empty() else 0.0)
	if not _validate_num(_u_shift_on_edit, "シフトon", on_cur, "%.0f"):
		return
	if not _validate_num(_u_shift_off_edit, "シフトoff", off_cur, "%.0f"):
		return
	if not _validate_num(_u_shift_period_edit, "シフト周期", sel.shift_period, "%.0f"):
		return
	editor.set_selected_operator_shift(
		_to_f(_u_shift_on_edit.text), _to_f(_u_shift_off_edit.text), _to_f(_u_shift_period_edit.text))

## 選択中の搬送者パラメータ確定。容量/優先度/積載時間/投下時間を検証し、
## いずれか無効なら現在値へ復元し中止。全て有効なら1回の undo で一括適用する。
func _on_unit_tr_submit(_t: String = "") -> void:
	var sel = editor.selected_node()
	if not (sel is Transporter):
		return
	if not _validate_num(_u_cap_edit, "容量", float(sel.capacity), "%.0f"):
		return
	if not _validate_num(_u_prio_edit, "優先度", float(sel.priority), "%.0f"):
		return
	if not _validate_num(_u_load_edit, "積載時間", sel.load_time, "%.2f"):
		return
	if not _validate_num(_u_unload_edit, "投下時間", sel.unload_time, "%.2f"):
		return
	editor.set_transporter_params(
		int(round(_to_f(_u_cap_edit.text, sel.capacity))),
		_to_f(_u_load_edit.text, sel.load_time),
		_to_f(_u_unload_edit.text, sel.unload_time),
		int(round(_to_f(_u_prio_edit.text, sel.priority))))

func _on_transform_changed(obj) -> void:
	if obj != null and (obj == editor.selected or obj == editor.selected_unit):
		_fill_transform(obj)

func _refresh_conn_options(obj) -> void:
	_conn_opt.clear()
	# 接続先候補は can_connect が許す先だけを掲載する（自己ループ・重複エッジ・
	# 受理不能先＝ Source 等を除外）。無効な配線をそもそも選べないようにする。
	for o in editor.ctx.flow_objects:
		if o == obj:
			continue
		if editor.can_connect(obj, o).ok:
			var i := _conn_opt.item_count
			_conn_opt.add_item("%s (%s)" % [o.obj_name, o.id])
			_conn_opt.set_item_metadata(i, o.id)
	_rebuild_outputs_list(obj)

## 出力エッジを1行1エッジで並べ直す。各行 = [port N] <接続先名> ▲ ▼ ×。
## ▲/▼ は reorder（ポート順＝ select_output 送出順）、× は remove_output（単一解除）。
## ポート番号は outputs 配列の添字で、3Dの矢印ラベルと一致する。
func _rebuild_outputs_list(obj) -> void:
	if _outputs_list == null:
		return
	for c in _outputs_list.get_children():
		c.queue_free()
	if obj == null:
		return
	var n: int = obj.outputs.size()
	if n == 0:
		var empty := Label.new()
		empty.text = "出力先: なし"
		empty.add_theme_color_override("font_color", C_MUTED)
		empty.add_theme_font_size_override("font_size", 12)
		_outputs_list.add_child(empty)
		return
	for idx in range(n):
		var t = obj.outputs[idx]
		var tname: String = (t.obj_name if (t != null and is_instance_valid(t)) else "?")
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var port := Label.new()
		port.text = "[port %d]" % idx
		port.add_theme_color_override("font_color", C_ACCENT)
		port.add_theme_font_size_override("font_size", 12)
		port.custom_minimum_size = Vector2(60, 0)
		row.add_child(port)
		var nm := Label.new()
		nm.text = tname
		nm.add_theme_color_override("font_color", C_TEXT)
		nm.add_theme_font_size_override("font_size", 12)
		nm.custom_minimum_size = Vector2(150, 0)
		nm.clip_text = true
		row.add_child(nm)
		# bind(idx) でポート番号を確定キャプチャ（ループ変数の遅延束縛を避ける）。
		var up := _btn("▲", editor.move_output_up.bind(idx), 0)
		up.disabled = idx == 0
		up.tooltip_text = "ポートを1つ上へ"
		row.add_child(up)
		var down := _btn("▼", editor.move_output_down.bind(idx), 0)
		down.disabled = idx == n - 1
		down.tooltip_text = "ポートを1つ下へ"
		row.add_child(down)
		var del := _btn("×", editor.remove_output.bind(idx), 0)
		del.tooltip_text = "このエッジを解除"
		row.add_child(del)
		_outputs_list.add_child(row)

func _on_model_rebuilt() -> void:
	_rebuild_stats_rows()
	if _chart != null:
		_chart.reset()
	_last_sample_t = -1.0
	_last_total = 0
	if editor.selected != null:
		_on_selection(editor.selected)
	elif editor.selected_unit != null:
		_on_selection(editor.selected_unit)

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
	_stats_vb.add_child(_header("設備ステータス / 稼働率"))
	for obj in editor.ctx.get("flow_objects", []):
		var row := _mk_row(obj.obj_name, true)
		row.st.obj = obj
		_stats_vb.add_child(row.c)
		_rows.append({"obj": obj, "name": row.name, "bar": row.bar, "io": row.io, "st": row.st})
	_stats_vb.add_child(_header("作業者 稼働率"))
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
		io_lbl.add_theme_color_override("font_color", C_MUTED)
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
	if not _kpi_tiles.is_empty():
		_kpi_tiles["out"].text = "%d" % out_total
		_kpi_tiles["thr"].text = "%.1f" % thr
		_kpi_tiles["lead"].text = "%.1f" % avg
		_kpi_tiles["wip"].text = "%d" % wip
		_kpi_tiles["awip"].text = "%.1f" % Sim.avg_wip()
		_kpi_tiles["free"].text = "%d" % freeop
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
		# 稼働率メーター＝青の逐次ランプ（低=淡青→健全=アクセント青）、
		# 高負荷(≥80%)のみ琥珀でボトルネックを示す（状態パレットと整合）。
		_bar_sb = [
			_mk_bar_sb(Color("#3d6ba8")),
			_mk_bar_sb(C_ACCENT),
			_mk_bar_sb(Color("#f0b429")),
		]
	var idx: int = 0 if util < 40.0 else (1 if util < 80.0 else 2)
	if bar.get_theme_stylebox("fill") != _bar_sb[idx]:
		bar.add_theme_stylebox_override("fill", _bar_sb[idx])
