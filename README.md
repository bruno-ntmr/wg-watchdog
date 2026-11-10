# WG/AWG handshake watchdog

Один POSIX `/bin/sh`-скрипт для Linux, OpenWrt и OPNsense. За один запуск читает
конфиг, проверяет handshakes и при необходимости перезапускает только выбранный
интерфейс через его сетевой менеджер. Для периодического запуска достаточно cron.
Ничего не устанавливает и не включает автоматически.

## Быстрая установка

Скопировать репозиторий на целевую систему и выполнить от root:

```sh
git clone https://github.com/bruno-ntmr/wg-watchdog.git
cd wg-watchdog
sh install.sh --dry-run
sh install.sh
```

Если Git на роутере отсутствует, достаточно скопировать рядом `install.sh` и
`wg-watchdog.sh`. Установщик сам определяет ОС, обходит доступные WG/AWG устройства,
выбирает backend, создаёт конфиг и задачу каждую минуту. По умолчанию таймаут —
5 минут. Зависимости/пакеты установщик не скачивает.

```sh
sh install.sh --timeout 10       # таймаут для вновь обнаруженных интерфейсов
sh install.sh                   # обновить скрипт, добавить новые интерфейсы
sh install.sh --no-cron          # установить файлы без настройки планировщика
sh install.sh --uninstall        # удалить скрипт и свою задачу, сохранить конфиг
```

Повторная установка сохраняет существующие строки и таймауты, не дублирует cron,
делает резервную копию существующего конфига (`.bak.TIMESTAMP`). Если сохранённый
конфиг уже не соответствует устройствам/UUID, проверка останавливает установку:
его нужно исправить вручную. Удалённые/неподдерживаемые интерфейсы не добавляются.

| Система | Скрипт | Конфиг | Планировщик |
|---|---|---|---|
| Linux | `/usr/local/sbin/wg-watchdog.sh` | `/etc/wg-watchdog.conf` | root crontab; systemd/OpenRC/SysV cron daemon |
| OpenWrt | `/usr/sbin/wg-watchdog.sh` | `/etc/wg-watchdog.conf` | root crontab; procd cron |
| OPNsense | `/usr/local/sbin/wg-watchdog.sh` | `/usr/local/etc/wg-watchdog.conf` | configd action и нативная Cron job в config.xml |

На OPNsense задача видна в GUI и переживает регенерацию crontab. Сохранение через
штатную модель создаёт резервную копию config.xml. Другие cron-задачи не удаляются.
Пути можно переопределить через `--bin /path/script` и `--config /path/config`;
при удалении нужно передать те же пути. Root нужен и для dry-run: обычный
пользователь не может надёжно обойти VPN-интерфейсы.

## Конфиг

```text
# interface  timeout_minutes [backend [target [tool]]]
wg0 5
awg0 5
```

Имена без пробелов; комментарии начинаются с `#`. Таймаут — целое число минут,
от 1 до 525600. Не shell-конфиг: `source` и `eval` не используются.

При нескольких пирах интерфейс перезапускается, только когда **ни у одного**
нет свежего handshake. Отсутствие пиров или ошибка чтения — ошибка проверки,
а не основание перезапускать сеть. Отключённые администратором instance/глобальный
VPN на OPNsense и интерфейсы без административного флага `UP` пропускаются.
`ip link down`/`ifconfig down` не считаются поломкой. Если watchdog увидел ручное
отключение, после следующего включения предоставляется новый льготный период.
Интерфейс, для которого CLI уже не может
прочитать пиров, скрипт не поднимает. После первого наблюдения и каждой попытки перезапуска
выдерживается полный таймаут, в том числе при handshake=0. Неудачная попытка
тоже запускает cooldown. Состояние хранится в `/var/run/wg-watchdog`, без ключей.

Неактивный WireGuard может штатно не обновлять handshake: для постоянного
туннеля нужен регулярный трафик/`PersistentKeepalive`. Обычно разумно начинать
с таймаута 5 минут и keepalive 25 секунд, а не с минутного боевого таймаута.
Наличие handshake не означает работоспособность DNS/маршрутизации/интернета.

## Автоопределение и явный выбор

| Система/способ | Автоопределение | Действие |
|---|---|---|
| OpenWrt, WG/AWG под netifd | Логическое имя или `l3_device`, VPN protocol | `ubus … down`, затем `up` |
| OpenWrt, отдельный AWG userspace | Один работающий procd instance, wrapper с одним буквальным вызовом `amneziawg-go [-f] DEVICE` | `/etc/init.d/SERVICE restart` |
| OPNsense WG | Активный instance в config.xml, UUID | `configctl wireguard restart UUID` |
| OPNsense AWG | Устройство и `/usr/local/etc/amnezia/DEVICE.conf`, доступный awg-quick | Прямой `awg-quick down/up CONFIG`, группа интерфейса и filter reload |
| Linux, wg-quick/awg-quick через systemd | Активный instance unit | `systemctl restart UNIT` |
| Linux, NetworkManager | Активный UUID соединения интерфейса | `nmcli connection down/up uuid UUID` |
| Linux, standalone quick | Один стандартный конфиг, нет активного известного менеджера | `wg-quick/awg-quick down/up CONFIG` |

Управление через systemd-networkd пока не поддерживается: простой down/up не
гарантирует пересоздание WireGuard netdev. Общий networkd-сервис не перезапускается.

На OPNsense можно указать `wgN`/`awgN`, assignment вроде `opt8` или имя instance
вроде `Farm`. XML разбирает штатный PHP OPNsense; наружу возвращаются только
device/UUID, без ключей. Остальные системы не требуют PHP. AWG backend не загружает
PHP-классы AWG-плагина и не вызывает его API, reconfigure или Apply. `config.xml`
только читается для имён и ручного отключения; при standalone awg-tools без модели
плагина достаточно устройства и стандартного конфига. Имена assignment тоже
поддерживаются. Старые строки с UUID принимаются для совместимости; новые строки
установщик создаёт с путём к конфигу.

AWG backend вызывает `awg-quick down /usr/local/etc/amnezia/DEVICE.conf`, проверяет
удаление device, ждёт 2 секунды и вызывает `awg-quick up` с тем же конфигом.
Затем восстанавливает `ifconfig DEVICE group amneziawg` и выполняет штатный
`configctl filter reload`: правила firewall/NAT должны увидеть новый device.
Это вызов ядра OPNsense, а не AWG-плагина. Другие VPN-instance не перезапускаются.
`enabled` и config.xml не меняются; на Farm проверены неизменность AWG-конфигурации
и свежий handshake через две секунды после начала прямого down/up.

Для собственного незавершённого down/up watchdog записывает recovery record
**до** удаления устройства. При ошибке/сигнале запускает отсутствующее устройство
через `awg-quick up`; после SIGKILL это делает следующий запуск cron до обычных
проверок. Уже поднятый device повторно не перезапускается. Ручное отключение
instance/глобального VPN или административный DOWN отменяют recovery.
По умолчанию record находится в `/conf/wg-watchdog.pending` и переживает reboot;
при явном `--state-dir` — в этом каталоге. Ручной запуск восстановления:
`wg-watchdog.sh --recover-only` (для custom state указать тот же `--state-dir`).
Обновление/удаление через установщик сначала завершает собственный pending restart
установленной версии, поддерживающей recovery, затем меняет файлы и cron.
Это также завершает старый enabled-toggle при обновлении с предыдущей версии.
Новая версия не интерпретирует старый recovery record как прямой down/up.

Для нестандартного userspace-wrapper укажите сервис явно. Он должен обслуживать
только этот туннель: указание общего сервиса перезапустит весь этот сервис.
Примеры:

```text
# OpenWrt netifd, если логический интерфейс vpn, а устройство wg0:
wg0 5 openwrt vpn
# Отдельный AWG userspace, в том числе с переменными внутри wrapper:
awg0 5 openwrt-service amneziawg-userspace awg
# Linux без systemd unit: явный путь для нестандартного конфига.
wg0 5 wg-quick /etc/wireguard/wg0.conf
awg0 5 awg-quick /etc/amnezia/amneziawg/awg0.conf
```

Последнее необязательное поле выбирает CLI: `wg`, `awg` или `awg3`.
По умолчанию скрипт пробует доступные инструменты и проверяет результат запроса.
Нативное поведение менеджера сохраняется, включая quick hooks и `SaveConfig`.
В частности, при `SaveConfig=true` quick может записать runtime-настройки в файл.

## Установка и запуск

Сначала отредактировать пример, оставив только нужные интерфейсы. Затем от root:

```sh
install -m 755 wg-watchdog.sh /usr/local/sbin/wg-watchdog.sh
install -m 600 wg-watchdog.conf.example /etc/wg-watchdog.conf
/usr/local/sbin/wg-watchdog.sh --dry-run
/usr/local/sbin/wg-watchdog.sh -v
```

На OpenWrt без `install` используйте `cp` и `chmod`; скрипт можно положить в
`/usr/sbin`. Проверьте наличие штатных `wg`/`awg`, `ubus`, `jsonfilter`.
На Linux нужны инструменты выбранного сетевого менеджера; Bash требуется самому
`wg-quick`/`awg-quick`, но не watchdog. На всех платформах нужен доступ root к VPN.

Для Linux/OpenWrt добавить в root crontab (`crontab -e`):

```cron
* * * * * /usr/local/sbin/wg-watchdog.sh
```

На OpenWrt при установке в `/usr/sbin` замените путь; если cron выключен,
включите его штатным `/etc/init.d/cron enable` и `/etc/init.d/cron start`.
Фактическое срабатывание — после истечения таймаута на ближайшей проверке cron.

На OPNsense удобнее использовать штатный GUI cron:

1. Установить конфиг в `/usr/local/etc/wg-watchdog.conf`.
2. Скопировать `actions_wgwatchdog.conf` в
   `/usr/local/opnsense/service/conf/actions.d/actions_wgwatchdog.conf`.
3. Выполнить `service configd restart`.
4. В System → Settings → Cron выбрать **Check WireGuard and AmneziaWG handshakes**,
   запуск каждую минуту.

Сначала проверить вручную:
`/usr/local/sbin/wg-watchdog.sh -c /usr/local/etc/wg-watchdog.conf --dry-run`.
Пользовательские файлы/действие нужно сохранять отдельно перед переустановкой ОС.

Обычный запуск молчит при исправной работе. Ошибки/перезапуски идут в stderr и
syslog с тегом `wg-watchdog`; `-v` показывает каждую проверку. `--dry-run` не
перезапускает интерфейсы, не пишет состояние и syslog. Для независимого теста
можно указать `--state-dir /var/run/wg-watchdog-test`. Код завершения: 0 — проверка
успешна/lock занят, 1 — ошибка интерфейса/конфига/перезапуска, 2 — ошибка запуска.
Блокировка использует `mkdir`, `flock` не нужен. После SIGKILL оставшийся lock
обычно убирается следующей проверкой по PID; после аварии непосредственно во время
очистки lock может потребоваться вручную удалить пустой каталог `STATE/reap`.

Автовыбор standalone quick — эвристика по единственному стандартному конфигу;
для нестандартного менеджера нужно указать корректный backend вручную.
Системные пакеты cron и VPN-инструменты должны быть установлены заранее.

## Проверка Linux без изменения сети хоста

```sh
unshare --user --map-root-user --net --mount python3 test-linux.py
```

Подход взят из integration-тестов проекта 0din. Создаются настоящие WG и AWG
пары в отдельном namespace, в памяти портятся peer keys, через минуту watchdog
перезапускает клиенты. Тест проверяет новые handshakes, восстановление endpoint,
поведение при мёртвом дополнительном пире, cooldown, блокировку и dry-run.
Временные интерфейсы и ключи удаляются. Требуются оба kernel protocol и quick CLI.
Изолированный bind mount `/etc/wireguard` нужен для AppArmor Ubuntu; содержимое
реального каталога хоста не меняется.
Также проверяется автообход установщика, сохранение изменённого таймаута,
повторная установка без изменения конфига и удаление с сохранением конфига.

Проверены настоящие WG/AWG на Linux, WG через netifd и AWG userspace на OpenWrt,
обнаружение интерфейсов и цикл install/reinstall/uninstall с нативным cron на
OPNsense. Native AWG netifd использует тот же адаптер, что WG, но отдельно на
реальном OpenWrt с установленным AWG protocol handler пока не проверен.
На OPNsense подтверждены возврат handshake после прямого awg-quick down/up,
неизменность config.xml и сохранение ручного отключения.
NetworkManager и systemd units отдельно в живой сети не проверялись.

`python3 test-opnsense.py` проверяет shell backend с имитацией нативных команд:
прямой down/up без исполнения плагина, восстановление после ошибки, сохранение
recovery record при неудаче и запрет вмешательства в ручное отключение.
