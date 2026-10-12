export function compareHostIdentitySets(expectedIds, renderedIds) {
  const normalize = values => Array.isArray(values)
    ? values.map(value => String(value || '').trim().toUpperCase())
    : [];
  const expected = normalize(expectedIds);
  const rendered = normalize(renderedIds);
  const validSet = values => values.length > 0
    && values.every(value => /^[0-9A-F]{40}$/.test(value))
    && new Set(values).size === values.length;
  const valid = validSet(expected) && validSet(rendered);
  return {
    valid,
    matches: valid && JSON.stringify([...expected].sort()) === JSON.stringify([...rendered].sort()),
    expected,
    rendered,
  };
}
