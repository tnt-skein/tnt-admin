--- Тесты отбора узлов по конфигурации: `GET /api/v1/instances`.
---
--- Первая группа идёт на двойнике источника: он запоминает отбор, который
--- ему отдала панель, и отвечает тем, что назвала проверка. Вторая — на
--- настоящей диагностике из исходников поверх двойника конфигурации:
--- стык панели с `tnt.cluster.filter` — имена полей отбора, вид узла
--- и слова отказа — проверяется только так.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')
local testing = helper.testing

local g = t.group('tnt.admin.app.http.handlers.instances')

--- Отказ незнакомому параметру слово в слово.
local UNKNOWN =
    'такого отбора нет: есть groups, replicasets, instances, roles, sharding_roles и labels[имя]'

--- Отказ повторённому параметру слово в слово.
local REPEATED =
    'параметр повторён: значения списка пишутся через запятую, метка задаётся один раз'

--- Отказ пустому имени в списке слово в слово.
local EMPTY =
    'пустое имя в списке: имена пишутся через запятую без пропусков'

--- Узлы, которыми отвечает двойник.
local ROUTER = {
    name = 'router-001-a',
    replicaset_name = 'router-001',
    group_name = 'routers',
    roles = { 'roles.httpd', 'tnt.admin' },
    sharding_roles = { 'router' },
    labels = { zone = 'msk' },
}

local STORAGE = {
    name = 'storage-001-a',
    replicaset_name = 'storage-001',
    group_name = 'storages',
    roles = { 'roles.metrics-export' },
    sharding_roles = { 'storage' },
    labels = { zone = 'spb', ['app.io/tier'] = 'data' },
}

---@type TntAdminPanel
local panel

--- Отборы, которые панель отдала источнику, по порядку.
---@type table[]
local asked

--- Источник отбора: запоминает отбор и отвечает названным.
---@param instances table[]|nil
---@param reason string|nil
---@return fun(selector: table): table[]|nil, string|nil
local function filtering(instances, reason)
    return function(selector)
        table.insert(asked, selector)

        return instances, reason
    end
end

--- Собирает панель на названных источниках.
---@param source table
local function configure(source)
    panel = helper.panel(source)
end

--- Запрос отбора: ответ и разобранное тело.
---@param query string Строка запроса без вопросительного знака
---@return table response
---@return table body
local function listed(query)
    local response = panel.ask('GET', '/api/v1/instances?' .. query)

    return response, json.decode(response.body)
end

g.before_each(function()
    helper.load('tnt.admin.app.support.root')

    asked = {}

    configure({ filter = filtering({ ROUTER, STORAGE }) })
end)

g.after_each(function()
    helper.unload()
end)

g.test_without_a_filter_every_instance_is_listed = function()
    local response, body = listed('')

    t.assert_equals(response.status, 200)
    t.assert_equals(response.headers['content-type'], 'application/json; charset=utf-8')
    t.assert_equals(body, { instances = { ROUTER, STORAGE } })
    t.assert_equals(asked, { {} })
end

g.test_every_instance_carries_fields_of_one_kind = function()
    -- Конфигурация молчит о ролях и метках, которых не объявили: поле
    -- пропало бы из ответа, а пустые метки ушли бы списком `[]`.
    configure({
        filter = filtering({ { name = 'lonely-001-a', replicaset_name = 'lonely-001', group_name = 'lonely' } }),
    })

    local response, body = listed('')

    t.assert_equals(body.instances, {
        {
            name = 'lonely-001-a',
            replicaset_name = 'lonely-001',
            group_name = 'lonely',
            roles = {},
            sharding_roles = {},
            labels = {},
        },
    })
    t.assert_str_contains(response.body, '"labels":{}')
    t.assert_str_contains(response.body, '"roles":[]')
    t.assert_str_contains(response.body, '"sharding_roles":[]')
end

g.test_labels_of_the_source_are_left_as_they_were = function()
    -- Ответ собирается копией: метки отдала диагностика, и признак
    -- словаря на её таблице увидел бы следующий, кто её возьмёт.
    listed('')

    t.assert_equals(getmetatable(STORAGE.labels), nil)
end

g.test_lists_are_written_through_commas = function()
    local response = listed(
        'groups=routers,storages&replicasets=storage-001&instances=router-001-a,storage-001-a'
            .. '&roles=roles.httpd,tnt.admin&sharding_roles=router'
    )

    t.assert_equals(response.status, 200)
    t.assert_equals(asked, {
        {
            groups = { 'routers', 'storages' },
            replicasets = { 'storage-001' },
            instances = { 'router-001-a', 'storage-001-a' },
            roles = { 'roles.httpd', 'tnt.admin' },
            sharding_roles = { 'router' },
        },
    })
end

g.test_labels_are_named_in_brackets = function()
    -- Имя метки берётся целиком: точка и косая черта в нём — обычное
    -- дело, а скобки клиент вправе прислать закодированными.
    local response = listed('labels[zone]=spb&labels%5Bapp.io%2Ftier%5D=data')

    t.assert_equals(response.status, 200)
    t.assert_equals(asked, { { labels = { zone = 'spb', ['app.io/tier'] = 'data' } } })
end

g.test_an_empty_label_value_is_still_a_value = function()
    -- Пустое значение отбирает узлы с пустой меткой, а не снимает
    -- условие: иначе ответ молча расширился бы.
    listed('labels[zone]=')

    t.assert_equals(asked, { { labels = { zone = '' } } })
end

g.test_an_unknown_parameter_is_refused = function()
    -- Опечатка в имени отбора, пропущенная молча, вернула бы весь кластер
    -- вместо части: скрипт, который выбирает узлы для действия, задел бы
    -- лишние.
    local response, body = listed('group=routers')

    t.assert_equals(response.status, 400)
    t.assert_equals(body.error.message, 'отбор узлов не разобран')
    t.assert_equals(body.error.fields, { group = UNKNOWN })
    t.assert_equals(asked, {})
end

g.test_labels_without_a_name_are_unknown = function()
    local response, body = listed('labels=zone&labels[]=spb')

    t.assert_equals(response.status, 400)
    t.assert_equals(body.error.fields, { labels = UNKNOWN, ['labels[]'] = UNKNOWN })
end

g.test_a_repeated_parameter_is_refused = function()
    -- «Или» или «и» имели в виду, не угадать, — и у списка, и у метки.
    local response, body = listed('groups=routers&groups=storages&labels[zone]=msk&labels[zone]=spb')

    t.assert_equals(response.status, 400)
    t.assert_equals(body.error.fields, { groups = REPEATED, ['labels[zone]'] = REPEATED })
    t.assert_equals(asked, {})
end

g.test_an_empty_name_in_a_list_is_refused = function()
    -- Пустой список отбор читает как «без ограничения»: `groups=` вернул
    -- бы весь кластер. Отказывают все три вида пропуска разом.
    local response, body = listed('groups=&roles=roles.httpd,,tnt.admin&instances=router-001-a,')

    t.assert_equals(response.status, 400)
    t.assert_equals(body.error.fields, { groups = EMPTY, roles = EMPTY, instances = EMPTY })
    t.assert_equals(asked, {})
end

g.test_a_good_parameter_next_to_a_wrong_one_is_not_named = function()
    local _, body = listed('groups=routers&group=routers')

    t.assert_equals(body.error.fields, { group = UNKNOWN })
end

g.test_without_the_diagnostics_the_filter_is_not_available = function()
    configure({})

    local response, body = listed('groups=routers')

    t.assert_equals(response.status, 501)
    t.assert_equals(body.error.message, 'отбор узлов этой панели недоступен')
end

g.test_a_wrong_filter_is_refused_even_without_the_diagnostics = function()
    -- Негодный адрес негоден на любом узле: клиент правит его сразу,
    -- а не после того, как узнает, что на другом узле отбор есть.
    configure({})

    local response = listed('group=routers')

    t.assert_equals(response.status, 400)
end

g.test_a_refusal_of_the_diagnostics_goes_out_in_its_words = function()
    configure({
        filter = filtering(
            nil,
            'по конфигурации ребалансировщик не найти: его назначает vshard'
        ),
    })

    local response, body = listed('sharding_roles=rebalancer')

    t.assert_equals(response.status, 400)
    t.assert_equals(
        body.error.message,
        'по конфигурации ребалансировщик не найти: его назначает vshard'
    )
    t.assert_equals(asked, { { sharding_roles = { 'rebalancer' } } })
end

g.test_a_refusal_without_words_gets_its_own = function()
    configure({ filter = filtering(nil, nil) })

    local response, body = listed('')

    t.assert_equals(response.status, 400)
    t.assert_equals(body.error.message, 'узлы не отобраны')
end

g.test_a_read_only_operator_may_filter = function()
    -- Отбор показывает то же, что состав кластера: права менять кластер
    -- для него не нужно.
    configure({
        filter = filtering({ ROUTER }),
        authorize = function()
            return { username = 'наблюдатель', readonly = true }
        end,
    })

    local response, body = listed('groups=routers')

    t.assert_equals(response.status, 200)
    t.assert_equals(body.instances, { ROUTER })
end

g.test_without_login_nothing_is_filtered = function()
    configure({
        filter = filtering({ ROUTER }),
        authorize = function()
            return nil
        end,
    })

    local response = listed('groups=routers')

    t.assert_equals(response.status, 401)
    t.assert_equals(asked, {})
end

-- ── Настоящая диагностика поверх двойника конфигурации ───────────────

local g_cluster = t.group('tnt.admin.app.http.handlers.instances.cluster')

--- Инстансы конфигурации: место в кластере.
local INSTANCES = {
    ['router-001-a'] = { replicaset_name = 'router-001', group_name = 'routers' },
    ['storage-001-a'] = { replicaset_name = 'storage-001', group_name = 'storages' },
    ['storage-002-a'] = { replicaset_name = 'storage-002', group_name = 'storages' },
}

--- Что конфигурация говорит о каждом инстансе, путь → значение.
local SETTINGS = {
    ['router-001-a'] = {
        roles = { 'roles.httpd', 'tnt.admin' },
        ['sharding.roles'] = { 'router' },
        labels = { zone = 'msk' },
    },
    ['storage-001-a'] = { ['sharding.roles'] = { 'storage' }, labels = { zone = 'spb' } },
    ['storage-002-a'] = { ['sharding.roles'] = { 'storage' }, labels = { zone = 'msk' } },
}

g_cluster.before_each(function()
    helper.load('tnt.admin.app.support.root', helper.CLUSTER)

    local cluster = testing.module('tnt.cluster')

    testing.module('tnt.cluster.pool')._set_source({
        config = function()
            return {
                instances = function()
                    return INSTANCES
                end,
                get = function(_, path, opts)
                    return SETTINGS[opts.instance][path]
                end,
            }
        end,
    })

    -- Панель находит диагностику так же, как на узле, — по имени; здесь
    -- имя ведёт к исходникам, а не к установленной копии.
    local sources = testing.module('tnt.admin.app.services.sources')

    sources._set_source({
        load = function(name)
            return name == 'tnt.cluster' and cluster or nil
        end,
    })

    panel = helper.panel((sources.collect()))
end)

g_cluster.after_each(function()
    helper.unload()
    testing.unload_sources(helper.CLUSTER)
end)

g_cluster.test_the_diagnostics_chooses_by_group_and_label = function()
    local response, body = listed('groups=storages&labels[zone]=spb')

    t.assert_equals(response.status, 200)
    t.assert_equals(body.instances, {
        {
            name = 'storage-001-a',
            replicaset_name = 'storage-001',
            group_name = 'storages',
            roles = {},
            sharding_roles = { 'storage' },
            labels = { zone = 'spb' },
        },
    })
end

g_cluster.test_roles_are_required_all_at_once = function()
    local _, body = listed('roles=roles.httpd,tnt.admin&sharding_roles=router')

    t.assert_equals(body.instances[1].name, 'router-001-a')
    t.assert_equals(#body.instances, 1)
end

g_cluster.test_instances_come_ordered_by_name = function()
    local _, body = listed('sharding_roles=storage')

    t.assert_equals(body.instances[1].name, 'storage-001-a')
    t.assert_equals(body.instances[2].name, 'storage-002-a')
end

g_cluster.test_the_rebalancer_is_refused_in_the_words_of_the_diagnostics = function()
    -- Ребалансировщика назначает vshard, и конфигурация о нём не знает:
    -- отказ диагностики уходит оператору её словами.
    local response, body = listed('sharding_roles=rebalancer')

    t.assert_equals(response.status, 400)
    t.assert_equals(
        body.error.message,
        'по конфигурации ребалансировщик не найти: его назначает vshard'
    )
end

g_cluster.test_an_unknown_sharding_role_is_refused_in_the_same_way = function()
    local response, body = listed('sharding_roles=archive')

    t.assert_equals(response.status, 400)
    t.assert_equals(
        body.error.message,
        'неизвестная роль шардирования archive: ожидается router или storage'
    )
end
