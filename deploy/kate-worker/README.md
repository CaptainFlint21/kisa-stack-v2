# Kate worker

Kate — удалённая Linux-среда для Codex Desktop: сборка, тесты, отдельные
ветки/worktrees и специальные команды Codex CLI.

Hermes остаётся независимым контуром. Этот профиль не меняет Hermes OAuth,
Telegram policy, proxy, gateway или systemd units.

## Установка

```bash
./deploy/kate-worker/bootstrap.sh --dry-run
./deploy/kate-worker/bootstrap.sh
./deploy/kate-worker/doctor.sh
```

Предпросмотр и обновление:

```bash
./deploy/kate-worker/kisa-worker.sh sync --dry-run
./deploy/kate-worker/kisa-worker.sh sync
```

Полная проверка после установки:

```bash
./deploy/kate-worker/verify.sh
```

Требования:

- Node.js;
- Git;
- установленный и авторизованный Codex CLI;
- обычный пользователь без passwordless sudo;
- checkout той же Git-ветки, которая используется на управляющем ПК.

Рекомендуемый путь:

```text
/home/kate/src/kisa-Codex-Desktop-stack
```

После добавления каталога как remote project в Codex Desktop задачи можно
запускать непосредственно на Kate. Вложенный вызов Codex CLI используется
только для CLI/MCP и batch-сценариев.
