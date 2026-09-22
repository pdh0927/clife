#!/usr/bin/env python3
"""앱 아이콘(Dock·Finder·알림에 뜨는 것)을 만든다.

메뉴바 아이콘은 여기서 만들지 않는다 — 그건 `src/main.swift` 가 코드로 그리는
이중 링이다. 이 파일이 만드는 건 그보다 큰 자리에 뜨는 그림이고, 알림 왼쪽에
나오는 것도 이것이다.

    python3 make_icon.py && iconutil -c icns AppIcon.iconset

이전 버전은 슬레이트 바탕에 흰 게이지 링이었는데, 알림 크기로 줄면 톱니바퀴처럼
보였다. 지금은 앱 안에서 달리는 그 강아지를 그대로 쓴다 — 아이콘과 내용물이 같은
캐릭터여야 알림이 어디서 왔는지 한눈에 읽힌다.
"""
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
RADIUS = 225          # macOS 스퀘어클에 가까운 값
DOG = Path("assets/dog/run-1.png")

# 강아지 팔레트에서 뽑은 따뜻한 배경. 위가 밝고 아래로 살짝 가라앉는다.
TOP = (255, 241, 219)
BOTTOM = (243, 214, 176)
TRACK = (214, 176, 134)

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# 세로 그라데이션을 한 번 그린 뒤 둥근 사각형으로 마스킹한다
gradient = Image.new("RGBA", (1, SIZE))
for y in range(SIZE):
    t = y / (SIZE - 1)
    gradient.putpixel((0, y), tuple(
        round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,))
gradient = gradient.resize((SIZE, SIZE))

mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=RADIUS, fill=255)
img.paste(gradient, (0, 0), mask)

# 강아지가 달리는 트랙. 앱의 은유(달린 거리 = 사용량)를 아이콘에도 한 줄로 남긴다.
draw = ImageDraw.Draw(img)
track_y = 790
draw.rounded_rectangle([150, track_y, SIZE - 150, track_y + 34], radius=17, fill=TRACK)

dog = Image.open(DOG).convert("RGBA")
bbox = dog.getbbox()
dog = dog.crop(bbox)

# 트랙 위에 발을 딛도록 아래를 기준으로 앉힌다
target_width = 720
scale = target_width / dog.width
dog = dog.resize((target_width, round(dog.height * scale)), Image.LANCZOS)
img.alpha_composite(dog, ((SIZE - dog.width) // 2, track_y + 26 - dog.height))

img.save("icon_source.png")

# iconset 도 같이 만들어 둔다 — iconutil 이 바로 먹을 수 있게
iconset = Path("AppIcon.iconset")
iconset.mkdir(exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale, suffix in ((1, ""), (2, "@2x")):
        px = size * scale
        img.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{size}x{size}{suffix}.png")

print("saved icon_source.png and AppIcon.iconset/")
