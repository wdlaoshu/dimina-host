/* Dream Tapir · 应用目录（静态站点，无构建步骤） */
(function () {
  "use strict";

  var CATALOG_URL = "./apps.json";

  var DEMO = {
    schema: 1,
    channel: "demo",
    generatedAt: "2026-11-09T02:00:00Z",
    apps: [
      {
        appId: "wxhost_expense",
        name: "报销助手",
        versionCode: 12,
        versionName: "1.2.0",
        zip: "packages/wxhost_expense/12.zip",
        sha256: "9f2c4e1b8a7d6350f1e2c3b4a5968778695a4b3c2d1e0f998877665544332211",
        size: 2516582,
        icon: "",
        notes: "新增差旅补贴自动计算；修复发票识别在深色模式下偶发失败的问题。",
        force: false,
        minHostVersion: "1.0.0",
        publishedAt: "2026-11-06"
      },
      {
        appId: "wxhost_inspect",
        name: "设备巡检",
        versionCode: 8,
        versionName: "1.8.2",
        zip: "packages/wxhost_inspect/8.zip",
        sha256: "3a4b5c6d7e8f90112233445566778899aabbccddeeff00112233445566778899",
        size: 3250585,
        icon: "",
        notes: "强制更新：修复离线巡检记录上传时可能重复提交的问题。请所有巡检人员升级。",
        force: true,
        minHostVersion: "1.0.0",
        publishedAt: "2026-11-08"
      },
      {
        appId: "wxhost_approval",
        name: "审批中心",
        versionCode: 21,
        versionName: "2.1.0",
        zip: "packages/wxhost_approval/21.zip",
        sha256: "11223344556677889900aabbccddeeff1234567890abcdef1234567890abcdef",
        size: 4404019,
        icon: "",
        notes: "支持会签节点与会话内催办；优化长流程加载速度。",
        force: false,
        minHostVersion: "1.0.0",
        publishedAt: "2026-10-29"
      },
      {
        appId: "wxhost_timesheet",
        name: "工时填报",
        versionCode: 5,
        versionName: "1.0.5",
        zip: "packages/wxhost_timesheet/5.zip",
        sha256: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
        size: 1887436,
        icon: "",
        notes: "按项目模板批量填充；修复跨月汇总少一天的问题。",
        force: false,
        minHostVersion: "1.0.0",
        publishedAt: "2026-10-22"
      }
    ]
  };

  var state = {
    apps: [],
    doc: null,
    demo: false,
    tab: "all",
    query: ""
  };

  var PALETTE = ["#4C63FF", "#7B5CFF", "#22B07D", "#F0A02A", "#E0464B", "#7A8194"];

  function $(id) {
    return document.getElementById(id);
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function formatBytes(bytes) {
    var value = Number(bytes) || 0;
    if (value <= 0) return "—";
    var units = ["B", "KB", "MB", "GB"];
    var index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    return (index === 0 ? value.toFixed(0) : value.toFixed(1)) + " " + units[index];
  }

  function gradient(name) {
    var hash = 0;
    var text = String(name || "app");
    for (var i = 0; i < text.length; i += 1) {
      hash = (hash * 31 + text.charCodeAt(i)) % 360;
    }
    var hue = hash;
    return ["hsl(" + hue + " 72% 58%)", "hsl(" + ((hue + 34) % 360) + " 74% 48%)"];
  }

  function iconHTML(app) {
    var letter = escapeHtml((app.name || "?").slice(0, 1));
    var colors = gradient(app.appId || app.name);
    var background =
      "background:linear-gradient(135deg," + colors[0] + "," + colors[1] + ")";
    if (app.icon) {
      return (
        '<div class="app-icon" style="' +
        background +
        '"><img alt="" src="' +
        escapeHtml(app.icon) +
        '" data-fallback="' +
        letter +
        '"></div>'
      );
    }
    return '<div class="app-icon" style="' + background + '">' + letter + "</div>";
  }

  function bindImageFallbacks(root) {
    var images = root.querySelectorAll(".app-icon img");
    for (var i = 0; i < images.length; i += 1) {
      images[i].addEventListener("error", function () {
        var parent = this.parentElement;
        if (!parent) return;
        parent.textContent = this.dataset.fallback || "?";
      });
    }
  }

  function toast(message) {
    var node = $("toast");
    node.textContent = message;
    node.classList.add("show");
    window.clearTimeout(toast.timer);
    toast.timer = window.setTimeout(function () {
      node.classList.remove("show");
    }, 2200);
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(
        function () {
          toast("已复制");
        },
        function () {
          fallbackCopy(text);
        }
      );
    } else {
      fallbackCopy(text);
    }
  }

  function fallbackCopy(text) {
    var area = document.createElement("textarea");
    area.value = text;
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand("copy");
      toast("已复制");
    } catch (error) {
      toast("复制失败，请手动选择");
    }
    document.body.removeChild(area);
  }

  function absoluteUrl(path) {
    try {
      return new URL(path, window.location.href).href;
    } catch (error) {
      return path;
    }
  }

  function loadCatalog() {
    return fetch(CATALOG_URL, { cache: "no-store" })
      .then(function (response) {
        if (!response.ok) throw new Error("HTTP " + response.status);
        return response.json();
      })
      .then(function (doc) {
        if (!doc || !Array.isArray(doc.apps)) throw new Error("apps 字段缺失");
        return { doc: doc, demo: false };
      })
      .catch(function () {
        return { doc: DEMO, demo: true };
      });
  }

  function computeStats() {
    var totalSize = 0;
    var forced = 0;
    state.apps.forEach(function (app) {
      totalSize += Number(app.size) || 0;
      if (app.force) forced += 1;
    });
    return { totalSize: totalSize, forced: forced };
  }

  function renderStats() {
    var stats = computeStats();
    $("stat-apps").textContent = state.apps.length;
    $("stat-size").textContent = formatBytes(stats.totalSize);
    $("stat-force").textContent = stats.forced;
    $("donut-total").textContent = formatBytes(stats.totalSize);
    $("count-all").textContent = "(" + state.apps.length + ")";
    $("count-force").textContent = stats.forced ? "(" + stats.forced + ")" : "";
  }

  function renderDonut() {
    var donut = $("donut");
    var legend = $("legend");
    var apps = state.apps
      .filter(function (app) {
        return (Number(app.size) || 0) > 0;
      })
      .sort(function (a, b) {
        return (Number(b.size) || 0) - (Number(a.size) || 0);
      });

    if (!apps.length) {
      donut.style.background = "var(--bg-soft)";
      legend.innerHTML =
        '<div class="legend-item"><span class="name">安装包未提供体积信息</span></div>';
      return;
    }

    var top = apps.slice(0, 4);
    var rest = apps.slice(4);
    var total = apps.reduce(function (sum, app) {
      return sum + (Number(app.size) || 0);
    }, 0);
    var segments = [];
    var cursor = 0;
    var legendHtml = "";

    top.forEach(function (app, index) {
      var share = (Number(app.size) || 0) / total;
      var start = cursor;
      var end = Math.min(100, cursor + share * 100);
      segments.push(
        PALETTE[index] + " " + start.toFixed(2) + "% " + end.toFixed(2) + "%"
      );
      cursor = end;
      legendHtml +=
        '<div class="legend-item"><span class="legend-swatch" style="background:' +
        PALETTE[index] +
        '"></span><span class="name">' +
        escapeHtml(app.name) +
        '</span><span class="val">' +
        Math.round(share * 100) +
        "%</span></div>";
    });

    if (rest.length) {
      var restSize = rest.reduce(function (sum, app) {
        return sum + (Number(app.size) || 0);
      }, 0);
      var share = restSize / total;
      segments.push(
        PALETTE[4] + " " + cursor.toFixed(2) + "% 100%"
      );
      legendHtml +=
        '<div class="legend-item"><span class="legend-swatch" style="background:' +
        PALETTE[4] +
        '"></span><span class="name">其他 ' +
        rest.length +
        ' 个</span><span class="val">' +
        Math.round(share * 100) +
        "%</span></div>";
    } else if (cursor < 99.99) {
      segments.push(PALETTE[5] + " " + cursor.toFixed(2) + "% 100%");
    }

    if (!segments.length) {
      segments.push(PALETTE[0] + " 0% 100%");
    }

    donut.style.background = "conic-gradient(" + segments.join(",") + ")";
    legend.innerHTML = legendHtml;
  }

  function visibleApps() {
    var list = state.apps.slice();
    if (state.tab === "force") {
      list = list.filter(function (app) {
        return !!app.force;
      });
    } else if (state.tab === "recent") {
      list.sort(function (a, b) {
        return String(b.publishedAt || "").localeCompare(String(a.publishedAt || ""));
      });
    } else {
      list.sort(function (a, b) {
        return String(a.name || "").localeCompare(String(b.name || ""), "zh-CN");
      });
    }

    var query = state.query.trim().toLowerCase();
    if (query) {
      list = list.filter(function (app) {
        return (
          String(app.name || "").toLowerCase().indexOf(query) >= 0 ||
          String(app.appId || "").toLowerCase().indexOf(query) >= 0 ||
          String(app.notes || "").toLowerCase().indexOf(query) >= 0
        );
      });
    }
    return list;
  }

  function cardHTML(app) {
    var badges = "";
    if (app.force) badges += '<span class="badge red">强制更新</span>';
    if (app.minHostVersion) {
      badges +=
        '<span class="badge gray">宿主 ≥ ' +
        escapeHtml(app.minHostVersion) +
        "</span>";
    }

    var meta = [];
    meta.push("v" + escapeHtml(app.versionName || "1.0.0"));
    if (app.size) meta.push(formatBytes(app.size));
    if (app.publishedAt) meta.push(escapeHtml(app.publishedAt));

    var metaHtml = meta
      .map(function (item) {
        return "<span>" + item + "</span>";
      })
      .join('<span class="sep"></span>');

    var downloadAttrs = state.demo
      ? 'data-demo="1"'
      : 'href="' + escapeHtml(app.zip || "#") + '" download';

    return (
      '<article class="app-card" data-id="' +
      escapeHtml(app.appId) +
      '">' +
      '<div class="app-top">' +
      iconHTML(app) +
      '<div class="badges">' +
      badges +
      "</div>" +
      "</div>" +
      "<h3>" +
      escapeHtml(app.name) +
      "</h3>" +
      '<div class="appid">' +
      escapeHtml(app.appId) +
      "</div>" +
      '<p class="notes">' +
      escapeHtml(app.notes || "暂无更新说明") +
      "</p>" +
      '<div class="app-meta">' +
      metaHtml +
      "</div>" +
      '<div class="card-actions">' +
      '<button class="btn ghost small" data-action="detail">详情</button>' +
      '<a class="btn primary small" ' +
      downloadAttrs +
      ">下载</a>" +
      "</div>" +
      "</article>"
    );
  }

  function renderGrid() {
    var grid = $("grid");
    var list = visibleApps();

    if (!list.length) {
      grid.innerHTML =
        '<div class="empty">' +
        '<div class="big">⌕</div>' +
        "<h3>" +
        (state.query ? "没有匹配的应用" : state.tab === "force" ? "暂无强制更新" : "目录还是空的") +
        "</h3>" +
        "<p>" +
        (state.query
          ? "换个关键词试试，或清空搜索后查看全部应用。"
          : "打开发布控制台，拖入小程序 ZIP 并生成 apps.json，上传到站点根目录即可。") +
        "</p>" +
        '<div class="row"><a class="btn primary" href="admin.html">打开发布控制台</a>' +
        '<a class="btn ghost" href="./apps.json" target="_blank" rel="noopener">查看 apps.json</a></div>' +
        "</div>";
      return;
    }

    grid.innerHTML = list.map(cardHTML).join("");
    bindImageFallbacks(grid);
  }

  function renderAll() {
    renderStats();
    renderDonut();
    renderGrid();

    $("catalog-sub").textContent =
      state.apps.length +
      " 个应用 · 共 " +
      formatBytes(computeStats().totalSize) +
      (state.demo ? " · 示例数据" : " · 来自 apps.json");

    $("demo-banner").classList.toggle("show", state.demo);

    var catalogLink = $("catalog-link");
    if (catalogLink) {
      catalogLink.href = state.demo ? "admin.html" : "./apps.json";
      catalogLink.textContent = state.demo ? "去发布第一版" : "查看 apps.json";
      if (state.demo) {
        catalogLink.removeAttribute("target");
      } else {
        catalogLink.setAttribute("target", "_blank");
      }
    }
    $("sync-text").textContent = state.demo
      ? "示例数据 · 上传 apps.json 后自动切换"
      : "目录已更新" + (state.doc.generatedAt ? " · " + state.doc.generatedAt : "");
    $("footer-time").textContent = state.demo
      ? "示例数据"
      : "生成时间 " + (state.doc.generatedAt || "未知");
  }

  function openDetail(app) {
    $("modal-title").textContent = app.name || app.appId;
    $("modal-appid").textContent = app.appId || "";
    $("modal-icon").outerHTML = iconHTML(app).replace(
      'class="app-icon"',
      'class="app-icon" id="modal-icon"'
    );
    bindImageFallbacks($("modal-mask"));

    var rows = [
      ["版本", "v" + (app.versionName || "1.0.0")],
      ["版本号", String(app.versionCode || 0)],
      ["安装包", formatBytes(app.size)],
      ["发布时间", app.publishedAt || "未提供"],
      ["最低宿主", app.minHostVersion || "不限"],
      ["强制更新", app.force ? "是" : "否"],
      ["包路径", app.zip || "未提供"],
      ["SHA-256", app.sha256 || "未提供"]
    ];
    if (state.doc && state.doc.channel) {
      rows.push(["渠道", state.doc.channel]);
    }

    $("modal-kv").innerHTML = rows
      .map(function (row) {
        return (
          '<div class="kv-row"><span class="k">' +
          escapeHtml(row[0]) +
          '</span><span class="v">' +
          escapeHtml(row[1]) +
          "</span></div>"
        );
      })
      .join("");

    $("modal-note").textContent = app.notes || "暂无更新说明";
    $("modal-note-box").style.display = app.notes ? "block" : "none";

    var download = $("modal-download");
    if (state.demo || !app.zip) {
      download.removeAttribute("href");
      download.removeAttribute("download");
      download.textContent = "示例数据无安装包";
      download.setAttribute("aria-disabled", "true");
    } else {
      download.setAttribute("href", app.zip);
      download.setAttribute("download", "");
      download.textContent = "下载安装包";
      download.removeAttribute("aria-disabled");
    }

    $("modal-copy").onclick = function () {
      if (!app.zip) {
        toast("该应用没有安装包路径");
        return;
      }
      copyText(absoluteUrl(app.zip));
    };

    $("modal-mask").classList.add("open");
  }

  function closeDetail() {
    $("modal-mask").classList.remove("open");
  }

  function bind() {
    $("search").addEventListener("input", function (event) {
      state.query = event.target.value;
      renderGrid();
    });

    var tabs = document.querySelectorAll(".tab");
    for (var i = 0; i < tabs.length; i += 1) {
      tabs[i].addEventListener("click", function () {
        for (var j = 0; j < tabs.length; j += 1) {
          tabs[j].classList.remove("active");
        }
        this.classList.add("active");
        state.tab = this.dataset.tab;
        renderGrid();
      });
    }

    $("grid").addEventListener("click", function (event) {
      var demoLink = event.target.closest("a[data-demo]");
      if (demoLink) {
        event.preventDefault();
        toast("示例数据没有真实安装包，请先上传 ZIP 与 apps.json");
        return;
      }
      var card = event.target.closest(".app-card");
      if (!card) return;
      var app = state.apps.filter(function (item) {
        return item.appId === card.dataset.id;
      })[0];
      if (!app) return;
      openDetail(app);
    });

    $("modal-close").addEventListener("click", closeDetail);
    $("modal-mask").addEventListener("click", function (event) {
      if (event.target === this) closeDetail();
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") closeDetail();
    });

    $("copy-source").addEventListener("click", function () {
      copyText(absoluteUrl(CATALOG_URL));
    });

    var modalDownload = $("modal-download");
    modalDownload.addEventListener("click", function (event) {
      if (this.getAttribute("aria-disabled") === "true") {
        event.preventDefault();
        toast("示例数据没有真实安装包");
      }
    });
  }

  function start() {
    $("source-url").textContent = absoluteUrl(CATALOG_URL);
    bind();
    loadCatalog().then(function (result) {
      state.doc = result.doc;
      state.demo = result.demo;
      state.apps = (result.doc.apps || []).filter(function (app) {
        return app && app.appId;
      });
      renderAll();
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
