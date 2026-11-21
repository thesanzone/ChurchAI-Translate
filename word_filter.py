"""Swear-word filter for Church AI Translation.

Reads word_filter.txt (shared with the Swift app) and cleans text so that no
blocked word is ever spoken, shown in captions or saved to a transcript.
See word_filter.txt for how the list works.
"""
import os
import re
import unicodedata

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LIST = os.path.join(SCRIPT_DIR, "word_filter.txt")

# A "word" is a run of letters (any language, incl. accents) plus inner apostrophes
_WORD = re.compile(r"[^\W\d_]+(?:'[^\W\d_]+)*", re.UNICODE)


def normalize(word):
    """Lowercase and strip accents: 'Cabrón' -> 'cabron'."""
    decomposed = unicodedata.normalize("NFD", word.lower())
    return "".join(c for c in decomposed if unicodedata.category(c) != "Mn")


def _match_case(original, replacement):
    if original.isupper() and len(original) > 1:
        return replacement.upper()
    if original[:1].isupper():
        return replacement[:1].upper() + replacement[1:]
    return replacement


class WordFilter:
    def __init__(self, path=DEFAULT_LIST):
        self.blocked_exact, self.blocked_prefixes = set(), []
        self.allowed, self.replacements = set(), {}
        self.path = path
        self.loaded = False
        if os.path.exists(path):
            self._load(path)
            self.loaded = True

    def _load(self, path):
        section = None
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                if line.startswith("[") and line.endswith("]"):
                    section = line[1:-1].strip().lower()
                    continue
                if section == "allow":
                    self.allowed.add(normalize(line))
                elif section == "replace" and "=>" in line:
                    risky, safe = (s.strip() for s in line.split("=>", 1))
                    if risky and safe:
                        self.replacements[normalize(risky)] = safe
                elif section == "block":
                    if line.endswith("*"):
                        self.blocked_prefixes.append(normalize(line[:-1]))
                    else:
                        self.blocked_exact.add(normalize(line))

    def is_blocked(self, word):
        w = normalize(word)
        if w in self.allowed:
            return False
        return w in self.blocked_exact or any(w.startswith(p) for p in self.blocked_prefixes)

    def clean(self, text, mask="•••"):
        """Return (clean_text, number_of_words_changed).

        Risky words are replaced with safe ones; blocked words become `mask`
        (use mask="" to drop them, e.g. for the Spanish voice and captions).
        """
        if not text:
            return text, 0
        changed = 0

        def fix(m):
            nonlocal changed
            word = m.group(0)
            key = normalize(word)
            if key in self.allowed:
                return word
            if key in self.replacements:
                changed += 1
                return _match_case(word, self.replacements[key])
            if self.is_blocked(word):
                changed += 1
                return mask
            return word

        out = _WORD.sub(fix, text)
        if changed and mask == "":
            # Tidy spacing and punctuation left behind by removed words
            out = re.sub(r"\s{2,}", " ", out)
            out = re.sub(r"\s+([,.;:!?])", r"\1", out)
            out = re.sub(r"[,;:]+([.!?])", r"\1", out)          # "vino,." -> "vino."
            out = re.sub(r"([¿¡])([?!])", "", out)              # empty "¡!" left behind
            out = re.sub(r"([¿¡])\s+", r"\1", out)
            out = re.sub(r"^[\s,;:]+", "", out).strip()
            if not _WORD.search(out):
                out = ""
        return out, changed

    def spanish_words_for_model(self):
        """Spanish-looking blocked/risky words, for blocking inside the translation model."""
        words = set(self.blocked_exact) | set(self.replacements.keys())
        return sorted(w for w in words if w not in self.allowed)
