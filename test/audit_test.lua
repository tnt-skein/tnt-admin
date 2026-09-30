--- Тесты маршрутов журнала аудита в панели. Источники подменяются:
--- ни журнала, ни сервера. Журнал за проводом — в `audit_server_test.lua`.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.http.handlers.audit')

--- Панель, собранная на последних названных источниках.
---@type TntAdminPanel
local panel

--- С чем звали источники.
---@type table
local asked

--- Личность, которую отдаёт вход.
---@type table
local identity

--- Источник выгрузки: отдаёт заданные куски по одному.
---@param pieces string[]
---@return fun(range: table): function
local function giving(pieces)
    return function(range)
        asked.export = range

        local index = 0

        return function()
            index = index + 1
            asked.produced = index

            return pieces[index]
        end
    end
end

--- Источник проверки: запоминает аргументы и отдаёт отчёт.
---@param report table|nil
---@param reason string|nil
---@return fun(opts: table): table|nil, string|nil
local function verifying(report, reason)
    return function(opts)
        asked.verify = opts

        return report, reason
    end
end

--- Настраивает панель со входом и заданными источниками журнала.
---@param sources table
local function configure(sources)
    sources.authorize = function()
        return identity
    end

    panel = helper.panel(sources)
end

g.before_each(function()
    helper.load('tnt.admin.app.support.root')
    asked = {}
    identity = { username = 'аудитор', readonly = true, audit = true }

    configure({
        audit = giving({ '{"id":1}\n', '{"id":2}\n' }),
        audit_verify = verifying({ ok = true, scanned = 2, seals = 0 }),
    })
end)

g.after_each(function()
    helper.unload()
end)

--- GET по адресу панели.
---@param path string Путь со строкой запроса
---@return table
local function get(path)
    return panel.ask('GET', path)
end

--- Тело потока, собранное так же, как его обходит сервер.
local drained = helper.drained

--- Тело отказа.
---@param response table
---@return table
local function refusal(response)
    return json.decode(response.body).error
end

-- ── Выгрузка ─────────────────────────────────────────────────────────

g.test_export_goes_out_as_a_stream = function()
    local response = get('/api/v1/audit?from_id=2&to_id=5')

    t.assert_equals(response.status, 200)
    t.assert_equals(response.headers['content-type'], 'application/x-ndjson; charset=utf-8')
    t.assert_equals(response.headers['x-accel-buffering'], 'no')
    t.assert_equals(response.headers['content-length'], nil)
    t.assert_type(response.body, 'function')

    -- Строка запроса доезжает до источника числами, а сам источник
    -- до обхода тела не зовётся ни разу: выгрузка идёт за клиентом.
    t.assert_equals(asked.export, { from_id = 2, to_id = 5 })
    t.assert_equals(asked.produced, nil)

    t.assert_equals(drained(response), '{"id":1}\n{"id":2}\n')
end

g.test_export_without_a_range_is_the_whole_log = function()
    drained(get('/api/v1/audit'))

    t.assert_equals(asked.export, {})
end

g.test_unknown_query_fields_are_dropped = function()
    -- Метку от кэша дописывают браузер и прокси: выгрузка о неё
    -- не ломается, и до источника она не доезжает.
    drained(get('/api/v1/audit?from_id=3&_=1789041300'))

    t.assert_equals(asked.export, { from_id = 3 })
end

g.test_export_needs_the_audit_right = function()
    -- Право менять кластер — не право читать журнал: проверять журнал
    -- должен уметь тот, кто не может его подделать, и наоборот.
    identity = { username = 'оператор', readonly = false }

    local response = get('/api/v1/audit')

    t.assert_equals(response.status, 403)
    t.assert_equals(refusal(response).message, 'у вас нет права читать журнал аудита')
    t.assert_equals(asked.export, nil)
end

g.test_audit_right_is_granted_only_by_true = function()
    -- Право — признак, а не что угодно правдивое: строка «нет» в личности
    -- не должна открывать журнал.
    identity = { username = 'оператор', audit = 'нет' }

    t.assert_equals(get('/api/v1/audit').status, 403)
    t.assert_equals(get('/api/v1/audit/verify').status, 403)
end

g.test_right_is_checked_before_the_query = function()
    identity = { username = 'гость', readonly = true }

    t.assert_equals(get('/api/v1/audit?from_id=не-число').status, 403)
end

g.test_open_panel_reads_the_log = function()
    -- Панель без входа открыта целиком: права полные, чтение журнала тоже.
    panel = helper.panel({ audit = giving({ '{"id":1}\n' }) })

    local response = get('/api/v1/audit')

    t.assert_equals(response.status, 200)
    t.assert_equals(drained(response), '{"id":1}\n')
end

g.test_bad_range_is_refused_with_the_fields = function()
    local response = get('/api/v1/audit?from_id=первая&to_id=0')
    local body = refusal(response)

    t.assert_equals(response.status, 400)
    t.assert_equals(body.message, 'отбор записей журнала не разобран')
    t.assert_type(body.fields.from_id, 'string')
    t.assert_type(body.fields.to_id, 'string')
    t.assert_equals(asked.export, nil)
end

g.test_record_number_has_at_most_fourteen_digits = function()
    -- Выше 2^53 целые в Lua идут через одно: номер молча стал бы соседним.
    -- Предел ниже и круглый, потому что его печатает отказ.
    t.assert_equals(get('/api/v1/audit?from_id=99999999999999').status, 200)
    t.assert_equals(get('/api/v1/audit?to_id=1').status, 200)

    local response = get('/api/v1/audit?from_id=100000000000000&to_id=0')

    t.assert_equals(response.status, 400)
    t.assert_equals(refusal(response).fields, {
        from_id = 'должно быть целым числом от 1 до 99999999999999, а не 1e+14',
        to_id = 'должно быть целым числом от 1 до 99999999999999, а не 0',
    })
end

g.test_export_without_a_source_is_not_available = function()
    configure({})

    local response = get('/api/v1/audit')

    t.assert_equals(response.status, 501)
    t.assert_equals(refusal(response).message, 'журнал аудита этой панели недоступен')
end

g.test_bad_range_is_told_before_the_missing_source = function()
    configure({})

    t.assert_equals(get('/api/v1/audit?from_id=0').status, 400)
end

g.test_log_that_cannot_be_read_is_reported = function()
    configure({
        audit = function()
            return nil, 'спейс app_audit не развёрнут'
        end,
    })

    local response = get('/api/v1/audit')

    t.assert_equals(response.status, 400)
    t.assert_equals(refusal(response).message, 'спейс app_audit не развёрнут')
end

g.test_log_that_cannot_be_read_without_a_word_is_reported = function()
    configure({
        audit = function()
            return nil
        end,
    })

    t.assert_equals(refusal(get('/api/v1/audit')).message, 'журнал аудита не прочитан')
end

g.test_head_of_the_export_does_not_read_the_log = function()
    local response = panel.ask('HEAD', '/api/v1/audit')

    t.assert_equals(response.status, 200)
    t.assert_equals(response.body, '')
    t.assert_equals(asked.produced, nil)
end

-- ── Проверка цепочки ─────────────────────────────────────────────────

g.test_verify_reports_the_chain = function()
    local response = get('/api/v1/audit/verify?from_id=2&to_id=9')

    t.assert_equals(response.status, 200)
    t.assert_equals(response.headers['content-type'], 'application/json; charset=utf-8')
    t.assert_equals(json.decode(response.body), { ok = true, scanned = 2, seals = 0 })

    -- Бюджет за запрос ставит панель, если клиент его не назвал.
    t.assert_equals(asked.verify, { from_id = 2, to_id = 9, budget = 50000 })
end

g.test_broken_chain_is_an_answer_and_not_a_refusal = function()
    configure({
        audit_verify = verifying({
            ok = false,
            scanned = 3,
            seals = 0,
            broken_at = 3,
            reason = 'содержимое записи не соответствует её хешу',
        }),
    })

    local response = get('/api/v1/audit/verify')

    t.assert_equals(response.status, 200)
    t.assert_equals(json.decode(response.body).broken_at, 3)
end

g.test_verify_goes_on_from_the_cursor = function()
    local hash = string.rep('ab', 32)

    get(('/api/v1/audit/verify?after_id=4&hash=%s&to_id=9&budget=10'):format(hash))

    t.assert_equals(asked.verify, { to_id = 9, budget = 10, cursor = { after_id = 4, hash = hash } })

    -- Курсор без хеша — тоже курсор: сверять ссылку следующей записи
    -- будет не с чем, и это решит проверка журнала.
    get('/api/v1/audit/verify?after_id=4')

    t.assert_equals(asked.verify, { budget = 50000, cursor = { after_id = 4 } })
end

g.test_budget_is_bounded = function()
    t.assert_equals(get('/api/v1/audit/verify?budget=50000').status, 200)
    t.assert_equals(asked.verify.budget, 50000)
    t.assert_equals(get('/api/v1/audit/verify?budget=1').status, 200)
    t.assert_equals(asked.verify.budget, 1)

    t.assert_equals(get('/api/v1/audit/verify?budget=50001').status, 400)
    t.assert_equals(get('/api/v1/audit/verify?budget=0').status, 400)
end

g.test_cursor_and_the_start_together_are_refused = function()
    local response = get('/api/v1/audit/verify?after_id=4&from_id=2')

    t.assert_equals(response.status, 400)
    t.assert_equals(refusal(response).fields, {
        after_id = 'курсор не задаётся вместе с from_id: он сам знает, откуда продолжать',
    })
    t.assert_equals(asked.verify, nil)
end

g.test_hash_without_its_record_is_refused = function()
    local response = get('/api/v1/audit/verify?hash=abcd')

    t.assert_equals(response.status, 400)
    t.assert_equals(
        refusal(response).fields,
        { hash = 'хеш курсора задаётся только вместе с after_id' }
    )
end

g.test_hash_is_hex_digits = function()
    t.assert_equals(get('/api/v1/audit/verify?after_id=4&hash=').status, 400)
    t.assert_equals(get('/api/v1/audit/verify?after_id=4&hash=xyz').status, 400)
    t.assert_equals(get('/api/v1/audit/verify?after_id=4&hash=0f').status, 200)
end

g.test_verify_needs_the_audit_right = function()
    identity = { username = 'оператор', readonly = false }

    local response = get('/api/v1/audit/verify')

    t.assert_equals(response.status, 403)
    t.assert_equals(asked.verify, nil)
end

g.test_verify_without_a_source_is_not_available = function()
    configure({})

    t.assert_equals(get('/api/v1/audit/verify').status, 501)
end

g.test_contradiction_is_told_before_the_missing_source = function()
    configure({})

    t.assert_equals(get('/api/v1/audit/verify?hash=ab').status, 400)
end

g.test_verify_that_found_no_answer_is_reported = function()
    configure({
        audit_verify = verifying(
            nil,
            'голова журнала ушла дальше записи 4: проверку надо начать заново'
        ),
    })

    local response = get('/api/v1/audit/verify?after_id=4')

    t.assert_equals(response.status, 400)
    t.assert_equals(
        refusal(response).message,
        'голова журнала ушла дальше записи 4: проверку надо начать заново'
    )
end
