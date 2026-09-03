"""Ollama client and guards, matching Activity.swift exactly.

Same endpoint, same /api/chat with think:false, same temperature 0.1 and
num_ctx 4096, same tidy() and the same two subtitle guards. A variant that only
wins because the harness was more forgiving than the bridge is not a win.
"""

import json
import re
import urllib.request

ENDPOINT = "http://127.0.0.1:11434/api/chat"
MODEL = "gemma4:12b"

SUBTITLE_MAX_CHARS = 130   # Activity.swift generateSubtitle
SUBTITLE_MAX_TOKENS = 32


def call(prompt: str, model: str = MODEL, max_tokens: int = SUBTITLE_MAX_TOKENS,
         temperature: float = 0.1, timeout: int = 60) -> str:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "think": False,
        "stream": False,
        "keep_alive": "30m",
        "options": {
            "temperature": temperature,
            "num_predict": max_tokens,
            "num_ctx": 4096,
        },
    }
    req = urllib.request.Request(
        ENDPOINT, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        obj = json.loads(r.read())
    return (obj.get("message", {}).get("content") or "").strip()


# --- Activity.swift: tidy ----------------------------------------------------

# Exactly the four Activity.swift strips — no more. A variant prompt that ends
# with a different cue word gets no cleanup the bridge would not give it.
_MARKERS = ("LABEL:", "NAME:", "FOCUS:", "STATE:")


def tidy(raw: str, max_chars: int = SUBTITLE_MAX_CHARS,
         multiline: bool = False) -> tuple[str | None, str | None]:
    """Returns (text, rejection_reason)."""
    s = raw.strip()
    for m in _MARKERS:
        i = s.upper().find(m)
        if i >= 0:
            s = s[i + len(m):].strip()
    if multiline:
        s = " ".join(x.strip() for x in s.splitlines() if x.strip())
    else:
        s = s.splitlines()[0] if s.splitlines() else s
    s = s.strip("\"'`“” ")
    if not multiline:
        s = s.strip(". ")
    if len(s) <= 3:
        return None, "too-short-or-empty"
    if len(s) > max_chars:
        return None, "too-long"
    return s, None


# --- Activity.swift: namesWork ----------------------------------------------

ASSISTANT_ACTIONS = {
    "greet", "greeting", "greets", "acknowledge", "acknowledging", "acknowledges",
    "respond", "responding", "reply", "replying", "answer", "answering",
    "assist", "assisting", "help", "helping", "welcome", "welcoming",
    "thank", "thanking", "apologize", "apologise", "chat", "chatting",
    "converse", "conversing", "engage", "engaging", "introduce", "introducing",
}


def names_work(heading: str) -> bool:
    words = [w for w in re.split(r"[^0-9A-Za-z]+", heading.lower()) if w]
    return not words or words[0] not in ASSISTANT_ACTIONS


# --- Activity.swift: distinct ------------------------------------------------

def _sig(s: str) -> set[str]:
    return {w for w in re.split(r"[^0-9A-Za-z]+", s.lower()) if len(w) > 3}


def distinct(subtitle: str, title: str | None) -> bool:
    """Mirrors Activity.swift: reject when >=60% of the title's >3-char words recur."""
    if not title:
        return True
    t = _sig(title)
    if not t:
        return True
    shared = len(t & _sig(subtitle))
    return shared / len(t) < 0.6


def guard(text: str, title: str | None) -> tuple[str | None, str | None]:
    """Full subtitle acceptance path: tidy -> namesWork -> distinct."""
    s, why = tidy(text)
    if s is None:
        return None, why
    if not names_work(s):
        return None, "assistant-action"
    if not distinct(s, title):
        return None, "too-close-to-title"
    return s, None
