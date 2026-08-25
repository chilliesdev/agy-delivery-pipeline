## Performance concern checks

Check the diff for performance regressions and resource bottlenecks:

- **N+1 query patterns** — executing database queries, API calls, or filesystem operations inside a loop rather than batching. → fetch data in bulk before the loop.
- **Unbounded memory loading** — reading entire large files or unbounded result sets into memory at once. → stream files or paginate queries in chunks.
- **Algorithmic complexity regressions** — nested loops performing repeated linear scans over lists instead of using set or map lookups (O(N^2) vs O(N)). → index lookup data into hash sets or dictionaries.
- **Missing memoization or redundant computation** — expensive calculations or DOM reconstructions executed repeatedly on every render or request. → cache or memoize expensive results.
- **Resource and listener leaks** — event listeners, timers (`setInterval`), or background workers registered without corresponding removal/cleanup on teardown. → register teardown handlers for all listeners and timers.
