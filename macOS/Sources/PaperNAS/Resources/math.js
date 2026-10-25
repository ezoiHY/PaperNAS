(() => {
  const walker = document.createTreeWalker(document.querySelector('article'), NodeFilter.SHOW_TEXT);
  const nodes = []; let node;
  while ((node = walker.nextNode())) if (!node.parentElement.closest('code,pre,script')) nodes.push(node);
  const pattern = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$([^$\n]+?)\$/g;
  for (const node of nodes) {
    const text = node.nodeValue; let last = 0; let match; const fragment = document.createDocumentFragment();
    while ((match = pattern.exec(text))) {
      fragment.append(document.createTextNode(text.slice(last, match.index)));
      const span = document.createElement('span');
      try { katex.render(match[1] || match[2] || match[3] || match[4], span, {displayMode:!!(match[1] || match[2]), throwOnError:false, trust:false, strict:'ignore', maxExpand:1000}); }
      catch { span.textContent = match[0]; }
      fragment.append(span); last = pattern.lastIndex;
    }
    if (last) { fragment.append(document.createTextNode(text.slice(last))); node.replaceWith(fragment); }
  }
})();
