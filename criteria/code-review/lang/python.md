## Python language checks

Check every Python hunk against these concrete failure patterns:

- **Mutable default arguments** — `def f(x=[], y={})`. Default expressions are evaluated once at function definition time; mutations persist across calls. → use `x=None` and initialize `x = []` inside the body.
- **Bare except or broad catches** — `except:` or `except Exception:` with no re-raise or logging. This swallows `KeyboardInterrupt`, `SystemExit`, syntax errors, and unexpected exceptions. → catch specific exception types or log and re-raise.
- **Unmanaged resources** — `open()`, network sockets, database connections, or thread locks acquired without a `with` context manager. → wrap in `with` to guarantee cleanup on exception.
- **Type hint drift and unchecked Any** — type annotations using `Any` where concrete types are known, or annotations that contradict actual returned shapes. → use explicit types, `Optional[T]`, or `Union`.
- **Async blocking calls** — `time.sleep()`, synchronous `requests.get()`, or blocking I/O inside `async def` functions. → use `asyncio.sleep()`, non-blocking I/O, or `run_in_executor`.
