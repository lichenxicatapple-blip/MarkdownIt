(() => {
  'use strict';
  // Token iteration follows markdown-it's MIT-licensed parser contract. The
  // bundled markdown-it.LICENSE covers the original iteration/merge structure.
  // Provenance is collected while parsing, never by matching saved quotations.
  const direct = (start, length) => Array.from({length: length * 2}, (_, i) => start + Math.floor(i / 2) + i % 2);
  const atomic = (map, start, end, length) => Array.from({length: length * 2}, (_, i) => map[(i % 2 ? end * 2 - 1 : start * 2)] ?? -1);
  // Mapping size follows document text length, not the engine's function-argument limit.
  function append(target, values) { for (const value of values) target.push(value); }
  function put(token, text, map) { token.meta = {...token.meta, readerSource: {text, map}}; }
  function mapping(token) {
    const source = token.meta?.readerSource;
    if (!source) return Array(token.content.length * 2).fill(-1);
    if (source.text === token.content) return source.map;
    // Parser extensions such as task lists remove a known prefix from a token.
    if (source.text.endsWith(token.content)) return source.map.slice((source.text.length - token.content.length) * 2);
    if (source.text.startsWith(token.content)) return source.map.slice(0, token.content.length * 2);
    return Array(token.content.length * 2).fill(-1);
  }
  function merge(tokens, special, levels, tracked) {
    const result = []; let level = 0;
    for (const token of tokens) {
      if (levels) { if (token.nesting < 0) level--; token.level = level; if (token.nesting > 0) level++; }
      if (special && token.type === 'text_special') token.type = 'text';
      const previous = result.at(-1);
      if (token.type === 'text' && previous?.type === 'text') {
        const text = previous.content + token.content;
        if(tracked){const map=[...mapping(previous),...mapping(token)];previous.content=text;put(previous,text,map);}
        else previous.content=text;
      } else result.push(token);
    }
    tokens.length = 0;
    append(tokens, result);
  }
  function trim(value, map) {
    const start = value.length - value.trimStart().length;
    return {text: value.trim(), map: map.slice(start * 2, (value.length - (value.length - value.trimEnd().length)) * 2)};
  }
  function cells(state, line) {
    const first = state.bMarks[line] + state.tShift[line], last = state.eMarks[line];
    const result = []; let text = '', map = [];
    for (let at = first; at < last; at++) {
      const char = state.src[at];
      if (char === '\\' && state.src[at + 1] === '|') { text += '|'; map.push(at, at + 2); at++; }
      else if (char === '|') { result.push(trim(text, map)); text = ''; map = []; }
      else { text += char; map.push(at, at + 1); }
    }
    result.push(trim(text, map));
    if (!result[0]?.text) result.shift();
    if (!result.at(-1)?.text) result.pop();
    return result;
  }
  function install(md) {
    const originalBlock = md.block.tokenize;
    md.block.tokenize = function(state, startLine, endLine) {
      if (!state.env.readerMap) return originalBlock.call(this, state, startLine, endLine);
      if (!state.readerLines) {
        state.readerLines = [];
        const original = state.getLines;
        state.getLines = function(begin, end, indent, lastLF) {
          const text = original.call(this, begin, end, indent, lastLF), lines = text.split('\n');
          const map = []; let output = 0;
          for (let line = begin; line < end && output < text.length; line++) {
            const value = lines[line - begin] || '', raw = this.src.slice(this.bMarks[line], this.eMarks[line]);
            let shared = 0;
            while (shared < Math.min(value.length, raw.length) && value[value.length - 1 - shared] === raw[raw.length - 1 - shared]) shared++;
            for (let i = 0; i < value.length; i++) {
              const at = i < value.length - shared ? this.bMarks[line] : this.eMarks[line] - value.length + i;
              map.push(at, at + 1);
            }
            output += value.length;
            if (text[output] === '\n') { map.push(this.eMarks[line], this.eMarks[line] + 1); output++; }
          }
          this.readerLines.push({begin, end, text, map}); return text;
        };
      }
      const first = state.tokens.length;
      originalBlock.call(this, state, startLine, endLine);
      let row = null, column = 0, previous = null;
      for (const token of state.tokens.slice(first)) {
        if (token.type === 'tr_open') { row = cells(state, token.map[0]); column = 0; }
        if (token.type === 'tr_close') row = null;
        if (!token.meta?.readerSource && ['inline', 'fence', 'code_block', 'html_block'].includes(token.type)) {
          if (row && token.type === 'inline') {
            const cell = row[column++]; if (cell?.text === token.content) put(token, cell.text, cell.map);
          } else if (token.map) {
            const lines = token.map;
            const captured = [...state.readerLines].reverse().find(value => value.begin >= lines[0] && value.end <= lines[1] && (value.text === token.content || value.text.trim() === token.content));
            if (captured) {
              const value = captured.text === token.content ? captured : trim(captured.text, captured.map);
              put(token, token.content, value.map);
            } else if (lines[1] === lines[0] + 1) {
              let at = state.bMarks[lines[0]] + state.tShift[lines[0]];
              if (previous?.type === 'heading_open') {
                at += previous.markup.length;
                while (state.src[at] === ' ' || state.src[at] === '\t') at++;
              }
              if (state.src.slice(at, at + token.content.length) === token.content) put(token, token.content, direct(at, token.content.length));
            }
          }
        }
        previous = token;
      }
    };
    const originalParse = md.inline.parse, originalTokenize = md.inline.tokenize;
    md.inline.parse = function(src, parser, env, tokens) {
      const source = env.readerInline;
      if (!source || source.content !== src) return originalParse.call(this, src, parser, env, tokens);
      const state = new this.State(src, parser, env, tokens);
      state.readerMap = source.map; state.readerPending = [];
      const pending = state.pushPending;
      state.pushPending = function() {
        const text = this.pending, map = this.readerPending.slice(0, text.length * 2);
        const token = pending.call(this); put(token, text, map); this.readerPending = []; return token;
      };
      this.tokenize(state);
      this.ruler2.getRules('').forEach(rule => rule(state));
    };
    md.inline.tokenize = function(state) {
      if (!state.readerMap) return originalTokenize.call(this, state);
      const rules = this.ruler.getRules(''), end = state.posMax;
      while (state.pos < end) {
        const start = state.pos, first = state.tokens.length; let accepted = false;
        if (state.level < state.md.options.maxNesting) {
          for (const rule of rules) { if (rule(state, false)) { accepted = true; break; } }
        }
        if (!accepted) state.pending += state.src[state.pos++];
        if (state.pos <= start) throw Error('Inline rule did not advance');
        let cursor = start;
        for (const token of state.tokens.slice(first)) {
          if (token.meta?.readerSource || !['text', 'text_special', 'code_inline'].includes(token.type)) continue;
          let from = cursor, to = state.pos;
          if (token.type === 'code_inline') {
            from = start + token.markup.length; to = state.pos - token.markup.length;
            const raw = state.src.slice(from, to).replace(/\n/g, ' ');
            if (/^ (.+) $/.test(raw)) { from++; to--; }
          }
          const literal = state.src.slice(from, from + token.content.length);
          let map;
          if (token.type === 'code_inline') map = state.readerMap.slice(from * 2, to * 2);
          else if (literal === token.content) { to = from + token.content.length; map = state.readerMap.slice(from * 2, to * 2); }
          else if (state.src.slice(to - token.content.length, to) === token.content) { from = to - token.content.length; map = state.readerMap.slice(from * 2, to * 2); }
          else map = atomic(state.readerMap, from, to, token.content.length);
          put(token, token.content, map); cursor = to;
        }
        const existing = Math.min(state.readerPending.length / 2, state.pending.length);
        state.readerPending.length = existing * 2;
        const appended = state.pending.slice(existing);
        if (appended) {
          const from = state.src.slice(start, state.pos).endsWith(appended) ? state.pos - appended.length : start;
          const map = state.src.slice(from, state.pos) === appended ? state.readerMap.slice(from * 2, state.pos * 2) : atomic(state.readerMap, from, state.pos, appended.length);
          append(state.readerPending, map);
        }
      }
      if (state.pending) state.pushPending();
    };
    md.inline.ruler2.at('fragments_join', state => merge(state.tokens, false, true, !!state.readerMap));
    md.core.ruler.at('inline', state => {
      for (const token of state.tokens) {
        if (token.type !== 'inline') continue;
        const old = state.env.readerInline;
        state.env.readerInline = token.meta?.readerSource ? {content: token.content, map: mapping(token)} : null;
        state.md.inline.parse(token.content, state.md, state.env, token.children);
        state.env.readerInline = old;
      }
    });
    md.core.ruler.at('text_join', state => {
      state.tokens.filter(token => token.type === 'inline').forEach(token => merge(token.children, true, false, !!state.env.readerMap));
    });
    const leaves = token => token.children.filter(value => ['text', 'text_special', 'code_inline'].includes(value.type));
    md.core.ruler.before('linkify', 'reader_link_maps_before', state => {
      if (!state.env.readerMap) return;
      state.tokens.filter(token => token.type === 'inline').forEach(token => {
        const values = leaves(token); token.readerLinkMap = {text: values.map(t => t.content).join(''), map: values.flatMap(mapping)};
      });
    });
    md.core.ruler.after('linkify', 'reader_link_maps_after', state => {
      if (!state.env.readerMap) return;
      state.tokens.filter(token => token.readerLinkMap).forEach(token => {
        const values = leaves(token), source = token.readerLinkMap;
        if (values.map(t => t.content).join('') !== source.text) return;
        let at = 0; values.forEach(t => { put(t, t.content, source.map.slice(at * 2, (at + t.content.length) * 2)); at += t.content.length; });
      });
    });
    function run(content, map, env, html) {
      if (!env.readerMap || !map?.length || map.length !== content.length * 2 || map.every(value => value < 0)) return html;
      const id = `${env.readerMap.nonce}-${env.readerMap.next++}`;
      env.readerMap.runs.set(id, {text: content, map});
      return `<span data-reader-text="${id}">${html}</span>`;
    }
    for (const type of ['text', 'code_inline']) {
      md.renderer.rules[type] = (tokens, index, options, env, renderer) => {
        const token = tokens[index];
        const html = md.utils.escapeHtml(token.content);
        const body = env.readerMap ? run(token.content, mapping(token), env, html) : html;
        return type === 'code_inline' ? `<code${renderer.renderAttrs(token)}>${body}</code>` : body;
      };
    }
    const htmlBlock = md.renderer.rules.html_block;
    md.renderer.rules.html_block = (tokens, index, options, env, renderer) => {
      const token = tokens[index], html = token.content;
      if (!env.readerMap || !token.meta?.readerSource || typeof document === 'undefined') return htmlBlock(tokens,index,options,env,renderer);
      const source=mapping(token), template=document.createElement('template');
      const decode=text=>{template.innerHTML=text;return template.content.textContent;};
      function textRun(raw, offset) {
        if(!raw.trim())return raw;
        let content='',map=[],at=0;
        const entities=/&(?:\#(?:x[\da-f]+|\d+)|[a-z][\da-z]+);?/gi;
        for(const match of raw.matchAll(entities)){
          const plain=raw.slice(at,match.index);content+=plain;append(map,source.slice((offset+at)*2,(offset+match.index)*2));
          const value=decode(match[0]);content+=value;
          append(map,atomic(source,offset+match.index,offset+match.index+match[0].length,value.length));at=match.index+match[0].length;
        }
        content+=raw.slice(at);append(map,source.slice((offset+at)*2,(offset+raw.length)*2));
        return run(content,map,env,raw);
      }
      let result='',at=0;
      for(const tag of html.matchAll(/<!--[\s\S]*?-->|<(?:"[^"]*"|'[^']*'|[^'">])*?>/g)){
        result+=textRun(html.slice(at,tag.index),at)+tag[0];at=tag.index+tag[0].length;
      }
      const originalContent=token.content;
      token.content=result+textRun(html.slice(at),at);
      try { return htmlBlock(tokens,index,options,env,renderer); }
      finally { token.content=originalContent; }
    };
    for (const type of ['fence', 'code_block']) {
      const original = md.renderer.rules[type];
      md.renderer.rules[type] = (tokens, index, options, env, renderer) => {
        const token = tokens[index], html = original(tokens, index, options, env, renderer);
        if (!env.readerMap || !token.meta?.readerSource || html.includes('mdv-mermaid')) return html;
        const id = `${env.readerMap.nonce}-${env.readerMap.next++}`;
        env.readerMap.runs.set(id, {text: token.content, map: mapping(token)});
        return html.replace('<code', `<code data-reader-text="${id}"`);
      };
    }
  }
  window.MarkdownItSourceMap = {install, environment: () => ({readerMap: {nonce: crypto.randomUUID(), next: 0, runs: new Map()}})};
})();
