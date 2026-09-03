"""Candidate subtitle prompts.

A is the shipped prompt, verbatim from Activity.swift generateSubtitle, including
its two input shapes (LATEST REQUEST when there is one, RECENT TURNS otherwise).
Everything else is a hypothesis about why the shipped one drifts toward the
project rather than the step:

  B  same inputs, atomic-step framing instead of "the specific task it is on now"
  C  B plus the agent's previous reply, so a thin prompt ("ok restarted",
     "sure check please") still has a step attached to it
  D  C plus two worked examples, including one thin-prompt case
  E  C plus a forced <verb> <object> shape, to pin the grain structurally

Each builder takes a checkpoint dict and returns the prompt string.
"""


def _title_line(title: str) -> str:
    if not title:
        return ""
    return f'The session\'s overall job is "{title}" — do not restate it.\n'


def _source(c: dict) -> str:
    if c["last_prompt"]:
        return "LATEST REQUEST:\n" + c["last_prompt"][:700]
    return "RECENT TURNS:\n" + c["recent"][:1200]


# --- A: shipped --------------------------------------------------------------

def variant_a(c: dict) -> str:
    return f"""A working session is moving through a series of requests.
{_title_line(c['title'])}In at most 8 words, name the specific task it is on now — the immediate
piece of work, not the project. Write impersonally, never "you" or "I".
Name the subject of the request, not the assistant's response to it: never
describe replying, greeting, acknowledging, helping or answering.
No quotes, no trailing period.

{_source(c)}

CURRENT TASK:"""


# --- B: atomic-step framing, same inputs -------------------------------------

def variant_b(c: dict) -> str:
    goal = c["title"] or "the session's larger goal"
    return f"""A working session is moving through a series of requests toward one larger goal.

THE LARGER GOAL: {goal}

Name the single concrete step now underway in service of that goal — one action
on one thing, of the size a person would tick off in a few minutes. Not the goal
itself, not a summary of the session, and never a restatement of the goal above.

In at most 8 words. Write impersonally, never "you" or "I". Name the subject of
the work, not the assistant's response to it: never describe replying, greeting,
acknowledging, helping or answering. No quotes, no trailing period.

{_source(c)}

CURRENT TASK:"""


# --- C: B plus the preceding reply -------------------------------------------

def _prev(c: dict) -> str:
    if not c["prev_reply"]:
        return ""
    return ("\nWHAT THE AGENT SAID JUST BEFORE THIS REQUEST (context only — do not\n"
            "describe the agent's reply itself, only the work it is about):\n"
            + c["prev_reply"][:900] + "\n")


def variant_c(c: dict) -> str:
    goal = c["title"] or "the session's larger goal"
    return f"""A working session is moving through a series of requests toward one larger goal.

THE LARGER GOAL: {goal}
{_prev(c)}
{_source(c)}

Name the single concrete step now underway in service of the larger goal — one
action on one thing, of the size a person would tick off in a few minutes. Not
the goal itself, and never a restatement of it.

If the latest request is short or is an answer to something the agent asked
("ok restarted", "yes do that", "sure check please"), the step is whatever that
answer sets in motion — read it out of the context above rather than describing
the words themselves.

In at most 8 words. Write impersonally, never "you" or "I". Name the subject of
the work, not the assistant's response to it: never describe replying, greeting,
acknowledging, helping or answering. No quotes, no trailing period.

CURRENT TASK:"""


# --- D: C plus worked examples ------------------------------------------------

def variant_d(c: dict) -> str:
    goal = c["title"] or "the session's larger goal"
    return f"""A working session is moving through a series of requests toward one larger goal.
Name the single concrete step now underway in service of that goal.

Two examples of the right size and shape:

  GOAL: Migrate the photo library to Postgres
  REQUEST: "the thumbnails are all coming out rotated 90 degrees"
  STEP: Fix rotated thumbnails in the importer

  GOAL: Tune the espresso grinder settings
  CONTEXT: the agent had just asked for a shot pulled at a finer grind
  REQUEST: "ok pulled it"
  STEP: Read the shot time at the finer grind

Notice the second one: a short answer names no work by itself, so the step comes
from what the answer sets in motion.

THE LARGER GOAL: {goal}
{_prev(c)}
{_source(c)}

One action on one thing, at most 8 words. Never restate the goal. Write
impersonally, never "you" or "I". Name the subject of the work, not the
assistant's response to it. No quotes, no trailing period.

STEP:"""


# --- E: forced verb + object --------------------------------------------------

def variant_e(c: dict) -> str:
    goal = c["title"] or "the session's larger goal"
    return f"""A working session is moving through a series of requests toward one larger goal.

THE LARGER GOAL: {goal}
{_prev(c)}
{_source(c)}

Name the single concrete step now underway in service of the larger goal.

Answer in exactly this shape: an imperative verb, then the one thing it acts on.
  Fix rotated thumbnails in the importer
  Add a retry to the upload queue
  Shorten the opening paragraph

If the latest request is short or answers something the agent asked, the step is
whatever that answer sets in motion — take it from the context above.

At most 8 words. Never restate the goal. Write impersonally, never "you" or "I".
Never describe replying, greeting, acknowledging, helping or answering.
No quotes, no trailing period.

CURRENT TASK:"""


# --- F: the shipped wording, plus context and examples ------------------------
#
# B (atomic reframing, no context) scored *below* the shipped prompt, while C
# (reframing + context) and D (+ examples) scored above it — so the gain looks
# like it comes from the inputs, not the reframing. F keeps the shipped
# sentence and adds only the two new ingredients, to say which it was.

def variant_f(c: dict) -> str:
    return f"""A working session is moving through a series of requests.
{_title_line(c['title'])}In at most 8 words, name the specific task it is on now — the immediate
piece of work, not the project. Write impersonally, never "you" or "I".
Name the subject of the request, not the assistant's response to it: never
describe replying, greeting, acknowledging, helping or answering.
No quotes, no trailing period.

If the latest request is short or answers something the agent asked
("ok restarted", "yes do that", "sure check please"), the task is whatever that
answer sets in motion — take it from the context, not from the words themselves.
For example, a session tuning a grinder whose agent had just asked for a shot at
a finer grind, given the request "ok pulled it", is on "Read the shot time at the
finer grind".
{_prev(c)}
{_source(c)}

CURRENT TASK:"""


# --- G: D, with the two rejection causes addressed directly -------------------

def variant_g(c: dict) -> str:
    goal = c["title"] or "the session's larger goal"
    return f"""A working session is moving through a series of requests toward one larger goal.
Name the single concrete step now underway in service of that goal.

Two examples of the right size and shape:

  GOAL: Migrate the photo library to Postgres
  REQUEST: "the thumbnails are all coming out rotated 90 degrees"
  STEP: Fix rotated thumbnails in the importer

  GOAL: Tune the espresso grinder settings
  CONTEXT: the agent had just asked for a shot pulled at a finer grind
  REQUEST: "ok pulled it"
  STEP: Read the shot time at the finer grind

Notice the second one: a short answer names no work by itself, so the step comes
from what the answer sets in motion.

THE LARGER GOAL: {goal}
{_prev(c)}
{_source(c)}

One action on one thing, at most 8 words. Start with a verb.

Two hard rules:
- Share no more than one significant word with the goal above. If the step you
  have in mind repeats the goal, you have named the goal — go narrower.
- Never begin with greet, acknowledge, respond, reply, answer, assist, help,
  welcome, thank, chat, converse, engage or introduce. Name the work, not the
  agent's response to it.

Write impersonally, never "you" or "I". No quotes, no trailing period.

STEP:"""


VARIANTS = {
    "A-shipped": variant_a,
    "B-atomic": variant_b,
    "C-context": variant_c,
    "D-examples": variant_d,
    "E-verbobj": variant_e,
    "F-shipped+ctx": variant_f,
    "G-hardened": variant_g,
}
