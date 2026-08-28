/**
 * Structured HTML to plain-text summary converter.
 *
 * Unlike regex-based tag stripping, this walks the HTML string token by
 * token: it skips comments/doctype/script/style regions, parses tag names
 * with quote-aware scanning, and decodes named/numeric entities before
 * whitespace collapsing.
 */

const BLOCK_TAGS = new Set([
  'address',
  'article',
  'aside',
  'blockquote',
  'br',
  'dd',
  'div',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'li',
  'main',
  'nav',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'ul',
]);

const RAW_TEXT_TAGS = new Set(['script', 'style', 'noscript', 'template']);

const NAMED_ENTITIES: Record<string, string> = {
  amp: '&',
  apos: "'",
  bull: '•',
  copy: '©',
  divide: '÷',
  gt: '>',
  hellip: '…',
  laquo: '«',
  ldquo: '“',
  lsquo: '‘',
  lt: '<',
  mdash: '—',
  middot: '·',
  nbsp: ' ',
  ndash: '–',
  quot: '"',
  raquo: '»',
  rdquo: '”',
  reg: '®',
  rsquo: '’',
  times: '×',
  trade: '™',
};

export interface HtmlToTextOptions {
  /** Truncate the result after this many characters. */
  maxLength?: number;
  /** Collapse all whitespace into single spaces (defaults to true). */
  collapseWhitespace?: boolean;
}

function isAlphaNumeric(ch: string): boolean {
  const code = ch.charCodeAt(0);
  return (
    (code >= 48 && code <= 57) ||
    (code >= 65 && code <= 90) ||
    (code >= 97 && code <= 122)
  );
}

function isSpace(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r';
}

function findTagEnd(html: string, start: number): number {
  let quote = '';
  for (let i = start; i < html.length; i += 1) {
    const ch = html[i];
    if (quote) {
      if (ch === quote) quote = '';
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (ch === '>') {
      return i;
    }
  }
  return -1;
}

function parseTagName(raw: string): { name: string; closing: boolean } {
  let i = 0;
  while (i < raw.length && isSpace(raw[i])) i += 1;
  const closing = raw[i] === '/';
  if (closing) i += 1;
  while (i < raw.length && isSpace(raw[i])) i += 1;
  const start = i;
  while (i < raw.length && isAlphaNumeric(raw[i])) i += 1;
  return { name: raw.slice(start, i).toLowerCase(), closing };
}

function codePointToString(code: number): string {
  if (code <= 0 || code > 0x10ffff) return '';
  try {
    return String.fromCodePoint(code);
  } catch {
    return '';
  }
}

function decodeEntity(entity: string): string {
  const body = entity.slice(1, -1);
  if (body.startsWith('#x') || body.startsWith('#X')) {
    return codePointToString(parseInt(body.slice(2), 16));
  }
  if (body.startsWith('#')) {
    return codePointToString(parseInt(body.slice(1), 10));
  }
  return NAMED_ENTITIES[body] ?? entity;
}

/**
 * Convert HTML to a plain-text summary.
 *
 * Script/style/comment/doctype regions are skipped entirely. Tags are only
 * used to insert separators between block elements; the text itself is
 * decoded and then whitespace-collapsed for use in single-line summaries.
 */
export function htmlToText(
  html: string,
  options: HtmlToTextOptions = {},
): string {
  const source = String(html ?? '');
  const collapseWhitespace = options.collapseWhitespace ?? true;
  const separator = collapseWhitespace ? ' ' : '\n';
  let text = '';
  let i = 0;

  while (i < source.length) {
    const lt = source.indexOf('<', i);
    const amp = source.indexOf('&', i);
    const nextToken =
      lt === -1 ? (amp === -1 ? source.length : amp) : amp === -1 ? lt : Math.min(lt, amp);

    if (nextToken > i) {
      text += source.slice(i, nextToken);
      i = nextToken;
      continue;
    }

    if (source[i] === '&') {
      const semi = source.indexOf(';', i + 1);
      if (semi !== -1 && semi - i <= 12) {
        text += decodeEntity(source.slice(i, semi + 1));
        i = semi + 1;
      } else {
        text += '&';
        i += 1;
      }
      continue;
    }

    if (source.startsWith('<!--', i)) {
      const end = source.indexOf('-->', i + 4);
      i = end === -1 ? source.length : end + 3;
      continue;
    }

    if (source[i + 1] === '!' || source[i + 1] === '?') {
      const end = source.indexOf('>', i);
      i = end === -1 ? source.length : end + 1;
      continue;
    }

    const tagEnd = findTagEnd(source, i + 1);
    if (tagEnd === -1) {
      text += '<';
      i += 1;
      continue;
    }

    const rawTag = source.slice(i + 1, tagEnd);
    const { name, closing } = parseTagName(rawTag);
    const selfClosing = rawTag.trimEnd().endsWith('/');

    if (RAW_TEXT_TAGS.has(name) && !closing) {
      const closePattern = `</${name}`;
      const closeAt = source.toLowerCase().indexOf(closePattern, tagEnd + 1);
      if (closeAt === -1) break;
      const closeEnd = findTagEnd(source, closeAt + closePattern.length);
      i = closeEnd === -1 ? source.length : closeEnd + 1;
      continue;
    }

    if (name === 'br' || BLOCK_TAGS.has(name) || selfClosing) {
      text += separator;
    }
    i = tagEnd + 1;
  }

  const collapsed = collapseWhitespace ? text.replace(/\s+/g, ' ') : text;
  let result = collapsed.trim();
  if (options.maxLength && options.maxLength > 0) {
    // 按 Unicode 码点截断（Array.from 计数），避免把代理对（emoji/生僻字）劈开
    const chars = Array.from(result);
    if (chars.length > options.maxLength) {
      result = `${chars.slice(0, options.maxLength).join('').trimEnd()}…`;
    }
  }
  return result;
}
