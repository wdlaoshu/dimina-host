/* Dream Tapir · 发布控制台（纯前端，无构建步骤） */
(function () {
  "use strict";

  var PALETTE = ["#4C63FF", "#7B5CFF", "#22B07D", "#F0A02A", "#E0464B", "#7A8194"];

  var state = {
    entries: [],
    images: []
  };

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

  function uid() {
    return Math.random().toString(36).slice(2, 10);
  }

  function today() {
    var date = new Date();
    var month = String(date.getMonth() + 1).padStart(2, "0");
    var day = String(date.getDate()).padStart(2, "0");
    return date.getFullYear() + "-" + month + "-" + day;
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
    return ["hsl(" + hash + " 72% 58%)", "hsl(" + ((hash + 34) % 360) + " 74% 48%)"];
  }

  function shortHash(value) {
    var text = String(value || "");
    if (!text) return "—";
    return text.slice(0, 12) + "…";
  }

  function buildZipPath(entry) {
    return (
      "packages/" +
      (entry.appId || "appId") +
      "/" +
      (Number(entry.versionCode) || 1) +
      ".zip"
    );
  }

  function toast(message) {
    var node = $("toast");
    node.textContent = message;
    node.classList.add("show");
    window.clearTimeout(toast.timer);
    toast.timer = window.setTimeout(function () {
      node.classList.remove("show");
    }, 2400);
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

  function hasSubtle() {
    return !!(window.crypto && window.crypto.subtle && window.crypto.subtle.digest);
  }

  function hasZip() {
    return typeof window.JSZip === "function";
  }

  async function sha256(file) {
    if (!hasSubtle()) throw new Error("当前环境无法计算 SHA-256，请用 HTTPS 域名打开");
    var buffer = await file.arrayBuffer();
    var digest = await window.crypto.subtle.digest("SHA-256", buffer);
    return Array.prototype.map
      .call(new Uint8Array(digest), function (byte) {
        return byte.toString(16).padStart(2, "0");
      })
      .join("");
  }

  function checkEnv() {
    var dot = $("env-dot");
    var text = $("env-text");
    if (!hasSubtle()) {
      dot.className = "status-dot err";
      text.textContent = "非 HTTPS 环境：仍可编辑与导出，但无法计算 SHA-256";
      return;
    }
    if (!hasZip()) {
      dot.className = "status-dot err";
      text.textContent = "JSZip 未加载（CDN 不可达）：可手动添加或导入 apps.json";
      return;
    }
    dot.className = "status-dot ok";
    text.textContent = "浏览器能力正常 · JSZip 已加载 · 本地计算 SHA-256";
  }

  function findFile(archive, pattern) {
    var found = null;
    archive.forEach(function (path, file) {
      if (file.dir) return;
      if (!pattern.test(path)) return;
      var depth = path.split("/").length;
      if (!found || depth < found.depth) found = { file: file, depth: depth };
    });
    return found ? found.file : null;
  }

  async function readJson(file) {
    return JSON.parse(await file.async("string"));
  }

  function inferName(appConfig) {
    if (!appConfig || !appConfig.app) return "";
    var app = appConfig.app;
    if (app.name) return String(app.name);
    if (app.window && app.window.navigationBarTitleText) {
      return String(app.window.navigationBarTitleText);
    }
    return "";
  }

  function matchIcon(appId) {
    if (!appId) return "";
    var target = String(appId).toLowerCase();
    for (var i = 0; i < state.images.length; i += 1) {
      var image = state.images[i];
      var base = image.name.replace(/\.[^.]+$/, "").toLowerCase();
      if (base === target) return "icons/" + image.name;
    }
    return "";
  }

  function registerImage(file) {
    var exists = state.images.some(function (image) {
      return image.name === file.name;
    });
    if (exists) {
      toast(file.name + " 已存在，已跳过");
      return;
    }
    state.images.push({ file: file, name: file.name });
    state.entries.forEach(function (entry) {
      if (!entry.icon && entry.appId && entry.appId.toLowerCase() === file.name.replace(/\.[^.]+$/, "").toLowerCase()) {
        entry.icon = "icons/" + file.name;
      }
    });
  }

  async function addZip(file) {
    var entry = {
      id: uid(),
      fileName: file.name,
      file: file,
      size: file.size,
      sha256: "",
      appId: "",
      name: "",
      versionCode: 1,
      versionName: "1.0.0",
      zipPath: "",
      icon: "",
      notes: "",
      force: false,
      minHostVersion: "",
      publishedAt: today(),
      status: "parsing",
      error: "",
      autoPath: ""
    };
    state.entries.push(entry);
    renderEntries();
    renderOutputs();

    try {
      if (!hasZip()) throw new Error("JSZip 未加载，无法解析 ZIP");
      var archive = await window.JSZip.loadAsync(file);
      var configFile = findFile(archive, /(^|\/)config\.json$/i);
      if (!configFile) {
        var appConfigFile = findFile(archive, /(^|\/)main\/app-config\.json$/i);
        if (appConfigFile) {
          var inferred = inferName(await readJson(appConfigFile));
          if (inferred) entry.name = inferred;
        }
        throw new Error(
          "ZIP 内缺少 config.json（需要 appId、versionCode、versionName），请在打包时加入 ZIP 根目录"
        );
      }

      var config = await readJson(configFile);
      var appId = String(config.appId || "").trim();
      if (!appId) throw new Error("config.json 缺少 appId");

      entry.appId = appId;
      entry.name = String(config.name || appId).trim();
      entry.versionCode = Number(config.versionCode) || 1;
      entry.versionName = String(config.versionName || "1.0.0").trim();
      entry.zipPath = buildZipPath(entry);
      entry.autoPath = entry.zipPath;
      entry.icon = matchIcon(appId);
      entry.sha256 = await sha256(file);
      entry.status = "ready";
    } catch (error) {
      entry.status = "error";
      entry.error = error && error.message ? error.message : "解析失败";
    }
    renderEntries();
    renderOutputs();
  }

  async function handleFiles(fileList) {
    var files = Array.prototype.slice.call(fileList || []);
    if (!files.length) return;
    var zips = files.filter(function (file) {
      return /\.zip$/i.test(file.name);
    });
    var images = files.filter(function (file) {
      return /\.(png|jpe?g|webp|svg)$/i.test(file.name);
    });
    var ignored = files.length - zips.length - images.length;

    images.forEach(registerImage);
    renderEntries();
    for (var i = 0; i < zips.length; i += 1) {
      await addZip(zips[i]);
    }
    if (images.length) toast("已加入 " + images.length + " 个图标");
    if (ignored > 0) toast("已忽略 " + ignored + " 个不支持的文件");
    renderAll();
  }

  function manualEntry() {
    var entry = {
      id: uid(),
      fileName: "",
      file: null,
      size: 0,
      sha256: "",
      appId: "",
      name: "",
      versionCode: 1,
      versionName: "1.0.0",
      zipPath: "",
      icon: "",
      notes: "",
      force: false,
      minHostVersion: "",
      publishedAt: today(),
      status: "manual",
      error: "",
      autoPath: ""
    };
    state.entries.push(entry);
    renderAll();
    var card = document.querySelector('.entry[data-id="' + entry.id + '"]');
    if (card) {
      var input = card.querySelector('[data-field="appId"]');
      if (input) input.focus();
      card.scrollIntoView({ block: "center", behavior: "smooth" });
    }
  }

  function statusChip(entry) {
    if (entry.status === "parsing") return '<span class="badge gray">解析中…</span>';
    if (entry.status === "error") {
      return (
        '<span class="badge red" title="' +
        escapeHtml(entry.error) +
        '">解析失败</span>'
      );
    }
    if (entry.status === "ready") {
      return entry.sha256
        ? '<span class="badge green">SHA-256 已生成</span>'
        : '<span class="badge gray">缺少 SHA-256</span>';
    }
    if (entry.status === "remote") return '<span class="badge gray">已导入</span>';
    return '<span class="badge brand">手动</span>';
  }

  function fieldHTML(label, field, value, options) {
    options = options || {};
    var attrs = [
      'class="input"',
      'data-field="' + field + '"',
      'value="' + escapeHtml(value == null ? "" : value) + '"'
    ];
    if (options.type) attrs.push('type="' + options.type + '"');
    if (options.placeholder) attrs.push('placeholder="' + escapeHtml(options.placeholder) + '"');
    if (options.readonly) attrs.push("readonly");
    if (options.min != null) attrs.push('min="' + options.min + '"');
    return (
      '<div class="field' +
      (options.full ? " full" : "") +
      '"><label>' +
      escapeHtml(label) +
      "</label><input " +
      attrs.join(" ") +
      " /></div>"
    );
  }

  function entryHTML(entry) {
    var colors = gradient(entry.appId || entry.name);
    var background =
      "background:linear-gradient(135deg," + colors[0] + "," + colors[1] + ")";
    var letter = escapeHtml((entry.name || entry.appId || "?").slice(0, 1));
    var source = entry.file
      ? entry.fileName
      : entry.status === "remote"
        ? "来自 apps.json"
        : "手动条目";

    return (
      '<article class="entry" data-id="' +
      entry.id +
      '">' +
      '<div class="entry-head">' +
      '<div class="app-icon" style="' +
      background +
      '">' +
      letter +
      "</div>" +
      '<div class="entry-title"><strong>' +
      escapeHtml(entry.name || "未命名应用") +
      "</strong><span>" +
      escapeHtml(entry.appId || "等待填写 appId") +
      "</span></div>" +
      statusChip(entry) +
      '<button class="icon-btn" data-action="remove" type="button" title="移除" aria-label="移除条目">✕</button>' +
      "</div>" +
      '<div class="entry-grid">' +
      fieldHTML("名称", "name", entry.name, { placeholder: "应用显示名称" }) +
      fieldHTML("appId", "appId", entry.appId, { placeholder: "wx...", readonly: !!entry.file }) +
      fieldHTML("版本名", "versionName", entry.versionName, { placeholder: "1.0.0", readonly: !!entry.file }) +
      fieldHTML("版本号", "versionCode", entry.versionCode, { type: "number", min: 1, readonly: !!entry.file }) +
      fieldHTML("安装包路径", "zipPath", entry.zipPath, {
        full: true,
        placeholder: "packages/{appId}/{versionCode}.zip"
      }) +
      fieldHTML("图标路径", "icon", entry.icon, {
        placeholder: "icons/{appId}.png（可留空）"
      }) +
      fieldHTML("最低宿主版本", "minHostVersion", entry.minHostVersion, {
        placeholder: "1.0.0（可留空）"
      }) +
      fieldHTML("发布时间", "publishedAt", entry.publishedAt, { type: "date" }) +
      '<div class="field full"><label>更新说明</label><textarea class="input" data-field="notes" rows="2" placeholder="本次更新内容，会展示在宿主详情页">' +
      escapeHtml(entry.notes) +
      "</textarea></div>" +
      "</div>" +
      '<div class="entry-foot">' +
      '<label class="checkbox"><input type="checkbox" data-field="force"' +
      (entry.force ? " checked" : "") +
      " /> 强制更新</label>" +
      '<span class="file-chip' +
      (entry.file ? " ok" : "") +
      '" title="' +
      escapeHtml(source) +
      '">' +
      escapeHtml(source) +
      "</span>" +
      "</div>" +
      "</article>"
    );
  }

  function renderEntries() {
    $("entries").innerHTML = state.entries.map(entryHTML).join("");
    $("entries-empty").style.display = state.entries.length ? "none" : "block";
  }

  function buildDoc() {
    var apps = state.entries
      .filter(function (entry) {
        return String(entry.appId || "").trim();
      })
      .map(function (entry) {
        var app = {
          appId: String(entry.appId).trim(),
          name: String(entry.name || entry.appId).trim(),
          versionCode: Number(entry.versionCode) || 0,
          versionName: String(entry.versionName || "1.0.0").trim(),
          zip: String(entry.zipPath || buildZipPath(entry)).trim()
        };
        if (entry.sha256) app.sha256 = String(entry.sha256);
        if (Number(entry.size) > 0) app.size = Number(entry.size);
        if (entry.icon) app.icon = String(entry.icon).trim();
        if (entry.notes) app.notes = String(entry.notes).trim();
        app.force = !!entry.force;
        if (entry.minHostVersion) app.minHostVersion = String(entry.minHostVersion).trim();
        if (entry.publishedAt) app.publishedAt = String(entry.publishedAt);
        return app;
      });

    return {
      schema: 1,
      channel: ($("channel").value || "prod").trim(),
      generatedAt: new Date().toISOString(),
      apps: apps
    };
  }

  function manifestRows() {
    var rows = [];
    state.entries.forEach(function (entry) {
      var target = String(entry.zipPath || buildZipPath(entry)).trim();
      if (entry.file) {
        rows.push({
          source: entry.fileName,
          target: target,
          size: entry.size,
          sha: entry.sha256
        });
      } else if (entry.status === "remote" && target) {
        rows.push({ source: "（已导入）", target: target, size: entry.size, sha: entry.sha256 });
      }
    });
    state.images.forEach(function (image) {
      rows.push({
        source: image.name,
        target: "icons/" + image.name,
        size: image.file.size,
        sha: ""
      });
    });
    rows.push({ source: "（下载 apps.json）", target: "apps.json", size: 0, sha: "" });
    return rows;
  }

  function renderManifest() {
    var rows = manifestRows();
    var body = $("manifest-body");
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="4">暂无需要上传的文件</td></tr>';
      return;
    }
    body.innerHTML = rows
      .map(function (row) {
        return (
          "<tr><td><code>" +
          escapeHtml(row.source) +
          "</code></td><td><code>" +
          escapeHtml(row.target) +
          "</code></td><td>" +
          escapeHtml(formatBytes(row.size)) +
          "</td><td><code title=\"" +
          escapeHtml(row.sha) +
          '">' +
          escapeHtml(shortHash(row.sha)) +
          "</code></td></tr>"
        );
      })
      .join("");
  }

  function renderPreview() {
    $("json-preview").textContent = JSON.stringify(buildDoc(), null, 2);
  }

  function renderCounts() {
    var missing = 0;
    var seen = {};
    var duplicates = 0;
    state.entries.forEach(function (entry) {
      var appId = String(entry.appId || "").trim();
      if (!appId) {
        missing += 1;
        return;
      }
      if (seen[appId]) {
        duplicates += 1;
      } else {
        seen[appId] = true;
      }
    });

    var parts = [state.entries.length + " 个应用条目"];
    if (missing) parts.push(missing + " 个缺少 appId");
    if (duplicates) parts.push(duplicates + " 个 appId 重复");
    $("entry-count").textContent = parts.join(" · ");
    $("entry-dot").className =
      "status-dot" + (missing || duplicates ? " err" : state.entries.length ? " ok" : "");
  }

  function renderOutputs() {
    renderCounts();
    renderManifest();
    renderPreview();
  }

  function renderAll() {
    renderEntries();
    renderOutputs();
  }

  function entryOf(node) {
    var card = node.closest(".entry");
    if (!card) return null;
    for (var i = 0; i < state.entries.length; i += 1) {
      if (state.entries[i].id === card.dataset.id) return { entry: state.entries[i], card: card };
    }
    return null;
  }

  function syncAutoPath(entry, card) {
    if (!entry.autoPath || entry.zipPath !== entry.autoPath) return;
    entry.zipPath = buildZipPath(entry);
    entry.autoPath = entry.zipPath;
    var input = card.querySelector('[data-field="zipPath"]');
    if (input) input.value = entry.zipPath;
  }

  function updateTitle(entry, card) {
    var title = card.querySelector(".entry-title strong");
    var appIdNode = card.querySelector(".entry-title span");
    if (title) title.textContent = entry.name || "未命名应用";
    if (appIdNode) appIdNode.textContent = entry.appId || "等待填写 appId";
  }

  function applyField(entry, card, field, input) {
    if (field === "force") {
      entry.force = !!input.checked;
    } else if (field === "versionCode") {
      entry.versionCode = Number(input.value) || 0;
      syncAutoPath(entry, card);
    } else if (field === "zipPath") {
      entry.zipPath = input.value;
      entry.autoPath = "";
    } else {
      entry[field] = input.value;
      if (field === "appId" || field === "versionCode") syncAutoPath(entry, card);
    }
    if (field === "name" || field === "appId") updateTitle(entry, card);
    renderOutputs();
  }

  function importCatalog(file) {
    file
      .text()
      .then(function (text) {
        return JSON.parse(text);
      })
      .then(function (doc) {
        if (!doc || !Array.isArray(doc.apps)) throw new Error("文件里没有 apps 数组");
        if (state.entries.length && !window.confirm("导入会替换当前 " + state.entries.length + " 个条目，继续？")) {
          return;
        }
        state.entries = doc.apps.map(function (app) {
          return {
            id: uid(),
            fileName: "",
            file: null,
            size: Number(app.size) || 0,
            sha256: String(app.sha256 || ""),
            appId: String(app.appId || ""),
            name: String(app.name || ""),
            versionCode: Number(app.versionCode) || 1,
            versionName: String(app.versionName || "1.0.0"),
            zipPath: String(app.zip || app.packageUrl || app.url || ""),
            icon: String(app.icon || ""),
            notes: String(app.notes || ""),
            force: !!app.force,
            minHostVersion: String(app.minHostVersion || ""),
            publishedAt: String(app.publishedAt || ""),
            status: "remote",
            error: "",
            autoPath: ""
          };
        });
        if (doc.channel) $("channel").value = String(doc.channel);
        renderAll();
        toast("已导入 " + state.entries.length + " 个条目");
      })
      .catch(function (error) {
        toast("导入失败：" + (error && error.message ? error.message : "无法读取"));
      });
  }

  function downloadJson() {
    var json = JSON.stringify(buildDoc(), null, 2);
    var blob = new Blob([json], { type: "application/json;charset=utf-8" });
    var url = URL.createObjectURL(blob);
    var link = document.createElement("a");
    link.href = url;
    link.download = "apps.json";
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    window.setTimeout(function () {
      URL.revokeObjectURL(url);
    }, 1000);
    toast("已生成 apps.json，请上传到站点根目录");
  }

  function manifestText() {
    var lines = ["# Dream Tapir 上传清单"];
    var rows = manifestRows();
    rows.forEach(function (row) {
      lines.push(row.source + "  ->  " + row.target);
    });
    return lines.join("\n");
  }

  function bind() {
    var dropzone = $("dropzone");
    var fileInput = $("file-input");

    dropzone.addEventListener("click", function () {
      fileInput.click();
    });
    dropzone.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        fileInput.click();
      }
    });
    ["dragenter", "dragover"].forEach(function (name) {
      dropzone.addEventListener(name, function (event) {
        event.preventDefault();
        dropzone.classList.add("dragging");
      });
    });
    ["dragleave", "drop"].forEach(function (name) {
      dropzone.addEventListener(name, function (event) {
        event.preventDefault();
        dropzone.classList.remove("dragging");
      });
    });
    dropzone.addEventListener("drop", function (event) {
      if (event.dataTransfer && event.dataTransfer.files) {
        handleFiles(event.dataTransfer.files);
      }
    });
    fileInput.addEventListener("change", function () {
      handleFiles(fileInput.files);
      fileInput.value = "";
    });

    $("add-entry").addEventListener("click", manualEntry);

    $("import-catalog").addEventListener("click", function () {
      $("json-input").click();
    });
    $("json-input").addEventListener("change", function () {
      if (this.files && this.files[0]) importCatalog(this.files[0]);
      this.value = "";
    });

    $("clear-all").addEventListener("click", function () {
      if (!state.entries.length && !state.images.length) return;
      if (!window.confirm("清空所有条目与图标？")) return;
      state.entries = [];
      state.images = [];
      renderAll();
      toast("已清空");
    });

    var entries = $("entries");
    entries.addEventListener("input", function (event) {
      var field = event.target.dataset.field;
      if (!field || event.target.type === "checkbox") return;
      var found = entryOf(event.target);
      if (!found) return;
      applyField(found.entry, found.card, field, event.target);
    });
    entries.addEventListener("change", function (event) {
      if (event.target.dataset.field !== "force") return;
      var found = entryOf(event.target);
      if (!found) return;
      applyField(found.entry, found.card, "force", event.target);
    });
    entries.addEventListener("click", function (event) {
      if (!event.target.closest('[data-action="remove"]')) return;
      var found = entryOf(event.target);
      if (!found) return;
      state.entries = state.entries.filter(function (entry) {
        return entry.id !== found.entry.id;
      });
      renderAll();
    });

    $("channel").addEventListener("input", renderOutputs);
    $("download-json").addEventListener("click", downloadJson);
    $("copy-json").addEventListener("click", function () {
      copyText(JSON.stringify(buildDoc(), null, 2));
    });
    $("copy-manifest").addEventListener("click", function () {
      copyText(manifestText());
    });
  }

  function start() {
    checkEnv();
    bind();
    renderAll();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
