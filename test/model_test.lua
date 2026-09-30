--- Тесты представления кластера. Модуль чистый: снимок подаётся таблицей.

local t = require('luatest')

local helper = dofile('test/helper.lua')
local testing = helper.testing

local g = t.group('tnt.admin.app.domain.cluster')

---@type any
local model

g.before_each(function()
    model = testing.load_sources(helper.MODEL, 'tnt.admin.app.domain.cluster')
end)

g.after_each(function()
    testing.unload_sources(helper.MODEL)
end)

--- Снимок диагностики из двух узлов.
---@param overrides table|nil
---@return table
local function snapshot(overrides)
    overrides = overrides or {}

    local instances = {
        ['storage-001-a'] = {
            name = 'storage-001-a',
            replicaset_name = 'storage-001',
            reachable = true,
            status = 'running',
            ro = false,
            lsn = 42,
            uptime = 3600,
            version = '3.8.0',
            clock = 1789041300,
            last_seen = 1789041300,
            advertise = { uri = '127.0.0.1:3301' },
            memory = { arena_ratio = 0.1, items_ratio = 0.2, quota_ratio = 0.3 },
            config = { status = 'ready', fingerprint = 'aaaa' },
            extensions = { lifecycle = { state = 'idle', previous = 'idle' } },
        },
        ['storage-001-b'] = {
            name = 'storage-001-b',
            replicaset_name = 'storage-001',
            reachable = true,
            status = 'running',
            ro = true,
            advertise = { uri = '127.0.0.1:3302' },
            memory = {},
            config = { status = 'ready', fingerprint = 'aaaa' },
        },
    }

    for name, patch in pairs(overrides.instances or {}) do
        for key, value in pairs(patch) do
            instances[name][key] = value
        end
    end

    local leaders = {}
    for name, entry in pairs(instances) do
        if entry.reachable and entry.ro == false then
            table.insert(leaders, name)
        end
    end
    table.sort(leaders)

    return {
        generation = 7,
        taken_at = 1789041300,
        self_name = 'router-001-a',
        instances = instances,
        replicasets = {
            ['storage-001'] = {
                name = 'storage-001',
                instances = { 'storage-001-a', 'storage-001-b' },
                leaders = leaders,
            },
        },
    }
end

--- Узел представления по имени.
---@param view table
---@param name string
---@return table
local function server(view, name)
    for _, entry in ipairs(view.servers) do
        if entry.name == name then
            return entry
        end
    end

    return {}
end

g.test_cluster_view_carries_its_version = function()
    -- Панель старой версии не должна молча показывать не то.
    local view = model.cluster(snapshot())

    t.assert_equals(view.version, 1)
    t.assert_equals(view.generation, 7)
    t.assert_equals(view.taken_at, 1789041300)
    t.assert_equals(view.self_name, 'router-001-a')
end

g.test_servers_are_ordered_by_name = function()
    local view = model.cluster(snapshot())

    t.assert_equals(view.servers[1].name, 'storage-001-a')
    t.assert_equals(view.servers[2].name, 'storage-001-b')
end

g.test_server_carries_what_the_panel_shows = function()
    local entry = server(model.cluster(snapshot()), 'storage-001-a')

    t.assert_equals(entry.replicaset, 'storage-001')
    t.assert_equals(entry.uri, '127.0.0.1:3301')
    t.assert_equals(entry.status, 'running')
    t.assert_equals(entry.writable, true)
    t.assert_equals(entry.lsn, 42)
    t.assert_equals(entry.uptime, 3600)
    t.assert_equals(entry.version, '3.8.0')
    t.assert_equals(entry.memory.quota_ratio, 0.3)
    t.assert_equals(entry.config.fingerprint, 'aaaa')
    t.assert_equals(entry.lifecycle.state, 'idle')
end

g.test_silent_server_is_marked_unreachable = function()
    local view = model.cluster(snapshot({
        instances = {
            ['storage-001-a'] = {
                reachable = false,
                ro = nil,
                failure = { kind = 'timeout', message = 'превышен срок ожидания' },
            },
        },
    }))

    local entry = server(view, 'storage-001-a')

    t.assert_equals(entry.status, 'unreachable')
    t.assert_equals(entry.reachable, false)
    t.assert_equals(entry.writable, false)
    t.assert_equals(entry.message, 'превышен срок ожидания')
    t.assert_equals(view.summary.unreachable, 1)
end

g.test_appointed_and_actual_leaders_are_separate = function()
    -- Расхождение между ними само по себе говорит больше, чем любая
    -- находка: назначение записано, а узел его ещё не применил.
    local view = model.cluster(snapshot(), { appointments = { ['storage-001'] = 'storage-001-b' } })

    t.assert_equals(view.replicasets[1].leader, 'storage-001-b')
    t.assert_equals(view.replicasets[1].active_leader, 'storage-001-a')
end

g.test_replicaset_without_appointments_shows_only_the_writer = function()
    local view = model.cluster(snapshot())

    t.assert_equals(view.replicasets[1].leader, nil)
    t.assert_equals(view.replicasets[1].active_leader, 'storage-001-a')
    t.assert_equals(view.replicasets[1].healthy, true)
end

g.test_replicaset_with_two_writers_is_not_healthy = function()
    local view = model.cluster(snapshot({ instances = { ['storage-001-b'] = { ro = false } } }))

    t.assert_equals(view.replicasets[1].writers, { 'storage-001-a', 'storage-001-b' })
    t.assert_equals(view.replicasets[1].healthy, false)
end

g.test_replicaset_without_a_writer_is_not_healthy = function()
    local view = model.cluster(snapshot({ instances = { ['storage-001-a'] = { ro = true } } }))

    t.assert_equals(view.replicasets[1].active_leader, nil)
    t.assert_equals(view.replicasets[1].healthy, false)
end

g.test_summary_counts_what_is_there = function()
    local view = model.cluster(snapshot())

    t.assert_equals(view.summary.total, 2)
    t.assert_equals(view.summary.unreachable, 0)
    t.assert_equals(view.summary.replicasets, 1)
end

g.test_empty_snapshot_is_survived = function()
    -- Панель спрашивают и до первого обхода кластера.
    local view = model.cluster(nil)

    t.assert_equals(view.servers, {})
    t.assert_equals(view.replicasets, {})
    t.assert_equals(view.generation, 0)
end

g.test_issues_are_renamed_for_the_panel = function()
    local shown = model.issues({
        {
            id = 'memory:instance:storage-001-a',
            rule = 'memory',
            severity = 'critical',
            scope = 'instance',
            instance = 'storage-001-a',
            replicaset = 'storage-001',
            message = 'память занята',
        },
    })

    t.assert_equals(shown[1].level, 'critical')
    t.assert_equals(shown[1].server, 'storage-001-a')
    t.assert_equals(shown[1].rule, 'memory')
    t.assert_equals(shown[1].message, 'память занята')
end

g.test_issues_without_findings_are_empty = function()
    t.assert_equals(model.issues(nil), {})
end

g.test_suggestions_keep_their_targets = function()
    local shown = model.suggestions({
        {
            action = 'reload_config',
            targets = { 'storage-001-a' },
            reasons = { 'конфигурация расходится' },
            message = 'перечитать конфигурацию на узлах: storage-001-a',
        },
    })

    t.assert_equals(shown[1].action, 'reload_config')
    t.assert_equals(shown[1].targets, { 'storage-001-a' })
    t.assert_equals(shown[1].reasons, { 'конфигурация расходится' })
end

g.test_suggestions_without_any_are_empty = function()
    t.assert_equals(model.suggestions(nil), {})
end

g.test_capabilities_are_declared_not_guessed = function()
    -- Панель одна на все кластеры: зашитые предположения делают её годной
    -- ровно для одного развёртывания.
    local capabilities = model.capabilities({
        failover = true,
        config_rollout = false,
        authenticated = true,
        actions = { 'reload_config', 'restart_replication' },
    })

    t.assert_equals(capabilities.failover, true)
    t.assert_equals(capabilities.config_rollout, false)
    t.assert_equals(capabilities.authenticated, true)
    t.assert_equals(capabilities.actions, { 'reload_config', 'restart_replication' })
    t.assert_equals(capabilities.version, 1)
end

g.test_capabilities_default_to_nothing = function()
    -- Кластер без надстроек умеет только показывать себя.
    local capabilities = model.capabilities()

    t.assert_equals(capabilities.failover, false)
    t.assert_equals(capabilities.config_rollout, false)
    t.assert_equals(capabilities.authenticated, false)
    t.assert_equals(capabilities.actions, {})
end

-- ── Выведенные узлы ──────────────────────────────────────────────────

--- Снимок, в котором один узел выведен из эксплуатации.
---@param overrides table|nil
---@return table
local function snapshot_with_retired(overrides)
    local taken = snapshot(overrides)

    taken.disabled = {
        ['storage-001-b'] = {
            name = 'storage-001-b',
            reason = 'отказал диск',
            author = 'admin',
            at = 1789041200,
        },
    }
    taken.disabled_read_at = 1789041290

    return taken
end

g.test_retired_server_carries_the_record = function()
    -- Причину и автора показывают человеку: через неделю по одной пометке
    -- «выведен» никто не вспомнит, почему.
    local view = model.cluster(snapshot_with_retired())

    ---@type any
    local retired = server(view, 'storage-001-b').retired

    t.assert_equals(retired ~= nil and retired.reason, 'отказал диск')
    t.assert_equals(retired ~= nil and retired.author, 'admin')
end

g.test_node_in_service_has_no_record = function()
    t.assert_equals(server(model.cluster(snapshot_with_retired()), 'storage-001-a').retired, nil)
end

g.test_retirement_does_not_replace_the_status = function()
    -- Выведенный узел обычно продолжает отвечать: подменять состояние
    -- значило бы прятать то, что с узлом на самом деле.
    local shown = server(model.cluster(snapshot_with_retired()), 'storage-001-b')

    t.assert_equals(shown.status, 'running')
    t.assert_equals(shown.reachable, true)
end

g.test_retired_are_counted_apart_from_unreachable = function()
    -- Недоступность — про связность, вывод — про намерение человека,
    -- и узел вправе быть и тем, и другим сразу.
    local view = model.cluster(snapshot_with_retired({
        instances = { ['storage-001-b'] = { reachable = false } },
    }))

    t.assert_equals(view.summary.retired, 1)
    t.assert_equals(view.summary.unreachable, 1)
end

g.test_cluster_without_retired_counts_none = function()
    local view = model.cluster(snapshot())

    t.assert_equals(view.summary.retired, 0)
    t.assert_equals(view.retired_read_at, nil)
end

g.test_time_of_the_last_successful_reading_is_shown = function()
    -- Единственный способ отличить «никого не выводили» от «хранилище
    -- молчит, показываем вчерашнее».
    t.assert_equals(model.cluster(snapshot_with_retired()).retired_read_at, 1789041290)
end
