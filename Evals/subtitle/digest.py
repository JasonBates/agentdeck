"""Faithful Python port of AgentDeckBridge's transcript digest.

The subtitle prompt is only as good as what it is handed, so an eval that
reconstructs the digest loosely is really evaluating a different system. Every
filter here mirrors Sources/AgentDeckBridge/Transcript.swift exactly:
isRealPrompt, carriesIntent, flatten, the isMeta drop, the 400/1400 char clips
and the 5-user/2-assistant windows.

Unlike the bridge, this replays a finished transcript from the beginning and
emits the digest as it stood at each intent-carrying user prompt — the exact
moments the bridge would have regenerated a subtitle.
"""

import json
import re
from dataclasses import dataclass, field, asdict
from pathlib import Path

USER_TURNS = 5
ASSISTANT_TURNS = 2

# --- Transcript.swift: isRealPrompt -----------------------------------------

_PREFIX_DROP = (
    "Base directory for this skill",
    "# AGENTS.md instructions",
    "## Mem0 context",
    "This session is being continued from a previous conversation",
    "[Request interrupted by user",
    "[Image",
    "[Screenshot",
)
_MARKER_DROP = ("system-reminder", "command-name", "local-command",
                "tool_use_error", "Caveat:")


def is_real_prompt(text: str) -> bool:
    t = text.strip()
    if len(t) <= 8 or t.startswith("<") or t.startswith("{"):
        return False
    if t.startswith(_PREFIX_DROP):
        return False
    if t.startswith("http") and " " not in t:
        return False
    return not any(m in t for m in _MARKER_DROP)


# --- Transcript.swift: carriesIntent ----------------------------------------

_FILLER = {"claude", "codex", "pi", "there", "mate", "buddy",
           "again", "all", "cool", "please", "now", "then"}

_PLEASANTRIES = {
    "hi", "hey", "hello", "yo", "gm", "morning", "afternoon", "evening", "hiya",
    "good morning", "good afternoon", "good evening", "good day", "good night",
    "howdy", "greetings", "welcome back", "how are you", "how are things",
    "thanks", "thank you", "thanks so much", "cheers", "ta", "much appreciated",
    "appreciated", "nice one", "perfect", "great", "excellent", "lovely",
    "brilliant", "awesome", "amazing", "wonderful", "sounds good", "looks good",
    "ok", "okay", "k", "sure", "yes", "yep", "yeah", "yup", "no", "nope", "nah",
    "right", "fine", "got it", "understood", "noted", "agreed", "indeed",
    "no worries", "no problem", "np", "never mind", "nvm", "carry on",
    "go ahead", "go on", "continue", "proceed", "keep going", "done", "ready",
    "bye", "goodbye", "see you", "later", "good stuff", "well done", "nice",
}


def carries_intent(text: str) -> bool:
    t = text.strip()
    if len(t) > 40:
        return True
    words = [w for w in re.sub(r"[^0-9a-z]+", " ", t.lower()).split(" ") if w]
    if not words:
        return False
    core = [w for w in words if w not in _FILLER]
    if not core:
        return False
    return " ".join(core) not in _PLEASANTRIES


# --- Transcript.swift: message / flatten ------------------------------------

def _flatten(content) -> str | None:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [b["text"] for b in content
                 if isinstance(b, dict) and isinstance(b.get("text"), str)]
        joined = " ".join(parts)
        return joined or None
    return None


def _message(kind: str, obj: dict):
    if kind in ("claude", "pi"):
        if kind == "pi" and obj.get("type") != "message":
            return None
        if kind == "claude" and obj.get("isMeta") is True:
            return None
        m = obj.get("message")
        if not isinstance(m, dict):
            return None
        role, text = m.get("role"), _flatten(m.get("content"))
        if not isinstance(role, str) or text is None:
            return None
        return role, text
    if kind == "codex":
        if obj.get("type") != "response_item":
            return None
        p = obj.get("payload")
        if not isinstance(p, dict) or p.get("type") != "message":
            return None
        role, text = p.get("role"), _flatten(p.get("content"))
        if not isinstance(role, str) or text is None:
            return None
        return role, text
    return None


# --- Replay ------------------------------------------------------------------

@dataclass
class Checkpoint:
    """The digest as the bridge would have seen it at one subtitle regeneration."""
    session: str
    agent: str
    index: int                 # 1-based count of intent-carrying prompts so far
    opening: str
    requests: str              # oldest-first bullets, newest 5
    last_prompt: str
    prev_reply: str            # agent's last reply *before* this prompt
    recent: str
    # Not available to the bridge at generation time — kept for labelling only,
    # and for testing whether look-ahead-free variants can be matched.
    next_reply: str = ""
    gold: str = ""
    notes: str = ""


def turns(path: Path, kind: str = "claude"):
    """(role, text) for real conversation turns, oldest-first."""
    with path.open(errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            got = _message(kind, obj)
            if not got:
                continue
            role, raw = got
            text = raw.strip()
            if len(text) <= 2:
                continue
            yield role, text


def replay(path: Path, kind: str = "claude") -> list[Checkpoint]:
    """Emit one Checkpoint per intent-carrying user prompt, oldest-first."""
    users: list[str] = []          # intent-carrying, oldest-first
    social: list[str] = []
    assistants: list[str] = []     # oldest-first
    opening = ""
    out: list[Checkpoint] = []

    for role, text in turns(path, kind):
        if role == "user":
            if not is_real_prompt(text):
                continue
            clipped = text[:400]
            if not carries_intent(text):
                if len(social) < 2:
                    social.append(clipped)
                continue
            users.append(clipped)
            if not opening:
                opening = text[:300]

            # The bridge keeps the newest 5 user / 2 assistant turns.
            recent_users = users[-USER_TURNS:]
            recent_assts = assistants[-ASSISTANT_TURNS:]
            recent_lines = [f"USER: {u}" for u in reversed(recent_users)]
            recent_lines += [f"ASSISTANT: {a[:400]}" for a in reversed(recent_assts)]

            out.append(Checkpoint(
                session=str(path),
                agent=kind,
                index=len(users),
                opening=opening or (social[0] if social else ""),
                requests="\n".join(f"- {u}" for u in recent_users),
                last_prompt=clipped,
                prev_reply=(assistants[-1][:1400] if assistants else ""),
                recent="\n".join(recent_lines),
            ))
        elif role == "assistant":
            assistants.append(text)
            if out and not out[-1].next_reply:
                out[-1].next_reply = text[:1400]

    return out


def dump(cps: list[Checkpoint]) -> list[dict]:
    return [asdict(c) for c in cps]
