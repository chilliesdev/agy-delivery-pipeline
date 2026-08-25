## Rust language checks

Check every Rust hunk against these concrete failure patterns:

- **Unwrap in non-test code** — `.unwrap()` or `.expect()` on `Option` or `Result` in library or production paths. Panicking in production takes down the process. → propagate with `?`, provide fallback with `.unwrap_or()`, or handle with `match`/`if let`.
- **Fought lifetimes and excessive cloning** — scattering `.clone()`, `.to_string()`, or `Arc` to bypass borrow checker errors instead of designing clear ownership and borrowing boundaries. → structure references and lifetimes cleanly.
- **Direct slice indexing** — indexing `slice[i]` with unvalidated or external indices instead of `.get(i)`. Direct indexing panics on out-of-bounds. → use `.get()` with `match` or `if let`.
- **Silently discarded Results** — `let _ = result;` ignoring potential errors from I/O or fallible operations. → handle the error or document why dropping is safe.
- **Unbuffered or redundant allocations** — repeatedly allocating `Vec` or `String` inside hot loops without reserving capacity (`Vec::with_capacity`). → preallocate or reuse buffers.
