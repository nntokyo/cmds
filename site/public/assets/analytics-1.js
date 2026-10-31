// Google Analytics 4: page views, plus a named event for each way out of the site
// that matters (Mac download, App Store, GitHub). See /privacy/ section 6.
(function () {
  var id = 'G-6JN971XLBV';
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
