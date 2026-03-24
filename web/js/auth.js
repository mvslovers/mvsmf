/**
 * Auth Module for mvsMF
 *
 * Integrates with the HTTPD 4.x cookie-based authentication system.
 *
 * Server flow (httpcred.c / process_post):
 *   POST /login  (userid=X&password=Y, form-urlencoded)
 *     → Success: Set-Cookie Sec-Token, 303 redirect to target URI
 *     → Failure: 200 with built-in HTTPD login page (print_login)
 *   GET  /logout
 *     → Clears Sec-Token cookie, ends session
 *
 * We use fetch() with redirect:'manual' so we stay on our custom
 * login page when credentials are wrong. The browser still processes
 * the Set-Cookie header from the 303 response, so the Sec-Token
 * cookie is set transparently.
 *
 * Credentials for API calls (Basic Auth) are stored in sessionStorage.
 * This survives page navigation but is cleared when the tab is closed.
 * This is a temporary solution until token-based API auth is available
 * in the HTTPD.
 *
 * For the userid display we store the name in a lightweight
 * "mvsmf_user" cookie ourselves (Sec-Token may be HttpOnly).
 */
const Auth = (function () {

  const USER_COOKIE = 'mvsmf_user';
  const CRED_KEY    = 'mvsmf_cred';

  // ── Public API ─────────────────────────────────────────────────

  /**
   * Attempt login via fetch() POST to /login.
   *
   * Server behaviour (httpcred.c):
   *   - Success → 303 + Set-Cookie Sec-Token
   *   - Failure → 200 + built-in HTML error page
   *
   * With redirect:'manual' the browser does NOT follow the 303,
   * giving us an opaque redirect response (type 'opaqueredirect',
   * status 0). A 200 means wrong credentials.
   *
   * @param {string} userid      - TSO User ID (max 8 chars)
   * @param {string} password    - Password (max 8 chars)
   * @param {string} redirectUri - URI to navigate to on success
   * @returns {Promise<boolean>}   true on success, false on failure
   */
  async function login(userid, password, redirectUri) {
    if (!userid || !password) return false;

    var body = 'userid=' + encodeURIComponent(userid.toUpperCase())
             + '&password=' + encodeURIComponent(password);

    // Include target URI so the server puts it in the 303 Location
    // (we won't follow it, but it keeps the server state consistent)
    if (redirectUri) {
      body += '&uri=' + encodeURIComponent(redirectUri);
    }

    var resp = await fetch('/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body,
      redirect: 'manual',         // don't follow the 303
      credentials: 'same-origin', // ensure cookies are sent & stored
    });

    // 303 → browser exposes it as opaque redirect (type='opaqueredirect', status=0)
    // The Set-Cookie header is still processed, so Sec-Token is set.
    if (resp.type === 'opaqueredirect' || resp.status === 303) {
      // Store userid client-side for display (Sec-Token may be HttpOnly)
      _setCookie(USER_COOKIE, userid.toUpperCase(), 8); // 8 hours

      // Persist credentials in sessionStorage for API calls across pages.
      // Cleared on tab close or explicit logout.
      sessionStorage.setItem(CRED_KEY, btoa(userid.toUpperCase() + ':' + password));

      // Navigate to the dashboard ourselves
      window.location.href = redirectUri || 'dashboard.html';
      return true;
    }

    // 200 → server rendered its built-in error page = wrong credentials
    return false;
  }

  /**
   * Log the current user out.
   * Clears all client-side state and calls /logout so the HTTPD
   * drops the Sec-Token cookie. Then redirects to the landing page.
   */
  function logout() {
    sessionStorage.removeItem(CRED_KEY);
    _deleteCookie(USER_COOKIE);
    fetch('/logout', {
      credentials: 'same-origin',
      redirect: 'manual',
    }).finally(function () {
      window.location.href = 'index.html';
    });
  }

  /**
   * Get the currently authenticated user, or null.
   *
   * We check for the presence of the Sec-Token cookie (set by the
   * server). If it exists, the user is authenticated. The userid
   * comes from our own lightweight cookie.
   *
   * @returns {{ userid: string } | null}
   */
  function getUser() {
    var secToken = _getCookie('Sec-Token');
    var userid   = _getCookie(USER_COOKIE);

    // If we have a server token, the session is valid
    if (secToken) {
      return { userid: userid || 'USER' };
    }

    // Fallback: if the server marks Sec-Token as HttpOnly we
    // cannot read it from JS. In that case we trust the presence
    // of our own user cookie as a hint that we are logged in.
    // The server will still enforce real auth on every request.
    if (userid) {
      return { userid: userid };
    }

    return null;
  }

  /**
   * Guard function – redirects to login page if no session exists.
   * Call this at the top of every protected page.
   */
  function requireAuth() {
    if (!getUser()) {
      window.location.href = 'login.html';
    }
  }

  /**
   * Returns the Basic Auth header value for API requests,
   * or null if credentials are not available.
   * @returns {string|null}  "Basic dXNlcjpwYXNz" or null
   */
  function getBasicAuth() {
    var cred = sessionStorage.getItem(CRED_KEY);
    return cred ? ('Basic ' + cred) : null;
  }

  /**
   * Check whether credentials are available for API calls.
   * @returns {boolean}
   */
  function hasCredentials() {
    return sessionStorage.getItem(CRED_KEY) !== null;
  }

  // ── Cookie Helpers ─────────────────────────────────────────────

  function _setCookie(name, value, hours) {
    var expires = '';
    if (hours) {
      var d = new Date();
      d.setTime(d.getTime() + hours * 3600000);
      expires = '; expires=' + d.toUTCString();
    }
    document.cookie = name + '=' + encodeURIComponent(value)
                    + expires + '; path=/; SameSite=Lax';
  }

  function _getCookie(name) {
    var match = document.cookie.match(
      new RegExp('(?:^|;\\s*)' + name + '=([^;]*)')
    );
    return match ? decodeURIComponent(match[1]) : null;
  }

  function _deleteCookie(name) {
    document.cookie = name + '=; Max-Age=0; path=/; SameSite=Lax';
  }

  // ── Expose ─────────────────────────────────────────────────────
  return {
    login,
    logout,
    getUser,
    requireAuth,
    getBasicAuth,
    hasCredentials,
  };

})();
