#requires -Version 5.1
<#
.SYNOPSIS
    SlyKiss HoTMetaL (CLI-Browser) - text-mode Chromium for firewall web consoles (and the rest of the web).

    (C) 2026 Jim Ames  N2NHU Labs  Newburgh NY USA  jimpames@gmail.com
    Designed and coded by Jim Ames, Claude, Grok and DeepSeek

.DESCRIPTION
    Built on the Pup module (PuppeteerSharp / Chrome DevTools Protocol). Requires Pup 0.4.5+.

    THE ALGEBRA
    -----------
    The browser is a state machine. Everything you type is parsed into a command
    value, and every command is evaluated as a transition on that state:

        parse : Line -> [Cmd]                     (pure; no browser needed)
        eval  : Cmd x State -> Ok | Err           (effects go through ONE primitive)
        a ; b                                     (sequence: b runs only if a is Ok)

    The single effect primitive is the kernel: one JavaScript function, kernel(op, args),
    evaluated in the page. It exposes: snap, act, settle, text, arm, disarm, mark, consent.

    Laws the design keeps (and -SelfTest checks):
      1. One namespace. Every link, button, field, list and checkbox on the page gets
         one number in ONE list. A number always refers to the most recently shown list.
      2. Handles are checked. Acting on item n first verifies it is still attached and
         still has the same fingerprint (kind|tag|label|name). If the page changed, the
         command fails instead of clicking the wrong thing.
      3. Dialogs are data. alert/confirm/prompt never block. confirm() answers CANCEL
         unless the command carries '!' (e.g. 7!), which answers OK for that command only.
      4. Fill is idempotent. 6=on twice leaves the box checked; 3=admin twice is one value.
      5. Nothing is auto-clicked. No cookie banners, no 'Continue', no 'Accept' -
         unless you ask (consent).

    QUICK START
    -----------
      .\CLI-Browser.ps1 10.1.1.1:4443      (arrow keys + Enter; ? for help; : for commands)
      > "Username"=admin ; "Password"=? ; "Login"
      > ls in          (fields only)      > 12=port3       (set a dropdown)
      > text           (page as text)     > 31!            (click, answering OK to confirm)

.EXAMPLE
    .\CLI-Browser.ps1 192.168.1.99
.EXAMPLE
    .\CLI-Browser.ps1 fw01.corp.local:8443 -Run fortigate-login
.EXAMPLE
    .\CLI-Browser.ps1 10.0.0.1 -Exec '"Username"=admin; "Password"=env:FWPASS; "Login"; expect Dashboard; text' -Dump
.EXAMPLE
    .\CLI-Browser.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Url,
    [switch]$Visible,
    [switch]$StrictTls,
    [string]$Proxy,
    [string]$UserAgent,
    [string]$Exec,
    [string]$Run,
    [switch]$Dump,
    [int]$TimeoutSec = 20,
    [switch]$Classic,
    [switch]$TraceAll,
    [switch]$SelfTest,
    [switch]$OfflineTest
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ===========================================================================
# 0. Environment and state
# ===========================================================================
$script:HomeDir = $env:USERPROFILE
if (-not $script:HomeDir) { $script:HomeDir = $HOME }
$script:AppDir   = Join-Path $script:HomeDir '.cli-browser'
$script:Version  = '6.2'
$script:Product  = 'SlyKiss HoTMetaL'
$script:MinPup   = [version]'0.4.5'

$script:Cfg = @{
    ListMax   = 40
    TimeoutMs = [Math]::Max(3, $TimeoutSec) * 1000
    BmFile    = Join-Path $script:AppDir 'bookmarks.json'
    LogFile   = Join-Path $script:AppDir 'debug.log'
    ScriptDir = Join-Path $script:AppDir 'scripts'
    DlDir     = Join-Path $script:AppDir 'downloads'
}

$script:S = @{
    Browser   = $null
    Tabs      = @{}
    Cur       = 0
    NextId    = 1
    Running   = $true
    Bookmarks = @{}
    Preload   = $true
    WarnedPw  = $false
    LastErr   = ''
    Stuck     = $false
}

$script:TraceAll = [bool]$TraceAll
$script:Interactive = $true
try { if ([Console]::IsInputRedirected) { $script:Interactive = $false } } catch {}
if ($Exec -or $Run -or $Dump) { $script:Interactive = $false }

# ===========================================================================
# 1. The kernel: the ONLY code that touches the page. (ASCII only.)
# ===========================================================================
$script:KERNEL = @'
(op, a) => {
  const V = 3;
  const A = (typeof a === 'string' && a.length) ? JSON.parse(a) : (a || {});
  const txt = s => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
  const ICON = /^(chevron_(right|left)|expand_(more|less)|more_(vert|horiz)|arrow_(back|forward|drop_down|drop_up|upward|downward|right_alt)|keyboard_arrow_(down|up|left|right)|open_in_new|navigate_(next|before)|check_box(_outline_blank)?|radio_button_(checked|unchecked)|arrow_back_ios|arrow_forward_ios|play_arrow|first_page|last_page|filter_list|more|refresh|close|menu|search|share|star|bookmark_border|bookmark_add|info|help_outline|settings|delete|edit|add|remove|done|clear|apps|home|account_circle|notifications|language|location_on|schedule)$/;
  const stripIcons = (s) => {
    let w = s.split(' ');
    if (w.length === 1 && w[0].indexOf('_') > 0 && ICON.test(w[0])) return '';
    if (w.length > 1 && ICON.test(w[w.length - 1]) && w[w.length - 1].indexOf('_') > 0) w.pop();
    if (w.length > 1 && ICON.test(w[0]) && w[0].indexOf('_') > 0) w.shift();
    return w.join(' ');
  };

  // ---- root state: one per top document, shared by same-origin frames ----
  const topWin = (() => { try { void window.top.document; return window.top; } catch (e) { return window; } })();
  if (!topWin.__cliState || topWin.__cliState.v !== V) {
    topWin.__cliState = { v: V, sid: Math.random().toString(36).slice(2, 8), gen: 0, refs: [], fps: [], big: '', dlg: [], armed: 0, promptAnswer: null,
                          pending: 0, mut: 0, leaving: 0 };
  }
  const S = topWin.__cliState;
  const drain = () => { const d = S.dlg.slice(0, 20); S.dlg.length = 0; return d; };

  // ---- hooks: dialogs become data, network + DOM activity become counters ----
  const install = (w) => {
    if (!w || w.__cliHooked === V) return;
    w.__cliHooked = V;
    if (w !== topWin) { S.leaving = 0; S.mut++; }
    w.alert = function (m) { S.dlg.push({ t: 'alert', m: txt(m) }); };
    w.confirm = function (m) {
      const ok = S.armed > 0;
      S.dlg.push({ t: 'confirm', m: txt(m), r: ok });
      return ok;
    };
    w.prompt = function (m, d) {
      const v = (S.promptAnswer != null) ? String(S.promptAnswer) : null;
      S.dlg.push({ t: 'prompt', m: txt(m), r: v != null });
      return v;
    };
    try {
      const of = w.fetch;
      if (of) w.fetch = function () {
        S.pending++;
        let p;
        try { p = of.apply(this, arguments); } catch (e) { S.pending--; throw e; }
        return p.finally(() => { S.pending = Math.max(0, S.pending - 1); });
      };
    } catch (e) {}
    try {
      const XP = w.XMLHttpRequest && w.XMLHttpRequest.prototype;
      if (XP && !XP.__cliSend) {
        XP.__cliSend = XP.send;
        XP.send = function () {
          S.pending++;
          this.addEventListener('loadend', () => { S.pending = Math.max(0, S.pending - 1); }, { once: true });
          return XP.__cliSend.apply(this, arguments);
        };
      }
    } catch (e) {}
    try { w.addEventListener('beforeunload', () => { S.leaving = Date.now(); }); } catch (e) {}
    const observe = () => {
      try {
        new w.MutationObserver(() => { S.mut++; }).observe(w.document.documentElement,
          { subtree: true, childList: true, attributes: true, characterData: true });
      } catch (e) {}
    };
    if (w.document && w.document.documentElement) observe();
    else { try { w.document.addEventListener('DOMContentLoaded', observe); } catch (e) {} }
  };

  // ---- traversal: document + open shadow roots + same-origin frames ----
  const ADRX = /google_ads|googlesyndication|doubleclick|adsystem|adnxs|taboola|outbrain|criteo|pubmatic|rubiconproject|openx|3lift|indexww|adtrafficquality|imrworldwide|optimizely|^aswift|^ad[_-]|[_-]ad$|usersync|user_sync|syncframe/i;
  const frameMeta = (el) => {
    const r = el.getBoundingClientRect();
    return { w: Math.round(r.width), h: Math.round(r.height), ad: ADRX.test((el.getAttribute('name') || '') + ' ' + (el.id || '') + ' ' + (el.getAttribute('src') || '')) ? 1 : 0 };
  };
  const frameInfo = (el, idx) => txt(el.getAttribute('name') || el.id || ('frame' + idx));
  const frameList = [];
  function* nodes(root, fr) {
    const all = root.querySelectorAll('*');
    for (let i = 0; i < all.length; i++) {
      const el = all[i];
      yield [el, fr];
      if (el.shadowRoot) yield* nodes(el.shadowRoot, fr);
      const tag = el.tagName;
      if (tag === 'IFRAME' || tag === 'FRAME') {
        const name = frameInfo(el, frameList.length + 1);
        const meta = frameMeta(el);
        let d = null;
        try { d = el.contentDocument; } catch (e) {}
        if (d && d.documentElement) {
          install(el.contentWindow);
          frameList.push({ n: name, u: String((d.location && d.location.href) || '').slice(0, 200), xo: false, w: meta.w, h: meta.h, ad: meta.ad });
          if (!meta.ad) yield* nodes(d, fr ? fr + '/' + name : name);
        } else {
          frameList.push({ n: name, u: String(el.src || '').slice(0, 200), xo: true, w: meta.w, h: meta.h, ad: meta.ad });
        }
      }
    }
  }

  const kindOf = (el) => {
    const t = el.tagName.toLowerCase();
    const ty = (el.getAttribute('type') || '').toLowerCase();
    const role = (el.getAttribute('role') || '').toLowerCase();
    if (t === 'a' && el.hasAttribute('href')) {
      const h = el.getAttribute('href') || '';
      // in-page anchors and script toggles (tabs, dropdowns) are actions, not destinations;
      // with <base href="/"> a "#tab" link would otherwise resolve to the site root
      if (/^\s*javascript:/i.test(h) || /^\s*#/.test(h) || el.hasAttribute('data-toggle')) return 'btn';
      return 'a';
    }
    if (t === 'button') return 'btn';
    if (t === 'input') {
      if (ty === 'hidden') return null;
      if (ty === 'checkbox' && /(^|\s)cbox(\s|$)/.test(el.className || '') && el.closest('tr.jqgrow')) return null;
      if (ty === 'button' || ty === 'submit' || ty === 'reset' || ty === 'image') return 'btn';
      if (ty === 'checkbox') return 'chk';
      if (ty === 'radio') return 'rad';
      if (ty === 'password') return 'pw';
      if (ty === 'file') return 'file';
      return 'in';
    }
    if (t === 'textarea') return 'in';
    if (t === 'select') return 'sel';
    if (role === 'checkbox' || role === 'switch') return 'chk';
    if (role === 'link') return 'a';
    if (['button', 'menuitem', 'tab', 'treeitem', 'option'].indexOf(role) >= 0) return 'btn';
    if (t === 'summary') return 'btn';
    if (el.hasAttribute('onclick')) return 'btn';
    if (/^(tooltip|popover)$/.test(el.getAttribute('data-toggle') || '')) return null;
    if (t !== 'a' && /^(collapse|tab|pill|dropdown|modal|button)$/.test(el.getAttribute('data-toggle') || '')) return 'btn';
    if (t === 'a' && (el.hasAttribute('data-toggle') || /(^|\s)btn(\s|$)/.test(el.className || ''))) return 'btn';
    if (/(^|\s)(config-lock|clickable)(\s|$)/.test(typeof el.className === 'string' ? el.className : '')) return 'btn';
    if (t === 'img') { try { if (el.ownerDocument.defaultView.getComputedStyle(el).cursor === 'pointer') return 'btn'; } catch (e) {} }
    if ((t === 'tr' || role === 'row') && isDataRow(el)) return 'row';
    return null;
  };
  // A row of a real data table: inside a table/grid that has column headers, not a header row.
  // Admin consoles make these clickable with listeners we cannot see, so we list them.
  const JQROW = /(^|\s)jqgrow(\s|$)/;
  function isDataRow(el) {
    if (el.closest('thead')) return false;
    const cls = typeof el.className === 'string' ? el.className : '';
    if (/(^|\s)jqgfirstrow(\s|$)/.test(cls)) return false;
    const tbl = el.closest('table,[role="grid"],[role="table"],[role="treegrid"]');
    if (!tbl) return false;
    // Grids like jqGrid draw headers in a separate table, so "has headers" is not enough to ask.
    if (el.querySelector('table')) return false;
    const grid = JQROW.test(cls) || tbl.matches('[role="grid"],[role="treegrid"],.ui-jqgrid-btable,.dataTable');
    const ownHead = Array.prototype.some.call(tbl.querySelectorAll('th,[role="columnheader"]'),
      h => h.closest('table,[role="grid"],[role="table"],[role="treegrid"]') === tbl);
    if (!grid && !ownHead) return false;
    let cells = 0;
    for (const c of el.children) {
      const tg = c.tagName, rl = (c.getAttribute('role') || '').toLowerCase();
      if (tg === 'TH' && !cells) continue;
      if (tg === 'TD' || rl === 'gridcell' || rl === 'cell') cells++;
    }
    return cells > 0 && txt(el.innerText).length > 0;
  }
  // column headings for the table a row belongs to: own thead, or jqGrid's separate header table
  const headerRowFor = (row) => {
    const tbl = row.closest('table,[role="grid"],[role="table"],[role="treegrid"]');
    if (!tbl) return null;
    let th = tbl.querySelector('thead th,[role="columnheader"]');
    if (!th) { const box = row.closest('.ui-jqgrid'); if (box) th = box.querySelector('.ui-jqgrid-htable th,[role="columnheader"]'); }
    if (!th) { const first = tbl.querySelector('tr'); if (first && first.querySelector('th') && !first.querySelector('td')) th = first.querySelector('th'); }
    return th ? th.closest('tr') : null;
  };
  const rowCells = (el) => {
    const out = [];
    for (const c of el.children) { if (!c.getClientRects().length) continue; const s = stripIcons(txt(c.innerText)); if (s) out.push(s); }
    return out.join(' | ');
  };
  const clickable = k => k === 'a' || k === 'btn';

  const NAVSEL = 'nav,[role="navigation"],[role="menubar"],ul.nav-list,.nav-list,.sidebar,#sidebar,.side-nav,.sidenav,.navbar';
  const visible = (el) => {
    if (!el.getClientRects().length) return false;
    const w = el.ownerDocument.defaultView;
    const cs = w.getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') return false;
    // folded sections (Bootstrap collapse) are squeezed to zero height, not hidden. Menu links in them
    // stay listed (reachable without unfolding); page content in them does not.
    if (el.closest(NAVSEL)) return true;
    let p = el.parentElement, n = 0;
    while (p && n < 15) {
      if (p.clientHeight === 0 && w.getComputedStyle(p).overflowY !== 'visible') return false;
      p = p.parentElement; n++;
    }
    return true;
  };

  const cellLabel = (el) => {
    const td = el.closest('td,th');
    if (td) {
      let p = td.previousElementSibling;
      while (p && (!txt(p.innerText) || p.querySelector('input,select,textarea,button'))) p = p.previousElementSibling;
      if (p) return txt(p.innerText);
    }
    const textBox = el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && !/^(checkbox|radio|button|submit|reset|image|file)$/i.test(el.type || ''));
    let s = el.previousSibling, hops = 0;
    while (s && hops < 8) {
      hops++;
      if (s.nodeType === 3) { const t = txt(s.textContent); if (t) return t.replace(/[:\s]+$/, ''); }
      else if (s.nodeType === 1) {
        const t = txt(s.innerText);
        if (t) {
          if (/^(H[1-6]|LEGEND)$/.test(s.tagName)) return t;
          const ctl = s.querySelector('input,select,textarea,button');
          if (!ctl && ['LABEL', 'SPAN', 'B', 'STRONG', 'DIV', 'TD', 'TH', 'EM', 'I', 'P'].indexOf(s.tagName) >= 0) return t.replace(/[:\s]+$/, '');
          // "[x] Set source IP [0.0.0.0]": the box after a tick-box option is that option's value
          if (s.tagName === 'LABEL' && textBox && ctl && /^(checkbox|radio)$/i.test(ctl.type || '')) return t;
          return '';
        }
        if (s.querySelector && s.querySelector('input,select,textarea')) return '';
      }
      s = s.previousSibling;
    }
    return '';
  };
  // "<input type=checkbox>Use delegated prefix": the text after a tick-box
  const afterText = (el) => {
    let s = el.nextSibling, hops = 0;
    while (s && hops < 3) {
      hops++;
      if (s.nodeType === 3) { const t = txt(s.textContent); if (t) return t; }
      else if (s.nodeType === 1) { if (s.matches('input,select,textarea,button')) return ''; const t = txt(s.innerText); if (t) return t; }
      s = s.nextSibling;
    }
    return '';
  };
  // last resort: make an id readable - add_member_hostip -> "Member host IP"
  const WORDS = { ip: 'IP', ip6: 'IPv6', ipv6: 'IPv6', ipv4: 'IPv4', hostip: 'host IP', netip: 'network IP', hostip6: 'host IPv6', netip6: 'network IPv6',
    fqdn: 'FQDN', dns: 'DNS', mac: 'MAC', dhcp: 'DHCP', vpn: 'VPN', svpn: 'SSL VPN', l2tp: 'L2TP', ikev2: 'IKEv2', nat: 'NAT', addr: 'address',
    addr6: 'IPv6 address', fwuser: 'firewall user', fwgroup: 'firewall group', pol: 'policy', tm: 'traffic management', geo: 'geolocation', intf: 'interface', gw: 'gateway', pd: 'prefix delegation',
    wins: 'WINS', sip: 'SIP', ntp: 'NTP', snmp: 'SNMP', mtu: 'MTU', vlan: 'VLAN', id: 'ID', url: 'URL', ssl: 'SSL', tls: 'TLS' };
  // the part of an id that is not the element's own text: btn_tag_edit + "Edit" -> "Tag"
  const idHint = (el, label) => {
    const own = String(label || '').toLowerCase().split(/\s+/);
    const w = String((el && (el.id || el.getAttribute('name'))) || '').replace(/([a-z])([A-Z])/g, '$1 $2').split(/[\s_\-.]+/)
      .map(x => x.toLowerCase()).filter(x => x && own.indexOf(x) < 0 &&
        !/^(btn|button|lnk|link|a|id|cb|chk|ckb|grid|popup|table|tbl|modal|dlg|dialog|div|jqg|\d+)$/.test(x));
    const s = w.map(x => WORDS[x] || x).join(' ');
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
  };
  const humanize = (id) => {
    let w = String(id || '').replace(/([a-z])([A-Z])/g, '$1 $2').split(/[\s_\-.]+/).filter(Boolean).map(x => x.toLowerCase());
    w = w.filter(x => !/^(sel|select|txt|text|ckb|chk|cb|rb|rdo|input|inp|btn|button|div|fld|field|add|edit|new|val|value)$/.test(x));
    for (let i = 0; i + 1 < w.length; i++) if (w[i] === 'sec' && /^ip/.test(w[i + 1])) w[i] = 'secondary';
    const s = w.map(x => WORDS[x] || x).join(' ').trim();
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
  };
  const groupLabel = (el) => {
    const grp = el.closest('.control-group,.form-group,.form-row,.field');
    if (!grp) return '';
    const l = grp.querySelector('label,.control-label');
    if (!l || l.contains(el)) return '';
    let t = txt(l.innerText);
    if (!t) return '';
    const ctrls = grp.querySelectorAll('input:not([type="hidden"]),select,textarea');
    if (ctrls.length > 1 && ctrls[0] !== el) t += el.tagName === 'SELECT' ? ' (unit)' : ' (' + (Array.prototype.indexOf.call(ctrls, el) + 1) + ')';
    return t;
  };
  const labelledBy = (el) => {
    const ids = (el.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean);
    return ids.map(id => { const n = el.ownerDocument.getElementById(id); return n ? n.innerText : ''; }).join(' ');
  };
  const labelOf = (el, k) => {
    let s = '';
    if (k === 'row') return rowCells(el).slice(0, 160);
    if (k === 'chk' && /(^|\s)cbox(\s|$)/.test(el.className || '') && el.closest('.ui-jqgrid-htable')) {
      const h = idHint(el, 'select all rows');
      return 'Select all rows' + (h ? ' (' + h + ')' : '');
    }
    if (clickable(k)) {
      const raw = txt(el.innerText);
      if (/^[<>+\-=*\u00ab\u00bb\u2190-\u21ff.]{1,3}$/.test(raw)) { const h = idHint(el, ''); if (h) return h + ' (' + raw + ')'; }
      if ((/(^|\s)close(\s|$)/.test(el.className || '') || el.getAttribute('data-dismiss')) && /^(x|\u00d7|X|)$/.test(raw)) return 'Close';
      s = stripIcons(raw) || txt(el.value) || el.getAttribute('aria-label') || el.title || el.getAttribute('alt') || '';
      if (!s) { const img = el.querySelector('img[alt],img[title]'); if (img) s = img.getAttribute('alt') || img.title; }
      if (!s && el.tagName === 'IMG') {
        let n = el.nextElementSibling;
        while (n && !txt(n.innerText)) n = n.nextElementSibling;
        if (n) s = txt(n.innerText);
      }
      if (!s && k === 'a') {
        const h = el.getAttribute('href') || '';
        const tail = h.split('?')[0].split('/').filter(Boolean).pop() || h;
        let host = ''; try { host = new URL(el.href).hostname; } catch (e) {}
        s = (tail.length > 24 && !/[\s-]/.test(tail)) ? '(image link' + (host ? ' to ' + host : '') + ')' : tail;
        el.__cliFallback = 1;
      }
      if (!s) {
        const ic = el.querySelector('[class*="icon-"],[class*="fa-"]');
        const m = ic && /(?:^|\s)(?:icon|fa)-([a-z0-9-]+)/.exec(ic.className || '');
        if (m && !/^(white|large|lg|2x|3x|fw)$/.test(m[1])) { s = m[1].replace(/-/g, ' '); s = s.charAt(0).toUpperCase() + s.slice(1); }
      }
      if (!s && (el.name || el.id)) {
        const words = String(el.name || el.id).replace(/([a-z])([A-Z])/g, '$1 $2').split(/[\s_\-.]+/)
          .filter(w => w && !/^(btn|button|link|lnk|icon|ico|img)$/i.test(w));
        if (words.length) { s = words.join(' ').toLowerCase(); s = s.charAt(0).toUpperCase() + s.slice(1); }
      }
      if (!s) s = '(unlabelled ' + el.tagName.toLowerCase() + ')';
    } else {
      const native = ['INPUT', 'SELECT', 'TEXTAREA'].indexOf(el.tagName) >= 0;
      s = el.getAttribute('aria-label') || labelledBy(el) || (native ? '' : stripIcons(txt(el.innerText))) ||
          (el.labels && el.labels.length ? Array.prototype.map.call(el.labels, l => l.innerText).join(' ') : '') ||
          el.getAttribute('placeholder') || ((k === 'chk' || k === 'rad') ? afterText(el) : '') ||
          cellLabel(el) || groupLabel(el) || el.title || humanize(el.id || el.name) || el.name || el.id || '';
    }
    return txt(s).slice(0, 80);
  };
  const valueOf = (el, k) => {
    if (k === 'pw') return el.value ? '*'.repeat(Math.min(el.value.length, 8)) : '';
    if (k === 'in') return String(el.value || '').slice(0, 60);
    if (k === 'chk' || k === 'rad') {
      if (el.tagName === 'INPUT') return el.checked ? 'on' : 'off';
      return el.getAttribute('aria-checked') === 'true' ? 'on' : 'off';
    }
    if (k === 'sel') {
      const o = el.options && el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null;
      return o ? txt(o.text) : '';
    }
    if (k === 'file') return el.files && el.files.length ? el.files[0].name : '';
    if (k === 'row') {
      const sel = el.getAttribute('aria-selected') === 'true' || /(^|[\s_-])(selected|active|highlight(ed)?|checked)([\s_-]|$)/i.test(el.className || '') ||
                  !!el.querySelector('input[type="checkbox"]:checked,input[type="radio"]:checked');
      return sel ? 'on' : 'off';
    }
    return '';
  };
  const fpOf = (el, k) => [k, el.tagName, labelOf(el, k), el.getAttribute('name') || ''].join('|');

  const setValue = (el, v) => {
    const w = el.ownerDocument.defaultView;
    try { el.focus(); } catch (e) {}
    let proto = w.HTMLInputElement.prototype;
    if (el.tagName === 'TEXTAREA') proto = w.HTMLTextAreaElement.prototype;
    if (el.tagName === 'SELECT') proto = w.HTMLSelectElement.prototype;
    const d = Object.getOwnPropertyDescriptor(proto, 'value');
    if (d && d.set) d.set.call(el, v); else el.value = v;
    el.dispatchEvent(new w.Event('input', { bubbles: true }));
    el.dispatchEvent(new w.Event('change', { bubbles: true }));
  };
  const headingFor = (el) => {
    let cur = el, depth = 0;
    while (cur && depth < 8) {
      let s = cur.previousElementSibling, n = 0;
      while (s && n < 25) {
        if (/^(H[1-6]|LEGEND)$/.test(s.tagName) && txt(s.innerText)) return txt(s.innerText).slice(0, 40);
        if (/(^|[\s_-])(title|heading|header|caption)([\s_-]|$)/i.test(typeof s.className === 'string' ? s.className : '') &&
            !s.querySelector('input,select,textarea,table') && txt(s.innerText) && txt(s.innerText).length < 60) return txt(s.innerText).slice(0, 40);
        const inner = s.querySelectorAll ? s.querySelectorAll('h1,h2,h3,h4,h5,h6,legend') : [];
        if (inner.length && txt(inner[inner.length - 1].innerText)) return txt(inner[inner.length - 1].innerText).slice(0, 40);
        s = s.previousElementSibling; n++;
      }
      cur = cur.parentElement; depth++;
    }
    return '';
  };
  // a heading directly above a table (sibling at most a few levels up), never one from an earlier section
  const nearHeading = (el) => {
    let cur = el, depth = 0;
    while (cur && depth < 4) {
      let s = cur.previousElementSibling, n = 0;
      while (s && n < 10) {
        if (/^(H[1-6]|LEGEND|CAPTION)$/.test(s.tagName) && txt(s.innerText)) return txt(s.innerText).slice(0, 40);
        if (/(^|[\s_-])(title|heading|caption)([\s_-]|$)/i.test(typeof s.className === 'string' ? s.className : '') &&
            txt(s.innerText) && txt(s.innerText).length < 60 && !s.querySelector('input,select,textarea,table')) return txt(s.innerText).slice(0, 40);
        if (s.tagName === 'TABLE' || (s.querySelector && s.querySelector('table'))) return '';
        s = s.previousElementSibling; n++;
      }
      cur = cur.parentElement; depth++;
    }
    return '';
  };
  const tableTitle = (box, tbl, cells) => {
    const cap = box && box.querySelector('.ui-jqgrid-title');
    let t = (cap && txt(cap.innerText)) || nearHeading(box || tbl) || idHint(tbl, '');
    if (t && cells && cells.toLowerCase().indexOf(t.toLowerCase()) === 0) t = '';     // "Tags: Tags" -> "Tags"
    return t;
  };
  // video / audio: flag links before you click them, and pages that are mainly a player
  const VIDEO_URL = /\/videos?\/|\/watch\b|youtube\.com\/|youtu\.be\/|vimeo\.com\/\d|dailymotion\.com\/video|\.(mp4|m3u8|webm|mov|mkv)(\?|#|$)/i;
  const AUDIO_URL = /\/(audio|podcasts?|radio|listen)\/|\.(mp3|m4a|aac|ogg|oga|wav|flac)(\?|#|$)|open\.spotify\.com\/(episode|show)|podcasts\.apple\.com/i;
  const mediaOfUrl = (u) => VIDEO_URL.test(u) ? 'video' : (AUDIO_URL.test(u) ? 'audio' : '');
  const pageMedia = () => {
    let v = 0, a = 0;
    document.querySelectorAll('video').forEach(e => { if (visible(e) && e.getBoundingClientRect().width >= 200) v++; });
    document.querySelectorAll('audio').forEach(e => { if (visible(e) || e.controls) a++; });
    document.querySelectorAll('iframe').forEach(f => {
      const s = f.getAttribute('src') || '';
      if (!visible(f) || f.getBoundingClientRect().width < 200) return;
      if (/youtube\.com\/embed|player\.vimeo|jwplayer|brightcove|players\.|\/player\/|dailymotion\.com\/embed|vidible|anvato|uplynk/i.test(s)) v++;
      else if (/spotify\.com\/embed|soundcloud\.com|podcasts\.apple|megaphone|omny|simplecast|libsyn|buzzsprout/i.test(s)) a++;
    });
    document.querySelectorAll('.jwplayer,.video-js,.vjs-tech,[class*="video-player"],[class*="videoPlayer"],[data-video-id]').forEach(e => { if (visible(e) && e.getBoundingClientRect().width >= 200) v++; });
    const og = (document.querySelector('meta[property="og:type"]') || {}).content || '';
    if (/^video/i.test(og)) v++;
    if (/^(music|audio)/i.test(og)) a++;
    const pathKind = mediaOfUrl(location.pathname);
    if (pathKind === 'video') v++; else if (pathKind === 'audio') a++;
    if (!v && !a) return null;
    return { k: v >= a ? 'video' : 'audio' };
  };
  const openModal = () => {
    const sel = '.modal.in,.modal[style*="display: block"],[aria-modal="true"],dialog[open],.ui-dialog';
    const all = Array.prototype.filter.call(document.querySelectorAll(sel), (m) => {
      if (!visible(m) || m.getAttribute('aria-hidden') === 'true') return false;
      if (m.classList.contains('ui-dialog')) { const ov = document.querySelector('.ui-widget-overlay'); return !!(ov && visible(ov)); }
      return true;
    });
    return all.length ? all[all.length - 1] : null;
  };
  const optionList = el => Array.prototype.map.call(el.options || [], o => txt(o.text) || o.value);
  const pickOption = (el, want) => {
    const opts = Array.prototype.slice.call(el.options || []);
    const w = String(want);
    let hit = opts.find(o => txt(o.text) === w) || opts.find(o => o.value === w);
    if (!hit) {
      const lw = w.toLowerCase();
      const c = opts.filter(o => txt(o.text).toLowerCase().indexOf(lw) >= 0);
      if (c.length === 1) hit = c[0];
    }
    if (!hit && /^#\d+$/.test(w)) hit = opts[parseInt(w.slice(1), 10) - 1];
    return hit || null;
  };

  const resolve = () => {
    if (A.gen && String(A.gen).split(':')[0] !== S.sid) return { err: 'stale', msg: 'that list belongs to a previous page (run ls)' };
    const el = S.refs[(A.i | 0) - 1];
    if (!el) return { err: 'stale', msg: 'no item ' + A.i + ' in the current list (run ls)' };
    if (!el.isConnected) return { err: 'stale', msg: 'item ' + A.i + ' is no longer on the page (run ls)' };
    const k = kindOf(el);
    if (A.gen && A.gen !== S.sid + ':' + S.gen) return { err: 'stale', msg: 'the list you used is out of date (run ls)' };
    if (fpOf(el, k) !== S.fps[(A.i | 0) - 1]) return { err: 'changed', msg: 'item ' + A.i + ' changed since it was listed (run ls)' };
    return { el: el, k: k };
  };

  const ASIDE = 'aside,nav,footer,[role="complementary"],[class*="sidebar"],[class*="related"],[class*="recirc"],[class*="rail"],' +
                '[class*="promo"],[class*="newsletter"],[class*="most-popular"],[class*="trending"],[id*="sidebar"],[id*="related"]';
  const bestArticle = (d) => {
    // 1. the page's own headline anchors the search: prefer text in the same article/main region
    const h1 = Array.prototype.find.call(d.querySelectorAll('h1'), h => h.getClientRects().length && txt(h.innerText));
    const scope = (h1 && h1.closest('article,main,[role="main"],[itemprop="articleBody"]')) || null;
    // 2. explicit article-body markers win when they hold real text
    const marked = Array.prototype.find.call(d.querySelectorAll('[itemprop="articleBody"],[data-component-name="article-body"],.article__content,.article-body,.story-body,.entry-content,.post-content'),
      e => txt(e.innerText).length >= (scope ? 250 : 600) && !e.closest(ASIDE) && (!scope || scope.contains(e) || e.contains(scope)));
    if (marked) return marked;
    const score = new Map();
    const ps = d.querySelectorAll('p');
    for (let i = 0; i < ps.length && i < 600; i++) {
      const p = ps[i];
      if (p.closest(ASIDE)) continue;                       // sidebars, related boxes, promos
      if (scope && !scope.contains(p)) continue;            // outside the headline's article
      const n = txt(p.innerText).length;
      if (n < 60) continue;
      const a = p.parentElement; if (!a) continue;
      score.set(a, (score.get(a) || 0) + n);
      const g = a.parentElement; if (g) score.set(g, (score.get(g) || 0) + n / 2);
    }
    let best = null, bs = 0;
    score.forEach((s, e) => { if (s > bs) { bs = s; best = e; } });
    if (bs >= 800 || (scope && bs >= 250)) return best;      // a short story inside the headline's own article still counts
    if (scope) {                                            // nothing big inside the scope: try the whole page once
      const s2 = new Map();
      for (let i = 0; i < ps.length && i < 600; i++) {
        const p = ps[i]; if (p.closest(ASIDE)) continue;
        const n = txt(p.innerText).length; if (n < 60 || !p.parentElement) continue;
        s2.set(p.parentElement, (s2.get(p.parentElement) || 0) + n);
      }
      s2.forEach((s, e) => { if (s > bs) { bs = s; best = e; } });
      if (bs >= 800) return best;
    }
    return null;
  };
  // Inline players in the text: replace each (just while reading) with one marker line,
  // "[VIDEO 0:44] caption", then restore the page exactly as it was.
  const EMBED_SEL = 'video,audio,iframe,.video-player,[class*="video-player"],[class*="videoPlayer"],[class*="video-resource"],' +
    '[class*="video__"],[class*="VideoPlayer"],[data-video-id],.jwplayer,.video-js,figure[class*="video"],[class*="audio-player"],[class*="podcast-player"]';
  const EMBED_IFRAME = /youtube\.com\/embed|player\.vimeo|jwplayer|brightcove|players\.|\/player\/|dailymotion\.com\/embed|vidible|anvato|uplynk|spotify\.com\/embed|soundcloud|podcasts\.apple|megaphone|omny|simplecast|libsyn|buzzsprout/i;
  const AUDIO_HINT = /audio|podcast|spotify|soundcloud|megaphone|omny|simplecast|libsyn|buzzsprout/i;
  const markEmbeds = (root) => {
    const undo = [];
    const found = [];
    root.querySelectorAll(EMBED_SEL).forEach(e => {
      if (e === root || e.contains(root)) return;
      if (e.tagName === 'IFRAME' && !EMBED_IFRAME.test(e.getAttribute('src') || '')) return;
      if (!e.getClientRects().length) return;
      const t = txt(e.innerText);
      if (t.length > 400) return;                         // a container of the article itself, not a player
      found.push(e);
    });
    const outer = found.filter(e => !found.some(o => o !== e && o.contains(e)));
    outer.forEach(e => {
      const d = e.ownerDocument;
      const t = txt(e.innerText);
      const dm = /\b(\d{1,2}:\d{2}(?::\d{2})?)\b/.exec(t);
      const cap = txt(t.replace(dm ? dm[0] : '', '')).slice(0, 140) || txt(e.getAttribute('title') || e.getAttribute('aria-label') || '');
      const kind = (e.tagName === 'AUDIO' || AUDIO_HINT.test((e.className && String(e.className)) + ' ' + (e.getAttribute('src') || ''))) ? 'AUDIO' : 'VIDEO';
      const m = d.createElement('div');
      m.textContent = '[' + kind + (dm ? ' ' + dm[1] : '') + ']' + (cap ? ' ' + cap : '');
      e.parentNode.insertBefore(m, e);
      const hadStyle = e.hasAttribute('style'), oldStyle = e.getAttribute('style');
      // attribute API only: touching e.style leaves an empty style="" behind even after removal (Chromium)
      e.setAttribute('style', (oldStyle ? oldStyle + ';' : '') + 'display:none !important');
      undo.push(() => { if (hadStyle) e.setAttribute('style', oldStyle); else e.removeAttribute('style'); m.remove(); });
    });
    return () => { for (let i = undo.length - 1; i >= 0; i--) { try { undo[i](); } catch (x) {} } };
  };
  const pageText = (d, mode) => {
    if (!d.body) return '';
    if (mode === 'article') {
      const best = bestArticle(d);
      if (best) {
        const h1 = Array.prototype.find.call(d.querySelectorAll('h1'), h => h.getClientRects().length && txt(h.innerText));
        const head = h1 && !best.contains(h1) ? txt(h1.innerText) + '\n\n' : '';
        const restore = markEmbeds(best);
        try { return head + (best.innerText || ''); } finally { restore(); }
      }
    }
    const restore = markEmbeds(d.body);
    try { return d.body.innerText || ''; } finally { restore(); }
  };

  const ops = {
    install: () => { install(window); return { ok: true }; },

    snap: () => {
      install(window);
      S.gen++; S.refs = []; S.fps = [];
      const max = A.max || 600;
      // pass 1: candidates in page order, with labels
      const cands = [];
      const taken = new Set();
      const labelledHref = new Set();
      const headedTables = new Set();
      for (const [el, fr] of nodes(document, '')) {
        if (cands.length >= max * 2) break;
        if (el.tagName === 'TABLE' && el.classList.contains('ui-jqgrid-btable') && !el.querySelector('tr.jqgrow') && visible(el.closest('.ui-jqgrid') || el)) {
          // an empty list is still a list: show its heading so you know it is there
          const box = el.closest('.ui-jqgrid');
          const th = box && box.querySelector('.ui-jqgrid-htable th');
          const hr = th && th.closest('tr');
          if (hr && !headedTables.has(el)) {
            headedTables.add(el);
            const hl = rowCells(hr);
            const ttl = tableTitle(box, el, hl);
            cands.push({ el: hr, k: 'hdr', fr: fr, lab: ((ttl ? ttl + ': ' : '') + (hl || 'list') + '  (empty)').slice(0, 160), fb: false });
          }
        }
        const k = kindOf(el);
        if (!k || !visible(el)) continue;
        if (k === 'row') {
          const tbl = el.closest('table,[role="grid"],[role="table"],[role="treegrid"]');
          if (tbl && !headedTables.has(tbl)) {
            headedTables.add(tbl);
            const hr = headerRowFor(el);
            if (hr && visible(hr)) {
              const hl = rowCells(hr);
              const ttl = tableTitle(tbl.closest('.ui-jqgrid'), tbl, hl);
              if (hl) cands.push({ el: hr, k: 'hdr', fr: fr, lab: ((ttl ? ttl + ': ' : '') + hl).slice(0, 160), fb: false });
            }
          }
        }
        if (clickable(k)) {
          let p = el.parentElement, skip = false, n = 0;
          while (p && n < 8) { if (taken.has(p)) { skip = true; break; } p = p.parentElement; n++; }
          if (skip) continue;
        }
        taken.add(el);
        el.__cliFallback = 0;
        const lab = labelOf(el, k);
        const fb = (k === 'a' && el.__cliFallback === 1);
        if (k === 'a' && !fb) labelledHref.add(el.href);
        cands.push({ el: el, k: k, fr: fr, lab: lab, fb: fb });
      }
      // an open modal dialog blocks the page behind it: list only the dialog
      const modal = openModal();
      let modalInfo = null;
      if (modal) {
        for (let i = cands.length - 1; i >= 0; i--) if (!modal.contains(cands[i].el)) cands.splice(i, 1);
        const h = modal.querySelector('.modal-header h1,.modal-header h2,.modal-header h3,.modal-header h4,.ui-dialog-title,[class*="title"],h1,h2,h3');
        let title = h ? txt(h.innerText) : (modal.getAttribute('aria-label') || labelledBy(modal) || '');
        const bodyEl = modal.querySelector('.modal-body,.ui-dialog-content,[class*="body"]') || modal;
        const hasFields = !!bodyEl.querySelector('input:not([type="hidden"]),select,textarea');
        const msg = hasFields ? '' : txt(bodyEl.innerText).slice(0, 600);
        modalInfo = { t: title, m: msg };
      }
      // pass 2: number them, dropping text-less links that duplicate a labelled link
      const items = [];
      const shownHref = new Set();
      for (const c of cands) {
        if (items.length >= max) break;
        if (c.k === 'a') {
          if (c.fb && labelledHref.has(c.el.href)) continue;
          if (shownHref.has(c.el.href)) continue;
          shownHref.add(c.el.href);
        }
        S.refs.push(c.el); S.fps.push(fpOf(c.el, c.k));
        const it = { i: S.refs.length, k: c.k, l: c.lab, v: valueOf(c.el, c.k) };
        if (c.el.disabled) it.d = 1;
        if (c.fr) it.f = c.fr;
        if (c.k === 'a') { it.h = String(c.el.href || '').slice(0, 160); const mk = mediaOfUrl(c.el.href || ''); if (mk) it.m = mk; }
        if (c.k === 'sel') it.n = (c.el.options || []).length;
        items.push(it);
      }
      const navOf = new Map(), navCount = new Map();
      items.forEach(it => {
        if (it.k !== 'a' && it.k !== 'btn') return;
        const el = S.refs[it.i - 1];
        if (el.closest('.nav-tabs,[role="tablist"]')) return;
        const nc = el.closest(NAVSEL);
        if (nc) { navOf.set(it, nc); navCount.set(nc, (navCount.get(nc) || 0) + 1); }
      });
      navOf.forEach((nc, it) => { if (navCount.get(nc) >= 10) it.nav = 1; });
      const counts = {};
      items.forEach(it => { if (it.k === 'btn' || it.k === 'a') counts[it.l] = (counts[it.l] || 0) + 1; });
      // Same-named buttons: name each by its section heading; if headings don't tell them apart,
      // by the part of its id that isn't its own text (btn_from_add -> "Add (From)").
      const groups = {};
      items.forEach(it => { if ((it.k === 'btn' || it.k === 'a') && counts[it.l] > 1) (groups[it.l] = groups[it.l] || []).push(it); });
      const GENERIC = /^(edit|add|remove|delete|clear|change|configure|modify|new|view|details|select|browse|import|export|copy|clone|move up|move down)$/i;
      items.forEach(it => {
        if (it.k !== 'btn' || !GENERIC.test(it.l) || counts[it.l] > 1) return;
        const h = idHint(S.refs[it.i - 1], it.l);
        if (h) it.l = (it.l + ' (' + h + ')').slice(0, 120);
      });
      Object.keys(groups).forEach(label => {
        const g = groups[label];
        const heads = g.map(it => headingFor(S.refs[it.i - 1]));
        const distinct = new Set(heads.filter(Boolean)).size === g.length;
        g.forEach((it, x) => {
          let sfx = distinct ? heads[x] : '';
          if (!sfx) { const hint = idHint(S.refs[it.i - 1], label); sfx = hint || heads[x]; }
          if (sfx) it.l = (label + ' (' + sfx + ')').slice(0, 120);
        });
      });
      let art = null;
      const best = bestArticle(document);
      if (best) {
        const t = txt(best.innerText);
        const words = t.split(' ').length;
        if (words >= 150) art = { w: words, lead: t.slice(0, 420) };
      }
      return { url: location.href, title: document.title, gen: S.sid + ':' + S.gen, items: items,
               frames: frameList, art: art, modal: modalInfo, media: pageMedia(), dlg: drain() };
    },

    act: () => {
      install(window);
      const r = resolve();
      if (r.err) return r;
      const el = r.el, k = r.k;
      if (el.disabled) return { err: 'disabled', msg: 'item ' + A.i + ' is disabled' };
      S.armed = A.confirm ? 1 : 0;
      if (A.prompt != null) S.promptAnswer = A.prompt;
      try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
      const verb = A.verb;
      if (verb === 'click' && k === 'row') {
        // click the first cell, as a person would (some grids listen on cells, not rows)
        const cell = el.querySelector('td,[role="gridcell"],[role="cell"]') || el;
        cell.click();
      } else if (verb === 'click') {
        if (k === 'a') {
          const tg = (el.getAttribute('target') || '').toLowerCase();
          if (tg && tg !== '_self' && tg !== '_top' && tg !== '_parent' && /^https?:/i.test(el.href)) {
            return { ok: true, nav: el.href, k: k };
          }
        }
        el.click();
      } else if (verb === 'dblclick') {
        const target = (k === 'row') ? (el.querySelector('td,[role="gridcell"],[role="cell"]') || el) : el;
        const w = el.ownerDocument.defaultView;
        const o = { bubbles: true, cancelable: true, view: w };
        target.dispatchEvent(new w.MouseEvent('mousedown', o)); target.dispatchEvent(new w.MouseEvent('mouseup', o));
        target.dispatchEvent(new w.MouseEvent('click', Object.assign({ detail: 1 }, o)));
        target.dispatchEvent(new w.MouseEvent('dblclick', Object.assign({ detail: 2 }, o)));
      } else if (verb === 'fill') {
        if (k === 'sel') {
          const o = pickOption(el, A.value);
          if (!o) return { err: 'nooption', msg: 'no unique option matching "' + A.value + '"', opts: optionList(el) };
          setValue(el, o.value);
        } else if (k === 'chk' || k === 'rad') {
          const want = /^(1|on|yes|true|y|x|check(ed)?)$/i.test(String(A.value));
          if ((valueOf(el, k) === 'on') !== want) el.click();
        } else if (k === 'in' || k === 'pw') {
          setValue(el, String(A.value));
        } else {
          return { err: 'kind', msg: 'item ' + A.i + ' (' + k + ') does not take a value' };
        }
      } else if (verb === 'focus') {
        try { el.focus(); } catch (e) {}
        if (k === 'in' || k === 'pw') { try { el.select(); } catch (e) {} }
      } else if (verb === 'submit') {
        const f = el.form || el.closest('form');
        if (!f) return { err: 'noform', msg: 'item ' + A.i + ' is not inside a form' };
        if (f.requestSubmit) f.requestSubmit(); else f.submit();
      } else if (verb === 'opts') {
        if (k !== 'sel') return { err: 'kind', msg: 'item ' + A.i + ' is not a list' };
        return { ok: true, opts: optionList(el), v: valueOf(el, k) };
      } else {
        return { err: 'verb', msg: 'unknown verb ' + verb };
      }
      return { ok: true, k: k, v: valueOf(el, k), h: (k === 'a' ? String(el.href || '') : undefined), dlg: drain() };
    },

    settle: () => {
      install(window);
      let rs = document.readyState;
      for (const f of document.querySelectorAll('iframe,frame')) {
        try { const d = f.contentDocument; if (d && d.readyState !== 'complete') rs = d.readyState; } catch (e) {}
      }
      const leaving = S.leaving ? (Date.now() - S.leaving) : 0;
      return { rs: rs, p: S.pending, m: S.mut, lv: leaving, url: location.href, dlg: drain() };
    },

    rect: () => {
      // centre of item i in top-level viewport coordinates (adds up frame offsets)
      const r = resolve();
      if (r.err) return r;
      try { r.el.scrollIntoView({ block: 'center' }); } catch (e) {}
      const b = r.el.getBoundingClientRect();
      let x = b.left + b.width / 2, y = b.top + b.height / 2;
      let w = r.el.ownerDocument.defaultView;
      while (w && w !== topWin && w.frameElement) {
        const fb = w.frameElement.getBoundingClientRect();
        x += fb.left; y += fb.top;
        w = w.parent;
      }
      return { ok: true, x: x, y: y, v: valueOf(r.el, r.k) };
    },

    html: () => {
      const parts = ['<!-- ' + location.href + ' -->', document.documentElement.outerHTML];
      document.querySelectorAll('iframe,frame').forEach((f, i) => {
        try { const d = f.contentDocument; if (d && d.documentElement) parts.push('<!-- frame ' + frameInfo(f, i + 1) + ': ' + d.location.href + ' -->', d.documentElement.outerHTML); } catch (e) {}
      });
      return { html: parts.join('\n') };
    },

    // The page's own "Edit" for a selected row: nearest enabled Edit/Open/Properties control,
    // including one inside a closed dropdown (Fireware's Action > Edit Policy). Clicks it.
    editfor: () => {
      const r = resolve();
      if (r.err) return r;
      const re = /^\s*(edit|open|view|properties|modify)\b/i;
      const near = r.el.closest('table,[role="grid"]') || r.el;
      const anc = new Set(); for (let p = near; p; p = p.parentElement) anc.add(p);
      let best = null, bestDepth = -1;
      document.querySelectorAll('a,button,[role="menuitem"],input[type="button"],input[type="submit"]').forEach(e => {
        const t = txt(e.innerText || e.textContent || e.value);
        if (!re.test(t) || e.disabled || e.closest('.disabled') || e.closest(NAVSEL)) return;
        let p = e, depth = 0;
        while (p && !anc.has(p)) p = p.parentElement;
        for (let q = p; q; q = q.parentElement) depth++;
        if (depth > bestDepth) { best = e; bestDepth = depth; }
      });
      if (!best) return { ok: false };
      const label = txt(best.innerText || best.textContent || best.value);
      best.click();
      return { ok: true, l: label, dlg: drain() };
    },

    arm: () => { install(window); S.armed = 1; return { ok: true }; },

    mark: () => {
      const r = resolve();
      if (r.err) return r;
      if (r.el.ownerDocument !== document) return { err: 'frame', msg: 'file upload inside a frame is not supported; open the frame URL directly' };
      document.querySelectorAll('[data-cli-mark]').forEach(n => n.removeAttribute('data-cli-mark'));
      r.el.setAttribute('data-cli-mark', '1');
      return { ok: true, k: r.k };
    },

    disarm: () => { S.armed = 0; S.promptAnswer = null; S.leaving = 0; return { ok: true, dlg: drain() }; },

    text: () => {
      install(window);
      const parts = [];
      const walk = (d, name, depth) => {
        const t = pageText(d, A.mode);
        if (txt(t)) parts.push((name ? '\n=== frame: ' + name + ' ===\n' : '') + t);
        if (depth > 4) return;
        if (A.mode === 'article') return;
        const fs = d.querySelectorAll('iframe,frame');
        for (let i = 0; i < fs.length; i++) {
          const meta = frameMeta(fs[i]);
          if (meta.ad || meta.w < 120 || meta.h < 60) continue;
          let cd = null;
          try { cd = fs[i].contentDocument; } catch (e) {}
          const fname = (name ? name + '/' : '') + frameInfo(fs[i], i + 1);
          if (cd && cd.documentElement) walk(cd, fname, depth + 1);
          else parts.push('\n=== frame ' + fname + ' is on another site (see: frames) ===');
        }
      };
      walk(document, '', 0);
      return { url: location.href, title: document.title, text: parts.join('\n'), dlg: drain() };
    },

    consent: () => {
      const targets = ['accept all', 'accept all cookies', 'accept cookies', 'allow all', 'allow all cookies', 'i agree'];
      for (const b of document.querySelectorAll('button,[role="button"],input[type="button"],input[type="submit"]')) {
        const t = txt(b.innerText || b.value).toLowerCase();
        if (targets.indexOf(t) >= 0 && visible(b)) { b.click(); return { ok: true, clicked: t }; }
      }
      return { ok: false };
    }
  };

  try {
    if (op === 'chunk') return S.big.substr(A.o | 0, A.n | 0);
    const fn = ops[op];
    if (!fn) return JSON.stringify({ err: 'op', msg: 'unknown kernel op ' + op });
    const out = JSON.stringify(fn());
    if (out.length > 16000) { S.big = out; return JSON.stringify({ big: out.length }); }
    return out;
  } catch (e) {
    return JSON.stringify({ err: 'kernel', msg: String(e && e.message || e) });
  }
}
'@

# ===========================================================================
# 2. Output helpers
# ===========================================================================
function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $script:AppDir)) { $null = New-Item -ItemType Directory -Path $script:AppDir -Force }
        $lf = $script:Cfg.LogFile
        if ((Test-Path $lf) -and (Get-Item $lf).Length -gt 2MB) { Move-Item $lf "$lf.1" -Force }
        Add-Content -Path $lf -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $msg)
    } catch {}
}
function Test-Quiet { return ($script:UI -and $script:UI.Quiet) }
function Write-Ok([string]$m)   { if (Test-Quiet) { Add-UiMsg $m; return }; Write-Host "  $m" -ForegroundColor Green }
function Write-Info([string]$m) { if (Test-Quiet) { Add-UiMsg $m; return }; Write-Host "  $m" -ForegroundColor Gray }
function Write-Warn([string]$m) { if (Test-Quiet) { Add-UiMsg $m; return }; Write-Host "  $m" -ForegroundColor Yellow }
function Write-Fail([string]$m) { if (Test-Quiet) { Add-UiMsg "! $m"; return }; Write-Host "  $m" -ForegroundColor Red }

function Get-InnermostMessage($err) {
    if ($null -eq $err) { return 'unknown error' }
    $e = $err
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    $depth = 0
    while ($e -and $depth -lt 20) {
        $depth++
        if ($e -is [System.AggregateException] -and $e.InnerExceptions.Count -gt 0) {
            return (@($e.InnerExceptions | ForEach-Object { Get-InnermostMessage $_ }) -join ' | ')
        }
        if ($e.InnerException) { $e = $e.InnerException; continue }
        break
    }
    if ($e -and $e.Message) { return "$($e.Message)" }
    return "$err"
}

function Get-ConsoleWidth {
    $w = 100
    try { $w = [Console]::WindowWidth } catch {}
    if ($w -lt 40) { $w = 100 }
    return ($w - 4)
}

# ===========================================================================
# 3. PURE LAYER - no browser. Everything here is unit-tested offline.
# ===========================================================================

# --- 3a. Targets (URLs) --------------------------------------------------------
$script:HostRx = '^(?<host>\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?)(?::(?<port>\d{1,5}))?(?<rest>[/?#].*)?$'

function ConvertTo-CliTarget([string]$s) {
    $s = "$s".Trim()
    if (-not $s) { return $null }
    if ($s -match '^(?i)(https?|ftp|file)://') { return $s }
    if ($s -match '^(?i)(about|data|view-source|chrome):') { return $s }
    $m = [regex]::Match($s, $script:HostRx)
    if (-not $m.Success) { return $null }
    $h = $m.Groups['host'].Value
    $port = $m.Groups['port'].Value
    $scheme = 'https'
    if ($port) {
        if (@('80', '8000', '8080') -contains $port) { $scheme = 'http' }
    } elseif ($h -match '^(?i)localhost$|^127\.|^\[::1\]$') {
        $scheme = 'http'
    }
    return "$($scheme)://$s"
}

function Test-IsTargetLike([string]$s) {
    $s = "$s".Trim()
    if (-not $s -or $s -match '\s') { return $false }
    if ($s -match '^(?i)(https?|ftp|file)://' -or $s -match '^(?i)(about|data|view-source):') { return $true }
    $m = [regex]::Match($s, $script:HostRx)
    if (-not $m.Success) { return $false }
    $h = $m.Groups['host'].Value
    if ($h -match '^\d+$') { return $false }
    return ($h.Contains('.') -or $m.Groups['port'].Success -or $h.StartsWith('[') -or $h -ieq 'localhost')
}

# --- 3b. Lexing -----------------------------------------------------------------
function Split-CliLine([string]$line) {
    $out = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $q = [char]0
    foreach ($ch in "$line".ToCharArray()) {
        if ($q -ne [char]0) {
            if ($ch -eq $q) { $q = [char]0 }
            [void]$sb.Append($ch)
        } elseif ($ch -eq '"' -or $ch -eq "'") {
            $q = $ch; [void]$sb.Append($ch)
        } elseif ($ch -eq ';') {
            $t = $sb.ToString().Trim(); if ($t) { $out.Add($t) }
            [void]$sb.Clear()
        } else { [void]$sb.Append($ch) }
    }
    $t = $sb.ToString().Trim(); if ($t) { $out.Add($t) }
    return $out.ToArray()
}

function Get-Unquoted([string]$s) {
    $s = "$s".Trim()
    if ($s.Length -ge 2 -and (($s[0] -eq '"' -and $s[-1] -eq '"') -or ($s[0] -eq "'" -and $s[-1] -eq "'"))) {
        return $s.Substring(1, $s.Length - 2)
    }
    return $s
}

# A reference is a number or a quoted label:  12   "Login"   'Admin Settings'
$script:RefRx = '(?<ref>\d+|"[^"]+"|''[^'']+'')'

function ConvertTo-CliRef([string]$tok) {
    if ($tok -match '^\d+$') { return @{ N = [int]$tok } }
    return @{ Label = (Get-Unquoted $tok) }
}

# --- 3c. Parsing: Line -> Cmd ---------------------------------------------------
function ConvertTo-CliCommand([string]$t) {
    $t = "$t".Trim()
    if (-not $t -or $t.StartsWith('#')) { return @{ Op = 'nop' } }

    # <ref>[!]                     activate
    if ($t -match ('^' + $script:RefRx + '(?<bang>!?)$')) {
        return @{ Op = 'act'; Ref = (ConvertTo-CliRef $matches['ref']); Bang = ($matches['bang'] -eq '!') }
    }
    # <ref> = value                fill  (value '?' = secret prompt, env:NAME = environment)
    if ($t -match ('^' + $script:RefRx + '\s*=\s*(?<val>.*)$')) {
        return (New-FillCmd (ConvertTo-CliRef $matches['ref']) $matches['val'])
    }
    # @bookmark
    if ($t -match '^@(\S+)$') { return @{ Op = 'go'; Target = "bm:$($matches[1])"; Bang = $false } }
    # bare host / ip[:port] / url
    if (Test-IsTargetLike $t) { return @{ Op = 'go'; Target = $t; Bang = $false } }

    $verb = $t; $rest = ''
    if ($t -match '^(\S+)\s+(.*)$') { $verb = $matches[1]; $rest = $matches[2].Trim() }
    $bang = $false
    if ($verb.Length -gt 1 -and $verb.EndsWith('!')) { $bang = $true; $verb = $verb.Substring(0, $verb.Length - 1) }
    $verb = $verb.ToLowerInvariant()

    $needRef = {
        param($op)
        if ($rest -match ('^' + $script:RefRx + '$')) { return @{ Op = $op; Ref = (ConvertTo-CliRef $matches['ref']); Bang = $bang } }
        if ($rest) { return @{ Op = $op; Ref = @{ Label = $rest }; Bang = $bang } }
        return @{ Op = 'error'; Msg = "usage: $verb <n|label>" }
    }

    switch -Regex ($verb) {
        '^(go|g|open)$'          { if ($rest) { return @{ Op = 'go'; Target = $rest; Bang = $bang } }; return @{ Op = 'error'; Msg = 'usage: go <host[:port]|url|bm:name>' } }
        '^(ls|l|list)$'          { return @{ Op = 'ls'; Filter = $rest } }
        '^(p|page)$'             { return @{ Op = 'page' } }
        '^(text|t)$'             { return @{ Op = 'text'; Mode = 'all' } }
        '^(read|r|reader)$'      { return @{ Op = 'text'; Mode = 'article' } }
        '^(find|/)$'             { if ($rest) { return @{ Op = 'find'; Pattern = $rest } }; return @{ Op = 'error'; Msg = 'usage: find <text|regex>' } }
        '^(click|c)$'            { return (& $needRef 'act') }
        '^(type|set)$'           {
            if ($rest -match ('^' + $script:RefRx + '\s+(?<val>.*)$')) { return (New-FillCmd (ConvertTo-CliRef $matches['ref']) $matches['val']) }
            return @{ Op = 'error'; Msg = "usage: $verb <n|""label""> <value>" }
        }
        '^(secret|pw)$'          { $c = & $needRef 'fill'; if ($c.Op -eq 'fill') { $c.Secret = $true }; return $c }
        '^(opts|options)$'       { return (& $needRef 'opts') }
        '^(upload)$'             {
            if ($rest -match ('^' + $script:RefRx + '\s+(?<val>.+)$')) { return @{ Op = 'upload'; Ref = (ConvertTo-CliRef $matches['ref']); Path = (Get-Unquoted $matches['val']) } }
            return @{ Op = 'error'; Msg = 'usage: upload <n|"label"> <file>' }
        }
        '^(key|k)$'              { if ($rest) { return @{ Op = 'key'; Key = $rest; Bang = $bang } }; return @{ Op = 'error'; Msg = 'usage: key <Enter|Tab|Escape|ArrowDown|...>' } }
        '^(enter)$'              { return @{ Op = 'key'; Key = 'Enter'; Bang = $bang } }
        '^(submit)$'             {
            if (-not $rest) { return @{ Op = 'key'; Key = 'Enter'; Bang = $bang } }
            return (& $needRef 'submit')
        }
        '^(back|b)$'             { return @{ Op = 'hist'; Dir = 'back'; Bang = $bang } }
        '^(fwd|forward|f)$'      { return @{ Op = 'hist'; Dir = 'fwd'; Bang = $bang } }
        '^(reload)$'             { return @{ Op = 'hist'; Dir = 'reload'; Bang = $bang } }
        '^(frames)$'             { return @{ Op = 'frames' } }
        '^(human|v)$'            { return @{ Op = 'human' } }
        '^(savehtml|html)$'      { return @{ Op = 'savehtml'; Path = (Get-Unquoted $rest) } }
        '^(tabs)$'               { return @{ Op = 'tabs' } }
        '^(tab)$'                { if ($rest -match '^\d+$') { return @{ Op = 'tab'; Id = [int]$rest } }; return @{ Op = 'tabs' } }
        '^(new)$'                { return @{ Op = 'new'; Target = $rest } }
        '^(close|x)$'            { return @{ Op = 'close' } }
        '^(bm|bookmark|bookmarks)$' { return @{ Op = 'bm'; Arg = $rest } }
        '^(auth)$'               { return @{ Op = 'auth'; User = $rest } }
        '^(consent)$'            { return @{ Op = 'consent' } }
        '^(cert)$'               { return @{ Op = 'cert' } }
        '^(shot|screenshot)$'    { return @{ Op = 'shot'; Path = (Get-Unquoted $rest) } }
        '^(pdf)$'                { return @{ Op = 'pdf'; Path = (Get-Unquoted $rest) } }
        '^(dl|downloads)$'       { return @{ Op = 'dl'; Path = (Get-Unquoted $rest) } }
        '^(run)$'                { if ($rest) { return @{ Op = 'run'; Path = (Get-Unquoted $rest) } }; return @{ Op = 'error'; Msg = 'usage: run <file|name>' } }
        '^(wait)$'               { $sec = 1.0; if ($rest -match '^\d+(\.\d+)?$') { $sec = [double]$rest }; return @{ Op = 'wait'; Sec = $sec } }
        '^(expect)$'             { if ($rest) { return @{ Op = 'expect'; Pattern = (Get-Unquoted $rest) } }; return @{ Op = 'error'; Msg = 'usage: expect <text|regex>' } }
        '^(debug)$'              { return @{ Op = 'debug' } }
        '^(log)$'                { return @{ Op = 'log' } }
        '^(h|help|\?)$'          { return @{ Op = 'help' } }
        '^(q|quit|exit)$'        { return @{ Op = 'quit' } }
    }
    return @{ Op = 'error'; Msg = "unknown command '$verb' (type help)" }
}

function New-FillCmd($ref, [string]$val) {
    $v = Get-Unquoted $val
    if ($v -eq '?') { return @{ Op = 'fill'; Ref = $ref; Secret = $true } }
    if ($v -match '^env:(\w+)$') { return @{ Op = 'fill'; Ref = $ref; Env = $matches[1] } }
    return @{ Op = 'fill'; Ref = $ref; Value = $v }
}

# --- 3d. Rendering ----------------------------------------------------------------
function Format-CliItem($it) {
    $lab = "$($it.l)"
    if ($it.m) { $lab = "[$("$($it.m)".ToUpperInvariant())] $lab" }
    $body = $lab
    switch ("$($it.k)") {
        'chk'  { $mark = ' '; if ($it.v -eq 'on') { $mark = 'x' }; $body = "[$mark] $lab" }
        'rad'  { $mark = ' '; if ($it.v -eq 'on') { $mark = '*' }; $body = "($mark) $lab" }
        'in'   { $v = "$($it.v)"; if (-not $v) { $v = '(empty)' }; $body = "$lab = $v" }
        'pw'   { $v = "$($it.v)"; if (-not $v) { $v = '(empty)' }; $body = "$lab = $v" }
        'sel'  { $body = "$lab = $($it.v)  ($($it.n) options)" }
        'file' { $v = "$($it.v)"; if (-not $v) { $v = '(no file)' }; $body = "$lab = $v" }
        'row'  { $mark = ' '; if ($it.v -eq 'on') { $mark = '>' }; $body = "$mark $lab" }
        'hdr'  { $body = "-- $lab --" }
    }
    $line = "[{0,3}] {1,-4} {2}" -f $it.i, $it.k, $body
    if ($it.d) { $line += '  (disabled)' }
    if ($it.f) { $line += "  @$($it.f)" }
    return $line
}

function Select-CliItems($items, [string]$filter) {
    $items = @($items)
    $f = "$filter".Trim().ToLowerInvariant()
    if (-not $f) { return $items }
    $kinds = @{
        'in' = @('in', 'pw'); 'fields' = @('in', 'pw', 'sel', 'chk', 'rad', 'file')
        'btn' = @('btn'); 'buttons' = @('btn'); 'a' = @('a'); 'links' = @('a')
        'sel' = @('sel'); 'chk' = @('chk', 'rad'); 'row' = @('row', 'hdr'); 'rows' = @('row', 'hdr')
    }
    if ($f -eq 'menu' -or $f -eq 'nav') { return @($items | Where-Object { $_.nav }) }
    if ($kinds.ContainsKey($f)) { $ks = $kinds[$f]; return @($items | Where-Object { $ks -contains $_.k }) }
    $out = New-Object System.Collections.Generic.List[object]
    $lastHdr = $null; $hdrHit = $false; $hdrShown = $false
    foreach ($it in $items) {
        $hit = "$($it.l)".ToLowerInvariant().Contains($f)
        if ($it.k -eq 'hdr') { $lastHdr = $it; $hdrHit = $hit; $hdrShown = $false; if ($hit) { $out.Add($it); $hdrShown = $true }; continue }
        if ($it.k -eq 'row') {
            if ($hdrHit -or $hit) {
                if (-not $hdrShown -and $lastHdr) { $out.Add($lastHdr); $hdrShown = $true }
                $out.Add($it)
            }
            continue
        }
        $hdrHit = $false; $lastHdr = $null
        if ($hit) { $out.Add($it) }
    }
    return $out.ToArray()
}

function Resolve-CliLabel($items, [string]$label) {
    # exact (case-insensitive) beats unique substring; ambiguity is an error, never a guess
    $items = @($items)
    $l = $label.Trim().ToLowerInvariant()
    $exact = @($items | Where-Object { "$($_.l)".Trim().ToLowerInvariant() -eq $l })
    if ($exact.Count -eq 1) { return @{ Hit = $exact[0] } }
    if ($exact.Count -gt 1) { return @{ Ambiguous = $exact } }
    $sub = @($items | Where-Object { "$($_.l)".ToLowerInvariant().Contains($l) })
    if ($sub.Count -eq 1) { return @{ Hit = $sub[0] } }
    if ($sub.Count -gt 1) { return @{ Ambiguous = $sub } }
    return @{}
}

function Test-CliChallenge($snap) {
    # Pages that exist to make a person prove they are a person. We never answer these;
    # we hand them to the user in a visible window.
    if (-not $snap) { return $false }
    $u = "$($snap.url)"; $t = "$($snap.title)"
    if ($u -match '(?i)google\.[a-z.]+/sorry/|/cdn-cgi/challenge-platform|captcha') { return $true }
    if ($t -match '(?i)^just a moment|attention required|verify you are (a )?human|are you a robot|unusual traffic|security check') { return $true }
    foreach ($f in @($snap.frames)) {
        if ($f -and "$($f.u)" -match '(?i)recaptcha/api2/(anchor|bframe)|hcaptcha\.com|challenges\.cloudflare\.com' -and [int]$f.w -ge 100) { return $true }
    }
    return $false
}

function Get-CliChallengeTarget($snap) {
    # Google's sorry page carries the address you were going to in ?continue=
    $u = "$($snap.url)"
    $m = [regex]::Match($u, '[?&]continue=([^&]+)')
    if ($m.Success) { try { return [Uri]::UnescapeDataString($m.Groups[1].Value) } catch {} }
    return $u
}

function Get-CliItemKey($it) { return "$($it.k)|$($it.l)|$($it.h)|$($it.f)|$([bool]$it.d)" }

function Get-CliDelta($before, $after) {
    # Items are identified by kind|label|target|frame, so the delta survives renumbering.
    $b = @{}; foreach ($x in @($before)) { if ($x) { $b[(Get-CliItemKey $x)] = $true } }
    $a = @{}; foreach ($x in @($after))  { if ($x) { $a[(Get-CliItemKey $x)] = $true } }
    $added = @(@($after) | Where-Object { $_ -and -not $b.ContainsKey((Get-CliItemKey $_)) })
    $gone = @($b.Keys | Where-Object { -not $a.ContainsKey($_) }).Count
    return @{ Added = $added; Gone = $gone }
}

function Test-CliSecondary($items, [int]$idx) {
    # A button whose label merely wraps a neighbouring link's label ("More - <headline>",
    # "Options for <row>") is secondary: hidden from the summary view, still numbered.
    $items = @($items)
    $it = $items[$idx]
    if ("$($it.k)" -ne 'btn') { return $false }
    $l = "$($it.l)"
    for ($j = [Math]::Max(0, $idx - 2); $j -le [Math]::Min($items.Count - 1, $idx + 2); $j++) {
        if ($j -eq $idx) { continue }
        $o = $items[$j]
        $ol = "$($o.l)"
        # labels are capped at 80 chars, so for long headlines both sides can be exactly 80 long
        if ("$($o.k)" -eq 'a' -and $ol.Length -ge 12 -and $l -ne $ol) {
            $probe = $ol.Substring(0, [Math]::Min(40, $ol.Length))
            if ($l.Contains($probe)) { return $true }
        }
    }
    return $false
}

function Split-CliWords([string]$line, [int]$width) {
    if ($line.Length -le $width) { return @($line) }
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($w in ($line -split ' ')) {
        while ($w.Length -gt $width) {
            if ($cur) { $out.Add($cur); $cur = '' }
            $out.Add($w.Substring(0, $width)); $w = $w.Substring($width)
        }
        if (-not $cur) { $cur = $w }
        elseif (($cur.Length + 1 + $w.Length) -le $width) { $cur = "$cur $w" }
        else { $out.Add($cur); $cur = $w }
    }
    if ($cur) { $out.Add($cur) }
    return $out.ToArray()
}

function Format-CliText([string]$text, [int]$width) {
    # Wrap prose; align runs of tab-separated lines (HTML tables) into columns.
    $lines = ("$text" -replace "`r", '') -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    $blank = 0
    $i = 0
    while ($i -lt $lines.Count) {
        $ln = $lines[$i].TrimEnd()
        if ($ln.Contains("`t")) {
            $rows = New-Object System.Collections.Generic.List[object]
            while ($i -lt $lines.Count -and $lines[$i].Contains("`t")) {
                $rows.Add(@($lines[$i].TrimEnd() -split "`t" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })); $i++
            }
            $ncol = ($rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
            $w = @(0) * $ncol
            foreach ($r in $rows) { for ($c = 0; $c -lt $r.Count; $c++) { $w[$c] = [Math]::Min(30, [Math]::Max($w[$c], $r[$c].Length)) } }
            foreach ($r in $rows) {
                $cells = for ($c = 0; $c -lt $r.Count; $c++) {
                    $cell = $r[$c]; if ($cell.Length -gt 30) { $cell = $cell.Substring(0, 29) + '~' }
                    $cell.PadRight($w[$c])
                }
                $row = (($cells -join '  ').TrimEnd())
                if ($row.Length -gt $width) { $row = $row.Substring(0, $width - 1) + '~' }
                if ($row.Trim()) { $out.Add($row) }
            }
            $blank = 0
            continue
        }
        if (-not $ln.Trim()) {
            $blank++
            if ($blank -eq 1 -and $out.Count -gt 0) { $out.Add('') }
        } else {
            $blank = 0
            foreach ($piece in (Split-CliWords ($ln -replace '\s+', ' ').Trim() $width)) { $out.Add($piece) }
        }
        $i++
    }
    while ($out.Count -gt 0 -and -not $out[$out.Count - 1]) { $out.RemoveAt($out.Count - 1) }
    return $out.ToArray()
}

function Get-NavHint([string]$m) {
    if ($m -match 'ERR_CONNECTION_REFUSED') { return 'Nothing listening on that port. Admin GUIs often move off 443 (FortiGate 4443/8443/10443, SonicWall 4433, WatchGuard 8080).' }
    if ($m -match 'ERR_CONNECTION_TIMED_OUT|ERR_TIMED_OUT|ERR_ADDRESS_UNREACHABLE') { return 'Unreachable. Check routing/VPN, and the trusted-hosts / admin-access list on the device.' }
    if ($m -match 'ERR_NAME_NOT_RESOLVED') { return 'DNS failed. Try the IP.' }
    if ($m -match 'ERR_CERT|ERR_SSL') { if ($StrictTls) { return 'Certificate rejected (-StrictTls is on).' }; return 'TLS handshake failed (old cipher/TLS 1.0 device?). Try http:// if the device allows it.' }
    if ($m -match 'ERR_CONNECTION_RESET|ERR_EMPTY_RESPONSE') { return 'Connection reset. Wrong scheme (http vs https) or the device rejected this source IP.' }
    if ($m -match 'ERR_PROXY|ERR_TUNNEL') { return 'Proxy problem. Check -Proxy.' }
    return ''
}

# ===========================================================================
# 4. EFFECT LAYER - the kernel call and the few Pup primitives
# ===========================================================================
# --- watchdog: every call into Chrome runs on a worker with a hard time limit ---------------
$script:Worker = $null
$script:WorkerOk = $true

function Get-PupWorker {
    if ($script:Worker -and $script:Worker.Runspace -and $script:Worker.Runspace.RunspaceStateInfo.State -eq 'Opened') { return $script:Worker }
    if (-not $script:WorkerOk) { return $null }
    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $m = Get-Module Pup
        $spec = 'Pup'; if ($m -and $m.Path) { $spec = $m.Path }
        $iss.ImportPSModule([string[]]@($spec))
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $script:Worker = $ps
        Write-Log 'watchdog: worker ready'
        return $ps
    } catch {
        $script:WorkerOk = $false
        Write-Log "watchdog: unavailable, calling Chrome directly ($(Get-InnermostMessage $_))"
        return $null
    }
}

function Invoke-PupGuarded([string]$cmd, [hashtable]$p, [int]$ms = 15000, [string]$what = '') {
    # Runs one Pup cmdlet with a time limit. A call that never returns is abandoned, logged,
    # and reported as a timeout instead of freezing the whole browser.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tag = "$cmd $what".Trim()
    $ps = Get-PupWorker
    if (-not $ps) {
        $out = & $cmd @p -ErrorAction Stop
        Write-Log ("call {0} {1}ms (direct)" -f $tag, $sw.ElapsedMilliseconds)
        return $out
    }
    $ps.Commands.Clear()
    $ps.Streams.ClearStreams()
    [void]$ps.AddCommand($cmd)
    foreach ($k in $p.Keys) { [void]$ps.AddParameter($k, $p[$k]) }
    [void]$ps.AddParameter('ErrorAction', 'Stop')
    $h = $ps.BeginInvoke()
    if (-not $h.AsyncWaitHandle.WaitOne($ms)) {
        Write-Log ("TIMEOUT {0}: no answer from Chrome after {1}ms - abandoned" -f $tag, $ms)
        try { $null = $ps.BeginStop($null, $null) } catch {}
        $script:Worker = $null
        throw [System.TimeoutException]::new("Chrome did not answer ($tag) within $([int]($ms / 1000))s")
    }
    try { $out = $ps.EndInvoke($h) }
    catch { Write-Log ("call {0} {1}ms FAILED: {2}" -f $tag, $sw.ElapsedMilliseconds, (Get-InnermostMessage $_)); throw }
    if ($sw.ElapsedMilliseconds -gt 1500) { Write-Log ("call {0} slow: {1}ms" -f $tag, $sw.ElapsedMilliseconds) }
    elseif ($script:TraceAll) { Write-Log ("call {0} {1}ms" -f $tag, $sw.ElapsedMilliseconds) }
    if ($out.Count -eq 0) { return $null }
    if ($out.Count -eq 1) { return $out[0] }
    return @($out)
}

function Get-Tab { if ($script:S.Tabs.ContainsKey($script:S.Cur)) { return $script:S.Tabs[$script:S.Cur] }; return $null }

function New-CliError([string]$kind, [string]$msg) { return [pscustomobject]@{ err = $kind; msg = $msg } }

function Invoke-Kernel([string]$op, $argsH) {
    $tab = Get-Tab
    if (-not $tab) { return (New-CliError 'notab' 'no open tab') }
    # [string] casts matter: on Windows PowerShell 5.1, ConvertTo-Json output is PSObject-wrapped,
    # and Pup's System.Text.Json serializer walks the wrapper until it hits its depth limit.
    $json = '{}'
    if ($argsH) { $json = [string](ConvertTo-Json -InputObject $argsH -Compress -Depth 6) }
    $kargs = [object[]]@([string]$op, [string]$json)
    $raw = $null
    try {
        $raw = Invoke-PupGuarded 'Invoke-PupScript' @{ Page = $tab.Page; Script = $script:KERNEL; Arguments = $kargs; AsString = $true } 10000 $op
    } catch {
        return (New-CliError 'eval' (Get-InnermostMessage $_))
    }
    if (-not $raw) { return (New-CliError 'empty' 'no result (page busy or navigating)') }
    $raw = "$raw"
    if ($raw.StartsWith('{"big":')) {
        # Large result: pull it in 12 KB pieces instead of one big CDP reply.
        $total = [int](($raw | ConvertFrom-Json).big)
        $sb = New-Object System.Text.StringBuilder $total
        $off = 0
        while ($off -lt $total) {
            try {
                $piece = Invoke-PupGuarded 'Invoke-PupScript' @{ Page = $tab.Page; Script = $script:KERNEL; Arguments = ([object[]]@([string]'chunk', [string]('{"o":' + $off + ',"n":12000}'))); AsString = $true } 10000 'chunk'
            } catch { return (New-CliError 'eval' ("chunk at $off of $($total): " + (Get-InnermostMessage $_))) }
            if (-not $piece) { return (New-CliError 'empty' "chunk at $off of $total came back empty") }
            [void]$sb.Append("$piece"); $off += "$piece".Length
        }
        $raw = $sb.ToString()
    }
    try { return ($raw | ConvertFrom-Json) } catch { return (New-CliError 'json' ("could not parse page data ($($raw.Length) chars): " + (Get-InnermostMessage $_))) }
}

function Get-SnapGen { $t = Get-Tab; if ($t -and $t.Snap) { return "$($t.Snap.gen)" }; return '' }

function Test-NavError($r) { return ($r.err -eq 'eval' -or $r.err -eq 'empty') -and ("$($r.msg)" -match 'context|destroy|navigat|detach|Target closed|no result|did not answer') }

function Show-Dialogs($dl) {
    if ($null -eq $dl) { return }
    if ($dl -is [System.Collections.Generic.List[object]]) { $dl = $dl.ToArray() }
    foreach ($d in $dl) {
        if (-not $d) { continue }
        if (Test-Quiet) {
            switch ("$($d.t)") {
                'alert'   { Add-UiMsg "The page says: $($d.m)" }
                'confirm' { if ($d.r) { Add-UiMsg "The page asked '$($d.m)' - answered OK." }
                            else { Add-UiMsg "The page asked '$($d.m)' - answered Cancel. Press ! on that line to answer OK." } }
                'prompt'  { Add-UiMsg "The page asked for input: $($d.m)" }
            }
            continue
        }
        switch ("$($d.t)") {
            'alert'   { Write-Host "  ALERT: $($d.m)" -ForegroundColor Yellow }
            'confirm' {
                if ($d.r) { Write-Host "  CONFIRM answered OK: $($d.m)" -ForegroundColor Magenta }
                else      { Write-Host "  CONFIRM cancelled: $($d.m)" -ForegroundColor Magenta
                            Write-Host "    (repeat the command with ! to answer OK, e.g. 12!)" -ForegroundColor DarkGray }
            }
            'prompt'  { Write-Host "  PROMPT ($(if ($d.r) {'answered'} else {'cancelled'})): $($d.m)" -ForegroundColor Magenta }
        }
    }
}

function Wait-Settle([int]$TimeoutMs = 0) {
    # Quiescence = document(s) complete AND no fetch/XHR in flight AND no DOM mutation for a beat.
    # Long-poll pages never reach zero requests, so 1.5s of DOM silence also counts as settled.
    if ($TimeoutMs -le 0) { $TimeoutMs = $script:Cfg.TimeoutMs }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 120
    $lastM = -1; $quiet = -1
    $dlg = New-Object System.Collections.Generic.List[object]
    $settled = $false
    $lastNote = -1
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        $r = Invoke-Kernel 'settle' $null
        if ($r.err -and "$($r.msg)" -match 'did not answer') {
            Write-Warn 'Chrome stopped answering on this page (it may be busy or stuck). Press b to go back, F5 to reload, or L to see the log.'
            Write-Log 'settle: page not answering - stopped waiting'
            $script:S.Stuck = $true
            return $false
        }
        $sec = [int]($sw.ElapsedMilliseconds / 1000)
        if ($sec -ne $lastNote) {
            $lastNote = $sec
            $why = if ($r.err) { "page not answering ($($r.err))" } else {
                $bits = @()
                if ($r.rs -ne 'complete') { $bits += "page $($r.rs)" }
                if ([double]$r.lv -gt 0) { $bits += 'leaving the page' }
                if ([int]$r.p -gt 0) { $bits += "$($r.p) request$(if ([int]$r.p -ne 1) {'s'}) in flight" }
                if ([long]$r.m -ne $lastM) { $bits += 'page still changing' }
                if (-not $bits.Count) { $bits += 'almost done' }
                $bits -join ', '
            }
            if ($sec -ge 1) { Write-Log ("settle {0}s: {1}  url={2}" -f $sec, $why, "$($r.url)") }
            if ((Test-Quiet) -and $sec -ge 1) { Show-BrowseStatus ("Working {0}s: {1}   (gives up at {2}s)" -f $sec, $why, [int]($TimeoutMs / 1000)) 'DarkGreen' }
            elseif (-not (Test-Quiet) -and $sec -ge 3 -and $sec % 3 -eq 0) { Write-Info ("...{0}s: {1}" -f $sec, $why) }
        }
        if (-not $r.err) {
            foreach ($d in @($r.dlg)) { if ($d) { $dlg.Add($d) } }
            $leaving = ([double]$r.lv -gt 0 -and [double]$r.lv -lt $TimeoutMs)
            if ($r.rs -eq 'complete' -and -not $leaving) {
                if ([long]$r.m -eq $lastM) {
                    if ($quiet -lt 0) { $quiet = $sw.ElapsedMilliseconds }
                    $q = $sw.ElapsedMilliseconds - $quiet
                    if (([int]$r.p -eq 0 -and $q -ge 300) -or $q -ge 1500) { $settled = $true; break }
                } else { $quiet = -1 }
                $lastM = [long]$r.m
            } else { $quiet = -1 }
        }
        Start-Sleep -Milliseconds 200
    }
    $d = Invoke-Kernel 'disarm' $null
    if (-not $d.err) { foreach ($x in @($d.dlg)) { if ($x) { $dlg.Add($x) } } }
    Show-Dialogs ($dlg.ToArray())
    if (-not $settled) { Write-Warn ("(page still busy after {0}s; showing what is there)" -f [int]($TimeoutMs / 1000)); Write-Log 'settle: gave up waiting' }
    else { Write-Log ("settle: done in {0}ms" -f $sw.ElapsedMilliseconds) }
    return $settled
}

function Update-Snap {
    $tab = Get-Tab
    if (-not $tab) { return $null }
    if ($script:S.Stuck) { $script:S.LastErr = 'Chrome is not answering on this page'; return $null }
    $r = Invoke-Kernel 'snap' @{ max = 600 }
    if ($r.err) { $script:S.LastErr = "$($r.err): $($r.msg)"; Write-Log "snap failed: $($r.msg)"; return $null }
    Show-Dialogs $r.dlg
    $tab.Snap = $r
    return $r
}

function Show-Page([int]$Max = -1) {
    if ($Max -lt 0) { $Max = $script:Cfg.ListMax }
    $tab = Get-Tab
    $s = Update-Snap
    if (Test-Quiet) { if (-not $s) { Write-Warn "Could not read the page: $($script:S.LastErr)" }; return }
    if (-not $s) { Write-Warn "Could not read the page: $($script:S.LastErr)"; Write-Info '(try: p   - if it repeats, run: debug   and send me the output)'; return }
    Write-Host ''
    Write-Host ('  ' + ('=' * [Math]::Min(76, (Get-ConsoleWidth)))) -ForegroundColor DarkCyan
    $title = "$($s.title)"; if (-not $title) { $title = '(no title)' }
    Write-Host "  $title" -ForegroundColor Cyan
    $u = "$($s.url)"; $cw = (Get-ConsoleWidth) - 10
    if ($u.Length -gt $cw) { $u = $u.Substring(0, [Math]::Max(20, $cw)) + '~' }
    Write-Host "  $u   [tab $($tab.Id)]" -ForegroundColor DarkGray
    $useful = @(@($s.frames) | Where-Object { $_ -and $_.xo -and -not $_.ad -and [int]$_.w -ge 120 -and [int]$_.h -ge 60 })
    $quiet = @(@($s.frames) | Where-Object { $_ -and $_.xo }).Count - $useful.Count
    foreach ($f in ($useful | Select-Object -First 3)) {
        $fu = "$($f.u)"; if ($fu.Length -gt 70) { $fu = $fu.Substring(0, 69) + '~' }
        Write-Host "  frame '$($f.n)' is on another site: $fu  (open it with: go <url>, see: frames)" -ForegroundColor DarkYellow
    }
    $extra = $quiet + [Math]::Max(0, $useful.Count - 3)
    if ($extra -gt 0) { Write-Host "  ($extra ad/tracker/hidden frames ignored - frames lists them)" -ForegroundColor DarkGray }
    Write-Host ('  ' + ('=' * [Math]::Min(76, (Get-ConsoleWidth)))) -ForegroundColor DarkCyan
    $all = @($s.items)
    if ($all.Count -eq 0) { Write-Info '(nothing to interact with - try: text)'; return }
    if ($s.media) { Write-Host ("  {0} page: the main content is a {1} player{2}" -f "$($s.media.k)".ToUpperInvariant(), "$($s.media.k)", $(if ($s.art) { ' (there is also an article: read)' } else { ' - there may be little or no text' })) -ForegroundColor Magenta }
    if ($s.modal) {
        $mt = "$($s.modal.t)"; if (-not $mt) { $mt = 'The page is asking' }
        Write-Host "  DIALOG: $mt" -ForegroundColor Magenta
        if ("$($s.modal.m)") { foreach ($ln in @(Split-CliWords "$($s.modal.m)" ((Get-ConsoleWidth) - 4))) { Write-Host "    $ln" -ForegroundColor Magenta } }
    }
    if (Test-CliChallenge $s) { Write-Host "  This page wants a person to answer a check. Type: human   (opens it in a browser window for you)" -ForegroundColor Magenta }
    $items = New-Object System.Collections.Generic.List[object]
    $navN = @($all | Where-Object { $_.nav }).Count
    for ($x = 0; $x -lt $all.Count; $x++) { if (-not (Test-CliSecondary $all $x) -and -not $all[$x].nav) { $items.Add($all[$x]) } }
    if ($navN) { Write-Host "  (site menu: $navN links - ls menu shows them)" -ForegroundColor DarkGray }
    $hidden = $all.Count - $items.Count
    $items = $items.ToArray()
    if ($s.art) {
        Write-Host ("  ARTICLE  about {0:N0} words   r  reads it  |  find <word> searches it" -f [int]$s.art.w) -ForegroundColor Green
        foreach ($ln in @(Split-CliWords ("$($s.art.lead)" + '...') ((Get-ConsoleWidth) - 2) | Select-Object -First 4)) { Write-Host "  $ln" }
        Write-Host ''
        if ($Max -gt 20) { $Max = 20 }
    }
    $show = $items
    if ($Max -gt 0 -and $items.Count -gt $Max) { $show = @($items | Select-Object -First $Max) }
    foreach ($it in $show) { Write-CliItem $it }
    $more = $items.Count - @($show).Count
    $notes = @()
    if ($more -gt 0) { $notes += "$more more" }
    if ($hidden -gt 0) { $notes += "$hidden menu buttons hidden" }
    if ($notes.Count) { Write-Host ("  ... {0}  (ls shows everything; ls <filter>, ls in|btn|a|sel)" -f ($notes -join ', ')) -ForegroundColor DarkGray }
}

function Write-CliItem($it) {
    if (Test-Quiet) { return }
    $c = 'White'
    switch ("$($it.k)") { 'a' { $c = 'Gray' } 'btn' { $c = 'White' } 'in' { $c = 'Cyan' } 'pw' { $c = 'Cyan' } 'sel' { $c = 'Cyan' } 'chk' { $c = 'Cyan' } 'rad' { $c = 'Cyan' } }
    if ($it.d) { $c = 'DarkGray' }
    Write-Host ('  ' + (Format-CliItem $it)) -ForegroundColor $c
}

function Resolve-Item($ref) {
    $tab = Get-Tab
    if (-not $tab) { Write-Fail 'No open tab'; return $null }
    if ($ref.Label) { $null = Update-Snap }
    if (-not $tab.Snap) { $null = Update-Snap }
    if (-not $tab.Snap) { Write-Fail "Could not read the page: $($script:S.LastErr)"; return $null }
    $items = @($tab.Snap.items)
    if ($ref.ContainsKey('N')) {
        $it = @($items | Where-Object { [int]$_.i -eq $ref.N }) | Select-Object -First 1
        if (-not $it) { Write-Fail "No item $($ref.N) on this page (ls to list)"; return $null }
        return $it
    }
    $m = Resolve-CliLabel $items $ref.Label
    if ($m.Hit) { return $m.Hit }
    if ($m.Ambiguous) {
        Write-Fail "'$($ref.Label)' matches $(@($m.Ambiguous).Count) items - use the number:"
        foreach ($x in @($m.Ambiguous) | Select-Object -First 10) { Write-CliItem $x }
        return $null
    }
    Write-Fail "Nothing labelled '$($ref.Label)' on this page"
    return $null
}

function Read-Secret([string]$prompt) {
    if (-not $script:Interactive) { throw "a secret prompt needs an interactive console (use env:NAME in scripts)" }
    if (Test-Quiet) { $v = Read-CliLine "$($prompt): " -Secret; if ($null -eq $v) { throw 'cancelled' }; return $v }
    $ss = Read-Host -Prompt "  $prompt" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Out-CliPager([string[]]$lines) {
    $lines = @($lines)
    $h = 25
    try { $h = [Console]::WindowHeight - 2 } catch {}
    if ($h -lt 8) { $h = 22 }
    if (-not $script:Interactive -or ($lines.Count -le $h -and -not (Test-Quiet))) {
        foreach ($l in $lines) { Write-CliTextLine $l }
        return
    }
    $pos = 0
    while ($true) {
        try { Clear-Host } catch {}
        $end = [Math]::Min($pos + $h - 1, $lines.Count - 1)
        for ($i = $pos; $i -le $end; $i++) { Write-CliTextLine $lines[$i] }
        $more = 'Space/Enter next page'; if ($end -ge $lines.Count - 1) { $more = 'end of text' }
        Write-Host (" lines {0}-{1} of {2}   {3}   Up/PgUp previous   b or q: back to the page " -f ($pos + 1), ($end + 1), $lines.Count, $more) -ForegroundColor White -BackgroundColor DarkBlue -NoNewline
        $k = $null
        try { $k = [Console]::ReadKey($true) } catch { return }
        switch ($k.Key) {
            'Spacebar'   { if ($end -ge $lines.Count - 1) { return }; $pos = [Math]::Min($pos + $h, [Math]::Max(0, $lines.Count - $h)) }
            'PageDown'   { $pos = [Math]::Min($pos + $h, [Math]::Max(0, $lines.Count - $h)) }
            'Enter'      { if ($end -ge $lines.Count - 1) { return }; $pos = [Math]::Min($pos + $h, [Math]::Max(0, $lines.Count - $h)) }
            'Backspace'  { return }
            'LeftArrow'  { return }
            'DownArrow'  { $pos = [Math]::Min($pos + 1, [Math]::Max(0, $lines.Count - $h)) }
            'UpArrow'    { $pos = [Math]::Max(0, $pos - 1) }
            'B'          { return }
            'PageUp'     { $pos = [Math]::Max(0, $pos - $h) }
            'G'          { if ($k.Modifiers -band [ConsoleModifiers]::Shift) { $pos = [Math]::Max(0, $lines.Count - $h) } else { $pos = 0 } }
            'Q'          { return }
            'Escape'     { return }
        }
    }
}

function Write-CliTextLine([string]$l) {
    if ($l -match '^=== frame') { Write-Host "  $l" -ForegroundColor DarkYellow }
    elseif ($l -match '^=== ') { Write-Host "  $($l.Substring(4))" -ForegroundColor Cyan }
    else { Write-Host "  $l" }
}

# --- navigation primitive -----------------------------------------------------------
function Invoke-Navigate([string]$url, [bool]$bang) {
    $tab = Get-Tab
    if (-not $tab) { Write-Fail 'No open tab'; return $false }
    if ($bang) { try { Set-PupPageHandler -Page $tab.Page -Event Dialog -Action Accept -ErrorAction Stop } catch {} }
    $ok = $true
    try {
        Invoke-PupGuarded 'Move-PupPage' @{ Page = $tab.Page; Url = ([string]$url); WaitForLoad = $true } ($script:Cfg.TimeoutMs + 15000) $url | Out-Null
    } catch {
        $m = Get-InnermostMessage $_
        if ($m -match '(?i)timeout|did not answer') {
            Write-Warn 'The page is slow to finish loading; showing what has arrived so far'
        } else {
            Write-Fail "Navigation failed: $m"
            $hint = Get-NavHint $m
            if ($hint) { Write-Info $hint }
            Write-Log "nav fail $url : $m"
            $ok = $false
        }
    } finally {
        if ($bang) { try { Remove-PupPageHandler -Page $tab.Page -Event Dialog -ErrorAction Stop } catch {} }
    }
    if (-not $ok) { return $false }
    $tab.Visited.Add($url)
    $null = Wait-Settle
    Show-Page
    return $true
}

function Invoke-CliMouseClick($it, [switch]$Double) {
    # Deliver the user's keypress as a real mouse click (or double-click) at the item's position.
    $tab = Get-Tab
    $r = Invoke-Kernel 'rect' @{ i = [int]$it.i; gen = (Get-SnapGen) }
    if ($r.err) { return $r }
    $seq = @(@('mouseMoved', 0), @('mousePressed', 1), @('mouseReleased', 1))
    if ($Double) { $seq += , @('mousePressed', 2); $seq += , @('mouseReleased', 2) }
    foreach ($step in $seq) {
        $type = $step[0]
        $p = @{ type = [string]$type; x = [double]$r.x; y = [double]$r.y; button = [string]'left'; clickCount = [int]$step[1] }
        if ($type -eq 'mouseMoved') { $p.button = [string]'none' }
        $null = Invoke-PupGuarded 'Invoke-PupCdpMessage' @{ Page = $tab.Page; Method = 'Input.dispatchMouseEvent'; Parameters = $p } 8000 $type
    }
    return $r
}

function Invoke-AfterAction($before) {
    $null = Wait-Settle
    $tab = Get-Tab
    if (-not $before) { Show-Page; return $true }
    $s = Update-Snap
    if (-not $s) { Write-Warn "Could not read the page: $($script:S.LastErr)"; return $true }
    if ("$($s.url)" -ne "$($before.url)") { Show-Page; return $true }
    $d = Get-CliDelta $before.items $s.items
    $n = @($d.Added).Count
    if (Test-Quiet) {
        if ([bool]$before.modal -ne [bool]$s.modal) {
            # a dialog opened or closed: that is the change, not every item on the page
            if ($s.modal) { $mt = "$($s.modal.t)"; if (-not $mt) { $mt = 'a question' }; Add-UiMsg "A dialog opened: $mt   (Esc closes it)"; $script:UI.JumpDialog = $true }
            else { Add-UiMsg 'Dialog closed.'; $script:UI.DialogClosed = $true }
            return $true
        }
        foreach ($x in @($d.Added)) { $script:UI.NewKeys[(Get-CliItemKey $x)] = $true }
        if ($n -gt 0) { Add-UiMsg "$n new item$(if ($n -ne 1) {'s'}) appeared on this page (marked +)" }
        elseif ($d.Gone -eq 0) { Add-UiMsg 'Nothing visible changed on the page.' }
        return $true
    }
    if ($n -eq 0 -and $d.Gone -eq 0) { Write-Info '(no visible change on the page - p shows it, text reads it)'; return $true }
    $msg = "same page: $n new item$(if ($n -ne 1) {'s'})"
    if ($d.Gone) { $msg += ", $($d.Gone) gone" }
    Write-Host "  $msg" -ForegroundColor DarkCyan
    $shown = 0
    foreach ($it in @($d.Added)) { Write-CliItem $it; $shown++; if ($shown -ge $script:Cfg.ListMax) { break } }
    if ($n -gt $shown) { Write-Host "  ... $($n - $shown) more new  (ls)" -ForegroundColor DarkGray }
    return $true
}

function Get-SnapBefore { $t = Get-Tab; if ($t -and $t.Snap) { return $t.Snap }; return $null }

# --- tabs ---------------------------------------------------------------------------
function Initialize-CliPage($page) {
    if ($script:S.Preload) {
        try {
            $src = [string]('(' + $script:KERNEL + ")('install','{}');")
            $null = Invoke-PupCdpMessage -Page $page -Method 'Page.addScriptToEvaluateOnNewDocument' -Parameters @{ source = $src } -ErrorAction Stop
        } catch {
            $script:S.Preload = $false
            Write-Log "preload unavailable: $(Get-InnermostMessage $_)"
        }
    }
    if (-not $StrictTls) {
        try { $null = Invoke-PupCdpMessage -Page $page -Method 'Security.setIgnoreCertificateErrors' -Parameters @{ ignore = $true } -ErrorAction Stop } catch {}
    }
    try { Set-PupViewport -Page $page -Width 1440 -Height 900 -ErrorAction Stop } catch {}
    try {
        if (-not (Test-Path $script:Cfg.DlDir)) { $null = New-Item -ItemType Directory -Path $script:Cfg.DlDir -Force }
        Set-PupDownloadPath -Page $page -Path $script:Cfg.DlDir -ErrorAction Stop
    } catch {}
}

function New-CliTab([string]$target) {
    $page = New-PupPage -Browser $script:S.Browser -ErrorAction Stop
    Initialize-CliPage $page
    $id = $script:S.NextId
    $script:S.NextId++
    $script:S.Tabs[$id] = [pscustomobject]@{
        Id = $id; Page = $page; Snap = $null
        Visited = (New-Object System.Collections.Generic.List[string])
    }
    $script:S.Cur = $id
    if ($target) {
        $u = ConvertTo-CliTarget $target
        if ($u) { return (Invoke-Navigate $u $false) }
        Write-Fail "Not a URL: $target"
        return $false
    }
    return $true
}

# ===========================================================================
# 5. INTERPRETER - one handler per Op. Every handler returns $true (Ok) or $false (Err).
# ===========================================================================
$script:Ops = @{}

$script:Ops['nop']   = { param($c) return $true }
$script:Ops['error'] = { param($c) Write-Fail $c.Msg; return $false }
$script:Ops['quit']  = { param($c) $script:S.Running = $false; return $true }

$script:Ops['go'] = {
    param($c)
    $t = Get-Unquoted "$($c.Target)"
    if ($t -match '^bm:(.+)$') {
        $n = $matches[1]
        if (-not $script:S.Bookmarks.ContainsKey($n)) { Write-Fail "No bookmark '$n' (bm to list)"; return $false }
        $t = $script:S.Bookmarks[$n]
    }
    $u = ConvertTo-CliTarget $t
    if (-not $u) { Write-Fail "Not a URL or host: $t"; return $false }
    return (Invoke-Navigate $u ([bool]$c.Bang))
}

$script:Ops['act'] = {
    param($c)
    $it = Resolve-Item $c.Ref
    if (-not $it) { return $false }
    switch ("$($it.k)") {
        { $_ -in 'in', 'pw' } {
            if (-not $script:Interactive) { Write-Fail "Item $($it.i) is a field; use $($it.i)=value"; return $false }
            if ($it.k -eq 'pw') { $v = Read-Secret "$($it.l)" }
            elseif (Test-Quiet) { $v = Read-CliLine "$($it.l): "; if ($null -eq $v) { return $true } }
            else { $v = Read-Host "  $($it.l)" }
            return (& $script:Ops['fill'] @{ Op = 'fill'; Ref = @{ N = [int]$it.i }; Value = $v })
        }
        'sel' {
            if (Test-Quiet) {
                $o = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = 'opts' }
                if ($o.err) { Write-Fail $o.msg; return $false }
                $pick = Select-CliChoice "$($it.l)" @($o.opts) "$($o.v)"
                if ($null -eq $pick) { return $true }
                return (& $script:Ops['fill'] @{ Op = 'fill'; Ref = @{ N = [int]$it.i }; Value = ('#' + ($pick + 1)) })
            }
            $null = & $script:Ops['opts'] @{ Op = 'opts'; Ref = @{ N = [int]$it.i } }
            if (-not $script:Interactive) { return $false }
            $v = Read-Host '  choose (text or #n)'
            if (-not $v) { return $true }
            return (& $script:Ops['fill'] @{ Op = 'fill'; Ref = @{ N = [int]$it.i }; Value = $v })
        }
        'file' { Write-Fail "Item $($it.i) is a file picker; use: upload $($it.i) <path>"; return $false }
        'hdr'  { Write-Info 'That line is the column headings for the rows below it.'; return $true }
    }
    $before = Get-SnapBefore
    if ($it.k -eq 'row' -and "$($it.v)" -eq 'on') { return (Open-CliRow $it $before) }
    $verb = 'click'
    $r = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = $verb; confirm = [bool]$c.Bang }
    if ($r.err -and -not (Test-NavError $r)) { Write-Fail $r.msg; return $false }
    if ($r.nav) {
        Write-Info "(opens in a new window; following it in this tab)"
        return (Invoke-Navigate "$($r.nav)" $false)
    }
    Show-Dialogs $r.dlg
    if ($it.k -eq 'chk' -or $it.k -eq 'rad' -or $it.k -eq 'row') {
        if ("$($r.v)" -eq "$($it.v)" -and $it.k -ne 'row') {
            # The box ignored a scripted click (some only accept real input): click it with the mouse.
            try { $null = Invoke-CliMouseClick $it } catch { Write-Log "mouse click: $(Get-InnermostMessage $_)" }
            $null = Wait-Settle 6000
            $null = Update-Snap
            $now = @(@((Get-Tab).Snap.items) | Where-Object { "$($_.l)" -eq "$($it.l)" })[0]
            if ($now) { $r = [pscustomobject]@{ v = $now.v } }
        } else { $null = Wait-Settle 4000 }
        if ($it.k -eq 'row') {
            if ($verb -eq 'click' -and (Test-Quiet)) { Add-UiMsg 'Row selected. Enter again opens it (double-click); or use the page''s Edit button.' }
            return (Invoke-AfterAction $before)
        }
        Write-Ok ("[{0}] {1} -> {2}" -f $it.i, $it.l, $r.v)
        if (Test-CliChallenge (Get-Tab).Snap) { Write-Info 'If the site now wants pictures picked, press v to answer it in a browser window.' }
        return $true
    }
    if (-not (Test-Quiet)) { Write-Info ("clicked [{0}] {1}" -f $it.i, $it.l) }
    if ($it.k -eq 'a' -and $r.h -and "$($r.h)" -notmatch '^(?i)javascript:') {
        # Some sites only navigate on a real mouse gesture. If the click left us on the same
        # document, follow the link's address directly.
        $null = Wait-Settle 6000
        $now = Invoke-Kernel 'settle' $null
        $strip = { param($u) ("$u" -split '#')[0] }
        if (-not $now.err -and (& $strip $now.url) -eq (& $strip $before.url) -and (& $strip $r.h) -ne (& $strip $before.url)) {
            Write-Info '(the page ignored the click; following the link directly)'
            return (Invoke-Navigate "$($r.h)" $false)
        }
    }
    return (Invoke-AfterAction $before)
}

function Open-CliRow($it, $before) {
    # 1) a real double-click (two genuine clicks: a tick-box grid toggles twice, so the row stays selected)
    if (-not (Test-Quiet)) { Write-Info "opening [$($it.i)] (double-click)" }
    $dbl = $null
    try { $dbl = Invoke-CliMouseClick $it -Double } catch { Write-Log "double-click: $(Get-InnermostMessage $_)" }
    if (-not $dbl -or $dbl.err) { $null = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = 'dblclick' } }
    $null = Wait-Settle 6000
    $now = Update-Snap
    if (-not $now) { return $true }
    $grew = @((Get-CliDelta $before.items $now.items).Added).Count
    if ("$($now.url)" -ne "$($before.url)" -or ($now.modal -and -not $before.modal) -or "$($now.title)" -ne "$($before.title)" -or $grew -ge 3) {
        if (Test-Quiet) { return (Invoke-AfterAction $before) }
        Show-Page; return $true
    }
    # 2) nothing opened: this table has no double-click. Make sure the row is still selected,
    #    then use the page's own Edit command (Fireware: Action > Edit Policy).
    $row = @(@($now.items) | Where-Object { $_.k -eq 'row' -and "$($_.l)" -eq "$($it.l)" })[0]
    if ($row -and "$($row.v)" -ne 'on') {
        $null = Invoke-Kernel 'act' @{ i = [int]$row.i; gen = "$($now.gen)"; verb = 'click' }
        $null = Wait-Settle 3000
        $now = Update-Snap
        $row = @(@($now.items) | Where-Object { $_.k -eq 'row' -and "$($_.l)" -eq "$($it.l)" })[0]
    }
    if (-not $row) { Write-Warn 'The row is no longer on the page.'; return $false }
    $ed = Invoke-Kernel 'editfor' @{ i = [int]$row.i; gen = "$($now.gen)" }
    if ($ed.ok) {
        Write-Info "This table does not open on double-click; used the page's '$($ed.l)'."
        Write-Log "open row: via '$($ed.l)'"
        Show-Dialogs $ed.dlg
        return (Invoke-AfterAction $now)
    }
    Write-Warn "This table does not open on double-click, and no Edit command was found. Try the page's buttons (Action, Edit...)."
    return $true
}

$script:Ops['fill'] = {
    param($c)
    $it = Resolve-Item $c.Ref
    if (-not $it) { return $false }
    $v = $c.Value
    if ($c.Secret) { $v = Read-Secret "$($it.l)" }
    elseif ($c.Env) {
        $v = [Environment]::GetEnvironmentVariable($c.Env)
        if ($null -eq $v) { Write-Fail "Environment variable '$($c.Env)' is not set"; return $false }
    } elseif ($it.k -eq 'pw' -and -not $script:S.WarnedPw -and -not (Test-Quiet)) {
        Write-Info "(tip: $($it.i)=? prompts without echo; env:NAME reads an environment variable)"
        $script:S.WarnedPw = $true
    }
    if ($null -eq $v) { $v = '' }
    $r = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = 'fill'; value = "$v" }
    if ($r.err -eq 'nooption') {
        Write-Fail $r.msg
        $n = 1; foreach ($o in @($r.opts)) { Write-Host ("    #{0,-3} {1}" -f $n, $o); $n++ }
        return $false
    }
    if ($r.err) { Write-Fail $r.msg; return $false }
    # Frameworks that ignore programmatic value: fall back to real keystrokes.
    $expect = "$v"
    $got = "$($r.v)"
    $mismatch = $false
    if ($it.k -eq 'in') { $mismatch = ($got -ne $expect.Substring(0, [Math]::Min(60, $expect.Length))) }
    if ($it.k -eq 'pw') { $mismatch = ($got.Length -ne [Math]::Min(8, $expect.Length)) }
    if ($mismatch) {
        Write-Log "fill [$($it.i)] did not stick; using keystrokes"
        $tab = Get-Tab
        $null = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = 'fill'; value = '' }
        $null = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = 'focus' }
        try { $null = Invoke-PupGuarded 'Send-PupKey' @{ Page = $tab.Page; Text = ([string]$expect) } 15000 'text' } catch { Write-Fail "keystroke fallback failed: $(Get-InnermostMessage $_)"; return $false }
    }
    $shown = "$($r.v)"
    if ($it.k -eq 'pw') { $shown = '********' }
    Write-Ok ("[{0}] {1} = {2}" -f $it.i, $it.l, $shown)
    Show-Dialogs $r.dlg
    return $true
}

$script:Ops['opts'] = {
    param($c)
    $it = Resolve-Item $c.Ref
    if (-not $it) { return $false }
    $r = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = 'opts' }
    if ($r.err) { Write-Fail $r.msg; return $false }
    Write-Host "  [$($it.i)] $($it.l)" -ForegroundColor Cyan
    $n = 1
    foreach ($o in @($r.opts)) {
        $mark = ' '; if ("$o" -eq "$($r.v)") { $mark = '>' }
        Write-Host ("   {0} #{1,-3} {2}" -f $mark, $n, $o); $n++
    }
    return $true
}

$script:Ops['upload'] = {
    param($c)
    $it = Resolve-Item $c.Ref
    if (-not $it) { return $false }
    if ($it.k -ne 'file') { Write-Fail "Item $($it.i) is not a file picker"; return $false }
    $path = $c.Path
    if (-not (Test-Path -LiteralPath $path)) { Write-Fail "No such file: $path"; return $false }
    $path = (Resolve-Path -LiteralPath $path).Path
    $r = Invoke-Kernel 'mark' @{ i = [int]$it.i; gen = (Get-SnapGen) }
    if ($r.err) { Write-Fail $r.msg; return $false }
    $tab = Get-Tab
    try {
        $el = Find-PupElements -Page $tab.Page -Selector '[data-cli-mark="1"]' -First -ErrorAction Stop
        Send-PupFile -Element $el -FilePath $path -ErrorAction Stop
    } catch { Write-Fail "Upload failed: $(Get-InnermostMessage $_)"; return $false }
    Write-Ok "[$($it.i)] $($it.l) = $(Split-Path $path -Leaf)"
    return $true
}

$script:Ops['submit'] = {
    param($c)
    $it = Resolve-Item $c.Ref
    if (-not $it) { return $false }
    $before = Get-SnapBefore
    $r = Invoke-Kernel 'act' @{ i = [int]$it.i; gen = (Get-SnapGen); verb = 'submit'; confirm = [bool]$c.Bang }
    if ($r.err -and -not (Test-NavError $r)) { Write-Fail $r.msg; return $false }
    Show-Dialogs $r.dlg
    return (Invoke-AfterAction $before)
}

$script:Ops['key'] = {
    param($c)
    $tab = Get-Tab
    if (-not $tab) { return $false }
    $before = Get-SnapBefore
    if ($c.Bang) { $null = Invoke-Kernel 'arm' $null }
    try { $null = Invoke-PupGuarded 'Send-PupKey' @{ Page = $tab.Page; Key = ([string]$c.Key) } 15000 $c.Key }
    catch { Write-Fail "key failed: $(Get-InnermostMessage $_)"; return $false }
    return (Invoke-AfterAction $before)
}

$script:Ops['hist'] = {
    param($c)
    $tab = Get-Tab
    if (-not $tab) { return $false }
    try {
        switch ($c.Dir) {
            'back'   { $null = Invoke-PupGuarded 'Invoke-PupPageBack' @{ Page = $tab.Page; WaitForLoad = $true } ($script:Cfg.TimeoutMs + 15000) }
            'fwd'    { $null = Invoke-PupGuarded 'Invoke-PupPageForward' @{ Page = $tab.Page; WaitForLoad = $true } ($script:Cfg.TimeoutMs + 15000) }
            'reload' { $null = Invoke-PupGuarded 'Invoke-PupPageReload' @{ Page = $tab.Page; WaitForLoad = $true } ($script:Cfg.TimeoutMs + 15000) }
        }
        if ($c.Dir -ne 'reload') {
            # Chrome restores history pages frozen as you left them (a login page mid-submit, a policy
            # list from before your change). Reload so what you see is current.
            $null = Invoke-PupGuarded 'Invoke-PupPageReload' @{ Page = $tab.Page; WaitForLoad = $true } ($script:Cfg.TimeoutMs + 15000) 'after history'
        }
    } catch {
        $m = Get-InnermostMessage $_
        if ($m -notmatch '(?i)timeout|did not answer') { Write-Fail "$($c.Dir) failed: $m"; return $false }
    }
    return (Invoke-AfterAction)
}

$script:Ops['ls'] = {
    param($c)
    $s = Update-Snap
    if (-not $s) { Write-Fail "Could not read the page: $($script:S.LastErr)"; return $false }
    $items = Select-CliItems $s.items $c.Filter
    if (@($items).Count -eq 0) { Write-Info '(no matching items)'; return $true }
    if (-not $script:Interactive -or @($items).Count -le 40) { foreach ($it in $items) { Write-CliItem $it }; return $true }
    Out-CliPager @($items | ForEach-Object { Format-CliItem $_ })
    return $true
}

$script:Ops['page'] = { param($c) Show-Page; return $true }

function Get-CliCookieList($page) {
    # All domains, not just the current page's (Google's check sets its cookie on .google.com
    # while the window has usually moved on to the publisher by the time you come back).
    $raw = Invoke-PupCdpMessage -Page $page -Method 'Network.getAllCookies' -AsJson -ErrorAction Stop
    $cs = @(("$raw" | ConvertFrom-Json).cookies)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cs) {
        if (-not $c) { continue }
        $h = @{ name = [string]$c.name; value = [string]$c.value; domain = [string]$c.domain; path = [string]$c.path
                secure = [bool]$c.secure; httpOnly = [bool]$c.httpOnly }
        if ($c.sameSite) { $h.sameSite = [string]$c.sameSite }
        if (-not $c.session -and [double]$c.expires -gt 0) { $h.expires = [double]$c.expires }
        $list.Add($h)
    }
    return $list.ToArray()
}

function Set-CliCookieList($page, $list) {
    $list = @($list)
    if ($list.Count) { $null = Invoke-PupCdpMessage -Page $page -Method 'Network.setCookies' -Parameters @{ cookies = [object[]]$list } -ErrorAction Stop }
    return $list.Count
}

$script:Ops['human'] = {
    param($c)
    # Pup runs one Chrome at a time, so the hidden browser and the window take turns:
    #   save session -> close hidden -> open window with session -> you answer the check
    #   -> take the window's cookies -> close window -> reopen hidden -> restore tabs.
    $tab = Get-Tab
    if (-not $tab -or -not $tab.Snap) { Write-Fail 'No page open'; return $false }
    if (-not $script:Interactive) { Write-Fail 'Answering a human check needs you at the keyboard.'; return $false }
    $here = "$($tab.Snap.url)"
    $target = Get-CliChallengeTarget $tab.Snap
    $saved = @()
    try { $saved = @(Get-CliCookieList $tab.Page) } catch { Write-Log "save cookies: $(Get-InnermostMessage $_)" }
    $tabUrls = @{}
    foreach ($id in @($script:S.Tabs.Keys)) {
        $tt = $script:S.Tabs[$id]; $u = ''
        if ($tt.Snap) { $u = "$($tt.Snap.url)" } elseif ($tt.Visited.Count) { $u = $tt.Visited[$tt.Visited.Count - 1] }
        $tabUrls[$id] = $u
    }
    $cookies = $saved
    $done = $target
    $cancelled = $false

    if (Test-Quiet) { Show-BrowseStatus 'Opening a browser window...' 'DarkGreen' } else { Write-Info 'Opening a browser window...' }
    try { Stop-PupBrowser -Browser $script:S.Browser -ErrorAction SilentlyContinue } catch {}
    $script:S.Browser = $null
    $vb = $null
    try {
        $vb = New-CliBrowserInstance $false
        $vp = New-PupPage -Browser $vb -ErrorAction Stop
        try { $null = Set-CliCookieList $vp $saved } catch { Write-Log "cookies to window: $(Get-InnermostMessage $_)" }
        Move-PupPage -Page $vp -Url ([string]$here) -ErrorAction Stop
        try { Clear-Host } catch {}
        foreach ($m in @('', '  A browser window is open on that page.', '',
                         '  1. Answer the check in that window (tick the box, pick the pictures).',
                         '  2. When the page you wanted appears there, come back to this window.',
                         '  3. Press Enter here to continue in the text browser.   (Esc cancels)', '')) { Write-Host $m -ForegroundColor Gray }
        while ($true) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') { break }
            if ($k.Key -eq 'Escape') { $cancelled = $true; break }
        }
        if (-not $cancelled) {
            try { $cookies = @(Get-CliCookieList $vp) } catch { Write-Fail "Could not read the window's session: $(Get-InnermostMessage $_)" }
            try {
                $u = Invoke-PupScript -Page $vp -Script '() => location.href' -AsString -ErrorAction Stop
                if ("$u" -and "$u" -notmatch '(?i)/sorry/|captcha') { $done = "$u" }
            } catch {}
        }
    } catch {
        Write-Fail "Could not open a browser window: $(Get-InnermostMessage $_)"
    } finally {
        if ($vb) { try { Stop-PupBrowser -Browser $vb -ErrorAction SilentlyContinue } catch {} }
    }

    # Bring the text browser back, carrying the window's session.
    if (Test-Quiet) { Show-BrowseStatus 'Returning to the text browser...' 'DarkGreen' }
    try { $script:S.Browser = New-CliBrowserInstance (-not $Visible) }
    catch { Write-Fail "Could not restart the browser: $(Get-InnermostMessage $_)"; $script:S.Running = $false; return $false }
    $first = $true
    foreach ($id in @($script:S.Tabs.Keys | Sort-Object)) {
        $tt = $script:S.Tabs[$id]
        try {
            $tt.Page = New-PupPage -Browser $script:S.Browser -ErrorAction Stop
            Initialize-CliPage $tt.Page
            $tt.Snap = $null
            if ($first) { try { $null = Set-CliCookieList $tt.Page $cookies } catch { Write-Log "cookies back: $(Get-InnermostMessage $_)" }; $first = $false }
        } catch { Write-Log "restore tab $($id): $(Get-InnermostMessage $_)" }
    }
    foreach ($id in @($script:S.Tabs.Keys)) {
        if ($id -eq $script:S.Cur) { continue }
        $u = $tabUrls[$id]
        if ($u -and $u -ne 'about:blank') { try { Move-PupPage -Page $script:S.Tabs[$id].Page -Url ([string]$u) -ErrorAction Stop } catch {} }
    }
    $go = $done; if ($cancelled) { $go = $here }
    $ok = Invoke-Navigate ([string]$go) $false
    if ($ok -and -not $cancelled -and (Test-CliChallenge (Get-Tab).Snap)) {
        Write-Warn 'The site is still asking. Its check may be tied to that window; you can try again (v), or read the page there.'
    }
    return $ok
}

$script:Ops['savehtml'] = {
    param($c)
    $r = Invoke-Kernel 'html' $null
    if ($r.err) { Write-Fail $r.msg; return $false }
    $p = $c.Path
    if (-not $p) {
        if (-not (Test-Path $script:Cfg.DlDir)) { $null = New-Item -ItemType Directory -Path $script:Cfg.DlDir -Force }
        $p = Join-Path $script:Cfg.DlDir ("page-{0}.html" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    [IO.File]::WriteAllText($p, "$($r.html)", [Text.Encoding]::UTF8)
    Write-Ok "saved the page's markup to $p"
    Write-Info '(it can contain usernames, addresses and settings from the page - check before sharing)'
    return $true
}

$script:Ops['frames'] = {
    param($c)
    $s = Get-SnapBefore
    if (-not $s) { $s = Update-Snap }
    $fs = @(@($s.frames) | Where-Object { $_ })
    if ($fs.Count -eq 0) { Write-Info '(no frames)'; return $true }
    foreach ($f in $fs) {
        $tag = 'same-site'; if ($f.xo) { $tag = 'other site' }
        if ($f.ad) { $tag += ', ad/tracker' }
        if ([int]$f.w -lt 120 -or [int]$f.h -lt 60) { $tag += ', tiny/hidden' }
        $fu = "$($f.u)"; $cw = (Get-ConsoleWidth) - 6; if ($fu.Length -gt $cw) { $fu = $fu.Substring(0, $cw) + '~' }
        Write-Host ("  {0}  ({1}, {2}x{3})" -f $f.n, $tag, $f.w, $f.h) -ForegroundColor Gray
        Write-Host "     $fu" -ForegroundColor DarkGray
    }
    return $true
}

$script:Ops['text'] = {
    param($c)
    $r = Invoke-Kernel 'text' @{ mode = $c.Mode }
    if ($r.err) { Write-Fail $r.msg; return $false }
    Show-Dialogs $r.dlg
    $lines = @(Format-CliText "$($r.text)" (Get-ConsoleWidth))
    Write-Log ("read: {0}  ({1} lines)  {2}" -f $c.Mode, $lines.Count, "$($r.url)")
    if ($Dump) { $lines | Write-Output; return $true }
    $u = "$($r.url)"; $cw = (Get-ConsoleWidth) - 2; if ($u.Length -gt $cw) { $u = $u.Substring(0, $cw - 1) + '~' }
    $lines = @("=== $($r.title)", "=== $u", '') + $lines
    if (@($lines).Count -eq 0) { Write-Info '(no text)'; return $true }
    Out-CliPager $lines
    return $true
}

$script:Ops['find'] = {
    param($c)
    $r = Invoke-Kernel 'text' @{ mode = 'all' }
    if ($r.err) { Write-Fail $r.msg; return $false }
    $lines = @(Format-CliText "$($r.text)" (Get-ConsoleWidth))
    $rx = $null
    try { $rx = [regex]::new($c.Pattern, 'IgnoreCase') } catch { $rx = [regex]::new([regex]::Escape($c.Pattern), 'IgnoreCase') }
    $hits = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($rx.IsMatch($lines[$i])) {
            Write-Host ("  {0,5}: {1}" -f ($i + 1), $lines[$i]); $hits++
            if ($hits -ge 50) { Write-Info '(first 50 matches)'; break }
        }
    }
    if ($hits -eq 0) { Write-Warn "No matches for '$($c.Pattern)'"; return $false }
    return $true
}

$script:Ops['expect'] = {
    param($c)
    # Poll until the text shows up: the guard that makes macros safe.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rx = $null
    try { $rx = [regex]::new($c.Pattern, 'IgnoreCase') } catch { $rx = [regex]::new([regex]::Escape($c.Pattern), 'IgnoreCase') }
    while ($sw.ElapsedMilliseconds -lt $script:Cfg.TimeoutMs) {
        $r = Invoke-Kernel 'text' @{ mode = 'all' }
        if (-not $r.err -and ($rx.IsMatch("$($r.text)") -or $rx.IsMatch("$($r.title)"))) { Write-Ok "expect '$($c.Pattern)': found"; return $true }
        Start-Sleep -Milliseconds 500
    }
    Write-Fail "expect '$($c.Pattern)': NOT found after $([int]($script:Cfg.TimeoutMs/1000))s"
    return $false
}

$script:Ops['wait'] = { param($c) Start-Sleep -Milliseconds ([int]($c.Sec * 1000)); $null = Wait-Settle; return $true }

$script:Ops['tabs'] = {
    param($c)
    foreach ($id in ($script:S.Tabs.Keys | Sort-Object)) {
        $t = $script:S.Tabs[$id]
        $mark = ' '; if ($id -eq $script:S.Cur) { $mark = '*' }
        $u = ''; if ($t.Snap) { $u = "$($t.Snap.title)  $($t.Snap.url)" } elseif ($t.Visited.Count) { $u = $t.Visited[$t.Visited.Count - 1] }
        Write-Host ("  {0} [{1}] {2}" -f $mark, $id, $u)
    }
    return $true
}

$script:Ops['tab'] = {
    param($c)
    if (-not $script:S.Tabs.ContainsKey($c.Id)) { Write-Fail "No tab $($c.Id)"; return $false }
    $script:S.Cur = $c.Id
    Show-Page
    return $true
}

$script:Ops['new'] = {
    param($c)
    $t = $c.Target
    if ($t -match '^@(.+)$' -or $t -match '^bm:(.+)$') {
        if (-not $script:S.Bookmarks.ContainsKey($matches[1])) { Write-Fail "No bookmark '$($matches[1])'"; return $false }
        $t = $script:S.Bookmarks[$matches[1]]
    }
    $ok = New-CliTab $t
    if (-not $t) { Write-Ok "tab $($script:S.Cur) opened" }
    return $ok
}

$script:Ops['close'] = {
    param($c)
    $tab = Get-Tab
    if (-not $tab) { return $false }
    if ($script:S.Tabs.Count -eq 1) { $null = New-CliTab '' }
    try { Remove-PupPage -Page $tab.Page -ErrorAction Stop } catch { Write-Log "close: $(Get-InnermostMessage $_)" }
    $script:S.Tabs.Remove($tab.Id)
    if (-not $script:S.Tabs.ContainsKey($script:S.Cur)) { $script:S.Cur = @($script:S.Tabs.Keys | Sort-Object)[0] }
    Write-Ok "closed tab $($tab.Id); now on tab $($script:S.Cur)"
    return $true
}

$script:Ops['bm'] = {
    param($c)
    $a = "$($c.Arg)".Trim()
    if (-not $a) {
        if ($script:S.Bookmarks.Count -eq 0) { Write-Info 'No bookmarks. bm add <name> [url]'; return $true }
        foreach ($k in ($script:S.Bookmarks.Keys | Sort-Object)) { Write-Host ("  @{0,-18} {1}" -f $k, $script:S.Bookmarks[$k]) }
        return $true
    }
    $p = $a -split '\s+', 3
    switch ($p[0].ToLowerInvariant()) {
        'add' {
            if ($p.Count -lt 2) { Write-Fail 'usage: bm add <name> [url]'; return $false }
            $u = ''
            if ($p.Count -ge 3) { $u = ConvertTo-CliTarget $p[2] }
            else { $t = Get-Tab; if ($t -and $t.Snap) { $u = "$($t.Snap.url)" } }
            if (-not $u) { Write-Fail 'No URL to bookmark'; return $false }
            $script:S.Bookmarks[$p[1]] = $u
            Save-CliBookmarks
            Write-Ok "@$($p[1]) -> $u"
            return $true
        }
        'del' {
            if ($p.Count -lt 2 -or -not $script:S.Bookmarks.ContainsKey($p[1])) { Write-Fail 'No such bookmark'; return $false }
            $script:S.Bookmarks.Remove($p[1]); Save-CliBookmarks; Write-Ok "removed @$($p[1])"; return $true
        }
        default { return (& $script:Ops['go'] @{ Op = 'go'; Target = "bm:$($p[0])"; Bang = $false }) }
    }
}

$script:Ops['auth'] = {
    param($c)
    $tab = Get-Tab
    if (-not $tab) { return $false }
    if ($c.User -eq 'clear') { Set-PupHttpAuth -Page $tab.Page -Clear; Write-Ok 'HTTP auth cleared'; return $true }
    if (-not $c.User) { Write-Fail 'usage: auth <user> | auth clear'; return $false }
    $pw = Read-Secret "password for $($c.User)"
    $cred = New-Object System.Management.Automation.PSCredential($c.User, (ConvertTo-SecureString $pw -AsPlainText -Force))
    Set-PupHttpAuth -Page $tab.Page -Credential $cred
    Write-Ok "HTTP Basic auth set for $($c.User) (reload to use it)"
    return $true
}

$script:Ops['consent'] = {
    param($c)
    $r = Invoke-Kernel 'consent' $null
    if ($r.ok) { Write-Ok "clicked '$($r.clicked)'"; return (Invoke-AfterAction) }
    Write-Info 'no cookie banner button found'
    return $true
}

$script:Ops['cert'] = {
    param($c)
    $tab = Get-Tab
    try {
        $certs = @(Get-PupCertificate -Page $tab.Page -Unique -ErrorAction Stop)
        if ($certs.Count -eq 0) { Write-Info '(no certificate info captured - reload the page first)'; return $true }
        foreach ($x in $certs) { ($x | Format-List | Out-String).Trim() -split "`n" | ForEach-Object { Write-Host "  $_" } ; Write-Host '' }
    } catch { Write-Fail "cert: $(Get-InnermostMessage $_)"; return $false }
    return $true
}

$script:Ops['shot'] = {
    param($c)
    $tab = Get-Tab
    $p = $c.Path; if (-not $p) { $p = Join-Path $script:Cfg.DlDir ("shot-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    try { Get-PupPageScreenshot -Page $tab.Page -FilePath $p -FullPage -ErrorAction Stop; Write-Ok "saved $p"; return $true }
    catch { Write-Fail "screenshot: $(Get-InnermostMessage $_)"; return $false }
}

$script:Ops['pdf'] = {
    param($c)
    $tab = Get-Tab
    $p = $c.Path; if (-not $p) { $p = Join-Path $script:Cfg.DlDir ("page-{0}.pdf" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    try { Export-PupPdf -Page $tab.Page -FilePath $p -ErrorAction Stop; Write-Ok "saved $p"; return $true }
    catch { Write-Fail "pdf: $(Get-InnermostMessage $_)"; return $false }
}

$script:Ops['dl'] = {
    param($c)
    $tab = Get-Tab
    if ($c.Path) {
        if (-not (Test-Path $c.Path)) { $null = New-Item -ItemType Directory -Path $c.Path -Force }
        $script:Cfg.DlDir = (Resolve-Path $c.Path).Path
        try { Set-PupDownloadPath -Page $tab.Page -Path $script:Cfg.DlDir -ErrorAction Stop } catch { Write-Fail "download path: $(Get-InnermostMessage $_)"; return $false }
    }
    Write-Info "downloads go to $($script:Cfg.DlDir)"
    if (Test-Path $script:Cfg.DlDir) {
        Get-ChildItem $script:Cfg.DlDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 10 |
            ForEach-Object { Write-Host ("    {0:yyyy-MM-dd HH:mm}  {1,10:N0}  {2}" -f $_.LastWriteTime, $_.Length, $_.Name) }
    }
    return $true
}

$script:Ops['run'] = {
    param($c)
    $p = $c.Path
    $cands = @($p, "$p.cli", (Join-Path $script:Cfg.ScriptDir $p), (Join-Path $script:Cfg.ScriptDir "$p.cli"))
    $file = $cands | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $file) { Write-Fail "Script not found: $p (looked in . and $($script:Cfg.ScriptDir))"; return $false }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $file)) {
        $n++
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        Write-Host "  $($file | Split-Path -Leaf):$n> $(Hide-Secrets $t)" -ForegroundColor DarkGray
        if (-not (Invoke-CliLine $t)) { Write-Fail "script stopped at line $n"; return $false }
        if (-not $script:S.Running) { break }
    }
    return $true
}

$script:Ops['debug'] = {
    param($c)
    $m = Get-Module Pup
    Write-Host "  $script:Product $script:Version  (CLI-Browser)"
    Write-Host "  PowerShell    $($PSVersionTable.PSVersion)"
    Write-Host "  Pup           $(if ($m) { $m.Version } else { '(not loaded)' })"
    Write-Host "  Headless      $(-not $Visible)    StrictTls $([bool]$StrictTls)    Proxy $(if ($Proxy) { $Proxy } else { '(none)' })"
    Write-Host "  Preload hook  $($script:S.Preload)   (dialog/network hooks before page scripts)"
    Write-Host "  Timeout       $([int]($script:Cfg.TimeoutMs/1000))s"
    Write-Host "  Watchdog      $(if ($script:Worker) { 'on' } elseif ($script:WorkerOk) { 'starts on first call' } else { 'UNAVAILABLE (direct calls)' })"
    Write-Host "  Log           $($script:Cfg.LogFile)"
    Write-Host "  Tabs          $($script:S.Tabs.Count) (current $($script:S.Cur))"
    Write-Host "  App dir       $script:AppDir"
    $r = Invoke-Kernel 'settle' $null
    if ($r.err) { Write-Host "  Kernel        ERROR $($r.err): $($r.msg)" -ForegroundColor Red }
    else { Write-Host "  Kernel        ok  readyState=$($r.rs) pending=$($r.p) mutations=$($r.m)" }
    $s = Invoke-Kernel 'snap' @{ max = 600 }
    if ($s.err) { Write-Host "  Snapshot      ERROR $($s.err): $($s.msg)" -ForegroundColor Red }
    else { Write-Host "  Snapshot      ok  $(@($s.items).Count) items" }
    Write-Host "  Runtime       $(if ($PSVersionTable.PSEdition -eq 'Core') { '.NET (PowerShell 7)' } else { '.NET Framework (Windows PowerShell 5.1)' })"
    $null = Update-Snap
    return $true
}

$script:Ops['log'] = {
    param($c)
    if (-not (Test-Path $script:Cfg.LogFile)) { Write-Info '(log is empty)'; return $true }
    Get-Content $script:Cfg.LogFile -Tail 30 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    return $true
}

$script:Ops['help'] = {
    param($c)
    Write-Host @'

  ADDRESSING   every link/button/field/list on the page has ONE number (see ls)
               12                activate item 12 (click / toggle / prompt for value)
               "Login"           same, by label  (exact match, else unique substring)
               12!               ... and answer OK to any confirm() it raises
               4=admin           set a field      4=?        prompt without echo
               4=env:FWPASS      value from env   7=on|off   checkbox   9=port3  dropdown
  GO           10.1.1.1:4443  fw.corp.local  https://...   go <x>   @name (bookmark)
               b/back  f/fwd  reload   (append ! to accept a leave-page dialog)
  LOOK         p (page+items)  ls [filter|in|btn|a|sel|chk]  r/read (article)
               text (whole page)  find <re>  opts <n>  frames  cert  savehtml [file]
  FORMS        type <n> <text>  secret <n>  submit [n]  enter  key <Tab|Escape|...>
               upload <n> <file>
  TABS         tabs  tab <n>  new [target]  close
  BOOKMARKS    bm   bm add <name> [url]   bm del <name>   bm <name>
  SCRIPTING    a ; b ; c        (stops at the first failure)
               run <file|name>  (~/.cli-browser/scripts/<name>.cli)
               expect <text>    (wait for text; fails the script if absent)
               wait <sec>
  OUTPUT       shot [file.png]  pdf [file.pdf]  dl [dir]
  MISC         auth <user>|clear (HTTP Basic)  consent (click a cookie banner)
               debug  log  help  quit

'@ -ForegroundColor Gray
    return $true
}

function Hide-Secrets([string]$line) {
    return ($line -replace '(?<=^\s*(\d+|"[^"]+"|''[^'']+'')\s*=\s*)(?!\?$|env:\w+$).+$', '****' -replace '(?<=^\s*(type|set)\s+(\d+|"[^"]+"|''[^'']+'')\s+).+$', '****')
}

function Invoke-CliCommand($c) {
    $h = $script:Ops[$c.Op]
    if (-not $h) { Write-Fail "no handler for '$($c.Op)'"; return $false }
    try {
        $out = @(& $h $c)
        return ($out.Count -gt 0 -and $out[$out.Count - 1] -eq $true)
    } catch {
        $m = Get-InnermostMessage $_
        Write-Fail "Error: $m"
        Write-Log "op $($c.Op) failed: $m`n$($_.ScriptStackTrace)"
        return $false
    }
}

function Invoke-CliLine([string]$line) {
    $script:S.Stuck = $false
    $parts = @(Split-CliLine $line)
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $c = ConvertTo-CliCommand $parts[$i]
        if ($c.Op -ne 'nop') { Write-Log ("cmd: " + (Hide-Secrets $parts[$i])) }
        if (-not (Invoke-CliCommand $c)) {
            if ($i -lt $parts.Count - 1) { Write-Warn "(skipped the rest: $(($parts[($i+1)..($parts.Count-1)] | ForEach-Object { Hide-Secrets $_ }) -join '; '))" }
            return $false
        }
        if (-not $script:S.Running) { return $true }
    }
    return $true
}

# ===========================================================================
# 5b. BROWSE MODE - the default interactive screen (arrow keys + Enter, like Lynx)
#
#     view   = Get-BrowseFrame(ui, snap, rows, height, width)     pure
#     effect = Step-Browse(ui, rows, key)                         pure (moves the cursor)
#     Invoke-BrowseEffect(effect)                                 the only part that acts
# ===========================================================================
$script:UI = @{
    Quiet   = $false
    ShowMenu = $false
    JumpDialog = $false
    DialogClosed = $false
    SavedSel = 0
    SavedTop = 0
    Sel     = 0
    Top     = 0
    Filter  = ''
    Num     = ''
    Msgs    = (New-Object System.Collections.Generic.List[string])
    NewKeys = @{}
    ListH   = 20
}

$script:BrowseHint = ' Up/Down move  Enter open  m menu  r read  b back  g go to  / find  : cmd  ? help  q quit '

function Add-UiMsg([string]$m) {
    $script:UI.Msgs.Add($m.Trim())
    while ($script:UI.Msgs.Count -gt 3) { $script:UI.Msgs.RemoveAt(0) }
}

function Get-BrowseRows($snap, [string]$filter) {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $snap) { return @() }
    if ($snap.modal -and -not $filter) {
        $title = "$($snap.modal.t)"; if (-not $title) { $title = 'The page is asking' }
        $rows.Add([pscustomobject]@{ i = 0; k = 'note'; l = "DIALOG: $title"; v = '' })
        if ("$($snap.modal.m)") { foreach ($ln in @(Split-CliWords "$($snap.modal.m)" 90)) { $rows.Add([pscustomobject]@{ i = 0; k = 'note'; l = "  $ln"; v = '' }) } }
    }
    if ($snap.media -and -not $filter -and -not $snap.modal) {
        $mk = "$($snap.media.k)".ToUpperInvariant()
        $msg = "$mk page: the main content is a $("$($snap.media.k)") player - there may be little or no text."
        if ($snap.art) { $msg = "$mk page with an article: the $("$($snap.media.k)") will not play here, but r reads the text." }
        $rows.Add([pscustomobject]@{ i = 0; k = 'note'; l = $msg; v = '' })
    }
    if ($snap.art -and -not $filter) {
        $rows.Add([pscustomobject]@{ i = 0; k = 'read'; l = ("Read the article  (about {0:N0} words)" -f [int]$snap.art.w); v = '' })
    }
    $all = @($snap.items)
    $navItems = @($all | Where-Object { $_.nav })
    if ($navItems.Count -and -not $filter) {
        $state = 'Enter or m to open'; if ($script:UI.ShowMenu) { $state = 'Enter or m to close' }
        $rows.Add([pscustomobject]@{ i = 0; k = 'menu'; l = ("Menu ({0} links)   {1}" -f $navItems.Count, $state); v = '' })
        if ($script:UI.ShowMenu) { foreach ($m in $navItems) { $rows.Add($m) } }
    }
    for ($x = 0; $x -lt $all.Count; $x++) {
        if (Test-CliSecondary $all $x) { continue }
        if ($all[$x].nav -and -not $filter) { continue }
        $rows.Add($all[$x])
    }
    if ((Test-CliChallenge $snap) -and -not $filter) {
        $rows.Add([pscustomobject]@{ i = 0; k = 'human'; l = 'Or answer this check in a normal browser window  (Enter here, or v)'; v = '' })
    }
    $out = $rows.ToArray()
    if ($filter) { $out = @(Select-CliItems $out $filter) }
    return $out
}

function Format-BrowseRow($it) {
    $l = "$($it.l)"
    $v = "$($it.v)"
    if ($it.m) { $l = "[$("$($it.m)".ToUpperInvariant())] $l" }
    $t = $l
    switch ("$($it.k)") {
        'read'  { $t = ">> $l" }
        'human' { $t = ">> $l" }
        'btn'  { $t = "[ $l ]" }
        'in'   { if (-not $v) { $v = '______________' }; $t = "$($l): $v" }
        'pw'   { if (-not $v) { $v = '______________' }; $t = "$($l): $v" }
        'sel'  { $t = "$($l): < $v >" }
        'chk'  { $m = ' '; if ($v -eq 'on') { $m = 'x' }; $t = "[$m] $l" }
        'rad'  { $m = ' '; if ($v -eq 'on') { $m = '*' }; $t = "($m) $l" }
        'file' { if (-not $v) { $v = 'choose a file' }; $t = "$($l): [$v]" }
        'row'  { $m = '  '; if ($v -eq 'on') { $m = '> ' }; $t = "$m$l" }
        'hdr'  { $t = "  $l" }
        'note' { $t = $l }
        'menu' { $m = '+'; if ($script:UI.ShowMenu) { $m = '-' }; $t = "[$m] $l" }
    }
    if ($it.d) { $t += '  (disabled)' }
    return $t
}

function Get-BrowseRowColor($it) {
    if ($it.d) { return 'DarkGray' }
    switch ("$($it.k)") {
        'read' { return 'Green' }
        'human' { return 'Magenta' }
        'a'    { return 'White' }
        'btn'  { return 'Yellow' }
        'row'  { if ("$($it.v)" -eq 'on') { return 'Green' }; return 'Gray' }
        'hdr'  { return 'DarkCyan' }
        'note' { return 'Magenta' }
        'menu' { return 'Green' }
    }
    return 'Cyan'
}

function Get-BrowseFrame($ui, $snap, $rows, [int]$h, [int]$w) {
    $lines = New-Object System.Collections.Generic.List[object]
    $fit = { param($s) $s = "$s"; if ($s.Length -gt $w) { $s = $s.Substring(0, [Math]::Max(1, $w - 1)) + '~' }; $s.PadRight($w) }
    $title = '(blank page - press g to go somewhere)'
    $url = ''
    if ($snap) { $title = "$($snap.title)"; if (-not $title) { $title = '(no title)' }; $url = "$($snap.url)" }
    $lines.Add(@{ T = (& $fit " $title"); F = 'Cyan'; B = '' })
    $lines.Add(@{ T = (& $fit " $url"); F = 'DarkGray'; B = '' })
    $sep = '-' * $w
    if ($ui.Filter) { $sep = " showing items matching '$($ui.Filter)' - $(@($rows).Count) found  (Esc shows all) " }
    $lines.Add(@{ T = (& $fit $sep); F = 'DarkCyan'; B = '' })

    $msgs = @($ui.Msgs)
    $listH = [Math]::Max(3, $h - 3 - $msgs.Count - 1)
    $ui.ListH = $listH
    $rows = @($rows)
    if ($rows.Count -eq 0) {
        $empty = ' (nothing to select here - press t to read the page text, g to go somewhere)'
        if ($ui.Filter) { $empty = ' (nothing matches - press Esc to show everything)' }
        $lines.Add(@{ T = (& $fit $empty); F = 'DarkGray'; B = '' })
        for ($z = 1; $z -lt $listH; $z++) { $lines.Add(@{ T = (' ' * $w); F = 'Gray'; B = '' }) }
    } else {
        for ($r = 0; $r -lt $listH; $r++) {
            $ix = $ui.Top + $r
            if ($ix -ge $rows.Count) { $lines.Add(@{ T = (' ' * $w); F = 'Gray'; B = '' }); continue }
            $it = $rows[$ix]
            $mark = ' '
            if ($ui.NewKeys.ContainsKey((Get-CliItemKey $it))) { $mark = '+' }
            $num = '    '
            if ([int]$it.i -gt 0) { $num = '{0,4}' -f $it.i }
            $text = & $fit (" $mark$num  " + (Format-BrowseRow $it))
            if ($ix -eq $ui.Sel) { $lines.Add(@{ T = $text; F = 'Black'; B = 'Cyan' }) }
            else { $lines.Add(@{ T = $text; F = (Get-BrowseRowColor $it); B = '' }) }
        }
    }
    foreach ($m in $msgs) { $lines.Add(@{ T = (& $fit " $m"); F = 'Yellow'; B = '' }) }
    $status = $script:BrowseHint
    if ($rows.Count -and $ui.Sel -lt $rows.Count) {
        $cur = $rows[$ui.Sel]
        $what = switch ("$($cur.k)") {
            'row'  { if ("$($cur.v)" -eq 'on') { 'open this row (like a double-click)' } else { 'select this row (its Edit / Remove buttons turn on)' } }
            'hdr'  { 'nothing (column headings)' }
            'in'   { 'type a value' }   'pw' { 'type a passphrase' }   'sel' { 'choose from a list' }
            'chk'  { 'tick / untick' }  'rad' { 'choose this option' }
            'a'    { 'follow this link' }
            'btn'  { if ($cur.d) { 'nothing yet (disabled)' } else { 'press this button' } }
            'read' { 'read the article' }  'menu' { 'open / close the site menu' }
            'note' { 'nothing (message)' } 'human' { 'answer the check in a browser window' }
            default { '' }
        }
        if ($what) { $status = " Enter: $what   |  b back  / find  m menu  ? help  q quit " }
    }
    if ($ui.Num) { $status = " Open item number: $($ui.Num)_   (Enter opens it, Esc cancels) " }
    $pos = ''
    if ($rows.Count) { $pos = " $([Math]::Min($ui.Sel + 1, $rows.Count))/$($rows.Count) " }
    if (($status.Length + $pos.Length) -le $w) { $status = $status.PadRight($w - $pos.Length) + $pos }
    $lines.Add(@{ T = (& $fit $status); F = 'White'; B = 'DarkBlue' })
    return $lines.ToArray()
}

function Set-BrowseSel($ui, [int]$sel, [int]$count) {
    if ($count -le 0) { $ui.Sel = 0; $ui.Top = 0; return }
    $ui.Sel = [Math]::Max(0, [Math]::Min($count - 1, $sel))
    if ($ui.Sel -lt $ui.Top) { $ui.Top = $ui.Sel }
    if ($ui.Sel -ge $ui.Top + $ui.ListH) { $ui.Top = $ui.Sel - $ui.ListH + 1 }
    if ($ui.Top -lt 0) { $ui.Top = 0 }
}

function Step-Browse($ui, $rows, [ConsoleKeyInfo]$k) {
    # Cursor movement is handled here; anything that touches the page comes back as an effect.
    $rows = @($rows)
    $n = $rows.Count
    $ch = $k.KeyChar
    if ([char]::IsDigit($ch)) { $ui.Num += $ch; return $null }
    switch ($k.Key) {
        'UpArrow'   { Set-BrowseSel $ui ($ui.Sel - 1) $n; return $null }
        'DownArrow' { Set-BrowseSel $ui ($ui.Sel + 1) $n; return $null }
        'Tab'       { if ($k.Modifiers -band [ConsoleModifiers]::Shift) { Set-BrowseSel $ui ($ui.Sel - 1) $n } else { Set-BrowseSel $ui ($ui.Sel + 1) $n }; return $null }
        'PageUp'    { Set-BrowseSel $ui ($ui.Sel - [Math]::Max(1, $ui.ListH - 1)) $n; return $null }
        'PageDown'  { Set-BrowseSel $ui ($ui.Sel + [Math]::Max(1, $ui.ListH - 1)) $n; return $null }
        'Home'      { Set-BrowseSel $ui 0 $n; return $null }
        'End'       { Set-BrowseSel $ui ($n - 1) $n; return $null }
        'Enter'     {
            if ($ui.Num) { $num = [int]$ui.Num; $ui.Num = ''; return @{ Do = 'num'; N = $num; Bang = $false } }
            if ($n -gt 0) { return @{ Do = 'open'; Row = $rows[$ui.Sel]; Bang = $false } }
            return $null
        }
        'Backspace' {
            if ($ui.Num) { $ui.Num = $ui.Num.Substring(0, $ui.Num.Length - 1); return $null }
            return @{ Do = 'back' }
        }
        'Escape'    {
            if ($ui.Num) { $ui.Num = ''; return $null }
            if ($ui.Filter) { $ui.Filter = ''; $ui.Sel = 0; $ui.Top = 0; return $null }
            return @{ Do = 'esc' }
        }
        'F5'        { return @{ Do = 'reload' } }
        'LeftArrow' { return @{ Do = 'back' } }
        'RightArrow'{ if ($n -gt 0) { return @{ Do = 'open'; Row = $rows[$ui.Sel]; Bang = $false } }; return $null }
    }
    switch -CaseSensitive ("$ch") {
        'j' { Set-BrowseSel $ui ($ui.Sel + 1) $n; return $null }
        'k' { Set-BrowseSel $ui ($ui.Sel - 1) $n; return $null }
        ' ' { Set-BrowseSel $ui ($ui.Sel + [Math]::Max(1, $ui.ListH - 1)) $n; return $null }
        '!' {
            if ($ui.Num) { $num = [int]$ui.Num; $ui.Num = ''; return @{ Do = 'num'; N = $num; Bang = $true } }
            if ($n -gt 0) { return @{ Do = 'open'; Row = $rows[$ui.Sel]; Bang = $true } }
            return $null
        }
        'r' { return @{ Do = 'read' } }
        't' { return @{ Do = 'text' } }
        'b' { return @{ Do = 'back' } }
        'f' { return @{ Do = 'fwd' } }
        'g' { return @{ Do = 'go' } }
        'o' { return @{ Do = 'go' } }
        'v' { return @{ Do = 'human' } }
        'L' { return @{ Do = 'log' } }
        'm' { return @{ Do = 'menu' } }
        '/' { return @{ Do = 'filter' } }
        ':' { return @{ Do = 'cmd' } }
        '?' { return @{ Do = 'help' } }
        'h' { return @{ Do = 'help' } }
        'q' { return @{ Do = 'quit' } }
        'Q' { return @{ Do = 'quit' } }
    }
    return $null
}

# --- painting and input (console only) ----------------------------------------------
function Get-ConsoleSize {
    $h = 30; $w = 100
    try { $h = [Console]::WindowHeight; $w = [Console]::WindowWidth } catch {}
    if ($h -lt 10) { $h = 30 }
    if ($w -lt 40) { $w = 100 }
    return @{ H = $h; W = $w - 1 }
}

function Show-BrowseFrame($frame) {
    try { [Console]::SetCursorPosition(0, 0) } catch { try { Clear-Host } catch {} }
    $last = @($frame).Count - 1
    for ($i = 0; $i -le $last; $i++) {
        $ln = $frame[$i]
        $p = @{ Object = $ln.T; ForegroundColor = $ln.F; NoNewline = ($i -eq $last) }
        if ($ln.B) { $p.BackgroundColor = $ln.B }
        Write-Host @p
    }
}

function Show-BrowseStatus([string]$text, [string]$bg = 'DarkBlue') {
    $sz = Get-ConsoleSize
    try {
        [Console]::SetCursorPosition(0, $sz.H - 1)
        $t = " $text"; if ($t.Length -gt $sz.W) { $t = $t.Substring(0, $sz.W) }
        Write-Host ($t.PadRight($sz.W)) -NoNewline -ForegroundColor White -BackgroundColor $bg
    } catch {}
}

function Read-CliLine([string]$prompt, [switch]$Secret) {
    # One-line editor on the bottom row. Enter accepts, Esc cancels (returns $null).
    $sz = Get-ConsoleSize
    $buf = New-Object System.Text.StringBuilder
    try { [Console]::CursorVisible = $true } catch {}
    try {
        while ($true) {
            $shown = $buf.ToString(); if ($Secret) { $shown = '*' * $buf.Length }
            $line = " $prompt$shown"
            if ($line.Length -ge $sz.W) { $line = $line.Substring($line.Length - $sz.W + 1) }
            [Console]::SetCursorPosition(0, $sz.H - 1)
            Write-Host ($line.PadRight($sz.W)) -NoNewline -ForegroundColor White -BackgroundColor DarkMagenta
            [Console]::SetCursorPosition([Math]::Min($line.Length, $sz.W - 1), $sz.H - 1)
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') { return $buf.ToString() }
            if ($k.Key -eq 'Escape') { return $null }
            if ($k.Key -eq 'Backspace') { if ($buf.Length) { [void]$buf.Remove($buf.Length - 1, 1) }; continue }
            if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { [void]$buf.Append($k.KeyChar) }
        }
    } finally { try { [Console]::CursorVisible = $false } catch {} }
}

function Select-CliChoice([string]$title, $opts, [string]$current) {
    # Full-screen arrow-key picker. Returns the chosen index, or $null on Esc.
    $opts = @($opts)
    if ($opts.Count -eq 0) { return $null }
    $sel = [Math]::Max(0, [Array]::IndexOf($opts, $current))
    $top = 0
    try { Clear-Host } catch {}
    while ($true) {
        $sz = Get-ConsoleSize
        $listH = $sz.H - 3
        if ($sel -lt $top) { $top = $sel }
        if ($sel -ge $top + $listH) { $top = $sel - $listH + 1 }
        [Console]::SetCursorPosition(0, 0)
        Write-Host ((" Choose: $title").PadRight($sz.W).Substring(0, $sz.W)) -ForegroundColor Cyan
        Write-Host ('-' * $sz.W) -ForegroundColor DarkCyan
        for ($r = 0; $r -lt $listH; $r++) {
            $ix = $top + $r
            $t = ''
            if ($ix -lt $opts.Count) { $t = "   $($opts[$ix])"; if ("$($opts[$ix])" -eq $current) { $t = " > $($opts[$ix])" } }
            if ($t.Length -gt $sz.W) { $t = $t.Substring(0, $sz.W) }
            if ($ix -eq $sel) { Write-Host ($t.PadRight($sz.W)) -ForegroundColor Black -BackgroundColor Cyan }
            else { Write-Host ($t.PadRight($sz.W)) -ForegroundColor Gray }
        }
        Write-Host ((' Up/Down move   Enter choose   Esc cancel').PadRight($sz.W)) -NoNewline -ForegroundColor White -BackgroundColor DarkBlue
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'UpArrow'   { $sel = [Math]::Max(0, $sel - 1) }
            'DownArrow' { $sel = [Math]::Min($opts.Count - 1, $sel + 1) }
            'PageUp'    { $sel = [Math]::Max(0, $sel - $listH) }
            'PageDown'  { $sel = [Math]::Min($opts.Count - 1, $sel + $listH) }
            'Home'      { $sel = 0 }
            'End'       { $sel = $opts.Count - 1 }
            'Enter'     { return $sel }
            'Escape'    { return $null }
        }
    }
}

function Show-BrowseHelp {
    try { Clear-Host } catch {}
    Write-Host @'

  MOVING AROUND
    Up / Down (or j / k)    move the highlight
    Enter  (or Right)       open the highlighted line: follow a link, press a button,
                            type into a box, pick from a list, tick a checkbox
    a number, then Enter    open that item directly (numbers are shown on the left)
    Space / PgDn / PgUp     page through the list

  PAGES
    r        read the article (or the page) as text; Enter or Space pages, b goes back
    t        the whole page as text
    b        back  (also Backspace or Left)          f   forward
    g        go to an address: news.google.com, 10.1.1.1:4443, @bookmark
    /        show only lines containing a word       Esc  show everything again
    m        open / close the site's menu (it is folded into one line at the top,
             so the page itself comes first; / searches the menu too)
    F5       reload

  WHEN A PAGE ASKS "ARE YOU SURE?"
    Browser pop-ups: the browser answers Cancel and shows you the question at the
    bottom. To answer OK, highlight the same button and press !  instead of Enter.
    Dialogs drawn by the page itself (like a firewall's "Remove user?" box) take
    over the list while open: the question is shown at the top, then its buttons.
    Esc closes most of them.

  TABLES (users, policies, interfaces...)
    Enter on a row selects it (it gets a >). Enter again on a selected row opens it,
    like a double-click. Buttons such as Edit or Action turn on once a row is selected.

  LINES MARKED +
    After a click that keeps you on the same page, new things that appeared
    (a menu, a panel, an edit form) are marked + and the highlight jumps to them.

  "I'M NOT A ROBOT" AND OTHER HUMAN CHECKS
    Highlight the box and press Enter to tick it yourself. If the site then wants
    pictures picked, press v: a normal browser window opens on that page, you answer
    it there, come back, press Enter, and the session continues here as you.

  L        show the log (every call into Chrome, how long it took, and anything that stalled)

  :        type a command (for scripts and firewall work: "Username"=admin, run login ...)
  q        quit

  Press any key to go back.
'@ -ForegroundColor Gray
    try { $null = [Console]::ReadKey($true) } catch {}
}

function Switch-BrowseMenu {
    # open: highlight the first menu link; close: highlight the menu line
    $script:UI.ShowMenu = -not $script:UI.ShowMenu
    $tab = Get-Tab
    $rows = @(Get-BrowseRows $tab.Snap $script:UI.Filter)
    for ($x = 0; $x -lt $rows.Count; $x++) {
        if ($rows[$x].k -eq 'menu') {
            $to = $x; if ($script:UI.ShowMenu -and $x + 1 -lt $rows.Count) { $to = $x + 1 }
            Set-BrowseSel $script:UI $to $rows.Count
            if (-not $script:UI.ShowMenu) { $script:UI.Top = [Math]::Min($script:UI.Top, $x) }
            return
        }
    }
}

function Get-BrowseFirstContent($rows) {
    # where the highlight starts on a new page: the first line that is not the folded menu
    # never start on the folded menu or on a log-out / sign-out button (one stray Enter ends the session)
    $rows = @($rows)
    for ($x = 0; $x -lt $rows.Count; $x++) {
        if ($rows[$x].k -eq 'menu' -or $rows[$x].k -eq 'note') { continue }
        if ("$($rows[$x].l)" -match '^(?i)\s*(log ?out|log ?off|sign ?out|disconnect)\b') { continue }
        return $x
    }
    return 0
}

function Invoke-BrowseEffect($e) {
    $tab = Get-Tab
    $before = $null; if ($tab) { $before = $tab.Snap }
    $script:UI.NewKeys = @{}
    $script:S.Stuck = $false
    $script:UI.JumpDialog = $false
    $script:UI.DialogClosed = $false
    if ($e.Do -eq 'num' -and $before) {
        # a typed number moves the highlight to that line, as if you had arrowed to it
        $rb = @(Get-BrowseRows $before $script:UI.Filter)
        for ($x = 0; $x -lt $rb.Count; $x++) { if ([int]$rb[$x].i -eq [int]$e.N) { Set-BrowseSel $script:UI $x $rb.Count; break } }
    }
    $selBefore = $script:UI.Sel; $topBefore = $script:UI.Top
    switch ($e.Do) {
        'open' {
            $row = $e.Row
            if ($row.k -eq 'read') { $null = & $script:Ops['text'] @{ Op = 'text'; Mode = 'article' }; return }
            if ($row.k -eq 'note') { return }
            if ($row.k -eq 'menu') { Switch-BrowseMenu; return }
            if ($row.k -eq 'human') { $null = Invoke-CliCommand @{ Op = 'human' } }
            else {
            $null = Invoke-CliCommand @{ Op = 'act'; Ref = @{ N = [int]$row.i }; Bang = [bool]$e.Bang }
            }
        }
        'num'    { $null = Invoke-CliCommand @{ Op = 'act'; Ref = @{ N = [int]$e.N }; Bang = [bool]$e.Bang } }
        'read'   { $null = & $script:Ops['text'] @{ Op = 'text'; Mode = 'article' }; return }
        'text'   { $null = & $script:Ops['text'] @{ Op = 'text'; Mode = 'all' }; return }
        'back'   { $null = Invoke-CliCommand @{ Op = 'hist'; Dir = 'back' } }
        'fwd'    { $null = Invoke-CliCommand @{ Op = 'hist'; Dir = 'fwd' } }
        'reload' { $null = Invoke-CliCommand @{ Op = 'hist'; Dir = 'reload' } }
        'esc'    {
            # A page-drawn dialog may not hear Esc; press its own dismiss button instead (never Yes/OK).
            $dismiss = $null
            if ($before -and $before.modal) {
                foreach ($name in @('Close', 'Cancel', 'No')) {
                    $dismiss = @(@($before.items) | Where-Object { "$($_.l)" -eq $name -and -not $_.d })[0]
                    if ($dismiss) { break }
                }
            }
            if ($dismiss) { $null = Invoke-CliCommand @{ Op = 'act'; Ref = @{ N = [int]$dismiss.i }; Bang = $false } }
            else { $null = Invoke-CliCommand @{ Op = 'key'; Key = 'Escape'; Bang = $false } }
        }
        'go' {
            $u = Read-CliLine 'Go to (address or @bookmark): '
            if (-not $u) { return }
            $null = Invoke-CliLine $u.Trim()
        }
        'filter' {
            $f = Read-CliLine 'Show lines containing: '
            if ($null -ne $f) { $script:UI.Filter = $f.Trim(); $script:UI.Sel = 0; $script:UI.Top = 0 }
            return
        }
        'cmd' {
            $c = Read-CliLine ': '
            if (-not $c) { return }
            try { Clear-Host } catch {}
            $script:UI.Quiet = $false
            try { [Console]::CursorVisible = $true } catch {}
            $null = Invoke-CliLine $c
            Write-Host "`n  (press any key to return to the page)" -ForegroundColor DarkGray
            try { $null = [Console]::ReadKey($true) } catch {}
            $script:UI.Quiet = $true
            try { [Console]::CursorVisible = $false; Clear-Host } catch {}
            $null = Update-Snap
        }
        'help' { Show-BrowseHelp; try { Clear-Host } catch {}; return }
        'menu' { Switch-BrowseMenu; return }
        'human' { $null = Invoke-CliCommand @{ Op = 'human' } }
        'log' {
            $lines = @()
            if (Test-Path $script:Cfg.LogFile) { $lines = @(Get-Content $script:Cfg.LogFile -Tail 300) }
            if (-not $lines.Count) { $lines = @('(the log is empty)') }
            $lines = @("Log: $($script:Cfg.LogFile)   (newest at the bottom)", '') + $lines
            Out-CliPager $lines
            try { Clear-Host } catch {}
            return
        }
        'quit' { $script:S.Running = $false; return }
    }
    # Where should the highlight go?
    $tab = Get-Tab
    $after = $null; if ($tab) { $after = $tab.Snap }
    if ($tab -and $after -and $before -and "$($after.gen)" -eq "$($before.gen)") {
        # the action did not re-read the page (typing into a box, ticking a checkbox): do it now
        $null = Update-Snap; $after = $tab.Snap
        $row = $null
        if ($e.Do -eq 'open') { $row = $e.Row } elseif ($e.Do -eq 'num') { $row = @(@($after.items) | Where-Object { [int]$_.i -eq [int]$e.N })[0] }
        if ($row -and @('in', 'pw', 'sel') -contains "$($row.k)" -and "$($after.url)" -eq "$($before.url)") {
            # filled a field: move to the next line, like Tab in a form
            $rows = @(Get-BrowseRows $after $script:UI.Filter)
            for ($x = 0; $x -lt $rows.Count; $x++) { if ([int]$rows[$x].i -eq [int]$row.i) { Set-BrowseSel $script:UI ($x + 1) $rows.Count; break } }
            return
        }
    }
    if ($after -and (-not $before -or "$($after.url)" -ne "$($before.url)")) {
        $script:UI.Top = 0; $script:UI.Filter = ''; $script:UI.ShowMenu = $false
        $script:UI.Sel = Get-BrowseFirstContent @(Get-BrowseRows $after '')
        if ($after.media) { Add-UiMsg ("This is a {0} page. It will not play here; any text is listed below{1}." -f "$($after.media.k)", $(if ($after.art) { ' (r reads the article)' } else { '' })) }
    } elseif ($script:UI.DialogClosed) {
        # back to where you were before the dialog opened
        $script:UI.Top = $script:UI.SavedTop
        Set-BrowseSel $script:UI $script:UI.SavedSel @(Get-BrowseRows $after $script:UI.Filter).Count
    } elseif ($script:UI.JumpDialog) {
        $script:UI.SavedSel = $selBefore; $script:UI.SavedTop = $topBefore
        $script:UI.Top = 0     # keep the dialog's title line in view
        $script:UI.Filter = '' # a filter from the page behind would hide the dialog
        # first box to type in, else the first button (Close / No on a yes-no question)
        $rows = @(Get-BrowseRows $after $script:UI.Filter)
        $pick = -1
        for ($x = 0; $x -lt $rows.Count; $x++) { if (@('in', 'pw', 'sel') -contains "$($rows[$x].k)") { $pick = $x; break } }
        if ($pick -lt 0) { for ($x = 0; $x -lt $rows.Count; $x++) { if ("$($rows[$x].k)" -ne 'note') { $pick = $x; break } } }
        if ($pick -ge 0) { Set-BrowseSel $script:UI $pick $rows.Count }
    } elseif ($script:UI.NewKeys.Count -gt 0) {
        $rows = @(Get-BrowseRows $after $script:UI.Filter)
        for ($x = 0; $x -lt @($rows).Count; $x++) {
            if ($script:UI.NewKeys.ContainsKey((Get-CliItemKey $rows[$x]))) { Set-BrowseSel $script:UI $x @($rows).Count; break }
        }
    }
}

function Start-Browse {
    $script:UI.Quiet = $true
    $t0 = Get-Tab
    if ($t0 -and $t0.Snap) { $script:UI.Sel = Get-BrowseFirstContent @(Get-BrowseRows $t0.Snap '') }
    try { [Console]::CursorVisible = $false } catch {}
    try { Clear-Host } catch {}
    $lastSize = ''
    try {
        while ($script:S.Running) {
            $tab = Get-Tab
            $snap = $null; if ($tab) { $snap = $tab.Snap }
            $rows = @(Get-BrowseRows $snap $script:UI.Filter)
            Set-BrowseSel $script:UI $script:UI.Sel @($rows).Count
            $sz = Get-ConsoleSize
            if ("$($sz.H)x$($sz.W)" -ne $lastSize) { try { Clear-Host } catch {}; $lastSize = "$($sz.H)x$($sz.W)" }
            Show-BrowseFrame @(Get-BrowseFrame $script:UI $snap $rows $sz.H $sz.W)
            $k = [Console]::ReadKey($true)
            $e = Step-Browse $script:UI $rows $k
            if (-not $e) { continue }
            if (@('open', 'num', 'back', 'fwd', 'reload', 'esc') -contains $e.Do) { Show-BrowseStatus 'Working...' 'DarkGreen' }
            $script:UI.Msgs.Clear()
            Invoke-BrowseEffect $e
            if (@('read', 'text', 'help', 'go', 'open', 'num', 'human', 'log') -contains $e.Do) { try { Clear-Host } catch {} }
        }
    } finally {
        $script:UI.Quiet = $false
        try { [Console]::CursorVisible = $true } catch {}
        try { Clear-Host } catch {}
    }
}

# ===========================================================================
# 6. Bookmarks
# ===========================================================================
function Import-CliBookmarks {
    $script:S.Bookmarks = @{}
    if (-not (Test-Path $script:Cfg.BmFile)) { return }
    try {
        $raw = Get-Content $script:Cfg.BmFile -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $script:S.Bookmarks[$p.Name] = "$($p.Value)" }
    } catch { Write-Log "bookmarks unreadable: $(Get-InnermostMessage $_)" }
}
function Save-CliBookmarks {
    try {
        if (-not (Test-Path $script:AppDir)) { $null = New-Item -ItemType Directory -Path $script:AppDir -Force }
        $o = [ordered]@{}; foreach ($k in ($script:S.Bookmarks.Keys | Sort-Object)) { $o[$k] = $script:S.Bookmarks[$k] }
        ConvertTo-Json -InputObject $o | Set-Content -Path $script:Cfg.BmFile -Encoding UTF8
    } catch { Write-Fail "could not save bookmarks: $(Get-InnermostMessage $_)" }
}

# ===========================================================================
# 7. Startup
# ===========================================================================
$script:RequiredCmdlets = @(
    'Start-PupBrowser', 'Stop-PupBrowser', 'New-PupPage', 'Remove-PupPage', 'Move-PupPage',
    'Invoke-PupScript', 'Invoke-PupCdpMessage', 'Invoke-PupPageBack', 'Invoke-PupPageForward',
    'Invoke-PupPageReload', 'Send-PupKey', 'Set-PupPageHandler', 'Remove-PupPageHandler'
)

function Initialize-Pup {
    if (-not (Get-Command Invoke-PupScript -ErrorAction SilentlyContinue)) {
        if (-not (Get-Module -ListAvailable -Name Pup)) {
            Write-Warn 'Installing the Pup module for the current user (one time)...'
            try {
                if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
                    $null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
                }
            } catch {}
            Install-Module -Name Pup -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module Pup -ErrorAction Stop
    }
    $m = Get-Module Pup
    if ($m -and $m.Version -lt $script:MinPup) {
        Write-Fail "Pup $($m.Version) is too old (need $script:MinPup+). Run:  Update-Module Pup   then restart PowerShell."
        return $false
    }
    $missing = @($script:RequiredCmdlets | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count) {
        Write-Fail "Pup is missing: $($missing -join ', '). Run:  Update-Module Pup"
        return $false
    }
    return $true
}

function New-CliBrowserInstance([bool]$headless) {
    $a = @()
    if (-not $StrictTls) { $a += '--ignore-certificate-errors' }
    $p = @{ Headless = $headless; ErrorAction = 'Stop' }
    if ($a.Count) { $p.Arguments = $a }
    if ($Proxy) { $p.Proxy = $Proxy }
    if ($UserAgent) { $p.UserAgent = $UserAgent }
    try { return (Start-PupBrowser @p) }
    catch {
        Write-Warn "Chromium did not start ($(Get-InnermostMessage $_)); downloading it..."
        Install-PupBrowser -ErrorAction Stop
        return (Start-PupBrowser @p)
    }
}

function Start-CliBrowser { $script:S.Browser = New-CliBrowserInstance (-not $Visible) }

function Set-CliWindowTitle { try { $Host.UI.RawUI.WindowTitle = "$script:Product $script:Version" } catch {} }

function Show-Banner {
    Set-CliWindowTitle
    $art = @'
  _____ _       _  ___
 / ____| |     | |/ (_)
| (___ | |_   _| ' / _ ___ ___     _  _    _____ __  __     _        _
 \___ \| | | | |  < | / __/ __|   | || |__|_   _|  \/  |___| |_ __ _| |
 ____) | | |_| | . \| \__ \__ \   | __ / _ \| | | |\/| / -_)  _/ _` | |__
|_____/|_|\__, |_|\_\_|___/___/   |_||_\___/|_| |_|  |_\___|\__\__,_|____|
           __/ |
          |___/
'@
    Write-Host ''
    foreach ($ln in ($art -split "`r?`n")) { Write-Host "  $ln" -ForegroundColor Cyan }
    Write-Host ("  " + ('=' * 74)) -ForegroundColor DarkCyan
    Write-Host ("  {0,-66}{1,8}" -f 'Text-mode Chromium for firewalls and the web   (CLI-Browser)', "v$script:Version") -ForegroundColor White
    Write-Host '  (C) 2026 Jim Ames  N2NHU Labs  Newburgh NY USA  jimpames@gmail.com' -ForegroundColor Gray
    Write-Host '  Designed and coded by Jim Ames, Claude, Grok and DeepSeek' -ForegroundColor Gray
    Write-Host ("  " + ('=' * 74)) -ForegroundColor DarkCyan
    if (-not $StrictTls) { Write-Host '  TLS certificates are NOT verified (firewall mode). Use -StrictTls for public sites.' -ForegroundColor DarkGray }
}

# ===========================================================================
# 8. Tests
# ===========================================================================
function Test-CliOffline {
    $res = New-Object System.Collections.Generic.List[object]
    function Add-T([string]$n, [bool]$ok, [string]$d = '') { $res.Add([pscustomobject]@{ Name = $n; Pass = $ok; Detail = $d }) }

    $cases = [ordered]@{
        '192.168.1.99'           = 'https://192.168.1.99'
        '10.0.0.1:4443'          = 'https://10.0.0.1:4443'
        '10.0.0.1:8080'          = 'http://10.0.0.1:8080'
        'fw01.corp.local:8443/ng' = 'https://fw01.corp.local:8443/ng'
        'fw01'                   = 'https://fw01'
        'localhost:3000'         = 'https://localhost:3000'
        'localhost'              = 'http://localhost'
        '[fe80::1]:443'          = 'https://[fe80::1]:443'
        'http://10.1.1.1'        = 'http://10.1.1.1'
        'about:blank'            = 'about:blank'
        'not a url'              = $null
    }
    foreach ($k in $cases.Keys) {
        $got = ConvertTo-CliTarget $k
        Add-T "target '$k'" ($got -eq $cases[$k]) "got '$got'"
    }
    Add-T 'bare ip:port is a target'   (Test-IsTargetLike '10.0.0.1:4443')
    Add-T 'bare host.domain is target' (Test-IsTargetLike 'fw.corp.local')
    Add-T 'bare number is not target'  (-not (Test-IsTargetLike '12'))
    Add-T 'command is not target'      (-not (Test-IsTargetLike 'ls'))

    $sp = @(Split-CliLine '4=admin; 5="a;b" ; 6')
    Add-T 'split respects quotes' ($sp.Count -eq 3 -and $sp[1] -eq '5="a;b"') ($sp -join ' | ')

    $p = ConvertTo-CliCommand '12'
    Add-T 'parse 12'        ($p.Op -eq 'act' -and $p.Ref.N -eq 12 -and -not $p.Bang)
    $p = ConvertTo-CliCommand '12!'
    Add-T 'parse 12!'       ($p.Op -eq 'act' -and $p.Bang)
    $p = ConvertTo-CliCommand '"Log In"'
    Add-T 'parse "label"'   ($p.Op -eq 'act' -and $p.Ref.Label -eq 'Log In')
    $p = ConvertTo-CliCommand '4 = admin user'
    Add-T 'parse fill'      ($p.Op -eq 'fill' -and $p.Ref.N -eq 4 -and $p.Value -eq 'admin user')
    $p = ConvertTo-CliCommand '"Password"=?'
    Add-T 'parse secret'    ($p.Op -eq 'fill' -and $p.Secret -and $p.Ref.Label -eq 'Password')
    $p = ConvertTo-CliCommand '4=env:FWPASS'
    Add-T 'parse env'       ($p.Op -eq 'fill' -and $p.Env -eq 'FWPASS')
    $p = ConvertTo-CliCommand 'click! "Reboot"'
    Add-T 'parse click!'    ($p.Op -eq 'act' -and $p.Bang -and $p.Ref.Label -eq 'Reboot')
    $p = ConvertTo-CliCommand '10.0.0.1:4443'
    Add-T 'parse bare target' ($p.Op -eq 'go' -and $p.Target -eq '10.0.0.1:4443')
    $p = ConvertTo-CliCommand '@nyc-fw'
    Add-T 'parse @bookmark' ($p.Op -eq 'go' -and $p.Target -eq 'bm:nyc-fw')
    $p = ConvertTo-CliCommand 'type 3 hello world'
    Add-T 'parse type'      ($p.Op -eq 'fill' -and $p.Value -eq 'hello world')
    $p = ConvertTo-CliCommand 'click Log In'
    Add-T 'parse bare label' ($p.Op -eq 'act' -and $p.Ref.Label -eq 'Log In')
    $p = ConvertTo-CliCommand 'r'
    Add-T 'r = reader'      ($p.Op -eq 'text' -and $p.Mode -eq 'article')
    $p = ConvertTo-CliCommand 'frobnicate'
    Add-T 'parse unknown -> error' ($p.Op -eq 'error')
    $p = ConvertTo-CliCommand 'submit'
    Add-T 'parse submit = Enter' ($p.Op -eq 'key' -and $p.Key -eq 'Enter')

    $items = @(
        [pscustomobject]@{ i = 1; k = 'in';  l = 'Username'; v = '' }
        [pscustomobject]@{ i = 2; k = 'pw';  l = 'Password'; v = '' }
        [pscustomobject]@{ i = 3; k = 'btn'; l = 'Login'; v = '' }
        [pscustomobject]@{ i = 4; k = 'btn'; l = 'Login with SSO'; v = '' }
        [pscustomobject]@{ i = 5; k = 'a';   l = 'Forgot password?'; v = '' }
    )
    $r = Resolve-CliLabel $items 'login'
    Add-T 'label: exact beats substring' ($r.Hit.i -eq 3)
    $r = Resolve-CliLabel $items 'pass'
    Add-T 'label: ambiguity refused'     ($null -eq $r.Hit -and @($r.Ambiguous).Count -eq 2)
    Add-T 'filter in -> fields' (@(Select-CliItems $items 'in').Count -eq 2)
    $lst = @(
        [pscustomobject]@{ i = 1; k = 'hdr'; l = 'From'; v = '' }
        [pscustomobject]@{ i = 2; k = 'row'; l = 'Any-Trusted'; v = '' }
        [pscustomobject]@{ i = 3; k = 'row'; l = 'Any-Optional'; v = '' }
        [pscustomobject]@{ i = 4; k = 'btn'; l = 'Remove (From)'; v = '' }
        [pscustomobject]@{ i = 5; k = 'hdr'; l = 'To'; v = '' }
        [pscustomobject]@{ i = 6; k = 'row'; l = 'Any'; v = '' })
    $fl = @(Select-CliItems $lst 'from')
    Add-T 'finding a list heading brings its rows' (($fl | ForEach-Object { $_.i }) -join ',' -eq '1,2,3,4') (($fl | ForEach-Object { $_.i }) -join ',')
    $fl = @(Select-CliItems $lst 'optional')
    Add-T 'finding a row brings its heading' (($fl | ForEach-Object { $_.i }) -join ',' -eq '1,3') (($fl | ForEach-Object { $_.i }) -join ',')

    $w = @(Split-CliWords ('x' * 130 + ' tail') 50)
    Add-T 'wrap hard-splits long words' (@($w | Where-Object { $_.Length -gt 50 }).Count -eq 0) ($w.Count)
    $t = @(Format-CliText "Interface`tIP`tStatus`nport1`t10.0.0.1/24`tup`nwan1`t203.0.113.9/30`tup" 80)
    Add-T 'table columns align' ($t.Count -eq 3 -and $t[1].IndexOf('10.0.0.1') -eq $t[2].IndexOf('203.0.113.9')) ($t -join ' | ')

    $news = @(
        [pscustomobject]@{ i = 1; k = 'btn'; l = 'More - Court Rejects Latest Effort to Impound Ballots' }
        [pscustomobject]@{ i = 2; k = 'a';   l = 'Court Rejects Latest Effort to Impound Ballots' }
        [pscustomobject]@{ i = 3; k = 'btn'; l = 'Apply' }
        [pscustomobject]@{ i = 4; k = 'a';   l = 'Policies' }
    )
    Add-T 'secondary menu button detected' ((Test-CliSecondary $news 0) -and -not (Test-CliSecondary $news 2))
    $long = @(
        [pscustomobject]@{ i = 13; k = 'btn'; l = 'More - 9th Circuit again denies Trump administration request to block 20,000 Cal' }
        [pscustomobject]@{ i = 14; k = 'a';   l = '9th Circuit again denies Trump administration request to block 20,000 California' }
    )
    Add-T 'secondary detected when both labels hit the 80-char cap' (Test-CliSecondary $long 0) "$($long[0].l.Length) vs $($long[1].l.Length)"
    Add-T 'link itself is never secondary' (-not (Test-CliSecondary $long 1))
    $d = Get-CliDelta @($news[2], $news[3]) @($news[2], $news[3], $news[0])
    Add-T 'delta finds new items'  (@($d.Added).Count -eq 1 -and $d.Added[0].i -eq 1 -and $d.Gone -eq 0)
    $snapT = [pscustomobject]@{ title = 'Story'; url = 'https://x/'; art = [pscustomobject]@{ w = 1240; lead = 'x' }; items = @(
        [pscustomobject]@{ i = 1; k = 'a'; l = 'Politics'; v = '' }
        [pscustomobject]@{ i = 2; k = 'btn'; l = 'More - A very long headline about the court case'; v = '' }
        [pscustomobject]@{ i = 3; k = 'a'; l = 'A very long headline about the court case'; v = '' }
        [pscustomobject]@{ i = 4; k = 'in'; l = 'Search'; v = '' }) }
    $rows = @(Get-BrowseRows $snapT '')
    Add-T 'browse: article row first, menu button hidden' ($rows.Count -eq 4 -and $rows[0].k -eq 'read' -and -not ($rows | Where-Object { $_.i -eq 2 }))
    $ui = @{ Sel = 0; Top = 0; Filter = ''; Num = ''; Msgs = (New-Object System.Collections.Generic.List[string]); NewKeys = @{}; ListH = 3; Quiet = $false }
    $key = { param($c, $k) [ConsoleKeyInfo]::new([char]$c, [ConsoleKey]$k, $false, $false, $false) }
    $e = Step-Browse $ui $rows (& $key ([char]13) 'Enter')
    Add-T 'browse: Enter on article row reads it' ($e.Do -eq 'open' -and $e.Row.k -eq 'read')
    $null = Step-Browse $ui $rows (& $key ([char]0) 'DownArrow'); $null = Step-Browse $ui $rows (& $key ([char]0) 'DownArrow'); $null = Step-Browse $ui $rows (& $key ([char]0) 'DownArrow'); $null = Step-Browse $ui $rows (& $key ([char]0) 'DownArrow')
    Add-T 'browse: cursor clamps and scrolls' ($ui.Sel -eq 3 -and $ui.Top -eq 1) "sel $($ui.Sel) top $($ui.Top)"
    $null = Step-Browse $ui $rows (& $key '1' 'D1'); $null = Step-Browse $ui $rows (& $key '4' 'D4')
    $e = Step-Browse $ui $rows (& $key ([char]13) 'Enter')
    Add-T 'browse: typed number + Enter' ($e.Do -eq 'num' -and $e.N -eq 14 -and $ui.Num -eq '')
    $e = Step-Browse $ui $rows (& $key '!' 'D1')
    Add-T 'browse: ! opens with OK-to-confirm' ($e.Do -eq 'open' -and $e.Bang)
    Add-T 'browse: b = back, r = read, q = quit' ((Step-Browse $ui $rows (& $key 'b' 'B')).Do -eq 'back' -and (Step-Browse $ui $rows (& $key 'r' 'R')).Do -eq 'read' -and (Step-Browse $ui $rows (& $key 'q' 'Q')).Do -eq 'quit')
    $ui.Msgs.Add('The page asked something')
    $fr = @(Get-BrowseFrame $ui $snapT $rows 12 60)
    Add-T 'browse: frame fits the screen exactly' ($fr.Count -eq 12 -and @($fr | Where-Object { $_.T.Length -ne 60 }).Count -eq 0) "$($fr.Count) lines"
    Add-T 'browse: highlight + status bar says what Enter does' (@($fr | Where-Object { $_.B -eq 'Cyan' }).Count -eq 1 -and $fr[-1].T -match 'Enter: ') $fr[-1].T
    $sorry = [pscustomobject]@{ url = 'https://www.google.com/sorry/index?continue=https%3A%2F%2Fnews.google.com%2Fread%2FCBMi123&q=x'; title = 'https://news.google.com/read/CBMi123'; frames = @(); items = @() }
    Add-T 'challenge: Google sorry page detected' (Test-CliChallenge $sorry)
    Add-T 'challenge: continue address recovered' ((Get-CliChallengeTarget $sorry) -eq 'https://news.google.com/read/CBMi123') (Get-CliChallengeTarget $sorry)
    Add-T 'challenge: Cloudflare title detected' (Test-CliChallenge ([pscustomobject]@{ url = 'https://x.com/'; title = 'Just a moment...'; frames = @() }))
    Add-T 'challenge: ordinary page is not one' (-not (Test-CliChallenge ([pscustomobject]@{ url = 'https://10.1.1.1/login'; title = 'FortiGate'; frames = @() })))
    $hr = @(Get-BrowseRows $sorry '')
    $sorry2 = [pscustomobject]@{ url = $sorry.url; title = $sorry.title; frames = @(); items = @([pscustomobject]@{ i = 1; k = 'chk'; l = "I'm not a robot"; v = 'off' }) }
    $hr = @(Get-BrowseRows $sorry2 '')
    Add-T 'challenge: your checkbox first, window option after' ($hr.Count -eq 2 -and $hr[0].k -eq 'chk' -and $hr[1].k -eq 'human')
    $navSnap = [pscustomobject]@{ title = 'Fireware'; url = 'https://fw/'; items = @(
        (1..12 | ForEach-Object { [pscustomobject]@{ i = $_; k = 'a'; l = "Menu $_"; v = ''; nav = 1 } })
        [pscustomobject]@{ i = 13; k = 'btn'; l = 'Refresh'; v = '' }) }
    $script:UI.ShowMenu = $false
    $nr = @(Get-BrowseRows $navSnap '')
    Add-T 'menu folded into one line, content first' ($nr.Count -eq 2 -and $nr[0].k -eq 'menu' -and $nr[1].l -eq 'Refresh' -and (Get-BrowseFirstContent $nr) -eq 1)
    $script:UI.ShowMenu = $true
    $nr = @(Get-BrowseRows $navSnap '')
    $script:UI.ShowMenu = $false
    Add-T 'menu opens in place' ($nr.Count -eq 14 -and $nr[1].l -eq 'Menu 1' -and $nr[13].l -eq 'Refresh')
    Add-T 'search covers the menu' (@(Get-BrowseRows $navSnap 'menu 1').Count -ge 1)
    $lo = @([pscustomobject]@{ i = 0; k = 'menu'; l = 'Menu'; v = '' }, [pscustomobject]@{ i = 1; k = 'btn'; l = 'Logout'; v = '' }, [pscustomobject]@{ i = 2; k = 'btn'; l = 'ACTION'; v = '' })
    Add-T 'highlight never starts on Logout' ((Get-BrowseFirstContent $lo) -eq 2)
    $login = [pscustomobject]@{ title = 'login'; url = 'https://fw/auth/login'; items = @(
        [pscustomobject]@{ i = 1; k = 'in'; l = 'User Name'; v = 'admin' }
        [pscustomobject]@{ i = 2; k = 'pw'; l = 'Passphrase'; v = '' }
        [pscustomobject]@{ i = 3; k = 'sel'; l = 'Authentication Server'; v = 'Firebox-DB'; n = 3 }
        [pscustomobject]@{ i = 4; k = 'btn'; l = 'LOG IN'; v = '' }) }
    $lr = @(Get-BrowseRows $login '')
    Add-T 'dropdown option counts are not menu links' ($lr.Count -eq 4 -and -not ($lr | Where-Object { $_.k -eq 'menu' }) -and $lr[2].l -eq 'Authentication Server') (($lr | ForEach-Object { "$($_.k):$($_.l)" }) -join ', ')
    Add-T 'video links tagged' ((Format-BrowseRow ([pscustomobject]@{ i = 1; k = 'a'; l = 'Disney prices'; v = ''; m = 'video' })) -eq '[VIDEO] Disney prices')
    $vs = [pscustomobject]@{ title = 'Video'; url = 'https://x/video/1'; media = [pscustomobject]@{ k = 'video' }; items = @([pscustomobject]@{ i = 1; k = 'a'; l = 'Home'; v = '' }) }
    $vr = @(Get-BrowseRows $vs '')
    Add-T 'video page flagged at the top' ($vr[0].k -eq 'note' -and $vr[0].l -match '^VIDEO page') "$($vr[0].l)"
    $f = Format-CliItem ([pscustomobject]@{ i = 7; k = 'chk'; l = 'Enable HTTPS'; v = 'on' })
    Add-T 'render checkbox' ($f -match '\[x\] Enable HTTPS') $f
    Add-T 'secrets hidden in logs' ((Hide-Secrets '4=hunter2') -eq '4=****' -and (Hide-Secrets '4=?') -eq '4=?' -and (Hide-Secrets 'type 4 hunter2') -eq 'type 4 ****') (Hide-Secrets '4=hunter2')

    $nonAscii = @($script:KERNEL.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count
    Add-T 'kernel is ASCII'  ($nonAscii -eq 0)
    Add-T 'kernel has ops'   (($script:KERNEL -match 'snap:') -and ($script:KERNEL -match 'settle:') -and ($script:KERNEL -match 'act:'))
    return $res
}

function Test-CliLive {
    $res = New-Object System.Collections.Generic.List[object]
    function Add-T([string]$n, [bool]$ok, [string]$d = '') { $res.Add([pscustomobject]@{ Name = $n; Pass = $ok; Detail = $d }) }
    $html = @'
<html><head><title>T0</title></head><body>
<form onsubmit="event.preventDefault(); document.title = (S.u==='admin' && S.p==='pw1') ? 'LOGGED-IN' : 'BAD';">
<table><tr><td>Username</td><td><input id="u"></td></tr><tr><td>Password</td><td><input id="p" type="password"></td></tr></table>
<button type="submit">Login</button></form>
<button onclick="if (confirm('Reboot now?')) document.title='REBOOTING';">Reboot</button>
<a href="about:blank#story" onclick="event.preventDefault();">Stubborn headline</a>
<span role="checkbox" aria-checked="false" tabindex="0" style="display:inline-block;width:24px;height:24px;border:1px solid" onclick="if (event.isTrusted) { this.setAttribute('aria-checked','true'); }">Real clicks only</span>
<button onclick="var p=document.createElement('div'); p.innerHTML='<button>Copy link</button><button>Hide story</button>'; document.body.appendChild(p);">Open menu</button>
<label>Enable HTTPS <input type="checkbox"></label>
<select aria-label="Interface"><option>port1</option><option>wan1</option></select>
<iframe name="cfg" srcdoc="<button onclick=&quot;parent.document.title='FRAME'&quot;>Apply</button>"></iframe>
<div id="h"></div>
<script>
var S = {u:'', p:''};
['u','p'].forEach(function(id){ var el = document.getElementById(id), tr = '', d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value');
  Object.defineProperty(el,'value',{get:function(){return d.get.call(el)},set:function(v){tr=v;d.set.call(el,v)}});
  el.addEventListener('input',function(){var v=d.get.call(el); if(v===tr)return; tr=v; S[id]=v;}); });
document.getElementById('h').attachShadow({mode:'open'}).innerHTML = '<button onclick="document.title=\'SHADOW\'">Shadow Save</button>';
</script></body></html>
'@
    $url = 'data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($html))
    $title = { $s = Invoke-Kernel 'snap' $null; return "$($s.title)" }
    try {
        Add-T 'navigate data: page'  (Invoke-CliCommand @{ Op = 'go'; Target = $url; Bang = $false })
        Add-T 'fill by label'        (Invoke-CliLine '"Username"=admin; "Password"=pw1')
        $null = Invoke-CliLine '"Login"'
        Add-T 'framework-safe login' ((& $title) -eq 'LOGGED-IN') (& $title)
        $null = Invoke-CliLine '"Reboot"'
        Add-T 'confirm defaults to CANCEL' ((& $title) -eq 'LOGGED-IN') (& $title)
        $null = Invoke-CliLine '"Reboot"!'
        Add-T 'bang answers OK'      ((& $title) -eq 'REBOOTING') (& $title)
        $before = @((Get-Tab).Snap.items).Count
        $null = Update-Snap
        $script:UI.Quiet = $true; $script:UI.Msgs.Clear()
        $menuRow = @((Get-Tab).Snap.items | Where-Object { $_.l -eq 'Open menu' })[0]
        Invoke-BrowseEffect @{ Do = 'open'; Row = $menuRow; Bang = $false }
        $rowsNow = @(Get-BrowseRows (Get-Tab).Snap '')
        $script:UI.Quiet = $false
        Add-T 'browse: new items marked, highlight jumps to them' ($script:UI.NewKeys.Count -eq 2 -and $rowsNow[$script:UI.Sel].l -eq 'Copy link' -and "$($script:UI.Msgs -join ' ')" -match 'appeared') "$($script:UI.Msgs -join ' | ')"
        $null = Invoke-CliLine 'go about:blank'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = $url; Bang = $false }
        $null = Invoke-CliLine '"Username"=admin; "Password"=pw1; "Login"'
        $before = @((Get-Tab).Snap.items).Count
        $null = Invoke-CliLine '"Open menu"'
        $after = Update-Snap
        Add-T 'in-page change: new items listed' ((@($after.items | Where-Object { $_.l -eq 'Copy link' }).Count -eq 1) -and (@($after.items).Count -eq $before + 2)) "$before -> $(@($after.items).Count)"
        $null = Invoke-CliLine '"Apply"'
        $keep = (Get-Tab).Snap
        Add-T 'click inside iframe'  ((& $title) -eq 'FRAME') (& $title)
        $null = Invoke-CliLine '"Shadow Save"'
        Add-T 'click inside shadow DOM' ((& $title) -eq 'SHADOW') (& $title)
        Add-T 'checkbox idempotent'  (Invoke-CliLine '"Enable HTTPS"=on; "Enable HTTPS"=on')
        $s = Update-Snap
        $cb = @($s.items | Where-Object { $_.l -eq 'Enable HTTPS' })[0]
        Add-T 'checkbox state on'    ($cb.v -eq 'on') "$($cb.v)"
        Add-T 'select by text'       (Invoke-CliLine '"Interface"=wan1')
        $null = Invoke-CliLine '"Real clicks only"'
        $rc = @(@((Get-Tab).Snap.items) | Where-Object { $_.l -eq 'Real clicks only' })[0]
        Add-T 'box that ignores scripted clicks gets a real one' ($rc.v -eq 'on') "$($rc.v)"
        $null = Invoke-CliLine '"Stubborn headline"'
        $s2 = Update-Snap
        Add-T 'link that ignores click is followed' ("$($s2.url)" -like 'about:blank*') "$($s2.url)"
        $para = '<p>' + (('The committee heard testimony about the measure and its effects on the district. ' * 4)) + '</p>'
        $art = '<html><head><title>Story</title></head><body><nav><a href="/a">Politics</a><a href="/b">World</a></nav><h1>Big Headline</h1><div class="article-body">' + ($para * 8) + '</div><a href="/x"><img alt=""></a><a href="/x">Related story</a><a href="/x">Related story</a></body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($art))); Bang = $false }
        $s3 = Update-Snap
        Add-T 'article detected' ($s3.art -and [int]$s3.art.w -ge 200) "$($s3.art.w)"
        Add-T 'same-destination links shown once' (@($s3.items | Where-Object { $_.l -eq 'Related story' }).Count -eq 1)
        $rd = Invoke-Kernel 'text' @{ mode = 'article' }
        Add-T 'reader gives headline + body, no nav' ("$($rd.text)".StartsWith('Big Headline') -and "$($rd.text)" -notmatch 'Politics') ("$($rd.text)".Substring(0, [Math]::Min(60, "$($rd.text)".Length)))
        $grid = @'
<html><head><title>Users and Roles</title></head><body>
<a href="#">Dashboard</a>
<table class="layout"><tr><td>Layout cell, not data</td></tr></table>
<table id="users"><thead><tr><th>Name</th><th>Role</th><th>Status</th></tr></thead>
<tbody><tr><td>admin</td><td>Device Administrator</td><td>Enabled</td></tr>
<tr><td>status</td><td>Device Monitor</td><td>Enabled</td></tr></tbody></table>
<button id="add">ADD</button><button id="edit" disabled>EDIT</button><button id="rm" disabled>REMOVE</button>
<script>
document.querySelector('#users tbody').addEventListener('click', function (e) {
  var tr = e.target.closest('tr'); if (!tr) return;
  document.querySelectorAll('#users tr.selected').forEach(function (x) { x.classList.remove('selected'); });
  tr.classList.add('selected'); document.getElementById('edit').disabled = false; document.getElementById('rm').disabled = false;
});
</script></body></html>
'@
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($grid))); Bang = $false }
        $sg = Update-Snap
        $rowsG = @($sg.items | Where-Object { $_.k -eq 'row' })
        Add-T 'table rows listed with their cells' ($rowsG.Count -eq 2 -and $rowsG[0].l -eq 'admin | Device Administrator | Enabled') (($rowsG | ForEach-Object { $_.l }) -join ' / ')
        Add-T 'layout table rows not listed' (-not ($sg.items | Where-Object { $_.l -match 'Layout cell' }))
        $script:UI.Quiet = $true; $script:UI.Msgs.Clear()
        Invoke-BrowseEffect @{ Do = 'open'; Row = $rowsG[1]; Bang = $false }
        $rowsNow = @(Get-BrowseRows (Get-Tab).Snap '')
        $script:UI.Quiet = $false
        $selRow = @($rowsNow | Where-Object { $_.k -eq 'row' -and $_.l -like 'status*' })[0]
        Add-T 'Enter on a row selects it' ($selRow.v -eq 'on') "$($selRow.v)"
        Add-T 'highlight jumps to the button that turned on' ("$($rowsNow[$script:UI.Sel].l)" -eq 'EDIT' -and -not $rowsNow[$script:UI.Sel].d) "$($rowsNow[$script:UI.Sel].l)"
        $mod = @'
<html><head><title>Modal</title><style>.modal{display:none;position:fixed;top:20px;left:20px}.modal.in{display:block}</style></head><body>
<h5>Firebox Users</h5><button id="a1">Add</button><button id="rm" onclick="document.getElementById('cb').classList.add('in')">Remove</button>
<h5>Firebox Groups</h5><button>Add</button>
<a data-toggle="tooltip" title="help">?</a>
<div id="cb" class="modal"><div class="modal-header"><button class="close" data-dismiss="modal">x</button></div>
<div class="modal-body">Are you sure you want to remove user 'jim'?</div>
<div class="modal-footer"><button onclick="document.title='REMOVED'">Yes</button><button onclick="this.closest('.modal').classList.remove('in')">No</button></div></div>
</body></html>
'@
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($mod))); Bang = $false }
        $sm = Update-Snap
        Add-T 'same-named buttons get their section' (@($sm.items | Where-Object { $_.l -eq 'Add (Firebox Users)' }).Count -eq 1 -and @($sm.items | Where-Object { $_.l -eq 'Add (Firebox Groups)' }).Count -eq 1) ((@($sm.items) | ForEach-Object { $_.l }) -join ', ')
        Add-T 'tooltip icons are not items' (-not ($sm.items | Where-Object { $_.l -eq '?' -or $_.l -eq 'help' }))
        $null = Invoke-CliLine '"Remove"'
        $sm = Update-Snap
        $mrows = @(Get-BrowseRows $sm '')
        Add-T 'page dialog takes over the list' (@($sm.items).Count -eq 3 -and $sm.items[0].l -eq 'Close' -and $sm.items[1].l -eq 'Yes') ((@($sm.items) | ForEach-Object { $_.l }) -join ', ')
        Add-T 'dialog question shown on top' ($mrows[0].k -eq 'note' -and "$($mrows[1].l)" -match "remove user 'jim'") "$($mrows[1].l)"
        $null = Invoke-CliLine '"No"'
        $sm = Update-Snap
        Add-T 'closing the dialog brings the page back' (-not $sm.modal -and @($sm.items | Where-Object { $_.l -like 'Remove*' }).Count -eq 1)
        $dash = @'
<html><head><title>Fireware Web UI (T30)</title></head><body>
<ul class="nav nav-list well" id="webui_nav_list">
<li><a href="#a">Front Panel</a></li><li><a href="#b">Subscription Services</a></li><li><a href="#c">FireWatch</a></li><li><a href="#d">Interfaces</a></li>
<li><a href="#e">Traffic Monitor</a></li><li><a href="#f">Gateway Wireless Controller</a></li><li><a href="#g">Geolocation</a></li><li><a href="#h">Network</a></li>
<li><a href="#i">Firewall</a></li><li><a href="#j">Authentication</a></li><li><a href="#k">System</a></li><li><a href="#l">About</a></li></ul>
<ul class="nav nav-tabs"><li><a href="#t1">Tab One</a></li></ul>
<button id="dashboard_btn_refresh"><i class="icon-refresh"></i></button>
<table class="layout"><tr><td>
  <div class="widget-title">Top Clients</div>
  <table><thead><tr><th>NAME</th><th>RATE</th></tr></thead><tbody><tr><td>192.168.1.244</td><td>598 Kbps</td></tr></tbody></table>
  <a href="#all">View all Top Clients</a>
</td></tr></table></body></html>
'@
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dash))); Bang = $false }
        $sd = Update-Snap
        Add-T 'site menu links flagged (tabs are not)' (@($sd.items | Where-Object { $_.nav }).Count -eq 12 -and -not ($sd.items | Where-Object { $_.l -eq 'Tab One' -and $_.nav })) "$(@($sd.items | Where-Object { $_.nav }).Count) flagged"
        Add-T 'layout table holding tables is not a row' (-not ($sd.items | Where-Object { $_.k -eq 'row' -and $_.l -match 'View all' })) ((@($sd.items | Where-Object { $_.k -eq 'row' }) | ForEach-Object { $_.l }) -join ' / ')
        Add-T 'column headings carry the widget title' (@($sd.items | Where-Object { $_.k -eq 'hdr' -and $_.l -eq 'Top Clients: NAME | RATE' }).Count -eq 1) ((@($sd.items | Where-Object { $_.k -eq 'hdr' }) | ForEach-Object { $_.l }) -join ' / ')
        Add-T 'icon button named (from its icon, else its id)' (@($sd.items | Where-Object { $_.l -eq 'Refresh' }).Count -eq 1) ((@($sd.items | Where-Object { $_.k -eq 'btn' }) | ForEach-Object { $_.l }) -join ' / ')
        $fold = '<html><body><button id="calc" onclick="var p=document.getElementById(''panel''); p.style.height=''auto''">Calculate</button>' +
                '<div id="panel" style="height:0;overflow:hidden"><label>Wildcard mask <input id="wm"></label></div><a class="mob btn"><i class="icon-chevron-left"></i></a></body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fold))); Bang = $false }
        $sf = Update-Snap
        Add-T 'fields in a folded section are not listed' (-not ($sf.items | Where-Object { $_.l -eq 'Wildcard mask' })) ((@($sf.items) | ForEach-Object { $_.l }) -join ', ')
        Add-T 'icon-only button named from its icon' (@($sf.items | Where-Object { $_.l -eq 'Chevron left' }).Count -eq 1)
        $null = Invoke-CliLine '"Calculate"'
        $sf = Update-Snap
        Add-T 'unfolding shows them' (@($sf.items | Where-Object { $_.l -eq 'Wildcard mask' }).Count -eq 1)
        $dbl = @'
<html><head><title>Policies</title></head><body>
<table id="g" role="grid"><thead><tr><th>Name</th><th>Port</th></tr></thead><tbody>
<tr class="jqgrow" id="1"><td><input type="checkbox" class="cbox" id="jqg_g_1"></td><td>Ping</td><td>ICMP</td></tr>
<tr class="jqgrow" id="2"><td><input type="checkbox" class="cbox" id="jqg_g_2"></td><td>DNS</td><td>53</td></tr></tbody></table>
<script>
var g = document.getElementById('g');
g.addEventListener('click', function (e) { var tr = e.target.closest('tr.jqgrow'); if (!tr) return;
  document.querySelectorAll('tr.jqgrow').forEach(function (x) { x.classList.remove('ui-state-highlight'); x.querySelector('.cbox').checked = false; });
  tr.classList.add('ui-state-highlight'); tr.querySelector('.cbox').checked = true; });
g.addEventListener('dblclick', function (e) { var tr = e.target.closest('tr.jqgrow'); if (tr) document.title = 'EDIT ' + tr.cells[1].innerText; });
</script></body></html>
'@
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dbl))); Bang = $false }
        $sb = Update-Snap
        Add-T 'grid row tick-boxes not listed separately' (-not ($sb.items | Where-Object { $_.k -eq 'chk' })) ((@($sb.items) | ForEach-Object { "$($_.k):$($_.l)" }) -join ', ')
        $null = Invoke-CliLine '"DNS"'
        $sb = Update-Snap
        Add-T 'first Enter selects the row' (@($sb.items | Where-Object { $_.l -like 'DNS*' -and $_.v -eq 'on' }).Count -eq 1 -and "$($sb.title)" -eq 'Policies')
        $null = Invoke-CliLine '"DNS"'
        $sb = Update-Snap
        Add-T 'Enter on a selected row opens it (double-click)' ("$($sb.title)" -eq 'EDIT DNS') "$($sb.title)"
        $ft = '<html><body><div><table id="gf"></table><button id="btn_from_add">Add</button><button id="btn_from_remove">Remove</button></div>' +
              '<div><table id="gt"></table><button id="btn_to_add">Add</button><button id="btn_to_remove">Remove</button></div></body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ft))); Bang = $false }
        $sft = Update-Snap
        $labs = (@($sft.items) | ForEach-Object { $_.l }) -join ', '
        Add-T 'Add/Remove told apart by their ids' ($labs -eq 'Add (From), Remove (From), Add (To), Remove (To)') $labs
        $tabs = '<html><head><base href="/"></head><body><ul class="nav-tabs"><li><a href="#p1" onclick="event.preventDefault();document.title=''TAB2''">Advanced</a></li></ul></body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tabs))); Bang = $false }
        $here = "$((Update-Snap).url)"
        $null = Invoke-CliLine '"Advanced"'
        $st = Update-Snap
        Add-T 'tab links never navigate away (base href=/)' ("$($st.url)" -eq $here -and "$($st.title)" -eq 'TAB2') "$($st.url)"
        $sub = '<html><body><button id="go" onclick="this.disabled=true;this.textContent=''LOGGING IN...'';location.href=''about:blank''">LOG IN</button></body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sub))); Bang = $false }
        $null = Invoke-CliLine '"LOG IN"'
        $null = Invoke-CliLine 'back'
        $sbk = Update-Snap
        Add-T 'back shows the page fresh, not frozen mid-submit' (@($sbk.items | Where-Object { $_.l -eq 'LOG IN' -and -not $_.d }).Count -eq 1) ((@($sbk.items) | ForEach-Object { "$($_.l)$(if ($_.d) {' (disabled)'})" }) -join ', ')
        $t30 = @'
<html><head><title>Policies</title></head><body>
<div class="btn-group"><button>Action</button><ul style="display:none"><li><a href="#" id="edit_policy">Edit Policy</a></li></ul></div>
<table id="g" role="grid"><thead><tr><th>Name</th><th>Port</th></tr></thead><tbody>
<tr class="jqgrow" id="1"><td><input type="checkbox" class="cbox"></td><td>Ping</td><td>ICMP</td></tr>
<tr class="jqgrow" id="2"><td><input type="checkbox" class="cbox"></td><td>DNS</td><td>53</td></tr></tbody></table>
<script>
var sel = null;
document.getElementById('g').addEventListener('click', function (e) { var tr = e.target.closest('tr.jqgrow'); if (!tr) return;
  var on = !tr.classList.contains('ui-state-highlight');            // multiselect: a click toggles
  tr.classList.toggle('ui-state-highlight', on); tr.querySelector('.cbox').checked = on; sel = on ? tr : null; });
document.getElementById('edit_policy').addEventListener('click', function (e) { e.preventDefault(); if (sel) document.title = 'EDIT ' + sel.cells[1].innerText; });
</script></body></html>
'@
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t30))); Bang = $false }
        $null = Invoke-CliLine '"Ping"'
        $null = Invoke-CliLine '"Ping"'
        $s30 = Update-Snap
        Add-T 'no double-click: uses the page''s Edit, row stays selected' ("$($s30.title)" -eq 'EDIT Ping') "$($s30.title)"
        $tagdlg = @'
<html><body><div><table id="grid_tags"></table><button id="btn_tag_edit">Edit</button></div>
<button id="btn_popup_add_tag">&#60;&#60;</button><button id="btn_popup_remove_tag">&#62;&#62;</button></body></html>
'@
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($tagdlg))); Bang = $false }
        $stg = Update-Snap
        $labs = (@($stg.items) | ForEach-Object { $_.l }) -join ', '
        Add-T 'lone generic button gets its context' ($labs -match 'Edit \(Tag\)') $labs
        Add-T 'symbol buttons named by what they do' ($labs -match 'Add tag \(<<\)' -and $labs -match 'Remove tag \(>>\)') $labs
        $med = '<html><head><meta property="og:type" content="video.other"></head><body><video style="width:640px;height:360px" controls></video>' +
               '<a href="https://www.foxbusiness.com/video/6407305992112">Disney hotel prices</a><a href="https://example.com/podcast/ep-12.mp3">Episode 12</a><a href="https://example.com/news/story">A story</a></body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($med))); Bang = $false }
        $sm2 = Update-Snap
        $mlabs = (@($sm2.items) | ForEach-Object { Format-CliItem $_ }) -join ' / '
        Add-T 'video page detected' ("$($sm2.media.k)" -eq 'video') "$($sm2.media.k)"
        Add-T 'video / audio links tagged, others not' ($mlabs -match '\[VIDEO\] Disney' -and $mlabs -match '\[AUDIO\] Episode 12' -and $mlabs -notmatch '\] A story') $mlabs
        $live = '<html><body><h1>Live updates</h1><div class="story">' + ('<p>' + ('Officials said the count would continue through the weekend in several counties. ' * 4) + '</p>') * 3 +
                '<div class="video-resource"><div class="video-resource__headline">Mike Rogers says he''d welcome Haley Stevens</div><div class="video-resource__duration">0:44</div></div>' +
                ('<p>' + ('Lawyers for both campaigns filed new motions in state court on Saturday afternoon. ' * 4) + '</p>') * 2 + '</div></body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($live))); Bang = $false }
        $rl = Invoke-Kernel 'text' @{ mode = 'article' }
        $rlines = "$($rl.text)" -split "`n" | ForEach-Object { $_.Trim() }
        Add-T 'reader marks inline video with its length' (($rlines -contains "[VIDEO 0:44] Mike Rogers says he'd welcome Haley Stevens") -and -not ($rlines -contains '0:44')) (($rlines | Where-Object { $_ -match 'VIDEO|0:44' }) -join ' / ')
        $big = '<html><head><title>BIG</title></head><body>' + ((1..900 | ForEach-Object { "<a href='https://news.example.com/read/$('X' * 120)$_'>Headline number $_ about something long enough</a><br>" }) -join '') + '</body></html>'
        $null = Invoke-CliCommand @{ Op = 'go'; Target = ('data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($big))); Bang = $false }
        $s = Update-Snap
        Add-T 'large page (chunked transfer)' ($s -and @($s.items).Count -ge 600) "$(@($s.items).Count) items; $($script:S.LastErr)"
        $tx = Invoke-Kernel 'text' @{ mode = 'all' }
        Add-T 'large page text' (-not $tx.err -and "$($tx.text)".Contains('Headline number 900')) "$($tx.msg)"
        Add-T 'vanished item refused' (-not (Invoke-CliLine 'go about:blank; 1')) 'acting on a vanished list must fail'
    } catch { Add-T 'live run' $false (Get-InnermostMessage $_) }
    return $res
}

function Write-TestResults($res) {
    $pass = @($res | Where-Object { $_.Pass }).Count
    $fail = @($res | Where-Object { -not $_.Pass }).Count
    foreach ($r in $res) {
        if ($r.Pass) { Write-Host ("    [PASS] {0}" -f $r.Name) -ForegroundColor Green }
        else { Write-Host ("    [FAIL] {0,-34} {1}" -f $r.Name, $r.Detail) -ForegroundColor Red }
    }
    $col = 'Green'; if ($fail) { $col = 'Red' }
    Write-Host ("`n    {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $col
    return ($fail -eq 0)
}

# ===========================================================================
# 9. Main
# ===========================================================================
if ($OfflineTest) {
    Write-Host "`n  -- offline tests (no browser) --" -ForegroundColor Cyan
    $ok = Write-TestResults (Test-CliOffline)
    if ($ok) { exit 0 } else { exit 1 }
}

try {
    if (-not $Dump) { Show-Banner }
    if (-not (Initialize-Pup)) { exit 1 }
    Write-Log ("===== {0} {1} start  PS {2}  Pup {3} =====" -f $script:Product, $script:Version, $PSVersionTable.PSVersion, (Get-Module Pup).Version)
    Import-CliBookmarks
    Start-CliBrowser

    if ($SelfTest) {
        $null = New-CliTab ''
        Write-Host "`n  -- offline tests --" -ForegroundColor Cyan
        $a = Write-TestResults (Test-CliOffline)
        Write-Host "`n  -- live tests (headless Chromium, no network) --" -ForegroundColor Cyan
        $saved = $script:Interactive; $script:Interactive = $false
        $b = Write-TestResults (Test-CliLive)
        $script:Interactive = $saved
        if ($a -and $b) { exit 0 } else { exit 1 }
    }

    $start = $Url
    if (-not $start -and $script:Interactive) {
        Write-Host ''
        Write-Host '  Where to?  Type an address and press Enter, for example:' -ForegroundColor Gray
        Write-Host '      news.google.com      10.1.1.1:4443      @mybookmark' -ForegroundColor Gray
        $start = Read-Host '  Address'
    }
    if ($start -match '^@(.+)$') {
        if ($script:S.Bookmarks.ContainsKey($matches[1])) { $start = $script:S.Bookmarks[$matches[1]] }
        else { Write-Warn "No bookmark '$start'"; $start = '' }
    }
    $okStart = New-CliTab $start

    if ($Run)  { $null = Invoke-CliLine "run $Run" }
    if ($Exec) { $null = Invoke-CliLine $Exec }
    if ($Dump) {
        if ($okStart -or $Exec -or $Run) { $null = & $script:Ops['text'] @{ Op = 'text'; Mode = 'all' } }
        return
    }
    if (-not $script:Interactive) { return }
    if (-not $Classic) { Start-Browse; return }

    while ($script:S.Running) {
        $tab = Get-Tab
        $label = 'blank'
        if ($tab -and $tab.Snap -and $tab.Snap.title) { $label = "$($tab.Snap.title)" }
        if ($label.Length -gt 24) { $label = $label.Substring(0, 23) + '~' }
        Write-Host ''
        Write-Host "  [$($script:S.Cur):$label] > " -NoNewline -ForegroundColor Cyan
        $line = $null
        try { $line = Read-Host } catch { break }
        if ($null -eq $line) { break }
        $null = Invoke-CliLine $line
    }
}
catch {
    $m = Get-InnermostMessage $_
    Write-Fail "Fatal: $m"
    Write-Log "fatal: $m"
    Write-Info 'Run  .\CLI-Browser.ps1 -SelfTest  to diagnose.'
}
finally {
    if ($script:S.Browser) {
        try { $null = Invoke-PupGuarded 'Stop-PupBrowser' @{ Browser = $script:S.Browser } 8000 'quit' } catch { Write-Log "quit: $(Get-InnermostMessage $_)" }
    }
    Write-Log '===== end ====='
}
