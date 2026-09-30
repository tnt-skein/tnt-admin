--- Описание API панели как собранный документ: сборка из кода панели,
--- запись файлом и сличение файла с документом.
---
--- `docs/api/panel.yaml` не пишут руками: документ OpenAPI собирает
--- `tnt-openapi` из маршрутов панели, форм `tnt-data` и слов операций
--- (`tnt.admin.app.http.openapi`), а файл — его запись. Сверка сличает
--- файл с документом, собранным заново, таблицами, а не текстом: порядок
--- ключей и перенос строк смысла не несут.
---
--- Запись идёт своей, а не встроенным `yaml.encode`: тот пишет ключи
--- в порядке обхода таблицы, и файл, собранный заново после правки одного
--- слова, переставлял бы соседние ключи — в разнице правки было бы
--- не найти самой правки. Здесь порядок постоянный: сначала ключи,
--- которые OpenAPI читает первыми, затем остальные по алфавиту.

local json = require('json')
local yaml = require('yaml')

local Module = {}

--- Где лежит описание в дереве.
Module.PATH = 'docs/api/panel.yaml'

--- Шапка файла: YAML её не разбирает, а человек читает первой.
Module.HEADER = [[
# Описание HTTP-API панели — собранное, а не написанное.
#
# Файл пишет `make api-spec` (tools/build_api_spec.lua): документ OpenAPI
# собирает `tnt-openapi` из маршрутов панели, форм `tnt-data`
# (tnt/admin/app/data пакета tnt-admin) и слов операций
# (tnt/admin/app/http/openapi.lua и openapi/). Руками его не правят:
# `make lint-api` сличает файл с документом, собранным заново, и правка
# формы или слова без пересборки файла роняет сверку.
#
# Тело отказа — тоже договор: сверка прогоняет через панель образцы
# отказов — свой, с разбором полей, ворот, раскатки, поломки, роутера —
# и сличает их тела со схемами (tools/check_api_spec.lua).
]]

--- Ключи, которые идут первыми, в этом порядке; остальные — по алфавиту.
---
--- Порядок — тот, в котором документ читают: корень — версия, сведения,
--- серверы, пути; сервер — адрес; операция — слова, опознаватель,
--- параметры, тело, ответы; параметр — имя и место; схема — слова, тип,
--- обязательные поля.
local FIRST = {
    'openapi',
    'info',
    'servers',
    'paths',
    'components',
    'title',
    'version',
    'url',
    'summary',
    'operationId',
    'name',
    'in',
    'description',
    'type',
    'format',
    'required',
    'style',
    'explode',
    'parameters',
    'requestBody',
    'responses',
    'content',
    'schema',
    'items',
    'properties',
    'additionalProperties',
}

--- Место ключа среди первых.
---@type table<string, integer>
local RANK = {}

for place, key in ipairs(FIRST) do
    RANK[key] = place
end

--- Разметки пустого словаря: встроенные кодировщики пишут его `{}`.
local MAPPINGS = { map = true, mapping = true }

--- Ключи словаря в порядке записи.
---@param map table
---@return any[]
local function ordered(map)
    local keys = {}

    for key in pairs(map) do
        table.insert(keys, key)
    end

    table.sort(keys, function(left, right)
        local a, b = RANK[left] or #FIRST + 1, RANK[right] or #FIRST + 1

        if a ~= b then
            return a < b
        end

        return tostring(left) < tostring(right)
    end)

    return keys
end

--- Список ли это: ключи — ровно 1…n.
---
--- Пустой список от пустого словаря отличает только разметка; без неё
--- пустая таблица пишется списком, как её пишет встроенный кодировщик.
---@param value table
---@return boolean
local function is_list(value)
    if next(value) == nil then
        return not MAPPINGS[(getmetatable(value) or {}).__serialize]
    end

    local count = 0

    for _ in pairs(value) do
        count = count + 1
    end

    return count == #value
end

--- Запись значения без таблиц: строки, числа, логические значения.
---
--- Кавычки и перенос строк решает встроенный кодировщик, а продолжения
--- строк сдвигаются на отступ места: иначе строка, перенесённая
--- кодировщиком, выпала бы из своего ключа.
---@param value any
---@param indent string Отступ ключа или черты списка, за которыми стоит значение
---@return string
local function scalar(value, indent)
    local text = yaml.encode(value):gsub('^%-%-%- ?', ''):gsub('\n%.%.%.\n$', '')

    if text == '' then
        return "''"
    end

    -- Пустая строка внутри блока остаётся пустой: отступ на ней — лишние
    -- пробелы в конце строки, а смысла у него нет.
    return (text:gsub('\n([^\n])', '\n' .. indent .. '%1'))
end

--- Пустая таблица одной строкой.
---@param value table
---@return string
local function empty(value)
    return is_list(value) and '[]' or '{}'
end

---@type fun(value: table, indent: string, out: string[])
local block

--- Строки одного значения за ключом или чертой списка.
---@param head string Ключ с двоеточием либо черта списка — с отступом
---@param value any
---@param indent string Отступ ключа или черты
---@param out string[]
local function entry(head, value, indent, out)
    if type(value) ~= 'table' then
        return table.insert(out, head .. ' ' .. scalar(value, indent))
    end

    if next(value) == nil then
        return table.insert(out, head .. ' ' .. empty(value))
    end

    table.insert(out, head)
    block(value, indent .. '  ', out)
end

--- Строки непустой таблицы с отступом.
---@param value table
---@param indent string
---@param out string[]
function block(value, indent, out)
    if not is_list(value) then
        for _, key in ipairs(ordered(value)) do
            entry(indent .. scalar(key, indent) .. ':', value[key], indent, out)
        end

        return
    end

    for _, item in ipairs(value) do
        ---@type string[]
        local inner = {}

        entry(indent .. '-', item, indent, inner)

        -- Таблица под чертой начинается на той же строке: первая строка
        -- вложенного переезжает к черте, остальные уже стоят на её отступе.
        if type(item) == 'table' and next(item) ~= nil then
            local first = inner[2] --[[@as string]]

            inner[2] = indent .. '- ' .. first:sub(#indent + 3)
            table.remove(inner, 1)
        end

        for _, line in ipairs(inner) do
            table.insert(out, line)
        end
    end
end

--- Текст файла описания: шапка и документ с постоянным порядком ключей.
---@param document table
---@return string
function Module.render(document)
    local lines = {}

    block(document, '', lines)

    return Module.HEADER .. table.concat(lines, '\n') .. '\n'
end

--- Шаг пути к значению: имя поля, строка в скобках или номер.
---@param key any
---@return string
local function step(key)
    if type(key) == 'number' then
        return ('[%d]'):format(key)
    end

    if tostring(key):match('^[%a_][%w_]*$') then
        return '.' .. key
    end

    return ('[%q]'):format(tostring(key))
end

--- Значение для отказа сличения.
---@param value any
---@return string
local function shown(value)
    if value == nil then
        return 'ничего'
    end

    if type(value) == 'table' then
        return 'таблица'
    end

    -- Записью JSON: строка — в кавычках и с переводами строк знаками `\n`,
    -- а число и логическое значение — без кавычек, и строку «1» от числа 1
    -- видно сразу.
    return json.encode(value)
end

--- Ключи обеих таблиц по порядку.
---@param left table
---@param right table
---@return any[]
local function union(left, right)
    local keys, seen = {}, {}

    for _, side in ipairs({ left, right }) do
        for key in pairs(side) do
            if not seen[key] then
                seen[key] = true

                table.insert(keys, key)
            end
        end
    end

    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    return keys
end

--- Где файл описания расходится с документом, собранным из кода.
---
--- Место называется самым верхним узлом, где разошлось: путь, которого
--- в файле нет вовсе, — одной строкой, а не строкой на каждый его лист.
---@param file any Документ из файла, разобранный YAML
---@param code any Документ, собранный заново
---@return string[] differences Пусто — сошлось
function Module.differences(file, code)
    local found = {}

    local function walk(left, right, path)
        if type(left) == 'table' and type(right) == 'table' then
            for _, key in ipairs(union(left, right)) do
                walk(left[key], right[key], path .. step(key))
            end
        elseif left ~= right then
            table.insert(
                found,
                ('%s: в описании %s, в коде %s'):format(path:gsub('^%.', ''), shown(left), shown(right))
            )
        end
    end

    walk(file, code, '')

    return found
end

return Module
