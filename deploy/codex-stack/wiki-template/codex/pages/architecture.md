# Architecture

```text
Codex Desktop (Windows)
├── local projects, tools, browser and GitHub
├── AGENTS.md, KISA skills and Wiki hooks
└── built-in SSH connection
    └── Kate (Linux worker)
        ├── isolated branches/worktrees
        ├── builds and tests
        └── Codex CLI
```

Hermes остаётся отдельным автономным контуром и не является транспортом
управления для Codex Desktop.
