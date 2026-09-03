# Subtitle eval

The subtitle is the middle heading on a card: the immediate task, regenerated
once per user prompt from that prompt alone. It is the weakest of the three,
and this measures why.

## The complaint

The subtitle should track the **atomic action** underway in service of the
title's larger goal. It often doesn't, because of what it is built from.
`generateSubtitle` sees the latest user request and nothing else — and a large
share of real requests name no work at all:

```
$ python3 prodcheck.py
227 intent-carrying prompts, of which 83 (37%) are <=8 words
```

That number comes from the running deck's own log, not from this eval's
labels. `ok run that`, `no that doesn't work`, `sure check please` all pass
`carriesIntent` — they are genuine requests, not pleasantries — so a subtitle
is generated, and there is nothing in the input to generate it from. The step
those answers set in motion is in the turn *before* them, which the shipped
prompt never sees.

## What is measured

Twenty real sessions, replayed. Technical work comes from 08-08..08-16; the
book half reaches back to 07-26..07-28, where multi-turn chapter work actually
happened. Both matter — one prompt serves all three agents and both domains.

- `digest.py` — line-by-line port of `Transcript.swift`. Same `isRealPrompt`,
  `carriesIntent`, `flatten`, `isMeta` drop, same 5-user/2-assistant window and
  400/1400-char clips. A variant that wins against a loose reconstruction has
  not won.
- `extract.py` — replays each session and emits the digest as it stood at three
  prompts spread across its length (25%, 55%, 85%), skipping prompt 1 where the
  subtitle is the title by construction. 60 checkpoints.
- `titles.py` — generates the title each checkpoint would have carried, with the
  shipped title prompt. The subtitle is prompted with its title and rejected for
  overlapping it, so inventing titles would measure a different system.
- `gold.json` — hand-written reference subtitles: the atomic action underway,
  derived only from what the bridge can see at generation time. All 60 pass the
  shipped gates at <=8 words, which is itself a finding — the gates are not what
  limits the subtitle.
- `variants.py` — the shipped prompt plus four hypotheses.
- `model.py` — same endpoint, `think:false`, temperature 0.1, `num_ctx` 4096,
  and exact ports of `tidy`, `namesWork` and `distinct`.
- `run.py` — every variant x checkpoint x 3 repeats, scored two ways.

## Scoring

Kept deliberately separate:

- **gates** — deterministic and exactly the bridge's. A subtitle rejected by
  `tidy`/`namesWork`/`distinct` never reaches the screen, so a variant with a
  good average and a bad rejection rate has not won.
- **match** — `gemma4:12b` judging the surviving subtitle against the gold:
  2 same step, 1 right area wrong grain, 0 wrong or too vague. The judge is the
  model being judged, so `judge_audit.py` checks it against a hand-scored
  stratified sample before any conclusion rests on it.

Means count a rejected generation as 0: on screen, a discarded subtitle and a
wrong one are the same thing.

## Running it

```bash
python3 extract.py      # sessions   -> checkpoints.json
python3 titles.py       # + the title each checkpoint carried
python3 run.py          # -> results.jsonl (resumable; ~45 min for 900 cells)
python3 report.py       # summary; --examples for per-checkpoint output
python3 judge_audit.py --sample 40 > sheet.txt   # then fill hand.json
python3 judge_audit.py  # judge vs hand agreement
```

`run.py` appends and skips completed cells, so it can be interrupted.

## Results

See `RESULTS.md`.
