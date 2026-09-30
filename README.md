# tnt-admin

Панель узла и кластера на Tarantool 3: состав репликасетов, кто лидер,
находки диагностики и что с ними делать, узлы конфигурации по отбору,
журнал аудита. Приложение подключает её ролью рядом со своей, а страницы
рисует сам узел — панель работает и без сценариев. О новом снимке
кластера узел сообщает толчком: обзор уходит в канал Centrifugo, и
браузер перерисовывает страницу, не опрашивая узел.

```yaml
# config.yaml — панель вторым жильцом узла, рядом с ролью приложения
roles: [roles.httpd, tnt.admin, bootstrap.app]
```

```lua
-- config/admin.lua — свой порт панели из окружения
---@param env TntEnv
return function(env)
    return { listen = env('ADMIN_LISTEN', '127.0.0.1:8081') }
end
```

```
панель питается: audit, audit_verify, filter, issues, snapshot, suggestions, updates
GET /api/v1/instances?groups=storages&labels[zone]=spb → 200 {"instances":[{"name":"storage-001-a",…}]}
GET /api/v1/instances?group=storages                   → 400 отбор узлов не разобран
```

Зависимости: [tnt-framework](https://github.com/tnt-skein/tnt-framework),
[tnt-kernel](https://github.com/tnt-skein/tnt-kernel),
[tnt-router](https://github.com/tnt-skein/tnt-router),
[tnt-template](https://github.com/tnt-skein/tnt-template),
[tnt-di](https://github.com/tnt-skein/tnt-di),
[tnt-config](https://github.com/tnt-skein/tnt-config),
[tnt-env](https://github.com/tnt-skein/tnt-env),
[tnt-error](https://github.com/tnt-skein/tnt-error),
[tnt-validate](https://github.com/tnt-skein/tnt-validate),
[tnt-data](https://github.com/tnt-skein/tnt-data),
[tnt-openapi](https://github.com/tnt-skein/tnt-openapi),
[tnt-log](https://github.com/tnt-skein/tnt-log),
[tnt-permissions](https://github.com/tnt-skein/tnt-permissions),
[tnt-cluster-health](https://github.com/tnt-skein/tnt-cluster-health),
[tnt-centrifugo](https://github.com/tnt-skein/tnt-centrifugo),
[tnt-must](https://github.com/tnt-skein/tnt-must),
[tnt-external](https://github.com/tnt-skein/tnt-external).
Журнал аудита и действия над кластером приходят от пакетов, которые
панель берёт по имени, если они стоят рядом:
[tnt-audit](https://github.com/tnt-skein/tnt-audit),
[tnt-ops](https://github.com/tnt-skein/tnt-ops),
[tnt-sharding](https://github.com/tnt-skein/tnt-sharding),
[tnt-recovery](https://github.com/tnt-skein/tnt-recovery).

## Зачем

Панель к кластеру пишут в последнюю очередь и под одно развёртывание,
а дальше она отстаёт от кластера. Здесь она отделена от него с трёх
сторон:

- **Приложение о ней не знает.** Панель — не провайдер и не набор
  маршрутов, а своя роль: приложение называет её в конфигурации так же,
  как `roles.httpd`.
- **Она не знает, что умеет кластер.** Координатор, выборы, смена
  лидерства извне — признаки, которые ей объявляют.
- **Она не знает, что установлено рядом.** Снимок кластера, находки,
  журнал аудита, действия — источники, и каждый берётся у своего пакета
  по имени. Пакета нет — кнопки нет, а API отвечает отказом с кодом.

## Установка

```sh
tt rocks install tnt-admin --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-admin.git
cd tnt-admin && tt rocks make
```

## Как пользоваться

Настройки читаются тремя слоями, каждый следующий сильнее: умолчания
пакета, `config/admin.lua` приложения и раздел `roles_cfg`:

| Поле | Что задаёт |
|---|---|
| `listen` | свой порт панели: с ним она поднимает собственный сервер |
| `server` | без `listen` — имя сервера `roles.httpd`, по умолчанию `admin` |
| `sources` | выключить установленный источник: `audit = false` |
| `watch` | учётка наблюдателя: панель сама заводит обход кластера |
| `actions` | учётка обслуживания: действия `tnt-ops` и `tnt-sharding` |

| Путь | Что отвечает |
|---|---|
| `/`, `/cluster`, `/issues`, `/config` | страницы, нарисованные узлом |
| `/audit?from_id=…&to_id=…` | страница журнала потоком, по тысяче записей, дальше — ссылкой |
| `/api/v1/overview`, `/api/v1/cluster`, `/api/v1/issues` | кластер, находки, подсказки |
| `/api/v1/instances?groups=…&labels[zone]=…` | узлы конфигурации по отбору |
| `/api/v1/actions/assess`, `/api/v1/actions` | оценка действия и само действие |
| `/api/v1/audit`, `/api/v1/audit/verify` | журнал аудита потоком и проверка цепочки |
| `/connection/websocket` | точка Centrifugo: канал `overview`, обзор толчком на каждый новый снимок |

Приложению со своим сервером и своим входом панель собирается функцией
«запрос — ответ» над его источниками:

```lua
local cluster = require('tnt.cluster')
local httpd = require('http.server').new('127.0.0.1', 8081)

local panel = require('tnt.admin.app.http.panel').new({
    snapshot = cluster.current,
    issues = cluster.findings,
    authorize = function(request)
        return { username = request.headers['x-operator'] or 'гость', readonly = true }
    end,
    panel = require('tnt.admin.public.bundle'),
})

panel.attach(httpd)
httpd:start()
```

Кто что может, решают ворота `tnt-permissions`, объявленные в одном
месте: признак `readonly` — роль `observer` (смотреть кластер), без него —
`admin` (ещё действия и конфигурация), `audit = true` — чтение журнала
аудита. Маршрут называет способность слоем `can`, и без неё API,
страница и форма отвечают 403 словом панели:

```json
{ "error": { "status": 403, "message": "у вас нет права смотреть конфигурацию кластера" } }
```

## Проверки

```sh
make deps          # зависимости пакета, соседи проверок, клиент centrifuge-js и инструменты проверок
make check         # форматирование, линт, сверка описания API, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
```

Описание API `docs/api/panel.yaml` собирается из кода панели
(`make api-spec`), а `make lint-api` сличает его с кодом. Стили
и сценарий панели собираются из `ui/` в `panel/` (`bun install`,
`bun run build`) и пакуются в модуль (`make panel`); упакованное
сверяется с `panel/` той же `make lint-api`.

375 проверок; покрытие строк — 100 % (1724 из 1724), убитых мутантов —
100 % (1076 мутантов в тридцати одном модуле). Роль проверяется
на двойнике мира ядра, запросы идут через настоящую границу ядра, отбор
узлов — и на настоящей диагностике, журнал аудита за проводом — на живом
узле, толчок обзора — на настоящем порту и с официальным клиентом
`centrifuge-js`.

## Документ

Полное описание с обоснованием решений: [docs/admin.md](docs/admin.md).

## Лицензия

MIT.
