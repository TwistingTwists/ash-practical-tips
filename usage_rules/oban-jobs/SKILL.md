---
name: oban-jobs
description: "Use this skill when working with Oban background jobs or scheduling. Consult this for job workers, queues, and Oban configuration."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

- [oban](references/oban.md)
- [oban_web](references/oban_web.md)
- [ash_oban](references/ash_oban.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p oban -p oban_web -p ash_oban
```

## Available Mix Tasks

- `mix oban.install` - Install and configure Oban for use in an application.
- `mix oban.install.docs`
- `mix oban_web.install` - Installs Oban Web into your Phoenix application
- `mix oban_web.install.docs`
- `mix ash_oban.install` - Installs AshOban and Oban
- `mix ash_oban.install.docs`
- `mix ash_oban.set_default_module_names` - Set module names to their default values for triggers and scheduled actions
- `mix ash_oban.set_default_module_names.docs`
- `mix ash_oban.upgrade`
<!-- usage-rules-skill-end -->
