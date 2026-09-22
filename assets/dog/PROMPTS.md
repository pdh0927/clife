# Nano Banana 프롬프트

목표는 **달리기 사이클 6프레임 + 앉아 쉬는 포즈 1장**. `README.md` 의 방식 1.

그림체는 **메신저 이모티콘(카카오톡·위챗 스티커)** 이다. 플랫 벡터 아이콘이 아니라,
손으로 그린 듯한 두꺼운 갈색 외곽선에, 네 발로 신나게 달리는 통통한 강아지.

## 핵심 전략 — 한 장으로 뽑는다

프레임을 따로 생성하면 캐릭터가 조금씩 달라져서 애니메이션이 깜빡인다.
**스프라이트 시트 한 장으로 생성하면 일관성이 공짜로 따라온다** — 한 번의 생성 안에서는
같은 캐릭터가 유지되기 때문이다. 시트를 자르는 건 내가 한다.

---

## 1. 달리기 사이클 (첫 번째로 이것부터)

> **한 번 실패한 지점.** "6 frames of a smooth running cycle" 처럼 추상적으로 말하면
> 모델이 안전하게 **거의 같은 포즈를 여섯 번** 그린다. 실제로 받은 시트는 다리
> 가로폭이 185~206px 로 ±5% 만 변했다 — 진짜 갤럽이면 50% 넘게 출렁인다.
> 그래서 **칸마다 다리 위치를 문장으로 못 박는다.** 이게 이 프롬프트의 핵심이다.

```
A sprite sheet in the style of a Korean KakaoTalk / Chinese WeChat messenger
emoticon sticker: one cute cartoon puppy running, drawn as 6 frames in ONE
horizontal row, evenly spaced, left to right.

CHARACTER (identical in all 6 frames)
A chubby round puppy in side view, facing RIGHT. Chibi proportions — big round
head, plump body, short stubby legs, short tail. Droopy pug-like muzzle, sleepy
half-closed eyes, two long floppy ears, a red collar with small gold studs, warm
tan-brown fur, a darker brown patch on the head, a cream-beige belly.

STYLE
Hand-drawn messenger sticker look. Thick, slightly uneven dark-brown outlines.
Completely flat fill colours, NO gradients, NO shading, NO texture. Bold and
simple enough to stay readable when shrunk very small.

THE 6 FRAMES — the legs MUST be in dramatically different positions in each one.
Each frame must have a clearly different silhouette. Do NOT repeat a pose.

Frame 1: legs at MAXIMUM SPREAD — front leg thrown far forward, back leg kicked
         far behind, the gap between the paws as wide as the dog's whole body.
         Both paws off the ground.
Frame 2: front paw striking the ground, back leg swinging forward, legs about
         half as far apart as frame 1.
Frame 3: legs CROSSED and close together directly under the body, almost
         touching, the dog at its most compact.
Frame 4: the opposite of frame 1 — the other front leg thrown far forward, the
         other back leg kicked far behind, maximum spread again.
Frame 5: mirror of frame 2 — the other front paw striking the ground.
Frame 6: legs gathered tightly under the body, airborne, the whole dog lifted
         highest off the ground.

Also vary across the frames: the ears flap up and down, the tail swings, the body
rises and falls. But the dog stays in the same spot inside its cell — only the
limbs and ears move.

CRITICAL
Transparent background — actual alpha transparency, NOT a drawn checkerboard
pattern. No ground, no shadow, no scenery, no text, no Chinese or Korean
characters, no watermark, no frame borders, no numbers, no grid lines. All 6
cells identical in size, the dog the same size and at the same height in each.
```

**비율**: 가로로 긴 것. `6:1` 이 안 되면 `16:9`.

### 받고 나서 30초 안에 확인할 것

6칸을 나란히 놓고 **다리만** 본다. 1·4번 칸의 다리가 활짝 벌어지고 3·6번 칸이
오므려져 있으면 성공이다. 여섯 칸이 다 비슷해 보이면 **다시 돌린다** — 재생 속도로는
고칠 수 없다. 프레임에 없는 움직임은 어디서도 생기지 않는다.

시트가 계속 비슷하게만 나오면 아래 3번(프레임별 개별 생성)으로 간다. 느리지만 확실하다.

### 배경이 체커보드로 나오면

투명 배경을 요구해도 **투명해 보이는 무늬를 그려서** 주는 경우가 흔하다(실제로 겪었다).
알파는 전부 불투명인데 눈으로만 투명해 보인다. 그래도 괜찮다 — `prepare.py` 가
테두리에서 flood fill 로 배경만 지운다. 단색 흰 배경도 마찬가지로 처리된다.

---

## 2. 앉아서 쉬는 포즈 (90% 초과용)

**1번 결과 이미지를 레퍼런스로 첨부하고** 이걸 쓴다. 첨부해야 같은 캐릭터가 나온다.

```
The exact same messenger-sticker puppy from the reference image — same
hand-drawn thick brown outlines, same tan fur, same dark patch, same cream
belly, same red collar with gold studs, same floppy ears, same chibi
proportions, same flat colours.

Now draw it SITTING DOWN and worn out, full side profile facing RIGHT: sitting
back on its haunches, front legs straight and propping it up, head drooping a
little, tongue lolling far out of its open mouth, eyes closed in happy
exhaustion, ears hanging flat and limp. Tired from running but still cheerful
and cute.

One character, centered, same size as in the reference. Transparent background,
no ground, no shadow, no scenery, no text, no watermark.
```

---

## 3. 그래도 프레임이 흔들리면

시트가 고르지 않게 나오면, 1번 결과에서 **가장 잘 나온 한 프레임**을 골라
레퍼런스로 첨부하고 포즈만 바꿔가며 한 장씩 받는다:

```
The exact same messenger-sticker dog character from the reference image — same
style, same colours, same hand-drawn outlines, same collar, same patch,
same floppy ears, same tongue.

Same full side profile facing RIGHT, same size, same position in frame.
Running on all four legs. Change ONLY the legs, ears and tail: <포즈>

Transparent background, no ground, no shadow, no text, no watermark.
```

`<포즈>` 자리에 하나씩:

1. `front legs reaching far forward and back legs stretched far back, all four paws off the ground, body stretched long`
2. `front paws touching down, back legs swinging forward under the belly`
3. `front legs planted on the ground, back legs gathered under the body, back arched`
4. `back paws planted, body pushing forward over them, front legs lifting off`
5. `pushing off powerfully, body rising, front legs reaching forward`
6. `all four legs tucked under the body, airborne at the top of the bounce, body compressed and round`

## 넘기기 전 체크

| | |
|---|---|
| 배경 | 투명이거나 완전히 균일한 단색. 그라데이션 배경이면 키잉이 지저분해진다 |
| 크기 | 가로 최소 1800px (6프레임 시트 기준). 잘라서 프레임당 300px |
| 위치 | 프레임마다 강아지가 같은 높이·같은 크기. 이게 어긋나면 제자리에서 덜덜 떤다 |
| 방향 | 전부 **오른쪽** 바라보기. 한 장이라도 반대면 그 프레임만 튄다 |
| 글자 | 중국어·한국어 글자가 같이 나오는 경우가 많다. 없어야 한다 |
| 워터마크 | 없어야 한다. 공개 레포에 들어간다 |

받으면 `assets/dog/` 에 넣지 말고 **원본 그대로 주면 된다** — 자르기·배경 제거·리사이즈는
내가 하고, 규격에 맞춰 `run-1.png` … `run-6.png`, `stand.png` 로 정리한다.

## 참고 — 네 발 측면이 은유와 맞는 이유

앱은 강아지가 **트랙 위를 달린 거리**로 사용량을 말한다. 완전 측면으로 달리는 네 발
캐릭터는 그 은유를 가장 직접적으로 보여준다 — 왼쪽에서 출발해 오른쪽 결승선(한도)으로
가는 그림이 그대로 성립한다. 정면을 보는 포즈였다면 트랙 위를 달릴 수 없어서 강아지가
숫자 옆 장식이 됐을 것이다.
