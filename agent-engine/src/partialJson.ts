// Reads the value of a string field out of a JSON object that is still being streamed,
// e.g. the `content` of a Write tool call whose input is only partly generated.
// Returns undefined until the field's opening quote has arrived.
export function extractPartialString(json: string, field: string): string | undefined {
  const key = `"${field}"`;
  let i = json.indexOf(key);
  if (i < 0) return undefined;
  i += key.length;
  while (i < json.length && (json[i] === ':' || json[i] === ' ' || json[i] === '\n' || json[i] === '\t')) i++;
  if (json[i] !== '"') return undefined;
  i++;

  let out = '';
  while (i < json.length) {
    const c = json[i];
    if (c === '"') break;
    if (c !== '\\') {
      out += c;
      i++;
      continue;
    }
    if (i + 1 >= json.length) break;
    const n = json[i + 1];
    if (n === 'u') {
      if (i + 6 > json.length) break;
      out += String.fromCharCode(parseInt(json.slice(i + 2, i + 6), 16));
      i += 6;
      continue;
    }
    out += ({ n: '\n', t: '\t', r: '\r', b: '\b', f: '\f' } as Record<string, string>)[n] ?? n;
    i += 2;
  }
  return out;
}
