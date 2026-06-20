# KISA Stack [![Awesome](https://awesome.re/badge.svg)](https://awesome.re)

Личный сетап для вайбкодинга: система поведения AI-ассистентов, skills, hooks и плагины. Артефакты рассчитаны на **Claude Code**, **Codex CLI** и **Hermes**.

## Contents

- [Глобальный конфиг](#глобальный-конфиг)
- [Скиллы](#скиллы)
- [Установка](#установка)
- [Профиль Kate](#профиль-kate)
- [Совместимость](#совместимость)

## Глобальный конфиг

Ядро системы — сначала думать, решать ровно поставленную задачу, проверять факты инструментами и не ломать уже рабочее.

- [CLAUDE.md](global-config/CLAUDE.md) — глобальный конфиг Claude Code.
- [AGENTS.md](global-config/AGENTS.md) — та же методология для Codex CLI.
- [Хуки](global-config/hooks) — Wiki-якорь на старте и периодическое напоминание.

Пошаговая установка: [global-config/README.md](global-config/README.md).

## Скиллы

Один формат `SKILL.md` используется всеми тремя рантаймами. Codex-метаданные находятся в `agents/openai.yaml`, Hermes-конвенции — во frontmatter `metadata.hermes`.

### Ресерч и знания

- [researcher](skills/researcher) — signal-only ресерч в режимах quick-scan / deep-research.
- [gamer-signal](skills/gamer-signal) — игровой ресерч по официальным источникам, Steam и allowlist-вики.
- [telegram-chat-wiki](skills/telegram-chat-wiki) — Telegram-экспорт в raw day-chunks и hub-страницу собеседника.

### Код и оркестрация

- [codex-delegator](skills/codex-delegator) — делегирование кодовых задач из Hermes в официальный Codex MCP server с сохранением `threadId`.

### Контент и медиа

- [css-graphics](skills/css-graphics) — HTML/CSS/SVG-графика с рендером через Puppeteer.
- [stream-timecodes](skills/stream-timecodes) — ровно 18 таймкодов из VTT.
- [voice-summary](skills/voice-summary) — транскрипция и action-first выжимки из аудио.

### Музыка и озвучка

- [elevenlabs-living-voice](skills/elevenlabs-living-voice) — живая подача ElevenLabs v2/v3.
- [suno-music](skills/suno-music) — генерация треков через EvoLink Suno API.
- [ai-music-and-audio-tools](skills/ai-music-and-audio-tools) — AI-музыка, локальная генерация и спектрограммы.

### Система и личное

- [wine-hid-device-tools](skills/wine-hid-device-tools) — HID-утилиты под Wine/PortProton/Bottles.
- [emotional-support](skills/emotional-support) — активное слушание и аккуратный CBT-рефрейминг.

Полный список плагинов и внешних инструментов: [plugins.md](plugins.md).

## Установка

Установщик поддерживает действия `install`, `sync`, `doctor`, профили и dry-run.

```bash
# Безопасное ядро в Codex + Hermes
./install.sh install core --codex --hermes

# Предпросмотр без изменений
./install.sh sync core --codex --hermes --dry-run

# Обновить установленные копии с backup только при изменениях
./install.sh sync core --codex --hermes

# Проверить drift
./install.sh doctor core --codex --hermes

# Один skill
./install.sh install researcher --codex
```

Профили находятся в [`profiles/`](profiles). Существующие отличающиеся skills бэкапятся с timestamp. Повторный запуск с идентичным содержимым ничего не перезаписывает. Локальные `.env` сохраняются при sync и никогда не копируются из repository source.

Без runtime-флагов сохраняется legacy-поведение: Claude Code + Codex.

## Профиль Kate

Готовый Linux deployment для цепочки:

```text
Telegram → Hermes → Codex CLI через MCP → GitHub
```

Он включает core skills, RTK, отдельный Hermes OAuth `openai-codex`, `codex mcp-server`, Wiki-якоря, Telegram allowlist, backup/rollback и проверочный workflow.

Инструкция: [deploy/kate/README.md](deploy/kate/README.md).

```bash
bash deploy/kate/bootstrap.sh --dry-run
bash deploy/kate/bootstrap.sh
bash deploy/kate/verify.sh
```

## Совместимость

| Рантайм | Скиллы | Конфиг | Примечания |
|---|---|---|---|
| Claude Code | `~/.claude/skills/` | `~/.claude/CLAUDE.md` + hooks | основной исторический сетап |
| Codex CLI | `~/.agents/skills/` | `~/.codex/AGENTS.md` + `hooks.json` | актуальный user-scope каталог skills |
| Hermes | `~/.hermes/skills/` | `~/.hermes/config.yaml` + hooks | MCP, Telegram, cron и автономная работа |

Имена инструментов и способы доставки отличаются по runtime, но логика skills остаётся общей.

## Contributing

Это персональный рабочий стек. Перед merge запускайте:

```bash
bash deploy/kate/verify.sh --offline
```

Нашли проблему — открывайте issue или draft PR.
