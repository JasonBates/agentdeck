# Subtitle eval — results

7 prompt variants × 60 checkpoints × 3 repeats = 1260 generations, `gemma4:12b`
at the bridge's own settings.

## The problem is the input, not the prompt

From the running deck's log, independent of anything hand-labelled here:

> Across the 25 sessions the bridge has titled, **83 of 227 intent-carrying
> prompts (37%) are eight words or fewer.**

`ok run that`, `no that doesn't work`, `sure check please` pass `carriesIntent` —
they are real requests, not pleasantries — so a subtitle is generated, from an
input that names no work. The shipped prompt sees `d.lastPrompt` and nothing
else, so on those turns it has nothing to work with and invents:

| prompt | shipped subtitle |
|---|---|
| `ok install this for me please` | Software installation |
| `done ... just approve tapped` | Approve tapped status |
| `how do you think you did` | Self-evaluation of performance |
| `simply put what's the decision` | Identify the final decision |
| `ok bypass everyone for inbox` | Bypass all recipients for inbox messages |

The last one is not merely vague — it is wrong. "Everyone" was Cloudflare Access;
the model read it as email recipients.

Two things this is **not**:

- Not the gates. All 60 hand-written gold subtitles pass `tidy`/`namesWork`/
  `distinct` at ≤8 words, and in production only 24 of 381 generations (6%) are
  rejected at all.
- Not the length cap. Zero `too-long` rejections in production.

## Variant scores

Mean over all 180 generations per variant, a gate rejection counting as 0
(on screen, a discarded subtitle and a wrong one are the same thing):

| variant | shown | mean | thin prompts | rest |
|---|---|---|---|---|
| **D — context + examples** | 96.1% | **1.22** | **1.04** | 1.29 |
| C — context, atomic framing | 93.3% | 1.16 | 0.96 | 1.23 |
| A — shipped | 99.4% | 1.14 | 0.73 | **1.30** |
| F — shipped wording + context + examples | 96.7% | 1.10 | 0.92 | 1.17 |
| G — D + hard anti-rejection rules | 97.2% | 1.04 | 0.98 | 1.07 |
| B — atomic framing, no context | 92.2% | 1.04 | 0.76 | 1.15 |
| E — forced `<verb> <object>` | 96.1% | 0.94 | 0.73 | 1.02 |

What the ordering says:

- **The gain is the inputs, not the phrasing.** B — the "atomic step in service
  of the goal" reframing with the same inputs — scores *below* the shipped
  prompt. Adding the preceding reply (C) recovers it; adding worked examples (D)
  passes it.
- **Constraining the shape backfires.** E, which forces `<verb> <object>`, is
  worst of the seven, and shortest (5.1 words): the model spends its budget on
  form and drops the qualifier that made the step identifiable.
- **Hardening against the gates backfires too.** G removes most rejections and
  loses more on quality than it gains — the extra rules crowd out the task.
- **On prompts that already name work, the shipped prompt is fine** (1.30, best
  of the seven). D costs −0.02 there, so this is not a trade.

## The decisive comparison, hand-scored

The judge is `gemma4` scoring its own output, so it was checked against 41
pairs I scored by hand: **66% exact agreement, 90% within one point, bias
−0.20**. Reliable at the ends — every hand-0 was judged 0 — and noise in the
middle, where hand-1 split 5/5/5 across all three grades. A binary re-judge
agreed 71%. That is enough to rank seven variants and not enough to separate
1.22 from 1.14.

A second, differently-noised opinion — the binary judge re-scoring all 1260
stored candidates on "same step, yes or no" — puts the ordering the same way:

| variant | same step | thin | rest |
|---|---|---|---|
| **D** | **65.6%** | **51.0%** | **71.3%** |
| C | 59.4% | 52.9% | 62.0% |
| B | 57.2% | 39.2% | 64.3% |
| A — shipped | 56.1% | 35.3% | 64.3% |
| G | 55.6% | 49.0% | 58.1% |
| F | 55.0% | 39.2% | 61.2% |
| E | 45.6% | 37.3% | 48.8% |

On thin prompts that is 35.3% → 51.0%, a 44% relative improvement.

So I hand-scored the claim the recommendation rests on: A against D on all 17
thin-prompt checkpoints (`hand_thin.json`).

| | shipped | D |
|---|---|---|
| mean (of 2) | 0.65 | **1.41** |
| useless (scored 0) | **8 of 17** | 2 of 17 |
| better on | 3 | **12** |

Both of D's zeros are gate rejections, not bad text — one of them
(`Verify inbox-zero sorting after restart`) was a perfectly good subtitle.

D's one real regression: `can I change the wake word` → `Identify wake word
configuration method`, where the shipped prompt's `Modifying the wake word
configuration` was better. Context pulled it toward the investigation the agent
was about to do rather than the change the user asked for.

## Tested and rejected: loosening `distinct()`

D loses one checkpoint to `too-close-to-title` on text that was right, which
suggested the gate over-fires when the step legitimately reuses the title's
subject. Two replacement rules were tried:

- *accept when the subtitle adds ≥2 words the title lacks* — on the eval set it
  recovers 40 rejections and loses 1, which looks like a clear win. Against the
  production log it would have shipped **22 of 24 real rejections**, nearly all
  genuine restatements (`Update the agentdeck readme` → `Update the readme file
  content`).
- *accept when the action word is new and ≥2 other words are new* — ships 7 of
  24 in production, of which only 2–3 name a genuinely different step.

Neither is worth it. `distinct()` stays as it is; the eval set alone would have
produced the wrong answer here.

## Caveats

- The eval set understates the problem: 28% of its checkpoints are thin prompts
  against 37% in production, because sampling at fixed fractions of session
  length happened to land on longer turns. The measured gain is a floor.
- Book sessions come from 07-26..07-28 rather than the technical window; pi
  sessions in August are single-shot and carry no multi-turn chapter work.
- Gold labels are mine, written from what the bridge can see at generation time.
- 60 checkpoints from 20 sessions is small. Differences under ~0.1 are noise.
- The replay always hands the subtitle the reply *before* the new prompt. Live,
  `digest.lastReply` is whatever is newest at that poll, so if the agent has
  already begun answering, the context is its reply to the current prompt
  instead. That is at least as good a source for the step, but it is not the
  thing that was measured.

## What this does not fix

The subtitle still regenerates only when a new user prompt arrives. Through a
ten-minute agentic turn it is frozen, however much the agent moves through. That
is a cadence question, not a prompt one — the `Activity` label already covers
mid-turn work, and making the subtitle track it would mean regenerating against
the visible screen rather than the transcript.

## An independent judge does not help (Aug 19)

The weakest joint above is that `gemma4:12b` graded candidates `gemma4:12b`
wrote. `qwen3.8:27b` was pulled to remove that — it wrote none of them — and
re-judged all 1260 stored candidates with the same two prompts, changing nothing
but the model. It fails, and the way it fails is worth keeping.

Against the same 41-pair hand set:

| judge | judge2 prompt | leniency-corrected prompt | error direction |
|---|---|---|---|
| `gemma4:12b` | **71%** | 66% | 10 false same, 4 false different |
| `qwen3.8:27b` | 59% | **68%** | **0 false same**, 13 false different |

As a 3-point judge it is worse still: 49% exact against gemma's 66%, bias −0.49,
and it collapses to the middle grade — 31 of 41 pairs judged 1, only 3 of 21
hand-2s graded 2. Across 82 verdicts it never once called two different steps
the same. It is not a worse reader; it is a stricter one, wrong in the opposite
direction, and `judge_bias.py` reproduces this.

Uniform strictness would still rank variants. This is not uniform — it is a
floor, and the floor sits under exactly the cases the eval exists to measure:

| variant | gemma same | qwen same | gemma thin | qwen thin |
|---|---|---|---|---|
| D — context + examples | **65.6%** | 13.3% | **26/51** | 3/51 |
| C — context | 59.4% | 19.4% | **27/51** | 4/51 |
| B — atomic framing | 57.2% | 15.6% | 20/51 | 3/51 |
| A — shipped | 56.1% | **21.1%** | 18/51 | 6/51 |
| G — hardened | 55.6% | 11.1% | 25/51 | 3/51 |
| F — shipped + context | 55.0% | 17.8% | 20/51 | 7/51 |
| E — forced verb-object | 45.6% | 5.0% | 19/51 | 0/51 |

Gemma spreads the seven variants across 18–27 of 51 on thin prompts. Qwen puts
all seven between 0 and 7. The orderings duly disagree — `D > C > B > A` against
`A > C > F > B > D` — and the second is a permutation of noise: A's "win" over D
on the thin prompts, the comparison this whole eval was built for, is **6 items
against 3**.

`hand_thin.json` settles it independently. Scored by hand over the same 17 thin
checkpoints, A averages **0.59** and D **1.41**. Qwen is contradicting the human
pass, not the self-marking model, and it does so on pairs that are the same step
by any reading — gold `Bypass Access on the webhook path` against D's `Disable
Cloudflare Access for inbox route`, hand-scored 2.00, judged different.

One hypothesis tested and rejected: that qwen punishes candidates more specific
than the gold. Its agreement *rises* with candidate length, 5.0% at four words
to 25.2% at eight, the same direction as gemma's, and D's mean length (6.4
words) barely exceeds A's (6.2).

So the conclusion is not that the ranking above is fragile. It is that
independence from the generator was never the binding constraint on the judge —
calibration was, and the 12B model is the better-calibrated one here. The hand
set was built to audit a self-marking judge; what it actually caught was an
independent judge failing harder. Two judges wrong in opposite directions are
still worth having: where a lenient and a strict grader agree, that agreement is
the cheapest available stand-in for a second hand pass over the disputed middle.

Reproduce with `judge_qwen.py` (re-judge), `judge_bias.py` (the bias table).

## The model and the input are complements, not alternatives (Aug 19)

Everything above holds the generator fixed at `gemma4:12b` and varies the
prompt. This varies the generator instead: all seven variants, all 60
checkpoints, three repeats, regenerated by `qwen3.8:27b` at the bridge's own
settings, judged by the same 3-point prompt. `run_gen.py` reproduces it.

The judge is `gemma4:12b` in both columns, which is worth noting in the
sceptical direction and turns out to favour the loser: in the gemma rows it is
marking its own work, in the qwen rows it is not. The self-marking column is the
one with the advantage, and it still loses.

| variant | writer | shown | mean | thin | rest | words |
|---|---|---|---|---|---|---|
| A — shipped | gemma | 99.4% | 1.14 | 0.73 | 1.30 | 6.2 |
| A — shipped | qwen | 96.1% | 1.21 | 0.73 | **1.40** | 5.4 |
| B — atomic | gemma | 92.2% | 1.04 | 0.76 | 1.15 | 6.6 |
| B — atomic | qwen | 95.0% | 1.12 | 0.67 | 1.29 | 5.5 |
| C — context | gemma | 93.3% | 1.16 | 0.96 | 1.23 | 7.0 |
| **C — context** | **qwen** | **97.2%** | **1.30** | **1.45** | 1.24 | 6.0 |
| D — context + examples | gemma | 96.1% | **1.22** | 1.04 | 1.29 | 6.4 |
| D — context + examples | qwen | 96.1% | 1.21 | 1.35 | 1.15 | 5.3 |
| E — forced verb-object | gemma | 96.1% | 0.94 | 0.73 | 1.02 | 5.1 |
| E — forced verb-object | qwen | 91.7% | 1.09 | 1.16 | 1.06 | 5.0 |
| F — shipped + context | gemma | 96.7% | 1.10 | 0.92 | 1.17 | 7.0 |
| F — shipped + context | qwen | 96.7% | 1.28 | 1.29 | 1.27 | 6.1 |
| G — hardened | gemma | 97.2% | 1.04 | 0.98 | 1.07 | 6.5 |
| G — hardened | qwen | 98.3% | 1.20 | 1.41 | 1.12 | 4.9 |

Every one of the five best thin-prompt scores is a qwen row. The best gemma
manages anywhere is 1.04.

**A bigger model alone fixes nothing.** On the shipped prompt, qwen scores 0.73
on thin prompts — identical to gemma to two decimals. The missing turn is
missing for both; no amount of capability infers a turn that was never shown.
That is the finding at the top of this file, holding under a direct test rather
than an argument.

**But the two changes are complements, and the split is exactly whether the
prompt carries the preceding reply:**

| | thin, gemma → qwen |
|---|---|
| no context (A, B) | −0.05 average |
| context (C, D, F, G) | **+0.40 average** |

So `gemma4:12b` was under-exploiting context it was already being handed. C
gives both models the same preceding reply; the 12B model gets 0.96 out of it
and the 27B model gets 1.45.

**Worked examples help a weak model and constrain a strong one.** D's two
examples lift gemma (0.96 → 1.04 on thin) and cost qwen (1.45 → 1.35 thin,
1.24 → 1.15 rest). The same reversal appears at G, worst-but-one for gemma at
1.04 mean and third best for qwen at 1.20, with the highest shown rate in the
table — the extra rules that "crowd out the task" only crowd it out when the
budget is tight. D's recommendation above was tuned to a model, not to the task.

That is a real effect and still **not** a reason to drop the examples if the
generator changes: +0.10 on thin sits exactly on this file's own noise floor,
and the examples shorten the output, so removing them costs +1.6s of latency
(below). Switching model alone is the whole recommendation. See
`MODEL-SWITCH.md`.

Read by hand, the thin checkpoints look better than 1.45 suggests: C/qwen is
clearly better on about 12 of 17, clearly worse on 1, level on the rest. The
worked example at the top of this file is among the fixed ones —

    ok bypass everyone for inbox
    gold      Bypass Access on the webhook path
    shipped   Bypass all recipients for inbox messages
    C/qwen    Remove Cloudflare Access policy for inbox

as are `Software installation` → `Installing Corral globally on Mac Studio`,
`Self-evaluation of performance` → `Self-assessing Chapter 6 draft quality`, and
`Verify system restart status` → `Verifying keepalive warm-up after proxy
restart`. The `Module` / `Movement` slip is gone too. One clear regression:
`ok alix is restarted` is rejected by the gates under C/qwen, where the shipped
prompt at least showed something.

Qwen also writes shorter while scoring higher — 4.9–6.1 words against 5.1–7.0 —
so the gain is density, not room.

What it costs. 17 GB resident against 7.6 GB, and latency measured warm with
both models loaded and the GPU otherwise idle (median of 8):

| generator | A | C | **D — shipped** |
|---|---|---|---|
| `gemma4:12b` | 1.02s | 1.95s | **1.91s** |
| `qwen3.8:27b` | 2.17s | 5.42s | **3.85s** |

Note which row is live. Commit `a018106` put **D** into `Activity.swift`, so the
shipped baseline is D at 1.91s and the change on the table is D/gemma → D/qwen:
**1.91s → 3.85s, +1.9s per subtitle**, for thin 1.04 → 1.35. C is *slower* than
D for qwen despite the shorter prompt, because D's examples shorten the output
and generation dominates — which is the second reason not to drop them.

Caveats: the judge agrees with the hand set 66% exactly and is lenient, so
treat 0.10 gaps as noise — C over D for qwen is *not* established, only that
examples stop paying. 51 thin items per cell. Gold labels unchanged.
