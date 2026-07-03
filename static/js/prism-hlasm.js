/* Prism grammar for S/370 assembler (HLASM-style; classic script, loaded
   after vendor/prism.js). Cosmetic highlighting only. */
(function (Prism) {
  if (!Prism) return;
  Prism.languages.hlasm = {
    // '*' in column 1 = comment line; '.*' = macro comment
    "comment": [
      { pattern: /^\*.*$/m },
      { pattern: /^\.\*.*$/m }
    ],
    // quoted operands ('' = escaped quote); also X'..' C'..' B'..' constants
    "constant": { pattern: /\b[XCBP]'(?:''|[^'\n])*'/i, alias: "number" },
    "string": { pattern: /'(?:''|[^'\n])*'/, greedy: true },
    // name field in column 1 (labels, macro names, &SETC symbols)
    "label": { pattern: /^[A-Z@#$&.][A-Z0-9@#$_]*/m, alias: "function" },
    // operation field: mnemonic after the name field (or leading blanks)
    "operation": {
      pattern: /(^(?:[A-Z@#$&.][A-Z0-9@#$_]*)?[ \t]+)[A-Z][A-Z0-9]*/m,
      lookbehind: true,
      alias: "keyword"
    },
    // &SYMBOLIC variables
    "symbolic": { pattern: /&[A-Z@#$][A-Z0-9@#$]*/, alias: "variable" },
    // R0..R15 register equates
    "register": { pattern: /\bR1[0-5]\b|\bR\d\b/, alias: "variable" },
    "number": /\b\d+\b/,
    "punctuation": /[,=()+*\-]/
  };
})(window.Prism);
