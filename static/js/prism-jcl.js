/* Prism grammar for MVS JCL (classic script, loaded after vendor/prism.js).
   Cosmetic highlighting only — no attempt at full JCL parsing. */
(function (Prism) {
  if (!Prism) return;
  Prism.languages.jcl = {
    // //* comment statements and JES2 control cards (/*XEQ, /*ROUTE, …)
    "comment": [
      { pattern: /^\/\/\*.*$/m },
      { pattern: /^\/\*[A-Z$].*$/m }
    ],
    // quoted parameter values ('' = escaped quote)
    "string": { pattern: /'(?:''|[^'\n])*'/, greedy: true },
    // //NAME field at the start of a statement (includes the slashes)
    "statement-name": { pattern: /^\/\/[A-Z0-9@#$.]{0,17}/m, alias: "property" },
    // operation field: JOB / EXEC / DD / …
    "operation": {
      pattern: /\b(?:JOB|EXEC|DD|PROC|PEND|SET|IF|THEN|ELSE|ENDIF|INCLUDE|JCLLIB|OUTPUT|CNTL|ENDCNTL|COMMAND|XMIT)\b/,
      alias: "keyword"
    },
    // KEYWORD= parameters
    "parameter": { pattern: /\b[A-Z@#$][A-Z0-9@#$]*(?==)/, alias: "attr-name" },
    // &SYMBOLIC and &&TEMPDS
    "symbolic": { pattern: /&&?[A-Z@#$][A-Z0-9@#$]*/, alias: "variable" },
    "number": /\b\d+\b/,
    "punctuation": /[,=()*]/
  };
})(window.Prism);
