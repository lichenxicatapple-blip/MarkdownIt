    let nativeToken = '';
    let nativeDocumentName = ''; 
    let nativeSymbols = {};
    function postNative(message) { window.webkit?.messageHandlers.reader.postMessage(message); }
    function prepareLocalResources(fragment, documentContent = false) {
      const images = [...fragment.querySelectorAll('img')];
      if (documentContent) {
        postNative({ type: 'localResources', token: nativeToken, paths: images.map(image => image.getAttribute('data-source-path') || image.getAttribute('src') || '') });
      }
      images.forEach(image => {
        if (documentContent && !image.closest('a[href]')) {
          const action = document.createElement('button');
          action.type = 'button';
          action.className = 'jm-image-action cursor-interaction';
          action.setAttribute('aria-label', image.getAttribute('alt') || t('Image'));
          action.setAttribute('aria-haspopup', 'menu');
          image.replaceWith(action);
          action.append(image);
        }
        const resourceToken = nativeToken;
        const path = image.getAttribute('data-source-path') || image.getAttribute('src') || '';
        if (!path || /^(https?:|data:|blob:)/i.test(path)) return;
        image.setAttribute('data-source-path', path);
        image.src = `jm-resource://${nativeToken}/image?path=${encodeURIComponent(path)}`;
        image.addEventListener('error', () => {
          if (resourceToken !== nativeToken) return;
          image.classList.add('jm-local-image-error');
        });
      });
    }
    let imageMenuID = null;
    function dismissImageMenu() {
      if (!imageMenuID) return;
      imageMenuID = null;
      postNative({ type: 'imageMenuDismiss', token: nativeToken });
    }
    function showImageMenu(image) {
      const index = [...reader.querySelectorAll('img')].indexOf(image);
      const reference = window.MarkdownIt.imageContext(index);
      if (!reference) return;
      window.getSelection()?.removeAllRanges();
      const rect = image.getBoundingClientRect();
      const top = Math.max(0, rect.top), bottom = Math.min(innerHeight, rect.bottom);
      imageMenuID = crypto.randomUUID();
      postNative({ type: 'imageMenu', id: imageMenuID, token: nativeToken, reference,
        x: Math.max(0, Math.min(innerWidth, rect.left + rect.width / 2)), y: (top + bottom) / 2 });
    }
    addEventListener('scroll', dismissImageMenu, { passive: true, capture: true });
    addEventListener('resize', dismissImageMenu, { passive: true });
    app.addEventListener('contextmenu', dismissImageMenu, true);
    function askNative(text) {
      readSelection();
      const selected = selectionAttachment || (text ? { text, markdown: text, mode: displayedMode } : null);
      const value = selected ? { ...selected, documentName: nativeDocumentName } : null;
      if (!value?.text.trim()) return;
      pinnedAnchor = captureReadingPosition();
      agentExperience.attach(value, value.rect || { left: 16, bottom: 80 });
    }
    app.addEventListener('click', event => {
      const image = event.target.closest('.mdv-article .jm-image-action')?.querySelector('img');
      if (image && event.button === 0 && !event.metaKey && !event.ctrlKey) {
        event.preventDefault(); event.stopImmediatePropagation();
        showImageMenu(image);
        return;
      }
      const link = event.target.closest(':is(.mdv-article,.mdv-rich-text) a[href]:not([href^="#"])');
      if (!link) return;
      event.preventDefault(); event.stopImmediatePropagation();
      postNative({type:'link', href:link.getAttribute('href')});
    }, true);
    let nativeSymbolSequence = 0;
    function updateSymbols() {
      if (!Object.keys(nativeSymbols).length) return;
      app.querySelectorAll('svg[data-lucide]:not([data-native-symbol])').forEach(svg => {
        const chrome = !!svg.closest('[data-reader-chrome]');
        const source = nativeSymbols[(chrome ? 'reader-' : '') + svg.dataset.lucide];
        if (!source) return;
        svg.dataset.nativeSymbol = 'true';
        const mask = 'native-symbol-' + (++nativeSymbolSequence);
        const inset = chrome ? 0 : 1;
        const size = 24 - inset * 2;
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.innerHTML = '<defs><mask id="' + mask + '"><image href="' + source + '" x="' + inset + '" y="' + inset + '" width="' + size + '" height="' + size + '" preserveAspectRatio="xMidYMid meet"/></mask></defs><rect width="24" height="24" fill="currentColor" mask="url(#' + mask + ')"/>';
      });
    }
    new MutationObserver(updateSymbols).observe(app, {childList:true,subtree:true});
    window.MarkdownIt = {
      async openDocument(document) {
        pendingNativeAgentConsent?.resolve(false);
        pendingNativeAgentConsent = null;
        nativeRequests.clear();
        frozenImageIDs.clear();
        dismissImageMenu();
        nativeUndoRequests.clear();
        postNative({ type: 'agentCancel', token: nativeToken });
        agentExperience.reset();
        nativeInputs.blur();
        nativeInputs.clear();
        nativeToken = document.token;
        nativeDocumentName = document.name || '';
        pendingNativeAgentEntry = null;
        renderedMarkdown = null; documentText = document.text;
        nativeSourcePosition = { line: 0, y: 0, atStart: true };
        ++modeRevision; modeAnimation?.cancel(); modeAnimation = null;
        readingLayout.style.removeProperty('opacity'); delete app.dataset.modeTransition;
        state.mode = 'preview'; displayedMode = 'preview'; state.agent = false;
        selection = ''; pinnedAnchor = null; lastPosition = null; layoutReadingAnchor = null; transitionAnchor = null;
        stopOutlineFollow(); outlineFollowPaused = false; outlineBody.scrollTop = 0;
        updateDocument(); render(); await documentReady;
        window.scrollTo(0,0);
        window.lucide.createIcons(); updateSymbols();
        postNative({type:'documentReady',token:nativeToken});
        return this.diagnostics();
      },
      toggleMode(payload) {
        if (payload?.anchor) nativeSourcePosition = payload.anchor;
        switchMode(state.mode === 'preview' ? 'source' : 'preview');
      },
      toggleOutline() {
        if (state.mode !== 'preview' || !headings.length) return;
        setPanelOpen('outline', !state.outline);
      },
      suppressSelection() { readSelection(); },
      askSelection(text) { askNative(text || window.getSelection()?.toString() || ''); },
      imageMenuDismissed(payload) { if (imageMenuID === payload.id) imageMenuID = null; },
      imageContext(index) {
        const contextImage = reader.querySelectorAll('img')[index];
        if (displayedMode !== 'preview' || !contextImage) return null;
        const range = document.createRange();
        range.selectNode(contextImage);
        const markdown = selectionMarkdown(range);
        const images = imageReferences(markdown);
        if (!images.length) return null;
        const bounds = contextImage.getBoundingClientRect();
        return { text: images[0].alt || t('Image'), markdown, images, mode: 'preview',
          documentName: nativeDocumentName, documentMarkdown: documentText,
          rect: { left: bounds.left, bottom: bounds.bottom } };
      },
      askImage(payload) {
        if (!payload?.images?.length) return;
        window.getSelection()?.removeAllRanges();
        pinnedAnchor = captureReadingPosition();
        agentExperience.attach(payload, payload.rect);
      },
      askSourceSelection(payload) {
        if (displayedMode !== 'source') return;
        const reference = sourceAttachment(payload);
        if (reference.text.trim()) agentExperience.attach(reference, reference.rect);
      },
      async sourceState(payload) {
        if (payload.token !== nativeToken) return false;
        documentText = payload.text;
        for (const detail of payload.events || []) app.dispatchEvent(new CustomEvent('mdv-source-history', { detail }));
        if (displayedMode === 'preview') { updateDocument(); render(); await documentReady; }
        return true;
      },
      toggleAgent() { agentExperience.toggleGlobal(); },
      resolveAgentEntry(payload) {
        const entry = pendingNativeAgentEntry;
        if (!entry || entry.id !== payload.id || entry.token !== nativeToken) return;
        pendingNativeAgentEntry = null;
        if (payload.allowed) entry.resume();
      },
      resolveAgentConsent(payload) {
        const pending = pendingNativeAgentConsent;
        if (!pending || pending.id !== payload.id || pending.token !== payload.token || pending.token !== nativeToken) return;
        pendingNativeAgentConsent = null;
        pending.resolve(payload.allowed === true);
      },
      async closeAgent() { setPanelOpen('agent', false); return await agentExperience.waitUntilClosed(); },
      setInputBottomInset(inset) {
        app.style.setProperty('--mdv-input-bottom-clearance', inset > 0 ? 'calc(' + inset + 'px + var(--mdv-floating-gap))' : '0px');
        nativeInputs.trackLayout();
      },
      agentInteraction() { notePanelInteraction('agent'); },
      updateAgentInput(payload) { nativeInputs.update(payload); },
      commitAgentInput(payload) { nativeInputs.commit(payload); },
      agentEvent(event) {
        if (event.token !== nativeToken) return;
        const request = nativeRequests.get(event.id);
        if (!request) return;
        if (event.type === 'images') { freezeImages(event.imageIDs || []); return; }
        if (event.type === 'change') request.change(event.change);
        else if (event.type === 'text') request.text(event.text);
        else {
          nativeRequests.delete(event.id);
          if (event.type === 'complete') request.complete(event);
          else if (event.type !== 'cancelled') request.fail(event.failure || { kind: 'service' });
        }
      },
      agentUndoResult(payload) {
        const resolve = nativeUndoRequests.get(payload.id);
        nativeUndoRequests.delete(payload.id);
        resolve?.(payload.result);
      },
      agentDiagnostics() {
        return { open: state.agent, modal: agent.hasAttribute('data-modal-active'), draft: agent.querySelector('textarea').value,
          reference: agent.querySelector('.mdv-composer-reference').textContent, referenceHTML: agent.querySelector('.mdv-composer-reference').innerHTML,
          turns: Array.from(agent.querySelectorAll('.mdv-turn')).map(turn => ({ role: turn.dataset.role, state: turn.dataset.state, text: turn.textContent, html: turn.innerHTML })),
          markup: agent.innerHTML };
      },
      reloadResources() {
        reader.querySelectorAll('img[src^="jm-resource:"]').forEach(image => { image.src = `jm-resource://${nativeToken}/image?path=${encodeURIComponent(image.dataset.sourcePath)}&revision=${Date.now()}`; });
      },
      theme(theme) {
        app.style.setProperty('--jm-font-scale', String(theme.fontScale));
        nativeSymbols = theme.symbols || {};
        Object.entries(theme.palette || {}).forEach(([name, value]) => app.style.setProperty('--mdv-' + name, value));
        updateSymbols();
      },
      async ready() { await documentReady; return true; },
      diagnostics() {
        const unsafeTags = Array.from(reader.querySelectorAll('script,iframe,form,style')).filter(node => node.tagName.toLowerCase() !== 'style' || !node.closest('.mdv-mermaid svg')).length;
        return {mode:displayedMode, targetMode:state.mode,  anchor:captureReadingPosition(), outline:state.outline && headings.length > 0, headings:headings.map(h=>h.textContent), math:reader.querySelectorAll('.katex').length, diagrams:reader.querySelectorAll('.mdv-mermaid svg').length, diagramErrors:reader.querySelectorAll('.mdv-diagram-error').length, localImages:Array.from(reader.querySelectorAll('img[src^="jm-resource:"]')).map(i=>({path:i.dataset.sourcePath,loaded:i.complete&&i.naturalWidth>0})), tables:reader.querySelectorAll('table').length, unsafeTags, source:documentText, questionVisible:false, selectedText:window.getSelection()?.toString() || '', overflow:document.documentElement.scrollWidth>window.innerWidth};
      },
      async scrollToSourceLine(line) {
        await documentReady; pinnedAnchor = null; lastPosition = null;
        restoreReadingPosition({line,y:24}); return this.diagnostics();
      }
    };
