(function attachMarkdownRenderer(globalScope) {
  'use strict';

  function isSafeUrl(urlValue) {
    if (!urlValue) {
      return false;
    }

    if (
      urlValue.startsWith('#') ||
      urlValue.startsWith('/') ||
      urlValue.startsWith('./') ||
      urlValue.startsWith('../')
    ) {
      return true;
    }

    try {
      var parsed = new URL(urlValue, window.location.href);
      return ['http:', 'https:', 'mailto:', 'tel:'].includes(parsed.protocol);
    } catch (err) {
      return false;
    }
  }

  function sanitizeHtml(inputHtml) {
    var template = document.createElement('template');
    template.innerHTML = inputHtml;

    template.content
      .querySelectorAll('script, iframe, object, embed, meta, link, base, form, style, svg, math, use')
      .forEach(function removeDisallowed(node) {
        node.remove();
      });

    template.content.querySelectorAll('*').forEach(function sanitizeElement(element) {
      Array.from(element.attributes).forEach(function sanitizeAttribute(attribute) {
        var name = attribute.name.toLowerCase();
        var value = attribute.value.trim();

        if (name.startsWith('on') || name === 'style' || name === 'srcdoc' || name === 'srcset') {
          element.removeAttribute(attribute.name);
          return;
        }

        if (name.startsWith('xmlns')) {
          element.removeAttribute(attribute.name);
          return;
        }

        if (name === 'href' || name === 'src' || name === 'xlink:href') {
          if (!isSafeUrl(value)) {
            element.removeAttribute(attribute.name);
          }
        }
      });
    });

    return template.innerHTML;
  }

  function renderMarkdownInto(options) {
    var elementId = options && options.elementId;
    var markdownSource = options && options.markdownSource;

    if (!globalScope.marked || typeof globalScope.marked.parse !== 'function') {
      throw new Error('marked.parse is unavailable; load marked.min.js before markdown-renderer.js');
    }

    if (!elementId || typeof elementId !== 'string') {
      throw new Error('renderMarkdownInto requires a non-empty elementId');
    }

    var target = document.getElementById(elementId);
    if (!target) {
      throw new Error('renderMarkdownInto target element not found: ' + elementId);
    }

    var renderedHtml = globalScope.marked.parse(String(markdownSource || ''));
    target.innerHTML = sanitizeHtml(renderedHtml);
  }

  globalScope.renderMarkdownInto = renderMarkdownInto;
})(window);
