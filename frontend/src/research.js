import { fileName } from './api.js';
import { el, button, iconButton, badge, muted, empty, date, textBlock, markdown, notify, dialog, formDialog, externalLink } from './ui.js';

const path = id => '/research/questions/' + id;
const text = (name, label, value = '', required = false) => ({ name, label, value, type: 'textarea', required });
const choice = (name, label, values, value) => ({ name, label, type: 'select', options: values.map(v => Array.isArray(v) ? v : [v, v.replaceAll('_', ' ')]), value });
const titleField = value => ({ name: 'title', label: 'Title', value, required: true, maxLength: 300 });
const evidenceField = (q, selected = []) => ({ name: 'evidence_ids', label: 'Supporting evidence', type: 'multi', options: q.evidence.map((e, i) => [e.id, `${i + 1}. ${e.work_title}: ${(e.quote || e.note || e.figure_label || '').slice(0, 90)}`]), value: selected, hint: 'Use Command/Ctrl to select multiple entries. Leave empty when the record has no saved evidence yet.' });

function questionEditor(q, ctx) {
  formDialog(q ? 'Edit research question' : 'New research question', [
    titleField(q?.title), text('context', 'What are you trying to understand?', q?.context), text('constraints', 'Constraints and evaluation criteria', q?.constraints),
    choice('status', 'Status', ['active', 'paused', 'completed'], q?.status || 'active'),
  ], async values => {
    const saved = await ctx.api.call(q ? path(q.id) : '/research/questions', { method: q ? 'PATCH' : 'POST', body: { ...values, ...(q ? { revision: q.revision } : {}) } });
    notify('Research question saved.');
    if (q) await ctx.refresh(); else ctx.go('/research/' + saved.id);
  });
}

export async function renderQuestions(main, ctx) {
  ctx.header(main, 'Research', undefined, iconButton('refresh', 'Refresh research', ctx.refresh), button('New question', () => questionEditor(null, ctx), 'primary'));
  const data = await ctx.api.call('/research/questions'); if (!ctx.isCurrent()) return;
  if (!data.questions.length) { main.append(empty('Start with a question', 'Connect papers to the question you are exploring. Keep the evidence, decisions, and results together.', button('Create a question', () => questionEditor(null, ctx), 'primary'))); return; }
  const list = el('div', { class: 'record-list' });
  for (const q of data.questions) list.append(el('article', { class: 'record' }, button(q.title, () => ctx.go('/research/' + q.id), 'paper-title'),
    q.context && muted(q.context.slice(0, 250)), el('footer', {}, badge(q.status), el('small', {}, `${q.work_count} papers`), el('small', {}, `${q.evidence_count} evidence records`), el('small', {}, 'Updated ' + date(q.updated_at)))));
  main.append(list);
}

async function linkPaper(q, ctx) {
  const form = el('form', { class: 'editor' });
  const search = el('input', { type: 'search', placeholder: 'Find a paper in your library', 'aria-label': 'Find a paper' });
  const results = el('div', { class: 'record-list' });
  const d = dialog('Link a paper', form, { wide: true });
  form.append(el('div', { class: 'actions' }, search, el('button', { type: 'submit', class: 'primary' }, 'Search')), results);
  let generation = 0;
  const load = async () => {
    const version = ++generation;
    results.replaceChildren(muted('Searching…'));
    try {
      const data = await ctx.api.call('/works?limit=100&q=' + encodeURIComponent(search.value));
      if (version !== generation) return;
      results.replaceChildren(...data.works.map(p => el('article', { class: 'record' }, el('h3', {}, p.title), button(q.works.some(w => w.id === p.id) ? 'Already linked' : 'Link paper', ctx.action(async () => {
        await ctx.api.call(path(q.id) + '/works', { method: 'POST', body: { work_id: p.id } }); d.close(); await ctx.refresh();
      }), 'soft', { disabled: q.works.some(w => w.id === p.id) }))));
      if (!data.works.length) results.append(muted('No matching papers. Import a paper from the library first.'));
      if (data.total > 100) results.append(muted('Showing the first 100 matches. Refine the search to find a specific paper.'));
    } catch (error) { results.replaceChildren(el('p', { class: 'form-error', role: 'alert' }, error.message)); }
  };
  form.addEventListener('submit', e => { e.preventDefault(); load(); }); await load();
}

function judgmentEditor(q, item, ctx) {
  formDialog(item ? 'Revise judgment' : 'Record a judgment', [
    text('statement', 'Judgment', item?.statement, true), text('rationale', 'Reasoning and counterevidence', item?.rationale),
    evidenceField(q, item?.evidence_ids), text('next_step', 'Next step', item?.next_step),
    choice('status', 'Status', ['tentative', 'accepted', 'revised'], item?.status || 'tentative'),
  ], async values => {
    await ctx.api.call(path(q.id) + '/judgments' + (item ? '/' + item.id : ''), { method: item ? 'PATCH' : 'POST', body: { ...values, ...(item ? { revision: item.revision } : {}) } });
    await ctx.refresh();
  }, { help: 'Record your interpretation separately from what a paper directly demonstrates. Revisions preserve earlier judgments.' });
}
function actionEditor(q, item, ctx) {
  formDialog(item ? 'Edit verification plan' : 'Plan a verification', [
    titleField(item?.title), choice('judgment_id', 'Related judgment', [['', 'None'], ...q.judgments.map(j => [j.id, j.statement.slice(0, 100)])], item?.judgment_id || ''),
    ...[['hypothesis', 'Hypothesis'], ['method', 'Method'], ['baseline', 'Baseline'], ['metrics', 'Measures'], ['success_criterion', 'Success criterion'], ['stop_condition', 'Stopping condition'], ['resource_budget', 'Time and resource budget']].map(([key, label]) => text(key, label, item?.[key])),
    choice('status', 'Status', ['planned', 'running', 'completed', 'abandoned'], item?.status || 'planned'),
  ], async values => {
    values.judgment_id ||= null;
    await ctx.api.call(path(q.id) + '/actions' + (item ? '/' + item.id : ''), { method: item ? 'PATCH' : 'POST', body: { ...values, ...(item ? { revision: item.revision } : {}) } });
    await ctx.refresh();
  }, { help: 'This records a plan. Paper NAS does not execute experiments.' });
}
function resultEditor(q, ctx, actionID = '') {
  formDialog('Record a result', [titleField(),
    choice('action_id', 'Related verification plan', [['', 'None'], ...q.actions.map(a => [a.id, a.title])], actionID),
    choice('judgment_id', 'Related judgment', [['', 'None'], ...q.judgments.map(j => [j.id, j.statement.slice(0, 100)])], ''),
    choice('outcome', 'Outcome', ['observation', 'supports', 'contradicts', 'inconclusive'], 'observation'),
    text('body', 'What happened?', '', true), text('metrics_text', 'Measurements (optional)', '', false),
    { name: 'artifact_url', label: 'Result or artifact link (optional)', type: 'url' },
  ], async values => {
    values.action_id ||= null; values.judgment_id ||= null;
    values.metrics = values.metrics_text ? { notes: values.metrics_text } : {}; delete values.metrics_text;
    await ctx.api.call(path(q.id) + '/results', { method: 'POST', body: values }); await ctx.refresh();
  });
}
function snapshotEditor(q, ctx) {
  formDialog('Save an understanding', [titleField(), text('understanding', 'Current understanding', '', true), evidenceField(q), text('open_questions', 'Open questions'), text('next_focus', 'Next focus')], async values => {
    await ctx.api.call(path(q.id) + '/snapshots', { method: 'POST', body: values }); await ctx.refresh();
  }, { help: 'Preserve what you currently understand, what is unresolved, and where to focus next.' });
}
function compare(q, ctx) {
  formDialog('Compare linked papers', [
    text('dimensions', 'Comparison dimensions', 'method, evidence, conditions, limitations', true),
    { name: 'token_budget', label: 'Token budget', type: 'number', value: 120000, min: 1000, max: 2000000, required: true },
  ], async values => { await ctx.runOperation({ kind: 'compare', question_id: q.id, ...values }); },
  { submit: 'Start comparison', help: 'At least two linked papers must have extracted text. This sends excerpts to your configured model provider and may incur charges.' });
}
async function showEvidence(e, ctx) {
  const body = el('div', {}, el('h3', {}, e.work_title), muted(e.page ? 'PDF page ' + e.page : 'PDF page unknown'), e.quote && el('blockquote', {}, e.quote), textBlock(e.note));
  if (e.block_id) {
    const block = await ctx.api.call('/blocks/' + e.block_id);
    body.append(textBlock(block.text));
  }
  if (e.pdf_sha256) body.append(button('Download source PDF', ctx.action(() => ctx.download('/assets/' + e.pdf_sha256, fileName(e.work_title, 'pdf')))));
  dialog('Saved evidence', body, { wide: true });
}

export async function evidenceDialog(paper, { block, figure }, ctx) {
  const result = await ctx.api.call('/research/questions');
  if (!result.questions.length) { dialog('Create a research question first', el('div', {}, muted('A question gives this evidence a purpose. Create one in Research, then return here to save the source.'), button('Open Research', () => { document.querySelector('dialog')?.close(); ctx.go('/research'); }, 'primary'))); return; }
  formDialog('Save source evidence', [
    choice('question_id', 'Research question', result.questions.map(q => [q.id, q.title]), result.questions[0].id),
    ...(block ? [text('quote', 'Exact source passage', block.text.slice(0, 20000), true)] : []),
    choice('relation', 'Role in this question', [['supports', 'Supports'], ['contradicts', 'Contradicts'], ['context', 'Background context']], 'context'),
    text('note', 'Why is it relevant?'),
  ], async ({ question_id, ...values }) => {
    await ctx.api.call(path(question_id) + '/works', { method: 'POST', body: { work_id: paper.id } });
    await ctx.api.call(path(question_id) + '/evidence', { method: 'POST', body: { ...values, work_id: paper.id, ...(block ? { block_id: block.id } : { figure_id: figure.id }) } });
    notify('Evidence saved to your research question.');
  }, { help: block ? 'The server verifies that the quote occurs in this source passage. Keep the original wording.' : 'The figure’s current source version and region will remain attached to this evidence.' });
}

export async function renderQuestion(main, identifier, ctx) {
  const q = await ctx.api.call(path(identifier)); if (!ctx.isCurrent()) return; ctx.state.currentQuestion = q;
  ctx.header(main, 'Research question', undefined, button('All questions', () => ctx.go('/research')), button('Edit', () => questionEditor(q, ctx)), iconButton('refresh', 'Refresh question', ctx.refresh),
    button('Export', () => dialog('Export research', el('div', { class: 'editor' },
      button('Download Markdown', ctx.action(() => ctx.download(path(q.id) + '/export?format=markdown', fileName(q.title, 'md')))),
      button('Download JSON', ctx.action(() => ctx.download(path(q.id) + '/export?format=json', fileName(q.title, 'json'))))))));
  main.append(el('section', { class: 'research-heading' }, el('h1', {}, q.title), badge(q.status), q.context && textBlock(q.context), q.constraints && el('details', {}, el('summary', {}, 'Constraints and evaluation criteria'), textBlock(q.constraints))));
  const tab = new URLSearchParams(location.hash.split('?')[1] || '').get('tab') || 'works';
  const tabs = [['works', 'Papers'], ['evidence', 'Evidence'], ['judgments', 'Judgments'], ['actions', 'Plans'], ['results', 'Results'], ['snapshots', 'Understanding'], ['comparisons', 'Comparisons']];
  main.append(el('nav', { class: 'tabs', 'aria-label': 'Research records' }, tabs.map(([key, title]) => button(`${title} ${q[key]?.length || 0}`, () => ctx.go('/research/' + q.id + '?tab=' + key), '', { 'aria-pressed': tab === key }))));
  const list = el('div', { class: 'record-list' }); main.append(list);
  const section = (title, label, fn) => list.append(el('div', { class: 'section-title' }, el('h2', {}, title), button(label, fn, 'primary')));
  const records = q[tab] || [];
  if (tab === 'works') {
    section('Linked papers', 'Link paper', ctx.action(() => linkPaper(q, ctx)));
    if (!records.length) list.append(empty('Build a reading list for this question', 'Link relevant papers, then save exact passages and figures as evidence.'));
    for (const p of records) list.append(el('article', { class: 'record' }, button(p.title, () => ctx.go('/papers/' + p.id), 'paper-title'), p.reason && muted(p.reason),
      el('footer', {}, badge(p.current_document_id ? 'Text available' : 'Needs extraction'), button('Read source', () => ctx.go('/papers/' + p.id + '?tab=source')), button('Unlink', ctx.action(async () => {
        if (!confirm('Unlink this paper from the question? Saved evidence is retained.')) return;
        await ctx.api.call(path(q.id) + '/works/' + p.id, { method: 'DELETE' }); await ctx.refresh();
      }), 'soft'))));
  } else if (tab === 'evidence') {
    list.append(el('div', { class: 'section-title' }, el('h2', {}, 'Saved evidence')),
      muted('Save passages from a paper’s Source text view, or figures from its Figures view. Each record keeps its original source version.'));
    if (!records.length) list.append(empty('Keep the source close', 'Open a linked paper and save the passages or figures that matter to this question.'));
    for (const [i, e] of records.entries()) list.append(el('article', { class: 'record' }, el('h3', {}, `${i + 1}. ${e.work_title}`), badge(e.relation), e.quote && el('blockquote', {}, e.quote), e.note && textBlock(e.note),
      el('footer', {}, el('small', {}, e.page ? 'PDF page ' + e.page : 'PDF page unknown'), e.source_is_older && badge('Earlier source version'), button('View source', ctx.action(() => showEvidence(e, ctx))))));
  } else if (tab === 'judgments') {
    section('Judgments', 'Record judgment', () => judgmentEditor(q, null, ctx));
    for (const j of records) list.append(el('article', { class: 'record' }, el('h3', {}, j.statement), badge(j.status), textBlock(j.rationale), j.next_step && el('p', {}, 'Next step: ' + j.next_step),
      el('div', { class: 'actions' }, (j.evidence_ids || []).map(id => { const e = q.evidence.find(v => v.id === id); return e && button('Evidence ' + (q.evidence.indexOf(e) + 1), ctx.action(() => showEvidence(e, ctx)), 'citation'); })),
      el('footer', {}, button('Revise', () => judgmentEditor(q, j, ctx)), button('History', ctx.action(async () => {
        const history = await ctx.api.call(path(q.id) + '/judgments/' + j.id + '/history');
        dialog('Judgment history', el('div', {}, history.history.map(row => el('article', { class: 'record' }, el('h3', {}, 'Revision ' + row.revision), textBlock(row.snapshot?.statement), textBlock(row.snapshot?.rationale), muted(date(row.created_at))))), { wide: true });
      })))));
  } else if (tab === 'actions') {
    section('Verification plans', 'Create plan', () => actionEditor(q, null, ctx));
    list.append(muted('Plans and results are recorded here. Experiments are performed outside Paper NAS.'));
    for (const a of records) list.append(el('article', { class: 'record' }, el('h3', {}, a.title), badge(a.status),
      ...[['hypothesis', 'Hypothesis'], ['method', 'Method'], ['baseline', 'Baseline'], ['metrics', 'Measures'], ['success_criterion', 'Success criterion'], ['stop_condition', 'Stopping condition'], ['resource_budget', 'Resource budget']].filter(([key]) => a[key]).map(([key, title]) => el('section', {}, el('h4', {}, title), textBlock(a[key]))),
      el('footer', {}, button('Edit plan', () => actionEditor(q, a, ctx)), button('Record result', () => resultEditor(q, ctx, a.id)))));
  } else if (tab === 'results') {
    section('Results and observations', 'Record result', () => resultEditor(q, ctx));
    for (const r of records) list.append(el('article', { class: 'record' }, el('h3', {}, r.title), badge(r.outcome), textBlock(r.body), Object.keys(r.metrics || {}).length > 0 && el('pre', {}, JSON.stringify(r.metrics, null, 2)), externalLink('Open result artifact', r.artifact_url), muted(date(r.created_at))));
  } else if (tab === 'snapshots') {
    section('Current understanding', 'Save understanding', () => snapshotEditor(q, ctx));
    for (const s of records) list.append(el('article', { class: 'record' }, el('h3', {}, s.title), textBlock(s.understanding), s.open_questions && el('section', {}, el('h4', {}, 'Open questions'), textBlock(s.open_questions)), s.next_focus && el('section', {}, el('h4', {}, 'Next focus'), textBlock(s.next_focus)), muted(date(s.created_at))));
  } else if (tab === 'comparisons') {
    section('Cross-paper comparisons', 'Compare papers', () => compare(q, ctx));
    list.append(muted('Comparisons require at least two linked papers with extracted text. Check the original sources before relying on the conclusions.'));
    for (const c of records) list.append(el('article', { class: 'record' }, el('h3', {}, c.data.title || 'Comparison'), muted(date(c.created_at)),
      c.data.markdown ? markdown(c.data.markdown) : textBlock(c.data.summary?.text),
      ...(c.data.findings || []).map(f => el('section', { class: 'claim' }, textBlock(f.text), (f.citations || []).map(source => button('View cited passage', ctx.action(async () => {
        const b = await ctx.api.call('/blocks/' + source.block_id);
        dialog('Cited passage', el('div', {}, el('h3', {}, b.work_title), muted(b.page ? 'PDF page ' + b.page : 'PDF page unknown'), el('blockquote', {}, source.quote), textBlock(b.text)), { wide: true });
      }), 'citation'))))));
  }
  if (records.length === 0 && !['works', 'evidence'].includes(tab)) list.append(empty('No records yet', 'Add a record when you have something to preserve. It will remain part of this question’s research history.'));
}
