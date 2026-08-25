## Go language checks

Check every Go hunk against these concrete failure patterns:

- **Ignored or discarded errors** — `_ = fn()` or calling functions returning `error` without checking `if err != nil`. → handle the error, wrap with context (`fmt.Errorf("...: %w", err)`), or return to caller.
- **Unbounded goroutine lifecycles** — launching goroutines (`go func()`) without a lifecycle manager, `context.Context` cancellation, or `sync.WaitGroup`. Leaked goroutines consume memory and block shutdowns. → tie goroutine lifetime to a context or channel.
- **Defer inside loops** — `defer file.Close()` or `defer mu.Unlock()` inside a `for` loop. Deferred calls execute when the enclosing function returns, not at loop iteration end, causing resource exhaustion. → wrap loop body in a helper function or manage cleanup explicitly.
- **Mutex copied by value** — structs containing `sync.Mutex` passed by value rather than by pointer (`*T`), which copies the lock state and causes race conditions or deadlocks. → pass lock-holding structs by pointer.
- **Nil interface pitfalls** — returning a typed nil pointer as an `error` interface, where `err != nil` evaluates to true because the interface holds type information. → return explicit `nil` on success.
