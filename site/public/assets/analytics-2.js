// Google Analytics 4: page views, plus a named event for each way out of the site
// that matters (Mac download, App Store, GitHub). See /privacy/ section 6.
// Visitors can turn it off on the privacy page; the choice is kept in localStorage.
(function () {
  var id = 'G-6JN971XLBV';
  var optOutKey = 'cmds-analytics-off';

  function optedOut() {
    try { return localStorage.getItem(optOutKey) === '1'; } catch (e) { return false; }
  }

  function removeCookies() {
    document.cookie.split(';').forEach(function (c) {
      var name = c.split('=')[0].trim();
      if (!/^_ga/.test(name)) return;
      ['', '; domain=' + location.hostname, '; domain=.' + location.hostname.split('.').slice(-2).join('.')]
        .forEach(function (domain) {
          document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/' + domain;
        });
    });
  }

  function bindSetting() {
    var box = document.getElementById('analytics-toggle');
    if (!box) return;
    box.checked = !optedOut();
    box.closest('[hidden]') && box.closest('[hidden]').removeAttribute('hidden');
    box.addEventListener('change', function () {
      try {
        if (box.checked) localStorage.removeItem(optOutKey);
        else localStorage.setItem(optOutKey, '1');
      } catch (e) {}
      if (!box.checked) {
        window['ga-disable-' + id] = true;
        removeCookies();
      } else {
        location.reload();
      }
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bindSetting);
  else bindSetting();

  if (optedOut()) {
    window['ga-disable-' + id] = true;
    return;
  }

  var s = document.createElement('script');
  s.async = true;
  s.src = 'https://www.googletagmanager.com/gtag/js?id=' + id;
  document.head.appendChild(s);

  window.dataLayer = window.dataLayer || [];
  function gtag() { window.dataLayer.push(arguments); }
  window.gtag = gtag;
  gtag('js', new Date());
  gtag('config', id);

  function eventFor(url) {
    if (/\.dmg$/.test(url.pathname)) return 'download_mac';
    if (url.hostname === 'apps.apple.com') return 'app_store_click';
    if (url.hostname === 'github.com') return 'github_click';
    return null;
  }

  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[href]');
    if (!a) return;
    var name = eventFor(new URL(a.href, location.href));
    if (name) gtag('event', name, { link_url: a.href, transport_type: 'beacon' });
  });
})();
