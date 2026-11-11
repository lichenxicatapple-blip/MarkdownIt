    let nativeToken = '';
    let nativeRevision = 0;
    let nativeDocumentName = ''; 
    function postNative(message) { window.webkit?.messageHandlers.reader.postMessage(message); }
    const annotations = new window.MarkdownItAnnotations({reader,
      context: () => ({token:nativeToken,revision:nativeRevision,enabled:displayedMode==='preview'&&!app.dataset.modeTransition}),
      post: message => postNative({token:nativeToken,revision:nativeRevision,...message})});
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
      return agentExperience.attach(value, value.rect || { left: 16, bottom: 80 });
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
    let recoveryFrame = 0;
    let recovering = false;
    function scheduleRecovery() {
      if (recovering || recoveryFrame || !nativeToken) return;
      recoveryFrame = requestAnimationFrame(() => {
        recoveryFrame = 0;
        if (!recovering) postNative({ type: 'recoveryChanged', token: nativeToken });
      });
    }
    function captureRecovery() {
      return {mode:state.mode, transitioning:!!app.dataset.modeTransition, outline:state.outline, agent:state.agent,
        anchor:pinnedAnchor || captureReadingPosition(),
        outlineScroll:outlineBody.scrollTop, outlinePaused:outlineFollowPaused,
        branches:[...outlineBody.querySelectorAll('.mdv-outline-branch')].filter(branch=>branch.dataset.expanded !== 'true').map(branch=>branch.id),
        previewDetails:[...reader.querySelectorAll('details')].map(details=>details.open)};
    }
    addEventListener('scroll', scheduleRecovery, { passive: true, capture: true });
    app.addEventListener('toggle', scheduleRecovery, true);
    window.MarkdownIt = {
      captureRecovery,

      async openDocument(document) {
        recovering = true;
        delete app.dataset.ready;
        dismissImageMenu();
        nativeToken = document.token;
        nativeRevision = document.revision;
        annotations.reset(document.annotations);
        nativeDocumentName = document.name || '';
        renderedMarkdown = null; documentText = document.text;
        nativeSourcePosition = { line: 0, y: 0, atStart: true };
        ++modeRevision; modeAnimation?.cancel(); modeAnimation = null;
        readingLayout.style.removeProperty('opacity'); delete app.dataset.modeTransition;
        state.mode = document.mode === 'source' ? 'source' : 'preview'; displayedMode = state.mode; state.agent = false;
        selection = ''; pinnedAnchor = null; lastPosition = null; layoutReadingAnchor = null; transitionAnchor = null;
        stopOutlineFollow(); outlineFollowPaused = false; outlineBody.scrollTop = 0;
        updateDocument();
        const saved = document.recovery;
        if (saved) {
          state.mode = saved.mode === 'source' ? 'source' : 'preview';
          displayedMode = state.mode;
          state.outline = !!saved.outline;
          state.agent = !!saved.agent;
          nativeSourcePosition = saved.transitioning ? saved.anchor : document.sourcePosition || saved.anchor;
          pinnedAnchor = state.mode === 'source' ? nativeSourcePosition : saved.anchor;
          layoutReadingAnchor = pinnedAnchor;
          [...reader.querySelectorAll('details')].forEach((details, index) => { details.open = !!saved.previewDetails?.[index]; });
          for (const id of saved.branches || []) {
            const branch = document.getElementById(id);
            if (!branch?.classList.contains('mdv-outline-branch')) continue;
            branch.dataset.expanded = 'false'; branch.inert = true;
            branch.setAttribute('aria-hidden', 'true');
            app.querySelector(`[data-collapse-heading="${CSS.escape(id)}"]`)?.setAttribute('aria-expanded', 'false');
          }
        }
        render(); await documentReady;
        if (saved) {
          pinnedAnchor = state.mode === 'source' ? nativeSourcePosition : saved.anchor;
          restoreReadingPosition(pinnedAnchor);
          outlineFollowPaused = !!saved.outlinePaused;
          if (outlineFollowPaused) { stopOutlineFollow(); outlineBody.scrollTop = saved.outlineScroll || 0; }
        } else window.scrollTo(0,0);
        recovering = false;
        scheduleRecovery();
        window.lucide.createIcons(); rendering.updateSymbols();
        postNative({type:'documentReady',token:nativeToken});
        return this.diagnostics();
      },
      annotationState(payload) {
        if(payload.token!==nativeToken||payload.revision!==nativeRevision)return false;
        annotations.set(payload.records,payload.acknowledged);return true;
      },
      annotationSelectionAction(payload) {annotations.act(payload.action);},
      annotationPresentation(payload) {annotations.presentation(payload);},
      resolveAnnotationAnchor(payload) {
        const rect=annotations.rangeAt(payload)?.getBoundingClientRect();
        return rect?{x:rect.x,y:rect.y,width:rect.width,height:rect.height}:null;
      },
      annotationPencil(payload) {annotations.pencil(payload);},
      toggleMode(payload) {
        if (payload?.anchor) nativeSourcePosition = payload.anchor;
        switchMode(state.mode === 'preview' ? 'source' : 'preview');
      },
      toggleOutline() {
        if (state.mode !== 'preview' || !headings.length) return;
        postNative({type:'panelRequest',token:nativeToken,panel:'outline',toggle:true});
      },
      suppressSelection() { readSelection(); },
      askSelection(text) { return askNative(text || window.getSelection()?.toString() || ''); },
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
        return agentExperience.attach(payload, payload.rect);
      },
      askSourceSelection(payload) {
        if (displayedMode !== 'source') return;
        const reference = sourceAttachment(payload);
        if (reference.text.trim()) return agentExperience.attach(reference, reference.rect);
      },
      async sourceState(payload) {
        if (payload.token !== nativeToken) return false;
        documentText = payload.text;
        nativeRevision = payload.revision;
        annotations.records = payload.annotations || [];
        if (displayedMode === 'preview') { updateDocument(); render(); await documentReady; }
        return true;
      },
      finishOpening() { app.getBoundingClientRect(); app.dataset.ready='true'; },
      documentBackground() {return {text:documentText,markdown:documentText,images:documentImageReferences(),mode:displayedMode,scope:'document',documentName:nativeDocumentName};},
      panelLayout(value) {
        if (panelLayout && value.revision < panelLayout.revision) return;
        const changedColumns = panelLayout && (Boolean(panelLayout.outline && !panelLayout.overlay) !== Boolean(value.outline && !value.overlay));
        if (changedColumns && app.dataset.ready && displayedMode === 'preview') pinnedAnchor = captureReadingPosition();
        panelLayout = {...value,viewportWidth:app.clientWidth};
        state.agent = value.agent; state.outline = value.outline;
        app.dataset.compactWindow=String(value.compact);
        app.dataset.agentLayout=value.sheet?'sheet':'side'; app.dataset.outlineLayout=value.overlay?'overlay':'side';
        app.dataset.panelsCoexist=String(value.coexist); app.classList.toggle('mdv-agent-open',value.agent);
        reader.inert=value.modal; outline.inert=value.modal;
        render(); if(changedColumns && pinnedAnchor)restoreReadingPosition(pinnedAnchor);
      },
      reloadResources() {
        reader.querySelectorAll('img[src^="jm-resource:"]').forEach(image => { image.src = `jm-resource://${nativeToken}/image?path=${encodeURIComponent(image.dataset.sourcePath)}&revision=${Date.now()}`; });
      },
      theme(theme) { rendering.theme(theme); },
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
