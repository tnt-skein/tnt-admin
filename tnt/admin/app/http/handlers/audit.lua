--- Журнал аудита в панели: выгрузка потоком и проверка цепочки.
---
--- До этих маршрутов прочитать журнал и проверить его цепочку можно было
--- только по iproto учётной записью со всеми правами — `eval` под super.
--- То есть ровно тем правом, которым журнал и подделывают: при разборе
--- происшествия за журналом шли к тому же человеку и с тем же ключом, что
--- и подозреваемый. Здесь на чтение журнала своё право — способность
--- `audit.read` ворот панели, которую даёт признак `audit` в личности, —
--- и выдаёт его приложение, а не роль на узле. Право отдельное и от
--- «менять кластер»: аудитору менять нечего, а тот, кто меняет, не обязан
--- читать журнал о себе. Спрашивает его слой `can` на обоих маршрутах
--- (`tnt.admin.app.http.middleware.can`), до разбора строки запроса.
---
--- `GET /audit` — выгрузка потоком (`router.stream`, `Transfer-Encoding:
--- chunked`): NDJSON, строка на запись, тем же видом, что уезжает в приёмник
--- вывоза, с обоими хешами — принявший проходит цепочку сам. Отбор — участок
--- номеров `from_id`…`to_id`, оба включительно; продолжить оборванную
--- выгрузку — `from_id` на единицу больше номера последней принятой строки.
--- В памяти узла на выгрузку лежит один кусок, а медленный клиент тормозит
--- источник. Обратный прокси об этом просят заголовком `x-accel-buffering:
--- no`: иначе он вычитывает журнал с узла целиком, как бы медленно ни читал
--- клиент (документ `tnt-router`, «Выход в сеть»). Отказ источника посреди
--- выгрузки рвёт соединение без завершающего куска: обрезанная выгрузка
--- не должна выглядеть целой.
---
--- `GET /audit/verify` — проверка цепочки на узле (`tnt.audit.verify`)
--- с бюджетом записей за запрос. Кончился бюджет — в отчёте курсор,
--- и следующий запрос продолжает с него: `after_id` и `hash` из курсора.
--- Журнал в миллионы записей проверяется минутами, а столько не ждут
--- ни прокси, ни браузер.
---
--- Откуда журнал, панель не знает: выгрузку и проверку отдаёт приложение
--- источниками `audit` и `audit_verify` — обычно `tnt.audit.stream.open`
--- и `tnt.audit.verify.run`. Пакета журнала панель поэтому не тянет.

local router = require('tnt.router')
local validate = require('tnt.validate')

local refusals = require('tnt.admin.app.exceptions.refusal')
local can = require('tnt.admin.app.http.middleware.can')

local Module = {}

--- Источник кусков потока: следующий кусок, nil — конец, nil, err — обрыв.
---@alias TntAdminAuditProduce fun(): string|nil, string|nil

--- Выгрузка журнала: источник кусков по участку номеров либо отказ.
---
--- Участок — `{ from_id, to_id }`, оба номера включительно и оба
--- необязательны. Аргумент назван просто таблицей: так под него подходит
--- `tnt.audit.stream.open` со своим классом настроек, а класс участка
--- здесь проверка типов сочла бы другим.
---@alias TntAdminAuditExport fun(range: table): TntAdminAuditProduce|nil, string|nil

--- Проверка цепочки: аргументы и отчёт — как у `tnt.audit.verify.run`.
---@alias TntAdminAuditVerify fun(opts: table): table|nil, string|nil

--- Заголовки выгрузки.
---
--- Тип — NDJSON: строка на запись, каждую разбирают отдельно, и оборванная
--- выгрузка годится до последней целой строки. Прокси просят не копить
--- поток, иначе обратное давление теряется на нём.
local EXPORT_HEADERS = {
    ['content-type'] = 'application/x-ndjson; charset=utf-8',
    ['x-accel-buffering'] = 'no',
}

--- Больше номера записи не принимается: четырнадцать знаков.
---
--- Номер — целое без знака, а числа Lua — с плавающей точкой: выше 2^53
--- целые идут через одно, и номер из строки запроса молча стал бы
--- соседним, а за пределом целых без знака выборка box и вовсе отказала бы
--- посреди выгрузки. Такой отбор отвергается сразу. Предел взят ниже 2^53
--- и круглым числом знаков затем, что его печатает отказ: 2^53 число
--- Lua показывает как «9.007199254741e+15». Журналу, в который пишут тысячу
--- записей в секунду, до предела три тысячи лет.
local LARGEST_ID = 10 ^ 14 - 1

--- Сколько записей проверяется за запрос, и больше не дают.
---
--- Около полутора секунд счёта (пересчёт хеша — около 30 мкс на запись):
--- с запасом внутри срока ожидания прокси и терпения человека. Дальше —
--- курсором, следующим запросом.
local VERIFY_BUDGET = 50000

--- Номер записи из строки запроса.
local ID = validate.integer({ min = 1, max = LARGEST_ID, optional = true })

--- Что выгрузка понимает в строке запроса.
local RANGE = { from_id = ID, to_id = ID }

--- Что проверка понимает в строке запроса.
local CHECKUP = {
    from_id = ID,
    to_id = ID,
    after_id = ID,
    hash = validate.string({ pattern = '^%x+$', optional = true }),
    budget = validate.integer({ min = 1, max = VERIFY_BUDGET, default = VERIFY_BUDGET }),
}

--- Настройки разбора строки запроса.
---
--- В строке запроса всё — строка, и числа приводятся. Лишние поля
--- выбрасываются, а не отвергаются: браузер и прокси дописывают свои
--- (метку от кэша), и выгрузка не должна о них ломаться.
local QUERY = { coerce = true, unknown = 'drop' }

--- Разбирает строку запроса к журналу.
---@param request table
---@param schema table Что ждать в строке запроса
---@return table|nil asked Разобранная строка запроса
---@return table|nil refusal Готовый ответ об отказе
local function asked_of(request, schema)
    local asked, wrong = validate.check(request.query, schema, QUERY)

    if wrong ~= nil then
        return nil, refusals.refuse('bad_audit', { details = { fields = wrong } })
    end

    return asked
end

--- Выгружает журнал потоком.
---@param request table
---@param source TntAdminSource
---@return table
local function export(request, source)
    local range, refusal = asked_of(request, RANGE)

    if range == nil then
        return refusal --[[@as table]]
    end

    if source.audit == nil then
        return refusals.refuse('audit_disabled')
    end

    local produce, reason = source.audit(range)

    if produce == nil then
        return refusals.refuse('audit_failed', { reason = reason })
    end

    return router.stream(produce, 200, EXPORT_HEADERS)
end

--- Где запрос проверки противоречит сам себе.
---
--- Курсор продолжает проверку с места, а `from_id` начинает её заново:
--- вместе проверка журнала их отвергает броском, как ошибку программиста,
--- а здесь это ошибка клиента. Хеш без номера курсора молча начал бы
--- проверку с начала журнала — клиент хотел другого.
---@param asked table
---@return table<string, string>|nil
local function contradiction(asked)
    if asked.after_id ~= nil and asked.from_id ~= nil then
        return {
            after_id = 'курсор не задаётся вместе с from_id: он сам знает, откуда продолжать',
        }
    end

    if asked.hash ~= nil and asked.after_id == nil then
        return { hash = 'хеш курсора задаётся только вместе с after_id' }
    end

    return nil
end

--- Проверяет цепочку журнала.
---
--- Порванная цепочка — это ответ 200 с `ok = false`, а не отказ: проверка
--- сделала своё дело. Отказ — когда ответа нет: журнала нет, очистка
--- обогнала проверку.
---@param request table
---@param source TntAdminSource
---@return table
local function verify(request, source)
    local asked, refusal = asked_of(request, CHECKUP)

    if asked == nil then
        return refusal --[[@as table]]
    end

    local wrong = contradiction(asked)

    if wrong ~= nil then
        return refusals.refuse('bad_audit', { details = { fields = wrong } })
    end

    if source.audit_verify == nil then
        return refusals.refuse('audit_disabled')
    end

    local cursor = nil

    if asked.after_id ~= nil then
        cursor = { after_id = asked.after_id, hash = asked.hash }
    end

    local report, reason = source.audit_verify({
        from_id = asked.from_id,
        to_id = asked.to_id,
        budget = asked.budget,
        cursor = cursor,
    })

    if report == nil then
        return refusals.refuse('audit_failed', { reason = reason })
    end

    return router.json(report)
end

--- Объявляет маршруты журнала в группе API панели.
---
--- Источники берутся те, что действуют при объявлении: настройка панели
--- собирает маршруты заново.
---@param r TntRouter Группа API панели: опознание уже стоит слоем
---@param source TntAdminSource
---@param gate TntPermissionsGate Ворота прав панели
function Module.declare(r, source, gate)
    local read = { can.layer(gate, can.AUDIT) }

    r.get('/audit', function(request)
        return export(request, source)
    end, { name = 'audit.export', middleware = read })

    r.get('/audit/verify', function(request)
        return verify(request, source)
    end, { name = 'audit.verify', middleware = read })
end

return Module
