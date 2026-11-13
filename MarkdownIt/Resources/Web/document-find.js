// Search only rendered article text. Ranges refer to one immutable DOM snapshot;
// CSS highlights decorate it without inserting nodes or changing text selection.
window.MarkdownItFind = {
  create(article) {
    let generation = 0, snapshot = null, selected = null;
    const found = new Highlight(), current = new Highlight();
    CSS.highlights.set('mdv-find-found', found);
    CSS.highlights.set('mdv-find-current', current);
    const clear = payload => {
      if (payload && payload.id !== snapshot?.id) return;
      generation++; snapshot = null; selected = null; found.clear(); current.clear();
    };
    function capture() {
      clear();
      const nodes = []; let text = '';
      const separator = value => { if (text && !text.endsWith('\n')) text += value; };
      function visit(element) {
        if (element.matches('button, input, textarea, select, script, style, .jm-annotation-icon, .katex-mathml, svg defs, svg title')) return;
        const style = getComputedStyle(element);
        if (style.display === 'none' || style.visibility !== 'visible' || !element.getClientRects().length) return;
        const block = /^(block|list-item|table-row|flex|grid)$/.test(style.display);
        if (block || element.tagName === 'BR') separator('\n');
        for (const child of element.childNodes) {
          if (child.nodeType === Node.ELEMENT_NODE) visit(child);
          else if (child.nodeType === Node.TEXT_NODE && child.length) {
            nodes.push({ node: child, start: text.length, end: text.length + child.length });
            text += child.data;
          }
        }
        if (block) separator('\n');
        else if (style.display === 'table-cell') separator('\t');
      }
      visit(article);
      snapshot = { id: generation, nodes, ranges: new Map() };
      return { id: generation, text };
    }
    function rangeAt(start, length) {
      const nodes = snapshot.nodes, end = start + length;
      const locate = (offset, edge) => {
        let low = 0, high = nodes.length;
        while (low < high) {
          const middle = (low + high) >>> 1;
          if (nodes[middle][edge] <= offset) low = middle + 1;
          else high = middle;
        }
        return low;
      };
      const first = nodes[locate(start, 'end')];
      const last = nodes[locate(end - 1, 'start') - 1];
      if (!first || !last || start < first.start || end > last.end) return null;
      const range = document.createRange();
      range.setStart(first.node, start - first.start); range.setEnd(last.node, end - last.start);
      return range;
    }
    function decorate({ id, ranges }) {
      if (id !== snapshot?.id) return;
      for (const { start, length, style } of ranges) {
        const key = start + ':' + length;
        let range = snapshot.ranges.get(key);
        if (!range && style) { range = rangeAt(start, length); if (range) snapshot.ranges.set(key, range); }
        if (!range) continue;
        if (style === 2) selected = { id, start, length };
        else if (selected?.start === start && selected?.length === length) selected = null;
        found.delete(range); current.delete(range);
        if (style === 1) found.add(range);
        if (style === 2) current.add(range);
      }
    }
    function reveal({ id, start, length }) {
      if (id !== snapshot?.id) return;
      const range = rangeAt(start, length);
      if (!range || !range.startContainer.isConnected) return false;
      // First reveal within horizontal code/table scrollers, then in the page.
      let element = range.startContainer.parentElement;
      while (element && article.contains(element)) {
        if (element.scrollWidth > element.clientWidth && /auto|scroll/.test(getComputedStyle(element).overflowX)) {
          const rect = range.getBoundingClientRect(), box = element.getBoundingClientRect();
          if (rect.left < box.left || rect.right > box.right) element.scrollLeft += rect.left - box.left - parseFloat(getComputedStyle(element).paddingLeft);
        }
        element = element.parentElement;
      }
      const rect = range.getBoundingClientRect();
      const top = parseFloat(getComputedStyle(article).paddingTop);
      window.scrollBy({ top: rect.top - Math.max(top, (innerHeight - rect.height) / 2), behavior: 'instant' });
      return true;
    }
    const restoreCurrent = () => selected ? reveal(selected) : false;
    return { capture, decorate, reveal, clear, restoreCurrent };
  }
};
