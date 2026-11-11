(() => {
  const { t, apply: localize } = window.MarkdownItLocalization;
  const root = document.getElementById('mdv-reading-concept');
  const template = document.getElementById('mdv-app-template');
  const apps = Array.from(root.querySelectorAll('.mdv-app'));
  const motion = JSON.parse(document.getElementById('mdv-motion-spec').textContent);
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  reducedMotion.addEventListener('change', event => {
    if (event.matches) apps.forEach(app => app.getAnimations({ subtree: true }).forEach(animation => { if (animation.effect?.getTiming().iterations !== Infinity) animation.finish(); }));
  });
  apps.forEach(app => {
    app.append(template.content.cloneNode(true));
    localize(app);
    const layout = app.dataset.layout;
    const state = { mode: 'preview', agent: false, outline: false };
    let panelLayout = null;
    let layoutReadingAnchor = null;
    let selection = '';
    let selectionAttachment = null;
    const reader = app.querySelector('.mdv-article');
    const source = app.querySelector('.mdv-source-panel');
    let documentText = '';
    let nativeSourcePosition = { line: 0, y: 0, atStart: true };
    const readingLayout = app.querySelector('.mdv-reading-layout');
    const outline = app.querySelector('.mdv-outline');
    const outlineBody = app.querySelector('.mdv-outline-body');
    const outlineList = app.querySelector('.mdv-outline-list');
    const headings = [];
    let currentHeadingId = null;
    let outlineFollowFrame = 0;
    let outlineFollowPaused = false;
    let outlineFollowVelocity = 0;
    let outlineFollowTime = 0;
    let outlineFollowPosition = null;
    let renderedMarkdown = null;
    let jumpUntil = 0;
    let displayedMode = state.mode;
    let modeAnimation = null;
    let modeRevision = 0;
    let positioning = false;
    let transitionAnchor = null;
    let documentReady = Promise.resolve();
    let lastPosition = null;
    let pinnedAnchor = null;
    let positionFrame = 0;
    const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));
    function viewportSnapshot() {
      return { mode: displayedMode, value: documentText, windowY: window.scrollY, width: reader.clientWidth };
    }
    function unchangedViewport() {
      if (!lastPosition) return false;
      const now = viewportSnapshot();
      return Object.keys(now).every(key => typeof now[key] === 'number' ? Math.abs(now[key] - lastPosition.viewport[key]) < 1 : now[key] === lastPosition.viewport[key]);
    }
    function mappedBlocks() {
      return Array.from(reader.querySelectorAll('[data-source-start]:not(pre > code)')).map(element => ({
        element, start: Number(element.dataset.sourceStart), end: Number(element.dataset.sourceEnd), rect: element.getBoundingClientRect()
      })).filter(block => block.rect.height > 0);
    }
    function blockLine(block, y) {
      if (block.element.dataset.codeStart !== undefined) {
        const style = getComputedStyle(block.element);
        const start = Number(block.element.dataset.codeStart);
        const count = Number(block.element.dataset.codeCount);
        return start + clamp((y - block.rect.top - parseFloat(style.paddingTop)) / parseFloat(style.lineHeight), 0, count - .001);
      }
      return block.start + clamp((y - block.rect.top) / block.rect.height, 0, .9999) * Math.max(1, block.end - block.start);
    }
    function captureReadingPosition() {
      if (positioning && transitionAnchor) return { ...transitionAnchor };
      // Keep the same semantic anchor on an unchanged round trip, even when an edge
      // clamps scrolling or one image occupies far more space than its source line.
      if (displayedMode === 'source') return { ...nativeSourcePosition };
      if (unchangedViewport()) return { ...lastPosition.anchor };
      const y = Math.max(20, reader.getBoundingClientRect().top + parseFloat(getComputedStyle(reader).paddingTop));
      const blocks = mappedBlocks();
      const covering = blocks.filter(block => block.rect.top <= y && block.rect.bottom > y);
      // A paragraph/list row wins over its containing list, quote or table.
      covering.sort((a, b) => (a.end - a.start) - (b.end - b.start) || a.rect.height - b.rect.height);
      const block = covering[0] || blocks.filter(item => item.rect.bottom > y).sort((a, b) => a.rect.top - b.rect.top || a.rect.height - b.rect.height)[0] || blocks.at(-1);
      if (!block) return { line: 0, y, atStart: true };
      const anchorY = clamp(y, block.rect.top, block.rect.bottom);
      return { line: blockLine(block, anchorY), y: anchorY, atStart: window.scrollY < 1 };
    }
    function restoreReadingPosition(anchor) {
      if (displayedMode === 'source') {
        window.scrollTo({ top: 0, behavior: 'instant' });
        nativeSourcePosition = { ...anchor };
        postNative({ type: 'sourceRestore', token: nativeToken, anchor });
      } else {
        const blocks = mappedBlocks();
        const distance = block => anchor.line < block.start ? block.start - anchor.line : anchor.line >= block.end ? anchor.line - block.end + .001 : 0;
        blocks.sort((a, b) => distance(a) - distance(b) || (a.end - a.start) - (b.end - b.start) || a.rect.height - b.rect.height);
        const block = blocks[0];
        if (block) {
          let y;
          if (block.element.dataset.codeStart !== undefined) {
            const style = getComputedStyle(block.element);
            y = block.rect.top + parseFloat(style.paddingTop) + clamp(anchor.line - Number(block.element.dataset.codeStart), 0, Number(block.element.dataset.codeCount)) * parseFloat(style.lineHeight);
          } else {
            y = block.rect.top + clamp((anchor.line - block.start) / Math.max(1, block.end - block.start), 0, 1) * block.rect.height;
          }
          window.scrollTo({ top: anchor.atStart ? 0 : window.scrollY + y - Math.max(20, anchor.y), behavior: 'instant' });
        }
      }
      const current = currentReadingHeading();
      if (displayedMode === 'preview' && current) markHeading(current.id);
      lastPosition = { anchor: { ...anchor }, viewport: viewportSnapshot() };
      pinnedAnchor = { ...anchor };
      layoutReadingAnchor = { ...anchor };
    }
    // Reflow or a late image can change geometry. Keep the anchor until the user
    // starts another interaction, without chasing their subsequent scrolling.
    const positionObserver = new ResizeObserver(() => {
      if (displayedMode !== 'preview' || !pinnedAnchor || positionFrame) return;
      positionFrame = requestAnimationFrame(() => {
        positionFrame = 0;
        if (pinnedAnchor) restoreReadingPosition(pinnedAnchor);
      });
    });
    positionObserver.observe(reader);
    ['wheel', 'touchstart', 'pointerdown', 'keydown'].forEach(type => {
      document.addEventListener(type, () => { pinnedAnchor = null; }, { passive: true, capture: true });
    });
    function buildOutline() {
    stopOutlineFollow();
    outlineList.replaceChildren();
    const minimumLevel = headings.length ? Math.min(...headings.map(heading => Number(heading.tagName.slice(1)))) : 1;
    const containers = [{ level: minimumLevel - 1, list: outlineList }];
    headings.forEach((heading, index) => {
      const level = Number(heading.tagName.slice(1));
      while (containers.length > 1 && containers.at(-1).level >= level) containers.pop();
      if (!heading.id) heading.id = `${layout}-heading-${index}`;
      const item = document.createElement('li');
      const row = document.createElement('div');
      row.className = 'mdv-outline-row';
      row.dataset.component = 'OutlineRow';
      row.dataset.level = String(containers.length - 1);
      const link = document.createElement('a');
      link.href = `#${heading.id}`;
      link.dataset.tocTarget = heading.id;
      link.className = 'cursor-interaction';
      link.textContent = heading.textContent;
      const hasChildren = Number(headings[index + 1]?.tagName.slice(1)) > level;
      let branch = null;
      let children = null;
      if (hasChildren) {
        branch = document.createElement('div');
        branch.id = `${heading.id}-children`;
        branch.className = 'mdv-outline-branch';
        branch.dataset.expanded = 'true';
        const clip = document.createElement('div');
        clip.className = 'mdv-outline-branch-clip';
        children = document.createElement('ol');
        children.className = 'mdv-outline-children';
        const toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'cursor-interaction';
        toggle.dataset.collapseHeading = branch.id;
        toggle.setAttribute('aria-label', t('Collapse or expand {title}', { title: heading.textContent }));
        toggle.setAttribute('aria-expanded', 'true');
        toggle.setAttribute('aria-controls', branch.id);
        const icon = document.createElement('i');
        icon.dataset.lucide = 'chevron-right';
        icon.setAttribute('aria-hidden', 'true');
        toggle.append(icon);
        row.append(toggle);
        clip.append(children);
        branch.append(clip);
      } else {
        const spacer = document.createElement('span');
        spacer.className = 'mdv-outline-spacer';
        spacer.setAttribute('aria-hidden', 'true');
        row.append(spacer);
      }
      row.append(link);
      item.append(row);
      if (branch) item.append(branch);
      containers.at(-1).list.append(item);
      if (children) containers.push({ level, list: children });
    });
    if (window.lucide) window.lucide.createIcons({ attrs: { width: 16, height: 16 } });
    }
    function currentReadingHeading() {
      const visible = headings.filter(heading => heading.getClientRects().length);
      let current = visible[0];
      if (window.scrollY <= 0) return current;
      const viewport = window.visualViewport;
      const top = viewport?.offsetTop || 0;
      const bottom = top + (viewport?.height || innerHeight);
      const focus = top + (bottom - top) / 3;
      visible.forEach(heading => { if (heading.getBoundingClientRect().top <= focus) current = heading; });
      // Keep the final visible section reachable even when it cannot reach the focus line.
      const last = visible.at(-1);
      if (last && window.scrollY + bottom >= document.documentElement.scrollHeight - 2 && last.getBoundingClientRect().top < bottom) current = last;
      return current;
    }
    function stopOutlineFollow() {
      cancelAnimationFrame(outlineFollowFrame);
      outlineFollowFrame = 0;
      outlineFollowVelocity = 0;
      outlineFollowTime = 0;
      outlineFollowPosition = null;
    }
    function advanceOutlineFollow(now) {
      outlineFollowFrame = 0;
      if (outlineFollowPaused || !state.outline || displayedMode !== 'preview' || outlineBody.inert) { stopOutlineFollow(); return; }
      const current = outlineList.querySelector('[aria-current="location"]');
      if (!current) { stopOutlineFollow(); return; }
      const viewport = outlineBody.getBoundingClientRect();
      const row = current.getBoundingClientRect();
      const actualPosition = outlineBody.scrollTop;
      const maximum = Math.max(0, outlineBody.scrollHeight - outlineBody.clientHeight);
      const target = clamp(actualPosition + row.top + row.height / 2 - (viewport.top + outlineBody.clientTop + outlineBody.clientHeight / 2), 0, maximum);
      const position = clamp(outlineFollowPosition ?? actualPosition, 0, maximum);
      const offset = position - target;
      if (reducedMotion.matches || motion.layout.duration <= 0 || (Math.abs(offset) < .75 && Math.abs(outlineFollowVelocity) < .02)) {
        outlineBody.scrollTop = target;
        stopOutlineFollow();
        return;
      }
      // Critically damped following preserves velocity when the destination changes.
      // Use the shared layout response time and cap elapsed time after a dropped frame.
      const elapsed = outlineFollowTime ? Math.min(32, now - outlineFollowTime) : 0;
      outlineFollowTime = now;
      const rate = 6 / motion.layout.duration;
      const tangent = outlineFollowVelocity + rate * offset;
      const decay = Math.exp(-rate * elapsed);
      const next = target + (offset + tangent * elapsed) * decay;
      outlineFollowVelocity = (outlineFollowVelocity - rate * tangent * elapsed) * decay;
      // Preserve fractional progress even if WebKit quantizes the scroll offset.
      outlineFollowPosition = clamp(next, 0, maximum);
      outlineBody.scrollTop = outlineFollowPosition;
      if (next < 0 || next > maximum) outlineFollowVelocity = 0;
      outlineFollowFrame = requestAnimationFrame(advanceOutlineFollow);
    }
    function keepCurrentHeadingVisible() {
      if (!outlineFollowPaused && !outlineFollowFrame) outlineFollowFrame = requestAnimationFrame(advanceOutlineFollow);
    }
    function pauseOutlineFollow() {
      outlineFollowPaused = true;
      stopOutlineFollow();
    }
    ['pointerdown', 'touchstart', 'wheel'].forEach(type => outlineBody.addEventListener(type, pauseOutlineFollow, { passive: true }));
    const scrollingKeys = new Set(['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' ']);
    outlineBody.addEventListener('keydown', event => { if (scrollingKeys.has(event.key)) pauseOutlineFollow(); });
    function resumeOutlineFollow(event) {
      if (!outlineFollowPaused || outline.contains(event.target)) return;
      if (!readingLayout.contains(event.target) && event.target !== document.body && event.target !== document.documentElement) return;
      outlineFollowPaused = false;
      keepCurrentHeadingVisible();
    }
    ['pointerdown', 'touchstart', 'wheel'].forEach(type => document.addEventListener(type, resumeOutlineFollow, { passive: true, capture: true }));
    document.addEventListener('keydown', event => { if (scrollingKeys.has(event.key)) resumeOutlineFollow(event); });
    reducedMotion.addEventListener('change', () => keepCurrentHeadingVisible());
    function markHeading(id) {
      currentHeadingId = id;
      const links = Array.from(outlineList.querySelectorAll('[data-toc-target]'));
      const previous = outlineList.querySelector('[aria-current="location"]');
      let current = links.find(link => link.dataset.tocTarget === id);
      // A manually collapsed branch represents its current descendant.
      let branch;
      while (current && (branch = current.closest('.mdv-outline-branch[data-expanded="false"]'))) {
        current = branch.parentElement.querySelector(':scope > .mdv-outline-row > a');
      }
      links.forEach(link => {
        if (link === current) link.setAttribute('aria-current', 'location');
        else link.removeAttribute('aria-current');
      });
      if (current && current !== previous) keepCurrentHeadingVisible();
    }
    const outlineSizeObserver = new ResizeObserver(keepCurrentHeadingVisible);
    outlineSizeObserver.observe(outlineBody);
    outlineSizeObserver.observe(outlineList);
    outlineBody.addEventListener('transitionend', event => {
      if (event.propertyName === 'grid-template-rows') keepCurrentHeadingVisible();
    });
    function imageReferences(markdown, environment) {
      return [...markdownFragment(markdown, environment).querySelectorAll('img')].map(image => ({
        id: crypto.randomUUID(), source: image.getAttribute('data-source-path') || image.getAttribute('src') || '',
        alt: image.getAttribute('alt') || ''
      })).filter(image => image.source);
    }
    let imageInventoryMarkdown = null;
    let imageInventorySources = [];
    function documentImageReferences() {
      if (imageInventoryMarkdown !== documentText) {
        imageInventoryMarkdown = documentText;
        imageInventorySources = imageReferences(documentText).map(({ source, alt }) => ({ source, alt }));
      }
      return imageInventorySources.map(image => ({ ...image, id: crypto.randomUUID() }));
    }
    const rendering = window.MarkdownItRendering.create({app, documentPrefix: layout, token: () => nativeToken, prepareLocalResources});
    const {render: renderRichMarkdown, markdownFragment, fragmentIdentifier} = rendering;
    const enhanceDocument = (surface = reader) => rendering.enhance(surface);
    function updateDocument() {
      if (renderedMarkdown === documentText) return;
      renderedMarkdown = documentText;
      const documentFragment = renderRichMarkdown(renderedMarkdown, layout);
      reader.replaceChildren(documentFragment);
      annotations.mount(rendering.sourceMap);
      const documentHeadings = Array.from(reader.querySelectorAll('h1,h2,h3,h4,h5,h6'));
      headings.splice(0, headings.length, ...documentHeadings);
      buildOutline();
      markHeading(headings[0]?.id);
      documentReady = enhanceDocument();
    }
    function notePanelInteraction(panel) { postNative({type:'panelInteraction',token:nativeToken,panel}); }
    function setPanelOpen(panel, shown) {
      pinnedAnchor = app.dataset.ready && !panelLayout?.overlay && displayedMode === 'preview' ? captureReadingPosition() : null;
      postNative({type:'panelRequest',token:nativeToken,panel,open:shown});
    }
    const agentExperience = {attach(value) {return window.webkit.messageHandlers.conversation.postMessage({token:nativeToken,attachment:value});}};
    ['pointerdown','wheel','keydown'].forEach(type=>outline.addEventListener(type,()=>notePanelInteraction('outline'),{passive:true,capture:true}));
    let readingAnchorFrame = 0;
    window.addEventListener('scroll', () => {
      if (readingAnchorFrame) return;
      readingAnchorFrame = requestAnimationFrame(() => {
        readingAnchorFrame = 0;
        // A resize can emit scrolling before its width policy has reconciled.
        // Keep the previous semantic anchor through that intermediate layout.
        const widthChanging = panelLayout && Math.abs(app.clientWidth - panelLayout.width) >= .5;
        if (!pinnedAnchor && !positioning && !widthChanging) layoutReadingAnchor = captureReadingPosition();
      });
    }, { passive: true });
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

    const sourceProjection = (() => {
      let frame = 0, previous = '', trackUntil = 0;
      function schedule() { if (!frame) frame = requestAnimationFrame(sync); }
      function trackLayout() { trackUntil = performance.now() + Math.max(motion.modeOut.duration + motion.modeIn.duration, motion.layout.duration); schedule(); }
      function sync() {
        frame = 0;
        const box = source.getBoundingClientRect();
        const value = { type:'sourceLayout', token:nativeToken, visible:displayedMode === 'source',
          interactive:state.mode === displayedMode && !app.dataset.modeTransition && !source.closest('[inert]'),
          opacity:Number(getComputedStyle(readingLayout).opacity), x:box.x, y:box.y, width:box.width, height:box.height };
        const fingerprint = JSON.stringify(value);
        if (fingerprint !== previous) { previous = fingerprint; postNative(value); }
        if (performance.now() < trackUntil) schedule();
      }
      new MutationObserver(schedule).observe(app, {subtree:true, attributes:true, attributeFilter:['hidden','inert','class','style','data-mode-transition']});
      new ResizeObserver(trackLayout).observe(app);
      addEventListener('resize', trackLayout);
      schedule();
      return {trackLayout};
    })();

    updateDocument();
    function render() {
      scheduleRecovery();
      const hasOutline = headings.length > 0;
      window.webkit?.messageHandlers.reader.postMessage({type:'state', token:nativeToken, mode:state.mode, outline:state.outline && hasOutline, hasOutline});
      const outlineWasExpanded = outline.dataset.expanded === 'true';
      app.classList.toggle('mdv-showing-source', displayedMode === 'source');
      reader.hidden = displayedMode !== 'preview';
      source.hidden = displayedMode !== 'source';
      const showOutline = hasOutline && state.outline && displayedMode === 'preview';
      outline.hidden = !hasOutline || displayedMode !== 'preview';
      outline.dataset.expanded = String(showOutline);
      outlineBody.inert = !showOutline;
      outlineBody.setAttribute('aria-hidden', String(!showOutline));
      readingLayout.classList.toggle('mdv-with-outline', showOutline);
      if (!showOutline) stopOutlineFollow();
      if (showOutline && !outlineWasExpanded) keepCurrentHeadingVisible();
      sourceProjection.trackLayout();
      annotations.scheduleLayout();
    }
    function switchMode(nextMode) {
      pinnedAnchor = null;
      state.mode = nextMode;
      const revision = ++modeRevision;
      const opacity = getComputedStyle(readingLayout).opacity;
      modeAnimation?.cancel();
      modeAnimation = null;
      readingLayout.style.opacity = opacity;
      render();
      function finish() {
        if (revision !== modeRevision) return;
        readingLayout.style.removeProperty('opacity');
        delete app.dataset.modeTransition;
        annotations.scheduleLayout();
      }
      function fadeTo(target, spec, done) {
        if (revision !== modeRevision) return;
        const start = getComputedStyle(readingLayout).opacity;
        if (reducedMotion.matches || Math.abs(Number(start) - target) < .001) {
          readingLayout.style.opacity = String(target);
          done();
          return;
        }
        const animation = readingLayout.animate([{ opacity: start }, { opacity: target }], { ...spec, fill: 'forwards' });
        modeAnimation = animation;
        animation.onfinish = () => {
          if (revision !== modeRevision) return;
          readingLayout.style.opacity = String(target);
          animation.cancel();
          modeAnimation = null;
          done();
        };
      }
      if (nextMode === displayedMode) {
        const reveal = () => {
          if (revision !== modeRevision) return;
          if (positioning && transitionAnchor) restoreReadingPosition(transitionAnchor);
          positioning = false;
          transitionAnchor = null;
          app.dataset.modeTransition = 'in';
          fadeTo(1, motion.modeIn, finish);
        };
        if (positioning && displayedMode === 'preview') documentReady.then(reveal);
        else reveal();
      } else {
        app.dataset.modeTransition = 'out';
        fadeTo(0, motion.modeOut, async () => {
          const anchor = captureReadingPosition();
          transitionAnchor = anchor;
          positioning = true;
          pinnedAnchor = null;
          displayedMode = nextMode;
          if (displayedMode === 'preview') updateDocument();
          render();
          if (displayedMode === 'preview') await documentReady;
          if (revision !== modeRevision) return;
          restoreReadingPosition(anchor);
          positioning = false;
          transitionAnchor = null;
          app.dataset.modeTransition = 'in';
          fadeTo(1, motion.modeIn, finish);
        });
      }
    }
    function previewSelectionEndRect(range) {
      const terminal = range.cloneRange();
      const node = range.endContainer;
      if (node.nodeType === Node.TEXT_NODE && range.endOffset > 0) {
        const start = node === range.startContainer ? range.startOffset : 0;
        const text = node.textContent.slice(start, range.endOffset).trimEnd();
        if (text) {
          const lastCharacter = Array.from(text).at(-1);
          terminal.setStart(node, start + text.length - lastCharacter.length);
          terminal.setEnd(node, start + text.length);
        }
      }
      // Range order is stable for both forward and backward selections.
      const fragments = Array.from(terminal.getClientRects()).filter(rect => rect.width > 0 && rect.height > 0);
      const rect = fragments.at(-1) || range.getBoundingClientRect();
      return { left: rect.right, right: rect.right, top: rect.top, bottom: rect.bottom };
    }
    function cloneSelectionWithin(element, range, existingFragment) {
      if (!range.intersectsNode(element)) return null;
      const clipped = range.cloneRange();
      if (range.comparePoint(element, 0) >= 0) clipped.setStart(element, 0);
      if (range.comparePoint(element, element.childNodes.length) <= 0) clipped.setEnd(element, element.childNodes.length);
      if (clipped.collapsed) {
        const parent = element.parentNode;
        const index = Array.prototype.indexOf.call(parent.childNodes, element);
        if (range.comparePoint(parent, index) !== 0 || range.comparePoint(parent, index + 1) !== 0) return null;
      }
      let content = existingFragment || clipped.cloneContents();
      let parent = clipped.commonAncestorContainer.nodeType === Node.ELEMENT_NODE ? clipped.commonAncestorContainer : clipped.commonAncestorContainer.parentElement;
      while (parent && parent !== element && element.contains(parent)) {
        const wrapper = parent.cloneNode(false);
        wrapper.append(content);
        content = wrapper;
        parent = parent.parentElement;
      }
      const sources = Array.from(element.querySelectorAll('table')).filter(table => range.intersectsNode(table));
      const tables = [...(content.nodeType === Node.ELEMENT_NODE && content.tagName === 'TABLE' ? [content] : []), ...content.querySelectorAll('table')];
      tables.forEach((table, index) => {
        if (!sources[index] || table.parentElement?.closest('table')) return;
        const replacement = cloneSelectedTable(sources[index], range);
        if (table === content) content = replacement;
        else table.replaceWith(replacement);
      });
      return content;
    }
    function cloneSelectedTable(table, range) {
      const copy = table.cloneNode(false);
      if (table.caption) {
        const content = cloneSelectionWithin(table.caption, range);
        if (content) {
          const caption = table.caption.cloneNode(false);
          caption.append(content);
          copy.append(caption);
        }
      }
      const rows = Array.from(table.rows);
      const groupEnds = new Map();
      rows.forEach((row, index) => groupEnds.set(row.parentElement, index + 1));
      const occupied = [];
      const selected = [];
      rows.forEach((row, rowIndex) => {
        let column = 0;
        Array.from(row.cells).forEach(cell => {
          while (occupied[column] > rowIndex) column++;
          const width = cell.colSpan;
          const remainingRows = groupEnds.get(row.parentElement) - rowIndex;
          const height = Math.min(cell.rowSpan || remainingRows, remainingRows);
          const content = cloneSelectionWithin(cell, range);
          if (content) selected.push({ cell, content, rowIndex, column, width, height });
          for (let offset = 0; offset < width; offset++) occupied[column + offset] = rowIndex + height;
          column += width;
        });
      });
      if (!selected.length) return copy;
      const firstRow = selected[0].rowIndex;
      const lastRow = selected.at(-1).rowIndex;
      const firstColumn = Math.min(...selected.map(cell => cell.column));
      const lastColumn = Math.max(...selected.map(cell => cell.column + cell.width));
      const byRow = new Map();
      selected.forEach(cell => {
        if (!byRow.has(cell.rowIndex)) byRow.set(cell.rowIndex, []);
        byRow.get(cell.rowIndex).push(cell);
      });
      const groups = new Map();
      const spans = [];
      for (let rowIndex = firstRow; rowIndex <= lastRow; rowIndex++) {
        const sourceRow = rows[rowIndex];
        const row = sourceRow.cloneNode(false);
        const sourceGroup = sourceRow.parentElement;
        if (sourceGroup === table) copy.append(row);
        else {
          if (!groups.has(sourceGroup)) {
            const group = sourceGroup.cloneNode(false);
            groups.set(sourceGroup, group);
            copy.append(group);
          }
          groups.get(sourceGroup).append(row);
        }
        let column = firstColumn;
        function fillUntil(limit) {
          while (column < limit) {
            if (spans[column] > rowIndex) { column++; continue; }
            const start = column;
            while (column < limit && !(spans[column] > rowIndex)) column++;
            // Empty boundary cells preserve column positions without quoting
            // any unselected text or inventing a header.
            const blank = document.createElement(sourceGroup.tagName === 'THEAD' ? 'th' : 'td');
            if (column - start > 1) blank.colSpan = column - start;
            row.append(blank);
          }
        }
        (byRow.get(rowIndex) || []).forEach(selectedCell => {
          fillUntil(selectedCell.column);
          const cell = selectedCell.cell.cloneNode(false);
          const height = Math.min(selectedCell.height, lastRow - rowIndex + 1);
          if (height > 1) cell.rowSpan = height;
          else cell.removeAttribute('rowspan');
          cell.append(selectedCell.content);
          row.append(cell);
          for (let offset = 0; offset < selectedCell.width; offset++) spans[selectedCell.column + offset] = rowIndex + height;
          column = selectedCell.column + selectedCell.width;
        });
        fillUntil(lastColumn);
      }
      return copy;
    }
    function selectionMarkdown(selectionRange) {
      const range = selectionRange.cloneRange();
      const elementAt = node => node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
      // Generated math/diagram DOM describes layout, not editable source. Treat
      // either boundary inside such content as a reference to that semantic unit.
      const start = elementAt(range.startContainer)?.closest('.mdv-math,.mdv-mermaid');
      const end = elementAt(range.endContainer)?.closest('.mdv-math,.mdv-mermaid');
      if (start) range.setStartBefore(start);
      if (end) range.setEndAfter(end);
      const cell = elementAt(range.startContainer)?.closest('td,th,caption');
      const container = cell?.contains(range.endContainer) ? cell : reader;
      const fragment = cloneSelectionWithin(container, range);
      if (!fragment) return '';
      window.MarkdownItAnnotations.clean(fragment);
      rendering.cleanControls(fragment);
      const tick = String.fromCharCode(96);
      function htmlMarkup(node) {
        const copy = node.cloneNode(true);
        copy.querySelectorAll('.mdv-math,.mdv-mermaid').forEach(element => {
          const math = element.classList.contains('mdv-math');
          const source = document.createElement(math ? 'span' : 'pre');
          source.className = math ? 'mdv-math' : 'mdv-mermaid';
          if (math) source.dataset.mathDisplay = element.dataset.mathDisplay;
          source.textContent = (math ? element.dataset.mathSource : element.dataset.diagramSource) || element.textContent;
          element.replaceWith(source);
        });
        copy.querySelectorAll('img[data-source-path]').forEach(image => image.setAttribute('src', image.dataset.sourcePath));
        [copy, ...copy.querySelectorAll('*')].forEach(element => {
          for (const attribute of [...element.attributes]) {
            if (attribute.name.startsWith('data-') && attribute.name !== 'data-math-display') element.removeAttribute(attribute.name);
          }
        });
        return '\n\n' + copy.outerHTML + '\n\n';
      }
      function serialize(node) {
        if (node.nodeType === Node.TEXT_NODE) return node.textContent.replace(/[\\*_{}\[\]<>#$]/g, '\\$&').replaceAll(tick, '\\' + tick);
        if (node.nodeType !== Node.ELEMENT_NODE) return Array.from(node.childNodes, serialize).join('');
        if (node.classList.contains('mdv-math')) {
          const tex = node.dataset.mathSource || node.textContent;
          return node.dataset.mathDisplay === 'true' ? '\n\n$$\n' + tex + '\n$$\n\n' : '$' + tex + '$';
        }
        if (node.classList.contains('mdv-mermaid')) return '\n\n' + tick.repeat(3) + 'mermaid\n' + (node.dataset.diagramSource || node.textContent) + '\n' + tick.repeat(3) + '\n\n';
        if (node.tagName === 'PRE') {
          const language = node.querySelector('code')?.className.match(/language-([\w+-]+)/)?.[1] || '';
          const fence = tick.repeat(Math.max(3, ...Array.from(node.textContent.matchAll(new RegExp(tick + '+', 'g')), match => match[0].length + 1)));
          return '\n\n' + fence + language + '\n' + node.textContent.replace(/\n$/, '') + '\n' + fence + '\n\n';
        }
        if (node.tagName === 'CODE') {
          const text = node.textContent;
          const delimiter = tick.repeat(Math.max(1, ...Array.from(text.matchAll(/`+/g), match => match[0].length + 1)));
          const padding = /^[` ]|[` ]$/.test(text) && !/^ +$/.test(text) ? ' ' : '';
          return delimiter + padding + text + padding + delimiter;
        }
        if (['TABLE','UL','OL','BLOCKQUOTE'].includes(node.tagName)) return htmlMarkup(node);
        const content = Array.from(node.childNodes, serialize).join('');
        if (['STRONG','B','EM','I','DEL','S','SUP','SUB'].includes(node.tagName)) {
          // Preserve the preview's inline semantics. Rebuilding Markdown
          // delimiters can change their meaning at whitespace/punctuation edges.
          const tag = { B: 'strong', I: 'em', S: 'del' }[node.tagName] || node.tagName.toLowerCase();
          return '<' + tag + '>' + content + '</' + tag + '>';
        }
        if (node.tagName === 'A') return '[' + content + '](' + node.getAttribute('href') + ')';
        if (node.tagName === 'IMG') return '![' + (node.getAttribute('alt') || '') + '](' + (node.dataset.sourcePath || node.getAttribute('src')) + ')';
        if (node.tagName === 'BR') return '  \n';
        if (['P','DIV'].includes(node.tagName)) return '\n\n' + content.trim() + '\n\n';
        if (/^H[1-6]$/.test(node.tagName)) return '\n\n' + '#'.repeat(Number(node.tagName.slice(1))) + ' ' + content.trim() + '\n\n';
        return content;
      }
      return serialize(fragment).trim();
    }
    function sourceQuote(markdown, start, end, tokens, offsets) {
      const regions = [];
      for (const token of tokens) {
        if (!token.map) continue;
        const from = offsets[token.map[0]], to = offsets[token.map[1]] ?? documentText.length;
        if (from >= end || to <= start) continue;
        if (['fence', 'code_block'].includes(token.type)) {
          regions.push({ from, to, block: true, language: token.info.trim().split(/\s/)[0] });
        } else if (token.type === 'inline' && token.children?.some(child => child.type === 'code_inline')) {
          // Markdown-it maps blocks, not inline source offsets. Locate exact
          // backtick runs only inside blocks it has identified as inline code.
          const raw = documentText.slice(from, to), runs = [...raw.matchAll(/`+/g)];
          for (let index = 0; index < runs.length; index++) {
            const opening = runs[index];
            let slash = opening.index - 1;
            while (slash >= 0 && raw[slash] === '\\') slash--;
            if ((opening.index - 1 - slash) % 2) continue;
            const close = runs.findIndex((run, next) => next > index && run[0].length === opening[0].length);
            if (close < 0) continue;
            regions.push({ from: from + opening.index, to: from + runs[close].index + runs[close][0].length, block: false });
            index = close;
          }
        }
      }
      // Fully selected code keeps its own Markdown delimiters. A clipped code
      // span/block needs explicit code markup so its text cannot become a picture.
      for (const region of regions.filter(region => region.from < end && region.to > start && (start > region.from || end < region.to)).sort((a, b) => b.from - a.from)) {
        const first = Math.max(start, region.from), last = Math.min(end, region.to);
        const code = document.createElement('code');
        code.textContent = documentText.slice(first, last);
        if (region.language) code.className = 'language-' + region.language;
        const tick = String.fromCharCode(96);
        const delimiter = tick.repeat(Math.max(1, ...[...code.textContent.matchAll(/`+/g)].map(match => match[0].length + 1)));
        let replacement = delimiter + ' ' + code.textContent + ' ' + delimiter;
        if (region.block) { const pre = document.createElement('pre'); pre.append(code); replacement = '\n\n' + pre.outerHTML + '\n\n'; }
        markdown = markdown.slice(0, first - start) + replacement + markdown.slice(last - start);
      }
      return markdown;
    }
    function sourceAttachment({ start, end, rect }) {
        selection = documentText.slice(start, end);
        const first = documentText.slice(0, start).split('\n').length;
        const last = documentText.slice(0, end).split('\n').length;
        const location = first === last ? t('Source · Line {line}', { line: first }) : t('Source · Lines {first}–{last}', { first, last });
        let markdown = selection;
        const offsets = [0];
        documentText.split('\n').forEach(line => offsets.push(offsets.at(-1) + line.length + 1));
        const environment = {};
        const tokens = rendering.parse(documentText, environment);
        markdown = sourceQuote(markdown, start, end, tokens, offsets);
        const documentImages = documentImageReferences();
        const images = imageReferences(markdown, { references: environment.references })
          .filter(image => documentImages.some(actual => actual.source === image.source));
        if (images.length && !imageReferences(markdown).length) {
          const container = document.createElement('div');
          container.append(markdownFragment(markdown, { references: environment.references }));
          markdown = container.innerHTML;
        }
        return { text: selection, markdown, images, mode: 'source', start, end, location, rect, documentName: nativeDocumentName };
    }
    function readSelection() {
      const selected = window.getSelection();
      const text = selected?.toString().trim();
      if (displayedMode === 'preview' && !selected?.isCollapsed && selected.rangeCount && selected.anchorNode && selected.focusNode && reader.contains(selected.anchorNode) && reader.contains(selected.focusNode)) {
        selection = text;
        const range = selected.getRangeAt(0);
        const block = (selected.anchorNode.nodeType === Node.ELEMENT_NODE ? selected.anchorNode : selected.anchorNode.parentElement)?.closest('[data-source-start]');
        const location = block ? t('Text · Line {line}', { line: Number(block.dataset.sourceStart) + 1 }) : t('Selected text');
        const rect = previewSelectionEndRect(range);
        const markdown = selectionMarkdown(range);
        const images = imageReferences(markdown);
        if (!text && !images.length) { selectionAttachment = null; return null; }
        selectionAttachment = { text: text || images.map(image => image.alt).filter(Boolean).join(', ') || t('Image'), markdown, images, mode: 'preview', location, rect };
        return rect;
      }
      selection = '';
      selectionAttachment = null;
      return null;
    }
    document.addEventListener('selectionchange', readSelection);
    document.addEventListener('pointerdown', event => {
      if (event.button !== 0 || event.ctrlKey) return;
      if (state.outline && panelLayout?.overlay && !outline.contains(event.target)) {
        setPanelOpen('outline', false);
      }
    });

    app.addEventListener('click', event => {
      const contentLink = event.target.closest('.mdv-article a[href^="#"]');
      if (contentLink) {
        event.preventDefault();
        const target = document.getElementById(fragmentIdentifier(contentLink));
        if (target && reader.contains(target)) {
          pinnedAnchor = null;
          target.scrollIntoView({ block: 'start', behavior: reducedMotion.matches ? 'instant' : 'smooth' });
        }
        return;
      }
      const targetLink = event.target.closest('[data-toc-target]');
      if (targetLink && app.contains(targetLink)) {
        event.preventDefault();
        pinnedAnchor = null; lastPosition = null;
        outlineFollowPaused = false;
        if (panelLayout?.overlay) setPanelOpen('outline',false);
        render();
        markHeading(targetLink.dataset.tocTarget);
        keepCurrentHeadingVisible();
        jumpUntil = Date.now() + 650;
        document.getElementById(targetLink.dataset.tocTarget).scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
        return;
      }
      const button = event.target.closest('button');
      if (!button || !app.contains(button)) return;
      if (button.dataset.collapseHeading) {
        const branch = document.getElementById(button.dataset.collapseHeading);
        const expanded = branch.dataset.expanded !== 'true';
        branch.dataset.expanded = String(expanded);
        branch.inert = !expanded;
        branch.setAttribute('aria-hidden', String(!expanded));
        button.setAttribute('aria-expanded', String(expanded));
        markHeading(currentHeadingId);
      }
      render();

    });
    render();
    layoutReadingAnchor = captureReadingPosition();
    const panelSizeObserver = new ResizeObserver(() => {
      if (!app.dataset.ready) { if(pinnedAnchor)restoreReadingPosition(pinnedAnchor); return; }
      if (panelLayout && Math.abs(app.clientWidth - panelLayout.viewportWidth) < .5) return;
      pinnedAnchor = displayedMode === 'preview' ? pinnedAnchor || layoutReadingAnchor || captureReadingPosition() : null;
      render();
      if (pinnedAnchor) restoreReadingPosition(pinnedAnchor);
    });
    panelSizeObserver.observe(app);
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { documentReady = enhanceDocument(); });
    requestAnimationFrame(() => postNative({type:'ready'}));
    window.lucide.createIcons();
    let scrollQueued = false;
    function updateReadingHeading() {
      if (scrollQueued || reader.hidden || !app.getClientRects().length || Date.now() < jumpUntil) return;
      scrollQueued = true;
      requestAnimationFrame(() => {
        const current = currentReadingHeading();
        if (current) markHeading(current.id);
        scrollQueued = false;
      });
    }
    window.addEventListener('scroll', updateReadingHeading, { passive: true });
    window.addEventListener('resize', updateReadingHeading, { passive: true });
    window.visualViewport?.addEventListener('resize', updateReadingHeading, { passive: true });
  });
})();
