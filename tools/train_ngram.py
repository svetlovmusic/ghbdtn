#!/usr/bin/env python3
"""Train Ghbdtn's character 4-gram models (interpolated Kneser-Ney).

Trains on real running text — Leipzig Corpora sentence collections (news +
public web), NOT on dictionary word lists — so the character statistics
reflect live language frequencies, including names and informal words.

Usage:
    python3 tools/train_ngram.py [--corpora-dir DIR] [--out-dir DIR]

Downloads ~100 MB of corpora on first run (cached afterwards), writes
Sources/Ghbdtn/Resources/Models/ngram-{en,ru}.bin and prints a report.
"""

import argparse
import math
import os
import re
import sys
import tarfile
import tempfile
import time
import urllib.request
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ngram_lm  # noqa: E402

CORPORA = {
    "en": ["eng_news_2023_100K", "eng-com_web-public_2018_100K"],
    "ru": ["rus_news_2023_100K", "rus-ru_web-public_2019_100K"],
    "uk": ["ukr_news_2023_100K", "ukr_newscrawl_2011_100K"],
}
BASE_URL = "https://downloads.wortschatz-leipzig.de/corpora/"

TOKEN_RE = {
    "en": re.compile(r"[a-z]+(?:'[a-z]+)*"),
    "ru": re.compile(r"[а-яё]+"),
    # Ukrainian letters (incl. і ї є ґ) plus internal apostrophes (п'ять).
    "uk": re.compile(r"[абвгґдеєжзиіїйклмнопрстуфхцчшщьюя]+(?:'[абвгґдеєжзиіїйклмнопрстуфхцчшщьюя]+)*"),
}
MAX_WORD_LEN = 20
# Runtime gating: complete words scored from 4 letters, prefixes from 5.
MIN_LEN_COMPLETE = 4
MIN_LEN_PREFIX = 5
PREFIX_CALIB_WORDS = 100_000  # most frequent words used for prefix quantiles


def fetch_corpus(name, corpora_dir):
    path = os.path.join(corpora_dir, name + ".tar.gz")
    if not os.path.exists(path):
        url = BASE_URL + name + ".tar.gz"
        print(f"  downloading {url}")
        urllib.request.urlretrieve(url, path)
    return path


def iter_sentences(tar_path):
    with tarfile.open(tar_path, "r:gz") as tar:
        for member in tar:
            if member.name.endswith("-sentences.txt"):
                f = tar.extractfile(member)
                for line in f:
                    parts = line.decode("utf-8", "replace").split("\t", 1)
                    if len(parts) == 2:
                        yield parts[1]


def collect_tokens(lang, corpora_dir):
    freqs = Counter()
    rx = TOKEN_RE[lang]
    for name in CORPORA[lang]:
        path = fetch_corpus(name, corpora_dir)
        n = 0
        for sentence in iter_sentences(path):
            for tok in rx.findall(sentence.lower()):
                if 1 <= len(tok) <= MAX_WORD_LEN:
                    freqs[tok] += 1
                    n += 1
        print(f"  {name}: {n:,} tokens")
    return freqs


def load_domain_words(lang, domain_dir):
    """Curated domain terminology (music, programming, 3D, audiophile) mixed
    into the corpus so its character statistics reflect the transliterated
    loanwords practitioners type (пэд, сэмпл, шейдер) — words too rare in
    general news/web text for the base model to rate as plausible. One word per
    line; only entries that are a single clean token of the language survive."""
    path = os.path.join(domain_dir, f"{lang}.txt")
    if not os.path.exists(path):
        return []
    rx = TOKEN_RE[lang]
    seen = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            w = line.strip().lower()
            m = rx.fullmatch(w) if w else None
            if m and 1 <= len(w) <= MAX_WORD_LEN:
                seen[w] = True
    return list(seen)


def calibrate(bin_model, word_freqs):
    """Quantiles of per-char avg lnP over real word TYPES (each distinct word
    once, hapaxes dropped as likely typos), computed with the QUANTIZED model
    so runtime scores map exactly.

    Type-weighting (not token-weighting) is deliberate: token weights let the
    top-1000 words dominate the scale and squash every rare-but-real word into
    the same bottom percentiles as gibberish. The question the runtime asks is
    "is this string a plausible word of the language" — a property of the
    population of word types.
    """
    complete = []
    for word, freq in word_freqs.items():
        if freq < 2 or len(word) < MIN_LEN_COMPLETE:
            continue
        avg = bin_model.avg_logp(word, complete=True)
        if avg is not None:
            complete.append((avg, 1.0))

    prefix = []
    top = sorted(word_freqs.items(), key=lambda kv: -kv[1])[:PREFIX_CALIB_WORDS]
    for word, freq in top:
        if freq < 2 or len(word) <= MIN_LEN_PREFIX:
            continue
        for plen in range(MIN_LEN_PREFIX, len(word)):
            avg = bin_model.avg_logp(word[:plen], complete=False)
            if avg is not None:
                prefix.append((avg, 1.0))

    return (ngram_lm.weighted_quantiles(complete),
            ngram_lm.weighted_quantiles(prefix))


def sanity_check(bin_model, lang):
    """Sum-to-1 over the predicted alphabet for a sample of seen contexts."""
    alphabet = [ch for ch in bin_model.alphabet if ch != "^"]
    inv = {i: ch for ch, i in bin_model.idx.items()}
    ctx_keys = sorted(bin_model.tables[2].keys())[:200]  # trigram table keys
    sums = []
    for key in ctx_keys:
        chars = []
        k = key
        for _ in range(3):
            chars.append(inv[k & 0x3F])
            k >>= 6
        ctx = "".join(reversed(chars))
        if "$" in ctx:
            continue
        s = sum(math.exp(bin_model.cond_logp(ctx, ch)) for ch in alphabet)
        sums.append(s)
    lo, hi = min(sums), max(sums)
    print(f"  sum-to-1 over {len(sums)} contexts: min={lo:.3f} max={hi:.3f}")
    if not (0.8 < lo and hi < 1.2):
        raise AssertionError(f"probability mass off for {lang}: [{lo}, {hi}]")


SMOKE_WORDS = {
    "en": ["hello", "world", "kowalski", "spasibo", "asdfgh", "ghbdtn"],
    "ru": ["привет", "андрей", "смузи", "фывапр", "ызфышищ", "руддщ"],
    "uk": ["привіт", "дякую", "семпл", "шейдер", "фівапр", "ячсміть"],
}


def smoke_report(models):
    for lang, m in models.items():
        for w in SMOKE_WORDS.get(lang, []):
            avg = m.avg_logp(w, complete=True)
            pct = m.percentile(avg, complete=True) if avg is not None else None
            print(f"  {lang} {w!r}: avg={avg and round(avg, 3)} pct={pct and round(pct, 3)}")


def main():
    ap = argparse.ArgumentParser()
    default_corpora = os.path.join(tempfile.gettempdir(), "ghbdtn-corpora")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--corpora-dir", default=default_corpora)
    ap.add_argument("--out-dir",
                    default=os.path.join(root, "Sources/Ghbdtn/Resources/Models"))
    ap.add_argument("--min-count4", type=int, default=1,
                    help="prune 4-grams with count below this (1 = keep all)")
    ap.add_argument("--domain-dir", default=os.path.join(root, "tools/domain-corpora"),
                    help="directory with {lang}.txt curated domain wordlists")
    ap.add_argument("--domain-weight", type=int, default=50,
                    help="pseudo-count added per domain term (0 disables)")
    args = ap.parse_args()

    os.makedirs(args.corpora_dir, exist_ok=True)
    os.makedirs(args.out_dir, exist_ok=True)

    models = {}
    for lang in CORPORA:
        print(f"[{lang}] collecting tokens…")
        freqs = collect_tokens(lang, args.corpora_dir)
        print(f"  {len(freqs):,} distinct words, {sum(freqs.values()):,} tokens")

        if args.domain_weight > 0:
            dom = load_domain_words(lang, args.domain_dir)
            for w in dom:
                freqs[w] += args.domain_weight
            print(f"  + {len(dom):,} domain terms @ weight {args.domain_weight}")

        print(f"[{lang}] training interpolated Kneser-Ney…")
        t0 = time.time()
        model = ngram_lm.train(freqs, lang, min_count4=args.min_count4)
        d = model["discounts"]
        print(f"  discounts D1..D4 = {[round(x, 3) for x in d]}  ({time.time()-t0:.1f}s)")
        for k in range(1, 5):
            print(f"  order {k}: {len(model['tables'][k]):,} entries")

        out_path = os.path.join(args.out_dir, f"ngram-{lang}.bin")
        # Two-pass write: serialize with placeholder quantiles, calibrate on
        # the quantized model, then re-serialize with the real quantiles.
        placeholder = [0.0] * ngram_lm.NUM_QUANTILES
        with open(out_path, "wb") as f:
            f.write(ngram_lm.serialize(model, lang, placeholder, placeholder))
        bin_model = ngram_lm.BinModel(out_path)

        print(f"[{lang}] calibrating percentiles…")
        qc, qp = calibrate(bin_model, freqs)
        with open(out_path, "wb") as f:
            f.write(ngram_lm.serialize(model, lang, qc, qp))
        bin_model = ngram_lm.BinModel(out_path)
        models[lang] = bin_model

        print(f"[{lang}] model: {bin_model.size_bytes/1e6:.2f} MB → {out_path}")
        print(f"  complete-word quantiles p1={qc[1]:.3f} p25={qc[25]:.3f} "
              f"p50={qc[50]:.3f} p99={qc[99]:.3f}")
        sanity_check(bin_model, lang)

    print("\nsmoke scores (avg lnP per char / percentile among real words):")
    smoke_report(models)


if __name__ == "__main__":
    main()
