extends Node
## 乱数ストリーム管理（autoload "Rng"）。
## 目的別・設備別に独立した RandomNumberGenerator を配り、マスターシードから決定的に導出する。
## reset(seed) で全ストリームを作り直すことで、同一シード=同一結果（再現性）を保証する。

var master_seed: int = 12345
var _streams: Dictionary = {}   # key(String) -> RandomNumberGenerator

func reset(seed_value: int) -> void:
	master_seed = seed_value
	_streams.clear()

func stream(key: String) -> RandomNumberGenerator:
	var r: RandomNumberGenerator = _streams.get(key, null)
	if r == null:
		r = RandomNumberGenerator.new()
		# マスターシードとキーから決定的にシードを導出。
		# GDScript の hash() はバージョン間で不安定なため、自前の安定ハッシュ
		# （FNV-1a 64bit 相当）でバイト列を畳み込む。
		r.seed = _stable_seed("%d::%s" % [master_seed, key])
		_streams[key] = r
	return r

## FNV-1a 64bit ハッシュ（GDScript hash() 非依存の安定ハッシュ）。
## GDScript の int は 64bit 符号付きで、乗算/加算は 2 の補数で wrap するため決定的。
func _stable_seed(s: String) -> int:
	var h: int = -3750763034362895579   # 0xcbf29ce484222325 を符号付き64bitで表した値（FNV offset basis）
	const PRIME: int = 1099511628211    # 0x100000001b3（FNV prime）
	for b in s.to_utf8_buffer():
		h ^= int(b)
		h *= PRIME
	return h
