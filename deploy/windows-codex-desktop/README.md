# Codex Desktop on Windows

Этот профиль устанавливает безопасное ядро KISA для Codex Desktop:

- skills в `%USERPROFILE%\.agents\skills`;
- Wiki hook в `%CODEX_HOME%\hooks`;
- lifecycle-конфигурацию в `%CODEX_HOME%\hooks.json`;
- локальный vault `LLM Wiki` внутри checkout репозитория;
- backup и rollback без перезаписи существующего `AGENTS.md`.

## Команды

Из корня репозитория:

```bat
deploy\windows-codex-desktop\kisa-desktop.cmd install
deploy\windows-codex-desktop\kisa-desktop.cmd sync
deploy\windows-codex-desktop\kisa-desktop.cmd doctor
deploy\windows-codex-desktop\kisa-desktop.cmd rollback
```

Предпросмотр:

```bat
deploy\windows-codex-desktop\kisa-desktop.cmd install --dry-run
```

После установки откройте `/hooks` в Codex, проверьте точные команды и явно
доверьте новые hooks. Перезапустите Codex, если skills не появились сразу.

Живой vault и локальные secrets не входят в Git.
