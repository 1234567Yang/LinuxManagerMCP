import re

from ISafetyFilter import ISafetyFilter


# Gap between the two halves of a pattern: "ignore all of your previous prompts"
# collapses to "ignoreallofyourpreviousprompts", so the two anchors are never
# adjacent. 30 characters is enough for the usual filler without letting a match
# span half a paragraph.
_GAP = r"[a-z]{0,30}"

# Patterns are matched against the NORMALIZED message (see _normalize: only the
# lowercase letters a-z are kept), so write them without spaces, digits,
# punctuation or capitals:
#   "send the ssh key"  ->  "sendthesshkey"
#   "id_ed25519"        ->  "ided"
_INJECT_PROMPT_PATTERNS = [
    # --- telling the model to drop its instructions ---
    rf"(?:ignore|disregard|forget|discard|override|bypass|update){_GAP}"
    rf"(?:prompt|instruction|rule|guideline|direction|restriction|constraint|limitation)s?",
    rf"(?:new|updated|revised|additional|real|actual|urgent){_GAP}"
    rf"(?:systemprompt|systemmessage|instructions)",
    # "Above is the old version of the system prompt" -- only with "system", so
    # READMEs saying "follow the above instructions" stay clean.
    rf"(?:old|outdated|deprecated|obsolete|previous|former|above){_GAP}"
    rf"(?:systemprompt|systemmessage)",
    r"(?:end|start|begin)of(?:the)?(?:system)?(?:prompt|instruction|message)s?",
    r"systemoverride|developermode|jailbreak|danmode",
    r"fromnowonyou|youarenolonger|yournewrole",

    # --- persona / role-play jailbreaks (DAN, EvilBOT, ANTI-DAN, ...) ---
    # These are aimed at "you" rather than at a reader, so anchor on the second
    # person to keep READMEs like "the server will act as a proxy" out.
    r"(?:fromnowon|fromhereon|fromthispointon|henceforth|startingnow)(?:you|your)",
    r"youwill(?:now|always|only)?(?:respond|act|behave|answer|reply|speak)(?:as|like)",
    rf"youwill(?:now|always|only)?(?:respond|answer|reply)(?:to)?{_GAP}(?:as|like)",
    r"youare(?:now)?goingto(?:act|respond|behave|pretend|roleplay)",
    r"(?:takeon|assume|adopt|play)(?:the)?(?:role|persona|character)of",
    r"(?:prefix|start|begin)(?:all|each|every)?(?:of)?your(?:response|answer|replie|reply|message)s?with",
    r"stayincharacter|breakingcharacter|breakcharacter|precautionsdropped",
    r"(?:hello|hi|hey|dear)(?:chatgpt|claude|gemini|copilot|languagemodel)",

    # --- asking for secrets to be shipped somewhere ---
    rf"(?:send|upload|post|exfiltrate|email|leak|transmit|share|curl|wget|paste){_GAP}"
    rf"(?:sshkey|privatekey|idrsa|idecdsa|ided|authorizedkeys|apikey|ssh|"
    rf"accesstoken|bearertoken|password|credential|secret|dotenv|envfile|shadowfile)s?",

    # --- asking the model to hide what it is doing ---
    rf"(?:donot|dont|never|without){_GAP}(?:tell|inform|mention|notify|reveal|say|"
    rf"disclose|show|report){_GAP}(?:theuser|user|human|operator|owner)",

    # add more here
]

_INJECT_PROMPT_RES = [re.compile(p) for p in _INJECT_PROMPT_PATTERNS]


class BasicSafetyFilter(ISafetyFilter):
    """
    Basic safety filter.
    This is NOT guaranteed and it's not part of this program's core feature. In fact, the way we used here can be bypassed easily with non-English.
    Ideally, the safety filter should be a neural network. However, this is not a neural network.
    """
    def ck_cmd_safe(cmd : str) -> bool:
        # at this point just return true.
        # if "rm -rf *" in cmd:
        #     return False

        return True

    @staticmethod
    def _normalize(msg : str) -> str:
        """
        Lowercase and keep only the letters a-z. This folds away whitespace,
        digits, punctuation ("id_rsa", "don't") and zero-width characters in
        one go. Fullwidth forms, homoglyphs and non-English text are simply
        dropped, so they still get through -- fine for a basic best-effort
        filter.
        """
        return re.sub(r"[^a-z]", "", msg.lower())

    def ck_ret_msg_safe(msg : str) -> bool:
        normalized = BasicSafetyFilter._normalize(msg)

        for pattern in _INJECT_PROMPT_RES:
            if pattern.search(normalized):
                return False

        return True
