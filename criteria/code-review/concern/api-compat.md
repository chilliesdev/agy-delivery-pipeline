## API compatibility concern checks

Check the diff for breaking public interface changes:

- **Breaking signature changes** — removing, renaming, or reordering parameters in exported public functions, methods, or endpoints. → keep old signatures deprecated or add optional parameters with defaults.
- **New mandatory parameters** — adding required parameters to existing public APIs without providing sensible default values. → make new parameters optional or provide overloaded entry points.
- **Schema and payload contract breaks** — removing fields, renaming keys, or changing field types in JSON/REST/GraphQL API payloads. → maintain backward-compatible field aliases.
- **CLI interface breaks** — changing flag names, removing supported options, or modifying stdout format that scripts might depend on. → retain deprecated flags with warnings and preserve machine-readable output formats.
- **Error type and code mutations** — changing error return types or status codes that external callers catch or handle. → preserve existing error contracts.
