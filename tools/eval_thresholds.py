#!/usr/bin/env python3
"""Tune the Decider's n-gram thresholds offline.

Replays the exact runtime decision — "typed percentile ≤ B AND candidate
percentile ≥ A" — over the full corpus vocabulary in both layout directions,
plus adversarial negatives (random strings, keyboard mashes, transliterated
Russian). Reports the Pareto frontier of (A, B) with ZERO false positives,
because corrupting correct text is the worst outcome for this app.

Usage:
    python3 tools/eval_thresholds.py [--corpora-dir DIR] [--models-dir DIR]
"""

import argparse
import os
import random
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ngram_lm  # noqa: E402
from train_ngram import CORPORA, TOKEN_RE, MAX_WORD_LEN, collect_tokens  # noqa: E402

# Standard ЙЦУКЕН ↔ US QWERTY physical-key correspondence.
RU2EN = {
    "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y", "г": "u",
    "ш": "i", "щ": "o", "з": "p", "х": "[", "ъ": "]", "ф": "a", "ы": "s",
    "в": "d", "а": "f", "п": "g", "р": "h", "о": "j", "л": "k", "д": "l",
    "ж": ";", "э": "'", "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b",
    "т": "n", "ь": "m", "б": ",", "ю": ".", "ё": "`",
}
EN2RU = {v: k for k, v in RU2EN.items()}

TRANSLIT_NEGATIVES = [
    # Latin transliterations users type on purpose while in the RU layout —
    # the screen shows Cyrillic gibberish, but converting to the translit is
    # NOT what the legacy behavior promises (selftest: "spasibo" stays put).
    "privet", "spasibo", "poka", "horosho", "kak", "dela", "chto", "gde",
    "kogda", "pochemu", "vchera", "zavtra", "segodnya", "davai", "poehali",
    "molodec", "krasava", "zdorovo", "otlichno", "ponyatno", "konechno",
    "naverno", "voobshe", "kstati", "ladno", "shas", "seychas", "budu",
]


def map_word(word, table):
    out = []
    for ch in word:
        m = table.get(ch)
        if m is None:
            return None
        out.append(m)
    return "".join(out)


def typed_percentile(model, s, complete):
    """Percentile of the as-typed string under the source-language model.
    Strings containing chars outside the language's alphabet are by
    definition not words of that language → 0.0 (mirrors the Swift side)."""
    p = model.word_percentile(s, complete)
    return p if p is not None else 0.0


def build_cases(en_model, ru_model, en_freqs, ru_freqs):
    """Returns (positives, negatives): lists of (typedP, candP, tag, word)."""
    positives, negatives = [], []

    # RU intended, typed on EN layout: ";bpym" → "жизнь".
    for word, freq in ru_freqs.items():
        if freq < 2 or len(word) < 4:
            continue
        cand_p = ru_model.word_percentile(word, True)
        if cand_p is None:
            continue
        typed = map_word(word, RU2EN)
        typed_p = typed_percentile(en_model, typed, True)
        positives.append((typed_p, cand_p, "ru-intent", word))

    # EN intended, typed on RU layout: "руддщ" → "hello".
    for word, freq in en_freqs.items():
        if freq < 2 or len(word) < 4:
            continue
        cand_p = en_model.word_percentile(word, True)
        if cand_p is None:
            continue
        typed = map_word(word, EN2RU)
        typed_p = typed_percentile(ru_model, typed, True)
        positives.append((typed_p, cand_p, "en-intent", word))

    # Negatives: EN word typed correctly; candidate is its RU-layout twin.
    for word, freq in en_freqs.items():
        if freq < 2 or len(word) < 4:
            continue
        typed_p = typed_percentile(en_model, word, True)
        twin = map_word(word, EN2RU)
        cand_p = ru_model.word_percentile(twin, True) if twin else None
        if cand_p is not None:
            negatives.append((typed_p, cand_p, "en-correct", word))

    # Negatives: RU word typed correctly; candidate is its EN-layout twin.
    for word, freq in ru_freqs.items():
        if freq < 2 or len(word) < 4:
            continue
        typed_p = typed_percentile(ru_model, word, True)
        twin = map_word(word, RU2EN)
        cand_p = en_model.word_percentile(twin, True) if twin else None
        if cand_p is not None:
            negatives.append((typed_p, cand_p, "ru-correct", word))

    # Negatives: transliterated Russian typed on purpose in the RU layout.
    for word in TRANSLIT_NEGATIVES:
        cand_p = en_model.word_percentile(word, True)
        if cand_p is None:
            continue
        typed = map_word(word, EN2RU)
        typed_p = typed_percentile(ru_model, typed, True)
        negatives.append((typed_p, cand_p, "translit", word))

    # Negatives: random letter strings and keyboard mashes (passwords, IDs)
    # typed on purpose — must never convert in either direction.
    rng = random.Random(20260703)
    en_letters = "abcdefghijklmnopqrstuvwxyz"
    ru_letters = "абвгдежзийклмнопрстуфхцчшщъыьэюя"
    mashes = ["asdfgh", "qwerty", "zxcvbn", "sdfgsdfg", "qazwsx", "hjkl",
              "фывапр", "йцукен", "ячсмить", "олдж"]
    for _ in range(4000):
        n = rng.randint(4, 12)
        mashes.append("".join(rng.choice(en_letters) for _ in range(n)))
        mashes.append("".join(rng.choice(ru_letters) for _ in range(n)))
    for s in mashes:
        if all(ch in en_letters for ch in s):
            typed_p = typed_percentile(en_model, s, True)
            twin = map_word(s, EN2RU)
            cand_p = ru_model.word_percentile(twin, True) if twin else None
            src = "rand-en"
        else:
            typed_p = typed_percentile(ru_model, s, True)
            twin = map_word(s, RU2EN)
            cand_p = en_model.word_percentile(twin, True) if twin else None
            src = "rand-ru"
        if cand_p is not None:
            negatives.append((typed_p, cand_p, src, s))

    return positives, negatives


def build_prefix_cases(en_model, ru_model, en_freqs, ru_freqs, min_len=5):
    """Same idea for mid-word (live) evaluation: every prefix of length
    ≥ min_len is a separate case, because live mode fires on any of them."""
    positives, negatives = [], []

    def add(word, src_model, cand_model, table, bucket, tag):
        for plen in range(min_len, len(word)):
            prefix = word[:plen]
            cand_p = cand_model.word_percentile(prefix, False)
            if cand_p is None:
                continue
            typed = map_word(prefix, table)
            typed_p = typed_percentile(src_model, typed, False) if typed else 0.0
            bucket.append((typed_p, cand_p, tag, prefix))

    for word, freq in ru_freqs.items():
        if freq < 2 or len(word) <= min_len:
            continue
        add(word, en_model, ru_model, RU2EN, positives, "ru-intent")
    for word, freq in en_freqs.items():
        if freq < 2 or len(word) <= min_len:
            continue
        add(word, ru_model, en_model, EN2RU, positives, "en-intent")

    # Correct-word prefixes: typed prefix under own model, twin under other.
    for word, freq in en_freqs.items():
        if freq < 2 or len(word) <= min_len:
            continue
        for plen in range(min_len, len(word)):
            prefix = word[:plen]
            typed_p = typed_percentile(en_model, prefix, False)
            twin = map_word(prefix, EN2RU)
            cand_p = ru_model.word_percentile(twin, False) if twin else None
            if cand_p is not None:
                negatives.append((typed_p, cand_p, "en-correct", prefix))
    for word, freq in ru_freqs.items():
        if freq < 2 or len(word) <= min_len:
            continue
        for plen in range(min_len, len(word)):
            prefix = word[:plen]
            typed_p = typed_percentile(ru_model, prefix, False)
            twin = map_word(prefix, RU2EN)
            cand_p = en_model.word_percentile(twin, False) if twin else None
            if cand_p is not None:
                negatives.append((typed_p, cand_p, "ru-correct", prefix))

    return positives, negatives


def grid_search(positives, negatives, label):
    print(f"\n=== {label}: {len(positives):,} positives, "
          f"{len(negatives):,} negatives ===")
    a_grid = [round(0.02 + 0.01 * i, 2) for i in range(40)]
    b_grid = [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.03]

    # Worst negatives: what does the most convert-looking correct text score?
    worst = sorted(negatives, key=lambda c: (-c[1], c[0]))[:15]
    print("  hardest negatives (candP desc):")
    for typed_p, cand_p, tag, word in worst:
        print(f"    cand={cand_p:.3f} typed={typed_p:.3f} [{tag}] {word!r}")

    results = []
    for a in a_grid:
        for b in b_grid:
            fp = sum(1 for t, c, _, _ in negatives if c >= a and t <= b)
            if fp:
                continue
            tp = sum(1 for t, c, _, _ in positives if c >= a and t <= b)
            results.append((tp, a, b))
    results.sort(reverse=True)
    print("  zero-FP frontier (best TP first):")
    seen_a = set()
    shown = 0
    for tp, a, b in results:
        if a in seen_a or shown >= 8:
            continue
        seen_a.add(a)
        shown += 1
        rate = tp / len(positives) if positives else 0
        print(f"    A={a:.2f} B={b:.4f} → TP {tp:,}/{len(positives):,} ({rate:.1%})")
    return results


def main():
    ap = argparse.ArgumentParser()
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--corpora-dir",
                    default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "ghbdtn-corpora"))
    ap.add_argument("--models-dir",
                    default=os.path.join(root, "Sources/Ghbdtn/Resources/Models"))
    args = ap.parse_args()

    en_model = ngram_lm.BinModel(os.path.join(args.models_dir, "ngram-en.bin"))
    ru_model = ngram_lm.BinModel(os.path.join(args.models_dir, "ngram-ru.bin"))

    print("collecting corpus vocabulary…")
    en_freqs = collect_tokens("en", args.corpora_dir)
    ru_freqs = collect_tokens("ru", args.corpora_dir)

    pos, neg = build_cases(en_model, ru_model, en_freqs, ru_freqs)
    grid_search(pos, neg, "complete words")

    # OOV proxy: rare words (freq 2..4) are mostly names/slang/loans — the
    # population the n-gram layer actually exists for.
    rare_words = {w for w, f in list(en_freqs.items()) + list(ru_freqs.items())
                  if 2 <= f <= 4}
    pos_rare = [c for c in pos if c[3] in rare_words]
    print(f"\nOOV proxy (freq 2-4) positives: {len(pos_rare):,}")
    for a, b in [(0.05, 0.002), (0.08, 0.002), (0.10, 0.002), (0.15, 0.001),
                 (0.20, 0.001), (0.30, 0.0005)]:
        tp = sum(1 for t, c, _, _ in pos_rare if c >= a and t <= b)
        print(f"    A={a:.2f} B={b:.4f} → OOV TP {tp/len(pos_rare):.1%}")

    ppos, pneg = build_prefix_cases(en_model, ru_model, en_freqs, ru_freqs)
    grid_search(ppos, pneg, "prefixes (live mode)")


if __name__ == "__main__":
    main()
