Resolve GitHub issue #$ARGUMENTS end-to-end. Follow these steps strictly:

1. **Read the issue:**
   Run: `gh issue view $ARGUMENTS --repo mvslovers/mvsmf`

2. **Check for spec:**
   If the issue has label `uss-phase1`, read `doc/uss-spec.md` before proceeding. It contains the authoritative architecture decisions, error code mappings, encoding rules, and I/O patterns.

3. **Create a feature branch:**
   Run: `git checkout main && git pull && git checkout -b issue-$ARGUMENTS-<short-description>`
   Use a short kebab-case description derived from the issue title.

4. **Update Notion status to "In Progress":**
   Search Notion for the issue: query "#$ARGUMENTS —" in the Issues & Tasks database (data source `collection://c666f502-1973-4f96-bb83-3c743d1d2b30`).
   If found, update its Status property to "In Progress".

5. **Analyze:**
   Read the issue body carefully. Identify all affected files. Study the existing patterns in nearby code — especially in the same source file or similar handlers.

6. **Implement:**
   Write code following the conventions in CLAUDE.md. Key rules:
   - This project uses `-std=gnu99` (not strict C89)
   - Prefer top-of-block variable declarations for readability
   - Use `__asm__("\n&FUNC    SETC '...'");` before every static function
   - Use `asm("SYMBOL")` on handler declarations
   - Never reference AI or Claude in code, comments, or commit messages

7. **Verify syntax:**
   Run: `make compiledb`
   Then check clangd diagnostics — there must be no errors in changed files.

8. **Update tests:**
   If the change affects an endpoint, add or update tests in `tests/`. Follow the patterns in existing test scripts (colored output, pass/fail counters).

9. **Update docs:**
   If touching an endpoint handler, update the corresponding file in `doc/endpoints/`.

10. **Commit:**
    Write a descriptive commit message. Reference the issue: `Fixes #$ARGUMENTS`
    Never mention AI, Claude, or automation in the message.

11. **Push and create PR:**
    Run: `git push -u origin HEAD`
    Run: `gh pr create --title "<descriptive title>" --body "Fixes #$ARGUMENTS" --repo mvslovers/mvsmf`

12. **Update Notion status to "In Review":**
    Search Notion for the issue: query "#$ARGUMENTS —" in the Issues & Tasks database (data source `collection://c666f502-1973-4f96-bb83-3c743d1d2b30`).
    If found, update its Status property to "In Review".

13. **Report:**
    Summarize what was done, which files were changed, and what needs manual verification on the live MVS system (if anything).

If any step fails or is ambiguous, stop and ask rather than guessing.
