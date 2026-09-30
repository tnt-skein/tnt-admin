--- Описание API панели: документ из маршрутов, форм и слов операций.
---
--- Документ собирает `tnt-openapi` из того, что объявлено в коде, и эти
--- проверки держат четыре стыка, которых сам документ не видит. Файл
--- описания в дереве — тот же документ: правка формы или слова без
--- пересборки файла видна здесь, а не клиенту. Аннотации форм — те же
--- объявления: класс записи, разошедшийся с формой, обманывает
--- анализатор. Ответ панели на самом деле проходит форму, которой
--- описан: форма описывает выдачу, а выдачу собирает код. И выдача
--- формы не урезает того, что собрала модель: поле, забытое в форме,
--- иначе молча пропало бы из ответа.

local json = require('json')
local t = require('luatest')
local yaml = require('yaml')

local helper = dofile('test/helper.lua')
local testing = helper.testing

local g = t.group('tnt.admin.openapi')

--- Формы из той же загрузки, что и панель: описание узнаёт форму
--- по реестру своей копии `tnt-data`.
---@type table
local data

--- Описание API панели.
---@type TntOpenapi
local api

--- Формы панели по именам схем.
---@type table<string, TntDataShape<any>>
local forms

--- Тело действия, о котором спрашивают образцы.
local ACTION = { action = 'reload_config', targets = { 'storage-001-a', 'storage-001-b' } }

--- Итог действия, удавшегося на части узлов, — как его собирает `tnt-ops`.
local PARTIAL = {
    action = 'reload_config',
    status = 'partial',
    entries = {
        ['storage-001-a'] = { ok = true, value = true },
        ['storage-001-b'] = { ok = false, err = 'узел не ответил' },
    },
    succeeded = { 'storage-001-a' },
    failed = { 'storage-001-b' },
    summary = 'reload_config: удалось на 1 из 2, не удалось на storage-001-b',
}

--- Источники со всем, что панель умеет показать: каждая форма ответа
--- получает настоящий ответ, а не пустой.
local SOURCE = {
    snapshot = function()
        return {
            generation = 7,
            taken_at = 1790000000.5,
            self_name = 'storage-001-a',
            disabled_read_at = 1790000000,
            instances = {
                ['storage-001-a'] = {
                    replicaset_name = 'storage-001',
                    advertise = { uri = 'storage-001-a:3301' },
                    reachable = true,
                    status = 'running',
                    ro = false,
                    last_seen = 1790000000.5,
                    uptime = 120.25,
                    version = '3.8.0',
                    lsn = 42,
                    clock = 1790000000.4,
                    memory = { arena_ratio = 0.5, items_ratio = 0.25, quota_ratio = 0.125 },
                    config = { status = 'ready', fingerprint = 'c0ffee' },
                    extensions = { lifecycle = { state = 'serving' } },
                },
                -- Недоступный и выведенный: у него нет ни памяти, ни
                -- конфигурации, и пустые словари обязаны уйти словарями.
                ['storage-001-b'] = {
                    replicaset_name = 'storage-001',
                    reachable = false,
                    failure = { message = 'узел не ответил' },
                },
            },
            replicasets = {
                ['storage-001'] = { instances = { 'storage-001-a', 'storage-001-b' }, leaders = { 'storage-001-a' } },
            },
            disabled = { ['storage-001-b'] = { reason = 'замена диска', at = 1789990000 } },
        }
    end,
    appointments = function()
        return { ['storage-001'] = 'storage-001-a' }
    end,
    issues = function()
        return {
            {
                id = 'replication:instance:storage-001-b',
                rule = 'replication',
                severity = 'critical',
                scope = 'instance',
                instance = 'storage-001-b',
                replicaset = 'storage-001',
                message = 'репликация с storage-001-a остановлена',
            },
        }
    end,
    suggestions = function()
        return {
            {
                action = 'restart_replication',
                targets = { 'storage-001-b' },
                message = 'перезапустить репликацию: storage-001-b',
                reasons = { 'репликация с storage-001-a остановлена' },
            },
        }
    end,
    capabilities = function()
        return { failover = true, config_rollout = true, authenticated = true, actions = { 'reload_config' } }
    end,
    filter = function()
        return {
            {
                name = 'storage-001-a',
                replicaset_name = 'storage-001',
                group_name = 'storages',
                roles = { 'app.storage' },
                sharding_roles = { 'storage' },
                labels = { zone = 'spb' },
            },
        }
    end,
    assess = function(action)
        return {
            action = action,
            risk = 'caution',
            data_loss = false,
            summary = 'узел перечитает конфигурацию',
            effects = { 'роли применяются заново' },
            warnings = {},
            manual = {},
            preconditions = { { ok = true, label = 'кворум есть', detail = 'два узла из двух' } },
            confirm = { required = false },
            fingerprint = 'c0ffee',
        }
    end,
    act = function()
        return PARTIAL
    end,
    authenticate = function(username)
        -- Приложение вправе вернуть сверх договора своё: форма открытая.
        return { username = username, readonly = false, audit = true, cookie = 'подписанная-строка' }
    end,
    authorize = function()
        return { username = 'admin', audit = true }
    end,
    audit = function()
        return function()
            return nil
        end
    end,
    audit_verify = function()
        return {
            ok = false,
            scanned = 10,
            seals = 1,
            broken_at = 5,
            reason = 'хеш записи не сошёлся',
            cursor = { after_id = 10, hash = 'ab' },
        }
    end,
}

--- Образцы удачных ответов: опознаватель операции, запрос и код.
---
--- По образцу на каждый удачный ответ, описанный формой: проверка ниже
--- требует, чтобы ни один такой ответ не остался без образца.
---@type { id: string, method: string, path: string, body: table|nil, status: integer, act: table|nil }[]
local SAMPLES = {
    { id = 'cluster', method = 'GET', path = '/api/v1/cluster', status = 200 },
    { id = 'issues', method = 'GET', path = '/api/v1/issues', status = 200 },
    { id = 'suggestions', method = 'GET', path = '/api/v1/suggestions', status = 200 },
    { id = 'overview', method = 'GET', path = '/api/v1/overview', status = 200 },
    { id = 'capabilities', method = 'GET', path = '/api/v1/capabilities', status = 200 },
    { id = 'instances', method = 'GET', path = '/api/v1/instances?groups=storages', status = 200 },
    { id = 'actions.assess', method = 'POST', path = '/api/v1/actions/assess', body = ACTION, status = 200 },
    { id = 'actions.run', method = 'POST', path = '/api/v1/actions', body = ACTION, status = 207 },
    {
        id = 'actions.run',
        method = 'POST',
        path = '/api/v1/actions',
        body = ACTION,
        status = 200,
        act = {
            action = 'reload_config',
            status = 'complete',
            entries = { ['storage-001-a'] = { ok = true } },
            succeeded = { 'storage-001-a' },
            failed = {},
            summary = 'reload_config: удалось на всех узлах (1)',
        },
    },
    {
        id = 'login',
        method = 'POST',
        path = '/api/v1/login',
        body = { username = 'admin', password = 'верный' },
        status = 200,
    },
    { id = 'audit.verify', method = 'GET', path = '/api/v1/audit/verify?after_id=9&hash=ab', status = 200 },
}

g.before_each(function()
    helper.load('tnt.admin.app.support.root')

    data = testing.module('tnt.data')
    api = testing.module('tnt.admin.app.http.openapi')
    forms = {}

    for name in pairs(helper.FORMS) do
        for _, value in pairs(testing.module(name)) do
            if data.is(value) then
                forms[value.name] = value
            end
        end
    end
end)

g.after_each(function()
    helper.unload()
end)

--- Документ панели, собранный на источниках.
---@param source table
---@return table
local function document_of(source)
    local document, problems = api.document(testing.module('tnt.admin.app.http.panel').new(source))

    t.assert_equals(problems, nil)

    return document --[[@as table]]
end

--- Операции документа по опознавателю: путь от сервера, способ и сама
--- операция.
---@param document table
---@return table<string, { path: string, method: string, operation: table }>
local function operations_of(document)
    local found = {}

    for path, item in pairs(document.paths) do
        for method, operation in pairs(item) do
            if method ~= 'servers' then
                found[operation.operationId] = { path = path, method = method, operation = operation }
            end
        end
    end

    return found
end

--- Панель на всех источниках, у которой действие отвечает названным итогом.
---@param act table|nil
---@return TntAdminPanel
local function panel_with(act)
    local source = table.copy(SOURCE)

    if act ~= nil then
        source.act = function()
            return act
        end
    end

    return helper.panel(source)
end

g.test_description_file_is_the_built_document = function()
    -- Файл описания собирает `make api-spec`: правка формы или слова
    -- без пересборки файла — договор, который разошёлся с кодом молча.
    local file = yaml.decode(testing.read_file(helper.API_SPEC))

    t.assert_equals(file, document_of({}))
end

g.test_document_does_not_depend_on_the_sources = function()
    -- Маршруты API объявлены всегда, а о недостающем источнике панель
    -- отвечает отказом: описание одно на любое развёртывание.
    t.assert_equals(document_of(SOURCE), document_of({}))
end

g.test_annotations_match_the_forms = function()
    for name, path in pairs(helper.FORMS) do
        local shapes = {}

        for _, value in pairs(testing.module(name)) do
            if data.is(value) then
                table.insert(shapes, value)
            end
        end

        t.assert_equals({ data.annotated(testing.read_file(path), shapes) }, { true }, name)
    end
end

g.test_every_answer_passes_the_form_it_is_described_with = function()
    local operations = operations_of(document_of(SOURCE))

    for _, sample in ipairs(SAMPLES) do
        local where = ('%s %s'):format(sample.id, sample.status)
        local body = sample.body ~= nil and json.encode(sample.body) or nil
        local response = panel_with(sample.act).ask(sample.method, sample.path, body)
        local described = operations[sample.id].operation.responses[tostring(sample.status)]
        local ref = described.content['application/json'].schema['$ref']
        local form = forms[ref:match('[^/]+$')]

        t.assert_equals(response.status, sample.status, where)

        local record, wrong = form.from(json.decode(response.body))

        t.assert_equals(wrong, nil, where)
        t.assert_type(record, 'table', where)
    end
end

g.test_every_answer_described_with_a_form_has_a_sample = function()
    -- Ответ, описанный формой и не проверенный образцом, описан словами
    -- формы, а не тем, что панель отдаёт.
    local described, sampled = {}, {}

    for id, entry in pairs(operations_of(document_of({}))) do
        for code, response in pairs(entry.operation.responses) do
            local media = (response.content or {})['application/json'] or {}

            if code:match('^2') and (media.schema or {})['$ref'] ~= nil then
                described[('%s %s'):format(id, code)] = true
            end
        end
    end

    for _, sample in ipairs(SAMPLES) do
        sampled[('%s %d'):format(sample.id, sample.status)] = true
    end

    t.assert_equals(sampled, described)
end

g.test_forms_keep_everything_the_model_builds = function()
    -- Выдача формы отбрасывает поле, которого форма не знает: поле,
    -- дописанное в представление кластера и забытое в форме, клиенту
    -- не уйдёт. Здесь это видно сразу, а не по жалобе клиента: ответ
    -- панели равен тому, что собрала модель, без урезания.
    local model = testing.module('tnt.admin.app.domain.cluster')
    local panel = helper.panel(SOURCE)
    local built = {
        ['/api/v1/overview'] = {
            cluster = model.cluster(SOURCE.snapshot(), { appointments = SOURCE.appointments() }),
            issues = model.issues(SOURCE.issues()),
            suggestions = model.suggestions(SOURCE.suggestions()),
        },
        ['/api/v1/capabilities'] = model.capabilities(SOURCE.capabilities()),
    }

    for path, view in pairs(built) do
        t.assert_equals(json.decode(panel.ask('GET', path).body), json.decode(json.encode(view)), path)
    end
end

g.test_cluster_answer_keeps_empty_maps_as_objects = function()
    -- Выдача формы помечает пустой словарь: без пометки память и
    -- конфигурация недоступного узла уехали бы списками `[]`.
    local response = helper.panel(SOURCE).ask('GET', '/api/v1/cluster')

    t.assert_str_contains(response.body, '"memory":{}')
    t.assert_str_contains(response.body, '"config":{}')
end

g.test_audit_limits_are_the_ones_the_panel_checks = function()
    -- Пределы номеров и бюджета написаны в описании числами: здесь видно,
    -- что панель принимает ровно их — предел проходит, за пределом отказ.
    local operations = operations_of(document_of(SOURCE))
    local panel = helper.panel(SOURCE)
    local checked = 0

    for _, id in ipairs({ 'audit.export', 'audit.verify' }) do
        for _, parameter in ipairs(operations[id].operation.parameters) do
            local schema = parameter.schema

            if schema.type == 'integer' then
                for value, status in pairs({
                    [schema.minimum] = 200,
                    [schema.minimum - 1] = 400,
                    [schema.maximum] = 200,
                    [schema.maximum + 1] = 400,
                }) do
                    local path = ('/api/v1%s?%s=%d'):format(operations[id].path, parameter.name, value)
                    local response = panel.ask('GET', path)

                    t.assert_equals(response.status, status, path)

                    if status == 400 then
                        t.assert_type(json.decode(response.body).error.fields[parameter.name], 'string', path)
                    end

                    checked = checked + 1
                end
            end
        end
    end

    -- Два номера у выгрузки, три номера и бюджет у проверки — по четыре
    -- запроса на каждый.
    t.assert_equals(checked, 24)
end

g.test_instance_filters_are_the_ones_the_panel_reads = function()
    -- Имена отбора написаны в описании: каждое панель принимает, а имя,
    -- которого там нет, отвергает.
    local operations = operations_of(document_of(SOURCE))
    local panel = helper.panel(SOURCE)
    local names = {}

    for _, parameter in ipairs(operations.instances.operation.parameters) do
        local query = parameter.style == 'deepObject' and '%s[zone]=spb' or '%s=a,b'
        local path = '/api/v1/instances?' .. query:format(parameter.name)

        t.assert_equals(panel.ask('GET', path).status, 200, path)

        table.insert(names, parameter.name)
    end

    t.assert_equals(names, { 'groups', 'replicasets', 'instances', 'roles', 'sharding_roles', 'labels' })
    t.assert_equals(panel.ask('GET', '/api/v1/instances?zone=spb').status, 400)
end
