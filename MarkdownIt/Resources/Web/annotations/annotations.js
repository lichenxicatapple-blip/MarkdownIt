(() => {
  'use strict';
  function normalize(ranges) {
    const result = [];
    ranges.filter(r => Number.isSafeInteger(r.start) && Number.isSafeInteger(r.end) && r.start >= 0 && r.end > r.start).sort((a,b) => a.start-b.start).forEach(range => {
      const last = result.at(-1);
      if (last && range.start <= last.end) last.end = Math.max(last.end,range.end);
      else result.push({...range});
    });
    return result;
  }
  class ReadingAnnotations {
    constructor({reader, post, context}) {
      this.reader = reader; this.post = post; this.context = context;
      this.waves=new window.MarkdownItAnnotationWaves(reader,ranges=>this.rectangles(ranges));
      this.runs = new Map(); this.records = []; this.entries = []; this.active = null;
      this.frame = 0; this.gesture = null; this.pending = new Map();
      reader.addEventListener('click', event => {
        if (event.button || event.detail > 1 || !context().enabled || !window.getSelection()?.isCollapsed || (!event.target.closest('.jm-annotation-icon')&&event.target.closest('a,summary,.jm-image-action'))) return;
        const id = event.target.closest('[data-annotation-id]')?.dataset.annotationId || this.waves.hit(event.clientX,event.clientY);
        const candidates = (event.target.closest('[data-annotation-ids]')?.dataset.annotationIds || '').split(',');
        const record = this.records.find(r => r.id === id) || this.records.filter(r => candidates.includes(r.id)).sort((a,b) => this.length(a)-this.length(b))[0];
        if (!record) return;
        event.preventDefault(); event.stopPropagation(); this.open(record, event.clientX,event.clientY);
      });
      document.addEventListener('selectionchange', () => {
        const ranges = this.selection();
        this.post({type:'annotationSelection', available: !!ranges.length});
      });
      reader.addEventListener('copy', event => {
        const selected = window.getSelection();
        if (!selected?.rangeCount || selected.isCollapsed || !reader.contains(selected.anchorNode) || !reader.contains(selected.focusNode)) return;
        const fragment = selected.getRangeAt(0).cloneContents();
        ReadingAnnotations.clean(fragment);
        const container = document.createElement('div'); container.append(fragment);
        event.clipboardData.setData('text/plain',selected.toString());
        event.clipboardData.setData('text/html',container.innerHTML);
        event.preventDefault();
      });
      this.observer = new ResizeObserver(() => this.scheduleLayout());
      this.observer.observe(reader);
      reader.addEventListener('load', () => this.scheduleLayout(), true);
      reader.addEventListener('toggle', () => this.scheduleLayout(), true);
      reader.addEventListener('scroll', () => this.scheduleLayout(), {passive:true,capture:true});
      window.addEventListener('resize', () => this.scheduleLayout());
    }
    length(record) { return record.ranges.reduce((sum,r) => sum+r.end-r.start,0); }
    mount(runs) { this.runs = runs || new Map(); this.decorate(); this.scheduleLayout(); }
    reset(records) { this.records = records || []; this.active = null; this.gesture = null; this.pending.clear(); }
    set(records,acknowledged) { this.records = records || []; if(acknowledged)this.pending.delete(acknowledged);this.decorate(); this.scheduleLayout(); }
    mapNodes() {
      this.entries = [];
      this.reader.querySelectorAll('[data-reader-text]').forEach(element => {
        const run = this.runs.get(element.dataset.readerText); if (!run) return;
        const walker = document.createTreeWalker(element,NodeFilter.SHOW_TEXT);
        const nodes=[]; let node;
        while ((node=walker.nextNode())) if (!node.parentElement.closest('.jm-annotation-icon')) nodes.push(node);
        if (nodes.map(n=>n.textContent).join('') !== run.text) return;
        let offset=0;
        for (const node of nodes) { this.entries.push({node,map:run.map.slice(offset*2,(offset+node.length)*2)}); offset+=node.length; }
      });
    }
    decorate() {
      this.reader.querySelectorAll('.jm-annotation-icon').forEach(el=>el.remove());
      this.reader.querySelectorAll('.jm-annotation-tail,.jm-annotation-fragment').forEach(el=>el.replaceWith(...el.childNodes));
      this.reader.querySelectorAll('[data-reader-text]').forEach(el=>el.normalize());
      this.mapNodes();
      if(!this.records.length){this.applyActive();this.redrawWaves();return;}
      for (const {node,map} of this.entries) {
        const candidates=this.records.filter(r=>r.ranges.some(range=>range.end>map[0]&&range.start<map.at(-1)));
        const fragment=document.createDocumentFragment(); let first=0,lastKey=null,ids=[];
        const flush=end=>{
          if (end<=first)return;
          const text=node.textContent.slice(first,end);
          if (!ids.length)fragment.append(document.createTextNode(text));
          else {
            const span=document.createElement('span');span.className='jm-annotation-fragment';span.dataset.annotationIds=ids.join(',');span.textContent=text;
            if(this.records.some(r=>ids.includes(r.id)&&r.underlined))span.classList.add('jm-annotation-wave');
            if(this.records.some(r=>ids.includes(r.id)&&r.hasNote))span.classList.add('jm-annotation-note');
            fragment.append(span);
          }
          first=end;
        };
        for(let i=0;i<node.length;i++){
          const matches=candidates.filter(r=>r.ranges.some(range=>map[i*2]>=0&&map[i*2]<range.end&&map[i*2+1]>range.start)).map(r=>r.id);
          const key=matches.join(',');if(key!==lastKey){flush(i);ids=matches;lastKey=key;}
        }
        flush(node.length);node.replaceWith(fragment);
      }
      this.mapNodes();
      for (const record of this.records.filter(r=>r.hasNote)) {
        const end=record.ranges.at(-1)?.end;
        const entry=[...this.entries].reverse().find(e=>e.map.some((v,i)=>i%2===1&&v===end));if(!entry)continue;
        let last=entry.node.length;
        while(last>0&&entry.map[last*2-1]!==end)last--;
        if(!last)continue;
        const range=document.createRange(),unit=entry.node.textContent.charCodeAt(last-1),first=last-(unit>=0xDC00&&unit<=0xDFFF?2:1);
        range.setStart(entry.node,Math.max(0,first));range.setEnd(entry.node,last);
        const tail=document.createElement('span');tail.className='jm-annotation-tail';tail.append(range.extractContents());
        const icon=document.createElement('button');icon.type='button';icon.className='jm-annotation-icon';icon.dataset.annotationId=record.id;icon.setAttribute('aria-label',window.MarkdownItLocalization.t('Annotation'));
        icon.innerHTML='<svg data-lucide="message-square-text" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M5 4h14a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H9l-5 4V5a1 1 0 0 1 1-1Z"/></svg>';
        tail.append(icon);range.insertNode(tail);this.mapNodes();
      }
      this.applyActive();
      this.redrawWaves();
    }
    redrawWaves() {
      this.waves.set([...this.records,...[...this.pending].map(([id,ranges])=>({id,ranges,underlined:true,transient:true}))],this.gesture&&!this.gesture.finished);
    }
    applyActive() {
      if(this.active?.ranges?.length)CSS.highlights.set('jm-annotation-active',new Highlight(...this.domRanges(this.active.ranges)));
      else CSS.highlights.delete('jm-annotation-active');
    }
    selection() {
      const selected=window.getSelection();if(!this.context().enabled||!selected?.rangeCount||selected.isCollapsed||!this.reader.contains(selected.anchorNode)||!this.reader.contains(selected.focusNode))return[];
      return this.rangesFor(selected.getRangeAt(0));
    }
    rangesFor(range) {
      const ranges=[];
      for(const {node,map} of this.entries){
        if(!node.isConnected||!range.intersectsNode(node))continue;
        const start=range.startContainer===node?range.startOffset:0,end=range.endContainer===node?range.endOffset:node.length;
        for(let i=start;i<end;i++)if(map[i*2]>=0)ranges.push({start:map[i*2],end:map[i*2+1]});
      }
      return normalize(ranges);
    }
    sourcePoint(x,y) {
      let node,offset;
      if(document.caretPositionFromPoint){const p=document.caretPositionFromPoint(x,y);node=p?.offsetNode;offset=p?.offset;}
      else {const p=document.caretRangeFromPoint(x,y);node=p?.startContainer;offset=p?.startOffset;}
      const entry=this.entries.find(e=>e.node===node);if(!entry||!node.length)return null;
      offset=Math.max(0,Math.min(offset,node.length-1));
      const start=entry.map[offset*2],end=entry.map[offset*2+1];
      return start>=0&&end>start?{start,end}:null;
    }
    rangeAt(source) {
      for(const {node,map} of this.entries){
        for(let i=0;i<node.length;i++)if(map[i*2]<source.end&&map[i*2+1]>source.start&&map[i*2]>=0){
          const range=document.createRange();range.setStart(node,i);range.setEnd(node,i+1);return range;
        }
      }
      return null;
    }
    open(record,x,y,create=false,ranges=record?.ranges) {
      const source=this.sourcePoint(x,y)||ranges?.at(-1);if(!source)return;
      const anchor=this.rangeAt(source)?.getBoundingClientRect();if(!anchor)return;
      const context=this.context();window.getSelection()?.removeAllRanges();
      this.post({type:'annotationOpen',request:{id:record?.id,token:context.token,revision:context.revision,ranges,anchor:source,rect:{x:anchor.x,y:anchor.y,width:anchor.width,height:anchor.height},create}});
    }
    act(action) {
      const selection=window.getSelection(),ranges=this.selection();if(!ranges.length)return;
      const rects=[...selection.getRangeAt(0).getClientRects()].filter(r=>r.width&&r.height),rect=rects.at(-1);if(!rect)return;
      if(action==='note')this.open(null,rect.x+rect.width/2,rect.y+rect.height/2,true,ranges);
      else {window.getSelection()?.removeAllRanges();this.underline(ranges);}
    }
    envelope(ranges) {
      const parts=this.domRanges(ranges);if(!parts.length)return null;
      const range=parts[0].cloneRange(),last=parts.at(-1);
      range.setEnd(last.endContainer,last.endOffset);return range;
    }
    joinable(a,b) {
      if(a.comparePoint(b.startContainer,b.startOffset)===0||b.comparePoint(a.startContainer,a.startOffset)===0)return true;
      const [left,right]=a.compareBoundaryPoints(Range.START_TO_START,b)<0?[a,b]:[b,a];
      const gap=document.createRange();gap.setStart(left.endContainer,left.endOffset);gap.setEnd(right.startContainer,right.startOffset);
      return !gap.toString().length&&!gap.cloneContents().querySelector('img,svg,br,hr');
    }
    underline(ranges,operationID) {
      const joining=[],candidates=this.records.filter(r=>r.underlined&&!r.hasNote);
      let combined=ranges,changed=true;
      while(changed){
        changed=false;const range=this.envelope(combined);if(!range)break;
        for(const record of candidates){
          if(joining.includes(record.id))continue;
          const other=this.envelope(record.ranges);
          if(other&&this.joinable(range,other)){
            joining.push(record.id);combined=normalize([...combined,...record.ranges]);changed=true;
          }
        }
      }
      this.post({type:'annotationAction',action:'underline',ranges,joining,operationID});
    }
    presentation(value) {this.active=value?.anchor?value:null;this.applyActive();this.scheduleLayout();}
    scheduleLayout() {if(!this.frame)this.frame=requestAnimationFrame(()=>{this.frame=0;this.publishLayout();});}
    publishLayout() {
      if(!this.context().enabled){this.post({type:"annotationRegions",regions:[]});return;}
      this.waves.draw();
      if(this.active){const rect=this.rangeAt(this.active.anchor)?.getBoundingClientRect();if(rect)this.post({type:'annotationAnchor',rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});}
      const regions=[];
      const geometry=getComputedStyle(this.reader),above=parseFloat(geometry.getPropertyValue('--mdv-pencil-start-above')),below=parseFloat(geometry.getPropertyValue('--mdv-pencil-start-below'));
      for(const {node} of this.entries){
        const range=document.createRange();range.selectNodeContents(node);
        const element=node.parentElement,style=getComputedStyle(element),font=parseFloat(style.fontSize),lineHeight=parseFloat(style.lineHeight)||font;
        const overflow=element.closest('pre,table');
        for(const rect of range.getClientRects())if(rect.width&&rect.height){regions.push({x:rect.x+scrollX,y:rect.bottom+scrollY-font*above,width:rect.width,height:font*above+lineHeight*below,fontSize:font,lineHeight,textY:rect.y+rect.height/2+scrollY,overflow:!!overflow&&overflow.scrollWidth>overflow.clientWidth+1});}
      }
      this.post({type:'annotationRegions',regions});
    }
    pencil(value) {
      if(!this.context().enabled)return;
      if(this.gesture?.id===value.id&&value.sequence<=this.gesture.sequence)return;
      if(this.gesture?.id!==value.id)this.gesture={id:value.id,sequence:-1,finished:false};
      if(this.gesture.finished)return;
      this.gesture.sequence=value.sequence;
      const start=this.sourcePoint(value.start.x,value.start.y),end=this.sourcePoint(value.point.x,value.start.y);
      if(value.phase==='cancel'){this.gesture.finished=true;this.waves.setPreview([]);return;}
      if(!start||!end){if(value.phase==='commit'&&this.gesture.ranges?.length)this.commitPencil(value.id,this.gesture.ranges);return;}
      const first=this.rangeAt(start),last=this.rangeAt(end);if(!first||!last)return;
      const range=document.createRange();
      if(first.compareBoundaryPoints(Range.START_TO_START,last)<=0){range.setStart(first.startContainer,first.startOffset);range.setEnd(last.endContainer,last.endOffset);}
      else {range.setStart(last.startContainer,last.startOffset);range.setEnd(first.endContainer,first.endOffset);}
      const ranges=this.rangesFor(range);
      this.gesture.ranges=ranges;this.waves.setPreview(ranges);
      if(value.phase==='commit')this.commitPencil(value.id,ranges);
    }
    commitPencil(id,ranges) {
      this.gesture.finished=true;this.pending.set(id,ranges);this.redrawWaves();
      this.underline(ranges,id);
    }
    domRanges(ranges) {
      const result=[];
      for(const {node,map} of this.entries){
        if(!ranges.some(r=>r.end>map[0]&&r.start<map.at(-1)))continue;
        let start=null;
        const add=end=>{
          if(start===null||end<=start)return;
          const range=document.createRange();range.setStart(node,start);range.setEnd(node,end);
          result.push(range);
        };
        for(let i=0;i<=node.length;i++){
          const matches=i<node.length&&ranges.some(r=>map[i*2]>=0&&map[i*2]<r.end&&map[i*2+1]>r.start);
          if(matches&&start===null)start=i;
          if(!matches&&start!==null){add(i);start=null;}
        }
      }
      return result;
    }
    rectangles(ranges) {
      return this.domRanges(ranges).flatMap(range=>{
        const element=range.startContainer.parentElement,style=getComputedStyle(element),overflow=element.closest('pre,table'),clip=overflow?.getBoundingClientRect();
        return [...range.getClientRects()].flatMap(rect=>{
          const left=clip?Math.max(rect.left,clip.left):rect.left,right=clip?Math.min(rect.right,clip.right):rect.right;
          return right>left&&rect.height>0?[{x:left,y:rect.y,right,bottom:rect.bottom,style}]:[];
        });
      });
    }
    static clean(fragment) {
      fragment.querySelectorAll('.jm-annotation-icon,.jm-annotation-waves[data-reader-decoration]').forEach(el=>el.remove());
      fragment.querySelectorAll('.jm-annotation-fragment,.jm-annotation-tail,span[data-reader-text]').forEach(el=>el.replaceWith(...el.childNodes));
      fragment.querySelectorAll('[data-reader-text]').forEach(el=>el.removeAttribute('data-reader-text'));
    }
  }
  window.MarkdownItAnnotations=ReadingAnnotations;
})();
