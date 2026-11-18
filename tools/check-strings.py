#!/usr/bin/env python3
"""アプリの文の訳の漏れを調べる。

Sources/main.swift の L("…") の最初の引数（英語の正本）がすべて各言語の Localizable.strings にあるか、
埋め込み（%@・%d など）の種類と数が正本と訳で同じか、使われていない訳が残っていないかを確かめる。
問題があれば終了コード 1 で終わる。
"""
import json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources" / "main.swift"
LANGUAGES = ["ja"]

def swift_keys():
    text = SOURCE.read_text(encoding="utf-8")
    keys = set()
    for m in re.finditer(r'\bL\(\s*"((?:[^"\\]|\\.)*)"', text):
        keys.add(bytes(m.group(1), "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8"))
    return keys

def placeholders(s):
    # %1$@ → @、%d・%lld → d のように種類だけにして、並べ替えを許す
    found = re.findall(r'%(?:\d+\$)?(?:ll|l)?([@dfs])', s.replace("%%", ""))
    return sorted(found)

def load_strings(path):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"{path}: 読めません: {out.stderr.strip()}")
    return json.loads(out.stdout)

def main():
    keys = swift_keys()
    problems = 0
    for lang in LANGUAGES:
        path = ROOT / "Resources" / f"{lang}.lproj" / "Localizable.strings"
        table = load_strings(path)
        for key in sorted(keys - table.keys()):
            print(f"[{lang}] 訳がない: {key}"); problems += 1
        for key in sorted(table.keys() - keys):
            print(f"[{lang}] 使われていない訳: {key}"); problems += 1
        for key in sorted(keys & table.keys()):
            if placeholders(key) != placeholders(table[key]):
                print(f"[{lang}] 埋め込みが合わない: {key} → {table[key]}"); problems += 1
    print(f"文 {len(keys)} 個、言語 {', '.join(LANGUAGES)}：問題 {problems} 件")
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main())
