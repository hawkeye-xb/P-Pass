// I18N-03 (#492) gate helpers: strip comments from desktop sources so the
// "no hardcoded CJK" gate only looks at code/markup that can reach the user.
//
// Hand-rolled on purpose (no parser dependency): a small state machine that
// knows JS strings / template literals / regex literals well enough that a
// `//` inside "https://…" is not mistaken for a comment, plus Svelte's three
// regions (<script>, <style>, markup with `{…}` expressions and <!-- -->).
// Comments are replaced by spaces (newlines kept) so line numbers survive.

const blank = (s) => s.replace(/[^\n]/g, " ");

/** Chars after which a `/` starts a regex literal rather than a division. */
const REGEX_PRECEDERS = new Set("(,=:[!&|?{};+-*%<>~^".split(""));
const REGEX_KEYWORDS = /(?:^|[^\w$])(return|typeof|case|do|else|in|of|void|yield|await)$/;

/**
 * Strip JS comments starting at `i`. When `untilBrace` is true, stop at the
 * `}` that closes the Svelte expression we were called for (depth 0) and
 * return its index (exclusive of the brace). Returns [out, endIndex].
 */
function stripJsFrom(src, i, untilBrace) {
  let out = "";
  let depth = 0;
  let lastSig = ""; // last significant (non-space) code char/word tail
  const tplStack = []; // brace depth at which each `${` opened
  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];
    // line comment
    if (c === "/" && n === "/") {
      const j = src.indexOf("\n", i);
      const end = j === -1 ? src.length : j;
      out += blank(src.slice(i, end));
      i = end;
      continue;
    }
    // block comment
    if (c === "/" && n === "*") {
      const j = src.indexOf("*/", i + 2);
      const end = j === -1 ? src.length : j + 2;
      out += blank(src.slice(i, end));
      i = end;
      continue;
    }
    // strings
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < src.length && src[j] !== c && src[j] !== "\n") j += src[j] === "\\" ? 2 : 1;
      out += src.slice(i, j + 1);
      i = j + 1;
      lastSig = "a";
      continue;
    }
    // template literal (resume after `}` of a `${…}` is handled below)
    if (c === "`") {
      out += "`";
      i = readTemplate(src, i + 1, (s) => (out += s), tplStack, depth);
      if (i < 0) {
        // entered a `${`: continue code scanning inside it
        i = -i;
        depth++;
        lastSig = "{";
        continue;
      }
      lastSig = "a";
      continue;
    }
    // regex literal
    if (c === "/") {
      const tail = out.trimEnd();
      const isRegex = lastSig === "" || REGEX_PRECEDERS.has(lastSig) || REGEX_KEYWORDS.test(tail);
      if (isRegex) {
        let j = i + 1;
        let inClass = false;
        while (j < src.length && src[j] !== "\n") {
          if (src[j] === "\\") {
            j += 2;
            continue;
          }
          if (src[j] === "[") inClass = true;
          else if (src[j] === "]") inClass = false;
          else if (src[j] === "/" && !inClass) break;
          j++;
        }
        out += src.slice(i, j + 1);
        i = j + 1;
        lastSig = "a";
        continue;
      }
    }
    if (c === "{") depth++;
    if (c === "}") {
      if (tplStack.length && tplStack[tplStack.length - 1] === depth - 1) {
        // closes a `${` → back into the template literal
        tplStack.pop();
        depth--;
        out += "}";
        i = readTemplate(src, i + 1, (s) => (out += s), tplStack, depth);
        if (i < 0) {
          i = -i;
          depth++;
          lastSig = "{";
          continue;
        }
        lastSig = "a";
        continue;
      }
      if (untilBrace && depth === 0) return [out, i];
      depth--;
    }
    out += c;
    if (!/\s/.test(c)) lastSig = /[\w$]/.test(c) ? "a" : c;
    i++;
  }
  return [out, i];
}

/**
 * Read template-literal body from `i` (just after the opening backtick or a
 * closing `}`). Emits text via `emit`. Returns the index after the closing
 * backtick, or a negative index (−pos after `${`) when an interpolation opens.
 */
function readTemplate(src, i, emit, tplStack, depth) {
  let j = i;
  while (j < src.length) {
    if (src[j] === "\\") {
      j += 2;
      continue;
    }
    if (src[j] === "`") {
      emit((i === j ? "" : src.slice(i, j)) + "`");
      return j + 1;
    }
    if (src[j] === "$" && src[j + 1] === "{") {
      emit(src.slice(i, j + 2));
      tplStack.push(depth);
      return -(j + 2);
    }
    j++;
  }
  emit(src.slice(i));
  return src.length;
}

export function stripJsComments(src) {
  return stripJsFrom(src, 0, false)[0];
}

export function stripSvelteComments(src) {
  let out = "";
  let i = 0;
  while (i < src.length) {
    if (src.startsWith("<!--", i)) {
      const j = src.indexOf("-->", i + 4);
      const end = j === -1 ? src.length : j + 3;
      out += blank(src.slice(i, end));
      i = end;
      continue;
    }
    const block = /^<(script|style)\b[^>]*>/.exec(src.slice(i, i + 200));
    if (block) {
      const tag = block[1];
      const bodyStart = i + block[0].length;
      const close = src.indexOf(`</${tag}>`, bodyStart);
      const bodyEnd = close === -1 ? src.length : close;
      const body = src.slice(bodyStart, bodyEnd);
      out += block[0];
      out +=
        tag === "script"
          ? stripJsComments(body)
          : body.replace(/\/\*[\s\S]*?\*\//g, blank);
      i = bodyEnd;
      continue;
    }
    if (src[i] === "{") {
      // Svelte block tags: `{/if}` has no expression (and its `/` would be
      // misread as a regex); `{#…}` `{:…}` `{@…}` carry one after the sigil.
      if (src[i + 1] === "/") {
        const j = src.indexOf("}", i);
        const end = j === -1 ? src.length : j + 1;
        out += src.slice(i, end);
        i = end;
        continue;
      }
      const sigil = "#:@".includes(src[i + 1]) ? 1 : 0;
      const [expr, end] = stripJsFrom(src, i + 1 + sigil, true);
      out += "{" + src.slice(i + 1, i + 1 + sigil) + expr + (end < src.length ? "}" : "");
      i = end + 1;
      continue;
    }
    out += src[i];
    i++;
  }
  return out;
}

/** CJK ideographs + CJK/fullwidth punctuation (「」、。，：！？（）…). */
export const CJK = new RegExp("[" + ["3000-\\u303f", "3400-\\u4dbf", "4e00-\\u9fff", "f900-\\ufaff", "ff00-\\uffef"].map((r) => "\\u" + r).join("") + "]");

/** Returns [{line, text}] for every line of stripped source containing CJK. */
export function cjkLines(stripped) {
  return stripped
    .split("\n")
    .map((text, idx) => ({ line: idx + 1, text: text.trim() }))
    .filter((l) => CJK.test(l.text));
}
