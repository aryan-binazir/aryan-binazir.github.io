(function initFindingsPostPage(globalScope) {
  'use strict';

  function readMarkdownSource() {
    var sourceElement = document.getElementById('post-markdown-source');
    if (!sourceElement) {
      throw new Error('post markdown source element not found: post-markdown-source');
    }

    return sourceElement.value || '';
  }

  function renderPost() {
    globalScope.renderMarkdownInto({
      elementId: 'post-body',
      markdownSource: readMarkdownSource()
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', renderPost, { once: true });
    return;
  }

  renderPost();
})(window);
