--- Тесты HTTP-слоя панели. Источники подменяются: ни кластера, ни сервера.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')
local testing = helper.testing

local g = t.group('tnt.admin.api')

--- Записи журнала: панель пишет о каждом запросе, и проверять их надо
--- ловушкой, а не выводом прогона.
local journal = testing.capture_log()

--- Панель, собранная на последних названных источниках.
---@type TntAdminPanel
local panel

--- Сколько раз спрашивали снимок кластера.
---@type number
local snapshots

--- Что отвечают источники.
---@type table
local answers

--- Собирает панель на названных источниках.
---
--- Панель собирается заново, а не настраивается: состав маршрутов
--- зависит от того, что дали, — раздача файлов объявляется только
--- с файлами, — и проверка обязана видеть ту панель, которая получилась
--- бы на узле с такими источниками.
---@param source table
local function configure(source)
    panel = helper.panel(source)
end

--- Запрос к панели.
---@param method string
---@param path string
---@param body table|nil
---@return table
local function ask(method, path, body)
    return panel.ask(method, path, body ~= nil and json.encode(body) or nil)
end

--- Запрос к панели полями: способ, путь, тело и что положить сверх.
---@param request table
---@return table
local function handle(request)
    return panel.ask(request.method, request.path, request.body, request)
end

g.before_each(function()
    helper.load('tnt.admin.app.support.root')

    journal.forget()

    snapshots = 0
    answers = {
        snapshot = {
            generation = 3,
            taken_at = 1789041300,
            instances = {
                ['storage-001-a'] = {
                    name = 'storage-001-a',
                    replicaset_name = 'storage-001',
                    reachable = true,
                    status = 'running',
                    ro = false,
                    memory = {},
                    config = { status = 'ready' },
                },
            },
            replicasets = {
                ['storage-001'] = {
                    name = 'storage-001',
                    instances = { 'storage-001-a' },
                    leaders = { 'storage-001-a' },
                },
            },
        },
        issues = {
            { id = 'memory:instance:storage-001-a', rule = 'memory', severity = 'warning', message = 'тесно' },
        },
        suggestions = { { action = 'reload_config', targets = { 'storage-001-a' }, message = 'перечитать' } },
        appointments = { ['storage-001'] = 'storage-001-a' },
        capabilities = { failover = true, actions = { 'reload_config' } },
    }

    configure({
        snapshot = function()
            snapshots = snapshots + 1

            return answers.snapshot
        end,
        issues = function()
            return answers.issues
        end,
        suggestions = function()
            return answers.suggestions
        end,
        appointments = function()
            return answers.appointments
        end,
        capabilities = function()
            return answers.capabilities
        end,
    })
end)

g.after_each(function()
    helper.unload()
end)

--- Тело ответа.
---@param response table
---@return table
local function decoded(response)
    return json.decode(response.body)
end

g.test_cluster_is_returned = function()
    local response = ask('GET', '/api/v1/cluster')

    t.assert_equals(response.status, 200)
    t.assert_equals(response.headers['content-type'], 'application/json; charset=utf-8')
    t.assert_equals(decoded(response).servers[1].name, 'storage-001-a')
end

g.test_issues_are_returned = function()
    local response = ask('GET', '/api/v1/issues')

    t.assert_equals(response.status, 200)
    t.assert_equals(decoded(response).issues[1].rule, 'memory')
end

g.test_suggestions_are_returned = function()
    local response = ask('GET', '/api/v1/suggestions')

    t.assert_equals(decoded(response).suggestions[1].action, 'reload_config')
end

g.test_overview_takes_one_snapshot = function()
    -- Страница обзора спрашивает всё сразу: три обхода кластера подряд
    -- ради одной страницы — ровно то, чем грешил GraphQL-слой Cartridge.
    local response = ask('GET', '/api/v1/overview')
    local body = decoded(response)

    t.assert_equals(snapshots, 1)
    t.assert_equals(body.cluster.servers[1].name, 'storage-001-a')
    t.assert_equals(body.issues[1].rule, 'memory')
    t.assert_equals(body.suggestions[1].action, 'reload_config')
end

g.test_appointments_reach_the_view = function()
    local body = decoded(ask('GET', '/api/v1/cluster'))

    t.assert_equals(body.replicasets[1].leader, 'storage-001-a')
end

g.test_capabilities_are_returned = function()
    local body = decoded(ask('GET', '/api/v1/capabilities'))

    t.assert_equals(body.failover, true)
    t.assert_equals(body.actions, { 'reload_config' })
end

g.test_unknown_path_is_not_found = function()
    t.assert_equals(ask('GET', '/api/v1/nothing').status, 404)
    t.assert_equals(ask('GET', '/admin').status, 404)
end

g.test_wrong_method_is_told_apart_from_a_wrong_path = function()
    -- «Нет такого пути» и «сюда так не ходят» — разные вещи, и панель
    -- показывает их по-разному.
    local response = ask('POST', '/api/v1/cluster')

    t.assert_equals(response.status, 405)
    t.assert_str_contains(decoded(response).error.message, 'способ')
end

g.test_error_body_carries_the_code_and_the_message = function()
    local body = decoded(ask('GET', '/api/v1/nothing'))

    t.assert_equals(body.error.status, 404)
    t.assert_type(body.error.message, 'string')
end

g.test_broken_handler_does_not_leak_the_stack = function()
    -- Стек Lua в ответе — подсказка тому, кто ищет уязвимость, и мусор
    -- для того, кто просто работает.
    configure({
        snapshot = function()
            error('внутри всё сломалось')
        end,
    })

    local response = ask('GET', '/api/v1/cluster')

    t.assert_equals(response.status, 500)
    t.assert_not_str_contains(response.body, 'внутри всё сломалось')
    t.assert_not_str_contains(response.body, 'stack traceback')
end

g.test_panel_without_sources_still_answers = function()
    -- Панель подключили, а диагностику ещё нет: показывать нечего,
    -- но падать незачем.
    configure({})

    local body = decoded(ask('GET', '/api/v1/overview'))

    t.assert_equals(body.cluster.servers, {})
    t.assert_equals(body.issues, {})
    t.assert_equals(body.suggestions, {})
end

g.test_routes_are_listed = function()
    t.assert_equals(panel.routes(), {
        '/api/v1/actions',
        '/api/v1/actions/assess',
        '/api/v1/audit',
        '/api/v1/audit/verify',
        '/api/v1/capabilities',
        '/api/v1/cluster',
        '/api/v1/config',
        '/api/v1/instances',
        '/api/v1/issues',
        '/api/v1/login',
        '/api/v1/overview',
        '/api/v1/suggestions',
        -- Выкладка метрик вне общего префикса: это договор со сборщиком,
        -- а не часть API панели.
        '/metrics',
    })
end

g.test_action_is_performed = function()
    ---@type any
    local asked

    configure({
        act = function(action, targets)
            asked = { action = action, targets = targets }

            return { status = 'complete', succeeded = targets, failed = {}, summary = 'удалось' }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'reload_config', targets = { 'storage-001-a' } })

    t.assert_equals(response.status, 200)
    t.assert_equals(asked.action, 'reload_config')
    t.assert_equals(decoded(response).summary, 'удалось')
end

g.test_action_learns_who_asked_for_it = function()
    -- Решение оператора, записанное без имени, через неделю невозможно
    -- объяснить: действие обязано знать, кто его потребовал.
    ---@type any
    local asked

    configure({
        authorize = function()
            return { username = 'admin', readonly = false }
        end,

        act = function(_, targets, identity)
            asked = identity

            return { status = 'complete', succeeded = targets, failed = {}, summary = 'удалось' }
        end,
    })

    ask('POST', '/api/v1/actions', { action = 'disable_server', targets = { 'storage-001-a' } })

    t.assert_equals(asked ~= nil and asked.username, 'admin')
end

g.test_partial_action_has_its_own_code = function()
    -- Частичный успех — обычное дело, и код говорит об этом отдельно.
    configure({
        act = function()
            return {
                status = 'partial',
                succeeded = { 'storage-001-a' },
                failed = { 'storage-001-b' },
                summary = 'удалось не всем',
            }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'reload_config', targets = { 'a', 'b' } })

    t.assert_equals(response.status, 207)
    t.assert_equals(decoded(response).failed, { 'storage-001-b' })
end

g.test_action_without_arguments_is_refused = function()
    configure({
        act = function()
            return { status = 'complete' }
        end,
    })

    t.assert_equals(ask('POST', '/api/v1/actions', { action = 'reload_config' }).status, 400)
    t.assert_equals(ask('POST', '/api/v1/actions', { targets = {} }).status, 400)
end

g.test_action_on_a_cluster_without_actions_is_refused = function()
    local response = ask('POST', '/api/v1/actions', { action = 'reload_config', targets = { 'a' } })

    t.assert_equals(response.status, 501)
    t.assert_str_contains(decoded(response).error.message, 'не включены')
end

g.test_broken_body_is_refused = function()
    local response = handle({ method = 'POST', path = '/api/v1/actions', body = 'не json' })

    t.assert_equals(response.status, 400)
end

g.test_refused_action_keeps_its_reason = function()
    configure({
        act = function()
            return nil, 'такого действия нет'
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'что-нибудь', targets = { 'a' } })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'такого действия нет')
end

g.test_login_returns_the_identity = function()
    configure({
        authenticate = function(username, secret)
            if username == 'admin' and secret == 'верный' then
                return { username = 'admin', cookie = 'подписанная-строка' }
            end

            return nil
        end,
    })

    local response = ask('POST', '/api/v1/login', { username = 'admin', password = 'верный' })

    t.assert_equals(response.status, 200)
    t.assert_equals(decoded(response).cookie, 'подписанная-строка')
end

g.test_wrong_password_is_refused_without_hints = function()
    -- Причина одна на оба случая: по разным ответам подбирают имена
    -- пользователей.
    configure({
        authenticate = function()
            return nil
        end,
    })

    local response = ask('POST', '/api/v1/login', { username = 'admin', password = 'неверный' })

    t.assert_equals(response.status, 401)
    t.assert_str_contains(decoded(response).error.message, 'неверное имя или пароль')
end

g.test_login_on_a_cluster_without_auth_is_refused = function()
    t.assert_equals(ask('POST', '/api/v1/login', { username = 'admin', password = 'x' }).status, 501)
end

g.test_login_without_a_password_names_the_field = function()
    -- Без пароля проверять нечего, и до проверки пароля запрос не доходит:
    -- отказ называет поле, а не отвечает «неверное имя или пароль».
    ---@type any
    local asked

    configure({
        authenticate = function(...)
            asked = { ... }
        end,
    })

    ---@type any
    local refusal = decoded(ask('POST', '/api/v1/login', { username = 'admin' })).error

    t.assert_equals(refusal.status, 400)
    t.assert_equals(refusal.message, 'тело запроса не разобрано')
    t.assert_equals(refusal.fields, { password = 'обязательное поле' })
    t.assert_equals(asked, nil)
end

g.test_login_refusal_does_not_show_the_password = function()
    -- Пароль в форме входа скрытый: отказ называет, что с полем не так,
    -- но присланного значения не повторяет.
    ---@type any
    local refusal = decoded(ask('POST', '/api/v1/login', { username = '', password = 271828 })).error

    t.assert_equals(refusal.status, 400)
    t.assert_equals(
        refusal.fields.username,
        'должно быть строкой длиной не меньше 1 знака, а сейчас 0 знаков'
    )
    t.assert_not_str_contains(refusal.fields.password, '271828')
end

g.test_login_takes_the_credentials_from_the_form = function()
    -- Лишнее поле тела выбрасывается, а имя и пароль доходят до проверки
    -- пароля как есть.
    ---@type any
    local asked

    configure({
        authenticate = function(username, password)
            asked = { username, password }

            return { username = username }
        end,
    })

    local response = ask('POST', '/api/v1/login', { username = 'admin', password = 'верный', remember = true })

    t.assert_equals(response.status, 200)
    t.assert_equals(asked, { 'admin', 'верный' })
end

g.test_request_without_a_session_is_refused_when_auth_is_on = function()
    configure({
        authorize = function()
            return nil, 'сессии нет'
        end,
    })

    local response = ask('GET', '/api/v1/cluster')

    t.assert_equals(response.status, 401)
    t.assert_str_contains(decoded(response).error.message, 'сессии нет')
end

g.test_reader_cannot_change_the_cluster = function()
    -- Смотреть и менять — разные права: у Cartridge их не было вовсе,
    -- и любой вошедший мог изгнать узел.
    configure({
        authorize = function()
            return { username = 'viewer', readonly = true }
        end,
        act = function()
            return { status = 'complete' }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'reload_config', targets = { 'a' } })

    t.assert_equals(response.status, 403)
    t.assert_str_contains(decoded(response).error.message, 'нет права')
end

g.test_reader_may_look = function()
    configure({
        authorize = function()
            return { username = 'viewer', readonly = true }
        end,
    })

    t.assert_equals(ask('GET', '/api/v1/cluster').status, 200)
end

g.test_every_change_needs_the_right_to_change = function()
    -- Право менять кластер спрашивает слой на маршруте, а не обработчик:
    -- наблюдателю каждый путь, который меняет кластер, отвечает одним
    -- и тем же отказом, а администратор проходит.
    local readonly = true
    local reached = 0

    configure({
        authorize = function()
            return { username = 'оператор', readonly = readonly }
        end,
        assess = function()
            reached = reached + 1

            return { risk = 'safe' }
        end,
        act = function()
            reached = reached + 1

            return { status = 'complete' }
        end,
        apply_config = function()
            reached = reached + 1

            return { phase = 'done' }
        end,
    })

    local changes = {
        { '/api/v1/actions/assess', { action = 'reload_config', targets = { 'a' } } },
        { '/api/v1/actions', { action = 'reload_config', targets = { 'a' } } },
        { '/api/v1/config', { text = 'credentials: {}' } },
    }

    for _, change in ipairs(changes) do
        local refused = ask('POST', change[1], change[2])

        t.assert_equals(refused.status, 403, change[1])
        t.assert_equals(
            decoded(refused),
            { error = { status = 403, message = 'у вас нет права менять кластер' } },
            change[1]
        )
    end

    t.assert_equals(reached, 0)

    readonly = false

    for _, change in ipairs(changes) do
        t.assert_equals(ask('POST', change[1], change[2]).status, 200, change[1])
    end

    t.assert_equals(reached, #changes)
end

g.test_the_right_is_asked_before_the_body = function()
    -- Тому, кому нельзя, не рассказывают, как правильно просить: негодное
    -- тело наблюдателя — отказ по праву, а не разбор тела.
    configure({
        authorize = function()
            return { username = 'наблюдатель', readonly = true }
        end,
    })

    local response = handle({ method = 'POST', path = '/api/v1/actions', body = 'не json' })

    t.assert_equals(response.status, 403)
    t.assert_equals(decoded(response).error.message, 'у вас нет права менять кластер')
end

g.test_configuration_needs_its_own_right = function()
    local readonly = true
    local read = 0

    configure({
        authorize = function()
            return { username = 'оператор', readonly = readonly }
        end,
        config = function()
            read = read + 1

            return { credentials = {} }
        end,
    })

    local refused = ask('GET', '/api/v1/config')

    t.assert_equals(refused.status, 403)
    t.assert_equals(decoded(refused), {
        error = {
            status = 403,
            message = 'у вас нет права смотреть конфигурацию кластера',
        },
    })
    t.assert_equals(read, 0)

    readonly = false

    t.assert_equals(ask('GET', '/api/v1/config').status, 200)
    t.assert_equals(read, 1)
end

g.test_every_route_answers_with_two_hundred = function()
    -- Код ответа настоящий: панель смотрит на него, а не разбирает текст.
    for _, path in ipairs({
        '/api/v1/cluster',
        '/api/v1/issues',
        '/api/v1/suggestions',
        '/api/v1/overview',
        '/api/v1/capabilities',
    }) do
        t.assert_equals(ask('GET', path).status, 200, path)
    end
end

g.test_path_must_start_with_the_prefix = function()
    -- Префикс проверяется с начала пути: иначе панель отвечала бы
    -- на чужие адреса, где он встретился где-то в середине.
    t.assert_equals(ask('GET', '/proxy/api/v1/cluster').status, 404)
    t.assert_equals(ask('GET', '/api/v1/cluster').status, 200)
end

g.test_a_request_without_a_path_is_the_root_page = function()
    -- Пути нет — роутер читает это как корень, и панель отвечает
    -- страницей обзора: своего разбора адреса у неё нет, и выдумывать
    -- второй ей незачем.
    local response = panel.serve({ method = 'GET', query = '', headers = {} })

    t.assert_equals(response.status, 200)
    t.assert_str_contains(response.body, 'Обзор')
end

g.test_body_that_is_not_an_object_is_refused = function()
    -- Тело разобралось, но это не запись: полей у числа не спросишь.
    configure({
        act = function()
            return { status = 'complete' }
        end,
    })

    local response = handle({ method = 'POST', path = '/api/v1/actions', body = '42' })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'тело запроса не разобрано')
end

g.test_broken_body_explains_itself = function()
    local response = handle({ method = 'POST', path = '/api/v1/login', body = 'не json' })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'тело запроса не разобрано')
end

g.test_empty_body_is_an_empty_object = function()
    -- Запрос без тела — это не ошибка JSON: у входа просто нет имени
    -- и пароля, и отказ называет оба поля.
    configure({
        authenticate = function()
            return nil
        end,
    })

    local response = handle({ method = 'POST', path = '/api/v1/login' })

    t.assert_equals(response.status, 400)
    t.assert_equals(decoded(response).error.fields, {
        username = 'обязательное поле',
        password = 'обязательное поле',
    })
end

g.test_login_refusal_has_its_own_code = function()
    configure({
        authenticate = function()
            return nil
        end,
    })

    t.assert_equals(ask('POST', '/api/v1/login', { username = 'admin', password = 'x' }).status, 401)
end

g.test_anonymous_panel_is_not_readonly = function()
    -- Вход не настроен: панель открыта, и это осознанный выбор
    -- развёртывания. Действия при этом разрешены.
    configure({
        act = function()
            return { status = 'complete' }
        end,
    })

    t.assert_equals(ask('POST', '/api/v1/actions', { action = 'reload_config', targets = { 'a' } }).status, 200)
end

g.test_open_panel_grants_full_rights = function()
    -- Панель без входа, которая ничего не даёт делать, бесполезна.
    configure({
        act = function()
            return { status = 'complete', summary = 'удалось' }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'reload_config', targets = { 'a' } })

    t.assert_equals(response.status, 200)
    t.assert_equals(decoded(response).summary, 'удалось')
end

g.test_silent_authorizer_still_explains_itself = function()
    -- Проверка входа отказала, не назвав причины: панель обязана сказать
    -- хоть что-то, иначе в браузере пусто.
    configure({
        authorize = function()
            return nil
        end,
    })

    local response = ask('GET', '/api/v1/cluster')

    t.assert_equals(response.status, 401)
    t.assert_str_contains(decoded(response).error.message, 'войдите в панель')
end

-- ── Ворота перед опасным действием ───────────────────────────────────

--- Оценка опасного действия в том виде, в каком её отдаёт узел.
---@return table
local function dangerous_assessment()
    return {
        action = 'maintenance.purge',
        risk = 'dangerous',
        data_loss = true,
        summary = 'будут стёрты карантинные файлы',
        fingerprint = 'отпечаток',
        confirm = { required = true, token = 'PURGE storage-001-a' },
    }
end

g.test_assessment_is_returned_before_the_action = function()
    -- Оценка показывается до того, как что-то произошло: в ней написано,
    -- что именно случится и каким словом это подтверждают.
    ---@type any
    local asked

    configure({
        assess = function(action, targets, identity)
            asked = { action = action, targets = targets, username = identity.username }

            return dangerous_assessment()
        end,
    })

    local response = ask('POST', '/api/v1/actions/assess', {
        action = 'maintenance.purge',
        targets = { 'storage-001-a' },
    })

    t.assert_equals(response.status, 200)
    t.assert_equals(asked.action, 'maintenance.purge')
    t.assert_equals(decoded(response).confirm.token, 'PURGE storage-001-a')
end

g.test_assessment_is_not_shown_to_a_guest = function()
    -- В оценке написано, что случится с кластером: гостю этого знать
    -- незачем ровно так же, как и нажимать кнопку.
    configure({
        authorize = function()
            return { username = 'гость', readonly = true }
        end,
        assess = dangerous_assessment,
    })

    t.assert_equals(ask('POST', '/api/v1/actions/assess', { action = 'x', targets = {} }).status, 403)
end

g.test_assessment_without_a_provider_is_not_available = function()
    configure({})

    local response = ask('POST', '/api/v1/actions/assess', { action = 'x', targets = {} })

    t.assert_equals(response.status, 501)
    t.assert_str_contains(decoded(response).error.message, 'не включена')
end

g.test_assessment_needs_action_and_targets = function()
    configure({ assess = dangerous_assessment })

    t.assert_equals(ask('POST', '/api/v1/actions/assess', { action = 'x' }).status, 400)
end

g.test_refused_assessment_is_reported = function()
    configure({
        assess = function()
            return nil, 'операция неизвестна'
        end,
    })

    local response = ask('POST', '/api/v1/actions/assess', { action = 'x', targets = {} })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'неизвестна')
end

--- Ловит подтверждение, с которым панель позвала действие.
---@return fun(): any
local function catching_confirmation()
    ---@type any
    local received

    configure({
        act = function(_, targets, _, confirmation)
            received = confirmation

            return { status = 'complete', succeeded = targets, failed = {}, summary = 'удалось' }
        end,
    })

    return function()
        return received
    end
end

g.test_confirmation_reaches_the_action = function()
    -- Разбирать подтверждение панель не умеет и не должна: она передаёт
    -- его тому, у кого стоят ворота.
    local caught = catching_confirmation()

    ask('POST', '/api/v1/actions', {
        action = 'maintenance.purge',
        targets = { 'storage-001-a' },
        fingerprint = 'отпечаток',
        acknowledge = true,
        confirm_token = 'PURGE storage-001-a',
        answers = { failover_paused = true, backup_taken = true },
    })

    local received = caught()

    t.assert_equals(received.fingerprint, 'отпечаток')
    t.assert_equals(received.acknowledge, true)
    t.assert_equals(received.confirm_token, 'PURGE storage-001-a')

    -- Ответы на требования — утверждения оператора о том, что он сделал.
    -- Проверить их некому, но ответить за них он должен явно.
    t.assert_equals(received.answers.failover_paused, true)
end

g.test_request_key_reaches_the_node = function()
    -- Браузер, не дождавшийся ответа, шлёт тот же запрос заново. Ключ
    -- едет узлу нетронутым: узнать в повторе повтор может только он.
    local caught = catching_confirmation()

    ask('POST', '/api/v1/actions', {
        action = 'cluster.reload_config',
        targets = { 'storage-001-a' },
        key = 'нажатие-17',
    })

    t.assert_equals(caught().key, 'нажатие-17')
end

g.test_missing_confirmation_gets_its_own_code = function()
    -- «Нужно подтверждение» — единственный случай, когда от оператора
    -- ждут дополнительного шага, и для него есть отдельный код.
    configure({
        act = function()
            return {
                refused = { allow = false, code = 'CONFIRMATION_REQUIRED', message = 'нужно слово' },
                assessment = dangerous_assessment(),
            }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } })
    local body = decoded(response)

    t.assert_equals(response.status, 428)
    t.assert_equals(body.error.code, 'CONFIRMATION_REQUIRED')
    t.assert_equals(body.assessment.confirm.token, 'PURGE storage-001-a')
end

g.test_stale_state_is_a_conflict = function()
    -- Состояние изменилось: это конфликт с тем, что произошло на кластере,
    -- а не ошибка запроса.
    configure({
        act = function()
            return {
                refused = { allow = false, code = 'STALE_FINGERPRINT', message = 'посмотрите заново' },
                assessment = dangerous_assessment(),
            }
        end,
    })

    t.assert_equals(ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } }).status, 409)
end

g.test_unmet_precondition_is_a_conflict_too = function()
    configure({
        act = function()
            return {
                refused = { allow = false, code = 'PRECONDITION_FAILED', message = 'сначала снимок' },
            }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } })

    t.assert_equals(response.status, 409)
    t.assert_str_contains(decoded(response).error.message, 'снимок')
end

g.test_unknown_refusal_code_is_a_plain_error = function()
    -- Ворота вправе отказать по причине, которой панель не знает: код
    -- тогда общий, а сообщение всё равно доходит.
    configure({
        act = function()
            return { refused = { allow = false, code = 'НЕЧТО', message = 'так нельзя' } }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'так нельзя')
end

g.test_refusal_without_a_message_still_says_something = function()
    configure({
        act = function()
            return { refused = { allow = false, code = 'CONFIRMATION_REQUIRED' } }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } })

    t.assert_str_contains(decoded(response).error.message, 'отвергнуто')
end

g.test_unreadable_assessment_request_is_refused = function()
    -- Тело приходит из браузера и вправе оказаться чем угодно.
    configure({ assess = dangerous_assessment })

    local response = handle({
        method = 'POST',
        path = '/api/v1/actions/assess',
        body = 'не json вовсе',
    })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'не разобрано')
end

-- ── Конфигурация кластера ────────────────────────────────────────────

g.test_configuration_is_shown_to_an_operator = function()
    configure({
        config = function()
            return { revision = 42, text = 'groups: {}', applied = { ['storage-001-a'] = 42 } }
        end,
    })

    local response = ask('GET', '/api/v1/config')
    local body = decoded(response)

    t.assert_equals(response.status, 200)
    t.assert_equals(body.revision, 42)
    t.assert_equals(body.applied['storage-001-a'], 42)
end

g.test_configuration_is_not_shown_to_a_guest = function()
    -- В конфигурации учётные записи и адреса: гостю её знать незачем.
    configure({
        authorize = function()
            return { username = 'гость', readonly = true }
        end,
        config = function()
            return { revision = 42 }
        end,
    })

    t.assert_equals(ask('GET', '/api/v1/config').status, 403)
end

g.test_unreadable_configuration_is_reported = function()
    configure({
        config = function()
            return nil, 'хранилище не отвечает'
        end,
    })

    local response = ask('GET', '/api/v1/config')

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'не отвечает')
end

g.test_configuration_without_a_provider_is_not_available = function()
    configure({})

    t.assert_equals(ask('GET', '/api/v1/config').status, 501)
end

g.test_edit_is_rolled_out = function()
    ---@type any
    local asked

    configure({
        apply_config = function(text, removing, identity)
            asked = { text = text, removing = removing, username = identity.username }

            return { phase = 'converge', revision = 43, converged = { 'storage-001-a' }, pending = {} }
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'groups: {}', removing = { 'storage-001-b' } })

    t.assert_equals(response.status, 200)
    t.assert_equals(asked.text, 'groups: {}')
    t.assert_equals(asked.removing, { 'storage-001-b' })
    t.assert_equals(decoded(response).revision, 43)
end

g.test_edit_without_text_is_refused = function()
    configure({
        apply_config = function()
            return { phase = 'converge' }
        end,
    })

    t.assert_equals(ask('POST', '/api/v1/config', { removing = {} }).status, 400)
    t.assert_equals(ask('POST', '/api/v1/config', { text = '' }).status, 400)
end

g.test_edit_that_breaks_topology_is_a_conflict = function()
    -- Правка не прошла сверку: это конфликт с тем, что есть на кластере,
    -- и в ответе видно, на какой фазе всё кончилось.
    configure({
        apply_config = function()
            return {
                phase = 'topology',
                pending = { 'storage-001-a' },
                errors = { ['storage-001-b'] = 'узел вычеркнут' },
                err = 'правка ломает топологию кластера',
            }
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'groups: {}' })
    local body = decoded(response)

    t.assert_equals(response.status, 409)
    t.assert_equals(body.error.phase, 'topology')
    t.assert_str_contains(body.error.message, 'ломает топологию')
    t.assert_str_contains(body.rollout.errors['storage-001-b'], 'вычеркнут')
end

g.test_edit_that_did_not_converge_is_a_conflict_too = function()
    -- Запись прошла, а доехала не до всех: чинится это перечитыванием
    -- на отставших, а не повтором раскатки — поэтому фаза в ответе.
    configure({
        apply_config = function()
            return {
                phase = 'converge',
                revision = 43,
                converged = { 'storage-001-a' },
                pending = { 'storage-001-b' },
                err = 'конфигурация записана, но применена не всеми',
            }
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'groups: {}' })

    t.assert_equals(response.status, 409)
    t.assert_equals(decoded(response).rollout.revision, 43)
end

g.test_every_rollout_phase_is_a_conflict = function()
    -- Фазы различаются тем, что успело записаться, но исход у всех один:
    -- это конфликт с тем, что происходит на кластере, а не ошибка запроса,
    -- и повторять её тем же запросом бессмысленно.
    for _, phase in ipairs({ 'topology', 'prepare', 'commit', 'converge' }) do
        configure({
            apply_config = function()
                return { phase = phase, err = 'так вышло' }
            end,
        })

        local response = ask('POST', '/api/v1/config', { text = 'x' })

        t.assert_equals(response.status, 409, phase)
        t.assert_equals(decoded(response).error.status, 409, phase)
    end
end

g.test_unknown_rollout_phase_is_a_plain_error = function()
    configure({
        apply_config = function()
            return { phase = 'нечто', err = 'так вышло' }
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'x' })

    t.assert_equals(response.status, 400)
    t.assert_equals(decoded(response).error.status, 400)
end

g.test_refused_rollout_is_reported = function()
    configure({
        apply_config = function()
            return nil, 'хранилище недоступно'
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'x' })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'недоступно')
end

g.test_edit_without_a_provider_is_not_available = function()
    configure({})

    t.assert_equals(ask('POST', '/api/v1/config', { text = 'x' }).status, 501)
end

g.test_edit_is_not_allowed_to_a_guest = function()
    configure({
        authorize = function()
            return { username = 'гость', readonly = true }
        end,
        apply_config = function()
            return { phase = 'converge' }
        end,
    })

    t.assert_equals(ask('POST', '/api/v1/config', { text = 'x' }).status, 403)
end

g.test_unreadable_edit_request_is_refused = function()
    configure({
        apply_config = function()
            return { phase = 'converge' }
        end,
    })

    local response = handle({ method = 'POST', path = '/api/v1/config', body = 'не json' })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'тело запроса не разобрано')
end

g.test_too_many_guesses_are_answered_with_a_deadline = function()
    -- Отказ без срока читается как поломка, и по нему стучат ещё чаще.
    -- Срок отличает «неверный пароль» от «слишком много попыток», и коды
    -- ответа у них поэтому разные.
    configure({
        authenticate = function()
            return nil, 'слишком много попыток: попробуйте через 42 с', 42
        end,
    })

    local response = ask('POST', '/api/v1/login', { username = 'admin', password = 'x' })

    t.assert_equals(response.status, 429)
    t.assert_equals(response.headers['retry-after'], '42')
    -- Приложение объясняет своими словами: срок в них уже назван.
    t.assert_str_contains(decoded(response).error.message, 'через 42 с')
end

g.test_silent_refusal_is_explained_by_the_panel = function()
    -- Приложение вправе отказать молча: слову в ответе всё равно надо
    -- быть, иначе оператор увидит пустой отказ.
    configure({
        authenticate = function()
            return nil, nil, 7
        end,
    })

    local response = ask('POST', '/api/v1/login', { username = 'admin', password = 'x' })

    t.assert_equals(response.status, 429)
    t.assert_str_contains(decoded(response).error.message, 'слишком много попыток')
end

g.test_wrong_password_without_a_deadline_stays_unauthorised = function()
    configure({
        authenticate = function()
            return nil, 'неверное имя или пароль'
        end,
    })

    local response = ask('POST', '/api/v1/login', { username = 'admin', password = 'x' })

    t.assert_equals(response.status, 401)
    t.assert_equals(response.headers['retry-after'], nil)
end

-- ── Выкладка метрик ──────────────────────────────────────────────────

g.test_metrics_are_exposed_as_text = function()
    -- Сборщик читает текст построчно и ничего другого не понимает:
    -- JSON здесь был бы вежливым отказом работать.
    configure({
        metrics = function()
            return 'cluster_up 1\n'
        end,
    })

    local response = handle({ method = 'GET', path = '/metrics' })

    t.assert_equals(response.status, 200)
    t.assert_equals(response.body, 'cluster_up 1\n')

    -- Тип объявляется целиком: без версии сборщик разбирает выкладку
    -- по самому старому уговору, а без кодировки — в кодировке страницы,
    -- и кириллица в именах узлов превращается в вопросительные знаки.
    t.assert_equals(response.headers['content-type'], 'text/plain; version=0.0.4; charset=utf-8')
end

g.test_metrics_do_not_need_a_session = function()
    -- У сборщика нет ни cookie, ни сессии: опознавать его общим способом
    -- значит закрыть выкладку насовсем.
    configure({
        authorize = function()
            return nil, 'войдите в панель'
        end,

        metrics = function()
            return 'cluster_up 1\n'
        end,
    })

    t.assert_equals(handle({ method = 'GET', path = '/metrics' }).status, 200)
end

g.test_application_decides_who_may_scrape = function()
    -- Кому отдавать выкладку, решает приложение: у него и credentials,
    -- и понимание, кто за ними стоит.
    configure({
        metrics = function(request)
            if (request.headers or {}).authorization ~= 'Bearer слово' then
                return nil, 'сборщик не назвался'
            end

            return 'cluster_up 1\n'
        end,
    })

    local refused = handle({ method = 'GET', path = '/metrics' })

    t.assert_equals(refused.status, 401)
    t.assert_str_contains(decoded(refused).error.message, 'не назвался')

    local allowed = handle({
        method = 'GET',
        path = '/metrics',
        headers = { authorization = 'Bearer слово' },
    })

    t.assert_equals(allowed.status, 200)
end

g.test_metrics_without_a_provider_are_not_available = function()
    configure({})

    local response = handle({ method = 'GET', path = '/metrics' })

    t.assert_equals(response.status, 501)
    t.assert_str_contains(decoded(response).error.message, 'не включена')
end

g.test_metrics_are_only_read = function()
    configure({
        metrics = function()
            return 'cluster_up 1\n'
        end,
    })

    t.assert_equals(handle({ method = 'POST', path = '/metrics' }).status, 405)
end

g.test_broken_metrics_do_not_leak_the_stack = function()
    configure({
        metrics = function()
            error('внутри всё сломалось')
        end,
    })

    local response = handle({ method = 'GET', path = '/metrics' })

    ---@type any
    local refusal = decoded(response).error

    t.assert_equals(response.status, 500)
    t.assert_not_str_contains(response.body, 'внутри всё сломалось')
    t.assert_str_contains(refusal.message, 'Внутренняя ошибка')

    -- Опознаватель называют дежурному: по нему запись о поломке находится
    -- в журнале, а подробности лежат там, а не в ответе.
    t.assert_str_contains(refusal.message, refusal.incident)
end

g.test_metrics_path_is_advertised = function()
    -- Список маршрутов читает и тот, кто подключает панель, и гейт
    -- описания API: маршрут, которого в нём нет, — молчаливый договор.
    local found = false

    for _, route in ipairs(panel.routes()) do
        if route == '/metrics' then
            found = true
        end
    end

    t.assert_equals(found, true)
end

-- ── Раздача самой панели ─────────────────────────────────────────────

--- Файлы панели в том виде, в каком они приезжают вместе с кодом.
local PANEL = {
    ['index.html'] = '<h1>панель</h1>',
    ['app.js'] = 'const refresh = 5000;',
}

g.test_panel_files_are_served_from_the_bundle = function()
    -- Файлы лежат не на диске, а в самом приложении: отдельного веб-сервера
    -- для статики нет, и расхождению версий взяться неоткуда.
    configure({ panel = PANEL })

    local response = handle({ method = 'GET', path = '/app.js' })

    t.assert_equals(response.status, 200)
    t.assert_equals(response.body, 'const refresh = 5000;')
    t.assert_str_contains(response.headers['content-type'], 'application/javascript')
end

g.test_unknown_address_is_refused_and_not_answered_with_a_page = function()
    -- Страницы рисует узел, и адрес, которого у панели нет, — это промах,
    -- а не повод отдать первую страницу с кодом 200. Прежде панель
    -- рисовала адреса сама, и опечатка в пути выглядела как успех.
    configure({ panel = PANEL })

    t.assert_equals(handle({ method = 'GET', path = '/nodes' }).status, 404)
end

g.test_browser_that_kept_the_file_gets_no_body = function()
    configure({ panel = PANEL })

    local first = handle({ method = 'GET', path = '/app.js' })
    local again = handle({
        method = 'GET',
        path = '/app.js',
        headers = { ['If-None-Match'] = first.headers.etag },
    })

    t.assert_equals(again.status, 304)
    t.assert_equals(again.body, nil)
end

g.test_unknown_api_address_stays_a_refusal_next_to_the_panel = function()
    -- Иначе клиент, ошибшийся в адресе API, получил бы первую страницу
    -- с кодом 200 и стал бы разбирать HTML как JSON.
    configure({ panel = PANEL })

    local response = handle({ method = 'GET', path = '/api/v1/nothing' })

    t.assert_equals(response.status, 404)
    t.assert_not_str_contains(response.body, 'панель')
end

g.test_unknown_metrics_address_stays_a_refusal_next_to_the_panel = function()
    -- Выкладка метрик — договор со сборщиком, а не страница: ошибившись
    -- в адресе, он должен получить отказ, а не HTML с кодом 200, который
    -- попробует разобрать построчно.
    configure({ panel = PANEL })

    local response = handle({ method = 'GET', path = '/metrics/всё' })

    t.assert_equals(response.status, 404)
    t.assert_not_str_contains(response.body, 'панель')
end

g.test_wrong_method_is_told_apart_next_to_the_panel = function()
    -- Раздача объявлена только на GET: объявленная на все способы, она
    -- подменяла бы 405 на первую страницу с кодом 200.
    configure({ panel = PANEL })

    local response = handle({ method = 'POST', path = '/api/v1/cluster' })

    t.assert_equals(response.status, 405)
    t.assert_equals(response.headers.allow, 'GET, HEAD, OPTIONS')
end

g.test_panel_is_not_listed_among_the_api_routes = function()
    -- Раздача — не договор с клиентом, а первая страница: описывать её
    -- в перечне API нечего, и перечень от неё меняться не должен.
    local without = panel.routes()

    configure({ panel = PANEL })

    t.assert_equals(panel.routes(), without)
    t.assert_equals(#without, 13)
end

-- ── Опознание оператора ──────────────────────────────────────────────

g.test_the_authorizer_sees_the_request_itself = function()
    -- Опознание приходит от приложения, и решает оно по самому запросу:
    -- способ, путь и заголовки — всё, по чему узнают оператора, — доезжают
    -- до него как есть.
    ---@type any
    local seen

    configure({
        authorize = function(request)
            seen = { method = request.method, path = request.path, cookie = request.headers.cookie }

            return { username = 'admin', readonly = false }
        end,
    })

    handle({
        method = 'GET',
        path = '/api/v1/cluster',
        headers = { cookie = 'session=внутри' },
    })

    t.assert_equals(seen, { method = 'GET', path = '/api/v1/cluster', cookie = 'session=внутри' })
end

g.test_identity_of_one_request_does_not_reach_the_next_one = function()
    -- Личность прошлого запроса, дожившая до следующего, отдала бы чужому
    -- клиенту чужие права.
    configure({
        authorize = function(request)
            if request.headers.cookie == nil then
                return nil, 'сессии нет'
            end

            return { username = 'admin', readonly = false }
        end,
    })

    t.assert_equals(
        handle({
            method = 'GET',
            path = '/api/v1/cluster',
            headers = { cookie = 'session=внутри' },
        }).status,
        200
    )
    t.assert_equals(handle({ method = 'GET', path = '/api/v1/cluster' }).status, 401)
end

g.test_client_address_reaches_the_login = function()
    -- По адресу вход считает неудачные догадки: без него счёт ведётся
    -- по одному имени на весь свет.
    ---@type any
    local seen

    configure({
        authenticate = function(_, _, request)
            seen = request.peer

            return { username = 'admin' }
        end,
    })

    handle({
        method = 'POST',
        path = '/api/v1/login',
        body = json.encode({ username = 'admin', password = 'верный' }),
        peer = { host = '10.0.0.7' },
    })

    t.assert_equals(seen, { host = '10.0.0.7' })
end

g.test_identifier_of_the_neighbour_is_kept = function()
    -- Запрос, прошедший через обратный прокси, обязан остаться одним
    -- запросом: иначе след обрывается на границе узла.
    ---@type any
    local seen

    configure({
        metrics = function(request)
            seen = request.request_id

            return 'cluster_up 1\n'
        end,
    })

    handle({
        method = 'GET',
        path = '/metrics',
        headers = { ['X-Request-Id'] = 'от-соседа' },
    })

    t.assert_equals(seen, 'от-соседа')

    handle({ method = 'GET', path = '/metrics' })

    -- Своего опознавателя у запроса не было — панель выдала его сама.
    t.assert_type(seen, 'string')
    t.assert_not_equals(seen, 'от-соседа')
end

g.test_the_trace_of_the_neighbour_is_continued_and_a_new_one_is_started_without_it = function()
    -- Трасса едет вместе с опознавателем: заголовок `traceparent` соседа
    -- продолжается серверным отрезком панели, а без него трасса новая.
    -- Модуль берётся после загрузки панели: ей достался тот же экземпляр.
    local trace = require('tnt.trace')
    local context = require('tnt.context')

    ---@type any
    local seen

    configure({
        metrics = function()
            seen = { current = trace.current(), exported = context.export() }

            return 'cluster_up 1\n'
        end,
    })

    local trace_id = '4bf92f3577b34da6a3ce929d0e0e4736'

    handle({
        method = 'GET',
        path = '/metrics',
        headers = {
            ['X-Request-Id'] = 'r-7',
            Traceparent = '00-' .. trace_id .. '-00f067aa0ba902b7-01',
            Tracestate = 'congo=t61rcWkgMzE',
        },
    })

    t.assert_equals(seen.current.trace_id, trace_id)
    t.assert_equals(seen.current.trace_flags, '01')
    t.assert_equals(#seen.current.span_id, 16)
    t.assert_not_equals(seen.current.span_id, '00f067aa0ba902b7')
    t.assert_equals(seen.exported['x-request-id'], 'r-7')
    t.assert_equals(seen.exported.traceparent, '00-' .. trace_id .. '-' .. seen.current.span_id .. '-01')
    t.assert_equals(seen.exported.tracestate, 'congo=t61rcWkgMzE')

    -- Запись слоя журнала — ниже трассы — несёт её опознаватели.
    ---@type any
    local passed = nil

    for _, entry in ipairs(journal.records()) do
        if entry.module == 'tnt.admin' and entry.record.message == 'запрос прошёл' then
            passed = entry.record
        end
    end

    t.assert_equals(passed.trace_id, trace_id)
    t.assert_equals(passed.span_id, seen.current.span_id)
    t.assert_equals(passed.request_id, 'r-7')

    handle({ method = 'GET', path = '/metrics' })

    t.assert_equals(#seen.current.trace_id, 32)
    t.assert_not_equals(seen.current.trace_id, trace_id)
    t.assert_equals(seen.current.trace_flags, '03')
    t.assert_equals(trace.current(), nil)
end

-- ── Опознаватель и трасса у каждого ответа ───────────────────────────

--- Записи журнала с этим словом, сделанные журналом с этим именем.
---@param module string
---@param message string
---@return any[]
local function written(module, message)
    local found = {}

    for _, entry in ipairs(journal.records()) do
        if entry.module == module and entry.record.message == message then
            table.insert(found, entry.record)
        end
    end

    return found
end

--- Серверные отрезки, записанные за время `fn`.
---
--- Трасса — установленная копия, общая на процесс: запись включается
--- только на время проверки и выключается в любом исходе, иначе она
--- досталась бы соседним наборам. Модуль берётся после загрузки панели —
--- ей достался тот же экземпляр.
---@param fn fun()
---@return table[]
local function recorded(fn)
    local trace = require('tnt.trace')

    trace.configure({ record = true })

    -- Чужие отрезки, если кто-то оставил запись включённой, снимаются
    -- заранее: проверка считает только свои.
    trace.take(trace.DEFAULT_CAPACITY)

    local ok, err = pcall(fn)
    local spans = trace.take(trace.DEFAULT_CAPACITY)

    trace.configure({})

    if not ok then
        error(err, 0)
    end

    return spans
end

g.test_misses_of_the_router_leave_with_the_request_id_and_a_record = function()
    -- Промах роутер отвечает до маршрута, но не до слоёв входа: оператор,
    -- которому панель ответила 404, называет номер из ответа, и по нему
    -- находятся и запись о запросе, и запись роутера об отказе.
    local cases = {
        { method = 'GET', path = '/api/v1/nothing', status = 404 },
        { method = 'POST', path = '/api/v1/cluster', status = 405 },
    }

    for index, case in ipairs(cases) do
        journal.forget()

        local id = 'мимо-' .. index
        local response = handle({ method = case.method, path = case.path, headers = { ['X-Request-Id'] = id } })
        local passed = written('tnt.admin', 'запрос прошёл')
        local refused = written('tnt.router', 'запрос отклонён')

        t.assert_equals(response.status, case.status)
        t.assert_equals(response.headers['x-request-id'], id)
        t.assert_equals(#passed, 1, 'запись слоя журнала о промахе')
        t.assert_equals(passed[1].request_id, id)
        t.assert_equals(passed[1].fields.status, case.status)
        t.assert_equals(passed[1].fields.path, case.path)
        t.assert_equals(#refused, 1)
        t.assert_equals(
            refused[1].request_id,
            id,
            'отказ роутера — в области опознавателя'
        )
    end
end

g.test_body_over_the_limit_leaves_with_the_request_id_too = function()
    -- Тело не в пределах отвергает подключение к серверу — до маршрута,
    -- но не до слоёв входа: у запроса есть голова, и журналу
    -- с опознавателем есть что записать.
    local response = panel.serve({
        method = 'POST',
        path = '/api/v1/actions',
        query = '',
        headers = { ['content-length'] = tostring(2 * 1024 * 1024), ['x-request-id'] = 'тело-1' },
        read = function()
            error('тело сверх предела читать нельзя')
        end,
    })

    local passed = written('tnt.admin', 'запрос прошёл')

    t.assert_equals(response.status, 413)
    t.assert_equals(response.headers['x-request-id'], 'тело-1')
    t.assert_equals(decoded(response).error.message, 'тело запроса слишком велико')
    t.assert_equals(#passed, 1)
    t.assert_equals({ passed[1].request_id, passed[1].fields.status }, { 'тело-1', 413 })
end

g.test_every_answer_carries_the_request_id_of_its_record = function()
    -- Номер в ответе — тот же, что в записи о запросе: свой, если сосед
    -- не прислал своего, и соседский, если прислал.
    local own = handle({ method = 'GET', path = '/api/v1/cluster' })
    local passed = written('tnt.admin', 'запрос прошёл')

    t.assert_equals(own.status, 200)
    t.assert_type(own.headers['x-request-id'], 'string')
    t.assert_equals(#passed, 1)
    t.assert_equals(passed[1].request_id, own.headers['x-request-id'])

    local given = handle({ method = 'GET', path = '/api/v1/cluster', headers = { ['X-Request-Id'] = 'r-9' } })

    t.assert_equals(given.status, 200)
    t.assert_equals(given.headers['x-request-id'], 'r-9')
end

g.test_broken_handler_is_drawn_by_the_guard_of_the_route = function()
    -- Поломку обработчика ловит страж у маршрута, а не роутер: о ней одна
    -- запись каталога с номером из ответа, а запись о запросе стоит выше
    -- и видит уже ответ 500.
    configure({
        snapshot = function()
            error('внутри всё сломалось')
        end,
    })

    local response = handle({
        method = 'GET',
        path = '/api/v1/cluster',
        headers = { ['X-Request-Id'] = 'сломано-1' },
    })

    ---@type any
    local shown = decoded(response).error
    local breakdowns = written('tnt.error', 'внутренняя поломка')
    local passed = written('tnt.admin', 'запрос прошёл')

    t.assert_equals(response.status, 500)
    t.assert_equals(response.headers['x-request-id'], 'сломано-1')
    t.assert_equals(#breakdowns, 1)
    t.assert_str_contains(tostring(breakdowns[1].fields.reason), 'внутри всё сломалось')
    t.assert_equals(breakdowns[1].fields.incident, shown.incident)
    t.assert_equals(#passed, 1)
    t.assert_equals({ passed[1].request_id, passed[1].fields.status }, { 'сломано-1', 500 })
    t.assert_equals(written('tnt.router', 'запрос отклонён'), {})
end

g.test_every_answer_gets_a_server_span_and_a_miss_is_named_by_the_method = function()
    -- Трасса соседа продолжается и на промахе: отрезок есть у всякого
    -- ответа панели. Имя у промаха — один способ: шаблона маршрута у него
    -- нет, а путь с номером записи дал бы имя на каждую запись. Ответ 500,
    -- собранный перехватом у маршрута, отрезок видит и ставит ему ошибку.
    local trace_id = '4bf92f3577b34da6a3ce929d0e0e4736'
    local parent_id = '00f067aa0ba902b7'
    local headers = { traceparent = ('00-%s-%s-01'):format(trace_id, parent_id) }

    local spans = recorded(function()
        handle({ method = 'GET', path = '/api/v1/nothing', headers = headers })
        handle({ method = 'POST', path = '/api/v1/cluster', headers = headers })
        handle({ method = 'GET', path = '/api/v1/cluster', headers = headers })

        configure({
            snapshot = function()
                error('внутри всё сломалось')
            end,
        })

        handle({ method = 'GET', path = '/api/v1/cluster', headers = headers })
    end)

    t.assert_equals(#spans, 4)

    ---@type any
    local expected = {
        { name = 'GET', code = 404, status = 'unset' },
        { name = 'POST', code = 405, status = 'unset' },
        { name = 'GET /api/v1/cluster', code = 200, status = 'unset', route = '/api/v1/cluster' },
        { name = 'GET /api/v1/cluster', code = 500, status = 'error', route = '/api/v1/cluster' },
    }

    for index, span in ipairs(spans) do
        local wanted = expected[index]

        t.assert_equals(
            { span.trace_id, span.parent_id, span.kind, span.name, span.status },
            { trace_id, parent_id, 'server', wanted.name, wanted.status },
            index
        )
        t.assert_equals(span.attributes['http.response.status_code'], wanted.code, index)
        t.assert_equals(span.attributes['http.route'], wanted.route, index)
    end
end

g.test_refusal_names_the_field_that_did_not_fit = function()
    -- Общую фразу панель показывает оператору, а разметить поля формы
    -- может только по списку полей.
    configure({
        act = function()
            return { status = 'complete' }
        end,
    })

    ---@type any
    local refusal = decoded(ask('POST', '/api/v1/actions', { action = 'reload_config' })).error

    t.assert_equals(refusal.message, 'нужны действие и список узлов')
    t.assert_type(refusal.fields.targets, 'string')
end

g.test_rollout_refusal_names_the_field_too = function()
    configure({
        apply_config = function()
            return { phase = 'converge' }
        end,
    })

    ---@type any
    local refusal = decoded(ask('POST', '/api/v1/config', { removing = {} })).error

    t.assert_equals(refusal.message, 'нужен текст новой конфигурации')
    t.assert_type(refusal.fields.text, 'string')
end

g.test_unknown_fields_of_the_body_do_not_break_the_action = function()
    -- За телом стоит браузер: панель, которой дописали поле, не должна
    -- ломаться о старый узел.
    ---@type any
    local seen

    configure({
        act = function(action, targets)
            seen = { action = action, targets = targets }

            return { status = 'complete' }
        end,
    })

    local response = ask('POST', '/api/v1/actions', {
        action = 'reload_config',
        targets = { 'storage-001-a' },
        whatever = 'из будущей панели',
    })

    t.assert_equals(response.status, 200)
    t.assert_equals(seen.action, 'reload_config')
end

g.test_action_without_a_name_is_refused = function()
    -- Пустое имя действия — это не действие: узлу его не найти, и дойти
    -- до него оно не должно.
    configure({
        act = function()
            return { status = 'complete' }
        end,
    })

    t.assert_equals(ask('POST', '/api/v1/actions', { action = '', targets = {} }).status, 400)
end

g.test_journal_names_the_method_and_the_path = function()
    -- Запись без способа и пути бесполезна: по ней не найти ни запроса,
    -- ни маршрута, на котором он шёл.
    ask('GET', '/api/v1/cluster')

    t.assert_equals(journal.logged('method=GET'), true)
    t.assert_equals(journal.logged('path=/api/v1/cluster'), true)
end

-- ── Вид отказа и причина источника ───────────────────────────────────

--- Чем панель подписывает любой ответ в JSON, отказ в том числе.
local JSON_TYPE = 'application/json; charset=utf-8'

--- Ошибки Tarantool: ими отказывают источники, которые ходят на узлы.
--- Конструктор в аннотациях описан не полностью, поэтому берётся через
--- промежуточную ссылку.
---@type any
local box_error = box.error

--- Каталог источника: отказ, который приложение возвращает парой
--- `nil, err`, заведён в его собственном каталоге, а не в каталоге панели.
---
--- Заводится у того пакета отказов, который взяла панель, и только после
--- её загрузки, а не в шапке файла. В полном прогоне проверки самого
--- пакета отказов грузят его исходниками и выгружают, и отказ из
--- экземпляра, взятого при загрузке этого файла, панель своим не узнала бы.
---@return TntErrorRegistry
local function source_catalog()
    local own = require('tnt.error').registry({})

    own:define('stand.busy', { status = 409, message = 'узел занят' })

    return own
end

--- Имена полей по алфавиту: вид отказа сверяется составом полей целиком,
--- а не одним-двумя из них.
---@param value table
---@return string[]
local function keys_of(value)
    local keys = {}

    for key in pairs(value) do
        table.insert(keys, key)
    end

    table.sort(keys)

    return keys
end

g.test_our_refusal_from_the_source_is_told_by_its_word = function()
    -- Отказ источника раньше уходил оператору строкой `table: 0x...`:
    -- подстановка звала `tostring` у таблицы, из которой вырезала тайны.
    local own = source_catalog()

    configure({
        act = function()
            return nil, own:new('stand.busy')
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } })

    -- Статус панельный, а не источника: 409 её JS читает как «состояние
    -- кластера не позволяет», а здесь действие просто не выполнено.
    t.assert_equals(response.status, 400)
    t.assert_equals(response.headers['content-type'], JSON_TYPE)
    t.assert_equals(decoded(response).error, { status = 400, message = 'узел занят' })
    t.assert_not_str_contains(response.body, 'table: 0x')
end

g.test_incident_of_our_refusal_reaches_the_operator = function()
    -- О поломке уже написал источник: второй номер увёл бы дежурного
    -- к записи, в которой ничего нет.
    local broken = source_catalog():internal('узел не ответил')

    configure({
        assess = function()
            return nil, broken
        end,
    })

    local response = ask('POST', '/api/v1/actions/assess', { action = 'x', targets = {} })

    t.assert_equals(response.status, 400)
    t.assert_equals(decoded(response).error.incident, broken.incident)
    t.assert_not_str_contains(response.body, 'узел не ответил')
end

g.test_foreign_table_from_the_source_is_not_shown = function()
    -- Таблица со статусом похожа на отказ границы HTTP, но пришла
    -- от источника: кто писал её слово, неизвестно, а её 404 JS панели
    -- прочёл бы как «нет такого адреса».
    configure({
        config = function()
            return nil, { status = 404, message = 'чужой текст' }
        end,
    })

    local response = ask('GET', '/api/v1/config')

    ---@type any
    local refusal = decoded(response).error

    t.assert_equals(response.status, 400)
    t.assert_equals(refusal.message, 'конфигурация не прочитана')
    t.assert_type(refusal.incident, 'string')
    t.assert_not_str_contains(response.body, 'чужой текст')
end

g.test_foreign_reason_goes_to_the_journal_under_the_shown_incident = function()
    configure({
        apply_config = function()
            return nil, box_error.new({ code = box_error.PROC_LUA, reason = 'чужой текст' })
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'x' })

    ---@type any
    local refusal = decoded(response).error

    t.assert_equals(response.status, 400)
    t.assert_equals(refusal.message, 'правка не раскатана')
    t.assert_not_str_contains(response.body, 'чужой текст')

    -- Текст причины наружу не идёт, но и не пропадает: он лежит в записи
    -- о поломке, и находится она по номеру из ответа.
    t.assert_equals(journal.logged('чужой текст'), true)
    t.assert_equals(journal.logged(refusal.incident), true)

    local breakdowns = 0

    for _, entry in ipairs(journal.records()) do
        if entry.module == 'tnt.error' and entry.level == 'error' then
            breakdowns = breakdowns + 1
        end
    end

    -- Одна поломка — одна запись: две читались бы как два происшествия.
    t.assert_equals(breakdowns, 1)
end

g.test_word_of_the_source_is_shown_as_is_and_silence_gets_its_own = function()
    configure({
        authenticate = function()
            return nil, 'учётная запись заблокирована'
        end,
    })

    local said = decoded(ask('POST', '/api/v1/login', { username = 'admin', password = 'x' }))
    local silent = decoded(ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } }))

    t.assert_equals(said.error, { status = 401, message = 'учётная запись заблокирована' })

    -- Отказ без причины — ожидаемый, а не поломка: номера у него нет,
    -- и искать в журнале нечего.
    t.assert_equals(
        silent.error,
        { status = 501, message = 'действия на этом кластере не включены' }
    )
end

g.test_refusals_of_every_origin_share_the_panel_view = function()
    -- Форма тела у панели одна, кто бы ни собрал отказ: сама панель,
    -- перехват поломки или роутер.
    configure({
        snapshot = function()
            error('внутри всё сломалось')
        end,
        act = function()
            return { status = 'complete' }
        end,
    })

    local broken = ask('GET', '/api/v1/cluster')
    local unknown = ask('GET', '/api/v1/nothing')
    local wrong_method = ask('POST', '/api/v1/cluster')
    local unfit = ask('POST', '/api/v1/actions', { action = 'x' })

    ---@type table[]
    local responses = { broken, unknown, wrong_method, unfit }

    for _, response in ipairs(responses) do
        t.assert_equals(response.headers['content-type'], JSON_TYPE, tostring(response.status))
    end

    t.assert_equals(keys_of(decoded(broken).error), { 'incident', 'message', 'status' })
    t.assert_equals(keys_of(decoded(unknown).error), { 'incident', 'message', 'status' })
    t.assert_equals(keys_of(decoded(unfit).error), { 'fields', 'message', 'status' })
    t.assert_equals(decoded(unknown).error.message, 'нет такого адреса')

    -- Перечень способов при 405 требует RFC 9110 от ответа, а не от того,
    -- кто первым собрал отказ: подставленный обработчик его не теряет.
    t.assert_equals(wrong_method.headers.allow, 'GET, HEAD, OPTIONS')
end

g.test_field_named_like_a_secret_is_still_explained = function()
    -- Разбор по полям дописывается после вида, а не подстановкой: среди
    -- примет тайны есть `token`, и объяснение поля `confirm_token` ушло
    -- бы оператору словом «скрыто».
    configure({
        act = function()
            return { status = 'complete' }
        end,
    })

    ---@type any
    local refusal = decoded(ask('POST', '/api/v1/actions', {
        action = 'x',
        targets = { 'a' },
        confirm_token = 1,
    })).error

    t.assert_type(refusal.fields.confirm_token, 'string')
    t.assert_not_equals(refusal.fields.confirm_token, require('tnt.log').HIDDEN)
end

g.test_unknown_gate_code_stays_the_code_of_the_gate = function()
    -- Код в теле — код ворот, а не код каталога панели: по нему панель
    -- узнаёт, какого шага ждут от оператора.
    configure({
        act = function()
            return { refused = { allow = false, code = 'НЕЧТО', message = 'так нельзя' } }
        end,
    })

    local refusal = decoded(ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } })).error

    t.assert_equals(refusal, { status = 400, message = 'так нельзя', code = 'НЕЧТО' })
end

g.test_missing_confirmation_is_answered_in_the_panel_view = function()
    configure({
        act = function()
            return {
                refused = { allow = false, code = 'CONFIRMATION_REQUIRED' },
                assessment = { level = 'danger' },
            }
        end,
    })

    local response = ask('POST', '/api/v1/actions', { action = 'x', targets = { 'a' } })

    t.assert_equals(response.status, 428)
    t.assert_equals(response.headers['content-type'], JSON_TYPE)
    t.assert_equals(decoded(response), {
        error = {
            status = 428,
            message = 'действие отвергнуто: нужно подтверждение',
            code = 'CONFIRMATION_REQUIRED',
        },
        assessment = { level = 'danger' },
    })
end

g.test_unfinished_rollout_without_a_word_still_says_something = function()
    -- Раскатка назвала поломку не словом, а значением: чужое значение
    -- наружу не идёт, но фаза и отчёт остаются на месте.
    configure({
        apply_config = function()
            return { phase = 'commit', err = { errno = 5 } }
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'x' })
    local body = decoded(response)

    t.assert_equals(response.status, 409)
    t.assert_str_contains(body.error.message, 'не закончена')
    t.assert_equals(body.error.phase, 'commit')
    t.assert_type(body.error.incident, 'string')
    t.assert_equals(body.rollout.phase, 'commit')
end

g.test_rollout_in_an_unknown_phase_without_a_word_is_a_plain_error = function()
    configure({
        apply_config = function()
            return { phase = 'нечто', err = { errno = 5 } }
        end,
    })

    local response = ask('POST', '/api/v1/config', { text = 'x' })

    t.assert_equals(response.status, 400)
    t.assert_str_contains(decoded(response).error.message, 'не раскатана')
end
