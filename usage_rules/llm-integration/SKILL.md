---
name: llm-integration
description: "Use this skill when working with LLM provider integrations. Consult this for chat completions, model configuration, and provider setup."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

- [req_llm](references/req_llm.md)
- [ash_ai](references/ash_ai.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p req_llm -p ash_ai
```

## Available Mix Tasks

- `mix req_llm.gen` - Generate text or objects from any AI model
- `mix req_llm.model_compat` - Validate ReqLLM model coverage with fixture-based testing
- `mix ash_ai.gen.chat` - Generates the resources and views for a conversational UI backed by `ash_postgres` and `ash_oban`
- `mix ash_ai.gen.chat.docs`
- `mix ash_ai.gen.mcp` - Sets up an MCP server for your application
- `mix ash_ai.gen.mcp.docs`
- `mix ash_ai.gen.usage_rules`
- `mix ash_ai.gen.usage_rules.docs`
- `mix ash_ai.install` - Installs `AshAi`. Call with `mix igniter.install ash_ai`. Requires igniter to run.
- `mix ash_ai.install.docs`
<!-- usage-rules-skill-end -->
