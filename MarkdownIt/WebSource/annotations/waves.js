(() => {
  'use strict';
  const svgNS='http://www.w3.org/2000/svg';
  class AnnotationWaves {
    constructor(reader, rectangles) {
      this.reader=reader;this.rectangles=rectangles;this.nodes=new Map();this.groups=[];this.preview=[];
      this.root=document.createElement('div');this.root.className='jm-annotation-waves';this.root.dataset.readerDecoration='waves';this.root.setAttribute('aria-hidden','true');
      this.context=document.createElement('canvas').getContext('2d');this.metrics=new Map();
    }
    mount(){if(!this.root.isConnected){this.root.replaceChildren();this.nodes.clear();this.reader.append(this.root);}}
    set(groups,keepPreview=false){this.groups=groups.filter(r=>r.underlined);if(!keepPreview)this.preview=[];this.draw();}
    setPreview(ranges){if(JSON.stringify(ranges)===JSON.stringify(this.preview))return;this.preview=ranges;this.draw(true);}
    offset(name,font){const value=getComputedStyle(this.reader).getPropertyValue(name).trim();return parseFloat(value)*(value.endsWith('em')?font:1);}
    descent(style) {
      const font=`${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
      if(!this.metrics.has(font)){this.context.font=font;this.metrics.set(font,((metrics)=>metrics.fontBoundingBoxDescent??metrics.actualBoundingBoxDescent)(this.context.measureText('M中pq')));}
      return this.metrics.get(font);
    }
    hit(x,y) {
      for(const node of this.nodes.values()){
        const rect=node.svg.getBoundingClientRect();
        if(x>=rect.left&&x<=rect.right&&y>=rect.top&&y<=rect.bottom)return node.id;
      }
      return null;
    }
    draw(previewOnly=false) {
      this.mount();const origin=this.root.getBoundingClientRect(),used=new Set();
      const groups=previewOnly?[]:[...this.groups];
      if(this.preview.length)groups.push({id:'pencil-preview',ranges:this.preview,transient:true});
      for(const group of groups){
        // Native JSON object key order is unspecified; compare range values.
        const signature=group.ranges.map(r=>`${r.start}:${r.end}`).join(','),rows=[];
        for(const rect of this.rectangles(group.ranges).sort((a,b)=>a.y-b.y||a.x-b.x)){
          const font=parseFloat(rect.style.fontSize),last=rows.at(-1);
          const baseline=rect.bottom-this.descent(rect.style),y=baseline+this.offset('--mdv-annotation-wave-offset',font);
          if(last&&Math.abs(last.y-y)<font/3&&rect.x<=last.right+1&&rect.right>=last.left-1){last.left=Math.min(last.left,rect.x);last.right=Math.max(last.right,rect.right);last.y=Math.max(last.y,y);last.font=Math.max(last.font,font);}
          else rows.push({left:rect.x,right:rect.right,y,font});
        }
        rows.forEach((row,index)=>{
          const key=`${group.id}:${index}`;let node=this.nodes.get(key);
          // The committed range adopts its preview's existing layer.
          if(!node&&!previewOnly)for(const [oldKey,candidate] of this.nodes){if(!used.has(oldKey)&&candidate.transient&&candidate.signature===signature&&candidate.index===index){node=candidate;this.nodes.delete(oldKey);break;}}
          if(!node){const svg=document.createElementNS(svgNS,'svg'),path=document.createElementNS(svgNS,'path');svg.append(path);this.root.append(svg);node={svg,path};}
          node.signature=signature;node.index=index;node.id=group.id;node.transient=!!group.transient;this.nodes.set(key,node);used.add(key);
          const amplitude=this.offset('--mdv-annotation-wave-amplitude',row.font),period=this.offset('--mdv-annotation-wave-period',row.font),stroke=this.offset('--mdv-annotation-wave-thickness',row.font);
          const width=Math.max(0,row.right-row.left),height=amplitude*2+stroke,mid=height/2;
          const left=row.left-origin.left,top=row.y-origin.top-height/2;
          node.svg.style.left=`${left}px`;node.svg.style.top=`${top}px`;
          node.svg.setAttribute('width',String(width));node.svg.setAttribute('height',String(height));node.svg.setAttribute('viewBox',`0 0 ${width} ${height}`);
          let x=Math.floor(left/period)*period-left,d=`M ${x} ${mid}`;
          for(;x<width;x+=period)d+=` q ${period/4} ${-amplitude*2} ${period/2} 0 t ${period/2} 0`;
          node.path.setAttribute('d',d);node.path.setAttribute('stroke-width',String(stroke));
        });
      }
      for(const [key,node] of this.nodes)if(!used.has(key)&&(!previewOnly||node.id==='pencil-preview')){node.svg.remove();this.nodes.delete(key);}
    }
  }
  window.MarkdownItAnnotationWaves=AnnotationWaves;
})();
