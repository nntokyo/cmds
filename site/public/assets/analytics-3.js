// Google Analytics 4: page views, plus a named event for each way out of the site
// that matters (Mac download, App Store, GitHub). See /privacy/ section 6, and keep it in step.
// - Visitors turn it off on the privacy page (kept in localStorage and a cookie). The privacy pages
//   themselves are never measured, so the setting can be changed before anything is sent; pages
//   already open (other tabs, back/forward cache) stop when the setting changes.
// - Host-only cookies with the prefix "cmds", 13 months: sibling n-n.tokyo sites neither share nor lose theirs.
// - No analytics cookies in the EEA, the UK and Switzerland (consent mode); no Google signals or ad features.
(function () {
  var id = 'G-6JN971XLBV';
  var optOutKey = 'cmds-analytics-off';
  var noCookieRegions = [
    'AT', 'BE', 'BG', 'CY', 'CZ', 'DE', 'DK', 'EE', 'ES', 'FI', 'FR', 'GR', 'HR', 'HU', 'IE', 'IT',
    'LT', 'LU', 'LV', 'MT', 'NL', 'PL', 'PT', 'RO', 'SE', 'SI', 'SK', 'IS', 'LI', 'NO', 'GB', 'CH',
    // Parts of the EEA and UK/Norwegian territories with their own country codes
    'AX', 'GF', 'GP', 'MQ', 'RE', 'YT', 'MF', 'SJ', 'GI', 'GG', 'IM', 'JE',
  ];

  function optedOut() {
    try { if (localStorage.getItem(optOutKey) === '1') return true; } catch (e) {}
    return document.cookie.split('; ').indexOf(optOutKey + '=1') !== -1;
  }

  function setOptedOut(off) {
    try {
      if (off) localStorage.setItem(optOutKey, '1');
      else localStorage.removeItem(optOutKey);
    } catch (e) {}
    document.cookie = optOutKey + (off ? '=1; max-age=31536000' : '=; max-age=0') + '; path=/; SameSite=Lax; Secure';
  }

  // This site's analytics cookies. `_ga` without a prefix (left by the first version of this script)
  // is deleted only when no sibling n-n.tokyo property uses it.
  function removeCookies() {
    var parent = location.hostname.split('.').slice(-2).join('.');
    var names = document.cookie.split('; ').map(function (c) { return c.split('=')[0]; });
    var own = ['cmds_ga', 'cmds_ga_' + id.slice(2), '_ga_' + id.slice(2)];
    var shared = names.some(function (n) { return /^_ga_/.test(n) && own.indexOf(n) === -1; });
    if (!shared) own.push('_ga');
    own.forEach(function (name) {
      ['', '; domain=' + location.hostname, '; domain=.' + parent].forEach(function (domain) {
        document.cookie = name + '=; max-age=0; path=/' + domain;
      });
    });
  }

  var box = document.getElementById('analytics-toggle');
  if (box) {
    var sync = function () { box.checked = !optedOut(); };
    sync();
    box.closest('[hidden]') && box.closest('[hidden]').removeAttribute('hidden');
    box.addEventListener('change', function () {
      setOptedOut(!box.checked);
      if (!box.checked) removeCookies();
    });
    window.addEventListener('pageshow', sync);
    return;
  }

  if (optedOut()) return;

  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  var noAds = { ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied' };
  gtag('consent', 'default', Object.assign({ analytics_storage: 'denied', region: noCookieRegions }, noAds));
  gtag('consent', 'default', Object.assign({ analytics_storage: 'granted' }, noAds));
  gtag('js', new Date());
  gtag('config', id, {
    cookie_domain: 'none',
    cookie_prefix: 'cmds',
    cookie_expires: 13 * 30 * 24 * 60 * 60,
    allow_google_signals: false,
    allow_ad_personalization_signals: false,
  });

  var s = document.createElement('script');
  s.async = true;
  s.src = 'https://www.googletagmanager.com/gtag/js?id=' + id;
  document.head.appendChild(s);

  // Turned off on the privacy page while this page stays open (another tab, or back/forward cache).
  function stopIfOptedOut() {
    if (!optedOut()) return;
    window['ga-disable-' + id] = true;
    gtag('consent', 'update', { analytics_storage: 'denied' });
    removeCookies();
  }
  window.addEventListener('pageshow', stopIfOptedOut);
  window.addEventListener('storage', function (e) { if (e.key === optOutKey) stopIfOptedOut(); });

  function eventFor(href) {
    var url;
    try { url = new URL(href, location.href); } catch (e) { return null; }
    if (/\.dmg$/.test(url.pathname)) return 'download_mac';
    if (url.hostname === 'apps.apple.com') return 'app_store_click';
    if (url.hostname === 'github.com') return 'github_click';
    return null;
  }

  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[href]');
    if (!a || optedOut()) return;
    var name = eventFor(a.href);
    if (name) gtag('event', name, { link_url: a.href });
  });
})();
