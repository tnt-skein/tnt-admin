--- Тесты обхода кластера: панель заводит его сама, когда ей дали учётку.
---
--- Настоящей диагностики здесь нет: она ходит к соседям по сети, а
--- проверять надо решение панели — заводить обход или нет и что она
--- за собой снимает.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.services.watch')

---@type any
local watch

--- Двойник диагностики: что ей сказали и идёт ли обход.
---@type table
local diagnostics

--- Ставит двойник диагностики; пусто — пакета на узле нет.
---@param running boolean|nil Идёт ли обход уже
local function installed(running)
    diagnostics = { configured = nil, started = 0, stopped = 0, running = running == true }

    watch._set_source({
        cluster = function()
            return {
                configure = function(opts)
                    diagnostics.configured = opts
                end,
                start = function()
                    diagnostics.started = diagnostics.started + 1
                    diagnostics.running = true
                end,
                stop = function()
                    diagnostics.stopped = diagnostics.stopped + 1
                    diagnostics.running = false
                end,
                status = function()
                    return { running = diagnostics.running }
                end,
            }
        end,
    })
end

g.before_each(function()
    watch = helper.load('tnt.admin.app.services.watch')
end)

g.after_each(function()
    -- Обход процессный, и признак «завела панель» живёт столько же:
    -- снятие возвращает его к исходному.
    watch.stop()
    helper.unload()
end)

g.test_the_login_of_the_watcher_starts_the_walk = function()
    installed()

    local said = watch.start({ login = 'health', password = 'секрет', interval = 5, timeout = 2 })

    t.assert_str_contains(said, 'обход кластера заведён под учёткой health')
    t.assert_equals(diagnostics.started, 1)
    t.assert_equals(diagnostics.configured.login, 'health')
    t.assert_equals(diagnostics.configured.password, 'секрет')
    t.assert_equals(diagnostics.configured.interval, 5)
    t.assert_equals(diagnostics.configured.timeout, 2)
end

g.test_without_a_login_nothing_is_started = function()
    -- Ходить к соседям нечем: молчаливая попытка под чужой учёткой
    -- кончилась бы отказами в журнале у каждого узла кластера.
    installed()

    t.assert_equals(watch.start(nil), nil)
    t.assert_equals(watch.start({}), nil)
    t.assert_equals(diagnostics.started, 0)
end

g.test_without_the_package_nothing_is_started = function()
    -- Диагностики рядом нет: панель работает и без неё, показывая пустой
    -- кластер, а не падая на применении конфигурации.
    watch._set_source({
        cluster = function()
            return nil
        end,
    })

    t.assert_equals(watch.start({ login = 'health' }), nil)
end

g.test_a_walk_that_is_already_going_is_left_alone = function()
    -- Обход мог завести сосед по процессу — приложение или вторая
    -- панель: перенастройка увела бы его на другую учётку молча.
    installed(true)

    t.assert_equals(watch.start({ login = 'health' }), nil)
    t.assert_equals(diagnostics.configured, nil)
    t.assert_equals(diagnostics.started, 0)
end

g.test_the_panel_stops_only_its_own_walk = function()
    installed()
    watch.start({ login = 'health' })
    watch.stop()

    t.assert_equals(diagnostics.stopped, 1)

    -- Второе снятие ничего не трогает: обход уже остановлен, и повторный
    -- вызов закрыл бы соединения того, кто завёл обход после панели.
    watch.stop()

    t.assert_equals(diagnostics.stopped, 1)
end

g.test_a_foreign_walk_survives_the_panel = function()
    -- Панель, снятая с узла, не уносит с собой диагностику соседа.
    installed(true)
    watch.start({ login = 'health' })
    watch.stop()

    t.assert_equals(diagnostics.stopped, 0)
    t.assert_equals(diagnostics.running, true)
end

g.test_the_real_external_takes_the_diagnostics_package = function()
    -- Умолчание внешней зависимости: пакет берётся по имени и только
    -- по вопросу — на узле, где его нет, панель работает без него.
    local placed = {}
    local previous = package.loaded['tnt.cluster']

    watch._set_source(nil)
    package.loaded['tnt.cluster'] = placed

    local taken = watch.cluster()

    package.loaded['tnt.cluster'] = previous

    t.assert_is(taken, placed)
end

g.test_without_the_package_the_real_external_is_empty = function()
    -- Умолчание внешней зависимости: пакета диагностики на узле может
    -- не быть вовсе, и панель тогда работает без обхода.
    watch._set_source(nil)

    t.assert_is(watch.cluster(), require('tnt.cluster'))
end
