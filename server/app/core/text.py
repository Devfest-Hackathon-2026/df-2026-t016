"""作者が書く文字（題名・表示名・申告の詳細）を整える。

ページで見え方を偽れる文字を消す。右から左に並べる制御文字（U+202E など）で制作者の名前を別人に見せる、
幅の無い文字やタグ文字（U+E0000 台）で見えない文を埋め込む、といったことを防ぐ。
- 制御文字（Cc）: 消す。複数行の欄だけ、改行とタブを残す
- 書式文字（Cf）: 消す。絵文字をつなぐ U+200D（ZWJ）だけ残す
- 行と段落の区切り（U+2028・U+2029）: 複数行の欄では改行にし、1行の欄では消す
- 片割れのサロゲート（Cs）: 消す
最後に前後の空白を取る。
"""

from __future__ import annotations

import unicodedata

_ZWJ = "‍"


def clean(s: str, multiline: bool = False) -> str:
    if multiline:
        s = s.replace("\r\n", "\n").replace("\r", "\n").replace(" ", "\n").replace(" ", "\n")
    out = []
    for ch in s:
        if multiline and ch in "\n\t":
            out.append(ch)
            continue
        cat = unicodedata.category(ch)
        if cat in ("Cc", "Cs", "Zl", "Zp"):
            continue
        if cat == "Cf" and ch != _ZWJ:
            continue
        out.append(ch)
    return "".join(out).strip()


def clean_line(s: str) -> str:
    """1行の欄（題名・表示名）。消した結果が空なら ValueError（400 BAD_REQUEST になる）。"""
    t = clean(s)
    if not t:
        raise ValueError("must contain visible characters")
    return t
