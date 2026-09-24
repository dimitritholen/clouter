/*
 * Clouter studio — media timeline.
 * Self-contained vanilla JS. No CDN, no build step.
 * Exposes window.ClouterTimeline.mount(container, mediaEl, {kind, markers}).
 */
(function () {
  "use strict";

  var STYLE_ID = "ct-timeline-style";

  function injectStyle() {
    if (document.getElementById(STYLE_ID)) return;
    var style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = [
      ":root{",
      "--ct-bg:#f4f4f5;--ct-track:#e2e2e6;--ct-border:#cfcfd6;--ct-fg:#1b1b1f;",
      "--ct-muted:#6b6b76;--ct-accent:#3b6fe0;--ct-accent-fg:#ffffff;",
      "--ct-pin:#e0693b;--ct-wave:#3b6fe0;--ct-popup-bg:#ffffff;--ct-danger:#c0392b;",
      "}",
      "@media (prefers-color-scheme: dark){:root{",
      "--ct-bg:#1c1c21;--ct-track:#2a2a31;--ct-border:#3a3a42;--ct-fg:#e9e9ee;",
      "--ct-muted:#9a9aa4;--ct-accent:#6f9bf2;--ct-accent-fg:#0d0d10;",
      "--ct-pin:#f0895c;--ct-wave:#8fb2f7;--ct-popup-bg:#26262c;--ct-danger:#e57267;",
      "}}",
      ".ct-timeline{position:relative;font:13px/1.4 system-ui,sans-serif;color:var(--ct-fg);",
      "background:var(--ct-bg);border:1px solid var(--ct-border);border-radius:6px;",
      "padding:8px;box-sizing:border-box;width:100%;}",
      ".ct-toolbar{display:flex;align-items:center;gap:8px;margin-bottom:6px;}",
      ".ct-add-btn{font:inherit;color:var(--ct-accent-fg);background:var(--ct-accent);",
      "border:none;border-radius:4px;padding:4px 10px;cursor:pointer;}",
      ".ct-add-btn:hover{filter:brightness(1.08);}",
      ".ct-bar-wrap{position:relative;height:56px;}",
      ".ct-wave{position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;}",
      ".ct-bar{position:relative;height:100%;background:var(--ct-track);border-radius:4px;",
      "cursor:pointer;overflow:visible;box-sizing:border-box;}",
      ".ct-ruler{position:absolute;left:0;right:0;bottom:0;height:16px;pointer-events:none;}",
      ".ct-tick{position:absolute;bottom:0;width:1px;height:6px;background:var(--ct-muted);}",
      ".ct-tick-label{position:absolute;bottom:6px;transform:translateX(-50%);",
      "font-size:10px;color:var(--ct-muted);white-space:nowrap;}",
      ".ct-playhead{position:absolute;top:0;bottom:0;width:2px;background:var(--ct-accent);",
      "pointer-events:none;}",
      ".ct-pin{position:absolute;top:-2px;transform:translateX(-50%);width:14px;height:14px;",
      "border-radius:50% 50% 50% 0;background:var(--ct-pin);border:1px solid var(--ct-border);",
      "transform-origin:center;rotate:-45deg;cursor:pointer;padding:0;}",
      ".ct-pin:focus-visible{outline:2px solid var(--ct-accent);outline-offset:2px;}",
      ".ct-popup{position:absolute;top:100%;margin-top:8px;z-index:5;min-width:220px;",
      "background:var(--ct-popup-bg);border:1px solid var(--ct-border);border-radius:6px;",
      "box-shadow:0 4px 16px rgba(0,0,0,.2);padding:8px;transform:translateX(-50%);}",
      ".ct-popup textarea{width:100%;box-sizing:border-box;font:inherit;color:var(--ct-fg);",
      "background:var(--ct-bg);border:1px solid var(--ct-border);border-radius:4px;",
      "padding:4px;resize:vertical;min-height:50px;}",
      ".ct-popup-actions{display:flex;justify-content:space-between;margin-top:6px;}",
      ".ct-popup-time{color:var(--ct-muted);font-size:11px;}",
      ".ct-btn{font:inherit;background:transparent;color:var(--ct-fg);",
      "border:1px solid var(--ct-border);border-radius:4px;padding:2px 8px;cursor:pointer;}",
      ".ct-btn-danger{color:var(--ct-danger);border-color:var(--ct-danger);}",
      ".ct-list{list-style:none;margin:10px 0 0;padding:0;",
      "border-top:1px solid var(--ct-border);}",
      ".ct-list-item{display:flex;align-items:baseline;gap:8px;padding:6px 2px;",
      "border-bottom:1px solid var(--ct-border);cursor:pointer;}",
      ".ct-list-time{color:var(--ct-accent);font-variant-numeric:tabular-nums;flex:none;}",
      ".ct-list-text{flex:1;color:var(--ct-fg);white-space:pre-wrap;overflow-wrap:anywhere;}",
      ".ct-list-del{flex:none;}",
      ".ct-empty{color:var(--ct-muted);padding:6px 2px;}",
    ].join("");
    document.head.appendChild(style);
  }

  function fmtTime(t) {
    t = Math.max(0, t || 0);
    var m = Math.floor(t / 60);
    var s = t - m * 60;
    var sStr = s.toFixed(1);
    if (s < 10) sStr = "0" + sStr;
    return m + ":" + sStr;
  }

  function fmtTick(t) {
    t = Math.max(0, Math.round(t));
    var m = Math.floor(t / 60);
    var s = t % 60;
    return m + ":" + (s < 10 ? "0" + s : s);
  }

  function niceTickInterval(duration) {
    var candidates = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800];
    var maxTicks = 10;
    for (var i = 0; i < candidates.length; i++) {
      if (duration / candidates[i] <= maxTicks) return candidates[i];
    }
    return candidates[candidates.length - 1];
  }

  function el(tag, cls, attrs) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (attrs) {
      for (var k in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, k)) node.setAttribute(k, attrs[k]);
      }
    }
    return node;
  }

  function isTextEntryTarget(target) {
    if (!target) return false;
    var tag = target.tagName;
    return tag === "TEXTAREA" || tag === "INPUT" || tag === "SELECT" || target.isContentEditable;
  }

  function mount(container, mediaEl, opts) {
    opts = opts || {};
    var kind = opts.kind === "audio" ? "audio" : "video";
    var initialMarkers = opts.markers || [];

    injectStyle();

    var root = el("div", "ct-timeline");
    var toolbar = el("div", "ct-toolbar");
    var addBtn = el("button", "ct-add-btn", { type: "button" });
    addBtn.textContent = "Add note at " + fmtTime(mediaEl.currentTime || 0);
    toolbar.appendChild(addBtn);

    var barWrap = el("div", "ct-bar-wrap");
    var bar = el("div", "ct-bar", { role: "slider", tabindex: "0", "aria-label": "Timeline" });
    var wave = null;
    var waveCtx = null;
    if (kind === "audio") {
      wave = el("canvas", "ct-wave");
      bar.appendChild(wave);
      waveCtx = wave.getContext("2d");
    }
    var ruler = el("div", "ct-ruler");
    var playhead = el("div", "ct-playhead");
    bar.appendChild(ruler);
    bar.appendChild(playhead);
    barWrap.appendChild(bar);

    var list = el("ul", "ct-list", { "aria-label": "Notes" });

    root.appendChild(toolbar);
    root.appendChild(barWrap);
    root.appendChild(list);
    container.appendChild(root);

    // ---- state ----
    var markers = initialMarkers.map(function (m) {
      return { t: m.t, text: m.text || "", frame: m.frame || null, blob: null, pinEl: null };
    });
    var openPopup = null; // {marker, el}
    var rafId = null;
    var dragging = false;
    var resizeObserver = null;
    var audioCtx = null;
    var destroyed = false;

    function duration() {
      var d = mediaEl.duration;
      return isFinite(d) && d > 0 ? d : 0;
    }

    function barRect() {
      return bar.getBoundingClientRect();
    }

    function timeFromClientX(clientX) {
      var rect = barRect();
      var frac = rect.width ? (clientX - rect.left) / rect.width : 0;
      frac = Math.min(1, Math.max(0, frac));
      return frac * duration();
    }

    function fracForTime(t) {
      var d = duration();
      return d ? Math.min(1, Math.max(0, t / d)) : 0;
    }

    // ---- ruler ----
    function renderRuler() {
      ruler.innerHTML = "";
      var d = duration();
      if (!d) return;
      var interval = niceTickInterval(d);
      for (var t = 0; t <= d; t += interval) {
        var frac = t / d;
        var tick = el("div", "ct-tick");
        tick.style.left = frac * 100 + "%";
        ruler.appendChild(tick);
        var label = el("div", "ct-tick-label");
        label.style.left = frac * 100 + "%";
        label.textContent = fmtTick(t);
        ruler.appendChild(label);
      }
    }

    // ---- playhead ----
    function renderPlayhead() {
      var frac = fracForTime(mediaEl.currentTime || 0);
      playhead.style.left = frac * 100 + "%";
    }

    function rafTick() {
      if (destroyed) return;
      renderPlayhead();
      if (!mediaEl.paused && !mediaEl.ended) {
        rafId = requestAnimationFrame(rafTick);
      } else {
        rafId = null;
      }
    }

    function onPlay() {
      if (rafId == null) rafId = requestAnimationFrame(rafTick);
    }
    function onPauseOrEnd() {
      if (rafId != null) {
        cancelAnimationFrame(rafId);
        rafId = null;
      }
      renderPlayhead();
    }
    function onTimeUpdate() {
      renderPlayhead();
      addBtn.textContent = "Add note at " + fmtTime(mediaEl.currentTime || 0);
    }
    function onSeeked() {
      renderPlayhead();
      addBtn.textContent = "Add note at " + fmtTime(mediaEl.currentTime || 0);
    }
    function onLoadedMeta() {
      renderRuler();
      renderPlayhead();
      renderMarkerPins();
      if (kind === "audio") loadWaveform();
    }

    mediaEl.addEventListener("play", onPlay);
    mediaEl.addEventListener("pause", onPauseOrEnd);
    mediaEl.addEventListener("ended", onPauseOrEnd);
    mediaEl.addEventListener("timeupdate", onTimeUpdate);
    mediaEl.addEventListener("seeked", onSeeked);
    mediaEl.addEventListener("loadedmetadata", onLoadedMeta);
    if (duration()) onLoadedMeta();

    // ---- seek by clicking/dragging the bar ----
    function seekFromEvent(e) {
      var t = timeFromClientX(e.clientX);
      mediaEl.currentTime = t;
      renderPlayhead();
    }
    function onBarPointerDown(e) {
      if (e.target !== bar && e.target !== ruler) return; // don't hijack pin clicks
      dragging = true;
      seekFromEvent(e);
      bar.setPointerCapture && bar.setPointerCapture(e.pointerId);
    }
    function onBarPointerMove(e) {
      if (!dragging) return;
      seekFromEvent(e);
    }
    function onBarPointerUp() {
      dragging = false;
    }
    bar.addEventListener("pointerdown", onBarPointerDown);
    bar.addEventListener("pointermove", onBarPointerMove);
    bar.addEventListener("pointerup", onBarPointerUp);
    bar.addEventListener("pointercancel", onBarPointerUp);

    function onBarKeydown(e) {
      var step = 1;
      if (e.key === "ArrowRight") {
        mediaEl.currentTime = Math.min(duration(), (mediaEl.currentTime || 0) + step);
        e.preventDefault();
      } else if (e.key === "ArrowLeft") {
        mediaEl.currentTime = Math.max(0, (mediaEl.currentTime || 0) - step);
        e.preventDefault();
      }
    }
    bar.addEventListener("keydown", onBarKeydown);

    // ---- waveform (audio) ----
    function loadWaveform() {
      if (kind !== "audio" || !mediaEl.currentSrc) return;
      // OfflineAudioContext decodes without opening an audio output device, so a
      // machine with no sound card (headless, WSL) still gets a waveform.
      var OfflineCtxClass = window.OfflineAudioContext || window.webkitOfflineAudioContext;
      if (!OfflineCtxClass) return;
      fetch(mediaEl.currentSrc)
        .then(function (r) {
          return r.arrayBuffer();
        })
        .then(function (buf) {
          if (destroyed) return;
          return new OfflineCtxClass(1, 1, 44100).decodeAudioData(buf);
        })
        .then(function (audioBuffer) {
          if (destroyed || !audioBuffer) return;
          waveformBuffer = audioBuffer;
          drawWaveform();
        })
        .catch(function () {
          // failure: plain bar, no crash
        });
    }

    var waveformBuffer = null;
    function drawWaveform() {
      if (!wave || !waveformBuffer) return;
      var w = barWrap.clientWidth || 1;
      var h = barWrap.clientHeight || 1;
      var dpr = window.devicePixelRatio || 1;
      wave.width = w * dpr;
      wave.height = h * dpr;
      wave.style.width = w + "px";
      wave.style.height = h + "px";
      waveCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
      waveCtx.clearRect(0, 0, w, h);
      var data = waveformBuffer.getChannelData(0);
      var samplesPerPixel = Math.max(1, Math.floor(data.length / w));
      waveCtx.fillStyle = getComputedStyle(root).getPropertyValue("--ct-wave") || "#9fa3ad";
      var mid = h / 2;
      for (var x = 0; x < w; x++) {
        var start = x * samplesPerPixel;
        var end = Math.min(data.length, start + samplesPerPixel);
        var min = 1, max = -1;
        for (var i = start; i < end; i++) {
          var v = data[i];
          if (v < min) min = v;
          if (v > max) max = v;
        }
        if (min > max) { min = 0; max = 0; }
        var y0 = mid + min * mid;
        var y1 = mid + max * mid;
        waveCtx.fillRect(x, y0, 1, Math.max(1, y1 - y0));
      }
    }

    if (kind === "audio" && typeof ResizeObserver !== "undefined") {
      resizeObserver = new ResizeObserver(function () {
        drawWaveform();
      });
      resizeObserver.observe(barWrap);
    }

    // ---- frame capture (video) ----
    function captureFrame(marker) {
      if (kind !== "video") return Promise.resolve();
      return new Promise(function (resolve) {
        function draw() {
          try {
            var w = mediaEl.videoWidth;
            var h = mediaEl.videoHeight;
            if (!w || !h) {
              resolve();
              return;
            }
            var canvas = document.createElement("canvas");
            canvas.width = w;
            canvas.height = h;
            var ctx = canvas.getContext("2d");
            ctx.drawImage(mediaEl, 0, 0, w, h);
            canvas.toBlob(function (blob) {
              marker.blob = blob;
              marker.frame = null; // pending, resolved on getMarkers()
              resolve();
            }, "image/png");
          } catch (err) {
            resolve(); // capture failure: no crash, leave frame null
          }
        }
        if (Math.abs((mediaEl.currentTime || 0) - marker.t) > 0.05) {
          var onSeekedOnce = function () {
            mediaEl.removeEventListener("seeked", onSeekedOnce);
            draw();
          };
          mediaEl.addEventListener("seeked", onSeekedOnce);
          mediaEl.currentTime = marker.t;
        } else {
          draw();
        }
      });
    }

    // ---- popup ----
    function closePopup() {
      if (openPopup) {
        openPopup.el.remove();
        openPopup = null;
      }
      document.removeEventListener("keydown", onDocKeydownForPopup, true);
    }
    function onDocKeydownForPopup(e) {
      if (e.key === "Escape" && openPopup) {
        closePopup();
      }
    }
    function openMarkerPopup(marker) {
      closePopup();
      var popup = el("div", "ct-popup", {
        role: "dialog",
        "aria-label": "Edit note at " + fmtTime(marker.t),
      });
      var timeLabel = el("div", "ct-popup-time");
      timeLabel.textContent = fmtTime(marker.t);
      var textarea = el("textarea", null, { "aria-label": "Note text" });
      textarea.value = marker.text || "";
      var actions = el("div", "ct-popup-actions");
      var delBtn = el("button", "ct-btn ct-btn-danger", { type: "button" });
      delBtn.textContent = "Delete";
      var doneBtn = el("button", "ct-btn", { type: "button" });
      doneBtn.textContent = "Done";
      actions.appendChild(delBtn);
      actions.appendChild(doneBtn);
      popup.appendChild(timeLabel);
      popup.appendChild(textarea);
      popup.appendChild(actions);

      var frac = fracForTime(marker.t);
      popup.style.left = frac * 100 + "%";
      barWrap.appendChild(popup);

      textarea.addEventListener("input", function () {
        marker.text = textarea.value;
      });
      delBtn.addEventListener("click", function () {
        deleteMarker(marker);
        closePopup();
      });
      doneBtn.addEventListener("click", function () {
        marker.text = textarea.value;
        closePopup();
        renderList();
      });
      popup.addEventListener("keydown", function (e) {
        if (e.key === "Escape") {
          closePopup();
        }
      });

      openPopup = { marker: marker, el: popup };
      document.addEventListener("keydown", onDocKeydownForPopup, true);
      textarea.focus();
    }

    // ---- markers: pins + list ----
    function renderMarkerPins() {
      markers.forEach(function (marker) {
        if (!marker.pinEl) {
          var pin = el("button", "ct-pin", {
            type: "button",
            "aria-label": "Note at " + fmtTime(marker.t),
          });
          pin.addEventListener("click", function (e) {
            e.stopPropagation();
            mediaEl.currentTime = marker.t;
            renderPlayhead();
            openMarkerPopup(marker);
          });
          bar.appendChild(pin);
          marker.pinEl = pin;
        }
        marker.pinEl.style.left = fracForTime(marker.t) * 100 + "%";
        marker.pinEl.setAttribute("aria-label", "Note at " + fmtTime(marker.t));
      });
    }

    function renderList() {
      list.innerHTML = "";
      var sorted = markers.slice().sort(function (a, b) {
        return a.t - b.t;
      });
      if (!sorted.length) {
        var empty = el("li", "ct-empty");
        empty.textContent = "No notes yet.";
        list.appendChild(empty);
        return;
      }
      sorted.forEach(function (marker) {
        var item = el("li", "ct-list-item", { tabindex: "0" });
        var timeEl = el("span", "ct-list-time");
        timeEl.textContent = fmtTime(marker.t);
        var textEl = el("span", "ct-list-text");
        textEl.textContent = marker.text || "";
        var delBtn = el("button", "ct-btn ct-btn-danger ct-list-del", {
          type: "button",
          "aria-label": "Delete note at " + fmtTime(marker.t),
        });
        delBtn.textContent = "Delete";
        item.appendChild(timeEl);
        item.appendChild(textEl);
        item.appendChild(delBtn);
        item.addEventListener("click", function (e) {
          if (e.target === delBtn) return;
          mediaEl.currentTime = marker.t;
          renderPlayhead();
          openMarkerPopup(marker);
        });
        delBtn.addEventListener("click", function (e) {
          e.stopPropagation();
          deleteMarker(marker);
        });
        list.appendChild(item);
      });
    }

    function deleteMarker(marker) {
      var idx = markers.indexOf(marker);
      if (idx !== -1) markers.splice(idx, 1);
      if (marker.pinEl) marker.pinEl.remove();
      renderList();
    }

    function addMarkerAtCurrentTime() {
      var t = mediaEl.currentTime || 0;
      var marker = { t: t, text: "", frame: null, blob: null, pinEl: null };
      markers.push(marker);
      renderMarkerPins();
      renderList();
      openMarkerPopup(marker);
      if (kind === "video") {
        captureFrame(marker);
      }
    }

    addBtn.addEventListener("click", addMarkerAtCurrentTime);

    function onKeyM(e) {
      if (e.key !== "m" && e.key !== "M") return;
      if (isTextEntryTarget(e.target)) return;
      e.preventDefault();
      addMarkerAtCurrentTime();
    }
    container.addEventListener("keydown", onKeyM);
    mediaEl.addEventListener("keydown", onKeyM);

    renderMarkerPins();
    renderList();

    // ---- public API ----
    function getMarkers() {
      var uploads = markers
        .filter(function (m) {
          return m.blob && !m.frame;
        })
        .map(function (m) {
          return fetch("/api/upload?kind=frame", {
            method: "POST",
            headers: { "Content-Type": "image/png" },
            body: m.blob,
          }).then(function (res) {
            if (!res.ok) {
              return res
                .json()
                .catch(function () {
                  return {};
                })
                .then(function (body) {
                  throw new Error(body.error || "Frame upload failed (" + res.status + ")");
                });
            }
            return res.json().then(function (body) {
              m.frame = body.path;
              m.blob = null;
            });
          });
        });
      return Promise.all(uploads).then(function () {
        return markers
          .slice()
          .sort(function (a, b) {
            return a.t - b.t;
          })
          .map(function (m) {
            return {
              t: Math.round(m.t * 10) / 10,
              text: m.text || "",
              frame: m.frame || null,
            };
          });
      });
    }

    function destroy() {
      destroyed = true;
      if (rafId != null) cancelAnimationFrame(rafId);
      closePopup();
      mediaEl.removeEventListener("play", onPlay);
      mediaEl.removeEventListener("pause", onPauseOrEnd);
      mediaEl.removeEventListener("ended", onPauseOrEnd);
      mediaEl.removeEventListener("timeupdate", onTimeUpdate);
      mediaEl.removeEventListener("seeked", onSeeked);
      mediaEl.removeEventListener("loadedmetadata", onLoadedMeta);
      mediaEl.removeEventListener("keydown", onKeyM);
      container.removeEventListener("keydown", onKeyM);
      bar.removeEventListener("pointerdown", onBarPointerDown);
      bar.removeEventListener("pointermove", onBarPointerMove);
      bar.removeEventListener("pointerup", onBarPointerUp);
      bar.removeEventListener("pointercancel", onBarPointerUp);
      bar.removeEventListener("keydown", onBarKeydown);
      if (resizeObserver) resizeObserver.disconnect();
      if (audioCtx && audioCtx.close) audioCtx.close();
      root.remove();
    }

    return { getMarkers: getMarkers, destroy: destroy };
  }

  window.ClouterTimeline = { mount: mount };
})();
