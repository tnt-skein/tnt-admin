--- Описание API панели для `tnt-openapi`: слова и коды её операций.
---
--- Пути, способы и параметры пути документ берёт у роутера панели,
--- схемы тел — у форм `tnt-data` (`tnt.admin.app.data.*`), а здесь
--- и в `tnt.admin.app.http.openapi.*` пишутся только слова: что делает
--- операция и что значит каждый её ответ. Описание ищется по имени
--- маршрута (`routes/api.lua`), и маршрут API без описания, как
--- и описание без маршрута, — отказ сборки документа, а не молча
--- пропавшая операция.
---
--- Документ собирается `Api.document(router)` и лежит в дереве файлом
--- `docs/api/panel.yaml`: его пишет `make api-spec`, а `make lint-api`
--- сличает файл с документом, собранным заново. Правка формы или слова
--- без пересборки файла роняет сверку.
---
--- Модуль лежит не в `routes/`: каждый файл там фреймворк берёт модулем
--- маршрутов, а описание маршрутов не объявляет.

local openapi = require('tnt.openapi')

local refusal = require('tnt.admin.app.data.refusal')
local audit = require('tnt.admin.app.http.openapi.audit')
local changes = require('tnt.admin.app.http.openapi.changes')
local views = require('tnt.admin.app.http.openapi.views')

--- Слова, общие для частей описания.
---@class TntAdminApiWords
---@field unauthenticated string Отказ опознания: он один у всех путей под слоем входа
---@field forbidden_change string Отказ права менять кластер

---@type TntAdminApiWords
local WORDS = {
    unauthenticated = 'Вход не выполнен',
    forbidden_change = 'Нет права менять кластер',
}

--- Описания операций по именам маршрутов, собранные из частей.
local operations = {}

for _, part in ipairs({ views, changes, audit }) do
    for name, operation in pairs(part(WORDS)) do
        operations[name] = operation
    end
end

local Api = openapi.define({
    title = 'Панель кластера Tarantool',
    version = '1',
    description = [[
Состояние кластера, находки диагностики, подсказки оператору и действия над узлами.

Код ответа настоящий: 401 — не вошли, 403 — нет права, 404 — нет такого пути, 405 — сюда
так не ходят, 207 — действие удалось не всем. Разбирать текст ошибки не нужно.

Тело отказа одно на всё API — схема Refusal: error.status — тот же код, error.message —
что показать человеку, error.incident — номер записи журнала, если отказ записан как
происшествие. Разбор по полям, код ворот, фаза и отчёт раскатки приходят у тех ответов,
где они описаны. Отказы до маршрута — 404, 405 с заголовком Allow, тело не в пределах
(400, 408, 411, 413) — приходят тем же видом.

Транспорт панель не шифрует: пароль оператора и слово сборщика метрик идут открытым
текстом. В развёртывании панель ставится за обратным прокси с TLS.
]],
    servers = { { url = '/api/v1' } },
    refusal = {
        schema = refusal.Refusal,
        description = 'Отказ, не названный у операции: поломка обработчика — 500 с номером происшествия — '
            .. 'или тело запроса не в пределах — 400, 408, 411, 413',
    },
    operations = operations,
})

return Api
