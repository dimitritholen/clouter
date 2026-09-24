/* Clouter studio — page shell. Vanilla ES2020, no build step. */
(function () {
  'use strict';

  var els = {
    headerRequest: document.getElementById('header-request'),
    headerModality: document.getElementById('header-modality'),
    headerState: document.getElementById('header-state'),
    connDot: document.getElementById('conn-dot'),
    connLabel: document.getElementById('conn-label'),
    errorBanner: document.getElementById('error-banner'),
    historyStrip: document.getElementById('history-strip'),
    newRoundPill: document.getElementById('new-round-pill'),
    roundMeta: document.getElementById('round-meta'),
    mediaView: document.getElementById('media-view'),
    briefDetails: document.getElementById('brief-details'),
    briefText: document.getElementById('brief-text'),
    defectsSection: document.getElementById('defects-section'),
    defectsList: document.getElementById('defects-list'),
    annotationSection: document.getElementById('annotation-section'),
    annotateBtn: document.getElementById('annotate-btn'),
    annotationPreview: document.getElementById('annotation-preview'),
    timelineMount: document.getElementById('timeline-mount'),
    feedbackText: document.getElementById('feedback-text'),
    branchToggleWrap: document.getElementById('branch-toggle-wrap'),
    branchToggle: document.getElementById('branch-toggle'),
    sendBtn: document.getElementById('send-feedback-btn'),
    acceptBtn: document.getElementById('accept-btn'),
    workingBanner: document.getElementById('working-banner'),
    acceptedBanner: document.getElementById('accepted-banner')
  };

  var state = {
    session: null,
    selectedRound: null,
    pendingAnnotation: {}, // round n -> {annotation, notes}
    acceptedDefects: {}, // round n -> Set of defect ids
    timelineController: null,
    overlayEl: null,
    annotationOverlayEl: null,
    acceptConfirmArmed: false,
    acceptConfirmTimer: null,
    esBackoff: 1000,
    prevRoundCount: 0
  };

  // ---------- small helpers ----------

  function escapeHtml(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function showError(msg) {
    els.errorBanner.textContent = msg;
    els.errorBanner.hidden = false;
  }

  function clearError() {
    els.errorBanner.hidden = true;
    els.errorBanner.textContent = '';
  }

  function draftKey(round) {
    var req = (state.session && state.session.request) || '';
    return 'clouter-studio-draft:' + req + ':' + round;
  }

  function loadDraft(round) {
    try {
      return localStorage.getItem(draftKey(round)) || '';
    } catch (e) {
      return '';
    }
  }

  function saveDraft(round, text) {
    try {
      if (text) {
        localStorage.setItem(draftKey(round), text);
      } else {
        localStorage.removeItem(draftKey(round));
      }
    } catch (e) {
      /* storage unavailable — draft just won't persist */
    }
  }

  function rounds() {
    return (state.session && state.session.rounds) || [];
  }

  function findRound(n) {
    var rs = rounds();
    for (var i = 0; i < rs.length; i++) {
      if (rs[i].n === n) return rs[i];
    }
    return null;
  }

  function newestRoundNumber() {
    var rs = rounds();
    if (!rs.length) return null;
    var max = rs[0].n;
    for (var i = 1; i < rs.length; i++) {
      if (rs[i].n > max) max = rs[i].n;
    }
    return max;
  }

  function isImageType(mediaType) {
    return !!mediaType && mediaType.indexOf('image/') === 0;
  }

  function isVideoType(mediaType) {
    return !!mediaType && mediaType.indexOf('video/') === 0;
  }

  function isAudioType(mediaType) {
    return !!mediaType && mediaType.indexOf('audio/') === 0;
  }

  // ---------- connection status ----------

  function setConn(mode) {
    els.connDot.className = 'conn-dot ' + (mode === 'live' ? 'live' : mode === 'reconnecting' ? 'reconnecting' : '');
    els.connLabel.textContent = mode === 'live' ? 'live' : mode === 'reconnecting' ? 'reconnecting…' : 'connecting…';
  }

  // ---------- SSE ----------

  function connectEvents() {
    var es;
    try {
      es = new EventSource('/events');
    } catch (e) {
      setConn('reconnecting');
      setTimeout(connectEvents, state.esBackoff);
      state.esBackoff = Math.min(state.esBackoff * 2, 15000);
      return;
    }
    es.addEventListener('session', function (e) {
      setConn('live');
      state.esBackoff = 1000;
      try {
        onSession(JSON.parse(e.data));
      } catch (err) {
        showError('Received malformed session data from server.');
      }
    });
    es.onerror = function () {
      setConn('reconnecting');
      es.close();
      setTimeout(connectEvents, state.esBackoff);
      state.esBackoff = Math.min(state.esBackoff * 2, 15000);
    };
  }

  // ---------- rendering ----------

  function onSession(session) {
    var prevCount = state.session ? rounds().length : 0;
    var isNewRound = session.rounds && session.rounds.length > prevCount;
    var hadSession = !!state.session;
    state.session = session;

    renderHeader();
    renderHistory();
    updateButtonsState();

    if (!hadSession && state.selectedRound == null) {
      selectRound(newestRoundNumber());
      return;
    }

    if (state.selectedRound != null && !findRound(state.selectedRound)) {
      selectRound(newestRoundNumber());
      return;
    }

    if (isNewRound) {
      var draftNonEmpty = els.feedbackText.value.trim().length > 0;
      if (draftNonEmpty) {
        els.newRoundPill.hidden = false;
      } else {
        selectRound(newestRoundNumber());
      }
      return;
    }

    // same round set — re-render current round in case its fields changed
    renderMain();
  }

  function renderHeader() {
    var s = state.session;
    if (!s) return;
    els.headerRequest.textContent = s.request || '';
    els.headerRequest.title = s.request || '';
    els.headerModality.textContent = s.modality || '';
    els.headerState.textContent = s.state || '';
  }

  function thumbFor(round) {
    if (isImageType(round.media_type)) {
      var img = document.createElement('img');
      img.src = '/files/' + round.file;
      img.alt = '';
      return img;
    }
    var icon = document.createElement('span');
    icon.textContent = isVideoType(round.media_type) ? '▶' : isAudioType(round.media_type) ? '♫' : '•';
    return icon;
  }

  function renderHistory() {
    var rs = rounds().slice().sort(function (a, b) { return a.n - b.n; });
    els.historyStrip.innerHTML = '';
    rs.forEach(function (round) {
      var card = document.createElement('button');
      card.type = 'button';
      card.className = 'round-card' + (round.n === state.selectedRound ? ' selected' : '');
      card.setAttribute('aria-pressed', round.n === state.selectedRound ? 'true' : 'false');

      var thumb = document.createElement('span');
      thumb.className = 'round-thumb';
      thumb.appendChild(thumbFor(round));

      var info = document.createElement('span');
      info.className = 'round-info';
      var costText = typeof round.cost === 'number' ? ('$' + round.cost.toFixed(3)) : '';
      var subText = (round.model || '') + (costText ? ' · ' + costText : '');
      info.innerHTML =
        '<span class="n">Round ' + round.n + '</span>' +
        '<span class="sub" title="' + escapeHtml(subText) + '">' + escapeHtml(subText) + '</span>';

      card.appendChild(thumb);
      card.appendChild(info);
      card.addEventListener('click', function () {
        selectRound(round.n);
      });
      els.historyStrip.appendChild(card);
    });
  }

  function selectRound(n) {
    if (state.timelineController && typeof state.timelineController.destroy === 'function') {
      state.timelineController.destroy();
    }
    state.timelineController = null;
    removeDefectOverlay();

    state.selectedRound = n;
    els.newRoundPill.hidden = true;
    resetAcceptButton();
    els.feedbackText.value = loadDraft(n);
    renderHistory();
    renderMain();
  }

  function currentRound() {
    return state.selectedRound == null ? null : findRound(state.selectedRound);
  }

  function renderMain() {
    var round = currentRound();
    if (!round) {
      els.roundMeta.textContent = '';
      els.mediaView.innerHTML = '';
      els.briefDetails.hidden = true;
      els.defectsSection.hidden = true;
      els.annotationSection.hidden = true;
      return;
    }

    var metaParts = [
      'Round ' + round.n,
      round.model || '',
      typeof round.cost === 'number' ? '$' + round.cost.toFixed(4) : ''
    ];
    if (round.parent != null) {
      metaParts.push('branched from r' + round.parent);
    }
    els.roundMeta.textContent = metaParts.filter(Boolean).join(' · ');

    buildMedia(round);

    els.briefDetails.hidden = false;
    els.briefText.textContent = round.brief || '';

    renderDefects(round);
    renderAnnotationSection(round);
    renderBranchToggle(round);
  }

  function buildMedia(round) {
    els.mediaView.innerHTML = '';
    state.annotationOverlayEl = null;
    var url = '/files/' + round.file;
    var type = round.media_type || '';

    if (isImageType(type)) {
      var img = document.createElement('img');
      img.src = url;
      img.alt = 'Round ' + round.n + ' result';
      img.addEventListener('click', function () {
        openEditor(round);
      });
      img.addEventListener('load', function () {
        repositionAnnotationOverlay();
      });
      els.mediaView.appendChild(img);
    } else if (isVideoType(type)) {
      var video = document.createElement('video');
      video.controls = true;
      video.src = url;
      els.mediaView.appendChild(video);
      mountTimeline(video, 'video');
    } else if (isAudioType(type)) {
      var audio = document.createElement('audio');
      audio.controls = true;
      audio.src = url;
      els.mediaView.appendChild(audio);
      mountTimeline(audio, 'audio');
    } else {
      var span = document.createElement('span');
      span.textContent = 'Unsupported media type: ' + type;
      els.mediaView.appendChild(span);
    }
  }

  function mountTimeline(mediaEl, kind) {
    els.timelineMount.innerHTML = '';
    if (!window.ClouterTimeline) return;
    try {
      state.timelineController = window.ClouterTimeline.mount(els.timelineMount, mediaEl, { kind: kind, markers: [] });
    } catch (e) {
      showError('Timeline failed to load: ' + e);
    }
  }

  // ---------- defects / overlay ----------

  function renderDefects(round) {
    var defects = round.defects || [];
    if (!defects.length) {
      els.defectsSection.hidden = true;
      els.defectsList.innerHTML = '';
      return;
    }
    els.defectsSection.hidden = false;
    els.defectsList.innerHTML = '';
    var acceptedSet = state.acceptedDefects[round.n] || (state.acceptedDefects[round.n] = new Set());

    defects.forEach(function (d) {
      var li = document.createElement('li');
      li.className = 'defect-item';

      var label = document.createElement('label');
      var cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = acceptedSet.has(d.id);
      cb.addEventListener('change', function () {
        if (cb.checked) acceptedSet.add(d.id);
        else acceptedSet.delete(d.id);
      });
      label.appendChild(cb);

      var text = document.createElement('span');
      text.className = 'defect-text';
      text.innerHTML =
        '<span class="sev">sev ' + escapeHtml(d.severity) + '</span> ' +
        escapeHtml(d.type || '') + ' &mdash; ' + escapeHtml(d.where || '') +
        (d.fix ? '<br>fix: ' + escapeHtml(d.fix) : '');
      label.appendChild(text);

      li.appendChild(label);
      if (d.box && d.box.length === 4) {
        li.addEventListener('mouseenter', function () { showDefectOverlay(d.box); });
        li.addEventListener('mouseleave', function () { removeDefectOverlay(); });
      }
      els.defectsList.appendChild(li);
    });
  }

  function imgRect() {
    var img = els.mediaView.querySelector('img');
    if (!img) return null;
    return { left: img.offsetLeft, top: img.offsetTop, width: img.offsetWidth, height: img.offsetHeight };
  }

  function positionElementToRect(el, rect) {
    el.style.left = rect.left + 'px';
    el.style.top = rect.top + 'px';
    el.style.width = rect.width + 'px';
    el.style.height = rect.height + 'px';
  }

  function showDefectOverlay(box) {
    var r = imgRect();
    if (!r) return;
    removeDefectOverlay();
    var el = document.createElement('div');
    el.className = 'defect-overlay';
    positionElementToRect(el, {
      left: r.left + box[0] * r.width,
      top: r.top + box[1] * r.height,
      width: (box[2] - box[0]) * r.width,
      height: (box[3] - box[1]) * r.height
    });
    els.mediaView.appendChild(el);
    state.overlayEl = el;
  }

  function removeDefectOverlay() {
    if (state.overlayEl) {
      state.overlayEl.remove();
      state.overlayEl = null;
    }
  }

  // ---------- annotation preview overlay (reuses imgRect/positionElementToRect above) ----------

  function showAnnotationOverlay(pending) {
    removeAnnotationOverlay();
    var r = imgRect();
    if (!r) return;
    var wrap = document.createElement('div');
    wrap.className = 'annotation-overlay';
    positionElementToRect(wrap, r);

    if (pending.annotation) {
      var img = document.createElement('img');
      img.className = 'annotation-overlay-img';
      img.src = '/files/' + pending.annotation;
      img.alt = '';
      wrap.appendChild(img);
    }

    (pending.notes || []).forEach(function (note, i) {
      var pin = document.createElement('div');
      pin.className = 'annotation-overlay-pin';
      pin.style.left = (note.x * 100) + '%';
      pin.style.top = (note.y * 100) + '%';
      pin.textContent = String(i + 1);
      pin.title = note.text || '';
      wrap.appendChild(pin);
    });

    els.mediaView.appendChild(wrap);
    state.annotationOverlayEl = wrap;
  }

  function removeAnnotationOverlay() {
    if (state.annotationOverlayEl) {
      state.annotationOverlayEl.remove();
      state.annotationOverlayEl = null;
    }
  }

  function repositionAnnotationOverlay() {
    if (!state.annotationOverlayEl) return;
    var r = imgRect();
    if (!r) return;
    positionElementToRect(state.annotationOverlayEl, r);
  }

  window.addEventListener('resize', repositionAnnotationOverlay);

  // ---------- annotation ----------

  function renderAnnotationSection(round) {
    var canAnnotate = isImageType(round.media_type) && !!window.ClouterEditor;
    els.annotationSection.hidden = !canAnnotate;
    if (!canAnnotate) {
      removeAnnotationOverlay();
      return;
    }
    renderAnnotationPreview(round);
  }

  function renderAnnotationPreview(round) {
    var pending = state.pendingAnnotation[round.n];
    if (!pending) {
      els.annotationPreview.hidden = true;
      els.annotationPreview.innerHTML = '';
      removeAnnotationOverlay();
      return;
    }
    showAnnotationOverlay(pending);
    els.annotationPreview.hidden = false;
    var noteCount = (pending.notes || []).length;
    els.annotationPreview.innerHTML = '';
    var span = document.createElement('span');
    span.textContent = 'annotation attached, ' + noteCount + ' note' + (noteCount === 1 ? '' : 's');
    var remove = document.createElement('a');
    remove.textContent = 'remove';
    remove.href = '#';
    remove.addEventListener('click', function (e) {
      e.preventDefault();
      delete state.pendingAnnotation[round.n];
      renderAnnotationPreview(round);
    });
    els.annotationPreview.appendChild(span);
    els.annotationPreview.appendChild(remove);
  }

  function openEditor(round) {
    if (!window.ClouterEditor || !isImageType(round.media_type)) return;
    var url = '/files/' + round.file;
    var existing = state.pendingAnnotation[round.n];
    var notes = (existing && existing.notes) || [];
    window.ClouterEditor.open(url, { notes: notes }).then(function (result) {
      if (!result) return;
      state.pendingAnnotation[round.n] = result;
      renderAnnotationPreview(round);
    }).catch(function (err) {
      showError('Annotation editor failed: ' + err);
    });
  }

  els.annotateBtn.addEventListener('click', function () {
    var round = currentRound();
    if (round) openEditor(round);
  });

  // ---------- branch toggle ----------

  function renderBranchToggle(round) {
    var newest = newestRoundNumber();
    var canBranch = round.n !== newest;
    els.branchToggleWrap.hidden = !canBranch;
    if (!canBranch) els.branchToggle.checked = false;
  }

  // ---------- new round pill ----------

  els.newRoundPill.addEventListener('click', function () {
    els.newRoundPill.hidden = true;
    selectRound(newestRoundNumber());
  });

  // ---------- feedback draft persistence ----------

  els.feedbackText.addEventListener('input', function () {
    if (state.selectedRound != null) {
      saveDraft(state.selectedRound, els.feedbackText.value);
    }
  });

  // ---------- send feedback ----------

  els.sendBtn.addEventListener('click', function () {
    sendFeedback();
  });

  function sendFeedback() {
    var round = state.selectedRound;
    if (round == null) return;
    var text = els.feedbackText.value.trim();
    var acceptedSet = state.acceptedDefects[round] || new Set();
    var accepted_defects = Array.from(acceptedSet);
    var pending = state.pendingAnnotation[round];
    var annotation = pending ? pending.annotation : null;
    var notes = pending ? (pending.notes || []) : [];
    var newest = newestRoundNumber();
    var branch_from = (els.branchToggle.checked && round !== newest) ? round : null;

    var afterMarkers = function (markers) {
      markers = markers || [];
      var hasContent = !!text || accepted_defects.length > 0 || !!annotation || notes.length > 0 || markers.length > 0;
      if (!hasContent) {
        showError('Add feedback text, accept a defect, or attach an annotation/notes before sending.');
        return;
      }
      clearError();
      els.sendBtn.disabled = true;
      fetch('/api/feedback', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          round: round,
          branch_from: branch_from,
          text: text,
          accepted_defects: accepted_defects,
          notes: notes,
          markers: markers,
          annotation: annotation
        })
      }).then(function (res) {
        return res.json().then(function (data) { return { ok: res.ok, data: data }; });
      }).then(function (r) {
        if (!r.ok) {
          showError((r.data && r.data.error) || 'Failed to send feedback.');
          return;
        }
        saveDraft(round, '');
        els.feedbackText.value = '';
        delete state.pendingAnnotation[round];
        var r2 = findRound(round);
        if (r2) renderAnnotationPreview(r2);
        if (state.acceptedDefects[round]) state.acceptedDefects[round].clear();
        renderDefects(r2 || {});
      }).catch(function (e) {
        showError('Network error sending feedback: ' + e);
      }).finally(function () {
        els.sendBtn.disabled = false;
        updateButtonsState();
      });
    };

    if (state.timelineController && typeof state.timelineController.getMarkers === 'function') {
      Promise.resolve(state.timelineController.getMarkers()).then(afterMarkers).catch(function (e) {
        showError('Failed to collect timeline markers: ' + e);
      });
    } else {
      afterMarkers([]);
    }
  }

  // ---------- accept ----------

  function resetAcceptButton() {
    state.acceptConfirmArmed = false;
    if (state.acceptConfirmTimer) {
      clearTimeout(state.acceptConfirmTimer);
      state.acceptConfirmTimer = null;
    }
    els.acceptBtn.textContent = 'Accept this round';
    els.acceptBtn.classList.remove('btn-danger-confirm');
  }

  els.acceptBtn.addEventListener('click', function () {
    if (!state.acceptConfirmArmed) {
      state.acceptConfirmArmed = true;
      els.acceptBtn.textContent = 'Confirm accept?';
      els.acceptBtn.classList.add('btn-danger-confirm');
      state.acceptConfirmTimer = setTimeout(resetAcceptButton, 4000);
      return;
    }
    doAccept();
  });

  function doAccept() {
    var round = state.selectedRound;
    resetAcceptButton();
    if (round == null) return;
    els.acceptBtn.disabled = true;
    fetch('/api/accept', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ round: round })
    }).then(function (res) {
      return res.json().then(function (data) { return { ok: res.ok, data: data }; });
    }).then(function (r) {
      if (!r.ok) {
        showError((r.data && r.data.error) || 'Failed to accept round.');
        return;
      }
      clearError();
    }).catch(function (e) {
      showError('Network error accepting round: ' + e);
    }).finally(function () {
      els.acceptBtn.disabled = false;
      updateButtonsState();
    });
  }

  // ---------- button/state gating ----------

  function updateButtonsState() {
    var s = state.session;
    if (!s) return;
    var working = s.state === 'feedback';
    var accepted = s.state === 'accepted';

    els.sendBtn.disabled = working || accepted;
    els.acceptBtn.disabled = accepted;
    els.feedbackText.disabled = accepted;
    els.branchToggle.disabled = accepted;

    els.workingBanner.hidden = !working;
    if (working) {
      els.workingBanner.textContent = 'Claude is working on round ' + (newestRoundNumber() + 1) + '…';
    }

    els.acceptedBanner.hidden = !accepted;
    if (accepted) {
      els.acceptedBanner.textContent = 'Round accepted. This session is closed.';
    }
  }

  // ---------- boot ----------

  fetch('/api/session')
    .then(function (res) { return res.json(); })
    .then(function (data) {
      onSession(data);
    })
    .catch(function () {
      /* SSE connection below will populate the page once it connects */
    })
    .finally(function () {
      connectEvents();
    });
})();
