## Accessibility concern checks

Check the diff for accessibility (a11y) barriers:

- **Non-semantic interactive elements** — using `<div>` or `<span>` with click handlers instead of `<button>` or `<a>`. → use native interactive HTML elements that provide built-in keyboard navigation and focus.
- **Missing accessible names** — icon buttons, form inputs, or image links without `aria-label`, `aria-labelledby`, or `<label>`. → provide clear accessible names for assistive technologies.
- **Keyboard navigation barriers** — elements that cannot be reached or operated using the keyboard alone, missing `tabIndex`, or focus traps that cannot be exited. → ensure full keyboard operability and visible focus indicators.
- **Form control associations** — `<input>`, `<select>`, or `<textarea>` without associated `<label for="...">` or enclosing `<label>`. → link labels to inputs explicitly.
- **Color-only indicators** — communicating state (success, error, required) solely through color without text labels or icons. → accompany color cues with text or semantic indicators.
