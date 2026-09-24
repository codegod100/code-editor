(function () {
  const grammarByLanguage = {
    bash: 'tree-sitter-bash.wasm',
    css: 'tree-sitter-css.wasm',
    dart: 'tree-sitter-dart.wasm',
    html: 'tree-sitter-html.wasm',
    javascript: 'tree-sitter-javascript.wasm',
    json: 'tree-sitter-json.wasm',
    python: 'tree-sitter-python.wasm',
    typescript: 'tree-sitter-typescript.wasm',
    tsx: 'tree-sitter-tsx.wasm',
  };
  const assetRoot = './assets/tree-sitter/';
  const languages = new Map();
  let ready;

  function utf16OffsetAtUtf8Index(source, byteIndex) {
    let bytes = 0;
    let offset = 0;
    while (offset < source.length && bytes < byteIndex) {
      const codePoint = source.codePointAt(offset);
      bytes += codePoint <= 0x7f ? 1 : codePoint <= 0x7ff ? 2 : codePoint <= 0xffff ? 3 : 4;
      offset += codePoint > 0xffff ? 2 : 1;
    }
    return offset;
  }

  function initialize() {
    if (!ready) {
      ready = window.TreeSitter.Parser.init({
        locateFile: () => assetRoot + 'tree-sitter.wasm',
      });
    }
    return ready;
  }

  async function languageFor(language) {
    const wasm = grammarByLanguage[language];
    if (!wasm) return null;
    if (!languages.has(language)) {
      languages.set(language, window.TreeSitter.Language.load(assetRoot + wasm));
    }
    return languages.get(language);
  }

  function kindFor(node, source) {
    const type = node.type;
    if (type.includes('comment')) return 'comment';
    if (type.includes('string') || type.includes('heredoc')) return 'string';
    if (type.includes('escape')) return 'escape';
    if (/^(integer|float|number|decimal|hex|binary|octal)$/.test(type)) return 'number';
    if (/^(true|false|null|none)$/.test(type)) return 'constant';
    if (/^(identifier|property_identifier|type_identifier)$/.test(type)) {
      const parent = node.parent && node.parent.type;
      if (parent && /(class|function|method|declaration|definition)/.test(parent)) return 'definition';
      return 'identifier';
    }
    if (node.childCount === 0) {
      const token = source.slice(node.startIndex, node.endIndex);
      if (/^(abstract|as|assert|async|await|base|break|case|catch|class|const|continue|covariant|default|deferred|do|dynamic|else|enum|export|extends|extension|external|factory|false|final|finally|for|function|get|hide|if|implements|import|in|interface|is|late|library|mixin|new|null|of|on|operator|part|required|rethrow|return|sealed|set|show|static|super|switch|sync|this|throw|true|try|typedef|var|void|when|while|with|yield)$/.test(token)) return 'keyword';
      if (/^(true|false|null|None|True|False)$/.test(token)) return 'constant';
    }
    return null;
  }

  function highlight(source, language) {
    return initialize().then(async () => {
      const grammar = await languageFor(language);
      if (!grammar || !source) return [];
      const parser = new window.TreeSitter.Parser();
      parser.setLanguage(grammar);
      const tree = parser.parse(source);
      const ranges = [];
      const visit = (node) => {
        const kind = kindFor(node, source);
        if (kind && node.endIndex > node.startIndex) {
          ranges.push({
            start: utf16OffsetAtUtf8Index(source, node.startIndex),
            end: utf16OffsetAtUtf8Index(source, node.endIndex),
            kind,
          });
        }
        for (let index = 0; index < node.childCount; index += 1) visit(node.child(index));
      };
      visit(tree.rootNode);
      tree.delete();
      parser.delete();
      return ranges.sort((left, right) => left.start - right.start || right.end - left.end);
    });
  }

  window.TreeSitterHighlighter = { highlight };
})();
