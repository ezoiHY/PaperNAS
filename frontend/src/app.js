import { API, fileName } from './api.js';
import { el, icon, button, iconButton, badge, muted, empty, date, authors, externalLink, field, select, textBlock, markdown, notify, dialog, formDialog } from './ui.js';
import { renderQuestions, renderQuestion, evidenceDialog } from './research.js';

const api = new API();
const root = document.querySelector('#app');
const state = { groups: [], counts: {}, selected: new Set(), objectURLs: new Set(), generation: 0, currentPaper: null, currentQuestion: null };
const SESSION = 'papernas.session.v2';
try {
  const saved = JSON.parse(sessionStorage.getItem(SESSION) || 'null');
  if (saved) { api.token = saved.token || ''; api.deviceID = saved.deviceID || ''; }
  document.documentElement.dataset.theme = localStorage.getItem('papernas.theme') || 'system';
} catch { /* Storage can be unavailable in private browsing. */ }

function rememberSession() {
  try {
    if (api.token) sessionStorage.setItem(SESSION, JSON.stringify({ token: api.token, deviceID: api.deviceID }));
    else sessionStorage.removeItem(SESSION);
  } catch { /* The current tab still works using the in-memory credential. */ }
}
function go(path) { location.hash = '#' + path; }
function route() {
  const [path, query = ''] = (location.hash.slice(1) || '/library').split('?');
  return { parts: path.split('/').filter(Boolean), params: new URLSearchParams(query) };
}
function releaseObjects() { for (const url of state.objectURLs) URL.revokeObjectURL(url); state.objectURLs.clear(); }
function objectURL(blob) { const url = URL.createObjectURL(blob); state.objectURLs.add(url); return url; }
async function resource(path) { const response = await api.call(path, { raw: true }); return objectURL(await response.blob()); }
async function download(path, name, type) {
  const response = await api.call(path, { raw: true });
  const blob = await response.blob();
  saveBlob(type ? new Blob([blob], { type }) : blob, name);
}
function saveBlob(blob, name) {
  const url = URL.createObjectURL(blob);
  const link = el('a', { href: url, download: name }); document.body.append(link); link.click(); link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
function fail(error) {
  if (error.status === 401) { api.token = ''; api.deviceID = ''; rememberSession(); login(); }
  notify(error.message, true);
}
function action(fn) { return async (...args) => { try { await fn(...args); } catch (error) { fail(error); } }; }
function context() { return { api, go, refresh: render, download, runOperation, action, state, resource, addEvidence }; }

function login(message = '') {
  releaseObjects(); state.generation++;
  const key = el('input', { type: 'password', required: true, autocomplete: 'off', placeholder: 'Server access key' });
  const name = el('input', { value: 'Web browser', required: true, maxLength: 200, autocomplete: 'off' });
  const error = el('p', { class: 'form-error', role: 'alert', hidden: !message }, message);
  const submit = el('button', { class: 'primary', type: 'submit' }, 'Open workspace');
  const form = el('form', { class: 'login' },
    el('div', { class: 'brand' }, icon('book'), el('strong', {}, 'Paper NAS')),
    el('h1', {}, 'A quiet place for research.'),
    muted('Connect to this server to read your papers and continue your research. Your library stays on the server.'),
    field('Access key', key, 'Use the access key from your Paper NAS server. It is exchanged for a separate device credential.'),
    field('Device name', name, 'A name you can recognize in the device list.'), error, submit,
    muted('Your device credential is kept for this browser tab’s session. Signing out clears it. Use HTTPS when accessing this server over a network.'));
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (submit.disabled) return;
    submit.disabled = true; submit.textContent = 'Connecting…'; error.hidden = true;
    try { await api.connect(key.value, name.value); key.value = ''; rememberSession(); await render(); }
    catch (e) { error.textContent = e.message; error.hidden = false; }
    finally { submit.disabled = false; submit.textContent = 'Open workspace'; }
  });
  root.replaceChildren(el('main', { id: 'main' }, form));
}

function navLink(label, target, name, active, count) {
  return el('a', { href: '#' + target, 'aria-current': active ? 'page' : null }, icon(name), el('span', { class: 'name' }, label), count !== undefined && el('span', { class: 'count' }, count));
}
function shell(active, groupID = '') {
  const main = el('main', { class: 'main', id: 'main', tabIndex: -1 });
  const side = el('aside', { class: 'sidebar', 'aria-label': 'Workspace navigation' },
    el('div', { class: 'brand' }, icon('book'), el('div', {}, el('strong', {}, 'Paper NAS'), el('small', {}, 'Research workspace'))),
    el('nav', { class: 'nav', 'aria-label': 'Main' },
      navLink('Library', '/library', 'book', active === 'library' && !groupID, state.counts.library ?? 0),
      navLink('Candidates', '/candidates', 'inbox', active === 'candidates', state.counts.candidates ?? 0),
      navLink('Research', '/research', 'research', active === 'research'),
      navLink('Tasks', '/tasks', 'tasks', active === 'tasks')),
    el('section', {}, el('div', { class: 'group-heading' }, 'Groups', iconButton('plus', 'Create group', () => editGroup())),
      el('nav', { class: 'nav', 'aria-label': 'Groups' }, state.groups.map(g => navLink(g.name, '/groups/' + g.id, 'folder', groupID === g.id, g.count)),
        !state.groups.length && el('small', { class: 'group-heading' }, 'Organize papers by topic'))),
    el('div', { class: 'sidebar-foot' }, el('nav', { class: 'nav' }, navLink('Settings', '/settings', 'settings', active === 'settings')),
      el('span', { class: 'connection' }, location.host)));
  const frame = el('div', { class: 'shell' }, side, main); root.replaceChildren(frame);
  return main;
}
function menuButton() { return button(icon('menu'), () => root.querySelector('.shell')?.classList.toggle('nav-open'), 'icon-button mobile-menu', { 'aria-label': 'Toggle navigation' }); }
function header(main, title, count, ...actions) {
  main.append(el('header', { class: 'topbar' }, el('div', { class: 'actions' }, menuButton(), el('h1', {}, title, count !== undefined && el('small', {}, count))), el('div', { class: 'actions' }, ...actions)));
}
async function metadata() {
  const [groups, overview] = await Promise.all([api.call('/groups'), api.call('/overview')]);
  state.groups = groups.groups; state.counts = overview.counts;
}
async function render() {
  if (!api.token) { login(); return; }
  const generation = ++state.generation;
  releaseObjects(); state.selected.clear(); state.currentPaper = null; state.currentQuestion = null;
  try {
    await metadata(); if (generation !== state.generation) return;
    const { parts, params } = route();
    const page = parts[0] || 'library';
    const main = shell(page === 'papers' || page === 'groups' ? 'library' : page, page === 'groups' ? parts[1] : '');
    if (['library', 'candidates', 'groups'].includes(page)) await library(main, page, parts[1], params, generation);
    else if (page === 'papers' && parts[1]) await paper(main, parts[1], params, generation);
    else if (page === 'research' && parts[1]) await renderQuestion(main, parts[1], { ...context(), header, isCurrent: () => generation === state.generation });
    else if (page === 'research') await renderQuestions(main, { ...context(), header, isCurrent: () => generation === state.generation });
    else if (page === 'tasks') await tasks(main, generation);
    else if (page === 'settings') await settings(main, generation);
    else main.append(empty('Page not found', 'Return to your library to continue.', button('Open library', () => go('/library'), 'primary')));
    document.title = 'Paper NAS';
  } catch (error) {
    if (generation !== state.generation) return;
    if (error.status === 401) { fail(error); return; }
    const main = root.querySelector('main');
    if (main) main.append(el('section', { class: 'inline-error', role: 'alert' }, el('p', {}, error.message), button('Try again', render)));
    else login(error.message);
  }
}

function editGroup(group) {
  formDialog(group ? 'Rename group' : 'New group', [{ name: 'name', label: 'Name', value: group?.name, required: true, maxLength: 200 }], async values => {
    await api.call('/groups' + (group ? '/' + group.id : ''), { method: group ? 'PATCH' : 'POST', body: { ...values, ...(group ? { revision: group.revision } : {}) } });
    await render();
  });
}
async function assignGroups(papers) {
  const checked = new Set(papers.length === 1 ? papers[0].group_ids : []);
  const choices = el('div', { class: 'checkboxes' }, state.groups.map(group => {
    const input = el('input', { type: 'checkbox', checked: checked.has(group.id), onchange: () => input.checked ? checked.add(group.id) : checked.delete(group.id) });
    return el('label', {}, input, group.name);
  }));
  const form = el('form', { class: 'editor' }, muted(papers.length > 1 ? 'Selected groups are added to each paper. Existing groups are preserved.' : 'Choose the groups for this paper.'), choices);
  const d = dialog('Organize papers', form);
  const save = el('button', { type: 'submit', class: 'primary', disabled: !state.groups.length }, 'Save groups');
  const error = el('p', { class: 'form-error', hidden: true, role: 'alert' });
  if (!state.groups.length) form.append(muted('Create a group from the sidebar first.'));
  form.append(error, el('footer', {}, button('Cancel', d.close), save));
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (save.disabled) return; save.disabled = true;
    try {
      for (const p of papers) {
        const group_ids = papers.length > 1 ? [...new Set([...p.group_ids, ...checked])] : [...checked];
        await api.call('/works/' + p.id, { method: 'PATCH', body: { revision: p.revision, group_ids } });
      }
      d.close(); await render();
    } catch (e) { error.textContent = e.message; error.hidden = false; }
    finally { save.disabled = false; }
  });
}
function importDialog() {
  const type = select([['link', 'DOI, arXiv ID, or URL'], ['pdf', 'PDF file']], 'link', null, 'Import type');
  const reference = el('input', { required: true, placeholder: '10.… or https://arxiv.org/abs/…', maxLength: 3000 });
  const file = el('input', { type: 'file', accept: '.pdf,application/pdf' });
  const title = el('input', { maxLength: 1000, placeholder: 'Optional title' });
  const pdfFields = el('div', { class: 'editor', hidden: true }, field('PDF', file), field('Title', title));
  const linkField = field('Paper reference', reference);
  type.addEventListener('change', () => { const isPDF = type.value === 'pdf'; pdfFields.hidden = !isPDF; linkField.hidden = isPDF; file.required = isPDF; reference.required = !isPDF; });
  const error = el('p', { class: 'form-error', hidden: true, role: 'alert' });
  const submit = el('button', { class: 'primary', type: 'submit' }, 'Import paper');
  const form = el('form', { class: 'editor' }, field('Import from', type), linkField, pdfFields,
    muted('The server downloads and extracts the paper. Analysis is a separate action.'), error);
  const d = dialog('Add a paper', form); form.append(el('footer', {}, button('Cancel', d.close), submit));
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (submit.disabled) return; submit.disabled = true; submit.textContent = 'Importing…'; error.hidden = true;
    try {
      if (type.value === 'pdf') {
        if (file.files[0].size > 80 * 1024 * 1024) throw new Error('Choose a PDF smaller than 80 MB.');
        const data = new FormData(); data.append('file', file.files[0]);
        await api.call('/imports/pdf?title=' + encodeURIComponent(title.value), { method: 'POST', form: data });
      } else await api.call('/operations', { method: 'POST', body: { kind: 'import', reference: reference.value } });
      d.close(); notify('Paper import queued. You can follow its progress in Tasks.'); go('/tasks'); if (route().parts[0] === 'tasks') await render();
    } catch (e) { error.textContent = e.message; error.hidden = false; }
    finally { submit.disabled = false; submit.textContent = 'Import paper'; }
  });
}
async function runOperation(body) {
  await api.call('/operations', { method: 'POST', body }); notify('Task queued. Processing continues on the server.');
}
function analyze(papers) {
  formDialog('Analyze selected papers', [{ name: 'token_budget', label: 'Token budget for this operation', type: 'number', value: 120000, min: 1000, max: 2000000, required: true }],
    async values => { await runOperation({ kind: 'analyze', work_ids: papers.map(p => p.id), ...values }); },
    { submit: 'Start analysis', help: 'This sends paper excerpts to your configured model provider and may incur charges. The budget is measured in tokens, not money.' });
}
function discover() {
  formDialog('Discover papers', [
    { name: 'query', label: 'Search query', required: true, hint: 'For arXiv, use its query syntax, such as cat:cs.RO.' },
    { name: 'source', label: 'Source', type: 'select', options: [['arxiv', 'arXiv'], ['crossref', 'Crossref']] },
    { name: 'limit', label: 'Maximum results', type: 'number', min: 1, max: 100, value: 15, required: true },
  ], async ({ query, source, limit }) => { await runOperation({ kind: 'discover', query, sources: [source], limit }); }, { submit: 'Find papers' });
}
async function library(main, page, groupID, params, generation) {
  const group = state.groups.find(g => g.id === groupID);
  const collection = page === 'candidates' ? 'candidates' : 'library';
  const title = group?.name || (collection === 'library' ? 'Library' : 'Candidates');
  const count = group ? group.count : state.counts[collection] || 0;
  const tools = [];
  if (group) tools.push(button('Rename', () => editGroup(group), 'soft mobile-hide'), button('Delete group', action(async () => {
    if (!confirm('Delete this group? Its papers will remain in your library.')) return;
    await api.call('/groups/' + group.id, { method: 'DELETE' }); go('/library');
  }), 'soft mobile-hide'));
  if (collection === 'candidates') tools.push(button('Discover', discover, 'soft'));
  tools.push(iconButton('refresh', 'Refresh library', render), button('Add paper', importDialog, 'primary'));
  header(main, title, count, ...tools);
  const query = new URLSearchParams({ collection, limit: '40', sort: params.get('sort') || 'published_desc', offset: params.get('offset') || '0', q: params.get('q') || '', status: params.get('status') || '' });
  if (groupID) query.set('group', groupID);
  const search = el('input', { type: 'search', value: query.get('q'), placeholder: 'Search titles, authors, and text', 'aria-label': 'Search papers' });
  const base = page === 'groups' ? '/groups/' + groupID : '/' + collection;
  const navigate = (name, value) => { const next = new URLSearchParams(query); next.set(name, value); if (name !== 'offset') next.set('offset', '0'); next.delete('collection'); next.delete('limit'); next.delete('group'); go(base + '?' + next); };
  const searchForm = el('form', { class: 'search', onsubmit: e => { e.preventDefault(); navigate('q', search.value); } }, icon('search'), search);
  search.addEventListener('search', () => { if (!search.value) navigate('q', ''); });
  main.append(el('div', { class: 'filters' }, searchForm,
    select([['', 'All papers'], ['analyzed', 'Analyzed'], ['extracted', 'Extracted'], ['attention', 'Needs attention']], query.get('status'), e => navigate('status', e.target.value), 'Paper status'),
    select([['published_desc', 'Newest published'], ['published_asc', 'Oldest published'], ['added_desc', 'Recently added'], ['title', 'Title']], query.get('sort'), e => navigate('sort', e.target.value), 'Sort papers')));
  const result = await api.call('/works?' + query); if (generation !== state.generation) return;
  const papers = result.works || result.papers;
  const batch = el('div', { class: 'batchbar', hidden: true }); main.append(batch);
  const selected = () => papers.filter(p => state.selected.has(p.id));
  function updateBatch() {
    batch.hidden = !state.selected.size;
    batch.replaceChildren(el('span', {}, state.selected.size + ' selected'),
      button('Analyze', () => analyze(selected())), button('Groups', () => assignGroups(selected())),
      button(collection === 'candidates' ? 'Add to library' : 'Move to candidates', action(async () => {
        for (const p of selected()) await api.call('/works/' + p.id, { method: 'PATCH', body: { revision: p.revision, collection: collection === 'candidates' ? 'library' : 'candidates' } });
        await render();
      })), button('Clear', () => { state.selected.clear(); main.querySelectorAll('.paper-row input').forEach(c => c.checked = false); updateBatch(); }));
  }
  const list = el('div', { class: 'paper-list' });
  for (const p of papers) {
    const checkbox = el('input', { type: 'checkbox', 'aria-label': 'Select ' + p.title, onchange: () => { checkbox.checked ? state.selected.add(p.id) : state.selected.delete(p.id); updateBatch(); } });
    list.append(el('article', { class: 'paper-row' }, checkbox,
      el('div', {}, button(p.title, () => go('/papers/' + p.id), 'paper-title'),
        el('div', { class: 'paper-meta' }, el('span', { class: 'author' }, authors(p.authors) || p.source), date(p.published_at) && el('span', {}, date(p.published_at)), p.has_report && el('span', {}, 'Analysis ready'), p.notes_count > 0 && el('span', {}, p.notes_count + ' notes'))),
      el('div', { class: 'paper-tags' }, p.groups?.map(g => el('span', {}, g.name)))));
  }
  main.append(list);
  if (!papers.length) main.append(empty(query.get('q') || group ? 'No matching papers' : 'Your reading starts here', query.get('q') || group ? 'Try a different search or add papers to this group.' : 'Import a PDF or a paper link. Your library and notes stay together on your server.', button('Add paper', importDialog, 'primary')));
  const offset = Number(query.get('offset')); const total = result.total ?? papers.length;
  main.append(el('footer', { class: 'pager' }, el('span', {}, total ? `${offset + 1}–${offset + papers.length} of ${total}` : '0 papers'), el('div', { class: 'actions' },
    button('Previous', () => navigate('offset', Math.max(0, offset - 40)), 'soft', { disabled: offset === 0 }),
    button('Next', () => navigate('offset', offset + 40), 'soft', { disabled: offset + papers.length >= total }))));
}

function reportContent(report) {
  const body = el('div', { class: 'prose' });
  const claim = value => {
    if (typeof value === 'string') return textBlock(value);
    if (!value?.text) return null;
    return el('section', { class: 'claim' }, el('p', {}, value.text), (value.citations || []).map((citation, index) =>
      button('Source ' + (index + 1), action(async () => {
        const block = await api.call('/blocks/' + citation.block_id);
        dialog('Source evidence', el('div', {}, el('h3', {}, block.work_title), muted(block.page ? 'PDF page ' + block.page : 'PDF page unknown'), el('blockquote', {}, citation.quote), textBlock(block.text), button('Open paper', () => { document.querySelector('dialog')?.close(); go('/papers/' + block.work_id + '?tab=source&block=' + block.id); })), { wide: true });
      }), 'citation')));
  };
  if (report.summary) body.append(claim(report.summary));
  for (const [key, title] of [['findings', 'Findings'], ['limitations', 'Conditions and limitations'], ['unknowns', 'Still unknown'], ['suggested_next_steps', 'Suggested next steps']]) {
    if (report[key]?.length) body.append(el('h2', {}, title), ...report[key].map(claim).filter(Boolean));
  }
  return body;
}
async function addEvidence(p, source) {
  try { await evidenceDialog(p, source, context()); } catch (error) { fail(error); }
}
async function paper(main, id, params, generation) {
  const [p, pdf, reading] = await Promise.all([api.call('/works/' + id), api.call('/works/' + id + '/pdf/info'), api.call('/works/' + id + '/reading-state')]);
  if (generation !== state.generation) return; state.currentPaper = p;
  const tab = params.get('tab') || 'report';
  main.append(el('header', { class: 'topbar reader-top' }, el('div', { class: 'actions' }, menuButton(), button([icon('arrow'), ' Library'], () => go('/library'), 'soft')),
    el('div', { class: 'actions' }, button('Organize', () => assignGroups([p])), button('Analyze', () => analyze([p])), iconButton('refresh', 'Refresh paper', render), button('More', () => paperMenu(p, pdf)))));
  main.append(el('nav', { class: 'tabs', 'aria-label': 'Reading views' }, [['report', 'Analysis'], ['pdf', 'PDF'], ['source', 'Source text'], ['figures', 'Figures'], ['notes', 'Notes']].map(([key, label]) => button(label, () => go('/papers/' + id + '?tab=' + key), '', { 'aria-pressed': tab === key }))));
  const content = el('div', { class: tab === 'pdf' ? '' : 'reader' }); main.append(content);
  if (tab !== 'pdf') content.append(el('div', { class: 'masthead' }, el('h1', {}, p.title), muted([authors(p.authors), date(p.published_at), p.venue].filter(Boolean).join(' · '))));
  if (tab === 'report') {
    if (p.report_stale) content.append(muted('This analysis refers to an earlier extraction. Its citations still point to the original material.'));
    if (p.report?.summary?.text) content.append(reportContent(p.report));
    else if (p.markdown) content.append(markdown(p.markdown));
    else if (p.brief) { content.append(el('h2', {}, 'Earlier reading notes'), textBlock(p.brief.overview || p.brief.summary || p.summary)); }
    else content.append(el('h2', {}, 'Abstract'), textBlock(p.abstract || p.summary || 'No abstract is available.'), empty('Make time for a closer read', 'Generate an analysis when you are ready to examine the methods, evidence, and limitations.', button('Analyze paper', () => analyze([p]), 'primary')));
  } else if (tab === 'pdf') {
    if (!pdf.available) { content.append(empty('PDF not available yet', 'Fetch the source or attach a PDF from your computer.', button('Get paper materials', action(async () => runOperation({ kind: 'extract', work_ids: [id] })), 'primary'))); return; }
    const page = el('input', { type: 'number', min: 1, max: pdf.page_count || 500, value: reading.reading.page || 1, 'aria-label': 'PDF page' });
    const imageArea = el('div', { class: 'pdf-page' });
    const pageCount = el('span', { class: 'muted' }, pdf.page_count ? 'of ' + pdf.page_count : '');
    const cache = new Map(); let pageRequest = 0;
    const loadPage = action(async () => {
      if (!page.reportValidity()) return;
      const index = Number(page.value), request = ++pageRequest;
      if (!cache.has(index)) {
        imageArea.setAttribute('aria-busy', 'true');
        const response = await api.call('/works/' + id + '/pdf/pages/' + index + '?version_id=' + pdf.version_id, { raw: true });
        const url = objectURL(await response.blob()); cache.set(index, url);
        page.max = Number(response.headers.get('X-PDF-Page-Count')) || 500;
        pageCount.textContent = 'of ' + page.max;
      }
      if (generation !== state.generation || request !== pageRequest) return;
      imageArea.replaceChildren(el('img', { src: cache.get(index), alt: `${p.title}, PDF page ${index}. Extracted text is available in the Source text view.` }));
      imageArea.removeAttribute('aria-busy');
      previous.disabled = index <= 1; next.disabled = index >= Number(page.max);
    });
    const previous = button('Previous page', () => { page.value = Math.max(1, Number(page.value) - 1); loadPage(); });
    const next = button('Next page', () => { page.value = Math.min(Number(page.max), Number(page.value) + 1); loadPage(); });
    const tools = el('div', { class: 'pdf-tools' }, previous, el('span', {}, 'Page'), page, pageCount, button('Go to page', loadPage), next, button('Save position', action(async () => {
      if (!page.reportValidity()) return;
      const result = await api.call('/works/' + id + '/reading-state', { method: 'PUT', body: { page: Number(page.value), section: 'pdf', pdf_sha256: pdf.sha256, revision: reading.reading.revision } });
      reading.reading = result.reading; notify('Reading position saved.');
    })), button('Add note', () => noteDialog(p, pdf, null, Number(page.value))), iconButton('download', 'Download PDF', action(() => download('/works/' + id + '/pdf', fileName(p.title, 'pdf')))));
    content.append(tools, muted('Original PDF pages are rendered by your server. Use Source text for selectable passages, or download the PDF for your preferred viewer.'), imageArea);
    await loadPage();
  } else if (tab === 'source') {
    const blocks = p.document?.blocks || [];
    if (!blocks.length) content.append(empty('Source text is not available', 'Extract the paper to make its paragraphs available for citation.', button('Extract paper', action(() => runOperation({ kind: 'extract', work_ids: [id] })), 'primary')));
    for (const block of blocks) content.append(el('article', { class: 'source-block', id: 'block-' + block.id },
      block.heading && el('h3', {}, block.heading), el('p', {}, block.text),
      el('footer', {}, el('small', {}, block.page ? 'PDF page ' + block.page : 'PDF page unknown'), button('Save as evidence', () => addEvidence(p, { block }), 'soft'))));
    if (params.get('block')) document.getElementById('block-' + params.get('block'))?.scrollIntoView({ block: 'center' });
  } else if (tab === 'figures') {
    const figures = p.document?.figures || [];
    if (!figures.length) content.append(empty('No figures extracted', 'Figures appear here after the server extracts the paper.'));
    for (const f of figures) {
      const imageBox = el('div', { class: 'figure-placeholder' }, f.asset_url ? 'Loading figure…' : 'Image unavailable');
      const fig = el('figure', { class: 'figure' }, imageBox, el('figcaption', {}, el('strong', {}, f.label || 'Figure'), ' ', f.caption),
        el('footer', {}, badge(f.status), el('small', {}, f.page ? 'PDF page ' + f.page : 'PDF page unknown'), button('Save evidence', () => addEvidence(p, { figure: f })), button('Correct region', () => figureCorrection(f)),
          f.original_download_url && button('Download original', action(() => download(f.original_download_url, fileName(f.label || 'figure', ({ 'image/svg+xml': 'svg', 'image/jpeg': 'jpg', 'image/webp': 'webp' })[f.original_mime_type] || 'png'))))));
      content.append(fig);
      if (f.asset_url) resource(f.asset_url).then(url => {
        if (generation !== state.generation) return;
        const image = el('img', { src: url, alt: f.caption || f.label || 'Paper figure', loading: 'lazy' });
        imageBox.replaceWith(button(image, () => dialog(f.label || 'Figure', el('div', { class: 'image-dialog' }, el('img', { src: url, alt: f.caption || f.label })), { wide: true }), 'figure-image'));
      }).catch(e => imageBox.textContent = e.message);
    }
  } else if (tab === 'notes') {
    content.append(el('div', { class: 'section-title' }, el('h2', {}, 'Your notes'), button('Add note', () => noteDialog(p, pdf), 'primary', { disabled: !pdf.available })));
    const result = await api.call('/works/' + id + '/notes'); if (generation !== state.generation) return;
    if (!result.notes.length) content.append(empty('Keep your own observations', 'Notes are saved against a PDF version and page, and are shared with your Mac app.'));
    for (const note of result.notes) content.append(el('article', { class: 'record' }, el('small', {}, 'PDF page ' + note.page, note.pdf_current ? '' : ' · Earlier PDF version'),
      note.selected_text && el('blockquote', {}, note.selected_text), textBlock(note.body), el('footer', {}, button('Edit', () => noteDialog(p, pdf, note)), button('Delete', action(async () => {
        if (!confirm('Delete this note?')) return;
        await api.call('/works/' + id + '/notes/' + note.id, { method: 'DELETE', body: { revision: note.revision } }); await render();
      }), 'danger'))));
  }
}
function noteDialog(p, pdf, note, page = 1) {
  const fields = note ? [] : [
    { name: 'page', label: 'PDF page', type: 'number', value: page, min: 1, max: pdf.page_count || 500, required: true },
    { name: 'selected_text', label: 'Quoted text (optional)', type: 'textarea', hint: 'Copy the passage from the PDF. Notes are your own annotations; verified research evidence is saved from Source text or Figures.' },
  ];
  fields.push({ name: 'body', label: 'Note', type: 'textarea', value: note?.body, required: true, rows: 6, maxLength: 30000 });
  formDialog(note ? 'Edit note' : 'New note', fields, async values => {
    await api.call('/works/' + p.id + '/notes' + (note ? '/' + note.id : ''), { method: note ? 'PATCH' : 'POST', body: note ? { ...values, revision: note.revision } : { ...values, pdf_sha256: pdf.sha256, rects: [] } });
    notify('Note saved.'); await render();
  });
}
function paperMenu(p, pdf) {
  const list = el('div', { class: 'editor' }); const d = dialog('Paper actions', list);
  const after = fn => action(async () => { await fn(); d.close(); });
  list.append(button(p.collection === 'library' ? 'Move to candidates' : 'Add to library', after(async () => {
    await api.call('/works/' + p.id, { method: 'PATCH', body: { revision: p.revision, collection: p.collection === 'library' ? 'candidates' : 'library' } }); await render();
  })), button('Edit title', () => { d.close(); formDialog('Edit title', [{ name: 'title', label: 'Title', value: p.title, required: true, maxLength: 1000 }], async values => {
    await api.call('/works/' + p.id, { method: 'PATCH', body: { ...values, revision: p.revision } }); await render();
  }); }), button('Extract again', after(() => runOperation({ kind: 'extract', work_ids: [p.id] }))),
  button('Attach PDF', () => { d.close(); formDialog('Attach PDF', [{ name: 'file', label: 'PDF file', type: 'file', accept: '.pdf,application/pdf', required: true }], async values => {
    const form = new FormData(); form.append('file', values.file); await api.call('/imports/pdf?work_id=' + p.id, { method: 'POST', form }); notify('PDF uploaded. Extraction queued.'); await render();
  }, { submit: 'Upload PDF' }); }),
  pdf.available && button('Download PDF', after(() => download('/works/' + p.id + '/pdf', fileName(p.title, 'pdf')))),
  p.markdown && button('Export analysis', () => saveBlob(new Blob([p.markdown], { type: 'text/markdown;charset=utf-8' }), fileName(p.title, 'md'))),
  externalLink('Open publication source', p.source_url),
  el('hr'), el('h3', {}, 'Candidate feedback'), ...[['useful', 'Useful'], ['known', 'Already known'], ['later', 'Read later'], ['irrelevant', 'Not relevant']].map(([choice, label]) => button(label, after(async () => {
    await api.call('/works/' + p.id + '/feedback', { method: 'PUT', body: { choice } }); notify('Feedback saved.');
  }))), button('Remove paper', after(async () => {
    if (!confirm('Remove this paper from your library and candidates? Its stored materials are retained on the server.')) return;
    await api.call('/works/' + p.id, { method: 'DELETE' }); go('/library');
  }), 'danger'));
}
function figureCorrection(f) {
  const page = el('input', { type: 'number', min: 1, max: 500, value: f.page || 1, required: true });
  const preview = el('div', {}, muted('Load the PDF page to check the region before saving. Coordinates are measured in PDF points from the top-left.'));
  const bounds = {}; let info;
  const form = el('form', { class: 'editor' }, field('PDF page', page));
  const error = el('p', { class: 'form-error', hidden: true, role: 'alert' });
  const load = button('Load page', action(async () => {
    info = await api.call('/figures/' + f.id + '/page-preview?page=' + page.value);
    const url = await resource(info.asset_url);
    preview.replaceChildren(el('img', { src: url, alt: 'PDF page ' + info.page }), muted(`Page dimensions: ${info.width} × ${info.height} PDF points.`));
    for (const [key, value] of Object.entries({ x0: 0, y0: 0, x1: info.width, y1: info.height })) bounds[key].value = value;
  }));
  form.append(load, preview);
  const fields = el('div', { class: 'field-grid' });
  for (const key of ['x0', 'y0', 'x1', 'y1']) { bounds[key] = el('input', { type: 'number', step: 'any', min: 0, required: true }); fields.append(field(key, bounds[key])); }
  const submit = el('button', { type: 'submit', class: 'primary' }, 'Save correction'); const d = dialog('Correct figure region', form, { wide: true });
  form.append(fields, error, el('footer', {}, button('Cancel', d.close), submit));
  form.addEventListener('submit', async event => {
    event.preventDefault(); if (submit.disabled) return; submit.disabled = true;
    try {
      if (!info || info.page !== Number(page.value)) throw new Error('Load the selected page before saving.');
      const bbox = Object.fromEntries(Object.entries(bounds).map(([key, input]) => [key, Number(input.value)]));
      if (bbox.x1 <= bbox.x0 || bbox.y1 <= bbox.y0 || bbox.x1 > info.width || bbox.y1 > info.height) throw new Error('Choose a region inside the page, with the right and bottom edges after the left and top edges.');
      await runOperation({ kind: 'repair_figure', figure_id: f.id, figure_page: Number(page.value), bbox }); d.close();
    } catch (e) { error.textContent = e.message; error.hidden = false; }
    finally { submit.disabled = false; }
  });
}

async function tasks(main, generation) {
  header(main, 'Tasks', undefined, iconButton('refresh', 'Refresh tasks', render));
  const result = await api.call('/operations?limit=100'); if (generation !== state.generation) return;
  main.append(muted('Background work continues when you close this window. Showing the 100 most recent operations.'));
  if (!result.operations.length) main.append(empty('Nothing is running', 'Imports, extraction, discovery, and analysis will appear here when you start them.'));
  const list = el('div', { class: 'record-list' }); main.append(list);
  for (const op of result.operations) {
    const buttons = [];
    const control = verb => button(verb[0].toUpperCase() + verb.slice(1), action(async () => {
      if (verb === 'cancel' && !confirm('Cancel this operation? Requests already sent to a model provider may still be charged.')) return;
      await api.call('/operations/' + op.id + '/' + verb, { method: 'POST' }); await render();
    }));
    if (['queued', 'running'].includes(op.state)) buttons.push(control('pause'), control('cancel'));
    if (op.state === 'paused') buttons.push(control('resume'), control('cancel'));
    if (['failed', 'needs_input', 'completed_with_gaps'].includes(op.state)) buttons.push(control('retry'), control('cancel'));
    const stages = el('ul', { class: 'stage-list' }, (op.stages || []).map(s => el('li', {}, el('span', {}, (s.kind || '').replaceAll('_', ' ')), badge(s.execution_status === 'doing' ? 'running' : s.outcome), s.error && Object.keys(s.error).length > 0 && el('span', { class: 'stage-error' }, s.error.message || JSON.stringify(s.error)))));
    list.append(el('article', { class: 'record' }, el('div', { class: 'operation-head' }, el('h2', {}, op.kind.replaceAll('_', ' ')), badge(op.state)), muted(date(op.created_at)), stages,
      el('div', { class: 'token-line' }, `Tokens: ${op.budget_used || 0} used · ${op.budget_reserved || 0} reserved · ${op.budget_limit ?? '—'} limit`),
      el('footer', {}, ...buttons, button('Details', action(async () => {
        const detail = await api.call('/operations/' + op.id);
        const body = el('div', {}, el('pre', {}, JSON.stringify(detail, null, 2)));
        for (const call of detail.invocations || []) if (call.state === 'unknown') body.prepend(button('Reconcile unknown model call', () => {
          formDialog('Reconcile model call', [
            { name: 'outcome', label: 'Verified provider outcome', type: 'select', options: [['not_charged', 'Not charged'], ['charged_no_result', 'Charged without a usable result']] },
            { name: 'used_tokens', label: 'Confirmed tokens', type: 'number', value: 0, min: 0, required: true },
            { name: 'note', label: 'Verification notes', type: 'textarea', required: true },
          ], async values => { await api.call('/model-invocations/' + call.id + '/resolve', { method: 'POST', body: values }); notify('Call reconciled. Retry remains an explicit action.'); }, { help: 'Check the provider’s usage records before recording an outcome.' });
        }));
        dialog('Operation details', body, { wide: true });
      })))));
  }
}

async function settings(main, generation) {
  header(main, 'Settings', undefined, iconButton('refresh', 'Reload settings', render));
  const [model, discovery, devices, health] = await Promise.all([api.call('/settings/model'), api.call('/settings/discovery'), api.call('/devices'), api.call('/health')]);
  if (generation !== state.generation) return;
  function settingsForm(title, inputs, onSave, help) {
    const section = el('section', { class: 'settings-section' }, el('h2', {}, title), help && muted(help));
    const form = el('form', { class: 'editor' });
    const error = el('p', { class: 'form-error', hidden: true, role: 'alert' });
    const submit = el('button', { type: 'submit', class: 'primary' }, 'Save changes');
    for (const [label, input, hint] of inputs) form.append(field(label, input, hint));
    form.append(error, el('footer', {}, submit));
    form.addEventListener('submit', async e => {
      e.preventDefault(); if (submit.disabled) return; submit.disabled = true; error.hidden = true;
      try { await onSave(); notify(title + ' saved.'); }
      catch (err) { error.textContent = err.message; error.hidden = false; }
      finally { submit.disabled = false; }
    });
    section.append(form); main.append(section); return form;
  }
  const appearance = el('section', { class: 'settings-section' }, el('h2', {}, 'Appearance'), field('Theme', select([['system', 'Follow system'], ['light', 'Light'], ['dark', 'Dark']], document.documentElement.dataset.theme || 'system', e => {
    document.documentElement.dataset.theme = e.target.value;
    try { localStorage.setItem('papernas.theme', e.target.value); } catch { /* Optional preference only. */ }
  }, 'Theme'))); main.append(appearance);
  const base = el('input', { type: 'url', value: model.config.base_url || '', placeholder: 'https://provider.example/v1', required: true });
  const name = el('input', { value: model.config.model || '', required: true });
  const max = el('input', { type: 'number', min: 512, max: 12000, value: model.config.max_output_tokens || 4000, required: true });
  settingsForm('Model provider', [['Base URL', base], ['Model name', name], ['Maximum output tokens', max, 'Some reasoning models include reasoning tokens in this limit.']], async () => {
    await api.call('/settings/model', { method: 'PUT', body: { base_url: base.value, model: name.value, max_output_tokens: Number(max.value), revision: model.revision } });
    Object.assign(model, await api.call('/settings/model'));
  }, 'Paper excerpts are sent to this provider only when you start analysis or comparison.');
  const key = el('input', { type: 'password', autocomplete: 'off', required: true });
  settingsForm('Provider key', [['New API key', key, model.key_configured ? 'A key is already stored on the server. Leave this section alone to keep it.' : 'No provider key has been stored.']], async () => {
    await api.call('/settings/model/key', { method: 'PUT', body: { api_key: key.value } }); key.value = '';
  }, 'The key is saved privately on the server and is never returned to the browser.');
  const config = discovery.config;
  const query = el('input', { value: config.query || '', required: true });
  const arxiv = el('input', { value: config.source_queries?.arxiv || '' });
  const crossref = el('input', { value: config.source_queries?.crossref || '' });
  const source = select([['arxiv', 'arXiv'], ['crossref', 'Crossref'], ['both', 'Both sources']], config.sources?.length === 2 ? 'both' : config.sources?.[0] || 'arxiv');
  const limit = el('input', { type: 'number', min: 1, max: 100, value: config.limit || 15, required: true });
  const enabled = el('input', { type: 'checkbox', checked: config.enabled });
  const time = el('input', { type: 'time', value: config.time || '09:00', required: true });
  const timezone = el('input', { value: config.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone, required: true });
  settingsForm('Daily discovery', [['Default query', query], ['Sources', source], ['arXiv query override', arxiv], ['Crossref query override', crossref], ['Results per source', limit], ['Run daily', enabled], ['Time', time], ['Timezone', timezone]], async () => {
    await api.call('/settings/discovery', { method: 'PUT', body: { query: query.value, sources: source.value === 'both' ? ['arxiv', 'crossref'] : [source.value], source_queries: { arxiv: arxiv.value, crossref: crossref.value }, limit: Number(limit.value), enabled: enabled.checked, time: time.value, timezone: timezone.value, revision: discovery.revision } });
    Object.assign(discovery, await api.call('/settings/discovery'));
  }, 'Discovery adds candidates. It does not automatically analyze them. Results are bounded by the configured per-source limit.');
  const connections = el('section', { class: 'settings-section' }, el('h2', {}, 'Connected devices'));
  for (const device of devices.devices) connections.append(el('article', { class: 'record' }, el('h3', {}, device.name, device.id === api.deviceID ? ' (this browser)' : ''), muted('Expires ' + date(device.expires_at)), button('Revoke access', action(async () => {
    if (!confirm('Revoke access for ' + device.name + '?')) return;
    await api.call('/devices/' + device.id, { method: 'DELETE' });
    if (device.id === api.deviceID) { api.token = ''; api.deviceID = ''; rememberSession(); login(); }
    else await render();
  }), 'danger')));
  connections.append(button('Sign out of this tab', async () => {
    let warning = '';
    try { await api.call('/devices/' + api.deviceID, { method: 'DELETE' }); }
    catch { warning = 'This tab is signed out. The server could not confirm revocation; revoke this browser from another connected device when the server is reachable.'; }
    api.token = ''; api.deviceID = ''; api.pending.clear(); rememberSession(); login(warning);
  }, 'soft')); main.append(connections);
  main.append(el('section', { class: 'settings-section' }, el('h2', {}, 'About Paper NAS'), muted(`Server ${health.version} · API v${health.api_version} · ${health.active_workers} active workers`),
    el('p', {}, 'A self-hosted research workspace. Browser and Mac clients share the same papers, evidence, and task history.'),
    el('a', { href: './about.html', target: '_blank', rel: 'noopener' }, 'Source code and third-party licenses')));
}

window.addEventListener('hashchange', render);
document.querySelector('.skip-link').addEventListener('click', event => { event.preventDefault(); document.querySelector('#main')?.focus(); });
window.addEventListener('keydown', event => {
  if (event.key === 'Escape') root.querySelector('.shell')?.classList.remove('nav-open');
  if ((event.metaKey || event.ctrlKey) && event.key === 'k' && !document.querySelector('dialog[open]')) {
    event.preventDefault(); const search = document.querySelector('input[type=search]'); if (search) search.focus(); else go('/library');
  }
});
setInterval(() => {
  if (api.token && route().parts[0] === 'tasks' && !document.hidden && !document.querySelector('dialog[open]') && !document.activeElement?.matches('button,input,textarea,select')) render();
}, 15000);
render();
