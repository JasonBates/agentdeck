# If you switch the heading model to qwen3.8:27b

Written 19 Aug 2026, after measuring it. Self-contained on purpose — it assumes
you remember none of the eval's shorthand. `RESULTS.md` has the full working.

## The short version

**Change the model tag. Change nothing else.**

```
AGENTDECK_MODEL=qwen3.8:27b
```

in `~/Library/LaunchAgents/com.agentdeck.bridge.plist`, or edit the default
at `Sources/AgentDeckBridge/main.swift:64`. Then restart the bridge.

Do **not** also change the subtitle prompt. An earlier draft of this advice said
to, and the latency measurement killed it — see "The prompt change you don't
want" below.

## What the subtitle is, and why this matters

The middle line on a card. A local model writes it fresh on every prompt you
send, in eight words or fewer, to say what the session is doing right now.

It is hard because **37% of your real requests are eight words or fewer** and
name no work at all — `ok restarted`, `sure check please`, `ok install this for
me please`. The work those refer to is in the previous turn, not in what you
typed. This file calls those **thin prompts**, and they are the whole problem;
on the other 63% the subtitle was always adequate.

## What the numbers say

Scored 0–2 against 60 hand-written reference subtitles taken from real sessions
(2 = names the same step, 1 = right area wrong precision, 0 = wrong or vacuous).
Latency is the median of 8 warm runs, GPU otherwise idle.

| setup | thin prompts | all prompts | latency |
|---|---|---|---|
| **shipped today** — gemma4:12b | 1.04 | 1.22 | **1.91s** |
| **gemma4:12b → qwen3.8:27b** | **1.35** | 1.21 | 3.85s |

So: **+30% on the cases that were failing, no change on the rest, for +1.9s per
subtitle and 17 GB resident instead of 7.6 GB.**

Concretely, what the deck stops printing:

| you typed | shipped today | with qwen |
|---|---|---|
| `ok install this for me please` | `Software installation` | `Installing Corral globally on Mac Studio` |
| `ok bypass everyone for inbox` | `Bypass all recipients for inbox messages` | `Remove Cloudflare Access policy for inbox` |
| `how do you think you did` | `Self-evaluation of performance` | `Self-assessing Chapter 6 draft quality` |
| `ok restarted` | `Verify system restart status` | `Verifying keepalive warm-up after proxy restart` |

The second row is the one worth noticing: it was not merely vague but **wrong**.
"Everyone" was Cloudflare Access; the 12B model read it as email recipients.

## Why the model alone was never the answer

Worth keeping, because it is the thing that is easy to get backwards.

Before commit `a018106`, the prompt showed the model only your latest message.
On that prompt, qwen scores **0.73** on thin prompts and gemma scores **0.73** —
identical to two decimals. A model 2.3x the size bought exactly nothing, because
no amount of capability infers a conversation turn it was never shown.

`a018106` fixed the input: it added the agent's previous reply to the prompt.
That is what made the bigger model worth anything. Across the four prompt
variants that carry the previous reply, moving to qwen gains **+0.40** on thin
prompts; across the two that withhold it, **−0.05**.

**The input fix and the model upgrade are complements, not alternatives.** You
already have the first. This note is about the second.

## The prompt change you don't want

The shipped prompt (`Activity.swift:523`) carries two worked examples, including
a thin-prompt one (`"ok pulled it"`). Removing them scores slightly better with
qwen — 1.45 against 1.35 on thin prompts — which is why an earlier version of
this advice said to remove them.

Don't. That +0.10 sits exactly on this eval's stated noise floor, and the
examples make the model produce *shorter* output, so removing them costs
**+1.6s** (3.85s → 5.42s). Paying 40% more latency for a difference the
measurement cannot resolve is a bad trade.

The real finding underneath it is still worth knowing: worked examples help a
weak model and constrain a strong one. If a future model is faster, retest it —
`python3 run_gen.py --model <tag>` regenerates the whole comparison.

## Before you commit to it

1. **This measures subtitles only.** `AGENTDECK_MODEL` also drives card *titles*
   and *state summaries*, and neither was tested here. If you want to move only
   the subtitle, keep titles on the old model with
   `AGENTDECK_TITLE_MODEL=gemma4:12b` — there is no equivalent flag for state.
2. **The judge is imperfect.** Every score above comes from `gemma4:12b` grading
   against your reference answers; it agrees with your own hand-scoring 66% of
   the time and errs generous. Reading the 17 thin checkpoints by hand, qwen is
   clearly better on ~12, clearly worse on 1, level on the rest — so the
   direction holds, but treat gaps under 0.1 as nothing.
3. **One known regression.** On `ok alix is restarted`, qwen's subtitle is
   rejected outright by the existing gates, where the shipped prompt at least
   printed something.
4. **Memory.** 17 GB resident. Both models together is ~25 GB, comfortable on
   64 GB, so this is a tidiness decision rather than a capacity one.

## Reproducing any of it

```
cd Evals/subtitle
python3 run_gen.py --model qwen3.8:27b     # regenerate all 1260, any model
python3 report.py                          # the original gemma-only table
python3 judge_bias.py                      # why qwen cannot be the judge
```

Stored results: `results.jsonl` (gemma-written), `results_gen_qwen3-8_27b.jsonl`
(qwen-written), both 1260 rows, both judged by gemma4:12b.
