/* Shared parser, sanitizer and offline rich-text extensions. */
(() => {
  const { t } = window.MarkdownItLocalization;
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
  window.MarkdownItSourceMap.install(markdownRenderer);
  window.MarkdownItRendering = { create({app, documentPrefix = null, token, prepareLocalResources, frozenImageIDs = new Set()}) {
    let sourceMap = new Map();
    const enhancementRevisions = new WeakMap();
    let diagramSequence = 0;
    const diagramSources = new WeakMap();
    const colorProbe = document.createElement('span');
    colorProbe.hidden = true;
    app.append(colorProbe);
    async function enhanceDocument(surface = app) {
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
          const { svg } = await window.mermaid.render(`${documentPrefix || "conversation"}-diagram-${++diagramSequence}`, code);
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
    function codeCopyButton(text) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'mdv-code-copy';
      function feedback(copied) {
        if (copied) button.dataset.copied = 'true';
        else delete button.dataset.copied;
        button.setAttribute('aria-label', t(copied ? 'Copied' : 'Copy Code'));
        button.title = button.getAttribute('aria-label');
      }
      feedback(false);
      for (const name of ['Copy', 'Check']) {
        button.append(window.lucide.createElement(window.lucide.icons[name], {
          'data-lucide': name.toLowerCase(), 'aria-hidden': 'true'
        }));
      }
      let confirmation;
      button.addEventListener('click', async event => {
        event.preventDefault();
        event.stopPropagation();
        if (button.disabled) return;
        button.disabled = true;
        try {
          const copied = await window.webkit.messageHandlers.copyCode.postMessage({token:token(), text}).catch(() => false);
          if (!copied || !button.isConnected) return;
          clearTimeout(confirmation);
          feedback(true);
          confirmation = setTimeout(() => feedback(false), parseFloat(getComputedStyle(app).getPropertyValue('--mdv-copy-confirmation')));
        } finally { button.disabled = false; }
      });
      return button;
    }
    function cleanControls(fragment) {
      fragment.querySelectorAll('.mdv-code-copy').forEach(button => button.remove());
      fragment.querySelectorAll('.mdv-code-block').forEach(block => block.replaceWith(...block.childNodes));
    }
    function renderRichMarkdown(markdown, prefix, images = []) {
      const environment = prefix === documentPrefix ? window.MarkdownItSourceMap.environment() : {};
      const documentFragment = markdownFragment(markdown, environment);
      if (prefix === documentPrefix) sourceMap = environment.readerMap.runs;
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
      prepareLocalResources(documentFragment, prefix === documentPrefix);
      // Quote images keep the immutable native snapshot after it is sent/read.
      documentFragment.querySelectorAll('img').forEach(image => {
        const reference = images.find(value => value.source === image.dataset.sourcePath);
        if (!reference) return;
        image.dataset.agentImageId = reference.id;
        if (frozenImageIDs.has(reference.id)) image.src = `jm-image://${token()}/${reference.id}`;
      });
      documentFragment.querySelectorAll('summary').forEach(summary => summary.classList.add('cursor-interaction'));
      documentFragment.querySelectorAll('pre').forEach(pre => {
        const code = pre.querySelector(':scope > code');
        if (!code || pre.closest('.mdv-mermaid')) return;
        const block = document.createElement('div');
        block.className = 'mdv-code-block';
        pre.replaceWith(block);
        block.append(pre, codeCopyButton(code.textContent));
      });
      return documentFragment;
    }
    let nativeSymbols = {};
    let nativeSymbolSequence = 0;
    function updateSymbols() {
      if (!Object.keys(nativeSymbols).length) return;
      app.querySelectorAll('svg[data-lucide]:not([data-native-symbol])').forEach(svg => {
        const source = nativeSymbols[svg.dataset.lucide];
        if (!source) return;
        svg.dataset.nativeSymbol = 'true';
        // Lucide refreshes all data-lucide nodes, including existing SVGs.
        // Native artwork owns this node from now on and uses one filled mask.
        svg.removeAttribute('data-lucide');
        svg.setAttribute('stroke', 'none');
        const mask = 'native-symbol-' + (++nativeSymbolSequence);
        const inset = 1;
        const size = 24 - inset * 2;
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.innerHTML = '<defs><mask id="' + mask + '"><image href="' + source + '" x="' + inset + '" y="' + inset + '" width="' + size + '" height="' + size + '" preserveAspectRatio="xMidYMid meet"/></mask></defs><rect width="24" height="24" fill="currentColor" mask="url(#' + mask + ')"/>';
      });
    }
    new MutationObserver(updateSymbols).observe(app, {childList:true,subtree:true});
    function theme(value) {
      app.style.setProperty('--jm-font-scale',String(value.fontScale));
      nativeSymbols=value.symbols || {};
      Object.entries(value.palette || {}).forEach(([name,color])=>app.style.setProperty('--mdv-'+name,color));
      updateSymbols();
    }
    return { theme, updateSymbols, render: renderRichMarkdown, enhance: enhanceDocument, cleanControls, markdownFragment, fragmentIdentifier,
      parse: (text, environment) => markdownRenderer.parse(text, environment), get sourceMap() { return sourceMap; } };
  }};
})();
