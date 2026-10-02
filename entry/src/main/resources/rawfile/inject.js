(function () {
  if (window.__dshShellInjected) {
    return;
  }
  window.__dshShellInjected = true;

  var N = window.dshShell || {};

  try {
    var mk = document.createElement('div');
    mk.id = 'dsh-inj-mark';
    mk.style.cssText = 'position:fixed;right:8px;bottom:8px;width:16px;height:16px;border-radius:50%;background:#e00000;z-index:2147483647;';
    (document.body || document.documentElement).appendChild(mk);
  } catch (e) {
  }

  function safe(fn, dflt) {
    try {
      return fn();
    } catch (e) {
      return dflt;
    }
  }

  function groups() {
    return safe(function () {
      return JSON.parse(N.getGroups() || '[]');
    }, []);
  }

  function current() {
    return safe(function () {
      return JSON.parse(N.getCurrent() || '{"g":0,"i":0}');
    }, { g: 0, i: 0 });
  }

  function log(m) {
    safe(function () {
      N.log(String(m));
    });
  }

  function setVal(el, v) {
    try {
      var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
      var desc = Object.getOwnPropertyDescriptor(proto, 'value');
      if (desc && desc.set) {
        desc.set.call(el, v);
      } else {
        el.value = v;
      }
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } catch (e) {
    }
  }

  window.addEventListener('error', function (e) {
    log('JS error: ' + (e && e.message ? e.message : ''));
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e && e.reason ? e.reason : '';
    log('Promise rejection: ' + ((r && r.message) ? r.message : r));
  });

  setInterval(function () {
    var b = document.querySelector("button[data-phase='disconnected']");
    if (!b) {
      var all = document.querySelectorAll('button');
      for (var i = 0; i < all.length; i++) {
        var lb = all[i].getAttribute('aria-label') || '';
        if (lb.indexOf('\u8fde\u63a5') >= 0) {
          b = all[i];
          break;
        }
      }
    }
    if (b) {
      safe(function () {
        b.click();
      });
    }
  }, 2500);

  (function () {
    var top = safe(function () {
      return N.getSafeTop();
    }, 0) || 0;
    var bottom = safe(function () {
      return N.getSafeBottom();
    }, 0) || 0;
    var st = document.createElement('style');
    st.id = 'dsh-shell-insets';
    st.textContent = 'html{box-sizing:border-box !important;padding-top:' + top + 'px !important;'
      + 'padding-bottom:' + bottom + 'px !important;height:100% !important;}'
      + 'body{height:100% !important;}';
    (document.head || document.documentElement).appendChild(st);
  })();

  function tryAutoLogin(tag) {
    var c = current();
    var g = groups();
    var addr = (g[c.g] && g[c.g].items) ? g[c.g].items[c.i] : null;
    if (!addr || !addr.user || !addr.pass) {
      return;
    }
    var pw = document.querySelector("input[type='password']");
    if (!pw) {
      return;
    }
    var scope = pw.form || document;
    var inputs = scope.querySelectorAll('input');
    var user = null;
    for (var i = 0; i < inputs.length; i++) {
      var t = (inputs[i].type || 'text').toLowerCase();
      if (t === 'text' || t === 'email' || t === 'tel' || t === 'number' || t === 'search') {
        user = inputs[i];
        break;
      }
    }
    if (user && !user.value) {
      setVal(user, addr.user);
    }
    if (!pw.value) {
      setVal(pw, addr.pass);
    }
    var btn = scope.querySelector("button[type='submit'],input[type='submit']");
    if (btn) {
      safe(function () {
        btn.click();
      });
    } else if (pw.form) {
      safe(function () {
        pw.form.requestSubmit();
      });
    }
    log('auto login (' + tag + '): ' + (addr.name || addr.url));
  }

  setTimeout(function () {
    tryAutoLogin('1.5s');
  }, 1500);
  setTimeout(function () {
    tryAutoLogin('3.5s');
  }, 3500);

  function anchorButton() {
    var dlg = document.querySelector("[role='dialog']");
    if (!dlg) {
      return null;
    }
    var all = dlg.querySelectorAll("button,[role='tab']");
    for (var i = 0; i < all.length; i++) {
      var txt = (all[i].textContent || '').trim();
      if (txt.indexOf('Agent') === 0 || txt.indexOf('\u9884\u8bbe') >= 0) {
        return all[i];
      }
    }
    return null;
  }

  function ensureTab() {
    var a = anchorButton();
    if (!a || !a.parentElement) {
      return;
    }
    if (a.parentElement.querySelector('[data-dsh-sites-tab]')) {
      return;
    }
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('data-dsh-sites-tab', '1');
    btn.textContent = '\u7ad9\u70b9';
    btn.className = a.className;
    btn.style.marginLeft = '4px';
    btn.addEventListener('click', function (e) {
      e.stopPropagation();
      safe(function () {
        N.openSites();
      });
    });
    a.parentElement.insertBefore(btn, a.nextSibling);
  }

  setInterval(ensureTab, 1500);

  (function () {
    var OKS = ['\u7ee7\u7eed', '\u6211\u77e5\u9053\u4e86', '\u5f00\u59cb\u4f7f\u7528', '\u540c\u610f'];
    function isOk(t) {
      for (var i = 0; i < OKS.length; i++) {
        if (t === OKS[i]) {
          return true;
        }
      }
      return false;
    }
    function collect(root, out) {
      var list;
      try {
        list = root.querySelectorAll('*');
      } catch (e) {
        return;
      }
      for (var i = 0; i < list.length; i++) {
        out.push(list[i]);
        if (list[i].shadowRoot) {
          collect(list[i].shadowRoot, out);
        }
      }
    }
    function clickIt(el, how) {
      log('dismiss intro (' + how + '): ' + el.tagName);
      try {
        el.click();
      } catch (e) {
      }
      try {
        el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
      } catch (e) {
      }
    }
    function byText() {
      var out = [];
      collect(document, out);
      for (var i = 0; i < out.length; i++) {
        var el = out[i];
        var t = (el.textContent || '').trim();
        if (!isOk(t)) {
          continue;
        }
        var r = el.getBoundingClientRect();
        if (r.width <= 1 || r.height <= 1 || r.width > window.innerWidth * 0.5) {
          continue;
        }
        clickIt(el, 'text');
        return true;
      }
      return false;
    }
    function byPoint() {
      var w = window.innerWidth;
      var h = window.innerHeight;
      var pts = [[0.69, 0.72], [0.66, 0.72], [0.72, 0.72], [0.69, 0.76], [0.6, 0.72], [0.62, 0.75]];
      for (var i = 0; i < pts.length; i++) {
        var el = document.elementFromPoint(Math.round(w * pts[i][0]), Math.round(h * pts[i][1]));
        if (!el) {
          continue;
        }
        if (isOk((el.textContent || '').trim())) {
          clickIt(el, 'point');
          return true;
        }
        var p = el.parentElement;
        if (p && isOk((p.textContent || '').trim())) {
          clickIt(p, 'point-parent');
          return true;
        }
      }
      return false;
    }
    function tick() {
      if (byText()) {
        return;
      }
      byPoint();
    }
    setInterval(tick, 900);
    setTimeout(tick, 800);
    setTimeout(tick, 2000);
    setTimeout(tick, 4000);
  })();

  var loginClicked = false;
  function autoSubmitLogin() {
    var list = document.querySelectorAll('button, input[type=submit], input[type=button], a');
    for (var i = 0; i < list.length; i++) {
      var b = list[i];
      var txt = (b.textContent || b.value || '').replace(/\s/g, '');
      var isLogin = txt === '\u767b\u5f55' || txt === '\u767b\u9646' || txt === 'Signin' || txt === 'Login';
      if (!isLogin) {
        continue;
      }
      var r = b.getBoundingClientRect();
      if (r.width < 40 || r.height < 10) {
        continue;
      }
      log('auto submit login');
      safe(function () {
        b.click();
      });
      return true;
    }
    return false;
  }
  setTimeout(function () {
    if (!loginClicked) {
      loginClicked = true;
      autoSubmitLogin();
    }
  }, 4500);

  document.addEventListener('click', function (e) {
    var t = e.target;
    if (!t || !t.closest) {
      return;
    }
    if (t.closest('button')) {
      return;
    }
    if (t.closest("[class*='logoRow']") || t.closest("[class*='railMark']")) {
      e.preventDefault();
      e.stopPropagation();
    }
  }, true);
})();
