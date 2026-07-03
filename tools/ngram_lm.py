"""Shared character n-gram LM code for Ghbdtn.

Defines the binary model format (.bin) produced by train_ngram.py and consumed
by Sources/Ghbdtn/Core/NgramModel.swift. The Python scorer here mirrors the
Swift scorer exactly (same quantized tables, same backoff chain), so offline
threshold tuning transfers 1:1 to the app.

Model: character 4-gram LM with interpolated Kneser-Ney smoothing, serialized
ARPA-style (per-order probability tables + per-context backoff weights).
Words are padded as ^^^word$ ('^' start marker never predicted, '$' end
marker predicted like a character).

Binary layout (little-endian):
    magic       4 bytes  b"GNG1"
    lang        2 bytes  ascii ("en", "ru")
    alphaCount  u8
    alphabet    alphaCount * u16 (UTF-16 code units; '^' and '$' included)
    quantComplete 101 * f32   (percentiles 0..100 of per-char avg logP,
                               complete words incl. '$' transition)
    quantPrefix   101 * f32   (same for word prefixes, no '$' transition)
    then for k = 1..4:
        count   u32
        keys    count * u32, sorted ascending (6 bits per char index)
        vals    count * 2 bytes (qlogp u8, qbow u8) for k<4
                count * 1 byte  (qlogp)            for k=4

Quantization: q = clamp(round(-ln(p) * 12), 0, 255); ln(p) = -q / 12.
"""

import math
import struct
from collections import Counter

MAGIC = b"GNG1"
ORDER = 4
QUANT_SCALE = 12.0
NUM_QUANTILES = 101  # p0..p100

ALPHABETS = {
    "en": "^$'" + "abcdefghijklmnopqrstuvwxyz",
    "ru": "^$" + "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
}

BOUNDARY = ("^", "$")


def quantize_ln(lnp):
    return min(255, max(0, int(round(-lnp * QUANT_SCALE))))


def dequantize(q):
    return -q / QUANT_SCALE


def encode(gram, idx):
    """Pack a k-gram (k<=5 chars, 6 bits each) into an int key."""
    key = 0
    for ch in gram:
        key = (key << 6) | idx[ch]
    return key


class BinModel:
    """Reader + scorer over the serialized (quantized) tables.

    Mirrors NgramModel.swift: the same file bytes must produce the same
    scores in both implementations.
    """

    def __init__(self, path):
        with open(path, "rb") as f:
            data = f.read()
        off = 0
        assert data[:4] == MAGIC, "bad magic"
        off = 4
        self.lang = data[off:off + 2].decode("ascii")
        off += 2
        alpha_count = data[off]
        off += 1
        units = struct.unpack_from("<%dH" % alpha_count, data, off)
        off += 2 * alpha_count
        self.alphabet = "".join(chr(u) for u in units)
        self.idx = {ch: i for i, ch in enumerate(self.alphabet)}
        self.quant_complete = list(struct.unpack_from("<%df" % NUM_QUANTILES, data, off))
        off += 4 * NUM_QUANTILES
        self.quant_prefix = list(struct.unpack_from("<%df" % NUM_QUANTILES, data, off))
        off += 4 * NUM_QUANTILES

        self.tables = []  # per order: dict key -> (lnp, lnbow) or lnp for k=4
        for k in range(1, ORDER + 1):
            (count,) = struct.unpack_from("<I", data, off)
            off += 4
            keys = struct.unpack_from("<%dI" % count, data, off)
            off += 4 * count
            table = {}
            if k < ORDER:
                for i, key in enumerate(keys):
                    qlp = data[off + 2 * i]
                    qbow = data[off + 2 * i + 1]
                    table[key] = (dequantize(qlp), dequantize(qbow))
                off += 2 * count
            else:
                for i, key in enumerate(keys):
                    table[key] = dequantize(data[off + i])
                off += count
            self.tables.append(table)
        self.size_bytes = len(data)
        # Floor for a char somehow missing from the unigram table.
        self.ln_floor = dequantize(255)

    # -- scoring (mirror of Swift) --------------------------------------

    def cond_logp(self, ctx, ch):
        """ln P(ch | ctx) where ctx is the 3 preceding chars."""
        t1, t2, t3, t4 = self.tables
        idx = self.idx
        k4 = encode(ctx + ch, idx)
        hit = t4.get(k4)
        if hit is not None:
            return hit
        acc = 0.0
        rec = t3.get(encode(ctx, idx))
        if rec is not None:
            acc += rec[1]
        rec = t3.get(encode(ctx[1:] + ch, idx))
        if rec is not None:
            return acc + rec[0]
        rec = t2.get(encode(ctx[1:], idx))
        if rec is not None:
            acc += rec[1]
        rec = t2.get(encode(ctx[2:] + ch, idx))
        if rec is not None:
            return acc + rec[0]
        rec = t1.get(encode(ctx[2:], idx))
        if rec is not None:
            acc += rec[1]
        rec = t1.get(encode(ch, idx))
        if rec is not None:
            return acc + rec[0]
        return acc + self.ln_floor

    def avg_logp(self, word, complete):
        """Per-transition avg ln P of the word, or None if not scoreable."""
        if not word:
            return None
        for ch in word:
            if ch in BOUNDARY or ch not in self.idx:
                return None
        ctx = "^^^"
        total = 0.0
        n = 0
        for ch in word:
            total += self.cond_logp(ctx, ch)
            n += 1
            ctx = ctx[1:] + ch
        if complete:
            total += self.cond_logp(ctx, "$")
            n += 1
        return total / n

    def percentile(self, avg, complete):
        table = self.quant_complete if complete else self.quant_prefix
        if avg <= table[0]:
            return 0.0
        if avg >= table[-1]:
            return 1.0
        lo, hi = 0, len(table) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if table[mid] <= avg:
                lo = mid
            else:
                hi = mid
        span = table[hi] - table[lo]
        frac = (avg - table[lo]) / span if span > 0 else 0.0
        return (lo + frac) / (len(table) - 1)

    def word_percentile(self, word, complete):
        avg = self.avg_logp(word, complete)
        if avg is None:
            return None
        return self.percentile(avg, complete)


# -- training ------------------------------------------------------------


def kn_discount(counts):
    """D = n1 / (n1 + 2*n2) from count-of-counts, with a sane fallback."""
    n1 = sum(1 for c in counts if c == 1)
    n2 = sum(1 for c in counts if c == 2)
    if n1 == 0 or (n1 + 2 * n2) == 0:
        return 0.5
    return n1 / (n1 + 2.0 * n2)


def train(word_freqs, lang, min_count4=1):
    """Estimate interpolated KN tables. Returns dict with per-order
    {gram: lnp} / {context: lnbow} maps ready for serialization."""
    alphabet = ALPHABETS[lang]
    vocab_pred = len(alphabet) - 1  # everything except '^' can be predicted

    counts4 = Counter()
    for word, freq in word_freqs.items():
        padded = "^^^" + word + "$"
        for i in range(3, len(padded)):
            counts4[padded[i - 3:i + 1]] += freq

    # Continuation counts (type counts of distinct one-char left extensions).
    cont3 = Counter()
    for g in counts4:
        cont3[g[1:]] += 1
    cont2 = Counter()
    for g in cont3:
        cont2[g[1:]] += 1
    cont1 = Counter()
    for g in cont2:
        cont1[g[1:]] += 1

    # Context aggregates.
    ctx3_total, ctx3_types = Counter(), Counter()
    for g, c in counts4.items():
        ctx3_total[g[:3]] += c
        ctx3_types[g[:3]] += 1
    ctx2_total, ctx2_types = Counter(), Counter()
    for g, c in cont3.items():
        ctx2_total[g[:2]] += c
        ctx2_types[g[:2]] += 1
    ctx1_total, ctx1_types = Counter(), Counter()
    for g, c in cont2.items():
        ctx1_total[g[:1]] += c
        ctx1_types[g[:1]] += 1

    d4 = kn_discount(counts4.values())
    d3 = kn_discount(cont3.values())
    d2 = kn_discount(cont2.values())
    d1 = kn_discount(cont1.values())

    t_cont1 = sum(cont1.values())
    n_types1 = len(cont1)

    def p1(ch):
        c = cont1.get(ch, 0)
        return max(c - d1, 0.0) / t_cont1 + (d1 * n_types1 / t_cont1) * (1.0 / vocab_pred)

    p1_cache = {ch: p1(ch) for ch in alphabet if ch != "^"}

    def p2(gram):  # P(gram[1] | gram[0])
        h, ch = gram[0], gram[1]
        total = ctx1_total.get(h, 0)
        if total == 0:
            return p1_cache[ch]
        lam = d2 * ctx1_types[h] / total
        return max(cont2.get(gram, 0) - d2, 0.0) / total + lam * p1_cache[ch]

    p2_cache = {g: p2(g) for g in cont2}

    def p3(gram):
        h, ch = gram[:2], gram[2]
        total = ctx2_total.get(h, 0)
        lower = p2_cache.get(gram[1:]) or p2(gram[1:])
        if total == 0:
            return lower
        lam = d3 * ctx2_types[h] / total
        return max(cont3.get(gram, 0) - d3, 0.0) / total + lam * lower

    p3_cache = {g: p3(g) for g in cont3}

    def p4(gram):
        h, ch = gram[:3], gram[3]
        total = ctx3_total[h]
        lower = p3_cache.get(gram[1:]) or p3(gram[1:])
        lam = d4 * ctx3_types[h] / total
        return max(counts4[gram] - d4, 0.0) / total + lam * lower

    # Backoff weights.
    def bow3(h):
        total = ctx3_total.get(h, 0)
        return d4 * ctx3_types[h] / total if total else 1.0

    def bow2(h):
        total = ctx2_total.get(h, 0)
        return d3 * ctx2_types[h] / total if total else 1.0

    def bow1(h):
        total = ctx1_total.get(h, 0)
        return d2 * ctx1_types[h] / total if total else 1.0

    tables = {
        1: {ch: (math.log(p1_cache[ch]), math.log(bow1(ch)))
            for ch in alphabet if ch != "^"},
        2: {g: (math.log(p), math.log(bow2(g))) for g, p in p2_cache.items()},
        3: {},
        4: {},
    }
    keys3 = set(cont3) | set(ctx3_total)
    for g in keys3:
        p = p3_cache.get(g)
        lnp = math.log(p) if p else dequantize(255)
        tables[3][g] = (lnp, math.log(bow3(g)))
    for g, c in counts4.items():
        if c >= min_count4:
            tables[4][g] = math.log(p4(g))

    return {"tables": tables, "discounts": (d1, d2, d3, d4)}


def serialize(model, lang, quant_complete, quant_prefix):
    alphabet = ALPHABETS[lang]
    idx = {ch: i for i, ch in enumerate(alphabet)}
    out = bytearray()
    out += MAGIC
    out += lang.encode("ascii")
    out.append(len(alphabet))
    for ch in alphabet:
        out += struct.pack("<H", ord(ch))
    assert len(quant_complete) == NUM_QUANTILES
    assert len(quant_prefix) == NUM_QUANTILES
    out += struct.pack("<%df" % NUM_QUANTILES, *quant_complete)
    out += struct.pack("<%df" % NUM_QUANTILES, *quant_prefix)

    for k in range(1, ORDER + 1):
        table = model["tables"][k]
        items = sorted((encode(g, idx), v) for g, v in table.items())
        out += struct.pack("<I", len(items))
        for key, _ in items:
            out += struct.pack("<I", key)
        if k < ORDER:
            for _, (lnp, lnbow) in items:
                out.append(quantize_ln(lnp))
                out.append(quantize_ln(lnbow))
        else:
            for _, lnp in items:
                out.append(quantize_ln(lnp))
    return bytes(out)


def weighted_quantiles(values_weights, n=NUM_QUANTILES):
    """values_weights: list of (value, weight). Returns n quantile points."""
    vw = sorted(values_weights)
    total = sum(w for _, w in vw)
    result = []
    cum = 0.0
    i = 0
    for q in range(n):
        target = (q / (n - 1)) * total
        while i < len(vw) - 1 and cum + vw[i][1] < target:
            cum += vw[i][1]
            i += 1
        result.append(vw[i][0])
    return result
