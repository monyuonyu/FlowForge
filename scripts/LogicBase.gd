extends RefCounted
class_name LogicBase
## ユーザースクリプトの基底クラス。
## 各設備に割り当てる GDScript は `extends LogicBase` で書き、
## 必要なイベントメソッドだけをオーバーライドする。
##
## 利用可能な変数:
##   obj … この設備（FlowObject）。obj.obj_name / obj.input_count 等
##   sim … シミュレーションAPI（SimAPI）。sim.now() / sim.log() / sim.rand() 等
##
## 例:
##   extends LogicBase
##   func on_create(item):
##       item.set_label("priority", sim.rand_int(1, 3))
##   func process_time():
##       return sim.normal(6.0, 1.0)
##   func select_output(item):
##       return 0 if item.item_type == 0 else 1

var obj = null   # FlowObject
var sim = null   # SimAPI

# --- イベント（何もしないのが既定）---
func on_reset() -> void: pass
func on_create(_item) -> void: pass
func on_entry(_item) -> void: pass
func on_exit(_item) -> void: pass
func on_process_start(_item) -> void: pass
func on_process_finish(_item) -> void: pass

# --- 値のオーバーライド（負数を返すと既定の分布を使用）---
func process_time() -> float: return -1.0
func interarrival() -> float: return -1.0

# --- 出力ポート選択（-1 で既定：空いている先頭ポート）---
func select_output(_item) -> int: return -1

# --- 便利メソッド ---
func log(m) -> void:
	if sim != null:
		sim.log(m)

func now() -> float:
	return sim.now() if sim != null else 0.0
