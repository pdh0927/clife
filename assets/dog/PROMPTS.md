# Nano Banana 프롬프트

## 먼저 — 실패한 방법과 그 이유

첫 시도는 "6프레임 달리기 사이클을 한 장의 스프라이트 시트로" 였다. 결과는 **거의 같은
포즈 열 장**이었다. 측정해보니 발이 263px 캔버스에서 10px, 4%도 안 움직였다.

한 이미지 안에 여러 칸을 요구하면 모델은 그걸 "애니메이션"이 아니라 **"같은 캐릭터를
여러 번"** 으로 해석한다. 칸마다 다리 위치를 문장으로 못 박아도 이 경향은 잘 안 꺾인다.

**그래서 한 번에 한 포즈씩 뽑는다.** 한 장에 한 자세만 그리게 하면 다른 자세가 나올
수밖에 없다. 캐릭터 일관성은 기존 그림을 레퍼런스로 첨부해서 잡는다.

## 몇 장이 필요한가

**4장이면 충분하다.** 2장만 번갈아도 달리기로 읽힌다 — 픽셀 게임에서 오래 쓰인 방법이고,
46pt 크기에서는 다리 디테일보다 **극과 극의 대비**가 훨씬 중요하다.

| 장수 | 결과 |
|---|---|
| 2장 | 벌림 ↔ 오므림. 최소한이지만 확실히 달려 보인다 |
| **4장** | **권장.** 부드럽고 그릴 양도 적다 |
| 6~8장 | 더 부드럽지만 캐릭터 드리프트 위험이 커진다 |

---

## 공통 준비

**`assets/dog/run-1.png` 을 레퍼런스로 첨부한다.** 네 번 다 같은 파일을 첨부해야
같은 강아지가 나온다. 매번 직전 결과를 첨부하면 변형이 조금씩 누적된다.

각 프롬프트는 이 머리말로 시작한다:

```
The exact same cartoon puppy as the attached reference image. Identical
character, identical art style: same hand-drawn thick dark-brown outlines, same
tan-brown fur, same darker patch on the head, same cream belly, same red collar
with gold studs, same droopy muzzle, same sleepy half-closed eyes, same floppy
ears. Same side view, facing RIGHT. Same size, same proportions.

Draw it running, in this exact pose:
```

아래 포즈 중 하나를 이어 붙이고, 마지막에 이 마무리를 붙인다:

```
Keep the head, body and face exactly as in the reference — change ONLY the legs,
arms, ears and tail.

Transparent background, no ground, no shadow, no scenery, no text, no Chinese or
Korean characters, no watermark, no border. One character, centered, same size
as the reference.
```

---

## 포즈 4종

### 1 · 최대 벌림 (왼쪽 앞)

```
MID-STRIDE AT FULL EXTENSION. The left leg is thrown far FORWARD, knee high and
the paw reaching out well in front of the chest. The right leg is kicked far
BACKWARD behind the body, fully straightened. The gap between the two paws is as
wide as the dog's entire body. Both paws are OFF the ground — the dog is
airborne. The left arm swings back, the right arm swings forward. Ears flying
upward from the speed, tail streaming out behind.
```

### 2 · 지나감 (다리 모음)

```
LEGS PASSING EACH OTHER. Both legs are directly UNDER the body and close
together, almost touching, one just landing and the other swinging through. The
dog is at its most compact and lowest — crouched slightly, body compressed.
Arms close to the sides. Ears dropping down, tail low.
```

### 3 · 최대 벌림 (오른쪽 앞)

```
MID-STRIDE AT FULL EXTENSION, the MIRROR of the first pose. Now the RIGHT leg is
thrown far FORWARD, knee high and paw reaching out in front of the chest, and
the LEFT leg is kicked far BACKWARD behind the body, fully straightened. Paws as
far apart as the dog's whole body. Both paws OFF the ground. The right arm
swings back, the left arm swings forward. Ears flying upward, tail streaming.
```

### 4 · 공중에서 모음

```
AIRBORNE AND TUCKED. Both legs are gathered up tightly under the belly, knees
bent, paws tucked close to the body. The dog is at the TOP of its bounce, lifted
highest off the ground, body rounded and compact. Arms tucked in. Ears lifted by
the upward motion, tail curled up.
```

---

## 지친 포즈 (90% 초과용)

```
The exact same cartoon puppy as the attached reference image — identical
character and art style.

Now draw it STANDING STILL and worn out: slumped, head drooping, tongue lolling
out of its mouth, eyes closed in exhaustion, ears hanging flat and limp, arms
hanging at its sides. Tired from running but still cute.

Same side view facing RIGHT, same size as the reference. Transparent background,
no ground, no shadow, no text, no watermark.
```

---

## 받고 나서

네 장을 나란히 놓고 **다리만** 본다. 1번과 3번이 활짝 벌어지고 2번과 4번이 오므려져
있어야 한다. 넷이 비슷하면 그 장만 다시 뽑는다 — 개별 생성이라 한 장만 다시 돌리면 된다.

가공은 스크립트가 한다. 파일명은 상관없고, **준 순서가 곧 재생 순서**다:

```sh
python3 assets/dog/prepare.py --frames 1.png 2.png 3.png 4.png --stand tired.png
./setup.sh
```

배경 제거(체커보드가 그려져 나와도 처리된다), 정렬, 정지 포즈 스케일 맞춤, 파일명
정리까지 한 번에 한다.

## 규격

| 항목 | 값 | 이유 |
|---|---|---|
| 배경 | 투명이 최선, 단색 흰색도 괜찮다 | 스크립트가 테두리에서 flood fill 로 지운다 |
| 크기 | 한 장당 가로 500px 이상 | 줄여 쓰는 건 괜찮지만 늘리면 뭉개진다 |
| 방향 | 전부 **오른쪽** 바라보기 | 한 장이라도 반대면 그 프레임만 튄다 |
| 글자 | 없어야 한다 | 중국어·한국어가 딸려 나오는 경우가 흔하다 |
| 워터마크 | 없어야 한다 | 공개 레포에 들어간다 |

## 부록 — 시트로 한 번 더 시도하고 싶다면

개별 생성이 번거로우면 시트를 다시 노려볼 수는 있다. 다만 칸마다 다리 위치를 문장으로
못 박아야 하고, 그래도 실패할 수 있다. `--sheet` 로 넘기면 스크립트가 격자를 찾아 자른다:

```sh
python3 assets/dog/prepare.py --sheet sheet.png --stand tired.png
```
