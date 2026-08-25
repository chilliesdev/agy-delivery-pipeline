## TypeScript language checks

Check every TypeScript hunk against these concrete failure patterns:

- **Type safety escapes** — `any`, `as any`, or `as unknown as T` used to silence compiler errors rather than fixing underlying type mismatches. → define proper interfaces or use `unknown` with runtime type narrowing.
- **Missing discriminated union exhaustiveness** — `switch` or `if/else` over a discriminated union without a compile-time exhaustiveness check (`default: const _exhaustive: never = val;`). → ensure all variants are handled so future union additions fail at build time.
- **Floating or unhandled Promises** — calling `async` functions without `await`, `.catch()`, or `void` prefix. Unhandled rejections crash or silently fail in Node/browsers. → await the promise or attach an explicit error handler.
- **Unsafe non-null assertions** — `val!` on values from external APIs, DOM queries, or optional map lookups where the value could be `null` or `undefined` at runtime. → use optional chaining (`?.`) or explicit null checks.
- **Loose equality comparisons** — `==` or `!=` instead of strict `===` or `!==`, causing unintended type coercions (e.g. `0 == ""` or `null == undefined`). → use strict equality everywhere.
