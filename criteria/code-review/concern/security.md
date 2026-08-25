## Security concern checks

Check the diff for security vulnerabilities and dangerous operations:

- **Command injection** — passing unsanitized variables into shell executors (`eval`, `exec`, `os.system`, `subprocess(shell=True)`, `child_process.exec`). → avoid shell execution or pass arguments as explicit token arrays.
- **Injection vulnerabilities** — concatenating strings into database queries, SQL statements, or LDAP filters. → use parameterized queries and prepared statements.
- **Path traversal** — resolving file paths with user input without validating that the canonical path stays within the intended root directory. → check paths against base directory with normalized prefixes.
- **Hardcoded credentials** — API keys, private keys, passwords, bearer tokens, or sensitive credentials committed into source code or test fixtures. → load secrets from environment variables or secure key vaults.
- **Insecure deserialization** — deserializing untrusted input using `pickle`, `yaml.load` (without `SafeLoader`), or `eval`. → use safe deserializers like `json.loads` or `yaml.safe_load`.
