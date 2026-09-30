--- Тесты прав панели: ворота, перевод личности в роли и слой `can`.
---
--- Ворота настоящие, исходниками `tnt-permissions`: кому что можно — стык
--- панели с воротами, и двойник ворот показал бы лишь то, что панель
--- правильно разговаривает сама с собой.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.http.middleware.can')

--- Права панели из той же загрузки, что и остальные её части.
---@type any
local can

--- Ворота, собранные заново на каждую проверку.
---@type TntPermissionsGate
local gate

g.before_each(function()
    can = helper.load('tnt.admin.app.http.middleware.can')
    gate = can.gate()
end)

g.after_each(function()
    helper.unload()
end)

--- Что можно личности: способность → да или нет.
---@param identity any
---@return table<string, boolean>
local function rights_of(identity)
    local rights = {}

    for _, ability in ipairs({ 'cluster.read', can.CHANGE, can.CONFIG, can.AUDIT }) do
        rights[ability] = gate:allows(identity, ability)
    end

    return rights
end

--- Обработчик за слоем: помнит, с чем его звали, и отвечает 200.
---@return fun(request: table): table handler
---@return table seen Запросы, дошедшие до обработчика
local function handler()
    local seen = {}

    return function(request)
        table.insert(seen, request)

        return { status = 200, body = 'дошло' }
    end,
        seen
end

g.test_the_observer_only_looks = function()
    -- Смотреть и менять — разные права: вошедший на чтение не должен
    -- уметь изгнать узел и не видит конфигурации с учётными записями.
    t.assert_equals(rights_of({ username = 'наблюдатель', readonly = true }), {
        ['cluster.read'] = true,
        ['cluster.change'] = false,
        ['cluster.config.read'] = false,
        ['audit.read'] = false,
    })
end

g.test_the_admin_changes_the_cluster_but_does_not_read_the_log = function()
    -- Право менять кластер — не право читать журнал: тот, кто меняет,
    -- не обязан читать журнал о себе.
    t.assert_equals(rights_of({ username = 'admin', readonly = false }), {
        ['cluster.read'] = true,
        ['cluster.change'] = true,
        ['cluster.config.read'] = true,
        ['audit.read'] = false,
    })

    t.assert_equals(rights_of({ username = 'admin' }), rights_of({ username = 'admin', readonly = false }))
end

g.test_the_log_is_opened_by_its_own_sign = function()
    -- Проверять журнал должен уметь тот, кто не может его подделать:
    -- признак журнала от права менять не зависит.
    t.assert_equals(rights_of({ username = 'аудитор', readonly = true, audit = true }), {
        ['cluster.read'] = true,
        ['cluster.change'] = false,
        ['cluster.config.read'] = false,
        ['audit.read'] = true,
    })

    t.assert_equals(gate:allows({ username = 'admin', audit = true }, can.AUDIT), true)
end

g.test_the_log_is_opened_only_by_true = function()
    -- Право — признак, а не что угодно правдивое: строка «нет» в личности
    -- журнала не открывает.
    t.assert_equals(gate:allows({ username = 'оператор', audit = 'нет' }, can.AUDIT), false)
    t.assert_equals(gate:allows({ username = 'оператор', audit = 1 }, can.AUDIT), false)
end

g.test_an_identity_that_is_not_a_table_gets_nothing = function()
    -- Строка на месте личности иначе прочиталась бы полями строковой
    -- библиотеки — без `readonly`, то есть администратором.
    for _, identity in ipairs({ 'admin', 42, true }) do
        t.assert_equals(rights_of(identity), {
            ['cluster.read'] = false,
            ['cluster.change'] = false,
            ['cluster.config.read'] = false,
            ['audit.read'] = false,
        }, tostring(identity))
    end

    t.assert_equals(gate:allows(nil, 'cluster.read'), false)
end

g.test_the_refusal_of_the_gate_is_declared_in_the_catalog_of_the_panel = function()
    -- Ворота объявляют свой отказ при сборке, и объявлять его в общем
    -- каталоге приложения панели не по чину: приложению о ней знать нечего.
    local refusals = helper.testing.module('tnt.admin.app.exceptions.refusal')
    local errors = helper.testing.module('tnt.error')
    local denied = helper.testing.module('tnt.permissions').DENIED

    t.assert_not_equals(refusals.catalog:defined(denied), nil)
    t.assert_equals(errors.default():defined(denied), nil)
end

g.test_the_one_with_the_right_goes_on = function()
    local layer = can.layer(gate, can.CHANGE)
    local handle, seen = handler()
    local request = { identity = { username = 'admin', readonly = false } }

    t.assert_equals(layer.name, 'can')
    t.assert_equals(layer[1](request, handle), { status = 200, body = 'дошло' })
    t.assert_equals(seen, { request })
end

g.test_the_one_without_the_right_is_refused_in_the_words_of_the_panel = function()
    -- Слово у каждой способности своё: JS панели показывает его как есть.
    -- Опознавателя в отказе нет: нет права — ожидаемый ответ, и искать
    -- его в журнале нечего.
    local observer = { identity = { username = 'наблюдатель', readonly = true } }

    for ability, word in pairs({
        [can.CHANGE] = 'у вас нет права менять кластер',
        [can.CONFIG] = 'у вас нет права смотреть конфигурацию кластера',
        [can.AUDIT] = 'у вас нет права читать журнал аудита',
    }) do
        local handle, seen = handler()
        local response = can.layer(gate, ability)[1](observer, handle)

        t.assert_equals(response.status, 403, ability)
        t.assert_equals(json.decode(response.body), { error = { status = 403, message = word } }, ability)
        t.assert_equals(seen, {}, ability)
    end
end

g.test_an_ability_without_a_refusal_is_a_mistake_of_the_route = function()
    -- Общим словом ворот панель не отвечает, и опечатка в способности
    -- находится при объявлении маршрута — на его строке, а не внутри
    -- панели.
    -- Скобки снимают хвостовой вызов: без кадра объявления винить было бы
    -- некого, и место броска выпало бы из слова.
    local function declare()
        return (can.layer(gate, 'cluster.restart'))
    end

    local _, err = pcall(declare)
    local info = debug.getinfo(declare, 'S') --[[@as { short_src: string, linedefined: integer }]]

    t.assert_equals(
        err,
        ('%s:%d: у способности «cluster.restart» нет отказа панели'):format(
            info.short_src,
            info.linedefined + 1
        )
    )
end
