# Plan: Prometheus Exporter для M5Stack AI Pyramid (textfile collector)

## Context

M5Stack AI Pyramid (AX8850, 4GB) — edge AI устройство с NPU 24 TOPS. На хосте установлен node_exporter, но ему не хватает специфичных для железа метрик: потребление по шинам питания, обороты вентилятора, состояние PCIe слотов, напряжения, USB PD и т.д. Установлен `ec_cli` (EC Proxy CLI), `axcl-smi` отсутствует.

Подход: bash-скрипт, который собирает метрики через `ec_cli` и sysfs, пишет `.prom` файл для node_exporter textfile collector.

## Файлы

| Файл | Назначение |
|------|-----------|
| `pyramid_exporter.sh` | Основной скрипт сбора метрик |
| `pyramid-exporter.service` | systemd service unit |
| `pyramid-exporter.timer` | systemd timer (каждые 15 сек) |
| `install.sh` | Скрипт установки |

## Собираемые метрики

### Из `ec_cli device --board` (JSON, 6 power rails)

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_power_voltage_millivolts{rail="pcie0"}` | gauge | Напряжение PCIe слот 0 |
| `pyramid_power_voltage_millivolts{rail="pcie1"}` | gauge | Напряжение PCIe слот 1 |
| `pyramid_power_voltage_millivolts{rail="usb1"}` | gauge | Напряжение USB 1 |
| `pyramid_power_voltage_millivolts{rail="usb2"}` | gauge | Напряжение USB 2 |
| `pyramid_power_voltage_millivolts{rail="invdd"}` | gauge | Напряжение внутренний VDD |
| `pyramid_power_voltage_millivolts{rail="extvdd"}` | gauge | Напряжение внешний VDD |
| `pyramid_power_current_milliamps{rail="..."}` | gauge | Ток по каждой шине (аналогично) |
| `pyramid_power_watts{rail="..."}` | gauge | Мощность (вычисляется: mV * mA / 1000000) |

### Из `ec_cli device --fanspeed`

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_fan_speed_rpm` | gauge | Обороты вентилятора |

### Из `ec_cli exec -f fan_get_pwm`

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_fan_pwm_percent` | gauge | PWM duty cycle вентилятора (0-100) |

### Из `ec_cli exec -f vddcpu_get`

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_cpu_voltage_millivolts` | gauge | Напряжение CPU |

### Из `ec_cli exec -f pd_power_info`

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_pd_voltage_millivolts` | gauge | USB PD напряжение |
| `pyramid_pd_current_milliamps` | gauge | USB PD ток |

### Из `ec_cli exec -f V3_3_good` и `V1_8_good`

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_rail_healthy{rail="3v3"}` | gauge | 3.3V шина здорова (1/0) |
| `pyramid_rail_healthy{rail="1v8"}` | gauge | 1.8V шина здорова (1/0) |

### Из `ec_cli exec -f pcie0_exists` и `pcie1_exists`

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_pcie_present{slot="0"}` | gauge | PCIe слот 0 занят (1/0) |
| `pyramid_pcie_present{slot="1"}` | gauge | PCIe слот 1 занят (1/0) |

### Из sysfs thermal zones

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_thermal_zone_celsius{zone="...",type="..."}` | gauge | Температура (°C) |

### Служебные

| Метрика | Тип | Описание |
|---------|-----|----------|
| `pyramid_ec_firmware_version` | gauge | Версия прошивки EC |
| `pyramid_exporter_duration_seconds` | gauge | Время сбора метрик |
| `pyramid_exporter_success` | gauge | Успешность последнего сбора (1/0) |

## Реализация `pyramid_exporter.sh`

1. Зависимости: `jq`, `ec_cli`, `bc`
2. Вывод записывается атомарно: сначала во временный файл, затем `mv` в целевой `.prom`
3. Каждый вызов ec_cli обёрнут в функцию с обработкой ошибок (timeout 5s)
4. ec_cli возвращает JSON-обёртку `{"created":...,"data":<result>,"work_id":"..."}` — парсим `.data` через jq
5. Для `--board`: парсим 12 полей JSON и генерим метрики voltage/current/watts по 6 шинам

## systemd unit

- `pyramid-exporter.timer`: `OnBootSec=30s`, `OnUnitActiveSec=15s`
- `pyramid-exporter.service`: `Type=oneshot`, запускает скрипт
- Скрипт пишет в `/var/lib/node_exporter/textfile_collector/pyramid.prom`

## install.sh

1. Проверяет зависимости (jq, ec_cli)
2. Копирует скрипт в `/usr/local/bin/`
3. Устанавливает systemd units
4. Создаёт директорию textfile collector если нет
5. Включает и запускает timer
6. Проверяет, что node_exporter настроен с `--collector.textfile.directory`

## Верификация

1. Запустить `./pyramid_exporter.sh` вручную, проверить выходной `.prom` файл
2. `curl localhost:9100/metrics | grep pyramid_` — метрики видны через node_exporter
3. `promtool check metrics < /var/lib/node_exporter/textfile_collector/pyramid.prom` — валидация формата
