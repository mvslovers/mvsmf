/**
 * mvsMF – Shared Application Utilities
 *
 * Provides common functions used across all pages:
 * - Navigation highlighting
 * - User session display
 * - Sidebar generation for sub-pages
 */
const App = (function () {

  /**
   * Highlight the current page in the sidebar navigation.
   * Matches by comparing the href attribute with the current filename.
   */
  function highlightNav() {
    const currentPage = window.location.pathname.split('/').pop() || 'dashboard.html';
    document.querySelectorAll('.nav-item').forEach(function (item) {
      item.classList.remove('active');
      const href = item.getAttribute('href');
      if (href === currentPage) {
        item.classList.add('active');
      }
    });
  }

  /**
   * Populate the user info in the top bar.
   */
  function initUserDisplay() {
    const user = Auth.getUser();
    if (user) {
      const nameEl = document.getElementById('userName');
      const avatarEl = document.getElementById('userAvatar');
      if (nameEl) nameEl.textContent = user.userid;
      if (avatarEl) avatarEl.textContent = user.userid.substring(0, 2);
    }
  }

  /**
   * Initialize a protected page (auth check + user display + nav highlight).
   */
  function init() {
    Auth.requireAuth();
    initUserDisplay();
    highlightNav();
  }

  return { init, highlightNav, initUserDisplay };

})();
