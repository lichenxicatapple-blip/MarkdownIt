(() => {
  const { t, apply: localize } = window.MarkdownItLocalization;
  const root = document.getElementById('mdv-reading-concept');
  const template = document.getElementById('mdv-app-template');
  const apps = Array.from(root.querySelectorAll('.mdv-app'));
  const motion = JSON.parse(document.getElementById('mdv-motion-spec').textContent);
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const markdownRenderer = window.markdownit({
    html: true,
    linkify: true,
    typographer: false,
    highlight(code, language) {
      return language && window.hljs.getLanguage(language) ? window.hljs.highlight(code, { language, ignoreIllegals: true }).value : '';
    }
  });
  markdownRenderer.use(window.MarkdownItCjkFriendly.default);
  markdownRenderer.use(window.markdownitTaskLists);
  markdownRenderer.use(window.markdownitFootnote);
  markdownRenderer.renderer.rules.footnote_caption = (tokens, index) => `[${tokens[index].meta.id + 1}]`;
  markdownRenderer.use(window.texmath, { engine: window.katex, delimiters: ['dollars', 'brackets'] });
  [...window.texmath.inlineRuleNames, ...window.texmath.blockRuleNames].forEach(type => {
    markdownRenderer.renderer.rules[type] = (tokens, index, options, env, renderer) => {
      const token = tokens[index];
      const display = type.startsWith('math_block') || type === 'math_inline_double';
      const tag = type.startsWith('math_block') ? 'div' : 'span';
      return `<${tag} class="mdv-math" data-math-display="${display}"${renderer.renderAttrs(token)}>${markdownRenderer.utils.escapeHtml(token.content)}</${tag}>`;
    };
  });
  // Retain the parser's zero-based, end-exclusive source ranges on rendered blocks.
  markdownRenderer.core.ruler.after('block', 'mdv_source_ranges', state => {
    state.tokens.forEach(token => {
      if (!token.map || token.type === 'inline' || token.nesting < 0) return;
      token.attrSet('data-source-start', String(token.map[0]));
      token.attrSet('data-source-end', String(token.map[1]));
      if (token.type === 'fence' || token.type === 'code_block') {
        const count = token.content.replace(/\n$/, '').split('\n').length;
        token.attrSet('data-code-start', String(token.map[0] + (token.type === 'fence' ? 1 : 0)));
        token.attrSet('data-code-count', String(count));
      }
      if (token.type === 'paragraph_open' && token.hidden) token.attrSet('class', 'mdv-tight-paragraph');
    });
  });
  ['fence', 'code_block'].forEach(type => {
    const original = markdownRenderer.renderer.rules[type];
    markdownRenderer.renderer.rules[type] = (tokens, index, options, env, renderer) => {
      const token = tokens[index];
      if (type === 'fence' && token.info.trim().split(/\s/)[0].toLowerCase() === 'mermaid') {
        return `<div class="mdv-mermaid" data-source-start="${token.map[0]}" data-source-end="${token.map[1]}"><pre><code>${markdownRenderer.utils.escapeHtml(token.content)}</code></pre></div>`;
      }
      return original(tokens, index, options, env, renderer).replace('<pre', `<pre${renderer.renderAttrs(token)}`);
    };
  });
  ['paragraph_open', 'paragraph_close'].forEach(type => {
    markdownRenderer.renderer.rules[type] = (tokens, index, options, env, renderer) => {
      const token = tokens[index];
      if (token.hidden) return token.nesting === 1 ? `<span${renderer.renderAttrs(token)}>` : '</span>';
      return renderer.renderToken(tokens, index, options);
    };
  });
  ['th_open', 'td_open'].forEach(type => {
    markdownRenderer.renderer.rules[type] = (tokens, index, options, env, renderer) => {
      const token = tokens[index];
      const alignment = token.attrGet('style')?.match(/text-align:(left|center|right)/)?.[1];
      if (alignment) token.attrSet('align', alignment);
      return renderer.renderToken(tokens, index, options);
    };
  });
  markdownRenderer.renderer.rules.html_block = (tokens, index, options, env, renderer) => {
    const token = tokens[index];
    return token.content.replace(/<([a-z][\w:-]*)(?=[\s>])/i, (opening, tag) => `<${tag}${renderer.renderAttrs(token)}`);
  };
  const renderImage = markdownRenderer.renderer.rules.image;
  markdownRenderer.renderer.rules.image = (tokens, index, options, env, renderer) => {
    const token = tokens[index];
    const sourcePath = token.attrGet('src');
    token.attrSet('data-source-path', sourcePath);
    return renderImage(tokens, index, options, env, renderer);
  };
  reducedMotion.addEventListener('change', event => {
    if (event.matches) apps.forEach(app => app.getAnimations({ subtree: true }).forEach(animation => { if (animation.effect?.getTiming().iterations !== Infinity) animation.finish(); }));
  });
  window.MarkdownItSourceMap.install(markdownRenderer);
  apps.forEach(app => {
    app.append(template.content.cloneNode(true));
    localize(app);
    const layout = app.dataset.layout;
    const state = { mode: 'preview', agent: false, outline: false };
    let lastActivePanel = 'outline';
    let panelLayout = null;
    let layoutReadingAnchor = null;
    let selection = '';
    let selectionAttachment = null;
    const reader = app.querySelector('.mdv-article');
    const source = app.querySelector('.mdv-source-panel');
    let documentText = '';
    let nativeSourcePosition = { line: 0, y: 0, atStart: true };
    const workspace = app.querySelector('.mdv-workspace');
    const agent = app.querySelector('.mdv-agent');
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
    const enhancementRevisions = new WeakMap();
    let diagramSequence = 0;
    const diagramSources = new WeakMap();
    const colorProbe = document.createElement('span');
    colorProbe.hidden = true;
    app.append(colorProbe);
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
    async function enhanceDocument(surface = reader) {
      const revision = (enhancementRevisions.get(surface) || 0) + 1;
      enhancementRevisions.set(surface, revision);
      surface.querySelectorAll('.mdv-math').forEach(element => {
        if (element.dataset.mathRendered) return;
        const tex = element.dataset.mathSource || element.textContent;
        element.dataset.mathSource = tex;
        window.katex.render(tex, element, { displayMode: element.dataset.mathDisplay === 'true', throwOnError: false, trust: false, strict: 'ignore', output: 'htmlAndMathml' });
        element.dataset.mathRendered = 'true';
      });
      const resolveColor = name => {
        colorProbe.style.color = `var(${name})`;
        return getComputedStyle(colorProbe).color;
      };
      const paper = getComputedStyle(app).backgroundColor;
      const ink = getComputedStyle(app).color;
      window.mermaid.initialize({
        startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true,
        theme: 'base', fontFamily: '-apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif',
        themeVariables: {
          darkMode: matchMedia('(prefers-color-scheme: dark)').matches,
          background: paper, primaryColor: resolveColor('--mdv-chrome'), primaryTextColor: ink,
          primaryBorderColor: resolveColor('--mdv-line'), secondaryColor: paper,
          tertiaryColor: resolveColor('--mdv-source'), textColor: ink, lineColor: resolveColor('--mdv-muted'),
          actorBkg: resolveColor('--mdv-chrome'), actorTextColor: ink, actorBorder: resolveColor('--mdv-line'),
          signalColor: ink, signalTextColor: ink, noteBkgColor: resolveColor('--mdv-source'), noteTextColor: ink,
          edgeLabelBackground: paper, fontSize: '16px'
        },
        flowchart: { htmlLabels: false, useMaxWidth: false }, sequence: { useMaxWidth: false }
      });
      const diagramTheme = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      for (const element of surface.querySelectorAll('.mdv-mermaid')) {
        if (element.dataset.diagramTheme === diagramTheme) continue;
        const code = diagramSources.get(element) || element.textContent;
        diagramSources.set(element, code);
        element.dataset.diagramSource = code;
        try {
          const { svg } = await window.mermaid.render(`${layout}-diagram-${++diagramSequence}`, code);
          if (revision !== enhancementRevisions.get(surface) || !element.isConnected) return;
          element.innerHTML = svg;
          element.dataset.diagramTheme = diagramTheme;
          const diagram = element.querySelector('svg');
          if (diagram.viewBox.baseVal.width && diagram.viewBox.baseVal.height) {
            diagram.style.width = `${diagram.viewBox.baseVal.width}px`;
            diagram.style.height = `${diagram.viewBox.baseVal.height}px`;
          }
          diagram.setAttribute('role', 'img');
          if (!diagram.hasAttribute('aria-label') && !diagram.hasAttribute('aria-labelledby')) diagram.setAttribute('aria-label', t("Mermaid diagram"));
        } catch (error) {
          if (revision !== enhancementRevisions.get(surface) || !element.isConnected) return;
          const pre = document.createElement('pre');
          const codeElement = document.createElement('code');
          codeElement.textContent = code;
          pre.append(codeElement);
          const message = document.createElement('p');
          message.className = 'mdv-diagram-error';
          message.textContent = t("Unable to parse the Mermaid diagram. The original content has been kept.");
          element.replaceChildren(message, pre);
        }
      }
      await document.fonts.ready;
    }
    function markdownFragment(markdown, environment = {}) {
      return window.DOMPurify.sanitize(markdownRenderer.render(markdown, environment), {
        USE_PROFILES: { html: true }, RETURN_DOM_FRAGMENT: true,
        ALLOW_DATA_ATTR: false,
        ADD_ATTR: ['data-source-start', 'data-source-end', 'data-code-start', 'data-code-count', 'data-source-path', 'data-math-display', 'data-reader-text'],
        FORBID_TAGS: ['style', 'script', 'iframe', 'object', 'embed', 'form', 'textarea', 'button', 'select', 'option', 'link', 'meta', 'base'],
        FORBID_ATTR: ['style', 'name', 'autofocus', 'form', 'contenteditable', 'tabindex']
      });
    }
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
    const frozenImageIDs = new Set();
    function freezeImages(ids) {
      ids.forEach(id => frozenImageIDs.add(id));
      app.querySelectorAll('img[data-agent-image-id]').forEach(image => {
        if (frozenImageIDs.has(image.dataset.agentImageId)) image.src = `jm-image://${nativeToken}/${image.dataset.agentImageId}`;
      });
    }
    function fragmentIdentifier(link) {
      const value = link.getAttribute('href').slice(1);
      try { return decodeURIComponent(value); }
      catch { return value; }
    }
    function assignHeadingIDs(fragment) {
      const used = new Set([...fragment.querySelectorAll('[id]')].map(element => element.id));
      fragment.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(heading => {
        if (heading.id) return;
        // Section links use the rendered title, without formatting or punctuation.
        const slug = heading.textContent.trim().toLowerCase().replace(/[^\p{L}\p{M}\p{N}_ -]/gu, '').replace(/ /g, '-');
        // Empty titles retain an outline-only ID without taking a named section's anchor.
        if (!slug) return;
        let id = slug, suffix = 0;
        while (used.has(id)) id = `${slug}-${++suffix}`;
        heading.id = id;
        used.add(id);
      });
    }
    function renderRichMarkdown(markdown, prefix, images = []) {
      const environment = prefix === layout ? window.MarkdownItSourceMap.environment() : {};
      const documentFragment = markdownFragment(markdown, environment);
      if (prefix === layout) documentSourceMap = environment.readerMap.runs;
      documentFragment.querySelectorAll('input').forEach(input => {
        if (input.type !== 'checkbox') input.remove();
        else input.disabled = true;
      });
      documentFragment.querySelectorAll('[class]').forEach(element => {
        Array.from(element.classList).filter(name => name.startsWith('mdv-') && !['mdv-tight-paragraph', 'mdv-math', 'mdv-mermaid'].includes(name)).forEach(name => element.classList.remove(name));
      });
      assignHeadingIDs(documentFragment);
      const contentIds = new Map();
      documentFragment.querySelectorAll('[id]').forEach((element, index) => {
        const original = element.id;
        element.id = `${prefix}-content-${index}-${original}`;
        if (!contentIds.has(original)) contentIds.set(original, element.id);
      });
      documentFragment.querySelectorAll('a[href^="#"]').forEach(link => {
        const id = fragmentIdentifier(link);
        if (contentIds.has(id)) link.setAttribute('href', `#${encodeURIComponent(contentIds.get(id))}`);
      });
      documentFragment.querySelectorAll('a[href]:not([href^="#"])').forEach(link => {
        link.setAttribute('target', '_blank');
        link.setAttribute('rel', 'noopener noreferrer');
      });
      documentFragment.querySelectorAll('img').forEach(image => {
        const path = image.getAttribute('data-source-path') || image.getAttribute('src');
        image.setAttribute('data-source-path', path || '');
      });
      prepareLocalResources(documentFragment, prefix === layout);
      // Quote images keep the immutable native snapshot after it is sent/read.
      documentFragment.querySelectorAll('img').forEach(image => {
        const reference = images.find(value => value.source === image.dataset.sourcePath);
        if (!reference) return;
        image.dataset.agentImageId = reference.id;
        if (frozenImageIDs.has(reference.id)) image.src = `jm-image://${nativeToken}/${reference.id}`;
      });
      documentFragment.querySelectorAll('summary').forEach(summary => summary.classList.add('cursor-interaction'));
      return documentFragment;
    }
    let documentSourceMap = new Map();
    function updateDocument() {
      if (renderedMarkdown === documentText) return;
      renderedMarkdown = documentText;
      const documentFragment = renderRichMarkdown(renderedMarkdown, layout);
      reader.replaceChildren(documentFragment);
      annotations.mount(documentSourceMap);
      const documentHeadings = Array.from(reader.querySelectorAll('h1,h2,h3,h4,h5,h6'));
      headings.splice(0, headings.length, ...documentHeadings);
      buildOutline();
      markHeading(headings[0]?.id);
      documentReady = enhanceDocument();
    }
    function notePanelInteraction(panel) { lastActivePanel = panel; }
    function setPanelOpen(panel, shown) {
      pinnedAnchor = displayedMode === 'preview' ? captureReadingPosition() : null;
      state[panel] = shown;
      if (shown) notePanelInteraction(panel);
      render();
    }
    function resolvePanelLayout() {
      const style = getComputedStyle(app);
      const value = name => parseFloat(style.getPropertyValue(name));
      const width = app.clientWidth;
      const documentMinimum = value('--mdv-document-minimum-width');
      const agentMinimum = value('--mdv-agent-minimum-width');
      const agentMaximum = value('--mdv-agent-width');
      const edge = value('--mdv-agent-edge-inset');
      const outlineWidth = value('--mdv-outline-width');
      const side = width >= documentMinimum + agentMinimum + edge;
      const coexist = width >= documentMinimum + agentMinimum + edge + outlineWidth;
      if (state.agent && state.outline && headings.length && displayedMode === 'preview' && !coexist) {
        state[lastActivePanel === 'outline' ? 'agent' : 'outline'] = false;
      }
      const outlineOpen = state.outline && headings.length && displayedMode === 'preview';
      const overlay = width < documentMinimum + outlineWidth;
      const available = width - documentMinimum - edge - (outlineOpen && !overlay ? outlineWidth : 0);
      const agentWidth = clamp(width * value('--mdv-agent-width-fraction'), agentMinimum, Math.min(agentMaximum, Math.max(agentMinimum, available)));
      const next = { width, sheet: !side, overlay, coexist, agentWidth,
        documentLeading: outlineOpen && !overlay ? outlineWidth : 0,
        reservedWidth: state.agent && side ? agentWidth + edge : 0 };
      app.dataset.agentLayout = next.sheet ? 'sheet' : 'side';
      app.dataset.outlineLayout = overlay ? 'overlay' : 'side';
      app.dataset.panelsCoexist = String(coexist);
      app.style.setProperty('--mdv-agent-panel-width', agentWidth + 'px');
      app.style.setProperty('--mdv-agent-reserved-width', next.reservedWidth + 'px');
      panelLayout = next;
      return next;
    }
    ['pointerdown', 'wheel', 'keydown'].forEach(type => {
      outline.addEventListener(type, () => notePanelInteraction('outline'), { passive: true, capture: true });
      agent.addEventListener(type, () => notePanelInteraction('agent'), { passive: true, capture: true });
    });
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
    /* native-bridge */
    /* native-agent */
    const agentExperience = window.MarkdownItAgent.create({
      ensureConfigured: ensureNativeAgentConfigured,
      onCheckpoint: scheduleRecovery,
      onLifecycle(event, count) { postNative({ type: 'agentLifecycle', token: nativeToken, event, count }); },
      provider: createNativeAgentTransport(), nativeInputs,
      app, panel: agent, renderMarkdown: renderRichMarkdown, fragmentIdentifier,
      enhance: enhanceDocument, motion, reducedMotion,
      onPresentationChange(value) { postNative({ type: 'agentPresentation', token: nativeToken, ...value }); },
      onToggle(shown) {
        setPanelOpen('agent', shown);
      },
      documentAttachment() {
        const markdown = documentText;
        return {
          text: markdown, markdown, images: documentImageReferences(), mode: displayedMode, scope: 'document',
          location: t('Current document · {name}', { name: nativeDocumentName }), documentName: nativeDocumentName
        };
      }
    });
    updateDocument();
    function render() {
      scheduleRecovery();
      const hasOutline = headings.length > 0;
      const previousRect = agent.hidden ? null : agent.getBoundingClientRect();
      const presentation = resolvePanelLayout();
      window.webkit?.messageHandlers.reader.postMessage({type:'state', token:nativeToken, mode:state.mode, outline:state.outline && hasOutline, hasOutline});
      const outlineWasExpanded = outline.dataset.expanded === 'true';
      app.classList.toggle('mdv-showing-source', displayedMode === 'source');
      reader.hidden = displayedMode !== 'preview';
      source.hidden = displayedMode !== 'source';
      agentExperience.present(state.agent, { ...presentation, previousRect });
      workspace.classList.toggle('mdv-has-agent', state.agent);
      const showOutline = hasOutline && state.outline && displayedMode === 'preview';
      outline.hidden = !hasOutline || displayedMode !== 'preview';
      outline.dataset.expanded = String(showOutline);
      outlineBody.inert = !showOutline;
      outlineBody.setAttribute('aria-hidden', String(!showOutline));
      readingLayout.classList.toggle('mdv-with-outline', showOutline);
      if (!showOutline) stopOutlineFollow();
      if (showOutline && !outlineWasExpanded) keepCurrentHeadingVisible();
      nativeInputs.trackLayout();
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
        const tokens = markdownRenderer.parse(documentText, environment);
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
      if (state.outline && panelLayout.overlay && !outline.contains(event.target)) {
        state.outline = false;
        render();
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
        outlineFollowPaused = false;
        if (panelLayout.overlay) state.outline = false;
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
    state.outline = !resolvePanelLayout().overlay;
    render();
    layoutReadingAnchor = captureReadingPosition();
    const panelSizeObserver = new ResizeObserver(() => {
      if (panelLayout && Math.abs(app.clientWidth - panelLayout.width) < .5) return;
      pinnedAnchor = displayedMode === 'preview' ? pinnedAnchor || layoutReadingAnchor || captureReadingPosition() : null;
      render();
      if (pinnedAnchor) restoreReadingPosition(pinnedAnchor);
    });
    panelSizeObserver.observe(app);
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { documentReady = enhanceDocument(); });
    requestAnimationFrame(() => { app.dataset.ready = 'true'; postNative({type:'ready'}); });
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
