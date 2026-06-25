defmodule AutoresumeDemo.Web.Page do
  @moduledoc false

  def html do
    """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Normandy · Autoresume Live</title>
    <style>
      body{font:14px/1.4 ui-monospace,Menlo,Consolas,monospace;background:#0b0e14;color:#cdd6f4;margin:0;padding:16px}
      h1{font-size:16px;color:#89b4fa;margin:0 0 12px}
      #cols{display:flex;gap:12px;align-items:flex-start}
      .col{flex:1;border:1px solid #313244;border-radius:8px;padding:10px;min-height:160px}
      .col h2{font-size:13px;margin:0 0 8px;display:flex;justify-content:space-between}
      .up{color:#a6e3a1}.down{color:#f38ba8}
      .card{border:1px solid #45475a;border-radius:6px;padding:8px;margin:6px 0;background:#11151c}
      .bar{height:6px;background:#313244;border-radius:3px;overflow:hidden;margin:4px 0}
      .bar>i{display:block;height:100%;background:#89b4fa}
      .resumed{color:#f9e2af}
      button{font:inherit;background:#f38ba8;color:#11111b;border:0;border-radius:5px;padding:5px 8px;cursor:pointer;margin-top:6px}
      button.restart{background:#a6e3a1}
      #log{margin-top:14px;border-top:1px solid #313244;padding-top:8px;max-height:220px;overflow:auto}
      #log div{white-space:pre}
      .k-nodedown,.k-kill{color:#f38ba8}.k-resume,.k-nodeup{color:#a6e3a1}
    </style></head>
    <body>
      <h1>NORMANDY · Autoresume Live <span id="clock"></span></h1>
      <div id="cols"></div>
      <h1>EVENT LOG</h1>
      <div id="log"></div>
    <script>
      function post(p){fetch(p,{method:'POST'})}
      function render(s){
        document.getElementById('clock').textContent = new Date(s.ts).toLocaleTimeString();
        const byNode = {};
        (s.nodes||[]).forEach(n=>byNode[n.name]={status:n.status,agents:[]});
        (s.agents||[]).forEach(a=>{
          const key = a.node || 'unassigned';
          (byNode[key]=byNode[key]||{status:'up',agents:[]}).agents.push(a);
        });
        const cols = document.getElementById('cols'); cols.innerHTML='';
        Object.keys(byNode).sort().forEach(name=>{
          const n = byNode[name];
          const col = document.createElement('div'); col.className='col';
          const cls = n.status==='down'?'down':'up';
          let h = `<h2><span>${name}</span><span class="${cls}">${n.status==='down'?'✖ DOWN':'● UP'}</span></h2>`;
          (n.agents||[]).forEach(a=>{
            const pct = a.total? Math.round(100*(a.step||0)/a.total):0;
            h += `<div class="card"><b>${a.id}</b>`;
            if(a.resumed_from) h+=`<div class="resumed">↻ RESUMED from ${a.resumed_from}</div>`;
            h += `<div>${a.status} · step ${a.step||0}/${a.total||'?'} · ${a.current_tool||''}</div>`;
            h += `<div class="bar"><i style="width:${pct}%"></i></div></div>`;
          });
          if(name!=='unassigned'){
            h += `<button onclick="post('/kill/${name}')">Kill ${name}</button>`;
          }
          col.innerHTML=h; cols.appendChild(col);
        });
        const log = document.getElementById('log'); log.innerHTML='';
        (s.events||[]).forEach(e=>{
          const d=document.createElement('div'); d.className='k-'+e.kind;
          d.textContent = new Date(e.ts).toLocaleTimeString()+'  '+e.text; log.appendChild(d);
        });
      }
      const es = new EventSource('/events');
      es.onmessage = ev => { try{ render(JSON.parse(ev.data)); }catch(e){} };
    </script></body></html>
    """
  end
end
