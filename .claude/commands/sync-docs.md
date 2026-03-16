Synchronize endpoint documentation with the current implementation.

1. **Scan routes:**
   Read `src/mvsmf.c` and extract all `add_route()` calls. Build a complete list of: method, URL pattern, handler function name.

2. **Scan docs:**
   List all files in `doc/endpoints/` (including subdirectories).

3. **Compare:**
   For each route, check if a matching documentation file exists. Report:
   - **Missing docs** — routes with no corresponding doc file
   - **Orphaned docs** — doc files with no corresponding route
   - **Potentially outdated** — doc files whose handler has been modified more recently than the doc

4. **Generate stubs:**
   For any missing documentation, create a stub file following the format of existing docs (see `doc/endpoints/datasets/` for the template pattern). Include: endpoint, method, description placeholder, request/response format, curl example placeholder.

5. **Report:**
   Summarize findings: how many routes, how many documented, how many missing, how many stubs generated.
