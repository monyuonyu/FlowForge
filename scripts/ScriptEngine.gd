extends Node
## スクリプト実行エンジン（autoload "Scripts"）。
## ユーザーの GDScript を実行時にコンパイルし、LogicBase インスタンスを生成する。
## ログ／エラーはコンソールに送る。

signal log_emitted(text)

var logs: Array = []
var objects_by_id: Dictionary = {}   # id -> FlowObject
var api: SimAPI
## 実行時(logic.call)の呼び出し前後を詳細ログするか。既定は静音。
## UI/自己テストから Scripts.verbose = true でトグルできる。
var verbose: bool = false

const DEFAULT_TEMPLATE := """extends LogicBase

# 使えるもの: obj（この設備） / sim（sim.now(), sim.log(), sim.rand() 等）
# 使いたいイベントだけ残して自由に編集してください。

func on_entry(item):
	pass
"""

func _ready() -> void:
	api = SimAPI.new()

func log_msg(msg) -> void:
	var line: String = "[t=%6.1f] %s" % [Sim.sim_time, str(msg)]
	logs.append(line)
	if logs.size() > 800:
		logs.pop_front()
	emit_signal("log_emitted", line)

func clear_log() -> void:
	logs.clear()

# --- id レジストリ（sim.find 用）---
func register_object(id: String, obj) -> void:
	objects_by_id[id] = obj

func clear_objects() -> void:
	objects_by_id.clear()

func find(id: String):
	return objects_by_id.get(id, null)

# --- コンパイル ---
## 戻り値: {"ok": bool, "instance": LogicBase or null, "error": String,
##          "error_line": int(推定, 無ければ-1), "message": String}
func compile(source: String, obj) -> Dictionary:
	if source.strip_edges() == "":
		return {"ok": true, "instance": null, "error": "", "error_line": -1, "message": ""}
	var nm := _name_of(obj)
	# 事前検証（未閉じ括弧 / extends LogicBase 有無 / インデント混在 等）で
	# 疑わしい行番号を推定する。GDScript.reload() は行番号を返さないため、
	# ここでの推定と、コンソールへの行番号つき本文出力で実用的に補う。
	var pre: Dictionary = _precheck(source)
	var gd := GDScript.new()
	gd.source_code = source
	var err: int = gd.reload()
	if err != OK:
		var eline: int = int(pre.get("line", -1))
		var m := "⚠ [%s] スクリプトのコンパイル失敗 (err=%d)。" % [nm, err]
		if eline > 0:
			m += " %d行目付近を確認してください。" % eline
		if str(pre.get("hint", "")) != "":
			m += " ヒント: %s" % str(pre["hint"])
		log_msg(m)
		_dump_source(source, eline)
		return {"ok": false, "instance": null, "error": m, "error_line": eline, "message": m}
	if not gd.can_instantiate():
		var m2 := "⚠ [%s] インスタンス化できません。" % nm
		log_msg(m2)
		_dump_source(source, int(pre.get("line", -1)))
		return {"ok": false, "instance": null, "error": m2, "error_line": int(pre.get("line", -1)), "message": m2}
	var inst = gd.new()
	if not (inst is LogicBase):
		var eline2: int = int(pre.get("line", -1))
		if eline2 <= 0:
			eline2 = _first_extends_line(source)
		var m3 := "⚠ [%s] スクリプトは `extends LogicBase` で始める必要があります。" % nm
		if eline2 > 0:
			m3 += " %d行目付近を確認してください。" % eline2
		log_msg(m3)
		_dump_source(source, eline2)
		return {"ok": false, "instance": null, "error": m3, "error_line": eline2, "message": m3}
	inst.obj = obj
	inst.sim = api
	log_msg("✔ [%s] スクリプトを適用しました。" % nm)
	return {"ok": true, "instance": inst, "error": "", "error_line": -1, "message": ""}

## 疑わしい行番号とヒントを推定する簡易事前検証。
## 戻り値: {"line": int(1始まり, 無ければ-1), "hint": String}
func _precheck(source: String) -> Dictionary:
	var lines := source.split("\n")
	# 1) extends LogicBase の有無
	var has_extends := false
	var extends_ok := false
	for ln in lines:
		var s := ln.strip_edges()
		if s.begins_with("extends "):
			has_extends = true
			if s == "extends LogicBase":
				extends_ok = true
			break
		# コメント/空行はスキップ、最初の実コードより前だけ見る
		if s != "" and not s.begins_with("#"):
			break
	if not has_extends:
		return {"line": 1, "hint": "先頭に `extends LogicBase` がありません。"}
	if not extends_ok:
		return {"line": _first_extends_line(source),
			"hint": "`extends LogicBase` である必要があります。"}
	# 2) 括弧の対応（( ) [ ] { }）
	var depth := 0
	var last_open_line := -1
	for i in range(lines.size()):
		var text := lines[i]
		# 文字列リテラルは大まかに除去（誤検出を減らす）
		var stripped := _strip_strings(text)
		for c in stripped:
			if c == "(" or c == "[" or c == "{":
				depth += 1
				last_open_line = i + 1
			elif c == ")" or c == "]" or c == "}":
				depth -= 1
				if depth < 0:
					return {"line": i + 1, "hint": "閉じ括弧が多すぎます（対応する開き括弧がありません）。"}
	if depth > 0:
		return {"line": last_open_line if last_open_line > 0 else lines.size(),
			"hint": "開いた括弧が閉じられていません。"}
	# 3) インデントのタブ/スペース混在
	for i in range(lines.size()):
		var t := lines[i]
		if t.strip_edges() == "":
			continue
		var lead := ""
		for c in t:
			if c == " " or c == "\t":
				lead += c
			else:
				break
		if lead.find(" ") != -1 and lead.find("\t") != -1:
			return {"line": i + 1, "hint": "インデントにタブとスペースが混在しています。"}
	return {"line": -1, "hint": ""}

func _strip_strings(text: String) -> String:
	var out := ""
	var in_str := false
	var quote := ""
	for c in text:
		if in_str:
			if c == quote:
				in_str = false
			continue
		if c == "\"" or c == "'":
			in_str = true
			quote = c
			continue
		if c == "#":
			break   # 行コメント以降は無視
		out += c
	return out

func _first_extends_line(source: String) -> int:
	var lines := source.split("\n")
	for i in range(lines.size()):
		if lines[i].strip_edges().begins_with("extends "):
			return i + 1
	return 1

## スクリプト本文を行番号つきでコンソールへ出力。疑わしい行には矢印を付す。
func _dump_source(source: String, suspect: int) -> void:
	log_msg("── スクリプト本文（行番号つき）──")
	var lines := source.split("\n")
	for i in range(lines.size()):
		var n := i + 1
		var mark := "→" if n == suspect else " "
		log_msg("%s %3d| %s" % [mark, n, lines[i]])
	if suspect > 0:
		log_msg("── %d行目付近を確認してください ──" % suspect)
	else:
		log_msg("── 上記本文と、標準出力の Parse Error / SCRIPT ERROR を突き合わせてください ──")

func _name_of(obj) -> String:
	if obj != null and "obj_name" in obj:
		return str(obj.obj_name)
	return "?"
