'use strict';
const $ = id => document.getElementById(id);
const labels = {queued:'等待中',planning:'理解交辦',running:'處理中',saving:'保存中',completed:'已完成',cancelled:'已停止',failed:'未完成',needs_input:'等你補充',needs_external:'待交外部 Agent',interrupted:'曾經中斷',incomplete:'部分內容',needs_provider:'等待 Agent 連線'};
let token = '', selected = '', tasks = [], connected = false, pendingRequest = null;
let lastDetail = '', lastList = '', parentId = '', handoffSelected = '', journalEntries = [], journalSignature = '';
let selectedJournal = new Set(), pendingJournal = null, pendingHandoff = null;
function node(tag, text, cls) { const el = document.createElement(tag); if(text !== undefined) el.textContent = text; if(cls) el.className=cls; return el; }
function message(text, error=false) { $('message').textContent=text; $('message').className=error?'error':''; }
async function api(path, body, retry=true) {
  const options = body === undefined ? {} : {method:'POST',headers:{'Content-Type':'application/json','X-Office-Token':token},body:JSON.stringify(body)};
  const r = await fetch(path, {...options, cache:'no-store'});
  const data = await r.json();
  if(r.status===403 && body!==undefined && retry){token=(await api('/api/bootstrap')).token;return api(path,body,false);}
  if(!r.ok) throw new Error(data.error || '操作沒有完成，請稍後再試。');
  return data;
}
function date(value) { return new Date(value).toLocaleString('zh-TW',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'}); }
function renderList() {
  const signature=JSON.stringify([tasks,selected]); if(signature===lastList)return; lastList=signature;
  $('task-list').replaceChildren();
  if(!tasks.length) $('task-list').append(node('p','還沒有交辦，從一小段文字開始。','hint'));
  for(const task of tasks) {
    const b=node('button',undefined,'task'+(task.id===selected?' selected':'')); b.type='button'; b.setAttribute('aria-pressed',String(task.id===selected));
    b.append(node('strong',task.title==='新交辦'?task.prompt.slice(0,44):task.title),node('small',date(task.created)),node('span',labels[task.status]||task.status,'badge '+task.status));
    b.addEventListener('click',()=>{selected=task.id;lastDetail='';renderList();refreshDetail().catch(e=>message(e.message,true));}); $('task-list').append(b);
  }
}
let liveState=null;
function tickLive(){
  if(!liveState||!liveState.pulse.isConnected)return;
  const seconds=Math.max(0,Math.round((Date.now()-liveState.lastAt)/1000));
  liveState.pulse.textContent=seconds>45?`已 ${seconds} 秒沒有收到 VPS 的消息，可能是連線中斷或服務停住。`:`VPS ${seconds} 秒前有回報，仍在工作。`;
  liveState.pulse.className='live-pulse'+(seconds>45?' warn':'');
}
setInterval(tickLive,1000);
async function refreshDetail() {
  if(!selected)return;
  const id=selected, task=await api('/api/tasks/'+id); if(id!==selected)return;
  const signature=JSON.stringify(task);if(signature===lastDetail)return;lastDetail=signature;
  const box=$('task-detail');box.replaceChildren();
  box.append(node('h3',task.title),node('p',task.prompt,'prompt-view'));
  box.append(node('p','執行者：'+(task.executor==='codex'?'Codex · 外部 Agent':'Gemma · VPS 本機'),'hint'));
  if(task.parent_id)box.append(node('p','接續自：'+task.parent_id,'hint'));
  if(task.source)box.append(node('p','來源：'+task.source,'hint'));
  box.append(node('span',labels[task.status]||task.status,'badge '+task.status),node('p',task.stage));
  if(['queued','planning','running','saving'].includes(task.status)) {
    const b=node('button','停止這件任務','secondary');b.type='button';b.onclick=async()=>{try{await api('/api/tasks/'+id+'/cancel',{});await refresh();}catch(e){message(e.message,true);}};box.append(b);
  }
  const continuation=node('button','接續這件工作','secondary');continuation.type='button';continuation.onclick=()=>{parentId=id;$('parent-context').textContent='將附上這件工作的交接：'+task.prompt.slice(0,60);$('parent-context').hidden=false;$('clear-parent').hidden=false;$('executor').value='codex';privacy();$('prompt').focus();$('command-form').scrollIntoView({behavior:'smooth'});};box.append(continuation);
  const active=['queued','planning','running','saving'].includes(task.status);
  const noteLabels={thinking:'思考',message:'回報',tool:'工具'};
  const isPulse=e=>e.status==='running'&&/^Codex (處理中：|正在處理，已等待)/.test(e.message);
  const notes=task.events.filter(e=>noteLabels[e.status]);
  if(active){
    const last=notes[notes.length-1];
    const live=node('div',undefined,'live'+(/可能卡住/.test(task.stage)?' stalled':''));
    live.append(node('strong',notes.length?`已做 ${notes.length} 個步驟`:'還沒有步驟回報'));
    if(last)live.append(node('p','最新：'+last.message.split('\n')[0].slice(0,120)));
    const pulse=node('p','','live-pulse');live.append(pulse);box.append(live);
    const latest=task.events[task.events.length-1];liveState={pulse,lastAt:latest?Date.parse(latest.at):Date.now()};tickLive();
  } else liveState=null;
  const events=node('ol',undefined,'events');let step=0,previous='';
  for(const e of task.events){
    const label=noteLabels[e.status];
    if(!label&&(isPulse(e)||e.message===previous))continue;
    const li=node('li');
    if(label){step+=1;li.className='note '+e.status;li.append(node('span',`步驟 ${step} · ${label}`,'note-label'),node('span',date(e.at),'note-time'),node('div',e.message,'note-text'));previous='';}
    else{li.textContent=date(e.at)+' · '+e.message;previous=e.message;}
    events.append(li);
  }
  box.append(events);if(active)events.scrollTop=events.scrollHeight;
  if(task.result!==null) {
    box.append(node('h3',task.status==='needs_external'?'交接單':'保存的內容','result-title'),node('pre',task.result));
    const a=node('a','下載 Markdown');a.href='/api/tasks/'+id+'/download';a.setAttribute('download',task.status==='needs_external'?'brief.md':'result.md');box.append(a);
    box.append(node('p','VPS 位置：data/'+task.artifact,'hint'));
  }
  if(['needs_provider','needs_input','failed','interrupted','incomplete'].includes(task.status))box.append(node('p','可以在上方補上內容，重新交辦。這筆紀錄會保留。','hint'));
  if(handoffSelected===id)await loadHandoff();
}
async function refresh() {
  const data=await api('/api/tasks');tasks=data.tasks;connected=true;
  $('mode').textContent=data.paused?'辦公室暫停中':'依序處理';$('pause').disabled=data.paused;$('resume').disabled=!data.paused;
  $('connection').textContent='已連上 VPS';
  if(!selected&&tasks.length)selected=tasks[0].id;
  renderList();await refreshDetail();if(selected!==handoffSelected)await loadHandoff();await loadJournal();
}
async function files() {
  const data=await api('/api/files'), old=$('source').value;
  $('source').replaceChildren(new Option('直接處理上面貼的內容',''));
  for(const file of data.files)$('source').append(new Option(file.name,file.name));
  $('source').value=old;
}
async function sendControl(prompt) { try{const r=await api('/api/command',{prompt});message(r.message);await refresh();}catch(e){message(e.message,true);} }
$('pause').onclick=()=>sendControl('先停一下');$('resume').onclick=()=>sendControl('繼續工作');
$('command-form').addEventListener('submit',async event=>{
  event.preventDefault();const prompt=$('prompt').value.trim(), source=$('source').value;if(!prompt)return;
  const fields={prompt,source,executor:$('executor').value,parent_id:parentId,journal_ids:[...selectedJournal].sort()};
  if(!pendingRequest||JSON.stringify(pendingRequest.fields)!==JSON.stringify(fields))pendingRequest={id:crypto.randomUUID(),fields};
  $('submit').disabled=true;
  try{const r=await api('/api/command',{id:pendingRequest.id,...pendingRequest.fields});if(r.task){selected=r.task.id;$('prompt').value='';lastDetail='';clearParent();selectedJournal.clear();renderJournal();}pendingRequest=null;message(r.message);await refresh();}
  catch(e){message(e.message+' 若連線中斷，保留內容重送會沿用同一編號。',true);}
  finally{$('submit').disabled=false;}
});
$('upload').addEventListener('change',async()=>{
  const file=$('upload').files[0];if(!file)return;
  try{if(file.size>48000)throw new Error('檔案上限為 48KB。');const text=new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer());await api('/api/files',{name:file.name,text});await files();$('source').value=file.name;message('文字檔已放進收件匣，請交代要怎麼處理。');}
  catch(e){message(e.message,true);}finally{$('upload').value='';}
});
async function init(){
  try{token=(await api('/api/bootstrap')).token;await files();await refresh();await loadJournal();await providerHealth();}
  catch(e){$('connection').textContent='暫時無法連線';message(e.message,true);}
}
init();
setInterval(async()=>{if(document.hidden)return;try{if(!token)await init();else await refresh();}catch(e){if(connected){connected=false;$('connection').textContent='連線中斷，已交辦工作仍留在 VPS';}}},2000);
document.addEventListener('visibilitychange',()=>{if(!document.hidden)init();});

function clearParent(){parentId='';$('parent-context').hidden=true;$('clear-parent').hidden=true;}
$('clear-parent').onclick=clearParent;
function privacy(){$('privacy-hint').textContent=$('executor').value==='codex'?'交辦、選定來源與選取的交接／生活紀錄會交給 OpenAI 處理。其他生活紀錄不會自動附加。':'Gemma 在 VPS 處理短文字，合計約千字內；不會上網或自動呼叫外部 Agent。';}
$('executor').onchange=privacy;
function showPage(life){$('work-page').hidden=life;$('life-page').hidden=!life;$('show-work').setAttribute('aria-pressed',String(!life));$('show-life').setAttribute('aria-pressed',String(life));}
$('show-work').onclick=()=>showPage(false);$('show-life').onclick=()=>showPage(true);
async function providerHealth(){const h=await api('/api/health'),p=h.provider;$('model').textContent='Codex · '+(p.authenticated?(p.last_success?'登入有效 · 曾完成真實工作':'已登入 · 尚待真任務驗證'):'等待 VPS 本人登入')+' ／ Gemma · '+(h.model.ready?'可用':'按需啟動');}
async function loadHandoff(){
  const id=selected;if(!id)return;const h=await api('/api/tasks/'+id+'/handoff');if(id!==selected)return;
  if(handoffSelected!==id){$('handoff-note').value='';$('next-step').value='';$('handoff-message').textContent='';pendingHandoff=null;}
  handoffSelected=id;$('handoff-area').hidden=false;$('handoff-text').textContent=h.text;
  $('handoff-download').href='/api/tasks/'+id+'/handoff/download';$('handoff-download').setAttribute('download','handoff.md');
}
$('handoff-form').onsubmit=async event=>{
  event.preventDefault();const taskId=selected,note=$('handoff-note').value.trim(),next_step=$('next-step').value.trim();
  const fields={taskId,note,next_step};if(!pendingHandoff||JSON.stringify(pendingHandoff.fields)!==JSON.stringify(fields))pendingHandoff={id:crypto.randomUUID(),fields};
  const b=event.submitter;b.disabled=true;
  try{await api('/api/tasks/'+taskId+'/handoff',{id:pendingHandoff.id,note,next_step});pendingHandoff=null;if(selected===taskId){$('handoff-note').value='';$('next-step').value='';await loadHandoff();$('handoff-message').textContent='交接已保存，可下載或接續工作。';}await refresh();}
  catch(e){$('handoff-message').textContent=e.message;}finally{b.disabled=false;}
};
async function loadJournal(){const data=await api('/api/journal'),sig=JSON.stringify(data.entries);if(sig!==journalSignature){journalSignature=sig;journalEntries=data.entries;renderJournal();}}
function renderJournal(){
  $('journal-list').replaceChildren();$('journal-context').replaceChildren();
  if(!journalEntries.length){$('journal-list').append(node('p','還沒有生活紀錄。','hint'));$('journal-context').append(node('p','可以先到「生活紀錄」留下一段話。','hint'));}
  for(const e of journalEntries){const article=node('article');article.append(node('strong',e.day),node('p',e.text,'journal-entry'));$('journal-list').append(article);
    const label=node('label',undefined,'context-choice'),input=document.createElement('input');input.type='checkbox';input.value=e.id;input.checked=selectedJournal.has(e.id);input.onchange=()=>{if(input.checked&&selectedJournal.size>=10){input.checked=false;message('每次最多選取十筆生活紀錄。',true);return;}if(input.checked)selectedJournal.add(e.id);else selectedJournal.delete(e.id);$('context-count').textContent=selectedJournal.size?'（已選 '+selectedJournal.size+' 筆）':'';};label.append(input,document.createTextNode(e.day+' · '+e.text.slice(0,100)));$('journal-context').append(label);
  }
  $('context-count').textContent=selectedJournal.size?'（已選 '+selectedJournal.size+' 筆）':'';
}
const today=new Date();$('journal-day').value=[today.getFullYear(),String(today.getMonth()+1).padStart(2,'0'),String(today.getDate()).padStart(2,'0')].join('-');
$('journal-form').onsubmit=async event=>{
  event.preventDefault();const fields={day:$('journal-day').value,text:$('journal-text').value.trim()};if(!fields.text)return;
  if(!pendingJournal||JSON.stringify(pendingJournal.fields)!==JSON.stringify(fields))pendingJournal={id:crypto.randomUUID(),fields};$('journal-save').disabled=true;
  try{await api('/api/journal',{id:pendingJournal.id,...fields});pendingJournal=null;$('journal-text').value='';$('journal-message').textContent='原話已保存在 VPS，未交給模型。';await loadJournal();}
  catch(e){$('journal-message').textContent=e.message;}finally{$('journal-save').disabled=false;}
};
setInterval(()=>{if(!document.hidden)providerHealth().catch(()=>{});},15000);
