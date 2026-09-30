--- Отбор узлов по конфигурации: `GET /api/v1/instances`.
---
--- Какие узлы объявлены конфигурацией кластера — группы, репликасеты,
--- имена, роли, роли шардирования, метки, — отбирает диагностика
--- (`tnt.cluster.filter`), а панель переводит строку запроса в отбор
--- и отдаёт найденное. Это чтение объявленного, а не применённого: оно
--- никого не соединяет и узлы не опрашивает. Что узлы применили и живы ли
--- они, говорит `/cluster` по снимку обхода.
---
--- Отбор приходит снаружи, строкой запроса, и панель его не дописывает:
--- списки — через запятую, метки — по одной, со скобками.
---
---     GET /api/v1/instances?groups=storages&sharding_roles=storage&labels[zone]=spb
---
--- Группы, репликасеты и имена читаются как «любой из», роли и метки —
--- как «все сразу»: так их читает диагностика, и отбор уходит к ней без
--- перевода.
---
--- Незнакомый параметр, повтор и пустое имя в списке — отказ с разбором
--- по полям, а не пропуск. Отбор сужает ответ, и потерянное условие молча
--- его расширило бы: скрипт, который выбирает узлы для действия, получил
--- бы весь кластер вместо трёх узлов.
---
--- Роли шардирования панель не сверяет: какие из них отбор понимает, знает
--- диагностика, и её отказ — ребалансировщика по конфигурации не найти,
--- роль незнакома — уходит оператору её же словами.

local router = require('tnt.router')

local refusals = require('tnt.admin.app.exceptions.refusal')

local Module = {}

--- Параметры-списки по порядку: имя в строке запроса — оно же поле отбора.
---
--- Списком, а не набором: по нему же собирается перечень знакомых
--- в отказе, и порядок в нём не должен меняться от запуска к запуску.
local LISTS = { 'groups', 'replicasets', 'instances', 'roles', 'sharding_roles' }

--- Те же параметры набором: имя → да.
---@type table<string, boolean>
local LISTED = {}

for _, name in ipairs(LISTS) do
    LISTED[name] = true
end

--- Метка в строке запроса: `labels[имя]`.
---
--- Имя метки берётся целиком, со всеми знаками: метки называет
--- развёртывание, и точка или косая черта в имени — обычное дело.
local LABEL = '^labels%[(.+)%]$'

--- Отказ незнакомому параметру: он же называет знакомые.
local UNKNOWN = ('такого отбора нет: есть %s и labels[имя]'):format(table.concat(LISTS, ', '))

--- Отказ повторённому параметру.
---
--- Какое из двух значений имели в виду, не угадать, а сложить их молча
--- значит решить за клиента, «или» он хотел или «и».
local REPEATED =
    'параметр повторён: значения списка пишутся через запятую, метка задаётся один раз'

--- Отказ пустому имени в списке.
---
--- Пустой список отбор читает как «без ограничения», и `groups=` вернул бы
--- весь кластер. Пустых имён у узлов, групп и ролей не бывает, так что
--- пустое имя в списке — всегда опечатка.
local EMPTY =
    'пустое имя в списке: имена пишутся через запятую без пропусков'

--- Словарь для JSON: пустой иначе ушёл бы списком `[]`.
local MAP = { __serialize = 'map' }

--- Список из значения через запятую.
---@param value string
---@return string[]|nil items
---@return string|nil reason
local function listed(value)
    local items = value:split(',')

    for _, item in ipairs(items) do
        if item == '' then
            return nil, EMPTY
        end
    end

    return items
end

--- Отбор из строки запроса.
---
--- Разбор сразу по всем параметрам, а не до первого негодного: клиент
--- правит адрес один раз, а не по параметру за запрос.
---@param query table<string, any> Строка запроса, разобранная роутером
---@return TntClusterSelector|nil selector
---@return table<string, string>|nil wrong Параметр, как его написал клиент, → что с ним не так
function Module.selector(query)
    local selector, wrong = {}, {}

    for name, value in pairs(query) do
        local label = name:match(LABEL)

        if type(value) ~= 'string' then
            -- Роутер отдаёт повторённый параметр списком значений.
            wrong[name] = REPEATED
        elseif LISTED[name] then
            selector[name], wrong[name] = listed(value)
        elseif label ~= nil then
            selector.labels = selector.labels or {}
            selector.labels[label] = value
        else
            wrong[name] = UNKNOWN
        end
    end

    if next(wrong) ~= nil then
        return nil, wrong
    end

    return selector
end

--- Узел в ответе: поля одного рода у каждого.
---
--- Конфигурация молчит о ролях и метках, которых узлу не объявили, и поле
--- пропало бы из ответа, а пустые метки JSON отдал бы списком. Клиент же
--- читает у каждого узла одно и то же: роли — списком, метки — словарём.
---@param instance TntClusterInstance
---@return table
local function shaped(instance)
    local labels = setmetatable({}, MAP)

    for name, value in pairs(instance.labels or {}) do
        labels[name] = value
    end

    return {
        name = instance.name,
        replicaset_name = instance.replicaset_name,
        group_name = instance.group_name,
        roles = instance.roles or {},
        sharding_roles = instance.sharding_roles or {},
        labels = labels,
    }
end

--- Узлы конфигурации по отбору из строки запроса.
---@param request table
---@param source TntAdminSource
---@return table
local function chosen(request, source)
    local selector, wrong = Module.selector(request.query)

    if selector == nil then
        return refusals.refuse('bad_filter', { details = { fields = wrong } })
    end

    if source.filter == nil then
        return refusals.refuse('filter_disabled')
    end

    local instances, reason = source.filter(selector)

    if instances == nil then
        return refusals.refuse('filter_failed', { reason = reason })
    end

    local answer = {}

    for _, instance in ipairs(instances) do
        table.insert(answer, shaped(instance))
    end

    return router.json({ instances = answer })
end

--- Объявляет маршрут отбора в группе API панели.
---
--- Права отдельного нет: отбор показывает то же, что и состав кластера, —
--- имена, роли и метки узлов, — и видеть его вправе всякий вошедший.
--- Учётных записей и адресов в ответе нет.
---@param r TntRouter Группа API панели: опознание уже стоит слоем
---@param source TntAdminSource
function Module.declare(r, source)
    r.get('/instances', function(request)
        return chosen(request, source)
    end, { name = 'instances' })
end

return Module
