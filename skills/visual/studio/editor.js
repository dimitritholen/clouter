/**
 * Clouter studio — image annotation editor.
 *
 * Self-contained vanilla JS. Injects its own <style> (class prefix `ce-`),
 * uses CSS custom properties with light/dark support via prefers-color-scheme.
 * No CDN, no build step, no dependencies.
 *
 * Public API:
 *   window.ClouterEditor.open(imgUrl, {notes = []} = {}) -> Promise<
 *     {annotation: "uploads/…png" | null, notes: [{n, x, y, text}]} | null
 *   >
 *   Resolves with the result object on Save, resolves with `null` on
 *   Cancel/Escape.
 */
(function () {
  'use strict';

  var STYLE_ID = 'ce-styles';
  var SWATCHES = ['#ff2d2d', '#ffe400', '#2ecc40', '#00e5ff', '#2979ff', '#ff2df0', '#ffffff', '#000000'];

  function injectStyles() {
    if (document.getElementById(STYLE_ID)) return;
    var style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = [
      ':root {',
      '  --ce-bg: #1c1c1e;',
      '  --ce-panel: #2c2c2e;',
      '  --ce-panel-border: #3a3a3c;',
      '  --ce-text: #f2f2f7;',
      '  --ce-text-dim: #a1a1a6;',
      '  --ce-accent: #0a84ff;',
      '  --ce-danger: #ff453a;',
      '  --ce-btn-bg: #3a3a3c;',
      '  --ce-btn-bg-hover: #48484a;',
      '  --ce-btn-active-bg: #0a84ff;',
      '  --ce-canvas-bg: #000000;',
      '  --ce-pin-bg: #0a84ff;',
      '  --ce-pin-text: #ffffff;',
      '  --ce-popup-bg: #2c2c2e;',
      '}',
      '@media (prefers-color-scheme: light) {',
      '  :root {',
      '    --ce-bg: #f2f2f7;',
      '    --ce-panel: #ffffff;',
      '    --ce-panel-border: #d1d1d6;',
      '    --ce-text: #1c1c1e;',
      '    --ce-text-dim: #6e6e73;',
      '    --ce-accent: #007aff;',
      '    --ce-danger: #ff3b30;',
      '    --ce-btn-bg: #e5e5ea;',
      '    --ce-btn-bg-hover: #d1d1d6;',
      '    --ce-btn-active-bg: #007aff;',
      '    --ce-canvas-bg: #1c1c1e;',
      '    --ce-pin-bg: #007aff;',
      '    --ce-pin-text: #ffffff;',
      '    --ce-popup-bg: #ffffff;',
      '  }',
      '}',
      '.ce-overlay {',
      '  position: fixed; inset: 0; z-index: 2147483000;',
      '  background: var(--ce-bg); color: var(--ce-text);',
      '  display: flex; flex-direction: column;',
      '  font: 13px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;',
      '  user-select: none;',
      '}',
      '.ce-toolbar {',
      '  display: flex; align-items: center; gap: 6px; flex-wrap: wrap;',
      '  padding: 8px 10px; background: var(--ce-panel);',
      '  border-bottom: 1px solid var(--ce-panel-border);',
      '  z-index: 2;',
      '}',
      '.ce-btn {',
      '  display: inline-flex; align-items: center; justify-content: center;',
      '  min-width: 34px; height: 34px; padding: 0 10px;',
      '  background: var(--ce-btn-bg); color: var(--ce-text);',
      '  border: 1px solid transparent; border-radius: 7px;',
      '  cursor: pointer; font-size: 13px;',
      '}',
      '.ce-btn:hover { background: var(--ce-btn-bg-hover); }',
      '.ce-btn:focus-visible { outline: 2px solid var(--ce-accent); outline-offset: 1px; }',
      '.ce-btn[aria-pressed="true"] {',
      '  background: var(--ce-btn-active-bg); color: #fff;',
      '}',
      '.ce-btn:disabled { opacity: .4; cursor: default; }',
      '.ce-btn-primary { background: var(--ce-accent); color: #fff; }',
      '.ce-btn-danger-outline { color: var(--ce-danger); }',
      '.ce-sep { width: 1px; align-self: stretch; background: var(--ce-panel-border); margin: 0 4px; }',
      '.ce-spacer { flex: 1 1 auto; }',
      '.ce-width-wrap { display: flex; align-items: center; gap: 6px; }',
      '.ce-width-preview {',
      '  width: 26px; height: 26px; display: flex; align-items: center; justify-content: center;',
      '}',
      '.ce-width-dot { border-radius: 50%; background: var(--ce-text); }',
      '.ce-range { width: 100px; accent-color: var(--ce-accent); }',
      '.ce-color-btn {',
      '  width: 28px; height: 28px; border-radius: 50%;',
      '  border: 2px solid var(--ce-panel-border); cursor: pointer; padding: 0;',
      '}',
      '.ce-color-btn:focus-visible { outline: 2px solid var(--ce-accent); outline-offset: 2px; }',
      '.ce-stage {',
      '  position: relative; flex: 1 1 auto; overflow: hidden;',
      '  display: flex; align-items: center; justify-content: center;',
      '  min-height: 0;',
      '}',
      '.ce-stage-inner { position: relative; }',
      '.ce-stage-inner img, .ce-stage-inner canvas.ce-draw {',
      '  position: absolute; top: 0; left: 0; width: 100%; height: 100%;',
      '  display: block;',
      '}',
      '.ce-stage-inner img { pointer-events: none; }',
      '.ce-draw { touch-action: none; cursor: crosshair; }',
      '.ce-pins { position: absolute; inset: 0; pointer-events: none; }',
      '.ce-pin {',
      '  position: absolute; width: 24px; height: 24px; margin: -12px 0 0 -12px;',
      '  border-radius: 50% 50% 50% 0; transform: rotate(-45deg);',
      '  background: var(--ce-pin-bg); color: var(--ce-pin-text);',
      '  display: flex; align-items: center; justify-content: center;',
      '  font-size: 11px; font-weight: 600; cursor: grab; pointer-events: auto;',
      '  box-shadow: 0 1px 4px rgba(0,0,0,.4);',
      '  touch-action: none;',
      '}',
      '.ce-pin > span { transform: rotate(45deg); }',
      '.ce-pin:active { cursor: grabbing; }',
      '.ce-pin:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }',
      '.ce-popup {',
      '  position: absolute; width: 220px; padding: 8px;',
      '  background: var(--ce-popup-bg); border: 1px solid var(--ce-panel-border);',
      '  border-radius: 8px; box-shadow: 0 6px 24px rgba(0,0,0,.35);',
      '  pointer-events: auto; z-index: 3; color: var(--ce-text);',
      '}',
      '.ce-popup-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }',
      '.ce-popup-head span { font-weight: 600; }',
      '.ce-popup-x {',
      '  background: none; border: none; color: var(--ce-text-dim); cursor: pointer;',
      '  font-size: 16px; line-height: 1; padding: 2px 4px; border-radius: 4px;',
      '}',
      '.ce-popup-x:hover { background: var(--ce-btn-bg); color: var(--ce-danger); }',
      '.ce-popup textarea {',
      '  width: 100%; min-height: 54px; resize: vertical; box-sizing: border-box;',
      '  background: var(--ce-bg); color: var(--ce-text); border: 1px solid var(--ce-panel-border);',
      '  border-radius: 6px; padding: 6px; font: inherit;',
      '}',
      '.ce-color-pop {',
      '  position: absolute; top: 44px; left: 8px; z-index: 4;',
      '  background: var(--ce-popup-bg); border: 1px solid var(--ce-panel-border);',
      '  border-radius: 10px; padding: 10px; box-shadow: 0 6px 24px rgba(0,0,0,.35);',
      '  display: flex; flex-direction: column; gap: 8px; width: 190px;',
      '}',
      '.ce-color-pop[hidden] { display: none; }',
      '.ce-wheel-wrap { position: relative; width: 160px; height: 160px; align-self: center; }',
      '.ce-wheel { border-radius: 50%; cursor: crosshair; touch-action: none; }',
      '.ce-wheel-handle {',
      '  position: absolute; width: 14px; height: 14px; margin: -7px 0 0 -7px;',
      '  border-radius: 50%; border: 2px solid #fff; box-shadow: 0 0 0 1px rgba(0,0,0,.5);',
      '  pointer-events: none;',
      '}',
      '.ce-swatches { display: flex; flex-wrap: wrap; gap: 6px; }',
      '.ce-swatch {',
      '  width: 20px; height: 20px; border-radius: 50%; cursor: pointer;',
      '  border: 1px solid var(--ce-panel-border); padding: 0;',
      '}',
      '.ce-swatch:focus-visible { outline: 2px solid var(--ce-accent); outline-offset: 2px; }',
      '.ce-error {',
      '  position: absolute; bottom: 10px; left: 50%; transform: translateX(-50%);',
      '  background: var(--ce-danger); color: #fff; padding: 8px 14px; border-radius: 8px;',
      '  font-size: 12px; max-width: 80%; text-align: center; z-index: 5;',
      '}',
      '.ce-vh { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }',
    ].join('\n');
    document.head.appendChild(style);
  }

  // ---- colour helpers -------------------------------------------------

  function hsvToRgb(h, s, v) {
    var c = v * s;
    var x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    var m = v - c;
    var r, g, b;
    if (h < 60) { r = c; g = x; b = 0; }
    else if (h < 120) { r = x; g = c; b = 0; }
    else if (h < 180) { r = 0; g = c; b = x; }
    else if (h < 240) { r = 0; g = x; b = c; }
    else if (h < 300) { r = x; g = 0; b = c; }
    else { r = c; g = 0; b = x; }
    return [
      Math.round((r + m) * 255),
      Math.round((g + m) * 255),
      Math.round((b + m) * 255),
    ];
  }

  function rgbToHex(r, g, b) {
    return '#' + [r, g, b].map(function (n) {
      return n.toString(16).padStart(2, '0');
    }).join('');
  }

  function hexToRgb(hex) {
    var m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);
    if (!m) return [255, 0, 0];
    return [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)];
  }

  // rough rgb -> hsv, used only to sync the wheel when a swatch is clicked
  function rgbToHsv(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b);
    var d = max - min;
    var h = 0;
    if (d !== 0) {
      if (max === r) h = 60 * (((g - b) / d) % 6);
      else if (max === g) h = 60 * ((b - r) / d + 2);
      else h = 60 * ((r - g) / d + 4);
    }
    if (h < 0) h += 360;
    var s = max === 0 ? 0 : d / max;
    var v = max;
    return [h, s, v];
  }

  // ---- main -------------------------------------------------------------

  function open(imgUrl, opts) {
    opts = opts || {};
    var initialNotes = Array.isArray(opts.notes) ? opts.notes : [];

    injectStyles();

    return new Promise(function (resolve) {
      var settled = false;
      function finish(result) {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(result);
      }

      // ---- state ----
      var tool = 'pen'; // 'pen' | 'eraser' | 'note'
      var color = '#ff2d2d';
      var lineWidth = 8; // image pixels
      var strokes = []; // {tool, color, width, points:[{x,y}]}
      var redoStack = [];
      var currentStroke = null;
      var notes = initialNotes.map(function (n, i) {
        return { n: typeof n.n === 'number' ? n.n : i + 1, x: n.x, y: n.y, text: n.text || '' };
      });
      var nextNoteN = notes.reduce(function (m, n) { return Math.max(m, n.n); }, 0) + 1;
      var activePopup = null; // note object whose popup is open
      var uploading = false;

      var previouslyFocused = document.activeElement;

      // ---- DOM scaffold ----
      var overlay = document.createElement('div');
      overlay.className = 'ce-overlay';
      overlay.setAttribute('role', 'dialog');
      overlay.setAttribute('aria-modal', 'true');
      overlay.setAttribute('aria-label', 'Image annotation editor');

      var toolbar = document.createElement('div');
      toolbar.className = 'ce-toolbar';
      overlay.appendChild(toolbar);

      function makeBtn(label, title, opts2) {
        opts2 = opts2 || {};
        var b = document.createElement('button');
        b.type = 'button';
        b.className = 'ce-btn' + (opts2.extraClass ? ' ' + opts2.extraClass : '');
        b.textContent = label;
        b.title = title;
        b.setAttribute('aria-label', title);
        toolbar.appendChild(b);
        return b;
      }

      var penBtn = makeBtn('✏️ Pen', 'Pen (P)');
      var eraserBtn = makeBtn('🧽 Eraser', 'Eraser (E)');
      var noteBtn = makeBtn('📌 Note', 'Add note (N)');

      var sep1 = document.createElement('div');
      sep1.className = 'ce-sep';
      toolbar.appendChild(sep1);

      var colorBtn = document.createElement('button');
      colorBtn.type = 'button';
      colorBtn.className = 'ce-color-btn';
      colorBtn.title = 'Colour';
      colorBtn.setAttribute('aria-label', 'Choose colour');
      colorBtn.style.background = color;
      toolbar.appendChild(colorBtn);

      var widthWrap = document.createElement('div');
      widthWrap.className = 'ce-width-wrap';
      var widthLabel = document.createElement('label');
      widthLabel.className = 'ce-vh';
      widthLabel.textContent = 'Line width';
      widthLabel.setAttribute('for', 'ce-width-range');
      var widthRange = document.createElement('input');
      widthRange.type = 'range';
      widthRange.id = 'ce-width-range';
      widthRange.className = 'ce-range';
      widthRange.min = '1';
      widthRange.max = '64';
      widthRange.title = 'Line width';
      widthRange.setAttribute('aria-label', 'Line width');
      var widthPreviewWrap = document.createElement('div');
      widthPreviewWrap.className = 'ce-width-preview';
      var widthDot = document.createElement('div');
      widthDot.className = 'ce-width-dot';
      widthPreviewWrap.appendChild(widthDot);
      widthWrap.appendChild(widthLabel);
      widthWrap.appendChild(widthRange);
      widthWrap.appendChild(widthPreviewWrap);
      toolbar.appendChild(widthWrap);

      var sep2 = document.createElement('div');
      sep2.className = 'ce-sep';
      toolbar.appendChild(sep2);

      var undoBtn = makeBtn('↶ Undo', 'Undo (Ctrl+Z)');
      var redoBtn = makeBtn('↷ Redo', 'Redo (Ctrl+Shift+Z)');
      var clearBtn = makeBtn('🗑 Clear', 'Clear all', { extraClass: 'ce-btn-danger-outline' });

      var spacer = document.createElement('div');
      spacer.className = 'ce-spacer';
      toolbar.appendChild(spacer);

      var cancelBtn = makeBtn('Cancel', 'Cancel (Esc)');
      var saveBtn = makeBtn('Save', 'Save annotation', { extraClass: 'ce-btn-primary' });

      // ---- colour popover ----
      var colorPop = document.createElement('div');
      colorPop.className = 'ce-color-pop';
      colorPop.hidden = true;
      colorPop.style.position = 'absolute';

      var wheelWrap = document.createElement('div');
      wheelWrap.className = 'ce-wheel-wrap';
      var wheelCanvas = document.createElement('canvas');
      wheelCanvas.className = 'ce-wheel';
      wheelCanvas.width = 160;
      wheelCanvas.height = 160;
      var wheelHandle = document.createElement('div');
      wheelHandle.className = 'ce-wheel-handle';
      wheelWrap.appendChild(wheelCanvas);
      wheelWrap.appendChild(wheelHandle);

      var valueLabel = document.createElement('label');
      valueLabel.className = 'ce-vh';
      valueLabel.textContent = 'Brightness';
      valueLabel.setAttribute('for', 'ce-value-range');
      var valueRange = document.createElement('input');
      valueRange.type = 'range';
      valueRange.id = 'ce-value-range';
      valueRange.className = 'ce-range';
      valueRange.min = '0';
      valueRange.max = '100';
      valueRange.value = '100';
      valueRange.style.width = '100%';
      valueRange.title = 'Brightness';
      valueRange.setAttribute('aria-label', 'Brightness');

      var swatchesWrap = document.createElement('div');
      swatchesWrap.className = 'ce-swatches';
      SWATCHES.forEach(function (hex) {
        var sw = document.createElement('button');
        sw.type = 'button';
        sw.className = 'ce-swatch';
        sw.style.background = hex;
        sw.title = hex;
        sw.setAttribute('aria-label', 'Colour ' + hex);
        sw.addEventListener('click', function () { setColor(hex, true); colorPop.hidden = true; });
        swatchesWrap.appendChild(sw);
      });

      colorPop.appendChild(wheelWrap);
      colorPop.appendChild(valueLabel);
      colorPop.appendChild(valueRange);
      colorPop.appendChild(swatchesWrap);
      toolbar.appendChild(colorPop);

      var hsvHue = 0, hsvSat = 1, hsvVal = 1;

      function drawWheel() {
        var ctx = wheelCanvas.getContext('2d');
        var w = wheelCanvas.width, h = wheelCanvas.height;
        var cx = w / 2, cy = h / 2, r = w / 2;
        var img = ctx.createImageData(w, h);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            var dx = x - cx, dy = y - cy;
            var dist = Math.sqrt(dx * dx + dy * dy);
            var idx = (y * w + x) * 4;
            if (dist > r) {
              img.data[idx + 3] = 0;
              continue;
            }
            var ang = Math.atan2(dy, dx) * 180 / Math.PI;
            if (ang < 0) ang += 360;
            var sat = Math.min(1, dist / r);
            var rgb = hsvToRgb(ang, sat, hsvVal);
            img.data[idx] = rgb[0];
            img.data[idx + 1] = rgb[1];
            img.data[idx + 2] = rgb[2];
            img.data[idx + 3] = 255;
          }
        }
        ctx.putImageData(img, 0, 0);
      }

      function positionHandle() {
        var r = wheelCanvas.width / 2;
        var ang = hsvHue * Math.PI / 180;
        var dist = hsvSat * r;
        var x = r + Math.cos(ang) * dist;
        var y = r + Math.sin(ang) * dist;
        wheelHandle.style.left = x + 'px';
        wheelHandle.style.top = y + 'px';
      }

      function applyHsv() {
        var rgb = hsvToRgb(hsvHue, hsvSat, hsvVal);
        setColor(rgbToHex(rgb[0], rgb[1], rgb[2]), false);
        positionHandle();
      }

      function setColor(hex, syncWheel) {
        color = hex;
        colorBtn.style.background = hex;
        if (syncWheel) {
          var rgb = hexToRgb(hex);
          var hsv = rgbToHsv(rgb[0], rgb[1], rgb[2]);
          hsvHue = hsv[0]; hsvSat = hsv[1]; hsvVal = hsv[2];
          valueRange.value = String(Math.round(hsvVal * 100));
          drawWheel();
          positionHandle();
        }
      }

      function wheelPointFromEvent(ev) {
        var rect = wheelCanvas.getBoundingClientRect();
        var x = ev.clientX - rect.left;
        var y = ev.clientY - rect.top;
        var r = wheelCanvas.width / 2;
        var dx = x - r, dy = y - r;
        var dist = Math.min(r, Math.sqrt(dx * dx + dy * dy));
        var ang = Math.atan2(dy, dx) * 180 / Math.PI;
        if (ang < 0) ang += 360;
        hsvHue = ang;
        hsvSat = r === 0 ? 0 : dist / r;
        applyHsv();
      }

      var wheelDragging = false;
      wheelCanvas.addEventListener('pointerdown', function (ev) {
        wheelDragging = true;
        wheelCanvas.setPointerCapture(ev.pointerId);
        wheelPointFromEvent(ev);
      });
      wheelCanvas.addEventListener('pointermove', function (ev) {
        if (wheelDragging) wheelPointFromEvent(ev);
      });
      wheelCanvas.addEventListener('pointerup', function (ev) {
        wheelDragging = false;
        try { wheelCanvas.releasePointerCapture(ev.pointerId); } catch (e) {}
      });

      valueRange.addEventListener('input', function () {
        hsvVal = valueRange.value / 100;
        drawWheel();
        applyHsv();
      });

      colorBtn.addEventListener('click', function (ev) {
        ev.stopPropagation();
        colorPop.hidden = !colorPop.hidden;
      });
      document.addEventListener('pointerdown', outsideColorPop, true);
      function outsideColorPop(ev) {
        if (!colorPop.hidden && !colorPop.contains(ev.target) && ev.target !== colorBtn) {
          colorPop.hidden = true;
        }
      }

      // ---- width preview ----
      function updateWidthPreview() {
        var d = Math.max(2, Math.min(26, lineWidth));
        widthDot.style.width = d + 'px';
        widthDot.style.height = d + 'px';
      }
      widthRange.addEventListener('input', function () {
        lineWidth = Number(widthRange.value);
        updateWidthPreview();
      });

      // ---- stage / canvas ----
      var stage = document.createElement('div');
      stage.className = 'ce-stage';
      overlay.appendChild(stage);

      var stageInner = document.createElement('div');
      stageInner.className = 'ce-stage-inner';
      stage.appendChild(stageInner);

      var imgEl = document.createElement('img');
      imgEl.alt = '';
      stageInner.appendChild(imgEl);

      var drawCanvas = document.createElement('canvas');
      drawCanvas.className = 'ce-draw';
      stageInner.appendChild(drawCanvas);

      var pinsLayer = document.createElement('div');
      pinsLayer.className = 'ce-pins';
      stageInner.appendChild(pinsLayer);

      var errorBox = null;
      function showError(msg) {
        if (errorBox) errorBox.remove();
        errorBox = document.createElement('div');
        errorBox.className = 'ce-error';
        errorBox.setAttribute('role', 'alert');
        errorBox.textContent = msg;
        stage.appendChild(errorBox);
      }
      function clearError() {
        if (errorBox) { errorBox.remove(); errorBox = null; }
      }

      document.body.appendChild(overlay);

      // ---- layout ----
      function layout() {
        var stageRect = stage.getBoundingClientRect();
        var padding = 20;
        var maxW = Math.max(50, stageRect.width - padding * 2);
        var maxH = Math.max(50, stageRect.height - padding * 2);
        var nw = drawCanvas.width || 1;
        var nh = drawCanvas.height || 1;
        var scale = Math.min(maxW / nw, maxH / nh, 1);
        // allow upscaling small images to fill available space too, but cap sanely
        scale = Math.min(maxW / nw, maxH / nh);
        var cssW = nw * scale;
        var cssH = nh * scale;
        stageInner.style.width = cssW + 'px';
        stageInner.style.height = cssH + 'px';
      }
      window.addEventListener('resize', layout);

      // ---- load image ----
      var naturalWidth = 0, naturalHeight = 0;
      var ready = new Promise(function (res, rej) {
        imgEl.onerror = function () { rej(new Error('image failed to load')); };
        imgEl.src = imgUrl;
        if (imgEl.decode) {
          imgEl.decode().then(function () { res(); }).catch(function () {
            // fall back to load event
            imgEl.onload = function () { res(); };
          });
        } else {
          imgEl.onload = function () { res(); };
        }
      });

      // Canvas pixel size: the natural size when its long edge is at least
      // MIN_LONG_EDGE, otherwise scaled up to that long edge. SVGs often have
      // no usable intrinsic size (Chromium reports a 150x150 fallback), so
      // their aspect ratio comes from a laid-out probe of the same image.
      var MIN_LONG_EDGE = 1024;

      function isSvgWithoutSize(nw, nh) {
        var path = String(imgUrl).split(/[?#]/)[0].toLowerCase();
        return !nw || !nh || (nw === 150 && nh === 150) || /\.svg$/.test(path);
      }

      function svgAspect() {
        // imgEl itself is sized by the canvas (100% of .ce-stage-inner), so it
        // cannot tell us the ratio; lay out a detached probe at a fixed width
        // and let the browser derive the height from the SVG's viewBox.
        var probe = document.createElement('img');
        probe.alt = '';
        probe.style.cssText = 'position:absolute;left:-99999px;top:0;visibility:hidden;' +
          'width:' + MIN_LONG_EDGE + 'px;height:auto;max-width:none;max-height:none;';
        probe.src = imgEl.currentSrc || imgEl.src;
        document.body.appendChild(probe);
        var r = probe.getBoundingClientRect();
        probe.remove();
        // A height of exactly 150 is the no-intrinsic-ratio fallback, not a ratio.
        if (r.width > 0 && r.height > 0 && r.height !== 150) return r.width / r.height;
        return 1;
      }

      function canvasSize() {
        var nw = imgEl.naturalWidth || imgEl.width;
        var nh = imgEl.naturalHeight || imgEl.height;
        if (nw && nh && Math.max(nw, nh) >= MIN_LONG_EDGE) return { w: nw, h: nh };
        var aspect = isSvgWithoutSize(nw, nh) ? svgAspect() : nw / nh;
        if (aspect >= 1) return { w: MIN_LONG_EDGE, h: Math.max(1, Math.round(MIN_LONG_EDGE / aspect)) };
        return { w: Math.max(1, Math.round(MIN_LONG_EDGE * aspect)), h: MIN_LONG_EDGE };
      }

      ready.then(function () {
        var size = canvasSize();
        naturalWidth = size.w;
        naturalHeight = size.h;
        drawCanvas.width = naturalWidth;
        drawCanvas.height = naturalHeight;
        lineWidth = Math.max(1, Math.round(Math.max(naturalWidth, naturalHeight) * 0.004));
        widthRange.value = String(lineWidth);
        updateWidthPreview();
        layout();
        renderAll();
        renderNotes();
        drawWheel();
        setColor(color, true);
        // focus trap init
        overlay.tabIndex = -1;
        overlay.focus();
      }).catch(function (err) {
        showError('Could not load image: ' + err.message);
      });

      var drawCtx = drawCanvas.getContext('2d');

      function renderAll() {
        drawCtx.clearRect(0, 0, drawCanvas.width, drawCanvas.height);
        strokes.forEach(renderStroke);
      }

      function renderStroke(s) {
        var pts = s.points;
        if (!pts.length) return;
        drawCtx.save();
        drawCtx.lineCap = 'round';
        drawCtx.lineJoin = 'round';
        drawCtx.lineWidth = s.width;
        if (s.tool === 'eraser') {
          drawCtx.globalCompositeOperation = 'destination-out';
          drawCtx.strokeStyle = 'rgba(0,0,0,1)';
        } else {
          drawCtx.globalCompositeOperation = 'source-over';
          drawCtx.strokeStyle = s.color;
        }
        if (pts.length === 1) {
          drawCtx.beginPath();
          drawCtx.arc(pts[0].x, pts[0].y, s.width / 2, 0, Math.PI * 2);
          drawCtx.fillStyle = drawCtx.strokeStyle;
          drawCtx.fill();
          drawCtx.restore();
          return;
        }
        drawCtx.beginPath();
        drawCtx.moveTo(pts[0].x, pts[0].y);
        for (var i = 1; i < pts.length - 1; i++) {
          var mx = (pts[i].x + pts[i + 1].x) / 2;
          var my = (pts[i].y + pts[i + 1].y) / 2;
          drawCtx.quadraticCurveTo(pts[i].x, pts[i].y, mx, my);
        }
        var last = pts[pts.length - 1];
        drawCtx.lineTo(last.x, last.y);
        drawCtx.stroke();
        drawCtx.restore();
      }

      function canvasPointFromEvent(ev) {
        var rect = drawCanvas.getBoundingClientRect();
        var sx = drawCanvas.width / rect.width;
        var sy = drawCanvas.height / rect.height;
        return {
          x: (ev.clientX - rect.left) * sx,
          y: (ev.clientY - rect.top) * sy,
        };
      }

      var drawing = false;
      drawCanvas.addEventListener('pointerdown', function (ev) {
        if (tool === 'note') return; // note tool handled by click below
        if (ev.button !== undefined && ev.button !== 0 && ev.pointerType === 'mouse') return;
        drawing = true;
        drawCanvas.setPointerCapture(ev.pointerId);
        var p = canvasPointFromEvent(ev);
        currentStroke = { tool: tool, color: color, width: lineWidth, points: [p] };
        redoStack = [];
        updateUndoRedoButtons();
        renderStroke(currentStroke);
        ev.preventDefault();
      });
      drawCanvas.addEventListener('pointermove', function (ev) {
        if (!drawing || !currentStroke) return;
        var p = canvasPointFromEvent(ev);
        currentStroke.points.push(p);
        renderAll();
        renderStroke(currentStroke);
        ev.preventDefault();
      });
      function endStroke(ev) {
        if (!drawing) return;
        drawing = false;
        if (currentStroke) {
          strokes.push(currentStroke);
          currentStroke = null;
          updateUndoRedoButtons();
        }
        try { drawCanvas.releasePointerCapture(ev.pointerId); } catch (e) {}
      }
      drawCanvas.addEventListener('pointerup', endStroke);
      drawCanvas.addEventListener('pointercancel', endStroke);

      drawCanvas.addEventListener('click', function (ev) {
        if (tool !== 'note') return;
        var rect = drawCanvas.getBoundingClientRect();
        var x = (ev.clientX - rect.left) / rect.width;
        var y = (ev.clientY - rect.top) / rect.height;
        x = Math.min(1, Math.max(0, x));
        y = Math.min(1, Math.max(0, y));
        var note = { n: nextNoteN++, x: x, y: y, text: '' };
        notes.push(note);
        renderNotes();
        openPopup(note, true);
      });

      // ---- undo/redo/clear ----
      function undo() {
        if (!strokes.length) return;
        redoStack.push(strokes.pop());
        renderAll();
        updateUndoRedoButtons();
      }
      function redo() {
        if (!redoStack.length) return;
        strokes.push(redoStack.pop());
        renderAll();
        updateUndoRedoButtons();
      }
      function clearAll() {
        if (!strokes.length) return;
        redoStack = [];
        strokes = [];
        renderAll();
        updateUndoRedoButtons();
      }
      function updateUndoRedoButtons() {
        undoBtn.disabled = strokes.length === 0;
        redoBtn.disabled = redoStack.length === 0;
      }
      updateUndoRedoButtons();

      undoBtn.addEventListener('click', undo);
      redoBtn.addEventListener('click', redo);
      clearBtn.addEventListener('click', clearAll);

      // ---- tools ----
      function setTool(t) {
        tool = t;
        [penBtn, eraserBtn, noteBtn].forEach(function (b) { b.setAttribute('aria-pressed', 'false'); });
        if (t === 'pen') penBtn.setAttribute('aria-pressed', 'true');
        if (t === 'eraser') eraserBtn.setAttribute('aria-pressed', 'true');
        if (t === 'note') noteBtn.setAttribute('aria-pressed', 'true');
        drawCanvas.style.cursor = t === 'note' ? 'copy' : 'crosshair';
      }
      penBtn.addEventListener('click', function () { setTool('pen'); });
      eraserBtn.addEventListener('click', function () { setTool('eraser'); });
      noteBtn.addEventListener('click', function () { setTool('note'); });
      setTool('pen');

      // ---- notes rendering ----
      function renderNotes() {
        pinsLayer.innerHTML = '';
        notes.forEach(function (note) {
          var pin = document.createElement('div');
          pin.className = 'ce-pin';
          pin.style.left = (note.x * 100) + '%';
          pin.style.top = (note.y * 100) + '%';
          pin.tabIndex = 0;
          pin.setAttribute('role', 'button');
          pin.setAttribute('aria-label', 'Note ' + note.n + (note.text ? ': ' + note.text : ''));
          var span = document.createElement('span');
          span.textContent = String(note.n);
          pin.appendChild(span);

          var dragging = false, moved = false;
          pin.addEventListener('pointerdown', function (ev) {
            dragging = true;
            moved = false;
            pin.setPointerCapture(ev.pointerId);
            ev.stopPropagation();
          });
          pin.addEventListener('pointermove', function (ev) {
            if (!dragging) return;
            moved = true;
            var rect = stageInner.getBoundingClientRect();
            var x = (ev.clientX - rect.left) / rect.width;
            var y = (ev.clientY - rect.top) / rect.height;
            note.x = Math.min(1, Math.max(0, x));
            note.y = Math.min(1, Math.max(0, y));
            pin.style.left = (note.x * 100) + '%';
            pin.style.top = (note.y * 100) + '%';
            if (activePopup === note) positionPopup(note);
          });
          function endDrag(ev) {
            if (!dragging) return;
            dragging = false;
            try { pin.releasePointerCapture(ev.pointerId); } catch (e) {}
            if (!moved) openPopup(note, false);
          }
          pin.addEventListener('pointerup', endDrag);
          pin.addEventListener('pointercancel', endDrag);
          pin.addEventListener('keydown', function (ev) {
            if (ev.key === 'Enter' || ev.key === ' ') {
              ev.preventDefault();
              openPopup(note, false);
            }
          });

          pinsLayer.appendChild(pin);
        });
      }

      function positionPopup(note) {
        if (!activePopupEl) return;
        activePopupEl.style.left = (note.x * 100) + '%';
        activePopupEl.style.top = (note.y * 100) + '%';
      }

      var activePopupEl = null;
      function closePopup() {
        if (activePopupEl) { activePopupEl.remove(); activePopupEl = null; }
        activePopup = null;
      }
      function openPopup(note, focusText) {
        closePopup();
        activePopup = note;
        var pop = document.createElement('div');
        pop.className = 'ce-popup';
        pop.style.left = (note.x * 100) + '%';
        pop.style.top = (note.y * 100) + '%';

        var head = document.createElement('div');
        head.className = 'ce-popup-head';
        var title = document.createElement('span');
        title.textContent = 'Note ' + note.n;
        var closeX = document.createElement('button');
        closeX.type = 'button';
        closeX.className = 'ce-popup-x';
        closeX.textContent = '×';
        closeX.title = 'Delete note';
        closeX.setAttribute('aria-label', 'Delete note ' + note.n);
        closeX.addEventListener('click', function (ev) {
          ev.stopPropagation();
          notes = notes.filter(function (n) { return n !== note; });
          closePopup();
          renderNotes();
        });
        head.appendChild(title);
        head.appendChild(closeX);

        var textarea = document.createElement('textarea');
        textarea.value = note.text;
        textarea.setAttribute('aria-label', 'Note ' + note.n + ' text');
        textarea.addEventListener('input', function () {
          note.text = textarea.value;
          var pin = pinsLayer.children[notes.indexOf(note)];
          if (pin) pin.setAttribute('aria-label', 'Note ' + note.n + (note.text ? ': ' + note.text : ''));
        });
        textarea.addEventListener('pointerdown', function (ev) { ev.stopPropagation(); });
        textarea.addEventListener('keydown', function (ev) { ev.stopPropagation(); });

        pop.appendChild(head);
        pop.appendChild(textarea);
        pop.addEventListener('pointerdown', function (ev) { ev.stopPropagation(); });
        stageInner.appendChild(pop);
        activePopupEl = pop;
        if (focusText) textarea.focus();
      }

      stage.addEventListener('pointerdown', function (ev) {
        if (activePopupEl && !activePopupEl.contains(ev.target)) closePopup();
      });

      // ---- save / cancel ----
      function hasDrawing() {
        return strokes.length > 0;
      }

      function doCancel() {
        finish(null);
      }

      function doSave() {
        if (uploading) return;
        clearError();
        if (!hasDrawing()) {
          finish({ annotation: null, notes: notes.map(cleanNote) });
          return;
        }
        uploading = true;
        saveBtn.disabled = true;
        drawCanvas.toBlob(function (blob) {
          if (!blob) {
            uploading = false;
            saveBtn.disabled = false;
            showError('Could not encode annotation.');
            return;
          }
          fetch('/api/upload?kind=annotation', {
            method: 'POST',
            headers: { 'Content-Type': 'image/png' },
            body: blob,
          }).then(function (resp) {
            if (!resp.ok) {
              return resp.json().catch(function () { return {}; }).then(function (j) {
                throw new Error(j.error || ('upload failed (' + resp.status + ')'));
              });
            }
            return resp.json();
          }).then(function (json) {
            uploading = false;
            finish({ annotation: json.path, notes: notes.map(cleanNote) });
          }).catch(function (err) {
            uploading = false;
            saveBtn.disabled = false;
            showError('Upload failed: ' + err.message);
          });
        }, 'image/png');
      }

      function cleanNote(n) {
        return { n: n.n, x: n.x, y: n.y, text: n.text };
      }

      cancelBtn.addEventListener('click', doCancel);
      saveBtn.addEventListener('click', doSave);

      // ---- keyboard ----
      function onKeydown(ev) {
        var target = ev.target;
        var isTyping = target && (target.tagName === 'TEXTAREA' || target.tagName === 'INPUT');
        if (ev.key === 'Escape') {
          ev.preventDefault();
          if (activePopupEl) { closePopup(); return; }
          if (!colorPop.hidden) { colorPop.hidden = true; return; }
          doCancel();
          return;
        }
        if (isTyping) {
          if ((ev.ctrlKey || ev.metaKey) && !ev.shiftKey && ev.key.toLowerCase() === 'z') {
            // allow default undo in textarea
          }
          return;
        }
        var mod = ev.ctrlKey || ev.metaKey;
        if (mod && ev.key.toLowerCase() === 'z' && ev.shiftKey) { ev.preventDefault(); redo(); return; }
        if (mod && ev.key.toLowerCase() === 'y') { ev.preventDefault(); redo(); return; }
        if (mod && ev.key.toLowerCase() === 'z') { ev.preventDefault(); undo(); return; }
        if (ev.key === 'p' || ev.key === 'P') { setTool('pen'); return; }
        if (ev.key === 'e' || ev.key === 'E') { setTool('eraser'); return; }
        if (ev.key === 'n' || ev.key === 'N') { setTool('note'); return; }
        if (ev.key === 'Tab') {
          trapFocus(ev);
        }
      }
      overlay.addEventListener('keydown', onKeydown);

      function focusableEls() {
        return Array.prototype.slice.call(
          overlay.querySelectorAll('button, [href], input, textarea, select, [tabindex]:not([tabindex="-1"])')
        ).filter(function (el) { return el.offsetParent !== null || el === overlay; });
      }
      function trapFocus(ev) {
        var list = focusableEls();
        if (!list.length) return;
        var first = list[0];
        var last = list[list.length - 1];
        if (ev.shiftKey && document.activeElement === first) {
          ev.preventDefault();
          last.focus();
        } else if (!ev.shiftKey && document.activeElement === last) {
          ev.preventDefault();
          first.focus();
        }
      }

      // ---- cleanup ----
      function cleanup() {
        window.removeEventListener('resize', layout);
        document.removeEventListener('pointerdown', outsideColorPop, true);
        if (overlay.parentNode) overlay.parentNode.removeChild(overlay);
        if (previouslyFocused && typeof previouslyFocused.focus === 'function') {
          previouslyFocused.focus();
        }
      }
    });
  }

  window.ClouterEditor = { open: open };
})();
