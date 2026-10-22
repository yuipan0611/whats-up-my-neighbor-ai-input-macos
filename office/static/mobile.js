'use strict';
(() => {
  const byId = id => document.getElementById(id);
  const mobile = () => matchMedia('(max-width:760px)').matches;
  const mediaExtensions = new Set(['pdf', 'png', 'jpg', 'jpeg', 'webp']);
  const allowedExtensions = new Set(['txt', 'md', ...mediaExtensions]);
  let listing = false, newChat = false, attachment = null, uploadedName = '', pending = null;
  let recognition = null;
  let codexState = '可交辦';
  const previousTasks = new Map();

  function icon(name, className = '') {
    const img = document.createElement('img');
    img.src = '/icon-' + name + '.svg';
    img.alt = '';
    if (className) img.className = className;
    return img;
  }
  function el(tag, content, className = '') {
    const item = document.createElement(tag);
    if (content !== undefined) item.textContent = content;
    if (className) item.className = className;
    return item;
  }
  function avatar(executor) {
    const image = document.createElement('img');
    image.src = executor === 'gemma' ? '/neko-gemma.png' : '/neko-openai.png';
    image.alt = '';
    image.className = 'mobile-cat-avatar';
    return image;
  }
  function status(text, error = false) {
    byId('mobile-message').textContent = text;
    byId('mobile-message').classList.toggle('error', error);
  }
  function closeAttach() {
    byId('mobile-attach-menu').hidden = true;
    byId('mobile-attach').setAttribute('aria-expanded', 'false');
  }
  function closeModel() {
    byId('mobile-model-overlay').hidden = true;
    byId('mobile-model').setAttribute('aria-expanded', 'false');
  }
  function closeMenu() {
    byId('mobile-menu-panel').hidden = true;
    byId('mobile-menu').setAttribute('aria-expanded', 'false');
  }
  function setExecutor(executor) {
    byId('executor').value = executor;
    privacy();
    byId('mobile-model-label').textContent = executor === 'gemma' ? 'Gemma · 本機' : 'Codex · 預設';
    renderModelOptions();
    if (newChat) renderEmpty();
  }
  function modelOption(name, detail, executor, available, avatarSrc) {
    const button = el('button', undefined, 'mobile-model-option');
    button.type = 'button';
    button.disabled = !available;
    if (avatarSrc) {
      const image = document.createElement('img');
      image.src = avatarSrc;
      image.alt = '';
      image.className = 'mobile-model-avatar';
      button.append(image);
    }
    button.append(el('strong', name), el('small', available ? detail : '尚未接通'));
    if (available && byId('executor').value === executor) button.append(icon('check', 'mobile-selected-check'));
    if (available) button.addEventListener('click', () => { setExecutor(executor); closeModel(); byId('mobile-prompt').focus(); });
    return button;
  }
  function renderModelOptions() {
    const box = byId('mobile-model-options');
    box.replaceChildren();
    const mediaAttached = attachment && mediaExtensions.has(attachment.name.split('.').pop().toLowerCase());
    const groups = [
      ['OpenAI', [
        ['Codex · 帳號預設', codexState, 'codex', true],
        ['Luna', '', '', false], ['Sol', '', '', false], ['Astra', '', '', false]
      ]],
      ['Anthropic', [['Claude', '', '', false]]],
      ['Google', [['Gemini', '', '', false], ['Gemma 3 4B', mediaAttached ? '圖片與 PDF 請改用 Codex' : 'VPS 本機文字模型', 'gemma', !mediaAttached]]]
    ];
    for (const [heading, options] of groups) {
      const group = el('section', undefined, 'mobile-model-group');
      group.append(el('h3', heading));
      for (const [name, detail, executor, available] of options) {
        const avatarSrc = heading === 'OpenAI' ? '/neko-openai.png'
          : name === 'Claude' ? '/neko-claude.png'
          : name === 'Gemma 3 4B' ? '/neko-gemma.png' : '';
        const option = modelOption(name, detail, executor, available, avatarSrc);
        if (name === 'Gemma 3 4B' && mediaAttached) option.querySelector('small').textContent = detail;
        group.append(option);
      }
      box.append(group);
    }
  }
  function updateAttachment() {
    const chip = byId('mobile-attachment-chip');
    chip.hidden = !attachment;
    byId('mobile-attachment-name').textContent = attachment?.name || '';
    renderModelOptions();
  }
  function selectFile(file) {
    if (!file) return;
    if (file.name.length > 100 || file.name.startsWith('.')) { status('請使用 100 字以內的檔名。', true); return; }
    const extension = file.name.split('.').pop().toLowerCase();
    if (!allowedExtensions.has(extension)) { status('可附加 TXT、Markdown、PDF、PNG、JPEG 或 WebP。', true); return; }
    const limit = mediaExtensions.has(extension) ? 8 * 1024 * 1024 : 48000;
    if (file.size > limit) { status(mediaExtensions.has(extension) ? '圖片與 PDF 每份上限 8MB。' : '文字檔上限 48KB。', true); return; }
    if (!file.size) { status('檔案是空的，請選擇其他檔案。', true); return; }
    attachment = file; uploadedName = ''; pending = null;
    if (mediaExtensions.has(extension) && byId('executor').value === 'gemma') {
      setExecutor('codex');
      status('圖片與 PDF 將交給 Codex 讀取。');
    } else status('已選擇附件，送出時才會上傳。');
    updateAttachment(); closeAttach();
  }
  async function uploadSelected() {
    if (!attachment || uploadedName) return uploadedName;
    const extension = attachment.name.split('.').pop().toLowerCase();
    let result, payload, endpoint;
    if (mediaExtensions.has(extension)) {
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).split(',')[1]);
        reader.onerror = () => reject(new Error('附件讀取失敗。'));
        reader.readAsDataURL(attachment);
      });
      const pages = extension === 'pdf' ? await renderPdfPages(attachment) : undefined;
      endpoint = '/api/attachments';
      payload = {name: attachment.name, data, ...(pages ? {pages} : {})};
    } else {
      const text = new TextDecoder('utf-8', {fatal: true}).decode(await attachment.arrayBuffer());
      endpoint = '/api/files'; payload = {name: attachment.name, text};
    }
    try { result = await api(endpoint, payload); }
    catch (error) {
      if (!error.message.includes('同名檔案已存在')) throw error;
      const stem = attachment.name.slice(0, -(extension.length + 1)).slice(0, 78);
      payload.name = `${stem}-${crypto.randomUUID().slice(0, 8)}.${extension}`;
      result = await api(endpoint, payload);
    }
    uploadedName = result.name;
    return uploadedName;
  }
  async function renderPdfPages(file) {
    status('正在讀取 PDF 頁面…');
    const pdfjs = await import('/pdf-main.mjs');
    pdfjs.GlobalWorkerOptions.workerSrc = '/pdf-worker.mjs';
    const pdf = await pdfjs.getDocument({data: new Uint8Array(await file.arrayBuffer())}).promise;
    try {
      if (pdf.numPages < 1 || pdf.numPages > 8) throw new Error('PDF 目前每份最多 8 頁，請先拆分檔案。');
      const pages = [];
      for (let number = 1; number <= pdf.numPages; number++) {
        status(`正在讀取 PDF 第 ${number}／${pdf.numPages} 頁…`);
        const page = await pdf.getPage(number);
        const natural = page.getViewport({scale: 1});
        if (!natural.width || !natural.height) throw new Error('PDF 頁面尺寸不正確。');
        const viewport = page.getViewport({scale: Math.min(1.8, 1400 / natural.width, 2000 / natural.height)});
        const canvas = document.createElement('canvas');
        canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
        await page.render({canvasContext: canvas.getContext('2d', {alpha: false}), viewport}).promise;
        const encoded = canvas.toDataURL('image/jpeg', .8).split(',')[1];
        pages.push(encoded);
        canvas.width = canvas.height = 0;
        page.cleanup();
      }
      const bytes = pages.reduce((sum, page) => sum + Math.floor(page.length * .75), 0);
      if (bytes > 8 * 1024 * 1024) throw new Error('PDF 頁面轉換後超過 8MB，請使用較小的檔案。');
      return pages;
    } finally { await pdf.destroy(); }
  }
  function renderResult(box, value) {
    const lines = value.split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const heading = trimmed.match(/^#{1,3}\s+(.+)/);
      const numbered = trimmed.match(/^(\d+)[.)]\s+(.+)/);
      const bullet = trimmed.match(/^[-*]\s+(.+)/);
      if (heading) box.append(el('h3', heading[1].replace(/\*\*/g, '')));
      else if (numbered) {
        const row = el('div', undefined, 'mobile-result-item');
        const content = el('div', undefined, 'mobile-result-copy');
        const clean = numbered[2].replace(/\*\*/g, '');
        const colon = clean.indexOf('：');
        if (colon > 0 && colon < 30) {
          content.append(el('strong', clean.slice(0, colon)));
          content.append(el('p', clean.slice(colon + 1).trim()));
        } else content.append(el('p', clean));
        row.append(el('span', numbered[1], 'mobile-result-number'), content);
        box.append(row);
      } else box.append(el('p', (bullet ? '• ' + bullet[1] : trimmed).replace(/\*\*/g, '')));
    }
  }
  function renderOneTask(task) {
    const group = el('article', undefined, 'mobile-turn');
    group.append(el('p', task.prompt, 'mobile-user-bubble'));
    if (task.source) {
      const file = el('div', undefined, 'mobile-source');
      file.append(icon('paperclip'), el('span', task.source));
      group.append(file);
    }
    const handoff = el('div', `貓咪辦公室已交給 ${task.executor === 'gemma' ? 'Gemma' : 'Codex'}`, 'mobile-handoff');
    group.append(handoff);
    const answer = el('div', undefined, 'mobile-answer');
    const byline = el('div', undefined, 'mobile-agent-byline');
    byline.append(avatar(task.executor), el('strong', task.executor === 'gemma' ? 'Gemma' : 'Codex'));
    answer.append(byline);
    let download = null;
    if (task.result) {
      if (!/^\s*#{1,3}\s+/.test(task.result)) answer.append(el('h2', task.status === 'completed' ? '整理好了' : '目前成果'));
      const result = el('div', undefined, 'mobile-result');
      renderResult(result, task.result);
      answer.append(result);
      download = el('a', '下載 Markdown', 'mobile-download');
      download.href = '/api/tasks/' + task.id + '/download';
      download.download = 'result.md';
    } else {
      answer.append(el('h2', labels[task.status] || task.status));
      answer.append(el('p', task.stage, 'mobile-stage'));
    }
    const notes = (task.events || []).filter(event => ['thinking', 'message', 'tool'].includes(event.status));
    const process = document.createElement('details');
    process.className = 'mobile-process';
    const summary = document.createElement('summary');
    summary.append(icon('code-xml'), el('span', `工作過程 · ${notes.length} 步`), icon('chevron-down'));
    process.append(summary);
    const history = el('ol', undefined, 'mobile-process-list');
    for (const note of notes) history.append(el('li', note.status === 'thinking' ? 'Codex 正在整理內容。' : note.message));
    if (!notes.length) history.append(el('li', '還沒有工作步驟。'));
    process.append(history);
    if (download) process.append(download);
    answer.append(process);
    group.append(answer);
    return group;
  }
  async function ancestorChain(task) {
    const chain = [task], seen = new Set([task.id]);
    let current = task;
    while (current.parent_id && chain.length < 12 && !seen.has(current.parent_id)) {
      seen.add(current.parent_id);
      try {
        current = previousTasks.get(current.parent_id) || await api('/api/tasks/' + current.parent_id);
        previousTasks.set(current.id, current);
        chain.unshift(current);
      } catch { break; }
    }
    return chain;
  }
  async function renderTask(task) {
    if (!mobile() || newChat || listing) return;
    const thread = byId('mobile-thread');
    const nearBottom = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 130;
    const oldScroll = thread.scrollTop;
    const chain = await ancestorChain(task);
    if (task.id !== selected || listing || newChat) return;
    thread.replaceChildren(...chain.map(renderOneTask));
    const title = chain[0]?.title && chain[0].title !== '新交辦' ? chain[0].title : (chain[0]?.prompt || task.prompt).split('\n')[0];
    byId('mobile-thread-title').textContent = title.length > 12 ? title.slice(0, 12) + '…' : title;
    if (nearBottom) thread.scrollTop = thread.scrollHeight;
    else thread.scrollTop = oldScroll;
  }
  function renderEmpty() {
    if (!mobile() || listing) return;
    byId('mobile-thread-title').textContent = '新對話';
    const empty = el('div', undefined, 'mobile-empty');
    empty.append(avatar(byId('executor').value), el('h2', '今天要交給貓咪什麼？'), el('p', '交代工作，進度與成果會留在這裡。'));
    byId('mobile-thread').replaceChildren(empty);
  }
  function renderList() {
    const box = byId('mobile-task-list');
    box.replaceChildren(el('h2', '對話'));
    if (!tasks.length) box.append(el('p', '還沒有對話，先交代一件事吧。', 'mobile-list-empty'));
    const byTaskId = new Map(tasks.map(task => [task.id, task]));
    const rootId = task => {
      const seen = new Set([task.id]);
      while (task.parent_id && byTaskId.has(task.parent_id) && !seen.has(task.parent_id)) {
        task = byTaskId.get(task.parent_id); seen.add(task.id);
      }
      return task.id;
    };
    const roots = tasks.filter(task => rootId(task) === task.id);
    for (const task of roots) {
      const latest = tasks.find(candidate => rootId(candidate) === task.id) || task;
      const button = el('button', undefined, 'mobile-task-row');
      button.type = 'button';
      button.append(el('strong', task.title === '新交辦' ? task.prompt.slice(0, 48) : task.title), el('small', labels[latest.status] || latest.status));
      button.addEventListener('click', () => {
        listing = false; newChat = false; selected = latest.id; lastDetail = '';
        byId('mobile-back').hidden = false;
        byId('mobile-prompt').placeholder = '接續這件工作…';
        box.hidden = true; byId('mobile-thread').hidden = false; byId('mobile-composer-wrap').hidden = false;
        refreshDetail().catch(error => status(error.message, true));
      });
      box.append(button);
    }
  }
  async function submit(event) {
    event.preventDefault();
    const prompt = byId('mobile-prompt').value.trim();
    if (!prompt) { status('請先輸入要交代的工作。', true); byId('mobile-prompt').focus(); return; }
    if (attachment && mediaExtensions.has(attachment.name.split('.').pop().toLowerCase()) && byId('executor').value !== 'codex') {
      status('圖片與 PDF 目前只能交給 Codex。', true); return;
    }
    const button = byId('mobile-send');
    button.disabled = true;
    try {
      status(attachment ? '正在附加檔案…' : '正在送出…');
      const source = await uploadSelected();
      const fields = {prompt, source: source || '', executor: byId('executor').value, parent_id: newChat ? '' : selected, journal_ids: []};
      if (!pending || JSON.stringify(pending.fields) !== JSON.stringify(fields)) pending = {id: crypto.randomUUID(), fields};
      const response = await api('/api/command', {id: pending.id, ...pending.fields});
      if (response.task) {
        selected = response.task.id; lastDetail = ''; newChat = false; listing = false;
        byId('mobile-prompt').placeholder = '接續這件工作…';
        byId('mobile-prompt').value = ''; attachment = null; uploadedName = ''; updateAttachment(); pending = null;
        await refresh();
        byId('mobile-thread').scrollTop = byId('mobile-thread').scrollHeight;
        status('交辦已保存。');
      } else status(response.message || '已送出。');
    } catch (error) {
      status(error.message + ' 內容會保留，請檢查後重試。', true);
    } finally { button.disabled = false; }
  }
  function startSpeech() {
    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!Recognition) { status('這個瀏覽器無法啟動語音輸入；可用鍵盤上的麥克風口述。', true); byId('mobile-prompt').focus(); return; }
    if (recognition) { recognition.stop(); return; }
    recognition = new Recognition();
    recognition.lang = 'zh-TW';
    recognition.interimResults = false;
    recognition.onresult = event => {
      const spoken = Array.from(event.results).map(result => result[0].transcript).join('');
      byId('mobile-prompt').value = [byId('mobile-prompt').value.trim(), spoken].filter(Boolean).join(' ');
      status('語音已加入輸入框，確認後再送出。');
    };
    recognition.onerror = () => status('語音輸入沒有完成，可改用鍵盤輸入。', true);
    recognition.onend = () => { recognition = null; byId('mobile-mic').classList.remove('listening'); };
    try { recognition.start(); byId('mobile-mic').classList.add('listening'); status('正在聆聽…'); }
    catch { recognition = null; status('無法啟動語音輸入。', true); }
  }
  function pageChanged(life) {
    if (life) { closeAttach(); closeModel(); closeMenu(); }
  }
  function updateHealth(health) {
    codexState = health.provider?.authenticated ? '已登入' : '等待登入，交辦會保留';
    renderModelOptions();
  }

  byId('mobile-form').addEventListener('submit', submit);
  byId('mobile-prompt').addEventListener('keydown', event => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); byId('mobile-form').requestSubmit(); }
  });
  byId('mobile-attach').addEventListener('click', () => {
    closeModel(); closeMenu();
    const menu = byId('mobile-attach-menu');
    menu.hidden = !menu.hidden;
    byId('mobile-attach').setAttribute('aria-expanded', String(!menu.hidden));
  });
  byId('mobile-pick-file').onclick = () => { byId('mobile-file-input').removeAttribute('capture'); byId('mobile-file-input').click(); };
  byId('mobile-pick-photo').onclick = () => { byId('mobile-file-input').accept = 'image/png,image/jpeg,image/webp'; byId('mobile-file-input').click(); };
  byId('mobile-pick-camera').onclick = () => byId('mobile-camera-input').click();
  for (const id of ['mobile-file-input', 'mobile-camera-input']) byId(id).addEventListener('change', event => {
    selectFile(event.target.files[0]); event.target.value = '';
    byId('mobile-file-input').accept = '.txt,.md,.pdf,.png,.jpg,.jpeg,.webp,text/plain,text/markdown,application/pdf,image/png,image/jpeg,image/webp';
  });
  byId('mobile-remove-attachment').onclick = () => { attachment = null; uploadedName = ''; pending = null; updateAttachment(); status('已移除附件。'); };
  byId('mobile-model').onclick = () => { closeAttach(); closeMenu(); renderModelOptions(); byId('mobile-model-overlay').hidden = false; byId('mobile-model').setAttribute('aria-expanded', 'true'); };
  byId('mobile-model-close').onclick = closeModel;
  byId('mobile-model-backdrop').onclick = closeModel;
  byId('mobile-mic').onclick = startSpeech;
  byId('mobile-back').onclick = () => {
    listing = true; closeAttach(); closeModel(); closeMenu(); renderList();
    byId('mobile-back').hidden = true;
    byId('mobile-task-list').hidden = false; byId('mobile-thread').hidden = true; byId('mobile-composer-wrap').hidden = true;
    byId('mobile-thread-title').textContent = '貓咪辦公室';
  };
  byId('mobile-new').onclick = () => {
    newChat = true; listing = false; selected = ''; lastDetail = '';
    byId('mobile-back').hidden = false;
    byId('mobile-prompt').placeholder = '交代一件工作…';
    byId('mobile-task-list').hidden = true; byId('mobile-thread').hidden = false; byId('mobile-composer-wrap').hidden = false;
    byId('mobile-prompt').value = ''; attachment = null; uploadedName = ''; pending = null; updateAttachment();
    renderEmpty(); byId('mobile-prompt').focus();
  };
  byId('mobile-menu').onclick = () => {
    closeAttach(); closeModel(); const panel = byId('mobile-menu-panel'); panel.hidden = !panel.hidden;
    byId('mobile-menu').setAttribute('aria-expanded', String(!panel.hidden));
    byId('mobile-pause').textContent = byId('pause').disabled ? '繼續工作' : '暫停辦公室';
  };
  byId('mobile-show-life').onclick = () => { closeMenu(); showPage(true); };
  byId('mobile-life-back').onclick = () => showPage(false);
  byId('mobile-pause').onclick = () => { const command = byId('pause').disabled ? '繼續工作' : '先停一下'; closeMenu(); sendControl(command); };
  document.addEventListener('keydown', event => { if (event.key === 'Escape') { closeAttach(); closeModel(); closeMenu(); } });
  document.addEventListener('click', event => {
    if (!byId('mobile-attach-menu').hidden && !byId('mobile-attach-menu').contains(event.target) && !byId('mobile-attach').contains(event.target)) closeAttach();
    if (!byId('mobile-menu-panel').hidden && !byId('mobile-menu-panel').contains(event.target) && !byId('mobile-menu').contains(event.target)) closeMenu();
  });
  window.mobileOffice = {renderList, renderTask, renderEmpty, pageChanged, updateHealth, isNewChat: () => newChat};
  setExecutor(byId('executor').value);
  renderEmpty();
})();
