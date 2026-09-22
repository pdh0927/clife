#!/usr/bin/env python3
"""생성된 스프라이트 시트를 앱이 쓸 프레임으로 가공한다.

    python3 assets/dog/prepare.py <시트.png> <정지포즈.png>

이미지 생성 모델은 "투명 배경"을 요구해도 **체커보드 무늬를 그려서** 돌려주는
경우가 많다. 알파가 전부 255인 불투명 이미지인데 투명해 보이는 그림일 뿐이다.
그래서 배경 제거가 첫 단계다.

색으로만 키잉하면 눈의 흰 하이라이트까지 지워져 눈에 구멍이 뚫린다. 배경은 테두리와
이어져 있고 강아지 안쪽 흰색은 그렇지 않으므로, 테두리에서 flood fill 로 번져나간
영역만 지운다.

두 번째 단계는 정렬이다. 프레임마다 강아지가 캔버스 안에서 다른 자리에 있으면
애니메이션이 제자리에서 덜덜 떤다. 각 프레임의 알파 경계상자를 재서 머리 꼭대기와
가로 중심을 맞춘다 — 달릴 때 다리는 오르내리지만 머리 높이는 거의 일정하므로,
머리를 맞추면 몸의 바운스는 남고 캔버스 안에서의 표류만 사라진다.
"""
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

PAD_TOP = 12
OUT = Path(__file__).parent


def dekey(path):
    """테두리에서 번져나가는 무채색 배경만 투명으로 바꾼다."""
    im = Image.open(path).convert("RGBA")
    rgb = np.array(im)[:, :, :3].astype(np.int16)
    h, w = rgb.shape[:2]

    chroma = rgb.max(axis=2) - rgb.min(axis=2)
    candidate = (chroma <= 14) & (rgb.mean(axis=2) >= 180)

    seen = np.zeros((h, w), bool)
    q = deque()
    border = [(y, x) for x in range(w) for y in (0, h - 1)]
    border += [(y, x) for y in range(h) for x in (0, w - 1)]
    for y, x in border:
        if candidate[y, x] and not seen[y, x]:
            seen[y, x] = True
            q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and candidate[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                q.append((ny, nx))

    alpha = np.where(seen, 0, 255).astype(np.uint8)
    # 경계에 남는 밝은 테두리를 1px 깎아낸다
    alpha = np.array(Image.fromarray(alpha).filter(ImageFilter.MinFilter(3)))
    return Image.fromarray(np.dstack([np.array(im)[:, :, :3], alpha]), "RGBA")


def bands(counts, min_run=20):
    """내용이 있는 구간들. 시트의 행·열 격자를 찾는 데 쓴다."""
    out, start = [], None
    for i, v in enumerate(counts):
        if v > 0 and start is None:
            start = i
        elif v == 0 and start is not None:
            if i - start >= min_run:
                out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(counts)))
    return out


def tight(image):
    ys, xs = np.where(np.array(image)[:, :, 3] > 0)
    return image.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def collar_width(image):
    """빨간 목줄의 가로폭. 포즈가 달라도 목 둘레는 변하지 않으므로 스케일 기준이 된다."""
    a = np.array(image).astype(np.int16)
    r, g, b, al = a[:, :, 0], a[:, :, 1], a[:, :, 2], a[:, :, 3]
    red = (al > 0) & (r > 140) & (r - g > 55) & (r - b > 55)
    ys, xs = np.where(red)
    band = np.bincount(ys, minlength=a.shape[0]).argmax()
    sel = xs[(ys >= band - 4) & (ys <= band + 4)]
    return sel.max() - sel.min() + 1


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sheet, standing = dekey(sys.argv[1]), dekey(sys.argv[2])

    a = np.array(sheet)[:, :, 3]
    rows = bands((a > 0).sum(axis=1))
    cols = bands((a > 0).sum(axis=0))
    print(f"격자 감지: {len(rows)}행 x {len(cols)}열 = {len(rows) * len(cols)}프레임")

    cut = [tight(sheet.crop((x0, y0, x1, y1)))
           for (y0, y1) in rows for (x0, x1) in cols]

    width = max(f.width for f in cut) + PAD_TOP * 2
    height = max(f.height for f in cut) + PAD_TOP * 2
    print(f"공통 캔버스 {width} x {height}")

    for index, frame in enumerate(cut, start=1):
        canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        canvas.alpha_composite(frame, ((width - frame.width) // 2, PAD_TOP))
        canvas.save(OUT / f"run-{index}.png")

    # 정지 포즈를 달리기 프레임과 같은 스케일로
    scale = collar_width(cut[0]) / collar_width(standing)
    stand = tight(standing)
    stand = stand.resize((round(stand.width * scale), round(stand.height * scale)),
                         Image.LANCZOS)
    floor = np.where(np.array(cut[0])[:, :, 3] > 0)[0].max() + PAD_TOP
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    canvas.alpha_composite(stand, ((width - stand.width) // 2, max(0, floor - stand.height)))
    canvas.save(OUT / "stand.png")

    print(f"저장: run-1..{len(cut)}.png, stand.png  (정지 포즈 배율 {scale:.3f})")


if __name__ == "__main__":
    main()
