/* Shared conversation UI. Model transport is provided by the host. */
(() => {
  const createNode = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  function icon(name) {
    const node = createNode('i');
    node.dataset.lucide = name;
    node.setAttribute('aria-hidden', 'true');
    return node;
  }
  function button(label, action, iconName) {
    const node = createNode('button', 'cursor-interaction');
    node.type = 'button';
    node.setAttribute('aria-label', label);
    if (action) node.dataset.agentAction = action;
    if (iconName) node.append(icon(iconName));
    else node.textContent = label;
    return node;
  }
  const { t, formatSeconds } = window.MarkdownItLocalization;
  const refreshIcons = () => window.lucide?.createIcons({ attrs: { width: 18, height: 18 } });
  function create(dependencies) {
    const { app, panel, renderMarkdown, fragmentIdentifier, enhance, motion, reducedMotion, onToggle, documentAttachment, provider, nativeInputs, onPresentationChange, ensureConfigured } = dependencies;
    const checkpoint = dependencies.onCheckpoint || (() => {});
    let restoring = false;
    let sheet = false;
    let documentLeading = 0;
    const scroll = panel.querySelector('.mdv-agent-scroll');
    const thread = panel.querySelector('.mdv-conversation');
    const composer = panel.querySelector('.mdv-composer');
    const input = composer.querySelector('textarea');
    const reference = composer.querySelector('.mdv-composer-reference');
    const sendButton = composer.querySelector('.mdv-agent-send');
    const useDocument = button(t("Reference current document"), 'use-document', 'file-text');
    useDocument.append(createNode('span', '', t("Reference document")));
    useDocument.classList.add('mdv-use-document');
    useDocument.hidden = true;
    composer.querySelector('.mdv-composer-input-row').before(useDocument);
    const announcement = panel.querySelector('[role="status"]');
    const scrim = createNode('div', 'mdv-agent-scrim');
    scrim.hidden = true;
    scrim.setAttribute('aria-hidden', 'true');
    panel.id = app.dataset.layout + '-conversation';
    app.append(scrim, panel);
    nativeInputs?.register(input, "question");
    const messages = [];
    const documentChanges = new Map();
    let attachment = null;
    let messageSequence = 0;
    let isOpen = false;
    let presented = false;
    let panelAnimation = null;
    let scrimAnimation = null;
    let panelRevision = 0;
    const closeWaiters = new Set();
    let activeStream = null;
    let pendingAuthorization = null;
    let conversationRevision = 0;
    let latestRequest = null;
    let referenceScrollTimer = 0;
    let followBottom = true;
    let followFrame = 0;
    let downwardScrollOrigin = null;
    let drag = null;
    const disclosureAnimations = new WeakMap();
    const seconds = spec => reducedMotion.matches ? 0 : spec.duration;
    function announce(text) { announcement.textContent = text; }
    function animateContent(element, spec = motion.message) {
      if (restoring || reducedMotion.matches) return;
      element.animate([{ opacity: 0, transform: 'translateY(4px)' }, { opacity: 1, transform: 'none' }], spec);
    }
    function disclosure(element, shown, finished) {
      const previous = disclosureAnimations.get(element);
      const start = element.hidden ? 0 : element.getBoundingClientRect().height;
      previous?.cancel();
      element.hidden = false;
      element.inert = !shown;
      element.setAttribute('aria-hidden', String(!shown));
      const finish = () => {
        element.hidden = !shown;
        element.style.removeProperty('height');
        element.style.removeProperty('overflow');
        disclosureAnimations.delete(element);
        finished?.();
      };
      if (restoring || reducedMotion.matches) { finish(); return; }
      element.style.overflow = 'hidden';
      const animation = element.animate([{ height: start + 'px', opacity: start ? 1 : 0 }, { height: shown ? element.scrollHeight + 'px' : '0px', opacity: shown ? 1 : 0 }], { ...motion.reference, fill: 'both' });
      disclosureAnimations.set(element, animation);
      animation.onfinish = () => {
        if (disclosureAnimations.get(element) !== animation) return;
        animation.cancel();
        finish();
      };
    }
    function rich(markdown, prefix) {
      const surface = createNode('div', 'mdv-rich-text');
      surface.dataset.component = 'RichText';
      surface.append(renderMarkdown(markdown, prefix));
      return surface;
    }
    function referenceLabel(value) {
      return value.scope === 'document'
        ? value.documentName || t('Current document')
        : value.text.trim() || value.images?.map(image => image.alt).filter(Boolean).join(', ') || t('Image');
    }
    function appendReference(parent, value) {
      const details = createNode('details', 'mdv-message-reference');
      const summary = createNode('summary', 'cursor-interaction');
      summary.setAttribute('aria-label', t("Expand reference"));
      summary.setAttribute('aria-expanded', 'false');
      summary.append(icon('chevron-right'), createNode('span', '', referenceLabel(value)));
      const body = createNode('div', 'mdv-rich-text');
      const prefix = 'reference-' + (++messageSequence);
      body.hidden = true;
      details.append(summary, body);
      parent.append(details);
      summary.addEventListener('click', event => {
        event.preventDefault();
        pauseFollowing();
        const shown = summary.getAttribute('aria-expanded') !== 'true';
        details.open = true;
        summary.setAttribute('aria-expanded', String(shown));
        summary.setAttribute('aria-label', shown ? t("Collapse reference") : t("Expand reference"));
        if (shown) {
          if (!body.childNodes.length) body.append(renderMarkdown(value.markdown, prefix, value.images));
          enhance(body);
        }
        disclosure(body, shown, () => { if (!shown) details.open = false; });
        checkpoint();
      });
      return details;
    }
    function renderAttachment(value, origin) {
      clearTimeout(referenceScrollTimer);
      reference.replaceChildren();
      reference.hidden = !value;
      useDocument.hidden = !!value;
      if (!value) return;
      const row = createNode('div', 'mdv-reference-row');
      const isDocument = value.scope === 'document';
      row.dataset.scope = isDocument ? 'document' : 'selection';
      const remove = button(t("Remove reference"), 'remove-reference', 'x');
      remove.classList.add('mdv-reference-remove');
      const body = createNode('div', 'mdv-reference-body');
      body.addEventListener('scroll', () => {
        body.dataset.scrolling = 'true';
        clearTimeout(referenceScrollTimer);
        referenceScrollTimer = setTimeout(() => { delete body.dataset.scrolling; }, 800);
      }, { passive: true });
      body.hidden = isDocument;
      const content = createNode('div', 'mdv-rich-text');
      content.dataset.component = 'RichText';
      const prefix = 'composer-reference-' + (++messageSequence);
      body.append(content);
      if (isDocument) {
        const toggle = button(t("Expand reference"), 'toggle-reference', 'file-text');
        toggle.classList.add('mdv-reference-toggle');
        toggle.setAttribute('aria-expanded', 'false');
        toggle.append(createNode('span', 'mdv-reference-label', referenceLabel(value)), icon('chevron-down'));
        row.append(toggle, remove);
        reference.append(row, body);
        toggle.addEventListener('click', event => {
          event.stopPropagation();
          const shown = toggle.getAttribute('aria-expanded') !== 'true';
          toggle.setAttribute('aria-expanded', String(shown));
          toggle.setAttribute('aria-label', shown ? t("Collapse reference") : t("Expand reference"));
          if (shown) {
            if (!content.childNodes.length) content.append(renderMarkdown(value.markdown, prefix, value.images));
            enhance(content);
          }
          disclosure(body, shown);
        });
      } else {
        body.setAttribute('role', 'region');
        body.setAttribute('aria-label', t("Referenced content"));
        body.tabIndex = 0;
        content.append(renderMarkdown(value.markdown, prefix, value.images));
        const marker = createNode('span', 'mdv-reference-icon');
        marker.setAttribute('aria-hidden', 'true');
        marker.append(icon(value.mode === 'source' ? 'code' : 'quote'));
        content.prepend(marker);
        row.append(body, remove);
        reference.append(row);
        enhance(content);
      }
      remove.addEventListener('click', event => { event.stopPropagation(); attachment = null; renderAttachment(null); });
      if (origin && !reducedMotion.matches) {
        const destination = reference.getBoundingClientRect();
        const dx = Math.max(-32, Math.min(32, origin.left - destination.left));
        reference.animate([{ opacity: 0, transform: 'translate(' + dx + 'px, 8px)' }, { opacity: 1, transform: 'none' }], motion.reference);
      }
      refreshIcons();
    }
    function updateSendState() {
      const generating = !!activeStream;
      sendButton.disabled = !!pendingAuthorization || (!generating && !input.value.trim());
      sendButton.setAttribute('aria-label', generating ? t("Stop generating") : t("Send message"));
      sendButton.type = generating ? 'button' : 'submit';
      const desired = generating ? 'square' : 'arrow-up';
      if (sendButton.dataset.icon !== desired) {
        sendButton.replaceChildren(icon(desired));
        sendButton.dataset.icon = desired;
        refreshIcons();
      }
      input.style.height = 'auto';
      const style = getComputedStyle(input);
      input.style.height = Math.max(parseFloat(style.minHeight), input.scrollHeight) + 'px';
    }
    function updateScrollEdge() {
      const overflow = scroll.scrollHeight - scroll.clientHeight;
      // WebKit can retain an old scroll offset after content shrinks to fit.
      scroll.toggleAttribute('data-scrolled', overflow > 1 && scroll.scrollTop > 1);
      scroll.toggleAttribute('data-more-below', overflow - scroll.scrollTop > 1);
    }
    function keepAtBottom() {
      if (followBottom && isOpen) scroll.scrollTop = scroll.scrollHeight;
      updateScrollEdge();
    }
    function cancelPendingFollow() {
      cancelAnimationFrame(followFrame);
      followFrame = 0;
      downwardScrollOrigin = null;
    }
    function pauseFollowing() {
      cancelPendingFollow();
      followBottom = false;
    }
    function followLatest() {
      cancelPendingFollow();
      followBottom = true;
      keepAtBottom();
    }
    const contentObserver = new ResizeObserver(keepAtBottom);
    contentObserver.observe(thread);
    contentObserver.observe(scroll);
    const atBottom = () => scroll.scrollHeight - scroll.clientHeight - scroll.scrollTop <= 1;
    function resumeFollowingAfterNavigation() {
      cancelPendingFollow();
      // Record the end the user is navigating toward before a keyboard or
      // composer reflow can move it. Rejoin immediately when already there.
      const bottom = scroll.scrollHeight - scroll.clientHeight;
      if (atBottom()) { followLatest(); return; }
      downwardScrollOrigin = scroll.scrollTop;
      followFrame = requestAnimationFrame(() => {
        followFrame = 0;
        if (atBottom() || scroll.scrollTop >= bottom - 1) followLatest();
      });
    }
    // Touch momentum may reach the end after the release frame. Require both
    // downward intent and actual movement, so a resize alone cannot rejoin.
    scroll.addEventListener('scroll', () => {
      // WebKit can deliver a scrolling update after the resize observer has
      // already placed the content at its new end. Following remains active
      // until navigation intent pauses it, including across that late update.
      if (followBottom) keepAtBottom();
      else if (downwardScrollOrigin !== null && scroll.scrollTop > downwardScrollOrigin && atBottom()) followLatest();
      updateScrollEdge();
    }, { passive: true });
    scroll.addEventListener('scrollend', () => { downwardScrollOrigin = null; }, { passive: true });
    // Resizing and layout also emit scroll events. Follow state comes from
    // navigation intent; only downward navigation at the end resumes following.
    scroll.addEventListener('wheel', event => {
      if (event.deltaY < 0) pauseFollowing();
      else if (event.deltaY > 0) resumeFollowingAfterNavigation();
    }, { passive: true });
    scroll.addEventListener('pointerdown', pauseFollowing, { passive: true });
    let touchY = null;
    let touchDirection = 0;
    scroll.addEventListener('touchstart', event => { touchY = event.touches[0]?.clientY ?? null; touchDirection = 0; }, { passive: true });
    scroll.addEventListener('touchmove', event => {
      const y = event.touches[0]?.clientY;
      if (touchY === null || y === undefined) return;
      touchDirection = touchY - y;
      touchY = y;
      pauseFollowing();
    }, { passive: true });
    scroll.addEventListener('touchend', () => {
      if (touchDirection > 0) resumeFollowingAfterNavigation();
      touchY = null;
    }, { passive: true });
    scroll.addEventListener('keydown', event => {
      if (['ArrowUp','PageUp','Home'].includes(event.key)) pauseFollowing();
      if (event.key === 'End') followLatest();
    });
    function notifyPresentation() {
      checkpoint();
      onPresentationChange?.({ open: isOpen, visible: !panel.hidden,
        modal: panel.hasAttribute('data-modal-active'), documentLeading });
    }
    function updateModality(shown, focus = false) {
      const modal = shown && sheet;
      panel.toggleAttribute('data-modal-active', modal);
      notifyPresentation();
      panel.setAttribute('role', modal ? 'dialog' : 'complementary');
      if (modal) panel.setAttribute('aria-modal', 'true');
      else panel.removeAttribute('aria-modal');
      const collapse = panel.querySelector('[data-agent-action="collapse"]');
      collapse.replaceChildren(icon(sheet ? 'chevron-down' : 'chevron-right'));
      refreshIcons();
      if (modal && focus && !panel.contains(document.activeElement)) collapse.focus({ preventScroll: true });
      [app.querySelector('.mdv-reader'), app.querySelector('.mdv-outline')].filter(Boolean).forEach(node => { node.inert = modal; });
    }
    function resolveCloseWaiters(closed) {
      for (const resolve of closeWaiters) resolve(closed);
      closeWaiters.clear();
    }
    function waitUntilClosed() {
      if (presented) return Promise.resolve(false);
      if (panel.hidden) return Promise.resolve(true);
      return new Promise(resolve => closeWaiters.add(resolve));
    }
    function present(shown, presentation) {
      if (shown) resolveCloseWaiters(false);
      const changed = sheet !== presentation.sheet;
      const previousRect = presentation.previousRect;
      documentLeading = presentation.documentLeading;
      sheet = presentation.sheet;
      viewportChanged();
      if (shown === presented) {
        if (changed) {
          panelAnimation?.cancel(); scrimAnimation?.cancel();
          panelAnimation = null; scrimAnimation = null;
          scrim.hidden = !shown || !sheet;
          panel.hidden = !shown;
          panel.inert = !shown;
          updateModality(shown);
          if (!shown) resolveCloseWaiters(true);
          if (shown && previousRect && !reducedMotion.matches) {
            const target = panel.getBoundingClientRect();
            const transform = `translate(${previousRect.left - target.left}px, ${previousRect.top - target.top}px) scale(${previousRect.width / target.width}, ${previousRect.height / target.height})`;
            panelAnimation = panel.animate([{ transform, transformOrigin: 'top left' }, { transform: 'none', transformOrigin: 'top left' }], motion.agentPanel);
          }
        } else notifyPresentation();
        keepAtBottom();
        return;
      }
      presented = shown;
      isOpen = shown;
      if (!shown) cancelPendingFollow();
      const revision = ++panelRevision;
      const hidden = panel.hidden;
      const style = hidden ? null : getComputedStyle(panel);
      const start = { opacity: hidden ? 0 : style.opacity, transform: hidden ? (sheet ? 'translateY(100%)' : 'translateX(24px)') : style.transform };
      panelAnimation?.cancel();
      scrimAnimation?.cancel();
      panel.hidden = false;
      panel.inert = !shown;
      nativeInputs?.trackLayout();
      app.classList.toggle('mdv-agent-open', shown);
      if (shown) updateModality(true, true);
      else { nativeInputs?.blur(); notifyPresentation(); }
      const useScrim = sheet && (shown || !scrim.hidden);
      if (useScrim) scrim.hidden = false;
      const finish = () => {
        if (revision !== panelRevision) return;
        panel.hidden = !shown;
        panelAnimation?.cancel();
        scrimAnimation?.cancel();
        panelAnimation = null;
        scrimAnimation = null;
        scrim.hidden = !shown || !sheet;
        if (!shown) {
          updateModality(false);
          resolveCloseWaiters(true);
        }
        keepAtBottom();
      };
      if (restoring || !seconds(motion.agentPanel)) { finish(); return; }
      panelAnimation = panel.animate([start, { opacity: shown ? 1 : 0, transform: shown ? 'none' : sheet ? 'translateY(100%)' : 'translateX(24px)' }], { ...motion.agentPanel, fill: 'both' });
      if (useScrim) scrimAnimation = scrim.animate([{ opacity: shown ? 0 : 1 }, { opacity: shown ? 1 : 0 }], { ...motion.agentPanel, fill: 'both' });
      panelAnimation.onfinish = finish;
    }
    function attach(value, rect, authorized = false) {
      if (!value?.text.trim()) return;
      if (!value.documentMarkdown) {
        const background = documentAttachment();
        value = { ...value, documentMarkdown: background.markdown, documentName: background.documentName };
      }
      if (!authorized && ensureConfigured) { const snapshot = { ...value }; ensureConfigured(() => attach(snapshot, rect, true)); return; }
      attachment = { ...value };
      followLatest();
      onToggle(true);
      renderAttachment(attachment, rect);
      input.focus({ preventScroll: true });
      checkpoint();
    }
    function addMessage(role, markdown, value) {
      const message = { id: ++messageSequence, role, markdown, attachment: value ? { ...value } : null };
      messages.push(message);
      const turn = createNode('article', 'mdv-turn mdv-' + role + '-turn');
      turn.dataset.component = 'ConversationTurn';
      turn.dataset.role = role;
      turn.setAttribute('aria-label', role === 'user' ? t("Your message") : t("AI response"));
      message.element = turn;
      if (value) message.reference = appendReference(turn, value);
      const surface = rich(markdown, 'message-' + message.id);
      message.surface = surface;
      turn.append(surface);
      thread.append(turn);
      animateContent(turn);
      enhance(surface);
      keepAtBottom();
      refreshIcons();
      checkpoint();
      return message;
    }
    function clearPending(record, fade = false) {
      if (fade && record.pendingRetiring) return;
      const { pending } = record;
      record.pendingAnimation?.cancel();
      record.pendingAnimation = null;
      if (!fade || reducedMotion.matches || !pending.isConnected) { pending.remove(); return; }
      record.pendingRetiring = true;
      // Keep the outgoing dots at their current pose and position. The answer
      // enters normal flow immediately, without waiting for a bounce to finish.
      const top = pending.offsetTop, left = pending.offsetLeft, width = pending.offsetWidth;
      pending.querySelectorAll('.mdv-agent-dot').forEach(dot => {
        const style = getComputedStyle(dot);
        const transform = style.transform, opacity = style.opacity;
        dot.style.animation = 'none';
        dot.style.transform = transform;
        dot.style.opacity = opacity;
      });
      Object.assign(pending.style, { position: 'absolute', top: top + 'px', left: left + 'px', width: width + 'px' });
      const animation = pending.animate([{ opacity: 1 }, { opacity: 0 }], motion.agentWaitingOut);
      record.pendingAnimation = animation;
      animation.finished.then(() => { pending.remove(); record.pendingAnimation = null; }, () => {});
    }
    function finishStream(record, stopped = false) {
      if (activeStream !== record) return;
      clearTimeout(record.renderTimer);
      if (record.liveMarkdown) renderLive(record);
      clearPending(record);
      record.message.element.dataset.state = stopped ? 'stopped' : 'complete';
      record.message.element.removeAttribute('aria-busy');
      if (!stopped) record.message.markdown = record.request.markdown;
      if (stopped) record.cancel?.();
      if (stopped) record.message.element.append(createNode('p', 'mdv-turn-status', t("Generation stopped")));
      activeStream = null;
      checkpoint();
      updateSendState();
      announce(stopped ? t("Generation stopped. The received content has been kept.") : t("Response complete. You can ask a follow-up question."));
      keepAtBottom();
    }
    const failureMessages = {
      interrupted: t("Response interrupted"),
      image: t("The image could not be read. Check that it is available and uses a supported format."),
      imagePermission: t("Allow access to the image folder, then retry."),
      permission: t("Allow sending to this AI service before trying again."),
      network: t("Unable to connect to the service"),
      timeout: t("Request timed out"),
      authentication: t("Authentication failed. Check your API key"),
      configuration: t("Check the service URL, API type, and model"),
      rateLimit: t("Too many requests"),
      service: t("Service temporarily unavailable"),
      response: t("Unable to read the response"),
      incomplete: t("Response incomplete"),
      contextLimit: t("Content exceeds the model’s context limit"),
      contextPreparation: t("Unable to prepare the conversation. Try again."),
      requestTooLarge: t("Request too large"),
      stale: t("The document has changed. No edits were made")
    };
    function clearRetry(request) {
      clearInterval(request?.cooldownTimer);
      request?.retryButton?.remove();
    }
    function failStream(record) {
      if (activeStream !== record) return;
      clearTimeout(record.renderTimer);
      if (record.liveMarkdown) renderLive(record);
      clearPending(record);
      activeStream = null;
      const { request, message, failure } = record;
      request.failure = failure;
      message.element.dataset.state = 'failed';
      message.element.removeAttribute('aria-busy');
      const partial = message.surface.hasChildNodes();
      const reason = partial ? t("Response interrupted") : failureMessages[failure.kind] || t("Request failed");
      const status = createNode('div', 'mdv-request-status');
      status.dataset.component = 'RequestStatus';
      status.setAttribute('role', 'group');
      status.setAttribute('aria-label', t("Request failed"));
      const retryLabel = partial ? t("Regenerate") : t("Retry");
      const retry = button(retryLabel, 'retry');
      status.append(createNode('p', '', reason), retry);
      message.element.append(status);
      request.status = status;
      request.retryButton = retry;
      request.retryAt = record.retryAt ?? Date.now() + Math.max(0, failure.retryAfterSeconds || 0) * 1000;
      function updateRetry() {
        const remaining = Math.max(0, Math.ceil((request.retryAt - Date.now()) / 1000));
        retry.disabled = remaining > 0;
        retry.textContent = remaining ? t('Retry in {duration}', { duration: formatSeconds(remaining) }) : retryLabel;
        if (!remaining) clearInterval(request.cooldownTimer);
      }
      updateRetry();
      if (retry.disabled) request.cooldownTimer = setInterval(updateRetry, 250);
      retry.addEventListener('click', () => {
        if (activeStream || latestRequest !== request || Date.now() < request.retryAt) return;
        authorizeSend(() => {
          if (latestRequest !== request) return;
          followLatest();
          // Keep keyboard focus in the response without opening the software keyboard.
          message.element.tabIndex = -1;
          message.element.focus({ preventScroll: true });
          streamReply(request);
        });
      });
      updateSendState();
      animateContent(status, motion.content);
      announce(retry.disabled ? t('{reason}. You can retry shortly.', { reason }) : t('{reason}. {action}.', { reason, action: retryLabel }));
      if (document.activeElement === message.element && !retry.disabled) retry.focus({ preventScroll: true });
      keepAtBottom();
      checkpoint();
    }
    function streamReply(request) {
      if (activeStream) return;
      const retrying = request.attempt++ > 0;
      clearRetry(request);
      request.status?.remove();
      const message = request.message || addMessage('assistant', '', null);
      request.message = message;
      const pending = createNode('div', 'mdv-request-status');
      pending.dataset.component = 'RequestStatus';
      const progress = createNode('div', 'mdv-agent-pending');
      progress.setAttribute('aria-hidden', 'true');
      for (let index = 0; index < 3; ++index) {
        const dot = createNode('span', 'mdv-agent-dot');
        dot.style.setProperty('--mdv-dot-index', index);
        progress.append(dot);
      }
      pending.append(createNode('span', 'mdv-sr-only', retrying ? t("Retrying…") : t("Generating…")));
      pending.append(progress);
      message.element.append(pending);
      message.element.dataset.state = retrying ? 'retrying' : 'pending';
      message.element.setAttribute('aria-busy', 'true');
      const record = { request, message, pending, replaceOnFirstBlock: message.surface.hasChildNodes(), liveMarkdown: '' };
      activeStream = record;
      request.failure = null;
      checkpoint();
      updateSendState();
      announce(retrying ? t("Retrying with the original question and reference.") : t("Generating a response."));
      record.cancel = provider.stream(request.snapshot, request.intent, {
        text(delta) {
          if (activeStream !== record) return;
          record.liveMarkdown += delta;
          checkpoint();
          if (!record.renderTimer) record.renderTimer = setTimeout(() => { record.renderTimer = null; renderLive(record); }, 100);
        },
        complete() {
          if (activeStream !== record) return;
          clearTimeout(record.renderTimer);
          request.markdown = record.liveMarkdown;
          if (record.liveMarkdown) renderLive(record);
          finishStream(record);
        },
        change(value) { appendDocumentChange(message, value); },
        fail(failure) { if (activeStream === record) { record.failure = failure; failStream(record); } }
      });
    }
    function renderLive(record) {
      if (activeStream !== record || !record.liveMarkdown.trim()) return;
      const prepared = renderMarkdown(record.liveMarkdown, 'message-' + record.message.id);
      const nodes = Array.from(prepared.childNodes).filter(node => node.nodeType !== Node.TEXT_NODE || node.textContent.trim());
      if (!nodes.length) return;
      clearPending(record, true);
      if (record.replaceOnFirstBlock) { record.message.surface.replaceChildren(); record.replaceOnFirstBlock = false; }
      const surface = record.message.surface;
      nodes.forEach((node, index) => {
        const markup = node.outerHTML || node.textContent;
        let block = surface.children[index];
        if (block?.dataset.markup === markup) return;
        const next = createNode('div', 'mdv-response-block');
        next.dataset.markup = markup;
        next.append(node);
        if (block) block.replaceWith(next); else surface.append(next);
        // Leave an unfinished Mermaid fence as readable source until closed.
        const fences = record.liveMarkdown.split('\n').filter(line => /^\s*(`{3,}|~{3,})/.test(line));
        if (!(index === nodes.length - 1 && fences.length % 2 && next.querySelector('.mdv-mermaid'))) enhance(next).then(keepAtBottom);
        if (!block) animateContent(next);
      });
      while (surface.children.length > nodes.length) surface.lastElementChild.remove();
      record.request.markdown = record.liveMarkdown;
      record.message.markdown = record.liveMarkdown;
      record.message.element.dataset.state = 'streaming';
      keepAtBottom();
    }
    function beginRequest(user) {
      clearRetry(latestRequest);
      user.intent = 'question';
      const currentDocument = documentAttachment();
      // The current quote and full-document inventory identify the same image
      // capture, so selected pixels need not be requested again through a tool.
      currentDocument.images = currentDocument.images?.map(image => user.attachment?.images?.find(selected => selected.source === image.source) || image);
      user.document = Object.freeze(currentDocument);
      const history = Object.freeze(messages.filter(message => message.role === 'user' || message.markdown.trim() || message.changes?.length).map(message => Object.freeze({
        role: message.role,
        intent: message.intent || null,
        document: message.document || null,
        markdown: message.markdown,
        attachment: message.attachment ? Object.freeze({ ...message.attachment }) : null,
        status: message.element.dataset.state || null,
        changes: message.changes?.map(change => Object.freeze({ before: change.edits.map(edit => edit.before).join('\n\n'), after: change.edits.map(edit => edit.after).join('\n\n'), status: change.status })) || null
      })));
      const snapshot = Object.freeze({ id: crypto.randomUUID(), question: user.markdown, attachment: user.attachment ? Object.freeze({ ...user.attachment }) : null, document: user.document, history });
      latestRequest = { snapshot, intent: 'question', markdown: '', attempt: 0 };
      streamReply(latestRequest);
    }
    function send() {
      if (activeStream || pendingAuthorization) return;
      if (nativeInputs && !nativeInputs.committing) { nativeInputs.requestSubmit('question'); return; }
      if (!input.value.trim()) return;
      authorizeSend(() => {
        if (!input.value.trim()) return;
        const text = input.value.trim();
        const value = attachment?.scope === 'document' ? documentAttachment() : attachment ? { ...attachment } : null;
        followLatest();
        const user = addMessage('user', text, value);
        input.value = '';
        attachment = null;
        renderAttachment(null);
        beginRequest(user);
        input.focus({ preventScroll: true });
      });
    }
    async function authorizeSend(action) {
      if (activeStream || pendingAuthorization) return;
      const pending = { revision: conversationRevision };
      pendingAuthorization = pending;
      updateSendState();
      try {
        const allowed = await provider.authorize();
        if (allowed && pendingAuthorization === pending && pending.revision === conversationRevision) action();
      } finally {
        if (pendingAuthorization === pending) pendingAuthorization = null;
        updateSendState();
      }
    }
    function diffLines(before, after) {
      const oldLines = before.split('\n');
      const newLines = after.split('\n');
      let commonStart = 0;
      while (commonStart < oldLines.length && commonStart < newLines.length && oldLines[commonStart] === newLines[commonStart]) commonStart++;
      let commonEnd = 0;
      while (commonEnd < oldLines.length - commonStart && commonEnd < newLines.length - commonStart && oldLines.at(-1 - commonEnd) === newLines.at(-1 - commonEnd)) commonEnd++;
      return [
        ...oldLines.slice(0, commonStart).map(text => ({ change: 'same', text })),
        ...oldLines.slice(commonStart, oldLines.length - commonEnd).map(text => ({ change: 'remove', text })),
        ...newLines.slice(commonStart, newLines.length - commonEnd).map(text => ({ change: 'insert', text })),
        ...oldLines.slice(oldLines.length - commonEnd).map(text => ({ change: 'same', text }))
      ];
    }
    function appendDocumentChange(message, value) {
      checkpoint();
      message.changes ||= [];
      const existing = message.changes.find(change => change.id === value.id);
      if (existing) {
        existing.saved = value.saved;
        existing.note.textContent = value.saved === false ? t("Changes have not been saved.") : '';
        existing.note.hidden = value.saved !== false;
        return;
      }
      const change = { ...value, status: 'applied' };
      message.changes.push(change);
      const card = createNode('section', 'mdv-proposal');
      card.dataset.component = 'DocumentChange';
      card.setAttribute('aria-label', t("Document changes"));
      const header = createNode('div', 'mdv-proposal-header');
      const title = createNode('span', '', t("Edited"));
      header.append(title);
      const diff = createNode('pre', 'mdv-diff');
      diff.setAttribute('aria-label', t("Changes: minus indicates removed text; plus indicates added text"));
      change.edits.forEach((edit, index) => {
        if (index) diff.append(createNode('span', 'mdv-diff-line', ''));
        diffLines(edit.before, edit.after).forEach(line => {
          const row = createNode('span', 'mdv-diff-line', (line.change === 'remove' ? '− ' : line.change === 'insert' ? '+ ' : '  ') + line.text);
          row.dataset.change = line.change;
          diff.append(row);
        });
      });
      const actions = createNode('div', 'mdv-proposal-actions');
      const undo = button(t("Undo this edit"), 'undo');
      undo.textContent = t("Undo");
      actions.append(undo);
      const note = createNode('p', 'mdv-proposal-note', value.saved === false ? t("Changes have not been saved.") : '');
      note.hidden = value.saved !== false;
      note.setAttribute('role', 'alert');
      change.note = note;
      change.showStatus = status => {
        const changed = change.status !== status;
        change.status = status;
        checkpoint();
        title.textContent = status === 'undone' ? t("Undone") : t("Edited");
        undo.hidden = status === 'undone';
        actions.hidden = status === 'undone';
        undo.disabled = false;
        note.hidden = true;
        if (changed) animateContent(title, motion.editFeedback);
      };
      documentChanges.set(change.id, change);
      card.append(header, diff, actions, note);
      message.element.append(card);
      undo.addEventListener('click', async () => {
        if (undo.disabled || change.status !== 'applied') return;
        undo.disabled = true;
        try {
          const result = await provider.undo(change.id);
          if (result.status === 'undone') {
            // History events already applied the undo. A later redo can precede
            // this save acknowledgement, so it must remain the source of truth.
            if (change.status !== 'undone') return;
            note.textContent = result.saved === 'false' ? t("The undo has not been saved.") : '';
            note.hidden = result.saved !== 'false';
            animateContent(title, motion.editFeedback);
            announce(t("This edit has been undone."));
          } else {
            note.textContent = result.message || t("Unable to undo this edit.");
            note.hidden = false;
            undo.disabled = result.error === 'stale';
          }
        } catch {
          note.textContent = t("Unable to undo. Try again."); note.hidden = false; undo.disabled = false;
        }
      });
      animateContent(card, motion.proposal);
      keepAtBottom();
      announce(t("Document edited. Undo is available."));
    }
    app.addEventListener('mdv-source-history', event => {
      const { transactionID, status } = event.detail;
      const change = documentChanges.get(transactionID);
      if (change && status) {
        change.showStatus(status);
        announce(status === 'undone' ? t("This edit has been undone.") : t("This edit has been redone."));
      }
    });
    composer.addEventListener('submit', event => { event.preventDefault(); send(); });
    sendButton.addEventListener('click', event => {
      if (!activeStream) return;
      event.preventDefault();
      finishStream(activeStream, true);
    });
    input.addEventListener('input', updateSendState);
    input.addEventListener('input', checkpoint);
    scroll.addEventListener('scroll', checkpoint, { passive: true });
    panel.querySelector('[data-agent-action="collapse"]').addEventListener('click', () => onToggle(false));
    function toggleGlobal(authorized = false) {
      if (!isOpen && !authorized && ensureConfigured) { ensureConfigured(() => toggleGlobal(true)); return; }
      if (isOpen) { onToggle(false); return; }
      // Entry intent determines the next request's context. Reopening globally
      // must never resurrect an abandoned selection; sent turns keep theirs.
      attachment = documentAttachment();
      onToggle(true);
      renderAttachment(attachment);
      input.focus({ preventScroll: true });
    }
    useDocument.addEventListener('click', () => {
      attachment = documentAttachment();
      renderAttachment(attachment);
      input.focus({ preventScroll: true });
    });
    scrim.addEventListener('click', () => onToggle(false));
    app.addEventListener('click', event => {
      const link = event.target.closest('.mdv-rich-text a[href^="#"]');
      if (!link) return;
      event.preventDefault();
      const target = document.getElementById(fragmentIdentifier(link));
      if (target && panel.contains(target)) {
        target.scrollIntoView({ block: 'nearest', behavior: reducedMotion.matches ? 'instant' : 'smooth' });
      }
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape') {
        if (isOpen) { event.preventDefault(); onToggle(false); }
      }
      if (event.key === 'Tab' && sheet && isOpen) {
        const controls = Array.from(panel.querySelectorAll('button:not([disabled]),textarea,a[href],summary')).filter(node => node.getClientRects().length && !node.closest('[inert]'));
        const first = controls[0];
        const last = controls.at(-1);
        if (event.shiftKey && (document.activeElement === first || !panel.contains(document.activeElement))) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }
    });
    const grabber = panel.querySelector('.mdv-agent-grabber');
    grabber.addEventListener('pointerdown', event => {
      if (!sheet || event.button !== 0) return;
      panelAnimation?.cancel();
      panelAnimation = null;
      drag = { y: event.clientY, offset: 0 };
      grabber.setPointerCapture(event.pointerId);
    });
    grabber.addEventListener('pointermove', event => {
      if (!drag) return;
      drag.offset = Math.max(0, event.clientY - drag.y);
      panel.style.transform = reducedMotion.matches ? 'none' : 'translateY(' + drag.offset + 'px)';
    });
    function endDrag(cancelled) {
      if (!drag) return;
      const offset = drag.offset;
      drag = null;
      if (!cancelled && offset > 72) { onToggle(false); panel.style.removeProperty('transform'); }
      else {
        if (!reducedMotion.matches) panel.animate([{ transform: 'translateY(' + offset + 'px)' }, { transform: 'none' }], motion.agentPanel);
        panel.style.removeProperty('transform');
      }
    }
    grabber.addEventListener('pointerup', () => endDrag(false));
    grabber.addEventListener('pointercancel', () => endDrag(true));
    reducedMotion.addEventListener('change', event => {
      if (event.matches) {
        panelAnimation?.finish();
        app.getAnimations({ subtree: true }).forEach(animation => {
          if (animation.effect?.getTiming().iterations !== Infinity) animation.finish();
        });
      }
    });
    function viewportChanged() {
      const viewport = window.visualViewport;
      if (sheet && viewport) {
        panel.style.setProperty('--mdv-agent-viewport-height', Math.max(160, viewport.height - 16) + 'px');
        panel.style.setProperty('--mdv-agent-visual-bottom-inset', Math.max(0, innerHeight - viewport.height - viewport.offsetTop) + 'px');
      } else {
        panel.style.removeProperty('--mdv-agent-viewport-height');
        panel.style.removeProperty('--mdv-agent-visual-bottom-inset');
      }
    }
    window.visualViewport?.addEventListener('resize', viewportChanged);
    window.visualViewport?.addEventListener('scroll', viewportChanged);
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      panel.querySelectorAll('.mdv-rich-text').forEach(surface => enhance(surface).then(keepAtBottom));
    });
    updateSendState();
    viewportChanged();
    function reset() {
      resolveCloseWaiters(false);
      cancelPendingFollow();
      ++conversationRevision;
      pendingAuthorization = null;
      if (activeStream) { activeStream.cancel?.(); clearTimeout(activeStream.renderTimer); clearPending(activeStream); }
      activeStream = null;
      clearRetry(latestRequest);
      latestRequest = null;
      messages.splice(0);
      documentChanges.clear();
      thread.replaceChildren();
      attachment = null;
      input.value = '';
      renderAttachment(null);
      updateSendState();
      onToggle(false);
    }
    function capture() {
      return {
        messages: messages.map(message => ({ id: message.id, role: message.role,
          markdown: activeStream?.message === message && activeStream.liveMarkdown ? activeStream.liveMarkdown : message.markdown,
          attachment: message.attachment, document: message.document, intent: message.intent,
          state: message.element.dataset.state || null, referenceExpanded: message.reference?.querySelector('summary').getAttribute('aria-expanded') === 'true',
          changes: message.changes?.map(({ id, edits, saved, status }) => ({ id, edits, saved, status })) || [] })),
        attachment, draft: input.value, referenceExpanded: reference.querySelector('[data-agent-action=toggle-reference]')?.getAttribute('aria-expanded') === 'true', referenceScroll: reference.querySelector('.mdv-reference-body')?.scrollTop || 0, scroll: scroll.scrollTop, followBottom,
        request: latestRequest ? { snapshot: latestRequest.snapshot, intent: latestRequest.intent,
          markdown: latestRequest.markdown, attempt: latestRequest.attempt, messageID: latestRequest.message?.id,
          failure: latestRequest.failure, retryAt: latestRequest.retryAt, interrupted: !!activeStream } : null
      };
    }
    function restore(value) {
      restoring = true;
      reset();
      for (const saved of value.messages || []) {
        messageSequence = saved.id - 1;
        const message = addMessage(saved.role, saved.markdown, saved.attachment);
        message.document = saved.document;
        message.intent = saved.intent;
        if (saved.referenceExpanded) message.reference?.querySelector('summary').click();
        message.element.dataset.state = saved.state || 'complete';
        for (const change of saved.changes || []) {
          appendDocumentChange(message, change);
          const restored = documentChanges.get(change.id);
          restored?.showStatus(change.status);
          if (restored && change.status !== 'undone' && change.saved === false) restored.note.hidden = false;
        }
        if (saved.state === 'stopped') message.element.append(createNode('p', 'mdv-turn-status', t("Generation stopped")));
      }
      attachment = value.attachment || null;
      input.value = value.draft || '';
      renderAttachment(attachment);
      if (value.referenceExpanded) reference.querySelector('[data-agent-action=toggle-reference]')?.click();
      const referenceBody = reference.querySelector('.mdv-reference-body');
      if (referenceBody) referenceBody.scrollTop = value.referenceScroll || 0;
      if (value.request) {
        const saved = value.request;
        const message = messages.find(message => message.id === saved.messageID);
        latestRequest = { ...saved, message, snapshot: Object.freeze(saved.snapshot) };
        if (message && (saved.interrupted || saved.failure)) {
          const record = { request: latestRequest, message, pending: createNode('div'),
            failure: saved.interrupted ? { kind: 'interrupted' } : saved.failure,
            retryAt: saved.interrupted ? 0 : saved.retryAt };
          activeStream = record;
          failStream(record);
        }
      }
      followBottom = value.followBottom !== false;
      cancelPendingFollow();
      scroll.scrollTop = value.scroll || 0;
      updateSendState();
    }
    function finishRestore(value) {
      restoring = false;
      cancelPendingFollow();
      followBottom = value.followBottom !== false;
      scroll.scrollTop = value.scroll || 0;
      if (followBottom) keepAtBottom();
      else updateScrollEdge();
    }
    return { attach, present, send, toggleGlobal, reset, waitUntilClosed, capture, restore, finishRestore };


  }
  window.MarkdownItAgent = { create };
})();
