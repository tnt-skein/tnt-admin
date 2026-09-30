--- Сверяет описание API панели с тем, что она обслуживает на самом деле.
---
--- Описание docs/api/panel.yaml собрано из кода: документ OpenAPI
--- собирает `tnt-openapi` (`Api.document`) из маршрутов панели, форм
--- `tnt-data` и слов операций, а файл пишет `make api-spec`. Сверка
--- собирает документ заново и сличает с ним файл таблицами: правка формы,
--- слова или маршрута без пересборки файла — это молчаливое изменение
--- договора, о котором чужой клиент узнал бы, только когда сломается.
--- Маршрут API без описания и описание без маршрута — отказ сборки
--- документа, и сверка называет их тоже.
---
--- Тело отказа — такой же договор. Каждый отказ в описании обязан
--- стоять на схеме `Refusal`, а образцы отказов ниже проходят через саму
--- панель, и их тела сличаются со схемами (`tools/lib/api_spec.lua`).
--- Поправили вид отказа и забыли форму — сверка это видит, а не клиент.
---
--- Запуск: tarantool tools/check_api_spec.lua [описание]
--- Описание по умолчанию — docs/api/panel.yaml.

local log = require('log')
local yaml = require('yaml')

local api_document = require('tools.lib.api_document')
local api_spec = require('tools.lib.api_spec')

local files = dofile('tools/files.lua')

local SPEC_PATH = arg[1] or api_document.PATH

--- Панель, собранная из исходников оснасткой её же проверок.
---
--- Панель берётся из исходников, а не из `.rocks`: установленная копия
--- пакета знала бы только вчерашний код, и описание сличалось бы с ним.
--- Границу собирает ядро — тем же вызовом, каким её собирает роль
--- панели, — и образцы проходят её целиком.
local panels = dofile('test/helper.lua')

--- Сборка панели: по её роутеру собирается документ.
local panel_http = panels.load('tnt.admin.app.http.panel')

--- Описание операций панели — из той же загрузки исходников.
local api = panels.testing.module('tnt.admin.app.http.openapi')

-- Образцы проходят панель целиком, и её журнал пишет о каждом: о запросе,
-- а о поломке — ошибкой. Поверх итога сверки это шум: поломки заказаны
-- образцами.
log.cfg({ level = 'fatal' })

--- Образец отказа: что спросить у панели и каким источником её настроить.
---@class CheckApiSpecSample: ApiSpecSample
---@field source TntAdminSource Источники панели на время образца
---@field body string|nil Тело запроса

--- Действие, о котором спрашивают образцы ворот.
local ACTION = '{"action":"reload_config","targets":["storage-001-a"]}'

--- Источник, чьи ворота отказали с кодом, — с оценкой, как отказывают
--- ворота `tnt.recovery.gate`.
---@param code string Код ворот
---@return table
local function gate(code)
    return {
        act = function()
            return {
                refused = { code = code, message = 'ворота образца отказали' },
                assessment = { risk = 'dangerous', confirm = { token = 'PURGE storage' } },
            }
        end,
    }
end

--- Образцы отказов: по одному на каждый вид тела и каждую схему отказа.
---
--- Вид тела — это то, что панель дописывает к фразе: разбор полей, код
--- ворот с оценкой, фаза с отчётом раскатки, номер происшествия. Отказ
--- без довесков — любой из прочих: 403, 501 и остальные собирает та же
--- функция тем же видом. `described = 'default'` — код, не названный
--- у операции; `routed = false` — отказ роутера до маршрута.
---@type CheckApiSpecSample[]
local SAMPLES = {
    {
        what = 'тело не JSON',
        method = 'POST',
        path = '/api/v1/actions',
        body = 'не JSON',
        source = {},
        status = 400,
    },
    {
        what = 'разбор по полям',
        method = 'POST',
        path = '/api/v1/actions',
        body = '{"action":"reload_config"}',
        source = {},
        status = 400,
    },
    {
        what = 'состояние изменилось',
        method = 'POST',
        path = '/api/v1/actions',
        body = ACTION,
        source = gate('STALE_FINGERPRINT'),
        status = 409,
    },
    {
        what = 'не выполнено требование',
        method = 'POST',
        path = '/api/v1/actions',
        body = ACTION,
        source = gate('PRECONDITION_FAILED'),
        status = 409,
    },
    {
        what = 'нужно подтверждение',
        method = 'POST',
        path = '/api/v1/actions',
        body = ACTION,
        source = gate('CONFIRMATION_REQUIRED'),
        status = 428,
    },
    {
        what = 'раскатка не закончена',
        method = 'POST',
        path = '/api/v1/config',
        body = '{"text":"credentials: {}"}',
        source = {
            apply_config = function()
                return {
                    phase = 'converge',
                    err = 'правка доехала не до всех',
                    pending = { 'storage' },
                }
            end,
        },
        status = 409,
    },
    {
        what = 'поломка обработчика',
        method = 'GET',
        path = '/api/v1/cluster',
        source = {
            snapshot = function()
                error('поломка, заказанная образцом')
            end,
        },
        status = 500,
        described = 'default',
    },
    {
        what = 'вход не выполнен',
        method = 'GET',
        path = '/api/v1/overview',
        source = {
            -- Вход никого не опознал.
            authorize = function()
                return nil
            end,
        },
        status = 401,
    },
    {
        what = 'нет такого адреса',
        method = 'GET',
        path = '/api/v1/nowhere',
        source = {},
        status = 404,
        routed = false,
    },
    {
        what = 'сюда так нельзя',
        method = 'DELETE',
        path = '/api/v1/cluster',
        source = {},
        status = 405,
        routed = false,
    },
}

local spec = yaml.decode(files.read(SPEC_PATH))
local check = api_spec.check(spec)
local served = panel_http.new({})
local document, drift = api.document(served)

-- Расхождения с кодом печатаются первыми: образец отказа у операции,
-- которой нет в файле, отказывает следом, и причина видна раньше
-- следствия.
local differences = document ~= nil and api_document.differences(spec, document) or drift

for _, problem in ipairs(differences) do
    table.insert(check.problems, problem)
end

--- Операций API у панели: именованные маршруты — её договор с клиентом.
local operations = 0

for _, route in ipairs(served.routes()) do
    if route.name ~= nil then
        operations = operations + 1
    end
end

local schemas = api_spec.refusals(check)

for _, sample in ipairs(SAMPLES) do
    -- Панель собирается на источниках образца: состав маршрутов зависит
    -- от того, что дали, и образец обязан видеть ту панель, которая
    -- получилась бы на узле с такими источниками.
    local panel = panels.panel(sample.source)

    api_spec.answer(check, sample, panel.ask(sample.method, sample.path, sample.body))
end

api_spec.unchecked(check, schemas)

if #check.problems == 0 then
    print(
        ('Описание API совпадает с кодом: операций %d, образцов отказа %d.'):format(
            operations,
            #SAMPLES
        )
    )
    os.exit(0)
end

print(('Описание %s расходится с кодом панели:'):format(SPEC_PATH))

for _, problem in ipairs(check.problems) do
    print('  ' .. problem)
end

-- Файл собран из кода: расхождение с документом чинится пересборкой,
-- а не правкой файла руками.
if document ~= nil and differences[1] ~= nil then
    print('Описание собирается из кода: make api-spec.')
end

os.exit(1)
