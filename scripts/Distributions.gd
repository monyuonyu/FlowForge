extends Node
## 確率分布（autoload "Dist"）。
## すべて RandomNumberGenerator を受け取り、決定的・再現可能にサンプリングする。
## 分布は Dictionary:
##   {"type":"const",   "a": value}
##   {"type":"exp",     "a": mean}
##   {"type":"uniform", "a": min, "b": max}
##   {"type":"normal",  "a": mean, "b": stddev}   ← 切断正規（棄却法で非負）
##   {"type":"triangular","a": min, "b": mode, "c": max}

func uniform(rng: RandomNumberGenerator, a: float, b: float) -> float:
	return a + rng.randf() * (b - a)

func exponential(rng: RandomNumberGenerator, mean: float) -> float:
	if mean <= 0.0:
		return 0.0
	return -mean * log(1.0 - rng.randf())

func _normal_raw(rng: RandomNumberGenerator, mean: float, sd: float) -> float:
	var u1: float = 1.0 - rng.randf()
	var u2: float = 1.0 - rng.randf()
	var z: float = sqrt(-2.0 * log(u1)) * cos(TAU * u2)
	return mean + sd * z

## 切断正規（負値は棄却して引き直す）。平均の上方バイアスを避ける。
func normal(rng: RandomNumberGenerator, mean: float, sd: float) -> float:
	if sd <= 0.0:
		return max(0.0, mean)
	for _i in range(64):
		var v: float = _normal_raw(rng, mean, sd)
		if v >= 0.0:
			return v
	return max(0.0, mean)

func triangular(rng: RandomNumberGenerator, a: float, m: float, b: float) -> float:
	var u: float = rng.randf()
	var fc: float = 0.0
	if b > a:
		fc = (m - a) / (b - a)
	if u < fc:
		return a + sqrt(u * (b - a) * (m - a))
	return b - sqrt((1.0 - u) * (b - a) * (b - m))

## 対数正規分布。実尺度の平均 m と標準偏差 sd を受け取り、
## 基礎正規の μ,σ を導出して exp(normal(μ,σ)) を返す（常に非負）。
func lognormal(rng: RandomNumberGenerator, m: float, sd: float) -> float:
	if m <= 0.0:
		return 0.0
	var sd2: float = max(0.0, sd)
	var sigma2: float = log(1.0 + (sd2 * sd2) / (m * m))
	var sigma: float = sqrt(sigma2)
	var mu: float = log(m) - 0.5 * sigma2
	# exp なので非負保証。切断せず生の正規を使う。
	return exp(_normal_raw(rng, mu, sigma))

## ワイブル分布。a=形状 k, b=尺度 λ。 λ*(-ln(1-U))^(1/k)
func weibull(rng: RandomNumberGenerator, k: float, lam: float) -> float:
	if k <= 0.0 or lam <= 0.0:
		return 0.0
	var u: float = 1.0 - rng.randf()   # (0,1] で ln 安全
	return lam * pow(-log(u), 1.0 / k)

## ガンマ分布（Marsaglia-Tsang法）。a=形状 k(>0), b=尺度 θ。平均 = kθ。
## k<1 は gamma(k) = gamma(k+1) * U^(1/k) の補正で処理。rng のみ使用し決定的。
func gamma(rng: RandomNumberGenerator, k: float, theta: float) -> float:
	if k <= 0.0 or theta <= 0.0:
		return 0.0
	if k < 1.0:
		var u0: float = rng.randf()
		if u0 <= 0.0:
			u0 = 1e-12
		return gamma(rng, k + 1.0, theta) * pow(u0, 1.0 / k)
	var d: float = k - 1.0 / 3.0
	var c: float = 1.0 / sqrt(9.0 * d)
	for _i in range(1024):
		var x: float = _normal_raw(rng, 0.0, 1.0)
		var v: float = 1.0 + c * x
		if v <= 0.0:
			continue
		v = v * v * v
		var u: float = rng.randf()
		var x2: float = x * x
		if u < 1.0 - 0.0331 * x2 * x2:
			return d * v * theta
		if log(u) < 0.5 * x2 + d * (1.0 - v + log(v)):
			return d * v * theta
	return d * theta   # 極端に稀なフォールバック（平均 dθ 近傍）

## 経験分布。a=値配列から一様抽出。b があれば対応する重み配列で重み付き抽出。
func empirical(rng: RandomNumberGenerator, values: Array, weights: Array = []) -> float:
	if values.is_empty():
		return 0.0
	if weights.size() == values.size():
		var total: float = 0.0
		for w in weights:
			total += max(0.0, float(w))
		if total > 0.0:
			var r: float = rng.randf() * total
			var acc: float = 0.0
			for i in range(values.size()):
				acc += max(0.0, float(weights[i]))
				if r < acc:
					return float(values[i])
			return float(values[values.size() - 1])
	var idx: int = rng.randi() % values.size()
	return float(values[idx])

## 連続経験分布。a=昇順データ配列。区分線形の逆CDF（順序統計量の線形補間）で
## 連続値をサンプリングする。U~uniform(0,1) → 位置 p=U*(n-1) → 隣接する順序統計量を
## 線形補間。値域は [a[0], a[n-1]] に収まり、決定的（rng のみ使用）。
func empirical_cont(rng: RandomNumberGenerator, values: Array) -> float:
	var n: int = values.size()
	if n == 0:
		return 0.0
	if n == 1:
		return float(values[0])
	var u: float = rng.randf()
	var p: float = u * float(n - 1)
	var lo: int = int(floor(p))
	if lo >= n - 1:
		return float(values[n - 1])
	var frac: float = p - float(lo)
	return float(values[lo]) + frac * (float(values[lo + 1]) - float(values[lo]))

## Dictionary からサンプリング（時間なので非負クランプ）
func sample(d: Dictionary, rng: RandomNumberGenerator) -> float:
	var t: String = str(d.get("type", "const"))
	var v: float = 1.0
	match t:
		"const":
			v = float(d.get("a", 1.0))
		"exp":
			v = exponential(rng, float(d.get("a", 1.0)))
		"uniform":
			v = uniform(rng, float(d.get("a", 0.0)), float(d.get("b", 1.0)))
		"normal":
			v = normal(rng, float(d.get("a", 1.0)), float(d.get("b", 0.1)))
		"triangular":
			v = triangular(rng, float(d.get("a", 0.0)), float(d.get("b", 1.0)), float(d.get("c", 2.0)))
		"lognormal":
			v = lognormal(rng, float(d.get("a", 1.0)), float(d.get("b", 0.1)))
		"weibull":
			v = weibull(rng, float(d.get("a", 1.0)), float(d.get("b", 1.0)))
		"gamma":
			v = gamma(rng, float(d.get("a", 1.0)), float(d.get("b", 1.0)))
		"empirical":
			v = empirical(rng, d.get("a", []) as Array, d.get("b", []) as Array)
		"empirical_cont":
			v = empirical_cont(rng, d.get("a", []) as Array)
		_:
			v = float(d.get("a", 1.0))
	return max(0.0, v)

func describe(d: Dictionary) -> String:
	match str(d.get("type", "const")):
		"const": return "定数 %.1f" % float(d.get("a", 1.0))
		"exp": return "指数 平均%.1f" % float(d.get("a", 1.0))
		"uniform": return "一様 %.1f〜%.1f" % [float(d.get("a", 0.0)), float(d.get("b", 1.0))]
		"normal": return "正規 μ%.1f σ%.1f" % [float(d.get("a", 1.0)), float(d.get("b", 0.1))]
		"triangular": return "三角 %.1f/%.1f/%.1f" % [float(d.get("a", 0.0)), float(d.get("b", 1.0)), float(d.get("c", 2.0))]
		"lognormal": return "対数正規 平均%.1f σ実尺度%.1f" % [float(d.get("a", 1.0)), float(d.get("b", 0.1))]
		"weibull": return "ワイブル k%.1f λ%.1f" % [float(d.get("a", 1.0)), float(d.get("b", 1.0))]
		"gamma": return "ガンマ k%.1f θ%.1f" % [float(d.get("a", 1.0)), float(d.get("b", 1.0))]
		"empirical": return "経験 n%d" % (d.get("a", []) as Array).size()
		"empirical_cont": return "連続経験 n%d" % (d.get("a", []) as Array).size()
		_: return str(d.get("type", "const"))
