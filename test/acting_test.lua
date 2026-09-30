--- Тесты действий панели: что она предлагает и что зовёт на узлах.
---
--- Настоящих пакетов действий здесь нет: их тела живут на узлах, а
--- проверять надо решение панели — что показать, что спросить у ворот
--- и какую функцию позвать.

local t = require('luatest')

local helper = dofile('test/helper.lua')
local testing = helper.testing

local g = t.group('tnt.admin.app.services.acting')

---@type any
local acting

--- Что спрашивали у узлов.
---@type any
local called

--- Учётка действий: без неё панель их не заводит вовсе.
local ACCOUNT = { login = 'maintenance', password = 'секрет' }

--- Ставит пакеты действий; `opts.without` убирает названный.
---@param opts table|nil
local function installed(opts)
    local given = opts or {}
    local without = given.without or {}

    called = { run = nil, decided = nil, connections = {} }

    acting._set_source({
        cluster = function()
            return not without.cluster
                    and {
                        current = function()
                            return { generation = 3, instances = {} }
                        end,
                    }
                or nil
        end,

        ops = function()
            return not without.ops
                    and {
                        RELOAD_FUNCTION = 'cluster_reload_config',
                        RESTART_REPLICATION_FUNCTION = 'cluster_restart_replication',
                        run = function(request)
                            called.run = request

                            -- Соединение спрашивается у набора панели: под
                            -- учёткой действий, а не наблюдателя.
                            table.insert(called.connections, request.connection('storage-001-a'))

                            return {
                                action = request.action,
                                status = 'complete',
                                succeeded = request.targets,
                                failed = {},
                            }
                        end,
                    }
                or nil
        end,

        sharding = function()
            return not without.sharding
                    and { FUNCTIONS = { bootstrap = 'sharding_bootstrap', rebalancer = 'sharding_rebalancer' } }
                or nil
        end,

        risk = function()
            return not without.risk
                    and {
                        of = function(spec)
                            return {
                                action = spec.action,
                                risk = spec.risk,
                                fingerprint = spec.fingerprint,
                                summary = spec.summary,
                            }
                        end,
                        fingerprint = function(snapshot, targets)
                            -- Отпечаток считается по снимку и узлам:
                            -- признак «снимок есть» вместо самого снимка
                            -- дал бы отпечаток, ни к чему не привязанный.
                            called.fingerprinted = { snapshot = snapshot, targets = targets }

                            return type(snapshot) == 'table' and ('отпечаток %d'):format(snapshot.generation)
                                or 'пусто'
                        end,
                    }
                or nil
        end,

        gate = function()
            return not without.gate
                    and {
                        decide = function(assessment, request)
                            called.decided = { assessment = assessment, request = request }

                            if given.refuse ~= nil then
                                return { allow = false, code = given.refuse, message = 'ворота отказали' }
                            end

                            return { allow = true }
                        end,
                    }
                or nil
        end,
    })
end

g.before_each(function()
    acting = helper.load('tnt.admin.app.services.acting')

    -- Соединения к узлам: настоящие открывали бы сокеты, а проверке
    -- важно лишь то, под какой учёткой их просили.
    testing.module('tnt.admin.app.services.dialing')._set_source({
        pool = function()
            return {
                peer_uri = function()
                    return { uri = '127.0.0.1:3301' }
                end,
            }
        end,

        net_box = function()
            return {
                connect = function(uri)
                    return { state = 'active', uri = uri, close = function() end }
                end,
            }
        end,
    })
end)

g.after_each(function()
    helper.unload()
end)

g.test_without_an_account_there_are_no_actions = function()
    -- Звать действия наблюдателем нельзя: узел откажет «нет права»,
    -- и кнопка обещала бы то, чего не будет.
    installed()

    t.assert_equals(acting.build(nil), nil)
    t.assert_equals(acting.build({}), nil)
end

g.test_without_the_packages_there_are_no_actions = function()
    -- Тело каждого действия живёт в своём пакете: нет пакета — нет
    -- и кнопки.
    installed({ without = { ops = true, sharding = true } })

    t.assert_equals(acting.build(ACCOUNT), nil)
end

g.test_the_catalog_follows_the_installed_packages = function()
    installed({ without = { sharding = true } })

    t.assert_equals(acting.build(ACCOUNT).capabilities(), {
        failover = false,
        config_rollout = false,
        authenticated = false,
        actions = { 'reload_config', 'restart_replication' },
    })

    installed()

    t.assert_equals(acting.build(ACCOUNT).capabilities().actions, {
        'reload_config',
        'restart_replication',
        'sharding_bootstrap',
        'sharding_rebalancer',
    })
end

g.test_an_action_calls_the_function_published_on_the_node = function()
    installed()

    local outcome = acting.build(ACCOUNT).act('sharding_bootstrap', { 'router-001-a' }, {}, nil)

    t.assert_equals(outcome.status, 'complete')
    t.assert_equals(called.run.func, 'sharding_bootstrap')
    t.assert_equals(called.run.targets, { 'router-001-a' })
    t.assert_equals(called.run.timeout, 10)

    -- Свой срок из настроек перебивает умолчание: действие на медленном
    -- узле иначе обрывалось бы на полпути.
    acting.build({ login = 'maintenance', timeout = 45 }).act('reload_config', { 'a' }, {}, nil)

    t.assert_equals(called.run.timeout, 45)
end

g.test_without_the_gate_package_the_action_still_goes = function()
    -- Ворота — отдельный пакет: без него панель действует по оценке,
    -- а не отказывает молча.
    installed({ without = { gate = true } })

    local outcome = acting.build(ACCOUNT).act('reload_config', { 'a' }, {}, nil)

    t.assert_equals(outcome.status, 'complete')
    t.assert_equals(called.run.func, 'cluster_reload_config')
end

g.test_an_unknown_action_is_refused_by_name = function()
    installed()

    local outcome, reason = acting.build(ACCOUNT).act('взорвать', { 'a' }, {}, nil)

    t.assert_equals(outcome, nil)
    t.assert_str_contains(reason, 'действие взорвать этому кластеру недоступно')

    local assessment, unknown = acting.build(ACCOUNT).assess('взорвать', { 'a' })

    t.assert_equals(assessment, nil)
    t.assert_str_contains(unknown, 'недоступно')
end

g.test_the_assessment_carries_the_fingerprint_of_the_state = function()
    -- По отпечатку ворота отличают подтверждение, данное по этой картине,
    -- от данного по вчерашней.
    installed()

    local assessment = acting.build(ACCOUNT).assess('reload_config', { 'a' })

    t.assert_equals(assessment.action, 'reload_config')
    t.assert_equals(assessment.risk, 'safe')
    t.assert_equals(assessment.fingerprint, 'отпечаток 3')
    t.assert_equals(called.fingerprinted.snapshot.generation, 3)
    t.assert_equals(called.fingerprinted.targets, { 'a' })
end

g.test_the_gate_stands_before_the_call = function()
    -- Отказ ворот — это разговор с оператором: действие не выполняется,
    -- а оценка уходит вместе с отказом.
    installed({ refuse = 'CONFIRMATION_REQUIRED' })

    local outcome = acting.build(ACCOUNT).act('sharding_bootstrap', { 'a' }, {}, { acknowledge = false })

    t.assert_equals(outcome.refused.code, 'CONFIRMATION_REQUIRED')
    t.assert_equals(outcome.assessment.action, 'sharding_bootstrap')
    t.assert_equals(called.run, nil, 'узлы не трогали')
end

g.test_without_the_assessment_package_nothing_is_done = function()
    -- Действие без оценки — это действие вслепую: ворота на нём не
    -- стоят, и оператор не видел, что случится.
    installed({ without = { risk = true } })

    local outcome, reason = acting.build(ACCOUNT).act('reload_config', { 'a' }, {}, nil)

    t.assert_equals(outcome, nil)
    t.assert_str_contains(reason, 'оценка действий на этом кластере не включена')
end

g.test_the_real_externals_take_the_packages_by_name = function()
    -- Умолчания внешних зависимостей: каждый пакет берётся по имени
    -- и только по вопросу — на узле, где его нет, панель работает
    -- без него.
    acting._set_source(nil)

    t.assert_is(acting.cluster(), require('tnt.cluster'))
    t.assert_is(acting.ops(), require('tnt.ops.actions'))
    t.assert_is(acting.sharding(), require('tnt.sharding.actions'))
    t.assert_is(acting.risk(), require('tnt.recovery.risk'))
    t.assert_is(acting.gate(), require('tnt.recovery.gate'))
end

g.test_actions_without_the_packages_of_the_bodies_are_refused = function()
    -- Каталог собран, а пакета с телом действия не стало: перечитывание
    -- конфигурации на узле звать нечем, и панель отказывает словами.
    installed()

    local actions = acting.build(ACCOUNT)

    installed({ without = { ops = true } })

    local outcome, reason = actions.act('reload_config', { 'a' }, {}, nil)

    t.assert_equals(outcome, nil)
    t.assert_str_contains(reason, 'действия на этом кластере не включены')
end

g.test_closing_lets_go_of_the_connections = function()
    -- Панель снимают вместе с её соединениями: открытые к каждому узлу,
    -- они пережили бы роль.
    installed()

    local closed = 0

    testing.module('tnt.admin.app.services.dialing')._set_source({
        pool = function()
            return {
                peer_uri = function()
                    return { uri = '127.0.0.1:3301' }
                end,
            }
        end,

        net_box = function()
            return {
                connect = function()
                    return {
                        state = 'active',
                        close = function()
                            closed = closed + 1
                        end,
                    }
                end,
            }
        end,
    })

    local actions = acting.build(ACCOUNT)

    actions.act('reload_config', { 'storage-001-a' }, {}, nil)
    actions.close()

    t.assert_equals(closed, 1)
end
