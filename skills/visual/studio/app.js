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
    messagesSection: document.getElementById('messages-section'),
    messagesList: document.getElementById('messages-list'),
    modelPicker: document.getElementById('model-picker'),
    modelOptionsList: document.getElementById('model-options-list'),
    modelSuggestBtn: document.getElementById('model-suggest-btn'),
    modelSuggestStatus: document.getElementById('model-suggest-status'),
    modelManualBtn: document.getElementById('model-manual-btn'),
    manualDialog: document.getElementById('manual-model-dialog'),
    manualModelClose: document.getElementById('manual-model-close'),
    manualModelSearch: document.getElementById('manual-model-search'),
    manualModelList: document.getElementById('manual-model-list'),
    manualModelThName: document.getElementById('manual-model-th-name'),
    manualModelThPrice: document.getElementById('manual-model-th-price'),
    feedbackText: document.getElementById('feedback-text'),
    branchToggleWrap: document.getElementById('branch-toggle-wrap'),
    branchToggle: document.getElementById('branch-toggle'),
    sendBtn: document.getElementById('send-feedback-btn'),
    acceptBtn: document.getElementById('accept-btn'),
    workingBanner: document.getElementById('working-banner'),
    acceptedBanner: document.getElementById('accepted-banner'),
    costTotal: document.getElementById('cost-total'),
    costBreakdown: document.getElementById('cost-breakdown'),
    newQuestionsPill: document.getElementById('new-questions-pill'),
    roundView: document.getElementById('round-view'),
    questionView: document.getElementById('question-view'),
    questionMeta: document.getElementById('question-meta'),
    questionMessage: document.getElementById('question-message'),
    questionForm: document.getElementById('question-form'),
    sendAnswersBtn: document.getElementById('send-answers-btn'),
    answersBanner: document.getElementById('answers-banner')
  };

  var state = {
    session: null,
    selectedRound: null,
    pendingAnnotation: {}, // round n -> {annotation, notes}
    acceptedDefects: {}, // round n -> Set of defect ids
    modelChoice: {}, // round n -> null (keep) | {type: 'suggested'|'manual', id, name}
    catalogue: null, // null | 'loading' | 'error' | [entries]
    catalogueError: null,
    catalogueSort: { key: 'price', dir: 'asc' },
    timelineController: null,
    overlayEl: null,
    annotationOverlayEl: null,
    acceptConfirmArmed: false,
    acceptConfirmTimer: null,
    esBackoff: 1000,
    prevRoundCount: 0,
    selectedQuestions: null, // question set id shown instead of a round, or null
    renderedQuestions: null // "id:answered" of the form on screen, so SSE updates don't wipe input
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

  function feedback() {
    return (state.session && state.session.feedback) || [];
  }

  function questionSets() {
    return (state.session && state.session.questions) || [];
  }

  function findQuestionSet(id) {
    var qs = questionSets();
    for (var i = 0; i < qs.length; i++) {
      if (qs[i].id === id) return qs[i];
    }
    return null;
  }

  // Oldest question set still waiting for answers, or null.
  function pendingQuestionSet() {
    var open = questionSets().filter(function (q) { return q.answers == null; });
    open.sort(function (a, b) { return a.id - b.id; });
    return open[0] || null;
  }

  function formatUsd(v) {
    return '$' + v.toFixed(v > 0 && v < 0.01 ? 4 : 2);
  }

  function roundCost(round) {
    var total = typeof round.cost === 'number' ? round.cost : 0;
    (round.extras || []).forEach(function (x) {
      if (typeof x.cost === 'number') total += x.cost;
    });
    return total;
  }

  function feedbackEntriesForRound(round) {
    return feedback().filter(function (e) { return e.round === round.n; }).sort(function (a, b) {
      return (a.id || 0) - (b.id || 0);
    });
  }

  function latestFeedbackEntry() {
    var fb = feedback();
    var latest = null;
    fb.forEach(function (e) {
      if (!latest || (e.id || 0) > (latest.id || 0)) latest = e;
    });
    return latest;
  }

  // Feedback entry the server is currently acting on for this round, or null.
  function pendingFeedbackEntry(round) {
    var s = state.session;
    if (!s || s.state !== 'feedback') return null;
    var latest = latestFeedbackEntry();
    if (!latest || latest.round !== round.n || latest.action !== 'feedback') return null;
    return latest;
  }

  function resolveModelName(id, round) {
    if (!id) return null;
    var models = (round && round.models) || [];
    for (var i = 0; i < models.length; i++) {
      if (models[i].id === id) return models[i].name;
    }
    if (Array.isArray(state.catalogue)) {
      for (var j = 0; j < state.catalogue.length; j++) {
        if (state.catalogue[j].id === id) return state.catalogue[j].name;
      }
    }
    return id;
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

  // price + unit, matching ranking.py's price_label formatting
  function formatPrice(price, unit) {
    if (typeof price !== 'number') return '';
    if (price < 0.01) return '$' + (price * 1000).toFixed(4) + ' per 1K ' + unit + 's';
    return '$' + price.toFixed(3) + ' per ' + unit;
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
    var prevPending = hadSession ? pendingQuestionSet() : null;
    state.session = session;

    renderHeader();
    renderHistory();
    updateButtonsState();

    var pending = pendingQuestionSet();
    if (pending && (!prevPending || prevPending.id !== pending.id)) {
      if (hadSession && els.feedbackText.value.trim().length > 0 && state.selectedQuestions == null) {
        els.newQuestionsPill.hidden = false;
      } else {
        selectQuestions(pending.id);
      }
      return;
    }
    if (state.selectedQuestions != null) {
      if (!isNewRound) {
        renderQuestionView();
        return;
      }
      selectRound(newestRoundNumber());
      return;
    }

    if (!hadSession && state.selectedRound == null) {
      var qs = questionSets();
      if (newestRoundNumber() == null && qs.length) {
        selectQuestions(qs[qs.length - 1].id);
      } else {
        selectRound(newestRoundNumber());
      }
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
    renderCost();
  }

  function renderCost() {
    var rs = rounds().slice().sort(function (a, b) { return a.n - b.n; });
    var total = 0;
    rs.forEach(function (r) { total += roundCost(r); });
    els.costTotal.hidden = rs.length === 0;
    els.costTotal.textContent = 'Spent ' + formatUsd(total);
    els.costTotal.title = 'Everything this session has cost on OpenRouter, across ' + rs.length +
      (rs.length === 1 ? ' round' : ' rounds') + '. Click for the breakdown.';

    var rows = [];
    rs.forEach(function (r) {
      rows.push('<tr class="cost-round"><td>Round ' + r.n + '</td><td class="usd">' +
        formatUsd(roundCost(r)) + '</td></tr>');
      rows.push('<tr class="cost-line"><td>Generation · ' + escapeHtml(r.model || '') +
        '</td><td class="usd">' + formatUsd(typeof r.cost === 'number' ? r.cost : 0) + '</td></tr>');
      (r.extras || []).forEach(function (x) {
        rows.push('<tr class="cost-line"><td>' + escapeHtml(x.label || '') + '</td><td class="usd">' +
          formatUsd(typeof x.cost === 'number' ? x.cost : 0) + '</td></tr>');
      });
    });
    rows.push('<tr class="cost-sum"><td>Total</td><td class="usd">' + formatUsd(total) + '</td></tr>');
    els.costBreakdown.innerHTML = '<table>' + rows.join('') + '</table>';
  }

  els.costTotal.addEventListener('click', function (e) {
    e.stopPropagation();
    var open = els.costBreakdown.hidden;
    els.costBreakdown.hidden = !open;
    els.costTotal.setAttribute('aria-expanded', open ? 'true' : 'false');
  });

  document.addEventListener('click', function (e) {
    if (!els.costBreakdown.hidden && !els.costBreakdown.contains(e.target)) {
      els.costBreakdown.hidden = true;
      els.costTotal.setAttribute('aria-expanded', 'false');
    }
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && !els.costBreakdown.hidden) {
      els.costBreakdown.hidden = true;
      els.costTotal.setAttribute('aria-expanded', 'false');
      els.costTotal.focus();
    }
  });

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

  function questionCard(qset) {
    var selected = qset.id === state.selectedQuestions;
    var card = document.createElement('button');
    card.type = 'button';
    card.className = 'round-card question-card' + (selected ? ' selected' : '') +
      (qset.answers == null ? ' pending' : '');
    card.setAttribute('aria-pressed', selected ? 'true' : 'false');
    var thumb = document.createElement('span');
    thumb.className = 'round-thumb';
    thumb.textContent = '?';
    var info = document.createElement('span');
    info.className = 'round-info';
    var count = qset.questions.length;
    var sub = (qset.answers == null ? 'Waiting for you' : 'Answered') + ' · ' + count +
      (count === 1 ? ' question' : ' questions');
    info.innerHTML = '<span class="n">Questions</span><span class="sub">' + escapeHtml(sub) + '</span>';
    card.appendChild(thumb);
    card.appendChild(info);
    card.addEventListener('click', function () { selectQuestions(qset.id); });
    return card;
  }

  function renderHistory() {
    // Rounds and question sets in the order they happened.
    var items = rounds().map(function (r) { return { kind: 'round', at: r.created || '', n: r.n, item: r }; })
      .concat(questionSets().map(function (q) { return { kind: 'questions', at: q.created || '', n: q.id, item: q }; }));
    items.sort(function (a, b) {
      if (a.at !== b.at) return a.at < b.at ? -1 : 1;
      return a.kind === b.kind ? a.n - b.n : (a.kind === 'questions' ? -1 : 1);
    });
    els.historyStrip.innerHTML = '';
    items.forEach(function (it) {
      if (it.kind === 'questions') {
        els.historyStrip.appendChild(questionCard(it.item));
        return;
      }
      var round = it.item;
      var isSelected = round.n === state.selectedRound && state.selectedQuestions == null;
      var card = document.createElement('button');
      card.type = 'button';
      card.className = 'round-card' + (isSelected ? ' selected' : '');
      card.setAttribute('aria-pressed', isSelected ? 'true' : 'false');

      var thumb = document.createElement('span');
      thumb.className = 'round-thumb';
      thumb.appendChild(thumbFor(round));

      var info = document.createElement('span');
      info.className = 'round-info';
      var costText = typeof round.cost === 'number' ? formatUsd(roundCost(round)) : '';
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
    state.selectedQuestions = null;
    state.renderedQuestions = null;
    els.questionView.hidden = true;
    els.roundView.hidden = false;
    els.newRoundPill.hidden = true;
    resetAcceptButton();
    els.feedbackText.value = loadDraft(n);
    renderHistory();
    renderMain();
  }

  function selectQuestions(id) {
    if (state.timelineController && typeof state.timelineController.destroy === 'function') {
      state.timelineController.destroy();
    }
    state.timelineController = null;
    removeDefectOverlay();
    state.selectedQuestions = id;
    state.renderedQuestions = null;
    els.newQuestionsPill.hidden = true;
    els.roundView.hidden = true;
    els.questionView.hidden = false;
    renderHistory();
    renderQuestionView();
  }

  function renderQuestionView() {
    var qset = findQuestionSet(state.selectedQuestions);
    if (!qset) return;
    var answered = qset.answers != null;
    var key = qset.id + ':' + answered;
    els.sendAnswersBtn.hidden = answered;
    els.answersBanner.hidden = !answered;
    if (answered) {
      els.answersBanner.textContent = qset.consumed
        ? 'Answered. Claude has your answers.'
        : 'Answers sent. Claude picks them up in a moment…';
    }
    if (state.renderedQuestions === key) return; // keep what the user is typing
    state.renderedQuestions = key;

    els.questionMeta.textContent = 'Questions · ' + (answered ? 'answered' : 'waiting for your answers');
    els.questionMessage.hidden = !qset.message;
    els.questionMessage.textContent = qset.message || '';
    els.questionForm.innerHTML = '';
    els.questionForm.className = 'question-form' + (answered ? ' answered' : '');
    els.sendAnswersBtn.disabled = false;

    qset.questions.forEach(function (q, qi) {
      var given = answered ? qset.answers[qi] : null;
      var block = document.createElement('fieldset');
      block.className = 'question-block';
      block.disabled = answered;
      var legend = document.createElement('legend');
      if (q.header) {
        var chip = document.createElement('span');
        chip.className = 'badge question-header';
        chip.textContent = q.header;
        legend.appendChild(chip);
      }
      var text = document.createElement('span');
      text.className = 'question-text';
      text.textContent = q.question;
      legend.appendChild(text);
      block.appendChild(legend);

      var type = q.multiSelect ? 'checkbox' : 'radio';
      var name = 'q' + qset.id + '-' + qi;
      q.options.forEach(function (o) {
        var row = document.createElement('label');
        row.className = 'question-option';
        var input = document.createElement('input');
        input.type = type;
        input.name = name;
        input.value = o.label;
        if (given) {
          input.checked = q.multiSelect ? (given.answer || []).indexOf(o.label) !== -1 : given.answer === o.label;
        }
        var body = document.createElement('span');
        body.innerHTML = '<span class="label">' + escapeHtml(o.label) + '</span>' +
          (o.description ? '<span class="description">' + escapeHtml(o.description) + '</span>' : '');
        row.appendChild(input);
        row.appendChild(body);
        block.appendChild(row);
      });

      var otherRow = document.createElement('label');
      otherRow.className = 'question-option';
      var otherPick = document.createElement('input');
      otherPick.type = type;
      otherPick.name = name;
      otherPick.value = '__other__';
      otherPick.dataset.other = '1';
      var otherBody = document.createElement('span');
      otherBody.style.flex = '1';
      otherBody.innerHTML = '<span class="label">Other</span>';
      var otherText = document.createElement('input');
      otherText.type = 'text';
      otherText.className = 'question-other';
      otherText.placeholder = 'Your own answer…';
      otherText.dataset.otherText = name;
      if (given && given.other) {
        otherPick.checked = true;
        otherText.value = given.other;
      }
      otherText.addEventListener('input', function () {
        if (otherText.value.trim()) otherPick.checked = true;
      });
      otherBody.appendChild(otherText);
      otherRow.appendChild(otherPick);
      otherRow.appendChild(otherBody);
      block.appendChild(otherRow);
      els.questionForm.appendChild(block);
    });
  }

  function collectAnswers(qset) {
    var answers = [];
    for (var qi = 0; qi < qset.questions.length; qi++) {
      var q = qset.questions[qi];
      var name = 'q' + qset.id + '-' + qi;
      var picked = Array.prototype.slice.call(
        els.questionForm.querySelectorAll('input[name="' + name + '"]:checked'));
      var otherBox = els.questionForm.querySelector('input[data-other-text="' + name + '"]');
      var otherOn = picked.some(function (i) { return i.dataset.other === '1'; });
      var other = otherOn && otherBox.value.trim() ? otherBox.value.trim() : null;
      var labels = picked.filter(function (i) { return i.dataset.other !== '1'; })
        .map(function (i) { return i.value; });
      if (otherOn && !other) {
        return { error: 'Question ' + (qi + 1) + ': type your own answer, or pick an option.' };
      }
      if (q.multiSelect) {
        if (!labels.length && !other) return { error: 'Question ' + (qi + 1) + ' needs an answer.' };
        answers.push({ answer: labels, other: other });
      } else {
        if (!labels.length && !other) return { error: 'Question ' + (qi + 1) + ' needs an answer.' };
        answers.push({ answer: other ? null : labels[0], other: other });
      }
    }
    return { answers: answers };
  }

  els.sendAnswersBtn.addEventListener('click', function () {
    var qset = findQuestionSet(state.selectedQuestions);
    if (!qset || qset.answers != null) return;
    var collected = collectAnswers(qset);
    if (collected.error) {
      showError(collected.error);
      return;
    }
    clearError();
    els.sendAnswersBtn.disabled = true;
    fetch('/api/answers', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: qset.id, answers: collected.answers })
    })
      .then(function (res) {
        return res.json().then(function (data) {
          if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
          return data;
        });
      })
      .catch(function (err) {
        els.sendAnswersBtn.disabled = false;
        showError('Could not send answers: ' + err.message);
      });
  });

  els.newQuestionsPill.addEventListener('click', function () {
    var pending = pendingQuestionSet();
    if (pending) selectQuestions(pending.id);
  });

  function currentRound() {
    return state.selectedRound == null ? null : findRound(state.selectedRound);
  }

  function renderMain() {
    var round = currentRound();
    if (!round) {
      els.roundMeta.textContent = '';
      els.mediaView.innerHTML = '';
      els.briefDetails.hidden = true;
      els.messagesSection.hidden = true;
      els.defectsSection.hidden = true;
      els.annotationSection.hidden = true;
      els.modelPicker.hidden = true;
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

    renderMessages(round);
    renderDefects(round);
    renderAnnotationSection(round);
    renderBranchToggle(round);
    renderModelPicker(round);
  }

  // ---------- messages ----------

  function buildYouBubble(entry, round) {
    var bubble = document.createElement('div');
    bubble.className = 'message-bubble message-you';
    var author = document.createElement('span');
    author.className = 'message-author';
    author.textContent = 'You';
    bubble.appendChild(author);

    if (entry.action === 'accept') {
      var acceptedP = document.createElement('p');
      acceptedP.textContent = 'You accepted this round';
      bubble.appendChild(acceptedP);
      return bubble;
    }

    if (entry.text) {
      var textP = document.createElement('p');
      textP.textContent = entry.text;
      bubble.appendChild(textP);
    }

    if (entry.model) {
      var modelP = document.createElement('p');
      modelP.textContent = 'Model for next round: ' + resolveModelName(entry.model, round);
      bubble.appendChild(modelP);
    }

    if (entry.accepted_defects && entry.accepted_defects.length) {
      var wheres = entry.accepted_defects.map(function (id) {
        var d = (round.defects || []).filter(function (x) { return x.id === id; })[0];
        return d ? (d.where || id) : id;
      });
      var acceptedDefectsP = document.createElement('p');
      acceptedDefectsP.textContent = 'Accepted suggestions: ' + wheres.join(', ');
      bubble.appendChild(acceptedDefectsP);
    }

    var counts = [];
    if (entry.annotation) counts.push('1 annotation');
    if (entry.notes && entry.notes.length) {
      counts.push(entry.notes.length + ' note' + (entry.notes.length === 1 ? '' : 's'));
    }
    if (entry.markers && entry.markers.length) {
      counts.push(entry.markers.length + ' timeline note' + (entry.markers.length === 1 ? '' : 's'));
    }
    if (counts.length) {
      var countsP = document.createElement('p');
      countsP.textContent = counts.join(', ');
      bubble.appendChild(countsP);
    }

    if (entry.branch_from != null) {
      var branchP = document.createElement('p');
      branchP.textContent = 'Branch from round ' + entry.branch_from;
      bubble.appendChild(branchP);
    }

    return bubble;
  }

  function renderMessages(round) {
    var hasSummary = !!round.summary;
    var hasMessage = !!round.message;
    var entries = feedbackEntriesForRound(round);
    els.messagesList.innerHTML = '';
    if (!hasSummary && !hasMessage && !entries.length) {
      els.messagesSection.hidden = true;
      return;
    }
    els.messagesSection.hidden = false;

    if (hasSummary) {
      var critic = document.createElement('div');
      critic.className = 'message-bubble message-critic';
      var criticAuthor = document.createElement('span');
      criticAuthor.className = 'message-author';
      criticAuthor.textContent = 'Critic';
      var criticText = document.createElement('p');
      criticText.textContent = round.summary;
      critic.appendChild(criticAuthor);
      critic.appendChild(criticText);
      if (round.model_trouble) {
        var trouble = document.createElement('p');
        trouble.className = 'message-trouble';
        trouble.textContent = 'The critic thinks this model is struggling — pick another model below.';
        critic.appendChild(trouble);
      }
      els.messagesList.appendChild(critic);
    }

    if (hasMessage) {
      var claude = document.createElement('div');
      claude.className = 'message-bubble message-claude';
      var claudeAuthor = document.createElement('span');
      claudeAuthor.className = 'message-author';
      claudeAuthor.textContent = 'Claude';
      var claudeText = document.createElement('p');
      claudeText.textContent = round.message;
      claude.appendChild(claudeAuthor);
      claude.appendChild(claudeText);
      els.messagesList.appendChild(claude);
    }

    entries.forEach(function (entry) {
      els.messagesList.appendChild(buildYouBubble(entry, round));
    });
  }

  // ---------- model picker ----------

  function addModelOption(name, value, label, checked, probability, referenceSupported) {
    var opt = document.createElement('label');
    opt.className = 'model-option';

    var radio = document.createElement('input');
    radio.type = 'radio';
    radio.name = name;
    radio.value = value;
    radio.checked = checked;

    var text = document.createElement('span');
    text.className = 'model-option-label';
    text.textContent = label;

    opt.appendChild(radio);
    opt.appendChild(text);

    if (referenceSupported) {
      var badge = document.createElement('span');
      badge.className = 'ref-badge';
      badge.textContent = 'ref';
      opt.appendChild(badge);
    }

    if (typeof probability === 'number') {
      var prob = document.createElement('span');
      prob.className = 'model-option-prob';
      prob.textContent = Math.round(probability * 100) + '%';
      opt.appendChild(prob);
    }

    return { el: opt, radio: radio };
  }

  function renderModelPicker(round) {
    els.modelPicker.hidden = false;
    els.modelOptionsList.innerHTML = '';

    var locked = pendingFeedbackEntry(round);

    var choice;
    if (locked) {
      choice = locked.model ? { type: 'sent', id: locked.model, name: resolveModelName(locked.model, round) } : null;
    } else {
      choice = state.modelChoice[round.n] || null;
      if (choice && choice.type === 'suggested') {
        var stillThere = (round.models || []).some(function (m) { return m.id === choice.id; });
        if (!stillThere) {
          choice = null;
          state.modelChoice[round.n] = null;
        }
      }
    }

    var radioName = 'model-choice-' + round.n;

    var keep = addModelOption(radioName, 'keep', 'Keep ' + (round.model || 'current model'), !choice);
    if (!locked) {
      keep.radio.addEventListener('change', function () {
        state.modelChoice[round.n] = null;
      });
    }
    els.modelOptionsList.appendChild(keep.el);

    var choiceInModels = false;
    (round.models || []).forEach(function (m) {
      var label = m.name + ' — ' + formatPrice(m.price, m.unit);
      var selected = !!choice && (choice.type === 'suggested' || choice.type === 'sent') && choice.id === m.id;
      if (selected) choiceInModels = true;
      var row = addModelOption(radioName, m.id, label, selected, m.probability, m.reference_supported);
      if (!locked) {
        row.radio.addEventListener('change', function () {
          state.modelChoice[round.n] = { type: 'suggested', id: m.id, name: m.name };
        });
      }
      els.modelOptionsList.appendChild(row.el);
    });

    if (choice && (choice.type === 'manual' || (choice.type === 'sent' && !choiceInModels))) {
      var manualRow = addModelOption(radioName, choice.id, 'Manual: ' + choice.name, true);
      if (!locked) {
        manualRow.radio.addEventListener('change', function () {
          state.modelChoice[round.n] = choice;
        });
      }
      els.modelOptionsList.appendChild(manualRow.el);
    }

    var s = state.session;
    var modelsRequest = s && s.models_request;
    var pendingForRound = !!modelsRequest && modelsRequest.round === round.n && modelsRequest.status === 'pending';
    var errorForRound = !!modelsRequest && modelsRequest.round === round.n && modelsRequest.status === 'error';

    var accepted = s && s.state === 'accepted';
    els.modelPicker.disabled = !!locked || accepted;
    els.modelSuggestBtn.disabled = pendingForRound || accepted;
    if (pendingForRound) {
      els.modelSuggestStatus.hidden = false;
      els.modelSuggestStatus.className = 'model-suggest-status';
      els.modelSuggestStatus.textContent = 'asking Jev…';
    } else if (errorForRound) {
      els.modelSuggestStatus.hidden = false;
      els.modelSuggestStatus.className = 'model-suggest-status error';
      els.modelSuggestStatus.textContent = modelsRequest.error || 'Failed to fetch model suggestions.';
    } else {
      els.modelSuggestStatus.hidden = true;
      els.modelSuggestStatus.textContent = '';
    }
  }

  els.modelSuggestBtn.addEventListener('click', function () {
    var round = state.selectedRound;
    if (round == null) return;
    els.modelSuggestBtn.disabled = true;
    fetch('/api/models', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ round: round })
    }).then(function (res) {
      return res.json().then(function (data) { return { ok: res.ok, status: res.status, data: data }; });
    }).then(function (r) {
      if (!r.ok && r.status !== 409) {
        showError((r.data && r.data.error) || 'Failed to request model suggestions.');
      }
    }).catch(function (e) {
      showError('Network error requesting model suggestions: ' + e);
    }).finally(function () {
      var round2 = currentRound();
      if (round2) renderModelPicker(round2);
    });
  });

  // ---------- manual model dialog ----------

  function loadCatalogue() {
    if (state.catalogue === 'loading' || Array.isArray(state.catalogue)) return;
    state.catalogue = 'loading';
    renderManualModelList();
    fetch('/api/catalogue').then(function (res) {
      return res.json().then(function (data) { return { ok: res.ok, data: data }; });
    }).then(function (r) {
      if (!r.ok) {
        state.catalogue = 'error';
        state.catalogueError = (r.data && r.data.error) || 'Failed to load catalogue.';
      } else {
        state.catalogue = (r.data && r.data.models) || [];
      }
      renderManualModelList();
    }).catch(function (e) {
      state.catalogue = 'error';
      state.catalogueError = 'Network error loading catalogue: ' + e;
      renderManualModelList();
    });
  }

  function emptyManualRow(text) {
    var tr = document.createElement('tr');
    var td = document.createElement('td');
    td.className = 'manual-model-empty';
    td.colSpan = 4;
    td.textContent = text;
    tr.appendChild(td);
    return tr;
  }

  function sortCatalogueItems(items) {
    var key = state.catalogueSort.key;
    var dir = state.catalogueSort.dir === 'desc' ? -1 : 1;
    var sorted = items.slice();
    sorted.sort(function (a, b) {
      var av, bv;
      if (key === 'price') {
        av = typeof a.price === 'number' ? a.price : Infinity;
        bv = typeof b.price === 'number' ? b.price : Infinity;
      } else {
        av = (a.name || a.id || '').toLowerCase();
        bv = (b.name || b.id || '').toLowerCase();
      }
      if (av < bv) return -1 * dir;
      if (av > bv) return 1 * dir;
      return 0;
    });
    return sorted;
  }

  function updateManualModelSortHeaders() {
    [els.manualModelThName, els.manualModelThPrice].forEach(function (th) {
      var key = th === els.manualModelThName ? 'name' : 'price';
      if (state.catalogueSort.key === key) {
        th.setAttribute('aria-sort', state.catalogueSort.dir === 'desc' ? 'descending' : 'ascending');
      } else {
        th.setAttribute('aria-sort', 'none');
      }
    });
  }

  function setManualModelSort(key) {
    if (state.catalogueSort.key === key) {
      state.catalogueSort.dir = state.catalogueSort.dir === 'asc' ? 'desc' : 'asc';
    } else {
      state.catalogueSort.key = key;
      state.catalogueSort.dir = key === 'price' ? 'asc' : 'asc';
    }
    renderManualModelList();
  }

  function renderManualModelList() {
    var listEl = els.manualModelList;
    listEl.innerHTML = '';
    updateManualModelSortHeaders();

    if (state.catalogue === 'loading') {
      listEl.appendChild(emptyManualRow('Loading catalogue…'));
      return;
    }
    if (state.catalogue === 'error') {
      listEl.appendChild(emptyManualRow(state.catalogueError || 'Failed to load catalogue.'));
      return;
    }

    var q = els.manualModelSearch.value.trim().toLowerCase();
    var items = (state.catalogue || []).filter(function (m) {
      if (!q) return true;
      return (m.id || '').toLowerCase().indexOf(q) !== -1 || (m.name || '').toLowerCase().indexOf(q) !== -1;
    });
    items = sortCatalogueItems(items);

    if (!items.length) {
      listEl.appendChild(emptyManualRow('No models match'));
      return;
    }

    var round = state.selectedRound;
    var picked = round != null ? state.modelChoice[round] : null;

    items.forEach(function (m) {
      var row = document.createElement('tr');
      row.className = 'manual-model-row';
      row.tabIndex = 0;
      if (picked && picked.type === 'manual' && picked.id === m.id) {
        row.classList.add('picked');
        row.setAttribute('aria-selected', 'true');
      }

      var nameCell = document.createElement('td');
      nameCell.className = 'manual-model-name';
      nameCell.textContent = m.name;
      row.appendChild(nameCell);

      var idCell = document.createElement('td');
      idCell.className = 'manual-model-id';
      idCell.textContent = m.id;
      row.appendChild(idCell);

      var refCell = document.createElement('td');
      refCell.className = 'manual-model-ref';
      refCell.textContent = m.reference_supported ? 'yes' : '—';
      row.appendChild(refCell);

      var priceCell = document.createElement('td');
      priceCell.className = 'manual-model-price';
      priceCell.textContent = formatPrice(m.price, m.unit);
      row.appendChild(priceCell);

      row.addEventListener('click', function () {
        pickManualModel(m);
      });
      row.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          pickManualModel(m);
        } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          var rows = Array.prototype.slice.call(listEl.querySelectorAll('.manual-model-row'));
          var idx = rows.indexOf(row);
          var next = e.key === 'ArrowDown' ? rows[idx + 1] : rows[idx - 1];
          if (next) next.focus();
        }
      });
      listEl.appendChild(row);
    });
  }

  function pickManualModel(m) {
    var round = state.selectedRound;
    if (round == null) return;
    state.modelChoice[round] = { type: 'manual', id: m.id, name: m.name };
    els.manualDialog.close();
    var round2 = currentRound();
    if (round2) renderModelPicker(round2);
  }

  els.modelManualBtn.addEventListener('click', function () {
    els.manualModelSearch.value = '';
    els.manualDialog.showModal();
    loadCatalogue();
    renderManualModelList();
    els.manualModelSearch.focus();
  });

  els.manualModelClose.addEventListener('click', function () {
    els.manualDialog.close();
  });

  els.manualModelSearch.addEventListener('input', renderManualModelList);

  [els.manualModelThName, els.manualModelThPrice].forEach(function (th) {
    var key = th === els.manualModelThName ? 'name' : 'price';
    th.addEventListener('click', function () {
      setManualModelSort(key);
    });
    th.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        setManualModelSort(key);
      }
    });
  });

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
    var locked = pendingFeedbackEntry(round);
    var acceptedSet = locked
      ? new Set(locked.accepted_defects || [])
      : (state.acceptedDefects[round.n] || (state.acceptedDefects[round.n] = new Set()));

    defects.forEach(function (d) {
      var li = document.createElement('li');
      li.className = 'defect-item';

      var label = document.createElement('label');
      var cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = acceptedSet.has(d.id);
      cb.disabled = !!locked;
      if (!locked) {
        cb.addEventListener('change', function () {
          if (cb.checked) acceptedSet.add(d.id);
          else acceptedSet.delete(d.id);
        });
      }
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
    var modelChoice = state.modelChoice[round] || null;
    var model = modelChoice ? modelChoice.id : undefined;

    var afterMarkers = function (markers) {
      markers = markers || [];
      var hasContent = !!text || accepted_defects.length > 0 || !!annotation || notes.length > 0 || markers.length > 0 || !!modelChoice;
      if (!hasContent) {
        showError('Add feedback text, accept a defect, attach an annotation/notes, or pick a model before sending.');
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
          annotation: annotation,
          model: model
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
        delete state.modelChoice[round];
        var r2 = findRound(round);
        if (r2) renderAnnotationPreview(r2);
        if (state.acceptedDefects[round]) state.acceptedDefects[round].clear();
        renderDefects(r2 || {});
        if (r2) renderModelPicker(r2);
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
    els.modelPicker.disabled = accepted;
    els.modelManualBtn.disabled = accepted;

    els.workingBanner.hidden = !working;
    if (working) {
      var nextN = newestRoundNumber() + 1;
      var round = currentRound();
      var locked = round ? pendingFeedbackEntry(round) : null;
      if (locked) {
        var modelName = locked.model ? resolveModelName(locked.model, round) : (round.model || 'current model');
        els.workingBanner.textContent = 'Claude is working on round ' + nextN + ' with ' + modelName + '…';
      } else {
        els.workingBanner.textContent = 'Claude is working on round ' + nextN + '…';
      }
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
