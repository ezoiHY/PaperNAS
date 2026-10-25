import { safeExternalURL } from './api.js';

export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith('on')) node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === 'class') node.className = value;
    else if (key === 'dataset') Object.assign(node.dataset, value);
    else if (key in node && !key.startsWith('aria-') && key !== 'form') node[key] = value;
    else node.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child !== null && child !== undefined && child !== false) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

const paths = {
  book: 'M4 4h6c2 0 2 1 2 2v15c0-2-2-3-4-3H4z M20 4h-6c-2 0-2 1-2 2 M20 4v14h-4c-2 0-4 1-4 3',
  inbox: 'M4 5h16l2 13H2z M2 14h5l2 3h6l2-3h5',
  research: 'M8 3h8 M10 3v6l-6 10c-1 1 0 2 1 2h14c1 0 2-1 1-2L14 9V3 M8 14h8',
  tasks: 'M4 5h2 M10 5h10 M4 12h2 M10 12h10 M4 19h2 M10 19h10',
  search: 'M21 21l-5-5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
  plus: 'M12 5v14 M5 12h14',
  settings: 'M4 6h16 M4 12h16 M4 18h16 M8 4v4 M16 10v4 M10 16v4',
  arrow: 'M19 12H5 M11 6l-6 6 6 6',
  refresh: 'M20 7v5h-5 M4 17v-5h5 M6 7a7 7 0 0 1 13 1 M18 17A7 7 0 0 1 5 16',
  close: 'M6 6l12 12 M18 6L6 18',
  folder: 'M3 6h7l2 3h9v11H3z',
  menu: 'M4 6h16 M4 12h16 M4 18h16',
  download: 'M12 3v12 M7 10l5 5 5-5 M4 16v5h16v-5',
  check: 'M4 12l5 5L20 6',
  link: 'M10 13a5 5 0 0 0 7 0l4-4a5 5 0 0 0-7-7l-3 3 M14 11a5 5 0 0 0-7 0l-4 4a5 5 0 0 0 7 7l3-3',
  sun: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8 M12 2v2 M12 20v2 M2 12h2 M20 12h2 M5 5l1 1 M18 18l1 1 M5 19l1-1 M18 6l1-1',
};
export function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  for (const [key, value] of Object.entries({ viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.6', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' })) svg.setAttribute(key, value);
  const path = document.createElementNS(svg.namespaceURI, 'path');
  path.setAttribute('d', paths[name] || paths.book); svg.append(path);
  return svg;
}
export const button = (text, fn, kind = 'soft', attrs = {}) => el('button', { type: 'button', class: kind, onclick: fn, ...attrs }, text);
export const iconButton = (name, label, fn) => button(icon(name), fn, 'icon-button', { title: label, 'aria-label': label });
export const badge = text => el('span', { class: 'badge' }, String(text || '').replaceAll('_', ' '));
export const muted = text => el('p', { class: 'muted' }, text);
export const empty = (title, detail, action) => el('section', { class: 'empty' }, icon('book'), el('h2', {}, title), muted(detail), action);
export const date = value => value && Number.isFinite(new Date(value).getTime()) ? new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(new Date(value)) : '';
export const authors = value => (Array.isArray(value) ? value.map(a => typeof a === 'string' ? a : a.name || '').filter(Boolean) : []).join(', ');
export function externalLink(label, value) {
  const url = safeExternalURL(value);
  return url ? el('a', { href: url, target: '_blank', rel: 'noreferrer noopener' }, label) : null;
}
export function field(label, input, hint) {
  input.id ||= 'field-' + Math.random().toString(36).slice(2);
  return el('div', { class: 'field' }, el('label', { htmlFor: input.id }, label), input, hint && el('small', {}, hint));
}
export function select(options, value, onChange, label) {
  const input = el('select', { 'aria-label': label, onchange: onChange }, options.map(([v, text]) => el('option', { value: v }, text)));
  input.value = value; return input;
}
export function textBlock(value, className = '') {
  // Treat imported prose as text, including HTML. Never insert source/model HTML.
  return el('div', { class: 'prose ' + className }, String(value || '').split(/\n\s*\n/).filter(Boolean).map(p => el('p', {}, p)));
}
export function markdown(value) {
  const result = el('div', { class: 'prose' });
  let inCode = false, code = [];
  for (const line of String(value || '').split('\n')) {
    if (line.startsWith('```')) {
      if (inCode) { result.append(el('pre', {}, el('code', {}, code.join('\n')))); code = []; }
      inCode = !inCode; continue;
    }
    if (inCode) { code.push(line); continue; }
    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) result.append(el('h' + Math.min(heading[1].length + 1, 6), {}, heading[2]));
    else if (line.trim()) result.append(el('p', {}, line.replace(/^[-*]\s+/, '• ').replace(/^>\s?/, '')));
  }
  if (code.length) result.append(el('pre', {}, code.join('\n')));
  return result;
}

export function notify(message, error = false) {
  const root = document.querySelector('#notifications');
  const toast = el('div', { class: 'toast' + (error ? ' error' : ''), role: error ? 'alert' : 'status' }, message, iconButton('close', 'Dismiss', () => toast.remove()));
  root.append(toast);
  if (!error) setTimeout(() => toast.remove(), 5000);
}

export function dialog(title, content, { wide = false, onClose } = {}) {
  const prior = document.activeElement;
  const body = el('div', { class: 'dialog-body' }, content);
  const node = el('dialog', { class: wide ? 'wide' : '', 'aria-label': title },
    el('header', {}, el('h2', {}, title), iconButton('close', 'Close', () => node.close())), body);
  document.body.append(node);
  node.addEventListener('close', () => { node.remove(); onClose?.(); prior?.focus?.(); });
  node.showModal();
  return { node, body, close: () => node.close() };
}

export function formDialog(title, fields, onSubmit, { submit = 'Save', help } = {}) {
  const inputs = {};
  const form = el('form', { class: 'editor' });
  if (help) form.append(muted(help));
  for (const spec of fields) {
    let input;
    if (spec.type === 'select') input = select(spec.options, spec.value ?? spec.options[0][0]);
    else if (spec.type === 'multi') {
      input = el('select', { multiple: true, size: Math.min(6, Math.max(3, spec.options.length)) }, spec.options.map(([value, label]) => el('option', { value, selected: (spec.value || []).includes(value) }, label)));
    }
    else if (spec.type === 'textarea') input = el('textarea', { rows: spec.rows || 4, value: spec.value || '' });
    else input = el('input', { type: spec.type || 'text', value: spec.value ?? '', min: spec.min, max: spec.max, step: spec.step, accept: spec.accept, autocomplete: spec.type === 'password' ? 'off' : undefined });
    if (spec.type === 'checkbox') input.checked = Boolean(spec.value);
    input.required = Boolean(spec.required);
    if (spec.maxLength) input.maxLength = spec.maxLength;
    input.name = spec.name; inputs[spec.name] = input;
    form.append(field(spec.label, input, spec.hint));
  }
  const error = el('p', { class: 'form-error', role: 'alert', hidden: true });
  const save = el('button', { type: 'submit', class: 'primary' }, submit);
  const d = dialog(title, form);
  form.append(error, el('footer', {}, button('Cancel', d.close), save));
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (save.disabled) return;
    const values = Object.fromEntries(Object.entries(inputs).map(([key, input]) => [key,
      input.multiple ? [...input.selectedOptions].map(o => o.value) : input.type === 'checkbox' ? input.checked : input.type === 'file' ? input.files[0] : input.type === 'number' ? Number(input.value) : input.value]));
    save.disabled = true; save.textContent = 'Saving…'; error.hidden = true;
    try { await onSubmit(values); d.close(); }
    catch (e) { error.textContent = e.message; error.hidden = false; error.scrollIntoView({ block: 'nearest' }); }
    finally { save.disabled = false; save.textContent = submit; }
  });
  return { ...d, form, inputs };
}
