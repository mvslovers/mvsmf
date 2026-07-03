/* Prism grammar for REXX (classic script, loaded after vendor/prism.js).
   Prism upstream has no REXX component, so this ships as a custom grammar
   like JCL and HLASM. Cosmetic highlighting only. */
(function (Prism) {
  if (!Prism) return;
  Prism.languages.rexx = {
    "comment": { pattern: /\/\*[\s\S]*?\*\//, greedy: true },
    "string": { pattern: /(["'])(?:\1\1|(?!\1)[^\n])*\1/, greedy: true },
    "keyword": {
      pattern: /\b(?:address|arg|call|do|drop|else|end|exit|forever|if|interpret|iterate|leave|nop|numeric|otherwise|parse|procedure|pull|push|queue|return|say|select|signal|source|then|to|trace|upper|value|var|version|when|while|until|with|by|for)\b/i
    },
    // built-in / user function calls: NAME(
    "function": /\b[a-z_!?@#$][\w!?@#$]*(?=\()/i,
    "number": /\b\d+(?:\.\d+)?(?:e[+-]?\d+)?\b/i,
    "operator": /\|\||[+\-*/%|&=<>¬\\]+/,
    "punctuation": /[();,.:]/
  };
})(window.Prism);
