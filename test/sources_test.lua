--- Тесты сбора источников: что нашлось рядом, то панель и показывает.
---
--- Настоящих пакетов здесь нет намеренно: набор обязан отличать
--- установленное от невыложенного на любой машине, а не на той, где
--- сегодня стоит диагностика.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.services.sources')

---@type any
local sources

--- Подключение модуля по имени: отдаёт то, что положили в набор.
---@param modules table<string, any>
---@return fun(name: string): any|nil
local function loading(modules)
    return function(name)
        return modules[name]
    end
end

--- Диагностика кластера: четыре действия, которые берёт панель.
local function cluster()
    return {
        current = function()
            return { name = 'снимок' }
        end,
        findings = function()
            return { 'находка' }
        end,
        suggestions = function()
            return { 'подсказка' }
        end,
        filter = function(selector)
            return { { name = 'отобранный', groups = selector.groups } }
        end,
    }
end

g.before_each(function()
    sources = helper.load('tnt.admin.app.services.sources')
end)

g.after_each(function()
    helper.unload()
end)

g.test_without_packages_nothing_is_collected = function()
    -- Панель на голом узле: показывать нечего, но и падать незачем.
    sources._set_source({ load = loading({}) })

    local collected, available = sources.collect()

    t.assert_equals(collected, {})
    t.assert_equals(available, {})
end

g.test_diagnostics_gives_four_sources = function()
    sources._set_source({ load = loading({ ['tnt.cluster'] = cluster() }) })

    local collected, available = sources.collect()

    t.assert_equals(collected.snapshot(), { name = 'снимок' })
    t.assert_equals(collected.issues(), { 'находка' })
    t.assert_equals(collected.suggestions(), { 'подсказка' })
    t.assert_equals(
        collected.filter({ groups = { 'storages' } }),
        { { name = 'отобранный', groups = { 'storages' } } }
    )
    t.assert_equals(available, { snapshot = true, issues = true, suggestions = true, filter = true })
end

g.test_diagnostics_announces_new_snapshots = function()
    -- Каждый обход диагностика объявляет событием узла: извещение
    -- панели — наблюдатель этого события, а отписка его снимает.
    local watched = { unregistered = 0 }
    local diagnostics = cluster()

    diagnostics.EVENT = 'tnt.cluster.health'

    sources._set_source({
        load = loading({ ['tnt.cluster'] = diagnostics }),
        watch = function(key, callback)
            watched.key, watched.callback = key, callback

            return {
                unregister = function()
                    watched.unregistered = watched.unregistered + 1
                end,
            }
        end,
    })

    local collected, available = sources.collect()
    local notified = 0
    local cancel = collected.updates(function(...)
        notified = notified + 1
        watched.arguments = { ... }
    end)

    t.assert_equals(available.updates, true)
    t.assert_equals(watched.key, 'tnt.cluster.health')

    watched.callback('tnt.cluster.health', { generation = 7 })

    t.assert_equals(notified, 1)
    t.assert_equals(
        watched.arguments,
        {},
        'извещение не несёт сводку события: обзор соберёт панель'
    )
    t.assert_equals(watched.unregistered, 0)

    cancel()

    t.assert_equals(watched.unregistered, 1)
end

g.test_a_package_without_the_event_gives_no_updates = function()
    -- Диагностика, отставшая от панели, извещения не даёт: толчка нет,
    -- а не бросок на первом подключении.
    local diagnostics = cluster()

    diagnostics.EVENT = 42

    sources._set_source({ load = loading({ ['tnt.cluster'] = diagnostics }) })

    local collected, available = sources.collect()

    t.assert_equals(collected.updates, nil)
    t.assert_equals(available.updates, nil)
end

g.test_the_watcher_is_the_one_of_the_node = function()
    -- Умолчание шва — наблюдатель `box`: событие, объявленное на узле,
    -- доходит до него, а снятый наблюдатель его больше не слышит.
    local heard = {}
    local watcher = sources.watch('tnt.admin.test.updates', function(key, value)
        table.insert(heard, { key, value })
    end)

    box.broadcast('tnt.admin.test.updates', 1)

    t.helpers.retrying({ timeout = 2 }, function()
        t.assert_equals(heard, { { 'tnt.admin.test.updates', 1 } })
    end)

    watcher:unregister()
    box.broadcast('tnt.admin.test.updates', 2)
    require('fiber').sleep(0.05)

    t.assert_equals(#heard, 1)
end

g.test_audit_comes_from_two_modules = function()
    sources._set_source({
        load = loading({
            ['tnt.audit.stream'] = {
                open = function()
                    return { 'запись' }
                end,
            },
            ['tnt.audit.verify'] = {
                run = function()
                    return { ok = true }
                end,
            },
        }),
    })

    local collected, available = sources.collect()

    t.assert_equals(collected.audit(), { 'запись' })
    t.assert_equals(collected.audit_verify(), { ok = true })
    t.assert_equals(available, { audit = true, audit_verify = true })
end

g.test_a_disabled_source_is_not_taken = function()
    -- Пакет стоит ради соседа, а показывать его панель не должна.
    sources._set_source({ load = loading({ ['tnt.cluster'] = cluster() }) })

    local collected, available = sources.collect({ disabled = { suggestions = true } })

    t.assert_not_equals(collected.snapshot, nil)
    t.assert_equals(collected.suggestions, nil)
    t.assert_equals(available.suggestions, nil)
end

g.test_a_module_without_the_action_gives_nothing = function()
    -- Пакет есть, а действия в нём нет: так выглядит пакет, отставший
    -- от панели. Панель обязана считать источник отсутствующим, а не
    -- звать nil на первом же запросе.
    sources._set_source({ load = loading({ ['tnt.cluster'] = { current = 'не функция' } }) })

    local collected, available = sources.collect()

    t.assert_equals(collected, {})
    t.assert_equals(available, {})
end

g.test_one_module_is_asked_once = function()
    -- Четыре источника берутся у одной диагностики: спрашивать её
    -- четырежды значит столько же раз разворачивать пакет на каждое
    -- применение.
    local asked = 0

    sources._set_source({
        load = function(name)
            asked = asked + 1

            return name == 'tnt.cluster' and cluster() or nil
        end,
    })

    sources.collect()

    t.assert_equals(asked, 3, 'по одному вопросу на модуль: cluster, audit.stream, audit.verify')
end

g.test_a_missing_module_is_not_asked_twice = function()
    local asked = {}

    sources._set_source({
        load = function(name)
            asked[name] = (asked[name] or 0) + 1

            return nil
        end,
    })

    sources.collect()

    t.assert_equals(asked['tnt.cluster'], 1)
end

g.test_a_missing_package_gives_nothing_instead_of_a_throw = function()
    -- Умолчание шва: пакета с таким именем нет ни на одной машине.
    -- Пустота, а не бросок: узел без диагностики — обычное развёртывание.
    t.assert_equals(sources.load('tnt.такого.пакета.нет'), nil)
end

g.test_an_installed_package_is_given_back = function()
    -- Тем же подключением берётся и установленный пакет: иначе проверка
    -- выше проходила бы и на подключении, которое всегда молчит.
    t.assert_equals(sources.load('tnt.admin.app.domain.cluster'), require('tnt.admin.app.domain.cluster'))
end
