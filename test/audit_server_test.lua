--- Журнал аудита за проводом: настоящий журнал на узле, настоящий сервер
--- и клиент, который читает сокет сам.
---
--- Маршруты журнала проверены таблицами в `audit_test.lua`, данные
--- страницы журнала — в `pages_test.lua`, а выгрузка кусками — в пакете
--- журнала. Здесь — то, чего не видно ни там, ни там: что журнал больше
--- одного куска уходит по проводу несколькими кусками `Transfer-Encoding:
--- chunked` и целиком, а обрыв источника посреди выгрузки рвёт соединение
--- без завершающего куска. То же у страницы журнала, и сверх того — что
--- её первый кусок уходит раньше, чем выгрузка прочитана, а читает она
--- выгрузку до своего предела, а не журнал целиком. Клиент HTTP здесь
--- не годится: он сам собирает куски и прячет, пришёл ли завершающий.
---
--- Панель поднимается на узле журнала, а не в процессе проверок: `box`
--- настроен только там. Докер не нужен, гейт от него не зависит.

local fio = require('fio')
local json = require('json')
local socket = require('socket')
local t = require('luatest')

local helper = dofile('test/helper.lua')
local journal = helper.journal

local g = t.group('tnt.admin.app.http.handlers.audit.server')

--- Исходники панели с путями от корня и без самой роли: проверяются
--- маршруты и страница журнала за проводом, а применять роль на узле,
--- поднятом без кластерной конфигурации, нечему.
local PANEL = helper.ON_NODE

--- Где лежит модуль роли в дереве: по нему панель на узле находит
--- свои страницы. Путём от корня — узел живёт в своём каталоге.
local ANCHOR = fio.abspath(helper.ROOT .. '.lua')

--- Сколько записей в куске выгрузки у панели на узле: мало, чтобы журнал
--- в тысячу записей ушёл десятью кусками.
local BATCH = 100

--- Сколько секунд источник ждёт проверку на втором куске страницы.
---
--- Проверка отпускает его, как только получила первый кусок, и срок
--- нужен только сломанной странице, которая читает выгрузку до ответа:
--- она простоит его и отдаст первый кусок с полным счётом вызовов,
--- вместо того чтобы повиснуть.
local HOLD = 10

--- Сколько секунд клиент страницы ждёт следующего куска.
---
--- Дольше удержания источника: сломанная страница придёт после него
--- с полным счётом вызовов, и проверка назовёт счёт, а не пустоту.
local WAIT = HOLD + 5

--- Порт панели на узле.
---@type integer
local port

g.before_all(function()
    g.server = journal.start()
end)

g.after_all(function()
    journal.stop(g.server)
end)

g.before_each(function()
    journal.prepare(g.server)

    port = g.server:exec(function(panel, anchor, batch)
        local http_server = require('http.server')
        local sources = require('tnt.testing.sources')

        local panels = sources.load(panel, 'tnt.admin.app.http.panel')

        -- Страницы панель находит по модулю роли, а роли на узле нет:
        -- каталог пакета ей показывают деревом разработки.
        ---@type any
        local root = require('tnt.admin.app.support.root')

        root._set_source({
            anchor = function()
                return anchor
            end,
        })

        local source = {
            authorize = function()
                return { username = 'аудитор', readonly = true, audit = true }
            end,
            audit = function(range)
                return _G.audit.stream.open({ from_id = range.from_id, to_id = range.to_id, batch = batch })
            end,
            audit_verify = _G.audit.verify.run,
        }

        -- Панель собирает тот же вызов, каким её встраивает приложение
        -- со своим сервером: граница ядра, маршруты API и страницы.
        ---@type any
        local httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })

        panels.new(source).attach(httpd)
        httpd:start()

        rawset(_G, 'httpd', httpd)

        return httpd.tcp_server:name().port
    end, { PANEL, ANCHOR, BATCH })
end)

g.after_each(function()
    g.server:exec(function()
        _G.httpd:stop()
    end)
end)

--- GET по сырому сокету: всё, что пришло до закрытия соединения.
---@param path string
---@return string
local function fetched(path)
    local connection = socket.tcp_connect('127.0.0.1', port)
    local parts = {}

    connection:write(('GET %s HTTP/1.1\r\nHost: panel\r\nConnection: close\r\n\r\n'):format(path))

    -- Читается до закрытия соединения: незавершённая выгрузка тем
    -- и видна, что последнего куска в ней нет.
    local part = connection:read(65536, 5)

    while part ~= nil and part ~= '' do
        table.insert(parts, part)

        part = connection:read(65536, 5)
    end

    connection:close()

    return table.concat(parts)
end

--- Тело ответа JSON, пришедшего по сырому сокету.
---@param path string
---@return table
local function answered(path)
    local body = fetched(path):match('\r\n\r\n(.*)$') --[[@as string]]

    return json.decode(body)
end

--- Разбирает ответ кусками: заголовки и тела кусков по порядку.
---
--- Разбор строгий: кусок, длина которого не сходится с заявленной, —
--- поломка проверки, а не ответа, и она падает здесь же.
---@param answer string
---@return string head Строка статуса и заголовки
---@return string[] pieces Тела кусков, без завершающего
---@return boolean finished Пришёл ли завершающий кусок
local function chunks_of(answer)
    local head, rest = answer:match('^(.-)\r\n\r\n(.*)$')
    ---@cast head string
    ---@cast rest string
    local pieces = {}

    while rest ~= '' do
        local size_text, after = rest:match('^(%x+)\r\n(.*)$')

        if size_text == nil then
            break
        end

        local size = tonumber(size_text, 16) --[[@as integer]]
        local tail = after --[[@as string]]

        if size == 0 then
            return head, pieces, tail == '\r\n'
        end

        assert(tail:sub(size + 1, size + 2) == '\r\n', 'кусок не той длины, что заявлена')

        table.insert(pieces, tail:sub(1, size))
        rest = tail:sub(size + 3)
    end

    return head, pieces, false
end

--- Записи выгрузки из её строк.
---@param pieces string[]
---@return table[]
local function rows_of(pieces)
    local rows = {}

    for line in table.concat(pieces):gmatch('([^\n]*)\n') do
        table.insert(rows, json.decode(line))
    end

    return rows
end

g.test_log_larger_than_a_piece_goes_out_in_pieces = function()
    journal.fill(g.server, { { count = 1000, at = 1000 } })

    local head, pieces, finished = chunks_of(fetched('/api/v1/audit'))

    t.assert_str_matches(head, '^HTTP/1.1 200 .*')
    t.assert_str_contains(head:lower(), 'transfer-encoding: chunked')
    t.assert_str_contains(head:lower(), 'content-type: application/x-ndjson; charset=utf-8')
    t.assert_not_str_contains(head:lower(), 'content-length')
    t.assert_equals(finished, true)

    -- Кусок — одна выборка источника: в памяти узла на выгрузку лежит
    -- сотня строк, а не тысяча.
    t.assert_equals(#pieces, 10)

    for _, piece in ipairs(pieces) do
        t.assert_equals(#rows_of({ piece }), BATCH)
    end

    -- Выгрузка целая и по порядку, а цепочка по её строкам сходится:
    -- принявший проверяет журнал сам, не спрашивая узел.
    local rows = rows_of(pieces)
    local previous

    t.assert_equals(#rows, 1000)

    for index, row in ipairs(rows) do
        t.assert_equals(row.id, index)
        t.assert_equals(row.prev_hash, previous)

        previous = row.current_hash
    end
end

g.test_range_travels_through_the_query = function()
    journal.fill(g.server, { { count = 300, at = 1000 } })

    local _, pieces, finished = chunks_of(fetched('/api/v1/audit?from_id=150&to_id=260'))
    ---@type any
    local rows = rows_of(pieces)

    t.assert_equals(finished, true)
    t.assert_equals({ #pieces, #rows, rows[1].id, rows[#rows].id }, { 2, 111, 150, 260 })
end

--- Сносит журнал на узле перед третьим куском выгрузки: источник
--- на нём отказывает, когда первые куски ответа уже ушли.
local function vanishing_before_the_third_piece()
    g.server:exec(function()
        local seen = 0

        _G.audit.stream._set_source({
            yield = function()
                seen = seen + 1

                if seen == 3 then
                    box.space[_G.audit.space.name()]:drop()
                end
            end,
        })
    end)
end

g.test_broken_source_cuts_the_connection_without_the_final_piece = function()
    journal.fill(g.server, { { count = 1000, at = 1000 } })

    -- Журнал сносят посреди выгрузки: источник отказывает, и клиент
    -- обязан увидеть обрыв — завершающий кусок сказал бы ему, что
    -- выгрузка целая.
    vanishing_before_the_third_piece()

    local head, pieces, finished = chunks_of(fetched('/api/v1/audit'))

    t.assert_str_matches(head, '^HTTP/1.1 200 .*')
    t.assert_equals(finished, false)
    t.assert_equals(#pieces, 2)
    t.assert_equals(#rows_of(pieces), 2 * BATCH)
end

g.test_chain_is_verified_over_the_wire_with_a_cursor = function()
    journal.fill(g.server, { { count = 1000, at = 1000 } })

    local first = answered('/api/v1/audit/verify?budget=600')

    t.assert_equals({ first.ok, first.scanned, first.cursor.after_id }, { true, 600, 600 })

    local cursor = ('after_id=%d&hash=%s'):format(first.cursor.after_id, first.cursor.hash)

    t.assert_equals(answered('/api/v1/audit/verify?' .. cursor), { ok = true, scanned = 400, seals = 0 })

    -- Подделка в обход писателя — вердикт в ответе 200, а не отказ.
    g.server:exec(function()
        box.space[_G.audit.space.name()]:update({ 700 }, { { '=', 'action', 'подделка' } })
    end)

    local forged = answered('/api/v1/audit/verify?from_id=650')

    t.assert_equals({ forged.ok, forged.broken_at }, { false, 700 })
end

-- ── Страница журнала ─────────────────────────────────────────────────

--- Следующий кусок ответа `Transfer-Encoding: chunked` из соединения.
---
--- Читает ровно кусок — строку длины, тело и его конец строки, — а не всё,
--- что пришло: проверке нужно знать, что к этому мигу получил клиент.
---@param connection table
---@return string|nil piece Тело куска; пустая строка — завершающий; nil — соединение закрылось
local function piece_of(connection)
    local size_text = tostring(connection:read('\r\n', WAIT)):match('^(%x+)\r\n$')

    if size_text == nil then
        return nil
    end

    local size = tonumber(size_text, 16) --[[@as integer]]

    return tostring(connection:read(size + 2, WAIT)):sub(1, size)
end

--- Номера записей в разметке страницы журнала, по порядку.
---@param page string
---@return integer[]
local function ids_of(page)
    local ids = {}

    for id in page:gmatch('<td class="font%-monospace small text%-body%-secondary">(%d+)</td>') do
        table.insert(ids, tonumber(id))
    end

    return ids
end

--- Сколько раз страница позвала источник выгрузки на узле.
---@return integer
local function calls()
    return g.server:exec(function()
        return _G.held.calls
    end)
end

g.test_log_page_goes_out_before_the_export_is_read = function()
    journal.fill(g.server, { { count = 2500, at = 1000 } })

    -- Источник считает свои вызовы, а на втором куске ждёт, пока клиент
    -- не получит первый кусок страницы: иначе быстрый узел успел бы
    -- дочитать всё раньше, чем проверка спросит счёт.
    g.server:exec(function(hold)
        local fiber = require('fiber')
        local held = { calls = 0, gate = fiber.channel(1) }

        rawset(_G, 'held', held)

        _G.audit.stream._set_source({
            yield = function()
                held.calls = held.calls + 1

                if held.calls == 2 then
                    held.gate:get(hold)
                end
            end,
        })
    end, { HOLD })

    local connection = socket.tcp_connect('127.0.0.1', port)

    connection:write('GET /audit HTTP/1.1\r\nHost: panel\r\nConnection: close\r\n\r\n')

    local head = tostring(connection:read('\r\n\r\n', WAIT))
    local first = piece_of(connection)
    local at_first = calls()

    g.server:exec(function()
        _G.held.gate:put(true)
    end)

    local pieces = { first }
    local piece = piece_of(connection)

    while piece ~= nil and piece ~= '' do
        table.insert(pieces, piece)

        piece = piece_of(connection)
    end

    connection:close()

    local page = table.concat(pieces)
    local ids = ids_of(page)

    t.assert_str_matches(head, '^HTTP/1.1 200 .*')
    t.assert_str_contains(head:lower(), 'transfer-encoding: chunked')
    t.assert_str_contains(head:lower(), 'content-type: text/html; charset=utf-8')
    t.assert_str_contains(head:lower(), 'x-accel-buffering: no')
    t.assert_not_str_contains(head:lower(), 'content-length')

    -- Первый кусок — начало страницы, и ушёл он, когда источник прочёл
    -- не больше двух кусков выгрузки из двадцати пяти.
    t.assert_str_matches(first, '^<!doctype html>.*')
    t.assert_le(at_first, 2)

    -- Страница целая: пришёл завершающий кусок, записей — предел страницы,
    -- по порядку, а дальше — ссылка. Выгрузку она прочла до предела и на
    -- кусок вперёд: одиннадцать вызовов, а не двадцать шесть.
    t.assert_equals(piece, '')
    t.assert_gt(#pieces, 1)
    t.assert_equals({ #ids, ids[1], ids[#ids] }, { 1000, 1, 1000 })
    t.assert_str_contains(page, 'записей на странице: 1000')
    t.assert_str_contains(page, 'href="/audit?from_id=1001"')
    t.assert_equals(calls(), 11)
end

g.test_log_page_range_travels_through_the_form = function()
    journal.fill(g.server, { { count = 2500, at = 1000 } })

    -- Адреса — те же, что в примере документа панели («Журнал — потоком
    -- и по страницам»): номера доезжают до выгрузки числами, а на конце
    -- отрезка ссылки дальше нет.
    local _, pieces, finished = chunks_of(fetched('/audit?from_id=1001&to_id=1500'))
    local page = table.concat(pieces)
    local ids = ids_of(page)

    t.assert_equals(finished, true)
    t.assert_equals({ #ids, ids[1], ids[#ids] }, { 500, 1001, 1500 })
    t.assert_str_contains(page, 'value="1001"')
    t.assert_not_str_contains(page, 'дальше')

    -- Форма шлёт оба поля, и пустое тоже: оно значит «до конца журнала».
    local _, tail = chunks_of(fetched('/audit?from_id=2400&to_id='))

    t.assert_equals(#ids_of(table.concat(tail)), 101)

    local _, wrong = chunks_of(fetched('/audit?from_id=0'))

    t.assert_str_contains(
        table.concat(wrong),
        'отбор записей журнала не разобран: from_id должно быть целым числом от 1 до 99999999999999, а не 0'
    )
end

g.test_log_page_shows_what_the_writer_puts = function()
    -- Колонки страницы — поля, которые кладёт писатель журнала: стык
    -- страницы с выгрузкой виден только на записи настоящего писателя.
    local stamp = g.server:exec(function()
        local row =
            _G.audit.record({ action = 'panel.reload_config.finished', user = 'admin', scope = 'storage-001-a' })

        -- Отметка в кортеже — целое int64: число Lua из него точное.
        local micros = tonumber(row.ts) --[[@as number]]

        return os.date('%d.%m.%Y %H:%M:%S', math.floor(micros / 1000000))
    end)

    local _, pieces = chunks_of(fetched('/audit'))
    local page = table.concat(pieces)

    t.assert_str_contains(page, '<td class="small text-nowrap">' .. stamp .. '</td>')
    t.assert_str_contains(page, '<td class="font-monospace small">admin</td>')
    t.assert_str_contains(page, '<td>panel.reload_config.finished</td>')
    t.assert_str_contains(page, '>storage-001-a</td>')
end

g.test_log_page_cut_by_a_vanished_log_has_no_final_piece = function()
    journal.fill(g.server, { { count = 1000, at = 1000 } })

    -- Первые куски страницы ушли: сказать «500» нечем, и клиент обязан
    -- увидеть обрыв, а не страницу, которая выглядит целой.
    vanishing_before_the_third_piece()

    local head, pieces, finished = chunks_of(fetched('/audit'))
    local page = table.concat(pieces)
    local ids = ids_of(page)

    t.assert_str_matches(head, '^HTTP/1.1 200 .*')
    t.assert_equals(finished, false)
    t.assert_equals(ids[1], 1)
    t.assert_le(#ids, 2 * BATCH)
    t.assert_not_str_contains(page, 'записей на странице')
end
