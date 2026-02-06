# Tasks

**Dex Epic**: `<epic-id>`

## Querying Tasks

```bash
# View epic and all subtasks
dex show <epic-id>

# List only ready (unblocked) tasks
dex list --ready

# List blocked tasks
dex list --blocked

# View full details for a specific task
dex show <task-id>
```

## Agent Workflow

1. **Pick up a ready task**: Run `dex list --ready` to find unblocked tasks
2. **Read context**: Use `dex show <task-id>` to get the full description and file references
3. **Read artifacts**: Open the referenced openspec files (proposal, design, specs) for full context
4. **Implement**: Make the changes described in the task
5. **Verify**: Run tests, build, and confirm the implementation meets the task criteria
6. **Commit**: Stage and commit the changes
7. **Complete**: Mark done with a result summary:
   ```bash
   dex complete <task-id> --result "What was accomplished and how it was verified" --commit <sha>
   ```
8. **Repeat**: Check for newly unblocked tasks with `dex list --ready` and continue
