--- Описание API как данные: пути, ссылки, ответы отказа и сличение тела
--- отказа со схемой.
---
--- Сличение понимает не весь JSON Schema, а подмножество, которым
--- написаны схемы отказов: `$ref`, `allOf`, `type`, `enum`, `required`,
--- `properties`, `additionalProperties`, `nullable` и пояснения. Ключ,
--- которого оно не понимает, — отказ, а не пропуск: обещание в описании,
--- которого никто не проверяет, расходится с кодом так же молча, как
--- описание без сверки.
---
--- Обратное — тоже отказ: описанное поле, которого не принёс ни один
--- образец. Либо код его больше не шлёт, и описание устарело, либо образцы
--- его не порождают, и у сверки слепое пятно.

local json = require('json')

local Module = {}

--- Схема тела отказа: на ней стоит тело любого отказа панели.
Module.REFUSAL = '#/components/schemas/Refusal'

--- Тип содержимого, под которым описано тело отказа.
local JSON = 'application/json'

--- Способы, которые OpenAPI держит в описании пути.
local METHODS = { 'get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace' }

--- Ключи схемы, которые сличение понимает. Пояснения ничего не требуют,
--- и проверять в них нечего.
---@type table<string, boolean>
local KEYWORDS = {
    ['$ref'] = true,
    allOf = true,
    type = true,
    enum = true,
    required = true,
    properties = true,
    additionalProperties = true,
    nullable = true,
    description = true,
    example = true,
}

--- Чем узнаётся значение каждого типа.
---
--- Объект от массива отличает разметка разбора: `json.decode` помечает
--- массив `__serialize = 'seq'`, а пустые `{}` и `[]` без неё неотличимы.
local KINDS = {
    object = function(value)
        return type(value) == 'table' and (getmetatable(value) or {}).__serialize ~= 'seq'
    end,
    string = function(value)
        return type(value) == 'string'
    end,
    integer = function(value)
        return type(value) == 'number' and math.floor(value) == value
    end,
}

---@class ApiSpecCheck
---@field spec table Описание целиком: по нему разрешаются ссылки
---@field seen table<table, boolean> Узлы схем, через которые прошло хоть одно значение
---@field said table<string, boolean> Что уже записано
---@field problems string[] Что не сошлось, в порядке находки

---@class ApiSpecSample
---@field what string Что за отказ: им образец назван в отказе сверки
---@field method string Способ запроса заглавными
---@field path string Путь запроса целиком, без строки запроса
---@field status integer Каким кодом панель обязана ответить
---@field described string|nil Под каким ответом описан отказ, если не под своим кодом: `default`
---@field routed boolean|nil `false` — отказ роутера до маршрута; сличается с самой `Refusal`

--- Ключи таблицы по порядку: сверка печатает отказы в одном порядке
--- от прогона к прогону.
---@param map table
---@return any[]
local function sorted(map)
    local keys = {}

    for key in pairs(map) do
        keys[#keys + 1] = key
    end

    table.sort(keys)

    return keys
end

--- Записывает несошедшееся, если его ещё не записали.
---
--- Одно расхождение находят несколько образцов, а печатать его надо раз.
---@param check ApiSpecCheck
---@param template string
---@param ... any
local function say(check, template, ...)
    local message = template:format(...)

    if not check.said[message] then
        check.said[message] = true

        table.insert(check.problems, message)
    end
end

--- Заводит сверку по описанию.
---@param spec table
---@return ApiSpecCheck
function Module.check(spec)
    return { spec = spec, seen = {}, said = {}, problems = {} }
end

--- Откуда считается путь: общий сервер описания или свой у пути.
---
--- Своим обзаводится тот, кто живёт вне API: выкладка метрик — договор
--- со сборщиком, а не часть панели, и префикса версии у неё нет.
---@param spec table
---@param item table Описание пути
---@return string
local function base_of(spec, item)
    local servers = item.servers or spec.servers or {}
    local url = servers[1] ~= nil and tostring(servers[1].url) or ''

    -- Косая черта в конце сложилась бы с косой чертой пути в двойную.
    return (url:gsub('/$', ''))
end

--- Описанные пути целиком, от сервера: путь → его описание.
---@param spec table
---@return table<string, table>
function Module.paths(spec)
    local found = {}

    for path, item in pairs(spec.paths or {}) do
        found[base_of(spec, item) .. path] = item
    end

    return found
end

--- Операции описания по порядку пути и способа.
---@param spec table
---@return { where: string, operation: table }[]
local function operations(spec)
    local found = {}
    local paths = Module.paths(spec)

    for _, route in ipairs(sorted(paths)) do
        for _, method in ipairs(METHODS) do
            local operation = paths[route][method]

            if operation ~= nil then
                table.insert(found, { where = method:upper() .. ' ' .. route, operation = operation })
            end
        end
    end

    return found
end

--- Узел описания по ссылке `#/…`; nil — ссылка никуда не ведёт.
---
--- Ссылки бывают только внутрь описания: чужих файлов сверка не читает.
---@param spec table
---@param ref any
---@return any
function Module.resolve(spec, ref)
    local rest = tostring(ref):match('^#/(.*)$')

    if rest == nil then
        return nil
    end

    local node = spec

    for name in rest:gmatch('[^/]+') do
        if type(node) ~= 'table' then
            return nil
        end

        node = node[name]
    end

    return node
end

--- Схема, которой описано тело ответа в JSON: ссылка либо схема по месту.
--- Ответ и сам бывает ссылкой — на общий ответ из `components/responses`.
---@param spec table
---@param response table
---@return table|nil
local function body_schema(spec, response)
    local resolved = Module.resolve(spec, response['$ref']) or response
    local media = (resolved.content or {})[JSON] or {}

    return media.schema
end

--- Именованные схемы, на которых стоит схема: по ссылкам и частям `allOf`.
---
--- Ссылка запоминается до того, как по ней пойти: схема, стоящая сама
--- на себе, иначе обходилась бы без конца.
---@param spec table
---@param schema any
---@param found table<string, boolean> Сюда складываются найденные ссылки
local function standing(spec, schema, found)
    if type(schema) == 'table' then
        local ref = schema['$ref']

        if ref ~= nil and not found[ref] then
            found[ref] = true

            standing(spec, Module.resolve(spec, ref), found)
        end

        for _, part in ipairs(schema.allOf or {}) do
            standing(spec, part, found)
        end
    end
end

--- Именованные схемы, до которых доходят из схемы: те, на которых она
--- стоит, и те, что стоят в её полях, — `RefusalError` в поле `error`.
---
--- Сверка обходит их все: описанное поле вложенной схемы, которого
--- не принёс ни один образец, — такое же расхождение, как поле самой
--- схемы тела.
---@param spec table
---@param schema any
---@param found table<string, boolean> Сюда складываются найденные ссылки
local function nested(spec, schema, found)
    if type(schema) == 'table' then
        local ref = schema['$ref']

        if ref ~= nil and not found[ref] then
            found[ref] = true

            nested(spec, Module.resolve(spec, ref), found)
        end

        for _, part in ipairs(schema.allOf or {}) do
            nested(spec, part, found)
        end

        for _, name in ipairs(sorted(schema.properties or {})) do
            nested(spec, schema.properties[name], found)
        end

        nested(spec, schema.additionalProperties, found)
    end
end

--- Ответ ли это отказа: код 4xx, 5xx — и числом, и диапазоном `4XX` —
--- или `default`.
---@param code string
---@return boolean
local function refusing(code)
    return code == 'default' or code:match('^[45]') ~= nil
end

--- Сверяет, что каждый отказ описан телом, стоящим на `Refusal`.
---
--- Тело отказа — ссылка на схему либо схема по месту, которая уточняет
--- `Refusal` через `allOf`: код ворот у отказа ворот — один из названных.
--- Сверка обходит целиком и тело по месту, и все именованные схемы,
--- до которых из тела доходят ссылки, и видит в них и непонятый ключ,
--- и поле, которого не принёс ни один образец. Ответ `default` обязателен
--- у каждой операции: поломка обработчика отвечает 500 на любом пути.
---@param check ApiSpecCheck
---@return table<string, table|true> schemas Схемы отказов: ссылка → true, тело по месту «СПОСОБ путь код» → схема
function Module.refusals(check)
    local schemas = {}

    for _, entry in ipairs(operations(check.spec)) do
        -- Код ответа в YAML пишется строкой, но число без кавычек
        -- разбирается числом: ключи приводятся к одному виду.
        local codes = {}

        for code, response in pairs(entry.operation.responses or {}) do
            codes[tostring(code)] = response
        end

        if codes.default == nil then
            say(
                check,
                '%s: нет ответа default, а поломка обработчика отвечает 500 телом Refusal',
                entry.where
            )
        end

        for _, code in ipairs(sorted(codes)) do
            if refusing(code) then
                -- Тело без схемы ни на чём не стоит: сверка скажет об этом ниже.
                local body = body_schema(check.spec, codes[code]) or {}
                local found = {}

                standing(check.spec, body, found)

                if found[Module.REFUSAL] then
                    nested(check.spec, body, schemas)

                    if body['$ref'] == nil then
                        schemas[('%s %s'):format(entry.where, code)] = body
                    end
                else
                    say(
                        check,
                        '%s %s: тело отказа не ссылается на схему, стоящую на Refusal',
                        entry.where,
                        code
                    )
                end
            end
        end
    end

    return schemas
end

--- Есть ли значение в перечне.
---@param list any[]
---@param value any
---@return boolean
local function listed(list, value)
    local found = false

    for _, item in ipairs(list) do
        found = found or item == value
    end

    return found
end

--- Сверяет поля объекта: обязательные на месте, описанные — по своим
--- схемам, прочие — по схеме прочих полей, а там, где прочих нет, — отказ.
---@param check ApiSpecCheck
---@param schema table
---@param value table
---@param where string
local function members(check, schema, value, where)
    for _, name in ipairs(schema.required or {}) do
        if value[name] == nil then
            say(check, '%s: нет обязательного поля %s', where, name)
        end
    end

    local described = schema.properties or {}
    local others = schema.additionalProperties

    for _, name in ipairs(sorted(value)) do
        local inner = where .. '.' .. name

        if described[name] ~= nil then
            Module.validate(check, described[name], value[name], inner)
        elseif type(others) == 'table' then
            Module.validate(check, others, value[name], inner)
        elseif others == false then
            say(check, '%s: поле не описано', inner)
        end
    end
end

--- Сличает значение со схемой; несошедшееся дописывает в сверку.
---
--- Каждый узел схемы, через который прошло значение, помечается: по этим
--- пометкам `unchecked` находит описанное, но ни разу не пришедшее.
---@param check ApiSpecCheck
---@param schema table
---@param value any
---@param where string Где значение: образец и путь в теле
function Module.validate(check, schema, value, where)
    check.seen[schema] = true

    -- `null` на месте необязательного поля — то же, что его отсутствие.
    if value == nil and schema.nullable then
        return
    end

    local ref = schema['$ref']

    if ref ~= nil then
        local target = Module.resolve(check.spec, ref)

        if type(target) ~= 'table' then
            return say(check, '%s: ссылка %s никуда не ведёт', where, ref)
        end

        Module.validate(check, target, value, where)
    end

    for _, part in ipairs(schema.allOf or {}) do
        Module.validate(check, part, value, where)
    end

    local kind = KINDS[schema.type]

    if kind ~= nil and not kind(value) then
        return say(check, '%s: ждали %s, пришло %s', where, schema.type, json.encode(value))
    end

    if schema.enum ~= nil and not listed(schema.enum, value) then
        say(
            check,
            '%s: значения %s нет среди %s',
            where,
            json.encode(value),
            table.concat(schema.enum, ', ')
        )
    end

    if KINDS.object(value) then
        members(check, schema, value, where)
    end
end

--- Схема, которой описан ответ образца у его операции.
---
--- Код ищется таким, каким он написан у образца: образец, описанный только
--- ответом `default`, называет это сам. Иначе код, пропавший из описания,
--- молча сличался бы с `default`, и расхождение прошло бы незамеченным.
---@param spec table
---@param sample ApiSpecSample
---@return table|nil schema
---@return string|nil reason Почему схемы нет
local function schema_for(spec, sample)
    local operation = (Module.paths(spec)[sample.path] or {})[sample.method:lower()]

    if operation == nil then
        return nil, 'операция не описана'
    end

    local code = sample.described or tostring(sample.status)
    local response = (operation.responses or {})[code]

    if response == nil then
        return nil, ('ответ %s не описан'):format(code)
    end

    local schema = body_schema(spec, response)

    if schema == nil then
        return nil, ('тело ответа %s не описано схемой'):format(code)
    end

    return schema
end

--- Сверяет ответ панели на образец с описанием: код, тип содержимого,
--- тело по схеме.
---@param check ApiSpecCheck
---@param sample ApiSpecSample
---@param response table Ответ панели: `status`, `headers`, `body`
function Module.answer(check, sample, response)
    local where = ('%s %s (%s)'):format(sample.method, sample.path, sample.what)

    if response.status ~= sample.status then
        return say(
            check,
            '%s: ждали код %d, панель ответила %d',
            where,
            sample.status,
            response.status
        )
    end

    -- Параметры типа — `charset` — к описанию тела не относятся.
    local media = tostring(response.headers['content-type'])

    if media:split(';')[1] ~= JSON then
        return say(check, '%s: тип содержимого %s, а описан %s', where, media, JSON)
    end

    local decoded, body = pcall(json.decode, response.body)

    if not decoded then
        return say(check, '%s: тело не JSON', where)
    end

    local schema, reason

    if sample.routed == false then
        -- Роутер отказал до маршрута: операции у такого отказа нет,
        -- а тело у него то же, что у любого отказа панели.
        schema = { ['$ref'] = Module.REFUSAL }
    else
        schema, reason = schema_for(check.spec, sample)
    end

    if schema == nil then
        return say(check, '%s: %s', where, reason)
    end

    Module.validate(check, schema, body, where .. ', тело')
end

--- Узлы схемы с их местом: сама схема, части `allOf`, свойства и схема
--- прочих полей. По ссылкам обход не идёт: схему, на которую ссылаются,
--- обходят под её собственным именем.
---@param schema table
---@param path string
---@param found { node: table, path: string }[]
local function nodes(schema, path, found)
    table.insert(found, { node = schema, path = path })

    for _, part in ipairs(schema.allOf or {}) do
        nodes(part, path, found)
    end

    for _, name in ipairs(sorted(schema.properties or {})) do
        nodes(schema.properties[name], path .. '.' .. name, found)
    end

    if type(schema.additionalProperties) == 'table' then
        nodes(schema.additionalProperties, path .. '.*', found)
    end
end

--- Что в схемах отказов осталось непроверенным: ключ и тип, которых
--- сличение не понимает, и узел, через который не прошло ни одно значение.
---@param check ApiSpecCheck
---@param schemas table<string, table|true> Схемы отказов, как их отдаёт `refusals`
function Module.unchecked(check, schemas)
    for _, name in ipairs(sorted(schemas)) do
        local inline = schemas[name]
        local root = inline == true and Module.resolve(check.spec, name) or inline
        local found = {}

        if type(root) ~= 'table' then
            say(check, '%s: ссылка никуда не ведёт', name)
        elseif inline == true then
            -- Именованная схема называется последним звеном ссылки.
            local links = name:split('/')

            nodes(root, links[#links], found)
        else
            nodes(root, name, found)
        end

        for _, entry in ipairs(found) do
            for _, key in ipairs(sorted(entry.node)) do
                if not KEYWORDS[key] then
                    say(check, '%s: ключ %s сличение не понимает', entry.path, key)
                end
            end

            if entry.node.type ~= nil and KINDS[entry.node.type] == nil then
                say(check, '%s: тип %s сличение не понимает', entry.path, entry.node.type)
            end

            if not check.seen[entry.node] then
                say(check, '%s: не пришло ни в одном образце отказа', entry.path)
            end
        end
    end
end

return Module
