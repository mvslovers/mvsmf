/**
 * mvsMF API Client
 *
 * Thin wrapper around the zOSMF-compatible REST API provided by mvsMF.
 * All requests use Basic Auth via credentials stored in Auth module memory.
 *
 * Endpoints used:
 *   GET /zosmf/restfiles/ds?dslevel={pattern}       → list datasets
 *   GET /zosmf/restfiles/ds/{dsname}/member          → list PDS members
 *   GET /zosmf/restfiles/ds/{dsname}                 → dataset content (PS)
 *   GET /zosmf/restfiles/ds/{dsname}({member})        → member content
 */
var API = (function () {

  var BASE = '/zosmf/restfiles';

  // ── Internal helpers ───────────────────────────────────────────

  /**
   * Perform an authenticated GET request against the mvsMF API.
   * Returns the parsed JSON body on success, throws on error.
   */
  async function _get(path, headers) {
    var auth = Auth.getBasicAuth();
    if (!auth) {
      // Credentials lost (page refresh) → force re-login
      window.location.href = 'login.html?redirect=' +
        encodeURIComponent(window.location.pathname);
      throw new Error('No credentials available');
    }

    var hdrs = Object.assign({
      'Authorization': auth,
      'Accept': 'application/json',
    }, headers || {});

    var resp = await fetch(BASE + path, {
      method: 'GET',
      headers: hdrs,
      credentials: 'same-origin',
    });

    if (resp.status === 401) {
      // Session expired or bad credentials → re-login
      window.location.href = 'login.html?redirect=' +
        encodeURIComponent(window.location.pathname);
      throw new Error('Authentication failed (401)');
    }

    if (!resp.ok) {
      var errText = await resp.text().catch(function () { return ''; });
      throw new Error('API error ' + resp.status + ': ' + errText);
    }

    return resp.json();
  }

  // ── Public API ─────────────────────────────────────────────────

  /**
   * List datasets matching a filter pattern.
   *
   * @param {string} pattern - Dataset name pattern (e.g. "SYS1.**")
   * @returns {Promise<Object[]>} Array of dataset objects
   *
   * zOSMF response format:
   * { "returnedRows": N, "items": [ { "dsname": "...", "vol": "...",
   *   "dsorg": "...", "recfm": "...", "lrecl": ..., "blksz": ... }, ... ] }
   */
  async function listDatasets(pattern) {
    var data = await _get('/ds?dslevel=' + encodeURIComponent(pattern));
    return data.items || [];
  }

  /**
   * List members of a partitioned dataset.
   *
   * @param {string} dsname - Fully qualified dataset name (no quotes)
   * @returns {Promise<Object[]>} Array of member objects
   *
   * zOSMF response format:
   * { "returnedRows": N, "items": [ { "member": "..." }, ... ] }
   */
  async function listMembers(dsname) {
    var data = await _get('/ds/' + encodeURIComponent(dsname) + '/member');
    return data.items || [];
  }

  /**
   * Retrieve the content of a sequential dataset or PDS member.
   *
   * @param {string} dsname - Dataset name
   * @param {string} [member] - Member name (omit for sequential DS)
   * @returns {Promise<string>} Plain text content
   */
  async function getContent(dsname, member) {
    var path = '/ds/' + encodeURIComponent(dsname);
    if (member) {
      path += '(' + encodeURIComponent(member) + ')';
    }

    var auth = Auth.getBasicAuth();
    if (!auth) {
      window.location.href = 'login.html?redirect=' +
        encodeURIComponent(window.location.pathname);
      throw new Error('No credentials available');
    }

    var resp = await fetch(BASE + path, {
      method: 'GET',
      headers: {
        'Authorization': auth,
        'Accept': 'text/plain',
      },
      credentials: 'same-origin',
    });

    if (resp.status === 401) {
      window.location.href = 'login.html?redirect=' +
        encodeURIComponent(window.location.pathname);
      throw new Error('Authentication failed (401)');
    }

    if (!resp.ok) {
      throw new Error('API error ' + resp.status);
    }

    return resp.text();
  }

  // ── Expose ─────────────────────────────────────────────────────
  return {
    listDatasets,
    listMembers,
    getContent,
  };

})();
