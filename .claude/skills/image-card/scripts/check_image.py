#!/usr/bin/env python3
"""圖卡機械檢查：把能用程式判定的事交給程式，眼睛只留給程式判不了的。

用法：
    python3 check_image.py <圖片路徑> [--expect 4:5|16:9|1:1|9:16]

輸出「比例」與「解析度」兩條的判定結果。角色、文字、單張、構圖四條
程式判不了，必須自己看圖——本腳本不會對那四條給任何結論。
"""
import argparse
import math
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("需要 Pillow：pip install Pillow")

TARGETS = {
    "4:5": (4, 5),
    "16:9": (16, 9),
    "9:16": (9, 16),
    "1:1": (1, 1),
}
# 容差 1.5%：模型輸出常有幾個 px 的誤差，不該因此退圖
TOLERANCE = 0.015
# 低於這個長邊，圖上的中文幾乎一定糊掉
MIN_LONG_EDGE = 1000


def describe(path, expect):
    if not os.path.exists(path):
        return [f"✕ 找不到檔案：{path}"], False

    with Image.open(path) as im:
        w, h = im.size
        fmt = im.format

    lines = [f"檔案：{path}", f"格式：{fmt}　尺寸：{w} × {h} px"]
    ok = True

    g = math.gcd(w, h)
    lines.append(f"實際比例：{w//g}:{h//g}（{w/h:.4f}）")

    # 找出最接近的常用比例
    closest, closest_err = None, None
    for name, (a, b) in TARGETS.items():
        err = abs((w / h) - (a / b)) / (a / b)
        if closest_err is None or err < closest_err:
            closest, closest_err = name, err
    lines.append(f"最接近的常用比例：{closest}（誤差 {closest_err*100:.2f}%）")

    if expect:
        if expect not in TARGETS:
            lines.append(f"✕ 不認得的目標比例：{expect}")
            ok = False
        else:
            a, b = TARGETS[expect]
            err = abs((w / h) - (a / b)) / (a / b)
            if err <= TOLERANCE:
                lines.append(f"✓ 比例：符合 {expect}（誤差 {err*100:.2f}%）")
            else:
                lines.append(
                    f"✕ 比例：要 {expect}，實際 {w//g}:{h//g}（誤差 {err*100:.2f}%）→ 退"
                )
                ok = False
    else:
        lines.append("－ 比例：未指定目標，未判定")

    long_edge = max(w, h)
    if long_edge < MIN_LONG_EDGE:
        lines.append(f"✕ 解析度：長邊只有 {long_edge} px，圖上中文大機率糊掉 → 退")
        ok = False
    else:
        lines.append(f"✓ 解析度：長邊 {long_edge} px，足夠承載中文字")

    lines.append("")
    lines.append("程式判不了的四條，請自己看圖逐條判：角色／文字／單張／構圖")
    return lines, ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--expect", help="目標比例：4:5 / 16:9 / 9:16 / 1:1")
    args = ap.parse_args()

    lines, ok = describe(args.image, args.expect)
    print("\n".join(lines))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
