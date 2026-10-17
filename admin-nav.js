// ═══════════════════════════════════════════════════════════════
// ADMIN TAB BAR — one shared menu on every admin page, so you can jump
// between Clients, Inbox, Program Builder and Exercise Videos in one
// click from anywhere (including on your phone). Shows a red count on
// Inbox when you have unread client messages or new applications.
//
// Included on each admin page with: <script src="admin-nav.js"></script>
// To add a new admin page later, add one line to ADMIN_TABS below.
// ═══════════════════════════════════════════════════════════════
(function () {
  const ADMIN_TABS = [
    { href: 'admin.html',                  label: 'Clients',         short: 'Clients' },
    { href: 'admin-messages.html',         label: 'Inbox',           short: 'Inbox', badge: true },
    { href: 'admin-program-builder.html',  label: 'Program Builder', short: 'Builder' },
    { href: 'admin-exercise-catalog.html', label: 'Exercise Videos', short: 'Videos' },
  ];

  const css = `
    .admin-bar {
      position: fixed; left: 0; right: 0; top: 0; z-index: 99;
      background: var(--black, #0a0a0a);
      border-bottom: 1px solid var(--border, #222);
      padding: 0 48px;
      display: flex; align-items: center; gap: 4px;
      overflow-x: auto; -webkit-overflow-scrolling: touch; scrollbar-width: none;
    }
    .admin-bar::-webkit-scrollbar { display: none; }
    .admin-bar-label {
      font-family: 'Barlow Condensed', sans-serif;
      font-size: 0.66rem; font-weight: 600; letter-spacing: 0.22em; text-transform: uppercase;
      color: var(--red, #c8102e); padding-right: 16px; margin-right: 4px;
      border-right: 1px solid var(--border, #222); white-space: nowrap;
    }
    .admin-bar a {
      font-family: 'Barlow Condensed', sans-serif;
      font-size: 0.82rem; font-weight: 600; letter-spacing: 0.12em; text-transform: uppercase;
      color: var(--light-grey, #bbb); text-decoration: none; white-space: nowrap;
      padding: 16px 14px 13px; border-bottom: 3px solid transparent;
      display: inline-flex; align-items: center; gap: 8px;
      transition: color 0.15s, border-color 0.15s;
    }
    .admin-bar a:hover { color: var(--white, #f5f3ef); }
    .admin-bar a.active { color: var(--white, #f5f3ef); border-bottom-color: var(--red, #c8102e); }
    .admin-bar .admin-badge {
      background: var(--red, #c8102e); color: #fff; border-radius: 999px;
      font-size: 0.68rem; letter-spacing: 0; min-width: 18px; height: 18px; padding: 0 5px;
      display: none; align-items: center; justify-content: center;
    }
    .admin-bar .admin-badge.show { display: inline-flex; }
    .admin-bar .admin-bar-site { margin-left: auto; color: var(--grey, #888); }
    .admin-bar .lbl-short { display: none; }
    @media (max-width: 700px) {
      .admin-bar { padding: 0 12px; }
      .admin-bar-label { display: none; }
      .admin-bar { gap: 0; }
      .admin-bar a { padding: 14px 9px 11px; font-size: 0.74rem; letter-spacing: 0.08em; }
      .admin-bar .lbl-long { display: none; }
      .admin-bar .lbl-short { display: inline; }
    }
  `;

  function build() {
    if (document.querySelector('.admin-bar')) return;
    const style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);

    const current = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
    const bar = document.createElement('div');
    bar.className = 'admin-bar';
    bar.innerHTML =
      '<span class="admin-bar-label">Admin</span>' +
      ADMIN_TABS.map(t =>
        `<a href="${t.href}" class="${current === t.href ? 'active' : ''}"><span class="lbl-long">${t.label}</span><span class="lbl-short">${t.short}</span>` +
        (t.badge ? '<span class="admin-badge" id="admin-inbox-badge"></span>' : '') +
        '</a>'
      ).join('') +
      '<a href="index.html" class="admin-bar-site"><span class="lbl-long">View Site ↗</span><span class="lbl-short">Site ↗</span></a>';

    const nav = document.querySelector('nav');
    if (nav) nav.insertAdjacentElement('afterend', bar);
    else document.body.prepend(bar);

    // The top menu is pinned to the screen, so pin this bar right under it
    // and push the page content down by the bar's height.
    const place = () => {
      bar.style.top = (nav ? nav.getBoundingClientRect().height : 0) + 'px';
      document.body.style.paddingTop = bar.offsetHeight + 'px';
    };
    place();
    window.addEventListener('resize', place);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(place);

    // Keep the active tab in view on phones
    const active = bar.querySelector('a.active');
    if (active) active.scrollIntoView({ block: 'nearest', inline: 'center' });

    refreshBadge();
    setInterval(refreshBadge, 60000);
  }

  async function refreshBadge() {
    const badge = document.getElementById('admin-inbox-badge');
    if (!badge || typeof supabaseClient === 'undefined' || !supabaseClient) return;
    try {
      const { data: { session } } = await supabaseClient.auth.getSession();
      if (!session) return;
      const [overview, inquiries] = await Promise.all([
        supabaseClient.rpc('admin_message_overview'),
        supabaseClient.from('inquiries')
          .select('id', { count: 'exact', head: true })
          .is('read_at', null)
          .eq('flagged', false)
      ]);
      const unreadMessages = (overview.data || []).reduce((n, c) => n + Number(c.unread_count || 0), 0);
      const total = unreadMessages + (inquiries.count || 0);
      badge.textContent = total > 99 ? '99+' : String(total);
      badge.classList.toggle('show', total > 0);
    } catch (e) { /* badge is a nice-to-have — never break the page */ }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', build);
  else build();
})();
