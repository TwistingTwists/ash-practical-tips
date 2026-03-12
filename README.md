# Ash Practical Examples

Collection of single-file Elixir scripts demonstrating Ash Framework patterns, issues, and solutions.

## Structure

```
├── working-single-file-elixir-scripts/  # Self-contained examples with Mix.install
├── usage_rules/                         # AI assistant guidelines for Ash/Phoenix
├── docs/                                # Discord conversation transcripts
│   ├── conversation_files/              # Original Q&A discussions
│   └── mistakes-learnings/              # Lessons learned
└── wojtekmach-mix_install_examples/     # Reference examples (external)
```

## Running Examples

Each script in `working-single-file-elixir-scripts/` is self-contained:

```bash
elixir 001-v1-many-many.exs
```

## Available Examples

| File | Topic |
|------|-------|
| `001-v1-many-many.exs` | Many-to-many relationship management pitfalls |
| `001-v2-many-many-ids-append-remove.exs` | Extended many-to-many with append/remove |
| `002-dump-typed-struct.exs` | Dumping Ash TypedStruct to native values |

## Usage Rules

The `usage_rules/` directory contains SKILL.md files for AI assistants working with:
- Ash Framework
- Phoenix Framework
- Oban Jobs
- LLM Integration

## Credits

- `wojtekmach-mix_install_examples/` from [wojtekmach/mix_install_examples](https://github.com/wojtekmach/mix_install_examples)
